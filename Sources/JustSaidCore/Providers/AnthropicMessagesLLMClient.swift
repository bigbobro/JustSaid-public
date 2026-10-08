import Foundation

/// Anthropic Messages API 的线上契约(10-08)。**Anthropic 的档位与思考词面只允许出现在这里。**
///
/// 不走 Anthropic 的 OpenAI 兼容层:它忽略 `reasoning_effort`、不回传思考、不支持 prompt caching,
/// 官方定位为测试用。取舍见任务 `10-08-anthropic-messages-channel/design.md`。
public enum AnthropicMessagesContract {
  public static let providerID = "anthropic"
  public static let apiVersion = "2023-06-01"
  public static let defaultBaseURL = "https://api.anthropic.com/v1"
  /// 思考 token 计入此上限。官方速率限制页写明 `max_tokens` 不计入 OTPM,取大值没有限流代价;
  /// 当前模型的最大输出均不低于 64K。
  public static let maxTokens = 64_000
  /// 模型列表单页条数(官方 1–1000,默认只有 20)与翻页上限。
  static let modelPageLimit = 1_000
  static let maxModelPages = 10

  /// Base URL 末段已是 `messages` 时原样使用,否则追加;模型列表同理。
  static func messagesURL(from baseURL: URL) -> URL { endpoint("messages", from: baseURL) }

  static func modelsURL(from baseURL: URL) -> URL { endpoint("models", from: baseURL) }

  private static func endpoint(_ leaf: String, from baseURL: URL) -> URL {
    let base =
      ["messages", "models"].contains(baseURL.lastPathComponent)
      ? baseURL.deletingLastPathComponent() : baseURL
    return base.appendingPathComponent(leaf)
  }

  /// 中性档位 → `output_config.effort`。off 发 `low`:Opus 5.5、Sonnet 5.5 等关不掉思考
  /// (`thinking.disabled` 返回 400),省略 `thinking` 再取最低强度是各模型都合法的写法。
  static func wireEffort(_ level: ReasoningEffortLevel) -> String {
    switch level {
    case .off, .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .xhigh: return "xhigh"
    case .max: return "max"
    }
  }

  /// off 不发 `thinking`(Opus 4.8/4.7 省略即不思考);其余开 adaptive 并要摘要——
  /// 摘要增量让长思考期间有可解码的进展,`display` 只管可见性,计费不变。
  static func requestsThinking(_ level: ReasoningEffortLevel) -> Bool { level != .off }

  /// 只含 Messages API 的 GA 字段:不带 OpenAI 字段、采样参数、预填或 beta 功能。
  static func requestBody(model: String, request: LLMRequest, level: ReasoningEffortLevel)
    -> [String: Any]
  {
    var body: [String: Any] = [
      "model": model,
      "max_tokens": maxTokens,
      "stream": true,
      "messages": [["role": "user", "content": request.userPrompt]],
      "output_config": ["effort": wireEffort(level)],
    ]
    // system 在同一路内稳定,缓存断点放在它末尾;转写所在的 user 前缀每拍都变,不加断点。
    if !request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      body["system"] = [
        [
          "type": "text", "text": request.systemPrompt,
          "cache_control": ["type": "ephemeral"],
        ]
      ]
    }
    if requestsThinking(level) {
      body["thinking"] = ["type": "adaptive", "display": "summarized"]
    }
    return body
  }

  static func applyHeaders(to request: inout URLRequest, apiKey: String) {
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
  }
}

/// 正常结束之外的两种「模型答完了但结果不能用」。文案固定,不含服务端正文。
public struct AnthropicMessagesError: LocalizedError, Equatable, Sendable {
  public enum Kind: String, Sendable {
    /// `stop_reason: refusal`:安全分类器或模型本身拒绝;已流出的部分不采用。
    case refused
    /// `stop_reason: max_tokens` / `model_context_window_exceeded`:输出不完整。
    case outputLimitReached
  }

  public let kind: Kind
  /// 拒答类别的净化短码(`cyber`、`bio` 等);服务端没给为 nil。
  public let category: String?

  public init(kind: Kind, category: String? = nil) {
    self.kind = kind
    self.category = category
  }

  public var errorDescription: String? {
    switch kind {
    case .refused: return "模型拒绝处理这次内容，已生成的部分未采用"
    case .outputLimitReached: return "模型输出达到长度上限，内容不完整，未采用"
    }
  }
}

/// Anthropic Messages 原生适配器:`POST <base>/messages`,`x-api-key` + `anthropic-version`,SSE。
///
/// 成功只有一种:收到 `message_stop`,`stop_reason` 不是拒答或长度上限,且正文非空。流内 `error`
/// 事件、提前 EOF、拒答、长度上限各自报错,半截不交。期限语义由 `LLMStreamLiveness` 统一执行。
public struct AnthropicMessagesLLMClient: LLMClient {
  public private(set) var configuration: LLMClientConfiguration
  /// 字节空闲超时(`URLRequest.timeoutInterval`)。
  public let idleTimeout: TimeInterval
  /// 发出请求 → 第一个带负载的事件;nil 不设。
  public let firstFrameTimeout: TimeInterval?
  /// 渠道声明的档位;第二跳降档只在其中挑。
  public let supportedReasoningLevels: Set<ReasoningEffortLevel>
  private let transport: any HTTPTransport
  private let diagnosticsLedger: DiagnosticEventLedger

  public init(
    configuration: LLMClientConfiguration,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    idleTimeout: TimeInterval = 600,
    firstFrameTimeout: TimeInterval? = nil,
    supportedReasoningLevels: Set<ReasoningEffortLevel> = Set(ReasoningEffortLevel.allCases),
    diagnosticsLedger: DiagnosticEventLedger = .shared
  ) {
    self.configuration = configuration
    self.transport = transport
    self.idleTimeout = idleTimeout
    self.firstFrameTimeout = firstFrameTimeout
    self.supportedReasoningLevels = supportedReasoningLevels
    self.diagnosticsLedger = diagnosticsLedger
  }

  public var streamsProgress: Bool { true }

  /// 降一档:取低于当前、不低于 medium、且渠道声明支持的最高一档(max→xhigh→high→medium)。
  public func reasoningDowngradedForRetry() -> (any LLMClient)? {
    let current = configuration.reasoningEffort
    guard current > .medium,
      let lower = supportedReasoningLevels.filter({ $0 < current && $0 >= .medium }).max()
    else { return nil }
    var copy = self
    let base = configuration
    copy.configuration = LLMClientConfiguration(
      providerID: base.providerID, baseURL: base.baseURL, apiKey: base.apiKey, model: base.model,
      reasoningEffort: lower, requestedReasoningEffort: base.requestedReasoningEffort,
      diagnosticRole: base.diagnosticRole, diagnosticPurpose: base.diagnosticPurpose,
      diagnosticOrigin: base.diagnosticOrigin, diagnosticMeetingHash: base.diagnosticMeetingHash,
      recoveryChannelID: base.recoveryChannelID, lane: base.lane,
      billingSource: base.billingSource)
    return copy
  }

  public func complete(_ request: LLMRequest) async throws -> LLMResponse {
    try await complete(request, options: LLMCallOptions())
  }

  public func complete(_ request: LLMRequest, options: LLMCallOptions) async throws -> LLMResponse {
    let context = options.context
    let callID = UUID().uuidString.lowercased()
    let startedAt = Date()
    let level = configuration.reasoningEffort
    let thinking = AnthropicMessagesContract.requestsThinking(level)
    let timeline = ResponsesStreamTimeline(startedAt: startedAt)
    func fields(
      stage: String? = nil, outcome: String? = nil, category: String? = nil, status: Int? = nil,
      code: String? = nil, response: LLMResponse? = nil, charged: String? = nil,
      error: Error? = nil
    ) -> DiagnosticEventFields {
      let snapshot = stage == nil ? nil : timeline.snapshot()
      return DiagnosticEventFields(
        family: "llm", operation: "complete",
        role: context?.role ?? configuration.diagnosticRole,
        purpose: context?.purpose ?? configuration.diagnosticPurpose,
        origin: context?.origin ?? configuration.diagnosticOrigin,
        meetingHash: context?.meetingHash ?? configuration.diagnosticMeetingHash,
        providerID: configuration.providerID, model: configuration.model,
        endpointFingerprint: LLMFailureContext.fingerprint(configuration.baseURL.absoluteString),
        requestedReasoning: configuration.requestedReasoningEffort.rawValue,
        effectiveReasoning: response.map {
          $0.reasoningExecution?.effectiveLevel?.rawValue ?? "unknown"
        } ?? level.rawValue,
        wireReasoning: AnthropicMessagesContract.wireEffort(level),
        reasoningOffStyle: thinking ? nil : "thinkingOmitted",
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
        firstFrameMs: snapshot?.firstFrameMs, responseBytes: snapshot?.responseBytes,
        charged: charged, reasoningSummaryRequested: thinking,
        firstReasoningMs: snapshot?.firstReasoningMs, firstOutputMs: snapshot?.firstOutputMs,
        reasoningSummaryEvents: snapshot?.reasoningSummaryEvents,
        outputDeltaEvents: snapshot?.outputDeltaEvents, keepaliveLines: snapshot?.keepaliveLines,
        maxGapMs: snapshot?.maxGapMs, lastByteAgoMs: snapshot?.lastByteAgoMs,
        lastEventType: snapshot?.lastEventType,
        safeErrorSummary: error.map(DiagnosticSanitizer.summary(for:)))
    }
    diagnosticsLedger.append(
      event: "modelCall.start", source: "AnthropicMessagesLLMClient", correlationID: callID,
      fields: fields())
    do {
      let urlRequest = try makeRequest(request)
      let transport = self.transport
      let accumulated = try await LLMStreamLiveness.run(
        firstFrameTimeout: firstFrameTimeout,
        progressTimeout: options.progressTimeout,
        open: { try await transport.validatedLines(for: urlRequest) },
        consume: { stream, hooks in
          try await Self.consume(
            stream, hooks: hooks, onStreamProgress: options.onStreamProgress, timeline: timeline)
        })
      let response = try Self.response(from: accumulated, configuration: configuration)
      diagnosticsLedger.append(
        event: "modelCall.finish", source: "AnthropicMessagesLLMClient", correlationID: callID,
        fields: fields(
          stage: "complete", outcome: "success", category: "success", response: response,
          charged: "completed"))
      return response
    } catch {
      let cancelled = error is CancellationError
      diagnosticsLedger.append(
        event: "modelCall.finish", severity: .error, source: "AnthropicMessagesLLMClient",
        correlationID: callID,
        fields: fields(
          stage: Self.diagnosticStage(for: error), outcome: cancelled ? "cancelled" : "failure",
          category: DiagnosticSanitizer.category(for: error),
          status: (error as? HTTPTransportError)?.statusCode,
          code: Self.diagnosticCode(for: error),
          charged: cancelled
            ? "unknown" : (minutesFailureIsPreSend(error) ? "notSent" : "possiblySent"),
          error: error))
      throw error
    }
  }

  private func makeRequest(_ request: LLMRequest) throws -> URLRequest {
    let endpoint = AnthropicMessagesContract.messagesURL(from: configuration.baseURL)
    guard endpoint.scheme?.lowercased() == "https" else { throw LLMClientError.insecureEndpoint }
    var urlRequest = URLRequest(
      url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: idleTimeout)
    urlRequest.httpMethod = "POST"
    AnthropicMessagesContract.applyHeaders(to: &urlRequest, apiKey: configuration.apiKey)
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    urlRequest.httpBody = try JSONSerialization.data(
      withJSONObject: AnthropicMessagesContract.requestBody(
        model: configuration.model, request: request, level: configuration.reasoningEffort),
      options: [.sortedKeys])
    return urlRequest
  }

  struct Accumulated: Sendable {
    var content = ""
    var observedThinking = false
    var stopped = false
    var stopReason: String?
    var refusalCategory: String?
    var inputTokens: Int?
    var cacheCreationTokens: Int?
    var cacheReadTokens: Int?
    var outputTokens: Int?

    /// `message_start` 给初值,`message_delta` 给累计值;缺席或 null 的字段保持原值,不补 0。
    mutating func applyUsage(_ usage: [String: Any]?) {
      guard let usage else { return }
      if let value = usage["input_tokens"] as? Int { inputTokens = value }
      if let value = usage["cache_creation_input_tokens"] as? Int { cacheCreationTokens = value }
      if let value = usage["cache_read_input_tokens"] as? Int { cacheReadTokens = value }
      if let value = usage["output_tokens"] as? Int { outputTokens = value }
    }
  }

  static func response(from accumulated: Accumulated, configuration: LLMClientConfiguration)
    throws -> LLMResponse
  {
    switch accumulated.stopReason {
    case "refusal":
      throw AnthropicMessagesError(kind: .refused, category: accumulated.refusalCategory)
    case "max_tokens", "model_context_window_exceeded":
      throw AnthropicMessagesError(kind: .outputLimitReached)
    default:
      break
    }
    let text = accumulated.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw LLMClientError.emptyResponse }
    // input_tokens 只算最后一个缓存断点之后的部分;总输入 = 三者之和(与 prompt_tokens 同口径)。
    let uncached = accumulated.inputTokens.map { $0 + (accumulated.cacheCreationTokens ?? 0) }
    let offIgnored = configuration.reasoningEffort == .off && accumulated.observedThinking
    return LLMResponse(
      text: text,
      inputTokens: uncached.map { $0 + (accumulated.cacheReadTokens ?? 0) },
      outputTokens: accumulated.outputTokens,
      cacheHitTokens: accumulated.cacheReadTokens,
      cacheMissTokens: uncached,
      reasoningTokens: nil,
      reasoningExecution: LLMReasoningExecution(
        requestedLevel: configuration.requestedReasoningEffort,
        effectiveLevel: offIgnored ? nil : configuration.reasoningEffort,
        offStyle: nil, offIgnored: offIgnored))
  }

  /// 按 SSE 规范切事件(空行为界,同一事件多行 data 拼接),按负载里的 `type` 处理;
  /// `event:` 行与 ping、未知事件不参与判定。
  static func consume(
    _ stream: AsyncThrowingStream<String, Error>,
    hooks: LLMStreamLiveness.Hooks,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?,
    timeline: ResponsesStreamTimeline
  ) async throws -> Accumulated {
    var accumulated = Accumulated()
    var dataLines: [String] = []
    var sawFrame = false
    var emitter = LLMStreamProgressEmitter(onStreamProgress: onStreamProgress)
    timeline.opened()

    func flush() throws {
      defer { dataLines.removeAll(keepingCapacity: true) }
      guard !dataLines.isEmpty, !accumulated.stopped else { return }
      if !sawFrame {
        sawFrame = true
        timeline.firstFrame()
        hooks.onFirstFrame()
      }
      let payload = dataLines.joined(separator: "\n")
      guard let data = payload.data(using: .utf8),
        let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type = event["type"] as? String
      else { throw LLMClientError.malformedResponse }
      timeline.event(type)
      switch type {
      case "message_start":
        accumulated.applyUsage((event["message"] as? [String: Any])?["usage"] as? [String: Any])
      case "content_block_start":
        let blockType = (event["content_block"] as? [String: Any])?["type"] as? String
        if blockType == "thinking" || blockType == "redacted_thinking" {
          accumulated.observedThinking = true
        }
      case "content_block_delta":
        let delta = event["delta"] as? [String: Any]
        switch delta?["type"] as? String {
        case "text_delta":
          let text = delta?["text"] as? String ?? ""
          guard !text.isEmpty else { return }
          timeline.outputDelta()
          try hooks.onDecodedProgress()
          accumulated.content += text
          emitter.emit(content: accumulated.content, thinking: accumulated.observedThinking)
        case "thinking_delta":
          // 思考摘要只表示进展,绝不进正文。
          let text = delta?["thinking"] as? String ?? ""
          guard !text.isEmpty else { return }
          accumulated.observedThinking = true
          timeline.reasoningDelta()
          try hooks.onDecodedProgress()
          emitter.emit(content: accumulated.content, thinking: true)
        default:
          // signature_delta、citations_delta 等不携带正文。
          break
        }
      case "message_delta":
        let delta = event["delta"] as? [String: Any]
        if let reason = delta?["stop_reason"] as? String {
          accumulated.stopReason = DiagnosticSanitizer.token(reason, fallback: "unknown")
        }
        let details =
          (delta?["stop_details"] as? [String: Any]) ?? (event["stop_details"] as? [String: Any])
        if let category = details?["category"] as? String {
          accumulated.refusalCategory = DiagnosticSanitizer.token(category, fallback: "unknown")
        }
        accumulated.applyUsage(event["usage"] as? [String: Any])
      case "message_stop":
        accumulated.stopped = true
        emitter.emit(content: accumulated.content, thinking: false, force: true)
      case "error":
        // 只带错误类型短码,服务端 message 原文不进错误、诊断或界面。
        let errorType = (event["error"] as? [String: Any])?["type"] as? String
        throw LLMClientError.streamFailed(
          DiagnosticSanitizer.token(errorType ?? "unknown", fallback: "unknown"))
      case "ping":
        timeline.keepalive()
      default:
        // 以后新增的事件类型。
        break
      }
    }

    var isFirstLine = true
    for try await rawLine in stream {
      timeline.line(bytes: rawLine.utf8.count + 1, isComment: rawLine.hasPrefix(":"))
      var line = rawLine
      if isFirstLine {
        isFirstLine = false
        if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
      }
      if line.isEmpty {
        try flush()
        if accumulated.stopped { return accumulated }
        continue
      }
      guard line.hasPrefix("data:") else { continue }
      var value = String(line.dropFirst("data:".count))
      if value.hasPrefix(" ") { value.removeFirst() }
      dataLines.append(value)
    }
    try flush()
    guard accumulated.stopped else {
      // 消费方被取消时异步序列会安静结束;那是取消,不是可重试的截断。
      try Task.checkCancellation()
      throw LLMClientError.streamTruncated
    }
    return accumulated
  }

  private static func diagnosticStage(for error: Error) -> String {
    switch error {
    case is HTTPTransportError, is AnthropicMessagesError:
      return "response"
    case let llm as LLMClientError:
      switch llm {
      case .invalidEndpoint, .insecureEndpoint: return "request"
      case .malformedResponse, .emptyResponse, .reasoningOnlyResponse: return "parse"
      case .firstFrameTimedOut: return "transport"
      case .streamFailed, .streamTruncated, .progressTimedOut: return "stream"
      }
    default:
      return "transport"
    }
  }

  private static func diagnosticCode(for error: Error) -> String? {
    switch error {
    case let http as HTTPTransportError:
      return http.providerErrorCode
    case let anthropic as AnthropicMessagesError:
      let kind = anthropic.kind.rawValue
      return anthropic.category.map { "\(kind).\($0)" } ?? kind
    case LLMClientError.streamFailed(let type):
      return type
    default:
      return nil
    }
  }

  /// 模型列表只用于设置辅助;失败返回 nil,界面保留手填,不阻断保存。
  public func availableModels() async -> [String]? {
    let callID = UUID().uuidString.lowercased()
    let startedAt = Date()
    func fields(outcome: String, stage: String? = nil, count: Int? = nil, error: Error? = nil)
      -> DiagnosticEventFields
    {
      DiagnosticEventFields(
        family: "llm", operation: "modelList", role: configuration.diagnosticRole,
        purpose: "modelList", origin: configuration.diagnosticOrigin,
        providerID: configuration.providerID, model: configuration.model,
        endpointFingerprint: LLMFailureContext.fingerprint(configuration.baseURL.absoluteString),
        requestedReasoning: "off", effectiveReasoning: "off", wireReasoning: "off",
        stage: stage, outcome: outcome,
        category: error.map(DiagnosticSanitizer.category(for:)) ?? (stage == nil ? nil : "success"),
        httpStatus: (error as? HTTPTransportError)?.statusCode,
        providerErrorCode: (error as? HTTPTransportError)?.providerErrorCode,
        outputSize: count,
        latencyMs: stage == nil ? nil : Int(Date().timeIntervalSince(startedAt) * 1_000),
        safeErrorSummary: error.map(DiagnosticSanitizer.summary(for:)))
    }
    diagnosticsLedger.append(
      event: "modelProbe.start", source: "AnthropicMessagesLLMClient", correlationID: callID,
      fields: fields(outcome: "started"))
    do {
      let ids = try await fetchModelIDs()
      diagnosticsLedger.append(
        event: "modelProbe.finish", source: "AnthropicMessagesLLMClient", correlationID: callID,
        fields: fields(outcome: "success", stage: "parse", count: ids.count))
      return ids
    } catch {
      diagnosticsLedger.append(
        event: "modelProbe.finish", severity: .error, source: "AnthropicMessagesLLMClient",
        correlationID: callID,
        fields: fields(outcome: "failure", stage: Self.diagnosticStage(for: error), error: error))
      return nil
    }
  }

  /// `GET <base>/models?limit=1000`,按 `has_more` / `last_id` 翻页;按服务端顺序去重。
  private func fetchModelIDs() async throws -> [String] {
    let base = AnthropicMessagesContract.modelsURL(from: configuration.baseURL)
    guard base.scheme?.lowercased() == "https" else { throw LLMClientError.insecureEndpoint }
    var ids: [String] = []
    var afterID: String?
    for _ in 0..<AnthropicMessagesContract.maxModelPages {
      var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
      var query = [
        URLQueryItem(name: "limit", value: String(AnthropicMessagesContract.modelPageLimit))
      ]
      if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
      components?.queryItems = query
      guard let url = components?.url else { throw LLMClientError.invalidEndpoint }
      var request = URLRequest(
        url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
        timeoutInterval: idleTimeout)
      request.httpMethod = "GET"
      AnthropicMessagesContract.applyHeaders(to: &request, apiKey: configuration.apiKey)
      let (data, _) = try await transport.validatedData(for: request)
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let page = object["data"] as? [[String: Any]]
      else { throw LLMClientError.malformedResponse }
      for id in page.compactMap({ $0["id"] as? String }) where !ids.contains(id) {
        ids.append(id)
      }
      guard object["has_more"] as? Bool == true, let last = object["last_id"] as? String,
        last != afterID
      else { break }
      afterID = last
    }
    return ids
  }
}
