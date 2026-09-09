import Foundation

public struct ProviderRegistry: Sendable {
  /// 已有线上实证的档位:`medium` 是本项目一直在发的值;`low` 是 OpenAI 兼容标准档且
  /// 严格弱于 medium(不会比现状更冒进)。`high`/`max` 在这几家没实测过,不声明——
  /// 会后纪要默认取最高档,声明了就等于让默认路径去发一个没人发过的词面。
  private static let measuredOpenAICompatibleLevels: Set<ReasoningEffortLevel> = [
    .off, .low, .medium,
  ]
  /// 自定义 OpenAI 兼容网关:用户 2026-08-06 实测其网关接受最高档词面,故整梯可选。
  /// 中间两档是同一网关(GPT 族)上的 OpenAI 兼容标准梯级,**只可能被用户显式选中**
  /// ——没有任何默认路径会发出它们,与上面"默认不发没实测过的词面"是同一条纪律。
  private static let fullOpenAICompatibleLevels: Set<ReasoningEffortLevel> = [
    .off, .low, .medium, .high, .max,
  ]

  public let providers: [ProviderDescriptor]

  public init() {
    var builtIns: [ProviderDescriptor] = [
      ProviderDescriptor(
        id: "qwen3-asr-0.6b",
        displayName: "Qwen3-ASR-0.6B（本地）",
        supportedRoles: [.liveTranscriber],
        defaultModel: "Qwen3-ASR-0.6B INT8（sherpa-onnx）",
        requiresAPIKey: false
      ),
      ProviderDescriptor(
        id: "sensevoice-small",
        displayName: "SenseVoice-Small（本地）",
        supportedRoles: [.liveTranscriber],
        defaultModel: "SenseVoice-Small int8（sherpa-onnx）",
        requiresAPIKey: false
      ),
      ProviderDescriptor(
        id: "volcengine-doubao-asr",
        displayName: "火山引擎",
        supportedRoles: [.batchASR],
        defaultModel: "录音文件识别 1.0（volc.bigasr.auc）",
        requiresAPIKey: true,
        asrVendorKind: .volcengine
      ),
      ProviderDescriptor(
        id: "alibaba-tingwu",
        displayName: "通义听悟",
        supportedRoles: [.batchASR],
        defaultModel: "录音文件识别",
        requiresAPIKey: true,
        asrVendorKind: .generic
      ),
      ProviderDescriptor(
        id: "tencent-cloud-asr",
        displayName: "腾讯云 ASR",
        supportedRoles: [.batchASR],
        defaultModel: "录音文件识别",
        requiresAPIKey: true,
        asrVendorKind: .generic
      ),
      ProviderDescriptor(
        id: "custom-openai-compatible-asr",
        displayName: "通用（OpenAI 格式）",
        supportedRoles: [.batchASR],
        defaultModel: "",
        requiresAPIKey: true,
        asrVendorKind: .generic
      ),
      ProviderDescriptor(
        id: "deepseek",
        displayName: "DeepSeek",
        supportedRoles: [.liveSummaryLLM, .minutesLLM],
        defaultBaseURL: "https://api.deepseek.com/v1",
        // 官方 API 模型 ID 是小写(2026-08-13 查 api-docs.deepseek.com 核实);
        // 大写驼峰 DeepSeek-V4-Flash 是 HuggingFace 仓库名,照官方 API 发是错的模型名。
        defaultModel: "deepseek-v4-flash",
        requiresAPIKey: true,
        supportedReasoningLevels: Self.measuredOpenAICompatibleLevels
      ),
      ProviderDescriptor(
        id: "qwen",
        displayName: "阿里百炼",
        supportedRoles: [.liveSummaryLLM, .minutesLLM],
        defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        defaultModel: "qwen-flash",
        requiresAPIKey: true,
        supportedReasoningLevels: Self.measuredOpenAICompatibleLevels
      ),
      ProviderDescriptor(
        id: "glm",
        displayName: "智谱 GLM",
        supportedRoles: [.liveSummaryLLM, .minutesLLM],
        defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4",
        defaultModel: "",
        requiresAPIKey: true,
        supportedReasoningLevels: Self.measuredOpenAICompatibleLevels
      ),
      ProviderDescriptor(
        id: "volcengine-ark",
        displayName: "火山方舟",
        supportedRoles: [.liveSummaryLLM, .minutesLLM],
        defaultBaseURL: "https://ark.cn-beijing.volces.com/api/v3",
        defaultModel: "",
        requiresAPIKey: true,
        supportedReasoningLevels: Self.measuredOpenAICompatibleLevels
      ),
      ProviderDescriptor(
        id: "custom-openai-compatible",
        displayName: "自定义 OpenAI 兼容服务",
        supportedRoles: [.liveSummaryLLM, .minutesLLM],
        defaultModel: "",
        requiresAPIKey: true,
        supportedReasoningLevels: Self.fullOpenAICompatibleLevels
      ),
    ]

    if #available(macOS 26.0, *) {
      builtIns.insert(
        ProviderDescriptor(
          id: "apple-speech-analyzer",
          displayName: "Apple SpeechAnalyzer（本地）",
          supportedRoles: [.liveTranscriber],
          defaultModel: "系统内置",
          requiresAPIKey: false
        ),
        at: 0
      )
    }

    providers = builtIns
  }

  public func providers(for role: ProviderRole) -> [ProviderDescriptor] {
    providers.filter { $0.supportedRoles.contains(role) }
  }

  public func provider(id: String, for role: ProviderRole) -> ProviderDescriptor? {
    providers(for: role).first { $0.id == id }
  }

  public func defaultBinding(for role: ProviderRole) -> RoleProviderBinding {
    let preferredID: String
    switch role {
    case .liveTranscriber:
      preferredID = "qwen3-asr-0.6b"
    case .batchASR:
      preferredID = "volcengine-doubao-asr"
    case .liveSummaryLLM, .minutesLLM:
      preferredID = "deepseek"
    }

    let descriptor = provider(id: preferredID, for: role) ?? providers(for: role)[0]
    let reasoningEffort = Self.defaultReasoningEffort(for: role, descriptor: descriptor)
    return RoleProviderBinding(
      role: role,
      providerID: descriptor.id,
      baseURL: descriptor.defaultBaseURL,
      model: descriptor.defaultModel,
      thinkingEnabled: (reasoningEffort ?? .off) != .off,
      reasoningEffort: reasoningEffort,
      automaticLanguageRouting: role == .liveTranscriber
    )
  }

  /// 按角色的出厂默认档。**只作用于新建绑定**——已存配置由
  /// `RoleProviderBinding.effectiveReasoningEffort` 的迁移表决定,不被这里覆盖。
  ///
  /// - 会后纪要:该供应商最高档(会后跑,超时 600 秒,等得起);
  /// - 会中总结:关闭。它的首帧超时是 45 秒且要跟上会议节奏,默认开推理等于在本就
  ///   不宽裕的预算里抢时间;用户想拉满,设置页一个下拉即可。
  /// - 非 LLM 角色:不涉及推理,保持 nil。
  private static func defaultReasoningEffort(
    for role: ProviderRole,
    descriptor: ProviderDescriptor
  ) -> ReasoningEffortLevel? {
    switch role {
    case .minutesLLM:
      return descriptor.highestReasoningLevel
    case .liveSummaryLLM:
      return .off
    case .liveTranscriber, .batchASR:
      return nil
    }
  }

  public func defaultConfiguration() -> ProviderConfiguration {
    let channels = ProviderRole.allCases.map { defaultChannel(for: $0) }
    let bindings = ProviderRole.allCases.map { defaultBinding(for: $0) }
    let selections = bindings.map { binding in
      RoleChannelSelection(
        role: binding.role,
        channelID: channels.first { $0.supportedRoles.contains(binding.role) }?.id ?? "",
        model: binding.model,
        reasoningEffort: binding.reasoningEffort,
        thinkingEnabled: binding.thinkingEnabled,
        asrResourceID: binding.asrResourceID,
        automaticLanguageRouting: binding.automaticLanguageRouting
      )
    }
    return ProviderConfiguration(
      channels: channels,
      roleSelections: selections,
      storage: .default
    )
  }

  /// 出厂默认渠道:确定性 ID——新装在首次保存前每次重建都得到同一身份,
  /// 满足"稳定 ID 生成必须确定且一次性持久化,不能每次读取重建"。
  public func defaultChannel(for role: ProviderRole) -> ProviderChannel {
    let binding = defaultBinding(for: role)
    let descriptor = provider(id: binding.providerID, for: role)
    let normalizedURL =
      binding.baseURL
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .lowercased()
    let id = ProviderChannel.deterministicID(
      seed: "justsaid.default-channel.v1|\(role.rawValue)|\(binding.providerID)|\(normalizedURL)"
    )
    return ProviderChannel(
      id: id,
      name: descriptor?.displayName ?? binding.providerID,
      providerID: binding.providerID,
      baseURL: binding.baseURL,
      appID: binding.appID,
      secretReference: "channel.\(id)",
      legacySecretAccountBase: nil,
      supportedRoles: [role],
      availableModels:
        binding.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? [] : [binding.model]
    )
  }
}
