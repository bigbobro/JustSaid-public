import AVKit
import JustSaidCore
import SwiftUI

struct EchoReductionSheet: View {
  let item: MeetingLibraryItem
  @ObservedObject var libraryModel: MeetingLibraryModel
  @StateObject private var model: EchoReductionModel
  @Environment(\.dismiss) private var dismiss

  init(item: MeetingLibraryItem, libraryModel: MeetingLibraryModel) {
    self.item = item
    self.libraryModel = libraryModel
    _model = StateObject(
      wrappedValue: EchoReductionModel(
        directory: item.paths.directory,
        microphoneURL: item.paths.microphoneAudio,
        canChange: { [weak libraryModel] in
          guard let libraryModel else { return false }
          return EchoReductionModel.canChange(item, in: libraryModel)
        }
      ))
  }

  private var canChange: Bool { EchoReductionModel.canChange(item, in: libraryModel) }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
        Text("减少外放串音")
          .font(.system(size: Tokens.FontSize.headline, weight: .semibold))
        Text(item.title)
          .font(.system(size: Tokens.FontSize.body, weight: .medium))
          .foregroundStyle(Tokens.Color.ink2)
          .lineLimit(2)
        Text("实验功能。在本机生成麦克风处理副本，原录音保留，不会上传或自动精转。处理可能改变声音，不能保证分清所有发言人。")
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !canChange {
        Text("这场会议正在录制或处理，或没有可处理的双轨录音，暂时不能生成或更改选择。")
          .foregroundStyle(Tokens.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier("echo-reduction.busy")
      }

      if model.isLoading {
        HStack {
          BreathingDots()
          Text("正在检查已有副本…")
        }
        .runtimeAccessibilityIdentifier("echo-reduction.loading")
      } else if model.isGenerating {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
          HStack {
            Text("正在本机生成副本…")
            Spacer()
            Text(model.progress, format: .percent.precision(.fractionLength(0)))
              .monospacedDigit()
          }
          ProgressView(value: model.progress)
            .runtimeAccessibilityIdentifier("echo-reduction.progress")
          Button("取消生成") { model.cancel() }
            .buttonStyle(.textAction)
            .runtimeAccessibilityIdentifier("echo-reduction.cancel")
        }
      }

      if model.report != nil {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
          HStack(spacing: Tokens.Spacing.sm) {
            Button("试听原始麦克风") { model.play(.original) }
              .buttonStyle(.toolbarPill)
              .runtimeAccessibilityIdentifier("echo-reduction.play-original")
            Button("试听处理副本") { model.play(.processed) }
              .buttonStyle(.toolbarPill)
              .runtimeAccessibilityIdentifier("echo-reduction.play-processed")
          }
          .disabled(model.isBusy)
          if let preview = model.preview {
            Text("正在试听：\(preview.rawValue)")
              .foregroundStyle(Tokens.Color.ink3)
            EchoReductionPlayer(player: model.player)
              .frame(minHeight: Tokens.Spacing.xxl + Tokens.Spacing.xl)
              .runtimeAccessibilityIdentifier("echo-reduction.player")
          }
          Text(model.isEnabled ? "下次精转：使用处理副本" : "下次精转：使用原录音")
            .fontWeight(.semibold)
            .runtimeAccessibilityIdentifier("echo-reduction.selection")
          if model.isEnabled {
            Button("恢复使用原录音") { model.setEnabled(false) }
              .buttonStyle(.toolbarPill)
              .disabled(model.isBusy || !canChange)
              .runtimeAccessibilityIdentifier("echo-reduction.restore")
          } else {
            Toggle("已试听，确认本人发言完整", isOn: $model.confirmedSpeech)
              .toggleStyle(.checkbox)
              .disabled(model.isBusy || !canChange)
              .runtimeAccessibilityIdentifier("echo-reduction.confirm-speech")
            Button("下次精转使用此副本") { model.setEnabled(true) }
              .buttonStyle(.toolbarPillAccent)
              .disabled(model.isBusy || !canChange || !model.confirmedSpeech)
              .runtimeAccessibilityIdentifier("echo-reduction.enable")
          }
          Text("这里只选择输入，不更改已有转写。重新精转仍需另行确认，并按全时长计费。")
            .foregroundStyle(Tokens.Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let error = model.errorMessage {
        Text(error)
          .foregroundStyle(Tokens.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .runtimeAccessibilityIdentifier("echo-reduction.error")
        if model.report == nil {
          Button("恢复使用原录音") { model.setEnabled(false) }
            .buttonStyle(.textAction)
            .disabled(model.isBusy || !canChange)
        }
      }
      if let notice = model.notice {
        Text(notice)
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier("echo-reduction.notice")
      }

      HStack {
        if !model.isEnabled {
          Button(model.report == nil ? "生成处理副本" : "重新生成副本") { model.generate() }
            .buttonStyle(.toolbarPill)
            .disabled(model.isBusy || !canChange)
            .runtimeAccessibilityIdentifier("echo-reduction.generate")
        }
        if model.isSaving { BreathingDots() }
        Spacer(minLength: Tokens.Spacing.sm)
        Button(model.isGenerating ? "取消并关闭" : "关闭") {
          model.cancel()
          dismiss()
        }
        .buttonStyle(.toolbarPill)
        .disabled(model.isSaving)
        .keyboardShortcut(.cancelAction)
      }
    }
    .font(.system(size: Tokens.FontSize.bodyMinimum))
    .foregroundStyle(Tokens.Color.ink)
    .padding(Tokens.Spacing.xxl)
    .frame(
      minWidth: Tokens.Layout.libraryDetailMinWidth, idealWidth: Tokens.Layout.historyContentWidth
    )
    .background(Tokens.Color.card)
    .interactiveDismissDisabled(model.isBusy)
    .runtimeAccessibilityIdentifier("echo-reduction.sheet")
    .onAppear { model.load() }
    .onDisappear { model.cancel() }
  }
}

private struct EchoReductionPlayer: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .inline
    view.showsFullScreenToggleButton = false
    view.player = player
    return view
  }

  func updateNSView(_ nsView: AVPlayerView, context: Context) {
    nsView.player = player
  }
}
