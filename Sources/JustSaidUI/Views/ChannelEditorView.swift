import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-20 批4 拆分:自 ProviderSettingsView.swift 机械迁出,零行为变更。
// MARK: - 渠道编辑器

/// 预设切换的字段替换判定:Base URL 与模型列表只在「当前值为空,或仍等于上一个预设的
/// 默认值(用户没动过)」时才跟随新预设默认;用户手填的值一律保留——静默覆盖会把
/// 中转站地址/模型列表悄悄换成官方默认(2026-08-13 事故)。纯函数,验证程序直接断言。
public enum ChannelPresetSwitchPolicy {
  public static func resolvedBaseURL(
    current: String,
    previousDefault: String,
    newDefault: String
  ) -> String {
    current.isEmpty || current == previousDefault ? newDefault : current
  }

  public static func resolvedModels(
    current: [String],
    previousDefault: [String],
    newDefault: [String]
  ) -> [String] {
    current.isEmpty || current == previousDefault ? newDefault : current
  }
}

/// 渠道编辑 sheet:名称/供应商/地址/能力角色/模型列表走**显式保存**(草稿 → 「保存渠道」),
/// 凭证照旧点「保存」立即入 Keychain。连接测试与模型拉取在渠道上下文进行——
/// 渠道还没被任何角色引用(比如新建中)也必须能测。
///
/// 公开是为了让 `UIHierarchyVerification` 能独立摆出这一页断言地址/密钥字段只出现在这里。
public struct ChannelEditorView: View {
  private let existingChannel: ProviderChannel?
  private let registry: ProviderRegistry
  @ObservedObject private var settingsStore: ProviderSettingsStore
  private let secretDigest: any StoredSecretDigest

  @Environment(\.dismiss) private var dismiss

  @State private var name: String
  @State private var providerID: String
  @State private var baseURL: String
  @State private var appID: String
  @State private var supportedRoles: Set<ProviderRole>
  @State private var availableModels: [String]
  @State private var newModelDraft = ""
  @State private var apiKeyDraft = ""
  @State private var accessTokenDraft = ""
  @State private var connectionState: ConnectionTestState = .idle
  @State private var isFetchingModels = false
  @State private var modelsHint: String?
  @State private var saveError: String?
  @State private var savedFlash = 0

  /// 新建模式下先「创建渠道」拿到稳定 ID,凭证区才解锁——Keychain 账户名按渠道 ID 派生,
  /// 渠道还不存在就存钥匙,会留下永远没人读的孤儿账户。
  @State private var createdChannel: ProviderChannel?

  /// - Parameter channel: nil = 新建模式(先「创建渠道」再解锁凭证/拉取/测试)。
  public init(
    channel: ProviderChannel?,
    registry: ProviderRegistry,
    settingsStore: ProviderSettingsStore,
    secretDigest: any StoredSecretDigest
  ) {
    self.existingChannel = channel
    self.registry = registry
    self.settingsStore = settingsStore
    self.secretDigest = secretDigest
    let descriptor = channel.flatMap { ch in
      registry.providers.first { $0.id == ch.providerID }
    }
    _name = State(initialValue: channel?.name ?? "")
    _providerID = State(initialValue: channel?.providerID ?? "custom-openai-compatible")
    _baseURL = State(initialValue: channel?.baseURL ?? descriptor?.defaultBaseURL ?? "")
    _appID = State(initialValue: channel?.appID ?? "")
    _supportedRoles = State(
      initialValue: channel?.supportedRoles ?? descriptor?.supportedRoles ?? [.minutesLLM]
    )
    _availableModels = State(initialValue: channel?.availableModels ?? [])
  }

  init(
    request: ChannelEditorRequest,
    registry: ProviderRegistry,
    settingsStore: ProviderSettingsStore,
    secretDigest: any StoredSecretDigest
  ) {
    self.init(
      channel: request.channel,
      registry: registry,
      settingsStore: settingsStore,
      secretDigest: secretDigest
    )
  }

  /// 已落盘的渠道:新建模式保存成功后就是它,编辑模式一开始就是传入的那个。
  private var persistedChannel: ProviderChannel? {
    if let createdChannel { return createdChannel }
    guard let existingChannel else { return nil }
    return settingsStore.configuration.channel(id: existingChannel.id) ?? existingChannel
  }

  private var descriptor: ProviderDescriptor? {
    registry.providers.first { $0.id == providerID }
  }

  private var isVolcengineASR: Bool {
    descriptor?.asrVendorKind == .volcengine
  }

  private var isLocalEngine: Bool {
    descriptor?.requiresAPIKey == false
  }

  private var showsBaseURL: Bool {
    descriptor?.requiresAPIKey == true && !isVolcengineASR
  }

  private var supportsLLM: Bool {
    descriptor?.supportedRoles.contains(where: \.isLLMRole) == true
  }

  private var showsBaseURLWarning: Bool {
    showsBaseURL && !baseURL.isEmpty && !baseURL.hasSuffix("/v1")
  }

  /// 探针用的渠道:按**当前草稿**组装(地址以用户正在看的为准),但 secretReference
  /// 必须沿用已落盘渠道——Keychain 账户按它派生,换一个就等于读别人的钥匙。
  private var probeChannel: ProviderChannel {
    let persisted = persistedChannel
    return ProviderChannel(
      id: persisted?.id ?? "draft",
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名渠道" : name,
      providerID: providerID,
      baseURL: baseURL,
      appID: appID,
      secretReference: persisted?.secretReference ?? "channel.draft",
      legacySecretAccountBase: persisted?.legacySecretAccountBase,
      supportedRoles: supportedRoles,
      availableModels: availableModels
    )
  }

  private var testModel: String {
    availableModels.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      ?? descriptor?.defaultModel
      ?? ""
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
      HStack {
        Text(existingChannel == nil && persistedChannel == nil ? "新建渠道" : "编辑渠道")
          .font(.system(size: Tokens.FontSize.headline, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink)
        Spacer()
        SavedFlashLabel(trigger: "\(savedFlash)")
        Button("完成") { dismiss() }
          .buttonStyle(.toolbarPill)
          .keyboardShortcut(.cancelAction)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
          LabeledField(label: "渠道名称") {
            TextField("如「公司 DeepSeek 网关」", text: $name)
          }
          .runtimeAccessibilityIdentifier("settings.channel.editor.name")

          LabeledField(label: "供应商 / 协议") {
            Picker("", selection: providerSelection) {
              ForEach(ConnectionManagedProviderPresentation.descriptors(in: registry)) { provider in
                Text(provider.displayName).tag(provider.id)
              }
            }
            .labelsHidden()
          }
          .runtimeAccessibilityIdentifier("settings.channel.editor.provider")

          if showsBaseURL {
            LabeledField(label: "Base URL") {
              TextField("如 https://api.example.com/v1", text: $baseURL)
            }
            .runtimeAccessibilityIdentifier("settings.channel.editor.base-url")
            if showsBaseURLWarning {
              HintText(text: "通常应以 /v1 结尾")
            }
          }

          if isVolcengineASR {
            LabeledField(label: "APP ID(旧版鉴权，备用)") {
              TextField("控制台中的 APP ID", text: $appID)
            }
          }

          capabilitySection

          if supportsLLM {
            modelListSection
          }

          credentialSection

          if supportsLLM {
            ConnectionTestRow(
              state: connectionState,
              action: persistedChannel == nil ? nil : { runConnectionTest() }
            )
            .runtimeAccessibilityIdentifier("settings.channel.editor.test")
          }

          if let saveError {
            HintText(text: saveError)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.vertical, Tokens.Spacing.hairline)
      }

      HStack(spacing: Tokens.Spacing.sm) {
        Button(persistedChannel == nil ? "创建渠道" : "保存渠道") {
          saveChannel()
        }
        .buttonStyle(.toolbarPillAccent)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if persistedChannel == nil {
          Text("创建后才能配置密钥、拉取模型与测试连接")
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.ink3)
        }
      }
    }
    .padding(Tokens.Spacing.xl)
    .background(Tokens.Color.bg)
    .runtimeAccessibilityIdentifier("settings.channel.editor")
  }

  /// 能力角色勾选:只列这家供应商声明支持的角色;已被引用仍试图取消时,
  /// store 会以能力不匹配报错(错误里带角色名),不静默通过。
  @ViewBuilder
  private var capabilitySection: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      Text("可用于角色")
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink3)
      let candidates = descriptor?.supportedRoles ?? []
      if candidates.isEmpty {
        Text("该供应商当前没有可分配的角色")
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink3)
      } else {
        ForEach(candidates.sorted(by: { $0.rawValue < $1.rawValue })) { role in
          Toggle(
            role.displayName,
            isOn: roleToggle(role)
          )
          .toggleStyle(.checkbox)
          .font(.system(size: Tokens.FontSize.bodyMinimum))
        }
      }
      if let channel = persistedChannel {
        let references = settingsStore.channelReferences(id: channel.id)
        if !references.isEmpty {
          Text("当前被引用：\(references.map(\.displayName).joined(separator: "、"))——取消勾选这些角色会在保存时报错")
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// 模型列表:手填逐条添加,或从网关拉取(许多网关不实现 /models,失败只提示不阻断)。
  /// 空列表 = 不约束,角色卡里自由填写;非空 = 角色只能从这里挑。
  @ViewBuilder
  private var modelListSection: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      HStack(spacing: Tokens.Spacing.xs) {
        Text("可用模型列表")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink3)
        Spacer()
        Button(isFetchingModels ? "拉取中…" : "从网关拉取") {
          fetchModels()
        }
        .buttonStyle(.textAction)
        .font(.system(size: Tokens.FontSize.ui))
        .disabled(isFetchingModels || persistedChannel == nil)
        .runtimeAccessibilityIdentifier("settings.channel.editor.fetch-models")
      }

      if availableModels.isEmpty {
        Text("空列表 = 不约束模型，角色卡里可自由填写")
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink3)
      } else {
        ForEach(availableModels, id: \.self) { model in
          HStack(spacing: Tokens.Spacing.xs) {
            Text(model)
              .font(.system(size: Tokens.FontSize.uiEmphasis, design: .monospaced))
              .foregroundStyle(Tokens.Color.ink2)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
              availableModels.removeAll { $0 == model }
            } label: {
              Image(systemName: "minus.circle")
                .font(.system(size: Tokens.FontSize.ui))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.Color.warn)
            .hoverRowBackground(cornerRadius: Tokens.Radius.chip)
            .accessibilityLabel("移除模型 \(model)")
          }
        }
      }

      HStack(spacing: Tokens.Spacing.xs) {
        TextField("手动添加模型名(注意大小写)", text: $newModelDraft)
          .textFieldStyle(.plain)
          .padding(.horizontal, Tokens.Spacing.xsm)
          .padding(.vertical, Tokens.Spacing.xs)
          .insetPanel()
          .font(.system(size: Tokens.FontSize.uiEmphasis))
          .onSubmit {
            addModelDraft()
          }
        Button("添加") {
          addModelDraft()
        }
        .buttonStyle(.textAction)
        .font(.system(size: Tokens.FontSize.ui))
        .disabled(newModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let modelsHint {
        Text(modelsHint)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .runtimeAccessibilityIdentifier("settings.channel.editor.models")
  }

  @ViewBuilder
  private var credentialSection: some View {
    if isLocalEngine {
      Label("本地引擎无需 API 密钥", systemImage: "lock.shield")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
    } else if persistedChannel == nil {
      Text("密钥在渠道创建后配置——先点下方「创建渠道」。")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
    } else {
      let channel = probeChannel
      VStack(alignment: .leading, spacing: Tokens.Spacing.smd) {
        SecretRow(
          label: isVolcengineASR ? "API Key(新版控制台，推荐)" : "API Key",
          isSaved: secretDigest.exists(slot: .apiKey, forChannel: channel),
          suffix: secretDigest.suffix(slot: .apiKey, forChannel: channel),
          draft: $apiKeyDraft,
          onSave: {
            try settingsStore.saveSecret(apiKeyDraft, slot: .apiKey, forChannel: channel)
          }
        )
        .runtimeAccessibilityIdentifier("settings.channel.editor.apikey")
        if isVolcengineASR {
          SecretRow(
            label: "Access Token(旧版鉴权，备用)",
            isSaved: secretDigest.exists(slot: .accessToken, forChannel: channel),
            suffix: secretDigest.suffix(slot: .accessToken, forChannel: channel),
            draft: $accessTokenDraft,
            onSave: {
              try settingsStore.saveSecret(
                accessTokenDraft, slot: .accessToken, forChannel: channel)
            }
          )
        }
      }
    }
  }

  private func roleToggle(_ role: ProviderRole) -> Binding<Bool> {
    Binding(
      get: { supportedRoles.contains(role) },
      set: { isOn in
        if isOn {
          supportedRoles.insert(role)
        } else {
          supportedRoles.remove(role)
        }
      }
    )
  }

  private var providerSelection: Binding<String> {
    Binding(
      get: { providerID },
      set: { newID in
        let previous = registry.providers.first { $0.id == providerID }
        providerID = newID
        let descriptor = registry.providers.first { $0.id == newID }
        // 换供应商 = 换一套协议默认值;但 Base URL 与模型列表只在用户没动过
        // (为空或仍是上一个预设的默认)时才替换,手填值一律保留——在下拉里
        // 碰一下别的供应商不该把中转站配置静默重置成官方默认。
        baseURL = ChannelPresetSwitchPolicy.resolvedBaseURL(
          current: baseURL,
          previousDefault: previous?.defaultBaseURL ?? "",
          newDefault: descriptor?.defaultBaseURL ?? ""
        )
        appID = ""
        availableModels = ChannelPresetSwitchPolicy.resolvedModels(
          current: availableModels,
          previousDefault: Self.defaultModels(of: previous),
          newDefault: Self.defaultModels(of: descriptor)
        )
        // 能力集合仍收敛到它真支持的角色——别家的角色留着只会在运行时报能力不匹配。
        supportedRoles = supportedRoles.intersection(descriptor?.supportedRoles ?? [])
        if supportedRoles.isEmpty {
          supportedRoles = descriptor?.supportedRoles ?? []
        }
        connectionState = .idle
        modelsHint = nil
      }
    )
  }

  private static func defaultModels(of descriptor: ProviderDescriptor?) -> [String] {
    let defaultModel = descriptor?.defaultModel ?? ""
    return defaultModel.isEmpty ? [] : [defaultModel]
  }

  private func addModelDraft() {
    let trimmed = newModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if !availableModels.contains(trimmed) {
      availableModels.append(trimmed)
    }
    newModelDraft = ""
  }

  private func saveChannel() {
    saveError = nil
    do {
      if let persisted = persistedChannel {
        var updated = persisted
        updated.name = name
        updated.providerID = providerID
        updated.baseURL = baseURL
        updated.appID = appID
        updated.supportedRoles = supportedRoles
        updated.availableModels = availableModels
        try settingsStore.updateChannel(updated)
      } else {
        createdChannel = try settingsStore.createChannel(
          name: name,
          providerID: providerID,
          baseURL: baseURL,
          appID: appID,
          supportedRoles: supportedRoles,
          availableModels: availableModels
        )
      }
      savedFlash += 1
    } catch {
      saveError = error.localizedDescription
    }
  }

  /// 渠道上下文的模型拉取:拿到多少并多少进草稿,「保存渠道」后才落盘。
  /// 失败只提示、不阻断——许多网关不实现 /models(实测有网关直接 500),手填永远可用。
  private func fetchModels() {
    isFetchingModels = true
    modelsHint = nil
    Task { @MainActor in
      defer { isFetchingModels = false }
      do {
        // /models 不吃模型名,没模型可填时给个占位串让客户端通过非空校验。
        let client = try settingsStore.makeLLMClient(
          forChannel: probeChannel,
          model: testModel.isEmpty ? "model-list-probe" : testModel
        )
        if let models = await client.availableModels(), !models.isEmpty {
          let fresh = models.filter { !availableModels.contains($0) }
          availableModels.append(contentsOf: fresh)
          modelsHint =
            fresh.isEmpty
            ? "拉到 \(models.count) 个模型，都已在列表里"
            : "拉到 \(models.count) 个模型，新增 \(fresh.count) 个——点「保存渠道」后生效"
        } else {
          modelsHint = "该服务商未提供模型列表，请手动添加(注意大小写)"
        }
      } catch {
        // 错误文案只含渠道名/槽位,不含凭证;服务端原文不进这里。
        modelsHint = error.localizedDescription
      }
    }
  }

  /// 真发一次最短的对话请求:能不能连通、是不是那个模型在答话、慢不慢,一次说清。
  /// 失败原样呈现服务端说法;凭证值不写进任何日志与界面文案。
  /// 渠道未落盘时按钮本身禁用;这里再守一次,避免草稿钥匙 `channel.draft` 去探针。
  private func runConnectionTest() {
    guard persistedChannel != nil else { return }
    connectionState = .running
    Task { @MainActor in
      let startedAt = Date()
      do {
        let client = try settingsStore.makeLLMClient(
          forChannel: probeChannel,
          model: testModel
        )
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
