import AppKit
import Combine
import JustSaidCore
import SwiftUI

/// 会议提醒胶囊的独立面板（设计系统「会议提醒胶囊」）。和强提醒同一套非激活悬浮面板：
/// 顶部居中、不抢键盘焦点。它是叠加层，不参与 `MeetingPresenceSurface` 的三选一：
/// 开始提醒在空闲时出现，结束提醒要和 Dock/小窗/强提醒并存。点名强提醒在场时排在它下面，
/// 两者互不遮挡、互不等待。本类只管显隐与几何，业务状态在 `MeetingDetectionController`。
@MainActor
final class MeetingPromptPanelController {
  /// 与强提醒胶囊的间距。
  static let stackGap = Tokens.V1.Space.sm

  let model = MeetingPromptViewModel()
  private(set) var prompt: MeetingPrompt?
  private(set) var isStackedBelowStrongAlert = false
  private var iconCache: [String: NSImage] = [:]
  private(set) lazy var panel: NSPanel = makePanel()
  private var isLoaded = false
  private var screenObserver: AnyCancellable?

  init() {
    // 拔显示器、改分辨率：有提醒时重排回顶部居中，不能留在屏外（结束提醒不会自己消失）。
    screenObserver = NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        guard let self, self.prompt != nil else { return }
        self.layout()
      }
  }

  /// 优先定位到主窗所在屏幕；由宿主设置。
  var preferredScreen: () -> NSScreen? = { NSScreen.main }

  var isVisible: Bool { isLoaded && panel.isVisible }
  var frame: CGRect? { isLoaded ? panel.frame : nil }

  func bindActions(_ controller: MeetingDetectionController?) {
    guard let controller else {
      model.onStart = {}
      model.onIgnore = {}
      model.onNever = {}
      model.onEnd = {}
      model.onContinue = {}
      model.onScopeSwitch = {}
      model.onScopeDismiss = {}
      return
    }
    model.onStart = { [weak controller] in controller?.startRecording() }
    model.onIgnore = { [weak controller] in controller?.ignore() }
    model.onNever = { [weak controller] in controller?.neverRemind() }
    model.onEnd = { [weak controller] in controller?.endRecording() }
    model.onContinue = { [weak controller] in controller?.continueRecording() }
    model.onScopeSwitch = { [weak controller] in controller?.switchScopeToGlobal() }
    model.onScopeDismiss = { [weak controller] in controller?.dismissScopeNotice() }
  }

  func apply(prompt: MeetingPrompt?, belowStrongAlert: Bool) {
    self.prompt = prompt
    isStackedBelowStrongAlert = belowStrongAlert
    guard let prompt else {
      model.prompt = nil
      if isLoaded { panel.orderOut(nil) }
      return
    }
    model.prompt = prompt
    model.canExclude = MeetingDetectionController.canExclude(prompt.info.app)
    model.icon = icon(for: prompt.info.app)
    layout()
    panel.orderFrontRegardless()
    // SwiftUI 宿主视图在本轮之后才按新内容定尺寸；下一拍再按实际大小排一次。
    DispatchQueue.main.async { [weak self] in
      guard let self, self.prompt != nil else { return }
      self.layout()
    }
  }

  /// 点名强提醒出现或消失时重排位置。
  func restack(belowStrongAlert: Bool) {
    guard prompt != nil, isStackedBelowStrongAlert != belowStrongAlert else { return }
    isStackedBelowStrongAlert = belowStrongAlert
    layout()
  }

  func invalidate() {
    prompt = nil
    model.prompt = nil
    if isLoaded { panel.orderOut(nil) }
  }

  private func layout() {
    guard let screen = preferredScreen() ?? NSScreen.main else { return }
    panel.contentView?.layoutSubtreeIfNeeded()
    let size = panel.contentView?.fittingSize ?? panel.frame.size
    var frame = DockGeometry.strongAlertFrame(size: size, in: screen.visibleFrame)
    if isStackedBelowStrongAlert {
      frame.origin.y -= MeetingPresenceMetrics.strongPillHeight + Self.stackGap
    }
    panel.setFrame(frame, display: true)
  }

  private func icon(for app: AppIdentity) -> NSImage? {
    if let cached = iconCache[app.key] { return cached }
    guard let bundleID = app.bundleID,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return nil }
    let image = NSWorkspace.shared.icon(forFile: url.path)
    iconCache[app.key] = image
    return image
  }

  private func makePanel() -> NSPanel {
    isLoaded = true
    let panel = MeetingPromptPanel(
      contentRect: NSRect(
        x: 0, y: 0, width: 480,
        height: MeetingPresenceMetrics.strongPillHeight
          + MeetingPresenceMetrics.strongShadowTop + MeetingPresenceMetrics.strongShadowBottom),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let hosting = NSHostingView(rootView: MeetingPromptPanelRoot(model: model))
    hosting.sizingOptions = [.intrinsicContentSize]
    panel.contentView = hosting
    return panel
  }
}

/// 胶囊上方的透明投影边会伸进菜单栏区域（可见上沿距菜单栏 16，投影边 20），系统默认会把面板压回可用区域，
/// 让胶囊比设计低几点；不压，和强提醒面板（经动画器设置几何）一致。
final class MeetingPromptPanel: NonActivatingPanel {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    guard let visible = (screen ?? self.screen ?? NSScreen.main)?.visibleFrame else {
      return frameRect
    }
    return Self.constrained(frameRect, to: visible)
  }

  /// 只放开上沿（投影边可伸进菜单栏 `strongShadowTop` 点），其余方向仍限制在可用区域内，
  /// 所以换屏后面板不会留在屏外。
  static func constrained(_ frame: NSRect, to visible: NSRect) -> NSRect {
    var result = frame
    let maxTop = visible.maxY + MeetingPresenceMetrics.strongShadowTop
    result.origin.y = min(result.origin.y, maxTop - result.height)
    result.origin.y = max(result.origin.y, visible.minY)
    result.origin.x = min(result.origin.x, visible.maxX - result.width)
    result.origin.x = max(result.origin.x, visible.minX)
    return result
  }
}
