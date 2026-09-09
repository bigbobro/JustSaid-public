import JustSaidCore
import SwiftUI

/// 一份正文用于 quick/pinned；窗口只决定尺寸，不复制跳转消费者。
public struct TranscriptPaneView: View {
  private let segments: [TranscriptSegment]
  @Binding var presentation: LiveTranscriptPresentationState
  private let excludedRanges: [ExcludedRange]
  private let onMarkChatFrom: ((TimeInterval) -> Void)?
  private let onRemoveExclusion: ((UUID) -> Void)?

  @Environment(\.textScale) private var textScale
  @State private var position = ScrollPosition(idType: LiveTranscriptRowID.self)
  @State private var visibleRows: [LiveTranscriptRowID] = []
  @State private var isUserScrolling = false

  public init(
    segments: [TranscriptSegment],
    presentation: Binding<LiveTranscriptPresentationState>,
    excludedRanges: [ExcludedRange] = [],
    onMarkChatFrom: ((TimeInterval) -> Void)? = nil,
    onRemoveExclusion: ((UUID) -> Void)? = nil
  ) {
    self.segments = segments
    _presentation = presentation
    self.excludedRanges = excludedRanges
    self.onMarkChatFrom = onMarkChatFrom
    self.onRemoveExclusion = onRemoveExclusion
  }

  private struct Row: Identifiable {
    let id: LiveTranscriptRowID
    let index: Int
    let segment: TranscriptSegment
  }

  private var rowIDs: [LiveTranscriptRowID] { LiveTranscriptRowID.rows(for: segments) }
  private var rows: [Row] {
    zip(rowIDs, segments).enumerated().map {
      Row(id: $0.element.0, index: $0.offset, segment: $0.element.1)
    }
  }
  private var firstVisibleRow: LiveTranscriptRowID? {
    rowIDs.first { visibleRows.contains($0) }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        TranscriptToggleButton(presentation: $presentation)
        Button {
          presentation.rememberReadingAnchor(firstVisibleRow)
          presentation.togglePin()
        } label: {
          Image(systemName: presentation.mode == .pinned ? "pin.slash" : "pin")
            .padding(Tokens.Spacing.xsm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.iconHover)
        .help(presentation.mode == .pinned ? "取消固定" : "固定在整理区")
        .accessibilityLabel(presentation.mode == .pinned ? "取消固定" : "固定在整理区")
        .runtimeAccessibilityIdentifier("transcript.live.pin")
      }
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
          if segments.isEmpty {
            Text("会议开始后，本地识别结果可能晚几秒显示在这里。")
              .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
              .foregroundStyle(Tokens.Color.ink3)
              .runtimeAccessibilityIdentifier("transcript.live.empty")
          } else {
            ForEach(rows) { row in
              TranscriptRow(
                segment: row.segment,
                fontSize: textScale.size(Tokens.FontSize.bodyMinimum),
                isHighlighted: presentation.highlightedRow == row.id,
                excludedRangeID: ExclusionUI.coveringRange(at: row.segment.t0, in: excludedRanges)?
                  .id,
                onMarkChatFrom: onMarkChatFrom,
                onRemoveExclusion: onRemoveExclusion
              )
              .id(row.id)
              .background {
                Color.clear.runtimeAccessibilityIdentifier("transcript.live.row.\(row.index)")
              }
            }
          }
        }
        .scrollTargetLayout()
        .padding(Tokens.Spacing.md)
      }
      .scrollPosition($position)
      .onScrollTargetVisibilityChange(idType: LiveTranscriptRowID.self, threshold: 0.01) {
        visibleRows = $0
      }
      .onScrollPhaseChange { _, phase, context in
        if phase == .tracking || phase == .interacting {
          if !isUserScrolling { presentation.userScrollBegan() }
          isUserScrolling = true
        } else if phase == .idle, isUserScrolling {
          isUserScrolling = false
          if presentation.pendingJump != nil || presentation.isFollowing {
            // 手势/惯性期间的新定位或「回最新」暂缓到这里，不被旧手势的落点覆盖。
            applyScrollIntent()
          } else {
            let geometry = context.geometry
            presentation.userScrollEnded(
              anchor: firstVisibleRow,
              atBottom: geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height - Tokens.Spacing.xxl
            )
          }
        }
      }
      .onScrollGeometryChange(for: CGSize.self) {
        $0.contentSize
      } action: { _, _ in
        if presentation.isFollowing { scrollToLatest() }
      }
      .onScrollGeometryChange(for: CGSize.self) {
        $0.containerSize
      } action: { _, _ in
        applyScrollIntent(restoringReading: true)
      }
      .onChange(of: segments) { _, _ in applyScrollIntent() }
      .onChange(of: presentation.pendingJump) { _, _ in applyScrollIntent() }
      .onChange(of: presentation.latestRequest) { _, _ in applyScrollIntent() }
      .onAppear { applyScrollIntent(restoringReading: true) }
      .overlay(alignment: .bottomTrailing) {
        if !presentation.isFollowing {
          OutlineActionButton(icon: "arrow.down", title: "回到最新") {
            presentation.returnToLatest()
          }
          .padding(Tokens.Spacing.sm)
          .runtimeAccessibilityIdentifier("transcript.live.latest")
        }
      }
    }
    .onKeyPress(.escape) {
      presentation.close()
      return .handled
    }
    .task(id: presentation.highlightRequest) {
      guard let requestID = presentation.highlightRequest else { return }
      do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
      presentation.clearHighlight(requestID: requestID)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Tokens.Color.pane)
    .runtimeAccessibilityIdentifier("transcript.live.expanded")
  }

  private func applyScrollIntent(restoringReading: Bool = false) {
    guard !isUserScrolling, !segments.isEmpty else { return }
    let rows = rowIDs
    if let request = presentation.pendingJump,
      let target = rows.min(by: { abs($0.t0 - request.seconds) < abs($1.t0 - request.seconds) })
    {
      position.scrollTo(id: target, anchor: .top)
      presentation.consumeJump(request, row: target)
    } else if presentation.isFollowing {
      scrollToLatest()
    } else if let anchor = presentation.readingAnchor,
      restoringReading || !rows.contains(anchor),
      let target = anchor.resolved(in: rows)
    {
      presentation.rememberReadingAnchor(target)
      position.scrollTo(id: target, anchor: .top)
    }
  }

  private func scrollToLatest() {
    guard !isUserScrolling, presentation.pendingJump == nil, !segments.isEmpty else { return }
    // 普通展开与后续增长走同一条真实滚动接线；.bottom 指向整段原文的末尾。
    position.scrollTo(edge: .bottom)
  }
}

private struct TranscriptRow: View {
  let segment: TranscriptSegment
  let fontSize: CGFloat
  let isHighlighted: Bool
  /// 覆盖本段 t0 的排除区间 id;nil = 没被排除。
  let excludedRangeID: UUID?
  let onMarkChatFrom: ((TimeInterval) -> Void)?
  let onRemoveExclusion: ((UUID) -> Void)?

  private var speakerColor: Color {
    segment.source == .me ? Tokens.Color.me : Tokens.Color.others
  }

  var body: some View {
    // 两个回调都没有时连空菜单都不挂——空 contextMenu 会把文本选中态的
    // 系统菜单也吃掉。
    if excludedRangeID != nil || onMarkChatFrom != nil {
      content.contextMenu { exclusionMenu }
    } else {
      content
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
        HStack(spacing: Tokens.Spacing.xxs) {
          Circle().fill(speakerColor).frame(width: 5, height: 5)
          Text(segment.source == .me ? "我" : "对方")
            .font(.system(size: Tokens.FontSize.secondary, weight: .bold))
            .foregroundStyle(speakerColor)
        }
        Text(ElapsedTime.shortLabel(segment.t0))
          .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
          .foregroundStyle(Tokens.Color.ink4)
          .runtimeAccessibilityIdentifier("transcript.live.chrome.timestamp")
        if excludedRangeID != nil {
          ExcludedMarker()
            .runtimeAccessibilityIdentifier("transcript.live.excluded")
        }
      }
      Text(segment.text)
        .font(.system(size: fontSize))
        .foregroundStyle(segment.isFinal ? Tokens.Color.inkBody : Tokens.Color.ink4)
        .italic(!segment.isFinal)
        .textSelection(.enabled)
        .runtimeAccessibilityIdentifier("transcript.live.body")
    }
    .background(
      isHighlighted
        ? RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge).fill(Tokens.Color.acSoft)
        : RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge).fill(Color.clear)
    )
    // 排除态只用不透明度,不占色相——与发言人高亮(并行任务)不冲突。
    .opacity(excludedRangeID != nil ? 0.45 : 1)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(segment.source == .me ? "我" : "对方")，\(ElapsedTime.shortLabel(segment.t0))：\(segment.text)"
    )
  }

  @ViewBuilder
  private var exclusionMenu: some View {
    if let excludedRangeID, let onRemoveExclusion {
      Button("撤销排除") {
        onRemoveExclusion(excludedRangeID)
      }
    }
    // 已落入区间的段不再提供「从这里开始」——在它内部再开一段没有新语义。
    if excludedRangeID == nil, let onMarkChatFrom {
      Button("从这里开始是闲聊") {
        onMarkChatFrom(segment.t0)
      }
    }
  }
}

/// 标题、留白和装饰箭头属于同一颗 toggle；固定按钮是它的相邻控件。
private struct TranscriptToggleButton: View {
  @Binding var presentation: LiveTranscriptPresentationState
  var preview: TranscriptSegment?

  var body: some View {
    Button {
      presentation.toggle()
    } label: {
      HStack(spacing: Tokens.Spacing.sm) {
        Text("实时转写")
          .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize()
        if !presentation.isExpanded {
          if let preview {
            Text(ElapsedTime.shortLabel(preview.t0))
              .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
              .foregroundStyle(Tokens.Color.ink4)
              .fixedSize()
            Text(preview.source == .me ? "我" : "对方")
              .font(.system(size: Tokens.FontSize.caption, weight: .bold))
              .foregroundStyle(preview.source == .me ? Tokens.Color.me : Tokens.Color.others)
              .fixedSize()
            Text(preview.text)
              .font(.system(size: Tokens.FontSize.uiEmphasis))
              .foregroundStyle(Tokens.Color.ink2)
              .lineLimit(1)
          } else {
            Text("会议开始后，最新一行原文会出现在这里")
              .font(.system(size: Tokens.FontSize.uiEmphasis))
              .foregroundStyle(Tokens.Color.ink4)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        Image(systemName: presentation.isExpanded ? "chevron.down" : "chevron.up")
          .font(.system(size: Tokens.FontSize.micro, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink4)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, Tokens.Spacing.md)
      .frame(minHeight: Tokens.Layout.transcriptStripHeight)
      .padding(.vertical, presentation.isExpanded ? Tokens.Spacing.xxs : 0)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .hoverRowBackground(cornerRadius: 0)
    }
    .buttonStyle(.plain)
    .help(presentation.toggleLabel)
    .accessibilityLabel(presentation.toggleLabel)
    .runtimeAccessibilityIdentifier("transcript.live.toggle")
  }
}

struct TranscriptStripView: View {
  let segments: [TranscriptSegment]
  @Binding var presentation: LiveTranscriptPresentationState

  var body: some View {
    TranscriptToggleButton(presentation: $presentation, preview: segments.last)
      .background(Tokens.Color.card)
      .runtimeAccessibilityIdentifier("cockpit.transcript-strip")
  }
}
