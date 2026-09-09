import JustSaidCore
import SwiftUI

/// 会中/会后共用章节目录：含图表标记，点击后由调用方决定滚动目标。
/// public 与横幅同理：headless 验证弹不出 popover，只能把它单独摆进一页布局探针。
public struct ChapterDirectoryView: View {
  let topics: [SummaryTopic]
  let nowCoveredLabel: String?
  let onSelectTopic: (UUID) -> Void

  public init(
    topics: [SummaryTopic],
    nowCoveredLabel: String? = nil,
    onSelectTopic: @escaping (UUID) -> Void
  ) {
    self.topics = topics
    self.nowCoveredLabel = nowCoveredLabel
    self.onSelectTopic = onSelectTopic
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if topics.isEmpty {
        Text("还没有归纳出话题")
          .font(.system(size: Tokens.FontSize.bodyMinimum))
          .foregroundStyle(Tokens.Color.ink3)
          .padding(Tokens.Spacing.md)
      } else if topics.count > 12 {
        ScrollView {
          topicRows
        }
        .frame(height: Tokens.Layout.windowMinHeight - Tokens.Layout.toolbarHeight * 2)
      } else {
        topicRows
      }
    }
    .padding(.vertical, Tokens.Spacing.xs)
    .frame(width: Tokens.Layout.chapterDirectoryWidth)
    .runtimeAccessibilityIdentifier("chapter-directory")
  }

  @ViewBuilder
  private var topicRows: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
        Button {
          onSelectTopic(topic.id)
        } label: {
          row(
            color: Tokens.Color.chapterAccent(index),
            title: topic.title,
            rangeLabel: topic.timeRangeLabel,
            hasVisualization: topic.hasVisualization,
            isAccent: false
          )
        }
        .buttonStyle(.plain)
        .hoverRowBackground()
        .accessibilityLabel("\(topic.title)，\(topic.timeRangeLabel)")
        .runtimeAccessibilityIdentifier("chapter.row-\(index)")
      }

      if let nowCoveredLabel {
        row(
          color: Tokens.Color.ac,
          title: "当前正在聊",
          rangeLabel: nowCoveredLabel,
          hasVisualization: false,
          isAccent: true
        )
        .runtimeAccessibilityIdentifier("chapter.now")
      }
    }
  }

  private func row(
    color: Color,
    title: String,
    rangeLabel: String,
    hasVisualization: Bool,
    isAccent: Bool
  ) -> some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(title)
        .font(.system(size: Tokens.FontSize.body, weight: isAccent ? .semibold : .regular))
        .foregroundStyle(isAccent ? Tokens.Color.ac : Tokens.Color.ink)
        .lineLimit(1)
        .help(title)
      if hasVisualization {
        ChapterVisualizationTag()
      }
      Spacer()
      Text(rangeLabel)
        .font(.system(size: Tokens.FontSize.caption, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink4)
    }
    .padding(.horizontal, Tokens.Spacing.xl)
    .padding(.vertical, Tokens.Spacing.xs)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

/// 会后章节只认落盘话题时间范围的下界，不从标题或正文猜时间。
/// public：验证程序可直接钉住合法/非法范围的导航边界。
public enum ChapterNavigation {
  public static func startSeconds(for topic: SummaryTopic) -> TimeInterval? {
    ExclusionUI.topicRangeSeconds(topic.timeRangeLabel)?.lowerBound
  }
}
