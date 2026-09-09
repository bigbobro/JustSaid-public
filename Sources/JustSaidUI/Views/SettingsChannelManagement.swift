import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-20 批4 拆分:自 ProviderSettingsView.swift 机械迁出,零行为变更。
// MARK: - 渠道管理

/// 统一渠道管理区:全部渠道的列表 + 新建入口。地址/凭证/模型列表只在这里维护,
/// 四个角色卡只做选择——同一份连接信息全app只有这一处真相。
struct ChannelManagementCard: View {
  let registry: ProviderRegistry
  @ObservedObject var settingsStore: ProviderSettingsStore
  let secretDigest: any StoredSecretDigest
  let onCreate: () -> Void
  let onEdit: (ProviderChannel) -> Void

  /// 删除是两段式的:第一次点只是武装,第二次才真删——列表里没有弹窗的余地,
  /// 被引用的渠道由 store 抛错拦住(错误列出全部引用角色)。
  /// 武装态 5 秒超时或鼠标离开渠道列表即复位,避免走开后再点一次就真删。
  @State private var armedDeletionID: String?
  @State private var deletionError: String?
  @State private var armResetTask: Task<Void, Never>?

  private var channels: [ProviderChannel] {
    ConnectionManagedProviderPresentation.channels(
      in: settingsStore.configuration.channels,
      registry: registry
    )
  }

  var body: some View {
    RoleCardShell(title: "渠道管理", subtitle: "地址、凭证与模型列表的统一维护处；角色卡只选择") {
      if channels.isEmpty {
        Text("还没有需要连接配置的渠道——点下方「新建渠道」添加。")
          .font(.system(size: Tokens.FontSize.uiEmphasis))
          .foregroundStyle(Tokens.Color.ink3)
      }
      ForEach(channels) { channel in
        channelRow(channel)
      }

      HStack(spacing: Tokens.Spacing.sm) {
        Button("新建渠道") {
          disarmDeletion()
          deletionError = nil
          onCreate()
        }
        .buttonStyle(.toolbarPill)
        .runtimeAccessibilityIdentifier("settings.channels.add")
        if let migrationFailure = settingsStore.migrationFailureMessage {
          HintText(text: "旧配置迁移失败，已保留原始数据：\(migrationFailure)")
        }
      }

      if let deletionError {
        HintText(text: deletionError)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onHover { hovering in
      if !hovering {
        disarmDeletion()
      }
    }
    .onDisappear {
      disarmDeletion()
    }
    .runtimeAccessibilityIdentifier("settings.channels")
  }

  private func disarmDeletion() {
    armResetTask?.cancel()
    armResetTask = nil
    armedDeletionID = nil
  }

  private func armDeletion(_ id: String) {
    armResetTask?.cancel()
    armedDeletionID = id
    deletionError = nil
    armResetTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      if armedDeletionID == id {
        armedDeletionID = nil
      }
    }
  }

  @ViewBuilder
  private func channelRow(_ channel: ProviderChannel) -> some View {
    let descriptor = registry.providers.first { $0.id == channel.providerID }
    let references = settingsStore.channelReferences(id: channel.id)
    HStack(alignment: .center, spacing: Tokens.Spacing.smd) {
      VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
        HStack(spacing: Tokens.Spacing.xs) {
          Text(channel.name)
            .font(.system(size: Tokens.FontSize.body, weight: .semibold))
            .foregroundStyle(Tokens.Color.ink)
          if !references.isEmpty {
            Text("引用：\(references.map(\.displayName).joined(separator: "、"))")
              .font(.system(size: Tokens.FontSize.caption))
              .foregroundStyle(Tokens.Color.ink4)
          }
        }
        Text(
          [
            descriptor?.displayName ?? channel.providerID,
            ProviderEffectiveSummary.host(from: channel.baseURL),
          ]
          .filter { !$0.isEmpty }
          .joined(separator: " · ")
        )
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
        HStack(spacing: Tokens.Spacing.xs) {
          ForEach(ProviderChannelPurpose.labels(for: channel.supportedRoles)) { purpose in
            Text(purpose.text)
              .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
              .foregroundStyle(
                purpose.kind == .asr ? Tokens.Color.acDeep : Tokens.Color.revision
              )
              .padding(.horizontal, Tokens.Spacing.xs)
              .padding(.vertical, Tokens.Spacing.hairline)
              .background(
                purpose.kind == .asr ? Tokens.Color.acSoft : Tokens.Color.revisionSoft,
                in: Capsule()
              )
              .runtimeAccessibilityIdentifier(
                "settings.channel.purpose.\(channel.id).\(purpose.kind.rawValue)"
              )
          }
        }
      }
      Spacer(minLength: Tokens.Spacing.xs)
      if descriptor?.requiresAPIKey == true {
        if let suffix = secretDigest.suffix(slot: .apiKey, forChannel: channel) {
          Label("····\(suffix)", systemImage: "checkmark.shield.fill")
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.ac)
        } else {
          Text("未存密钥")
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.warn)
        }
      }
      Button("编辑") {
        disarmDeletion()
        deletionError = nil
        onEdit(channel)
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.ui))
      Button(armedDeletionID == channel.id ? "确认删除" : "删除") {
        if armedDeletionID == channel.id {
          disarmDeletion()
          do {
            try settingsStore.deleteChannel(id: channel.id)
            deletionError = nil
          } catch {
            deletionError = error.localizedDescription
          }
        } else {
          armDeletion(channel.id)
        }
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.ui))
      .foregroundStyle(Tokens.Color.warn)
    }
    .padding(.vertical, Tokens.Spacing.xxs)
    .runtimeAccessibilityIdentifier("settings.channel.row.\(channel.id)")
  }
}
