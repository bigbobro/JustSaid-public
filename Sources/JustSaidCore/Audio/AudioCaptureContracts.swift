import AVFAudio
import CoreAudio
import Darwin
import Foundation

public enum AudioCaptureClock {
  private static let timebase: mach_timebase_info_data_t = {
    var value = mach_timebase_info_data_t()
    mach_timebase_info(&value)
    return value
  }()

  public static func nowHostTime() -> UInt64 {
    mach_absolute_time()
  }

  public static func secondsSinceEpoch(
    hostTime: UInt64,
    epochHostTime: UInt64
  ) -> TimeInterval {
    secondsSinceEpoch(
      hostTime: hostTime,
      epochHostTime: epochHostTime,
      timebaseNumerator: timebase.numer,
      timebaseDenominator: timebase.denom
    )
  }

  static func secondsSinceEpoch(
    hostTime: UInt64,
    epochHostTime: UInt64,
    timebaseNumerator: UInt32,
    timebaseDenominator: UInt32
  ) -> TimeInterval {
    let deltaTicks: UInt64
    let sign: Double
    if hostTime >= epochHostTime {
      deltaTicks = hostTime - epochHostTime
      sign = 1
    } else {
      deltaTicks = epochHostTime - hostTime
      sign = -1
    }
    return sign * Double(deltaTicks) * Double(timebaseNumerator)
      / Double(timebaseDenominator) / 1_000_000_000
  }
}

public struct CaptureLossStats: Codable, Equatable, Sendable {
  public var capturedFrames: UInt64
  public var writtenFrames: UInt64
  public var gapFrames: UInt64
  public var droppedByBackpressure: UInt64
  public var droppedByOverload: UInt64
  public var droppedOutOfOrder: UInt64
  public var asrFedFrames: UInt64
  public var asrSkippedFrames: UInt64
  public var asrAnchorGapFrames: UInt64?
  /// 会中实时转写发射统计(可选:旧会议与无速记会议为 nil)。
  public var livePartialsEmitted: UInt64?
  public var livePartialsSkipped: UInt64?
  public var liveFinalsEmitted: UInt64?

  public init(
    capturedFrames: UInt64 = 0,
    writtenFrames: UInt64 = 0,
    gapFrames: UInt64 = 0,
    droppedByBackpressure: UInt64 = 0,
    droppedByOverload: UInt64 = 0,
    droppedOutOfOrder: UInt64 = 0,
    asrFedFrames: UInt64 = 0,
    asrSkippedFrames: UInt64 = 0,
    asrAnchorGapFrames: UInt64? = nil,
    livePartialsEmitted: UInt64? = nil,
    livePartialsSkipped: UInt64? = nil,
    liveFinalsEmitted: UInt64? = nil
  ) {
    self.capturedFrames = capturedFrames
    self.writtenFrames = writtenFrames
    self.gapFrames = gapFrames
    self.droppedByBackpressure = droppedByBackpressure
    self.droppedByOverload = droppedByOverload
    self.droppedOutOfOrder = droppedOutOfOrder
    self.asrFedFrames = asrFedFrames
    self.asrSkippedFrames = asrSkippedFrames
    self.asrAnchorGapFrames = asrAnchorGapFrames
    self.livePartialsEmitted = livePartialsEmitted
    self.livePartialsSkipped = livePartialsSkipped
    self.liveFinalsEmitted = liveFinalsEmitted
  }

  var logDescription: String {
    "capturedFrames=\(capturedFrames) writtenFrames=\(writtenFrames) "
      + "gapFrames=\(gapFrames) droppedByBackpressure=\(droppedByBackpressure) "
      + "droppedByOverload=\(droppedByOverload) "
      + "droppedOutOfOrder=\(droppedOutOfOrder) asrFedFrames=\(asrFedFrames) "
      + "asrSkippedFrames=\(asrSkippedFrames)"
  }
}

final class CaptureLossStatsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stats = CaptureLossStats()

  func reset() {
    lock.lock()
    stats = CaptureLossStats()
    lock.unlock()
  }

  func snapshot() -> CaptureLossStats {
    lock.lock()
    defer { lock.unlock() }
    return stats
  }

  func recordCapturedFrames(_ count: UInt64) {
    mutate { $0.capturedFrames += count }
  }

  func recordWrittenFrames(_ count: UInt64) {
    mutate { $0.writtenFrames += count }
  }

  func recordGapFrames(_ count: UInt64) {
    mutate { $0.gapFrames += count }
  }

  func recordBackpressureDrop() {
    mutate { $0.droppedByBackpressure += 1 }
  }

  func recordOverloadDrop(skippedFrames: UInt64) {
    mutate {
      $0.droppedByOverload += 1
      $0.asrSkippedFrames += skippedFrames
    }
  }

  func recordOutOfOrderDrop() {
    mutate { $0.droppedOutOfOrder += 1 }
  }

  func recordASRFedFrames(_ count: UInt64) {
    mutate { $0.asrFedFrames += count }
  }

  private func mutate(_ mutation: (inout CaptureLossStats) -> Void) {
    lock.lock()
    mutation(&stats)
    lock.unlock()
  }
}

final class BoundedCaptureProcessingQueue: @unchecked Sendable {
  private static let maximumPendingDuration: TimeInterval = 5

  private let queue: DispatchQueue
  private let maximumPendingFrames: UInt64
  private let lock = NSLock()
  private var pendingFrames: UInt64 = 0
  private var isAccepting = true
  private var isCancelled = false

  init(label: String, sampleRate: Double) {
    queue = DispatchQueue(label: label, qos: .userInitiated)
    maximumPendingFrames = UInt64(
      (sampleRate * Self.maximumPendingDuration).rounded()
    )
  }

  func submit(
    frameCount: UInt64,
    work: @escaping @Sendable () -> Void
  ) -> Bool {
    lock.lock()
    guard
      isAccepting,
      !isCancelled,
      frameCount <= maximumPendingFrames,
      pendingFrames <= maximumPendingFrames - frameCount
    else {
      lock.unlock()
      return false
    }
    pendingFrames += frameCount
    queue.async { [self] in
      defer { complete(frameCount: frameCount) }
      lock.lock()
      let shouldRun = !isCancelled
      lock.unlock()
      if shouldRun {
        work()
      }
    }
    lock.unlock()
    return true
  }

  func finishAcceptingAndDrain() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      isAccepting = false
      queue.async {
        continuation.resume()
      }
      lock.unlock()
    }
  }

  func cancel() {
    lock.lock()
    isAccepting = false
    isCancelled = true
    lock.unlock()
  }

  private func complete(frameCount: UInt64) {
    lock.lock()
    pendingFrames -= frameCount
    lock.unlock()
  }

}

public typealias AudioPCMBufferHandler =
  @Sendable (
    AVAudioPCMBuffer,
    TimeInterval
  ) -> Void

public protocol SystemAudioCapturing: AnyObject, Sendable {
  var captureLossStats: CaptureLossStats { get }
  /// 本场首次采集失败的错误与发生时刻;无失败为 nil。
  /// stop 收尾用它换算「缺失从会议第几秒开始」,写进部分完成语义。
  var firstCaptureFailure: (error: any Error, at: Date)? { get }
  func start(
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    processIDs: [pid_t]?,
    bufferHandler: AudioPCMBufferHandler?
  ) async throws
  func stop() async throws
  /// 自愈原语(08-05 单路故障当场提示与自愈):重建采集链路,
  /// **writer/处理队列/统计保持不动**,新样本仍按 session epoch 锚定。
  /// 由会话层健康监测驱动;不支持自愈的实现走默认抛错,由重试上限兜底。
  func rebuild() async throws
}

/// 麦克风启动子阶段(08-20 失败可自证单;design §2.1 已拍板方案 A:启动契约不变,
/// firstFrame 不进失败卡点清单——`start()` 在 `startRunning()` 返回后即完成,
/// 失败轨迹里首帧不可能出现)。
///
/// **完成语义**:每个 case 在对应步骤返回后上报;失败记录里最后一个已上报子阶段
/// 的下一步即卡点。四段固定:queueEntry → resolveDevice → route → startRunning。
public enum MicrophoneStartStage: String, Sendable, Equatable {
  /// captureQueue 真正开始执行(零子阶段到达 = 队列本身被楔住,
  /// 与 permission/解析卡死可区分)。
  case queueEntry = "mic.queueEntry"
  /// 路由决策落定(按已解析的目标设备判断 HFP);
  /// detail 携带路由与 `fallbackReason`。
  case route = "mic.route"
  /// 本次固定目标的 HAL UID 与 AVCapture 身份核对完成;detail 携带设备名。
  case resolveDevice = "mic.resolveDevice"
  /// 输入启动返回且实际设备已核对。
  case startRunning = "mic.startRunning"
}

/// 启动子阶段回调:在采集内部队列上同步调用。**可能晚于启动失败到达**——
/// 迟到上报要继续收(「startRunning 12.3s 才返回」与「永不返回」是不同的诊断结论),
/// 因此回调以 `start()` 形参注入,天然绑定本次启动的世代。
public typealias MicrophoneStartStageObserver =
  @Sendable (MicrophoneStartStage, String?) -> Void

/// A current AVCapture runtime fault, independent of the meeting's historical first error.
/// The session consumes this identity only after a matching rebuild and qualifying new frames.
public struct MicrophoneRuntimeRecoveryRequest: Equatable, Sendable {
  public let generation: UInt
  public let observedAt: Date
}

/// One coherent health read: the latest fault plus its matching successful replacement.
/// The retained identity prevents duplicate notifications from reopening a consumed episode.
public struct MicrophoneRuntimeRecoverySnapshot: Sendable {
  public let request: MicrophoneRuntimeRecoveryRequest
  public let rebuiltAt: Date?
  public let framesAtRebuild: UInt64?
  public let capturedFrames: UInt64
}

/// Stable CoreAudio identity. AVCapture's uniqueID is checked separately at each attempt.
public struct MicrophoneDeviceUID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct MicrophoneCaptureDeviceID: RawRepresentable, Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public enum MicrophoneInputPreference: Codable, Equatable, Sendable {
  case automatic
  case device(uid: MicrophoneDeviceUID, name: String?)
}

/// A read-only directory entry; presence does not establish a running capture binding.
public struct MicrophoneInputDevice: Equatable, Sendable, Identifiable {
  public let uid: MicrophoneDeviceUID
  public let captureID: MicrophoneCaptureDeviceID?
  public let objectID: UInt32
  public let name: String
  public let summary: AudioInputDeviceSummary
  public var incarnation: UInt64
  public var id: MicrophoneDeviceUID { uid }

  public init(
    uid: MicrophoneDeviceUID, captureID: MicrophoneCaptureDeviceID?, objectID: UInt32,
    name: String, summary: AudioInputDeviceSummary = AudioInputDeviceSummary(),
    incarnation: UInt64 = 0
  ) {
    self.uid = uid
    self.captureID = captureID
    self.objectID = objectID
    self.name = name
    self.summary = summary
    self.incarnation = incarnation
  }

  public func isSameEndpoint(as other: MicrophoneInputDevice) -> Bool {
    uid == other.uid && incarnation == other.incarnation
  }
}

public struct MicrophoneInputDirectorySnapshot: Equatable, Sendable {
  public var devices: [MicrophoneInputDevice]
  public var defaultInputUID: MicrophoneDeviceUID?
  public var queryFailure: String?

  public init(
    devices: [MicrophoneInputDevice] = [], defaultInputUID: MicrophoneDeviceUID? = nil,
    queryFailure: String? = nil
  ) {
    self.devices = devices
    self.defaultInputUID = defaultInputUID
    self.queryFailure = queryFailure
  }
}

public struct MicrophoneInputTarget: Equatable, Sendable {
  public let device: MicrophoneInputDevice
  public let revision: UInt64
  public let fallbackReason: String?

  public init(device: MicrophoneInputDevice, revision: UInt64 = 0, fallbackReason: String? = nil) {
    self.device = device
    self.revision = revision
    self.fallbackReason = fallbackReason
  }
}

/// Only returned after the current attempt has confirmed its running endpoint.
public struct MicrophoneInputBinding: Equatable, Sendable {
  public let device: MicrophoneInputDevice
  public let route: MicrophoneCaptureRoutePlanner.Route
  public let generation: UInt64
  public let processingFallbackReason: String?

  public init(
    device: MicrophoneInputDevice, route: MicrophoneCaptureRoutePlanner.Route,
    generation: UInt64, processingFallbackReason: String? = nil
  ) {
    self.device = device
    self.route = route
    self.generation = generation
    self.processingFallbackReason = processingFallbackReason
  }
}

public enum MicrophoneInputStatus: Equatable, Sendable {
  case idle(target: MicrophoneInputTarget)
  case pending(target: MicrophoneInputTarget)
  case active(binding: MicrophoneInputBinding, fallbackReason: String?)
  case unready(reason: String)

  public var text: String {
    switch self {
    case .idle(let target): return "开录将使用：\(target.device.name)"
    case .pending(let target): return "正在切换：\(target.device.name)"
    case .active(let binding, _): return "当前使用：\(binding.device.name)"
    case .unready: return "麦克风未就绪"
    }
  }

  public var notice: String? {
    switch self {
    case .idle(let target): return target.fallbackReason
    case .pending(let target): return "正在切换至\(target.device.name)，实际输入尚未确认。"
    case .active(let binding, let fallback):
      let reasons = [fallback, binding.processingFallbackReason].compactMap { $0 }
      return reasons.isEmpty ? nil : "当前使用：\(binding.device.name)。" + reasons.joined(separator: "；")
    case .unready(let reason): return reason
    }
  }
}

public protocol MicrophoneAudioCapturing: AnyObject, Sendable {
  var runtimeRecoverySnapshot: MicrophoneRuntimeRecoverySnapshot? { get }
  var captureLossStats: CaptureLossStats { get }
  /// 当前采集路径描述：`VPIO` / `AVCaptureSession`；未启动时为 nil。
  var activeCaptureRouteDescription: String? { get }
  /// 本场首次采集失败的错误与发生时刻;无失败为 nil。语义同 `SystemAudioCapturing`。
  var firstCaptureFailure: (error: any Error, at: Date)? { get }
  func requestPermission() async throws
  /// 启动采集并上报子阶段。`onStartStage` 走 **required 签名**而非 extension 默认
  /// no-op(08-20 评审:extension 默认实现与 `SummaryFeed.postMeetingDirectory`
  /// 是同一种静默死法——真实实现掉线,断言全跑替身照样全绿)。
  /// 替身漏接该形参直接编译失败。
  func start(
    target: MicrophoneInputTarget,
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    bufferHandler: AudioPCMBufferHandler?,
    onStartStage: MicrophoneStartStageObserver?
  ) async throws -> MicrophoneInputBinding
  /// 启动超时后同步让当前 start 世代失效，并把半启动资源收尾排到后台。
  /// 不能只依赖 Task.cancel：AVCaptureSession.startRunning 可能长期不响应取消。
  func cancelPendingStart()
  /// 只暂停麦克风内容：采集时钟继续推进，母带写等长静音，实时 ASR 不收该区间。
  /// `captureTime` 与 `bufferHandler` 的会议时间轴同轴。
  func setPaused(_ paused: Bool, at captureTime: TimeInterval)
  func stop() async throws
  /// 自愈原语,语义同 `SystemAudioCapturing.rebuild()`;
  /// 麦克风实现必须重走既有 VPIO→AVCaptureSession 路由决策,不得新造路径。
  func rebuild(target: MicrophoneInputTarget) async throws -> MicrophoneInputBinding
}

/// 「麦克风回声消除」开关。**默认关**;键缺失时视为 false。
/// 2026-08-13 改判:VPIO 会重协商共享输入流拓扑,线上会议 App 先协商好的输入流
/// 可能被错位(对方听不到用户),偿还 08-05 护栏单"修复合入前不得默认打开 AEC"欠债。
/// 用户显式设置过的键(true/false)一律尊重,不迁移。
public enum MicrophoneAECSettings {
  public static let defaultsKey = "justsaid.microphone.aecEnabled"

  public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
    guard defaults.object(forKey: defaultsKey) != nil else {
      return false
    }
    return defaults.bool(forKey: defaultsKey)
  }

  public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: defaultsKey)
  }
}

/// 麦克风采集路径规划：VPIO（AEC）优先，失败/关闭/蓝牙 HFP 回落 AVCaptureSession。
public enum MicrophoneCaptureRoutePlanner {
  public enum Route: String, Sendable, Equatable {
    case vpio = "VPIO"
    case avCaptureSession = "AVCaptureSession"
  }

  /// 是否尝试 VPIO。真正启动仍可能因初始化失败而回落。
  public static func preferredRoute(
    aecEnabled: Bool,
    isBluetoothHFPInput: Bool
  ) -> Route {
    if aecEnabled && !isBluetoothHFPInput {
      return .vpio
    }
    return .avCaptureSession
  }

  /// 与 AECProbe spike 一致：Bluetooth / Bluetooth-LE 且有输入声道才判 HFP。
  public static func isBluetoothHFPInput(
    transportType: UInt32,
    inputChannelCount: UInt32
  ) -> Bool {
    inputChannelCount > 0
      && (transportType == kAudioDeviceTransportTypeBluetooth
        || transportType == kAudioDeviceTransportTypeBluetoothLE)
  }

  public static func fallbackReason(
    aecEnabled: Bool,
    isBluetoothHFPInput: Bool
  ) -> String? {
    if !aecEnabled {
      return "麦克风回声消除开关关闭"
    }
    if isBluetoothHFPInput {
      return "检测到蓝牙 HFP 输入"
    }
    return nil
  }
}

extension SystemAudioCapturing {
  public var captureLossStats: CaptureLossStats {
    CaptureLossStats()
  }

  public var firstCaptureFailure: (error: any Error, at: Date)? {
    nil
  }

  public func start(
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    processIDs: [pid_t]?
  ) async throws {
    try await start(
      outputURL: outputURL,
      sessionEpochHostTime: sessionEpochHostTime,
      processIDs: processIDs,
      bufferHandler: nil
    )
  }

  public func rebuild() async throws {
    throw AudioCaptureError.audioWriteFailed("该系统音频采集实现不支持在线重建")
  }
}

extension MicrophoneAudioCapturing {
  public var runtimeRecoverySnapshot: MicrophoneRuntimeRecoverySnapshot? { nil }

  public var captureLossStats: CaptureLossStats {
    CaptureLossStats()
  }

  public var activeCaptureRouteDescription: String? {
    nil
  }

  public var firstCaptureFailure: (error: any Error, at: Date)? {
    nil
  }

  public func start(
    outputURL: URL,
    sessionEpochHostTime: UInt64
  ) async throws {
    try await start(
      outputURL: outputURL,
      sessionEpochHostTime: sessionEpochHostTime,
      bufferHandler: nil
    )
  }

  /// 便捷重载(非 required 成员的默认 no-op——required 的是带 `onStartStage`
  /// 的完整签名,漏实现编译不过;这里只是转发)。
  public func start(
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    bufferHandler: AudioPCMBufferHandler?
  ) async throws {
    try await start(
      outputURL: outputURL,
      sessionEpochHostTime: sessionEpochHostTime,
      bufferHandler: bufferHandler,
      onStartStage: nil
    )
  }

  public func start(
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    bufferHandler: AudioPCMBufferHandler?,
    onStartStage: MicrophoneStartStageObserver?
  ) async throws {
    let target = try AudioInputDeviceMonitor.automaticTarget()
    _ = try await start(
      target: target, outputURL: outputURL, sessionEpochHostTime: sessionEpochHostTime,
      bufferHandler: bufferHandler, onStartStage: onStartStage
    )
  }

  public func cancelPendingStart() {
    Task { [self] in
      try? await stop()
    }
  }

  public func rebuild() async throws {
    _ = try await rebuild(target: AudioInputDeviceMonitor.automaticTarget())
  }
}

public enum RecordingSettingsDestination: Equatable, Sendable {
  case microphone
  case systemAudio
}

public enum AudioCaptureError: LocalizedError {
  case microphonePermissionDenied
  case microphonePermissionRestricted
  case microphoneUnavailable(String)
  case systemAudioProcessUnavailable(pid_t)
  case systemAudioTapFailed(operation: String, status: OSStatus)
  case audioWriteFailed(String)

  public var errorDescription: String? {
    switch self {
    case .microphonePermissionDenied:
      return "麦克风权限已被拒绝"
    case .microphonePermissionRestricted:
      return "这台 Mac 不允许 JustSaid 使用麦克风"
    case .microphoneUnavailable(let detail):
      return "麦克风采集启动失败：\(detail)"
    case .systemAudioProcessUnavailable(let processID):
      return "找不到进程 \(processID) 的可采集音频对象"
    case .systemAudioTapFailed(let operation, let status):
      return "系统音频采集在“\(operation)”时失败（Core Audio \(status)）"
    case .audioWriteFailed(let detail):
      return "录音文件写入失败：\(detail)"
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .microphonePermissionDenied, .microphonePermissionRestricted:
      return "请到“系统设置 > 隐私与安全性 > 麦克风”允许 JustSaid 访问。"
    case .systemAudioProcessUnavailable:
      return "请确认目标会议应用仍在运行并正在播放音频，或改用默认的全局系统音频采集。"
    case .systemAudioTapFailed:
      return
        "请到“系统设置 > 隐私与安全性 > 屏幕与系统音频录制”允许 JustSaid。"
        + "若 Core Audio process tap 仍不可用，可切换 ScreenCaptureKit 路线；"
        + "本版本仅提示该路线，尚未实现。"
    // 08-05 事故教训:旧文案「请结束其他独占音频设备的应用」是未经证实的归因,
    // 真实根因(VPIO 挤开 tap 流)与设备独占无关。只说确知的事实,不猜原因。
    case .microphoneUnavailable, .audioWriteFailed:
      return "录音通道数据出现异常；已捕获的可用录音会保留在会议目录。"
    }
  }

  public var settingsDestination: RecordingSettingsDestination? {
    switch self {
    case .microphonePermissionDenied, .microphonePermissionRestricted:
      return .microphone
    case .systemAudioTapFailed:
      return .systemAudio
    case .microphoneUnavailable, .systemAudioProcessUnavailable, .audioWriteFailed:
      return nil
    }
  }
}

final class CaptureFailureBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?
  private var storedFirstFailure: (error: any Error, at: Date)?

  @discardableResult
  func record(_ error: Error) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard storedError == nil else {
      return false
    }
    storedError = error
    if storedFirstFailure == nil {
      storedFirstFailure = (error, Date())
    }
    return true
  }

  /// 只取走待抛错误;首错时刻保留,供 stop 收尾把「缺失起点」写进 meeting.json。
  func take() -> Error? {
    lock.lock()
    defer { lock.unlock() }
    let error = storedError
    storedError = nil
    return error
  }

  /// 首次失败的错误与发生时刻;新一场开录前由 `reset()` 清空。
  var firstFailure: (error: any Error, at: Date)? {
    lock.lock()
    defer { lock.unlock() }
    return storedFirstFailure
  }

  /// 开录时清场:待抛错误与首错时刻一起清零,避免上一场的失败串到本场。
  func reset() {
    lock.lock()
    storedError = nil
    storedFirstFailure = nil
    lock.unlock()
  }
}

/// >2 声道输入降混为立体声(2026-07-31 实测:微信语音通话时输入设备呈多声道,
/// 写入器按契约只收 1-2 声道,开始录音直接失败——真实会议硬阻断)。优先使用
/// `kAudioDevicePropertyPreferredChannelsForStereo` 指定的设备声道;属性不可用或越界时
/// 才全声道平均兜底。采样率不变;写入与喂引擎共用降混后的同一份缓冲。
/// 1-2 声道输入返回 nil(维持原样直通,零开销)。
public final class PCMStereoDownmixer {
  private let converter: AVAudioConverter
  private let preferredChannelIndexes: [Int]?
  public let outputFormat: AVAudioFormat
  public let selectedChannels: [UInt32]?

  public init?(
    inputFormat: AVAudioFormat,
    preferredChannels: [UInt32]? = nil
  ) {
    guard
      inputFormat.channelCount > 2,
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputFormat.sampleRate,
        channels: 2,
        interleaved: false
      ),
      let converter = AVAudioConverter(from: inputFormat, to: target)
    else {
      return nil
    }
    self.converter = converter
    self.outputFormat = target
    if let preferredChannels,
      preferredChannels.count == 2,
      preferredChannels.allSatisfy({
        $0 >= 1 && $0 <= inputFormat.channelCount
      })
    {
      // Core Audio 的设备声道号从 1 开始,AVAudioPCMBuffer 数组从 0 开始。
      selectedChannels = preferredChannels
      preferredChannelIndexes = preferredChannels.map { Int($0 - 1) }
      converter.channelMap = preferredChannels.map {
        NSNumber(value: Int($0 - 1))
      }
    } else {
      selectedChannels = nil
      preferredChannelIndexes = nil
    }
  }

  static func preferredChannels(
    for deviceID: AudioDeviceID,
    scope: AudioObjectPropertyScope
  ) -> [UInt32]? {
    guard deviceID != kAudioObjectUnknown else { return nil }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else {
      return nil
    }

    var pair = (UInt32(0), UInt32(0))
    var size = UInt32(MemoryLayout.size(ofValue: pair))
    let status = withUnsafeMutablePointer(to: &pair) { pointer in
      AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &size,
        pointer
      )
    }
    guard status == noErr, size == MemoryLayout.size(ofValue: pair) else {
      return nil
    }
    return [pair.0, pair.1]
  }

  public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard
      let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: max(1, buffer.frameLength)
      )
    else {
      return nil
    }
    // 首选设备明确标出的立体声声道。拿不到设备属性才全声道平均兜底;兜底对
    // "信号在哪排"零假设,但单路信号会被 1/N 衰减,不能再当主路径。
    if buffer.format.commonFormat == .pcmFormatFloat32,
      let inputData = buffer.floatChannelData,
      let outputData = output.floatChannelData
    {
      let frames = Int(buffer.frameLength)
      let channels = Int(buffer.format.channelCount)
      if buffer.format.isInterleaved {
        let samples = inputData[0]
        for frame in 0..<frames {
          let frameOffset = frame * channels
          if let preferredChannelIndexes {
            outputData[0][frame] =
              samples[
                frameOffset + preferredChannelIndexes[0]
              ]
            outputData[1][frame] =
              samples[
                frameOffset + preferredChannelIndexes[1]
              ]
          } else {
            var sum: Float = 0
            for channel in 0..<channels {
              sum += samples[frameOffset + channel]
            }
            let mixed = sum / Float(channels)
            outputData[0][frame] = mixed
            outputData[1][frame] = mixed
          }
        }
      } else {
        if let preferredChannelIndexes {
          let left = inputData[preferredChannelIndexes[0]]
          let right = inputData[preferredChannelIndexes[1]]
          for frame in 0..<frames {
            outputData[0][frame] = left[frame]
            outputData[1][frame] = right[frame]
          }
        } else {
          let scale = 1.0 / Float(channels)
          for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
              sum += inputData[channel][frame]
            }
            let mixed = sum * scale
            outputData[0][frame] = mixed
            outputData[1][frame] = mixed
          }
        }
      }
      output.frameLength = buffer.frameLength
      return output
    }

    // 退路:交给系统转换器;但若输入明明有信号、输出却纯零,按失败处理——
    // "静音地成功"比报错更危险(纯零母带无法事后挽救)。
    // 降混不改采样率,所以走无输入块的简单转换:没有 Sendable 回调要捕获输入缓冲,
    // 缓冲仍归调用方,转换后还能拿它做静音校验。
    do {
      try converter.convert(to: output, from: buffer)
    } catch {
      return nil
    }
    if Self.quickRMS(buffer) > 0.001, Self.quickRMS(output) < 0.000_01 {
      return nil
    }
    return output
  }

  private static func quickRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else {
      return 0
    }
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    var sum: Float = 0
    if buffer.format.isInterleaved {
      for index in 0..<(frames * channels) {
        let value = data[0][index]
        sum += value * value
      }
    } else {
      for channel in 0..<channels {
        for frame in 0..<frames {
          let value = data[channel][frame]
          sum += value * value
        }
      }
    }
    let total = frames * channels
    return total > 0 ? (sum / Float(total)).squareRoot() : 0
  }
}
