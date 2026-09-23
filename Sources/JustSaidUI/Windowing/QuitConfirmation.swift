import AppKit
import JustSaidCore
import OSLog

/// 退出前的确认。关主窗本来就不退出、录音照常(T11);真正退出会中断录音或打断会议收尾,
/// 所以 ⌘Q、菜单栏「退出 JustSaid」、Dock、注销关机等退出请求先问一句。
/// Sparkle 更新器发起的退出不走这里:它的守卫在忙碌时直接拦下并说明(`AppUpdater`)。
public struct QuitConfirmation: Equatable, Sendable {
  public let title: String
  public let message: String
  /// 默认按钮(回车),点了不退出。另一颗固定是「退出」。
  public let keepButton: String

  /// 正在开始或录制时按录音问;正在停止、「结束会议」收尾或补充记录还在写时按保存问;其余不问。
  public static func needed(phase: RecordingSessionPhase, savingMeeting: Bool) -> QuitConfirmation? {
    switch phase {
    case .starting, .recording:
      return QuitConfirmation(
        title: "正在录制，要退出 JustSaid 吗？",
        message: "退出会中断这场会议的录音。如果只是想收起窗口，关掉窗口即可，录音会在菜单栏里继续。",
        keepButton: "继续录制")
    case .stopping:
      return saving
    case .idle, .completed, .failed:
      return savingMeeting ? saving : nil
    }
  }

  private static let saving = QuitConfirmation(
    title: "会议还在保存，要退出 JustSaid 吗？",
    message: "现在退出，这场会议最后的录音或补充记录可能保存不全。等它保存完再退出更稳妥。",
    keepButton: "先不退出")

  /// App 层在启动时装一次,读界面用的同一个录制会话与协调者(`JustSaidApp.init` 可能不止跑一次,
  /// 只认第一次,与 `@StateObject` 保留的实例一致)。
  @MainActor
  public static func install(recordingSession: RecordingSession, appCoordinator: AppCoordinator) {
    guard JustSaidAppDelegate.quitConfirmation == nil else { return }
    JustSaidAppDelegate.quitConfirmation = {
      let phase = recordingSession.phase
      let saving = appCoordinator.finishingMeetingCount > 0 || NotesController.pendingWriteTotal > 0
      guard let confirmation = needed(phase: phase, savingMeeting: saving) else {
        return .terminateNow
      }
      logger.info(
        "quit confirmation shown: phase=\(phase.rawValue, privacy: .public) saving=\(saving, privacy: .public)"
      )
      return confirmation.ask()
    }
  }

  /// 弹确认并返回 `terminateLater`,选完再回复 AppKit。提示在 run loop 上打开,不在主队列块里,
  /// 等待期间录制相关的主线程任务照常运行。
  @MainActor
  func ask(
    reply: @escaping @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
  ) -> NSApplication.TerminateReply {
    AppUpdateInteraction.runModalOffMainQueue {
      makeAlert()
    } completion: { response in
      let quit = response == .alertSecondButtonReturn
      Self.logger.info("quit confirmation answered: quit=\(quit, privacy: .public)")
      reply(quit)
    }
    return .terminateLater
  }

  /// 第一颗是不退出的按钮,占回车键;「退出」排第二、标成破坏性。
  @MainActor
  func makeAlert() -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: keepButton)
    alert.addButton(withTitle: "退出").hasDestructiveAction = true
    return alert
  }

  private static let logger = Logger(subsystem: "com.justsaid.app", category: "Quit")
}
