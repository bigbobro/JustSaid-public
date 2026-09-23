import AppKit
import JustSaidCore
import SwiftUI

/// 滚轮事件只更新这个非观察对象；不得把每一帧都升级成 SwiftUI 状态发布。
private final class ScrollOffsetTracker {
  var latestOffset: CGFloat?
}

/// 页签互斥切走会销毁 ScrollView;把 contentOffset.y 写回调用方,回来时按点还原。
/// 精度就是 SwiftUI `ScrollPosition.scrollTo(y:)` 能稳定做到的程度:内容高度没变时
/// 对齐到点,字号/窗宽变了只是近似落点。
struct RememberedScrollOffsetModifier: ViewModifier {
  @Binding var offset: CGFloat
  var restoresOnAppear: Bool

  @State private var position = ScrollPosition()
  @State private var isTracking = false
  @State private var tracker = ScrollOffsetTracker()

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y
      } action: { _, y in
        guard isTracking else { return }
        tracker.latestOffset = y
      }
      .onScrollPhaseChange { _, phase in
        guard
          isTracking,
          phase == .idle,
          let latestOffset = tracker.latestOffset,
          abs(offset - latestOffset) > 0.5
        else {
          return
        }
        // `offset` 来自 AppCoordinator 的 @Published；只在滚动停下时提交一次。
        // 逐帧提交会让整个主窗边滚边重算，并与文字选择布局形成反馈循环。
        offset = latestOffset
        HangSentinel.shared.note("scroll-commit:\(Int(latestOffset))")
      }
      .onAppear {
        tracker.latestOffset = nil
        if restoresOnAppear, offset > 0.5 {
          position.scrollTo(y: offset)
        }
        Task { @MainActor in
          await Task.yield()
          isTracking = true
        }
      }
      .onDisappear {
        isTracking = false
        tracker.latestOffset = nil
      }
  }
}

extension View {
  @ViewBuilder
  func rememberedScrollOffset(
    _ offset: Binding<CGFloat>?,
    restoresOnAppear: Bool = true
  ) -> some View {
    if let offset {
      modifier(
        RememberedScrollOffsetModifier(offset: offset, restoresOnAppear: restoresOnAppear)
      )
    } else {
      self
    }
  }
}

/// A section anchor carries the following meeting identity; plain meeting IDs keep their old meaning.
enum LibraryListAnchor {
  static let sectionPrefix = "@section:"
  static func meetingID(_ anchor: String) -> String {
    anchor.hasPrefix(sectionPrefix) ? String(anchor.dropFirst(sectionPrefix.count)) : anchor
  }
}

/// List 不消费 ScrollView 的 scrollPosition / onScrollPhaseChange。
/// 用它实际的 NSTableView 行位置保留锚点，只在手势结束或卸载时回写。
struct RememberedListScrollPositionModifier: ViewModifier {
  @Binding var retainedID: String?
  let rowIDs: [String?]

  init(_ retainedID: Binding<String?>, rowIDs: [String?]) {
    _retainedID = retainedID
    self.rowIDs = rowIDs
  }

  func body(content: Content) -> some View {
    content.background(
      ListScrollAnchorBridge(retainedID: $retainedID, rowIDs: rowIDs)
        .allowsHitTesting(false)
    )
  }
}

private struct ListScrollAnchorBridge: NSViewRepresentable {
  @Binding var retainedID: String?
  let rowIDs: [String?]

  func makeNSView(context: Context) -> ListScrollAnchorView {
    let view = ListScrollAnchorView()
    view.setAccessibilityElement(false)
    return view
  }

  func updateNSView(_ view: ListScrollAnchorView, context: Context) {
    view.configure(rowIDs: rowIDs, retainedID: $retainedID)
  }

  static func dismantleNSView(_ view: ListScrollAnchorView, coordinator: ()) {
    view.detach()
  }
}

@MainActor
private final class ListScrollAnchorView: NSView {
  private weak var table: NSTableView?
  private weak var scroll: NSScrollView?
  private var rowIDs: [String?] = []
  private var retainedID: Binding<String?>?
  private var requestedID: String?
  private var latestID: String?
  private var hasTrackedPosition = false
  private var needsRestore = true
  private var isLiveScrolling = false
  private var idleCommit: DispatchWorkItem?

  func configure(rowIDs: [String?], retainedID: Binding<String?>) {
    if self.rowIDs != rowIDs || requestedID != retainedID.wrappedValue {
      needsRestore = true
    }
    self.rowIDs = rowIDs
    self.retainedID = retainedID
    requestedID = retainedID.wrappedValue
    DispatchQueue.main.async { [weak self] in self?.attachAndRestore() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      DispatchQueue.main.async { [weak self] in self?.attachAndRestore() }
    }
  }

  private func attachAndRestore() {
    guard window != nil else { return }
    if table == nil {
      func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
          if let table = findTable(in: child) { return table }
        }
        return nil
      }
      var ancestor = superview
      while let view = ancestor {
        if let found = findTable(in: view), let scroll = found.enclosingScrollView {
          table = found
          self.scroll = scroll
          let center = NotificationCenter.default
          scroll.contentView.postsBoundsChangedNotifications = true
          center.addObserver(
            self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
          center.addObserver(
            self, selector: #selector(scrollStarted),
            name: NSScrollView.willStartLiveScrollNotification, object: scroll)
          center.addObserver(
            self, selector: #selector(scrollEnded),
            name: NSScrollView.didEndLiveScrollNotification, object: scroll)
          break
        }
        ancestor = view.superview
      }
    }
    guard needsRestore, let table, let scroll, table.numberOfRows == rowIDs.count else { return }
    needsRestore = false
    if let requestedID,
      let meetingRow = rowIDs.firstIndex(where: { $0 == LibraryListAnchor.meetingID(requestedID) })
    {
      let row =
        requestedID.hasPrefix(LibraryListAnchor.sectionPrefix)
        ? rowIDs[...meetingRow].lastIndex(where: { $0 == nil }) ?? meetingRow : meetingRow
      let rect = table.rect(ofRow: row)
      let top = table.convert(rect.origin, to: scroll.documentView)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: top.y))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    trackPosition()
  }

  @objc private func boundsChanged() {
    guard !needsRestore else { return }
    trackPosition()
    // 非触控板路径（滚动条、程序性滚动）没有 live-scroll 阶段，静止后同样提交。
    if !isLiveScrolling {
      idleCommit?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.commitPosition() }
      idleCommit = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
  }

  @objc private func scrollStarted() {
    isLiveScrolling = true
    idleCommit?.cancel()
  }

  @objc private func scrollEnded() {
    isLiveScrolling = false
    idleCommit?.cancel()
    trackPosition()
    commitPosition()
  }

  private func trackPosition() {
    guard let table, let scroll, table.numberOfRows == rowIDs.count else { return }
    let visible = table.convert(scroll.contentView.bounds, from: scroll.contentView)
    let row = table.row(at: NSPoint(x: visible.midX, y: visible.minY + 1))
    guard row >= 0, row < rowIDs.count else { return }
    hasTrackedPosition = true
    // Top means no restoration scroll on the next mount, so the first section title stays visible.
    if scroll.contentView.bounds.minY <= 0 {
      latestID = nil
    } else if let id = rowIDs[row] {
      latestID = id
    } else {
      latestID = rowIDs[row...].compactMap { $0 }.first.map { LibraryListAnchor.sectionPrefix + $0 }
    }
  }

  private func commitPosition() {
    guard !isLiveScrolling, !needsRestore, hasTrackedPosition, let retainedID,
      retainedID.wrappedValue != latestID
    else { return }
    requestedID = latestID
    retainedID.wrappedValue = latestID
  }

  func detach() {
    isLiveScrolling = false
    idleCommit?.cancel()
    commitPosition()
    NotificationCenter.default.removeObserver(self)
    table = nil
    scroll = nil
  }
}
