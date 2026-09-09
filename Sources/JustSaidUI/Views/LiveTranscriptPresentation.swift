import JustSaidCore
import SwiftUI

/// 只属于当前工作台的呈现意图；正文、轨道和溯源入口共用这一份状态。
public struct LiveTranscriptPresentationState: Equatable {
  public enum Mode: Equatable { case closed, quick, pinned }

  public private(set) var mode: Mode
  public private(set) var lastVisibleMode: Mode = .quick
  public private(set) var isFollowing = true
  public private(set) var pendingJump: TranscriptJumpRequest?
  public private(set) var latestRequest = UUID()
  public private(set) var readingAnchor: LiveTranscriptRowID?
  public private(set) var highlightRequest: UUID?
  public private(set) var highlightedRow: LiveTranscriptRowID?

  public init(isExpanded: Bool = false) { mode = isExpanded ? .quick : .closed }
  public var isExpanded: Bool { mode != .closed }
  public var toggleLabel: String { isExpanded ? "收起实时转写" : "展开实时转写" }

  public mutating func toggle() {
    if isExpanded {
      close()
    } else {
      mode = lastVisibleMode
      returnToLatest()
    }
  }

  public mutating func close() {
    if isExpanded { lastVisibleMode = mode }
    mode = .closed
    invalidateReading()
  }

  public mutating func togglePin() {
    mode = mode == .pinned ? .quick : .pinned
    lastVisibleMode = mode
  }

  public mutating func show(at seconds: TimeInterval) {
    if !isExpanded { mode = lastVisibleMode }
    isFollowing = false
    pendingJump = TranscriptJumpRequest(seconds: seconds)
    readingAnchor = nil
    highlightedRow = nil
    highlightRequest = nil
  }

  public mutating func returnToLatest() {
    invalidateReading()
    latestRequest = UUID()
  }

  public mutating func userScrollBegan() {
    isFollowing = false
    pendingJump = nil
    highlightRequest = nil
    highlightedRow = nil
  }

  public mutating func userScrollEnded(anchor: LiveTranscriptRowID?, atBottom: Bool) {
    isFollowing = atBottom
    readingAnchor = atBottom ? nil : anchor
  }

  public mutating func rememberReadingAnchor(_ anchor: LiveTranscriptRowID?) {
    if !isFollowing, pendingJump == nil, let anchor { readingAnchor = anchor }
  }

  public mutating func consumeJump(_ request: TranscriptJumpRequest, row: LiveTranscriptRowID) {
    guard pendingJump?.id == request.id else { return }
    pendingJump = nil
    isFollowing = false
    readingAnchor = row
    highlightedRow = row
    highlightRequest = request.id
  }

  public mutating func clearHighlight(requestID: UUID) {
    guard highlightRequest == requestID else { return }
    highlightedRow = nil
    highlightRequest = nil
  }

  public mutating func resetForMeeting() {
    invalidateReading()
    latestRequest = UUID()
  }

  private mutating func invalidateReading() {
    isFollowing = true
    pendingJump = nil
    readingAnchor = nil
    highlightRequest = nil
    highlightedRow = nil
  }
}

/// partial 的文字增长不改变身份；同一路同一秒的碰撞按原有顺序区分。
public struct LiveTranscriptRowID: Hashable {
  public let source: AudioSource
  public let t0: TimeInterval
  public let occurrence: Int

  public static func rows(for segments: [TranscriptSegment]) -> [Self] {
    var occurrences: [AudioSource: [TimeInterval: Int]] = [:]
    return segments.map { segment in
      let occurrence = occurrences[segment.source, default: [:]][segment.t0, default: 0]
      occurrences[segment.source, default: [:]][segment.t0] = occurrence + 1
      return Self(source: segment.source, t0: segment.t0, occurrence: occurrence)
    }
  }

  public func resolved(in rows: [Self]) -> Self? {
    if rows.contains(self) { return self }
    let sameSource = rows.filter { $0.source == source }
    return (sameSource.isEmpty ? rows : sameSource).min { abs($0.t0 - t0) < abs($1.t0 - t0) }
  }
}

/// quick 覆盖两列下沿；pinned 只替换整理区正文，公共降级横幅仍在同一位置。
public struct LiveTranscriptPresentation<Header: View, Organizer: View, Sidebar: View>: View {
  @Binding var presentation: LiveTranscriptPresentationState
  var transcriptSegments: [TranscriptSegment]
  var transcriptExcludedRanges: [ExcludedRange]
  var onMarkChatFrom: ((TimeInterval) -> Void)?
  var onRemoveExclusion: ((UUID) -> Void)?
  let organizerHeader: Header
  let organizer: Organizer
  let sidebar: Sidebar

  public init(
    presentation: Binding<LiveTranscriptPresentationState>,
    transcriptSegments: [TranscriptSegment],
    transcriptExcludedRanges: [ExcludedRange] = [],
    onMarkChatFrom: ((TimeInterval) -> Void)? = nil,
    onRemoveExclusion: ((UUID) -> Void)? = nil,
    @ViewBuilder organizerHeader: () -> Header,
    @ViewBuilder organizer: () -> Organizer,
    @ViewBuilder sidebar: () -> Sidebar
  ) {
    _presentation = presentation
    self.transcriptSegments = transcriptSegments
    self.transcriptExcludedRanges = transcriptExcludedRanges
    self.onMarkChatFrom = onMarkChatFrom
    self.onRemoveExclusion = onRemoveExclusion
    self.organizerHeader = organizerHeader()
    self.organizer = organizer()
    self.sidebar = sidebar()
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          organizerHeader
          if presentation.mode == .pinned {
            transcript.runtimeAccessibilityIdentifier("cockpit.transcript-pinned")
          } else {
            organizer
          }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .runtimeAccessibilityIdentifier("dashboard.organizer")
        Divider()
        sidebar
      }
      .frame(maxHeight: .infinity)
      .overlay(alignment: .bottom) {
        if presentation.mode == .quick {
          transcript
            .frame(height: Tokens.Layout.transcriptDrawerHeight)
            .overlay(alignment: .top) { Divider() }
            .shadow(
              color: Tokens.Shadow.sh3.color, radius: Tokens.Shadow.sh3.radius,
              x: 0, y: -Tokens.Shadow.sh3.y
            )
            .runtimeAccessibilityIdentifier("cockpit.transcript-drawer")
        }
      }
      if presentation.mode == .closed {
        Divider()
        TranscriptStripView(segments: transcriptSegments, presentation: $presentation)
      }
    }
    .runtimeAccessibilityIdentifier("dashboard.two-column")
  }

  private var transcript: some View {
    TranscriptPaneView(
      segments: transcriptSegments, presentation: $presentation,
      excludedRanges: transcriptExcludedRanges,
      onMarkChatFrom: onMarkChatFrom, onRemoveExclusion: onRemoveExclusion
    )
  }
}

/// 实际控制轨按钮也用于无服务呈现验证，避免另造一套测试动作。
public struct LiveTranscriptRailButton: View {
  @Binding var presentation: LiveTranscriptPresentationState

  public init(presentation: Binding<LiveTranscriptPresentationState>) {
    _presentation = presentation
  }

  public var body: some View {
    RailButton(
      systemImage: "text.quote", label: "转写", isOn: presentation.isExpanded,
      statusDotIdentifier: nil
    ) { presentation.toggle() }
    .help(presentation.toggleLabel)
    .accessibilityLabel(presentation.toggleLabel)
    .runtimeAccessibilityIdentifier("cockpit.rail.transcript")
  }
}

/// 仅验证入口：复用实际舞台、整理区、笔记与轨道控件，不创建录音或存储服务。
@_spi(Verification)
public struct LiveTranscriptVerificationScene<Feed: SummaryFeed>: View {
  @ObservedObject var feed: Feed
  @Binding var presentation: LiveTranscriptPresentationState
  @Binding var chapterRequest: UUID?
  let segments: [TranscriptSegment]
  @StateObject private var notes = NotesController()

  public init(
    feed: Feed, presentation: Binding<LiveTranscriptPresentationState>,
    chapterRequest: Binding<UUID?>, segments: [TranscriptSegment]
  ) {
    self.feed = feed
    _presentation = presentation
    _chapterRequest = chapterRequest
    self.segments = segments
  }

  public var body: some View {
    HStack(spacing: 0) {
      VStack {
        LiveTranscriptRailButton(presentation: $presentation)
        Spacer()
      }
      .background(Tokens.Color.rail)
      VStack(spacing: 0) {
        NowPaneView(state: feed.now, onJumpToTranscript: { presentation.show(at: $0) })
          .frame(height: Tokens.Layout.nowStageHeight)
          .runtimeAccessibilityIdentifier("cockpit.now-stage")
        SummaryPaneView(
          feed: feed, notesController: notes, scrollRequest: $chapterRequest,
          onSaveSourceAsNote: { _ in }, onJumpToTranscript: { presentation.show(at: $0) },
          transcriptPresentation: $presentation, transcriptSegments: segments
        )
      }
    }
  }
}
