import AppKit
import Combine
import JustSaidCore
import SwiftUI

/// 菜单栏常驻入口(拍板 T11):
/// - 左键点击 = 回到/唤起主窗口(录制中亦然);
/// - 右键 / Control 点击 = 菜单:开始会议录音(录制中变为「标记重点」+「结束会议」)、
///   查看历史会议、退出;
/// - 未在录制时可直接从菜单栏开录,不必先打开主窗;
/// - 图标为单色模板图(纯黑 + 透明),由系统按浅/深色自动反转;录制中叠加一枚小红点表示状态。
///
/// 2026-07-29 实测后去掉了「查看笔记」:笔记是会中在右栏写的东西,菜单栏直接甩一个
/// .md 文件出来既不是产品形态、也不该作为独立入口;它现在是会议详情页的一个页签。
/// 「查看历史会议」也不再打开 Finder,改为唤起应用内会议库。
@MainActor
public final class MenuBarController: NSObject {
  private var statusItem: NSStatusItem?
  private var cancellables: Set<AnyCancellable> = []
  private var markFlashTask: Task<Void, Never>?

  private let recordingSession: RecordingSession
  private let onStartMeeting: @MainActor () -> Void
  private let onEndMeeting: @MainActor () -> Void
  /// 录制中菜单的「标记重点」(G9/F-C7,08-15):与右栏补充记录区同一入口
  /// (`NotesController.beginMark`),由 AppCoordinator 路由到主窗注册来的 handler。
  private let onMarkNote: @MainActor () -> Void
  private let onActivateMainWindow: @MainActor () -> Void
  private let onOpenLibrary: @MainActor (URL?) -> Void

  public init(
    recordingSession: RecordingSession,
    onStartMeeting: @escaping @MainActor () -> Void,
    onEndMeeting: @escaping @MainActor () -> Void,
    onMarkNote: @escaping @MainActor () -> Void,
    onActivateMainWindow: @escaping @MainActor () -> Void,
    onOpenLibrary: @escaping @MainActor (URL?) -> Void
  ) {
    self.recordingSession = recordingSession
    self.onStartMeeting = onStartMeeting
    self.onEndMeeting = onEndMeeting
    self.onMarkNote = onMarkNote
    self.onActivateMainWindow = onActivateMainWindow
    self.onOpenLibrary = onOpenLibrary
    super.init()
  }

  public func install() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.target = self
    item.button?.action = #selector(handleClick(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item
    refreshIcon()

    recordingSession.$phase
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.refreshIcon()
      }
      .store(in: &cancellables)
  }

  // MARK: - 图标

  private var isRecording: Bool {
    recordingSession.phase == .recording || recordingSession.phase == .starting
  }

  private func refreshIcon() {
    guard let button = statusItem?.button else { return }
    button.image = Self.makeTemplateImage(recording: isRecording, marked: false)
    button.image?.isTemplate = true
    button.toolTip = isRecording ? "JustSaid · 录制中" : "JustSaid"
  }

  /// 主窗不在前台、悬浮窗也不在场时的标记回执:只改菜单栏图标,不激活任何窗口。
  func flashMarkConfirmation() {
    flashActionConfirmation(tooltip: "JustSaid · 已标记")
  }

  /// 闲聊/暂停全局热键的开/关回执:同款打勾闪,不激活任何窗口。
  func flashActionConfirmation(tooltip: String) {
    guard let button = statusItem?.button else { return }
    markFlashTask?.cancel()
    button.image = Self.makeTemplateImage(recording: isRecording, marked: true)
    button.image?.isTemplate = true
    button.toolTip = tooltip
    markFlashTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1_200))
      guard !Task.isCancelled else { return }
      self.refreshIcon()
    }
  }

  /// 声波 + 结论线的单色剪影(与应用图标同一形状语言);录制中在右上叠一枚实心点。
  private static func makeTemplateImage(recording: Bool, marked: Bool) -> NSImage {
    let size = NSSize(width: 20, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
      let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (1.5, 5.5, 5.0),
        (5.0, 3.5, 9.0),
        (8.5, 2.0, 12.0),
        (12.0, 4.0, 8.0),
        (15.5, 6.0, 4.5),
      ]
      NSColor.black.setFill()
      for (x, y, height) in bars {
        NSBezierPath(
          roundedRect: NSRect(x: x, y: y, width: 2.0, height: height),
          xRadius: 1.0,
          yRadius: 1.0
        ).fill()
      }
      NSBezierPath(
        roundedRect: NSRect(x: 1.5, y: 1.0, width: 16.0, height: 2.0),
        xRadius: 1.0,
        yRadius: 1.0
      ).fill()
      if marked {
        let check = NSBezierPath()
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: NSPoint(x: 12.5, y: 15.0))
        check.line(to: NSPoint(x: 14.6, y: 13.0))
        check.line(to: NSPoint(x: 18.6, y: 17.2))
        NSColor.black.setStroke()
        check.stroke()
      } else if recording {
        NSBezierPath(ovalIn: NSRect(x: 15.0, y: 14.0, width: 4.5, height: 4.5)).fill()
      }
      return true
    }
    image.isTemplate = true
    return image
  }

  // MARK: - 点击

  @objc private func handleClick(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    let isSecondary =
      event?.type == .rightMouseUp
      || (event?.modifierFlags.contains(.control) ?? false)
    if isSecondary {
      presentMenu()
    } else {
      onActivateMainWindow()
    }
  }

  private func presentMenu() {
    let menu = NSMenu()

    if isRecording {
      // 「标记重点」(G9):会中最高频动作进菜单栏——主窗被共享屏幕盖住时
      // 不再需要先把主窗翻出来。放在「结束会议」之前,与右栏同一入口语义。
      let mark = NSMenuItem(
        title: "标记重点",
        action: #selector(markNote),
        keyEquivalent: ""
      )
      mark.target = self
      menu.addItem(mark)

      let end = NSMenuItem(
        title: "结束会议",
        action: #selector(endMeeting),
        keyEquivalent: ""
      )
      end.target = self
      menu.addItem(end)
    } else {
      let start = NSMenuItem(
        title: "开始会议录音",
        action: #selector(startMeeting),
        keyEquivalent: ""
      )
      start.target = self
      menu.addItem(start)
    }

    menu.addItem(.separator())

    let history = NSMenuItem(
      title: "查看历史会议",
      action: #selector(openHistory),
      keyEquivalent: ""
    )
    history.target = self
    menu.addItem(history)

    menu.addItem(.separator())

    let quit = NSMenuItem(title: "退出 JustSaid", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil
  }

  // MARK: - 菜单动作

  @objc private func startMeeting() {
    onStartMeeting()
  }

  @objc private func endMeeting() {
    onEndMeeting()
  }

  @objc private func markNote() {
    onMarkNote()
  }

  @objc private func openHistory() {
    onOpenLibrary(recordingSession.currentMeetingDirectory)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
