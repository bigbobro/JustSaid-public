import Combine
import CryptoKit
import Foundation
import OSLog

/// Keychain 里区分“这是哪一个密钥”的槽位。同一个 (role, providerID) 在火山型 ASR 下
/// 需要同时保存 Access Token 与 TOS 的 AK/SK 三个互相独立的密钥，因此不能只有一个槽位。
public enum ProviderSecretSlot: String, Sendable {
  case apiKey
  case accessToken
  case tosAccessKey
  case tosSecretKey
  /// 旧版单 SAS 槽保留用于读取既有 Keychain 项；新代码不会把管理权限 SAS 交给外部 ASR。
  case azureSAS
  case azureManagementSAS
  case azureReadOnlySAS
  case azureAccountKey
  case r2AccessKey
  case r2SecretKey
}

public enum ProviderRuntimeConfigurationError: LocalizedError, Sendable {
  case unsupportedRole
  case missingBaseURL(ProviderRole)
  case invalidBaseURL(ProviderRole)
  case insecureBaseURL(ProviderRole)
  case missingModel(ProviderRole)
  case missingSecret(ProviderRole, ProviderSecretSlot, key: String)
  case missingField(String)
  case invalidField(String)
  case unsupportedBatchProvider(String)
  /// 角色没有任何渠道选择(v2 数据损坏);不得静默回落默认渠道。
  case missingRoleSelection(ProviderRole)
  /// 选择引用的渠道 ID 不存在(半迁移/悬空引用);不得静默回落默认渠道。
  case unknownChannel(ProviderRole, channelID: String)
  /// 渠道声明的能力不含该角色。
  case channelDoesNotSupportRole(ProviderRole, channelName: String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedRole:
      return "该角色不是 LLM 角色"
    case .missingBaseURL(let role):
      return "\(role.displayName)尚未填写 Base URL"
    case .invalidBaseURL(let role):
      return "\(role.displayName)的 Base URL 无效"
    case .insecureBaseURL(let role):
      return "\(role.displayName)的 Base URL 必须使用 HTTPS"
    case .missingModel(let role):
      return "\(role.displayName)尚未填写模型名称"
    case .missingSecret(let role, _, let key):
      return "\(role.displayName)缺少钥匙串凭证「\(key)」"
    case .missingField(let name):
      return "会后管线尚未填写\(name)"
    case .invalidField(let name):
      return "会后管线的\(name)无效"
    case .unsupportedBatchProvider(let providerID):
      return "当前会后精转供应商尚无运行时 adapter：\(providerID)"
    case .missingRoleSelection(let role):
      return "\(role.displayName)没有配置渠道选择,请在设置中重新选择渠道"
    case .unknownChannel(let role, let channelID):
      return "\(role.displayName)引用的渠道已不存在(\(channelID)),请在设置中重新选择渠道"
    case .channelDoesNotSupportRole(let role, let channelName):
      return "渠道「\(channelName)」不支持\(role.displayName),请更换渠道或调整渠道能力"
    }
  }
}

/// 渠道 CRUD 的可诊断错误。全部只含渠道可见名称/角色/槽位,绝不含秘密值。
public enum ProviderChannelError: LocalizedError, Sendable {
  case notFound(channelID: String)
  case emptyName
  case invalidBaseURL(String)
  case capabilityMismatch(channelName: String, role: ProviderRole)
  /// 白名单拒绝。`roles` 是正在引用该模型的角色(updateChannel 的引用完整性路径非空,
  /// 文案据此给出解锁出路);selectModel 路径没有引用方,传空。
  case modelNotDeclared(channelName: String, model: String, roles: [ProviderRole])
  /// 仍被角色选择引用的渠道不能直接删除;错误列出全部引用角色。
  case channelInUse(channelName: String, roles: [ProviderRole])
  /// 渠道上下文探针(连接测试/模型拉取)的前置缺失;渠道可能尚未被任何角色引用,
  /// 不能借用角色语义的错误。
  case missingChannelBaseURL(channelName: String)
  case insecureChannelBaseURL(channelName: String)
  case missingChannelModel(channelName: String)
  case missingChannelSecret(channelName: String, slot: ProviderSecretSlot)

  public var errorDescription: String? {
    switch self {
    case .notFound(let channelID):
      return "渠道不存在(\(channelID))"
    case .emptyName:
      return "渠道名称不能为空"
    case .invalidBaseURL(let baseURL):
      return "渠道地址无效:\(baseURL)"
    case .capabilityMismatch(let channelName, let role):
      return "渠道「\(channelName)」不支持\(role.displayName)"
    case .modelNotDeclared(let channelName, let model, let roles):
      guard !roles.isEmpty else {
        return "渠道「\(channelName)」的模型列表不包含「\(model)」——清空渠道模型列表可自由填写"
      }
      let usingRoles = roles.map(\.displayName).joined(separator: "、")
      return "渠道「\(channelName)」的模型列表不包含「\(model)」,\(usingRoles)正在使用它"
        + "——请先在角色卡换成列表内模型,或保留/补上「\(model)」,或清空列表转为自由填写"
    case .channelInUse(let channelName, let roles):
      let roleNames = roles.map(\.displayName).joined(separator: "、")
      return "渠道「\(channelName)」仍被\(roleNames)使用,请先重新分配这些角色"
    case .missingChannelBaseURL(let channelName):
      return "渠道「\(channelName)」尚未填写 Base URL"
    case .insecureChannelBaseURL(let channelName):
      return "渠道「\(channelName)」的 Base URL 必须使用 HTTPS"
    case .missingChannelModel(let channelName):
      return "渠道「\(channelName)」尚未选择用于测试的模型"
    case .missingChannelSecret(let channelName, let slot):
      return "渠道「\(channelName)」缺少钥匙串凭证(\(slot.rawValue)),请先在渠道编辑中保存"
    }
  }
}

@MainActor
public final class ProviderSettingsStore: ObservableObject {
  public nonisolated static let applicationDefaultsSuiteName = "com.justsaid.app"

  @Published public private(set) var configuration: ProviderConfiguration
  @Published public private(set) var storageHealthMessage: String?
  @Published public private(set) var storageHealthFailureMessage: String?
  /// 新旧格式都无法解码时的可诊断错误;旧数据保留未动,不为 nil 时界面上必须能看到。
  @Published public private(set) var migrationFailureMessage: String?

  public let registry: ProviderRegistry

  private let defaults: UserDefaults
  private let secretStore: any ProviderSecretStore
  private let healthCheckTransport: any HTTPTransport
  private var storageHealthTask: Task<Void, Never>?
  private var storageHealthGeneration = 0
  private let defaultsKey = "provider-configuration"
  /// 读路径不回写:数据损坏且尚未发生任何显式保存动作时,persist 一律跳过,
  /// 绝不用出厂默认覆盖原始 UserDefaults(旧行为是静默换掉,违反迁移红线)。
  private var allowPersist = true
  private let logger = Logger(
    subsystem: "com.justsaid.app",
    category: "provider-settings"
  )

  public init(
    registry: ProviderRegistry = ProviderRegistry(),
    defaults: UserDefaults = .standard,
    secretStore: any ProviderSecretStore = KeychainStore(),
    healthCheckTransport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.registry = registry
    self.defaults = defaults
    self.secretStore = secretStore
    self.healthCheckTransport = healthCheckTransport

    guard let data = defaults.data(forKey: defaultsKey) else {
      configuration = registry.defaultConfiguration()
      return
    }
    guard let saved = try? JSONDecoder().decode(ProviderConfiguration.self, from: data) else {
      configuration = registry.defaultConfiguration()
      allowPersist = false
      migrationFailureMessage =
        "供应商配置数据损坏,已暂时使用出厂默认;原始数据保留未改动,重新选择并保存渠道后生效。"
      logger.error("供应商配置新旧格式均解码失败,保留原始数据不落盘")
      return
    }
    if let legacy = saved.legacyBindings {
      // 旧格式:内存里迁移成渠道模型(稳定确定性 ID,重建不产生新身份);
      // 盘上旧数据保持原样,首次显式保存才写新格式与迁移后的 Keychain 引用。
      configuration = Self.migratingConfiguration(from: legacy, registry: registry)
    } else {
      configuration = saved
    }
  }

  // MARK: - 旧格式迁移(内存级,读路径不回写)

  /// 旧 bindings → 渠道模型。去重键 = 角色 + provider + 标准化地址 + 旧凭证账户基址:
  /// 同 provider、同标准化地址、同旧凭证账户的绑定复用一个渠道,避免无意复制秘密。
  /// 渠道 ID 由去重键确定性派生,每次读取重建迁移结果身份不变。
  static func migratingConfiguration(
    from legacyBindings: [RoleProviderBinding],
    registry: ProviderRegistry
  ) -> ProviderConfiguration {
    var channels: [ProviderChannel] = []
    var selections: [RoleChannelSelection] = []
    var channelIDsByKey: [String: String] = [:]
    var storage = StorageConfiguration.default

    for rawBinding in legacyBindings {
      // 沿用既有载入期清理:Azure 容器地址剥掉误粘的 SAS/用户信息(内存级)。
      var binding = sanitizingAzureContainerURL(in: rawBinding)
      // 沿用既有防线:已移除的本地引擎落回当前默认(内存级,不触碰盘上旧数据)。
      if binding.role == .liveTranscriber,
        registry.provider(id: binding.providerID, for: binding.role) == nil
      {
        binding = registry.defaultBinding(for: .liveTranscriber)
      }
      let legacyBase = legacySecretAccountBase(
        role: binding.role,
        providerID: binding.providerID,
        baseURL: binding.baseURL
      )
      let dedupeKey =
        "\(binding.role.rawValue)|\(binding.providerID)"
        + "|\(normalizedEndpoint(binding.baseURL))|\(legacyBase)"
      let channelID: String
      if let existing = channelIDsByKey[dedupeKey] {
        channelID = existing
      } else {
        let id = ProviderChannel.deterministicID(
          seed: "justsaid.migrated-channel.v1|\(dedupeKey)"
        )
        let descriptor = registry.provider(id: binding.providerID, for: binding.role)
        channels.append(
          ProviderChannel(
            id: id,
            name: "\(descriptor?.displayName ?? binding.providerID)(\(binding.role.displayName))",
            providerID: binding.providerID,
            baseURL: binding.baseURL,
            appID: binding.appID,
            secretReference: "channel.\(id)",
            legacySecretAccountBase: legacyBase,
            supportedRoles: [binding.role],
            availableModels:
              binding.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ? [] : [binding.model]
          )
        )
        channelIDsByKey[dedupeKey] = id
        channelID = id
      }
      selections.append(
        RoleChannelSelection(
          role: binding.role,
          channelID: channelID,
          model: binding.model,
          reasoningEffort: binding.reasoningEffort,
          thinkingEnabled: binding.thinkingEnabled,
          asrResourceID: binding.asrResourceID,
          automaticLanguageRouting: binding.automaticLanguageRouting
        )
      )
      if binding.role == .batchASR {
        // 对象存储迁成独立配置并冻结账户基址:旧存储密钥账户逐字节保持可读。
        storage = StorageConfiguration(
          kind: binding.storageProviderKind,
          tosBucket: binding.tosBucket,
          tosRegion: binding.tosRegion,
          azureContainerURL: binding.azureContainerURL,
          r2AccountID: binding.r2AccountID,
          r2Bucket: binding.r2Bucket,
          secretAccountBase: "\(binding.role.rawValue).\(binding.providerID)",
          tosSecretEndpointSource: binding.baseURL
        )
      }
    }
    // 缺失的角色不回填默认:旧行为是访问时惰性回落,迁移保持同一语义。
    return ProviderConfiguration(
      channels: channels,
      roleSelections: selections,
      storage: storage
    )
  }

  // MARK: - 旧绑定表示的读取(投影,供 UI 与历史快照沿用)

  public func binding(for role: ProviderRole) -> RoleProviderBinding {
    guard let saved = configuration.binding(for: role) else {
      return registry.defaultBinding(for: role)
    }
    // 防御：若持久化的 providerID 在当前 registry 里已解析不出供应商
    // （例如未来供应商改名/下线后读到旧存档），不要把这个悬空绑定交给界面渲染——
    // 那会让厂商专属字段（如火山引擎的 TOS 分区）按错误的“通用”分支显示。
    // 干净地退回默认绑定，比展示一个 ID 对不上号的表单更安全。
    guard registry.provider(id: saved.providerID, for: role) != nil else {
      return registry.defaultBinding(for: role)
    }
    return saved
  }

  public func bindings(for language: MeetingLanguage) -> [RoleProviderBinding] {
    var bindings = configuration.bindings
    let liveBinding = binding(for: .liveTranscriber)
    let index: Int
    if let existingIndex = bindings.firstIndex(where: { $0.role == .liveTranscriber }) {
      index = existingIndex
      bindings[index] = liveBinding
    } else {
      index = bindings.endIndex
      bindings.append(liveBinding)
    }
    guard liveBinding.usesAutomaticLanguageRouting else {
      return bindings
    }

    // 08-11 纯 Qwen 体验分支:自动路由对 Auto/中/英一律选择 Qwen3-ASR。
    // 语言选择器仍管会中识别语种意图,由 Qwen actual stream 翻成 option;
    // 它不决定纪要份数。SenseVoice 与 Apple 只保留为设置页显式手选项。
    // Qwen 缺模型或启动失败由转写引擎如实报错,这里不得静默回退。
    let preferredID = "qwen3-asr-0.6b"
    guard
      let descriptor = registry.provider(
        id: preferredID,
        for: .liveTranscriber
      )
    else {
      return bindings
    }
    bindings[index].providerID = descriptor.id
    bindings[index].baseURL = descriptor.defaultBaseURL
    bindings[index].model = descriptor.defaultModel
    bindings[index].automaticLanguageRouting = true
    return bindings
  }

  /// 切换供应商：baseURL/model/APP ID/TOS 桶与区域重置为新供应商的默认值
  /// （这些是与供应商绑定的配置）；推理强度（`thinkingEnabled` 与 `reasoningEffort`）
  /// 是角色层面的偏好，不随供应商重置。
  ///
  /// 保留的是用户**原样选定**的档位，不是能力协商后的结果——存降级后的值会让
  /// 「自定义 → deepseek → 自定义」把用户原本选的最高档悄悄毁掉。
  public func selectProvider(id: String, for role: ProviderRole) {
    guard let descriptor = registry.provider(id: id, for: role) else {
      return
    }
    allowPersist = true
    let previous = binding(for: role)
    let channel = findOrCreateChannel(
      providerID: descriptor.id,
      baseURL: descriptor.defaultBaseURL,
      appID: "",
      role: role,
      name: descriptor.displayName,
      model: descriptor.defaultModel
    )
    var selection =
      configuration.selection(for: role)
      ?? RoleChannelSelection(
        role: role,
        channelID: channel.id,
        model: descriptor.defaultModel,
        reasoningEffort: previous.reasoningEffort,
        thinkingEnabled: previous.thinkingEnabled
      )
    selection.channelID = channel.id
    selection.model = descriptor.defaultModel
    selection.reasoningEffort = previous.reasoningEffort
    selection.thinkingEnabled = previous.thinkingEnabled
    if role == .liveTranscriber {
      selection.automaticLanguageRouting = false
    }
    upsert(selection)
    persist()
    if role == .batchASR {
      scheduleStorageHealthCheck()
    }
  }

  /// 用户在设置页选定推理档位。写入新字段的同时回写旧布尔，保证降级回旧版本仍可用；
  /// **回写只发生在用户主动选档时**——否则会把只有 `thinkingEnabled` 的旧配置改坏。
  public func updateReasoningEffort(
    _ level: ReasoningEffortLevel,
    for role: ProviderRole
  ) {
    allowPersist = true
    var selection = configuration.selection(for: role) ?? defaultSelection(for: role)
    selection.reasoningEffort = level
    selection.thinkingEnabled = level != .off
    upsert(selection)
    persist()
  }

  /// 这一次真正会发出去的档位（用户选择 → 供应商能力协商后的结果）。
  /// 供设置页显示与运行时构造客户端共用；**不回写配置**。
  public func effectiveReasoningEffort(for role: ProviderRole) -> ReasoningEffortLevel {
    reasoningResolution(for: role).level
  }

  public func supportedReasoningLevels(for role: ProviderRole) -> [ReasoningEffortLevel] {
    if let selection = configuration.selection(for: role),
      let channel = configuration.channel(id: selection.channelID)
    {
      // 渠道自己的声明优先;没有声明跟随 ProviderDescriptor。
      if let levels = channel.supportedReasoningLevels {
        return levels.union([.off]).sorted()
      }
      guard let descriptor = registry.provider(id: channel.providerID, for: role) else {
        return [.off]
      }
      return descriptor.supportedReasoningLevels.sorted()
    }
    let binding = binding(for: role)
    guard let descriptor = registry.provider(id: binding.providerID, for: role) else {
      return [.off]
    }
    return descriptor.supportedReasoningLevels.sorted()
  }

  private func reasoningResolution(
    for role: ProviderRole
  ) -> ReasoningEffortPolicy.Resolution {
    let requested: ReasoningEffortLevel
    let supported: Set<ReasoningEffortLevel>
    let providerID: String
    if let selection = configuration.selection(for: role) {
      requested = selection.effectiveReasoningEffort
      let channel = configuration.channel(id: selection.channelID)
      providerID = channel?.providerID ?? ""
      supported =
        channel?.supportedReasoningLevels
        ?? registry.provider(id: providerID, for: role)?
        .supportedReasoningLevels
        ?? [.off]
    } else {
      let binding = binding(for: role)
      requested = binding.effectiveReasoningEffort
      providerID = binding.providerID
      supported =
        registry.provider(id: providerID, for: role)?
        .supportedReasoningLevels ?? [.off]
    }
    return ReasoningEffortPolicy.resolve(
      requested: requested,
      supported: supported,
      role: role,
      providerID: providerID
    )
  }

  public func selectAutomaticLiveTranscriberRouting() {
    allowPersist = true
    let binding = registry.defaultBinding(for: .liveTranscriber)
    let channel = findOrCreateChannel(
      providerID: binding.providerID,
      baseURL: binding.baseURL,
      appID: binding.appID,
      role: .liveTranscriber,
      name: registry.provider(id: binding.providerID, for: .liveTranscriber)?
        .displayName ?? binding.providerID,
      model: binding.model
    )
    var selection =
      configuration.selection(for: .liveTranscriber)
      ?? RoleChannelSelection(role: .liveTranscriber, channelID: channel.id, model: binding.model)
    selection.channelID = channel.id
    selection.model = binding.model
    selection.automaticLanguageRouting = true
    upsert(selection)
    persist()
  }

  /// 旧 UI 的整绑定写入入口(兼容层):连接信息(providerID/地址/APP ID)落到渠道,
  /// 模型/推理档位/角色专属字段落到角色选择,存储字段落到独立存储配置。
  /// 渠道被多个角色共享时新建渠道而不是就地改——绝不让一次编辑悄悄改动其他角色。
  public func update(_ binding: RoleProviderBinding) {
    allowPersist = true
    let safeBinding = Self.sanitizingAzureContainerURL(in: binding)
    syncChannelAndSelection(for: safeBinding)
    if safeBinding.role == .batchASR {
      syncStorage(from: safeBinding)
    }
    persist()
    if safeBinding.role == .batchASR {
      scheduleStorageHealthCheck()
    }
  }

  private func syncChannelAndSelection(for binding: RoleProviderBinding) {
    let selection = configuration.selection(for: binding.role)
    let currentChannel = selection.flatMap { configuration.channel(id: $0.channelID) }
    let matchesCurrent =
      currentChannel != nil
      && currentChannel?.providerID == binding.providerID
      && Self.normalizedEndpoint(currentChannel?.baseURL ?? "")
        == Self.normalizedEndpoint(binding.baseURL)
      && (currentChannel?.appID ?? "") == binding.appID

    let targetChannelID: String
    if let currentChannel, matchesCurrent {
      targetChannelID = currentChannel.id
    } else if let reusable = configuration.channels.first(where: {
      $0.providerID == binding.providerID
        && Self.normalizedEndpoint($0.baseURL) == Self.normalizedEndpoint(binding.baseURL)
        && $0.appID == binding.appID
        && $0.supportedRoles.contains(binding.role)
    }) {
      targetChannelID = reusable.id
    } else if let current = currentChannel,
      !configuration.roleSelections.contains(where: {
        $0.channelID == current.id && $0.role != binding.role
      })
    {
      // 只被本角色引用:就地改连接信息,渠道 ID 不变。
      var updated = current
      updated.providerID = binding.providerID
      updated.baseURL = binding.baseURL
      updated.appID = binding.appID
      if let index = configuration.channels.firstIndex(where: { $0.id == current.id }) {
        configuration.channels[index] = updated
      }
      targetChannelID = current.id
    } else {
      // 渠道被其他角色共享,或选择悬空:为本次改动新建渠道,其他角色不动。
      targetChannelID =
        findOrCreateChannel(
          providerID: binding.providerID,
          baseURL: binding.baseURL,
          appID: binding.appID,
          role: binding.role,
          name: registry.provider(id: binding.providerID, for: binding.role)?
            .displayName ?? binding.providerID,
          model: binding.model
        ).id
    }

    var updatedSelection =
      selection
      ?? RoleChannelSelection(
        role: binding.role,
        channelID: targetChannelID,
        model: binding.model
      )
    updatedSelection.channelID = targetChannelID
    updatedSelection.model = binding.model
    updatedSelection.thinkingEnabled = binding.thinkingEnabled
    updatedSelection.reasoningEffort = binding.reasoningEffort
    updatedSelection.asrResourceID = binding.asrResourceID
    updatedSelection.automaticLanguageRouting = binding.automaticLanguageRouting
    upsert(updatedSelection)
  }

  /// 存储字段落到独立配置;账户基址与 TOS endpoint 来源保持冻结,不随编辑漂移。
  private func syncStorage(from binding: RoleProviderBinding) {
    var storage = configuration.storage
    storage.kind = binding.storageProviderKind
    storage.tosBucket = binding.tosBucket
    storage.tosRegion = binding.tosRegion
    storage.azureContainerURL = binding.azureContainerURL
    storage.r2AccountID = binding.r2AccountID
    storage.r2Bucket = binding.r2Bucket
    configuration.storage = storage
  }

  private func findOrCreateChannel(
    providerID: String,
    baseURL: String,
    appID: String,
    role: ProviderRole,
    name: String,
    model: String
  ) -> ProviderChannel {
    if let existing = configuration.channels.first(where: {
      $0.providerID == providerID
        && Self.normalizedEndpoint($0.baseURL) == Self.normalizedEndpoint(baseURL)
        && $0.appID == appID
        && $0.supportedRoles.contains(role)
    }) {
      return existing
    }
    let id = UUID().uuidString
    let channel = ProviderChannel(
      id: id,
      name: name,
      providerID: providerID,
      baseURL: baseURL,
      appID: appID,
      secretReference: "channel.\(id)",
      supportedRoles: [role],
      availableModels:
        model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [model]
    )
    configuration.channels.append(channel)
    return channel
  }

  private func defaultSelection(for role: ProviderRole) -> RoleChannelSelection {
    let binding = registry.defaultBinding(for: role)
    let channel = findOrCreateChannel(
      providerID: binding.providerID,
      baseURL: binding.baseURL,
      appID: binding.appID,
      role: role,
      name: registry.provider(id: binding.providerID, for: role)?
        .displayName ?? binding.providerID,
      model: binding.model
    )
    return RoleChannelSelection(
      role: role,
      channelID: channel.id,
      model: binding.model,
      reasoningEffort: binding.reasoningEffort,
      thinkingEnabled: binding.thinkingEnabled,
      asrResourceID: binding.asrResourceID,
      automaticLanguageRouting: binding.automaticLanguageRouting
    )
  }

  private func upsert(_ selection: RoleChannelSelection) {
    if let index = configuration.roleSelections.firstIndex(where: {
      $0.role == selection.role
    }) {
      configuration.roleSelections[index] = selection
    } else {
      configuration.roleSelections.append(selection)
    }
  }

  // MARK: - 渠道 CRUD 与角色选择(新信息架构的核心 API)

  /// 创建渠道。凭证不进这里:保存后另用 `saveSecret` 按渠道账户写入 Keychain。
  @discardableResult
  public func createChannel(
    name: String,
    providerID: String,
    baseURL: String,
    appID: String = "",
    supportedRoles: Set<ProviderRole>,
    availableModels: [String] = [],
    supportedReasoningLevels: Set<ReasoningEffortLevel>? = nil
  ) throws -> ProviderChannel {
    allowPersist = true
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw ProviderChannelError.emptyName
    }
    let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedURL.isEmpty {
      guard let url = URL(string: trimmedURL), url.scheme != nil, url.host != nil else {
        throw ProviderChannelError.invalidBaseURL(baseURL)
      }
    }
    let id = UUID().uuidString
    let channel = ProviderChannel(
      id: id,
      name: trimmedName,
      providerID: providerID,
      baseURL: trimmedURL,
      appID: appID,
      secretReference: "channel.\(id)",
      supportedRoles: supportedRoles,
      availableModels: availableModels,
      supportedReasoningLevels: supportedReasoningLevels
    )
    configuration.channels.append(channel)
    persist()
    return channel
  }

  /// 编辑渠道:ID 不可变;不得把仍引用它的角色移出能力集(引用完整性)。
  public func updateChannel(_ channel: ProviderChannel) throws {
    allowPersist = true
    guard let index = configuration.channels.firstIndex(where: { $0.id == channel.id }) else {
      throw ProviderChannelError.notFound(channelID: channel.id)
    }
    let trimmedName = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw ProviderChannelError.emptyName
    }
    let trimmedURL = channel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedURL.isEmpty {
      guard let url = URL(string: trimmedURL), url.scheme != nil, url.host != nil else {
        throw ProviderChannelError.invalidBaseURL(channel.baseURL)
      }
    }
    for selection in configuration.roleSelections where selection.channelID == channel.id {
      guard channel.supportedRoles.contains(selection.role) else {
        throw ProviderChannelError.capabilityMismatch(
          channelName: trimmedName,
          role: selection.role
        )
      }
      // 引用完整性延伸到模型:非空模型列表必须仍包含引用角色正在用的模型
      // (大小写不敏感)——否则保存一生效,该角色的选择就成了渠道声明外的组合。
      // 校验全部在写入前,拒绝就是整体拒绝,不存在写了一半的状态。
      guard
        channel.availableModels.isEmpty
          || Self.declaredModel(matching: selection.model, in: channel.availableModels)
            != nil
      else {
        // 报错要给出路:带上正在引用该模型的角色,用户才知道去哪个角色卡解锁。
        // 收集与匹配同一口径(大小写折叠):既然白名单匹配不分大小写,大小写变体
        // 引用同一被删模型的角色也一样被挡,漏列会让用户少解锁一张角色卡。
        let foldedModel = selection.model.lowercased()
        let referencingRoles = configuration.roleSelections
          .filter { $0.channelID == channel.id && $0.model.lowercased() == foldedModel }
          .map(\.role)
        throw ProviderChannelError.modelNotDeclared(
          channelName: trimmedName,
          model: selection.model,
          roles: referencingRoles
        )
      }
    }
    var sanitized = channel
    sanitized.name = trimmedName
    sanitized.baseURL = trimmedURL
    configuration.channels[index] = sanitized
    persist()
  }

  /// 删除渠道:仍被任一角色选择引用的渠道不能删(错误列出全部引用角色)。
  /// 历史会议只存快照不反向引用,删除渠道不改变历史文件;Keychain 账户
  /// (含旧账户)一律保留不删,旧版本回滚后仍能读到凭证。
  public func deleteChannel(id: String) throws {
    allowPersist = true
    guard let channel = configuration.channel(id: id) else {
      throw ProviderChannelError.notFound(channelID: id)
    }
    let referencingRoles = channelReferences(id: id)
    guard referencingRoles.isEmpty else {
      throw ProviderChannelError.channelInUse(
        channelName: channel.name,
        roles: referencingRoles
      )
    }
    configuration.channels.removeAll { $0.id == id }
    persist()
  }

  /// 哪些角色正在选择这个渠道。
  public func channelReferences(id: String) -> [ProviderRole] {
    configuration.roleSelections.filter { $0.channelID == id }.map(\.role)
  }

  public func channelsSupporting(role: ProviderRole) -> [ProviderChannel] {
    configuration.channels.filter { $0.supportedRoles.contains(role) }
  }

  public func selection(for role: ProviderRole) -> RoleChannelSelection? {
    configuration.selection(for: role)
  }

  /// 角色选择渠道:能力不匹配直接报错,绝不静默换成默认渠道。
  /// 模型不在渠道声明内(大小写不敏感)时落到声明的第一个模型;仅大小写不同时
  /// 纠正为列表声明的那条(空列表 = 不约束,保持当前值)。
  public func selectChannel(channelID: String, for role: ProviderRole) throws {
    allowPersist = true
    guard let channel = configuration.channel(id: channelID) else {
      throw ProviderChannelError.notFound(channelID: channelID)
    }
    guard channel.supportedRoles.contains(role) else {
      throw ProviderChannelError.capabilityMismatch(channelName: channel.name, role: role)
    }
    var selection =
      configuration.selection(for: role)
      ?? RoleChannelSelection(role: role, channelID: channelID, model: "")
    selection.channelID = channelID
    if !channel.availableModels.isEmpty {
      selection.model =
        Self.declaredModel(matching: selection.model, in: channel.availableModels)
        ?? channel.availableModels[0]
    }
    // 显式选渠道 = 退出自动路由(与旧 UI selectProvider 的语义一致);
    // 不清掉的话,会中速记选了具体引擎也会被自动路由拽回 Qwen。
    if role == .liveTranscriber {
      selection.automaticLanguageRouting = false
    }
    upsert(selection)
    persist()
  }

  /// 角色选择模型:渠道声明了模型列表时,不支持的组合不能选(匹配大小写不敏感,
  /// 仅大小写不同时落盘值取列表声明的那条——渠道声明的才是它承诺可发的)。
  public func selectModel(_ model: String, for role: ProviderRole) throws {
    allowPersist = true
    guard let selection = configuration.selection(for: role) else {
      throw ProviderRuntimeConfigurationError.missingRoleSelection(role)
    }
    guard let channel = configuration.channel(id: selection.channelID) else {
      throw ProviderRuntimeConfigurationError.unknownChannel(
        role,
        channelID: selection.channelID
      )
    }
    var resolved = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if !channel.availableModels.isEmpty {
      guard
        let declared = Self.declaredModel(matching: resolved, in: channel.availableModels)
      else {
        throw ProviderChannelError.modelNotDeclared(
          channelName: channel.name,
          model: model,
          roles: []
        )
      }
      resolved = declared
    }
    var updated = selection
    updated.model = resolved
    upsert(updated)
    persist()
  }

  /// 白名单匹配大小写不敏感:返回**列表里声明的那条**(渠道声明的才是它承诺可发的)。
  /// 精确命中优先;否则取第一条大小写不敏感相等的声明;完全不匹配返回 nil。
  private static func declaredModel(
    matching model: String,
    in availableModels: [String]
  ) -> String? {
    if availableModels.contains(model) {
      return model
    }
    let folded = model.lowercased()
    return availableModels.first { $0.lowercased() == folded }
  }

  // MARK: - Keychain 密钥（多槽位）

  /// 存入前必须去掉首尾空白:凭证几乎总是从控制台复制粘贴来的,尾随空格或换行看不见,
  /// 却会让签名头变成畸形。2026-08-07 实测:R2 对 Access Key ID 长度硬校验,
  /// 多一个空格就是「length 33, should be 32」并返回 HTTP 400
  /// ——而格式正确、仅签名错时它返回的是 401。两者含义完全不同,不能让空格伪装成凭证错误。
  ///
  /// 密钥本身不含首尾空白(各家控制台生成的都是 base64/hex),因此 trim 不会损坏合法值。
  public func saveSecret(
    _ value: String,
    slot: ProviderSecretSlot,
    for binding: RoleProviderBinding
  ) throws {
    allowPersist = true
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch secretDestination(slot: slot, for: binding) {
    case .channel(let channel):
      try secretStore.save(value, account: Self.secretAccount(slot: slot, for: channel))
    case .storage(let storage):
      try secretStore.save(value, account: Self.secretAccount(slot: slot, forStorage: storage))
    case .legacy(let account):
      try secretStore.save(value, account: account)
    }
    if binding.role == .batchASR {
      scheduleStorageHealthCheck()
    }
  }

  public func hasSecret(slot: ProviderSecretSlot, for binding: RoleProviderBinding) -> Bool {
    switch secretDestination(slot: slot, for: binding) {
    case .channel(let channel):
      return channelSecretCandidates(slot: slot, channel: channel, role: binding.role)
        .contains { secretStore.contains(account: $0) }
    case .storage(let storage):
      return secretStore.contains(
        account: Self.secretAccount(slot: slot, forStorage: storage)
      )
    case .legacy(let account):
      return secretStore.contains(account: account)
    }
  }

  /// 运行时按需读取密钥。调用方只应把返回值放进短生命周期的请求配置，
  /// 不得写入文件、UserDefaults 或日志。读路径不回写:命中旧账户也不复制。
  public func loadSecret(
    slot: ProviderSecretSlot,
    for binding: RoleProviderBinding
  ) throws -> String? {
    switch secretDestination(slot: slot, for: binding) {
    case .channel(let channel):
      return try firstAvailableSecret(
        channelSecretCandidates(slot: slot, channel: channel, role: binding.role)
      )
    case .storage(let storage):
      return try secretStore.load(account: Self.secretAccount(slot: slot, forStorage: storage))
    case .legacy(let account):
      return try secretStore.load(account: account)
    }
  }

  /// 已保存密钥的末四位，供设置页显示「✓ 已保存 ····末四位」；不保存/不可读时返回 nil。
  public func secretSuffix(slot: ProviderSecretSlot, for binding: RoleProviderBinding) -> String? {
    guard let value = try? loadSecret(slot: slot, for: binding), !value.isEmpty else {
      return nil
    }
    return String(value.suffix(4))
  }

  /// 便捷封装：绝大多数角色只有一个密钥槽位（LLM 的 API key、通用型 ASR 的 API key）。
  public func saveAPIKey(_ key: String, for binding: RoleProviderBinding) throws {
    try saveSecret(key, slot: .apiKey, for: binding)
  }

  public func hasAPIKey(for binding: RoleProviderBinding) -> Bool {
    hasSecret(slot: .apiKey, for: binding)
  }

  // MARK: - 渠道上下文的凭证与探针(设置页渠道管理专用)

  /// 渠道凭证直接落渠道账户:同地址的两个渠道各存各的钥匙,不经绑定坐标推导。
  /// 与绑定入口同样先 trim——凭证几乎总是粘贴来的,尾随空白会让签名头畸形。
  public func saveSecret(
    _ value: String,
    slot: ProviderSecretSlot,
    forChannel channel: ProviderChannel
  ) throws {
    allowPersist = true
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    try secretStore.save(value, account: Self.secretAccount(slot: slot, for: channel))
  }

  /// 「这把 key 存了吗」:任一候选账户(渠道账户 → 迁移来源旧账户 → 坐标派生旧账户)命中即算。
  public func hasSecret(slot: ProviderSecretSlot, forChannel channel: ProviderChannel) -> Bool {
    channelSecretCandidates(
      slot: slot,
      channel: channel,
      role: channel.supportedRoles.first ?? .batchASR
    )
    .contains { secretStore.contains(account: $0) }
  }

  /// 已存渠道密钥的末四位;没存或读不到时返回 nil。读路径不回写。
  public func secretSuffix(slot: ProviderSecretSlot, forChannel channel: ProviderChannel) -> String?
  {
    guard
      let value = try? firstAvailableSecret(
        channelSecretCandidates(
          slot: slot,
          channel: channel,
          role: channel.supportedRoles.first ?? .batchASR
        )
      ),
      !value.isEmpty
    else {
      return nil
    }
    return String(value.suffix(4))
  }

  /// 渠道上下文的 LLM 客户端:连接测试与模型拉取不经过角色选择——
  /// 渠道可能还没被任何角色引用(新建中),也必须能测、能拉。
  /// 探针是「答不答话」级别的问候,固定发 `.off` 档,不为测试白烧推理预算。
  public func makeLLMClient(
    forChannel channel: ProviderChannel,
    model: String,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) throws -> any LLMClient {
    let name = channel.name
    let baseURLText = channel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !baseURLText.isEmpty else {
      throw ProviderChannelError.missingChannelBaseURL(channelName: name)
    }
    guard let baseURL = URL(string: baseURLText) else {
      throw ProviderChannelError.invalidBaseURL(baseURLText)
    }
    guard baseURL.scheme?.lowercased() == "https" else {
      throw ProviderChannelError.insecureChannelBaseURL(channelName: name)
    }
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedModel.isEmpty else {
      throw ProviderChannelError.missingChannelModel(channelName: name)
    }
    let secretCandidates = channelSecretCandidates(
      slot: .apiKey,
      channel: channel,
      role: channel.supportedRoles.first ?? .minutesLLM
    )
    guard
      let apiKey = try firstAvailableSecret(secretCandidates),
      !apiKey.isEmpty
    else {
      throw ProviderChannelError.missingChannelSecret(channelName: name, slot: .apiKey)
    }
    return OpenAICompatibleLLMClient(
      configuration: LLMClientConfiguration(
        providerID: channel.providerID,
        baseURL: baseURL,
        apiKey: apiKey,
        model: trimmedModel,
        reasoningEffort: .off,
        diagnosticRole: channel.supportedRoles.first?.rawValue,
        diagnosticPurpose: "connectionProbe",
        diagnosticOrigin: "channel"
      ),
      transport: transport,
      // 渠道探针(连接测试/模型拉取)是设置页的即时反馈,自己卡 30 秒空闲上限;
      // 外层 ConnectionProbe 另有同额超时兜底,两个时钟取先响的。
      // 不设首帧超时:探针的总时长本来就被外层墙钟卡死,再加一层只会多一种失败说法。
      idleTimeout: 30
    )
  }

  /// 旧 API(绑定坐标)写入的落点:存储槽位永远落独立存储配置;
  /// 角色凭证优先落坐标一致的渠道,找不到匹配渠道才回落旧派生账户——
  /// 保证 save/load 对任意绑定对称(验证里刻意用未保存的绑定)。
  private enum SecretDestination {
    case channel(ProviderChannel)
    case storage(StorageConfiguration)
    case legacy(account: String)
  }

  private func secretDestination(
    slot: ProviderSecretSlot,
    for binding: RoleProviderBinding
  ) -> SecretDestination {
    switch slot {
    case .tosAccessKey, .tosSecretKey, .azureSAS, .azureManagementSAS, .azureReadOnlySAS,
      .azureAccountKey, .r2AccessKey, .r2SecretKey:
      return .storage(configuration.storage)
    case .apiKey, .accessToken:
      break
    }
    if let selection = configuration.selection(for: binding.role),
      let channel = configuration.channel(id: selection.channelID),
      channel.providerID == binding.providerID,
      Self.normalizedEndpoint(channel.baseURL) == Self.normalizedEndpoint(binding.baseURL)
    {
      return .channel(channel)
    }
    if let channel = configuration.channels.first(where: {
      $0.providerID == binding.providerID
        && Self.normalizedEndpoint($0.baseURL) == Self.normalizedEndpoint(binding.baseURL)
        && $0.supportedRoles.contains(binding.role)
    }) {
      return .channel(channel)
    }
    return .legacy(account: Self.secretAccount(slot: slot, for: binding))
  }

  /// 渠道秘密的候选账户,按优先级:① 新渠道账户;② 迁移来源的旧账户基址;
  /// ③ 按渠道坐标算出的旧派生账户(旧版本 App 为同一供应商+地址保存的密钥)。
  /// 三个候选都只读;显式保存永远写 ①。
  private func channelSecretCandidates(
    slot: ProviderSecretSlot,
    channel: ProviderChannel,
    role: ProviderRole
  ) -> [String] {
    var accounts = [Self.secretAccount(slot: slot, for: channel)]
    if let legacyBase = channel.legacySecretAccountBase {
      accounts.append("\(legacyBase).\(slot.rawValue)")
    }
    accounts.append(
      Self.secretAccount(
        slot: slot,
        for: RoleProviderBinding(
          role: role,
          providerID: channel.providerID,
          baseURL: channel.baseURL,
          model: ""
        )
      )
    )
    var seen = Set<String>()
    return accounts.filter { seen.insert($0).inserted }
  }

  private func firstAvailableSecret(_ candidates: [String]) throws -> String? {
    for account in candidates {
      if let value = try secretStore.load(account: account) {
        return value
      }
    }
    return nil
  }

  // MARK: - 运行时解析(角色 → 选择 → 渠道)

  /// 解析链的统一入口:渠道必须存在、声明支持该角色;错误带角色与渠道可见名称,
  /// 绝不静默回落默认渠道。
  private func resolveChannel(
    for role: ProviderRole
  ) throws -> (channel: ProviderChannel, selection: RoleChannelSelection) {
    guard let selection = configuration.selection(for: role) else {
      throw ProviderRuntimeConfigurationError.missingRoleSelection(role)
    }
    guard let channel = configuration.channel(id: selection.channelID) else {
      throw ProviderRuntimeConfigurationError.unknownChannel(
        role,
        channelID: selection.channelID
      )
    }
    guard channel.supportedRoles.contains(role) else {
      throw ProviderRuntimeConfigurationError.channelDoesNotSupportRole(
        role,
        channelName: channel.name
      )
    }
    return (channel, selection)
  }

  public func makeLLMClient(
    for role: ProviderRole,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) throws -> any LLMClient {
    try makeLLMClient(
      for: role,
      transport: transport,
      reasoningOverride: nil,
      diagnosticPurpose: role.rawValue,
      diagnosticOrigin: "production"
    )
  }

  /// 「测试连接」探针用(08-13 D3):与正式链路同一渠道/模型/密钥解析——测的就是
  /// 该角色此刻真正生效的配置——唯一区别是推理档固定「关闭」。探针测连通性不测质量,
  /// 高档思考在外层 30 秒硬超时下只会制造假超时;与渠道上下文探针
  /// (`makeLLMClient(forChannel:model:)` 固定 `.off`)同一口径。
  public func makeConnectionTestLLMClient(
    for role: ProviderRole,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) throws -> any LLMClient {
    try makeLLMClient(
      for: role,
      transport: transport,
      reasoningOverride: .off,
      diagnosticPurpose: "connectionProbe",
      diagnosticOrigin: "connectionProbe"
    )
  }

  /// 认名前置提取(08-20 naming-first)专用客户端:复用**会中总结**的渠道/模型/密钥
  /// (flash 档,不动纪要大模型),但超时口径按会后语义放宽——提取输入是整场转写,
  /// prefill 远长于会中总结,45 秒首帧会制造假超时;会后无节奏可赶,宁可等。
  /// 推理档固定「关」:提取是抽取不是推理,thinking 只烧钱(与连接探针同口径)。
  public func makeSpeakerNamingLLMClient(
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) throws -> any LLMClient {
    try makeLLMClient(
      for: .liveSummaryLLM,
      transport: transport,
      reasoningOverride: .off,
      usesPostMeetingTimeouts: true,
      diagnosticPurpose: CloudUsageRecord.speakerNamingPurpose,
      diagnosticOrigin: "postMeeting"
    )
  }

  private func makeLLMClient(
    for role: ProviderRole,
    transport: any HTTPTransport,
    reasoningOverride: ReasoningEffortLevel?,
    usesPostMeetingTimeouts: Bool = false,
    diagnosticPurpose: String,
    diagnosticOrigin: String
  ) throws -> any LLMClient {
    guard role.isLLMRole else {
      throw ProviderRuntimeConfigurationError.unsupportedRole
    }
    let (channel, selection) = try resolveChannel(for: role)
    let baseURLText = channel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !baseURLText.isEmpty else {
      throw ProviderRuntimeConfigurationError.missingBaseURL(role)
    }
    guard let baseURL = URL(string: baseURLText) else {
      throw ProviderRuntimeConfigurationError.invalidBaseURL(role)
    }
    guard baseURL.scheme?.lowercased() == "https" else {
      throw ProviderRuntimeConfigurationError.insecureBaseURL(role)
    }
    let model = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else {
      throw ProviderRuntimeConfigurationError.missingModel(role)
    }
    let secretCandidates = channelSecretCandidates(slot: .apiKey, channel: channel, role: role)
    guard
      let apiKey = try firstAvailableSecret(secretCandidates),
      !apiKey.isEmpty
    else {
      throw ProviderRuntimeConfigurationError.missingSecret(
        role,
        .apiKey,
        key: secretCandidates.joined(separator: " 或 ")
      )
    }
    // 能力协商在配置层做完,客户端只收最终档位。降级是正常路径,绝不让请求失败。
    // 探针 override 跳过协商直接取「关闭」:每家能力集必含 .off
    // (BatchPipelineVerification 有正断言),不存在发不出去的组合。
    let requestedLevel = reasoningOverride ?? requestedReasoning(for: role)
    let resolution =
      reasoningOverride.map {
        ReasoningEffortPolicy.Resolution(level: $0, downgradeNotice: nil)
      } ?? reasoningResolution(for: role)
    if let notice = resolution.downgradeNotice {
      logger.notice("\(notice, privacy: .public)")
    }
    return OpenAICompatibleLLMClient(
      configuration: LLMClientConfiguration(
        providerID: channel.providerID,
        baseURL: baseURL,
        apiKey: apiKey,
        model: model,
        reasoningEffort: resolution.level,
        requestedReasoningEffort: requestedLevel,
        diagnosticRole: role.rawValue,
        diagnosticPurpose: diagnosticPurpose,
        diagnosticOrigin: diagnosticOrigin
      ),
      transport: transport,
      // 会后纪要走 SSE 流式,但 URLRequest.timeoutInterval 是**空闲**超时:推理档开着时,
      // 模型可能思考数分钟才吐第一个 token,长会议尤甚。2026-08-07 实测:91 分钟会议的
      // 英文版纪要在 300 秒上超时,而中文版已成功——转写与中文纪要都在盘上,整场却被标失败。
      // `usesPostMeetingTimeouts`(08-20 naming-first):认名提取借 liveSummary 渠道
      // 但按会后口径取超时——它的输入是整场转写,会中档超时对它就是假超时制造机。
      idleTimeout: role == .liveSummaryLLM && !usesPostMeetingTimeouts
        ? OpenAICompatibleLLMClient.liveSummaryIdleTimeout : 600,
      // 首帧超时只给会中总结:它要跟上会议节奏,等不到首帧就该早点认输交给下一轮。
      // 会后纪要**必须保持 nil**——同上那次事故里首 token 就来在 300 秒之后,
      // 给它设首帧超时等于当场复刻。
      firstFrameTimeout: role == .liveSummaryLLM && !usesPostMeetingTimeouts
        ? OpenAICompatibleLLMClient.liveSummaryFirstFrameTimeout : nil
    )
  }

  private func requestedReasoning(for role: ProviderRole) -> ReasoningEffortLevel {
    if let selection = configuration.selection(for: role) {
      return selection.effectiveReasoningEffort
    }
    return binding(for: role).effectiveReasoningEffort
  }

  public func makeDefaultPostMeetingPipeline(
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    meetingStore: MeetingStore = MeetingStore(),
    configuration: PostMeetingPipelineConfiguration = PostMeetingPipelineConfiguration(),
    dictionaryStore: DictionaryStore = DictionaryStore()
  ) throws -> PostMeetingPipeline {
    try makePostMeetingPipeline(
      storage: makeConfiguredStorageProvider(transport: transport),
      batchTranscriber: makeConfiguredBatchTranscriptionProvider(
        transport: transport,
        dictionaryStore: dictionaryStore
      ),
      transport: transport,
      meetingStore: meetingStore,
      configuration: configuration,
      dictionaryStore: dictionaryStore
    )
  }

  public func makeConfiguredBatchTranscriptionProvider(
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    dictionaryStore: DictionaryStore = DictionaryStore()
  ) throws -> any BatchTranscriptionProvider {
    let (channel, selection) = try resolveChannel(for: .batchASR)
    guard channel.providerID == "volcengine-doubao-asr" else {
      throw ProviderRuntimeConfigurationError.unsupportedBatchProvider(
        channel.providerID
      )
    }
    // 鉴权优先级(2026-07-30 新控制台迁移):存了新版 API Key 就用新版;
    // 否则回落旧版 APP ID + Access Token(官方仍兼容,但"逐步下线")。
    let authentication: VolcengineSpeechAuthentication
    let apiKeyCandidates = channelSecretCandidates(slot: .apiKey, channel: channel, role: .batchASR)
    if let apiKey = try firstAvailableSecret(apiKeyCandidates),
      !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      authentication = .apiKey(apiKey)
    } else {
      let appID = channel.appID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !appID.isEmpty else {
        throw ProviderRuntimeConfigurationError.missingSecret(
          .batchASR,
          .apiKey,
          key: apiKeyCandidates.joined(separator: " 或 ")
        )
      }
      let tokenCandidates = channelSecretCandidates(
        slot: .accessToken,
        channel: channel,
        role: .batchASR
      )
      guard
        let accessToken = try firstAvailableSecret(tokenCandidates),
        !accessToken.isEmpty
      else {
        throw ProviderRuntimeConfigurationError.missingSecret(
          .batchASR,
          .accessToken,
          key: tokenCandidates.joined(separator: " 或 ")
        )
      }
      authentication = .legacy(appID: appID, accessToken: accessToken)
    }
    return VolcengineBatchTranscriptionProvider(
      configuration: VolcengineBatchTranscriptionConfiguration(
        authentication: authentication,
        resourceID: selection.selectedASRResourceID
      ),
      transport: transport,
      dictionaryStore: dictionaryStore
    )
  }

  /// 对象存储独立解析:只读 `StorageConfiguration`,与 ASR 渠道解耦——
  /// 切换/重建 AI 渠道不影响存储账户;Azure/TOS/R2 永不进入渠道列表。
  public func makeConfiguredStorageProvider(
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) throws -> any StorageProvider {
    try Self.makeConfiguredStorageProvider(
      storage: configuration.storage,
      secretStore: secretStore,
      transport: transport
    )
  }

  private nonisolated static func makeConfiguredStorageProvider(
    storage: StorageConfiguration,
    secretStore: any ProviderSecretStore,
    transport: any HTTPTransport
  ) throws -> any StorageProvider {
    func storageSecret(_ slot: ProviderSecretSlot) throws -> String? {
      try secretStore.load(account: Self.secretAccount(slot: slot, forStorage: storage))
    }
    func storageAccount(_ slot: ProviderSecretSlot) -> String {
      Self.secretAccount(slot: slot, forStorage: storage)
    }
    switch storage.selectedKind {
    case .volcengineTOS:
      let bucket = storage.tosBucket.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !bucket.isEmpty else {
        throw ProviderRuntimeConfigurationError.missingField("TOS 桶")
      }
      let region = storage.tosRegion.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !region.isEmpty else {
        throw ProviderRuntimeConfigurationError.missingField("TOS 区域")
      }
      guard
        let accessKey = try storageSecret(.tosAccessKey),
        !accessKey.isEmpty
      else {
        throw ProviderRuntimeConfigurationError.missingSecret(
          .batchASR,
          .tosAccessKey,
          key: storageAccount(.tosAccessKey)
        )
      }
      guard
        let secretKey = try storageSecret(.tosSecretKey),
        !secretKey.isEmpty
      else {
        throw ProviderRuntimeConfigurationError.missingSecret(
          .batchASR,
          .tosSecretKey,
          key: storageAccount(.tosSecretKey)
        )
      }
      return VolcengineTOSStorageProvider(
        configuration: VolcengineTOSConfiguration(
          region: region,
          bucket: bucket,
          accessKey: accessKey,
          secretKey: secretKey
        ),
        transport: transport
      )

    case .cloudflareR2:
      let accountID =
        storage.r2AccountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !accountID.isEmpty else {
        throw ProviderRuntimeConfigurationError.missingField("R2 Account ID")
      }
      let bucket = storage.r2Bucket?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !bucket.isEmpty else {
        throw ProviderRuntimeConfigurationError.missingField("R2 Bucket")
      }
      guard
        let accessKey = try storageSecret(.r2AccessKey),
        !accessKey.isEmpty
      else {
        throw ProviderRuntimeConfigurationError.missingSecret(
          .batchASR,
          .r2AccessKey,
          key: storageAccount(.r2AccessKey)
        )
      }
      guard
        let secretKey = try storageSecret(.r2SecretKey),
        !secretKey.isEmpty
      else {
        throw ProviderRuntimeConfigurationError.missingSecret(
          .batchASR,
          .r2SecretKey,
          key: storageAccount(.r2SecretKey)
        )
      }
      return CloudflareR2StorageProvider(
        configuration: CloudflareR2Configuration(
          accountID: accountID,
          bucket: bucket,
          accessKey: accessKey,
          secretKey: secretKey
        ),
        transport: transport
      )

    case .azureBlob:
      let containerURLText =
        storage.azureContainerURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !containerURLText.isEmpty else {
        throw ProviderRuntimeConfigurationError.missingField("Azure 容器 URL")
      }
      guard
        let components = URLComponents(string: containerURLText),
        components.query == nil,
        components.fragment == nil,
        components.user == nil,
        components.password == nil,
        let containerURL = components.url,
        containerURL.scheme?.lowercased() == "https",
        containerURL.host != nil
      else {
        throw ProviderRuntimeConfigurationError.invalidField("Azure 容器 URL")
      }
      let managementSAS = try storageSecret(.azureManagementSAS) ?? ""
      let accountKey = try storageSecret(.azureAccountKey) ?? ""
      // 仅凭账户共享密钥即可:管理操作所需的账户级 SAS 由 provider 现场派生,
      // 用户不必额外准备管理 SAS(2026-07-29 真机实测通过)。
      if !accountKey.isEmpty {
        if managementSAS.isEmpty {
          return AzureBlobStorageProvider(
            configuration: AzureBlobStorageConfiguration(
              containerURL: containerURL,
              accountSharedKey: accountKey
            ),
            transport: transport
          )
        }
        return AzureBlobStorageProvider(
          configuration: AzureBlobStorageConfiguration(
            containerURL: containerURL,
            managementSASToken: managementSAS,
            readSASAccountKey: accountKey
          ),
          transport: transport
        )
      }
      guard !managementSAS.isEmpty else {
        throw ProviderRuntimeConfigurationError.missingSecret(
          .batchASR,
          .azureAccountKey,
          key: storageAccount(.azureAccountKey)
        )
      }
      if let readOnlySAS = try storageSecret(.azureReadOnlySAS),
        !readOnlySAS.isEmpty
      {
        return AzureBlobStorageProvider(
          configuration: AzureBlobStorageConfiguration(
            containerURL: containerURL,
            managementSASToken: managementSAS,
            readOnlySASToken: readOnlySAS
          ),
          transport: transport
        )
      }
      throw ProviderRuntimeConfigurationError.missingSecret(
        .batchASR,
        .azureAccountKey,
        key: storageAccount(.azureAccountKey)
      )
    }
  }

  /// 启动、设置保存和“测试连接”共用同一条轻量 HEAD 探测。
  /// 自动探测在配置未填完整时保持安静；用户主动测试时则返回可读的缺项提示。
  public func refreshStorageHealth(showConfigurationErrors: Bool = false) async {
    storageHealthGeneration &+= 1
    let expectedGeneration = storageHealthGeneration
    let storageConfiguration = configuration.storage
    let secretStore = secretStore
    let transport = healthCheckTransport
    let storage: any StorageProvider
    do {
      storage = try await Task.detached(priority: .utility) {
        try Self.makeConfiguredStorageProvider(
          storage: storageConfiguration,
          secretStore: secretStore,
          transport: transport
        )
      }.value
      guard
        !Task.isCancelled,
        expectedGeneration == storageHealthGeneration
      else {
        return
      }
    } catch let error as ProviderRuntimeConfigurationError {
      guard
        !Task.isCancelled,
        expectedGeneration == storageHealthGeneration
      else {
        return
      }
      let message = showConfigurationErrors ? error.localizedDescription : nil
      storageHealthMessage = message
      storageHealthFailureMessage = message
      return
    } catch {
      guard
        !Task.isCancelled,
        expectedGeneration == storageHealthGeneration
      else {
        return
      }
      let message = showConfigurationErrors ? error.localizedDescription : nil
      storageHealthMessage = message
      storageHealthFailureMessage = message
      return
    }

    storageHealthMessage = "正在检查对象存储连接…"
    do {
      let result = try await storage.healthCheck()
      guard
        !Task.isCancelled,
        expectedGeneration == storageHealthGeneration
      else {
        return
      }
      storageHealthMessage = result.message
      storageHealthFailureMessage = nil
    } catch is CancellationError {
      return
    } catch {
      guard
        !Task.isCancelled,
        expectedGeneration == storageHealthGeneration
      else {
        return
      }
      storageHealthMessage = error.localizedDescription
      storageHealthFailureMessage = error.localizedDescription
    }
  }

  /// App 启动时网络栈或代理可能尚未就绪；首次失败后短暂重试两次，任一次成功即静默。
  /// 设置页的手动“测试连接”仍直接调用 `refreshStorageHealth`，保持单次请求。
  public func refreshStorageHealthForStartup(
    retryDelays: [TimeInterval] = [2, 5],
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    }
  ) async {
    await refreshStorageHealth()
    for delay in retryDelays {
      guard storageHealthFailureMessage != nil, !Task.isCancelled else { return }
      do {
        try await sleep(max(0, delay))
      } catch {
        return
      }
      await refreshStorageHealth()
    }
  }

  public func makePostMeetingPipeline(
    storage: any StorageProvider,
    batchTranscriber: any BatchTranscriptionProvider,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    meetingStore: MeetingStore = MeetingStore(),
    configuration: PostMeetingPipelineConfiguration = PostMeetingPipelineConfiguration(),
    dictionaryStore: DictionaryStore = DictionaryStore()
  ) throws -> PostMeetingPipeline {
    PostMeetingPipeline(
      storage: storage,
      batchTranscriber: batchTranscriber,
      minutesClient: try makeLLMClient(
        for: .minutesLLM,
        transport: transport
      ),
      // 认名提取是可选增益:会中总结未配置/配置坏了 → nil,提取整步静默跳过,
      // 绝不让它拖垮精转+纪要主链路的管线构造。
      namingClient: try? makeSpeakerNamingLLMClient(transport: transport),
      meetingStore: meetingStore,
      configuration: configuration,
      dictionaryStore: dictionaryStore
    )
  }

  // MARK: - 钥匙串账户派生

  public static func secretAccount(
    slot: ProviderSecretSlot,
    for binding: RoleProviderBinding
  ) -> String {
    let endpointSource =
      switch slot {
      case .azureSAS, .azureManagementSAS, .azureReadOnlySAS, .azureAccountKey:
        binding.azureContainerURL ?? ""
      case .r2AccessKey, .r2SecretKey:
        // 用 accountID 做钥匙串分区,避免不同 R2 账户的密钥互相覆盖。
        binding.r2AccountID ?? ""
      default:
        binding.baseURL
      }
    return
      "\(binding.role.rawValue).\(binding.providerID).\(endpointScope(for: endpointSource)).\(slot.rawValue)"
  }

  /// 渠道秘密账户:以创建时冻结的凭证引用为基址,渠道 ID 稳定不可复用,
  /// 账户天然继承这两条性质。
  public static func secretAccount(
    slot: ProviderSecretSlot,
    for channel: ProviderChannel
  ) -> String {
    "\(channel.secretReference).\(slot.rawValue)"
  }

  /// 独立存储的秘密账户:基址在创建/迁移时冻结;endpoint 规则与旧方案逐槽位一致
  /// (Azure 槽位按容器 URL、R2 槽位按 accountID、TOS 槽位按冻结的来源),
  /// 迁移/全新安装的账户字符串与旧版逐字节相同,旧 Keychain 条目继续可读。
  public nonisolated static func secretAccount(
    slot: ProviderSecretSlot,
    forStorage storage: StorageConfiguration
  ) -> String {
    let endpointSource =
      switch slot {
      case .azureSAS, .azureManagementSAS, .azureReadOnlySAS, .azureAccountKey:
        storage.azureContainerURL ?? ""
      case .r2AccessKey, .r2SecretKey:
        storage.r2AccountID ?? ""
      default:
        storage.tosSecretEndpointSource
      }
    return
      "\(storage.secretAccountBase).\(endpointScope(for: endpointSource)).\(slot.rawValue)"
  }

  /// 旧方案的账户基址(`角色.供应商.endpoint 指纹`),迁移时冻结进渠道/存储配置。
  static func legacySecretAccountBase(
    role: ProviderRole,
    providerID: String,
    baseURL: String
  ) -> String {
    "\(role.rawValue).\(providerID).\(endpointScope(for: baseURL))"
  }

  nonisolated static func normalizedEndpoint(_ source: String) -> String {
    source
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .lowercased()
  }

  nonisolated static func endpointScope(for source: String) -> String {
    let endpoint = normalizedEndpoint(source)
    guard !endpoint.isEmpty else {
      return "vendor"
    }
    return
      SHA256.hash(data: Data(endpoint.utf8))
      .prefix(8)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func persist() {
    guard allowPersist else {
      logger.notice("供应商配置损坏且尚未显式保存:跳过写入,保留原始数据")
      return
    }
    guard let data = try? JSONEncoder().encode(configuration) else {
      return
    }
    defaults.set(data, forKey: defaultsKey)
  }

  private func scheduleStorageHealthCheck() {
    storageHealthTask?.cancel()
    storageHealthTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: 800_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.refreshStorageHealth()
    }
  }

  private static func sanitizingAzureContainerURL(
    in binding: RoleProviderBinding
  ) -> RoleProviderBinding {
    guard
      var value = binding.azureContainerURL?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return binding
    }
    value = String(value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    value = String(value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
    if var components = URLComponents(string: value) {
      components.user = nil
      components.password = nil
      value = components.string ?? value
    }
    var sanitized = binding
    sanitized.azureContainerURL = value
    return sanitized
  }
}
