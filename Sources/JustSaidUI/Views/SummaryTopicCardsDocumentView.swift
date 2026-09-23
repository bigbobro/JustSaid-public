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
    LazyVStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      ForEach(topics) { topic in
        // 外框与「这场会」的块同款:细边 + paper-2 + 大圆角,标题在块内。
        // 用 background(_:in:) + strokeBorder 而不是 background + clipShape——后者会把
        // 这一块推到离屏图层,文字的次像素抗锯齿被关掉,看着发糊(owner 2026-09-20)。
        SummaryTopicCardView(
          topic: topic,
          // 原来每个话题一个色相(chapterAccent(index))。色相在这里不承载任何含义——
          // 话题的先后顺序不是语义;而且超过六个就开始撞色,色盲看不出,暗色下饱和度也塌。
          // 同完整转写的说话人配色 2026-09-20 一起退役。这道竖条只留一个区分:
          // 「还在聊」用强调色,已沉淀的用中性灰。
          accent: Tokens.V1.Color.ink4,
          isHighlighted: false,
          fontSize: textScale.size(Tokens.FontSize.body),
          openSourceBulletID: $openSourceBulletID,
          onSaveSourceAsNote: nil,
          onJumpToTranscript: onJumpToTranscript,
          chromeless: true
        )
        .padding(Tokens.V1.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Tokens.V1.Color.paper2,
          in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg))
        .overlay {
          RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
            .strokeBorder(
              topic.isInProgress ? Tokens.V1.Color.accent : Tokens.V1.Color.rule,
              lineWidth: Tokens.V1.Size.controlRuleWidth)
        }
      }
    }
    // 会中记录是整栏工作区：可视化需要利用详情栏的剩余宽度，避免在明明放得下时
    // 先被 780pt 阅读限宽挤出横向滚动。独立的一页纸/留痕卡仍保留舒适行长。
    .frame(
      maxWidth: embedded ? .infinity : Tokens.Layout.typedSummaryContentWidth,
      alignment: .leading
    )
    .padding(.horizontal, Tokens.V1.Space.lg)
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
