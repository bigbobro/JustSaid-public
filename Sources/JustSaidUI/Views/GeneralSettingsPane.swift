import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-20 批4 拆分:自 ProviderSettingsView.swift 机械迁出,零行为变更。
public struct GeneralSettingsPane: View {
  let settingsStore: ProviderSettingsStore?

  public init(settingsStore: ProviderSettingsStore? = nil) {
    self.settingsStore = settingsStore
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
        Text("应用级采集与使用偏好放在这里；不会改变任何模型或渠道选择。")
          .font(.system(size: Tokens.FontSize.bodyMinimum))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
        AppearanceSettingsCard()
        MicrophoneAECSettingsCard()
        AudioRetentionSettingsCard()
        GlobalHotkeySettingsCard()
        DiagnosticsExportCard(settingsStore: settingsStore)
      }
      .padding(Tokens.Spacing.lg)
    }
    .runtimeAccessibilityIdentifier("settings.general")
  }
}

/// 渠道编辑器 sheet 的请求:nil 渠道 = 新建。

// MARK: - 外观

private struct AppearanceSettingsCard: View {
  @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue =
    AppAppearance.system.rawValue

  var body: some View {
    RoleCardShell(title: "外观", subtitle: "选择 JustSaid 的界面显示方式") {
      Picker("外观", selection: $appearanceRawValue) {
        ForEach(AppAppearance.allCases) { appearance in
          Text(appearance.displayName).tag(appearance.rawValue)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .runtimeAccessibilityIdentifier("settings.appearance.picker")

      Text("跟随系统会随 macOS 的浅色/深色模式变化；浅色和深色会立即应用到 JustSaid。")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
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
    RoleCardShell(title: "麦克风采集", subtitle: "回声消除 · 外放会议") {
      Toggle("麦克风回声消除", isOn: $aecEnabled)
        .toggleStyle(.switch)
        .runtimeAccessibilityIdentifier("settings.microphone-aec")

      Text(
        "开启后用系统语音处理（VPIO）从麦克风里去掉扬声器回声；关闭、蓝牙耳机通话，或 VPIO 启动失败时自动回落原采集路径。注意：开启可能影响其他正在使用麦克风的应用（线上会议对方可能听不到你），仅建议独自外放、且不开其他会议软件时开启。"
      )
      .font(.system(size: Tokens.FontSize.ui))
      .foregroundStyle(Tokens.Color.ink3)
      .fixedSize(horizontal: false, vertical: true)
    }
    .runtimeAccessibilityIdentifier("settings.microphone")
  }
}

// MARK: - 音频保留期

private struct AudioRetentionSettingsCard: View {
  @AppStorage(AudioRetentionPolicy.defaultsKey) private var policyRaw =
    AudioRetentionPolicy.never.rawValue

  var body: some View {
    RoleCardShell(title: "音频保留期", subtitle: "到期自动删除已精转会议的音频，转写和纪要留下") {
      Picker("音频保留期", selection: $policyRaw) {
        ForEach(AudioRetentionPolicy.allCases) { policy in
          Text(policy.displayName).tag(policy.rawValue)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .runtimeAccessibilityIdentifier("settings.audio-retention.picker")
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

      Text("默认不删除。只有你选了保留期、且该场已经完成精转，超期后才会删 m4a。")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .runtimeAccessibilityIdentifier("settings.audio-retention")
  }
}

// MARK: - 全局热键(标记重点 / 闲聊 / 暂停麦克风)

private struct GlobalHotkeySettingsCard: View {
  @ObservedObject private var manager = GlobalHotkeyManager.shared

  var body: some View {
    RoleCardShell(title: "全局热键", subtitle: "录制中在其他应用前台也能用") {
      Text("默认与应用内快捷键一致。走系统全局热键接口，不需要辅助功能权限。仅录制中生效。")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
        ForEach(GlobalHotkeyAction.allCases) { action in
          GlobalHotkeyRow(action: action, manager: manager)
        }
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

  private var isCapturingThis: Bool { manager.capturingAction == action }
  private var chord: MarkHotkeyChord { manager.configuration(for: action) }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
      HStack(spacing: Tokens.Spacing.xs) {
        Text(action.title)
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink2)
        Text("默认 \(action.defaultLabel)")
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink3)
      }

      HStack(spacing: Tokens.Spacing.sm) {
        Button {
          if isCapturingThis {
            manager.cancelCapture()
          } else {
            manager.beginCapture(action)
          }
        } label: {
          HStack(spacing: Tokens.Spacing.xs) {
            if isCapturingThis {
              Text("按下新的组合键…")
                .font(.system(size: Tokens.FontSize.body, weight: .medium))
                .foregroundStyle(Tokens.Color.ac)
            } else if chord.isEnabled {
              KeycapView(label: chord.displayLabel)
              Text("点击改键")
                .font(.system(size: Tokens.FontSize.ui))
                .foregroundStyle(Tokens.Color.ink3)
            } else {
              Text("已停用")
                .font(.system(size: Tokens.FontSize.body))
                .foregroundStyle(Tokens.Color.ink3)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, Tokens.Spacing.sm)
          .padding(.vertical, Tokens.Spacing.xs)
          .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.widget)
              .fill(Tokens.Color.surface2)
          )
          .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.widget)
              .stroke(
                isCapturingThis ? Tokens.Color.ac : Tokens.Color.surface2Line,
                lineWidth: 1
              )
          )
        }
        .buttonStyle(.plain)
        // 整块可点(点了开始录键),此前无任何悬停反馈(走查 P-7g)。
        .hoverStrokeOutline(cornerRadius: Tokens.Radius.widget)
        .runtimeAccessibilityIdentifier("\(action.accessibilityPrefix).recorder")

        Button("恢复默认") {
          manager.restoreDefault(action)
        }
        .buttonStyle(.textAction)
        .disabled(chord == action.defaultChord)
        .runtimeAccessibilityIdentifier("\(action.accessibilityPrefix).restore")

        Button("停用") {
          manager.disable(action)
        }
        .buttonStyle(.textAction)
        .disabled(!chord.isEnabled)
        .runtimeAccessibilityIdentifier("\(action.accessibilityPrefix).disable")
      }

      if isCapturingThis, let hint = manager.captureHint {
        Text(hint)
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let status = manager.statusMessage(for: action) {
        Group {
          if manager.statusIsError(for: action) {
            HintText(text: status)
          } else {
            Text(status)
              .font(.system(size: Tokens.FontSize.ui))
              .foregroundStyle(Tokens.Color.ink3)
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
    RoleCardShell(title: "诊断", subtitle: "出问题时把现场发回来，不含会议内容与密钥") {
      Text(ProviderSettingsView.buildLabel)
        .font(.system(size: Tokens.FontSize.ui, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink3)
        .textSelection(.enabled)
        .accessibilityLabel("构建标识 \(ProviderSettingsView.buildLabel)")

      Button("导出诊断包") {
        exportPackage()
      }
      .buttonStyle(.toolbarPill)
      .runtimeAccessibilityIdentifier("settings.diagnostics-export")

      Text("包内只有哨兵日志、构建标识、设置快照（密钥只写已配置/末四位）和本机系统信息。")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)

      if let statusMessage {
        Text(statusMessage)
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(statusIsError ? Tokens.Color.warn : Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier("settings.diagnostics-export.status")
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
