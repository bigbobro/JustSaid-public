import AppKit
import JustSaidCore
import JustSaidUI
import SwiftUI

@main
struct JustSaidApp: App {
  /// 卡死哨兵引导(08-16 加固)。static let 保证进程内只执行一次;
  /// 不放 app delegate——adaptor 的 `applicationDidFinishLaunching` 不会被调用,
  /// 接在那里是无声的死代码(2026-08-16 实证,详见 JustSaidAppDelegate 注释)。
  /// 前后台面包屑让事故报告能区分「操作中卡死」与「后台自转」。
  private static let sentinelBootstrap: Void = {
    HangSentinel.shared.start(
      processStartedAt: NSRunningApplication.current.launchDate ?? Date()
    )
    AudioRetentionScheduler.shared.start()
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
    ) { _ in
      HangSentinel.shared.note("app:active")
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
    ) { _ in
      HangSentinel.shared.note("app:inactive")
    }
  }()
  private let registry: ProviderRegistry
  @StateObject private var providerSettings: ProviderSettingsStore
  @StateObject private var recordingSession: RecordingSession
  @StateObject private var summaryFeed: LiveSummaryFeed
  @StateObject private var modelAssetManager: LocalModelAssetManager
  @State private var startupStorageFailure: String?
  @StateObject private var appCoordinator: AppCoordinator
  /// 应用更新器(进程内唯一,与主窗无关);开发构建与未盖章的包为 nil。
  private let appUpdater: AppUpdater?
  @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue =
    AppAppearance.system.rawValue
  // 关主窗不退出(T11)必须经由 SwiftUI 的 delegate 适配器安装,不能直接赋值 NSApp.delegate。
  @NSApplicationDelegateAdaptor(JustSaidAppDelegate.self) private var appDelegate

  init() {
    _ = Self.sentinelBootstrap
    // 转写抽屉每次启动都从收起开始(2026-08-19 实机改判)。
    //
    // 07-31 的「展开偏好跨会话记住」是给**左侧定宽栏**定的:那时展开只是并排多一列,
    // 记住它没有代价。08-19 把转写改成盖住两列下沿的 overlay 抽屉之后,同一个 true
    // 变成了「一进驾驶舱就有 240pt 压在整理区和右栏上」——旧偏好的语义被换掉了,
    // 键名却没换,于是老用户开机第一眼看到的是被遮住的驾驶舱。
    // 复位放在 App 启动这一层而不是视图里:视图里改会和验证夹具打架
    // (UIHierarchy / UIScreenshots 正是靠写这个 key 驱动细条/抽屉两态),
    // 而夹具直接构造 MainWorkspaceView、根本不经过这里。
    UserDefaults.standard.set(false, forKey: "justsaid.transcriptExpanded")
    let registry = ProviderRegistry()
    let providerSettings = ProviderSettingsStore(registry: registry)
    let meetingStore = MeetingStore()
    let transport = URLSessionHTTPTransport()
    let postMeetingPipelineResolver: LiveSummaryFeed.PostMeetingPipelineResolver = {
      try providerSettings.makeDefaultPostMeetingPipeline(
        transport: transport,
        meetingStore: meetingStore
      )
    }
    // 会后长任务的唯一所有者。**必须是同一个实例**同时交给会中总结与应用协调者:
    // 两份就是两个去重源,启动续查会和手动精转对同一目录各跑一遍。
    let postMeetingTasks = PostMeetingTaskCoordinator(
      meetingStore: meetingStore,
      pipelineResolver: postMeetingPipelineResolver
    )
    self.registry = registry
    _providerSettings = StateObject(
      wrappedValue: providerSettings
    )
    // 录制会话、协调者(含会后任务)与模型管理器同时交给更新器的最终退出守卫与退出确认,必须是界面用的同一实例。
    let recordingSession = RecordingSession(store: meetingStore)
    _recordingSession = StateObject(
      wrappedValue: recordingSession
    )
    _summaryFeed = StateObject(
      wrappedValue: LiveSummaryFeed(
        clientResolver: {
          try providerSettings.makeLLMClient(
            for: .liveSummaryLLM,
            transport: transport
          )
        },
        postMeetingPipelineResolver: postMeetingPipelineResolver,
        meetingStore: meetingStore,
        postMeetingTasks: postMeetingTasks
      )
    )
    let appCoordinator = AppCoordinator(
      meetingStore: meetingStore,
      postMeetingPipelineResolver: postMeetingPipelineResolver,
      postMeetingTasks: postMeetingTasks
    )
    _appCoordinator = StateObject(
      wrappedValue: appCoordinator
    )
    let modelAssetManager = LocalModelAssetManager(
      catalogResult: LocalModelAssetCatalogLoader.loadFromBundle(.main),
      modelsRoot: LocalModelAssetManager.defaultModelsRoot(),
      transport: URLSessionModelAssetDownloadTransport()
    )
    _modelAssetManager = StateObject(
      wrappedValue: modelAssetManager
    )
    appUpdater = AppUpdater.installIfEnabled(
      appCoordinator: appCoordinator,
      recordingSession: recordingSession,
      modelAssets: modelAssetManager
    )
    appCoordinator.appUpdates = appUpdater?.model
    QuitConfirmation.install(recordingSession: recordingSession, appCoordinator: appCoordinator)
  }

  var body: some Scene {
    WindowGroup(id: Self.mainSceneID) {
      MainWorkspaceView(
        registry: registry,
        providerSettings: providerSettings,
        recordingSession: recordingSession,
        summaryFeed: summaryFeed,
        appCoordinator: appCoordinator,
        modelAssetManager: modelAssetManager
      )
      .preferredColorScheme(
        AppAppearance.persisted(appearanceRawValue).preferredColorScheme
      )
      .background(MainWindowOpenerRegistrar(appCoordinator: appCoordinator))
      .background(FullSizeContentWindowConfigurator())
      .task {
        // 菜单栏常驻入口(T11):关主窗不退出、录音继续,菜单栏是唯一入口。
        appCoordinator.installMenuBarIfNeeded(
          recordingSession: recordingSession,
          summaryFeed: summaryFeed,
          providerSettings: providerSettings
        )
        await modelAssetManager.refresh()
        await providerSettings.refreshStorageHealthForStartup()
        startupStorageFailure = providerSettings.storageHealthFailureMessage
      }
      // 窗最小 1040×640（ui-spec §2）：低于此转写区自动折叠让位。
      .frame(minWidth: 1_040, minHeight: 640)
      .alert(
        "对象存储不可用",
        isPresented: Binding(
          get: { startupStorageFailure != nil },
          set: { isPresented in
            if !isPresented {
              startupStorageFailure = nil
            }
          }
        )
      ) {
        Button("知道了", role: .cancel) {
          startupStorageFailure = nil
        }
      } message: {
        Text(startupStorageFailure ?? "")
      }
    }
    .defaultSize(width: 1320, height: 780)
    // 2026-09-20 owner:独立标题栏横在整个应用上面太难看。内容顶到 y=0,
    // 图标轨与页面都从最上面开始,系统红绿灯浮在轨的顶端空位上,轨宽由 V1 令牌留足余量。
    .windowStyle(.hiddenTitleBar)
    // 设置的唯一入口路径(2026-08-20 批4 容器收敛):此前 Settings scene 固定
    // frame 760×680 会裁长词表,且与 gear/轨按钮凑成 ⌘, 三注册。现在 ⌘, 唯一
    // owner 是这条菜单命令(无主窗也生效),真身始终是主窗上那张可拉伸 sheet。
    // 真机实测(批4-E):没有 Settings scene 时 `.appSettings` 占位不渲染,
    // replacing 会把菜单项连同 ⌘, 一起吞成死键——改挂在「关于」之后,不依赖占位。
    .commands {
      CommandGroup(after: .appInfo) {
        if let appUpdater {
          Button("检查更新…") { appUpdater.checkForUpdates() }
        }
        Divider()
        OpenSettingsCommand(appCoordinator: appCoordinator)
      }
      MeetingSessionCommands(
        appCoordinator: appCoordinator,
        recordingSession: recordingSession
      )
    }
  }
}

extension JustSaidApp {
  /// 主窗 Scene id:openWindow(id:) 重开已关闭的主窗用(批4-E 真机修正)。
  static let mainSceneID = "JustSaid.MainScene"
}

/// 把 SwiftUI 的 `openWindow(id:)` 登记给 AppCoordinator:悬浮内容「回主窗」在主窗
/// 已关闭时走这条与菜单命令相同的重开路由(`newWindowForTab` 对本 App 空转)。
/// 让内容真的顶到 y=0。`.windowStyle(.hiddenTitleBar)` 只把标题栏做成透明并藏掉标题,
/// 内容仍旧从标题栏底下开始,顶上因此留了一条约 28 点的白带,图标轨的底色进不去,
/// 红绿灯浮在白带上而不是浮在轨上(2026-09-20 真机放大实测)。真正管用的开关是
/// `.fullSizeContentView`,SwiftUI 不暴露它,所以到 NSWindow 上直接加。
private struct FullSizeContentWindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { ConfiguratorView() }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class ConfiguratorView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      window.styleMask.insert(.fullSizeContentView)
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
    }
  }
}

private struct MainWindowOpenerRegistrar: View {
  @Environment(\.openWindow) private var openWindow
  let appCoordinator: AppCoordinator

  var body: some View {
    Color.clear
      .onAppear {
        let openWindow = openWindow
        appCoordinator.registerMainWindowOpener {
          openWindow(id: JustSaidApp.mainSceneID)
        }
      }
  }
}

/// 「设置…」菜单命令(⌘, 唯一 owner)。有可见主窗走前置+挂起请求;
/// 无主窗时 `newWindowForTab` 空转(真机实测),必须走 SwiftUI openWindow 重开,
/// 新窗 onAppear 消费挂起请求补弹设置 sheet。
private struct OpenSettingsCommand: View {
  @Environment(\.openWindow) private var openWindow
  let appCoordinator: AppCoordinator

  var body: some View {
    Button("设置…") {
      appCoordinator.pendingSettingsRequest = true
      if appCoordinator.hasVisibleMainWindow {
        appCoordinator.activateMainWindow()
      } else {
        openWindow(id: JustSaidApp.mainSceneID)
      }
    }
    .keyboardShortcut(",", modifiers: .command)
  }
}

/// 会中四键的唯一注册点(批1):⌘L/⌘K/⌥⌘X/⌥⌘P 从顶栏与驾驶舱轨拆出,
/// 挂在 App 层 `.commands`,两套 chrome 的按钮只管展示与点击。
/// 无主窗时与 ⌘, 同款:openWindow 重开,主窗 onAppear 消费挂起请求。
private struct MeetingSessionCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var appCoordinator: AppCoordinator
  @ObservedObject var recordingSession: RecordingSession

  private var isRecording: Bool { recordingSession.phase == .recording }
  private var isSessionActive: Bool {
    recordingSession.phase == .recording || recordingSession.phase == .stopping
  }

  private var workspaceToggleTitle: String {
    if appCoordinator.workspaceMode != .cockpit {
      return isSessionActive ? "返回会中" : "切换到会中"
    }
    return "切换到会议库"
  }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      // ⌘R 只在文件菜单注册,其他开始入口沿用协调者同一动作。
      Button("开始一场会议") {
        ensureMainWindow()
        appCoordinator.requestStartMeeting()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(isSessionActive)
      Button("导入录音…") {
        appCoordinator.requestImportRecording()
      }
      Button("重新扫描录音文件夹") {
        appCoordinator.requestRescanRecordings()
      }
      Divider()
      Button("在 Finder 中显示录音") { appCoordinator.revealRecordingsInFinder() }
    }

    CommandMenu("会议") {
      Button("标记重点") { appCoordinator.requestMark() }
        .disabled(!isRecording)
      Button(appCoordinator.isChatExclusionOpen ? "结束闲聊" : "闲聊") {
        ensureMainWindow()
        appCoordinator.requestToggleChat()
      }
      .keyboardShortcut("x", modifiers: [.command, .option])
      .disabled(recordingSession.startedAt == nil || !isRecording)
      Button(recordingSession.isMicrophonePaused ? "恢复麦克风" : "暂停麦克风") {
        appCoordinator.requestToggleMicrophonePause()
      }
      .keyboardShortcut("p", modifiers: [.command, .option])
      .disabled(!isRecording)
      Divider()
      Button("结束会议") { appCoordinator.requestEndMeeting() }
        .disabled(!isRecording)
      Divider()
      Button("查看历史会议") {
        ensureMainWindow()
        appCoordinator.openLibrary()
      }
      Divider()
      Button(workspaceToggleTitle) {
        ensureMainWindow()
        appCoordinator.toggleWorkspaceMode()
      }
      .keyboardShortcut("l", modifiers: .command)

      Button("章节目录") {
        ensureMainWindow()
        appCoordinator.requestChapterDirectory()
      }
      .keyboardShortcut("k", modifiers: .command)
      .disabled(!isSessionActive)

    }
  }

  private func ensureMainWindow() {
    if appCoordinator.hasVisibleMainWindow {
      appCoordinator.activateMainWindow()
    } else {
      openWindow(id: JustSaidApp.mainSceneID)
    }
  }
}
