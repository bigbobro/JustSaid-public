import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置内容区顶部的三个分段。
public enum SettingsSection: String, CaseIterable, Identifiable {
  case general
  case providers
  case nameAlert

  public var id: String { rawValue }

  /// public:截图装置按页签命名输出文件。
  public var title: String {
    switch self {
    case .providers: return "模型与服务"
    case .general: return "通用"
    case .nameAlert: return "点名提醒"
    }
  }
}

/// 「渠道管理」只承载需要维护连接信息的供应商。过滤只作用于 UI 呈现，
/// 不删除本地渠道，也不改任何角色选择。
public enum ConnectionManagedProviderPresentation {
  public static func descriptors(in registry: ProviderRegistry) -> [ProviderDescriptor] {
    registry.providers.filter(\.requiresAPIKey)
  }

  public static func providerIDs(in registry: ProviderRegistry) -> [String] {
    descriptors(in: registry).map(\.id)
  }

  public static func channels(
    in channels: [ProviderChannel],
    registry: ProviderRegistry
  ) -> [ProviderChannel] {
    let providerIDs = Set(providerIDs(in: registry))
    return channels.filter { providerIDs.contains($0.providerID) }
  }
}

/// 本地转写引擎不进渠道管理，但必须始终可在会中速记角色里选择。
public enum LiveTranscriberProviderPresentation {
  public static func descriptors(in registry: ProviderRegistry) -> [ProviderDescriptor] {
    registry.providers(for: .liveTranscriber).filter { !$0.requiresAPIKey }
  }

  public static func providerIDs(in registry: ProviderRegistry) -> [String] {
    descriptors(in: registry).map(\.id)
  }
}

public struct ProviderChannelPurposeLabel: Identifiable, Equatable {
  public enum Kind: String {
    case asr
    case llm
  }

  public let kind: Kind
  public let text: String
  public var id: String { kind.rawValue }
}

/// 渠道名称由用户决定；用途标签从能力角色派生，避免两条 OpenAI 兼容渠道看起来同义。
public enum ProviderChannelPurpose {
  public static func labels(for roles: Set<ProviderRole>) -> [ProviderChannelPurposeLabel] {
    let asrRoles = roles.filter { !$0.isLLMRole }.sorted { $0.rawValue < $1.rawValue }
    let llmRoles = roles.filter(\.isLLMRole).sorted { $0.rawValue < $1.rawValue }
    var labels: [ProviderChannelPurposeLabel] = []
    if !asrRoles.isEmpty {
      labels.append(
        ProviderChannelPurposeLabel(
          kind: .asr,
          text: "语音识别 · \(asrRoles.map(\.displayName).joined(separator: " / "))"
        )
      )
    }
    if !llmRoles.isEmpty {
      labels.append(
        ProviderChannelPurposeLabel(
          kind: .llm,
          text: "大模型 · \(llmRoles.map(\.displayName).joined(separator: " / "))"
        )
      )
    }
    return labels
  }
}

/// 供应商设置(2026-08-10 统一渠道重构):连接信息收敛到「渠道管理」一个区域——
/// 地址、凭证、模型列表、连接测试只在这里维护;四个角色卡只选择渠道/模型/推理强度,
/// 不再重复填写同一份连接信息。会后精转的对象存储(TOS/Azure/R2)保持独立区域,
/// 不是 AI 渠道,也不进模型选择器。所有密钥只进 Keychain,界面只显示「已保存 + 末四位」。
public struct ProviderSettingsView: View {
  let registry: ProviderRegistry
  @ObservedObject var settingsStore: ProviderSettingsStore
  @ObservedObject var modelAssetManager: LocalModelAssetManager
  let secretDigest: any StoredSecretDigest
  let nameAlertPreferences: NameAlertPreferencesStore?
  let displayTimeZone: DisplayTimeZone?
  let appUpdates: AppUpdatesModel?
  let onDone: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @State private var localSection: SettingsSection = .general
  /// 工作台持有本次运行的设置分区，有它时读写它;
  /// 没有时(截图装置等)退回本地状态。
  private let externalSection: Binding<SettingsSection>?
  private var section: SettingsSection {
    get { externalSection?.wrappedValue ?? localSection }
    nonmutating set {
      if let externalSection {
        externalSection.wrappedValue = newValue
      } else {
        localSection = newValue
      }
    }
  }
  @State private var channelEditorRequest: ChannelEditorRequest?

  /// - Parameter secretDigest: 「这把 key 存了吗、末四位多少」的来源。
  ///   缺省是真读 Keychain;验证程序必须注入 `InMemorySecretDigest`,
  ///   否则每渲染一帧就向用户弹一次钥匙串授权框。
  public init(
    registry: ProviderRegistry,
    settingsStore: ProviderSettingsStore,
    modelAssetManager: LocalModelAssetManager,
    secretDigest: (any StoredSecretDigest)? = nil,
    nameAlertPreferences: NameAlertPreferencesStore? = nil,
    displayTimeZone: DisplayTimeZone? = nil,
    appUpdates: AppUpdatesModel? = nil,
    initialSection: SettingsSection = .general,
    section: Binding<SettingsSection>? = nil,
    /// 壳里的一页用它回上一页;仍以弹窗出现时留空,走 `dismiss`。
    onDone: (() -> Void)? = nil
  ) {
    self.onDone = onDone
    _localSection = State(initialValue: initialSection)
    externalSection = section
    self.nameAlertPreferences = nameAlertPreferences
    self.displayTimeZone = displayTimeZone
    self.appUpdates = appUpdates
    self.registry = registry
    self.settingsStore = settingsStore
    self.modelAssetManager = modelAssetManager
    self.secretDigest = secretDigest ?? KeychainSecretDigest(settingsStore: settingsStore)
  }

  static var buildLabel: String {
    let info = Bundle.main.infoDictionary
    guard let version = info?["CFBundleShortVersionString"] as? String,
      let build = info?["CFBundleVersion"] as? String
    else { return "本地构建" }
    return "v\(version) · \(build)"
  }

  public var body: some View {
    // 顶栏只标页名；分段切换与三段表单沿同一居中列。
    VStack(spacing: .zero) {
      pageBar
      sectionTabs
      Group {
        switch section {
        case .providers:
          providerPane
        case .general:
          GeneralSettingsPane(
            settingsStore: settingsStore, nameAlertPreferences: nameAlertPreferences,
            appUpdates: appUpdates, displayTimeZone: displayTimeZone)
        case .nameAlert:
          if let nameAlertPreferences {
            NameAlertSettingsPane(preferences: nameAlertPreferences)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Tokens.V1.Color.paper)
    // Esc 回到进来之前那一页——「完成」按钮拿掉后留一个键盘出口(输入框里的 Esc 先由输入框处理)。
    .onExitCommand { onDone?() }
    .sheet(item: $channelEditorRequest) { request in
      ChannelEditorView(
        request: request,
        registry: registry,
        settingsStore: settingsStore,
        secretDigest: secretDigest
      )
      .frame(minWidth: Tokens.V1.Size.settingsForm)
    }
  }

  private var sectionTabs: some View {
    GeometryReader { geometry in
      V1SegmentedPicker(
        "设置分区", selection: Binding(get: { section }, set: { section = $0 }),
        options: SettingsSection.allCases.map { candidate in
          .init(candidate, candidate.title)
        }, fills: true, segmentHeight: Tokens.V1.Size.controlLg - Tokens.V1.Space.s2xs
      )
      .frame(width: Tokens.V1.Size.settingsForm)
      .runtimeAccessibilityIdentifier("settings.tabs")
      .runtimeAccessibilityIdentifier("settings.tabs.selected.\(section.rawValue)")
      .padding(
        .horizontal,
        SettingsPageGeometry.inset(for: geometry.size.width, fullWidth: false))
    }
    .frame(height: Tokens.V1.Size.controlLg)
    .padding(.vertical, Tokens.V1.Space.md)
  }

  private var pageBar: some View {
    WorkspaceTopBar("设置") { EmptyView() }
  }

  private var providerPane: some View {
    SettingsPage(title: "模型与服务", subtitle: "先配置渠道，再为每个阶段选择模型。") {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
        ChannelManagementCard(
          registry: registry, settingsStore: settingsStore, secretDigest: secretDigest,
          onEdit: { channelEditorRequest = ChannelEditorRequest(channel: $0) },
          onCreate: { channelEditorRequest = ChannelEditorRequest(channel: nil) })

        ChannelRoleCard(
          role: .liveTranscriber, registry: registry, settingsStore: settingsStore,
          secretDigest: secretDigest, modelAssetManager: modelAssetManager
        ) { LocalModelsSettingsRow(manager: modelAssetManager) }
        ChannelRoleCard(
          role: .liveSummaryLLM, registry: registry, settingsStore: settingsStore,
          secretDigest: secretDigest)
        ChannelRoleCard(
          role: .batchASR, registry: registry, settingsStore: settingsStore,
          secretDigest: secretDigest
        ) { StorageSettingsRow(settingsStore: settingsStore, secretDigest: secretDigest) }
        ChannelRoleCard(
          role: .minutesLLM, registry: registry, settingsStore: settingsStore,
          secretDigest: secretDigest)
      }
    }
  }
}

/// 与模型选择无关的应用级设置单独摆页，避免麦克风采集夹在模型角色之间。

// 通用页/共享小件/渠道管理/编辑器/角色卡/存储卡 见各自文件(批4 拆分)。

struct ChannelEditorRequest: Identifiable {
  let channel: ProviderChannel?

  var id: String { channel?.id ?? "new-channel" }
}
