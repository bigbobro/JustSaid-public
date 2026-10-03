import Combine
import Foundation
import JustSaidCore

/// 会议提醒胶囊此刻要显示的内容。
public enum MeetingPrompt: Equatable, Sendable {
  /// 检测到 App 进入通话，问要不要开始记录（没有在记录时）。
  case start(MeetingCallInfo)
  /// 正在记录、被跟踪的 App 通话结束，问要不要结束记录。
  case stop(MeetingCallInfo)
  /// 按 App 录制失败、已改录全部系统声音（信息级，自动收起）。
  case scopeFallback(MeetingCallInfo)
  /// 按 App 录制时 tap 里一直是零，建议改录全部系统声音（要用户处理，不自动改）。
  case scopeSilent(MeetingCallInfo)
  /// 改录全局也失败，系统声音可能没在录（警示级，比全零建议更要紧）。
  case scopeFailed(MeetingCallInfo)

  public var info: MeetingCallInfo {
    switch self {
    case .start(let info), .stop(let info), .scopeFallback(let info), .scopeSilent(let info),
      .scopeFailed(let info):
      return info
    }
  }
}

/// 会议检测提醒的应用级控制器：把 `MicrophoneUsageMonitor` 的通话事件和录制状态变成唯一的提醒状态，
/// 并接住提醒上的动作。监视器的创建与启停受设置开关控制；提醒的显示由 `MeetingPresenceController` 订阅 `prompt`。
///
/// 规则：
/// - 开始提醒只在空闲（idle/completed/failed）时出现；`.starting`、`.stopping` 期间隐藏，
///   避免点到 `RecordingSession.start` 会静默吞掉的相位（issue #28 的形态）。
/// - 结束提醒只在记录中、被跟踪的 App 通话结束时出现，点「继续」或该 App 再次通话才收起，不会自己消失
///   （owner 常忘记结束，不能让它消失）。
/// - 记录结束后，仍在通话的那个 App 不会马上再弹开始提醒（自动忽略这一次通话）。
/// - 系统声录制范围的两条通知（回退、tap 全零）也走这块胶囊，因为由提醒开始的记录主窗在后台。
///   胶囊一次只显示一种，记录中的优先级：结束提醒 > 录制失败提示 > 全零建议 > 回退通知。
///   结束提醒最高：通话已结束就不必再追问「有没有录到对方」；点「继续记录」后全零建议会重新出现。
@MainActor
public final class MeetingDetectionController: ObservableObject {
  public struct Actions {
    /// 开始记录。返回后才解除「正在从提醒开始」的闩锁。
    public var start: (MeetingCallInfo) async -> Void
    /// 结束记录：走既有的结束路径（含聊天范围确认、纪要、跳资料库），不直接 `stop()`。
    public var end: () -> Void

    public init(start: @escaping (MeetingCallInfo) async -> Void, end: @escaping () -> Void) {
      self.start = start
      self.end = end
    }
  }

  @Published public private(set) var prompt: MeetingPrompt?

  public let preferences: MeetingDetectionPreferencesStore
  public let monitor: MicrophoneUsageMonitor
  private weak var recordingSession: RecordingSession?
  private let actions: Actions
  private var cancellables: Set<AnyCancellable> = []
  /// `@Published` 的订阅在属性赋值之前收到新值，读 `preferences.excludedKeys` 会拿到旧的，所以自己存一份。
  private var excludedKeys: Set<String>
  private var isEnabled: Bool
  private var phase: RecordingSessionPhase
  /// 已通知监视器「记录中」。`recording → stopping → completed` 要在终态才通知停止，不能只看上一相位。
  private var monitorKnowsRecording = false
  private var stopInfo: MeetingCallInfo?
  /// 回退通知自动收起的时间。信息级、不需要操作，主窗横幅仍留着；10 秒够扫一眼读完一句话，
  /// 又不会像结束提醒那样一直挂在屏幕上。验证可注入更短的值。
  private let scopeFallbackDuration: TimeInterval
  private var scopeNotice: SystemAudioScopeNotice?
  /// 用户已对当前这条通知点过「不用」/「知道了」，或回退通知已自动收起。通知变化时重置。
  private var scopeNoticeHandled = false
  private var scopeFallbackTimer: Task<Void, Never>?
  /// 点了「开始记录」到 `actions.start` 返回之间为真：这段时间开始提醒保持隐藏。
  private var isStartingFromPrompt = false

  public init(
    monitor: MicrophoneUsageMonitor,
    recordingSession: RecordingSession,
    preferences: MeetingDetectionPreferencesStore,
    actions: Actions,
    scopeFallbackDuration: TimeInterval = 10
  ) {
    self.scopeFallbackDuration = scopeFallbackDuration
    self.monitor = monitor
    self.recordingSession = recordingSession
    self.preferences = preferences
    self.actions = actions
    phase = recordingSession.phase
    excludedKeys = preferences.excludedKeys
    isEnabled = preferences.isEnabled

    monitor.setUserExcludedAppKeys(preferences.excludedKeys)
    if phase == .recording {
      monitorKnowsRecording = true
      monitor.recordingDidStart(tracking: recordingSession.sourceApp?.app.key)
    }

    recordingSession.$phase
      .removeDuplicates()
      .sink { [weak self] in self?.phaseChanged($0) }
      .store(in: &cancellables)
    recordingSession.$systemAudioScopeNotice
      .removeDuplicates()
      .sink { [weak self] in self?.scopeNoticeChanged($0) }
      .store(in: &cancellables)
    preferences.$isEnabled
      .removeDuplicates()
      .sink { [weak self] in self?.applyEnabled($0) }
      .store(in: &cancellables)
    preferences.$excludedApps
      .dropFirst()
      .sink { [weak self] apps in
        self?.excludedKeys = Set(apps.keys)
        self?.monitor.setUserExcludedAppKeys(Set(apps.keys))
        self?.refresh()
      }
      .store(in: &cancellables)
  }

  /// 停掉监视器并收起提醒（验证换宿主、App 退出）。
  public func invalidate() {
    cancellables.removeAll()
    monitor.stop()
    scopeFallbackTimer?.cancel()
    prompt = nil
  }

  private func scopeNoticeChanged(_ notice: SystemAudioScopeNotice?) {
    scopeNotice = notice
    scopeNoticeHandled = false
    scopeFallbackTimer?.cancel()
    scopeFallbackTimer = nil
    if notice == .fellBackToGlobal {
      let seconds = scopeFallbackDuration
      scopeFallbackTimer = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard !Task.isCancelled, let self, self.scopeNotice == .fellBackToGlobal else { return }
        self.scopeNoticeHandled = true
        self.refresh()
      }
    }
    refresh()
  }

  // MARK: - 监视器事件

  private func applyEnabled(_ enabled: Bool) {
    isEnabled = enabled
    if enabled {
      monitor.start { [weak self] events in
        Task { @MainActor in self?.handle(events) }
      }
    } else {
      monitor.stop()
      stopInfo = nil
    }
    refresh()
  }

  private func handle(_ events: [MeetingDetectionEvent]) {
    // 合约：`stop()` 之后已交到回调阶段的一批事件可能仍会送达一次，这里按开关丢弃。
    guard isEnabled else { return }
    for event in events {
      switch event {
      case .stopPromptDue(let info, _) where phase == .recording:
        stopInfo = info
      case .callStarted(let info) where info.app.key == stopInfo?.app.key:
        // 被跟踪的 App 又进入通话：之前的「通话已结束」作废。
        stopInfo = nil
      default:
        break
      }
    }
    refresh()
  }

  private func phaseChanged(_ newPhase: RecordingSessionPhase) {
    phase = newPhase
    switch newPhase {
    case .recording:
      if !monitorKnowsRecording {
        monitorKnowsRecording = true
        monitor.recordingDidStart(tracking: recordingSession?.sourceApp?.app.key)
      }
    case .idle, .completed, .failed:
      if monitorKnowsRecording {
        monitorKnowsRecording = false
        // 记录结束时仍在通话的 App，这一次通话不再弹开始提醒。
        let tracked = monitor.trackedAppKey
        monitor.recordingDidStop()
        if let tracked { monitor.ignore(appKey: tracked) }
        stopInfo = nil
      }
    case .starting, .stopping:
      break
    }
    refresh()
  }

  private func refresh() {
    let next = computePrompt()
    if prompt != next { prompt = next }
  }

  private func computePrompt() -> MeetingPrompt? {
    guard isEnabled else { return nil }
    switch phase {
    case .recording:
      if let stopInfo { return .stop(stopInfo) }
      guard !scopeNoticeHandled, let info = recordingSession?.sourceApp else { return nil }
      switch scopeNotice {
      case .silentTap: return .scopeSilent(info)
      case .rebuildFailed: return .scopeFailed(info)
      case .fellBackToGlobal: return .scopeFallback(info)
      case nil: return nil
      }
    case .idle, .completed, .failed:
      guard !isStartingFromPrompt else { return nil }
      return monitor.promptCandidates.first { !excludedKeys.contains($0.app.key) }
        .map(MeetingPrompt.start)
    case .starting, .stopping:
      return nil
    }
  }

  // MARK: - 提醒上的动作

  public func startRecording() {
    guard case .start(let info) = prompt else { return }
    monitor.recordPromptAction("start", appKey: info.app.key)
    isStartingFromPrompt = true
    refresh()
    Task { @MainActor in
      await actions.start(info)
      isStartingFromPrompt = false
      // 用户已经对这次通话点过「开始记录」：没开成（失败，或模型没就绪退回了主窗）时不再为它重复弹。
      if phase != .recording && phase != .starting { monitor.ignore(appKey: info.app.key) }
      refresh()
    }
  }

  public func ignore() {
    guard case .start(let info) = prompt else { return }
    monitor.recordPromptAction("ignore", appKey: info.app.key)
    monitor.ignore(appKey: info.app.key)
    refresh()
  }

  /// 「不再提醒此 App」。找不到宿主的 WebKit helper 按 pid 各成一家（key 含 `#`），
  /// 存下来也匹配不到下一个进程，所以提醒上不给这个按钮（见 `canExclude`）。
  public func neverRemind() {
    guard case .start(let info) = prompt, Self.canExclude(info.app) else { return }
    monitor.recordPromptAction("never", appKey: info.app.key)
    preferences.exclude(key: info.app.key, name: info.app.displayName)
  }

  public func endRecording() {
    guard case .stop(let info) = prompt else { return }
    monitor.recordPromptAction("stop-end", appKey: info.app.key)
    stopInfo = nil
    refresh()
    actions.end()
  }

  public func continueRecording() {
    guard case .stop(let info) = prompt else { return }
    monitor.recordPromptAction("stop-continue", appKey: info.app.key)
    stopInfo = nil
    refresh()
  }

  /// 全零建议上的主按钮：改录全部系统声音。只由用户点击触发，不自动改。
  public func switchScopeToGlobal() {
    guard case .scopeSilent(let info) = prompt else { return }
    monitor.recordPromptAction("scope-switch", appKey: info.app.key)
    scopeNoticeHandled = true
    refresh()
    Task { @MainActor [weak self] in await self?.recordingSession?.switchSystemAudioToGlobal() }
  }

  /// 「不用」（全零建议）或「知道了」（回退通知）：只收起胶囊，不改范围；主窗横幅仍在。
  public func dismissScopeNotice() {
    let action: String
    switch prompt {
    case .scopeSilent: action = "scope-dismiss"
    case .scopeFallback: action = "scope-ack"
    case .scopeFailed: action = "scope-failed-ack"
    default: return
    }
    if let info = prompt?.info { monitor.recordPromptAction(action, appKey: info.app.key) }
    scopeNoticeHandled = true
    refresh()
  }

  public static func canExclude(_ app: AppIdentity) -> Bool { !app.key.contains("#") }
}
