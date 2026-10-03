import Foundation

/// 请求使用的关闭写法。仅作运行时结果与诊断，不进入供应商配置持久化。
public enum ReasoningOffStyle: String, Sendable, CaseIterable {
  case enableThinking
  case reasoningNone
  case thinkingDisabled
}

public struct LLMReasoningExecution: Equatable, Sendable {
  public let requestedLevel: ReasoningEffortLevel
  /// 关闭被忽略时，只能确认仍在思考，不能猜出服务端的实际强度。
  public let effectiveLevel: ReasoningEffortLevel?
  public let offStyle: ReasoningOffStyle?
  public let offIgnored: Bool
}

struct ReasoningAttempt: Equatable, Sendable {
  let level: ReasoningEffortLevel
  var offStyle: ReasoningOffStyle = .enableThinking
}

/// 只累积明确的拒绝，不把成功的低档猜成模型上限。并发调用通过并集归并，避免晚回包复活已拒绝写法。
struct ReasoningFallbackKnowledge: Sendable, Equatable {
  var rejectedLevels: Set<ReasoningEffortLevel> = []
  var rejectedOffStyles: Set<ReasoningOffStyle> = []
  var confirmedLevels: [ReasoningEffortLevel: Set<ReasoningEffortLevel>] = [:]
  var confirmedOffStyles: Set<ReasoningOffStyle> = []
  var observedIgnoredOff = false
  /// 最近一个返回 200 但被静默忽略的关闭写法：探索新写法失败时，同一次调用回到它交付正文。
  var ignoredOffStyle: ReasoningOffStyle?
  /// 探索中的写法 / 档位连续失败次数（任意类型），成功清零；只在内存里，不持久化。
  var explorationFailures: [String: Int] = [:]
  static let maximumExplorationFailures = 2

  func resolve(_ requested: ReasoningEffortLevel) -> ReasoningAttempt? {
    let level = ReasoningEffortLevel.allCases.sorted().last {
      $0 <= requested && !rejectedLevels.contains($0)
    }
    guard let level else { return nil }
    if level != .off { return ReasoningAttempt(level: level) }
    if let style = ReasoningOffStyle.allCases.first(where: { !rejectedOffStyles.contains($0) }) {
      return ReasoningAttempt(level: .off, offStyle: style)
    }
    // 所有关法都不行时只试 low；low 已被明确拒绝则到底，不能在 off/low 间循环。
    return rejectedLevels.contains(.low) ? nil : ReasoningAttempt(level: .low)
  }

  mutating func reject(_ attempt: ReasoningAttempt) {
    if attempt.level == .off {
      rejectedOffStyles.insert(attempt.offStyle)
    } else {
      rejectedLevels.insert(attempt.level)
    }
  }

  private static func failureKey(_ attempt: ReasoningAttempt) -> String {
    attempt.level == .off ? "off." + attempt.offStyle.rawValue : attempt.level.rawValue
  }

  /// 明确的 4xx 立即拒绝；其它失败（5xx、流内错误、超时）连续第 2 次才拒绝，避免每次调用都白试一次。
  mutating func recordExplorationFailure(_ attempt: ReasoningAttempt, clientSide: Bool) {
    let key = Self.failureKey(attempt)
    let count = (explorationFailures[key] ?? 0) + 1
    explorationFailures[key] = count
    if clientSide || count >= Self.maximumExplorationFailures { reject(attempt) }
  }

  mutating func recordSuccess(_ attempt: ReasoningAttempt) {
    explorationFailures[Self.failureKey(attempt)] = 0
  }

  mutating func formUnion(_ other: Self) {
    rejectedLevels.formUnion(other.rejectedLevels)
    rejectedOffStyles.formUnion(other.rejectedOffStyles)
    for (requested, levels) in other.confirmedLevels {
      confirmedLevels[requested, default: []].formUnion(levels)
    }
    confirmedOffStyles.formUnion(other.confirmedOffStyles)
    observedIgnoredOff = observedIgnoredOff || other.observedIgnoredOff
    ignoredOffStyle = other.ignoredOffStyle ?? ignoredOffStyle
    for (key, count) in other.explorationFailures { explorationFailures[key] = count }
  }
}

/// Store 主 actor 拥有记忆；客户端跨 executor 只交换 Sendable 快照。
struct ReasoningFallbackContext: Sendable {
  let read: @Sendable () async -> ReasoningFallbackKnowledge
  let merge: @Sendable (ReasoningFallbackKnowledge) async -> ReasoningFallbackKnowledge
}

extension OpenAICompatibleLLMClient {
  /// 可归因于请求写法的 4xx；鉴权、超时、限流与 5xx / 网络错误是瞬时或无关问题，不该记为写法被拒。
  static func isClientSideFailure(_ error: Error) -> Bool {
    guard let transportError = error as? HTTPTransportError,
      case .unsuccessfulStatus(let status, _) = transportError
    else { return false }
    return (400..<500).contains(status) && ![401, 403, 408, 429].contains(status)
  }

  /// research 只证明明确的推理参数拒绝；不能仅凭 400 / invalid_parameter_error 或正文里出现 thinking 重试。
  static func isReasoningRejection(_ error: Error, attempt: ReasoningAttempt) -> Bool {
    guard let transportError = error as? HTTPTransportError,
      case .unsuccessfulStatus(400, let body) = transportError
    else { return false }
    let object = body.data(using: .utf8).flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    let detail = object?["error"] as? [String: Any] ?? object
    let message = (detail?["message"] as? String ?? (object == nil ? body : "")).lowercased()
    let code = (detail?["code"] as? String ?? detail?["type"] as? String ?? "").lowercased()
    let parameter = (detail?["param"] as? String)?.lowercased()
    let target: String
    switch (attempt.level, attempt.offStyle) {
    case (.off, .enableThinking): target = "enable_thinking"
    case (.off, .thinkingDisabled): target = "thinking"
    default: target = "reasoning_effort"
    }
    if let parameter, parameter != target && !(target == "thinking" && parameter == "thinking.type")
    {
      return false
    }
    // 百炼 error-code 原文的两个确定关闭拒绝；流式限制、thinking_budget/max_tokens 范围错误不在此列。
    if target == "enable_thinking" {
      if code == "invalidparameter.notsupportenablethinking"
        || message == "invalidparameter.notsupportenablethinking"
      {
        return true
      }
      if message.contains("the value of the enable_thinking parameter is restricted to true") {
        return true
      }
    }
    // 按完整参数标识匹配：thinking 不能误中 enable_thinking 或 thinking_budget。
    let namesTarget = message.range(of: "\\b" + target + "\\b", options: .regularExpression) != nil
    guard parameter != nil || namesTarget else { return false }
    // 文档未提供稳定 envelope 的供应商仅按明确拒绝语义识别，不猜 code 或模型身份。
    // 排除另一参数的约束，以及文档所述“仅支持流式”错误；它们不是换档可解决的问题。
    // 词边界匹配：聚合网关的 "upstream error" 不能误中 stream。
    let excluded = [
      "max_tokens", "max_completion_tokens", "thinking_budget", "stream", "temperature", "top_p",
    ]
    guard
      !excluded.contains(where: {
        message.range(of: "\\b" + $0 + "\\b", options: .regularExpression) != nil
      })
    else { return false }
    // 「未知参数」类措辞：上面已确认错误点名了本次发送的参数，才足以说明它被拒绝。
    let unknownPhrases = [
      "unrecognized", "unknown parameter", "unknown field", "unknown name", "unknown variant",
      "extra inputs are not permitted",
    ]
    return [
      "not support", "unsupported", "invalid value", "invalid parameter", "only support",
      "not allowed", "不支持", "仅支持", "无效的参数", "无效的值",
    ]
    .contains(where: { message.contains($0) })
      || unknownPhrases.contains(where: { message.contains($0) })
      || (code == "invalid_parameter_error" && parameter != nil)
  }
}
