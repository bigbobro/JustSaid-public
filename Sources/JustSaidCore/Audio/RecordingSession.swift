import AVFAudio
import Combine
import Foundation
import OSLog

public enum RecordingSessionPhase: String, Equatable, Sendable {
  case idle
  case starting
  case recording
  case stopping
  case completed
  case failed

  public var isBusy: Bool {
    self == .starting || self == .recording || self == .stopping
  }
}

public struct RecordingSessionIssue: Identifiable {
  public let id = UUID()
  public let title: String
  public let message: String
  public let settingsDestination: RecordingSettingsDestination?

  public init(
    title: String,
    message: String,
    settingsDestination: RecordingSettingsDestination?
  ) {
    self.title = title
    self.message = message
    self.settingsDestination = settingsDestination
  }
}

/// 采集路标识(会中健康监测的运行时键,不入 meeting.json;
/// 持久化的路级失败仍走 `CaptureLegFailure.Leg`)。
public enum CaptureLeg: String, CaseIterable, Sendable, Hashable {
  case microphone
  case systemAudio

  /// 与 `CaptureLegFailure` 同一套用户话术(横幅口径一致红线)。
  public var displayName: String {
    switch self {
    case .microphone: return "你的麦克风声音"
    case .systemAudio: return "系统播放声音"
    }
  }

  /// 「保住了什么」的另一路话术,同 `CaptureLegFailure.preservedLegDescription`。
  public var preservedDescription: String {
    switch self {
    case .microphone: return "系统播放声音的完整录音"
    case .systemAudio: return "你的麦克风完整录音"
    }
  }
}

/// 单路采集健康状态机(08-05 自愈单 design 定案):
/// healthy → stalled(重试中,attempts 递增) → recovered(缺口已补静音) / givenUp(停止重试)。
public enum CaptureLegHealthCause: Equatable, Sendable {
  case noFrameProgress
  case runtimeError
}

public enum CaptureLegHealth: Equatable, Sendable {
  case healthy
  case stalled(since: Date, attempts: Int, cause: CaptureLegHealthCause = .noFrameProgress)
  case recovered(gapSeconds: Double, cause: CaptureLegHealthCause = .noFrameProgress)
  case givenUp(lastGoodSecondsIntoMeeting: Double, cause: CaptureLegHealthCause = .noFrameProgress)
}

/// 看门狗参数(design 定案:5s 采样、≥10s 无增长判停、重试 立即/15s/30s 共 3 次)。
/// 验证注入缩短时标以避免固定墙钟长等;产品代码一律用默认值。
public struct CaptureHealthPolicy: Sendable {
  /// 麦克风启动必须有界；蓝牙 HFP 协商卡住时不能无限阻塞会话启动。
  /// 阈值取 20s:DJI Wireless Mic Rx(USB)冷启动 `mic.startRunning` 实测
  /// 12.58/12.69/13.33s 完成(start-failures-20260821),10s 会把迟到的成功掐成失败。
  public var microphoneStartTimeout: TimeInterval
  public var sampleInterval: TimeInterval
  public var stallThreshold: TimeInterval
  /// 判定「这一路跟得上会议时钟」的最低出帧速率(帧/秒)。
  ///
  /// 只问「有没有多出帧」分不出健康与涓流:2026-09-04 事故里 systemAudio 全程平均
  /// 约 103 帧/秒(48 kHz 额定的 0.2%),每个采样周期都有增量,于是整场停在
  /// `.healthy`、一条 `audioLeg.*` 都没有。取值刻意远低于任何真实采样率
  /// (16 kHz 麦克风也有 16 倍余量),只用来把「几乎不出帧」和「正常出帧」分开。
  public var minimumProgressFramesPerSecond: Double
  /// 第 N 次重试距「判停/上一次尝试」的等待;个数即重试上限。
  public var retryDelays: [TimeInterval]
  /// 单次重建的上界。
  ///
  /// 重建把活派到采集队列再等 continuation;队列被楔住时它永远不返回,而重建是在
  /// 唯一那条采样循环里被 await 的——2026-09-04 事故里三次重建各等了 67/78/78 分钟,
  /// 设计的 0/15/30 秒节奏因此失效,同一场的 systemAudio 也整段没被采样过。
  /// 取 20s 与 `microphoneStartTimeout` 同源:重建走的就是一次完整的停+起,
  /// DJI 无线麦冷启动实测 12.58/12.69/13.33s,再小会把慢成功掐成超时。
  public var rebuildTimeout: TimeInterval
  /// recovered 横幅短暂显示后转回 healthy(消失)的时长。
  public var recoveredNoticeDuration: TimeInterval
  /// 启动看门狗阈值(08-20 失败可自证单,G4):`start()` 超过该时长仍未到终态,
  /// 先行 flush 启动轨迹(stuck)。裸 await 卡死不抛异常、HangSentinel 也不触发
  /// (actor suspension 不是主线程卡死),没有它这类失败在磁盘上零痕迹;
  /// 同一个看门狗也让「慢成功」留下对照样本。
  public var startupStuckThreshold: TimeInterval

  public init(
    microphoneStartTimeout: TimeInterval = 20,
    sampleInterval: TimeInterval = 5,
    stallThreshold: TimeInterval = 10,
    minimumProgressFramesPerSecond: Double = 1_000,
    retryDelays: [TimeInterval] = [0, 15, 30],
    rebuildTimeout: TimeInterval = 20,
    recoveredNoticeDuration: TimeInterval = 15,
    startupStuckThreshold: TimeInterval = 30
  ) {
    self.microphoneStartTimeout = microphoneStartTimeout
    self.sampleInterval = sampleInterval
    self.stallThreshold = stallThreshold
    self.minimumProgressFramesPerSecond = minimumProgressFramesPerSecond
    self.retryDelays = retryDelays
    self.rebuildTimeout = rebuildTimeout
    self.recoveredNoticeDuration = recoveredNoticeDuration
    self.startupStuckThreshold = startupStuckThreshold
  }

  public var maximumAttempts: Int { retryDelays.count }
}

private struct MicrophoneStartTimedOut: Error {}

private enum MicrophoneStartOutcome: @unchecked Sendable {
  case completed(Result<Void, Error>)
  case timedOut
  case cancelled
}

/// 单次采集重建的结局。`timedOut` 不代表重建失败,只代表**采样循环不再等它**:
/// 在飞的重建继续在采集队列上跑,循环回去按节奏采样另一路、排下一次尝试。
///
/// Safety invariant: single-owner 的一次性传值——由 `rebuildCapture` 里那个重建 Task
/// 构造一次、经 `AsyncStream` 交给唯一在等的采样循环消费一次,之后不再被任何人读写,
/// 内部也没有可变状态。`@unchecked` 只是因为 `Result<Void, Error>` 里的 `Error`
/// 不是 `Sendable`(与同文件 `MicrophoneStartOutcome` 同因),不是在放宽真实共享。
private enum CaptureRebuildOutcome: @unchecked Sendable {
  case completed(Result<Void, Error>)
  case timedOut
  case cancelled
}

@MainActor
public final class RecordingSession: ObservableObject {
  @Published public private(set) var phase: RecordingSessionPhase = .idle {
    didSet { reconcileMicrophoneInput() }
  }
  @Published public private(set) var microphoneInputPreference: MicrophoneInputPreference =
    .automatic
  @Published public private(set) var microphoneInputDevices: [MicrophoneInputDevice] = []
  @Published public private(set) var microphoneInputDirectoryIsKnown = false
  @Published public private(set) var microphoneInputStatus: MicrophoneInputStatus = .unready(
    reason: "正在读取麦克风设备"
  )
  @Published public private(set) var currentMeetingDirectory: URL?
  @Published public private(set) var currentTitle: String?
  @Published public private(set) var issue: RecordingSessionIssue?
  @Published public private(set) var liveSegments: [TranscriptSegment] = []
  /// 麦克风采集电平(0~1,-50dBFS~0dBFS 线性映射),≤10Hz 节流发布;仅录制中有值。
  @Published public private(set) var microphoneLevel: Float = 0
  /// 只暂停麦克风内容；系统声、录制时钟与母带写入均继续。
  @Published public private(set) var isMicrophonePaused = false
  /// 本场录音的权威起点(= meeting.json 的 startedAt)。
  ///
  /// 界面层原先各自记一个"点开始的那一刻",于是**从菜单栏开录时根本没人记**——
  /// 笔记时间戳全成 00:00,「标记」取到的又是 [0,0] 空窗口,一按必报「提炼失败」
  /// (2026-07-29 实测,连挂 7 次)。起点只能由这里发布,两条开录路径才不会分叉。
  @Published public private(set) var startedAt: Date?
  /// 单路失败的非模态横幅文案(08-05 事故:单路失败不再拖垮整场,不弹模态对话框)。
  /// 非 nil 即"部分完成":整场仍是 completed,会后流水线照常;文案含缺失起点与保住了什么。
  @Published public private(set) var partialCaptureNotice: String?
  /// 会中路级健康(08-05 自愈单):统计推进看门狗驱动,UI 据此出非模态横幅。
  /// 运行时状态,不入 meeting.json;与既有「30 秒纯零静音」看门狗是两套信号
  /// (那边帧在流但纯零,这边帧停摆),不合并。
  @Published public private(set) var legHealth: [CaptureLeg: CaptureLegHealth] = [:]

  private let store: MeetingStore
  private let systemAudioCapture: any SystemAudioCapturing
  private let microphoneCapture: any MicrophoneAudioCapturing
  private let inputDeviceMonitor: AudioInputDeviceMonitor
  private let microphoneInputSettings: MicrophoneInputSettings
  private let verificationMicrophoneWaiter: (@Sendable () async -> Void)?
  private var inputDirectorySubscription: AnyCancellable?
  private var desiredMicrophoneTarget: MicrophoneInputTarget?
  private var lastResolvedMicrophoneDevice: MicrophoneInputDevice?
  private var microphoneRouteRevision: UInt64 = 0
  private var consumedMicrophoneRouteRevision: UInt64?
  private var confirmedMicrophoneBinding: MicrophoneInputBinding?
  private var microphoneRouteFailure: String?
  private var microphoneDirectoryFailure: String?
  private var microphoneOperationOrdinal: UInt64 = 0
  private var microphoneOperation: MicrophoneOperation?

  private struct MicrophoneOperation: Equatable {
    let epoch: UInt64
    let ordinal: UInt64
    let target: MicrophoneInputTarget
  }
  private let transcriberFactory: @Sendable (String) throws -> any TranscriberEngine
  private let healthPolicy: CaptureHealthPolicy
  /// 启动失败证据的落点(诊断包整目录收集该目录,证据自动进包)。
  /// 验证一律注入临时目录,绝不写用户真目录。
  private let diagnosticsRoot: URL
  /// 完备度落盘执行体(默认真 scanner;验证注入慢实现,把 discard 竞态时序钉成确定性)。
  private let completenessScan: @Sendable (MeetingPaths) -> Void
  private let logger = Logger(
    subsystem: "com.justsaid.app",
    category: "RecordingSession"
  )

  private var currentRecord: MeetingRecord?
  private var transcriberEngine: (any TranscriberEngine)?
  private var transcriberResultsTask: Task<Error?, Never>?
  private var liveTranscriptWriter: LiveTranscriptWriter?
  private var transcriberASRAnchorGapFrames: [AudioSource: UInt64] = [:]
  private var transcriberLiveEmissionStats: [AudioSource: LiveEmissionStats] = [:]
  private var healthMonitorTask: Task<Void, Never>?
  private var legWatchStates: [CaptureLeg: LegWatchState] = [:]
  /// 在飞的物理重建,每路至多一个。`rebuildTimeout` 只解除**采样循环**的等待,
  /// 重建本身的所有权仍留在会话:同一路不再派第二个,`stop()` 也必须等它收敛后
  /// 才去拆采集。系统声的 `rebuild()` 是非隔离 async、直接读写 tap/聚合设备/IO 句柄
  /// (没有麦克风那条串行 captureQueue),两个重建重叠或重建与 teardown 重叠会互相
  /// 销毁对方刚建好的资源(review 5120025793 §1)。
  private var legRebuildTasks: [CaptureLeg: Task<Void, Never>] = [:]
  private var sessionEpochHostTime: UInt64?
  private var microphonePauseIntervals: [MicrophonePauseInterval] = []
  /// 自动重建额度耗尽后确认过的中断。每路同一时刻至多一个未闭合区间；
  /// 只在 stop 的 meeting.json 原子提交中落盘，不在会中增加写盘系统。
  private var captureInterruptions: [CaptureInterruption] = []
  /// stop 尾部派发的完备度落盘任务(utility 级 detached,stop 不等它,异步性保留)。
  /// 废弃路径删目录前必须收敛它:重载下该任务可被推迟进删除窗口,atomic 写
  /// completeness.json 与 removeItem 互撞 → 废弃失败(08-20 高负载 3/30 实证)。
  private var pendingCompletenessScan: Task<Void, Never>?

  /// 看门狗单路记账(仅监测任务读写,MainActor 串行)。
  private struct LegWatchState {
    /// 上一次**采样**读到的帧数与时刻——速率窗口的起点,每轮都前移。
    var lastFrames: UInt64
    var lastSampledAt: Date
    /// 上一次**合格推进**的时刻——停摆阈值的起点,只在达标时才前移。
    var lastProgressAt: Date
    var hasObservedFrames: Bool
    var stalledSince: Date?
    var cause: CaptureLegHealthCause = .noFrameProgress
    var runtimeErrorAt: Date?
    var consumedRuntimeGeneration: UInt?
    var attempts = 0
    var nextRetryAt: Date?
    var recoveredAt: Date?
    /// 重试额度一旦耗尽，本场不再补充；即使迟到帧回来也不重新发物理 rebuild。
    var retryBudgetExhausted = false
    /// 当前是否处于一个尚未恢复的 given-up 中断；迟到帧可将它关闭。
    var isGivenUp = false
  }

  public init(
    store: MeetingStore = MeetingStore(),
    systemAudioCapture: any SystemAudioCapturing = SystemAudioCapture(),
    microphoneCapture: any MicrophoneAudioCapturing = MicrophoneCapture(),
    inputDeviceMonitor: AudioInputDeviceMonitor? = nil,
    microphoneInputSettings: MicrophoneInputSettings? = nil,
    verificationMicrophoneWaiter: (@Sendable () async -> Void)? = nil,
    transcriberFactory: @escaping @Sendable (String) throws -> any TranscriberEngine = {
      try TranscriberEngineFactory().make(providerID: $0)
    },
    healthPolicy: CaptureHealthPolicy = CaptureHealthPolicy(),
    completenessScan: @escaping @Sendable (MeetingPaths) -> Void = {
      CompletenessScanner().scan(paths: $0)
    },
    diagnosticsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("JustSaid", isDirectory: true)
      .appendingPathComponent("diagnostics", isDirectory: true)
  ) {
    self.store = store
    self.systemAudioCapture = systemAudioCapture
    self.microphoneCapture = microphoneCapture
    self.inputDeviceMonitor = inputDeviceMonitor ?? AudioInputDeviceMonitor()
    self.microphoneInputSettings = microphoneInputSettings ?? MicrophoneInputSettings()
    self.verificationMicrophoneWaiter = verificationMicrophoneWaiter
    self.transcriberFactory = transcriberFactory
    self.healthPolicy = healthPolicy
    self.completenessScan = completenessScan
    self.diagnosticsRoot = diagnosticsRoot
    microphoneInputPreference = self.microphoneInputSettings.load()
    inputDirectorySubscription = self.inputDeviceMonitor.$snapshot.sink { [weak self] snapshot in
      self?.receiveMicrophoneDirectory(snapshot)
    }
    self.inputDeviceMonitor.start()
  }

  /// Only an explicit user action changes persisted intent. Temporary routing never calls save.
  @discardableResult
  public func selectMicrophoneInput(_ preference: MicrophoneInputPreference) -> Bool {
    guard phase != .stopping, preference != microphoneInputPreference else { return false }
    if case .device(let uid, _) = preference, uid.rawValue.isEmpty { return false }
    microphoneInputPreference = preference
    microphoneInputSettings.save(preference)
    receiveMicrophoneDirectory(inputDeviceMonitor.snapshot)
    return true
  }

  private func receiveMicrophoneDirectory(_ snapshot: MicrophoneInputDirectorySnapshot) {
    microphoneInputDirectoryIsKnown = snapshot.queryFailure == nil
    microphoneInputDevices = snapshot.devices
    if let failure = snapshot.queryFailure {
      // Query jitter is unknown, not a positively observed availability edge.
      desiredMicrophoneTarget = nil
      microphoneDirectoryFailure = failure
      reconcileMicrophoneInput()
      return
    }
    let device: MicrophoneInputDevice?
    var fallback: String?
    switch microphoneInputPreference {
    case .automatic:
      device = snapshot.devices.first { $0.uid == snapshot.defaultInputUID }
    case .device(let uid, let name):
      if let preferred = snapshot.devices.first(where: { $0.uid == uid }) {
        device = preferred
      } else {
        device = snapshot.devices.first { $0.uid == snapshot.defaultInputUID }
        fallback = "首选\(name ?? "麦克风")未连接，已临时回落至\(device?.name ?? "系统输入")"
      }
    }
    guard let device else {
      desiredMicrophoneTarget = nil
      lastResolvedMicrophoneDevice = nil
      microphoneDirectoryFailure = "没有可用的麦克风输入；已保留你的选择"
      reconcileMicrophoneInput()
      return
    }
    guard device.captureID != nil else {
      // An unresolved join is not an attempted endpoint or proof of a disconnect.
      desiredMicrophoneTarget = nil
      microphoneDirectoryFailure = "无法核对所选麦克风与采集设备的对应关系"
      reconcileMicrophoneInput()
      return
    }
    if lastResolvedMicrophoneDevice?.isSameEndpoint(as: device) != true {
      microphoneRouteRevision &+= 1
      microphoneRouteFailure = nil
    }
    lastResolvedMicrophoneDevice = device
    desiredMicrophoneTarget = MicrophoneInputTarget(
      device: device, revision: microphoneRouteRevision, fallbackReason: fallback
    )
    microphoneDirectoryFailure = nil
    reconcileMicrophoneInput()
  }

  /// One latest target and one spent opportunity. Runtime accounting remains sampler-owned.
  private func reconcileMicrophoneInput() {
    guard let target = desiredMicrophoneTarget else {
      microphoneInputStatus = .unready(reason: microphoneDirectoryFailure ?? "麦克风输入待确认")
      return
    }
    guard phase == .starting || phase == .recording || phase == .stopping else {
      microphoneInputStatus = .idle(target: target)
      return
    }
    if microphoneOperation != nil || phase == .starting {
      microphoneInputStatus = .pending(target: target)
      return
    }
    if let binding = confirmedMicrophoneBinding,
      binding.device.isSameEndpoint(as: target.device)
    {
      consumedMicrophoneRouteRevision = target.revision
      microphoneInputStatus = .active(binding: binding, fallbackReason: target.fallbackReason)
      return
    }
    guard phase == .recording else { return }
    guard consumedMicrophoneRouteRevision != target.revision else {
      microphoneInputStatus = .unready(reason: microphoneRouteFailure ?? "麦克风实际输入尚未确认")
      return
    }
    guard legRebuildTasks[.microphone] == nil, let epoch = sessionEpochHostTime else { return }
    let operation = reserveMicrophoneOperation(target: target, epoch: epoch)
    let capture = microphoneCapture
    legRebuildTasks[.microphone] = Task { @MainActor [weak self] in
      let result: Result<MicrophoneInputBinding, Error>
      do { result = .success(try await capture.rebuild(target: target)) } catch {
        result = .failure(error)
      }
      self?.finishMicrophoneOperation(operation, result: result)
    }
  }

  private func reserveMicrophoneOperation(
    target: MicrophoneInputTarget, epoch: UInt64
  ) -> MicrophoneOperation {
    precondition(microphoneOperation == nil && legRebuildTasks[.microphone] == nil)
    microphoneOperationOrdinal &+= 1
    let operation = MicrophoneOperation(
      epoch: epoch, ordinal: microphoneOperationOrdinal, target: target)
    microphoneOperation = operation
    consumedMicrophoneRouteRevision = target.revision
    confirmedMicrophoneBinding = nil
    microphoneInputStatus = .pending(target: desiredMicrophoneTarget ?? target)
    return operation
  }

  /// The sole mic finish path. Neither a timed-out waiter nor an old task tail may clear a new slot.
  private func finishMicrophoneOperation(
    _ operation: MicrophoneOperation, result: Result<MicrophoneInputBinding, Error>
  ) {
    guard microphoneOperation == operation else { return }
    microphoneOperation = nil
    legRebuildTasks[.microphone] = nil
    guard sessionEpochHostTime == operation.epoch else { return }
    switch result {
    case .success(let binding):
      if binding.device.isSameEndpoint(as: operation.target.device) {
        confirmedMicrophoneBinding = binding
        microphoneRouteFailure = nil
      } else {
        confirmedMicrophoneBinding = nil
        microphoneRouteFailure = "麦克风返回的实际设备与本次目标不一致"
      }
    case .failure(let error):
      confirmedMicrophoneBinding = nil
      microphoneRouteFailure = "麦克风未就绪：\(error.localizedDescription)"
    }
    reconcileMicrophoneInput()
  }

  @_spi(Verification) public var microphoneRoutingSnapshot:
    (operation: UInt64?, target: MicrophoneDeviceUID?, exhausted: Bool)
  {
    (
      microphoneOperation?.ordinal, microphoneOperation?.target.device.uid,
      legWatchStates[.microphone]?.retryBudgetExhausted ?? false
    )
  }

  public func start(
    title: String = "会议",
    language: MeetingLanguage,
    providers: [RoleProviderBinding],
    systemAudioProcessIDs: [pid_t]? = nil
  ) async {
    guard phase == .idle || phase == .completed || phase == .failed else {
      return
    }
    // A previous timed-out physical start still owns the microphone until it returns.
    if let pending = legRebuildTasks[.microphone] { await pending.value }
    guard phase == .idle || phase == .completed || phase == .failed else { return }
    let startupStartedAt = Date()
    DiagnosticEventLedger.shared.append(
      event: "recording.start",
      source: "RecordingSession",
      fields: DiagnosticEventFields(
        family: "audio",
        operation: "recordingStart",
        purpose: "recording",
        origin: "app",
        outcome: "started"
      )
    )
    // 设备信息在**开工前**采一次留着,不到失败时才去查(2026-08-20 评审):
    // 摘要查询是同步 CoreAudio HAL 调用。如果启动超时的根因正是 HAL 被楔住
    // (无线麦场景完全可能),在失败分支里再查它,就会把「告诉用户出了什么事」
    // 这条路自己也挂住——诊断手段死在它要诊断的那个故障上。
    let inputDeviceSummary = desiredMicrophoneTarget?.device.summary ?? AudioInputDeviceSummary()
    let inputDeviceLabelAtStart = inputDeviceSummary.name
    // 本次启动的轨迹:面包屑进内存,失败/卡死/慢成功时落盘 start-failures-*.log
    // (诊断包整目录收集,证据自动进包)。notice 级让面包屑同时进持久 log store
    // (G1:info 级默认不落盘,`log show` 不加 --info 一条都看不见)。
    let trace = RecordingStartupTrace(
      startedAt: startupStartedAt,
      device: inputDeviceSummary,
      diagnosticsRoot: diagnosticsRoot
    )
    func logStartupStage(_ stage: String) {
      let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startupStartedAt))
      logger.notice(
        "开会启动 stage=\(stage, privacy: .public) elapsed=\(elapsed, privacy: .public)"
      )
      trace.complete(stage: stage)
    }

    confirmedMicrophoneBinding = nil
    consumedMicrophoneRouteRevision = nil
    microphoneRouteFailure = nil
    phase = .starting
    issue = nil
    partialCaptureNotice = nil
    currentRecord = nil
    currentMeetingDirectory = nil
    currentTitle = nil
    liveSegments = []
    startedAt = nil
    transcriberASRAnchorGapFrames = [:]
    transcriberLiveEmissionStats = [:]
    microphoneLevel = 0
    isMicrophonePaused = false
    sessionEpochHostTime = nil
    microphonePauseIntervals = []
    captureInterruptions = []
    legHealth = [:]

    // 启动看门狗(G4):裸 await(requestPermission / systemAudioCapture.start)卡死
    // 不抛异常,HangSentinel 也不触发——超阈值先行 flush 轨迹(stuck),
    // 终态到达再由 markSuccess/flushFailure 追加终态行。detached:
    // 即使 MainActor 被饿死,落盘也不依赖它还活着。
    let startupWatchdog = Task.detached(priority: .utility) {
      [trace, threshold = healthPolicy.startupStuckThreshold] in
      let nanoseconds = UInt64(max(0.01, threshold) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      trace.flushStuck()
    }

    do {
      guard desiredMicrophoneTarget != nil else {
        throw AudioCaptureError.microphoneUnavailable(microphoneDirectoryFailure ?? "没有可用的麦克风输入")
      }
      trace.begin(stage: "permission")
      try await microphoneCapture.requestPermission()
      logStartupStage("permission")

      trace.begin(stage: "createMeeting")
      let record = try store.createMeeting(
        title: title,
        language: language,
        providers: providers
      )
      logStartupStage("createMeeting")
      currentRecord = record
      currentMeetingDirectory = record.paths.directory
      currentTitle = record.metadata.title
      startedAt = record.metadata.startedAt

      trace.begin(stage: "transcriber")
      await startTranscription(
        language: language,
        providers: providers,
        record: record
      )
      logStartupStage("transcriber")

      let activeTranscriber = transcriberEngine
      let systemAudioHandler = Self.makeTranscriptionHandler(
        engine: activeTranscriber,
        source: .others,
        logger: logger
      )
      let baseMicrophoneHandler = Self.makeTranscriptionHandler(
        engine: activeTranscriber,
        source: .me,
        logger: logger
      )
      let silenceWatchdog = SilenceWatchdogBox()
      let levelThrottle = LevelPublishThrottleBox()
      let microphoneHandler: AudioPCMBufferHandler? = {
        [weak self, logger] buffer, captureTime in
        baseMicrophoneHandler?(buffer, captureTime)
        let seconds = Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
        let rms = Self.bufferRMS(buffer)
        if levelThrottle.shouldPublish() {
          let level = Self.normalizedLevel(rms: rms)
          Task { @MainActor [weak self] in
            // 启动期首批 buffer 也要发布;停止后拦截,防陈旧任务复活电平。
            guard
              let self,
              self.phase == .recording || self.phase == .starting,
              !self.isMicrophonePaused
            else {
              return
            }
            self.microphoneLevel = level
          }
        }
        if silenceWatchdog.track(rms: rms, seconds: seconds) {
          logger.error("麦克风连续 30 秒纯静音——疑似被通话应用独占")
          Task { @MainActor [weak self] in
            guard let self, self.phase == .recording else { return }
            self.issue = RecordingSessionIssue(
              title: "录不到你的声音",
              message: "麦克风已连续 30 秒纯静音,很可能被通话应用(微信/腾讯会议等)独占了。"
                + "录音仍在继续,对方声音不受影响;建议在通话应用里换一个麦克风设备,"
                + "或结束本场后改用手机开会、Mac 只旁听的方式。",
              settingsDestination: nil
            )
          }
        }
      }

      let sessionEpochHostTime = AudioCaptureClock.nowHostTime()
      self.sessionEpochHostTime = sessionEpochHostTime
      // mic 子阶段并入同一条轨迹;回调在 captureQueue 上同步触发,
      // 失败 flush 之后的同世代迟到上报由 trace 记为 late 行。
      let microphoneStageObserver: MicrophoneStartStageObserver = {
        [trace] stage, detail in
        trace.complete(stage: stage.rawValue, detail: detail)
      }
      do {
        // 顺序承重:麦克风必须先于系统声 tap 启动。tap 在跑时,AVCaptureSession
        // 的 CMIOGraph 启动会被 tap 占住的 Core Audio 资源堵死(2026-08-22 实证:
        // Starting CMIOGraph 后 21.4s 无动静,超时清理停掉 tap 后 150ms 内
        // setPlayState Started 立刻放行;六次失败全部同签名,与超时取值无关)。
        // 两路时间戳都对 sessionEpochHostTime 对齐,对调不影响时间轴。
        trace.begin(stage: "micStart")
        try await startMicrophoneWithTimeout(
          outputURL: record.paths.microphoneAudio,
          sessionEpochHostTime: sessionEpochHostTime,
          bufferHandler: microphoneHandler,
          onStartStage: microphoneStageObserver
        )
        logStartupStage("micStart")
        trace.begin(stage: "systemStart")
        try await systemAudioCapture.start(
          outputURL: record.paths.systemAudio,
          sessionEpochHostTime: sessionEpochHostTime,
          processIDs: systemAudioProcessIDs,
          bufferHandler: systemAudioHandler
        )
        logStartupStage("systemStart")
      } catch {
        // 落盘顺序是承重的(design §1.1):进 catch 第一件事就是这次同步写盘,
        // 后面的 cleanUpCaptures / stopTranscription 全是 await——若根因是
        // HAL 楔住,它们可能自己挂住,诊断不能死在它要诊断的故障上。
        // 设备信息用开工时采好的快照,这里不再查 HAL。
        let flushDescription: String
        if error is MicrophoneStartTimedOut {
          flushDescription =
            "麦克风采集启动超时(\(healthPolicy.microphoneStartTimeout)s 未开始收音)"
        } else {
          flushDescription = error.localizedDescription
        }
        trace.flushFailure(errorDescription: flushDescription)

        let surfacedError: Error
        if error is MicrophoneStartTimedOut {
          // cancelPendingStart 已同步让旧世代失效；这里只等本地系统声路收尾，
          // 不能再 await 可能仍卡在 startRunning 的麦克风 stop。
          await cleanUpCaptures(waitForMicrophone: false)
          // 2026-08-20 用户实测改判:这条文案原先**无条件**归因到蓝牙,并建议改用内置麦克风。
          // 两处都错:
          // ① 归因错——超时路径拿不到任何证据说明是蓝牙。用户设备是 DJI 无线麦的 **USB**
          //    接收器(Transport: USB),被这句话指去排查一个根本不存在的蓝牙故障。
          //    代码里虽有 `isDefaultInputBluetoothHFP()`,但它查的是真实硬件,写进错误构造
          //    会让文案随机器而变、验证也钉不住,所以这里改成**不猜原因**。
          // ② 处置错——"换成内置麦克风"是在说用户的设备不该用。同一支麦在其他会议软件里
          //    工作正常,让用户换设备既解决不了问题,也把缺陷说成了用法问题。
          // 现在只说**事实**(哪支麦、多久没出声),再给两条不预设设备类别的自查方向。
          let deviceLabel = inputDeviceLabelAtStart.map { "「\($0)」" } ?? ""
          surfacedError = AudioCaptureError.microphoneUnavailable(
            "麦克风\(deviceLabel)在 \(Int(healthPolicy.microphoneStartTimeout)) 秒内没有开始收音。"
              + "若用的是无线麦(接收器 + 独立发射器),请确认发射器已开机、已配对且在接收范围内;"
              + "也可能是其他 App 正占用这支麦克风。"
          )
        } else {
          await cleanUpCaptures()
          surfacedError = error
        }
        _ = await stopTranscription()
        self.sessionEpochHostTime = nil
        markFailed(record: record)
        throw surfacedError
      }

      phase = .recording
      startHealthMonitoring()
      logStartupStage("total")
      // 快成功不落盘;看门狗已 flush 过(慢成功)则追加终态行留下对照样本。
      startupWatchdog.cancel()
      trace.markSuccess()
      DiagnosticEventLedger.shared.append(
        event: "recording.finish",
        source: "RecordingSession",
        fields: DiagnosticEventFields(
          family: "audio",
          operation: "recordingStart",
          purpose: "recording",
          origin: "app",
          meetingHash: MeetingDiagnosticsPackageExporter.meetingHash(for: record.metadata.id),
          stage: "total",
          outcome: "success",
          category: "success",
          latencyMs: Int(Date().timeIntervalSince(startupStartedAt) * 1_000)
        )
      )
      logger.info(
        "双路录音开始：\(record.paths.directory.path, privacy: .public)"
      )
    } catch {
      // 内层 catch 已 flush 过则无操作;permission/createMeeting 这类只经外层的
      // 失败在此落盘——同样先写盘再做其余收尾。
      trace.flushFailure(errorDescription: error.localizedDescription)
      DiagnosticEventLedger.shared.append(
        event: "recording.finish",
        severity: .error,
        source: "RecordingSession",
        fields: DiagnosticEventFields(
          family: "audio",
          operation: "recordingStart",
          purpose: "recording",
          origin: "app",
          meetingHash: currentRecord.map {
            MeetingDiagnosticsPackageExporter.meetingHash(for: $0.metadata.id)
          },
          stage: "startup",
          outcome: "failure",
          category: DiagnosticSanitizer.category(for: error),
          errorSummary: DiagnosticSanitizer.summary(error.localizedDescription)
        )
      )
      startupWatchdog.cancel()
      sessionEpochHostTime = nil
      phase = .failed
      let issue = Self.makeIssue(error, action: "开始录音")
      self.issue = issue
      logger.error("开始录音失败：\(issue.message, privacy: .public)")
    }
  }

  /// 收敛在飞的完备度落盘:cancel 是让路信号,await value 才是保证——取消不中断
  /// 已在跑的任务体,等它自然结束。spec「完备度落盘收敛契约」:任何删除会议目录的
  /// 路径,删除前必须先经这里;正常 stop 路径不调用,落盘异步性保留。
  public func settlePendingCompletenessScan() async {
    if let pending = pendingCompletenessScan {
      pendingCompletenessScan = nil
      pending.cancel()
      await pending.value
    }
  }

  /// 废弃当前会议(拍板 T15):停采集 → 删掉本场目录 → 回到空闲态。
  ///
  /// **不可逆**,录音、速记、笔记一并消失,所以只允许由界面上带确认的动作触发。
  /// 先走完整的 `stop()` 再删,是为了让两路 writer 正常收尾——直接删目录会留下
  /// 还持着文件句柄的 writer。会后云端管线不由这里触发(调用方先让总结引擎放弃本场),
  /// 因此废弃路径上不产生任何一次云端计费调用。
  /// 只允许在 `.recording` 下废弃:`stop()` 自身也只处理 `.recording`,
  /// 若放宽到 `.starting`/`.stopping`,`stop()` 会直接空转返回,接着就在
  /// 两路 writer 还活着的时候删目录——正是上面那句注释要避免的事。
  @discardableResult
  public func discardCurrentMeeting() async -> Bool {
    guard phase == .recording else {
      return false
    }
    let directory = currentRecord?.paths.directory ?? currentMeetingDirectory
    await stop()
    // 竞态收敛(08-20 高负载实证「废弃动作返回失败」,da39ab6 引入):stop 尾部
    // 派发的完备度落盘必须彻底退出,删目录才不会与它的 atomic 写互撞。
    await settlePendingCompletenessScan()
    currentRecord = nil
    currentMeetingDirectory = nil
    currentTitle = nil
    startedAt = nil
    liveSegments = []
    issue = nil
    phase = .idle
    guard let directory else { return false }
    do {
      try store.deleteMeeting(at: MeetingPaths(directory: directory))
      logger.info("已废弃并删除会议：\(directory.path, privacy: .public)")
      return true
    } catch {
      logger.error(
        "废弃会议时删除目录失败：\(error.localizedDescription, privacy: .public)"
      )
      return false
    }
  }

  /// 结束录音的判定矩阵(08-05 事故:system 路旧错把整场标 failed,mic 完好 17 分钟
  /// 却不跑会后流水线):
  /// - 两路都好 -> completed(现状不变);
  /// - 单路失败 -> 整场仍 completed + `captureLegFailures` 写盘 + 非模态横幅,不弹对话框,
  ///   会后流水线(只认 phase == .completed)天然放行;
  /// - 两路全失败 / 元数据写入失败 -> failed + 模态对话框(现状不变)。
  public func stop() async {
    guard phase == .recording, let record = currentRecord else {
      return
    }

    phase = .stopping
    microphoneLevel = 0
    issue = nil
    partialCaptureNotice = nil

    DiagnosticEventLedger.shared.append(
      event: "recording.stopRequested",
      source: "RecordingSession",
      fields: DiagnosticEventFields(
        family: "audio", operation: "recordingStop", purpose: "recording", origin: "app",
        meetingHash: MeetingDiagnosticsPackageExporter.meetingHash(for: record.metadata.id),
        outcome: "started"
      )
    )
    // Stop scheduling first, then let each leg drain only its own physical work.
    // A held mic rebuild must not prevent an otherwise safe system stop from starting.
    await stopHealthMonitoring()
    async let microphoneStop = stopCaptureLeg(.microphone)
    async let systemAudioStop = stopCaptureLeg(.systemAudio)
    let (microphoneError, systemAudioError) = await (microphoneStop, systemAudioStop)

    let transcriptionError = await stopTranscription()
    sessionEpochHostTime = nil
    if let transcriptionError {
      logger.error(
        "本地速记收尾失败：\(transcriptionError.localizedDescription, privacy: .public)"
      )
    }

    let endedAt = Date()
    let bothLegsFailed = microphoneError != nil && systemAudioError != nil
    let legFailures =
      bothLegsFailed
      ? []
      : makeLegFailures(
        microphoneError: microphoneError,
        systemAudioError: systemAudioError,
        startedAt: record.metadata.startedAt
      )
    var fatalError: Error? = bothLegsFailed ? (microphoneError ?? systemAudioError) : nil
    let finalStatus: MeetingStatus = bothLegsFailed ? .failed : .completed

    do {
      currentRecord = try store.updateStatus(
        finalStatus,
        endedAt: endedAt,
        captureLossStats: captureLossStats,
        captureLegFailures: legFailures.isEmpty ? nil : legFailures,
        captureInterruptions: captureInterruptions.isEmpty ? nil : captureInterruptions,
        for: record
      )
    } catch {
      fatalError = fatalError ?? error
    }

    if let fatalError {
      phase = .failed
      let issue = Self.makeIssue(fatalError, action: "结束录音")
      self.issue = issue
      logger.error("结束录音失败：\(issue.message, privacy: .public)")
    } else {
      phase = .completed
      if !captureInterruptions.isEmpty {
        let descriptions =
          legFailures.map(\.missingDescription)
          + captureInterruptions.map(\.displayDescription)
        let notice =
          descriptions.joined(separator: "；")
          + "；纪要将基于实际录到的内容生成。"
        partialCaptureNotice = notice
        logger.error(
          "采集曾中断，整场按可用内容完成：\(notice, privacy: .public)"
        )
      } else if let firstLegFailure = legFailures.first {
        let notice = Self.makePartialCaptureNotice(firstLegFailure)
        partialCaptureNotice = notice
        logger.error(
          "单路采集失败，整场降级为部分完成：\(notice, privacy: .public)"
        )
      }
      if let transcriptionError {
        issue = RecordingSessionIssue(
          title: "速记保存失败",
          message: "\(transcriptionError.localizedDescription)\n\n双路录音已经保存。",
          settingsDestination: nil
        )
      }
      logger.info(
        "双路录音完成：\(record.paths.directory.path, privacy: .public)"
      )
    }
    let scannedPaths = record.paths
    let scan = completenessScan
    // 句柄留给废弃路径收敛;stop 自身不等它(异步性保留,落盘时机语义不变)。
    // 下一场 stop 覆盖旧句柄是安全的:被覆盖的旧任务只写上一场的目录,与后续
    // 废弃的删除目标无交集(路径复用仅在旧目录先被库列表删除时可能,那要求
    // utility 任务横跨整段用户操作仍未调度,远超本单毫秒级竞态窗口,不设防)。
    pendingCompletenessScan = Task.detached(priority: .utility) {
      scan(scannedPaths)
    }
  }

  public func dismissIssue() {
    issue = nil
  }

  /// 只暂停麦克风内容。采集路继续推进并写等长静音，系统声完全不受影响。
  /// 返回 false 表示当前不在录制，或已经处于暂停态。
  @discardableResult
  public func pauseMicrophone() -> Bool {
    guard
      phase == .recording,
      !isMicrophonePaused,
      let captureTime = currentCaptureTime()
    else {
      return false
    }

    microphonePauseIntervals.append(
      MicrophonePauseInterval(start: captureTime)
    )
    // 隐私动作先于诊断落盘生效；即使 meeting.json 暂时写失败，也不继续收音。
    microphoneCapture.setPaused(true, at: captureTime)
    isMicrophonePaused = true
    microphoneLevel = 0
    persistMicrophonePauseIntervals()
    logger.notice(
      "麦克风已暂停：会议第 \(captureTime, privacy: .public) 秒起写等长静音，系统声继续"
    )
    return true
  }

  /// 恢复麦克风采集与实时 ASR。返回 false 表示当前不在录制，或并未暂停。
  @discardableResult
  public func resumeMicrophone() -> Bool {
    guard
      phase == .recording,
      isMicrophonePaused,
      let captureTime = currentCaptureTime()
    else {
      return false
    }

    closeActiveMicrophonePause(at: captureTime)
    microphoneCapture.setPaused(false, at: captureTime)
    isMicrophonePaused = false
    persistMicrophonePauseIntervals()
    logger.notice(
      "麦克风已恢复：会议第 \(captureTime, privacy: .public) 秒起恢复母带与实时转写"
    )
    return true
  }

  /// 录制中改名也只提交 `meeting.json`:不停止采集、不重建 writer、不移动会议目录。
  /// 返回 `false` 时保留原名称并发布可呈现的错误,当前录音状态不受影响。
  @discardableResult
  public func renameCurrentMeeting(to title: String) -> Bool {
    guard let record = currentRecord else {
      return false
    }

    do {
      let metadata = try store.renameMeeting(to: title, at: record.paths)
      currentRecord = MeetingRecord(paths: record.paths, metadata: metadata)
      currentTitle = metadata.title
      return true
    } catch {
      issue = RecordingSessionIssue(
        title: "会议改名失败",
        message: error.localizedDescription,
        settingsDestination: nil
      )
      return false
    }
  }

  private func currentCaptureTime() -> TimeInterval? {
    guard let sessionEpochHostTime else { return nil }
    let captureTime = AudioCaptureClock.secondsSinceEpoch(
      hostTime: AudioCaptureClock.nowHostTime(),
      epochHostTime: sessionEpochHostTime
    )
    guard captureTime.isFinite else { return nil }
    return max(0, captureTime)
  }

  private func closeActiveMicrophonePause(at captureTime: TimeInterval) {
    guard
      let index = microphonePauseIntervals.lastIndex(where: { $0.end == nil })
    else {
      return
    }
    microphonePauseIntervals[index].end = max(
      microphonePauseIntervals[index].start,
      captureTime
    )
  }

  private func persistMicrophonePauseIntervals() {
    guard let record = currentRecord else { return }
    do {
      let metadata = try store.recordMicrophonePauseIntervals(
        microphonePauseIntervals,
        at: record.paths
      )
      currentRecord = MeetingRecord(paths: record.paths, metadata: metadata)
    } catch {
      issue = RecordingSessionIssue(
        title: "麦克风暂停记录保存失败",
        message: "麦克风暂停或恢复已经生效，但时间点未能写入 meeting.json。\n\n"
          + error.localizedDescription,
        settingsDestination: nil
      )
      logger.error(
        "麦克风暂停区间写入 meeting.json 失败：\(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // MARK: - 会中路级健康看门狗(08-05 自愈单)

  /// 统计推进看门狗:每 `sampleInterval` 采样两路 capturedFrames,连续
  /// `stallThreshold` 无增长判 stalled 并按 立即/15s/30s 驱动 rebuild,3 次后 givenUp。
  /// 不碰 IO 热路径——只读 lossStats 快照;该信号同时覆盖「回调停了」与
  /// 「回调仍触发但帧全被丢弃」两类死法(08-05 事故即后者)。
  private func startHealthMonitoring() {
    healthMonitorTask?.cancel()
    let now = Date()
    legWatchStates = Dictionary(
      uniqueKeysWithValues: CaptureLeg.allCases.map { leg in
        let frames = capturedFrames(for: leg)
        return (
          leg,
          LegWatchState(
            lastFrames: frames,
            lastSampledAt: now,
            lastProgressAt: now,
            hasObservedFrames: frames > 0
          )
        )
      }
    )
    legHealth = Dictionary(
      uniqueKeysWithValues: CaptureLeg.allCases.map { ($0, .healthy) }
    )
    let interval = healthPolicy.sampleInterval
    healthMonitorTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } catch {
          return
        }
        guard let self else { return }
        guard await self.sampleLegHealthOnce() else { return }
      }
    }
  }

  /// Cancel only the sampler's wait layer. Physical tasks retain their registrations
  /// until their own completion paths remove them; each stop branch awaits its own leg.
  private func stopHealthMonitoring() async {
    if let task = healthMonitorTask {
      healthMonitorTask = nil
      task.cancel()
      await task.value
    }
  }

  /// A nonthrowing result keeps both structured branches owned even when one leg fails.
  private func stopCaptureLeg(_ leg: CaptureLeg) async -> Error? {
    if let pending = legRebuildTasks[leg] {
      appendCaptureDiagnostic(event: "audioLeg.stopWait", leg: leg, outcome: "waiting")
      await pending.value
    }

    let pauseEndAtStop = leg == .microphone && isMicrophonePaused ? currentCaptureTime() : nil
    if let pauseEndAtStop {
      closeActiveMicrophonePause(at: pauseEndAtStop)
      isMicrophonePaused = false
    }
    if leg == .microphone && !microphonePauseIntervals.isEmpty {
      // Retry any transient pause metadata failure with the complete in-memory snapshot.
      persistMicrophonePauseIntervals()
    }

    appendCaptureDiagnostic(event: "audioLeg.stopBegin", leg: leg, outcome: "started")
    var stopError: Error?
    do {
      switch leg {
      case .microphone: try await microphoneCapture.stop()
      case .systemAudio: try await systemAudioCapture.stop()
      }
    } catch {
      stopError = error
    }
    if let pauseEndAtStop {
      // Keep the capture gate fail-closed until the real microphone processor has drained.
      microphoneCapture.setPaused(false, at: pauseEndAtStop)
    }
    appendCaptureDiagnostic(
      event: "audioLeg.stopFinish", leg: leg,
      outcome: stopError == nil ? "success" : "failure", error: stopError
    )
    return stopError
  }

  /// 一轮采样;返回 false 表示录制已不在进行,监测应结束。
  private func sampleLegHealthOnce() async -> Bool {
    guard phase == .recording else { return false }
    for leg in CaptureLeg.allCases {
      await sampleLeg(leg)
      // rebuild 的 await 期间可能已开始 stop;逐路复查再继续。
      guard phase == .recording else { return false }
    }
    return true
  }

  private func sampleLeg(_ leg: CaptureLeg) async {
    guard var state = legWatchStates[leg] else { return }
    let recovery = leg == .microphone ? microphoneCapture.runtimeRecoverySnapshot : nil
    let now = Date()
    let frames = recovery?.capturedFrames ?? capturedFrames(for: leg)
    let runtimeRequest = recovery.flatMap {
      $0.request.generation == state.consumedRuntimeGeneration ? nil : $0.request
    }
    if let runtimeRequest {
      if state.runtimeErrorAt != runtimeRequest.observedAt {
        appendCaptureDiagnostic(
          event: "audioLeg.runtimeError", leg: leg, outcome: "observed",
          category: "runtimeError", attempt: state.attempts
        )
        logger.error("麦克风当前采集会话报告运行错误，按本场既有重建额度处理")
      }
      state.cause = .runtimeError
      state.runtimeErrorAt = runtimeRequest.observedAt
      // Preserve the episode's earlier stall anchor, attempts and deadline. The new
      // cause names the time the runtime error was actually observed, not that anchor.
      if state.stalledSince != nil {
        legHealth[leg] =
          state.isGivenUp
          ? .givenUp(
            lastGoodSecondsIntoMeeting: max(
              0, runtimeRequest.observedAt.timeIntervalSince(startedAt ?? now)),
            cause: .runtimeError
          )
          : .stalled(
            since: runtimeRequest.observedAt, attempts: state.attempts, cause: .runtimeError)
      }
    }
    // 推进判据是**速率**,不是「有没有多出帧」。窗口只取**上一次采样到现在**,
    // 绝不是「上一次合格推进到现在」:后者会把此前一整段合法的无输入时段算进分母,
    // 于是系统声合法静默 2 小时后第一口满速输入(5s 得 240,000 帧)要去和
    // 1000×7205 帧的门槛比,满速反被判故障(review 5120025793 §2)。按采样窗口算,
    // 涓流照样追不上(每个窗口的速率恒定地低于门槛),满速则当场达标。
    // 窗口用实际间隔而不是固定的 sampleInterval:采样被负载推迟时分子分母同涨,
    // 替身也按同一个墙钟出帧,抖动两边抵消。
    let sampleWindow = max(0, now.timeIntervalSince(state.lastSampledAt))
    let framesDelta = frames >= state.lastFrames ? frames - state.lastFrames : 0
    var hasQualifyingProgress =
      framesDelta > 0
      && Double(framesDelta)
        >= healthPolicy.minimumProgressFramesPerSecond * sampleWindow
    if runtimeRequest != nil {
      if let rebuiltAt = recovery?.rebuiltAt, let framesAtRebuild = recovery?.framesAtRebuild {
        let newGenerationFrames = frames - min(frames, max(state.lastFrames, framesAtRebuild))
        let newGenerationWindow = max(0, now.timeIntervalSince(max(state.lastSampledAt, rebuiltAt)))
        hasQualifyingProgress =
          newGenerationFrames > 0
          && Double(newGenerationFrames) >= healthPolicy.minimumProgressFramesPerSecond
            * newGenerationWindow
      } else {
        hasQualifyingProgress = false
      }
    }
    // 速率窗口每一轮都前移;停摆阈值那条锚点(lastProgressAt)只在合格推进时才动。
    state.lastFrames = frames
    state.lastSampledAt = now
    let sinceLastProgress = max(0, now.timeIntervalSince(state.lastProgressAt))

    // The request is consumed only after the matching replacement's own rate qualifies.
    // Retaining that identity in this existing state prevents the old fault being replayed.
    if hasQualifyingProgress {
      if let runtimeRequest { state.consumedRuntimeGeneration = runtimeRequest.generation }
      state.lastProgressAt = now
      state.hasObservedFrames = true
      if state.isGivenUp, let stalledSince = state.stalledSince {
        // 重试额度耗尽只禁止新的物理 rebuild，不禁止继续观察真实帧。迟到成功
        // 一旦被速率判据确认，就关闭当前 interruption 并让用户看到 recovered。
        let gapSeconds = max(0, now.timeIntervalSince(stalledSince))
        closeCaptureInterruption(for: leg, recoveredAt: now)
        state.stalledSince = nil
        state.nextRetryAt = nil
        state.recoveredAt = now
        state.isGivenUp = false
        legHealth[leg] = .recovered(gapSeconds: gapSeconds, cause: state.cause)
        appendCaptureDiagnostic(
          event: "audioLeg.recovered",
          leg: leg,
          outcome: "lateRecovered",
          category: "rebuildBudgetExhausted",
          attempt: state.attempts,
          latencyMs: Int(gapSeconds * 1_000)
        )
        if state.cause == .runtimeError {
          logger.notice("麦克风运行错误后已重建并接收新一代采集数据，已有录音继续保留；本场重建额度仍保持耗尽")
        } else {
          logger.notice(
            "\(leg.displayName, privacy: .public)在停止重试后重新出帧，中断约 \(Int(gapSeconds.rounded()), privacy: .public) 秒；本场重试额度仍保持耗尽"
          )
        }
      } else if let stalledSince = state.stalledSince {
        let gapSeconds = now.timeIntervalSince(stalledSince)
        state.stalledSince = nil
        state.attempts = 0
        state.nextRetryAt = nil
        state.recoveredAt = now
        legHealth[leg] = .recovered(gapSeconds: gapSeconds, cause: state.cause)
        appendCaptureDiagnostic(
          event: "audioLeg.recovered",
          leg: leg,
          outcome: "recovered",
          latencyMs: Int(gapSeconds * 1_000)
        )
        if state.cause == .runtimeError {
          logger.notice("麦克风运行错误后已重建并接收新一代采集数据，已有录音继续保留")
        } else {
          logger.notice(
            "\(leg.displayName, privacy: .public)已恢复出帧，中断约 \(Int(gapSeconds.rounded()), privacy: .public) 秒（缺口按等长静音保留）"
          )
        }
      } else if let recoveredAt = state.recoveredAt,
        now.timeIntervalSince(recoveredAt) >= healthPolicy.recoveredNoticeDuration
      {
        state.recoveredAt = nil
        legHealth[leg] = .healthy
      }
      legWatchStates[leg] = state
      return
    }

    // 不合格但确实多出了帧,仍然算「这一路曾经出过帧」——否则一路从头到尾只涓流的
    // 系统声会永远卡在下面那条 hasObservedFrames 早退里,再也判不出停摆。
    // **首次**出帧同时把停摆锚点定在此刻:在这之前系统声没有输入是合法状态
    // (Mac 没在放声音),那段时间不能算进停摆窗口,否则第一口气不够满速就被判停
    // (review 5120025793 §2)。从这个锚点起,涓流照样会在 stallThreshold 后判停。
    if framesDelta > 0, !state.hasObservedFrames, runtimeRequest == nil {
      state.hasObservedFrames = true
      state.lastProgressAt = now
      legWatchStates[leg] = state
      return
    }

    if state.isGivenUp {
      legWatchStates[leg] = state
      return
    }

    // 系统音频是「系统正在播放的声音」，本场可能合法地从未有过输入（例如
    // 面对面交流且 Mac 没有播放任何声音）。只有曾经观察到帧、之后才停止，
    // 才能证明是采集链路中断并进入 stalled/rebuild；麦克风路保持原有零帧判定。
    if leg == .systemAudio, !state.hasObservedFrames {
      legWatchStates[leg] = state
      return
    }

    if state.stalledSince == nil {
      guard runtimeRequest != nil || sinceLastProgress >= healthPolicy.stallThreshold else {
        legWatchStates[leg] = state
        return
      }
      let faultAt = runtimeRequest?.observedAt ?? state.lastProgressAt
      state.cause = runtimeRequest == nil ? .noFrameProgress : .runtimeError
      state.runtimeErrorAt = runtimeRequest?.observedAt
      state.stalledSince = faultAt
      state.recoveredAt = nil
      if state.retryBudgetExhausted {
        // 迟到恢复不会补充重试额度。同一路再次停摆时直接开一段新的
        // interruption 并回到 givenUp，绝不派新的物理 rebuild。
        enterGivenUp(
          for: leg,
          state: &state,
          stalledSince: faultAt,
          isRepeatedInterruption: true
        )
        legWatchStates[leg] = state
        return
      }
      state.attempts = 0
      state.nextRetryAt = now
      legHealth[leg] = .stalled(since: faultAt, attempts: 0, cause: state.cause)
      appendCaptureDiagnostic(
        event: "audioLeg.stalled",
        leg: leg,
        outcome: "stalled",
        category: state.cause == .runtimeError ? "runtimeError" : "noFrameProgress"
      )
      if state.cause == .runtimeError {
        logger.error("麦克风采集运行错误，准备自动重建；当前帧计数不能确认恢复")
      } else {
        logger.error(
          "\(leg.displayName, privacy: .public)采集停摆：capturedFrames 连续 \(Int(self.healthPolicy.stallThreshold), privacy: .public) 秒以上无增长，准备自动重建"
        )
      }
    }

    if let nextRetryAt = state.nextRetryAt,
      now >= nextRetryAt,
      state.attempts < healthPolicy.maximumAttempts,
      let stalledSince = state.stalledSince
    {
      // 上一次的物理重建还没回来:**不派第二个**(所有权与互斥不变,采样循环立刻
      // 返回,另一路照常被采样),但这一次尝试照常计入额度。
      //
      // 原先这里把额度也一起让出去,于是一次永不返回的重建会把该路永久钉在
      // `.stalled(attempts: 1)`,横幅一直说「第 1 次自动重建…」,永远走不到 givenUp
      // (#57 review 5120183969 记为已知限制)。物理重建卡死是**这一路已经没救了**的
      // 证据,不是「还没轮到重试」:额度照常推进,打完按既有事件进 givenUp,
      // 用户可见状态因此有界收敛。派不出去的这次不写成一次物理重建(独立 outcome)。
      if legRebuildTasks[leg] != nil {
        state.attempts += 1
        let skippedAttempt = state.attempts
        state.nextRetryAt =
          skippedAttempt < healthPolicy.maximumAttempts
          ? now.addingTimeInterval(healthPolicy.retryDelays[skippedAttempt])
          : nil
        legHealth[leg] = .stalled(
          since: state.runtimeErrorAt ?? stalledSince, attempts: skippedAttempt, cause: state.cause)
        legWatchStates[leg] = state
        appendCaptureDiagnostic(
          event: "audioLeg.rebuild",
          leg: leg,
          outcome: "stillInFlight",
          category: "rebuildStillInFlight",
          attempt: skippedAttempt
        )
        logger.error(
          "\(leg.displayName, privacy: .public)第 \(skippedAttempt, privacy: .public)/\(self.healthPolicy.maximumAttempts, privacy: .public) 次重建未派出：上一次重建仍未返回，本次按失败计入尝试额度"
        )
        return
      }
      state.attempts += 1
      let attempt = state.attempts
      // 下一次尝试锚在**本次尝试开始**,不是「重建返回」。重建返回可能被采集队列
      // 拖到任意久(事故里 67/78/78 分钟),拿它当锚点等于把节奏交给故障本身。
      let attemptStartedAt = now
      // Install the mic deadline before awaiting: a late waiter has no state-writing tail.
      state.nextRetryAt =
        leg == .microphone && attempt < healthPolicy.maximumAttempts
        ? attemptStartedAt.addingTimeInterval(healthPolicy.retryDelays[attempt]) : nil
      legHealth[leg] = .stalled(
        since: state.runtimeErrorAt ?? stalledSince, attempts: attempt, cause: state.cause)
      legWatchStates[leg] = state
      logger.notice(
        "\(leg.displayName, privacy: .public)第 \(attempt, privacy: .public)/\(self.healthPolicy.maximumAttempts, privacy: .public) 次自动重建采集管线…"
      )
      let rebuildOutcome = await rebuildCapture(
        for: leg,
        timeout: healthPolicy.rebuildTimeout
      )
      if leg == .systemAudio, case .completed = rebuildOutcome {
        clearRebuildRegistration(for: leg)
      }
      switch rebuildOutcome {
      case .completed(.success):
        appendCaptureDiagnostic(
          event: "audioLeg.rebuild",
          leg: leg,
          outcome: "requested",
          attempt: attempt
        )
        logger.notice(
          "\(leg.displayName, privacy: .public)第 \(attempt, privacy: .public) 次重建完成，等待帧恢复"
        )
      case .completed(.failure(let error)):
        appendCaptureDiagnostic(
          event: "audioLeg.rebuild",
          leg: leg,
          outcome: "failure",
          category: DiagnosticSanitizer.category(for: error),
          attempt: attempt,
          error: error
        )
        logger.error(
          "\(leg.displayName, privacy: .public)第 \(attempt, privacy: .public) 次重建失败：\(error.localizedDescription, privacy: .public)"
        )
      case .timedOut:
        appendCaptureDiagnostic(
          event: "audioLeg.rebuild",
          leg: leg,
          outcome: "timeout",
          category: "rebuildTimeout",
          attempt: attempt,
          latencyMs: Int(healthPolicy.rebuildTimeout * 1_000)
        )
        logger.error(
          "\(leg.displayName, privacy: .public)第 \(attempt, privacy: .public) 次重建 \(Int(self.healthPolicy.rebuildTimeout), privacy: .public) 秒未返回，不再等它；监测继续按节奏推进"
        )
      case .cancelled:
        return
      }
      if leg == .microphone { return }
      // await 期间监测循环不重入(单任务串行),但状态可能被新一场 start 重建;重取。
      guard var latest = legWatchStates[leg], latest.stalledSince != nil,
        !latest.isGivenUp
      else {
        return
      }
      if attempt < healthPolicy.maximumAttempts {
        latest.nextRetryAt = attemptStartedAt.addingTimeInterval(
          healthPolicy.retryDelays[attempt]
        )
      }
      legWatchStates[leg] = latest
      return
    }

    // 3 次尝试打完、最后一轮观察窗(一个采样周期)仍无推进 → 放弃并保持提示。
    if state.attempts >= healthPolicy.maximumAttempts, state.nextRetryAt == nil,
      let stalledSince = state.stalledSince
    {
      enterGivenUp(
        for: leg,
        state: &state,
        stalledSince: stalledSince,
        isRepeatedInterruption: false
      )
      legWatchStates[leg] = state
      return
    }
    legWatchStates[leg] = state
  }

  private func enterGivenUp(
    for leg: CaptureLeg,
    state: inout LegWatchState,
    stalledSince: Date,
    isRepeatedInterruption: Bool
  ) {
    state.isGivenUp = true
    state.retryBudgetExhausted = true
    state.nextRetryAt = nil
    state.recoveredAt = nil
    let sessionStart = startedAt ?? stalledSince
    let lastGoodSeconds = max(0, stalledSince.timeIntervalSince(sessionStart))
    beginCaptureInterruption(for: leg, lastGoodSeconds: lastGoodSeconds)
    let noticeSeconds =
      state.runtimeErrorAt.map { max(0, $0.timeIntervalSince(sessionStart)) } ?? lastGoodSeconds
    legHealth[leg] = .givenUp(lastGoodSecondsIntoMeeting: noticeSeconds, cause: state.cause)
    appendCaptureDiagnostic(
      event: "audioLeg.givenUp",
      leg: leg,
      outcome: "givenUp",
      category: isRepeatedInterruption
        ? "rebuildBudgetAlreadyExhausted" : "rebuildExhausted",
      attempt: state.attempts
    )
    let timecode =
      CaptureLegFailure.timecode(secondsIntoMeeting: lastGoodSeconds) ?? "未知时刻"
    if state.cause == .runtimeError {
      logger.error("麦克风采集运行错误仍未确认恢复，本场自动重建额度已耗尽；已收到的录音继续保留，另一路不受影响")
    } else if isRepeatedInterruption {
      logger.error(
        "\(leg.displayName, privacy: .public)自 \(timecode, privacy: .public) 起再次停摆；本场自动重建额度已耗尽，不再发起新的重建"
      )
    } else {
      logger.error(
        "\(leg.displayName, privacy: .public)自动重建 \(self.healthPolicy.maximumAttempts, privacy: .public) 次未成功，停止重试；已保留 \(timecode, privacy: .public) 前的内容，另一路不受影响"
      )
    }
  }

  private func beginCaptureInterruption(
    for leg: CaptureLeg,
    lastGoodSeconds: Double
  ) {
    let persistedLeg = Self.persistedLeg(for: leg)
    guard
      !captureInterruptions.contains(where: {
        $0.leg == persistedLeg && $0.recoveredSecondsIntoMeeting == nil
      })
    else {
      return
    }
    captureInterruptions.append(
      CaptureInterruption(
        leg: persistedLeg,
        lastGoodSecondsIntoMeeting: lastGoodSeconds
      )
    )
  }

  private func closeCaptureInterruption(for leg: CaptureLeg, recoveredAt: Date) {
    let persistedLeg = Self.persistedLeg(for: leg)
    guard
      let index = captureInterruptions.lastIndex(where: {
        $0.leg == persistedLeg && $0.recoveredSecondsIntoMeeting == nil
      })
    else {
      return
    }
    let sessionStart = startedAt ?? recoveredAt
    let recoveredSeconds = max(0, recoveredAt.timeIntervalSince(sessionStart))
    captureInterruptions[index].recoveredSecondsIntoMeeting = max(
      captureInterruptions[index].lastGoodSecondsIntoMeeting,
      recoveredSeconds
    )
  }

  private nonisolated static func persistedLeg(
    for leg: CaptureLeg
  ) -> CaptureLegFailure.Leg {
    switch leg {
    case .microphone: return .microphone
    case .systemAudio: return .systemAudio
    }
  }

  private func capturedFrames(for leg: CaptureLeg) -> UInt64 {
    switch leg {
    case .microphone:
      return microphoneCapture.captureLossStats.capturedFrames
    case .systemAudio:
      return systemAudioCapture.captureLossStats.capturedFrames
    }
  }

  /// 有界重建。在飞的重建**不取消**——取消停不下已经进 HAL 的调用,只会让所有权
  /// 更模糊;超时只是让**采样循环**不再替它等着,回去按节奏采样另一路。
  /// 重建本身的所有权登记在 `legRebuildTasks`:同一路不会有第二个物理重建
  /// (调用点先查),`stop()` 也要等它收敛后才拆采集(`stopCaptureLeg`)。
  /// 形状与 `startMicrophoneWithTimeout` 同源(非结构化 Task + 流 vs 睡眠竞速)。
  private func rebuildCapture(
    for leg: CaptureLeg,
    timeout: TimeInterval
  ) async -> CaptureRebuildOutcome {
    let (stream, signal) = AsyncStream<CaptureRebuildOutcome>.makeStream()
    let microphoneCapture = self.microphoneCapture
    let systemAudioCapture = self.systemAudioCapture
    let operation: MicrophoneOperation?
    if leg == .microphone {
      guard let target = desiredMicrophoneTarget, let epoch = sessionEpochHostTime else {
        return .completed(.failure(AudioCaptureError.microphoneUnavailable("麦克风目标尚未就绪")))
      }
      operation = reserveMicrophoneOperation(target: target, epoch: epoch)
    } else {
      operation = nil
    }
    let rebuildTask = Task { @MainActor [weak self] in
      let outcome: CaptureRebuildOutcome
      do {
        if let operation {
          let binding = try await microphoneCapture.rebuild(target: operation.target)
          self?.finishMicrophoneOperation(operation, result: .success(binding))
        } else {
          try await systemAudioCapture.rebuild()
        }
        outcome = .completed(.success(()))
      } catch {
        if let operation { self?.finishMicrophoneOperation(operation, result: .failure(error)) }
        outcome = .completed(.failure(error))
      }
      if leg == .systemAudio { self?.legRebuildTasks[leg] = nil }
      signal.yield(outcome)
      signal.finish()
    }
    legRebuildTasks[leg] = rebuildTask
    defer {
      // 超时路径故意**不**取消 rebuildTask:见方法注释。这里只收口信号流。
      signal.finish()
    }

    let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
    let outcome = await withTaskGroup(
      of: CaptureRebuildOutcome.self,
      returning: CaptureRebuildOutcome.self
    ) { group in
      group.addTask {
        for await outcome in stream {
          return outcome
        }
        return .cancelled
      }
      group.addTask {
        do {
          try await Task.sleep(nanoseconds: timeoutNanoseconds)
        } catch {
          return .cancelled
        }
        return .timedOut
      }
      let first = await group.next() ?? .cancelled
      group.cancelAll()
      return first
    }
    if leg == .microphone { await verificationMicrophoneWaiter?() }
    return outcome
  }

  /// 摘掉本次重建的登记。`.completed` 说明物理重建已经返回(信号正是在 `rebuild()`
  /// 返回后才 yield 的),此刻同步摘除,下一轮采样不必等任务尾巴那次调度跳点;
  /// 超时/取消时不摘,登记留给任务自己在真正结束时清。
  private func clearRebuildRegistration(for leg: CaptureLeg) {
    legRebuildTasks[leg] = nil
  }

  private func appendCaptureDiagnostic(
    event: String,
    leg: CaptureLeg,
    outcome: String,
    category: String? = nil,
    attempt: Int? = nil,
    latencyMs: Int? = nil,
    error: Error? = nil
  ) {
    DiagnosticEventLedger.shared.append(
      event: event,
      // 派不出去的那次尝试同样是取证素材,落 error 级(info 不落盘)。
      severity: outcome == "failure" || outcome == "givenUp"
        || outcome == "stillInFlight" ? .error : .notice,
      source: "RecordingSession",
      fields: DiagnosticEventFields(
        family: "audio",
        operation: "captureLeg",
        role: leg.rawValue,
        purpose: "recording",
        origin: "audioHealth",
        meetingHash: currentRecord.map {
          MeetingDiagnosticsPackageExporter.meetingHash(for: $0.metadata.id)
        },
        attempt: attempt,
        outcome: outcome,
        category: category,
        latencyMs: latencyMs,
        errorSummary: error.map { DiagnosticSanitizer.summary($0.localizedDescription) }
      )
    )
  }

  /// 会中路级健康横幅文案;与结束后的 partial 结算横幅口径一致
  /// (mm:ss 起点、说清「保住了什么」,不做未经证实的归因)。healthy 返回 nil。
  public nonisolated static func makeLegHealthNotice(
    leg: CaptureLeg,
    health: CaptureLegHealth,
    startedAt: Date
  ) -> String? {
    switch health {
    case .healthy:
      return nil
    case .stalled(let since, let attempts, let cause):
      let timecode =
        CaptureLegFailure.timecode(
          secondsIntoMeeting: max(0, since.timeIntervalSince(startedAt))
        ) ?? "未知时刻"
      let attemptText =
        attempts == 0
        ? "即将自动重建采集" : "正在第 \(attempts) 次自动重建采集"
      if cause == .runtimeError {
        return "\(leg.displayName)在 \(timecode) 报告采集运行错误，\(attemptText)；"
          + "已收到的录音继续保留，另一条录音不受影响。"
      }
      return "\(leg.displayName)自 \(timecode) 起无新数据，\(attemptText)；"
        + "录音其余部分不受影响。"
    case .recovered(let gapSeconds, let cause):
      if cause == .runtimeError {
        return "\(leg.displayName)已重建并恢复接收采集数据，已有录音与时间轴继续保留。"
      }
      let gap = max(1, Int(gapSeconds.rounded()))
      return "\(leg.displayName)已恢复，中断的约 \(gap) 秒已按等长静音保留，"
        + "时间轴不受影响。"
    case .givenUp(let lastGoodSeconds, let cause):
      let timecode =
        CaptureLegFailure.timecode(secondsIntoMeeting: lastGoodSeconds) ?? "未知时刻"
      if cause == .runtimeError {
        return "\(leg.displayName)在 \(timecode) 报告的采集运行错误尚未确认恢复，已停止自动重建；"
          + "已收到的录音与\(leg.preservedDescription)继续保留。"
      }
      return "\(leg.displayName)自 \(timecode) 起持续无新数据，自动重建未成功，已停止重试；"
        + "已保住 \(timecode) 前的内容与\(leg.preservedDescription)。"
    }
  }

  private func cleanUpCaptures(waitForMicrophone: Bool = true) async {
    if waitForMicrophone {
      do {
        try await microphoneCapture.stop()
      } catch {
        logger.warning("启动失败后的麦克风清理失败：\(error.localizedDescription, privacy: .public)")
      }
    }

    do {
      try await systemAudioCapture.stop()
    } catch {
      logger.warning("启动失败后的系统音频清理失败：\(error.localizedDescription, privacy: .public)")
    }
  }

  /// 真正的 start 放在独立任务；TaskGroup 只竞速可取消的结果信号与时钟。
  /// 若把 start 本身放进 group，离开 group 时仍会等待不响应取消的
  /// AVCaptureSession.startRunning，timeout 看似触发却依旧卡死。
  private func startMicrophoneWithTimeout(
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    bufferHandler: AudioPCMBufferHandler?,
    onStartStage: MicrophoneStartStageObserver?
  ) async throws {
    let (stream, signal) = AsyncStream<MicrophoneStartOutcome>.makeStream()
    let microphoneCapture = self.microphoneCapture
    guard let target = desiredMicrophoneTarget else {
      throw AudioCaptureError.microphoneUnavailable("麦克风目标尚未就绪")
    }
    let operation = reserveMicrophoneOperation(target: target, epoch: sessionEpochHostTime)
    let startTask = Task { @MainActor [weak self] in
      do {
        let binding = try await microphoneCapture.start(
          target: target,
          outputURL: outputURL,
          sessionEpochHostTime: sessionEpochHostTime,
          bufferHandler: bufferHandler,
          onStartStage: onStartStage
        )
        self?.finishMicrophoneOperation(operation, result: .success(binding))
        signal.yield(.completed(.success(())))
      } catch {
        self?.finishMicrophoneOperation(operation, result: .failure(error))
        signal.yield(.completed(.failure(error)))
      }
      signal.finish()
    }
    legRebuildTasks[.microphone] = startTask
    defer { signal.finish() }

    let timeoutNanoseconds = UInt64(
      max(0, healthPolicy.microphoneStartTimeout) * 1_000_000_000
    )
    let outcome = await withTaskGroup(
      of: MicrophoneStartOutcome.self,
      returning: MicrophoneStartOutcome.self
    ) { group in
      group.addTask {
        for await outcome in stream {
          return outcome
        }
        return .cancelled
      }
      group.addTask {
        do {
          try await Task.sleep(nanoseconds: timeoutNanoseconds)
        } catch {
          return .cancelled
        }
        return .timedOut
      }
      let first = await group.next() ?? .cancelled
      group.cancelAll()
      return first
    }

    switch outcome {
    case .completed(.success):
      return
    case .completed(.failure(let error)):
      throw error
    case .timedOut:
      microphoneCapture.cancelPendingStart()
      throw MicrophoneStartTimedOut()
    case .cancelled:
      throw CancellationError()
    }
  }

  private func startTranscription(
    language: MeetingLanguage,
    providers: [RoleProviderBinding],
    record: MeetingRecord
  ) async {
    do {
      let writer = try LiveTranscriptWriter(
        fileURL: record.paths.liveTranscript
      )
      liveTranscriptWriter = writer

      guard
        let binding = providers.first(where: {
          $0.role == .liveTranscriber
        })
      else {
        return
      }

      let engine = try transcriberFactory(binding.providerID)
      try await engine.start(language: language)
      transcriberEngine = engine
      transcriberResultsTask = Task { [weak self] in
        var firstError: Error?
        for await segment in engine.results {
          if Self.isLikelyNoiseHallucination(segment) {
            continue
          }
          do {
            try await writer.append(segment)
          } catch {
            firstError = firstError ?? error
          }
          self?.receive(segment)
        }
        return firstError
      }
    } catch {
      issue = RecordingSessionIssue(
        title: "本地速记不可用",
        message: "\(error.localizedDescription)\n\n双路录音仍会继续保存。",
        settingsDestination: nil
      )
      logger.error("本地速记启动失败：\(error.localizedDescription, privacy: .public)")
    }
  }

  private func stopTranscription() async -> Error? {
    let engine = transcriberEngine
    let resultsTask = transcriberResultsTask
    let writer = liveTranscriptWriter
    transcriberEngine = nil
    transcriberResultsTask = nil
    liveTranscriptWriter = nil

    await engine?.stop()
    if let statsProvider = engine as? any TranscriberASRAnchorGapFramesProviding {
      transcriberASRAnchorGapFrames = Dictionary(
        uniqueKeysWithValues: AudioSource.allCases.map { source in
          (source, statsProvider.asrAnchorGapFrames(for: source))
        }
      )
    }
    if let statsProvider = engine as? any TranscriberLiveEmissionStatsProviding {
      transcriberLiveEmissionStats = Dictionary(
        uniqueKeysWithValues: AudioSource.allCases.map { source in
          (source, statsProvider.liveEmissionStats(for: source))
        }
      )
    }
    var firstError: Error?
    if let resultsTask {
      firstError = await resultsTask.value
    }
    do {
      try await writer?.finish()
    } catch {
      firstError = firstError ?? error
    }
    return firstError
  }

  private func receive(_ segment: TranscriptSegment) {
    if segment.isFinal {
      liveSegments.removeAll {
        !$0.isFinal
          && $0.source == segment.source
          && Self.overlaps($0, segment)
      }
    } else {
      liveSegments.removeAll {
        !$0.isFinal && $0.source == segment.source
      }
    }

    liveSegments.append(segment)
    liveSegments.sort {
      if $0.t0 != $1.t0 {
        return $0.t0 < $1.t0
      }
      return $0.source.rawValue < $1.source.rawValue
    }
  }

  private static func overlaps(
    _ lhs: TranscriptSegment,
    _ rhs: TranscriptSegment
  ) -> Bool {
    lhs.t0 <= rhs.t1 && rhs.t0 <= lhs.t1
  }

  /// VAD 后的幻听保险层(2026-07-31 两轮实测):①对方声道舒适噪声曾幻听孤字;
  /// ②「我」声道纯零母带曾在旧定长切片下每 10 秒幻听「我.」×132。
  /// VAD 是当前主防线,这里只拦已经漏到结果侧的已知退化形态。
  /// 「我」侧只拦**退化形态**(单独的「我」/同字重复)——「嗯」「对」这类真实短应答
  /// 在「我」侧是有效表态,不拦;对方侧维持完整停用词表。母带录音不受影响。
  public nonisolated static func isLikelyNoiseHallucination(
    _ segment: TranscriptSegment
  ) -> Bool {
    guard segment.isFinal else {
      return false
    }
    let normalized = segment.text
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
    guard normalized.count <= 2 else {
      return false
    }
    if normalized.isEmpty {
      return true
    }
    if segment.source == .me {
      // 只拦实测出现过的退化形态(纯零母带下的「我.」):「嗯」「对」是真实表态。
      return normalized == "我" || normalized == "我我"
    }
    let stoplist: Set<String> = [
      "我", "嗯", "啊", "哦", "呃", "哈", "诶", "是", "对",
      "uh", "um", "mm", "ah", "oh", "eh", "so", "the", "you",
    ]
    return stoplist.contains(normalized) || Set(normalized).count == 1
  }

  /// 麦克风持续静音看门狗的累计器。纯零(RMS < 5e-5)只有数字静音才会出现——
  /// 正常房间的底噪都高于它;连续 30 秒纯零≈麦克风被通话应用独占(微信实战:
  /// 22 分钟零母带,用户散会才发现自己整场没被录进去)。触发一次横幅,录音继续。
  public final class SilenceWatchdogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var silentSeconds: Double = 0
    private var hasFired = false

    public init() {}

    /// 返回 true 表示本次跨过 30 秒阈值(只会返回一次)。
    public func track(rms: Float, seconds: Double) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if rms >= 0.000_05 {
        silentSeconds = 0
        return false
      }
      silentSeconds += seconds
      guard silentSeconds >= 30, !hasFired else {
        return false
      }
      hasFired = true
      return true
    }
  }

  /// RMS → 0~1 电平:-50dBFS 以下视为 0,0dBFS 为 1,线性映射。
  public nonisolated static func normalizedLevel(rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    let decibels = 20 * log10(rms)
    return max(0, min(1, (decibels + 50) / 50))
  }

  /// 电平发布节流(≤10Hz):采集线程只做一次时间比较,不给音频路加负担。
  final class LevelPublishThrottleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPublishUptime: TimeInterval = 0

    func shouldPublish(minimumInterval: TimeInterval = 0.1) -> Bool {
      let now = ProcessInfo.processInfo.systemUptime
      lock.lock()
      defer { lock.unlock() }
      guard now - lastPublishUptime >= minimumInterval else {
        return false
      }
      lastPublishUptime = now
      return true
    }
  }

  public nonisolated static func bufferRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard
      let channelData = buffer.floatChannelData,
      buffer.frameLength > 0
    else {
      return 0
    }
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    var sum: Float = 0
    if buffer.format.isInterleaved {
      for index in 0..<(frames * channels) {
        let value = channelData[0][index]
        sum += value * value
      }
    } else {
      for channel in 0..<channels {
        let samples = channelData[channel]
        for index in 0..<frames {
          let value = samples[index]
          sum += value * value
        }
      }
    }
    let total = frames * channels
    return total > 0 ? (sum / Float(total)).squareRoot() : 0
  }

  private static func makeTranscriptionHandler(
    engine: (any TranscriberEngine)?,
    source: AudioSource,
    logger: Logger
  ) -> AudioPCMBufferHandler? {
    guard let engine else {
      return nil
    }
    return { buffer, captureTime in
      do {
        try engine.feed(buffer, source: source, at: captureTime)
      } catch {
        logger.error(
          "\(source.rawValue, privacy: .public) 速记输入失败：\(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  private func markFailed(record: MeetingRecord) {
    do {
      currentRecord = try store.updateStatus(
        .failed,
        endedAt: Date(),
        captureLossStats: captureLossStats,
        for: record
      )
    } catch {
      logger.error("meeting.json 失败状态写入失败：\(error.localizedDescription, privacy: .public)")
    }
  }

  /// 把单路 stop 错误换算成 `CaptureLegFailure`:首错时刻来自 capture 的
  /// `firstCaptureFailure`(会中记账),减去 startedAt 得「会议第几秒」;
  /// 错误只在 stop 阶段才暴露(无会中时刻)时起点为 nil,不编造时刻。
  private func makeLegFailures(
    microphoneError: Error?,
    systemAudioError: Error?,
    startedAt: Date
  ) -> [CaptureLegFailure] {
    var failures: [CaptureLegFailure] = []
    if let microphoneError {
      failures.append(
        Self.makeLegFailure(
          leg: .microphone,
          error: microphoneError,
          firstFailureAt: microphoneCapture.firstCaptureFailure?.at,
          startedAt: startedAt
        )
      )
    }
    if let systemAudioError {
      failures.append(
        Self.makeLegFailure(
          leg: .systemAudio,
          error: systemAudioError,
          firstFailureAt: systemAudioCapture.firstCaptureFailure?.at,
          startedAt: startedAt
        )
      )
    }
    return failures
  }

  private static func makeLegFailure(
    leg: CaptureLegFailure.Leg,
    error: Error,
    firstFailureAt: Date?,
    startedAt: Date
  ) -> CaptureLegFailure {
    let seconds = firstFailureAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    let message =
      (error as? AudioCaptureError)?.errorDescription ?? error.localizedDescription
    return CaptureLegFailure(
      leg: leg,
      firstFailureSecondsIntoMeeting: seconds,
      message: message
    )
  }

  /// 部分完成横幅的文案红线:必须说清「哪路自何时起缺失」与「保住了什么」,
  /// 不做任何未经证实的归因(08-05 事故里的「独占设备」文案教训)。
  public nonisolated static func makePartialCaptureNotice(
    _ failure: CaptureLegFailure
  ) -> String {
    "\(failure.missingDescription)，已保住\(failure.preservedLegDescription)；"
      + "纪要将基于可用的一路生成。"
  }

  private var captureLossStats: MeetingCaptureLossStats {
    var microphone = microphoneCapture.captureLossStats
    var systemAudio = systemAudioCapture.captureLossStats
    microphone.asrAnchorGapFrames = transcriberASRAnchorGapFrames[.me]
    systemAudio.asrAnchorGapFrames = transcriberASRAnchorGapFrames[.others]
    if let me = transcriberLiveEmissionStats[.me] {
      microphone.livePartialsEmitted = me.partialsEmitted
      microphone.livePartialsSkipped = me.partialsSkipped
      microphone.liveFinalsEmitted = me.finalsEmitted
    }
    if let others = transcriberLiveEmissionStats[.others] {
      systemAudio.livePartialsEmitted = others.partialsEmitted
      systemAudio.livePartialsSkipped = others.partialsSkipped
      systemAudio.liveFinalsEmitted = others.finalsEmitted
    }
    return MeetingCaptureLossStats(
      microphone: microphone,
      systemAudio: systemAudio
    )
  }

  private static func makeIssue(
    _ error: Error,
    action: String
  ) -> RecordingSessionIssue {
    if let captureError = error as? AudioCaptureError {
      let description = captureError.errorDescription ?? error.localizedDescription
      let message =
        if let recovery = captureError.recoverySuggestion {
          "\(description)\n\n\(recovery)"
        } else {
          description
        }
      return RecordingSessionIssue(
        title: "\(action)失败",
        message: message,
        settingsDestination: captureError.settingsDestination
      )
    }

    return RecordingSessionIssue(
      title: "\(action)失败",
      message: "\(error.localizedDescription)\n\n已有可用录音片段会保留在会议目录。",
      settingsDestination: nil
    )
  }
}
