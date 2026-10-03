import CryptoKit
import Foundation

/// Request-time identity for presentation only. Never contains credentials or response text.
public struct LLMFailureContext: Hashable, Sendable {
  public enum Feature: String, Sendable {
    case connectionTest, liveSummary, minutes, englishMinutes
    public var title: String {
      switch self {
      case .connectionTest: return "连接测试未通过"
      case .liveSummary: return "会中总结未更新"
      case .minutes: return "纪要未生成"
      case .englishMinutes: return "英文版纪要未生成"
      }
    }
  }
  public let feature: Feature
  public let role: ProviderRole?
  /// 三路配置下失败所属的用途;nil 时按 role 的旧对应理解(会中总结 = 快路)。
  public let lane: LLMLane?
  public let channelID: String?
  public let providerID: String?
  public let providerFingerprint: String?
  public let model: String?
  public let modelFingerprint: String?
  public let endpointFingerprint: String?
  public let occurredAt: Date?

  public init(
    feature: Feature, role: ProviderRole? = nil, lane: LLMLane? = nil, channelID: String? = nil,
    providerID: String? = nil, model: String? = nil, baseURL: String? = nil,
    occurredAt: Date? = Date()
  ) {
    self.feature = feature
    self.role = role ?? lane?.role
    self.lane = lane
    self.channelID = channelID
    self.providerID = providerID.map { DiagnosticSanitizer.token($0, fallback: "unknown") }
    self.providerFingerprint = providerID.map(Self.fingerprint)
    self.model = model.map { DiagnosticSanitizer.token($0, fallback: "unknown") }
    self.modelFingerprint = model.map(Self.fingerprint)
    self.endpointFingerprint = baseURL.map(Self.fingerprint)
    self.occurredAt = occurredAt
  }

  public init(feature: Feature, configuration: LLMClientConfiguration, occurredAt: Date? = Date()) {
    self.init(
      feature: feature, role: configuration.diagnosticRole.flatMap(ProviderRole.init(rawValue:)),
      lane: configuration.lane,
      channelID: configuration.recoveryChannelID, providerID: configuration.providerID,
      model: configuration.model, baseURL: configuration.baseURL.absoluteString,
      occurredAt: occurredAt)
  }

  private init(feature: Feature, copying context: Self) {
    self.feature = feature
    self.role = context.role
    self.lane = context.lane
    self.channelID = context.channelID
    self.providerID = context.providerID
    self.providerFingerprint = context.providerFingerprint
    self.model = context.model
    self.modelFingerprint = context.modelFingerprint
    self.endpointFingerprint = context.endpointFingerprint
    self.occurredAt = context.occurredAt
  }

  public func withFeature(_ feature: Feature) -> Self { Self(feature: feature, copying: self) }

  /// 失败所属的用途:显式 lane 优先,否则按旧角色对应(会中总结 = 快路)。
  public var effectiveLane: LLMLane? { lane ?? role.flatMap(LLMLane.init(role:)) }

  public static func fingerprint(_ value: String) -> String {
    String(
      SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
  }
}

/// A closed, display-only projection. It must never decide retries, billing or task outcomes.
public struct LLMRecoveryAdvice: Hashable, Sendable {
  public enum Cause: String, Sendable {
    case missingKey, missingModel, configuration, authentication, permission, quota, concurrency,
      rateLimit
    case unsupported, unavailable, offline, connection, unknown, history
    /// ChatGPT 计划用量(10-01):额度用尽;需要重新登录或开启计划用量授权。
    case chatGPTUsageLimit, chatGPTSignIn
  }
  public enum Action: String, Sendable {
    case steps, editKey, editModel, editConfiguration, chooseChannel, exportDiagnostics
    /// 打开 ChatGPT 用量设置(外部网页,不发请求)。
    case manageChatGPTUsage
    /// 打开该渠道的账户区,由用户重新登录。
    case signInChatGPT
  }
  public let cause: Cause
  public let context: LLMFailureContext
  public let httpStatus: Int?
  public let providerCode: String?
  public let eventID: String?

  public var channelIssue: Bool {
    [.authentication, .permission, .quota, .concurrency, .rateLimit, .unsupported, .unavailable]
      .contains(cause)
  }
  public var action: Action {
    switch cause {
    case .chatGPTUsageLimit: return .manageChatGPTUsage
    case .chatGPTSignIn: return .signInChatGPT
    case .missingKey: return .editKey
    case .missingModel: return .editModel
    case .configuration: return .editConfiguration
    case .unsupported where context.role != nil: return .chooseChannel
    case .connection, .unknown, .history: return .exportDiagnostics
    default: return .steps
    }
  }
  public var message: String {
    switch cause {
    case .chatGPTUsageLimit:
      return "ChatGPT 计划用量已达上限，可能是整个计划或本应用的额度"
    case .chatGPTSignIn: return "ChatGPT 授权不可用，需要重新登录或开启计划用量"
    case .missingKey: return "这个渠道还没有保存 API 密钥"
    case .missingModel: return "这次操作尚未选择模型，请填写或选择模型"
    case .configuration: return "渠道或模型配置不完整，请检查本次使用的配置"
    case .authentication: return "渠道未通过身份验证，请到渠道后台检查密钥有效性"
    case .permission: return "渠道拒绝了这次请求，请检查使用权限"
    case .quota: return "渠道可用额度不足，请检查余额或额度设置"
    case .concurrency: return "渠道提示并发已达上限，请检查上游并发限制"
    case .rateLimit: return "渠道提示请求过多，请检查上游并发限制"
    case .unsupported: return "渠道不支持这次请求，请联系渠道服务商，或更换渠道"
    case .unavailable: return "渠道无法处理当前请求，请检查渠道状态或联系渠道服务商"
    case .offline: return "当前未连接网络，请连接网络后再试"
    case .connection: return "连接未完成，原因尚不明确；请导出诊断包交给 JustSaid 开发者排查"
    case .unknown: return "暂时无法判断失败原因，请导出诊断包交给 JustSaid 开发者排查"
    case .history: return "历史失败缺少精确上下文，请导出诊断包交给 JustSaid 开发者排查"
    }
  }
  public var actionTitle: String {
    switch cause {
    case .chatGPTUsageLimit: return "管理用量"
    case .chatGPTSignIn: return "重新登录 ChatGPT"
    case .missingKey: return "填写密钥"
    case .missingModel: return "选择模型"
    case .configuration: return "检查配置"
    case .authentication: return "检查密钥有效性"
    case .permission: return "检查渠道权限"
    case .quota: return "检查额度"
    case .concurrency, .rateLimit: return "检查上游并发限制"
    case .unsupported: return context.role == nil ? "查看渠道排查步骤" : "更换渠道"
    case .unavailable: return "查看渠道排查步骤"
    case .offline: return "查看网络检查步骤"
    case .connection, .unknown, .history: return "导出诊断包"
    }
  }
  public var steps: [String] {
    switch cause {
    case .chatGPTUsageLimit:
      return [
        "在 ChatGPT 设置 → 用量里查看计划与本应用的额度，必要时调整本应用的上限。",
        "JustSaid 不会自动改用按量付费渠道；也可手动为这一路换一个渠道。",
      ]
    case .chatGPTSignIn:
      return ["在渠道管理里打开这个 ChatGPT 渠道，重新登录并允许使用计划用量。", "退出或在 ChatGPT 设置里断开过授权时，都需要重新登录。"]
    case .authentication:
      return ["到获取密钥的渠道后台核对密钥归属和有效性。", "如需替换 App 中的密钥，打开本次出错的渠道配置。", "仍被拒绝时，复制渠道排查信息交给渠道服务商。"]
    case .permission:
      if context.providerID == ChatGPTPlanContract.providerID {
        return [
          "检查当前 ChatGPT 账户、计划用量授权和应用注册配置。",
          "保留渠道排查信息联系 JustSaid 开发者；仅凭这次响应不能确认授权已撤销。",
        ]
      }
      return ["到渠道后台核对模型权限与账号限制；有分组时再核对当前分组。", "仅凭这次响应不能确定是哪项权限；可复制渠道排查信息联系服务商。"]
    case .quota:
      return ["到渠道后台检查余额、项目或账号的额度设置。", "尚不能确定余额为零；以渠道后台提示为准。"]
    case .concurrency, .rateLimit:
      return ["到渠道后台检查同时允许的请求数及调用频率限制。", "具体原因未确认时，同时核对额度提示；必要时联系渠道服务商。", "可减少同时运行的任务或稍后手动重试。"]
    case .unsupported, .unavailable:
      return ["到渠道后台检查当前状态及出错时刻的日志。", "复制渠道排查信息交给渠道服务商；也可手动更换渠道。"]
    case .offline:
      return ["检查本机网络是否已连接，再按原入口重试。", "若网络恢复后仍失败，可导出诊断包。"]
    case .missingKey, .missingModel, .configuration:
      if context.providerID == ChatGPTPlanContract.providerID {
        return [
          "检查本次失败使用的 ChatGPT 渠道、模型和推理档位。",
          "若提示应用注册配置无效，请保留渠道排查信息联系 JustSaid 开发者。",
        ]
      }
      return ["检查本次失败使用的渠道、模型和已保存密钥。", "配置修改需要明确保存，查看本提示不会发起请求。"]
    default:
      return ["直接导出诊断包，无需先测试渠道。", "请将诊断包发送给 JustSaid 开发者；应用不会自动上传。"]
    }
  }

  public func supportText(version: String) -> String {
    var lines = [
      "JustSaid \(version)", "功能：\(context.feature.title)",
      "时间：\(context.occurredAt.map { ISO8601DateFormatter().string(from: $0) } ?? "历史发生时间未取得")",
      "原因：\(cause.rawValue)",
      message,
    ]
    if let role = context.role { lines.append("角色：\(role.rawValue)") }
    if let provider = context.providerID { lines.append("供应商标识：\(provider)") }
    if let model = context.model { lines.append("模型：\(model)") }
    if let fingerprint = context.modelFingerprint { lines.append("模型指纹：\(fingerprint)") }
    if let endpoint = context.endpointFingerprint { lines.append("端点指纹：\(endpoint)") }
    if let httpStatus { lines.append("HTTP：\(httpStatus)") }
    if let providerCode { lines.append("渠道短码：\(providerCode)") }
    if let eventID {
      lines.append("本机事件编号：\(eventID)")
    } else {
      lines.append("本机事件编号：未取得；服务商请求编号：未取得")
    }
    return lines.joined(separator: "\n")
  }

  public static func history(feature: LLMFailureContext.Feature, occurredAt: Date? = nil) -> Self {
    Self(
      cause: .history, context: .init(feature: feature, occurredAt: occurredAt), httpStatus: nil,
      providerCode: nil,
      eventID: nil)
  }

  public static func project(_ error: Error, context: LLMFailureContext) -> Self? {
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
    if let exhausted = error as? MinutesTransportExhaustedError,
      let advice = exhausted.recoveryAdvice
    {
      return advice
    }
    var cause: Cause = .unknown
    var status: Int?
    var code: String?
    if let configuration = error as? ProviderRuntimeConfigurationError {
      switch configuration {
      case .missingSecret: cause = .missingKey
      case .missingModel: cause = .missingModel
      default: cause = .configuration
      }
    } else if let configuration = error as? ProviderChannelError {
      switch configuration {
      case .missingChannelSecret: cause = .missingKey
      case .missingChannelModel: cause = .missingModel
      default: cause = .configuration
      }
    } else if let unavailable = error as? ChatGPTPlanUnavailable {
      switch unavailable {
      case .notSignedIn, .planUsageNotGranted, .reauthorizationRequired: cause = .chatGPTSignIn
      case .usageLimitPaused: cause = .chatGPTUsageLimit
      case .credentialsUnavailable, .accountChanged: cause = .unavailable
      case .clientConfigurationInvalid, .modelNotInCatalog, .reasoningCapabilityUnknown,
        .reasoningLevelUnsupported:
        cause = .configuration
      }
    } else if let service = error as? ChatGPTPlanServiceError {
      status = service.httpStatus
      code = service.code
      switch service.kind {
      case .usageLimitExceeded: cause = .chatGPTUsageLimit
      case .invalidUser, .notAuthorized: cause = .permission
      case .usageUnavailable, .userUnavailable: cause = .unavailable
      case .notEligible, .routeNotSupported: cause = .permission
      case .unsupportedCapability: cause = .unsupported
      case .admissionRejected:
        cause = service.httpStatus == 503 ? .unavailable : .permission
      case .responseFailed, .responseIncomplete, .refused, .other: cause = .unknown
      }
    } else if let url = error as? URLError {
      cause = url.code == .notConnectedToInternet ? .offline : .connection
    } else if let http = error as? HTTPTransportError,
      case .unsuccessfulStatus(let value, let body) = http
    {
      status = value
      // Bounded JSON, closed code allowlist, and status-compatible refinement only.
      let refinements = recognizedCodes(body: body, status: value)
      if Set(refinements.map(\.1)).count == 1, let first = refinements.first {
        code = first.0
        cause = first.1
      } else {
        switch value {
        case 401: cause = .authentication
        case 403: cause = .permission
        case 429: cause = .rateLimit
        case 501: cause = .unsupported
        case 500, 502, 503, 504: cause = .unavailable
        default: cause = .unknown
        }
      }
    } else if let client = error as? LLMClientError {
      switch client {
      case .invalidEndpoint, .insecureEndpoint: cause = .configuration
      default: cause = .unknown
      }
    }
    return Self(
      cause: cause, context: context, httpStatus: status, providerCode: code, eventID: nil)
  }

  private static func recognizedCodes(body: String, status: Int) -> [(String, Cause)] {
    guard body.utf8.count <= 16_384, let data = body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }
    let nested = object["error"] as? [String: Any]
    let candidates = [object["code"], nested?["code"], nested?["type"]].compactMap { $0 as? String }
    let quota: Set<String> = [
      "insufficient_quota", "quota_exceeded", "insufficient_balance", "balance_not_enough",
    ]
    let concurrency: Set<String> = ["concurrency_limit_exceeded", "too_many_concurrent_requests"]
    let rate: Set<String> = ["rate_limit_exceeded", "rate_limit_error", "too_many_requests"]
    return candidates.compactMap { code in
      if [402, 429].contains(status), quota.contains(code) { return (code, .quota) }
      if status == 429, concurrency.contains(code) { return (code, .concurrency) }
      if status == 429, rate.contains(code) { return (code, .rateLimit) }
      return nil
    }
  }
}

extension ProviderSettingsStore {
  /// Read before beginning an async operation; does not read secrets.
  public func failureContext(feature: LLMFailureContext.Feature, role: ProviderRole)
    -> LLMFailureContext
  {
    let selection = configuration.selection(for: role)
    let channel = selection.flatMap { configuration.channel(id: $0.channelID) }
    return LLMFailureContext(
      feature: feature, role: role, channelID: selection?.channelID,
      providerID: channel?.providerID, model: selection?.model, baseURL: channel?.baseURL)
  }

  /// 按用途读取失败上下文:慢路失败对照慢路选择,不拿快路的渠道/模型去比。
  public func failureContext(feature: LLMFailureContext.Feature, lane: LLMLane)
    -> LLMFailureContext
  {
    let selection = configuration.selection(for: lane)
    let channel = selection.flatMap { configuration.channel(id: $0.channelID) }
    return LLMFailureContext(
      feature: feature, role: lane.role, lane: lane, channelID: selection?.channelID,
      providerID: channel?.providerID, model: selection?.model, baseURL: channel?.baseURL)
  }
}
