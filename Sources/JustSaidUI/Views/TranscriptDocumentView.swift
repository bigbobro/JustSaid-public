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
  /// 空集 = 不筛。原来是 `String?`,只能盯一个人;实际读会是「发言人 1 和 3 聊得多,
  /// 把 2 关掉」,一次只能看一个人等于每看一句都要切一次(owner 2026-09-20)。
  let speakerFilters: Set<String>
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
  var onRequestNaming: ((String) -> Void)? = nil
  var onRequestNamingLine: ((TranscriptSpeechLine) -> Void)? = nil
  var isBatchSelecting = false
  var onCancelBatch: (() -> Void)? = nil
  var onViewportLine: ((TranscriptSpeechLine?) -> Void)? = nil
  var onToggleSpeakerHighlight: ((String) -> Void)? = nil
  var highlightedSpeaker: String? = nil
  var selection: Binding<TranscriptLineSelection?>? = nil
  var onExcludeRange: ((TranscriptSpeechLine, TranscriptSpeechLine) -> Void)? = nil
  var scrollOffset: Binding<CGFloat>? = nil
  var onViewportAnchor: ((TimeInterval?) -> Void)? = nil
  @Binding var jumpRequest: TranscriptJumpRequest?

  @Environment(\.textScale) private var textScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(
    rows: [TranscriptDisplayRow],
    speakerFilter: String? = nil,
    speakerFilters: Set<String>? = nil,
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
    onRequestNaming: ((String) -> Void)? = nil,
    onRequestNamingLine: ((TranscriptSpeechLine) -> Void)? = nil,
    isBatchSelecting: Bool = false,
    onCancelBatch: (() -> Void)? = nil,
    onViewportLine: ((TranscriptSpeechLine?) -> Void)? = nil,
    onToggleSpeakerHighlight: ((String) -> Void)? = nil,
    highlightedSpeaker: String? = nil,
    selection: Binding<TranscriptLineSelection?>? = nil,
    onExcludeRange: ((TranscriptSpeechLine, TranscriptSpeechLine) -> Void)? = nil,
    scrollOffset: Binding<CGFloat>? = nil,
    onViewportAnchor: ((TimeInterval?) -> Void)? = nil,
    jumpRequest: Binding<TranscriptJumpRequest?> = .constant(nil)
  ) {
    self.rows = rows
    // 单人入口保留:验证程序与旧调用点照原样传 `speakerFilter:`。
    self.speakerFilters = speakerFilters ?? Set([speakerFilter].compactMap { $0 })
    self.onViewportAnchor = onViewportAnchor
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
    self.onRequestNaming = onRequestNaming
    self.onRequestNamingLine = onRequestNamingLine
    self.isBatchSelecting = isBatchSelecting
    self.onCancelBatch = onCancelBatch
    self.onViewportLine = onViewportLine
    self.onToggleSpeakerHighlight = onToggleSpeakerHighlight
    self.highlightedSpeaker = highlightedSpeaker
    self.selection = selection
    self.onExcludeRange = onExcludeRange
    self.scrollOffset = scrollOffset
    _jumpRequest = jumpRequest
  }

  public var body: some View {
    let visibleRows = Self.filtering(rows, to: speakerFilters, matching: searchQuery)
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
          isSpeakerFiltered: !speakerFilters.isEmpty,
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
          onSetSpeakerExcluded: onSetSpeakerExcluded,
          onRequestNaming: onRequestNaming,
          onToggleSpeakerHighlight: onToggleSpeakerHighlight,
          onViewportAnchor: onViewportAnchor,
          onRequestNamingLine: onRequestNamingLine,
          isBatchSelecting: isBatchSelecting,
          onSelectBatchEndpoint: { selectTimestamp($0, shiftPressed: true) },
          onCancelBatch: onCancelBatch,
          onViewportLine: onViewportLine
        )
      }
      TranscriptSelectionBar(
        count: onExcludeRange != nil && !selectedIndexes.isEmpty ? selectedIndexes.count : nil,
        onApply: applySelection,
        onClear: {
          selection?.wrappedValue = nil
          onCancelBatch?()
        },
        isBatchSelecting: isBatchSelecting,
        hiddenCount: selectedIndexes.subtracting(
          Set(
            visibleRows.compactMap { row in
              guard case .speech(let line) = row else { return nil }
              return line.index
            })
        ).count,
        onReselect: { selection?.wrappedValue = nil }
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
    filtering(rows, to: Set([speaker].compactMap { $0 }), matching: query)
  }

  public static func filtering(
    _ rows: [TranscriptDisplayRow],
    to speakers: Set<String>,
    matching query: String
  ) -> [TranscriptDisplayRow] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = speakers.filter { !$0.isEmpty }
    guard !selected.isEmpty || !normalizedQuery.isEmpty else { return rows }
    return rows.filter { row in
      guard case .speech(let line) = row else { return false }
      let matchesSpeaker = selected.isEmpty || selected.contains(line.speaker)
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
  var isBatchSelecting = false
  var hiddenCount = 0
  var onReselect: (() -> Void)?

  var body: some View {
    if count != nil || isBatchSelecting {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        Text(count == nil ? "点一段设起点，滚动后点另一段设终点" : "已选原文连续 \(count ?? 0) 段")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink2)
        if hiddenCount > 0 {
          Text("包含当前筛选隐藏的 \(hiddenCount) 段，也会不进纪要")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.warn)
            .runtimeAccessibilityIdentifier("transcript.selection-bar.hidden-count")
        }
        HStack(spacing: Tokens.V1.Space.xs) {
          Button("不进纪要（\(count ?? 0) 段）", action: onApply)
            .buttonStyle(.v1Primary)
            .disabled(count == nil)
            .help("保存一条排除记录；撤销时恢复该记录涉及的整个范围")
            .runtimeAccessibilityIdentifier("transcript.selection-bar.apply")
          if isBatchSelecting {
            Button("重选") { onReselect?() }
              .buttonStyle(.v1Outline)
              .disabled(count == nil)
              .runtimeAccessibilityIdentifier("transcript.batch.reselect")
            Button("取消", action: onClear)
              .buttonStyle(.v1Quiet)
              .runtimeAccessibilityIdentifier("transcript.batch.cancel")
          } else {
            Button("清除选段", action: onClear)
              .buttonStyle(.v1Quiet)
              .runtimeAccessibilityIdentifier("transcript.selection-bar.clear")
          }
        }
        Text(
          isBatchSelecting
            ? "↑ ↓ 移动候选，空格设首尾，Tab 到操作，Esc 取消。原文保留。"
            : "只影响之后生成的纪要，原文保留；Esc 取消"
        )
        .font(Tokens.V1.Text.micro.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(Tokens.V1.Space.sm)
      .background(Tokens.V1.Color.raised, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
          .stroke(Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
      )
      .padding(Tokens.V1.Space.sm)
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

  /// 彩虹说话人色退役(批2 早就在 `Tokens.Color.speakerAccents` 上标了「v1:第 2 批退役」,
  /// 只是没执行)。六个人六种高饱和色,既没有图例解释,又和上面筛选行里的灰字对不上,
  /// 一屏读下来全是彩字(owner 2026-09-20 走查完整转写)。
  /// 现在只区分「我」和其他人:我用 `color-me`,其余走正文墨色,靠字重分辨。
  public static func color(for speaker: String, in speakers: [String]) -> Color {
    speaker == TranscriptSpeakerNaming.selfSpeakerLabel
      ? Tokens.V1.Color.me
      : Tokens.V1.Color.ink2
  }
}
