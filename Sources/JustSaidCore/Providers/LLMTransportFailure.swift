import Foundation

/// 纪要 LLM 单跳调用失败的重试判决(08-20 传输韧性单 R1)。
///
/// 只服务会后纪要(`minutesLLM` 角色)的**管线层**重试;会中总结的正确语义是
/// "认输交给下一轮",绝不挂接本判决(design 边界拍板:重试不进共用客户端)。
public enum MinutesCallVerdict: Equatable, Sendable {
  /// 传输层失败:连接断在半路,供应商可能根本没收全/没送完,重试有意义。
  /// `reason` 是稳定子原因(如 `urlError(-1001)` / `streamTruncated`)。
  case retryable(reason: String)
  /// 服务端明确报错或响应不可用:重试大概率原样再失败,纯烧钱,交还用户。
  case terminal

  /// R2 失败痕 `kind` 的稳定字符串。写盘取值只有这两个,不随错误细节漂移。
  public var kind: String {
    switch self {
    case .retryable: return "transport"
    case .terminal: return "terminal"
    }
  }
}

/// 纯函数分类器(R1 判据,穷举断言在 BatchPipelineVerification)。
///
/// **白名单制:宁可漏重试,不可误重试花冤枉钱。** 可重试的只有 URLError 传输族
/// 六种 + `LLMClientError.streamTruncated`(流断在结尾,等价传输丢帧);
/// 其余一切——HTTP 非 2xx、流内报错 `streamFailed`、`malformedResponse`、
/// `emptyResponse`、`reasoningOnlyResponse`、配置类错误、取消——一律 terminal。
public func classifyMinutesFailure(_ error: Error) -> MinutesCallVerdict {
  if let urlError = error as? URLError {
    switch urlError.code {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet,
      .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
      return .retryable(reason: "urlError(\(urlError.code.rawValue))")
    default:
      return .terminal
    }
  }
  if let clientError = error as? LLMClientError,
    case .streamTruncated = clientError
  {
    return .retryable(reason: "streamTruncated")
  }
  return .terminal
}

/// R3 记账门:失败发生在**请求发出之前**(端点拼装 / HTTPS 校验)时不记 usage,
/// 只留 R2 失败痕——钱不可能已花。其余失败一律当"请求已发出"记一笔失败账。
public func minutesFailureIsPreSend(_ error: Error) -> Bool {
  guard let clientError = error as? LLMClientError else { return false }
  switch clientError {
  case .invalidEndpoint, .insecureEndpoint:
    return true
  default:
    return false
  }
}

/// R4:传输族自动重试耗尽后的用户可见错误。文案说人话并指明出路;
/// 底层错误细节已逐跳写入 `minutesFailureAttempts`,不再拼进用户文案。
public struct MinutesTransportExhaustedError: LocalizedError, Sendable {
  /// 最后一跳的底层错误描述(日志/排查用,不进用户文案)。
  public let underlyingDescription: String

  public init(underlying: Error) {
    underlyingDescription = underlying.localizedDescription
  }

  public var errorDescription: String? {
    "网络通道中断（常见于 VPN/代理环境），已自动重试仍失败；换个网络环境后可再试"
  }
}
