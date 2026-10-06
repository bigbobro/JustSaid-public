import CryptoKit
import Foundation

public struct LLMClientConfiguration: Equatable, Sendable {
  public let providerID: String
  public let baseURL: URL
  public let apiKey: String
  public let model: String
  /// 供应商声明协商后的档位；自定义渠道还可在收到明确拒绝后运行时降档。
  public let reasoningEffort: ReasoningEffortLevel
  public let requestedReasoningEffort: ReasoningEffortLevel
  /// 诊断上下文只包含闭合身份词，不承载 prompt/转写。
  public let diagnosticRole: String?
  public let diagnosticPurpose: String?
  public let diagnosticOrigin: String?
  public let diagnosticMeetingHash: String?
  public let recoveryChannelID: String?
  /// 解析时所属的用途(三路配置)。随配置快照固定:调用开始后改设置不重标本次调用。
  public let lane: LLMLane?
  /// 计费来源;按量 API 为 nil,ChatGPT 计划用量为 `ChatGPTPlanContract.billingSource`。
  public let billingSource: String?

  public var thinkingEnabled: Bool {
    reasoningEffort != .off
  }

  public init(
    providerID: String = "custom-openai-compatible",
    baseURL: URL,
    apiKey: String,
    model: String,
    reasoningEffort: ReasoningEffortLevel = .off,
    requestedReasoningEffort: ReasoningEffortLevel? = nil,
    diagnosticRole: String? = nil,
    diagnosticPurpose: String? = nil,
    diagnosticOrigin: String? = nil,
    diagnosticMeetingHash: String? = nil,
    recoveryChannelID: String? = nil,
    lane: LLMLane? = nil,
    billingSource: String? = nil
  ) {
    self.providerID = providerID
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.requestedReasoningEffort = requestedReasoningEffort ?? reasoningEffort
    self.diagnosticRole = diagnosticRole
    self.diagnosticPurpose = diagnosticPurpose
    self.diagnosticOrigin = diagnosticOrigin
    self.diagnosticMeetingHash = diagnosticMeetingHash
    self.recoveryChannelID = recoveryChannelID
    self.lane = lane
    self.billingSource = billingSource
  }
}

public struct LLMRequest: Equatable, Sendable {
  public let systemPrompt: String
  public let userPrompt: String
  public let expectsJSON: Bool

  public init(
    systemPrompt: String,
    userPrompt: String,
    expectsJSON: Bool = false
  ) {
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
    self.expectsJSON = expectsJSON
  }
}

public struct LLMResponse: Equatable, Sendable {
  public let text: String
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let cacheHitTokens: Int?
  public let cacheMissTokens: Int?
  public let reasoningTokens: Int?
  public let reasoningExecution: LLMReasoningExecution?

  public init(
    text: String,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    cacheHitTokens: Int? = nil,
    cacheMissTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    reasoningExecution: LLMReasoningExecution? = nil
  ) {
    self.text = text
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheHitTokens = cacheHitTokens
    self.cacheMissTokens = cacheMissTokens
    self.reasoningTokens = reasoningTokens
    self.reasoningExecution = reasoningExecution
  }
}

public struct LLMCallDiagnosticContext: Equatable, Sendable {
  public let role: String?
  public let purpose: String
  public let origin: String
  public let meetingHash: String?
  public let attempt: Int?
  public let retryGroup: String?

  public init(
    role: String? = nil,
    purpose: String,
    origin: String,
    meetingHash: String? = nil,
    attempt: Int? = nil,
    retryGroup: String? = nil
  ) {
    self.role = role
    self.purpose = purpose
    self.origin = origin
    self.meetingHash = meetingHash
    self.attempt = attempt
    self.retryGroup = retryGroup
  }
}

public enum LLMClientError: LocalizedError {
  case invalidEndpoint
  case insecureEndpoint
  case malformedResponse
  case reasoningOnlyResponse
  case emptyResponse
  /// 服务端以 HTTP 200 开流后,把错误塞进流里。
  case streamFailed(String)
  /// 流结束却没收到 `[DONE]`:内容可能只到一半,一律按失败处理,不交半截结果。
  case streamTruncated
  /// 请求发出后在约定时限内没等到**第一个数据帧**(心跳/注释帧不算)。
  /// 与 `URLRequest.timeoutInterval` 的空闲超时是两件事:那个管"两次字节之间",
  /// 这个管"发出请求 → 第一帧"。
  case firstFrameTimedOut(TimeInterval)
  /// 本次调用在时限内没有解码到新的非空 content / reasoning 增量。
  case progressTimedOut(TimeInterval)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "LLM Base URL 无法组成 chat/completions 地址"
    case .insecureEndpoint:
      return "LLM Base URL 必须使用 HTTPS"
    case .malformedResponse:
      return "LLM 返回格式无法解析"
    case .reasoningOnlyResponse:
      return "LLM 只返回了 reasoning_content，没有最终 content；请检查 thinking 配置或服务商输出参数"
    case .emptyResponse:
      return "LLM 没有返回可用文本"
    case .streamFailed(let message):
      return "LLM 流式响应中途报错：\(message)"
    case .streamTruncated:
      return "LLM 流式响应未正常结束（缺少结束标记），已生成的内容不完整，未采用"
    case .progressTimedOut:
      return "LLM 超过本轮无内容进展时限，本次已放弃"
    case .firstFrameTimedOut(let seconds):
      // 取整前先 round:阈值本就是整秒(生产值 45),四舍五入不会把 0.6 说成「0 秒」。
      return "LLM 在 \(Int(seconds.rounded())) 秒内没有返回任何数据（心跳不算），本次已放弃"
    }
  }
}

/// 一次生产调用的附加约定:诊断上下文、解码进展期限与增量观测。
public struct LLMCallOptions: Sendable {
  public var context: LLMCallDiagnosticContext?
  /// 无解码进展的期限(会中快/慢);nil 表示不设。只有 `streamsProgress` 的客户端执行它。
  public var progressTimeout: TimeInterval?
  /// 增量观测(会后纪要的思考/写作进度与 partial)。回调抛错不影响完成路径。
  public var onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?

  public init(
    context: LLMCallDiagnosticContext? = nil,
    progressTimeout: TimeInterval? = nil,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)? = nil
  ) {
    self.context = context
    self.progressTimeout = progressTimeout
    self.onStreamProgress = onStreamProgress
  }
}

public protocol LLMClient: Sendable {
  var configuration: LLMClientConfiguration { get }
  func complete(_ request: LLMRequest) async throws -> LLMResponse
  /// 生产调用入口(10-01 共同契约)。调用方一律经此派发,不按具体客户端类型分支。
  /// `streamsProgress` 为 true 的客户端必须执行 `options` 的进展期限并回调增量;
  /// 简单桩可用默认实现:按 `complete(_:)` 完整返回,不报增量。
  func complete(_ request: LLMRequest, options: LLMCallOptions) async throws -> LLMResponse
  /// true:本客户端流式解码,自行执行 `progressTimeout` 并经 `onStreamProgress` 报增量。
  /// false(默认):调用方为它套整轮时限,完成后自行补报一次写作进度。
  var streamsProgress: Bool { get }
  /// 设置页辅助能力:返回服务商可用模型列表。不支持或失败时返回 nil,
  /// 调用方必须降级为手填,不得因此阻断配置保存。
  func availableModels() async -> [String]?
  /// 会后纪要第二跳用的降档副本(10-06):长推理被切断后原样重放大概率再被切。
  /// 只改实际发出的档位,`requestedReasoningEffort` 保持用户所选;不能或不该降时返回 nil。
  /// 默认 nil:其他供应商与桩原样重试。
  func reasoningDowngradedForRetry() -> (any LLMClient)?
}

extension LLMClient {
  public func complete(_ request: LLMRequest, options: LLMCallOptions) async throws -> LLMResponse {
    try await complete(request)
  }

  public var streamsProgress: Bool { false }

  public func availableModels() async -> [String]? { nil }

  public func reasoningDowngradedForRetry() -> (any LLMClient)? { nil }
}

public struct OpenAICompatibleLLMClient: LLMClient {
  /// 会中总结的**首帧超时**。30 秒已被 2026-08-10 事故实证打穿(中转站排队/冷启动常落在
  /// 30–45 秒带,整轮 100% 失败并在网关记 `client_gone`);上界受快通道最坏检出预算约束,
  /// 见 `Verification/SummaryEngine/main.swift` 的预算不变量。
  public static let liveSummaryFirstFrameTimeout: TimeInterval = 45
  /// 会中总结的**字节空闲超时**。网关 keepalive 常见 15–30 秒,30 秒阈值与之贴脸;
  /// 60 秒留出裕量,同时仍能兜住"连响应头都不发"的死连接。
  public static let liveSummaryIdleTimeout: TimeInterval = 60

  public let configuration: LLMClientConfiguration
  /// **字节空闲**超时(落在 `URLRequest.timeoutInterval`):语义是"两次字节之间",
  /// 心跳帧天然重置它。注意它在收到任何字节**之前**同样在跑。
  public let idleTimeout: TimeInterval
  /// **首帧**超时:发出请求 → 第一个数据帧(reasoning 增量帧算数,心跳/注释帧不算)。
  /// `nil` = 不设首帧超时。
  public let firstFrameTimeout: TimeInterval?

  private let transport: any HTTPTransport
  private let diagnosticsLedger: DiagnosticEventLedger
  var reasoningFallback: ReasoningFallbackContext?

  /// `firstFrameTimeout` 默认 **nil 而不是 45**:本类型是会中总结与会后纪要共用的。
  /// 会后纪要开着推理档,2026-08-07 实测 91 分钟会议的英文纪要思考超过 300 秒才吐出
  /// 第一个 token——默认设死等于当场复刻那次"整场被标失败"的事故。首帧超时是**调用场景**
  /// 的属性,由构造方(`ProviderSettingsStore`)按角色显式打开。
  public init(
    configuration: LLMClientConfiguration,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    idleTimeout: TimeInterval = 30,
    firstFrameTimeout: TimeInterval? = nil,
    diagnosticsLedger: DiagnosticEventLedger = .shared
  ) {
    self.configuration = configuration
    self.transport = transport
    self.idleTimeout = idleTimeout
    self.firstFrameTimeout = firstFrameTimeout
    self.diagnosticsLedger = diagnosticsLedger
  }

  public func complete(_ request: LLMRequest) async throws -> LLMResponse {
    try await complete(request, context: nil, onStreamProgress: nil)
  }

  public var streamsProgress: Bool { true }

  public func complete(_ request: LLMRequest, options: LLMCallOptions) async throws -> LLMResponse {
    try await complete(
      request,
      context: options.context,
      progressTimeout: options.progressTimeout,
      onStreamProgress: options.onStreamProgress
    )
  }

  /// 流式完成;可选增量回调在**发出侧节流**(≥200ms 或字符增量阈值,取先到者)。
  /// 回调抛错被吞掉——进度是观测,不得成为完成路径的失败源。
  public func complete(
    _ request: LLMRequest,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?
  ) async throws -> LLMResponse {
    try await complete(
      request,
      context: nil,
      onStreamProgress: onStreamProgress
    )
  }

  public func complete(
    _ request: LLMRequest,
    context: LLMCallDiagnosticContext?,
    progressTimeout: TimeInterval? = nil,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)? = nil
  ) async throws -> LLMResponse {
    let role = context?.role ?? configuration.diagnosticRole
    let purpose = context?.purpose ?? configuration.diagnosticPurpose
    let origin = context?.origin ?? configuration.diagnosticOrigin
    let meetingHash = context?.meetingHash ?? configuration.diagnosticMeetingHash
    let attempt = context?.attempt
    let retryGroup = context?.retryGroup
    let callID = UUID().uuidString.lowercased()
    let startedAt = Date()
    let allowsFallback = configuration.providerID == "custom-openai-compatible"
    var knowledge =
      allowsFallback
      ? await reasoningFallback?.read() ?? ReasoningFallbackKnowledge()
      : ReasoningFallbackKnowledge()
    var execution =
      allowsFallback
      ? knowledge.resolve(configuration.reasoningEffort)
        ?? ReasoningAttempt(
          level: configuration.reasoningEffort,
          offStyle: knowledge.ignoredOffStyle ?? .enableThinking)
      : ReasoningAttempt(
        level: configuration.reasoningEffort,
        offStyle: configuration.providerID == "deepseek" ? .thinkingDisabled : .enableThinking)
    var wireReasoning: String {
      if execution.level == .off, execution.offStyle == .reasoningNone { return "none" }
      return Self.wireReasoningEffort(execution.level) ?? "off"
    }
    diagnosticsLedger.append(
      event: "modelCall.start",
      source: "OpenAICompatibleLLMClient",
      correlationID: callID,
      fields: DiagnosticEventFields(
        family: "llm",
        operation: "complete",
        role: role,
        purpose: purpose,
        origin: origin,
        meetingHash: meetingHash,
        providerID: configuration.providerID,
        model: configuration.model,
        endpointFingerprint: Self.endpointFingerprint(configuration.baseURL),
        requestedReasoning: configuration.requestedReasoningEffort.rawValue,
        effectiveReasoning: execution.level.rawValue,
        wireReasoning: wireReasoning,
        reasoningOffStyle: execution.level == .off ? execution.offStyle.rawValue : nil,
        stream: true,
        expectsJSON: request.expectsJSON,
        timeoutProfile:
          "idle=\(Int(idleTimeout))s;first=\(firstFrameTimeout.map { Int($0) } ?? 0)s"
          + (progressTimeout.map { ";progress=decodedIdle:\($0)s" } ?? ""),
        attempt: attempt,
        retryGroup: retryGroup
      )
    )
    do {
      let instrumented: InstrumentedResult
      var isFinalFallback = false
      while true {
        try Task.checkCancellation()
        do {
          instrumented = try await completeInstrumented(
            request,
            execution: execution,
            progressTimeout: progressTimeout,
            onStreamProgress: onStreamProgress,
            startedAt: startedAt
          )
          break
        } catch {
          if isFinalFallback || Task.isCancelled || error is CancellationError { throw error }
          // 上一写法被静默忽略但拿到过 200：探索新写法的任何失败都不能让调用比改动前更差。
          // 探索对象包括新的关闭写法，以及所有关法耗尽后改发的 low。
          if allowsFallback, configuration.reasoningEffort == .off,
            let ignored = knowledge.ignoredOffStyle,
            execution.level == .off
              ? execution.offStyle != ignored
                && !knowledge.confirmedOffStyles.contains(execution.offStyle)
              : execution.level == .low
                && knowledge.confirmedLevels[.off]?.contains(.low) != true
          {
            knowledge.recordExplorationFailure(
              execution, clientSide: Self.isClientSideFailure(error))
            if let reasoningFallback { knowledge = await reasoningFallback.merge(knowledge) }
            execution = ReasoningAttempt(level: .off, offStyle: ignored)
            isFinalFallback = true
            continue
          }
          guard allowsFallback, Self.isReasoningRejection(error, attempt: execution) else {
            throw error
          }
          knowledge.reject(execution)
          if let reasoningFallback { knowledge = await reasoningFallback.merge(knowledge) }
          guard let next = knowledge.resolve(configuration.reasoningEffort), next != execution
          else { throw error }
          execution = next
        }
      }
      if allowsFallback {
        if instrumented.response.reasoningExecution?.offIgnored == true {
          knowledge.reject(execution)
          knowledge.observedIgnoredOff = true
          knowledge.recordSuccess(execution)
          if execution.level == .off { knowledge.ignoredOffStyle = execution.offStyle }
        } else {
          knowledge.recordSuccess(execution)
          knowledge.confirmedLevels[configuration.reasoningEffort, default: []].insert(
            execution.level)
          if execution.level == .off { knowledge.confirmedOffStyles.insert(execution.offStyle) }
        }
        if let reasoningFallback { _ = await reasoningFallback.merge(knowledge) }
      }
      diagnosticsLedger.append(
        event: "modelCall.finish",
        source: "OpenAICompatibleLLMClient",
        correlationID: callID,
        fields: DiagnosticEventFields(
          family: "llm",
          operation: "complete",
          role: role,
          purpose: purpose,
          origin: origin,
          meetingHash: meetingHash,
          providerID: configuration.providerID,
          model: configuration.model,
          endpointFingerprint: Self.endpointFingerprint(configuration.baseURL),
          requestedReasoning: configuration.requestedReasoningEffort.rawValue,
          effectiveReasoning: instrumented.response.reasoningExecution?.effectiveLevel?.rawValue
            ?? "unknown",
          wireReasoning: wireReasoning,
          reasoningOffStyle: execution.level == .off ? execution.offStyle.rawValue : nil,
          stream: true,
          expectsJSON: request.expectsJSON,
          attempt: attempt,
          retryGroup: retryGroup,
          stage: "complete",
          outcome: "success",
          category: "success",
          outputSize: instrumented.response.text.utf8.count,
          inputTokens: instrumented.response.inputTokens,
          outputTokens: instrumented.response.outputTokens,
          cacheHitTokens: instrumented.response.cacheHitTokens,
          cacheMissTokens: instrumented.response.cacheMissTokens,
          reasoningTokens: instrumented.response.reasoningTokens,
          latencyMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
          firstFrameMs: instrumented.firstFrameMs,
          responseBytes: instrumented.responseBytes,
          charged: "completed"
        )
      )
      return instrumented.response
    } catch {
      let status = (error as? HTTPTransportError)?.statusCode
      diagnosticsLedger.append(
        event: "modelCall.finish",
        severity: .error,
        source: "OpenAICompatibleLLMClient",
        correlationID: callID,
        fields: DiagnosticEventFields(
          family: "llm",
          operation: "complete",
          role: role,
          purpose: purpose,
          origin: origin,
          meetingHash: meetingHash,
          providerID: configuration.providerID,
          model: configuration.model,
          endpointFingerprint: Self.endpointFingerprint(configuration.baseURL),
          requestedReasoning: configuration.requestedReasoningEffort.rawValue,
          effectiveReasoning: execution.level.rawValue,
          wireReasoning: wireReasoning,
          reasoningOffStyle: execution.level == .off ? execution.offStyle.rawValue : nil,
          stream: true,
          expectsJSON: request.expectsJSON,
          attempt: attempt,
          retryGroup: retryGroup,
          stage: Self.diagnosticStage(for: error),
          outcome: error is CancellationError ? "cancelled" : "failure",
          category: DiagnosticSanitizer.category(for: error),
          httpStatus: status,
          providerErrorCode: (error as? HTTPTransportError)?.providerErrorCode,
          latencyMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
          parseShape: Self.diagnosticParseShape(for: error),
          charged: error is CancellationError ? "unknown" : "possiblySent",
          safeErrorSummary: DiagnosticSanitizer.summary(for: error)
        )
      )
      throw error
    }
  }

  private func completeInstrumented(
    _ request: LLMRequest,
    execution: ReasoningAttempt,
    progressTimeout: TimeInterval?,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?,
    startedAt: Date
  ) async throws -> InstrumentedResult {
    guard let endpoint = Self.chatCompletionsURL(from: configuration.baseURL) else {
      throw LLMClientError.invalidEndpoint
    }
    guard endpoint.scheme?.lowercased() == "https" else {
      throw LLMClientError.insecureEndpoint
    }

    var urlRequest = URLRequest(
      url: endpoint,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: idleTimeout
    )
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue(
      "Bearer \(configuration.apiKey)",
      forHTTPHeaderField: "Authorization"
    )
    var messages: [Message] = []
    if !request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      messages.append(Message(role: "system", content: request.systemPrompt))
    }
    messages.append(Message(role: "user", content: request.userPrompt))
    let off = execution.level == .off
    let wireReasoning =
      off
      ? (execution.offStyle == .reasoningNone ? "none" : nil)
      : Self.wireReasoningEffort(execution.level)
    urlRequest.httpBody = try JSONEncoder().encode(
      ChatCompletionRequest(
        model: configuration.model,
        messages: messages,
        stream: true,
        // 流式默认不返回 usage;不显式索要就等于从此丢掉花销账本(既有红线)。
        streamOptions: StreamOptions(includeUsage: true),
        responseFormat: request.expectsJSON ? ResponseFormat(type: "json_object") : nil,
        enableThinking: off && execution.offStyle == .enableThinking ? false : nil,
        thinking: off && execution.offStyle == .thinkingDisabled
          ? ThinkingMode(type: "disabled") : nil,
        reasoningEffort: wireReasoning
      )
    )

    let accumulated = try await streamGuardedByLiveness(
      urlRequest,
      progressTimeout: progressTimeout,
      onStreamProgress: onStreamProgress,
      startedAt: startedAt
    )

    let text = accumulated.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      let reasoning = accumulated.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
      if !reasoning.isEmpty {
        throw LLMClientError.reasoningOnlyResponse
      }
      throw LLMClientError.emptyResponse
    }
    return InstrumentedResult(
      response: LLMResponse(
        text: text,
        inputTokens: accumulated.promptTokens,
        outputTokens: accumulated.completionTokens,
        cacheHitTokens: accumulated.cacheHitTokens,
        cacheMissTokens: accumulated.cacheMissTokens,
        reasoningTokens: accumulated.reasoningTokens,
        reasoningExecution: LLMReasoningExecution(
          requestedLevel: configuration.requestedReasoningEffort,
          effectiveLevel: off && accumulated.observedReasoning ? nil : execution.level,
          offStyle: off ? execution.offStyle : nil,
          offIgnored: off && accumulated.observedReasoning
        )
      ),
      firstFrameMs: accumulated.firstFrameMs,
      responseBytes: accumulated.responseBytes
    )
  }

  private struct InstrumentedResult {
    let response: LLMResponse
    let firstFrameMs: Int?
    let responseBytes: Int
  }

  /// 同一调用的 reader 与可选看门狗共用终态；开流前开始计时，退出时取消并等待子任务。
  /// 首帧仍按首个 data 负载解除；progress 只认成功解码的当前非空增量，与 UI 节流无关。
  /// 期限与终态语义在 `LLMStreamLiveness`,各协议适配器共用。
  private func streamGuardedByLiveness(
    _ urlRequest: URLRequest,
    progressTimeout: TimeInterval?,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?,
    startedAt: Date
  ) async throws -> AccumulatedStream {
    let transport = self.transport
    return try await LLMStreamLiveness.run(
      firstFrameTimeout: firstFrameTimeout,
      progressTimeout: progressTimeout,
      open: { try await transport.validatedLines(for: urlRequest) },
      consume: { stream, hooks in
        try await Self.consumeSSE(
          stream,
          onFirstFrame: hooks.onFirstFrame,
          onDecodedProgress: hooks.onDecodedProgress,
          onStreamProgress: onStreamProgress,
          startedAt: startedAt
        )
      }
    )
  }

  /// SSE 累积结果。用量为 nil 表示「这次没拿到」——与「这次没花钱(0)」是两回事,
  /// 上层记账要能区分,所以此处绝不用 0 兜底。
  private struct AccumulatedStream {
    var content = ""
    var reasoning = ""
    var observedReasoning = false
    var promptTokens: Int?
    var completionTokens: Int?
    var cacheHitTokens: Int?
    var cacheMissTokens: Int?
    var reasoningTokens: Int?
    var firstFrameMs: Int?
    var responseBytes = 0
  }

  /// 流式进度节流:时间间隔与字符增量阈值,取先到者。长文上万 delta 绝不能每个都回调。
  private static let streamProgressMinInterval: TimeInterval = 0.2
  private static let streamProgressCharThreshold = 32

  /// 按 SSE 规范消费:空行是事件边界,同一事件的多行 `data:` 拼接后才是一个负载。
  /// `[DONE]` 是 OpenAI 的约定、不属于 SSE 规范。
  ///
  /// 失败语义(半截内容一律不算成功——纪要是对客产物,半截比没有更危险):
  /// - 流里发来 error 帧(HTTP 仍可能是 200)-> 抛错;
  /// - 流结束却没见过 `[DONE]` -> 视为截断,抛错;
  /// - 上游抛错 -> 原样上抛。
  private static func consumeSSE(
    _ stream: AsyncThrowingStream<String, Error>,
    onFirstFrame: (@Sendable () -> Void)? = nil,
    onDecodedProgress: (@Sendable () throws -> Void)? = nil,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)? = nil,
    startedAt: Date = Date()
  ) async throws -> AccumulatedStream {
    var accumulated = AccumulatedStream()
    var eventDataLines: [String] = []
    var sawDone = false
    var signalledFirstFrame = false
    var lastProgressEmit = Date.distantPast
    var lastEmittedContentCount = -1
    var lastEmittedWasWriting = false

    /// 发出侧节流。回调抛错一律吞掉——观测不得拖垮完成路径。
    func emitProgressIfNeeded(force: Bool = false) {
      guard let onStreamProgress else { return }
      let contentCount = accumulated.content.count
      let hasReasoning = !accumulated.reasoning.isEmpty
      let progress: LLMStreamProgress?
      if contentCount > 0 {
        progress = .writing(
          characters: contentCount,
          accumulatedContent: accumulated.content
        )
      } else if hasReasoning {
        progress = .thinking
      } else {
        progress = nil
      }
      guard let progress else { return }

      let now = Date()
      let isWriting = contentCount > 0
      let transitionedToWriting = isWriting && !lastEmittedWasWriting
      let elapsedEnough =
        lastProgressEmit == Date.distantPast
        || now.timeIntervalSince(lastProgressEmit) >= streamProgressMinInterval
      let charsEnough =
        isWriting
        && (lastEmittedContentCount < 0
          || contentCount - lastEmittedContentCount >= streamProgressCharThreshold)
      guard force || transitionedToWriting || elapsedEnough || charsEnough else {
        return
      }

      do {
        try onStreamProgress(progress)
        lastProgressEmit = now
        lastEmittedWasWriting = isWriting
        if isWriting {
          lastEmittedContentCount = contentCount
        }
      } catch {
        // 进度是观测:回调失败不得成为管线失败源。
      }
    }

    /// 处理一个完整事件(已按空行切分)。返回 true 表示收到 `[DONE]`。
    func flushEvent() throws -> Bool {
      defer { eventDataLines.removeAll(keepingCapacity: true) }
      guard !eventDataLines.isEmpty else {
        return false
      }
      // 首帧 = 第一个**带负载的事件**:reasoning 增量帧同样算数(思考型模型正文来得晚,
      // 只认 content 会把健康的长思考流误杀)。心跳(`:`)与 `event:`/`id:` 字段进不了
      // `eventDataLines`,所以它们天然不解除看门狗。解除放在解码之前:流内 error 帧
      // 与畸形负载要报自己的错,不该去和首帧超时抢先。
      if !signalledFirstFrame {
        signalledFirstFrame = true
        accumulated.firstFrameMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        onFirstFrame?()
      }
      let payload = eventDataLines.joined(separator: "\n")
      if payload == "[DONE]" {
        // 末次尽量把最终字数推出去,避免 UI 停在节流窗口前的旧值。
        emitProgressIfNeeded(force: true)
        return true
      }
      guard let data = payload.data(using: .utf8) else {
        throw LLMClientError.malformedResponse
      }
      // 有些网关以 HTTP 200 开流,再把错误塞进流里。必须当失败处理。
      if let failure = try? JSONDecoder().decode(StreamErrorEnvelope.self, from: data),
        let message = failure.error.message
      {
        throw LLMClientError.streamFailed(message)
      }
      guard
        let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data),
        chunk.isRecognizable
      else {
        throw LLMClientError.malformedResponse
      }
      // 带 usage 的那一帧常见形态是 choices 为空数组(甚至整个键缺席),不能假定非空。
      if let delta = chunk.choices?.first?.delta {
        if delta.content?.isEmpty == false || delta.reasoningContent?.isEmpty == false {
          try onDecodedProgress?()
        }
        if let content = delta.content {
          accumulated.content += content
        }
        if let reasoning = delta.reasoningContent {
          accumulated.reasoning += reasoning
          if !reasoning.isEmpty { accumulated.observedReasoning = true }
        }
        if delta.content != nil || delta.reasoningContent != nil {
          emitProgressIfNeeded()
        }
      }
      if let usage = chunk.usage {
        accumulated.promptTokens = usage.promptTokens
        accumulated.completionTokens = usage.completionTokens
        accumulated.cacheHitTokens =
          usage.promptCacheHitTokens ?? usage.promptTokensDetails?.cachedTokens
        accumulated.cacheMissTokens = usage.promptCacheMissTokens
        accumulated.reasoningTokens = usage.completionTokensDetails?.reasoningTokens
        if (accumulated.reasoningTokens ?? 0) > 0 { accumulated.observedReasoning = true }
      }
      return false
    }

    var isFirstLine = true
    for try await line in stream {
      accumulated.responseBytes += line.utf8.count + 1
      var line = line
      if isFirstLine {
        isFirstLine = false
        // WHATWG SSE 规范:流首至多一个 U+FEFF(BOM)必须剥除。不剥的话,首行若是
        // `data:` 会被当成未知字段整帧丢弃——首块内容静默消失而 [DONE] 照常到达,
        // 半截文本就会被当成功返回,正好踩中「半截不交」红线。
        if line.hasPrefix("\u{FEFF}") {
          line.removeFirst()
        }
      }
      if line.isEmpty {
        if try flushEvent() {
          sawDone = true
        }
        continue
      }
      if line.hasPrefix(":") {
        // 注释/心跳:保持连接不静默,本身不携带负载。
        continue
      }
      guard line.hasPrefix("data:") else {
        // `event:` / `id:` 等其它字段本客户端用不到。
        continue
      }
      var value = String(line.dropFirst("data:".count))
      if value.hasPrefix(" ") {
        value.removeFirst()
      }
      eventDataLines.append(value)
    }
    // 末事件可能没有以空行收尾。
    if try flushEvent() {
      sawDone = true
    }

    guard sawDone else {
      throw LLMClientError.streamTruncated
    }
    return accumulated
  }

  /// 模型列表只用于设置辅助；兼容网关经常不实现 `/models`，失败时返回 nil，
  /// 让界面继续保留手填模型，而不是阻断配置保存。
  public func availableModels() async -> [String]? {
    let callID = UUID().uuidString.lowercased()
    let startedAt = Date()
    appendModelProbeStart(callID: callID)
    let endpoint = Self.modelsURL(from: configuration.baseURL)
    let endpointError: LLMClientError? =
      endpoint == nil
      ? .invalidEndpoint
      : (endpoint?.scheme?.lowercased() == "https" ? nil : .insecureEndpoint)
    if let endpointError {
      appendModelProbeFinish(
        callID: callID,
        startedAt: startedAt,
        error: endpointError
      )
      return nil
    }
    guard let endpoint else { return nil }
    var request = URLRequest(
      url: endpoint,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: idleTimeout
    )
    request.httpMethod = "GET"
    request.setValue(
      "Bearer \(configuration.apiKey)",
      forHTTPHeaderField: "Authorization"
    )
    do {
      let (data, _) = try await transport.validatedData(for: request)
      let response = try JSONDecoder().decode(ModelListResponse.self, from: data)
      diagnosticsLedger.append(
        event: "modelProbe.finish",
        source: "OpenAICompatibleLLMClient",
        correlationID: callID,
        fields: DiagnosticEventFields(
          family: "llm",
          operation: "modelList",
          role: configuration.diagnosticRole,
          purpose: "modelList",
          origin: configuration.diagnosticOrigin,
          providerID: configuration.providerID,
          model: configuration.model,
          endpointFingerprint: Self.endpointFingerprint(configuration.baseURL),
          requestedReasoning: "off",
          effectiveReasoning: "off",
          wireReasoning: "off",
          stage: "parse",
          outcome: "success",
          category: "success",
          outputSize: response.data.count,
          latencyMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
          responseBytes: data.count,
        )
      )
      return response.data.map(\.id)
    } catch {
      appendModelProbeFinish(callID: callID, startedAt: startedAt, error: error)
      return nil
    }
  }

  private func appendModelProbeFinish(callID: String, startedAt: Date, error: Error) {
    diagnosticsLedger.append(
      event: "modelProbe.finish",
      severity: .error,
      source: "OpenAICompatibleLLMClient",
      correlationID: callID,
      fields: DiagnosticEventFields(
        family: "llm",
        operation: "modelList",
        role: configuration.diagnosticRole,
        purpose: "modelList",
        origin: configuration.diagnosticOrigin,
        providerID: configuration.providerID,
        model: configuration.model,
        endpointFingerprint: Self.endpointFingerprint(configuration.baseURL),
        requestedReasoning: "off",
        effectiveReasoning: "off",
        wireReasoning: "off",
        stage: Self.diagnosticStage(for: error),
        outcome: "failure",
        category: DiagnosticSanitizer.category(for: error),
        httpStatus: (error as? HTTPTransportError)?.statusCode,
        providerErrorCode: (error as? HTTPTransportError)?.providerErrorCode,
        latencyMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
        parseShape: Self.diagnosticParseShape(for: error),
        safeErrorSummary: DiagnosticSanitizer.summary(for: error)
      )
    )
  }

  private func appendModelProbeStart(callID: String) {
    diagnosticsLedger.append(
      event: "modelProbe.start",
      source: "OpenAICompatibleLLMClient",
      correlationID: callID,
      fields: DiagnosticEventFields(
        family: "llm",
        operation: "modelList",
        role: configuration.diagnosticRole,
        purpose: "modelList",
        origin: configuration.diagnosticOrigin,
        providerID: configuration.providerID,
        model: configuration.model,
        endpointFingerprint: Self.endpointFingerprint(configuration.baseURL),
        requestedReasoning: "off",
        effectiveReasoning: "off",
        wireReasoning: "off",
        outcome: "started"
      )
    )
  }

  /// 中性档位 → OpenAI 兼容线上词面。**全项目唯一允许出现供应商词面的地方。**
  /// medium 与 xhigh 有既有调用证据；max 按官方文档开放手选，不进入默认路径。
  /// `.off` 返回 nil；关闭写法在请求编码处按供应商声明或自定义渠道识别结果翻译。
  /// 自定义渠道只按响应识别，不按模型名猜供应商。
  private static func wireReasoningEffort(_ level: ReasoningEffortLevel) -> String? {
    switch level {
    case .off:
      return nil
    case .low:
      return "low"
    case .medium:
      return "medium"
    case .high:
      return "high"
    case .xhigh:
      return "xhigh"
    case .max:
      return "max"
    }
  }

  private static func endpointFingerprint(_ url: URL) -> String {
    let scheme = url.scheme?.lowercased() ?? ""
    let host = url.host?.lowercased() ?? ""
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let digest = SHA256.hash(data: Data("\(scheme)://\(host)/\(path)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
  }

  private static func diagnosticStage(for error: Error) -> String {
    if error is DecodingError { return "parse" }
    guard let llm = error as? LLMClientError else { return "transport" }
    switch llm {
    case .malformedResponse, .emptyResponse, .reasoningOnlyResponse:
      return "parse"
    case .streamFailed, .streamTruncated:
      return "stream"
    case .invalidEndpoint, .insecureEndpoint:
      return "request"
    case .firstFrameTimedOut:
      return "transport"
    case .progressTimedOut:
      return "stream"
    }
  }

  private static func diagnosticParseShape(for error: Error) -> String? {
    switch error {
    case is DecodingError:
      return "json"
    case let llm as LLMClientError:
      switch llm {
      case .malformedResponse: return "sse"
      case .streamFailed: return "errorEnvelope"
      case .streamTruncated: return "missingDone"
      case .emptyResponse: return "emptyContent"
      case .reasoningOnlyResponse: return "reasoningOnly"
      default: return nil
      }
    default:
      return nil
    }
  }

  private static func chatCompletionsURL(from baseURL: URL) -> URL? {
    let trimmedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmedPath.hasSuffix("chat/completions") {
      return baseURL
    }
    return baseURL.appendingPathComponent("chat/completions")
  }

  private static func modelsURL(from baseURL: URL) -> URL? {
    let trimmedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmedPath.hasSuffix("chat/completions") {
      return
        baseURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("models")
    }
    return baseURL.appendingPathComponent("models")
  }
}

private struct ChatCompletionRequest: Encodable {
  let model: String
  let messages: [Message]
  let stream: Bool
  let streamOptions: StreamOptions?
  let responseFormat: ResponseFormat?
  let enableThinking: Bool?
  let thinking: ThinkingMode?
  let reasoningEffort: String?

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case stream
    case streamOptions = "stream_options"
    case responseFormat = "response_format"
    case enableThinking = "enable_thinking"
    case thinking
    case reasoningEffort = "reasoning_effort"
  }
}

private struct ThinkingMode: Encodable {
  let type: String
}

private struct StreamOptions: Encodable {
  let includeUsage: Bool

  enum CodingKeys: String, CodingKey {
    case includeUsage = "include_usage"
  }
}

/// 流式增量帧。`choices` 在带 usage 的末帧常见为空数组,故不假定非空。
private struct ChatCompletionChunk: Decodable {
  struct Choice: Decodable {
    struct Delta: Decodable {
      let content: String?
      let reasoningContent: String?

      enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
      }
    }
    let delta: Delta?
  }
  /// `choices` 缺席而非空数组:自建网关/转发器(LiteLLM、one-api 之类)的 usage 帧
  /// 形态不一,官方发 `"choices":[]`,转发器可能整个键都不发。若在此硬失败,代价是
  /// **整段纪要已经生成完、钱也花了,却因最后一帧的格式差异全场作废**——这是本单
  /// 最贵的失败模式,故按缺席容忍处理。
  let choices: [Choice]?
  let usage: ChatCompletionUsage?

  /// 容忍 `choices` 缺席不等于容忍空对象:`{}` 这类无法辨认的负载仍须判 malformed,
  /// 否则解析失效会伪装成"收到一个空帧"而静默通过。
  var isRecognizable: Bool {
    choices != nil || usage != nil
  }
}

/// 服务端以 200 开流后把错误塞进流里的形态。
private struct StreamErrorEnvelope: Decodable {
  struct Payload: Decodable {
    let message: String?
  }
  let error: Payload
}

private struct Message: Codable {
  let role: String
  let content: String
}

private struct ResponseFormat: Encodable {
  let type: String
}

private struct ChatCompletionUsage: Decodable {
  struct PromptDetails: Decodable {
    let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
      case cachedTokens = "cached_tokens"
    }
  }

  struct CompletionDetails: Decodable {
    let reasoningTokens: Int?

    enum CodingKeys: String, CodingKey {
      case reasoningTokens = "reasoning_tokens"
    }
  }

  let promptTokens: Int?
  let completionTokens: Int?
  let promptCacheHitTokens: Int?
  let promptCacheMissTokens: Int?
  let promptTokensDetails: PromptDetails?
  let completionTokensDetails: CompletionDetails?

  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case promptCacheHitTokens = "prompt_cache_hit_tokens"
    case promptCacheMissTokens = "prompt_cache_miss_tokens"
    case promptTokensDetails = "prompt_tokens_details"
    case completionTokensDetails = "completion_tokens_details"
  }
}

private struct ModelListResponse: Decodable {
  struct Model: Decodable {
    let id: String
  }

  let data: [Model]
}
