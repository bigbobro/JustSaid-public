import JustSaidCore
import SwiftUI

/// 会议详情页里 Markdown 类产物(纪要 / 会中总结留痕 / 补充记录)的正文渲染。
///
/// 刻意不引入 Markdown 依赖:落盘的四种产物都是本应用自己写出来的,行级结构固定
/// (`#`/`##`/`###` 标题、`- ` 要点、`| ` 表格、`> ` 引言),按行分派样式就够了,
/// 行内的 `**强调**` 交给 `AttributedString(markdown:)`。
///
/// 完整转写走 `TranscriptDocumentView`:它要按说话人配色、点名字筛选、右键更正说话人,
/// 挤进这套按行分派的渲染里两头不讨好。这里只负责它的空态提示。
struct MeetingDocumentView: View {
  let document: MeetingDocument
  var scrollOffset: Binding<CGFloat>? = nil

  @Environment(\.textScale) private var textScale

  var body: some View {
    if let body = document.body {
      if let structuredMinutes = document.structuredMinutes,
        let structuredView = MinutesStructuredView(
          document: structuredMinutes,
          minutesMarkdown: body,
          onJumpToTranscript: document.onJumpToTranscript
        )
      {
        structuredView.rememberedScrollOffset(scrollOffset)
      } else {
        plainTextBody(body)
      }
    } else {
      VStack(spacing: 0) {
        Text(document.emptyHint)
          .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
          .foregroundStyle(Tokens.Color.ink3)
          .multilineTextAlignment(.center)
          .frame(maxWidth: Tokens.Layout.emptyStateContentWidth)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(Tokens.Spacing.lg)
    }
  }

  private func lines(of text: String) -> [String] {
    text.components(separatedBy: "\n")
  }

  private func plainTextBody(_ body: String) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines(of: body).enumerated()), id: \.offset) { _, line in
          MarkdownLineView(line: line, fontSize: textScale.size(Tokens.FontSize.body))
        }
      }
      .frame(maxWidth: Tokens.Layout.readingContentWidth, alignment: .leading)
      .padding(.horizontal, Tokens.Spacing.lg)
      .padding(.vertical, Tokens.Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .rememberedScrollOffset(scrollOffset)
  }
}

// MARK: - Markdown 行

struct MarkdownLineView: View {
  let line: String
  let fontSize: CGFloat

  var body: some View {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      Color.clear.frame(height: 7)
    } else if trimmed.hasPrefix("### ") {
      styled(String(trimmed.dropFirst(4)), size: fontSize, weight: .semibold, top: 9)
    } else if trimmed.hasPrefix("## ") {
      styled(String(trimmed.dropFirst(3)), size: fontSize + 1, weight: .bold, top: 13)
    } else if trimmed.hasPrefix("# ") {
      styled(String(trimmed.dropFirst(2)), size: fontSize + 2.5, weight: .bold, top: 2)
    } else if trimmed.hasPrefix("> ") {
      Text(String(trimmed.dropFirst(2)))
        .font(.system(size: fontSize - 1))
        .foregroundStyle(Tokens.Color.ink3)
        .padding(.leading, Tokens.Spacing.xsm)
        .overlay(alignment: .leading) {
          Rectangle().fill(Tokens.Color.line).frame(width: 2)
        }
        .padding(.vertical, Tokens.Spacing.hairline)
    } else if trimmed.hasPrefix("|") {
      // 表格行是纪要数据正文(07-29 F3 亮线 ≥12pt):字号随同一档会议正文阅读缩放。
      Text(trimmed)
        .font(.system(size: fontSize - 0.5, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink2)
        .padding(.vertical, Tokens.Spacing.hairline)
    } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
      HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
        Circle()
          .fill(Tokens.Color.ink4)
          .frame(width: 4, height: 4)
          .padding(.top, fontSize * 0.5)
        inline(String(trimmed.dropFirst(2)))
          .font(.system(size: fontSize))
          .foregroundStyle(Tokens.Color.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, Tokens.Spacing.hairline)
    } else {
      inline(trimmed)
        .font(.system(size: fontSize))
        .foregroundStyle(Tokens.Color.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Tokens.Spacing.hairline)
    }
  }

  private func styled(
    _ text: String,
    size: CGFloat,
    weight: Font.Weight,
    top: CGFloat
  ) -> some View {
    inline(text)
      .font(.system(size: size, weight: weight))
      .foregroundStyle(Tokens.Color.ink)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, top)
      .padding(.bottom, Tokens.Spacing.hairline)
  }

  /// 行内 `**强调**` / `` `代码` `` 交给系统解析；解析不了就原样显示，不吞内容。
  private func inline(_ text: String) -> Text {
    guard
      let attributed = try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
      )
    else {
      return Text(text)
    }
    return Text(attributed)
  }
}
