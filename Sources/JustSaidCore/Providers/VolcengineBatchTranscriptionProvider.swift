import Foundation
import OSLog

public enum VolcengineSpeechAuthentication: Equatable, Sendable {
  case apiKey(String)
  case legacy(appID: String, accessToken: String)
}

public enum VolcengineHotwordContextEncoding: Equatable, Sendable {
  /// 历史版官方示例：`context` 的值是内嵌 JSON 字符串。
  case jsonString
  /// 新版字段表同时把 `context` 描述为对象；留给真实凭证切换验证。
  case object
}

public struct VolcengineBatchTranscriptionConfiguration: Equatable, Sendable {
  public let authentication: VolcengineSpeechAuthentication
  public let resourceID: String
  public let endpoint: URL
  public let hotwordContextEncoding: VolcengineHotwordContextEncoding

  public init(
    authentication: VolcengineSpeechAuthentication,
    resourceID: String = "volc.bigasr.auc",
    endpoint: URL = URL(string: "https://openspeech.bytedance.com")!,
    hotwordContextEncoding: VolcengineHotwordContextEncoding = .jsonString
  ) {
    self.authentication = authentication
    self.resourceID = resourceID
    self.endpoint = endpoint
    self.hotwordContextEncoding = hotwordContextEncoding
  }
}

public enum VolcengineBatchTranscriptionError: LocalizedError, Sendable {
  case exactlyOneAudioURLRequired
  case missingTaskID
  case malformedResponse
  case serviceFailed(code: String, message: String, logID: String)
  case insecureEndpoint
  case insecureAudioURL

  public var errorDescription: String? {
    switch self {
    case .exactlyOneAudioURLRequired:
      return "火山录音文件识别每个任务只接受一个音频 URL"
    case .missingTaskID:
      return "火山录音文件识别没有返回 task_id"
    case .malformedResponse:
      return "火山录音文件识别返回格式无法解析"
    case .serviceFailed(let code, let message, let logID):
      return "火山状态码 \(code)(\(message)),logid=\(logID)"
    case .insecureEndpoint:
      return "火山录音文件识别端点必须使用 HTTPS"
    case .insecureAudioURL:
      return "交给火山录音文件识别的音频 URL 必须使用 HTTPS"
    }
  }
}

public struct VolcengineBatchTranscriptionProvider: BatchTranscriptionProvider {
  /// D4 `volc-batch`:提交/查询的 HTTP 层证据。request_id 是客户端随机 UUID,可 public;
  /// 供应商 message 是自由文本走 private;签名 URL 与凭证绝不进日志。
  private static let logger = Logger(
    subsystem: "com.justsaid.app",
    category: "volc-batch"
  )

  /// 每个任务上一次观察到的 vendorState(排队/处理中):只在状态变化时打一条 notice,
  /// 30s 轮询的重复态不刷日志。进程内存,不落盘。
  private final class VendorStateTracker: @unchecked Sendable {
    static let shared = VendorStateTracker()
    private let lock = NSLock()
    private var lastStates: [String: String] = [:]

    /// 返回 true = 状态相对上次有变化(或首次观察),值得打一条日志。
    func observe(_ state: String, for jobID: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard lastStates[jobID] != state else { return false }
      lastStates[jobID] = state
      return true
    }

    func forget(_ jobID: String) {
      lock.lock()
      lastStates.removeValue(forKey: jobID)
      lock.unlock()
    }
  }

  public let providerID = "volcengine-doubao-asr"
  public let model: String

  private let configuration: VolcengineBatchTranscriptionConfiguration
  private let transport: any HTTPTransport
  private let requestID: @Sendable () -> UUID
  private let dictionaryStore: DictionaryStore

  public init(
    configuration: VolcengineBatchTranscriptionConfiguration,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    requestID: @escaping @Sendable () -> UUID = { UUID() },
    dictionaryStore: DictionaryStore = DictionaryStore()
  ) {
    self.configuration = configuration
    self.transport = transport
    self.requestID = requestID
    self.dictionaryStore = dictionaryStore
    model = configuration.resourceID
  }

  public func submit(
    audioFiles: [URL],
    language: BatchLanguageDecision,
    enableChannelSplit: Bool,
    audioFormat: String
  ) async throws -> BatchTranscriptionJob {
    try await submit(
      audioFiles: audioFiles,
      language: language,
      enableChannelSplit: enableChannelSplit,
      audioFormat: audioFormat,
      requestID: nil
    )
  }

  /// `requestID` 非 nil 时复用管线预生成并已落盘的任务身份(08-13 可观测单 R2);
  /// nil 时自生成,行为与旧签名逐字节等同。
  public func submit(
    audioFiles: [URL],
    language: BatchLanguageDecision,
    enableChannelSplit: Bool,
    audioFormat: String,
    requestID injectedRequestID: String?
  ) async throws -> BatchTranscriptionJob {
    guard audioFiles.count == 1, let audioURL = audioFiles.first else {
      throw VolcengineBatchTranscriptionError.exactlyOneAudioURLRequired
    }
    guard configuration.endpoint.scheme?.lowercased() == "https" else {
      throw VolcengineBatchTranscriptionError.insecureEndpoint
    }
    guard audioURL.scheme?.lowercased() == "https" else {
      throw VolcengineBatchTranscriptionError.insecureAudioURL
    }
    var request = URLRequest(
      url: configuration.endpoint
        .appendingPathComponent("api/v3/auc/bigmodel/submit")
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    addAuthenticationHeaders(to: &request)
    request.setValue(configuration.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
    // SeedASR 以客户端生成的 X-Api-Request-Id 作为任务标识:提交与轮询必须复用同一值,
    // 服务端不在响应体返回 task_id(2026-07-29 真实接口实测确认)。
    let submissionRequestID = injectedRequestID ?? requestID().uuidString
    request.setValue(submissionRequestID, forHTTPHeaderField: "X-Api-Request-Id")
    request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
    // 主体与称呼都进热词:它们都是会被说出口的真词(人物主体模型,2026-07-30)。
    let hotwords = try dictionaryStore.loadEntries().flatMap(\.allSpokenForms)
    // 导入源可能是 mp3/wav 等;空串回落 m4a,既有本机录制行为不变。
    let trimmed = audioFormat.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedFormat = trimmed.isEmpty ? "m4a" : trimmed
    request.httpBody = try JSONEncoder().encode(
      SubmitRequest(
        audio: AudioRequest(
          url: audioURL.absoluteString,
          format: resolvedFormat,
          language: language.apiLanguage,
          channelCount: enableChannelSplit ? 2 : 1
        ),
        request: RecognitionRequest(
          modelName: "bigmodel",
          showUtterances: true,
          showVolume: true,
          enablePunctuation: true,
          enableSpeakerInfo: true,
          enableGenderDetection: true,
          enableChannelSplit: enableChannelSplit,
          vadSegment: true,
          enableITN: true,
          enableDDC: false,
          corpus: Corpus.make(
            hotwords: hotwords,
            encoding: configuration.hotwordContextEncoding
          )
        )
      )
    )
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.validatedData(for: request)
    } catch {
      // HTTP 层失败留痕(R4):状态码/错误摘要;正文与凭证不进日志。
      Self.logger.error(
        "submit 传输失败 request_id=\(submissionRequestID, privacy: .public) error=\(Self.summarize(error), privacy: .private)"
      )
      throw error
    }
    do {
      try requireSuccessStatus(from: response)
    } catch let error as VolcengineBatchTranscriptionError {
      if case .serviceFailed(let code, let message, let logID) = error {
        Self.logger.error(
          "submit 被拒 request_id=\(submissionRequestID, privacy: .public) code=\(code, privacy: .public) logid=\(logID, privacy: .public) message=\(String(message.prefix(500)), privacy: .private)"
        )
      }
      throw error
    }
    guard let response = try? JSONDecoder().decode(SubmitResponse.self, from: data) else {
      Self.logger.error(
        "submit 响应无法解析 request_id=\(submissionRequestID, privacy: .public)"
      )
      throw VolcengineBatchTranscriptionError.malformedResponse
    }
    let serverTaskID = response.taskID ?? response.result?.taskID
    let taskID = (serverTaskID?.isEmpty == false) ? serverTaskID! : submissionRequestID
    Self.logger.notice(
      "submit 成功 request_id=\(submissionRequestID, privacy: .public) task_id=\(taskID, privacy: .public) resource=\(configuration.resourceID, privacy: .public)"
    )
    return BatchTranscriptionJob(
      id: taskID,
      submissionRequestID: submissionRequestID
    )
  }

  public func status(
    for job: BatchTranscriptionJob
  ) async throws -> BatchTranscriptionStatus {
    guard configuration.endpoint.scheme?.lowercased() == "https" else {
      throw VolcengineBatchTranscriptionError.insecureEndpoint
    }
    var request = URLRequest(
      url: configuration.endpoint
        .appendingPathComponent("api/v3/auc/bigmodel/query")
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    addAuthenticationHeaders(to: &request)
    request.setValue(configuration.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
    request.setValue(job.id, forHTTPHeaderField: "X-Api-Request-Id")
    request.httpBody = Data("{}".utf8)

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.validatedData(for: request)
    } catch {
      Self.logger.error(
        "query 传输失败 request_id=\(job.id, privacy: .public) error=\(Self.summarize(error), privacy: .private)"
      )
      throw error
    }
    guard
      let statusCode = response.value(forHTTPHeaderField: "X-Api-Status-Code")
    else {
      Self.logger.error(
        "query 响应缺 X-Api-Status-Code request_id=\(job.id, privacy: .public)"
      )
      throw VolcengineBatchTranscriptionError.malformedResponse
    }
    switch statusCode {
    case "20000001":
      logVendorStateChange("processing", jobID: job.id)
      return .processing
    case "20000002":
      logVendorStateChange("queued", jobID: job.id)
      return .pending
    case "20000003":
      Self.logger.notice(
        "query 完成(静音空结果) request_id=\(job.id, privacy: .public)"
      )
      VendorStateTracker.shared.forget(job.id)
      return .completed([])
    case "20000000":
      guard
        let result = try? JSONDecoder().decode(QueryResponse.self, from: data),
        let utterances = result.result?.utterances
      else {
        Self.logger.error(
          "query 完成但结果无法解析 request_id=\(job.id, privacy: .public)"
        )
        throw VolcengineBatchTranscriptionError.malformedResponse
      }
      let segments =
        utterances.map {
          BatchTranscriptSegment(
            t0: $0.startTime / 1_000,
            t1: $0.endTime / 1_000,
            speaker: $0.additions?.speaker?.stringValue ?? "",
            text: $0.text,
            source: Self.source(for: $0.additions?.channelID?.stringValue),
            volumeDB: Self.volumeDB(for: $0.additions?.volume?.stringValue),
            gender: Self.gender(for: $0.additions?.gender?.stringValue)
          )
        }
      Self.logger.notice(
        "query 完成 request_id=\(job.id, privacy: .public) utterances=\(segments.count, privacy: .public)"
      )
      VendorStateTracker.shared.forget(job.id)
      return .completed(segments)
    default:
      let detail = failureDetail(statusCode: statusCode, response: response)
      Self.logger.error(
        "query 终态失败 request_id=\(job.id, privacy: .public) code=\(statusCode, privacy: .public) logid=\(headerValue("X-Tt-Logid", from: response), privacy: .public) message=\(String(headerValue("X-Api-Message", from: response).prefix(500)), privacy: .private)"
      )
      VendorStateTracker.shared.forget(job.id)
      return .failed(detail)
    }
  }

  /// 只在 vendorState 变化时打一条(排队→处理中);30s 轮询的重复态不刷日志。
  private func logVendorStateChange(_ state: String, jobID: String) {
    guard VendorStateTracker.shared.observe(state, for: jobID) else { return }
    Self.logger.notice(
      "query 状态变化 request_id=\(jobID, privacy: .public) state=\(state, privacy: .public)"
    )
  }

  /// 错误摘要(≤500 字符):LocalizedError 文案或类型描述,不携带请求体。
  private static func summarize(_ error: Error) -> String {
    String(error.localizedDescription.prefix(500))
  }

  private func addAuthenticationHeaders(to request: inout URLRequest) {
    switch configuration.authentication {
    case .apiKey(let key):
      request.setValue(key, forHTTPHeaderField: "X-Api-Key")
    case .legacy(let appID, let accessToken):
      request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
      request.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
    }
  }

  private static func source(for channelID: String?) -> AudioSource? {
    switch channelID?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "1":
      return .me
    case "2":
      return .others
    default:
      return nil
    }
  }

  private static func volumeDB(for value: String?) -> Double? {
    guard
      let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      let volume = Double(value),
      volume.isFinite
    else {
      return nil
    }
    return volume
  }

  private static func gender(for value: String?) -> SpeakerGender? {
    guard
      let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
      return nil
    }
    return SpeakerGender(rawValue: value)
  }

  private func requireSuccessStatus(from response: HTTPURLResponse) throws {
    guard
      let statusCode = response.value(forHTTPHeaderField: "X-Api-Status-Code")
    else {
      throw VolcengineBatchTranscriptionError.malformedResponse
    }
    guard statusCode == "20000000" else {
      throw VolcengineBatchTranscriptionError.serviceFailed(
        code: statusCode,
        message: headerValue("X-Api-Message", from: response),
        logID: headerValue("X-Tt-Logid", from: response)
      )
    }
  }

  private func failureDetail(
    statusCode: String,
    response: HTTPURLResponse
  ) -> String {
    "火山状态码 \(statusCode)(\(headerValue("X-Api-Message", from: response))),"
      + "logid=\(headerValue("X-Tt-Logid", from: response))"
  }

  private func headerValue(
    _ name: String,
    from response: HTTPURLResponse
  ) -> String {
    guard
      let value = response.value(forHTTPHeaderField: name)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return "无"
    }
    return value
  }
}

private struct SubmitRequest: Encodable {
  let audio: AudioRequest
  let request: RecognitionRequest
}

private struct AudioRequest: Encodable {
  let url: String
  let format: String
  let language: String?
  let channelCount: Int

  enum CodingKeys: String, CodingKey {
    case url
    case format
    case language
    case channelCount = "channel"
  }
}

private struct RecognitionRequest: Encodable {
  let modelName: String
  let showUtterances: Bool
  let showVolume: Bool
  let enablePunctuation: Bool
  let enableSpeakerInfo: Bool
  let enableGenderDetection: Bool
  let enableChannelSplit: Bool
  let vadSegment: Bool
  let enableITN: Bool
  let enableDDC: Bool
  let corpus: Corpus?

  enum CodingKeys: String, CodingKey {
    case modelName = "model_name"
    case showUtterances = "show_utterances"
    case showVolume = "show_volume"
    case enablePunctuation = "enable_punc"
    case enableSpeakerInfo = "enable_speaker_info"
    case enableGenderDetection = "enable_gender_detection"
    case enableChannelSplit = "enable_channel_split"
    case vadSegment = "vad_segment"
    case enableITN = "enable_itn"
    case enableDDC = "enable_ddc"
    case corpus
  }
}

private struct Corpus: Encodable {
  let context: HotwordContext?

  enum CodingKeys: String, CodingKey {
    case context
  }

  /// 词典为空就整个不发 `corpus`——多发一个空字段等于把「没配热词」说成「配了空热词」,
  /// 供应商侧的行为没有保证。
  /// (供应商侧热词词表通道 N3 已被用户否决——供应商绑定,2026-07-30;词典别名机制是中立正解。)
  static func make(
    hotwords: [String],
    encoding: VolcengineHotwordContextEncoding
  ) -> Corpus? {
    guard !hotwords.isEmpty else { return nil }
    return Corpus(
      context: HotwordContext(words: hotwords, encoding: encoding)
    )
  }
}

private enum HotwordContext: Encodable {
  case jsonString(HotwordPayload)
  case object(HotwordPayload)

  init(
    words: [String],
    encoding: VolcengineHotwordContextEncoding
  ) {
    let payload = HotwordPayload(
      hotwords: words.map(Hotword.init(word:))
    )
    switch encoding {
    case .jsonString:
      self = .jsonString(payload)
    case .object:
      self = .object(payload)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .jsonString(let payload):
      let data = try JSONEncoder().encode(payload)
      guard let value = String(data: data, encoding: .utf8) else {
        throw EncodingError.invalidValue(
          payload,
          EncodingError.Context(
            codingPath: encoder.codingPath,
            debugDescription: "热词 context 无法编码为 UTF-8"
          )
        )
      }
      try container.encode(value)
    case .object(let payload):
      try container.encode(payload)
    }
  }
}

private struct HotwordPayload: Encodable {
  let hotwords: [Hotword]
}

private struct Hotword: Encodable {
  let word: String
}

private struct SubmitResponse: Decodable {
  struct Result: Decodable {
    let taskID: String?

    enum CodingKeys: String, CodingKey {
      case taskID = "task_id"
    }
  }

  let taskID: String?
  let result: Result?

  enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case result
  }
}

private struct QueryResponse: Decodable {
  struct Result: Decodable {
    let utterances: [Utterance]?
  }

  struct Utterance: Decodable {
    struct Additions: Decodable {
      let speaker: FlexibleString?
      let channelID: FlexibleString?
      let volume: FlexibleString?
      let gender: FlexibleString?

      enum CodingKeys: String, CodingKey {
        case speaker
        case channelID = "channel_id"
        case volume
        case gender
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speaker = try? container.decode(FlexibleString.self, forKey: .speaker)
        channelID = try? container.decode(FlexibleString.self, forKey: .channelID)
        volume = try? container.decode(FlexibleString.self, forKey: .volume)
        gender = try? container.decode(FlexibleString.self, forKey: .gender)
      }
    }

    let startTime: Double
    let endTime: Double
    let text: String
    let additions: Additions?

    enum CodingKeys: String, CodingKey {
      case startTime = "start_time"
      case endTime = "end_time"
      case text
      case additions
    }
  }

  let result: Result?
}

private enum FlexibleString: Decodable {
  case string(String)
  case integer(Int)
  case double(Double)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else {
      self = .double(try container.decode(Double.self))
    }
  }

  var stringValue: String {
    switch self {
    case .string(let value):
      return value
    case .integer(let value):
      return String(value)
    case .double(let value):
      return String(value)
    }
  }
}
