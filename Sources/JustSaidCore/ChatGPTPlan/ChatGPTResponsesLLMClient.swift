import Foundation

/// ChatGPT 计划用量的 Responses 适配器:固定 `POST https://api.openai.com/v1/responses`,
/// Bearer 取自调用开始时绑定账户的令牌来源;`store:false`、`stream:true`、`input` 数组。
///
/// 成功只有一种:收到 `response.completed` 且正文非空、不是拒绝。`response.failed`、
/// `response.incomplete`、`error` 事件与未完成就断流各自报错,半截不交。期限语义由
/// `LLMStreamLiveness` 统一执行;本类型只解析事件并报告首帧与解码进展。
public struct ChatGPTResponsesLLMClient: LLMClient {
  public let configuration: LLMClientConfiguration
  public let idleTimeout: TimeInterval
  public let firstFrameTimeout: TimeInterval?
  private let transport: any HTTPTransport
  private let tokenSource: @Sendable () async throws -> String
  private let onUsageLimit: (@Sendable () async -> Void)?
  private let diagnosticsLedger: DiagnosticEventLedger

  public init(
    configuration: LLMClientConfiguration,
    tokenSource: @escaping @Sendable () async throws -> String,
    onUsageLimit: (@Sendable () async -> Void)? = nil,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    idleTimeout: TimeInterval = 600,
    firstFrameTimeout: TimeInterval? = nil,
    diagnosticsLedger: DiagnosticEventLedger = .shared
  ) {
    self.configuration = configuration
    self.tokenSource = tokenSource
    self.onUsageLimit = onUsageLimit
    self.transport = transport
    self.idleTimeout = idleTimeout
    self.firstFrameTimeout = firstFrameTimeout
    self.diagnosticsLedger = diagnosticsLedger
  }

  public var streamsProgress: Bool { true }

  public func complete(_ request: LLMRequest) async throws -> LLMResponse {
    try await complete(request, options: LLMCallOptions())
  }

  public func complete(_ request: LLMRequest, options: LLMCallOptions) async throws -> LLMResponse {
    let context = options.context
    let callID = UUID().uuidString.lowercased()
    let startedAt = Date()
    let wire = ChatGPTModelCatalogParser.wire(configuration.reasoningEffort)
    func fields(
      stage: String? = nil, outcome: String? = nil, category: String? = nil, status: Int? = nil,
      code: String? = nil, response: LLMResponse? = nil, firstFrameMs: Int? = nil,
      bytes: Int? = nil, charged: String? = nil, error: Error? = nil
    ) -> DiagnosticEventFields {
      DiagnosticEventFields(
        family: "llm", operation: "complete",
        role: context?.role ?? configuration.diagnosticRole,
        purpose: context?.purpose ?? configuration.diagnosticPurpose,
        origin: context?.origin ?? configuration.diagnosticOrigin,
        meetingHash: context?.meetingHash ?? configuration.diagnosticMeetingHash,
        providerID: configuration.providerID, model: configuration.model,
        endpointFingerprint: LLMFailureContext.fingerprint(
          ChatGPTPlanContract.responsesURL.absoluteString),
        requestedReasoning: configuration.requestedReasoningEffort.rawValue,
        effectiveReasoning: configuration.reasoningEffort.rawValue, wireReasoning: wire,
        stream: true, expectsJSON: request.expectsJSON,
        timeoutProfile: stage == nil
          ? "idle=\(Int(idleTimeout))s;first=\(firstFrameTimeout.map { Int($0) } ?? 0)s"
            + (options.progressTimeout.map { ";progress=decodedIdle:\($0)s" } ?? "") : nil,
        attempt: context?.attempt, retryGroup: context?.retryGroup, stage: stage,
        outcome: outcome, category: category, httpStatus: status, providerErrorCode: code,
        outputSize: response?.text.utf8.count, inputTokens: response?.inputTokens,
        outputTokens: response?.outputTokens, cacheHitTokens: response?.cacheHitTokens,
        cacheMissTokens: response?.cacheMissTokens, reasoningTokens: response?.reasoningTokens,
        latencyMs: stage == nil ? nil : Int(Date().timeIntervalSince(startedAt) * 1_000),
        firstFrameMs: firstFrameMs, responseBytes: bytes, charged: charged,
        safeErrorSummary: error.map(DiagnosticSanitizer.summary(for:)))
    }
    diagnosticsLedger.append(
      event: "modelCall.start", source: "ChatGPTResponsesLLMClient", correlationID: callID,
      fields: fields())

    let token: String
    do {
      token = try await tokenSource()
      try Task.checkCancellation()
    } catch {
      diagnosticsLedger.append(
        event: "modelCall.finish", severity: .error, source: "ChatGPTResponsesLLMClient",
        correlationID: callID,
        fields: fields(
          stage: "auth", outcome: error is CancellationError ? "cancelled" : "failure",
          category: DiagnosticSanitizer.category(for: error), charged: "notSent", error: error))
      throw error
    }
    do {
      let urlRequest = try makeRequest(request, token: token)
      let transport = self.transport
      let accumulated = try await LLMStreamLiveness.run(
        firstFrameTimeout: firstFrameTimeout,
        progressTimeout: options.progressTimeout,
        open: { try await Self.openStream(urlRequest, transport: transport) },
        consume: { stream, hooks in
          try await Self.consume(
            stream, hooks: hooks, onStreamProgress: options.onStreamProgress,
            startedAt: startedAt)
        })
      let response = try Self.response(from: accumulated, configuration: configuration)
      diagnosticsLedger.append(
        event: "modelCall.finish", source: "ChatGPTResponsesLLMClient", correlationID: callID,
        fields: fields(
          stage: "complete", outcome: "success", category: "success", response: response,
          firstFrameMs: accumulated.firstFrameMs, bytes: accumulated.responseBytes,
          charged: "completed"))
      return response
    } catch {
      let service = error as? ChatGPTPlanServiceError
      if service?.kind == .usageLimitExceeded { await onUsageLimit?() }
      diagnosticsLedger.append(
        event: "modelCall.finish", severity: .error, source: "ChatGPTResponsesLLMClient",
        correlationID: callID,
        fields: fields(
          stage: service == nil ? "stream" : "response",
          outcome: error is CancellationError ? "cancelled" : "failure",
          category: DiagnosticSanitizer.category(for: error), status: service?.httpStatus,
          code: service?.code,
          charged: error is CancellationError ? "unknown" : "possiblySent", error: error))
      throw error
    }
  }

  private func makeRequest(_ request: LLMRequest, token: String) throws -> URLRequest {
    var urlRequest = URLRequest(
      url: ChatGPTPlanContract.responsesURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: idleTimeout)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    // JSON mode validates input messages, not instructions, for an explicit JSON request.
    let input =
      request.expectsJSON
      ? "Respond with JSON matching the requested structure.\n\n" + request.userPrompt
      : request.userPrompt
    var body: [String: Any] = [
      "model": configuration.model,
      // 每次请求自带所需上下文;system 角色消息会被拒,系统提示放 instructions。
      "input": [["role": "user", "content": input]],
      "store": false,
      "stream": true,
      "reasoning": ["effort": ChatGPTModelCatalogParser.wire(configuration.reasoningEffort)],
    ]
    let instructions = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !instructions.isEmpty { body["instructions"] = request.systemPrompt }
    if request.expectsJSON { body["text"] = ["format": ["type": "json_object"]] }
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return urlRequest
  }

  /// 开流;非 2xx 读有界错误体并映射成带状态、机器码与请求 ID 的错误(不保留正文)。
  private static func openStream(_ request: URLRequest, transport: any HTTPTransport) async throws
    -> AsyncThrowingStream<String, Error>
  {
    let (stream, response) = try await transport.lines(for: request)
    guard (200..<300).contains(response.statusCode) else {
      var body = ""
      for try await line in stream {
        body += line + "\n"
        if body.utf8.count >= 16_384 { break }
      }
      throw ChatGPTResponsesErrorMapper.serviceError(
        status: response.statusCode, body: Data(body.utf8), requestID: response.requestID)
    }
    return stream
  }

  struct Accumulated: Sendable {
    var content = ""
    var refusal = ""
    var hasReasoningSummary = false
    var completed = false
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedTokens: Int?
    var reasoningTokens: Int?
    var firstFrameMs: Int?
    var responseBytes = 0
  }

  static func response(from accumulated: Accumulated, configuration: LLMClientConfiguration)
    throws -> LLMResponse
  {
    let text = accumulated.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard accumulated.refusal.isEmpty else { throw ChatGPTPlanServiceError(kind: .refused) }
    guard !text.isEmpty else {
      throw LLMClientError.emptyResponse
    }
    let cacheMiss: Int? =
      if let input = accumulated.inputTokens, let cached = accumulated.cachedTokens,
        input >= cached
      { input - cached } else { nil }
    return LLMResponse(
      text: text,
      inputTokens: accumulated.inputTokens,
      outputTokens: accumulated.outputTokens,
      cacheHitTokens: accumulated.cachedTokens,
      cacheMissTokens: cacheMiss,
      reasoningTokens: accumulated.reasoningTokens,
      reasoningExecution: LLMReasoningExecution(
        requestedLevel: configuration.requestedReasoningEffort,
        effectiveLevel: configuration.reasoningEffort, offStyle: nil, offIgnored: false))
  }

  /// 按 SSE 规范切事件(空行为界,同一事件多行 data 拼接),按负载里的 `type` 处理。
  static func consume(
    _ stream: AsyncThrowingStream<String, Error>,
    hooks: LLMStreamLiveness.Hooks,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?,
    startedAt: Date
  ) async throws -> Accumulated {
    var accumulated = Accumulated()
    var dataLines: [String] = []
    var emitter = LLMStreamProgressEmitter(onStreamProgress: onStreamProgress)

    func flush() throws {
      defer { dataLines.removeAll(keepingCapacity: true) }
      guard !dataLines.isEmpty, !accumulated.completed else { return }
      if accumulated.firstFrameMs == nil {
        accumulated.firstFrameMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        hooks.onFirstFrame()
      }
      let payload = dataLines.joined(separator: "\n")
      guard let data = payload.data(using: .utf8),
        let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type = event["type"] as? String
      else { throw LLMClientError.malformedResponse }
      switch type {
      case "response.output_text.delta":
        let delta = event["delta"] as? String ?? ""
        guard !delta.isEmpty else { return }
        try hooks.onDecodedProgress()
        accumulated.content += delta
        emitter.emit(content: accumulated.content, thinking: accumulated.hasReasoningSummary)
      case "response.reasoning_summary_text.delta":
        let delta = event["delta"] as? String ?? ""
        guard !delta.isEmpty else { return }
        try hooks.onDecodedProgress()
        accumulated.hasReasoningSummary = true
        emitter.emit(content: accumulated.content, thinking: true)
      case "response.refusal.delta":
        let delta = event["delta"] as? String ?? ""
        guard !delta.isEmpty else { return }
        try hooks.onDecodedProgress()
        accumulated.refusal += delta
      case "response.completed":
        let response = event["response"] as? [String: Any]
        let usage = response?["usage"] as? [String: Any]
        accumulated.inputTokens = (usage?["input_tokens"] as? NSNumber)?.intValue
        accumulated.outputTokens = (usage?["output_tokens"] as? NSNumber)?.intValue
        accumulated.cachedTokens =
          ((usage?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?
          .intValue
        accumulated.reasoningTokens =
          ((usage?["output_tokens_details"] as? [String: Any])?["reasoning_tokens"]
          as? NSNumber)?.intValue
        accumulated.completed = true
        emitter.emit(content: accumulated.content, thinking: false, force: true)
      case "response.failed":
        let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
        throw ChatGPTResponsesErrorMapper.streamError(
          code: error?["code"] as? String, param: error?["param"] as? String,
          fallback: .responseFailed)
      case "response.incomplete":
        let details =
          (event["response"] as? [String: Any])?["incomplete_details"] as? [String: Any]
        throw ChatGPTPlanServiceError(
          kind: .responseIncomplete,
          code: (details?["reason"] as? String).map {
            DiagnosticSanitizer.token($0, fallback: "unknown")
          })
      case "error":
        let nested = event["error"] as? [String: Any]
        throw ChatGPTResponsesErrorMapper.streamError(
          code: (event["code"] as? String) ?? (nested?["code"] as? String),
          param: (event["param"] as? String) ?? (nested?["param"] as? String),
          fallback: .responseFailed)
      default:
        // created / in_progress / output_item.* / content_part.* / *.done 等不携带新正文。
        break
      }
    }

    var isFirstLine = true
    for try await rawLine in stream {
      accumulated.responseBytes += rawLine.utf8.count + 1
      var line = rawLine
      if isFirstLine {
        isFirstLine = false
        if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
      }
      if line.isEmpty {
        try flush()
        if accumulated.completed { return accumulated }
        continue
      }
      guard line.hasPrefix("data:") else { continue }
      var value = String(line.dropFirst("data:".count))
      if value.hasPrefix(" ") { value.removeFirst() }
      dataLines.append(value)
    }
    try flush()
    guard accumulated.completed else { throw LLMClientError.streamTruncated }
    return accumulated
  }
}

/// 写作/思考进度的发出侧节流(时间间隔与字符增量取先到者);回调抛错一律吞掉。
struct LLMStreamProgressEmitter {
  static let minimumInterval: TimeInterval = 0.2
  static let characterThreshold = 32

  let onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?
  private var lastEmit = Date.distantPast
  private var lastCount = -1
  private var lastWasWriting = false

  init(onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?) {
    self.onStreamProgress = onStreamProgress
  }

  mutating func emit(content: String, thinking: Bool, force: Bool = false) {
    guard let onStreamProgress else { return }
    let count = content.count
    let progress: LLMStreamProgress
    if count > 0 {
      progress = .writing(characters: count, accumulatedContent: content)
    } else if thinking {
      progress = .thinking
    } else {
      return
    }
    let now = Date()
    let writing = count > 0
    let due =
      force || (writing && !lastWasWriting) || lastEmit == .distantPast
      || now.timeIntervalSince(lastEmit) >= Self.minimumInterval
      || (writing && (lastCount < 0 || count - lastCount >= Self.characterThreshold))
    guard due else { return }
    do {
      try onStreamProgress(progress)
      lastEmit = now
      lastWasWriting = writing
      if writing { lastCount = count }
    } catch {
      // 进度是观测,不得成为完成路径的失败源。
    }
  }
}

/// Responses 错误的统一映射:只认已列出的机器码,未知码保留状态与码本身,不解析自由文本。
enum ChatGPTResponsesErrorMapper {
  static func kind(forCode code: String) -> ChatGPTPlanServiceError.Kind? {
    switch code {
    case "subscription_sharing_usage_limit_exceeded": return .usageLimitExceeded
    case "subscription_sharing_usage_unavailable": return .usageUnavailable
    case "subscription_sharing_user_not_eligible": return .notEligible
    case "subscription_sharing_unsupported_capability": return .unsupportedCapability
    case "subscription_sharing_route_not_supported": return .routeNotSupported
    case "subscription_sharing_invalid_user": return .invalidUser
    case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
      return .notAuthorized
    case "subscription_sharing_user_unavailable": return .userUnavailable
    default: return nil
    }
  }

  static func streamError(
    code: String?, param: String?, fallback: ChatGPTPlanServiceError.Kind
  ) -> ChatGPTPlanServiceError {
    let safeCode = code.map { DiagnosticSanitizer.token($0, fallback: "unknown") }
    return ChatGPTPlanServiceError(
      kind: safeCode.flatMap(kind(forCode:)) ?? fallback, code: safeCode,
      param: param.map { DiagnosticSanitizer.token($0, fallback: "unknown") })
  }

  static func serviceError(status: Int, body: Data, requestID: String?) -> ChatGPTPlanServiceError {
    var code: String?
    var param: String?
    if body.count <= 16_384,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    {
      let nested = object["error"] as? [String: Any]
      code = (nested?["code"] as? String) ?? (object["code"] as? String)
      param = (nested?["param"] as? String) ?? (object["param"] as? String)
    }
    let safeCode = code.map { DiagnosticSanitizer.token($0, fallback: "unknown") }
    let kind: ChatGPTPlanServiceError.Kind =
      safeCode.flatMap(kind(forCode:))
      ?? ([401, 403, 503].contains(status) ? .admissionRejected : .other)
    return ChatGPTPlanServiceError(
      kind: kind, httpStatus: status, code: safeCode,
      param: param.map { DiagnosticSanitizer.token($0, fallback: "unknown") },
      requestID: requestID)
  }
}
