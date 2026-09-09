import JustSaidCore
import SwiftUI

/// 溯源弹层内容（E1）：要点→转写片段。外层用系统原生 `.popover` 呈现——
/// 因此没有沿用 `ui-final-v2.html` 里手绘的绝对定位浮层与关闭按钮（系统弹层自带
/// 点击外部/Esc 关闭），内容排版仍按 tokens 对齐。
/// public 与横幅同理：headless 验证弹不出 popover，只能把它单独摆进一页布局探针。
public struct SourcePopoverView: View {
  let reference: SummarySourceReference
  let onSaveAsNote: (() -> Void)?
  let onJumpToTranscript: () -> Void

  public init(
    reference: SummarySourceReference,
    onSaveAsNote: (() -> Void)?,
    onJumpToTranscript: @escaping () -> Void
  ) {
    self.reference = reference
    self.onSaveAsNote = onSaveAsNote
    self.onJumpToTranscript = onJumpToTranscript
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xsm) {
      Text("来源 · \(reference.sourceLabel) \(reference.rangeLabel)")
        .font(.system(size: Tokens.FontSize.caption, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink4)

      VStack(alignment: .leading, spacing: Tokens.Spacing.xsm) {
        ForEach(reference.lines) { line in
          QuotedLineRow(line: line)
        }
      }

      Divider()

      HStack(spacing: Tokens.Spacing.md) {
        if let onSaveAsNote {
          Button {
            onSaveAsNote()
          } label: {
            HStack(spacing: Tokens.Spacing.xxs) {
              Image(systemName: "flag.fill")
                .accessibilityHidden(true)
              Text("存为补充记录")
            }
          }
          .accessibilityHint("把这段引文写入补充记录，保留原始时间戳")
          .runtimeAccessibilityIdentifier("source.save-note")
        }

        Button {
          onJumpToTranscript()
        } label: {
          Text("跳到转写位置")
        }
        .accessibilityHint("展开转写区并定位到最接近的原文")
        .runtimeAccessibilityIdentifier("source.jump-transcript")
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      .foregroundStyle(Tokens.Color.acDeep)
    }
    .padding(Tokens.Spacing.smd)
    .frame(width: Tokens.Layout.sourcePopoverWidth)
    .runtimeAccessibilityIdentifier("source-popover")
  }
}

private struct QuotedLineRow: View {
  let line: SummaryQuotedLine
  @Environment(\.textScale) private var textScale

  private var speakerColor: Color {
    line.source == .me ? Tokens.Color.me : Tokens.Color.others
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      HStack(spacing: Tokens.Spacing.xs) {
        HStack(spacing: Tokens.Spacing.xxs) {
          Circle().fill(speakerColor).frame(width: 5, height: 5)
          Text(line.source == .me ? "我" : "对方")
            .font(.system(size: Tokens.FontSize.secondary, weight: .bold))
            .foregroundStyle(speakerColor)
        }
        Text(ElapsedTime.shortLabel(line.timestamp))
          .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
          .foregroundStyle(Tokens.Color.ink4)
      }
      Text(line.text)
        .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
        .foregroundStyle(Tokens.Color.inkBody)
    }
    .accessibilityElement(children: .combine)
  }
}
