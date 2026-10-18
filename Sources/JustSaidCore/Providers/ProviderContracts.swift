import AVFAudio
import Foundation

public enum AudioSource: String, Codable, CaseIterable, Hashable, Sendable {
  case me
  case others
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
  public let t0: TimeInterval
  public let t1: TimeInterval
  public let text: String
  public let isFinal: Bool
  public let source: AudioSource

  public init(
    t0: TimeInterval,
    t1: TimeInterval,
    text: String,
    isFinal: Bool,
    source: AudioSource
  ) {
    self.t0 = t0
    self.t1 = t1
    self.text = text
    self.isFinal = isFinal
    self.source = source
  }
}

public protocol TranscriberEngine: AnyObject, Sendable {
  var results: AsyncStream<TranscriptSegment> { get }
  /// True only when input and decode ranges use the session captureTime clock.
  /// Optional microphone processing may hold buffers without moving those anchors.
  var usesCaptureTime: Bool { get }

  /// 传的是用户在工具栏选的**语言意图**,不是 locale 字符串(08-10 实证:
  /// `.auto` 与 `.chinese` 的 `transcriptionLocaleIdentifier` 都是 `"zh-CN"`,
  /// 只传 locale 的话引擎分不出「自动」和「锁中文」)。各引擎自行把意图翻成自己那套参数:
  /// Apple 取 locale,Qwen 取 stream option,SenseVoice 取语言 token。
  func start(language: MeetingLanguage) async throws
  func feed(
    _ pcmBuffer: AVAudioPCMBuffer,
    source: AudioSource,
    at captureTime: TimeInterval
  ) throws
  func stop() async
}

extension TranscriberEngine {
  public var usesCaptureTime: Bool { false }
}

/// 会中切换识别语种(owner 2026-10-16 定)。只有能不重启引擎、不动音频链路就换语种的引擎
/// 才实现:Qwen 的 language 是每段 stream 的 option。SenseVoice 的语言 token 与 Apple 的
/// locale 在开录时就定了,不实现,会中改语言对它们仍只写下一场的偏好。
public protocol LiveLanguageSwitching: Sendable {
  /// 从下一段新建的解码起生效;正在解码的那一段按旧语种出结果。
  func switchLanguage(to language: MeetingLanguage)
}

/// 会中引擎运行中发生、调用方要当场知道的事。目前只有 Pro 模式的回退(PR-07)。
public enum LiveEngineEvent: Equatable, Sendable {
  /// GPU 真出错(ERR_BACKEND / ERR_OOM),或开录后 1.7B 没能装好(加载或预热出错),本场改用标准识别继续。
  /// 在失败那一刻送出,不等热备把那一段重解完;每场至多一次。输入被拒、静音与短段都不算。
  /// `callIndex`:第几次 GPU 调用(从 1 起,不含预热);0 = 开录后 1.7B 没能装好。
  /// `at`:送出时刻,`DispatchTime.now().uptimeNanoseconds`(与解码观察导出同一时钟)。
  case fellBackToStandard(callIndex: Int, at: UInt64)
}

/// 能送出 `LiveEngineEvent` 的会中引擎。
public protocol LiveEngineEventProviding: Sendable {
  /// 单一消费方。引擎建好就有、无界缓冲,start 前后读都不丢;引擎 `stop()` 返回前结束。
  var engineEvents: AsyncStream<LiveEngineEvent> { get }
}

/// 一场会中速记实际用了什么。停止后读;停止前读到的是截至当时的状态。
public struct TranscriberLiveEngineReport: Codable, Equatable, Sendable {
  /// 本场选用的模型,清单资产 ID:`qwen3-asr-1.7b-q8-gguf`(Pro;开录头几秒、装好之前由 0.6B 出字)
  /// 或 `qwen3-asr-0.6b-int8`(标准)。
  public let modelAssetID: String
  /// 会中改用了标准识别(GPU 真出错,或开录后 1.7B 没能装好)。
  public let fellBack: Bool
  /// 回退发生在第几次 GPU 调用(从 1 起,不含预热);0 = 开录后没能装好;没回退为 nil。
  public let fallbackCallIndex: Int?
  /// ggml 设备名(如 `MTL0`);标准识别或读不到为 nil。
  public let deviceName: String?
  /// 人读的设备描述(芯片型号);标准识别或读不到为 nil。
  public let deviceDescription: String?
  /// 从 ggml-metal 初始化日志读到的 has_tensor;读不到为 nil(未核实)。
  public let hasTensor: Bool?
  /// GPU 会话请求的 CPU 线程数(0 = 库自选);标准识别为 nil。
  public let requestedThreads: Int32?
  /// 1.7B 加载 GGUF 并建会话的用时(秒);标准识别、还没接手或没能装好为 nil。下同。
  public let proLoadSeconds: Double?
  /// 0.1 s 噪声预热的用时(秒);GPU 没接收那次预热时也为 nil。
  public let proWarmupSeconds: Double?
  /// 开录后多久 1.7B 接手(秒)。
  public let proReadyAfterSeconds: Double?

  public init(
    modelAssetID: String,
    fellBack: Bool,
    fallbackCallIndex: Int?,
    deviceName: String?,
    deviceDescription: String?,
    hasTensor: Bool?,
    requestedThreads: Int32?,
    proLoadSeconds: Double? = nil,
    proWarmupSeconds: Double? = nil,
    proReadyAfterSeconds: Double? = nil
  ) {
    self.modelAssetID = modelAssetID
    self.fellBack = fellBack
    self.fallbackCallIndex = fallbackCallIndex
    self.deviceName = deviceName
    self.deviceDescription = deviceDescription
    self.hasTensor = hasTensor
    self.requestedThreads = requestedThreads
    self.proLoadSeconds = proLoadSeconds
    self.proWarmupSeconds = proWarmupSeconds
    self.proReadyAfterSeconds = proReadyAfterSeconds
  }
}

/// 停止时能交出 `TranscriberLiveEngineReport` 的会中引擎。
public protocol TranscriberLiveEngineReporting: Sendable {
  var liveEngineReport: TranscriberLiveEngineReport { get }
}

public protocol TranscriberASRAnchorGapFramesProviding: Sendable {
  func asrAnchorGapFrames(for source: AudioSource) -> UInt64
}

/// 会中实时转写的发射统计。取证用:某一路若只出定稿、流式预览被系统性跳过,
/// 散会后必须能从落盘统计看出来(08-08「实时区只见对方」调查的取证缺口)。
public struct LiveEmissionStats: Equatable, Sendable {
  public var partialsEmitted: UInt64
  public var partialsSkipped: UInt64
  public var finalsEmitted: UInt64

  public init(
    partialsEmitted: UInt64 = 0,
    partialsSkipped: UInt64 = 0,
    finalsEmitted: UInt64 = 0
  ) {
    self.partialsEmitted = partialsEmitted
    self.partialsSkipped = partialsSkipped
    self.finalsEmitted = finalsEmitted
  }
}

public protocol TranscriberLiveEmissionStatsProviding: Sendable {
  func liveEmissionStats(for source: AudioSource) -> LiveEmissionStats
}

public struct BatchTranscriptionJob: Equatable, Sendable {
  public let id: String
  /// 提交时客户端发送的 request-id。服务端未来若返回独立 task_id，`id` 会用于轮询，
  /// 但排障与跨重启续查仍必须保留这个客户端 request-id。
  public let submissionRequestID: String

  public init(id: String, submissionRequestID: String? = nil) {
    self.id = id
    self.submissionRequestID = submissionRequestID ?? id
  }
}

public enum SpeakerGender: String, Codable, Equatable, Sendable {
  case male
  case female
}

public struct BatchTranscriptSegment: Codable, Equatable, Sendable {
  public let t0: TimeInterval
  public let t1: TimeInterval
  public let speaker: String
  public let text: String
  /// 双声道任务由 provider 从供应商的声道标记归一化；单声道任务保持 `nil`，
  /// 由会后管线按所提交的母带补回来源。
  public let source: AudioSource?
  /// 供应商返回的句级音量（dB）；缺字段或无法解析时为 nil。
  public let volumeDB: Double?
  /// 供应商返回的句级性别提示；仅保留官方定义的 male/female。
  public let gender: SpeakerGender?

  public init(
    t0: TimeInterval,
    t1: TimeInterval,
    speaker: String,
    text: String,
    source: AudioSource? = nil,
    volumeDB: Double? = nil,
    gender: SpeakerGender? = nil
  ) {
    self.t0 = t0
    self.t1 = t1
    self.speaker = speaker
    self.text = text
    self.source = source
    self.volumeDB = volumeDB
    self.gender = gender
  }
}

public enum BatchTranscriptionStatus: Equatable, Sendable {
  case pending
  case processing
  case completed([BatchTranscriptSegment])
  case failed(String)
}

public protocol BatchTranscriptionProvider: Sendable {
  var providerID: String { get }
  var model: String { get }

  func submit(
    audioFiles: [URL],
    language: BatchLanguageDecision,
    enableChannelSplit: Bool,
    audioFormat: String
  ) async throws -> BatchTranscriptionJob
  /// 注入客户端预生成 request_id 的口子(08-13 可观测单 R2:request_id 生成即落盘,
  /// 提交复用同一值)。**必须是协议要求**而非纯扩展方法——纯扩展在 `any` 存在类型上
  /// 静态派发,具体 provider 的实现永远不会被调到。默认实现忽略注入值(桩/历史实现
  /// 自生成),管线以返回 job 的实际身份为准覆盖落盘。
  func submit(
    audioFiles: [URL],
    language: BatchLanguageDecision,
    enableChannelSplit: Bool,
    audioFormat: String,
    requestID: String?
  ) async throws -> BatchTranscriptionJob
  func status(for job: BatchTranscriptionJob) async throws -> BatchTranscriptionStatus
}

extension BatchTranscriptionProvider {
  /// 缺省 format=`m4a`,兼容既有调用方。
  public func submit(
    audioFiles: [URL],
    language: BatchLanguageDecision,
    enableChannelSplit: Bool
  ) async throws -> BatchTranscriptionJob {
    try await submit(
      audioFiles: audioFiles,
      language: language,
      enableChannelSplit: enableChannelSplit,
      audioFormat: "m4a"
    )
  }

  /// 默认忽略注入 request_id:桩与不支持注入的实现照旧自生成任务身份。
  public func submit(
    audioFiles: [URL],
    language: BatchLanguageDecision,
    enableChannelSplit: Bool,
    audioFormat: String,
    requestID: String?
  ) async throws -> BatchTranscriptionJob {
    try await submit(
      audioFiles: audioFiles,
      language: language,
      enableChannelSplit: enableChannelSplit,
      audioFormat: audioFormat
    )
  }
}

extension BatchTranscriptionProvider {
  public var providerID: String { "batch-asr" }
  public var model: String { "unknown" }
}

public struct StoredObject: Equatable, Sendable {
  public let identifier: String
  public let objectURL: URL

  public init(identifier: String, objectURL: URL) {
    self.identifier = identifier
    self.objectURL = objectURL
  }
}

public struct StorageHealthCheckResult: Equatable, Sendable {
  public let providerID: String
  public let endpoint: URL

  public init(providerID: String, endpoint: URL) {
    self.providerID = providerID
    self.endpoint = endpoint
  }

  public var message: String {
    let location = endpoint.host ?? endpoint.absoluteString
    return "对象存储连接正常：\(providerID)（\(location)）"
  }
}

public enum StorageHealthCheckError: LocalizedError, Equatable, Sendable {
  case unsupported(providerID: String)
  case dnsOrAccountUnreachable(host: String)
  case tlsHandshakeFailed(host: String)
  case endpointUnreachable(host: String)
  case invalidCredentials(providerID: String, statusCode: Int)
  case containerNotFound(providerID: String)
  /// 服务端说请求本身没解析成功(HTTP 400),不是凭证不对。
  /// S3 兼容存储上这几乎总是签名头里混进了不该有的字符——最常见的是凭证尾随空格/换行。
  /// 与 `invalidCredentials`(401/403,格式没问题但签名或权限不对)必须分开说,
  /// 否则用户会去反复重生成一把本来就没错的密钥。
  case malformedRequest(providerID: String)
  case unexpectedResponse(providerID: String, statusCode: Int)
  case nonHTTPResponse(providerID: String)

  public var errorDescription: String? {
    switch self {
    case .unsupported(let providerID):
      return "\(providerID) 暂不支持对象存储连接测试"
    case .dnsOrAccountUnreachable(let host):
      return "无法解析或连接对象存储地址 \(host)，请检查账户名、区域与 DNS 设置"
    case .tlsHandshakeFailed(let host):
      return "无法与对象存储 \(host) 建立 TLS 安全连接，请检查账户、私有终结点或代理设置"
    case .endpointUnreachable(let host):
      return "对象存储地址 \(host) 暂时不可达，请检查网络连接后重试"
    case .invalidCredentials(let providerID, let statusCode):
      return "\(providerID) 的凭证、签名或访问权限无效（HTTP \(statusCode)）"
    case .containerNotFound(let providerID):
      return "\(providerID) 的存储桶或容器不存在（HTTP 404），请检查名称与区域"
    case .malformedRequest(let providerID):
      return
        "\(providerID) 拒绝了请求本身（HTTP 400），通常是密钥里混入了空格或换行。"
        + "请重新复制粘贴 Access Key ID 与 Secret Access Key（不要带首尾空白）后重试"
    case .unexpectedResponse(let providerID, let statusCode):
      return "\(providerID) 连接测试返回异常状态（HTTP \(statusCode)）"
    case .nonHTTPResponse(let providerID):
      return "\(providerID) 连接测试没有收到有效的 HTTP 响应"
    }
  }
}

public protocol StorageProvider: Sendable {
  var providerID: String { get }

  func healthCheck() async throws -> StorageHealthCheckResult
  func upload(fileURL: URL, objectName: String) async throws -> StoredObject
  func signedReadURL(
    for object: StoredObject,
    expiresIn: TimeInterval
  ) async throws -> URL
  func delete(_ object: StoredObject) async throws
}

extension StorageProvider {
  public func healthCheck() async throws -> StorageHealthCheckResult {
    throw StorageHealthCheckError.unsupported(providerID: providerID)
  }
}
