import JustSaidCore
import SwiftUI

/// 有规范化 `minutes.json` 时的中文纪要正文；这里只换呈现数据源，不改写落盘产物。
struct MinutesStructuredView: View {
  let document: MeetingMinutesDocument
  let titleMarkdownLine: String?
  let chapterMarkdown: String
  let onJumpToTranscript: ((TimeInterval) -> Void)?

  init?(
    document: MeetingMinutesDocument,
    minutesMarkdown: String,
    onJumpToTranscript: ((TimeInterval) -> Void)? = nil
  ) {
    guard
      let chapterMarkdown = Self.chapterMarkdown(in: minutesMarkdown),
      Self.hasEquivalentFiveSections(document: document, markdown: minutesMarkdown)
    else {
      return nil
    }
    self.document = document
    self.titleMarkdownLine = Self.titleMarkdownLine(in: minutesMarkdown)
    self.chapterMarkdown = chapterMarkdown
    self.onJumpToTranscript = onJumpToTranscript
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: Tokens.Spacing.md) {
        if let titleMarkdownLine {
          MarkdownLineView(
            line: titleMarkdownLine,
            fontSize: textScale.size(Tokens.FontSize.body)
          )
        }

        MinutesSectionView(section: .coreConclusions) {
          let conclusions = Array(document.coreConclusions.prefix(3))
          if conclusions.isEmpty {
            MinutesTextRow(text: MinutesSection.coreConclusions.emptyText)
          } else {
            ForEach(conclusions) { conclusion in
              MinutesTraceableTextRow(
                content: conclusion.content,
                onJumpToTranscript: onJumpToTranscript
              )
            }
          }
        }

        MinutesSectionView(section: .keyDiscussions) {
          if document.keyDiscussions.isEmpty {
            MinutesTextRow(text: MinutesSection.keyDiscussions.emptyText)
          } else {
            ForEach(Array(document.keyDiscussions.enumerated()), id: \.offset) { _, discussion in
              MinutesTraceableTextRow(
                content: discussion,
                onJumpToTranscript: onJumpToTranscript
              )
            }
          }
        }

        MinutesSectionView(section: .decisions) {
          if document.decisions.isEmpty {
            MinutesTextRow(text: MinutesSection.decisions.emptyText)
          } else {
            ForEach(Array(document.decisions.enumerated()), id: \.element.id) { index, decision in
              MinutesDecisionView(
                index: index + 1,
                decision: decision,
                onJumpToTranscript: onJumpToTranscript
              )
            }
          }
        }

        MinutesSectionView(section: .actionItems) {
          if document.actionItems.isEmpty {
            MinutesTextRow(text: MinutesSection.actionItems.emptyText)
          } else {
            ForEach(document.actionItems) { action in
              MinutesTraceableTextRow(
                text: action.text,
                anchor: action.recordedAt,
                evidence: action.evidence,
                onJumpToTranscript: onJumpToTranscript
              )
            }
          }
        }

        MinutesSectionView(section: .openQuestions) {
          if document.openQuestions.isEmpty {
            MinutesTextRow(text: MinutesSection.openQuestions.emptyText)
          } else {
            ForEach(document.openQuestions) { question in
              MinutesTraceableTextRow(
                content: question.content,
                disagreement: question.disagreement,
                onJumpToTranscript: onJumpToTranscript
              )
            }
          }
        }

        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(chapterMarkdown.components(separatedBy: "\n").enumerated()), id: \.offset) {
            _, line in
            MarkdownLineView(
              line: line,
              fontSize: textScale.size(Tokens.FontSize.body)
            )
          }
        }
        .runtimeAccessibilityIdentifier("library.minutes.structured.chapters")
      }
      .frame(maxWidth: Tokens.Layout.readingContentWidth, alignment: .leading)
      .padding(.horizontal, Tokens.Spacing.lg)
      .padding(.vertical, Tokens.Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .runtimeAccessibilityIdentifier("library.minutes.structured")
  }

  @Environment(\.textScale) private var textScale

  /// 与失败构造同一组门:核对工作台入口要在「结构化视图可构造」时才出现,
  /// 复用这里的判定,不许在别处抄一份五节全等逻辑。
  static func canRender(document: MeetingMinutesDocument, minutesMarkdown: String) -> Bool {
    chapterMarkdown(in: minutesMarkdown) != nil
      && hasEquivalentFiveSections(document: document, markdown: minutesMarkdown)
  }

  /// `章节视图` 是管线追加的最后一个二级标题。拿不准格式时返回 nil，宿主整页回落。
  static func chapterMarkdown(in markdown: String) -> String? {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard
      let chapterIndex = lines.lastIndex(where: {
        $0.trimmingCharacters(in: .whitespacesAndNewlines) == "## 章节视图"
      })
    else {
      return nil
    }
    if lines.indices.contains(chapterIndex + 1) {
      let hasLaterSection = lines[(chapterIndex + 1)...].contains {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ")
      }
      guard !hasLaterSection else { return nil }
    }
    return lines[chapterIndex...].joined(separator: "\n")
  }

  private static func titleMarkdownLine(in markdown: String) -> String? {
    markdown.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .first {
        let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("# ")
      }
  }

  private static let sectionHeadings = MinutesSection.allCases.map(\.rawValue)

  /// 存量会议可能同时留着旧 `minutes-full.md` 与较新的 sidecar；不同版绝不能混着画。
  private static func hasEquivalentFiveSections(
    document: MeetingMinutesDocument,
    markdown: String
  ) -> Bool {
    guard let projected = projectedSections(in: markdown) else { return false }
    return projected == expectedSections(from: document)
  }

  private static func expectedSections(
    from document: MeetingMinutesDocument
  ) -> [[String]] {
    let conclusions = document.coreConclusions.prefix(3).map(\.content.text)
    let discussions = document.keyDiscussions.map(\.text)
    var decisions: [String] = []
    for (index, decision) in document.decisions.enumerated() {
      decisions += [
        "决定 \(index + 1)",
        "问题：\(decision.issue)",
        "讨论方案：",
      ]
      if decision.options.isEmpty {
        decisions.append("未记录具体方案。")
      } else {
        decisions += decision.options.map { "\($0.speaker)：\($0.proposal)" }
      }
      decisions.append("决策依据：\(decision.rationale)")
    }
    let actions = document.actionItems.map(\.text)
    let openQuestions = document.openQuestions.map(\.content.text)
    return [
      conclusions.isEmpty ? [MinutesSection.coreConclusions.emptyText] : conclusions,
      discussions.isEmpty ? [MinutesSection.keyDiscussions.emptyText] : discussions,
      decisions.isEmpty ? [MinutesSection.decisions.emptyText] : decisions,
      actions.isEmpty ? [MinutesSection.actionItems.emptyText] : actions,
      openQuestions.isEmpty ? [MinutesSection.openQuestions.emptyText] : openQuestions,
    ]
  }

  private static func projectedSections(in markdown: String) -> [[String]]? {
    var result = Array(repeating: [String](), count: sectionHeadings.count)
    var seenHeadings: [String] = []
    var currentSection: Int?
    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("## ") {
        let heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        seenHeadings.append(heading)
        currentSection = sectionHeadings.firstIndex(of: heading)
        continue
      }
      guard !line.isEmpty else { continue }
      guard let currentSection else {
        if seenHeadings.last == "章节视图" || (seenHeadings.isEmpty && line.hasPrefix("# ")) {
          continue
        }
        return nil
      }
      if currentSection == 2, line.hasPrefix("### ") {
        result[currentSection].append(
          String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        )
        continue
      }
      guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
      var text = String(line.dropFirst(2))
      if currentSection == 2 {
        for label in ["问题", "讨论方案", "决策依据"] {
          let marker = "**\(label)**"
          if text.hasPrefix(marker) {
            text = label + text.dropFirst(marker.count)
            break
          }
        }
      }
      result[currentSection].append(text)
    }
    guard seenHeadings == sectionHeadings + ["章节视图"] else { return nil }
    return result
  }
}

private enum MinutesSection: String, CaseIterable {
  case coreConclusions = "核心结论"
  case keyDiscussions = "关键讨论"
  case decisions = "决定"
  case actionItems = "待办"
  case openQuestions = "未决"

  var emptyText: String {
    self == .decisions ? "暂无明确决定。" : "无。"
  }

  var identifier: String {
    switch self {
    case .coreConclusions: return "library.minutes.structured.core-conclusions"
    case .keyDiscussions: return "library.minutes.structured.key-discussions"
    case .decisions: return "library.minutes.structured.decisions"
    case .actionItems: return "library.minutes.structured.action-items"
    case .openQuestions: return "library.minutes.structured.open-questions"
    }
  }
}

private struct MinutesSectionView<Content: View>: View {
  let section: MinutesSection
  @ViewBuilder let content: () -> Content

  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      Text(section.rawValue)
        .font(.system(size: textScale.size(Tokens.FontSize.body) + 1, weight: .bold))
        .foregroundStyle(Tokens.Color.ink)
        .padding(.top, Tokens.Spacing.xs)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .runtimeAccessibilityIdentifier(section.identifier)
  }
}

private struct MinutesTextRow: View {
  let text: String
  var isNested = false

  @Environment(\.textScale) private var textScale

  var body: some View {
    HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
      Circle()
        .fill(Tokens.Color.ink4)
        .frame(width: Tokens.Spacing.xxs, height: Tokens.Spacing.xxs)
        .padding(.top, Tokens.Spacing.xs)
      Text(text)
        .font(.system(size: textScale.size(Tokens.FontSize.body)))
        .foregroundStyle(Tokens.Color.ink2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.leading, isNested ? Tokens.Spacing.smd : 0)
    .padding(.vertical, Tokens.Spacing.hairline)
  }
}

private struct MinutesTraceableTextRow: View {
  let text: String
  let anchor: TranscriptAnchor?
  let evidence: SummaryEvidenceMark?
  let revision: SummaryRevisionTrace?
  let disagreement: SummaryDisagreement?
  let onJumpToTranscript: ((TimeInterval) -> Void)?

  @Environment(\.textScale) private var textScale
  @State private var isRevisionExpanded = false

  init(
    text: String,
    anchor: TranscriptAnchor?,
    evidence: SummaryEvidenceMark?,
    revision: SummaryRevisionTrace? = nil,
    disagreement: SummaryDisagreement? = nil,
    onJumpToTranscript: ((TimeInterval) -> Void)?
  ) {
    self.text = text
    self.anchor = anchor
    self.evidence = evidence
    self.revision = revision
    self.disagreement = disagreement
    self.onJumpToTranscript = onJumpToTranscript
  }

  init(
    content: AnchoredText,
    disagreement: SummaryDisagreement? = nil,
    onJumpToTranscript: ((TimeInterval) -> Void)?
  ) {
    self.init(
      text: content.text,
      anchor: content.anchor,
      evidence: content.evidence,
      revision: content.revision,
      disagreement: disagreement,
      onJumpToTranscript: onJumpToTranscript
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
        Circle()
          .fill(Tokens.Color.ink4)
          .frame(width: Tokens.Spacing.xxs, height: Tokens.Spacing.xxs)
          .padding(.top, Tokens.Spacing.xs)
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
          Text(text)
            .font(.system(size: textScale.size(Tokens.FontSize.body)))
            .foregroundStyle(Tokens.Color.ink2)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: Tokens.Spacing.xxs) {
            MinutesEvidenceBadge(
              mark: evidence,
              isRepresentedByRevision: revision != nil
            )
            MinutesAnchorButton(anchor: anchor, onJump: onJumpToTranscript)
            if let revision {
              RevisionDisclosureButton(
                revision: revision,
                isExpanded: $isRevisionExpanded
              )
              .runtimeAccessibilityIdentifier("library.minutes.revision-toggle")
            }
          }
        }
      }

      if isRevisionExpanded, let revision {
        RevisionTraceView(
          revision: revision,
          onJumpToTranscript: onJumpToTranscript
        )
        .padding(.leading, Tokens.Spacing.smd)
      }
      if let disagreement {
        DisagreementTraceView(
          disagreement: disagreement,
          onJumpToTranscript: onJumpToTranscript
        )
        .padding(.leading, Tokens.Spacing.smd)
        .runtimeAccessibilityIdentifier("library.minutes.disagreement")
      }
    }
    .padding(.vertical, Tokens.Spacing.hairline)
  }
}

private struct MinutesEvidenceBadge: View {
  let mark: SummaryEvidenceMark?
  let isRepresentedByRevision: Bool

  @ViewBuilder
  var body: some View {
    switch mark {
    case .confirmed:
      SummaryMarkerBadge(kind: .convergence, label: "✓ 已确认")
        .runtimeAccessibilityIdentifier("library.minutes.evidence.confirmed")
    case .toVerify:
      SummaryMarkerBadge(kind: .toVerify)
        .runtimeAccessibilityIdentifier("library.minutes.evidence.to-verify")
    case .corrected where !isRepresentedByRevision:
      SummaryMarkerBadge(kind: .revision)
        .runtimeAccessibilityIdentifier("library.minutes.evidence.corrected")
    case .corrected, nil:
      EmptyView()
    }
  }
}

private struct MinutesAnchorButton: View {
  let anchor: TranscriptAnchor?
  let onJump: ((TimeInterval) -> Void)?

  var body: some View {
    if let anchor, anchor.seconds != nil, let onJump {
      TranscriptAnchorButton(anchor: anchor, onJump: onJump)
        .runtimeAccessibilityIdentifier("library.minutes.anchor")
    }
  }
}

private struct MinutesDecisionView: View {
  let index: Int
  let decision: MeetingDecision
  let onJumpToTranscript: ((TimeInterval) -> Void)?

  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      HStack(spacing: Tokens.Spacing.xxs) {
        Text("决定 \(index)")
          .font(.system(size: textScale.size(Tokens.FontSize.body), weight: .semibold))
          .foregroundStyle(Tokens.Color.ink)
        MinutesAnchorButton(anchor: decision.anchor, onJump: onJumpToTranscript)
      }
      .padding(.top, Tokens.Spacing.xs)
      MinutesTextRow(text: "问题：\(decision.issue)")
      MinutesTextRow(text: "讨论方案：")
      if decision.options.isEmpty {
        MinutesTextRow(text: "未记录具体方案。", isNested: true)
      } else {
        ForEach(decision.options) { option in
          MinutesTextRow(
            text: "\(option.speaker)：\(option.proposal)",
            isNested: true
          )
        }
      }
      MinutesTextRow(text: "决策依据：\(decision.rationale)")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
