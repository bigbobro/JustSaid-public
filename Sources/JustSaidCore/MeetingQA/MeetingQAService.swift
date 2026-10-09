import Foundation

/// 一问的输入。转写与话题是提问那一刻的快照。
public struct MeetingQAQuestion: Sendable {
  public let question: String
  /// 提问时的会议计时(秒)。
  public let askedAt: TimeInterval
  public let history: [MeetingQAExchange]
  public let segments: [TranscriptSegment]
  public let topics: [SummaryTopic]
  public let meetingPaths: MeetingPaths?

  public init(
    question: String, askedAt: TimeInterval, history: [MeetingQAExchange],
    segments: [TranscriptSegment], topics: [SummaryTopic], meetingPaths: MeetingPaths?
  ) {
    self.question = question
    self.askedAt = askedAt
    self.history = history
    self.segments = segments
    self.topics = topics
    self.meetingPaths = meetingPaths
  }
}

public enum MeetingQAServiceError: LocalizedError {
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .timedOut: return "模型长时间没有回答，这一问已放弃"
    }
  }
}

/// 发出一问:组装上下文 → 流式调用 → 解析来源 → 写 `qa.jsonl` 与用量。
/// 失败也写一行 `qa.jsonl`(`outcome: failed`);请求可能已发出时记一笔失败用量(token 为 nil)。
public enum MeetingQAService {
  /// 流式客户端的无进展期限,与会中慢总结同口径。
  public static let progressTimeout: TimeInterval = 300
  /// 不报进展的客户端的整轮时限。
  public static let requestTimeout: TimeInterval = 300

  public static func ask(
    _ input: MeetingQAQuestion,
    client: any LLMClient,
    store: MeetingStore,
    onPartial: @escaping @Sendable (String) -> Void
  ) async throws -> MeetingQAAnswer {
    let context = await Task.detached(priority: .userInitiated) {
      MeetingQAContextBuilder.build(
        segments: input.segments, topics: input.topics, meetingPaths: input.meetingPaths,
        store: store)
    }.value
    try Task.checkCancellation()
    let request = LLMRequest(
      systemPrompt: MeetingQAPrompt.system,
      userPrompt: MeetingQAPrompt.user(
        context: context, history: input.history, question: input.question))
    let meetingHash =
      input.meetingPaths
      .flatMap { try? store.read(from: $0).id }
      .map(MeetingDiagnosticsPackageExporter.meetingHash)
    let options = LLMCallOptions(
      context: LLMCallDiagnosticContext(
        role: ProviderRole.liveSummaryLLM.rawValue,
        purpose: CloudUsageRecord.meetingQAPurpose,
        origin: "liveMeeting",
        meetingHash: meetingHash),
      progressTimeout: progressTimeout,
      onStreamProgress: { progress in
        if case .writing(_, let accumulated) = progress {
          onPartial(MeetingQAAnswerParser.streamingBody(accumulated))
        }
      })
    let response: LLMResponse
    do {
      response = try await complete(request, options: options, client: client)
    } catch {
      let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
      if let paths = input.meetingPaths {
        if !cancelled, !minutesFailureIsPreSend(error) {
          recordUsage(nil, client: client, store: store, paths: paths)
        }
        try? MeetingQALog.append(
          .turn(
            askedAt: input.askedAt, question: input.question, answer: "", sources: [],
            model: client.configuration.model, failed: true),
          to: paths)
      }
      throw error
    }
    let answer = MeetingQAAnswerParser.parse(response.text, context: context)
    if let paths = input.meetingPaths {
      recordUsage(response, client: client, store: store, paths: paths)
      try? MeetingQALog.append(
        .turn(
          askedAt: input.askedAt, question: input.question, answer: answer.body,
          sources: answer.sources, model: client.configuration.model, failed: false),
        to: paths)
    }
    return answer
  }

  private static func complete(
    _ request: LLMRequest, options: LLMCallOptions, client: any LLMClient
  ) async throws -> LLMResponse {
    if client.streamsProgress {
      return try await client.complete(request, options: options)
    }
    let response = try await withThrowingTaskGroup(of: LLMResponse.self) { group in
      group.addTask { try await client.complete(request, options: options) }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000))
        throw MeetingQAServiceError.timedOut
      }
      guard let result = try await group.next() else { throw MeetingQAServiceError.timedOut }
      group.cancelAll()
      return result
    }
    // 不报进展的客户端完成后补报一次,界面同一条路径刷新。
    try? options.onStreamProgress?(
      .writing(characters: response.text.count, accumulatedContent: response.text))
    return response
  }

  /// `response` 为 nil = 请求已发出但没有完成:token 保持 nil,不用 0 兜底。
  private static func recordUsage(
    _ response: LLMResponse?, client: any LLMClient, store: MeetingStore, paths: MeetingPaths
  ) {
    let configuration = client.configuration
    _ = try? store.appendUsage(
      CloudUsageRecord(
        role: .liveSummaryLLM,
        provider: configuration.providerID,
        model: configuration.model,
        inputTokens: response?.inputTokens,
        outputTokens: response?.outputTokens,
        cacheHitTokens: response?.cacheHitTokens,
        cacheMissTokens: response?.cacheMissTokens,
        reasoningTokens: response?.reasoningTokens,
        outcome: response == nil ? CloudUsageRecord.failedOutcome : nil,
        purpose: CloudUsageRecord.meetingQAPurpose,
        lane: configuration.lane?.usageLane,
        billingSource: configuration.billingSource
      ),
      to: paths
    )
  }
}
