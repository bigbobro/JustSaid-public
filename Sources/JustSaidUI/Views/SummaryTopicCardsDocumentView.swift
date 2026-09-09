import JustSaidCore
import SwiftUI

/// 已保存留痕与会中整理区共用同一张类型化话题卡；旧会议由 Core 的保守解析器
/// 退化成要点卡，新会议优先读取 JSON sidecar 并保留六原语与修订/分歧状态。
struct SummaryTopicCardsDocumentView: View {
  let topics: [SummaryTopic]
  let emptyHint: String
  let onJumpToTranscript: (TimeInterval) -> Void
  var scrollOffset: Binding<CGFloat>? = nil
  /// 嵌进会中记录页外层滚动时不再自建 ScrollView。
  var embedded: Bool = false

  @Environment(\.textScale) private var textScale
  @State private var openSourceBulletID: UUID?

  private var cardsStack: some View {
    LazyVStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
        SummaryTopicCardView(
          topic: topic,
          accent: Tokens.Color.chapterAccent(index),
          isHighlighted: false,
          fontSize: textScale.size(Tokens.FontSize.body),
          openSourceBulletID: $openSourceBulletID,
          onSaveSourceAsNote: nil,
          onJumpToTranscript: onJumpToTranscript
        )
      }
    }
    // 会中记录是整栏工作区：可视化需要利用详情栏的剩余宽度，避免在明明放得下时
    // 先被 780pt 阅读限宽挤出横向滚动。独立的一页纸/留痕卡仍保留舒适行长。
    .frame(
      maxWidth: embedded ? .infinity : Tokens.Layout.typedSummaryContentWidth,
      alignment: .leading
    )
    .padding(Tokens.Spacing.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var body: some View {
    if topics.isEmpty {
      Text(emptyHint)
        .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
        .foregroundStyle(Tokens.Color.ink3)
        .multilineTextAlignment(embedded ? .leading : .center)
        .frame(
          maxWidth: embedded ? .infinity : Tokens.Layout.emptyStateContentWidth,
          maxHeight: embedded ? nil : .infinity,
          alignment: embedded ? .leading : .center
        )
        .padding(Tokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity)
    } else if embedded {
      cardsStack
        .runtimeAccessibilityIdentifier("library.typed-summary-cards")
    } else {
      ScrollView {
        cardsStack
      }
      .rememberedScrollOffset(scrollOffset)
      .runtimeAccessibilityIdentifier("library.typed-summary-cards")
    }
  }
}
