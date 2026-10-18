import Foundation
import JustSaidCore
import SwiftUI

/// 会中速记组里「转写引擎」下一行「Pro 模式」(PR-10)。各态与点开关做什么由 `ProModeSwitchState` 定,
/// 这里只负责画与执行。下载与校验都在这一行里发生,不跳转、不弹窗;离开设置页不打断下载。
public struct ProModeSettingsRow: View {
  @ObservedObject var manager: LocalModelAssetManager
  @ObservedObject var settingsStore: ProviderSettingsStore
  let isRecording: Bool
  let memoryGB: Int
  @Environment(\.settingsCardLayout) private var cardLayout

  private static let capabilityID = LocalModelKnownIDs.qwenLivePro

  public init(
    manager: LocalModelAssetManager,
    settingsStore: ProviderSettingsStore,
    isRecording: Bool,
    memoryGB: Int = ProModeSwitchState.memoryGB(
      physicalMemory: ProcessInfo.processInfo.physicalMemory)
  ) {
    self.manager = manager
    self.settingsStore = settingsStore
    self.isRecording = isRecording
    self.memoryGB = memoryGB
  }

  private var state: ProModeSwitchState {
    let job = ProModeSwitchState.job(
      from: manager.preparation, proCapabilityID: Self.capabilityID)
    var otherJobRunning = manager.isBusy
    if case .downloading = job { otherJobRunning = false }
    return ProModeSwitchState(
      .init(
        intent: settingsStore.liveProModeEnabled,
        proStatus: manager.snapshot(forCapabilityID: Self.capabilityID)?.status,
        job: job,
        otherJobRunning: otherJobRunning,
        isRecording: isRecording,
        memoryGB: memoryGB))
  }

  public var body: some View {
    let state = self.state
    VStack(alignment: .leading, spacing: .zero) {
      SettingsFormRow("Pro 模式", labelDetail: state.labelDetail) {
        if state.showsCancel {
          Button("取消") { cancel() }
            .buttonStyle(.v1Quiet)
            .runtimeAccessibilityIdentifier("settings.pro-mode.cancel")
        }
        if state.showsNeedsRepair {
          Text(ProModeSwitchState.needsRepairText)
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.warn)
            .runtimeAccessibilityIdentifier("settings.pro-mode.needs-repair")
        }
        Toggle(
          "Pro 模式",
          isOn: Binding(get: { state.isOn }, set: { _ in toggle(state.toggleAction) })
        )
        .toggleStyle(.v1Switch)
        .labelsHidden()
        .disabled(!state.isEnabled)
        .runtimeAccessibilityIdentifier(
          state.isEnabled ? "settings.pro-mode.switch" : "settings.pro-mode.switch.disabled")
      }
      if state.showsProgress {
        // 同首页「正在准备本机模型」那条:知道总量画确定进度,不知道画不定进度;不显示百分比。
        Group {
          if let progress = state.progress {
            ProgressView(value: progress)
          } else {
            ProgressView()
          }
        }
        .progressViewStyle(.linear)
        .controlSize(.small)
        .padding(.horizontal, cardLayout ? Tokens.V1.Space.md : Tokens.V1.Space.sm)
        .padding(.bottom, Tokens.V1.Space.xs)
        .runtimeAccessibilityIdentifier("settings.pro-mode.progress")
      }
      if let note = state.failureNote {
        SettingsFormNote(note, tone: .warn)
          .runtimeAccessibilityIdentifier("settings.pro-mode.failure")
      }
    }
    .runtimeAccessibilityIdentifier("settings.pro-mode")
    .runtimeAccessibilityIdentifier(
      "settings.pro-mode.state.\(state.phase.rawValue).\(state.isOn ? "on" : "off")"
    )
    // 失败说明在下一次切换或离开页面时消失。
    .onDisappear { manager.dismissPreparationFailure(capabilityID: Self.capabilityID) }
  }

  private func toggle(_ action: ProModeSwitchState.ToggleAction?) {
    guard let action else { return }
    manager.dismissPreparationFailure(capabilityID: Self.capabilityID)
    switch action {
    case .enable, .enableJoiningDownload:
      settingsStore.setLiveProMode(true)
    case .enableAndDownload:
      settingsStore.setLiveProMode(true)
      HangSentinel.shared.note("models:settings:pro-mode:download")
      Task { await manager.prepare(capabilityID: Self.capabilityID) }
    case .disable:
      settingsStore.setLiveProMode(false)
    }
  }

  /// 取消:开关回关,小字回到内存行,不出提示。已下部分由下载器保留,下次接着下。
  private func cancel() {
    HangSentinel.shared.note("models:settings:pro-mode:cancel")
    manager.cancelActivePreparation()
    settingsStore.setLiveProMode(false)
  }
}

/// 会中 Pro 模式那一句(PR-10):中性级,没有按钮,不自动收起,散会消失。
/// public 是为了截图装置把它和其他提示摆在一起。
public struct ProModeNotice: View {
  public static let needsRepairText = "本场使用标准识别：Pro 模型需要修复"
  public static let fellBackText = "已改用标准识别继续"

  let fellBack: Bool

  public init(fellBack: Bool) {
    self.fellBack = fellBack
  }

  public var body: some View {
    HintBanner(
      systemImage: "info.circle",
      text: fellBack ? Self.fellBackText : Self.needsRepairText
    ) { EmptyView() }
    .runtimeAccessibilityIdentifier(
      fellBack ? "banner.pro-fell-back" : "banner.pro-standard-needs-repair")
  }
}
