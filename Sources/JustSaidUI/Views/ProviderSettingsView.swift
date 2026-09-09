import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置页的三个页签;「完成」属于容器层,三个页签共用一个。
private enum SettingsSection: String, CaseIterable, Identifiable {
  case providers
  case general
  case dictionary

  var id: String { rawValue }

  var title: String {
    switch self {
    case .providers: return "模型与服务"
    case .general: return "通用"
    case .dictionary: return "词典"
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
          text: "ASR · \(asrRoles.map(\.displayName).joined(separator: " / "))"
        )
      )
    }
    if !llmRoles.isEmpty {
      labels.append(
        ProviderChannelPurposeLabel(
          kind: .llm,
          text: "LLM · \(llmRoles.map(\.displayName).joined(separator: " / "))"
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
  let dictionaryStore: DictionaryStore
  let secretDigest: any StoredSecretDigest

  @Environment(\.dismiss) private var dismiss
  @State private var section: SettingsSection = .providers
  @State private var channelEditorRequest: ChannelEditorRequest?

  /// - Parameter secretDigest: 「这把 key 存了吗、末四位多少」的来源。
  ///   缺省是真读 Keychain;验证程序必须注入 `InMemorySecretDigest`,
  ///   否则每渲染一帧就向用户弹一次钥匙串授权框。
  public init(
    registry: ProviderRegistry,
    settingsStore: ProviderSettingsStore,
    modelAssetManager: LocalModelAssetManager,
    dictionaryStore: DictionaryStore = DictionaryStore(),
    secretDigest: (any StoredSecretDigest)? = nil
  ) {
    self.registry = registry
    self.settingsStore = settingsStore
    self.modelAssetManager = modelAssetManager
    self.dictionaryStore = dictionaryStore
    self.secretDigest = secretDigest ?? KeychainSecretDigest(settingsStore: settingsStore)
  }

  static var buildLabel: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "v\(version) · \(build)"
  }

  public var body: some View {
    VStack(spacing: 0) {
      sectionBar
      Divider()
      switch section {
      case .providers:
        providerPane
      case .general:
        GeneralSettingsPane(settingsStore: settingsStore)
      case .dictionary:
        DictionarySettingsView(store: dictionaryStore)
      }
    }
    .background(Tokens.Color.bg)
    .sheet(item: $channelEditorRequest) { request in
      ChannelEditorView(
        request: request,
        registry: registry,
        settingsStore: settingsStore,
        secretDigest: secretDigest
      )
      .frame(minWidth: 560)
    }
  }

  /// 页签沿用会议库详情页那一排的视觉语言(pill + 墨青底),不新造一套。
  private var sectionBar: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      ForEach(SettingsSection.allCases) { candidate in
        Button {
          section = candidate
        } label: {
          Text(candidate.title)
            .font(.system(size: Tokens.FontSize.uiEmphasis, weight: section == candidate ? .semibold : .regular))
            .foregroundStyle(section == candidate ? Tokens.Color.acDeep : Tokens.Color.ink2)
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, Tokens.Spacing.xxs)
            .background(
              RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(section == candidate ? Tokens.Color.acSoft : Color.clear)
            )
            .overlay(
              RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .stroke(section == candidate ? Tokens.Color.acLine : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .hoverRowBackground(cornerRadius: Tokens.Radius.control)
        .runtimeAccessibilityIdentifier("settings.section.\(candidate.rawValue)")
      }

      Spacer()

      // 构建标识(2026-07-31):部署验证的唯一凭据——口头核对这一串,不猜版本。
      Text(Self.buildLabel)
        .font(.system(size: Tokens.FontSize.secondary, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink4)
        .textSelection(.enabled)
        .accessibilityLabel("构建标识 \(Self.buildLabel)")

      // 所有编辑都是即时写入的(密钥点「保存」入 Keychain,其余随打随存),
      // 所以「完成」只负责关窗,不承担提交语义。
      Button("完成") {
        dismiss()
      }
      .buttonStyle(.toolbarPillAccent)
      .keyboardShortcut("w", modifiers: .command)
      .accessibilityLabel("完成并关闭设置")
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.sm)
  }

  private var providerPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
        Text("渠道在「渠道管理」里统一维护；四个角色只选择渠道、模型与推理强度，互不同步。密钥只存入 macOS Keychain。")
          .font(.system(size: Tokens.FontSize.bodyMinimum))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)

        ChannelManagementCard(
          registry: registry,
          settingsStore: settingsStore,
          secretDigest: secretDigest,
          onCreate: {
            channelEditorRequest = ChannelEditorRequest(channel: nil)
          },
          onEdit: { channel in
            channelEditorRequest = ChannelEditorRequest(channel: channel)
          }
        )
        ChannelRoleCard(
          role: .liveTranscriber,
          registry: registry,
          settingsStore: settingsStore,
          secretDigest: secretDigest,
          modelAssetManager: modelAssetManager
        )
        LocalModelsSettingsCard(manager: modelAssetManager)
        ChannelRoleCard(
          role: .liveSummaryLLM,
          registry: registry,
          settingsStore: settingsStore,
          secretDigest: secretDigest
        )
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
          ChannelRoleCard(
            role: .batchASR,
            registry: registry,
            settingsStore: settingsStore,
            secretDigest: secretDigest
          )
          StorageSettingsCard(
            settingsStore: settingsStore,
            secretDigest: secretDigest
          )
        }
        ChannelRoleCard(
          role: .minutesLLM,
          registry: registry,
          settingsStore: settingsStore,
          secretDigest: secretDigest
        )
      }
      .padding(Tokens.Spacing.lg)
    }
  }
}

/// 与模型选择无关的应用级设置单独摆页，避免麦克风采集夹在模型角色之间。

// 通用页/共享小件/渠道管理/编辑器/角色卡/存储卡 见各自文件(批4 拆分)。

struct ChannelEditorRequest: Identifiable {
  let channel: ProviderChannel?

  var id: String { channel?.id ?? "new-channel" }
}

