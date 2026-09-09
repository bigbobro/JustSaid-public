import AppKit
import Combine
import JustSaidCore
import SwiftUI

/// 缩略置顶窗生命周期：主窗失焦 1.5s 后出现（短暂切窗不弹，V7）；
/// 用户点击关闭后本场会议不再自动弹——通过 `UserDefaults` 按会议稳定 id 记忆
/// (08-15 G9:读 meeting.json 的 `MeetingMetadata.id`,UI 层既有能力,不动 Core;
/// 读不到才退回目录路径键)。
@MainActor
final class CompactPanelController: ObservableObject {
  let overlayModel = CompactOverlayViewModel()

  private weak var mainWindow: NSWindow?
  private var notificationTokens: [NSObjectProtocol] = []
  private lazy var panel: NSPanel = makePanel()
  private var pendingShowTask: Task<Void, Never>?
  private var dismissedDefaultsKey: String?
  private var isRecordingActive = false
  private var isShowingPanel = false
  private let defaults: UserDefaults
  private let contentScale: CompactContentScaleModel

  var isPanelVisible: Bool { isShowingPanel }

  func flashMarkConfirmation() {
    overlayModel.flashMarkConfirmation()
  }

  func flashActionConfirmation(_ text: String) {
    overlayModel.flashActionConfirmation(text)
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    contentScale = CompactContentScaleModel(
      value: TextScale.persisted(defaults.string(forKey: TextScale.defaultsKey))
    )
    overlayModel.onReturnToMain = { [weak self] in self?.returnToMainWindow() }
    overlayModel.onClose = { [weak self] in self?.userDismissed() }
  }

  func observe(mainWindow: NSWindow?) {
    guard self.mainWindow !== mainWindow else {
      return
    }

    stopObserving()
    self.mainWindow = mainWindow

    guard let mainWindow else {
      return
    }

    let notificationCenter = NotificationCenter.default
    notificationTokens = [
      notificationCenter.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: mainWindow,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.scheduleShow()
        }
      },
      notificationCenter.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: mainWindow,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.hidePanel()
        }
      },
      notificationCenter.addObserver(
        forName: NSWindow.willCloseNotification,
        object: mainWindow,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.hidePanel()
        }
      },
    ]
  }

  /// 会议目录变化时更新“本场会议是否已被用户关闭过”的记忆键。
  /// 键优先用 meeting.json 的稳定 id(G9/F-C6,08-15):UI 层经既有 `MeetingStore.read`
  /// 即可拿到,不动 Core;元数据读不到(写入竞态/坏档)退回目录路径,与旧行为一致。
  /// 注:现行 Core 改名只写 meeting.json、不动目录(`MeetingStore.renameMeeting` 明写
  /// 「目录名是会议的稳定身份」),路径键今天其实已不怕改名;换 id 键是把「会议身份」
  /// 坐实到不依赖目录命名约定的层面上(例如整个 meetings 根目录被搬走也不怕)。
  /// 旧路径键的存量记录不迁移——代价至多是一次重弹,迁移动作反而要碰两份键。
  func updateCurrentMeeting(directory: URL?) {
    dismissedDefaultsKey = directory.map { Self.dismissedDefaultsKey(for: $0) }
  }

  private static func dismissedDefaultsKey(for directory: URL) -> String {
    if let metadata = try? MeetingStore().read(from: MeetingPaths(directory: directory)) {
      return "compact-overlay-dismissed.\(metadata.id.uuidString)"
    }
    return "compact-overlay-dismissed.\(directory.path)"
  }

  /// 没有会议在录制时，缩略窗没有内容可给，不应弹出（V7 的隐含前提：它是“回到会议”
  /// 的兜底，不是脱离会议场景也常驻的小组件）。
  func updateRecordingActive(_ isActive: Bool) {
    isRecordingActive = isActive
    if !isActive {
      hidePanel()
    }
  }

  isolated deinit {
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
  }

  private var isDismissedForCurrentMeeting: Bool {
    guard let dismissedDefaultsKey else {
      return false
    }
    return defaults.bool(forKey: dismissedDefaultsKey)
  }

  private func userDismissed() {
    if let dismissedDefaultsKey {
      defaults.set(true, forKey: dismissedDefaultsKey)
    }
    hidePanel()
  }

  private func returnToMainWindow() {
    hidePanel()
    NSApp.activate(ignoringOtherApps: true)
    mainWindow?.makeKeyAndOrderFront(nil)
  }

  private func scheduleShow() {
    pendingShowTask?.cancel()
    pendingShowTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else {
        return
      }
      self?.showPanelIfEligible()
    }
  }

  private func showPanelIfEligible() {
    guard isRecordingActive, !isDismissedForCurrentMeeting else {
      return
    }
    contentScale.value = TextScale.persisted(defaults.string(forKey: TextScale.defaultsKey))
    positionPanel()
    isShowingPanel = true
    panel.orderFrontRegardless()
  }

  private func hidePanel() {
    pendingShowTask?.cancel()
    pendingShowTask = nil
    isShowingPanel = false
    panel.orderOut(nil)
  }

  private func stopObserving() {
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    notificationTokens.removeAll()
  }

  private func makePanel() -> NSPanel {
    let panel = NonActivatingPanel(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: Tokens.Layout.compactOverlayWidth,
        height: Tokens.Layout.compactOverlayHeight
      ),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = NSHostingView(
      rootView: CompactPanelRoot(
        overlayModel: overlayModel,
        contentScale: contentScale
      )
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return panel
  }

  private func positionPanel() {
    guard let visibleFrame = mainWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
      return
    }
    let origin = NSPoint(
      x: visibleFrame.maxX - panel.frame.width - 24,
      y: visibleFrame.maxY - panel.frame.height - 24
    )
    panel.setFrameOrigin(origin)
  }
}

@MainActor
private final class CompactContentScaleModel: ObservableObject {
  @Published var value: TextScale

  init(value: TextScale) {
    self.value = value
  }
}

private struct CompactPanelRoot: View {
  @ObservedObject var overlayModel: CompactOverlayViewModel
  @ObservedObject var contentScale: CompactContentScaleModel
  @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue =
    AppAppearance.system.rawValue

  var body: some View {
    CompactOverlayView(model: overlayModel)
      .environment(\.textScale, contentScale.value)
      .preferredColorScheme(
        AppAppearance.persisted(appearanceRawValue).preferredColorScheme
      )
  }
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
