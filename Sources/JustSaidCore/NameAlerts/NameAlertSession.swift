import Combine
import Foundation

/// 一次逻辑点名事件。同一事件的 partial/final 修订不会产生新事件,也不改变它的身份。
public struct NameAlertEvent: Identifiable, Equatable, Sendable {
  public let id: UInt64
  /// 本会话对象内的会议序号;每次进入录制加一。
  public let meeting: UInt64
  public let aliasID: Int
  /// 用户配置的别名原文,供界面显示;不写日志。
  public let aliasText: String
  public let kind: LiveDecodeObservation.Kind
  public let decodedRange: ClosedRange<TimeInterval>
  public let newCallCount: Int

  public init(
    id: UInt64,
    meeting: UInt64,
    aliasID: Int,
    aliasText: String,
    kind: LiveDecodeObservation.Kind,
    decodedRange: ClosedRange<TimeInterval>,
    newCallCount: Int
  ) {
    self.id = id
    self.meeting = meeting
    self.aliasID = aliasID
    self.aliasText = aliasText
    self.kind = kind
    self.decodedRange = decodedRange
    self.newCallCount = newCallCount
  }
}

public enum NameAlertReminderState: Equatable, Sendable {
  case notRecording
  /// 录制中但没有有效别名:不匹配。
  case needsAliases
  /// 录制中、别名有效、提醒已暂停:仍在本地匹配并记账去重,不产生事件。
  case paused
  case active
}

/// 只含计数与耗时,不含名字或转写。
public struct NameAlertDiagnostics: Equatable, Sendable {
  public var observationsQueued: UInt64 = 0
  public var observationsProcessed: UInt64 = 0
  public var observationsDroppedForBacklog: UInt64 = 0
  /// 过载未进入结果排队、但接收时已写入账本的观察数。
  public var observationsTrackedAfterBacklogDrop: UInt64 = 0
  public var staleResultsDiscarded: UInt64 = 0
  public var eventsCreated: UInt64 = 0
  /// 暂停期间(或暂停前已排队)检测到新点名但不提醒的次数。
  public var detectionsSuppressedWhilePaused: UInt64 = 0
  /// 最近至多 512 次检测的匹配 + 账本耗时,秒;在接收线程计量,不含结果排队与送回。
  public var recentProcessingDurations: [TimeInterval] = []
  /// 过载未入队的接收中,匹配 + 账本耗时,至多 512 次,秒。
  public var recentOverflowMatchDurations: [TimeInterval] = []
}

/// 会议级点名提醒状态。由应用级对象持有,生命周期高于主窗、会议库与浮窗;
/// 视图只读 `pendingEvent`/`reminderState` 并调用 `acknowledge(eventID:)`,
/// 显示模式、提醒方式、焦点与视图重建都不经过这里,因此不会确认、重置或重复发出事件。
///
/// 录制中且别名有效时处理 `.others` 观察,与提醒开关无关:在接收线程按到达顺序调用同一
/// `occurrences(in:)` 与账本 `ingest`。64 格只约束已算好的结果排队与投递,满员拒绝入队的观察
/// 也已写入账本。实际事件投递仍推迟,并用当时的提醒代数/检测代数门控。会议开始、结束或更改
/// 别名使账本代数失效(更改别名另设屏障);暂停/恢复提醒不动账本,只换提醒代数:暂停清除未确认
/// 事件,暂停前或暂停期间送达的观察即使恢复后才处理完也不提醒,恢复后新送达的观察照常提醒。
@MainActor
public final class NameAlertSession: ObservableObject {
  /// 已算好的检测结果排队上限。超过后新到的观察不进入投递排队并计数,但接收时已写入账本。
  /// 控制命令不受限。
  public static let observationBacklogLimit = 64

  @Published public private(set) var pendingEvent: NameAlertEvent?
  @Published public private(set) var reminderState: NameAlertReminderState = .notRecording

  /// 每个新逻辑事件恰好一次,供之后的可选提示音;呈现或模式变化不会发出。
  public var newEvents: AnyPublisher<NameAlertEvent, Never> {
    newEventSubject.eraseToAnyPublisher()
  }

  public var diagnostics: NameAlertDiagnostics { counters.snapshot() }

  private let newEventSubject = PassthroughSubject<NameAlertEvent, Never>()
  private let counters = NameAlertDetectionCounters()
  private let commands: AsyncStream<NameAlertDetectionCommand>.Continuation
  private var subscriptions: Set<AnyCancellable> = []
  private var recordingSubscriptions: Set<AnyCancellable> = []
  private weak var attachedInput: AnyObject?
  private var inputAudioEnd: (AudioSource) -> TimeInterval? = { _ in nil }

  private var isRecording = false
  private var remindersEnabled = false
  private var aliasInputs: [String] = []
  private var aliasSet = NameAlertAliasSet([])
  private var generation: UInt64 = 0
  private var reminderEpoch: UInt64 = 0
  private var meeting: UInt64 = 0
  private var nextEventID: UInt64 = 0
  private var tracker = NameAlertRevisionTracker(barrier: .infinity)

  public init(preferences: NameAlertPreferencesStore) {
    let stream = AsyncStream.makeStream(
      of: NameAlertDetectionCommand.self, bufferingPolicy: .unbounded)
    commands = stream.continuation
    let counters = counters
    let initial = preferences.preferences
    remindersEnabled = initial.remindersEnabled
    aliasInputs = initial.aliases
    aliasSet = NameAlertAliasSet(initial.aliases)
    let deliver: @MainActor @Sendable (NameAlertDetectionResult) -> Void = { [weak self] result in
      self?.deliver(result)
    }
    Task.detached(priority: .userInitiated) {
      await NameAlertDetectionWorker.run(stream.stream, counters: counters, deliver: deliver)
    }
    preferences.$preferences
      .sink { [weak self] in self?.apply($0) }
      .store(in: &subscriptions)
    updateState()
  }

  deinit {
    commands.finish()
  }

  /// 应用接线:从同一个 RecordingSession 读阶段、观察流与送入音频末端。
  public func attach(to recordingSession: RecordingSession) {
    attach(
      input: recordingSession,
      phase: recordingSession.$phase.eraseToAnyPublisher(),
      observations: recordingSession.liveDecodeObservations,
      inputAudioEnd: { [weak recordingSession] source in
        recordingSession?.liveDecodeInputAudioEnd(for: source)
      }
    )
  }

  /// 与 `attach(to:)` 相同的接线,输入可替换。`input` 是这组流的来源对象(弱引用):
  /// 再次接同一个对象不做任何事,保留订阅、账本与待确认事件;接另一个对象视为换了输入源,
  /// 先结束当前会议并使排队结果失效,再按新来源的阶段重新开始。
  /// `inputAudioEnd` 在更改别名时读取,作为屏障:起点早于它的解码窗口不再提醒。
  public func attach(
    input: AnyObject,
    phase: AnyPublisher<RecordingSessionPhase, Never>,
    observations: AnyPublisher<LiveDecodeObservation, Never>,
    inputAudioEnd: @escaping (AudioSource) -> TimeInterval?
  ) {
    guard attachedInput !== input else { return }
    attachedInput = input
    recordingSubscriptions = []
    recordingPhaseDidChange(.idle)
    self.inputAudioEnd = inputAudioEnd
    phase
      .sink { [weak self] in self?.recordingPhaseDidChange($0) }
      .store(in: &recordingSubscriptions)
    observations
      .sink { [weak self] in self?.receive($0) }
      .store(in: &recordingSubscriptions)
  }

  public func recordingPhaseDidChange(_ phase: RecordingSessionPhase) {
    let recording = phase == .recording
    guard recording != isRecording else { return }
    isRecording = recording
    pendingEvent = nil
    if recording {
      meeting += 1
      // 新会议的时钟从 0 重新开始,账本清空且没有屏障。
      invalidate(barrier: -.infinity)
    } else {
      invalidate(barrier: nil)
    }
    updateState()
  }

  public func receive(_ observation: LiveDecodeObservation) {
    guard isRecording, !aliasSet.isEmpty, observation.source == .others else { return }
    let started = ProcessInfo.processInfo.systemUptime
    let names = aliasSet.occurrences(in: observation.text)
    let fresh = tracker.ingest(
      kind: observation.kind, range: observation.decodedRange, text: observation.text,
      names: names)
    let duration = ProcessInfo.processInfo.systemUptime - started
    counters.recordProcessingDuration(duration)

    var payload: NameAlertDetectionResult?
    if fresh > 0, let latest = names.last, let match = Self.displayMatch(latest) {
      if remindersEnabled {
        let alias = aliasSet.aliases.first { $0.id == match.aliasID }
        payload = NameAlertDetectionResult(
          generation: generation,
          reminderEpoch: reminderEpoch,
          aliasID: match.aliasID,
          aliasText: alias?.text ?? "",
          kind: observation.kind,
          decodedRange: observation.decodedRange,
          newCallCount: fresh
        )
      } else {
        counters.recordSuppressedWhilePaused()
      }
    }

    guard counters.reserveObservation(limit: Self.observationBacklogLimit) else {
      counters.recordOverflowMatch(duration: duration)
      counters.recordTrackedAfterBacklogDrop()
      return
    }
    commands.yield(.result(generation: generation, payload: payload))
  }

  /// 只确认界面上显示的那个事件;若期间已有更新的事件,它保持未确认。
  public func acknowledge(eventID: NameAlertEvent.ID) {
    guard pendingEvent?.id == eventID else { return }
    pendingEvent = nil
  }

  /// 等待此前排队的检测全部处理并送回主线程。供验证与需要同步点的调用方使用。
  public func waitForPendingDetection() async {
    await withCheckedContinuation { continuation in
      commands.yield(.flush(continuation))
    }
  }

  private func apply(_ preferences: NameAlertPreferences) {
    let remindersChanged = preferences.remindersEnabled != remindersEnabled
    let aliasesChanged = preferences.aliases != aliasInputs
    guard remindersChanged || aliasesChanged else { return }
    if remindersChanged {
      remindersEnabled = preferences.remindersEnabled
      reminderEpoch += 1
      if !remindersEnabled {
        pendingEvent = nil
      }
    }
    if aliasesChanged {
      aliasInputs = preferences.aliases
      aliasSet = NameAlertAliasSet(preferences.aliases)
      if isRecording {
        // 新别名集合没有旧账本:屏障取当前已送入音频的末端,只接之后的新输入。
        invalidate(barrier: inputAudioEnd(.others) ?? -.infinity)
      }
    }
    updateState()
  }

  private func invalidate(barrier: TimeInterval?) {
    generation += 1
    tracker = NameAlertRevisionTracker(barrier: barrier ?? .infinity)
    commands.yield(.reset(generation: generation))
  }

  private func updateState() {
    reminderState =
      !isRecording
      ? .notRecording : aliasSet.isEmpty ? .needsAliases : remindersEnabled ? .active : .paused
  }

  private func deliver(_ result: NameAlertDetectionResult) {
    guard result.generation == generation else {
      counters.recordStaleResult()
      return
    }
    guard remindersEnabled, result.reminderEpoch == reminderEpoch else {
      counters.recordSuppressedWhilePaused()
      return
    }
    nextEventID += 1
    let event = NameAlertEvent(
      id: nextEventID,
      meeting: meeting,
      aliasID: result.aliasID,
      aliasText: result.aliasText,
      kind: result.kind,
      decodedRange: result.decodedRange,
      newCallCount: result.newCallCount
    )
    counters.recordEvent()
    pendingEvent = event
    newEventSubject.send(event)
  }

  private static func displayMatch(_ occurrence: NameAlertOccurrence) -> NameAlertAliasMatch? {
    occurrence.matches.max {
      ($0.bestScore, -$0.aliasID) < ($1.bestScore, -$1.aliasID)
    }
  }
}

enum NameAlertDetectionCommand: Sendable {
  case reset(generation: UInt64)
  /// 已在接收线程匹配并写入账本的投递载荷;`nil` 表示无需提醒。
  case result(generation: UInt64, payload: NameAlertDetectionResult?)
  case flush(CheckedContinuation<Void, Never>)
}

struct NameAlertDetectionResult: Sendable {
  let generation: UInt64
  let reminderEpoch: UInt64
  let aliasID: Int
  let aliasText: String
  let kind: LiveDecodeObservation.Kind
  let decodedRange: ClosedRange<TimeInterval>
  let newCallCount: Int
}

/// 串行投递:消费任务按命令顺序投递已算好的结果,不再匹配或改账本。
enum NameAlertDetectionWorker {
  static func run(
    _ commands: AsyncStream<NameAlertDetectionCommand>,
    counters: NameAlertDetectionCounters,
    deliver: @MainActor @Sendable (NameAlertDetectionResult) -> Void
  ) async {
    var generation: UInt64 = 0
    for await command in commands {
      switch command {
      case .reset(let newGeneration):
        generation = newGeneration
      case .flush(let continuation):
        continuation.resume()
      case .result(let observationGeneration, let payload):
        guard observationGeneration == generation else {
          counters.recordStaleResult()
          counters.completeObservation()
          continue
        }
        if let payload {
          await deliver(payload)
        }
        counters.completeObservation()
      }
    }
  }
}

/// Safety invariant: every stored counter is lock-protected by `lock`; no other mutable state.
final class NameAlertDetectionCounters: @unchecked Sendable {
  private let lock = NSLock()
  private var value = NameAlertDiagnostics()
  private var waiting = 0

  func reserveObservation(limit: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard waiting < limit else {
      value.observationsDroppedForBacklog += 1
      return false
    }
    waiting += 1
    value.observationsQueued += 1
    return true
  }

  func recordProcessingDuration(_ duration: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    Self.appendDuration(&value.recentProcessingDurations, duration)
  }

  func recordOverflowMatch(duration: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    Self.appendDuration(&value.recentOverflowMatchDurations, duration)
  }

  func recordTrackedAfterBacklogDrop() {
    lock.lock()
    value.observationsTrackedAfterBacklogDrop += 1
    lock.unlock()
  }

  func completeObservation() {
    lock.lock()
    defer { lock.unlock() }
    waiting = max(0, waiting - 1)
    value.observationsProcessed += 1
  }

  private static func appendDuration(_ values: inout [TimeInterval], _ duration: TimeInterval) {
    values.append(duration)
    if values.count > 512 {
      values.removeFirst(values.count - 512)
    }
  }

  func recordStaleResult() {
    lock.lock()
    value.staleResultsDiscarded += 1
    lock.unlock()
  }

  func recordSuppressedWhilePaused() {
    lock.lock()
    value.detectionsSuppressedWhilePaused += 1
    lock.unlock()
  }

  func recordEvent() {
    lock.lock()
    value.eventsCreated += 1
    lock.unlock()
  }

  func snapshot() -> NameAlertDiagnostics {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
