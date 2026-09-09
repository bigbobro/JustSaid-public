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
public struct ChannelRoleCard: View {
  private let role: ProviderRole
  private let registry: ProviderRegistry
  @ObservedObject private var settingsStore: ProviderSettingsStore
  private let secretDigest: any StoredSecretDigest
  private let connectionTestAction: (() -> Void)?
  private let modelAssetManager: LocalModelAssetManager?

  @State private var lastSavedAt: Date?
  @State private var connectionState: ConnectionTestState

  private static let automaticSelection = "automatic-language-routing"

  public init(
    role: ProviderRole,
    registry: ProviderRegistry,
    settingsStore: ProviderSettingsStore,
    secretDigest: any StoredSecretDigest,
    connectionTestState: ConnectionTestState = .idle,
    connectionTestAction: (() -> Void)? = nil,
    modelAssetManager: LocalModelAssetManager? = nil
  ) {
    self.role = role
    self.registry = registry
    self.settingsStore = settingsStore
    self.secretDigest = secretDigest
    self.connectionTestAction = connectionTestAction
    self.modelAssetManager = modelAssetManager
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
      return descriptor?.requiresAPIKey == false ? "本地引擎 · 无需密钥" : "云端 · 按量"
    case .batchASR:
      return "云端 · 按量 · 对象存储在下方独立配置"
    case .liveSummaryLLM, .minutesLLM:
      return "云端 · 按量 · 独立选择，不与其他角色同步"
    }
  }

  public var body: some View {
    RoleCardShell(title: role.displayName, subtitle: subtitle) {
      channelPicker

      if isVolcengineASR {
        asrResourcePicker
      } else if role != .liveTranscriber || descriptor?.requiresAPIKey == true {
        modelControl
      }

      if role.isLLMRole {
        reasoningPicker
      }

      // 两个 LLM 角色都有「测试连接」(08-13 D3:纪要角色此前是遗漏不是设计——
      // ConnectionProbe 的 30 秒外层硬超时本来就为纪要角色的 600s 超时准备)。
      // ASR 角色维持无按钮:无安全轻量探针的 adapter 不显示测试入口。
      if role.isLLMRole {
        ConnectionTestRow(state: connectionState) {
          if let connectionTestAction {
            connectionTestAction()
          } else {
            runRoleConnectionTest()
          }
        }
        .runtimeAccessibilityIdentifier("settings.role-test.\(role.rawValue)")
      }

      if descriptor?.requiresAPIKey == false {
        Label("本地引擎无需 API 密钥", systemImage: "lock.shield")
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink3)
      }

      EffectiveConfigurationRow(
        summary: ProviderEffectiveSummary.text(
          segments: effectiveSegments,
          savedAt: lastSavedAt
        )
      )
    }
    .runtimeAccessibilityIdentifier("settings.role-card.\(role.rawValue)")
  }

  /// 渠道下拉只列**声明支持该角色**的渠道——能力不兼容的选项不该出现在界面上。
  @ViewBuilder
  private var channelPicker: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      Text(role == .liveTranscriber ? "转写引擎" : "渠道")
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink3)
      Picker(role == .liveTranscriber ? "转写引擎" : "渠道", selection: channelSelection) {
        if role == .liveTranscriber {
          Text("自动（Qwen3-ASR，质量优先，会有数秒延迟）")
            .tag(Self.automaticSelection)
        }
        ForEach(channels) { candidate in
          Text(channelLabel(candidate)).tag(candidate.id)
            .disabled(isChannelDisabled(candidate))
        }
      }
      .labelsHidden()
    }
    .runtimeAccessibilityIdentifier("settings.channel-select.\(role.rawValue)")
  }

  /// 模型:渠道声明了列表就只能从列表挑(不支持的组合在界面上就不存在);
  /// 空列表 = 不约束,保留自由填写(很多网关不实现 /models)。
  @ViewBuilder
  private var modelControl: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      Text("模型")
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink3)
      if effectiveChannel.availableModels.isEmpty {
        TextField("自由填写，如 deepseek-v4-flash", text: modelTextBinding)
          .textFieldStyle(.plain)
          .font(.system(size: Tokens.FontSize.body))
          .padding(.horizontal, Tokens.Spacing.xsm)
          .padding(.vertical, Tokens.Spacing.xs)
          .insetPanel()
          .accessibilityLabel("模型名称")
      } else {
        Picker("模型", selection: modelPickerBinding) {
          ForEach(effectiveChannel.availableModels, id: \.self) { model in
            Text(model).tag(model)
          }
        }
        .labelsHidden()
      }
    }
    .runtimeAccessibilityIdentifier("settings.model.\(role.rawValue)")
  }

  /// 火山精转的模型版本是角色级资源选择,不进渠道模型列表。
  @ViewBuilder
  private var asrResourcePicker: some View {
    LabeledField(label: "模型版本") {
      Picker("", selection: asrResourceSelection) {
        Text("2.0 · 质量优先").tag("volc.seedasr.auc")
        Text("1.0 · 额度充裕").tag("volc.bigasr.auc")
      }
      .pickerStyle(.segmented)
      .frame(width: 240)
    }
    .runtimeAccessibilityIdentifier("settings.model.\(role.rawValue)")
  }

  @ViewBuilder
  private var reasoningPicker: some View {
    // 下拉只列这个渠道真支持的档:选了也不生效的选项不该出现在界面上。
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      Picker("推理强度", selection: reasoningBinding) {
        ForEach(settingsStore.supportedReasoningLevels(for: role), id: \.self) { level in
          Text(level.displayName).tag(level)
        }
      }
      .font(.system(size: Tokens.FontSize.bodyMinimum))
      if let hint = reasoningHint {
        Text(hint)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .runtimeAccessibilityIdentifier("settings.reasoning.\(role.rawValue)")
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
            label: "key",
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
        label: "key",
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
          return Self.automaticSelection
        }
        return effectiveChannel.id
      },
      set: { newValue in
        if newValue == Self.automaticSelection {
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
      return "会后纪要不赶时间，默认取这家可用的最高档。"
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
