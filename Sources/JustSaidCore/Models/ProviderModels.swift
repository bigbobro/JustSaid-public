import CryptoKit
import Foundation

public enum ProviderRole: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
  case liveTranscriber
  case batchASR
  case liveSummaryLLM
  case minutesLLM

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .liveTranscriber:
      return "会中速记"
    case .batchASR:
      return "会后精转"
    case .liveSummaryLLM:
      return "会中总结"
    case .minutesLLM:
      return "会后纪要"
    }
  }

  public var isLLMRole: Bool {
    self == .liveSummaryLLM || self == .minutesLLM
  }
}

public enum MeetingLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
  /// 自动识别(08-09 R4,工具栏默认):把自动语种意图原样交给当前会中引擎。
  /// 08-11 纯 Qwen 体验分支下,actual stream 不设置 `language` option；显式手选
  /// SenseVoice 时仍对应 `lang_auto`。会后精转语言由 `MeetingLanguageDetector`
  /// 检测决定。已存的 "en"/"zh" 手动选择不受影响。
  ///
  /// 选 `.chinese`/`.english` 则把会中识别器**钉死**在该语种。各引擎翻译参数:
  /// Qwen 使用 `Chinese`/`English` stream option；SenseVoice 使用 `zh`/`en` token。
  case auto = "auto"
  case chinese = "zh"
  case english = "en"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .auto:
      return "Auto"
    case .english:
      return "英语 en"
    case .chinese:
      return "中文 zh"
    }
  }

  /// **只给 Apple SpeechAnalyzer 用**。Qwen 走 actual stream language option；
  /// SenseVoice 走 `SenseVoiceTranscriberEngine.languageToken(for:)`——它只认裸语言码,
  /// 喂 BCP-47 会让配置校验失败并 fatalError。
  public var transcriptionLocaleIdentifier: String {
    switch self {
    case .auto:
      // Apple 引擎没有「自动」档,必须给一个具体 locale;它是设置页手选项,
      // 选了即自行承担语言责任。这里回落中文的行为自 08-09 未变。
      return "zh-CN"
    case .english:
      return "en-IN"
    case .chinese:
      return "zh-CN"
    }
  }
}

public enum BatchLanguageDecision: String, Codable, Equatable, Sendable {
  case english = "en-US"
  case chinese = "zh-CN"
  case auto

  public var apiLanguage: String? {
    switch self {
    case .english, .chinese:
      return rawValue
    case .auto:
      return nil
    }
  }
}

/// 「生成纪要」这一次要出几份。F5:出几份不再由精转时记下的
/// `BatchLanguageDecision` 替用户决定,而是点按钮时当场拍板。
///
/// **语言列表与文案刻意绑在这一个类型里**:分开放会出现"文案说一次计费、
/// 实际跑两次"这种撒谎形态,验证专门断言 `billedCallCount == languages.count`。
public enum MinutesGenerationScope: String, CaseIterable, Equatable, Sendable {
  /// 只出中文主产物。日常默认,一次 LLM 调用。
  case chineseOnly
  /// 中英各出一份,两次 LLM 调用、两份钱。
  case bilingual

  public var languages: [MeetingLanguage] {
    switch self {
    case .chineseOnly:
      return [.chinese]
    case .bilingual:
      return [.chinese, .english]
    }
  }

  /// 会真正发生的 minutesLLM 调用次数 —— 一种语言一次。
  public var billedCallCount: Int { languages.count }

  /// 选项文案。计费次数由 `billedCallCount` 渲染进去,不手写数字,
  /// 避免改了行为忘了改文案。
  public var actionTitle: String {
    switch self {
    case .chineseOnly:
      return "只生成中文(\(billedCallCount) 次计费)"
    case .bilingual:
      return "中英都生成(\(billedCallCount) 次计费)"
    }
  }
}

/// ASR 实际用量记录里的模型名。已知供应商资源 ID 换成人话；未知值原样保留，
/// 让后续换模型或供应商时无需先升级 App 也能在会议详情里留痕。
public enum ASRModelNaming {
  public static func displayName(for model: String) -> String {
    switch model {
    case "volc.seedasr.auc":
      return "录音文件识别 2.0"
    case "volc.bigasr.auc":
      return "录音文件识别 1.0"
    default:
      return model
    }
  }
}

/// 会后精转 ASR 的两种 adapter 形状（design.md T8，2026-07-28 深夜修正）：
/// 火山型需要 APP ID + Access Token 并联动对象存储(TOS)上传配置；
/// 通用型只需 OpenAI 格式的 base URL + API key。非 ASR 角色的 provider 不使用该字段。
public enum ASRVendorKind: String, Codable, Sendable {
  case volcengine
  case generic
}

public enum StorageProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case volcengineTOS
  case azureBlob
  case cloudflareR2

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .volcengineTOS:
      return "火山 TOS"
    case .azureBlob:
      return "Azure Blob"
    case .cloudflareR2:
      return "Cloudflare R2"
    }
  }

  /// 设置页旁注:三者取舍(免费额度 / 实名认证 / 跨境速度)。
  public var selectionHint: String {
    switch self {
    case .cloudflareR2:
      return "推荐新用户:额度永久免费、本场景几乎零成本;无实名;跨境速度待你实测"
    case .azureBlob:
      return "免费额度 12 个月后过期;无实名;跨境大文件偶发超时"
    case .volcengineTOS:
      return "国内最快(与火山同云);需实名认证与预充值"
    }
  }
}

/// 中性推理档位。序只表达相对强弱(供"就近降级"比较用),**不对应任何供应商的词面**：
/// 各家形态本就不可通约(OpenAI 兼容是档位字符串、Claude 是思考预算 token 数),
/// 把某一家的词存进配置等于把它固化进用户数据。词面只允许出现在客户端翻译处。
///
/// String 枚举会被整体序列化进 UserDefaults：**加新 case 会让旧版本解码整份
/// ProviderConfiguration 失败**(与 core spec 对 `MeetingStatus` 的红线同源),五档为定案。
public enum ReasoningEffortLevel: String, Codable, CaseIterable, Comparable, Sendable {
  case off
  case low
  case medium
  case high
  case max

  public var displayName: String {
    switch self {
    case .off:
      return "关闭"
    case .low:
      return "低"
    case .medium:
      return "中"
    case .high:
      return "高"
    case .max:
      return "最高"
    }
  }

  private var rank: Int {
    switch self {
    case .off:
      return 0
    case .low:
      return 1
    case .medium:
      return 2
    case .high:
      return 3
    case .max:
      return 4
    }
  }

  public static func < (lhs: ReasoningEffortLevel, rhs: ReasoningEffortLevel) -> Bool {
    lhs.rank < rhs.rank
  }
}

/// 能力协商:用户档位超出当前供应商声明的能力时按**就近可用档**降级。
/// 降级是正常路径,**绝不让请求失败**,也不得静默按最低档发。
public enum ReasoningEffortPolicy {
  public struct Resolution: Equatable, Sendable {
    /// 本次真正发出去的档位。
    public let level: ReasoningEffortLevel
    /// 发生降级时的 notice 日志文案;没降级为 nil。
    public let downgradeNotice: String?
  }

  public static func resolve(
    requested: ReasoningEffortLevel,
    supported: Set<ReasoningEffortLevel>,
    role: ProviderRole,
    providerID: String
  ) -> Resolution {
    guard supported.contains(requested) else {
      let available = supported.sorted()
      // 取不超过用户档位的最大可用档;没有更低档才退到最低可用档。
      let level = available.last { $0 < requested } ?? available.first ?? .off
      let notice =
        "推理档位就近降级:\(role.displayName)"
        + "想要「\(requested.displayName)」,"
        + "供应商 \(providerID) 只支持 "
        + available.map(\.displayName).joined(separator: "/")
        + ",实发「\(level.displayName)」"
      return Resolution(level: level, downgradeNotice: notice)
    }
    return Resolution(level: requested, downgradeNotice: nil)
  }
}

public struct ProviderDescriptor: Identifiable, Hashable, Sendable {
  public let id: String
  public let displayName: String
  public let supportedRoles: Set<ProviderRole>
  public let defaultBaseURL: String
  public let defaultModel: String
  public let requiresAPIKey: Bool
  public let asrVendorKind: ASRVendorKind?
  /// 这家真支持哪几档推理强度。界面下拉只列这里声明的档,**不给用户选了也不生效的选项**;
  /// 不支持推理的供应商声明 `[.off]`。构造时一律并入 `.off`——「关闭」必须始终可选,
  /// 否则用户选关闭却撞上不含 `.off` 的能力集时,就近降级会**反向升档**(唯一会把
  /// 用户意愿改大的路径),白花推理预算。
  public let supportedReasoningLevels: Set<ReasoningEffortLevel>

  /// 该供应商可用的最高档,用于「会后纪要默认拉满」。
  public var highestReasoningLevel: ReasoningEffortLevel {
    supportedReasoningLevels.max() ?? .off
  }

  public init(
    id: String,
    displayName: String,
    supportedRoles: Set<ProviderRole>,
    defaultBaseURL: String = "",
    defaultModel: String,
    requiresAPIKey: Bool,
    asrVendorKind: ASRVendorKind? = nil,
    supportedReasoningLevels: Set<ReasoningEffortLevel> = [.off]
  ) {
    self.id = id
    self.displayName = displayName
    self.supportedRoles = supportedRoles
    self.defaultBaseURL = defaultBaseURL
    self.defaultModel = defaultModel
    self.requiresAPIKey = requiresAPIKey
    self.asrVendorKind = asrVendorKind
    self.supportedReasoningLevels = supportedReasoningLevels.union([.off])
  }
}

public struct RoleProviderBinding: Equatable, Identifiable, Sendable {
  public var role: ProviderRole
  public var providerID: String
  public var baseURL: String
  public var model: String
  /// 推理强度的旧形态（布尔开关）。**保留字段不删**：删了旧 UserDefaults 会掉字段，
  /// 且降级回旧版本仍要靠它。新界面选档后同步回写 `thinkingEnabled = (level != .off)`。
  public var thinkingEnabled: Bool
  /// 中性推理档位。旧配置没有该字段，因此保持 Optional，让 Codable 无迁移读取已有
  /// UserDefaults（nil 时按 `effectiveReasoningEffort` 从 `thinkingEnabled` 推导）。
  public var reasoningEffort: ReasoningEffortLevel?
  /// 会后精转·火山型的非密钥标识字段；通用型不使用。密钥类字段（Access Token、
  /// TOS AK/SK、R2 AK/SK）一律只进 Keychain，不进这个会被整体序列化进 UserDefaults 的结构体。
  public var appID: String
  public var tosBucket: String
  public var tosRegion: String
  /// 旧配置没有这两个字段，因此保持 Optional，让 Codable 能无迁移读取已有 UserDefaults。
  /// `nil` 等价于主选 Azure；Azure 容器地址不含 SAS，凭证仍只进 Keychain。
  public var storageProviderKind: StorageProviderKind?
  public var azureContainerURL: String?
  /// Cloudflare R2 非密字段。凭证(Access Key / Secret Key)只进钥匙串,绝不可进 meeting.json。
  public var r2AccountID: String?
  public var r2Bucket: String?
  /// 火山录音文件识别模型版本(2026-07-30 新控制台迁移):nil 等价 2.0(volc.seedasr.auc)。
  /// 1.0(volc.bigasr.auc)额度更充裕(实测 120h vs 20h),质量对测后由用户定默认。
  public var asrResourceID: String?
  /// 会中速记默认按会议语言选本地引擎；用户在设置里点选具体引擎后改为 false。
  /// 旧配置没有该字段，nil 按自动路由迁移。
  public var automaticLanguageRouting: Bool?

  public var id: ProviderRole { role }

  public var usesAutomaticLanguageRouting: Bool {
    role == .liveTranscriber && automaticLanguageRouting != false
  }

  public var selectedASRResourceID: String {
    let trimmed = (asrResourceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // 产品默认 1.0(wayfinder 03 票 Resolution,2026-08-08 用户拍板:不双跑直接定 1.0;
    // 同素材对照几乎逐字相同,1.0 额度 120h 远大于 2.0)。显式选择永远优先。
    return trimmed.isEmpty ? "volc.bigasr.auc" : trimmed
  }

  /// 用户配置里的有效档位（尚未做供应商能力协商）。迁移表（不可回退）：
  /// 新字段非 nil 取其值；nil + `thinkingEnabled=true` → `.medium`（等价改动前硬编码的
  /// medium）；nil + false → `.off`（等价改动前不发该字段）。**读路径纯净，不回写配置。**
  public var effectiveReasoningEffort: ReasoningEffortLevel {
    if let reasoningEffort {
      return reasoningEffort
    }
    return thinkingEnabled ? .medium : .off
  }

  public var selectedStorageProviderKind: StorageProviderKind {
    if let storageProviderKind {
      return storageProviderKind
    }
    let hasLegacyTOSConfiguration =
      !tosBucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !tosRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return hasLegacyTOSConfiguration ? .volcengineTOS : .azureBlob
  }

  public init(
    role: ProviderRole,
    providerID: String,
    baseURL: String,
    model: String,
    thinkingEnabled: Bool = false,
    reasoningEffort: ReasoningEffortLevel? = nil,
    appID: String = "",
    tosBucket: String = "",
    tosRegion: String = "",
    storageProviderKind: StorageProviderKind? = nil,
    azureContainerURL: String? = nil,
    r2AccountID: String? = nil,
    r2Bucket: String? = nil,
    asrResourceID: String? = nil,
    automaticLanguageRouting: Bool? = nil
  ) {
    self.role = role
    self.providerID = providerID
    self.baseURL = baseURL
    self.model = model
    self.thinkingEnabled = thinkingEnabled
    self.reasoningEffort = reasoningEffort
    self.appID = appID
    self.tosBucket = tosBucket
    self.tosRegion = tosRegion
    self.storageProviderKind = storageProviderKind
    self.azureContainerURL = azureContainerURL
    self.r2AccountID = r2AccountID
    self.r2Bucket = r2Bucket
    self.asrResourceID = asrResourceID
    self.automaticLanguageRouting = automaticLanguageRouting
  }
}

// 自定义 Codable:storageProviderKind 以 String 容错解码——未知取值(旧版本不认识的
// 新 case,或未来再加的后端)落 nil,再由 selectedStorageProviderKind 回退到默认,
// **避免整份 ProviderConfiguration / meeting.json providers 解码失败**。
extension RoleProviderBinding: Codable {
  private enum CodingKeys: String, CodingKey {
    case role
    case providerID
    case baseURL
    case model
    case thinkingEnabled
    case reasoningEffort
    case appID
    case tosBucket
    case tosRegion
    case storageProviderKind
    case azureContainerURL
    case r2AccountID
    case r2Bucket
    case asrResourceID
    case automaticLanguageRouting
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    role = try container.decode(ProviderRole.self, forKey: .role)
    providerID = try container.decode(String.self, forKey: .providerID)
    baseURL = try container.decode(String.self, forKey: .baseURL)
    model = try container.decode(String.self, forKey: .model)
    thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
    reasoningEffort = try container.decodeIfPresent(
      ReasoningEffortLevel.self,
      forKey: .reasoningEffort
    )
    appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""
    tosBucket = try container.decodeIfPresent(String.self, forKey: .tosBucket) ?? ""
    tosRegion = try container.decodeIfPresent(String.self, forKey: .tosRegion) ?? ""
    if let raw = try container.decodeIfPresent(String.self, forKey: .storageProviderKind) {
      // 未知 raw → nil → selectedStorageProviderKind 走 TOS 遗留字段 / Azure 默认。
      storageProviderKind = StorageProviderKind(rawValue: raw)
    } else {
      storageProviderKind = nil
    }
    azureContainerURL = try container.decodeIfPresent(String.self, forKey: .azureContainerURL)
    r2AccountID = try container.decodeIfPresent(String.self, forKey: .r2AccountID)
    r2Bucket = try container.decodeIfPresent(String.self, forKey: .r2Bucket)
    asrResourceID = try container.decodeIfPresent(String.self, forKey: .asrResourceID)
    automaticLanguageRouting = try container.decodeIfPresent(
      Bool.self,
      forKey: .automaticLanguageRouting
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(role, forKey: .role)
    try container.encode(providerID, forKey: .providerID)
    try container.encode(baseURL, forKey: .baseURL)
    try container.encode(model, forKey: .model)
    try container.encode(thinkingEnabled, forKey: .thinkingEnabled)
    try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
    try container.encode(appID, forKey: .appID)
    try container.encode(tosBucket, forKey: .tosBucket)
    try container.encode(tosRegion, forKey: .tosRegion)
    try container.encodeIfPresent(storageProviderKind, forKey: .storageProviderKind)
    try container.encodeIfPresent(azureContainerURL, forKey: .azureContainerURL)
    try container.encodeIfPresent(r2AccountID, forKey: .r2AccountID)
    try container.encodeIfPresent(r2Bucket, forKey: .r2Bucket)
    try container.encodeIfPresent(asrResourceID, forKey: .asrResourceID)
    try container.encodeIfPresent(automaticLanguageRouting, forKey: .automaticLanguageRouting)
  }
}

/// 统一渠道实体(08-10 单):会中速记/会中总结/会后精转 ASR/会后纪要四类 AI 服务
/// 共用一份连接配置——地址与凭证只在这里维护,角色侧只做选择。
///
/// 凭证值绝不进本结构体(它会整体序列化进 UserDefaults):只保存 `secretReference`
/// 这个 Keychain 账户基址,实际账户为 `\(secretReference).\(slot)`。
public struct ProviderChannel: Codable, Equatable, Identifiable, Sendable {
  /// 稳定、不可复用的 UUID 字符串;编辑渠道不得改变它。
  public var id: String
  /// 用户可见名称,用于错误诊断与渠道列表。
  public var name: String
  /// 供应商/协议类型,继续引用 `ProviderDescriptor.id`;不得把 provider 专属能力抹平。
  public var providerID: String
  /// 非秘密连接地址;本地引擎渠道为空。
  public var baseURL: String
  /// 火山旧控制台的非密钥身份字段(新版 API Key 鉴权不需要);其他供应商为空。
  public var appID: String
  /// Keychain 账户基址(凭证引用),创建时定为 `channel.\(id)` 后不再改变。
  public var secretReference: String
  /// 迁移来源的旧钥匙串账户基址:新账户缺失时回落读取旧账户。
  /// 读路径不回写、不删除旧账户;只有显式保存才把凭证写进新账户。
  public var legacySecretAccountBase: String?
  /// 渠道声明支持的角色;不支持的组合不能被会中/会后选择。
  public var supportedRoles: Set<ProviderRole>
  /// 渠道声明可用的模型;空数组 = 不约束(自定义网关的模型随服务端变化)。
  public var availableModels: [String]
  /// nil = 跟随 `ProviderDescriptor.supportedReasoningLevels` 的声明与就近降级规则。
  public var supportedReasoningLevels: Set<ReasoningEffortLevel>?

  public init(
    id: String,
    name: String,
    providerID: String,
    baseURL: String,
    appID: String = "",
    secretReference: String,
    legacySecretAccountBase: String? = nil,
    supportedRoles: Set<ProviderRole>,
    availableModels: [String] = [],
    supportedReasoningLevels: Set<ReasoningEffortLevel>? = nil
  ) {
    self.id = id
    self.name = name
    self.providerID = providerID
    self.baseURL = baseURL
    self.appID = appID
    self.secretReference = secretReference
    self.legacySecretAccountBase = legacySecretAccountBase
    self.supportedRoles = supportedRoles
    self.availableModels = availableModels
    self.supportedReasoningLevels = supportedReasoningLevels
  }

  /// 迁移与出厂默认渠道的确定性 ID:同一去重键恒得同一 UUID。
  /// 读路径在内存里重建迁移结果不产生新身份,首次显式保存后 ID 冻结。
  /// 格式取 UUID version-5 的位布局,纯 SHA-256 派生,不引入随机性。
  public static func deterministicID(seed: String) -> String {
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let part1 = hex.prefix(8)
    let part2 = hex.dropFirst(8).prefix(4)
    let part3 = hex.dropFirst(12).prefix(4)
    let part4 = hex.dropFirst(16).prefix(4)
    let part5 = hex.dropFirst(20).prefix(12)
    return "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
  }
}

/// 运行角色对渠道的选择:只含渠道、模型、推理档位与角色专属运行时字段。
/// 角色专属字段(火山 ASR resource、会中语言路由)留在选择里,**不得塞入通用渠道**;
/// 对象存储不属于这里,由独立 `StorageConfiguration` 管理。
public struct RoleChannelSelection: Codable, Equatable, Identifiable, Sendable {
  public var role: ProviderRole
  public var channelID: String
  public var model: String
  /// 中性推理档位;nil 时按 `effectiveReasoningEffort` 从旧布尔推导(与旧绑定同一张迁移表)。
  public var reasoningEffort: ReasoningEffortLevel?
  /// 旧形态布尔开关,保留不删:用户选档后回写,降级回旧版本仍可用;读路径不回写。
  public var thinkingEnabled: Bool
  /// 会后精转·火山型模型版本(角色专属,不进渠道);nil 等价产品默认 1.0。
  public var asrResourceID: String?
  /// 会中速记语言路由(角色专属);nil 按自动路由。
  public var automaticLanguageRouting: Bool?

  public var id: ProviderRole { role }

  /// 与 `RoleProviderBinding.effectiveReasoningEffort` 同一张迁移表(不可回退):
  /// 新字段优先;nil + true → .medium;nil + false → .off。
  public var effectiveReasoningEffort: ReasoningEffortLevel {
    if let reasoningEffort {
      return reasoningEffort
    }
    return thinkingEnabled ? .medium : .off
  }

  public var selectedASRResourceID: String {
    let trimmed = (asrResourceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "volc.bigasr.auc" : trimmed
  }

  public init(
    role: ProviderRole,
    channelID: String,
    model: String,
    reasoningEffort: ReasoningEffortLevel? = nil,
    thinkingEnabled: Bool = false,
    asrResourceID: String? = nil,
    automaticLanguageRouting: Bool? = nil
  ) {
    self.role = role
    self.channelID = channelID
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.thinkingEnabled = thinkingEnabled
    self.asrResourceID = asrResourceID
    self.automaticLanguageRouting = automaticLanguageRouting
  }
}

/// 会后精转 ASR 的独立对象存储配置(08-10 单 R4):
/// Azure Blob / 火山 TOS / Cloudflare R2 **不是 AI 渠道**,不参与模型选择器。
/// 凭证只进 Keychain;账户基址在创建/迁移时冻结,之后切换 ASR 渠道不再让存储密钥"搬家"。
public struct StorageConfiguration: Equatable, Sendable {
  /// nil 走 `selectedKind` 的旧回退规则(有 TOS 遗留字段按 TOS,否则 Azure)。
  public var kind: StorageProviderKind?
  public var tosBucket: String
  public var tosRegion: String
  public var azureContainerURL: String?
  public var r2AccountID: String?
  public var r2Bucket: String?
  /// Keychain 账户基址:旧方案为 `batchASR.<providerID>`(迁移时冻结自旧绑定);
  /// 冻结后切换/重建 ASR 渠道不影响存储密钥账户。
  public var secretAccountBase: String
  /// TOS 槽位的 endpoint 来源(旧方案取 batchASR 绑定的 baseURL);迁移时冻结。
  public var tosSecretEndpointSource: String

  /// 与 `RoleProviderBinding.selectedStorageProviderKind` 同一套回退规则。
  public var selectedKind: StorageProviderKind {
    if let kind {
      return kind
    }
    let hasLegacyTOSConfiguration =
      !tosBucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !tosRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return hasLegacyTOSConfiguration ? .volcengineTOS : .azureBlob
  }

  /// 与旧默认 batchASR 绑定(火山 ASR、空 baseURL)逐字节一致的账户基址:
  /// 全新安装的存储密钥账户与改动前完全相同。
  public static var `default`: StorageConfiguration {
    StorageConfiguration(
      kind: nil,
      tosBucket: "",
      tosRegion: "",
      azureContainerURL: nil,
      r2AccountID: nil,
      r2Bucket: nil,
      secretAccountBase: "batchASR.volcengine-doubao-asr",
      tosSecretEndpointSource: ""
    )
  }

  public init(
    kind: StorageProviderKind?,
    tosBucket: String = "",
    tosRegion: String = "",
    azureContainerURL: String? = nil,
    r2AccountID: String? = nil,
    r2Bucket: String? = nil,
    secretAccountBase: String,
    tosSecretEndpointSource: String = ""
  ) {
    self.kind = kind
    self.tosBucket = tosBucket
    self.tosRegion = tosRegion
    self.azureContainerURL = azureContainerURL
    self.r2AccountID = r2AccountID
    self.r2Bucket = r2Bucket
    self.secretAccountBase = secretAccountBase
    self.tosSecretEndpointSource = tosSecretEndpointSource
  }
}

// 自定义 Codable:kind 以 String 容错解码——未知取值落 nil 走回退,与
// RoleProviderBinding.storageProviderKind 的既有红线同源,避免整份配置解码失败。
extension StorageConfiguration: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case tosBucket
    case tosRegion
    case azureContainerURL
    case r2AccountID
    case r2Bucket
    case secretAccountBase
    case tosSecretEndpointSource
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let raw = try container.decodeIfPresent(String.self, forKey: .kind) {
      kind = StorageProviderKind(rawValue: raw)
    } else {
      kind = nil
    }
    tosBucket = try container.decodeIfPresent(String.self, forKey: .tosBucket) ?? ""
    tosRegion = try container.decodeIfPresent(String.self, forKey: .tosRegion) ?? ""
    azureContainerURL = try container.decodeIfPresent(String.self, forKey: .azureContainerURL)
    r2AccountID = try container.decodeIfPresent(String.self, forKey: .r2AccountID)
    r2Bucket = try container.decodeIfPresent(String.self, forKey: .r2Bucket)
    secretAccountBase =
      try container.decodeIfPresent(String.self, forKey: .secretAccountBase)
      ?? StorageConfiguration.default.secretAccountBase
    tosSecretEndpointSource =
      try container.decodeIfPresent(String.self, forKey: .tosSecretEndpointSource) ?? ""
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(kind, forKey: .kind)
    try container.encode(tosBucket, forKey: .tosBucket)
    try container.encode(tosRegion, forKey: .tosRegion)
    try container.encodeIfPresent(azureContainerURL, forKey: .azureContainerURL)
    try container.encodeIfPresent(r2AccountID, forKey: .r2AccountID)
    try container.encodeIfPresent(r2Bucket, forKey: .r2Bucket)
    try container.encode(secretAccountBase, forKey: .secretAccountBase)
    try container.encode(tosSecretEndpointSource, forKey: .tosSecretEndpointSource)
  }
}

/// 版本化配置(v2):`channels` + `roleSelections` + 独立 `storage`。
/// 旧 `bindings` 字段只作兼容解码入口(`legacyBindings`),**新写入只写新格式**;
/// `bindings` 计算属性把新结构投影回 `RoleProviderBinding`,让历史快照(meeting.json
/// providers)与运行时共享同一种字节形态——快照稳定,不反向引用当前渠道。
public struct ProviderConfiguration: Codable, Equatable, Sendable {
  public static let currentVersion = 2

  public var version: Int
  public var channels: [ProviderChannel]
  public var roleSelections: [RoleChannelSelection]
  public var storage: StorageConfiguration
  /// 旧格式解码保留(迁移输入)。非 nil 时本值是"旧表示":`bindings` 原样返回它,
  /// 编码也只写 `bindings` 键——验证夹具借此继续构造旧格式数据。
  public var legacyBindings: [RoleProviderBinding]?

  /// 新版构造。
  public init(
    version: Int = ProviderConfiguration.currentVersion,
    channels: [ProviderChannel],
    roleSelections: [RoleChannelSelection],
    storage: StorageConfiguration
  ) {
    self.version = version
    self.channels = channels
    self.roleSelections = roleSelections
    self.storage = storage
    self.legacyBindings = nil
  }

  /// 旧格式构造(迁移前的唯一形态);保留给既有夹具与调用点。
  public init(bindings: [RoleProviderBinding]) {
    self.version = 1
    self.channels = []
    self.roleSelections = []
    self.storage = .default
    self.legacyBindings = bindings
  }

  /// 把当前配置投影成旧绑定表示:角色选择 + 渠道连接信息 + 独立存储字段。
  /// 旧表示直接返回旧绑定,投影不产生任何改写。
  public var bindings: [RoleProviderBinding] {
    if let legacyBindings {
      return legacyBindings
    }
    return roleSelections.map { selection in
      let channel = channels.first { $0.id == selection.channelID }
      var binding = RoleProviderBinding(
        role: selection.role,
        providerID: channel?.providerID ?? "",
        baseURL: channel?.baseURL ?? "",
        model: selection.model,
        thinkingEnabled: selection.thinkingEnabled,
        reasoningEffort: selection.reasoningEffort,
        appID: channel?.appID ?? "",
        asrResourceID: selection.asrResourceID,
        automaticLanguageRouting: selection.automaticLanguageRouting
      )
      if selection.role == .batchASR {
        binding.storageProviderKind = storage.kind
        binding.tosBucket = storage.tosBucket
        binding.tosRegion = storage.tosRegion
        binding.azureContainerURL = storage.azureContainerURL
        binding.r2AccountID = storage.r2AccountID
        binding.r2Bucket = storage.r2Bucket
      }
      return binding
    }
  }

  public func binding(for role: ProviderRole) -> RoleProviderBinding? {
    bindings.first { $0.role == role }
  }

  public func selection(for role: ProviderRole) -> RoleChannelSelection? {
    roleSelections.first { $0.role == role }
  }

  public func channel(id: String) -> ProviderChannel? {
    channels.first { $0.id == id }
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case channels
    case roleSelections
    case storage
    case bindings
  }

  /// 读取顺序红线:先新版本(有 `channels` 即 v2);没有新配置才读旧 `bindings`。
  /// 两者都没有 = 数据已损坏,抛错由调用方决定回落——绝不静默猜一份配置。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let channels = try container.decodeIfPresent([ProviderChannel].self, forKey: .channels) {
      version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
      self.channels = channels
      roleSelections =
        try container.decodeIfPresent([RoleChannelSelection].self, forKey: .roleSelections) ?? []
      storage =
        try container.decodeIfPresent(StorageConfiguration.self, forKey: .storage) ?? .default
      legacyBindings = nil
    } else if let legacy = try container.decodeIfPresent(
      [RoleProviderBinding].self,
      forKey: .bindings
    ) {
      version = 1
      channels = []
      roleSelections = []
      storage = .default
      legacyBindings = legacy
    } else {
      throw DecodingError.dataCorruptedError(
        forKey: .channels,
        in: container,
        debugDescription: "配置既不是新版渠道格式也不是旧版 bindings 格式"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let legacyBindings {
      // 旧表示原样往返:只写 bindings 键,供迁移验证夹具使用。
      try container.encode(legacyBindings, forKey: .bindings)
      return
    }
    try container.encode(version, forKey: .version)
    try container.encode(channels, forKey: .channels)
    try container.encode(roleSelections, forKey: .roleSelections)
    try container.encode(storage, forKey: .storage)
  }
}
