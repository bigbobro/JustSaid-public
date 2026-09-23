import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-20 批4 拆分:自 ProviderSettingsView.swift 机械迁出,零行为变更。
public struct GeneralSettingsPane: View {
  let settingsStore: ProviderSettingsStore?
  let nameAlertPreferences: NameAlertPreferencesStore?
  let appUpdates: AppUpdatesModel?
  let displayTimeZone: DisplayTimeZone?

  public init(
    settingsStore: ProviderSettingsStore? = nil,
    nameAlertPreferences: NameAlertPreferencesStore? = nil,
    appUpdates: AppUpdatesModel? = nil,
    displayTimeZone: DisplayTimeZone? = nil
  ) {
    self.settingsStore = settingsStore
    self.nameAlertPreferences = nameAlertPreferences
    self.appUpdates = appUpdates
    self.displayTimeZone = displayTimeZone
  }

  public var body: some View {
    SettingsPage(title: "通用", subtitle: "外观、录音与日常使用偏好。") {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
        AppearanceSettingsCard()
        GlobalHotkeySettingsCard()
        if let displayTimeZone {
          TimeZoneSettingsCard(displayTimeZone: displayTimeZone)
        }

        MicrophoneAECSettingsCard()
        AudioRetentionSettingsCard()
        if let appUpdates {
          AppUpdateSettingsCard(model: appUpdates)
        } else {
          SettingsFormGroup(
            "应用更新", hint: "从公开正式版获取新版本。"
          ) {
            SettingsFormRow("状态", isFirst: true) {
              Text("本地构建，应用内更新未启用")
                .font(Tokens.V1.Text.meta.font)
                .foregroundStyle(Tokens.V1.Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .runtimeAccessibilityIdentifier("settings.app-updates.disabled")
        }
        DiagnosticsExportCard(settingsStore: settingsStore)
      }
    }
    .runtimeAccessibilityIdentifier("settings.general")
  }
}

/// 渠道编辑器 sheet 的请求:nil 渠道 = 新建。

// MARK: - 外观

private struct AppearanceSettingsCard: View {
  @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue =
    AppAppearance.system.rawValue
  // 阅读缩放是全局持久化的(justsaid.textScale),按性质就该和外观在一起。
  // 会中顶栏那颗留着:那是读的时候临时调,这里是你会去找它的地方
  // (macOS 自己也是两处:设置里有字号,控制中心也能调)。
  @AppStorage(TextScale.defaultsKey) private var textScaleRawValue = TextScale.standard.rawValue

  var body: some View {
    SettingsFormGroup(
      "外观", hint: "选择界面外观与会议正文的阅读大小。"
    ) {
      SettingsFormRow("界面", labelDetail: "跟随系统，或为 JustSaid 单独选择。", isFirst: true) {
        V1SegmentedPicker(
          "外观", selection: $appearanceRawValue,
          options: AppAppearance.allCases.map { .init($0.rawValue, $0.displayName) }
        )
        .fixedSize()
        .runtimeAccessibilityIdentifier("settings.appearance.picker")
      }
      // 只缩放会议正文(转写、纪要),首页与列表按设计系统的字阶不动,标签照实写(owner 2026-09-22)。
      SettingsFormRow("字号", labelDetail: "只调整转写与纪要的正文。") {
        V1SegmentedPicker(
          "字号", selection: $textScaleRawValue,
          options: TextScale.allCases.map { .init($0.rawValue, $0.displayName) }
        )
        .fixedSize()
        .runtimeAccessibilityIdentifier("settings.text-scale.picker")
      }
    }
    .runtimeAccessibilityIdentifier("settings.appearance")
  }
}

// MARK: - 麦克风回声消除（AEC / VPIO）

private struct MicrophoneAECSettingsCard: View {
  // 默认值必须与 `MicrophoneAECSettings.isEnabled` 的键缺失分支一致(默认关),
  // 否则 UI 显示与实际采集路由打架。
  @AppStorage(MicrophoneAECSettings.defaultsKey) private var aecEnabled = false

  var body: some View {
    SettingsFormGroup(
      "麦克风采集", hint: "设置录制时的麦克风采集方式。"
    ) {
      // 「实验性功能」走 labelDetail(标签下的小字),不要并进标签本身——
      // 标签列定宽 112,「回声消除（实验性功能）」会折成两行,
      // 而那正是 owner 一开始就指出的毛病(2026-09-21)。
      SettingsFormRow("回声消除", labelDetail: "实验性功能", isFirst: true) {
        Toggle("回声消除", isOn: $aecEnabled)
          .toggleStyle(.v1Switch)
          .labelsHidden()
          .help("开了它，别的会议软件里对方可能听不到你")
          .runtimeAccessibilityIdentifier("settings.microphone-aec")
      }

    }
    .runtimeAccessibilityIdentifier("settings.microphone")
  }
}

// MARK: - 音频保留期

private struct AudioRetentionSettingsCard: View {
  @AppStorage(AudioRetentionPolicy.defaultsKey) private var policyRaw =
    AudioRetentionPolicy.never.rawValue

  var body: some View {
    SettingsFormGroup(
      "音频保留期", hint: "到期删除已精转会议的音频，转写和纪要留下。"
    ) {
      SettingsFormRow("保留录音", isFirst: true) {
        V1Dropdown(
          value: (AudioRetentionPolicy(rawValue: policyRaw) ?? .never).displayName,
          identifier: "settings.audio-retention.picker"
        ) {
          ForEach(AudioRetentionPolicy.allCases) { policy in
            Button(policy.displayName) { policyRaw = policy.rawValue }
          }
        }
        .frame(width: Tokens.V1.Size.settingsModelField)
        .onChange(of: policyRaw) { _, _ in
          DispatchQueue.global(qos: .utility).async {
            AudioRetentionScheduler.shared.sweepIfNeeded(
              meetingsRoot: MeetingStore.defaultRootDirectory(),
              diagnosticsRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("JustSaid", isDirectory: true)
                .appendingPathComponent("diagnostics", isDirectory: true),
              defaults: .standard,
              force: true
            )
          }
        }
      }
    }
    .runtimeAccessibilityIdentifier("settings.audio-retention")
  }
}

// MARK: - 全局热键(标记重点 / 闲聊 / 暂停麦克风)

private struct GlobalHotkeySettingsCard: View {
  @ObservedObject private var manager = GlobalHotkeyManager.shared

  var body: some View {
    SettingsFormGroup(
      "全局热键", hint: "录制中，在其他应用前台也能用。"
    ) {
      ForEach(Array(GlobalHotkeyAction.allCases.enumerated()), id: \.element) { index, action in
        GlobalHotkeyRow(action: action, manager: manager, isFirst: index == 0)
      }
    }
    .runtimeAccessibilityIdentifier("settings.global-hotkeys")
    .onDisappear {
      manager.cancelCapture()
    }
  }
}

private struct GlobalHotkeyRow: View {
  let action: GlobalHotkeyAction
  @ObservedObject var manager: GlobalHotkeyManager
  var isFirst = false

  private var isCapturingThis: Bool { manager.capturingAction == action }
  private var chord: MarkHotkeyChord { manager.configuration(for: action) }

  var body: some View {
    // 没改过键时,原来同一件事说四遍:标签下「默认 ⌥⌘M」、键帽「⌥⌘M」、
    // 「点击改键」、还有一颗「恢复默认」。「默认 X」只在**你改过**之后才有信息
    // (它回答「本来是什么」);没改过时它和键帽一字不差(owner 2026-09-21)。
    SettingsFormRow(
      action.title,
      labelDetail: chord == action.defaultChord ? nil : "默认 \(action.defaultLabel)",
      isFirst: isFirst
    ) {
      HStack(spacing: Tokens.V1.Space.sm) {
        Button {
          if isCapturingThis {
            manager.cancelCapture()
          } else {
            manager.beginCapture(action)
          }
        } label: {
          Text(isCapturingThis ? "按下新的组合键…" : (chord.isEnabled ? chord.displayLabel : "已停用"))
            .font(Tokens.V1.Text.body.font.monospaced())
            .foregroundStyle(isCapturingThis ? Tokens.V1.Color.accent : Tokens.V1.Color.ink2)
            .fixedSize()
            .frame(minWidth: Tokens.V1.Size.settingsLabel - Tokens.V1.Space.sm * 2)
        }
        .buttonStyle(.v1Outline)
        .runtimeAccessibilityIdentifier("\(action.accessibilityPrefix).keycap")
        .help(chord.isEnabled ? "点击改键" : "点击设置快捷键")
        .runtimeAccessibilityIdentifier("\(action.accessibilityPrefix).recorder")

        Menu {
          Button("恢复默认") { manager.restoreDefault(action) }
            .disabled(chord == action.defaultChord)
            .runtimeAccessibilityIdentifier("\(action.accessibilityPrefix).restore")
          Button("停用") { manager.disable(action) }
            .disabled(!chord.isEnabled)
            .runtimeAccessibilityIdentifier("\(action.accessibilityPrefix).disable")
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: Tokens.V1.Space.sm)
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(.v1Outline)
        .accessibilityLabel("\(action.title)选项")
        .runtimeAccessibilityIdentifier("\(action.accessibilityPrefix).menu")
      }

      if isCapturingThis, let hint = manager.captureHint {
        Text(hint)
          .font(.system(size: Tokens.V1.Text.meta.size))
          .foregroundStyle(Tokens.V1.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let status = manager.statusMessage(for: action) {
        Group {
          if manager.statusIsError(for: action) {
            HintText(text: status)
          } else {
            Text(status)
              .font(.system(size: Tokens.V1.Text.meta.size))
              .foregroundStyle(Tokens.V1.Color.ink3)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .runtimeAccessibilityIdentifier("\(action.accessibilityPrefix).status")
      }
    }
    .runtimeAccessibilityIdentifier(action.accessibilityPrefix)
  }
}

// MARK: - 诊断包

private struct DiagnosticsExportCard: View {
  let settingsStore: ProviderSettingsStore?
  @State private var statusMessage: String?
  @State private var statusIsError = false

  var body: some View {
    SettingsFormGroup(
      "诊断", hint: "导出诊断包，帮助定位问题。"
    ) {
      SettingsFormRow("诊断包", labelDetail: "不含会议内容与密钥。", isFirst: true) {
        Button("导出…") {
          exportPackage()
        }
        .buttonStyle(.v1Outline)
        .help("包内只有哨兵日志、构建标识、设置快照（密钥只写已配置/末四位）和本机系统信息。")
        .runtimeAccessibilityIdentifier("settings.diagnostics-export")
        // 导出结果贴在按钮旁边,不另起一行:它是这次点击的回执,不是一条常驻状态。
        if let statusMessage {
          Text(statusMessage)
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(statusIsError ? Tokens.V1.Color.warn : Tokens.V1.Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .runtimeAccessibilityIdentifier("settings.diagnostics-export.status")
        }
      }
    }
    .runtimeAccessibilityIdentifier("settings.diagnostics")
  }

  private func exportPackage() {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.zip]
    panel.nameFieldStringValue = DiagnosticsPackageBuilder.defaultFileName()
    panel.message = "诊断包不含会议内容与密钥"
    panel.prompt = "导出"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let snapshot: String
      if let settingsStore {
        snapshot = DiagnosticsSettingsSnapshot.render(store: settingsStore)
      } else {
        snapshot = "设置快照不可用（设置页未注入 ProviderSettingsStore）\n"
      }
      let builder = DiagnosticsPackageBuilder(settingsSnapshotText: snapshot)
      let report = try builder.export(to: url)
      statusIsError = false
      if report.notes.isEmpty {
        statusMessage = "已导出"
      } else {
        statusMessage = "已导出（\(report.notes.joined(separator: "；"))）"
      }
    } catch {
      statusIsError = true
      statusMessage = error.localizedDescription
    }
  }
}
