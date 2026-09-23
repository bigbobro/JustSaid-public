import JustSaidCore
import SwiftUI

/// 会中/会后共用章节目录：含图表标记，点击后由调用方决定滚动目标。
/// public 与横幅同理：headless 验证弹不出 popover，只能把它单独摆进一页布局探针。
public struct ChapterDirectoryView: View {
  let topics: [SummaryTopic]
  let nowCoveredLabel: String?
  /// 会后看转写时,一行标题回答不了「凭什么这是一章」,点进去只能落到第一句
  /// (owner 2026-09-20)。话题自己的要点就是答案,它一直在数据里,只是没画出来。
  /// 会中那一份目录是边聊边长的,要点还在变,所以默认关,只有会后的转写页打开。
  let showsBullets: Bool
  let onSelectTopic: (UUID) -> Void

  public init(
    topics: [SummaryTopic],
    nowCoveredLabel: String? = nil,
    showsBullets: Bool = false,
    onSelectTopic: @escaping (UUID) -> Void
  ) {
    self.topics = topics
    self.nowCoveredLabel = nowCoveredLabel
    self.showsBullets = showsBullets
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
          VStack(alignment: .leading, spacing: .zero) {
            row(
              color: Tokens.Color.chapterAccent(index),
              title: topic.title,
              rangeLabel: topic.timeRangeLabel,
              hasVisualization: topic.hasVisualization,
              isAccent: false
            )
            if showsBullets {
              bullets(topic)
            }
          }
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

  /// 这一章聊了什么:最多三条要点。三条以上再列就成了第二份纪要,
  /// 目录的活是让你决定跳不跳,不是替代正文。
  @ViewBuilder
  private func bullets(_ topic: SummaryTopic) -> some View {
    let lines = topic.bullets.prefix(3)
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        ForEach(lines) { bullet in
          Text(bullet.text.plainText)
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if topic.bullets.count > lines.count {
          Text("还有 \(topic.bullets.count - lines.count) 条")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink4)
        }
      }
      .padding(.leading, Tokens.Spacing.xl + Tokens.V1.Space.md)
      .padding(.trailing, Tokens.Spacing.xl)
      .padding(.bottom, Tokens.V1.Space.xs)
      .runtimeAccessibilityIdentifier("chapter.bullets")
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
