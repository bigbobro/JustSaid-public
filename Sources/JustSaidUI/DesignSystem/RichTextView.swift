import JustSaidCore
import SwiftUI

extension SummaryRichText {
  /// 把结构化的富文本片段（design.md 类型化 JSON 的文本载体）转成可直接交给 `Text` 渲染的
  /// `AttributedString`：`.strong` 走 `inlinePresentationIntent`（跟随环境字体加粗），
  /// `.callout` 叠加点名高亮的琥珀底色（V10，全屏唯一暖色）。
  func attributedString(calloutForeground: Color = Tokens.Color.warn) -> AttributedString {
    var result = AttributedString()
    for run in runs {
      var piece = AttributedString(run.text)
      switch run.style {
      case .plain:
        break
      case .strong:
        piece.inlinePresentationIntent = .stronglyEmphasized
      case .callout:
        piece.inlinePresentationIntent = .stronglyEmphasized
        piece.backgroundColor = Tokens.Color.amber
        piece.foregroundColor = calloutForeground
      }
      result += piece
    }
    return result
  }
}

/// 富文本渲染视图：字号/字重由调用方通过 `.font` 环境值控制（配合会议正文阅读缩放），
/// 样式（加粗/高亮）随数据携带，不在视图层重新发明。
struct RichText: View {
  let content: SummaryRichText

  init(_ content: SummaryRichText) {
    self.content = content
  }

  var body: some View {
    Text(content.attributedString())
  }
}
