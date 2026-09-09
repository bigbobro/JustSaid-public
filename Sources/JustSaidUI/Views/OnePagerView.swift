import AppKit
import JustSaidCore
import SwiftUI

/// 会后详情的默认首屏。结构化 sidecar 可用时忠实呈现六原语；旧会议只显示
/// 从现有纪要保守提取的要点，不反推结论类型、负责人或转写锚点。
struct OnePagerView: View {
  let document: MeetingMinutesDocument
  let isLegacyFallback: Bool
  /// 落盘留痕话题，只用于给既有 topicTrail 证明章节起点；不改写一页纸内容。
  let topics: [SummaryTopic]
  let onJumpToTranscript: (TimeInterval) -> Void
  var scrollOffset: Binding<CGFloat>? = nil

  @Environment(\.textScale) private var textScale

  init(
    document: MeetingMinutesDocument,
    isLegacyFallback: Bool,
    topics: [SummaryTopic] = [],
    onJumpToTranscript: @escaping (TimeInterval) -> Void,
    scrollOffset: Binding<CGFloat>? = nil
  ) {
    self.document = document
    self.isLegacyFallback = isLegacyFallback
    self.topics = topics
    self.onJumpToTranscript = onJumpToTranscript
    self.scrollOffset = scrollOffset
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: Tokens.Spacing.md) {
        if !document.topicTrail.isEmpty {
          HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xsm) {
            Text("话题脉络")
              .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
              .foregroundStyle(Tokens.Color.ink3)
            OnePagerTopicTrailLayout {
              ForEach(Array(document.topicTrail.enumerated()), id: \.offset) { index, item in
                HStack(spacing: Tokens.Spacing.xs) {
                  topicTrailItem(item, index: index)
                  if index < document.topicTrail.count - 1 {
                    Image(systemName: "arrow.right")
                      .font(.system(size: textScale.size(Tokens.FontSize.micro)))
                      .foregroundStyle(Tokens.Color.ink4)
                      .accessibilityHidden(true)
                  }
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .runtimeAccessibilityIdentifier("one-page.topic-trail")
        }
        if isLegacyFallback {
          legacyNotice
        }
        if !orderedConclusions.isEmpty || !document.decisions.isEmpty {
          conclusionsBand
        }
        skeletonSection
        actionAndOpenWorkRow
      }
      .padding(Tokens.Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .rememberedScrollOffset(scrollOffset)
    .background(Tokens.Color.card)
    .runtimeAccessibilityIdentifier("library.one-page")
  }

  /// 只给能由同名留痕或纪要自身锚定讨论证明位置的项补点击；拿不准就保持文字。
  @ViewBuilder
  private func topicTrailItem(_ item: String, index: Int) -> some View {
    if let seconds = OnePagerTopicNavigation.startSeconds(
      for: item,
      in: topics,
      anchoredDiscussions: document.keyDiscussions
    ) {
      Button(item) {
        onJumpToTranscript(seconds)
      }
      .buttonStyle(.textAction)
      .font(.system(size: textScale.size(Tokens.FontSize.ui)))
      .foregroundStyle(Tokens.Color.acDeep)
      .help("跳到完整转写 \(TranscriptAnchor(seconds: seconds).timecode)")
      .runtimeAccessibilityIdentifier("one-page.topic-trail.item-\(index)")
    } else {
      Text(item)
        .font(.system(size: textScale.size(Tokens.FontSize.ui)))
        .foregroundStyle(Tokens.Color.ink2)
        .runtimeAccessibilityIdentifier("one-page.topic-trail.unavailable-\(index)")
    }
  }

  private var legacyNotice: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      Image(systemName: "list.bullet.rectangle")
        .foregroundStyle(Tokens.Color.ac)
      Text("这场旧会议没有类型化骨架，已退化为纪要要点；原文没有被改写。")
        .font(.system(size: textScale.size(Tokens.FontSize.secondary)))
        .foregroundStyle(Tokens.Color.ink3)
    }
    .padding(.horizontal, Tokens.Spacing.sm)
    .padding(.vertical, Tokens.Spacing.xs)
    .background(Tokens.Color.acSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.widget))
    .runtimeAccessibilityIdentifier("one-page.legacy-fallback")
  }

  private var conclusionsBand: some View {
    sectionCard(
      title: "结论带",
      identifier: "one-page.conclusions",
      count: orderedConclusions.count,
      hero: true
    ) {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xsm) {
        ForEach(orderedConclusions) { conclusion in
          OnePagerHoverCopyRow(
            copyText: OnePagerCopyText.conclusion(conclusion),
            identifier: "one-page.conclusion-copy"
          ) {
            HStack(alignment: .top, spacing: Tokens.Spacing.xsm) {
              ConclusionBadge(kind: conclusion.kind)
              VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(conclusion.content.text)
                  .font(.system(size: textScale.size(Tokens.FontSize.body), weight: .semibold))
                  .foregroundStyle(Tokens.Color.ink)
                  .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Tokens.Spacing.xs) {
                  EvidenceText(mark: conclusion.content.evidence)
                  TranscriptAnchorButton(
                    anchor: conclusion.content.anchor,
                    onJump: onJumpToTranscript
                  )
                }
              }
            }
          }
        }
        if !document.decisions.isEmpty {
          VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            Text("决策对账")
              .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
              .foregroundStyle(Tokens.Color.ink3)
            ForEach(document.decisions) { decision in
              OnePagerHoverCopyRow(
                copyText: OnePagerCopyText.decision(decision),
                identifier: "one-page.decision-copy"
              ) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                  HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                    Text(decision.issue)
                      .font(
                        .system(
                          size: textScale.size(Tokens.FontSize.bodyMinimum),
                          weight: .semibold
                        )
                      )
                      .foregroundStyle(Tokens.Color.ink)
                    TranscriptAnchorButton(
                      anchor: decision.anchor,
                      onJump: onJumpToTranscript
                    )
                  }
                  ForEach(decision.options) { option in
                    HStack(alignment: .top, spacing: Tokens.Spacing.xxs) {
                      Text("\(option.speaker)：")
                        .font(
                          .system(
                            size: textScale.size(Tokens.FontSize.bodyMinimum),
                            weight: .semibold
                          )
                        )
                        .foregroundStyle(Tokens.Color.ink3)
                      Text(option.proposal)
                        .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
                        .foregroundStyle(Tokens.Color.ink2)
                      TranscriptAnchorButton(
                        anchor: option.anchor,
                        onJump: onJumpToTranscript
                      )
                    }
                  }
                  if !decision.rationale.isEmpty {
                    Text("依据：\(decision.rationale)")
                      .font(.system(size: textScale.size(Tokens.FontSize.secondary)))
                      .foregroundStyle(Tokens.Color.ink3)
                  }
                }
                .padding(.top, Tokens.Spacing.hairline)
              }
            }
          }
          .padding(Tokens.Spacing.xsm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Tokens.Color.pane)
          .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.widget)
              .stroke(Tokens.Color.line2, lineWidth: 1)
          )
          .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.widget))
        }
      }
      .frame(maxWidth: Tokens.Layout.readingContentWidth, alignment: .leading)
    }
  }

  @ViewBuilder
  private var skeletonSection: some View {
    let blocks = document.skeleton?.blocks ?? []
    let fallback =
      document.skeleton?.fallbackPoints.isEmpty == false
      ? document.skeleton?.fallbackPoints ?? []
      : document.keyDiscussions

    sectionCard(
      title: "会议骨架",
      identifier: "one-page.skeleton",
      subtitle: document.skeleton?.semanticTemplate.flatMap { $0.isEmpty ? nil : "形态 · \($0)" },
      subtitleIdentifier: "one-page.skeleton-template"
    ) {
      if !blocks.isEmpty {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
          ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            block.makeView(onJumpToTranscript: onJumpToTranscript)
          }
        }
      } else if !fallback.isEmpty {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
          ForEach(Array(fallback.enumerated()), id: \.offset) { _, point in
            AnchoredOnePagerRow(
              content: point,
              onJumpToTranscript: onJumpToTranscript
            )
          }
        }
        .runtimeAccessibilityIdentifier("one-page.skeleton-fallback")
      } else {
        Text("这场会议没有足够可靠的信息形成会议骨架。")
          .font(.system(size: textScale.size(Tokens.FontSize.uiEmphasis)))
          .foregroundStyle(Tokens.Color.ink3)
      }
    }
  }

  @ViewBuilder
  private var actionAndOpenWorkRow: some View {
    let showActions = !orderedActions.isEmpty
    let showOpen = !document.openQuestions.isEmpty
    if showActions && showOpen {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Tokens.Spacing.smd) {
          actionsSection
          openWorkSection
        }
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
          actionsSection
          openWorkSection
        }
      }
    } else if showActions {
      actionsSection
    } else if showOpen {
      openWorkSection
    }
  }

  private var actionsSection: some View {
    sectionCard(
      title: "替你记",
      identifier: "one-page.actions",
      count: orderedActions.count
    ) {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xsm) {
        ForEach(Array(orderedActions.enumerated()), id: \.element.id) { index, item in
          OnePagerHoverCopyRow(
            copyText: OnePagerCopyText.actionItem(index: index, action: item),
            identifier: "one-page.action-copy"
          ) {
            HStack(alignment: .top, spacing: Tokens.Spacing.xsm) {
              Text(item.ownership == .me ? "我的" : "行动")
                .font(.system(size: Tokens.FontSize.badge, weight: .bold))
                .foregroundStyle(
                  item.ownership == .me ? Tokens.Color.acDeep : Tokens.Color.ink3
                )
                .padding(.horizontal, Tokens.Spacing.xs)
                .padding(.vertical, Tokens.Spacing.hairline)
                .background(
                  item.ownership == .me ? Tokens.Color.acSoft : Tokens.Color.cardWash,
                  in: Capsule()
                )
              VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(item.text)
                  .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
                  .foregroundStyle(Tokens.Color.ink)
                  .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Tokens.Spacing.xs) {
                  Text(item.displayOwner)
                    .font(.system(size: Tokens.FontSize.secondary, weight: .medium))
                    .foregroundStyle(Tokens.Color.ink3)
                  EvidenceText(mark: item.evidence)
                  TranscriptAnchorButton(
                    anchor: item.recordedAt,
                    onJump: onJumpToTranscript
                  )
                }
                if let deadline = item.deadline {
                  Text("时限：\(deadline)")
                    .font(.system(size: textScale.size(Tokens.FontSize.secondary)))
                    .foregroundStyle(Tokens.Color.ink3)
                    .runtimeAccessibilityIdentifier("one-page.action-deadline")
                }
                ForEach(item.updates) { update in
                  HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xxs) {
                      Image(systemName: "arrow.turn.down.right")
                        .font(
                          .system(
                            size: textScale.size(Tokens.FontSize.micro),
                            weight: .semibold
                          )
                        )
                        .foregroundStyle(Tokens.Color.ink4)
                        .accessibilityHidden(true)
                      Text(update.text)
                        .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
                        .foregroundStyle(Tokens.Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    TranscriptAnchorButton(
                      anchor: update.anchor,
                      onJump: onJumpToTranscript
                    )
                  }
                }
              }
            }
          }
        }
      }
      .frame(maxWidth: Tokens.Layout.readingContentWidth, alignment: .leading)
    }
  }

  private var openWorkSection: some View {
    sectionCard(
      title: "遗留的活",
      identifier: "one-page.open-work",
      count: document.openQuestions.count
    ) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Tokens.Spacing.xsm) {
          openWorkColumn(kind: .toVerify)
          openWorkColumn(kind: .disagreement)
        }
        VStack(alignment: .leading, spacing: Tokens.Spacing.smd) {
          openWorkColumn(kind: .toVerify)
          openWorkColumn(kind: .disagreement)
        }
      }
      .frame(maxWidth: Tokens.Layout.readingContentWidth, alignment: .leading)
    }
  }

  private func openWorkColumn(
    kind: MeetingOpenItemKind
  ) -> some View {
    let items = document.openQuestions.filter { $0.kind == kind }
    return VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      Text(kind == .toVerify ? "[待核] 等确认" : "⚑ 尚有分歧")
        .font(.system(size: Tokens.FontSize.caption, weight: .bold))
        .foregroundStyle(
          kind == .toVerify ? Tokens.Color.warn : Tokens.Color.disagreement
        )
      if items.isEmpty {
        Text("无")
          .font(.system(size: textScale.size(Tokens.FontSize.secondary)))
          .foregroundStyle(Tokens.Color.ink4)
      } else {
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            Text(item.content.text)
              .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
              .foregroundStyle(Tokens.Color.ink2)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.Spacing.xs) {
              EvidenceText(mark: item.content.evidence)
              TranscriptAnchorButton(
                anchor: item.content.anchor,
                onJump: onJumpToTranscript
              )
            }
          }
          .padding(.vertical, Tokens.Spacing.xxs)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var orderedConclusions: [MeetingConclusion] {
    document.coreConclusions.enumerated().sorted { lhs, rhs in
      let lhsRank = conclusionRank(lhs.element.kind)
      let rhsRank = conclusionRank(rhs.element.kind)
      return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
  }

  private var orderedActions: [SummaryActionItem] {
    SummaryActionItem.mineFirst(document.actionItems)
  }

  private func conclusionRank(_ kind: MeetingConclusionKind) -> Int {
    switch kind {
    case .decision: return 0
    case .consensus: return 1
    case .direction: return 2
    }
  }

  private func sectionCard<Content: View>(
    title: String,
    identifier: String,
    count: Int? = nil,
    subtitle: String? = nil,
    subtitleIdentifier: String? = nil,
    hero: Bool = false,
    @ViewBuilder content: () -> Content
  ) -> some View {
    let shadow = hero ? Tokens.Shadow.sh2 : Tokens.Shadow.sh1
    return VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
      SectionHeaderRow(
        title: title,
        count: count,
        subtitle: subtitle,
        subtitleIdentifier: subtitleIdentifier
      )
      content()
    }
    .padding(Tokens.Spacing.smd)
    .padding(.leading, hero ? Tokens.Spacing.xxs : 0)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tokens.Color.card)
    .overlay(alignment: .leading) {
      if hero {
        Rectangle()
          .fill(Tokens.Color.ac)
          .frame(width: Tokens.Layout.accentEdgeWidth)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
    .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    .runtimeAccessibilityIdentifier(identifier)
  }
}

/// 一页纸话题脉络的保守导航：同名留痕优先；真实产物标题不一致时，只从纪要自身
/// 已落盘的关键讨论锚点里做确定性词项匹配。没有足够文字证据就保持不可点。
/// public：验证程序可直接覆盖同名、锚点兜底与弱匹配三臂。
public enum OnePagerTopicNavigation {
  public static func startSeconds(
    for trailItem: String,
    in topics: [SummaryTopic],
    anchoredDiscussions: [AnchoredText] = []
  ) -> TimeInterval? {
    let title = trailItem.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }

    if let topic = topics.first(where: {
      $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == title
    }),
      let seconds = ChapterNavigation.startSeconds(for: topic)
    {
      return seconds
    }

    let queryTerms = navigationTerms(in: title)
    guard !queryTerms.isEmpty else { return nil }
    let candidates = anchoredDiscussions.compactMap { discussion -> NavigationCandidate? in
      guard let seconds = discussion.anchor?.seconds else { return nil }
      let candidateTerms = navigationTerms(in: discussion.text)
      let asciiMatches = queryTerms.ascii.intersection(candidateTerms.ascii)
      let hanMatches = queryTerms.hanBigrams.intersection(candidateTerms.hanBigrams)
      let score: Int
      if !asciiMatches.isEmpty {
        score = asciiMatches.reduce(0) { $0 + $1.count + 2 } * 4 + hanMatches.count
      } else {
        guard hanMatches.count >= 2 else { return nil }
        score = hanMatches.count
      }
      return NavigationCandidate(seconds: seconds, score: score)
    }
    return candidates.sorted {
      $0.score == $1.score
        ? $0.seconds < $1.seconds
        : $0.score > $1.score
    }.first?.seconds
  }

  private struct NavigationTerms {
    let ascii: Set<String>
    let hanBigrams: Set<String>

    var isEmpty: Bool {
      ascii.isEmpty && hanBigrams.isEmpty
    }
  }

  private struct NavigationCandidate {
    let seconds: TimeInterval
    let score: Int
  }

  private static let ignoredASCIITerms: Set<String> = [
    "and", "are", "for", "from", "in", "into", "of", "on", "that", "the", "this", "to",
    "was", "with",
  ]

  private static let ignoredHanBigrams: Set<String> = [
    "方案", "讨论", "确认", "调整", "内容", "问题", "时间", "应用", "是否", "计划", "反馈",
    "后续", "进行", "相关", "以及", "中的", "后的", "可以", "需要", "实现", "能力", "流程",
    "设备", "范围", "评估", "路径", "会议", "工作", "情况", "关于",
  ]

  private static func navigationTerms(in text: String) -> NavigationTerms {
    let ascii = Set(
      runs(in: text, matching: isASCIIAlphaNumeric)
        .map { $0.lowercased() }
        .filter { $0.count >= 2 && !ignoredASCIITerms.contains($0) }
    )
    let hanBigrams = Set(
      runs(in: text, matching: isHan).flatMap { run -> [String] in
        let characters = Array(run)
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).compactMap { index in
          let bigram = String(characters[index...index + 1])
          return ignoredHanBigrams.contains(bigram) ? nil : bigram
        }
      }
    )
    return NavigationTerms(ascii: ascii, hanBigrams: hanBigrams)
  }

  private static func runs(
    in text: String,
    matching predicate: (Unicode.Scalar) -> Bool
  ) -> [String] {
    var result: [String] = []
    var current = ""
    for scalar in text.unicodeScalars {
      if predicate(scalar) {
        current.append(contentsOf: String(scalar))
      } else if !current.isEmpty {
        result.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      result.append(current)
    }
    return result
  }

  private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 48...57, 65...90, 97...122:
      return true
    default:
      return false
    }
  }

  private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF:
      return true
    default:
      return false
    }
  }
}

/// 单用途换行布局：保持既有“话题 → 话题”阅读顺序，同时让每个话题拥有独立点击热区。
private struct OnePagerTopicTrailLayout: Layout {
  private struct Placement {
    let origin: CGPoint
    let size: CGSize
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    measure(proposedWidth: proposal.width, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let measured = measure(proposedWidth: bounds.width, subviews: subviews)
    for (subview, placement) in zip(subviews, measured.placements) {
      subview.place(
        at: CGPoint(
          x: bounds.minX + placement.origin.x,
          y: bounds.minY + placement.origin.y
        ),
        anchor: .topLeading,
        proposal: ProposedViewSize(placement.size)
      )
    }
  }

  private func measure(
    proposedWidth: CGFloat?,
    subviews: Subviews
  ) -> (size: CGSize, placements: [Placement]) {
    let maximumWidth =
      proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil }
      ?? CGFloat.greatestFiniteMagnitude
    let childProposal = ProposedViewSize(
      width: maximumWidth.isFinite ? maximumWidth : nil,
      height: nil
    )
    var placements: [Placement] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var contentWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(childProposal)
      if x > 0, x + size.width > maximumWidth {
        x = 0
        y += rowHeight + Tokens.Spacing.xxs
        rowHeight = 0
      }
      placements.append(Placement(origin: CGPoint(x: x, y: y), size: size))
      contentWidth = max(contentWidth, x + size.width)
      x += size.width + Tokens.Spacing.xs
      rowHeight = max(rowHeight, size.height)
    }

    return (
      CGSize(
        width: maximumWidth.isFinite ? min(maximumWidth, contentWidth) : contentWidth,
        height: placements.isEmpty ? 0 : y + rowHeight
      ),
      placements
    )
  }
}

/// 一页纸单条复制文本。行动项行口径与 `ActionItemsRenderer.renderPlainText`
/// 逐字相同（含该条更新行）；renderer 无单行 API，这里只在 UI 侧重拼。
enum OnePagerCopyText {
  static func actionItem(index: Int, action: SummaryActionItem) -> String {
    let deadline = action.deadline.map { "（时限：\($0)）" } ?? ""
    let anchor = validTimecode(action.recordedAt).map { "〔回看 \($0)〕" } ?? ""
    var lines = [
      "\(index + 1). [ ] \(action.displayOwner)：\(action.text)\(deadline)\(anchor)"
    ]
    for update in action.updates {
      let updateAnchor = validTimecode(update.anchor).map { "〔回看 \($0)〕" } ?? ""
      lines.append("   更新：\(update.text)\(updateAnchor)")
    }
    return lines.joined(separator: "\n")
  }

  /// 结论正文。拍板/共识/方向与 [待核]/已修正/已确认不混入。
  static func conclusion(_ conclusion: MeetingConclusion) -> String {
    conclusion.content.text
  }

  /// 决策对账一条：议题 + 各方方案 + 依据。无徽标。
  static func decision(_ decision: MeetingDecision) -> String {
    var lines = [decision.issue]
    for option in decision.options {
      lines.append("\(option.speaker)：\(option.proposal)")
    }
    if !decision.rationale.isEmpty {
      lines.append("依据：\(decision.rationale)")
    }
    return lines.joined(separator: "\n")
  }

  private static func validTimecode(_ anchor: TranscriptAnchor?) -> String? {
    guard let anchor, anchor.seconds != nil else { return nil }
    return anchor.timecode
  }
}

/// 行 hover 出复制小钮。钮走 overlay，不挤既有布局；成功反馈对齐 G2：
/// 仅 pasteboard 写入成功后亮「已复制 ✓」，1.5 秒后熄。
private struct OnePagerHoverCopyRow<Content: View>: View {
  let copyText: String
  let identifier: String
  let content: Content

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false
  @State private var didCopy = false
  @State private var resetTask: Task<Void, Never>?

  init(
    copyText: String,
    identifier: String,
    @ViewBuilder content: () -> Content
  ) {
    self.copyText = copyText
    self.identifier = identifier
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .topTrailing) {
        Button(action: copy) {
          Text(didCopy ? "已复制 ✓" : "复制")
            .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
            .foregroundStyle(didCopy ? Tokens.Color.resolved : Tokens.Color.acDeep)
            .padding(.horizontal, Tokens.Spacing.xs)
            .padding(.vertical, Tokens.Spacing.hairline)
            .background(
              (didCopy ? Tokens.Color.resolvedSoft : Tokens.Color.cardWash),
              in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help("复制这条")
        .accessibilityLabel(didCopy ? "已复制" : "复制")
        .runtimeAccessibilityIdentifier(identifier)
        .opacity(isHovering || didCopy ? 1 : 0)
        .allowsHitTesting(isHovering || didCopy)
        .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: didCopy)
      }
      .onHover { hovering in
        isHovering = hovering
      }
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(copyText, forType: .string) else { return }
    didCopy = true
    resetTask?.cancel()
    resetTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      didCopy = false
    }
  }
}

private struct ConclusionBadge: View {
  let kind: MeetingConclusionKind

  var body: some View {
    Text(label)
      .font(.system(size: Tokens.FontSize.badge, weight: .bold))
      .foregroundStyle(foreground)
      .padding(.horizontal, Tokens.Spacing.xs)
      .padding(.vertical, Tokens.Spacing.hairline)
      .background(background, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.chip)
          .stroke(stroke, lineWidth: 1)
      )
      .accessibilityLabel("结论类型：\(label)")
  }

  private var label: String {
    switch kind {
    case .decision: return "拍板"
    case .consensus: return "共识"
    case .direction: return "方向"
    }
  }

  private var foreground: Color {
    switch kind {
    case .decision: return Tokens.Color.onAccent
    case .consensus: return Tokens.Color.acDeep
    case .direction: return Tokens.Color.ink2
    }
  }

  private var background: Color {
    switch kind {
    case .decision: return Tokens.Color.accentFill
    case .consensus: return Tokens.Color.acSoft
    case .direction: return Tokens.Color.line2
    }
  }

  private var stroke: Color {
    switch kind {
    case .decision: return Tokens.Color.accentFill
    case .consensus: return Tokens.Color.acLine
    case .direction: return Tokens.Color.line
    }
  }
}

private struct AnchoredOnePagerRow: View {
  let content: AnchoredText
  let onJumpToTranscript: (TimeInterval) -> Void
  @Environment(\.textScale) private var textScale

  var body: some View {
    HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
      Circle()
        .fill(Tokens.Color.ac)
        .frame(width: 5, height: 5)
        .padding(.top, Tokens.Spacing.xs)
      VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
        Text(content.text)
          .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
          .foregroundStyle(Tokens.Color.ink2)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Tokens.Spacing.xs) {
          EvidenceText(mark: content.evidence)
          TranscriptAnchorButton(anchor: content.anchor, onJump: onJumpToTranscript)
        }
      }
    }
  }
}

private struct EvidenceText: View {
  let mark: SummaryEvidenceMark?

  @ViewBuilder
  var body: some View {
    switch mark {
    case .toVerify:
      Text("[待核]")
        .foregroundStyle(Tokens.Color.warn)
    case .corrected:
      Text("已修正")
        .foregroundStyle(Tokens.Color.revision)
    case .confirmed:
      Text("已确认")
        .foregroundStyle(Tokens.Color.resolved)
    case nil:
      EmptyView()
    }
  }
}
