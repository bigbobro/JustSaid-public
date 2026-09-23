import AppKit
import Combine
import CoreServices
import JustSaidCore
import SwiftUI

// 应用内更新里与 Sparkle 无关的部分:是否启用、忙碌来源、单次退出请求的来源判别和设置桥。
// Sparkle 只由 App target 导入;这里不引用它,验证程序可以直接覆盖这些判定。

/// 生产更新器是否启动。只有打包入口盖章的分发构建启用:debug 构建、未盖章的
/// `JustSaidUpdaterEnabled`、缺 feed 或公钥时一律不启动,不提供运行时环境覆盖。
public enum AppUpdatePolicy {
  public static let enabledInfoKey = "JustSaidUpdaterEnabled"

  public static func isEnabled(infoDictionary: [String: Any]?, isDebugBuild: Bool) -> Bool {
    guard !isDebugBuild, let info = infoDictionary,
      info[enabledInfoKey] as? Bool == true,
      let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
      let key = info["SUPublicEDKey"] as? String, !key.isEmpty
    else { return false }
    return true
  }
}

/// 更新器检查与最终退出时读取的真实业务状态。只读既有所有者:录制会话、会后任务、
/// 模型准备、补充记录的未完成写入,以及「结束会议」收尾本身;不扫描会议目录、不另建登记。
/// 输入框草稿按原契约在提交(回车/失焦)时同步落盘,更新器退出前先结束编辑触发这些提交。
public struct AppUpdateBusyState: Equatable, Sendable {
  public var recording: Bool
  public var postMeetingTasks: Bool
  public var modelPreparation: Bool
  public var notesSaving: Bool
  public var finishingMeeting: Bool

  public init(
    recording: Bool, postMeetingTasks: Bool, modelPreparation: Bool,
    notesSaving: Bool = false, finishingMeeting: Bool = false
  ) {
    self.recording = recording
    self.postMeetingTasks = postMeetingTasks
    self.modelPreparation = modelPreparation
    self.notesSaving = notesSaving
    self.finishingMeeting = finishingMeeting
  }

  public var isBusy: Bool {
    recording || postMeetingTasks || modelPreparation || notesSaving || finishingMeeting
  }

  @MainActor
  public static func current(
    appCoordinator: AppCoordinator,
    recordingSession: RecordingSession,
    modelAssets: LocalModelAssetManager
  ) -> AppUpdateBusyState {
    AppUpdateBusyState(
      recording: recordingSession.phase.isBusy,
      postMeetingTasks: appCoordinator.postMeetingTasks.hasActiveTasks,
      modelPreparation: modelAssets.isBusy,
      notesSaving: NotesController.pendingWriteTotal > 0,
      finishingMeeting: appCoordinator.finishingMeetingCount > 0
    )
  }

  private var reason: String {
    var parts: [String] = []
    if recording { parts.append("正在录制") }
    if finishingMeeting || notesSaving { parts.append("会议记录还在保存") }
    if postMeetingTasks { parts.append("会后处理或录音导入还在进行") }
    if modelPreparation { parts.append("本地模型正在准备") }
    return parts.joined(separator: "、")
  }

  /// 忙碌时手动检查的说明(Sparkle 以错误窗口显示;后台定时检查静默跳过)。
  public var checkBlockedMessage: String {
    "\(reason)，暂时不检查或安装更新。完成后再选择「检查更新…」。"
  }

  /// 更新器请求退出被挡下时的说明。此前已选择「立即安装并重启」,Sparkle 保留这次安装
  /// 与重启意图,所以不能说成已取消或改为稍后。
  public var quitRejectedMessage: String {
    "\(reason)，JustSaid 这次不会退出安装。完成后选择「检查更新…」继续安装并重新打开；"
      + "如果在那之前退出 JustSaid，这个更新也会在退出时安装并重新打开。"
  }
}

/// 单次退出请求是否由当前已加载 Sparkle 框架内的 Updater.app 发出。只在
/// `applicationShouldTerminate` 内同步判定,不缓存 PID,也不看「是否有更新会话」。
public enum AppUpdateQuitOrigin {
  public static func isUpdaterQuit(
    event: NSAppleEventDescriptor?,
    updaterAppURL: URL?,
    bundleURLForProcess: (pid_t) -> URL? = {
      NSRunningApplication(processIdentifier: $0)?.bundleURL
    }
  ) -> Bool {
    guard let event,
      event.eventClass == AEEventClass(kCoreEventClass),
      event.eventID == AEEventID(kAEQuitApplication),
      let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))
    else { return false }
    return isUpdater(
      senderPIDDescriptor: sender, updaterAppURL: updaterAppURL,
      bundleURLForProcess: bundleURLForProcess)
  }

  /// `spid` 属性的判定部分。实测 Updater 发来的 spid 是 typeUInt32('magn'),
  /// 交给 Apple Event Manager 转换成 typeSInt32 再读,不信任声明类型。
  public static func isUpdater(
    senderPIDDescriptor: NSAppleEventDescriptor,
    updaterAppURL: URL?,
    bundleURLForProcess: (pid_t) -> URL?
  ) -> Bool {
    guard
      let senderPID = senderPIDDescriptor.coerce(toDescriptorType: DescType(typeSInt32))?
        .int32Value,
      senderPID > 0,
      let updaterAppURL,
      let senderURL = bundleURLForProcess(senderPID)
    else { return false }
    return canonicalPath(senderURL) == canonicalPath(updaterAppURL)
  }

  static func canonicalPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }
}

/// 更新器相关的提示与退出前的编辑收尾。
@MainActor
public enum AppUpdateInteraction {
  /// 在 run loop 上(而不是主队列块里)运行模态提示:Sparkle 从主队列回调,若在其中
  /// 嵌套 `runModal()`,提示打开期间主队列与 MainActor 任务会被饿住。
  public static func runModalOffMainQueue(
    _ makeAlert: @escaping @MainActor () -> NSAlert,
    completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
  ) {
    RunLoop.main.perform(inModes: [.common]) {
      MainActor.assumeIsolated {
        let alert = makeAlert()
        NSApp.activate()
        completion(alert.runModal())
      }
    }
  }

  /// 结束所有窗口里的编辑,让既有的回车/失焦提交先落盘。任何窗口拒绝结束编辑时返回 false。
  public static func endEditing(in windows: [NSWindow]) -> Bool {
    windows.allSatisfy { $0.makeFirstResponder(nil) }
  }
}

/// 设置页与菜单使用的更新入口。App 层用 Sparkle 更新器的真实持久化选择构造;
/// 更新器未启用(开发构建)时不存在,设置页不显示更新卡片。
@MainActor
public final class AppUpdatesModel: ObservableObject {
  @Published public private(set) var automaticallyChecksForUpdates: Bool

  private let readAutomaticChecks: () -> Bool
  private let writeAutomaticChecks: (Bool) -> Void
  private let performCheck: () -> Void
  private var defaultsObservation: AnyCancellable?

  /// Sparkle 把选择持久化在宿主的标准 UserDefaults(`SUEnableAutomaticChecks`);首次询问
  /// 等外部改写都会发出 `didChangeNotification`,设置页已打开时也随之刷新。
  public init(
    readAutomaticChecks: @escaping () -> Bool,
    writeAutomaticChecks: @escaping (Bool) -> Void,
    checkForUpdates: @escaping () -> Void,
    notificationCenter: NotificationCenter = .default
  ) {
    self.readAutomaticChecks = readAutomaticChecks
    self.writeAutomaticChecks = writeAutomaticChecks
    self.performCheck = checkForUpdates
    automaticallyChecksForUpdates = readAutomaticChecks()
    defaultsObservation = notificationCenter.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.refresh() }
  }

  public func refresh() {
    let current = readAutomaticChecks()
    if automaticallyChecksForUpdates != current {
      automaticallyChecksForUpdates = current
    }
  }

  public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    writeAutomaticChecks(enabled)
    refresh()
  }

  public func checkForUpdates() {
    performCheck()
  }
}

struct AppUpdateSettingsCard: View {
  @ObservedObject var model: AppUpdatesModel

  var body: some View {
    SettingsFormGroup(
      "应用更新", hint: "从公开正式版获取新版本。"
    ) {
      // 一行装下:开关是「以后自动查」,按钮是「现在就查」,同一件事的两个时态。
      // 原来拆两行,第二行的标签只能叫「现在」——这一页其余标签都在命名一个真东西
      // (界面/字号/当前时区/保留/回声消除),只有它什么都没命名,是为了填满标签列
      // 硬造出来的。需要造标签才能成行,通常说明它不该单独成行(owner 2026-09-21:
      // 「以美观优先」)。
      SettingsFormRow("自动检查", isFirst: true) {
        Toggle(
          "自动检查更新",
          isOn: Binding(
            get: { model.automaticallyChecksForUpdates },
            set: { model.setAutomaticallyChecksForUpdates($0) }
          )
        )
        .toggleStyle(.v1Switch)
        .labelsHidden()
        .runtimeAccessibilityIdentifier("settings.app-updates.automatic-checks")
        Button("检查更新…") { model.checkForUpdates() }
          .buttonStyle(.v1Outline)
          .help("发现新版后仍由你决定是否安装。检查只请求更新清单和安装包，不发送会议内容或系统信息。")
          .runtimeAccessibilityIdentifier("settings.app-updates.check")
      }
    }
    .runtimeAccessibilityIdentifier("settings.app-updates")
  }
}
