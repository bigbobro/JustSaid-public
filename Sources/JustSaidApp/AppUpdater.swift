import AppKit
import JustSaidCore
import JustSaidUI
import OSLog
import Sparkle

/// 进程内唯一的应用更新器。在 `JustSaidApp.init` 创建(adaptor 的
/// `applicationDidFinishLaunching` 不会被调用),生命周期与主窗无关。
///
/// 使用 `SPUUpdater` + 标准 user driver;`SPUStandardUpdaterController` 不能注入 driver,
/// 而 Sparkle 2.10.0 初次「准备好安装」窗口只有「安装并重启」,所以只覆盖这一步给出
/// 已批准的两个选择。检查、下载、错误与首次自动检查询问仍是标准窗口。
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
  private(set) static var shared: AppUpdater?

  let model: AppUpdatesModel

  private let appCoordinator: AppCoordinator
  private let recordingSession: RecordingSession
  private let modelAssets: LocalModelAssetManager
  private let userDriver: ReadyToInstallChoiceUserDriver
  private var updater: SPUUpdater?
  private let logger = Logger(subsystem: "com.justsaid.app", category: "AppUpdates")

  /// 进程内只安装一次。开发构建或未盖章的包返回 nil,不创建任何 Sparkle 对象。
  static func installIfEnabled(
    appCoordinator: AppCoordinator,
    recordingSession: RecordingSession,
    modelAssets: LocalModelAssetManager
  ) -> AppUpdater? {
    if let shared { return shared }
    #if DEBUG
      let isDebugBuild = true
    #else
      let isDebugBuild = false
    #endif
    guard
      AppUpdatePolicy.isEnabled(
        infoDictionary: Bundle.main.infoDictionary, isDebugBuild: isDebugBuild)
    else { return nil }
    let updater = AppUpdater(
      appCoordinator: appCoordinator,
      recordingSession: recordingSession,
      modelAssets: modelAssets
    )
    shared = updater
    return updater
  }

  private init(
    appCoordinator: AppCoordinator,
    recordingSession: RecordingSession,
    modelAssets: LocalModelAssetManager
  ) {
    self.appCoordinator = appCoordinator
    self.recordingSession = recordingSession
    self.modelAssets = modelAssets
    let userDriver = ReadyToInstallChoiceUserDriver(hostBundle: .main, delegate: nil)
    self.userDriver = userDriver
    var sparkle: SPUUpdater?
    model = AppUpdatesModel(
      readAutomaticChecks: { sparkle?.automaticallyChecksForUpdates ?? false },
      writeAutomaticChecks: { sparkle?.automaticallyChecksForUpdates = $0 },
      checkForUpdates: { sparkle?.checkForUpdates() }
    )
    super.init()
    let updater = ProfileFreeUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: self)
    sparkle = updater
    self.updater = updater
    // 不上传系统画像:用户默认值优先于 Info.plist,旧的 true 会压过 SUSendProfileInfo=false,
    // 所以启动前经受支持的属性明确写 false。
    updater.sendsSystemProfile = false
    do {
      try updater.start()
    } catch {
      logger.error("updater start failed: \(error.localizedDescription, privacy: .public)")
    }
    model.refresh()
    JustSaidAppDelegate.terminationGuard = { [weak self] in
      self?.terminationReply() ?? .terminateNow
    }
  }

  func checkForUpdates() {
    model.checkForUpdates()
  }

  private var busyState: AppUpdateBusyState {
    .current(
      appCoordinator: appCoordinator,
      recordingSession: recordingSession,
      modelAssets: modelAssets
    )
  }

  /// 最终退出边界:只有当前这次 quit 来自已加载 Sparkle 框架的 Updater.app 时才介入;
  /// ⌘Q、菜单栏退出和其他发送者这里一律放行,录制中是否先问一句由退出确认(`QuitConfirmation`)决定。
  private func terminationReply() -> NSApplication.TerminateReply {
    let updaterAppURL = Bundle(for: SPUUpdater.self).url(forAuxiliaryExecutable: "Updater.app")
    guard
      AppUpdateQuitOrigin.isUpdaterQuit(
        event: NSAppleEventManager.shared().currentAppleEvent, updaterAppURL: updaterAppURL)
    else { return .terminateNow }
    guard rejectIfBusy() == false else { return .terminateCancel }
    // 先按原契约提交输入框草稿(回车/失焦),下一拍重读忙碌后再真正退出。
    guard AppUpdateInteraction.endEditing(in: NSApp.windows) else {
      logger.info("updater quit cancelled: an editor refused to end editing")
      return .terminateCancel
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        NSApp.reply(toApplicationShouldTerminate: true)
        return
      }
      let proceed = !self.rejectIfBusy()
      if proceed { self.logger.info("updater quit accepted (idle)") }
      NSApp.reply(toApplicationShouldTerminate: proceed)
    }
    return .terminateLater
  }

  /// 忙碌时记录并提示,返回 true;空闲返回 false。
  private func rejectIfBusy() -> Bool {
    let busy = busyState
    guard busy.isBusy else { return false }
    logger.info(
      "updater quit rejected: recording=\(busy.recording, privacy: .public) tasks=\(busy.postMeetingTasks, privacy: .public) models=\(busy.modelPreparation, privacy: .public) notes=\(busy.notesSaving, privacy: .public) finishing=\(busy.finishingMeeting, privacy: .public)"
    )
    let message = busy.quitRejectedMessage
    AppUpdateInteraction.runModalOffMainQueue {
      let alert = NSAlert()
      alert.messageText = "暂时不能安装更新"
      alert.informativeText = message
      alert.addButton(withTitle: "知道了")
      return alert
    } completion: { _ in
    }
    return true
  }

  // MARK: - SPUUpdaterDelegate

  /// 忙碌时不开始检查:手动检查由 Sparkle 显示这条说明,后台定时检查静默跳过。
  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    let busy = busyState
    guard busy.isBusy else { return }
    throw NSError(
      domain: "com.justsaid.app.updates", code: 1,
      userInfo: [NSLocalizedDescriptionKey: busy.checkBlockedMessage])
  }
}

/// R9:不在本地收集系统画像。Sparkle 2.10.0 的首次自动检查询问(`SPUUpdater.m:424`)与画像上传
/// 都经这个公开 getter 取值,默认实现会读取机型、CPU、内存与语言;返回空数组后收集函数不再执行。
/// 询问窗口的画像区域本就因 `SUEnableSystemProfiling=false` 隐藏,询问与选择不变。
final class ProfileFreeUpdater: SPUUpdater {
  override var systemProfileArray: [[String: String]] { [] }
}

/// 只覆盖初次「准备好安装」:立即安装并重启 → `.install`;稍后 → `.dismiss`,
/// Sparkle 在下次主动退出时安装、不自动重启(真实探针 C3 已验证)。
final class ReadyToInstallChoiceUserDriver: SPUStandardUserDriver {
  override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    AppUpdateInteraction.runModalOffMainQueue {
      let alert = NSAlert()
      alert.messageText = "更新已准备好"
      alert.informativeText = "立即安装会退出并重新打开 JustSaid。选择稍后，会在你下次主动退出 JustSaid 时安装，不会自动重新打开。"
      alert.addButton(withTitle: "立即安装并重启")
      alert.addButton(withTitle: "稍后")
      return alert
    } completion: { response in
      reply(response == .alertFirstButtonReturn ? .install : .dismiss)
    }
  }
}
