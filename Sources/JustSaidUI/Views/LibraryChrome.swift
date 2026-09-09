import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

// 2026-08-20 批3 拆分:自 MeetingLibraryView.swift 按 MARK 边界机械迁出,零行为变更。
/// 跨页签 ⏱ 跳转后的临时回程。调用点无条件实例化,`trail == nil` 整条不存在。
public struct LibraryReturnTrailBanner: View {
  public let trail: LibraryReturnTrail?
  public let onBack: () -> Void
  public let onDismiss: () -> Void

  public init(
    trail: LibraryReturnTrail?,
    onBack: @escaping () -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.trail = trail
    self.onBack = onBack
    self.onDismiss = onDismiss
  }

  @ViewBuilder
  public var body: some View {
    if let trail {
      HStack(spacing: Tokens.Spacing.xs) {
        Button(action: onBack) {
          HStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: "chevron.left")
              .accessibilityHidden(true)
            Text("回到 \(trail.sourceTab.title)")
          }
        }
        .buttonStyle(.textAction)
        .runtimeAccessibilityIdentifier("library.return-trail.back")
        Spacer(minLength: 0)
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: Tokens.FontSize.micro, weight: .bold))
        }
        .buttonStyle(.iconHover)
        .accessibilityLabel("关闭回程提示")
        .runtimeAccessibilityIdentifier("library.return-trail.dismiss")
      }
      .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
      .foregroundStyle(Tokens.Color.acDeep)
      .padding(.horizontal, Tokens.Spacing.lg)
      .padding(.vertical, Tokens.Spacing.xs)
      .background(Tokens.Color.acSoft)
      .overlay(alignment: .bottom) { Divider() }
      .runtimeAccessibilityIdentifier("library.return-trail")
    }
  }
}

public struct ActionItemsCopyButton: View {
  private let text: String?
  private let pasteboard: NSPasteboard
  private let onCopy: () -> Void

  public init(
    text: String?,
    pasteboard: NSPasteboard = .general,
    onCopy: @escaping () -> Void = {}
  ) {
    self.text = text
    self.pasteboard = pasteboard
    self.onCopy = onCopy
  }

  public var body: some View {
    Button("复制行动清单") {
      _ = copy()
    }
    .disabled(!isEnabled)
    .runtimeAccessibilityIdentifier("library.copy-actions")
  }

  public var isEnabled: Bool {
    text != nil
  }

  @discardableResult
  public func copy() -> Bool {
    guard let text else { return false }
    pasteboard.clearContents()
    let didCopy = pasteboard.setString(text, forType: .string)
    if didCopy {
      onCopy()
    }
    return didCopy
  }
}

// MARK: - 导入录音表单

struct ImportRecordingForm: View {
  let suggestedTitle: String
  let probe: ExternalRecordingImport.ProbeResult
  let onCancel: () -> Void
  let onConfirm: (String, Date, MeetingLanguage) -> Void

  @State private var title: String = ""
  @State private var startedAt: Date = Date()
  @State private var language: MeetingLanguage = .chinese

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
      Text("导入录音")
        .font(.system(size: Tokens.FontSize.headline, weight: .semibold))
      Text("将作为一场新会议补做精转。音频落在 system 路，说话人会显示为「发言人 N」。")
        .font(.system(size: Tokens.FontSize.uiEmphasis))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)

      LabeledContent("标题") {
        TextField("留空则用「会议」(精转后可自动命名)", text: $title)
          .textFieldStyle(.plain)
          .padding(.horizontal, Tokens.Spacing.xsm)
          .padding(.vertical, Tokens.Spacing.xs)
          .insetPanel()
          .frame(minWidth: 260)
      }
      LabeledContent("开始时间") {
        DatePicker("", selection: $startedAt)
          .labelsHidden()
      }
      LabeledContent("会议语言") {
        Picker("", selection: $language) {
          Text("中文").tag(MeetingLanguage.chinese)
          Text("英文").tag(MeetingLanguage.english)
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
      }

      Group {
        if let duration = probe.durationSeconds {
          Text(
            String(
              format: "探测时长约 %.0f 秒 · 文件 %.1f MB · 格式 %@",
              duration,
              Double(probe.fileSizeBytes) / (1_024 * 1_024),
              probe.audioFormat
            )
          )
        } else {
          Text(
            String(
              format: "未能读出时长(账本将记未知) · 文件 %.1f MB · 格式 %@",
              Double(probe.fileSizeBytes) / (1_024 * 1_024),
              probe.audioFormat
            )
          )
        }
      }
      .font(.system(size: Tokens.FontSize.ui))
      .foregroundStyle(Tokens.Color.ink3)

      if probe.exceedsVolumeGate {
        Text("文件超过 \(ExternalRecordingImport.volumeGateBytes / (1_024 * 1_024)) MB，确认导入后会再提示直传风险。")
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.warn)
      }

      HStack {
        Spacer()
        Button("取消", action: onCancel)
          .buttonStyle(.textAction)
          .keyboardShortcut(.cancelAction)
        Button("导入") {
          onConfirm(title, startedAt, language)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.toolbarPillAccent)
      }
    }
    .padding(Tokens.Spacing.lg)
    .frame(minWidth: 420)
    .onAppear {
      title = suggestedTitle
      startedAt = Date()
    }
  }
}
