import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-20 批4 拆分:自 ProviderSettingsView.swift 机械迁出,零行为变更。
// MARK: - 角色卡(只做选择)

/// 瘦身后的角色卡:渠道 + 模型 + 推理强度(LLM),不再出现 Base URL 与 API Key——
/// 那些在渠道管理区统一维护。四个角色各自独立,互不同步。
///
/// 公开是为了让 `UIHierarchyVerification` 能独立摆出卡片做反向断言
/// (卡内不得出现地址/密钥输入)。
/// 泛型类型里不能有 static stored property,常量挪到外面。
enum ChannelRoleCardConstants {
  static let automaticSelection = "automatic-language-routing"
}

public struct ChannelRoleCard<Extra: View>: View {
  private let role: ProviderRole
  private let registry: ProviderRegistry
  @ObservedObject private var settingsStore: ProviderSettingsStore
  private let secretDigest: any StoredSecretDigest
  private let connectionTestAction: (() -> Void)?
  private let modelAssetManager: LocalModelAssetManager?
  /// 挂在本组末尾的额外行。设计稿把「本机模型」并进会中速记、把「对象存储」并进
  /// 会后精转——它们是这个角色要配的东西,不是另一张卡。
  @ViewBuilder private let extraRows: () -> Extra

  @State private var lastSavedAt: Date?
  @State private var connectionState: ConnectionTestState

  public init(
    role: ProviderRole,
    registry: ProviderRegistry,
    settingsStore: ProviderSettingsStore,
    secretDigest: any StoredSecretDigest,
    connectionTestState: ConnectionTestState = .idle,
    connectionTestAction: (() -> Void)? = nil,
    modelAssetManager: LocalModelAssetManager? = nil,
    @ViewBuilder extraRows: @escaping () -> Extra
  ) {
    self.role = role
    self.registry = registry
    self.settingsStore = settingsStore
    self.secretDigest = secretDigest
    self.connectionTestAction = connectionTestAction
    self.modelAssetManager = modelAssetManager
    self.extraRows = extraRows
    _connectionState = State(initialValue: connectionTestState)
  }

  private var selection: RoleChannelSelection? {
    settingsStore.selection(for: role)
  }

  private var channel: ProviderChannel? {
    selection.flatMap { settingsStore.configuration.channel(id: $0.channelID) }
  }

  /// 选择悬空(半迁移)或尚未选择时退回出厂默认渠道做展示——绝不渲染一张空卡。
  private var effectiveChannel: ProviderChannel {
    channel ?? registry.defaultChannel(for: role)
  }

  private var channels: [ProviderChannel] {
    var listed = settingsStore.channelsSupporting(role: role)
    if role == .liveTranscriber {
      for descriptor in LiveTranscriberProviderPresentation.descriptors(in: registry)
      where !listed.contains(where: { $0.providerID == descriptor.id }) {
        listed.append(localTranscriberCandidate(for: descriptor))
      }
    }
    guard !listed.contains(where: { $0.id == effectiveChannel.id }) else {
      return listed
    }
    return [effectiveChannel] + listed
  }

  private func localTranscriberCandidate(for descriptor: ProviderDescriptor) -> ProviderChannel {
    let id = "local-transcriber-option.\(descriptor.id)"
    return ProviderChannel(
      id: id,
      name: descriptor.displayName,
      providerID: descriptor.id,
      baseURL: descriptor.defaultBaseURL,
      appID: "",
      secretReference: "channel.\(id)",
      supportedRoles: [.liveTranscriber],
      availableModels: descriptor.defaultModel.isEmpty ? [] : [descriptor.defaultModel]
    )
  }

  private var binding: RoleProviderBinding { settingsStore.binding(for: role) }

  private var descriptor: ProviderDescriptor? {
    registry.provider(id: effectiveChannel.providerID, for: role)
  }

  private var isVolcengineASR: Bool {
    role == .batchASR && descriptor?.asrVendorKind == .volcengine
  }

  private var subtitle: String {
    switch role {
    case .liveTranscriber:
      return descriptor?.requiresAPIKey == false ? "在本机转写，无需密钥。" : "云端按量使用，转写会中对话。"
    case .batchASR:
      return "云端按量使用，重新整理整场转写。"
    case .liveSummaryLLM:
      return "云端按量使用，与会后纪要分别选择。"
    case .minutesLLM:
      return "云端按量使用，与会中总结分别选择。"
    }
  }

  public var body: some View {
    SettingsFormGroup(role.displayName, hint: subtitle) {
      channelRow

      if isVolcengineASR {
        asrResourceRow
      } else if role != .liveTranscriber || descriptor?.requiresAPIKey == true {
        modelRow
      }

      if role.isLLMRole {
        reasoningRow
      }

      // 推理强度的提示是**后果**(选到中高档会中总结可能缺轮),不是解释,所以留着。
      if role.isLLMRole, let hint = reasoningHint {
        SettingsFormNote(hint, tone: .warn)
      }

      extraRows()

      // 「当前生效」只在它**和你刚选的不一样**时才说话。
      //
      // 本地引擎那一组,下拉里写着「自动(Qwen3-ASR,质量优先,会有数秒延迟)」,
      // 下面又来一条「当前生效:自动路由 · Qwen3-ASR 质量优先」——同一件事说第三遍。
      // 它真正该守的是「你改了但还没保存」「保存的和在跑的不是一个」这种落差,
      // 没有落差就什么都不显示(设计系统:没有状态就什么都不显示)。
      if descriptor?.requiresAPIKey == true || lastSavedAt != nil {
        SettingsFormNote(
          ProviderEffectiveSummary.text(segments: effectiveSegments, savedAt: lastSavedAt))
      }

      // 连接测试的**结果**整行宽:出错时是一段带原因的长文,塞不进控件行。
      if role.isLLMRole, let detail = connectionState.settingsNote {
        SettingsFormNote(detail, tone: connectionState.isFailure ? .warn : .meta)
      }
    }
    .runtimeAccessibilityIdentifier("settings.role-card.\(role.rawValue)")
  }

  /// 渠道行。下拉只列**声明支持该角色**的渠道——能力不兼容的选项不该出现在界面上。
  /// 两个 LLM 角色在同一行右边带「测试连接」(08-13 D3:纪要角色此前是遗漏不是设计——
  /// ConnectionProbe 的 30 秒外层硬超时本来就为纪要角色的 600s 超时准备)。
  /// ASR 角色维持无按钮:无安全轻量探针的 adapter 不显示测试入口。
  @ViewBuilder
  private var channelRow: some View {
    SettingsFormRow(role == .liveTranscriber ? "转写引擎" : "渠道", isFirst: true) {
      V1Dropdown(
        value: channelSelection.wrappedValue == ChannelRoleCardConstants.automaticSelection
          ? "自动（Qwen3-ASR，质量优先，会有数秒延迟）" : channelLabel(effectiveChannel),
        identifier: "settings.channel-select.\(role.rawValue)"
      ) {
        if role == .liveTranscriber {
          Button("自动（Qwen3-ASR，质量优先，会有数秒延迟）") {
            channelSelection.wrappedValue = ChannelRoleCardConstants.automaticSelection
          }
        }
        ForEach(channels) { candidate in
          Button(channelLabel(candidate)) { channelSelection.wrappedValue = candidate.id }
            .disabled(isChannelDisabled(candidate))
        }
      }
      .frame(width: Tokens.V1.Size.settingsModelField)
      .help(
        channelSelection.wrappedValue == ChannelRoleCardConstants.automaticSelection
          ? "自动（Qwen3-ASR，质量优先，会有数秒延迟）" : channelLabel(effectiveChannel)
      )

      if role.isLLMRole {
        Button(connectionState.isRunning ? "测试中…" : "测试连接") {
          if let connectionTestAction {
            connectionTestAction()
          } else {
            runRoleConnectionTest()
          }
        }
        .buttonStyle(.v1Outline)
        .disabled(connectionState.isRunning)
        .runtimeAccessibilityIdentifier("settings.role-test.\(role.rawValue)")
        if connectionState.isRunning {
          BreathingDots()
        }
      }
    }
  }

  /// 模型行。渠道声明了列表就只能从列表挑(不支持的组合在界面上就不存在);
  /// 空列表 = 不约束,保留自由填写(很多网关不实现 /models)。
  /// 推理强度另起一行，为每个控件保留完整的操作宽度。
  @ViewBuilder
  private var modelRow: some View {
    SettingsFormRow("模型") {
      if effectiveChannel.availableModels.isEmpty {
        V1TextField(
          placeholder: "自由填写，如 deepseek-v4-flash", text: modelTextBinding,
          identifier: "settings.model-input.\(role.rawValue)"
        )
        .frame(width: Tokens.V1.Size.settingsModelField)
        .accessibilityLabel("模型名称")
      } else {
        V1Dropdown(
          value: modelPickerBinding.wrappedValue,
          identifier: "settings.model-select.\(role.rawValue)"
        ) {
          ForEach(effectiveChannel.availableModels, id: \.self) { model in
            Button(model) { modelPickerBinding.wrappedValue = model }
          }
        }
        .frame(width: Tokens.V1.Size.settingsModelField)
      }
    }
    .runtimeAccessibilityIdentifier("settings.model.\(role.rawValue)")
  }

  private var reasoningRow: some View {
    SettingsFormRow("推理强度") {
      // 下拉只列这个渠道真支持的档:选了也不生效的选项不该出现在界面上。
      V1Dropdown(
        value: reasoningBinding.wrappedValue.displayName,
        identifier: "settings.reasoning.\(role.rawValue)"
      ) {
        ForEach(settingsStore.supportedReasoningLevels(for: role), id: \.self) { level in
          Button(level.displayName) { reasoningBinding.wrappedValue = level }
        }
      }
      .frame(width: Tokens.V1.Size.settingsModelField)
    }
    .runtimeAccessibilityIdentifier("settings.reasoning-row.\(role.rawValue)")
  }

  /// 火山精转的模型版本是角色级资源选择,不进渠道模型列表。
  @ViewBuilder
  private var asrResourceRow: some View {
    SettingsFormRow("模型版本") {
      V1SegmentedPicker(
        "模型版本", selection: asrResourceSelection,
        options: [
          .init("volc.seedasr.auc", "2.0 · 质量优先"),
          .init("volc.bigasr.auc", "1.0 · 额度充裕"),
        ]
      )
      .fixedSize()
    }
    .runtimeAccessibilityIdentifier("settings.model.\(role.rawValue)")
  }

  private var effectiveSegments: [String?] {
    if role == .liveTranscriber, binding.usesAutomaticLanguageRouting {
      return ["自动路由 · Qwen3-ASR 质量优先"]
    }
    let channelName = effectiveChannel.name
    if isVolcengineASR {
      let usingNewKey = secretDigest.exists(slot: .apiKey, forChannel: effectiveChannel)
      return [
        channelName,
        binding.selectedASRResourceID == "volc.bigasr.auc" ? "模型 1.0" : "模型 2.0",
        usingNewKey
          ? ProviderEffectiveSummary.keySegment(
            label: "密钥",
            suffix: secretDigest.suffix(slot: .apiKey, forChannel: effectiveChannel)
          )
          : (effectiveChannel.appID.isEmpty
            ? "旧版鉴权未配置"
            : "旧版 APP ID \(effectiveChannel.appID)"),
      ]
    }
    let model = selection?.model ?? effectiveChannel.availableModels.first ?? ""
    if descriptor?.requiresAPIKey == false {
      return [channelName, model]
    }
    return [
      channelName,
      model,
      ProviderEffectiveSummary.keySegment(
        label: "密钥",
        suffix: secretDigest.suffix(slot: .apiKey, forChannel: effectiveChannel)
      ),
    ]
  }

  private func isChannelDisabled(_ candidate: ProviderChannel) -> Bool {
    guard role == .liveTranscriber else { return false }
    guard candidate.providerID == LocalModelKnownIDs.sensevoiceProvider else { return false }
    guard let manager = modelAssetManager else { return false }
    return manager.snapshot(forCapabilityID: LocalModelKnownIDs.sensevoiceLive)?.isReady != true
  }

  private func channelLabel(_ candidate: ProviderChannel) -> String {
    if isChannelDisabled(candidate) {
      return "\(candidate.name)（请先在下方下载）"
    }
    return candidate.name
  }

  private var channelSelection: Binding<String> {
    Binding(
      get: {
        if role == .liveTranscriber, binding.usesAutomaticLanguageRouting {
          return ChannelRoleCardConstants.automaticSelection
        }
        return effectiveChannel.id
      },
      set: { newValue in
        if newValue == ChannelRoleCardConstants.automaticSelection {
          settingsStore.selectAutomaticLiveTranscriberRouting()
        } else if let candidate = channels.first(where: { $0.id == newValue }) {
          if isChannelDisabled(candidate) { return }
          if settingsStore.configuration.channel(id: newValue) == nil {
            settingsStore.selectProvider(id: candidate.providerID, for: role)
          } else {
            try? settingsStore.selectChannel(channelID: newValue, for: role)
          }
        } else {
          try? settingsStore.selectChannel(channelID: newValue, for: role)
        }
        lastSavedAt = Date()
      }
    )
  }

  private var modelPickerBinding: Binding<String> {
    Binding(
      get: {
        let current = selection?.model ?? ""
        return effectiveChannel.availableModels.contains(current)
          ? current
          : (effectiveChannel.availableModels.first ?? "")
      },
      set: { newValue in
        select(newValue)
      }
    )
  }

  private var modelTextBinding: Binding<String> {
    Binding(
      get: { selection?.model ?? "" },
      set: { newValue in
        select(newValue)
      }
    )
  }

  /// 模型改动要落到角色选择;选择还没建(极端的半迁移数据)先按当前渠道建一个再写。
  private func select(_ model: String) {
    if settingsStore.selection(for: role) == nil {
      try? settingsStore.selectChannel(channelID: effectiveChannel.id, for: role)
    }
    try? settingsStore.selectModel(model, for: role)
    lastSavedAt = Date()
  }

  private var asrResourceSelection: Binding<String> {
    Binding(
      get: { binding.selectedASRResourceID },
      set: { newValue in
        var updated = binding
        updated.asrResourceID = newValue
        settingsStore.update(updated)
        lastSavedAt = Date()
      }
    )
  }

  /// 显示的是「这次真会发出去的档」——用户存的档若超出当前渠道能力,
  /// 界面就该照实显示降级后的结果,而不是显示一个发不出去的档。存的值不动。
  private var reasoningBinding: Binding<ReasoningEffortLevel> {
    Binding(
      get: { settingsStore.effectiveReasoningEffort(for: role) },
      set: { newValue in
        settingsStore.updateReasoningEffort(newValue, for: role)
        lastSavedAt = Date()
      }
    )
  }

  private var reasoningHint: String? {
    switch role {
    case .liveSummaryLLM:
      // 高档思考可能拖过会中总结的首帧墙(等不到首帧 45 秒即放弃本轮)——
      // 不拦用户选(快的渠道如 DeepSeek 用得上),但选到「中」及以上要照实提示。
      if settingsStore.effectiveReasoningEffort(for: role) >= .medium {
        return "中高推理档会让每轮总结变慢：会中总结等不到首帧 45 秒即放弃本轮，"
          + "高档可能导致总结延时或缺轮。"
      }
      return nil
    case .minutesLLM:
      // 这里原来有一句「会后纪要不赶时间,默认取这家可用的最高档。」——
      // 它不是后果,是解释,而且挂在警告样式下像是出了事(设计系统原则 1)。
      // 当前档位下拉自己写着,不用再说一遍。
      return nil
    case .liveTranscriber, .batchASR:
      return nil
    }
  }

  /// 探针走角色解析入口,拿到的是该角色当前真正生效的渠道与模型;推理档由
  /// `makeConnectionTestLLMClient` 强制降到「关闭」——纪要角色配置高档时,
  /// 高档思考在 30 秒外层硬超时内可能出不了首句,按原档发就是假超时(08-13 D3)。
  private func runRoleConnectionTest() {
    connectionState = .running
    Task { @MainActor in
      let startedAt = Date()
      do {
        let client = try settingsStore.makeConnectionTestLLMClient(for: role)
        let response = try await ConnectionProbe.run(client)
        connectionState = .succeeded(
          latencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
          replyPreview: ConnectionProbe.preview(of: response.text)
        )
      } catch {
        connectionState = .failed(message: error.localizedDescription)
      }
    }
  }
}

extension ChannelRoleCard where Extra == EmptyView {
  /// 不挂额外行的角色组(会中总结 / 会后纪要)。
  public init(
    role: ProviderRole,
    registry: ProviderRegistry,
    settingsStore: ProviderSettingsStore,
    secretDigest: any StoredSecretDigest,
    connectionTestState: ConnectionTestState = .idle,
    connectionTestAction: (() -> Void)? = nil,
    modelAssetManager: LocalModelAssetManager? = nil
  ) {
    self.init(
      role: role,
      registry: registry,
      settingsStore: settingsStore,
      secretDigest: secretDigest,
      connectionTestState: connectionTestState,
      connectionTestAction: connectionTestAction,
      modelAssetManager: modelAssetManager,
      extraRows: { EmptyView() })
  }
}
