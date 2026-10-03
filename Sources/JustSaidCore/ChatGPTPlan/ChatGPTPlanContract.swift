import Foundation

/// ChatGPT 计划用量渠道(Sign in with ChatGPT,开源本地 direct flow)的固定契约。
///
/// 端点写死并与 2026-10-01 的发现文档核对过(`.trellis/tasks/10-01-chatgpt-oauth-responses/
/// research/openai-siwc/`)。**令牌只发往这里列出的地址**:渠道的 baseURL 仅作展示,
/// 不参与拼装,避免可轮换凭证被送到用户可改的地址。
public enum ChatGPTPlanContract {
  public static let providerID = "chatgpt-plan"
  public static let issuer = "https://auth.openai.com"
  static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
  static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
  static let revokeURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
  static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
  /// 推理与模型目录的资源地址;也作为 OAuth `resource` 参数。
  public static let apiBaseURL = URL(string: "https://api.openai.com/v1")!
  static let resource = "https://api.openai.com/v1"
  static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
  static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
  /// 首次注册的入口 client ID;**不能**保存或拿去换码。
  static let dynamicClientID = "dynamic_agent_client"
  /// 首次注册时的应用名提示(用户可在授权页改名),各安装一致。
  static let agentNameHint = "JustSaid"
  static let callbackPath = "/auth/callback"
  /// 身份 + 计划用量的完整 scope 集合;是否获准计划用量以 token 响应的 scope 为准。
  static let scopes =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  static let planUsageScope = "chatgpt.tokens.use.direct"
  /// 用户管理计划用量与本应用额度的官方页面。
  public static let usageSettingsURL = URL(string: "https://chatgpt.com/settings/usage")!
  /// 用量记录与诊断里的计费来源标识(区别于按量 API)。
  public static let billingSource = "chatgptPlan"
}

/// 推理请求**发出之前**就确定的失败:不产生推理用量,恢复动作指向重新登录或换选择,
/// 不指向「修改 API Key」。
public enum ChatGPTPlanUnavailable: LocalizedError, LLMRequestNotSentError, Equatable, Sendable {
  /// 渠道还没有登录过,或已退出。
  case notSignedIn
  /// 已登录身份,但授权里没有 ChatGPT 计划用量许可。
  case planUsageNotGranted
  /// 授权已失效(刷新被拒、会话被撤销或已在 ChatGPT 设置里断开),需要重新登录。
  case reauthorizationRequired
  /// 暂时取不到可用凭证(钥匙串读取失败、刷新时网络或服务暂不可用);凭证保留,稍后再试。
  case credentialsUnavailable
  /// OAuth 客户端配置被拒,保留当前凭证,排查注册而不是反复登录。
  case clientConfigurationInvalid
  /// 调用开始后账户已退出或更换,本次不会改用另一个账户继续。
  case accountChanged
  case modelNotInCatalog(model: String)
  /// 模型目录与官方模型契约都没有给出该模型可用的推理档位。
  case reasoningCapabilityUnknown(model: String)
  case reasoningLevelUnsupported(model: String, level: ReasoningEffortLevel)
  /// 刚收到用量上限错误:本账户在一段退避期内不再发新请求(不是对套餐重置时间的推断)。
  case usageLimitPaused

  public var errorDescription: String? {
    switch self {
    case .usageLimitPaused:
      return "ChatGPT 计划用量已达上限，暂停发送新请求；可在 ChatGPT 用量设置里查看"
    case .notSignedIn:
      return "ChatGPT 渠道还没有登录，请在渠道管理里继续使用 ChatGPT 登录"
    case .planUsageNotGranted:
      return "已登录 ChatGPT，但没有开启使用 ChatGPT 计划用量的授权"
    case .reauthorizationRequired:
      return "ChatGPT 授权已失效，请重新登录"
    case .credentialsUnavailable:
      return "暂时取不到 ChatGPT 授权，凭证已保留，请稍后再试"
    case .clientConfigurationInvalid:
      return "ChatGPT 应用注册配置未通过验证，凭证已保留；请检查应用版本与注册配置"
    case .accountChanged:
      return "调用开始后 ChatGPT 账户已退出或更换，本次已停止"
    case .modelNotInCatalog(let model):
      return "当前 ChatGPT 账户的模型目录里没有「\(model)」，请重新选择模型"
    case .reasoningCapabilityUnknown(let model):
      return "无法确认「\(model)」支持哪些推理档位，暂不能用于调用"
    case .reasoningLevelUnsupported(let model, let level):
      return "「\(model)」不支持推理档位「\(level.displayName)」，请换一个档位"
    }
  }
}

/// 推理请求已发出后,ChatGPT 计划用量路径返回的失败。保留 HTTP 状态、机器错误码、
/// 参数与请求 ID;**不保存**可能含会议内容的响应正文。
public struct ChatGPTPlanServiceError: LocalizedError, Equatable, Sendable {
  public enum Kind: String, Sendable {
    /// 计划或本应用的用量额度已用尽(可能在开流后才报)。
    case usageLimitExceeded
    /// 暂时无法确认用量可用性。
    case usageUnavailable
    /// 该用户、工作区或策略不允许计划用量。
    case notEligible
    /// 请求用了该路径不支持的输入、工具、模型或档位;同一请求不应重试。
    case unsupportedCapability
    case routeNotSupported
    /// 订阅身份无法验证,需排查凭证。
    case invalidUser
    /// 签名的许可上下文不允许此操作。
    case notAuthorized
    case userUnavailable
    /// 开流前的直连准入拒绝(401/403/503,可能只有 detail 文本)。
    case admissionRejected
    case responseFailed
    case responseIncomplete
    case refused
    case other
  }

  public let kind: Kind
  public let httpStatus: Int?
  public let code: String?
  public let param: String?
  public let requestID: String?

  public init(
    kind: Kind, httpStatus: Int? = nil, code: String? = nil, param: String? = nil,
    requestID: String? = nil
  ) {
    self.kind = kind
    self.httpStatus = httpStatus
    self.code = code
    self.param = param
    self.requestID = requestID
  }

  public var errorDescription: String? {
    switch kind {
    case .usageLimitExceeded:
      return "ChatGPT 计划用量已达上限（可能是本应用的额度），可在 ChatGPT 用量设置里查看"
    case .usageUnavailable, .userUnavailable:
      return "ChatGPT 计划用量暂时无法确认，凭证已保留，请稍后再试"
    case .notEligible:
      return "当前 ChatGPT 账户或工作区不能把计划用量用于本应用"
    case .unsupportedCapability:
      return "这次请求用了 ChatGPT 计划用量不支持的能力"
        + (param.map { "（\($0)）" } ?? "") + "，请换模型或档位"
    case .routeNotSupported:
      return "ChatGPT 计划用量不支持这个请求地址"
    case .invalidUser:
      return "ChatGPT 订阅身份未通过验证，请检查当前账户及授权状态"
    case .notAuthorized:
      return "ChatGPT 授权不允许这次请求，请检查应用注册与计划用量权限"
    case .admissionRejected:
      return "ChatGPT 计划用量拒绝了这次请求"
        + (httpStatus.map { "（HTTP \($0)）" } ?? "")
    case .responseFailed:
      return "ChatGPT 生成失败" + (code.map { "（\($0)）" } ?? "")
    case .responseIncomplete:
      return "ChatGPT 生成未完成" + (code.map { "（\($0)）" } ?? "") + "，未采用半截结果"
    case .refused:
      return "ChatGPT 拒绝生成这次内容"
    case .other:
      return "ChatGPT 请求失败" + (httpStatus.map { "（HTTP \($0)）" } ?? "")
    }
  }
}
