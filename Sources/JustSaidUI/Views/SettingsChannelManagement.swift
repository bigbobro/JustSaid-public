import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-20 批4 拆分:自 ProviderSettingsView.swift 机械迁出,零行为变更。
// 2026-09-20 批4:卡片换成设计稿的渠道表(`settings-models.html` 的 `.fgrp-resource`)。
// MARK: - 渠道

/// 渠道表:全部渠道一行一个。地址/凭证/模型列表只在这里维护,
/// 四个角色组只做选择——同一份连接信息全app只有这一处真相。
///
/// 「新建渠道」挂在这张表的组头右端(`settings.channel.create`),全屏只此一处。
/// 原来放在分区标题行「模型与服务」右边——那一行管整个分区,渠道只是其中一组
/// (owner 2026-09-21:「为什么会建在标题栏这个位置?渠道就在这里添加就好了」)。
struct ChannelManagementCard: View {
  let registry: ProviderRegistry
  @ObservedObject var settingsStore: ProviderSettingsStore
  let secretDigest: any StoredSecretDigest
  let onEdit: (ProviderChannel) -> Void
  let onCreate: () -> Void

  // 菜单只提出删除请求；确认后仍由 store 检查是否被角色引用。
  @State private var deletionCandidate: ProviderChannel?
  @State private var deletionError: String?

  private var channels: [ProviderChannel] {
    ConnectionManagedProviderPresentation.channels(
      in: settingsStore.configuration.channels,
      registry: registry
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      SettingsFormGroup(
        "渠道", hint: "先建渠道，再为会议各阶段选择服务。"
      ) {
        if channels.isEmpty {
          // 空盒子不画:没有渠道时这一行就是这张表的全部内容。
          SettingsFormRow(labelWidth: .fit, isFirst: true) {
            Text("还没有渠道，点「新建渠道」添加。")
              .font(Tokens.V1.Text.body.font)
              .foregroundStyle(Tokens.V1.Color.ink3)
          } content: {
            EmptyView()
          }
        }
        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
          channelRow(channel, isFirst: index == .zero)
        }
      } accessory: {
        Button(action: onCreate) {
          Label("新建渠道", systemImage: "plus")
        }
        .buttonStyle(.v1Outline)
        .runtimeAccessibilityIdentifier("settings.channel.create")
      }
      // 两条只在出事时才存在的提示,放在盒子外面——盒子里是表,表里只有渠道。
      if let deletionError {
        HintText(text: deletionError)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let migrationFailure = settingsStore.migrationFailureMessage {
        HintText(text: "旧配置迁移失败，已保留原始数据：\(migrationFailure)")
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .confirmationDialog(
      "删除渠道？",
      isPresented: Binding(
        get: { deletionCandidate != nil },
        set: { if !$0 { deletionCandidate = nil } }
      ),
      titleVisibility: .visible, presenting: deletionCandidate
    ) { channel in
      Button("删除", role: .destructive) {
        do {
          try settingsStore.deleteChannel(id: channel.id)
          deletionError = nil
        } catch {
          deletionError = error.localizedDescription
        }
        deletionCandidate = nil
      }
      Button("取消", role: .cancel) { deletionCandidate = nil }
    } message: { channel in
      Text(channel.name)
    }
    .runtimeAccessibilityIdentifier("settings.channels")
    .runtimeAccessibilityIdentifier(
      deletionCandidate == nil
        ? "settings.channel.deletion.closed" : "settings.channel.deletion.pending")
  }

  /// 名称、用途与凭证状态归左侧，编辑和删除靠右；详情仍来自真实配置。
  @ViewBuilder
  private func channelRow(_ channel: ProviderChannel, isFirst: Bool) -> some View {
    let descriptor = registry.providers.first { $0.id == channel.providerID }
    let purposes = ProviderChannelPurpose.labels(for: channel.supportedRoles)
    SettingsFormRow(
      labelWidth: .fit,
      value: channelDetail(channel, descriptor: descriptor),
      isFirst: isFirst
    ) {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
        Text(channel.name)
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .lineLimit(1)
        HStack(spacing: Tokens.V1.Space.xs) {
          ForEach(purposes) { purpose in
            Text(purpose.kind == .asr ? "语音识别" : "大模型")
              .font(Tokens.V1.Text.meta.font)
              .foregroundStyle(Tokens.V1.Color.ink2)
              .runtimeAccessibilityIdentifier(
                "settings.channel.purpose.\(channel.id).\(purpose.kind.rawValue)")
          }
          if descriptor?.requiresAPIKey == true {
            SettingsKeyBadge(suffix: secretDigest.suffix(slot: .apiKey, forChannel: channel))
              .fixedSize()
          }
        }
      }
    } content: {
      Button("编辑") {
        deletionCandidate = nil
        deletionError = nil
        onEdit(channel)
      }
      .buttonStyle(.v1Outline)
      .runtimeAccessibilityIdentifier("settings.channel.edit.\(channel.id)")
      Menu {
        Button("删除", role: .destructive) {
          deletionError = nil
          deletionCandidate = channel
        }
        .foregroundStyle(Tokens.V1.Color.danger)
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: Tokens.V1.Space.sm)
      }
      .menuStyle(.button).menuIndicator(.hidden)
      .buttonStyle(.v1Outline)
      .accessibilityLabel("\(channel.name)选项")
      .runtimeAccessibilityIdentifier("settings.channel.menu.\(channel.id)")
    }
    .runtimeAccessibilityIdentifier("settings.channel.row.\(channel.id)")
  }

  /// 副行:主机 + 谁在用它。渠道名和渠道商名常常一字不差,同名就不再重复一遍。
  private func channelDetail(
    _ channel: ProviderChannel,
    descriptor: ProviderDescriptor?
  ) -> String? {
    let vendor =
      descriptor?.displayName == channel.name ? "" : (descriptor?.displayName ?? channel.providerID)
    let references = settingsStore.channelReferences(id: channel.id)
    let used =
      references.isEmpty ? "" : "用于 \(references.map(\.displayName).joined(separator: "、"))"
    let parts = [vendor, ProviderEffectiveSummary.host(from: channel.baseURL), used]
      .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
