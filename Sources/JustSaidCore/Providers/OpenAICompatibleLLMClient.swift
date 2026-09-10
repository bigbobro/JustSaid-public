import CryptoKit
import Foundation
import Synchronization

public struct LLMClientConfiguration: Equatable, Sendable {
  public let providerID: String
  public let baseURL: URL
  public let apiKey: String
  public let model: String
  /// 已经过供应商能力协商的**最终**档位:客户端只负责翻译成线上格式,不再做降级判断。
  public let reasoningEffort: ReasoningEffortLevel
  public let requestedReasoningEffort: ReasoningEffortLevel
  /// 诊断上下文只包含闭合身份词，不承载 prompt/转写。
  public let diagnosticRole: String?
  public let diagnosticPurpose: String?
  public let diagnosticOrigin: String?
  public let diagnosticMeetingHash: String?

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
    diagnosticMeetingHash: String? = nil
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

  public init(text: String, inputTokens: Int? = nil, outputTokens: Int? = nil) {
    self.text = text
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
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

public protocol LLMClient: Sendable {
  var configuration: LLMClientConfiguration { get }
  func complete(_ request: LLMRequest) async throws -> LLMResponse
  /// 设置页辅助能力:返回服务商可用模型列表。不支持或失败时返回 nil,
  /// 调用方必须降级为手填,不得因此阻断配置保存。
  func availableModels() async -> [String]?
}

extension LLMClient {
  public func availableModels() async -> [String]? { nil }
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
    let wireReasoning = Self.wireReasoningEffort(configuration.reasoningEffort) ?? "off"
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
        effectiveReasoning: configuration.reasoningEffort.rawValue,
        wireReasoning: wireReasoning,
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
      let instrumented = try await completeInstrumented(
        request,
        wireReasoning: wireReasoning,
        progressTimeout: progressTimeout,
        onStreamProgress: onStreamProgress,
        startedAt: startedAt
      )
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
          effectiveReasoning: configuration.reasoningEffort.rawValue,
          wireReasoning: wireReasoning,
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
          effectiveReasoning: configuration.reasoningEffort.rawValue,
          wireReasoning: wireReasoning,
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
    wireReasoning: String,
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
    urlRequest.httpBody = try JSONEncoder().encode(
      ChatCompletionRequest(
        model: configuration.model,
        messages: [
          Message(role: "system", content: request.systemPrompt),
          Message(role: "user", content: request.userPrompt),
        ],
        stream: true,
        // 流式默认不返回 usage;不显式索要就等于从此丢掉花销账本(既有红线)。
        streamOptions: StreamOptions(includeUsage: true),
        responseFormat: request.expectsJSON ? ResponseFormat(type: "json_object") : nil,
        enableThinking: configuration.thinkingEnabled ? nil : false,
        reasoningEffort: wireReasoning == "off" ? nil : wireReasoning
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
        outputTokens: accumulated.completionTokens
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
  private func streamGuardedByLiveness(
    _ urlRequest: URLRequest,
    progressTimeout: TimeInterval?,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?,
    startedAt: Date
  ) async throws -> AccumulatedStream {
    guard let progressTimeout else {
      return try await streamGuardedByFirstFrame(
        urlRequest, onStreamProgress: onStreamProgress, startedAt: startedAt
      )
    }
    let lifetime = try StreamLifetime(progressTimeout: progressTimeout)
    let transport = self.transport
    return try await withTaskCancellationHandler {
      do {
        return try await withThrowingTaskGroup(of: AccumulatedStream?.self) { group in
          defer { group.cancelAll() }
          group.addTask {
            do {
              try Task.checkCancellation()
              let stream = try await transport.validatedLines(for: urlRequest)
              let accumulated = try await Self.consumeSSE(
                stream,
                onFirstFrame: { lifetime.markFirstFrame() },
                onDecodedProgress: { try lifetime.renewProgress() },
                onStreamProgress: onStreamProgress,
                startedAt: startedAt
              )
              try Task.checkCancellation()
              try lifetime.finish()
              return accumulated
            } catch {
              try lifetime.finish(error: error)
              throw error
            }
          }
          if let firstFrameTimeout {
            group.addTask {
              try await Task.sleep(
                nanoseconds: UInt64(max(0, firstFrameTimeout) * 1_000_000_000)
              )
              try lifetime.checkFirstFrame(timeout: firstFrameTimeout)
              return nil
            }
          }
          group.addTask {
            while let remaining = try lifetime.remainingProgress() {
              try await Task.sleep(nanoseconds: remaining)
            }
            return nil
          }
          while let finished = try await group.next() {
            // 已解除的看门狗不是 LLM 结果；继续等 reader。
            if let accumulated = finished { return accumulated }
          }
          throw CancellationError()
        }
      } catch {
        // 超时拥有终态后，它取消 reader 产生的 CancellationError 不能反客为主。
        try lifetime.finish(error: error)
        throw error
      }
    } onCancel: {
      try? lifetime.finish(error: CancellationError())
    }
  }

  /// 所有状态都在短临界区中更新；不跨 await / 外部回调持锁，也不为每帧创建任务。
  private final class StreamLifetime: Sendable {
    private enum Terminal {
      case completed
      case failed(Error)
    }

    private struct State {
      var firstFrameReceived = false
      var deadline: UInt64
      var terminal: Terminal?
    }

    private let progressTimeout: TimeInterval
    private let interval: UInt64
    private let state: Mutex<State>

    init(progressTimeout: TimeInterval) throws {
      self.progressTimeout = progressTimeout
      guard progressTimeout.isFinite, progressTimeout >= 0,
        let interval = UInt64(exactly: (progressTimeout * 1_000_000_000).rounded(.down))
      else { throw LLMClientError.progressTimedOut(progressTimeout) }
      let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
        interval)
      guard !overflow else { throw LLMClientError.progressTimedOut(progressTimeout) }
      self.interval = interval
      state = Mutex(State(deadline: deadline))
    }

    func markFirstFrame() {
      state.withLock {
        guard case nil = $0.terminal else { return }
        $0.firstFrameReceived = true
      }
    }

    func renewProgress() throws {
      try state.withLock { state in
        let now = DispatchTime.now().uptimeNanoseconds
        guard try isActive(&state, now: now) else { return }
        let (deadline, overflow) = now.addingReportingOverflow(interval)
        guard !overflow else {
          let error = LLMClientError.progressTimedOut(progressTimeout)
          state.terminal = .failed(error)
          throw error
        }
        state.deadline = deadline
      }
    }

    func remainingProgress() throws -> UInt64? {
      try state.withLock { state in
        let now = DispatchTime.now().uptimeNanoseconds
        guard try isActive(&state, now: now) else { return nil }
        return state.deadline - now
      }
    }

    func checkFirstFrame(timeout: TimeInterval) throws {
      try state.withLock { state in
        guard try isActive(&state, now: DispatchTime.now().uptimeNanoseconds),
          !state.firstFrameReceived
        else { return }
        let error = LLMClientError.firstFrameTimedOut(timeout)
        state.terminal = .failed(error)
        throw error
      }
    }

    func finish(error: Error? = nil) throws {
      try state.withLock { state in
        guard try isActive(&state, now: DispatchTime.now().uptimeNanoseconds) else { return }
        if let error {
          state.terminal = .failed(error)
          throw error
        }
        state.terminal = .completed
      }
    }

    /// 到期本身即终态；即使看门狗暂未被调度，晚到的增量也不能续命。
    private func isActive(_ state: inout State, now: UInt64) throws -> Bool {
      switch state.terminal {
      case .completed?: return false
      case .failed(let error)?: throw error
      case nil: break
      }
      if now >= state.deadline {
        let error = LLMClientError.progressTimedOut(progressTimeout)
        state.terminal = .failed(error)
        throw error
      }
      return true
    }
  }

  /// 开流并消费,附带**首帧看门狗**。
  ///
  /// 看门狗只睡一觉:醒来时首帧已到就自行退场(此后是否被砍由空闲超时说了算——长内容
  /// **不得**因为总时长超过首帧阈值被砍);首帧未到才抛错,连带取消开流任务。
  /// `firstFrameTimeout == nil` 时完全不起任务组,路径与改动前逐字一致。
  private func streamGuardedByFirstFrame(
    _ urlRequest: URLRequest,
    onStreamProgress: (@Sendable (LLMStreamProgress) throws -> Void)?,
    startedAt: Date
  ) async throws -> AccumulatedStream {
    guard let firstFrameTimeout else {
      let stream = try await transport.validatedLines(for: urlRequest)
      return try await Self.consumeSSE(
        stream,
        onStreamProgress: onStreamProgress,
        startedAt: startedAt
      )
    }
    let latch = FirstFrameLatch()
    let transport = self.transport
    return try await withThrowingTaskGroup(of: AccumulatedStream?.self) { group in
      group.addTask {
        // 开流与消费放同一个子任务:首帧超时因此覆盖握手与响应头,而流不跨任务边界。
        let stream = try await transport.validatedLines(for: urlRequest)
        return try await Self.consumeSSE(
          stream,
          onFirstFrame: { latch.mark() },
          onStreamProgress: onStreamProgress,
          startedAt: startedAt
        )
      }
      group.addTask {
        try await Task.sleep(
          nanoseconds: UInt64(max(0, firstFrameTimeout) * 1_000_000_000)
        )
        guard latch.isMarked else {
          throw LLMClientError.firstFrameTimedOut(firstFrameTimeout)
        }
        return nil
      }
      while let finished = try await group.next() {
        guard let accumulated = finished else {
          // 看门狗解除,继续等真正的结果。
          continue
        }
        group.cancelAll()
        return accumulated
      }
      // 消费任务只会返回结果或抛错;走到这里说明整个任务组被外部取消了。
      throw CancellationError()
    }
  }

  /// 首帧是否到达的一次性标记。看门狗睡醒时读一次,消费侧写一次,用最简单的锁即可。
  private final class FirstFrameLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
      lock.lock()
      marked = true
      lock.unlock()
    }

    var isMarked: Bool {
      lock.lock()
      defer { lock.unlock() }
      return marked
    }
  }

  /// SSE 累积结果。用量为 nil 表示「这次没拿到」——与「这次没花钱(0)」是两回事,
  /// 上层记账要能区分,所以此处绝不用 0 兜底。
  private struct AccumulatedStream {
    var content = ""
    var reasoning = ""
    var promptTokens: Int?
    var completionTokens: Int?
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
        }
        if delta.content != nil || delta.reasoningContent != nil {
          emitProgressIfNeeded()
        }
      }
      if let usage = chunk.usage {
        accumulated.promptTokens = usage.promptTokens
        accumulated.completionTokens = usage.completionTokens
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
  /// `medium` 是本项目一直在发的值;最高档词面由用户 2026-08-06 在其自定义网关实测确认。
  /// `.off` 返回 nil,该字段缺省(维持改动前语义,配合 `enable_thinking: false`)。
  /// Claude(思考预算 token 数)与 Grok 尚未接入,取值以接入时实测为准,此处不预写。
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
    case .max:
      return "xhigh"
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
  let reasoningEffort: String?

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case stream
    case streamOptions = "stream_options"
    case responseFormat = "response_format"
    case enableThinking = "enable_thinking"
    case reasoningEffort = "reasoning_effort"
  }
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
  let promptTokens: Int?
  let completionTokens: Int?

  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
  }
}

private struct ModelListResponse: Decodable {
  struct Model: Decodable {
    let id: String
  }

  let data: [Model]
}
