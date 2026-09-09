import AppKit
import JustSaidCore
import SwiftUI

/// 独立压力目标读取的轻量计数器。计数只记录真正的 attributed rebuild 与滚动提交，
/// 不参与渲染快照，因此 verification 自己不会制造额外更新。
@MainActor
public enum TranscriptTextKitDiagnostics {
  public private(set) static var attributedRebuildCount = 0
  public private(set) static var scrollCommitCount = 0
  public private(set) static var boundsChangeCount = 0
  public private(set) static var liveScrollEndCount = 0
  public private(set) static var documentBuildStartCount = 0
  public private(set) static var documentBuildCompletionCount = 0
  public private(set) static var documentBuildCancellationCount = 0
  public private(set) static var maximumCancelledDocumentBuildRowCount = 0
  public private(set) static var maximumAttributedConstructionDuration: TimeInterval = 0
  public private(set) static var maximumTextStorageInstallDuration: TimeInterval = 0

  public static func reset() {
    attributedRebuildCount = 0
    scrollCommitCount = 0
    boundsChangeCount = 0
    liveScrollEndCount = 0
    documentBuildStartCount = 0
    documentBuildCompletionCount = 0
    documentBuildCancellationCount = 0
    maximumCancelledDocumentBuildRowCount = 0
    maximumAttributedConstructionDuration = 0
    maximumTextStorageInstallDuration = 0
  }

  static func recordAttributedRebuild() {
    attributedRebuildCount += 1
  }

  static func recordScrollCommit() {
    scrollCommitCount += 1
  }

  static func recordBoundsChange() {
    boundsChangeCount += 1
  }

  static func recordLiveScrollEnd() {
    liveScrollEndCount += 1
  }

  static func recordDocumentBuildStart() {
    documentBuildStartCount += 1
  }

  static func recordDocumentBuildCompletion() {
    documentBuildCompletionCount += 1
  }

  static func recordDocumentBuildCancellation(processedRowCount: Int) {
    documentBuildCancellationCount += 1
    maximumCancelledDocumentBuildRowCount = max(
      maximumCancelledDocumentBuildRowCount,
      processedRowCount
    )
  }

  static func recordAttributedConstruction(duration: TimeInterval) {
    maximumAttributedConstructionDuration = max(maximumAttributedConstructionDuration, duration)
  }

  static func recordTextStorageInstall(duration: TimeInterval) {
    maximumTextStorageInstallDuration = max(maximumTextStorageInstallDuration, duration)
  }
}

private struct TranscriptDocumentSnapshot: Equatable, Sendable {
  let rows: [TranscriptDisplayRow]
  let speakers: [String]
  let isSpeakerFiltered: Bool
  let bodyFontSize: CGFloat
}

private struct TranscriptStyleSnapshot: Equatable, Sendable {
  let excludedRanges: [ExcludedRange]
  let excludedSpeakers: Set<String>
  let highlightedSpeaker: String?
  let selectedLineIndexes: Set<Int>
}

private struct RenderedSpeechRange: Sendable {
  let line: TranscriptSpeechLine
  let paragraphRange: NSRange
  let speakerRange: NSRange
  let timestampRange: NSRange
  let bodyRange: NSRange
  let seconds: TimeInterval?
}

/// Detached builder 的纯值结果。这里刻意不携带任何 AppKit 对象：`NSFont`、`NSColor`、
/// `NSParagraphStyle` 和 attributed string 都只在主线程安装阶段创建。
private struct BuiltTranscriptDocument: Sendable {
  let string: String
  let speechRanges: [RenderedSpeechRange]
}

private enum TranscriptDocumentBuildResult: Sendable {
  case completed(BuiltTranscriptDocument)
  case cancelled(processedRowCount: Int)
}

private struct VisibleTranscriptDecoration {
  let rendered: RenderedSpeechRange
  let paragraphRect: NSRect
  let speakerRect: NSRect?
  let timestampRect: NSRect?
}

private struct TranscriptTextActions {
  var onSelectSpeaker: (String) -> Void = { _ in }
  var onSelectTimestamp: (Int, Bool) -> Void = { _, _ in }
  var onDragTimestamp: (Int, Int) -> Void = { _, _ in }
  var onOverride: (TranscriptSpeechLine, String?) -> Void = { _, _ in }
  var onRequestNewName: (TranscriptSpeechLine) -> Void = { _ in }
  var onExcludeLine: ((TranscriptSpeechLine) -> Void)?
  /// 右键落在选区内时用的批量排除:与底部动作条同一个入口,按整个选区结算。
  var onExcludeSelection: (() -> Void)?
  var onRemoveExclusion: ((UUID) -> Void)?
  var onSetSpeakerExcluded: ((String, Bool) -> Void)?
  var beginProgrammaticScroll: () -> Void = {}
}

@MainActor
private final class TranscriptAccessibilityActionElement: NSAccessibilityElement {
  var onPress: (() -> Void)?

  override func accessibilityPerformPress() -> Bool {
    guard let onPress else { return false }
    onPress()
    return true
  }
}

/// SwiftUI 只在此 seam 与 AppKit 交接；真正的文档树始终是一份 TextKit 2 storage。
struct TranscriptTextView: NSViewRepresentable {
  let rows: [TranscriptDisplayRow]
  let speakers: [String]
  let isSpeakerFiltered: Bool
  let bodyFontSize: CGFloat
  let excludedRanges: [ExcludedRange]
  let excludedSpeakers: Set<String>
  let highlightedSpeaker: String?
  let selectedLineIndexes: Set<Int>
  let selectionAnchorIndex: Int?
  let selectionEnabled: Bool
  let reduceMotion: Bool
  let scrollOffset: Binding<CGFloat>?
  @Binding var jumpRequest: TranscriptJumpRequest?
  let onSelectSpeaker: (String) -> Void
  let onSelectTimestamp: (Int, Bool) -> Void
  let onDragTimestamp: (Int, Int) -> Void
  let onOverride: (TranscriptSpeechLine, String?) -> Void
  let onRequestNewName: (TranscriptSpeechLine) -> Void
  let onExcludeLine: ((TranscriptSpeechLine) -> Void)?
  let onExcludeSelection: (() -> Void)?
  let onRemoveExclusion: ((UUID) -> Void)?
  let onSetSpeakerExcluded: ((String, Bool) -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    let textContainer = NSTextContainer(size: .zero)
    contentStorage.addTextLayoutManager(layoutManager)
    layoutManager.textContainer = textContainer

    let textView = InteractiveTranscriptTextView(
      contentStorage: contentStorage,
      layoutManager: layoutManager,
      textContainer: textContainer
    )
    textContainer.widthTracksTextView = false
    textContainer.heightTracksTextView = false

    let scrollView = NSScrollView(frame: .zero)
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.documentView = textView

    let contentSize = scrollView.contentSize
    textView.frame = NSRect(origin: .zero, size: contentSize)
    textView.minSize = NSSize(width: 0, height: contentSize.height)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    context.coordinator.attach(to: scrollView, textView: textView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? InteractiveTranscriptTextView else { return }
    let coordinator = context.coordinator
    coordinator.updateScrollBinding(scrollOffset)
    textView.actions = TranscriptTextActions(
      onSelectSpeaker: onSelectSpeaker,
      onSelectTimestamp: onSelectTimestamp,
      onDragTimestamp: onDragTimestamp,
      onOverride: onOverride,
      onRequestNewName: onRequestNewName,
      onExcludeLine: onExcludeLine,
      onExcludeSelection: onExcludeSelection,
      onRemoveExclusion: onRemoveExclusion,
      onSetSpeakerExcluded: onSetSpeakerExcluded,
      beginProgrammaticScroll: { [weak coordinator] in
        coordinator?.beginProgrammaticScroll()
      }
    )
    textView.selectionEnabled = selectionEnabled
    textView.selectionAnchorIndex = selectionAnchorIndex

    let documentSnapshot = TranscriptDocumentSnapshot(
      rows: rows,
      speakers: speakers,
      isSpeakerFiltered: isSpeakerFiltered,
      bodyFontSize: bodyFontSize
    )
    let styleSnapshot = TranscriptStyleSnapshot(
      excludedRanges: excludedRanges,
      excludedSpeakers: excludedSpeakers,
      highlightedSpeaker: highlightedSpeaker,
      selectedLineIndexes: selectedLineIndexes
    )
    coordinator.updateDocument(
      snapshot: documentSnapshot,
      style: styleSnapshot,
      in: textView
    )

    coordinator.restoreIfNeeded(pendingJump: jumpRequest != nil)
    if let request = jumpRequest, coordinator.lastJumpID != request.id {
      coordinator.lastJumpID = request.id
      let jumpBinding = $jumpRequest
      Task { @MainActor in
        guard jumpBinding.wrappedValue?.id == request.id else { return }
        jumpBinding.wrappedValue = nil
      }
      coordinator.requestJump(request, in: textView, reduceMotion: reduceMotion)
    }
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.detach()
  }

  @MainActor
  final class Coordinator {
    fileprivate var documentSnapshot: TranscriptDocumentSnapshot?
    fileprivate var styleSnapshot: TranscriptStyleSnapshot?
    fileprivate var lastJumpID: UUID?

    private weak var scrollView: NSScrollView?
    private weak var textView: InteractiveTranscriptTextView?
    private var documentTask: Task<Void, Never>?
    private var documentGeneration: UUID?
    private var pendingDocumentSnapshot: TranscriptDocumentSnapshot?
    private var desiredStyleSnapshot: TranscriptStyleSnapshot?
    private var pendingJump: (request: TranscriptJumpRequest, reduceMotion: Bool)?
    private var pendingRestoreOffset: CGFloat?
    private var observers: [NSObjectProtocol] = []
    private var idleCommit: DispatchWorkItem?
    /// A cancelled DispatchWorkItem can already be queued on the main queue.  Keep a
    /// monotonic generation beside cancellation so an old bounds callback can never
    /// commit after a newer live-scroll phase has started or ended.
    private var idleCommitGeneration: UInt = 0
    private var viewportRefreshPending = false
    private var viewportRefreshInstallChromePending = false
    private var jumpClear: DispatchWorkItem?
    private var latestOffset: CGFloat?
    private var didRestore = false
    private var isLiveScrolling = false
    private var isProgrammaticScrolling = false
    private var programmaticScrollGeneration: UInt = 0
    private var currentOffset: () -> CGFloat = { 0 }
    private var commitOffset: ((CGFloat) -> Void)?

    fileprivate func attach(to scrollView: NSScrollView, textView: InteractiveTranscriptTextView) {
      self.scrollView = scrollView
      self.textView = textView
      let center = NotificationCenter.default
      scrollView.contentView.postsBoundsChangedNotifications = true
      observers.append(
        center.addObserver(
          forName: NSView.boundsDidChangeNotification,
          object: scrollView.contentView,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.boundsDidChange() }
        }
      )
      observers.append(
        center.addObserver(
          forName: NSScrollView.willStartLiveScrollNotification,
          object: scrollView,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.isLiveScrolling = true
            self?.invalidateIdleCommit()
          }
        }
      )
      observers.append(
        center.addObserver(
          forName: NSScrollView.didEndLiveScrollNotification,
          object: scrollView,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.isLiveScrolling = false
            self?.invalidateIdleCommit()
            TranscriptTextKitDiagnostics.recordLiveScrollEnd()
            self?.textView?.refreshViewportDecorations(installChrome: true)
            self?.commitLatestOffset()
          }
        }
      )
    }

    func detach() {
      documentTask?.cancel()
      documentGeneration = nil
      invalidateIdleCommit()
      programmaticScrollGeneration &+= 1
      viewportRefreshPending = false
      viewportRefreshInstallChromePending = false
      jumpClear?.cancel()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers.removeAll()
    }

    func updateScrollBinding(_ binding: Binding<CGFloat>?) {
      currentOffset = { binding?.wrappedValue ?? 0 }
      commitOffset = binding.map { binding in
        { binding.wrappedValue = $0 }
      }
    }

    fileprivate func updateDocument(
      snapshot: TranscriptDocumentSnapshot,
      style: TranscriptStyleSnapshot,
      in textView: InteractiveTranscriptTextView
    ) {
      desiredStyleSnapshot = style
      if documentSnapshot == snapshot {
        // The desired snapshot may have returned to the installed value while a
        // different document is still building (A -> B -> A).  Cancel B before it
        // can win its generation guards and overwrite A after this update returns.
        if pendingDocumentSnapshot != nil {
          documentTask?.cancel()
          documentTask = nil
          pendingDocumentSnapshot = nil
          documentGeneration = nil
        }
        if styleSnapshot != style {
          textView.updateStyle(from: styleSnapshot, to: style)
          styleSnapshot = style
        }
        return
      }
      guard pendingDocumentSnapshot != snapshot else { return }
      documentTask?.cancel()
      pendingDocumentSnapshot = snapshot
      let generation = UUID()
      documentGeneration = generation
      TranscriptTextKitDiagnostics.recordDocumentBuildStart()
      let buildTask = Task.detached(priority: .userInitiated) {
        TranscriptDocumentBuilder.build(snapshot: snapshot)
      }
      documentTask = Task { [weak self, weak textView] in
        let result = await withTaskCancellationHandler {
          await buildTask.value
        } onCancel: {
          buildTask.cancel()
        }
        guard case .completed(let document) = result else {
          guard case .cancelled(let processedRowCount) = result else { return }
          TranscriptTextKitDiagnostics.recordDocumentBuildCancellation(
            processedRowCount: processedRowCount
          )
          return
        }
        TranscriptTextKitDiagnostics.recordDocumentBuildCompletion()
        guard !Task.isCancelled,
          let self,
          let textView,
          self.pendingDocumentSnapshot == snapshot,
          self.documentGeneration == generation
        else { return }
        let latestStyle = self.desiredStyleSnapshot ?? style
        textView.install(document, snapshot: snapshot, style: latestStyle)
        self.documentSnapshot = snapshot
        self.styleSnapshot = latestStyle
        self.pendingDocumentSnapshot = nil
        self.documentGeneration = nil
        self.documentTask = nil
        if self.pendingJump != nil {
          self.pendingRestoreOffset = nil
          self.performPendingJump(in: textView)
        } else {
          self.performPendingRestore()
        }
      }
    }

    func restoreIfNeeded(pendingJump: Bool) {
      guard !didRestore else { return }
      didRestore = true
      guard !pendingJump else { return }
      let offset = currentOffset()
      guard offset > 0.5 else { return }
      guard documentSnapshot != nil, pendingDocumentSnapshot == nil else {
        pendingRestoreOffset = offset
        return
      }
      restore(to: offset)
    }

    private func performPendingRestore() {
      guard let offset = pendingRestoreOffset else { return }
      pendingRestoreOffset = nil
      restore(to: offset)
    }

    private func restore(to offset: CGFloat) {
      guard let scrollView else { return }
      beginProgrammaticScroll()
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func beginProgrammaticScroll() {
      isProgrammaticScrolling = true
      programmaticScrollGeneration &+= 1
      let generation = programmaticScrollGeneration
      latestOffset = nil
      invalidateIdleCommit()
      let suppressionDuration = Tokens.Motion.scroll + Tokens.Motion.listShift
      DispatchQueue.main.asyncAfter(deadline: .now() + suppressionDuration) { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.programmaticScrollGeneration == generation else { return }
          self.latestOffset = nil
          self.invalidateIdleCommit()
          self.isProgrammaticScrolling = false
          self.textView?.refreshViewportDecorations(installChrome: true)
        }
      }
    }

    fileprivate func requestJump(
      _ request: TranscriptJumpRequest,
      in textView: InteractiveTranscriptTextView,
      reduceMotion: Bool
    ) {
      guard documentSnapshot != nil, pendingDocumentSnapshot == nil else {
        pendingJump = (request, reduceMotion)
        return
      }
      performJump(request, in: textView, reduceMotion: reduceMotion)
    }

    private func performPendingJump(in textView: InteractiveTranscriptTextView) {
      guard let pendingJump else { return }
      self.pendingJump = nil
      performJump(
        pendingJump.request,
        in: textView,
        reduceMotion: pendingJump.reduceMotion
      )
    }

    private func performJump(
      _ request: TranscriptJumpRequest,
      in textView: InteractiveTranscriptTextView,
      reduceMotion: Bool
    ) {
      guard let target = textView.nearestSpeechRange(to: request.seconds) else { return }
      jumpClear?.cancel()
      textView.setJumpLine(target.line.index)
      textView.scrollToCenter(target, animated: !reduceMotion)
      let lineIndex = target.line.index
      let clear = DispatchWorkItem { [weak textView] in
        MainActor.assumeIsolated {
          guard textView?.jumpLineIndex == lineIndex else { return }
          textView?.setJumpLine(nil)
        }
      }
      jumpClear = clear
      DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.sweep, execute: clear)
    }

    private func boundsDidChange() {
      TranscriptTextKitDiagnostics.recordBoundsChange()
      guard !isProgrammaticScrolling, let scrollView else { return }
      latestOffset = scrollView.contentView.bounds.minY
      scheduleViewportRefresh()
      invalidateIdleCommit()
      let generation = idleCommitGeneration
      let work = DispatchWorkItem { [weak self] in
        MainActor.assumeIsolated {
          guard let self,
            self.idleCommitGeneration == generation,
            self.isLiveScrolling == false,
            self.isProgrammaticScrolling == false
          else { return }
          self.textView?.refreshViewportDecorations(installChrome: true)
          self.commitLatestOffset()
        }
      }
      idleCommit = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.listShift, execute: work)
    }

    /// Bounds notifications can arrive many times per display frame.  Refresh chrome
    /// geometry once on the next main-queue turn while keeping offset persistence on
    /// the independent end-live-scroll/idle path.
    private func scheduleViewportRefresh(installChrome: Bool = false) {
      viewportRefreshInstallChromePending =
        viewportRefreshInstallChromePending || installChrome
      guard !viewportRefreshPending else { return }
      viewportRefreshPending = true
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.viewportRefreshPending else { return }
          let installChrome = self.viewportRefreshInstallChromePending
          self.viewportRefreshPending = false
          self.viewportRefreshInstallChromePending = false
          self.textView?.refreshViewportDecorations(installChrome: installChrome)
        }
      }
    }

    private func invalidateIdleCommit() {
      idleCommit?.cancel()
      idleCommit = nil
      idleCommitGeneration &+= 1
    }

    private func commitLatestOffset() {
      invalidateIdleCommit()
      guard
        !isProgrammaticScrolling,
        let offset = latestOffset,
        let commitOffset,
        abs(currentOffset() - offset) > 0.5
      else {
        latestOffset = nil
        return
      }
      latestOffset = nil
      commitOffset(offset)
      HangSentinel.shared.note("scroll-commit:\(Int(offset))")
      TranscriptTextKitDiagnostics.recordScrollCommit()
    }
  }
}

private enum TranscriptDocumentBuilder {
  static func build(snapshot: TranscriptDocumentSnapshot) -> TranscriptDocumentBuildResult {
    var output = ""
    var utf16Length = 0
    var speechRanges: [RenderedSpeechRange] = []

    // AppKit's character ranges are UTF-16 based. Track that offset explicitly while building a
    // Swift String so this detached phase stays Foundation-value-only and does not repeatedly walk
    // the accumulated string.
    func append(_ value: String) -> Int {
      let start = utf16Length
      output.append(value)
      utf16Length += value.utf16.count
      return start
    }

    for (rowIndex, row) in snapshot.rows.enumerated() {
      if rowIndex.isMultiple(of: 256), Task.isCancelled {
        return .cancelled(processedRowCount: rowIndex)
      }
      switch row {
      case .plain(let text):
        _ = append(text)
        _ = append("\n")
      case .speech(let line):
        let paragraphStart = utf16Length
        let speakerStart = append(line.speaker)
        let speakerRange = NSRange(
          location: speakerStart,
          length: line.speaker.utf16.count
        )
        _ = append("  ")
        let timestampStart = append(line.timestamp)
        let timestampRange = NSRange(
          location: timestampStart,
          length: line.timestamp.utf16.count
        )
        _ = append("  \n")
        let bodyStart = append(line.text)
        _ = append("\n")
        let bodyRange = NSRange(
          location: bodyStart,
          length: line.text.utf16.count + 1
        )
        speechRanges.append(
          RenderedSpeechRange(
            line: line,
            paragraphRange: NSRange(
              location: paragraphStart,
              length: utf16Length - paragraphStart
            ),
            speakerRange: speakerRange,
            timestampRange: timestampRange,
            bodyRange: bodyRange,
            seconds: TranscriptAnchor(timecode: line.timestamp).seconds
          )
        )
      }
    }
    guard !Task.isCancelled else {
      return .cancelled(processedRowCount: snapshot.rows.count)
    }
    return .completed(
      BuiltTranscriptDocument(
        string: output,
        speechRanges: speechRanges
      )
    )
  }
}

@MainActor
private final class InteractiveTranscriptTextView: NSTextView {
  let transcriptContentStorage: NSTextContentStorage
  let transcriptLayoutManager: NSTextLayoutManager
  let transcriptTextContainer: NSTextContainer

  var actions = TranscriptTextActions()
  var selectionEnabled = false
  var selectionAnchorIndex: Int?
  private(set) var jumpLineIndex: Int?

  private var documentSnapshot: TranscriptDocumentSnapshot?
  private var styleSnapshot = TranscriptStyleSnapshot(
    excludedRanges: [],
    excludedSpeakers: [],
    highlightedSpeaker: nil,
    selectedLineIndexes: []
  )
  private var speechRanges: [RenderedSpeechRange] = []
  private var speechRangeByLineIndex: [Int: RenderedSpeechRange] = [:]
  /// Rendering attributes are installed only for the current viewport. Keeping this set lets us
  /// invalidate just the ranges that changed as the user scrolls or toggles exclusion state.
  private var excludedRenderingLineIndexes: Set<Int> = []
  private var chromeAttributeLineIndexes: Set<Int> = []
  private var lineSelectionAnchor: Int?
  private var menuActions: [() -> Void] = []
  private var markerViews: [NSView] = []
  private var visibleDecorations: [VisibleTranscriptDecoration] = []
  private var markerRefreshPending = false
  private var viewportRefreshPending = false
  private var viewportRefreshInstallChromePending = false
  private let speakerAccessibilityElement = TranscriptAccessibilityActionElement()
  private let timestampAccessibilityElement = TranscriptAccessibilityActionElement()
  private var exposesAccessibilityChrome = false

  init(
    contentStorage: NSTextContentStorage,
    layoutManager: NSTextLayoutManager,
    textContainer: NSTextContainer
  ) {
    transcriptContentStorage = contentStorage
    transcriptLayoutManager = layoutManager
    transcriptTextContainer = textContainer
    super.init(frame: .zero, textContainer: textContainer)
    isEditable = false
    isSelectable = true
    isRichText = false
    importsGraphics = false
    drawsBackground = false
    backgroundColor = .clear
    allowsUndo = false
    usesFindBar = true
    isIncrementalSearchingEnabled = true
    isContinuousSpellCheckingEnabled = false
    isGrammarCheckingEnabled = false
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticLinkDetectionEnabled = false
    isAutomaticDataDetectionEnabled = false
    linkTextAttributes = [:]
    identifier = NSUserInterfaceItemIdentifier("transcript.document.body")
    setAccessibilityElement(true)
    setAccessibilityIdentifier("transcript.document.body")
    setAccessibilityLabel("完整转写正文")
    speakerAccessibilityElement.setAccessibilityParent(self)
    speakerAccessibilityElement.setAccessibilityRole(.button)
    speakerAccessibilityElement.setAccessibilityIdentifier("transcript.document.speaker")
    timestampAccessibilityElement.setAccessibilityParent(self)
    timestampAccessibilityElement.setAccessibilityRole(.button)
    timestampAccessibilityElement.setAccessibilityIdentifier(
      "transcript.document.chrome.timestamp"
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func accessibilityChildren() -> [Any]? {
    let nativeChildren = super.accessibilityChildren() ?? []
    guard exposesAccessibilityChrome else { return nativeChildren }
    return nativeChildren + [speakerAccessibilityElement, timestampAccessibilityElement]
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    let horizontalInset = Tokens.Spacing.lg
    let contentWidth = min(
      Tokens.Layout.readingContentWidth,
      max(0, newSize.width - horizontalInset * 2)
    )
    let inset = NSSize(width: horizontalInset, height: Tokens.Spacing.md)
    let containerSize = NSSize(
      width: contentWidth,
      height: CGFloat.greatestFiniteMagnitude
    )
    var needsViewportRefresh = false
    if textContainerInset != inset {
      textContainerInset = inset
      needsViewportRefresh = true
    }
    if transcriptTextContainer.containerSize != containerSize {
      transcriptTextContainer.containerSize = containerSize
      needsViewportRefresh = true
    }
    if needsViewportRefresh {
      scheduleViewportRefresh()
    }
  }

  func install(
    _ document: BuiltTranscriptDocument,
    snapshot: TranscriptDocumentSnapshot,
    style: TranscriptStyleSnapshot
  ) {
    let constructionStart = ProcessInfo.processInfo.systemUptime
    let attributedString = makeAttributedString(
      from: document,
      bodyFontSize: snapshot.bodyFontSize
    )
    TranscriptTextKitDiagnostics.recordAttributedConstruction(
      duration: ProcessInfo.processInfo.systemUptime - constructionStart
    )
    let installStart = ProcessInfo.processInfo.systemUptime
    let seededRanges = document.speechRanges.prefix(128)
    transcriptContentStorage.performEditingTransaction {
      guard let storage = transcriptContentStorage.textStorage else { return }
      storage.setAttributedString(attributedString)
      addChromeAttributes(for: seededRanges, speakers: snapshot.speakers, to: storage)
    }
    TranscriptTextKitDiagnostics.recordTextStorageInstall(
      duration: ProcessInfo.processInfo.systemUptime - installStart
    )
    documentSnapshot = snapshot
    speechRanges = document.speechRanges
    speechRangeByLineIndex = Dictionary(
      uniqueKeysWithValues: document.speechRanges.map { ($0.line.index, $0) }
    )
    styleSnapshot = style
    jumpLineIndex = nil
    excludedRenderingLineIndexes.removeAll(keepingCapacity: true)
    chromeAttributeLineIndexes = Set(seededRanges.map(\.line.index))
    scheduleMarkerRefresh()
    scheduleViewportRefresh(installChrome: true)
    TranscriptTextKitDiagnostics.recordAttributedRebuild()
  }

  /// TextKit storage is MainActor-owned. Keep all AppKit object construction here, after the
  /// detached phase has produced only the document string and primitive character ranges.
  private func makeAttributedString(
    from document: BuiltTranscriptDocument,
    bodyFontSize: CGFloat
  ) -> NSAttributedString {
    let bodyFont = NSFont.systemFont(ofSize: bodyFontSize)
    let bodyStyle = NSMutableParagraphStyle()
    bodyStyle.paragraphSpacing = Tokens.Spacing.xxs
    let attributedString = NSMutableAttributedString(
      string: document.string,
      attributes: [
        .font: bodyFont,
        .foregroundColor: NSColor(Tokens.Color.ink2),
        .paragraphStyle: bodyStyle,
      ]
    )
    return attributedString
  }

  private func addChromeAttributes(
    for ranges: some Sequence<RenderedSpeechRange>,
    speakers: [String],
    to storage: NSMutableAttributedString
  ) {
    let speakerFont = NSFont.systemFont(ofSize: Tokens.FontSize.secondary, weight: .bold)
    let timestampFont = NSFont.monospacedSystemFont(
      ofSize: Tokens.FontSize.badge,
      weight: .regular
    )
    let timestampColor = NSColor(Tokens.Color.ink4)
    for range in ranges {
      storage.addAttributes(
        [
          .font: speakerFont,
          .foregroundColor: NSColor(
            SpeakerAccents.color(for: range.line.speaker, in: speakers)
          ),
        ],
        range: range.speakerRange
      )
      storage.addAttributes(
        [
          .font: timestampFont,
          .foregroundColor: timestampColor,
        ],
        range: range.timestampRange
      )
    }
  }

  func updateStyle(
    from old: TranscriptStyleSnapshot?,
    to new: TranscriptStyleSnapshot
  ) {
    _ = old
    styleSnapshot = new
    scheduleMarkerRefresh()
    scheduleViewportRefresh()
  }

  func setJumpLine(_ lineIndex: Int?) {
    jumpLineIndex = lineIndex
    scheduleViewportRefresh()
  }

  /// AppKit geometry/accessibility mutation must not happen synchronously inside
  /// `NSViewRepresentable.updateNSView` or `setFrameSize`; doing so feeds an invalidation
  /// back into SwiftUI's current AttributeGraph transaction. Defer both marker subviews and
  /// visible-range measurement to the next main-queue turn.
  private func scheduleMarkerRefresh() {
    guard !markerRefreshPending else { return }
    markerRefreshPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.markerRefreshPending = false
      self.refreshMarkers()
    }
  }

  private func scheduleViewportRefresh(installChrome: Bool = false) {
    viewportRefreshInstallChromePending =
      viewportRefreshInstallChromePending || installChrome
    guard !viewportRefreshPending else { return }
    viewportRefreshPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let installChrome = self.viewportRefreshInstallChromePending
      self.viewportRefreshPending = false
      self.viewportRefreshInstallChromePending = false
      self.refreshViewportDecorations(installChrome: installChrome)
    }
  }

  func nearestSpeechRange(to seconds: TimeInterval) -> RenderedSpeechRange? {
    speechRanges.compactMap { range -> (RenderedSpeechRange, TimeInterval)? in
      guard let lineSeconds = range.seconds else { return nil }
      return (range, lineSeconds)
    }.min { lhs, rhs in
      abs(lhs.1 - seconds) < abs(rhs.1 - seconds)
    }?.0
  }

  func scrollToCenter(_ range: RenderedSpeechRange, animated: Bool) {
    guard let scrollView = enclosingScrollView else { return }
    actions.beginProgrammaticScroll()
    scrollRangeToVisible(range.bodyRange)
    layoutSubtreeIfNeeded()
    guard let localRect = localRect(for: range.bodyRange) else { return }
    let clipView = scrollView.contentView
    let maximumY = max(0, bounds.height - clipView.bounds.height)
    let targetY = min(maximumY, max(0, localRect.midY - clipView.bounds.height / 2))
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Tokens.Motion.scroll
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        clipView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
      }
    } else {
      clipView.scroll(to: NSPoint(x: 0, y: targetY))
      scrollView.reflectScrolledClipView(clipView)
    }
  }

  override func mouseDown(with event: NSEvent) {
    let characterIndex = characterIndex(at: event)
    if let range = speechRange(at: characterIndex) {
      if selectionEnabled, NSLocationInRange(characterIndex, range.timestampRange) {
        let shiftPressed = event.modifierFlags.contains(.shift)
        lineSelectionAnchor =
          shiftPressed
          ? selectionAnchorIndex ?? range.line.index
          : range.line.index
        actions.onSelectTimestamp(range.line.index, shiftPressed)
        trackTimestampSelection(from: event)
        return
      }
      if NSLocationInRange(characterIndex, range.speakerRange) {
        // Let NSTextView own double-click and drag selection starting on the speaker name.  A
        // simple click still selects the speaker once the native gesture has completed.
        super.mouseDown(with: event)
        if selectedRange().length == 0 {
          actions.onSelectSpeaker(range.line.speaker)
        }
        return
      }
    }
    super.mouseDown(with: event)
  }

  private func trackTimestampSelection(from mouseDown: NSEvent) {
    guard let window else { return }
    let eventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
    while let next = window.nextEvent(matching: eventMask) {
      switch next.type {
      case .leftMouseDragged:
        mouseDragged(with: next)
      case .leftMouseUp:
        mouseUp(with: next)
        return
      default:
        continue
      }
    }
    lineSelectionAnchor = nil
  }

  override func mouseDragged(with event: NSEvent) {
    guard let anchor = lineSelectionAnchor else {
      super.mouseDragged(with: event)
      return
    }
    // 拖出视口:先滚屏、再排版、最后才把命中点夹回可见区去问位置。
    //
    // TextKit 2 只为当前视口物化 fragment,直接拿视口外的点问 `characterIndexForInsertion`
    // 会解析成**文档末尾**(与 `visibleSpeechRanges()` 顶边同一个陷阱),焦点一跳到底,
    // 选区把后面的全文都吞进去——issue #25 的「继续拖拽会把剩下来的所有内容全部选上」。
    // 夹回可见区后焦点停在当前可见的首/末行,autoscroll 把下一屏搬进视口,下一个拖拽
    // 事件接着往下延伸,锚点始终不动,跨页因此连续。
    autoscroll(with: event)
    transcriptLayoutManager.ensureLayout(for: visibleRect)
    let point = clampedToVisibleContent(convert(event.locationInWindow, from: nil))
    guard let target = speechRange(nearest: point) else { return }
    actions.onDragTimestamp(anchor, target.line.index)
  }

  /// 把点夹进当前可见区。贴边退 1pt:正好落在边界上会解析到相邻行。
  private func clampedToVisibleContent(_ point: NSPoint) -> NSPoint {
    let visible = visibleRect
    guard visible.width > 2, visible.height > 2 else { return point }
    let inset = visible.insetBy(dx: 1, dy: 1)
    return NSPoint(
      x: min(max(point.x, inset.minX), inset.maxX),
      y: min(max(point.y, inset.minY), inset.maxY)
    )
  }

  /// 视口内某点落在哪一段。顶边那一格必须**绕开**插入点查询:贴着 textContainerInset
  /// 问 `characterIndexForInsertion` 同样会拿到文档末尾(`visibleSpeechRanges()` 记的
  /// 就是这条),向上拖出视口时选区因此一路甩到全文末段。那一格直接取当前视口的首段。
  private func speechRange(nearest point: NSPoint) -> RenderedSpeechRange? {
    if point.y <= textContainerInset.height {
      return visibleSpeechRanges().first ?? speechRanges.first
    }
    return nearestSpeechRange(toCharacterIndex: characterIndexForInsertion(at: point))
  }

  override func mouseUp(with event: NSEvent) {
    guard lineSelectionAnchor != nil else {
      super.mouseUp(with: event)
      return
    }
    lineSelectionAnchor = nil
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let characterIndex = characterIndex(at: event)
    guard let rendered = speechRange(at: characterIndex) else {
      return copyMenu()
    }
    menuActions.removeAll(keepingCapacity: true)
    let menu = NSMenu()
    let line = rendered.line
    let coveringRange = rendered.seconds.flatMap {
      ExclusionUI.coveringRange(at: $0, in: styleSnapshot.excludedRanges)
    }
    let isSpeakerExcluded = styleSnapshot.excludedSpeakers.contains(line.originalSpeaker)

    if let coveringRange, let onRemoveExclusion = actions.onRemoveExclusion {
      addInformation("这段已被排除，不进纪要", to: menu)
      addAction("撤销这段的排除", to: menu) { onRemoveExclusion(coveringRange.id) }
      menu.addItem(.separator())
    } else if isSpeakerExcluded,
      let onSetSpeakerExcluded = actions.onSetSpeakerExcluded
    {
      addInformation("「\(line.originalSpeaker)」已整体排除，不进纪要", to: menu)
      addAction("恢复此人的纪要参与", to: menu) {
        onSetSpeakerExcluded(line.originalSpeaker, false)
      }
      menu.addItem(.separator())
    } else if let onExcludeSelection = actions.onExcludeSelection,
      styleSnapshot.selectedLineIndexes.count > 1,
      styleSnapshot.selectedLineIndexes.contains(line.index)
    {
      // 右键落在选区里就按整个选区标(与底部动作条同一条记录、同一个计数);
      // 落在选区外仍旧只标这一段——不把无关的选区拖下水。
      addAction(
        "所选 \(styleSnapshot.selectedLineIndexes.count) 段不进纪要（排除）",
        to: menu
      ) { onExcludeSelection() }
      menu.addItem(.separator())
    } else if let onExcludeLine = actions.onExcludeLine {
      addAction("这段话不进纪要（排除）", to: menu) { onExcludeLine(line) }
      menu.addItem(.separator())
    }

    addInformation("这段现在记在「\(line.speaker)」名下", to: menu)
    menu.addItem(.separator())
    if let snapshot = documentSnapshot {
      for candidate in snapshot.speakers where candidate != line.speaker {
        addAction("改成「\(candidate)」", to: menu) { [actions] in
          actions.onOverride(line, candidate)
        }
      }
    }
    addAction("新名字…", to: menu) { [actions] in actions.onRequestNewName(line) }
    if line.speaker != line.originalSpeaker {
      menu.addItem(.separator())
      addAction("撤销这段的更正（回到「\(line.originalSpeaker)」）", to: menu) { [actions] in
        actions.onOverride(line, nil)
      }
    }
    menu.addItem(.separator())
    addCopyItem(to: menu)
    return menu
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    for decoration in visibleDecorations {
      if let speakerRect = decoration.speakerRect {
        addCursorRect(speakerRect, cursor: .pointingHand)
      }
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let snapshot = styleSnapshot
    let decorations = visibleDecorations
    for decoration in decorations {
      let range = decoration.rendered
      if let background = backgroundColor(for: range, snapshot: snapshot) {
        background.setFill()
        decoration.paragraphRect.fill()
      }
    }

    super.draw(dirtyRect)
    for decoration in decorations {
      let range = decoration.rendered
      if snapshot.highlightedSpeaker == range.line.speaker {
        NSColor(
          SpeakerAccents.color(for: range.line.speaker, in: documentSnapshot?.speakers ?? [])
        ).setFill()
        NSRect(
          x: decoration.paragraphRect.minX - Tokens.Spacing.xs,
          y: decoration.paragraphRect.minY,
          width: Tokens.Layout.accentEdgeWidth,
          height: decoration.paragraphRect.height
        ).fill()
      }
      if isExcluded(range, snapshot: snapshot),
        let timestampRect = decoration.timestampRect
      {
        let attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: Tokens.FontSize.micro, weight: .semibold),
          .foregroundColor: NSColor(Tokens.Color.ink4).withAlphaComponent(0.45),
        ]
        NSString(string: "不进纪要").draw(
          at: NSPoint(x: timestampRect.maxX + Tokens.Spacing.xxs, y: timestampRect.minY),
          withAttributes: attributes
        )
      }
    }
  }

  @objc private func performMenuAction(_ sender: NSMenuItem) {
    guard let index = sender.representedObject as? Int, menuActions.indices.contains(index) else {
      return
    }
    menuActions[index]()
  }

  private func addAction(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
    let index = menuActions.count
    menuActions.append(action)
    let item = NSMenuItem(
      title: title,
      action: #selector(performMenuAction(_:)),
      keyEquivalent: ""
    )
    item.target = self
    item.representedObject = index
    menu.addItem(item)
  }

  private func addInformation(_ title: String, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
  }

  private func isExcluded(
    _ range: RenderedSpeechRange,
    snapshot: TranscriptStyleSnapshot
  ) -> Bool {
    snapshot.excludedSpeakers.contains(range.line.originalSpeaker)
      || range.seconds.map {
        ExclusionUI.coveringRange(at: $0, in: snapshot.excludedRanges) != nil
      } == true
  }

  private func updateExcludedForeground(for visibleRanges: ArraySlice<RenderedSpeechRange>) {
    let visibleExcluded = Set(
      visibleRanges.compactMap { range in
        isExcluded(range, snapshot: styleSnapshot) ? range.line.index : nil
      }
    )
    let changed = excludedRenderingLineIndexes.symmetricDifference(visibleExcluded)
    let manager = transcriptLayoutManager
    for lineIndex in changed {
      guard let range = speechRangeByLineIndex[lineIndex],
        let textRange = textRange(for: range.paragraphRange)
      else { continue }
      // Remove the old viewport-only rendering attribute before invalidating. Without this,
      // undoing an exclusion leaves the previous alpha foreground attached to the range.
      manager.removeRenderingAttribute(.foregroundColor, for: textRange)
      manager.invalidateRenderingAttributes(for: textRange)
    }
    let excludedColor = NSColor(Tokens.Color.ink2).withAlphaComponent(0.45)
    for lineIndex in visibleExcluded.subtracting(excludedRenderingLineIndexes) {
      guard let range = speechRangeByLineIndex[lineIndex],
        let paragraphTextRange = textRange(for: range.paragraphRange),
        let speakerTextRange = textRange(for: range.speakerRange),
        let timestampTextRange = textRange(for: range.timestampRange)
      else { continue }
      manager.addRenderingAttribute(
        .foregroundColor,
        value: excludedColor,
        for: paragraphTextRange
      )
      manager.addRenderingAttribute(
        .foregroundColor,
        value: NSColor(
          SpeakerAccents.color(
            for: range.line.speaker,
            in: documentSnapshot?.speakers ?? []
          )
        ).withAlphaComponent(0.45),
        for: speakerTextRange
      )
      manager.addRenderingAttribute(
        .foregroundColor,
        value: NSColor(Tokens.Color.ink4).withAlphaComponent(0.45),
        for: timestampTextRange
      )
    }
    excludedRenderingLineIndexes = visibleExcluded
  }

  private func textRange(for range: NSRange) -> NSTextRange? {
    guard
      let start = transcriptContentStorage.location(
        transcriptContentStorage.documentRange.location,
        offsetBy: range.location
      ),
      let end = transcriptContentStorage.location(start, offsetBy: range.length)
    else { return nil }
    return NSTextRange(location: start, end: end)
  }

  private func backgroundColor(
    for range: RenderedSpeechRange,
    snapshot: TranscriptStyleSnapshot
  ) -> NSColor? {
    if jumpLineIndex == range.line.index {
      return NSColor(Tokens.Color.acSoft)
    }
    if snapshot.selectedLineIndexes.contains(range.line.index) {
      return NSColor(Tokens.Color.me).withAlphaComponent(0.10)
    }
    if snapshot.highlightedSpeaker == range.line.speaker {
      return NSColor(
        SpeakerAccents.color(for: range.line.speaker, in: documentSnapshot?.speakers ?? [])
      ).withAlphaComponent(0.12)
    }
    return nil
  }

  private func copyMenu() -> NSMenu {
    let menu = NSMenu()
    addCopyItem(to: menu)
    return menu
  }

  private func addCopyItem(to menu: NSMenu) {
    let item = NSMenuItem(title: "复制", action: #selector(NSTextView.copy(_:)), keyEquivalent: "c")
    item.target = self
    item.isEnabled = selectedRange().length > 0
    menu.addItem(item)
  }

  private func characterIndex(at event: NSEvent) -> Int {
    characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
  }

  private func speechRange(at characterIndex: Int) -> RenderedSpeechRange? {
    var lower = 0
    var upper = speechRanges.count
    while lower < upper {
      let middle = (lower + upper) / 2
      let range = speechRanges[middle]
      if characterIndex < range.paragraphRange.location {
        upper = middle
      } else if characterIndex >= NSMaxRange(range.paragraphRange) {
        lower = middle + 1
      } else {
        return range
      }
    }
    return nil
  }

  private func nearestSpeechRange(toCharacterIndex characterIndex: Int) -> RenderedSpeechRange? {
    if let exact = speechRange(at: characterIndex) { return exact }
    return speechRanges.min { lhs, rhs in
      distance(from: characterIndex, to: lhs.paragraphRange)
        < distance(from: characterIndex, to: rhs.paragraphRange)
    }
  }

  private func distance(from location: Int, to range: NSRange) -> Int {
    if location < range.location { return range.location - location }
    if location >= NSMaxRange(range) { return location - NSMaxRange(range) }
    return 0
  }

  private func visibleSpeechRanges() -> ArraySlice<RenderedSpeechRange> {
    guard !speechRanges.isEmpty else { return [] }
    let visible = visibleRect
    // At the top edge AppKit's insertion lookup can resolve to the document end
    // while TextKit is still materializing the first fragment. Keep the first
    // viewport anchored to the first speech range instead of hiding chrome until
    // a later bounds change.
    let firstCharacter: Int
    if visible.minY <= textContainerInset.height {
      firstCharacter = 0
    } else {
      firstCharacter = characterIndexForInsertion(
        at: NSPoint(x: textContainerInset.width, y: visible.minY)
      )
    }
    let lastCharacter = characterIndexForInsertion(
      at: NSPoint(x: textContainerInset.width, y: visible.maxY)
    )
    var firstIndex = 0
    var upper = speechRanges.count
    while firstIndex < upper {
      let middle = (firstIndex + upper) / 2
      if NSMaxRange(speechRanges[middle].paragraphRange) < firstCharacter {
        firstIndex = middle + 1
      } else {
        upper = middle
      }
    }
    var lastIndex = firstIndex
    while lastIndex < speechRanges.count,
      speechRanges[lastIndex].paragraphRange.location <= lastCharacter
    {
      lastIndex += 1
    }
    return speechRanges[firstIndex..<lastIndex]
  }

  private func localRect(for range: NSRange) -> NSRect? {
    guard
      let start = transcriptContentStorage.location(
        transcriptContentStorage.documentRange.location,
        offsetBy: range.location
      ),
      let end = transcriptContentStorage.location(start, offsetBy: range.length),
      let textRange = NSTextRange(location: start, end: end)
    else { return nil }
    transcriptLayoutManager.ensureLayout(for: textRange)
    var union = NSRect.null
    transcriptLayoutManager.enumerateTextSegments(
      in: textRange,
      type: .standard,
      options: [.rangeNotRequired]
    ) { _, segmentFrame, _, _ in
      union = union.union(segmentFrame)
      return true
    }
    guard !union.isNull, !union.isEmpty else { return nil }
    return union.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
  }

  func refreshViewportDecorations(installChrome: Bool = false) {
    layoutSubtreeIfNeeded()
    transcriptLayoutManager.ensureLayout(for: visibleRect)
    let visibleRanges = visibleSpeechRanges()
    if installChrome {
      installVisibleChromeAttributes(visibleRanges)
    }
    visibleDecorations = visibleRanges.compactMap { range in
      guard let paragraphRect = localRect(for: range.paragraphRange) else { return nil }
      return VisibleTranscriptDecoration(
        rendered: range,
        paragraphRect: paragraphRect,
        speakerRect: localRect(for: range.speakerRange),
        timestampRect: localRect(for: range.timestampRange)
      )
    }
    updateExcludedForeground(for: visibleRanges)
    refreshAccessibilityChrome()
    window?.invalidateCursorRects(for: self)
    needsDisplay = true
  }

  private func installVisibleChromeAttributes(
    _ visibleRanges: ArraySlice<RenderedSpeechRange>
  ) {
    guard let storage = transcriptContentStorage.textStorage else { return }
    let pending = visibleRanges.filter { !chromeAttributeLineIndexes.contains($0.line.index) }
    guard !pending.isEmpty else { return }
    storage.beginEditing()
    addChromeAttributes(
      for: pending,
      speakers: documentSnapshot?.speakers ?? [],
      to: storage
    )
    storage.endEditing()
    chromeAttributeLineIndexes.formUnion(pending.map(\.line.index))
  }

  private func refreshAccessibilityChrome() {
    guard let first = visibleDecorations.first,
      let speakerRect = first.speakerRect,
      let timestampRect = first.timestampRect
    else {
      exposesAccessibilityChrome = false
      speakerAccessibilityElement.onPress = nil
      timestampAccessibilityElement.onPress = nil
      return
    }
    exposesAccessibilityChrome = true
    let range = first.rendered
    let stateHelp = accessibilityStateHelp(for: range)

    speakerAccessibilityElement.setAccessibilityFrameInParentSpace(speakerRect)
    speakerAccessibilityElement.setAccessibilityLabel(
      documentSnapshot?.isSpeakerFiltered == true
        ? "取消只看「\(range.line.speaker)」"
        : "只看「\(range.line.speaker)」的发言"
    )
    speakerAccessibilityElement.setAccessibilityValue(range.line.speaker)
    let speakerHelp =
      documentSnapshot?.isSpeakerFiltered == true
      ? "按下以查看全部发言"
      : "按下以只看这位说话人"
    speakerAccessibilityElement.setAccessibilityHelp(
      [speakerHelp, stateHelp].compactMap { $0 }.joined(separator: "；")
    )
    speakerAccessibilityElement.onPress = { [weak self] in
      self?.actions.onSelectSpeaker(range.line.speaker)
    }

    timestampAccessibilityElement.setAccessibilityFrameInParentSpace(timestampRect)
    timestampAccessibilityElement.setAccessibilityLabel("时间戳")
    timestampAccessibilityElement.setAccessibilityValue(range.line.timestamp)
    timestampAccessibilityElement.setAccessibilityRole(selectionEnabled ? .button : .staticText)
    timestampAccessibilityElement.setAccessibilityHelp(
      [selectionEnabled ? "按下以设置选段锚点" : nil, stateHelp]
        .compactMap { $0 }
        .joined(separator: "；")
    )
    timestampAccessibilityElement.onPress =
      selectionEnabled
      ? { [weak self] in
        self?.actions.onSelectTimestamp(range.line.index, false)
      } : nil
  }

  private func accessibilityStateHelp(for range: RenderedSpeechRange) -> String? {
    var states: [String] = []
    if isExcluded(range, snapshot: styleSnapshot) { states.append("不进纪要") }
    if styleSnapshot.highlightedSpeaker == range.line.speaker { states.append("正在高亮通读") }
    if styleSnapshot.selectedLineIndexes.contains(range.line.index) { states.append("已选入闲聊段") }
    if jumpLineIndex == range.line.index { states.append("当前跳转位置") }
    return states.isEmpty ? nil : states.joined(separator: "，")
  }

  private func refreshMarkers() {
    for markerView in markerViews {
      markerView.removeFromSuperview()
    }
    markerViews.removeAll(keepingCapacity: true)
    guard !speechRanges.isEmpty else { return }
    addMarker("transcript.document.chrome.timestamp")
    if speechRanges.contains(where: { isExcluded($0, snapshot: styleSnapshot) }) {
      addMarker("transcript.document.excluded")
    }
    if let highlightedSpeaker = styleSnapshot.highlightedSpeaker,
      speechRanges.contains(where: { $0.line.speaker == highlightedSpeaker })
    {
      addMarker("transcript.document.highlighted")
    }
    let selectedCount = speechRanges.reduce(into: 0) { count, range in
      if styleSnapshot.selectedLineIndexes.contains(range.line.index) { count += 1 }
    }
    // 常规选段保持精确 occurrence；极端压力选段用一个摘要 marker，绝不造 5 万个 NSView。
    let markerCount = selectedCount <= 128 ? selectedCount : selectedCount > 0 ? 1 : 0
    for _ in 0..<markerCount {
      addMarker("transcript.document.selected")
    }
  }

  private func addMarker(_ identifier: String) {
    let marker = NSView(
      frame: NSRect(
        x: textContainerInset.width,
        y: textContainerInset.height,
        width: 1,
        height: 1
      )
    )
    marker.identifier = NSUserInterfaceItemIdentifier(identifier)
    marker.setAccessibilityElement(false)
    markerViews.append(marker)
    addSubview(marker)
  }
}
