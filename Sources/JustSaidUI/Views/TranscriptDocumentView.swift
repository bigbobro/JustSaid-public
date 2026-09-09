import AppKit
import JustSaidCore
import SwiftUI

/// 详情页「完整转写」的正文 seam。
///
/// 调用方只交付已经结算好的 `TranscriptDisplayRow` 与业务动作；原生文档、字符 range、
/// hit testing、菜单和滚动提交全部封装在 `TranscriptTextView` 内。本层不读盘、不改映射，
/// `transcript.md` 始终保持权威原文。
public struct TranscriptDocumentView: View {
  let rows: [TranscriptDisplayRow]
  let speakerFilter: String?
  let searchQuery: String
  let speakers: [String]
  let onSelectSpeaker: (String) -> Void
  let onOverride: (TranscriptSpeechLine, String?) -> Void
  let onRequestNewName: (TranscriptSpeechLine) -> Void
  var excludedRanges: [ExcludedRange] = []
  var excludedSpeakers: [String] = []
  var onExcludeLine: ((TranscriptSpeechLine) -> Void)? = nil
  var onRemoveExclusion: ((UUID) -> Void)? = nil
  var onSetSpeakerExcluded: ((String, Bool) -> Void)? = nil
  var highlightedSpeaker: String? = nil
  var selection: Binding<TranscriptLineSelection?>? = nil
  var onExcludeRange: ((TranscriptSpeechLine, TranscriptSpeechLine) -> Void)? = nil
  var scrollOffset: Binding<CGFloat>? = nil
  @Binding var jumpRequest: TranscriptJumpRequest?

  @Environment(\.textScale) private var textScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(
    rows: [TranscriptDisplayRow],
    speakerFilter: String?,
    searchQuery: String = "",
    speakers: [String],
    onSelectSpeaker: @escaping (String) -> Void,
    onOverride: @escaping (TranscriptSpeechLine, String?) -> Void,
    onRequestNewName: @escaping (TranscriptSpeechLine) -> Void,
    excludedRanges: [ExcludedRange] = [],
    excludedSpeakers: [String] = [],
    onExcludeLine: ((TranscriptSpeechLine) -> Void)? = nil,
    onRemoveExclusion: ((UUID) -> Void)? = nil,
    onSetSpeakerExcluded: ((String, Bool) -> Void)? = nil,
    highlightedSpeaker: String? = nil,
    selection: Binding<TranscriptLineSelection?>? = nil,
    onExcludeRange: ((TranscriptSpeechLine, TranscriptSpeechLine) -> Void)? = nil,
    scrollOffset: Binding<CGFloat>? = nil,
    jumpRequest: Binding<TranscriptJumpRequest?> = .constant(nil)
  ) {
    self.rows = rows
    self.speakerFilter = speakerFilter
    self.searchQuery = searchQuery
    self.speakers = speakers
    self.onSelectSpeaker = onSelectSpeaker
    self.onOverride = onOverride
    self.onRequestNewName = onRequestNewName
    self.excludedRanges = excludedRanges
    self.excludedSpeakers = excludedSpeakers
    self.onExcludeLine = onExcludeLine
    self.onRemoveExclusion = onRemoveExclusion
    self.onSetSpeakerExcluded = onSetSpeakerExcluded
    self.highlightedSpeaker = highlightedSpeaker
    self.selection = selection
    self.onExcludeRange = onExcludeRange
    self.scrollOffset = scrollOffset
    _jumpRequest = jumpRequest
  }

  public var body: some View {
    let visibleRows = Self.filtering(rows, to: speakerFilter, matching: searchQuery)
    let selectedIndexes = selectedLineIndexes
    ZStack(alignment: .bottom) {
      if visibleRows.isEmpty, !normalizedSearchQuery.isEmpty {
        Text("当前过滤组合没有找到包含「\(normalizedSearchQuery)」的转写。")
          .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .runtimeAccessibilityIdentifier("transcript.search.empty")
      } else {
        TranscriptTextView(
          rows: visibleRows,
          speakers: speakers,
          isSpeakerFiltered: speakerFilter != nil,
          bodyFontSize: textScale.size(Tokens.FontSize.body),
          excludedRanges: excludedRanges,
          excludedSpeakers: Set(excludedSpeakers),
          highlightedSpeaker: highlightedSpeaker,
          selectedLineIndexes: selectedIndexes,
          selectionAnchorIndex: selection?.wrappedValue?.anchorIndex,
          selectionEnabled: selection != nil,
          reduceMotion: reduceMotion,
          scrollOffset: scrollOffset,
          jumpRequest: $jumpRequest,
          onSelectSpeaker: onSelectSpeaker,
          onSelectTimestamp: selectTimestamp,
          onDragTimestamp: dragTimestamp,
          onOverride: onOverride,
          onRequestNewName: onRequestNewName,
          onExcludeLine: onExcludeLine,
          // 批量标记与底部动作条共用 applySelection:选中多段后右键标记闲聊,
          // 结算的是整个选区,不是光标底下那一段(issue #25)。
          onExcludeSelection: onExcludeRange == nil ? nil : applySelection,
          onRemoveExclusion: onRemoveExclusion,
          onSetSpeakerExcluded: onSetSpeakerExcluded
        )
      }
      TranscriptSelectionBar(
        count: onExcludeRange != nil && !selectedIndexes.isEmpty ? selectedIndexes.count : nil,
        onApply: applySelection,
        onClear: { selection?.wrappedValue = nil }
      )
    }
    .onChange(of: rows) { _, newRows in
      clearInvalidSelection(in: newRows)
    }
  }

  private var normalizedSearchQuery: String {
    searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var selectedLineIndexes: Set<Int> {
    guard let bound = selection?.wrappedValue else { return [] }
    return Self.selectedLineIndexes(in: rows, anchor: bound.anchorIndex, focus: bound.focusIndex)
  }

  private func clearInvalidSelection(in newRows: [TranscriptDisplayRow]) {
    guard let selection, let bound = selection.wrappedValue else { return }
    let speechIndexes = Set(
      newRows.compactMap { row -> Int? in
        guard case .speech(let line) = row else { return nil }
        return line.index
      }
    )
    guard !speechIndexes.contains(bound.anchorIndex) || !speechIndexes.contains(bound.focusIndex)
    else { return }
    selection.wrappedValue = nil
  }

  private func selectTimestamp(_ lineIndex: Int, shiftPressed: Bool) {
    guard let selection else { return }
    if shiftPressed, let current = selection.wrappedValue {
      selection.wrappedValue = TranscriptLineSelection(
        anchorIndex: current.anchorIndex,
        focusIndex: lineIndex
      )
    } else {
      selection.wrappedValue = TranscriptLineSelection(
        anchorIndex: lineIndex,
        focusIndex: lineIndex
      )
    }
  }

  private func dragTimestamp(_ anchorIndex: Int, _ focusIndex: Int) {
    selection?.wrappedValue = TranscriptLineSelection(
      anchorIndex: anchorIndex,
      focusIndex: focusIndex
    )
  }

  private func applySelection() {
    let selected = selectedLineIndexes
    let covered = rows.compactMap { row -> TranscriptSpeechLine? in
      guard case .speech(let line) = row, selected.contains(line.index) else { return nil }
      return line
    }.sorted { $0.index < $1.index }
    guard let first = covered.first, let last = covered.last else { return }
    onExcludeRange?(first, last)
  }

  /// 纯呈现过滤：搜索与说话人「只看」取交集；任一激活时 plain 行隐藏。
  public static func filtering(
    _ rows: [TranscriptDisplayRow],
    to speaker: String?
  ) -> [TranscriptDisplayRow] {
    filtering(rows, to: speaker, matching: "")
  }

  public static func filtering(
    _ rows: [TranscriptDisplayRow],
    to speaker: String?,
    matching query: String
  ) -> [TranscriptDisplayRow] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasSpeakerFilter = speaker?.isEmpty == false
    guard hasSpeakerFilter || !normalizedQuery.isEmpty else { return rows }
    return rows.filter { row in
      guard case .speech(let line) = row else { return false }
      let matchesSpeaker = !hasSpeakerFilter || line.speaker == speaker
      let matchesSearch =
        normalizedQuery.isEmpty
        || line.text.localizedCaseInsensitiveContains(normalizedQuery)
      return matchesSpeaker && matchesSearch
    }
  }

  public static func filteredSpeechCount(
    in rows: [TranscriptDisplayRow],
    speaker: String?,
    query: String
  ) -> Int {
    filtering(rows, to: speaker, matching: query).reduce(into: 0) { count, row in
      if case .speech = row { count += 1 }
    }
  }

  /// anchor/focus 闭区间按全文行序结算；被过滤隐藏的中间行仍在选区内。
  public static func selectedLineIndexes(
    in rows: [TranscriptDisplayRow],
    anchor: Int,
    focus: Int
  ) -> Set<Int> {
    let range = min(anchor, focus)...max(anchor, focus)
    return Set(
      rows.compactMap { row -> Int? in
        guard case .speech(let line) = row, range.contains(line.index) else { return nil }
        return line.index
      }
    )
  }

  public static func nearestSpeechLine(
    in rows: [TranscriptDisplayRow],
    to seconds: TimeInterval
  ) -> TranscriptSpeechLine? {
    rows.compactMap { row -> (TranscriptSpeechLine, TimeInterval)? in
      guard
        case .speech(let line) = row,
        let lineSeconds = TranscriptAnchor(timecode: line.timestamp).seconds
      else {
        return nil
      }
      return (line, lineSeconds)
    }.min { lhs, rhs in
      abs(lhs.1 - seconds) < abs(rhs.1 - seconds)
    }?.0
  }

  public static func highlightAnchors(
    in rows: [TranscriptDisplayRow],
    of speaker: String
  ) -> [TimeInterval] {
    rows.compactMap { row in
      guard case .speech(let line) = row, line.speaker == speaker else { return nil }
      return TranscriptAnchor(timecode: line.timestamp).seconds
    }
  }
}

/// 批量选段动作条保留在 SwiftUI chrome；正文与命中均由 TextKit 模块承担。
struct TranscriptSelectionBar: View {
  let count: Int?
  let onApply: () -> Void
  let onClear: () -> Void

  var body: some View {
    if let count {
      HStack(spacing: Tokens.Spacing.xs) {
        Button("标为闲聊(\(count) 段)", action: onApply)
          .buttonStyle(.textAction)
          .fontWeight(.semibold)
          .help("这一整段写成一条排除记录，不进纪要；在排除行上右键可一次撤销整段")
          .runtimeAccessibilityIdentifier("transcript.selection-bar.apply")
        Button(action: onClear) {
          Image(systemName: "xmark")
            .font(.system(size: Tokens.FontSize.glyphTiny, weight: .bold))
        }
        .buttonStyle(.textAction)
        .accessibilityLabel("清除选段")
        .runtimeAccessibilityIdentifier("transcript.selection-bar.clear")
        Text("只影响之后生成的纪要，转写原文不动；Esc 取消")
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink4)
      }
      .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      .foregroundStyle(Tokens.Color.acDeep)
      .padding(.horizontal, Tokens.Spacing.sm)
      .padding(.vertical, Tokens.Spacing.xs)
      .insetPanel()
      .tokenShadow(Tokens.Shadow.sh2)
      .padding(.bottom, Tokens.Spacing.sm)
      .runtimeAccessibilityIdentifier("transcript.selection-bar")
    }
  }
}

/// 发言人配色。「我」固定为 me 蓝且不占其他人的色环位次。
public enum SpeakerAccents {
  public static func accentIndex(for speaker: String, in speakers: [String]) -> Int? {
    guard speaker != TranscriptSpeakerNaming.selfSpeakerLabel else { return nil }
    return
      speakers
      .filter { $0 != TranscriptSpeakerNaming.selfSpeakerLabel }
      .firstIndex(of: speaker)
  }

  public static func color(for speaker: String, in speakers: [String]) -> Color {
    guard let index = accentIndex(for: speaker, in: speakers) else {
      return speaker == TranscriptSpeakerNaming.selfSpeakerLabel
        ? Tokens.Color.me
        : Tokens.Color.others
    }
    let ring = Tokens.Color.speakerAccents
    return ring.isEmpty ? Tokens.Color.others : ring[index % ring.count]
  }
}
