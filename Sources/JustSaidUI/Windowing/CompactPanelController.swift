import AppKit
import Combine
import JustSaidCore
import SwiftUI

/// 会中悬浮载体的 AppKit 宿主:Dock 把手、会议内容(Dock 展开或悬浮小窗)与独立强提醒卡。
/// 由应用级 `MeetingPresenceController` 持有并驱动,主窗关闭/重建不影响它;
/// 所有面板非激活、不能成为 key/main,不抢键盘焦点。本类只管显隐与几何,
/// 不持有检测、确认或声音状态,关闭与动画结束也不会改业务状态。
/// 过渡(契约 R12):面板位移/尺寸与淡入淡出用 AppKit 动画从当前呈现值转向最新目标;
/// 把手面板深度固定为拉出深度,露出深度由 SwiftUI 外壳过渡。动画只动几何与透明度。
@MainActor
final class CompactPanelController {
  let overlayModel: CompactOverlayViewModel

  /// 把手与内容共同区域离开后收起的延迟(已确认契约约 0.4 秒)。
  static let leaveDelay: Duration = .milliseconds(400)

  private(set) var surface: MeetingPresenceSurface = .none
  private(set) var isPending = false
  private(set) var isRecording = false
  private(set) var dockPlacement = DockPlacement.initial
  /// 小窗左上角(x, maxY);名字区出现时向下长高,左上角不动。
  private(set) var windowTopLeft: CGPoint?
  private(set) var windowDisplayID: UInt32?
  private(set) var isDockContentExpanded = false
  private(set) var isHandleHovered = false
  private(set) var isContentHovered = false
  private(set) var isHandleMouseDown = false
  /// 内容里的按钮按住期间(SwiftUI 吞掉鼠标事件,由本地事件监视记录)不误收。
  private(set) var isContentMouseDown = false
  private(set) var collapseTask: Task<Void, Never>?

  /// 优先定位到主窗所在屏幕;主窗关闭时退回主屏。
  var preferredScreen: () -> NSScreen? = { NSScreen.main }

  private let contentScale: CompactContentScaleModel
  private let handleState = DockHandleState()
  private weak var handleContainer: DockHandleContainerView?
  private let defaults: UserDefaults
  private var cancellables: Set<AnyCancellable> = []
  private var dragStartMouse: CGPoint?
  /// 按下时指针在把手面板内的相对位置(比例)与当时朝向;拖动跟手时保持抓握点。
  private var dragGrip: (fraction: CGPoint, isVertical: Bool)?
  private var didDrag = false
  private var isApplyingFrame = false
  /// 进行中的面板几何过渡目标。同目标的重复刷新不重启动画,新目标从当前位置转向。
  private var frameTargets: [ObjectIdentifier: CGRect] = [:]
  /// 面板透明度的当前目标(1 显示 / 0 淡出中或已隐藏)。
  private var alphaTargets: [ObjectIdentifier: CGFloat] = [:]
  /// 新载体正在等旧载体淡出移出(见 `refresh()`)。
  private var isAwaitingCarrierHandoff = false
  private let contentVisibility = PanelVisibilityModel()
  private let strongVisibility = PanelVisibilityModel()
  private var mouseMonitor: Any?

  private(set) lazy var contentPanel: NSPanel = makeContentPanel()
  private(set) lazy var handlePanel: NSPanel = makeHandlePanel()
  private(set) lazy var strongPanel: NSPanel = makeStrongPanel()

  init(overlayModel: CompactOverlayViewModel, defaults: UserDefaults = .standard) {
    self.overlayModel = overlayModel
    self.defaults = defaults
    contentScale = CompactContentScaleModel(
      value: TextScale.persisted(defaults.string(forKey: TextScale.defaultsKey))
    )
    // 内容高度随名字区/暂停条变化:下一拍按实际内容尺寸重排,保持 Dock 朝内或小窗左上角不动。
    overlayModel.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.contentLayoutMayHaveChanged() }
      .store(in: &cancellables)
    // 内容面板的 SwiftUI 根嵌在跟踪容器里,preferredColorScheme 不会改到面板本身:
    // 外观偏好变化时直接设面板 appearance,材质与语义色才跟着深浅切换。
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.applyAppearance() }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in self?.screenParametersChanged() }
      .store(in: &cancellables)
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
      [weak self] event in
      MainActor.assumeIsolated {
        self?.observeContentMouse(event)
      }
      return event
    }
  }

  isolated deinit {
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
  }

  /// 内容面板里的按下/松开:按住期间暂停离开收起;按下即停住进行中的程序化几何过渡,
  /// 按住期间不再改内容面板几何(业务状态照常更新),用户拖动从当前位置开始;
  /// 松开后以用户位置为准,尺寸补齐并限界到可用区域。
  func observeContentMouse(_ event: NSEvent) {
    guard contentPanelIsLoaded, event.window === contentPanel else { return }
    switch event.type {
    case .leftMouseDown:
      isContentMouseDown = true
      stopFrameTransition(contentPanel)
      cancelCollapse()
    case .leftMouseUp:
      isContentMouseDown = false
      if surface == .window {
        windowTopLeft = CGPoint(x: contentPanel.frame.minX, y: contentPanel.frame.maxY)
        windowDisplayID = displayID(of: contentPanel.screen) ?? windowDisplayID
      }
      // 按住期间延后的几何(例如按住时来点名)在松开后从当前位置过渡到位。
      refresh()
      hoverRegionChanged()
    default:
      break
    }
  }

  /// 内容载体此刻是否在屏幕上(热键标记回执据此决定闪悬浮窗还是菜单栏)。
  var isContentVisible: Bool {
    (surface == .window || (surface == .dock && isDockContentExpanded))
      && contentPanelLoadedAndVisible
  }

  var isAnyPanelVisible: Bool {
    surface != .none
  }

  private var contentPanelLoadedAndVisible: Bool {
    contentPanelIsLoaded && contentPanel.isVisible
  }

  /// 当前真正在屏幕上的面板(未创建的面板视为不可见,查询不会触发创建)。
  var visiblePanels: (handle: Bool, content: Bool, strong: Bool) {
    (
      handlePanelIsLoaded && handlePanel.isVisible,
      contentPanelLoadedAndVisible,
      strongPanelIsLoaded && strongPanel.isVisible
    )
  }

  /// 各面板的持续绘制标志(高光与声波是否走帧),与 `visiblePanels` 同序。
  var activeDecorations: (handle: Bool, content: Bool, strong: Bool) {
    (handleState.isVisible, contentVisibility.isVisible, strongVisibility.isVisible)
  }

  private var contentPanelIsLoaded = false
  private var handlePanelIsLoaded = false
  private var strongPanelIsLoaded = false

  func flashMarkConfirmation() {
    overlayModel.flashMarkConfirmation()
  }

  func flashActionConfirmation(_ text: String) {
    overlayModel.flashActionConfirmation(text)
  }

  /// 新会议:位置、展开与悬停只属于本场。
  func resetForNewMeeting() {
    dockPlacement = .initial
    windowTopLeft = nil
    windowDisplayID = nil
    isDockContentExpanded = false
    isHandleHovered = false
    isContentHovered = false
    cancelCollapse()
  }

  /// 呈现控制器每次状态变化后调用;只改显隐与几何。
  func apply(
    surface newSurface: MeetingPresenceSurface, isPending pending: Bool, isRecording recording: Bool
  ) {
    let previous = surface
    surface = newSurface
    isPending = pending
    isRecording = recording
    if handleState.isPending != pending { handleState.isPending = pending }
    if handleState.isRecording != recording { handleState.isRecording = recording }
    if newSurface != .dock {
      isDockContentExpanded = false
      cancelCollapse()
    }
    if newSurface != previous, newSurface == .window || newSurface == .dock {
      contentScale.value = TextScale.persisted(defaults.string(forKey: TextScale.defaultsKey))
    }
    if previous == .dock, newSurface == .window, windowTopLeft == nil, contentPanelLoadedAndVisible
    {
      // 「保持展开」从 Dock 内容切小窗:小窗接在当前内容位置(过渡中取目标),不跳到默认角落。
      let frame = frameTargets[ObjectIdentifier(contentPanel)] ?? contentPanel.frame
      windowTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
      windowDisplayID = displayID(of: contentPanel.screen)
    }
    let carrier: CompactOverlayViewModel.Carrier = newSurface == .dock ? .dock : .window
    if overlayModel.carrier != carrier { overlayModel.carrier = carrier }
    refresh()
  }

  // MARK: - Dock 交互(把手视图与内容容器调用;验证程序直接驱动同一入口)

  func handleHoverChanged(inside: Bool) {
    isHandleHovered = inside
    hoverRegionChanged()
  }

  func contentHoverChanged(inside: Bool) {
    isContentHovered = inside
    hoverRegionChanged()
  }

  func handleMouseDown(at screenPoint: CGPoint) {
    isHandleMouseDown = true
    dragStartMouse = screenPoint
    didDrag = false
    if handlePanelIsLoaded {
      stopFrameTransition(handlePanel)
      let frame = handlePanel.frame
      dragGrip = (
        CGPoint(
          x: frame.width > 0 ? (screenPoint.x - frame.minX) / frame.width : 0.5,
          y: frame.height > 0 ? (screenPoint.y - frame.minY) / frame.height : 0.5),
        dockPlacement.edge.isVertical
      )
    }
    cancelCollapse()
  }

  /// 拖动跟手:把手随指针移动(保持抓握点),朝向与本场位置实时跟随最近边;
  /// 松手后 `refresh()` 把它吸附回边上并缓动。
  func handleMouseDragged(to screenPoint: CGPoint) {
    guard surface == .dock, let start = dragStartMouse else { return }
    if !didDrag, hypot(screenPoint.x - start.x, screenPoint.y - start.y) < 3 {
      return
    }
    didDrag = true
    let screen =
      NSScreen.screens.first { $0.frame.contains(screenPoint) }
      ?? currentScreen(for: dockPlacement.displayID)
    guard let screen else { return }
    let visible = screen.visibleFrame
    dockPlacement = DockGeometry.placement(
      nearest: screenPoint, in: visible, displayID: displayID(of: screen))
    let edge = dockPlacement.edge
    if handleState.edge != edge { handleState.edge = edge }
    if !handleState.isPulled { handleState.isPulled = true }
    handleContainer?.setExposed(edge: edge, depth: DockGeometry.pulledDepth)
    let size = DockGeometry.handleFrame(dockPlacement, depth: DockGeometry.pulledDepth, in: visible)
      .size
    var fraction = dragGrip?.fraction ?? CGPoint(x: 0.5, y: 0.5)
    if let grip = dragGrip, grip.isVertical != edge.isVertical {
      fraction = CGPoint(x: fraction.y, y: fraction.x)
    }
    let frame = CGRect(
      x: screenPoint.x - fraction.x * size.width,
      y: screenPoint.y - fraction.y * size.height,
      width: size.width, height: size.height)
    setFrame(handlePanel, frame, animated: false)
    if isDockContentExpanded {
      let content = DockGeometry.contentFrame(
        size: fittingContentSize(), handle: frame, edge: edge, in: visible)
      setFrame(contentPanel, content, animated: false)
    }
  }

  func handleMouseUp(at screenPoint: CGPoint) {
    isHandleMouseDown = false
    dragStartMouse = nil
    dragGrip = nil
    if !didDrag, surface == .dock {
      isDockContentExpanded.toggle()
      if isDockContentExpanded {
        contentScale.value = TextScale.persisted(defaults.string(forKey: TextScale.defaultsKey))
      }
    }
    didDrag = false
    refresh()
    hoverRegionChanged()
  }

  func screenParametersChanged() {
    refresh()
  }

  // MARK: - 显隐与几何

  private func hoverRegionChanged() {
    guard surface == .dock else {
      cancelCollapse()
      return
    }
    if isHandleHovered || isContentHovered || isHandleMouseDown || isContentMouseDown {
      cancelCollapse()
      refresh()
      return
    }
    guard collapseTask == nil else { return }
    collapseTask = Task { [weak self] in
      try? await Task.sleep(for: Self.leaveDelay)
      guard !Task.isCancelled, let self else { return }
      self.collapseTask = nil
      guard
        !self.isHandleHovered, !self.isContentHovered, !self.isHandleMouseDown,
        !self.isContentMouseDown
      else { return }
      self.isDockContentExpanded = false
      self.refresh()
    }
  }

  private func cancelCollapse() {
    collapseTask?.cancel()
    collapseTask = nil
  }

  private var isHandlePulled: Bool {
    isPending || isHandleHovered || isHandleMouseDown || isDockContentExpanded
      || collapseTask != nil
  }

  private func contentLayoutMayHaveChanged() {
    guard contentPanelLoadedAndVisible || strongPanelIsLoaded && strongPanel.isVisible else {
      return
    }
    refresh()
  }

  /// 当前把手露出深度(拉出或静息);外壳按它过渡,命中与悬停区域也只取这一段。
  var handleExposedDepth: CGFloat {
    handleState.isPulled ? DockGeometry.pulledDepth : DockGeometry.restDepth
  }

  /// 强提醒与普通载体(把手 + 内容)互相替代:旧载体淡出并移出屏幕(停止接收指针与绘制)后,
  /// 新载体才出现,淡出完成时按当时的呈现重新刷新。中途反向由刷新读取最新呈现,旧载体从
  /// 当前透明度转回,新载体不出现。同一载体内的几何与显隐过渡不受影响。
  /// 先启动旧载体淡出,再读真实在屏状态:若完成回调同步跑完,过期 snapshot 不会把等待悬空。
  private func refresh() {
    isAwaitingCarrierHandoff = false
    switch surface {
    case .none:
      orderOutContent()
      orderOutHandle()
      orderOutStrong()
    case .strongAlert:
      orderOutContent()
      orderOutHandle()
      let visible = visiblePanels
      guard !(visible.handle || visible.content) else {
        isAwaitingCarrierHandoff = true
        return
      }
      showStrong()
    case .window:
      orderOutHandle()
      orderOutStrong()
      let visible = visiblePanels
      guard !visible.strong else {
        isAwaitingCarrierHandoff = true
        return
      }
      showWindowContent()
    case .dock:
      orderOutStrong()
      let visible = visiblePanels
      guard !visible.strong else {
        isAwaitingCarrierHandoff = true
        return
      }
      showDock()
    }
  }

  private func showDock() {
    guard let screen = currentScreen(for: dockPlacement.displayID) else { return }
    let visible = screen.visibleFrame
    if dockPlacement.displayID == nil
      || !NSScreen.screens.contains(where: { displayID(of: $0) == dockPlacement.displayID })
    {
      dockPlacement.displayID = displayID(of: screen)
    }
    let pulled = isHandlePulled
    if handleState.isPulled != pulled { handleState.isPulled = pulled }
    // 拖动中把手跟着指针,只在松手后吸附;其余刷新(总结更新、悬停)不打断拖动。
    let isDragging = isHandleMouseDown && didDrag
    let handleFrame: CGRect
    if isDragging {
      handleFrame = handlePanel.frame
    } else {
      if handleState.edge != dockPlacement.edge { handleState.edge = dockPlacement.edge }
      handleFrame = DockGeometry.handleFrame(
        dockPlacement, depth: DockGeometry.pulledDepth, in: visible)
      setFrame(handlePanel, handleFrame)
    }
    handleContainer?.setExposed(edge: handleState.edge, depth: handleExposedDepth)
    present(handlePanel)

    if isDockContentExpanded {
      let contentFrame = DockGeometry.contentFrame(
        size: fittingContentSize(),
        handle: handleFrame,
        edge: dockPlacement.edge,
        in: visible
      )
      if !(isContentMouseDown && contentPanel.isVisible) {
        setFrame(contentPanel, contentFrame, animated: !isDragging)
      }
      present(contentPanel)
    } else {
      orderOutContent()
    }
  }

  private func showWindowContent() {
    let size = fittingContentSize()
    guard let screen = currentScreen(for: windowDisplayID) else { return }
    let visible = screen.visibleFrame
    let frame: CGRect
    if let windowTopLeft {
      frame = DockGeometry.clamp(
        CGRect(
          x: windowTopLeft.x, y: windowTopLeft.y - size.height,
          width: size.width, height: size.height),
        to: visible)
    } else {
      frame = DockGeometry.defaultWindowFrame(size: size, in: visible)
      windowDisplayID = displayID(of: screen)
    }
    if !(isContentMouseDown && contentPanel.isVisible) {
      windowTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
      setFrame(contentPanel, frame)
    }
    present(contentPanel)
  }

  private func showStrong() {
    guard let screen = currentScreen(for: windowDisplayID ?? dockPlacement.displayID) else {
      return
    }
    // 面板已存在时,宿主视图这一拍可能还停在确认后的空卡片(新 pending 尚未刷新进 SwiftUI,
    // fittingSize 近 0),面板会从角落长大:未在屏或尺寸退化时按当前状态新建宿主测量卡片。
    let live = strongPanel.contentView?.fittingSize ?? .zero
    let size =
      strongPanel.isVisible && live.width >= 1 && live.height >= 1
      ? live
      : NSHostingView(
        rootView: StrongAlertPanelRoot(overlayModel: overlayModel, visibility: strongVisibility)
      ).fittingSize
    setFrame(strongPanel, DockGeometry.strongAlertFrame(size: size, in: screen.visibleFrame))
    present(strongPanel)
  }

  private func orderOutContent() {
    guard contentPanelIsLoaded else { return }
    dismiss(contentPanel)
  }

  private func orderOutHandle() {
    guard handlePanelIsLoaded else { return }
    dismiss(handlePanel)
  }

  private func orderOutStrong() {
    guard strongPanelIsLoaded else { return }
    dismiss(strongPanel)
  }

  private func fittingContentSize() -> CGSize {
    let fitting = contentPanel.contentView?.fittingSize ?? .zero
    return CGSize(width: Tokens.Layout.compactOverlayWidth, height: max(fitting.height, 1))
  }

  private static var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// 面板几何:在屏面板缓动到新目标(中途再改目标则从当前位置转向);未显示、拖动跟手
  /// 或减少动态效果时直接到位。
  private func setFrame(_ panel: NSPanel, _ frame: CGRect, animated: Bool = true) {
    let key = ObjectIdentifier(panel)
    if let target = frameTargets[key] {
      guard target != frame else { return }
    } else if panel.frame == frame {
      return
    }
    guard animated, panel.isVisible, !Self.reduceMotion else {
      frameTargets[key] = nil
      isApplyingFrame = true
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        panel.animator().setFrame(frame, display: true)
      }
      isApplyingFrame = false
      return
    }
    frameTargets[key] = frame
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Tokens.Motion.presenceTransition
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().setFrame(frame, display: true)
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.frameTargets[key] == frame else { return }
        self.frameTargets[key] = nil
      }
    }
  }

  /// 停在当前呈现位置,放弃进行中的几何过渡目标(用户按下/抓取时,过渡不能抢回位置)。
  private func stopFrameTransition(_ panel: NSPanel) {
    let key = ObjectIdentifier(panel)
    guard frameTargets[key] != nil else { return }
    frameTargets[key] = nil
    let current = panel.frame
    isApplyingFrame = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      panel.animator().setFrame(current, display: true)
    }
    isApplyingFrame = false
  }

  /// 显示:未在屏的面板从透明淡入;淡出途中再次需要显示则从当前透明度转回。
  private func present(_ panel: NSPanel) {
    let key = ObjectIdentifier(panel)
    if !panel.isVisible {
      panel.alphaValue = 0
      alphaTargets[key] = 0
      panel.orderFrontRegardless()
    }
    setDecorationActive(true, for: panel)
    guard alphaTargets[key] != 1 else { return }
    alphaTargets[key] = 1
    NSAnimationContext.runAnimationGroup { context in
      context.duration =
        Self.reduceMotion ? Tokens.Motion.presenceReducedFade : Tokens.Motion.presenceTransition
      panel.animator().alphaValue = 1
    }
  }

  /// 隐藏:淡出结束时仍不需要显示才真正移出屏幕,并停止该面板的持续绘制。
  private func dismiss(_ panel: NSPanel) {
    let key = ObjectIdentifier(panel)
    guard panel.isVisible, alphaTargets[key] != 0 else { return }
    alphaTargets[key] = 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration =
        Self.reduceMotion ? Tokens.Motion.presenceReducedFade : Tokens.Motion.presenceTransition
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.alphaTargets[key] == 0, let panel = self.loadedPanel(key),
          !self.isWanted(panel)
        else { return }
        panel.orderOut(nil)
        self.frameTargets[key] = nil
        self.setDecorationActive(false, for: panel)
        if self.isAwaitingCarrierHandoff { self.refresh() }
      }
    }
  }

  private func loadedPanel(_ key: ObjectIdentifier) -> NSPanel? {
    if handlePanelIsLoaded, ObjectIdentifier(handlePanel) == key { return handlePanel }
    if contentPanelIsLoaded, ObjectIdentifier(contentPanel) == key { return contentPanel }
    if strongPanelIsLoaded, ObjectIdentifier(strongPanel) == key { return strongPanel }
    return nil
  }

  /// 当前呈现是否需要这个面板(由载体与展开状态推出,不另存显隐状态)。
  private func isWanted(_ panel: NSPanel) -> Bool {
    if handlePanelIsLoaded, panel === handlePanel { return surface == .dock }
    if contentPanelIsLoaded, panel === contentPanel {
      return surface == .window || (surface == .dock && isDockContentExpanded)
    }
    return surface == .strongAlert
  }

  private func setDecorationActive(_ active: Bool, for panel: NSPanel) {
    if handlePanelIsLoaded, panel === handlePanel {
      if handleState.isVisible != active { handleState.isVisible = active }
    } else if contentPanelIsLoaded, panel === contentPanel {
      if contentVisibility.isVisible != active { contentVisibility.isVisible = active }
    } else if strongVisibility.isVisible != active {
      strongVisibility.isVisible = active
    }
  }

  private func currentScreen(for displayID: UInt32?) -> NSScreen? {
    if let displayID,
      let screen = NSScreen.screens.first(where: { self.displayID(of: $0) == displayID })
    {
      return screen
    }
    return preferredScreen() ?? NSScreen.main ?? NSScreen.screens.first
  }

  private func displayID(of screen: NSScreen?) -> UInt32? {
    (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  // MARK: - 面板

  /// 与主窗 `@AppStorage(AppAppearance.defaultsKey)` 读同一偏好。
  private static func panelAppearance() -> NSAppearance? {
    switch AppAppearance.persisted(UserDefaults.standard.string(forKey: AppAppearance.defaultsKey))
    {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }

  private func applyAppearance() {
    let appearance = Self.panelAppearance()
    for (loaded, panel) in [
      (contentPanelIsLoaded, { self.contentPanel }), (handlePanelIsLoaded, { self.handlePanel }),
      (strongPanelIsLoaded, { self.strongPanel }),
    ] where loaded {
      let target = panel()
      if target.appearance?.name != appearance?.name {
        target.appearance = appearance
      }
    }
  }

  private func configure(_ panel: NSPanel) {
    panel.appearance = Self.panelAppearance()
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  private func makeContentPanel() -> NSPanel {
    contentPanelIsLoaded = true
    let panel = NonActivatingPanel(
      contentRect: NSRect(x: 0, y: 0, width: Tokens.Layout.compactOverlayWidth, height: 160),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configure(panel)
    let container = HoverTrackingView { [weak self] inside in
      self?.contentHoverChanged(inside: inside)
    }
    let hosting = NSHostingView(
      rootView: CompactPanelRoot(
        overlayModel: overlayModel, contentScale: contentScale, visibility: contentVisibility)
    )
    // 只报告理想尺寸供 fittingSize 读取,不让宿主视图按内容最小/最大尺寸直接改面板:
    // 面板几何只由本控制器设置并过渡(否则长高会在过渡开始前一帧跳到终点)。
    hosting.sizingOptions = [.intrinsicContentSize]
    container.embed(hosting)
    panel.contentView = container
    NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
      .sink { [weak self, weak panel] _ in
        // 程序化几何过渡中的中间位置不当作用户拖动;过渡结束后以实际位置为准。
        guard let self, let panel, !self.isApplyingFrame, self.surface == .window,
          self.frameTargets[ObjectIdentifier(panel)] == nil
        else { return }
        self.windowTopLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        self.windowDisplayID = self.displayID(of: panel.screen)
      }
      .store(in: &cancellables)
    return panel
  }

  private func makeHandlePanel() -> NSPanel {
    handlePanelIsLoaded = true
    let panel = NonActivatingPanel(
      contentRect: NSRect(
        x: 0, y: 0, width: DockGeometry.pulledDepth, height: DockGeometry.handleLength),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configure(panel)
    panel.hasShadow = false
    let view = DockHandleContainerView(state: handleState)
    view.onHover = { [weak self] inside in self?.handleHoverChanged(inside: inside) }
    view.onMouseDown = { [weak self] point in self?.handleMouseDown(at: point) }
    view.onMouseDragged = { [weak self] point in self?.handleMouseDragged(to: point) }
    view.onMouseUp = { [weak self] point in self?.handleMouseUp(at: point) }
    panel.contentView = view
    handleContainer = view
    return panel
  }

  private func makeStrongPanel() -> NSPanel {
    strongPanelIsLoaded = true
    let panel = NonActivatingPanel(
      contentRect: NSRect(x: 0, y: 0, width: MeetingPresenceMetrics.strongCardWidth, height: 60),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configure(panel)
    let hosting = NSHostingView(
      rootView: StrongAlertPanelRoot(overlayModel: overlayModel, visibility: strongVisibility)
    )
    // 同内容面板:确认后卡片移除过渡期间,面板不随空内容缩成 0,只由淡出结束后移出。
    hosting.sizingOptions = [.intrinsicContentSize]
    panel.contentView = hosting
    return panel
  }
}

// MARK: - 宿主视图

@MainActor
final class CompactContentScaleModel: ObservableObject {
  @Published var value: TextScale

  init(value: TextScale) {
    self.value = value
  }
}

/// 面板是否在屏(呈现数据):隐藏后点名高光停止走帧。
@MainActor
final class PanelVisibilityModel: ObservableObject {
  @Published var isVisible = false
}

private struct CompactPanelRoot: View {
  @ObservedObject var overlayModel: CompactOverlayViewModel
  @ObservedObject var contentScale: CompactContentScaleModel
  @ObservedObject var visibility: PanelVisibilityModel
  @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue =
    AppAppearance.system.rawValue

  var body: some View {
    CompactOverlayView(model: overlayModel)
      // 小窗自由拖动:手势挂在内容根上(内容自带的材质底会吃掉背后图层的点击);
      // 子按钮的点击优先,空白处拖动移动窗口。Dock 内容只启用子视图手势,不能拖。
      .gesture(
        WindowDragGesture(),
        including: overlayModel.carrier == .window ? .all : .subviews
      )
      .environment(\.textScale, contentScale.value)
      .environment(\.presenceDecorationActive, visibility.isVisible)
      .preferredColorScheme(
        AppAppearance.persisted(appearanceRawValue).preferredColorScheme
      )
  }
}

private struct StrongAlertPanelRoot: View {
  @ObservedObject var overlayModel: CompactOverlayViewModel
  @ObservedObject var visibility: PanelVisibilityModel
  @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue =
    AppAppearance.system.rawValue
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // 确认立即清掉共享 pending;卡片以移除过渡淡出,与面板淡出同一时长,不会先变成空面板。
    ZStack {
      if let event = overlayModel.pendingEvent {
        NameAlertStrongCard(event: event, onAcknowledge: overlayModel.onAcknowledge)
          .transition(.opacity)
      }
    }
    .animation(
      PresenceHighlight.fade(reduceMotion: reduceMotion),
      value: overlayModel.pendingEvent?.id
    )
    .environment(\.presenceDecorationActive, visibility.isVisible)
    .preferredColorScheme(
      AppAppearance.persisted(appearanceRawValue).preferredColorScheme
    )
  }
}

@MainActor
final class DockHandleState: ObservableObject {
  @Published var edge: DockEdge = DockPlacement.initial.edge
  @Published var isPulled = false
  @Published var isPending = false
  @Published var isRecording = false
  /// 把手面板是否在屏(呈现数据):隐藏后声波与高光停止走帧。
  @Published var isVisible = false
}

private struct DockHandleRoot: View {
  @ObservedObject var state: DockHandleState

  var body: some View {
    DockHandleVisual(
      edge: state.edge,
      isPulled: state.isPulled,
      isPending: state.isPending,
      isRecording: state.isRecording,
      isVisible: state.isVisible
    )
  }
}

/// 把手自己处理鼠标:悬停拉出、点击展开内容、拖动沿边移动或换边。SwiftUI 只负责外观。
/// 面板深度固定为拉出深度;命中与悬停只取贴边的当前露出段,其余透明部分不拦截指针。
final class DockHandleContainerView: NSView {
  var onHover: (Bool) -> Void = { _ in }
  var onMouseDown: (CGPoint) -> Void = { _ in }
  var onMouseDragged: (CGPoint) -> Void = { _ in }
  var onMouseUp: (CGPoint) -> Void = { _ in }
  private var trackingArea: NSTrackingArea?
  private var exposedEdge = DockPlacement.initial.edge
  private var exposedDepth = DockGeometry.restDepth

  init(state: DockHandleState) {
    super.init(frame: .zero)
    let hosting = NSHostingView(rootView: DockHandleRoot(state: state))
    hosting.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
      hosting.topAnchor.constraint(equalTo: topAnchor),
      hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setExposed(edge: DockEdge, depth: CGFloat) {
    guard edge != exposedEdge || depth != exposedDepth else { return }
    exposedEdge = edge
    exposedDepth = depth
    updateTrackingAreas()
  }

  /// 贴屏幕边的露出段(视图坐标,原点左下)。
  var exposedRect: NSRect {
    let depth = min(exposedDepth, exposedEdge.isVertical ? bounds.width : bounds.height)
    switch exposedEdge {
    case .right: return NSRect(x: bounds.maxX - depth, y: 0, width: depth, height: bounds.height)
    case .left: return NSRect(x: 0, y: 0, width: depth, height: bounds.height)
    case .top: return NSRect(x: 0, y: bounds.maxY - depth, width: bounds.width, height: depth)
    case .bottom: return NSRect(x: 0, y: 0, width: bounds.width, height: depth)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    exposedRect.contains(convert(point, from: superview)) ? self : nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateTrackingAreas()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: exposedRect,
      options: [.mouseEnteredAndExited, .activeAlways],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { onHover(true) }
  override func mouseExited(with event: NSEvent) { onHover(false) }
  override func mouseDown(with event: NSEvent) { onMouseDown(screenLocation(of: event)) }
  override func mouseDragged(with event: NSEvent) { onMouseDragged(screenLocation(of: event)) }
  override func mouseUp(with event: NSEvent) { onMouseUp(screenLocation(of: event)) }

  private func screenLocation(of event: NSEvent) -> CGPoint {
    guard let window = event.window ?? window else { return NSEvent.mouseLocation }
    return window.convertPoint(toScreen: event.locationInWindow)
  }
}

/// 内容容器:只报告指针进出,点击仍交给 SwiftUI 按钮。
final class HoverTrackingView: NSView {
  private let onHover: (Bool) -> Void
  private var trackingArea: NSTrackingArea?

  init(onHover: @escaping (Bool) -> Void) {
    self.onHover = onHover
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func embed(_ view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: leadingAnchor),
      view.trailingAnchor.constraint(equalTo: trailingAnchor),
      view.topAnchor.constraint(equalTo: topAnchor),
      view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  override var fittingSize: NSSize {
    subviews.first?.fittingSize ?? super.fittingSize
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { onHover(true) }
  override func mouseExited(with event: NSEvent) { onHover(false) }
}

private final class NonActivatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

struct WindowAccessor: NSViewRepresentable {
  let onResolve: (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      onResolve(view.window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      onResolve(nsView.window)
    }
  }

}
