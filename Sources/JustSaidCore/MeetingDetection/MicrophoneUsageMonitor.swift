import Foundation
import os

/// 按固定间隔读进程快照，交给 `MeetingCallDetector`，把事件送给调用方并写诊断日志。
///
/// 线程模型：轮询在私有串行队列上跑；检测状态只在 `lock` 内读写，而且只有 `ingest` 这段纯内存计算
/// 在锁内。读快照、写账本、回调 `onEvent` 都在锁外，所以：
/// - `onEvent` 里可以直接调用本类的任何方法（不会死锁）；
/// - 主线程调用 `promptCandidates`、`recordingDidStart` 等不会等一次快照或账本写入。
/// `onEvent` 在私有队列上回调，调用方自行切线程。
/// `stop()` 只清观察状态（正在通话的家族）；录制状态、被跟踪的 App、用户排除清单是外部输入，保留。
/// 正在进行中的一拍在 `stop()` 之后丢弃；已经交到回调阶段的一批事件可能仍会送达一次。
// Safety invariant: lock-protected. `state` is only read or written inside `lock`; the provider,
// the ledger and the `onEvent` callback are invoked outside the lock on the serial `queue`.
public final class MicrophoneUsageMonitor: @unchecked Sendable {
  public static let defaultPollInterval: TimeInterval = 0.5

  private struct State {
    var detector: MeetingCallDetector
    var timer: DispatchSourceTimer?
    var handler: (@Sendable ([MeetingDetectionEvent]) -> Void)?
    /// `stop()` 每次加一：读快照期间被停掉的那一拍据此丢弃。
    var generation = 0
    /// 诊断账本每天的写入份额（按事件时间的日历日），见 `DailyBudget`。
    var activityBudget = DailyBudget(limit: MicrophoneUsageMonitor.activityLedgerLimitPerDay)
    var callBudget = DailyBudget(limit: MicrophoneUsageMonitor.callLedgerLimitPerDay)
  }

  /// 账本全局每日 2000 条，会议检测不能挤占别的诊断，也不能被某个反复开关麦的进程占满：
  /// 输入输出起停每天最多 400 条，通话起止与结束提示最多 200 条，超出只写 os.Logger。
  /// 被排除的家族（输入法、听写工具）的起停只写 os.Logger，不进账本。
  /// 用户对提醒的动作（`recordPromptAction`）由用户点击驱动，不设份额。
  public static let activityLedgerLimitPerDay = 400
  public static let callLedgerLimitPerDay = 200

  /// 每天最多 `limit` 次的计数；日期变了重新数。
  struct DailyBudget {
    let limit: Int
    private var day: Date?
    private var used = 0
    init(limit: Int) { self.limit = limit }
    mutating func take(at date: Date) -> Bool {
      let today = Calendar.current.startOfDay(for: date)
      if today != day {
        day = today
        used = 0
      }
      guard used < limit else { return false }
      used += 1
      return true
    }
  }

  private let provider: AudioProcessSnapshotProvider
  private let ledger: DiagnosticEventLedger
  private let pollInterval: TimeInterval
  private let queue = DispatchQueue(label: "com.justsaid.meeting-detection")
  private let logger = Logger(subsystem: "com.justsaid.app", category: "MeetingDetection")
  private let lock = NSLock()
  private var state: State

  /// `lookup` 必须由调用方给：系统实现依赖 AppKit，放在界面层，Core 不导入 AppKit。
  public init(
    provider: AudioProcessSnapshotProvider = CoreAudioProcessSnapshotProvider(),
    lookup: RunningAppLookup,
    selfPID: Int32 = getpid(),
    thresholds: MeetingCallDetector.Thresholds = .init(),
    ledger: DiagnosticEventLedger = .shared,
    pollInterval: TimeInterval = MicrophoneUsageMonitor.defaultPollInterval
  ) {
    self.provider = provider
    self.ledger = ledger
    self.pollInterval = pollInterval
    self.state = State(
      detector: MeetingCallDetector(
        resolver: MeetingAppIdentityResolver(lookup: lookup, selfPID: selfPID),
        thresholds: thresholds))
  }

  public var isRunning: Bool { lock.withLock { state.timer != nil } }

  public func start(onEvent: @escaping @Sendable ([MeetingDetectionEvent]) -> Void) {
    lock.withLock {
      guard state.timer == nil else { return }
      state.handler = onEvent
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(50))
      source.setEventHandler { [weak self] in self?.tick(at: nil) }
      state.timer = source
      source.resume()
    }
  }

  /// 关掉轮询并清空观察状态，保留录制状态与用户排除清单。
  public func stop() {
    lock.withLock {
      state.timer?.cancel()
      state.timer = nil
      state.handler = nil
      state.generation += 1
      state.detector.resetObservations()
    }
  }

  /// 手动走一拍（验证与调试用；正常由定时器驱动）。不能在 `onEvent` 里调用。
  public func poll(at now: Date = Date()) {
    dispatchPrecondition(condition: .notOnQueue(queue))
    queue.sync { tick(at: now) }
  }

  public var promptCandidates: [MeetingCallInfo] {
    lock.withLock { state.detector.promptCandidates }
  }
  public var trackedAppKey: String? { lock.withLock { state.detector.trackedAppKey } }

  public func setUserExcludedAppKeys(_ keys: Set<String>) {
    lock.withLock { state.detector.userExcludedAppKeys = keys }
  }

  public func ignore(appKey: String) { lock.withLock { state.detector.ignore(appKey: appKey) } }

  public func recordingDidStart(tracking appKey: String? = nil) {
    lock.withLock { state.detector.recordingDidStart(tracking: appKey) }
  }

  public func recordingDidStop() { lock.withLock { state.detector.recordingDidStop() } }

  /// 只在私有队列上调用。`now` 为 nil 时取读完快照之后的时刻：负载高时读快照可能要几百毫秒，
  /// 在读之前取时间会让「两路首次同时停」的时刻早于真实读数。
  private func tick(at now: Date?) {
    let generation = lock.withLock { state.generation }
    let samples = provider.snapshot()
    let outcome:
      (events: [MeetingDetectionEvent], handler: (@Sendable ([MeetingDetectionEvent]) -> Void)?)? =
        lock.withLock {
          guard state.generation == generation else { return nil }
          let events = state.detector.ingest(samples, at: now ?? Date())
          return (events, state.handler)
        }
    guard let outcome, !outcome.events.isEmpty else { return }
    for event in outcome.events { log(event) }
    outcome.handler?(outcome.events)
  }

  /// 诊断只记 bundle ID（或无 bundle 时的进程名）与时间，不含声音、窗口标题或会议内容。
  private func log(_ event: MeetingDetectionEvent) {
    switch event {
    case .activity(let activity):
      let operation = "\(activity.kind.rawValue)-\(activity.isActive ? "start" : "stop")"
      let who = DiagnosticSanitizer.token(activity.app.key, fallback: "unknown")
      logger.notice(
        "\(operation, privacy: .public) \(who, privacy: .public) excluded=\(activity.isExcluded)")
      guard !activity.isExcluded, lock.withLock({ state.activityBudget.take(at: activity.at) })
      else { return }
      ledger.append(
        event: "meetingDetection.audioActivity", source: "meeting-detection",
        ts: activity.at,
        fields: DiagnosticEventFields(
          family: "meeting-detection", operation: operation, origin: who,
          outcome: "counted"))
    case .callStarted(let info):
      logCall("call-start", info.app, at: info.startedAt)
    case .callEnded(let info, let endedAt):
      logCall("call-end", info.app, at: endedAt)
    case .stopPromptDue(let info, let endedAt):
      logCall("stop-prompt", info.app, at: endedAt)
    }
  }

  private func logCall(_ operation: String, _ app: AppIdentity, at: Date) {
    let who = DiagnosticSanitizer.token(app.key, fallback: "unknown")
    logger.notice("\(operation, privacy: .public) \(who, privacy: .public)")
    guard lock.withLock({ state.callBudget.take(at: at) }) else { return }
    ledger.append(
      event: "meetingDetection.call", source: "meeting-detection", ts: at,
      fields: DiagnosticEventFields(
        family: "meeting-detection", operation: operation, origin: who))
  }

  /// 用户对提醒的动作（start-记录、ignore、never、stop-end、stop-continue），只记 App key 与时间，
  /// 用来算误报率与调门槛。不设每日份额：由用户点击驱动，量很小。
  public func recordPromptAction(_ action: String, appKey: String, at: Date = Date()) {
    let who = DiagnosticSanitizer.token(appKey, fallback: "unknown")
    let operation = "prompt-\(action)"
    logger.notice("\(operation, privacy: .public) \(who, privacy: .public)")
    ledger.append(
      event: "meetingDetection.prompt", source: "meeting-detection", ts: at,
      fields: DiagnosticEventFields(
        family: "meeting-detection", operation: operation, origin: who))
  }
}
