import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-20 批4 拆分:自 ProviderSettingsView.swift 机械迁出,零行为变更。
// MARK: - 会后精转 · 对象存储(独立区域)

/// 对象存储不是 AI 渠道:TOS / Azure / R2 的配置与凭证独立维护在这张卡里,
/// 不进渠道列表,也不进任何模型选择器。存储槽位的密钥经绑定坐标路由到
/// 独立 `StorageConfiguration` 的冻结账户,与渠道账户互不相干。
struct StorageSettingsCard: View {
  @ObservedObject var settingsStore: ProviderSettingsStore
  let secretDigest: any StoredSecretDigest

  @State private var tosAccessKeyDraft = ""
  @State private var tosSecretKeyDraft = ""
  @State private var azureAccountKeyDraft = ""
  @State private var r2AccessKeyDraft = ""
  @State private var r2SecretKeyDraft = ""
  @State private var lastSavedAt: Date?
  @State private var storageTestState: ConnectionTestState = .idle

  private let role = ProviderRole.batchASR

  private var binding: RoleProviderBinding { settingsStore.binding(for: role) }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      LabeledField(label: "存储渠道") {
        Picker("", selection: storageKindSelection) {
          ForEach(StorageProviderKind.allCases) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
      Text(binding.selectedStorageProviderKind.selectionHint)
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
        .runtimeAccessibilityIdentifier("settings.storage-kind-hint")

      switch binding.selectedStorageProviderKind {
      case .azureBlob:
        azureFields
      case .volcengineTOS:
        tosFields
      case .cloudflareR2:
        r2Fields
      }

      ConnectionTestRow(
        state: storageTestState,
        kind: .storage
      ) {
        runStorageConnectionTest()
      }
      .runtimeAccessibilityIdentifier("settings.storage.test")

      EffectiveConfigurationRow(
        summary: ProviderEffectiveSummary.text(
          segments: [storageSegment],
          savedAt: lastSavedAt
        ),
        pendingWarning: pendingDraftWarning
      )
    }
    .runtimeAccessibilityIdentifier("settings.storage")
  }

  @ViewBuilder
  private var azureFields: some View {
    LabeledField(label: "容器地址", savedTrigger: binding.azureContainerURL ?? "") {
      TextField(
        "如 https://账户名.blob.core.windows.net/容器名",
        text: azureContainerBinding
      )
    }
    SecretRow(
      label: "账户密钥",
      isSaved: secretDigest.exists(slot: .azureAccountKey, for: binding),
      suffix: secretDigest.suffix(slot: .azureAccountKey, for: binding),
      draft: $azureAccountKeyDraft,
      onSave: {
        try settingsStore.saveSecret(
          azureAccountKeyDraft, slot: .azureAccountKey, for: binding)
        lastSavedAt = Date()
      }
    )
    Text("只需账户密钥；上传/删除所需的短效 SAS 由应用现场派生，无需手动准备。")
      .font(.system(size: Tokens.FontSize.secondary))
      .foregroundStyle(Tokens.Color.ink3)
  }

  @ViewBuilder
  private var tosFields: some View {
    SecretRow(
      label: "Access Key",
      isSaved: secretDigest.exists(slot: .tosAccessKey, for: binding),
      suffix: secretDigest.suffix(slot: .tosAccessKey, for: binding),
      draft: $tosAccessKeyDraft,
      onSave: {
        try settingsStore.saveSecret(tosAccessKeyDraft, slot: .tosAccessKey, for: binding)
        lastSavedAt = Date()
      }
    )
    SecretRow(
      label: "Secret Key",
      isSaved: secretDigest.exists(slot: .tosSecretKey, for: binding),
      suffix: secretDigest.suffix(slot: .tosSecretKey, for: binding),
      draft: $tosSecretKeyDraft,
      onSave: {
        try settingsStore.saveSecret(tosSecretKeyDraft, slot: .tosSecretKey, for: binding)
        lastSavedAt = Date()
      }
    )
    LabeledField(label: "存储桶 Bucket", savedTrigger: binding.tosBucket) {
      TextField("如 justsaid-audio", text: tosBucketBinding)
    }
    LabeledField(label: "区域 Region", savedTrigger: binding.tosRegion) {
      TextField("如 cn-beijing", text: tosRegionBinding)
    }
  }

  @ViewBuilder
  private var r2Fields: some View {
    LabeledField(label: "Account ID", savedTrigger: binding.r2AccountID ?? "") {
      TextField("Cloudflare 控制台右侧的 Account ID", text: r2AccountIDBinding)
    }
    LabeledField(label: "存储桶 Bucket", savedTrigger: binding.r2Bucket ?? "") {
      TextField("如 justsaid-audio", text: r2BucketBinding)
    }
    SecretRow(
      label: "Access Key ID",
      isSaved: secretDigest.exists(slot: .r2AccessKey, for: binding),
      suffix: secretDigest.suffix(slot: .r2AccessKey, for: binding),
      draft: $r2AccessKeyDraft,
      onSave: {
        try settingsStore.saveSecret(r2AccessKeyDraft, slot: .r2AccessKey, for: binding)
        lastSavedAt = Date()
      }
    )
    SecretRow(
      label: "Secret Access Key",
      isSaved: secretDigest.exists(slot: .r2SecretKey, for: binding),
      suffix: secretDigest.suffix(slot: .r2SecretKey, for: binding),
      draft: $r2SecretKeyDraft,
      onSave: {
        try settingsStore.saveSecret(r2SecretKeyDraft, slot: .r2SecretKey, for: binding)
        lastSavedAt = Date()
      }
    )
    Text("Access Key / Secret Key 只进钥匙串，不会写入会议档案。")
      .font(.system(size: Tokens.FontSize.secondary))
      .foregroundStyle(Tokens.Color.ink3)
  }

  private var storageSegment: String {
    switch binding.selectedStorageProviderKind {
    case .azureBlob:
      let container = binding.azureContainerURL ?? ""
      let label =
        container.isEmpty ? "未填容器" : ProviderEffectiveSummary.host(from: container)
      return "Azure \(label)"
    case .volcengineTOS:
      return "TOS \(binding.tosBucket.isEmpty ? "未填桶" : binding.tosBucket)"
    case .cloudflareR2:
      let bucket = binding.r2Bucket ?? ""
      return "R2 \(bucket.isEmpty ? "未填桶" : bucket)"
    }
  }

  /// 与角色卡同理:唯一真会不一致的是还没点保存的密钥草稿。
  private var pendingDraftWarning: String? {
    let drafts = [
      tosAccessKeyDraft,
      tosSecretKeyDraft,
      azureAccountKeyDraft,
      r2AccessKeyDraft,
      r2SecretKeyDraft,
    ]
    let hasPending = drafts.contains {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return hasPending
      ? "有密钥框还没点「保存」——写进 Keychain 之前，当前生效的仍是上一把凭证。"
      : nil
  }

  private var storageKindSelection: Binding<StorageProviderKind> {
    Binding(
      get: { binding.selectedStorageProviderKind },
      set: { newKind in
        var updated = binding
        updated.storageProviderKind = newKind
        settingsStore.update(updated)
        lastSavedAt = Date()
        storageTestState = .idle
      }
    )
  }

  private func runStorageConnectionTest() {
    storageTestState = .running
    Task { @MainActor in
      await settingsStore.refreshStorageHealth(showConfigurationErrors: true)
      if let failure = settingsStore.storageHealthFailureMessage {
        storageTestState = .failed(message: failure)
      } else if let message = settingsStore.storageHealthMessage {
        storageTestState = .succeeded(latencyMilliseconds: 0, replyPreview: message)
      } else {
        storageTestState = .idle
      }
    }
  }

  private var azureContainerBinding: Binding<String> {
    Binding(
      get: { binding.azureContainerURL ?? "" },
      set: { newValue in
        var updated = binding
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.azureContainerURL = trimmed.isEmpty ? nil : trimmed
        settingsStore.update(updated)
        lastSavedAt = Date()
      }
    )
  }

  private var r2AccountIDBinding: Binding<String> {
    Binding(
      get: { binding.r2AccountID ?? "" },
      set: { newValue in
        var updated = binding
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.r2AccountID = trimmed.isEmpty ? nil : trimmed
        settingsStore.update(updated)
        lastSavedAt = Date()
      }
    )
  }

  private var r2BucketBinding: Binding<String> {
    Binding(
      get: { binding.r2Bucket ?? "" },
      set: { newValue in
        var updated = binding
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.r2Bucket = trimmed.isEmpty ? nil : trimmed
        settingsStore.update(updated)
        lastSavedAt = Date()
      }
    )
  }

  private var tosBucketBinding: Binding<String> {
    Binding(
      get: { binding.tosBucket },
      set: { newValue in
        var updated = binding
        updated.tosBucket = newValue
        settingsStore.update(updated)
        lastSavedAt = Date()
      }
    )
  }

  private var tosRegionBinding: Binding<String> {
    Binding(
      get: { binding.tosRegion },
      set: { newValue in
        var updated = binding
        updated.tosRegion = newValue
        settingsStore.update(updated)
        lastSavedAt = Date()
      }
    )
  }
}

/// 会后精转组里的对象存储行。提供方与连接配置分行，仍属于同一阶段卡：
/// 录音先传到这里再交给 ASR 拉取,它是这个角色链路的一环,不是另一张卡。
/// 地址与凭证收进「配置…」浮层——填一次就不再看,不该常驻在你改主意用的表单上。
struct StorageSettingsRow: View {
  @ObservedObject var settingsStore: ProviderSettingsStore
  let secretDigest: any StoredSecretDigest

  @State private var isConfiguring = false
  @State private var testState: ConnectionTestState = .idle

  private let role = ProviderRole.batchASR

  private var binding: RoleProviderBinding { settingsStore.binding(for: role) }

  var body: some View {
    VStack(spacing: .zero) {
      SettingsFormRow("对象存储") {
        V1Dropdown(
          value: storageKindSelection.wrappedValue.displayName,
          identifier: "settings.storage.kind"
        ) {
          ForEach(StorageProviderKind.allCases) { kind in
            Button(kind.displayName) { storageKindSelection.wrappedValue = kind }
          }
        }
        .frame(width: Tokens.V1.Size.settingsModelField)
      }
      .runtimeAccessibilityIdentifier("settings.storage.provider")
      SettingsFormRow("连接配置", labelDetail: summary) {
        Button("配置…") { isConfiguring = true }
          .buttonStyle(.v1Outline)
          .runtimeAccessibilityIdentifier("settings.storage.configure")
        Button(testState.isRunning ? "测试中…" : "测试连接") { runStorageConnectionTest() }
          .buttonStyle(.v1Outline)
          .disabled(testState.isRunning)
          .runtimeAccessibilityIdentifier("settings.storage.test")
      }
      .runtimeAccessibilityIdentifier("settings.storage.connection")
    }
    .runtimeAccessibilityIdentifier("settings.storage")
    .sheet(isPresented: $isConfiguring) {
      SettingsSheetShell(
        "对象存储",
        subtitle: "录音先上传到对象存储，再交给 ASR 拉取；与 AI 渠道相互独立",
        onDone: { isConfiguring = false }
      ) {
        StorageSettingsCard(settingsStore: settingsStore, secretDigest: secretDigest)
      }
    }

    if let note = testState.settingsNote {
      SettingsFormNote(note, tone: testState.isFailure ? .warn : .meta)
    }
  }

  /// 「现在往哪儿传、密钥在不在」——一行说清,不用点开就知道要不要点开。
  private var summary: String {
    let target: String
    switch binding.selectedStorageProviderKind {
    case .azureBlob:
      let container = binding.azureContainerURL ?? ""
      target = container.isEmpty ? "未填容器" : ProviderEffectiveSummary.host(from: container)
    case .volcengineTOS:
      target = binding.tosBucket.isEmpty ? "未填桶" : binding.tosBucket
    case .cloudflareR2:
      let bucket = binding.r2Bucket ?? ""
      target = bucket.isEmpty ? "未填桶" : bucket
    }
    return "\(target) · \(hasStoredSecret ? "密钥已保存" : "未存密钥")"
  }

  private var hasStoredSecret: Bool {
    switch binding.selectedStorageProviderKind {
    case .azureBlob:
      return secretDigest.exists(slot: .azureAccountKey, for: binding)
    case .volcengineTOS:
      return secretDigest.exists(slot: .tosAccessKey, for: binding)
    case .cloudflareR2:
      return secretDigest.exists(slot: .r2AccessKey, for: binding)
    }
  }

  private var storageKindSelection: Binding<StorageProviderKind> {
    Binding(
      get: { binding.selectedStorageProviderKind },
      set: { newKind in
        var updated = binding
        updated.storageProviderKind = newKind
        settingsStore.update(updated)
        testState = .idle
      }
    )
  }

  private func runStorageConnectionTest() {
    testState = .running
    Task { @MainActor in
      await settingsStore.refreshStorageHealth(showConfigurationErrors: true)
      if let failure = settingsStore.storageHealthFailureMessage {
        testState = .failed(message: failure)
      } else if let message = settingsStore.storageHealthMessage {
        testState = .succeeded(latencyMilliseconds: 0, replyPreview: message)
      } else {
        testState = .idle
      }
    }
  }
}
