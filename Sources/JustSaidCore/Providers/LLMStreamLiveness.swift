import Foundation
import Synchronization

/// 流式 LLM 调用的活性守护(首帧期限、解码进展期限),供各协议适配器共用。
///
/// 适配器只负责开流与解析事件,并在解析时报告两件事:第一个带负载的事件(首帧)与
/// 成功解码的当前非空增量(进展)。期限、终态与取消语义全部在这里,不得在适配器里各写一份。
/// 契约见 `.trellis/spec/core/live-summary-recovery.md` 的检出预算一节。
enum LLMStreamLiveness {
  struct Hooks: Sendable {
    let onFirstFrame: @Sendable () -> Void
    let onDecodedProgress: @Sendable () throws -> Void
  }

  /// - Parameters:
  ///   - firstFrameTimeout: 发出请求 → 第一个数据帧;nil 不设。
  ///   - progressTimeout: 无解码进展期限;nil 不设(健康流只受字节空闲超时约束)。
  ///   - open: 开流(含握手与响应头,计入首帧/进展预算)。
  ///   - consume: 消费到协议定义的完整结束;未完整结束必须抛错。
  static func run<Result: Sendable>(
    firstFrameTimeout: TimeInterval?,
    progressTimeout: TimeInterval?,
    open: @escaping @Sendable () async throws -> AsyncThrowingStream<String, Error>,
    consume: @escaping @Sendable (AsyncThrowingStream<String, Error>, Hooks) async throws -> Result
  ) async throws -> Result {
    guard let progressTimeout else {
      return try await guardedByFirstFrame(
        firstFrameTimeout: firstFrameTimeout, open: open, consume: consume)
    }
    let lifetime = try Lifetime(progressTimeout: progressTimeout)
    let hooks = Hooks(
      onFirstFrame: { lifetime.markFirstFrame() },
      onDecodedProgress: { try lifetime.renewProgress() })
    return try await withTaskCancellationHandler {
      do {
        return try await withThrowingTaskGroup(of: Result?.self) { group in
          defer { group.cancelAll() }
          group.addTask {
            do {
              try Task.checkCancellation()
              let stream = try await open()
              let result = try await consume(stream, hooks)
              try Task.checkCancellation()
              try lifetime.finish()
              return result
            } catch {
              try lifetime.finish(error: error)
              throw error
            }
          }
          if let firstFrameTimeout {
            group.addTask {
              try await Task.sleep(
                nanoseconds: UInt64(max(0, firstFrameTimeout) * 1_000_000_000)
              )
              try lifetime.checkFirstFrame(timeout: firstFrameTimeout)
              return nil
            }
          }
          group.addTask {
            while let remaining = try lifetime.remainingProgress() {
              try await Task.sleep(nanoseconds: remaining)
            }
            return nil
          }
          while let finished = try await group.next() {
            // 已解除的看门狗不是 LLM 结果；继续等 reader。
            if let result = finished { return result }
          }
          throw CancellationError()
        }
      } catch {
        // 超时拥有终态后，它取消 reader 产生的 CancellationError 不能反客为主。
        try lifetime.finish(error: error)
        throw error
      }
    } onCancel: {
      try? lifetime.finish(error: CancellationError())
    }
  }

  /// 开流并消费,附带**首帧看门狗**。
  ///
  /// 看门狗只睡一觉:醒来时首帧已到就自行退场(此后是否被砍由空闲超时说了算——长内容
  /// **不得**因为总时长超过首帧阈值被砍);首帧未到才抛错,连带取消开流任务。
  /// `firstFrameTimeout == nil` 时完全不起任务组。
  private static func guardedByFirstFrame<Result: Sendable>(
    firstFrameTimeout: TimeInterval?,
    open: @escaping @Sendable () async throws -> AsyncThrowingStream<String, Error>,
    consume: @escaping @Sendable (AsyncThrowingStream<String, Error>, Hooks) async throws -> Result
  ) async throws -> Result {
    let noProgress: @Sendable () throws -> Void = {}
    guard let firstFrameTimeout else {
      let stream = try await open()
      return try await consume(stream, Hooks(onFirstFrame: {}, onDecodedProgress: noProgress))
    }
    let latch = FirstFrameLatch()
    return try await withThrowingTaskGroup(of: Result?.self) { group in
      group.addTask {
        // 开流与消费放同一个子任务:首帧超时因此覆盖握手与响应头,而流不跨任务边界。
        let stream = try await open()
        return try await consume(
          stream, Hooks(onFirstFrame: { latch.mark() }, onDecodedProgress: noProgress))
      }
      group.addTask {
        try await Task.sleep(
          nanoseconds: UInt64(max(0, firstFrameTimeout) * 1_000_000_000)
        )
        guard latch.isMarked else {
          throw LLMClientError.firstFrameTimedOut(firstFrameTimeout)
        }
        return nil
      }
      while let finished = try await group.next() {
        guard let result = finished else {
          // 看门狗解除,继续等真正的结果。
          continue
        }
        group.cancelAll()
        return result
      }
      // 消费任务只会返回结果或抛错;走到这里说明整个任务组被外部取消了。
      throw CancellationError()
    }
  }

  /// 所有状态都在短临界区中更新；不跨 await / 外部回调持锁，也不为每帧创建任务。
  private final class Lifetime: Sendable {
    private enum Terminal {
      case completed
      case failed(Error)
    }

    private struct State {
      var firstFrameReceived = false
      var deadline: UInt64
      var terminal: Terminal?
    }

    private let progressTimeout: TimeInterval
    private let interval: UInt64
    private let state: Mutex<State>

    init(progressTimeout: TimeInterval) throws {
      self.progressTimeout = progressTimeout
      guard progressTimeout.isFinite, progressTimeout >= 0,
        let interval = UInt64(exactly: (progressTimeout * 1_000_000_000).rounded(.down))
      else { throw LLMClientError.progressTimedOut(progressTimeout) }
      let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
        interval)
      guard !overflow else { throw LLMClientError.progressTimedOut(progressTimeout) }
      self.interval = interval
      state = Mutex(State(deadline: deadline))
    }

    func markFirstFrame() {
      state.withLock {
        guard case nil = $0.terminal else { return }
        $0.firstFrameReceived = true
      }
    }

    func renewProgress() throws {
      try state.withLock { state in
        let now = DispatchTime.now().uptimeNanoseconds
        guard try isActive(&state, now: now) else { return }
        let (deadline, overflow) = now.addingReportingOverflow(interval)
        guard !overflow else {
          let error = LLMClientError.progressTimedOut(progressTimeout)
          state.terminal = .failed(error)
          throw error
        }
        state.deadline = deadline
      }
    }

    func remainingProgress() throws -> UInt64? {
      try state.withLock { state in
        let now = DispatchTime.now().uptimeNanoseconds
        guard try isActive(&state, now: now) else { return nil }
        return state.deadline - now
      }
    }

    func checkFirstFrame(timeout: TimeInterval) throws {
      try state.withLock { state in
        guard try isActive(&state, now: DispatchTime.now().uptimeNanoseconds),
          !state.firstFrameReceived
        else { return }
        let error = LLMClientError.firstFrameTimedOut(timeout)
        state.terminal = .failed(error)
        throw error
      }
    }

    func finish(error: Error? = nil) throws {
      try state.withLock { state in
        guard try isActive(&state, now: DispatchTime.now().uptimeNanoseconds) else { return }
        if let error {
          state.terminal = .failed(error)
          throw error
        }
        state.terminal = .completed
      }
    }

    /// 到期本身即终态；即使看门狗暂未被调度，晚到的增量也不能续命。
    private func isActive(_ state: inout State, now: UInt64) throws -> Bool {
      switch state.terminal {
      case .completed?: return false
      case .failed(let error)?: throw error
      case nil: break
      }
      if now >= state.deadline {
        let error = LLMClientError.progressTimedOut(progressTimeout)
        state.terminal = .failed(error)
        throw error
      }
      return true
    }
  }

  /// 首帧是否到达的一次性标记。看门狗睡醒时读一次,消费侧写一次,用最简单的锁即可。
  /// Safety invariant: `marked` is lock-protected in both `mark()` and `isMarked`;
  /// the consumer and watchdog share only this latch, never an unlocked reference to its state.
  private final class FirstFrameLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
      lock.lock()
      marked = true
      lock.unlock()
    }

    var isMarked: Bool {
      lock.lock()
      defer { lock.unlock() }
      return marked
    }
  }
}
