import AppKit
import Combine
import JustSaidCore

/// 主工作台全局模式:两个页面共用同一个 SwiftUI 主窗和同一份会议状态。
public enum WorkspaceMode: Equatable, Sendable {
  case cockpit
  case library
}

/// 应用级协调者(拍板 T11):安装菜单栏常驻入口、维持"关主窗不退出、录音继续"、
/// 支持从菜单栏直接开始会议录音(未在录制时),并统一主窗的驾驶舱/会议库导航。
@MainActor
public final class AppCoordinator: ObservableObject {
  @Published public private(set) var workspaceMode: WorkspaceMode = .library
  @Published public private(set) var libraryFocus: URL?
  @Published public private(set) var libraryRefreshGeneration = 0
  /// 会议库 remount 之间保留的纯呈现态。数据仍由每个新 model 重新扫盘；
  /// 这里只记用户所在位置，不缓存会议内容与会后任务状态。
  @Published public var librarySelectedMeetingID: String?
  @Published public var librarySelectedTab: MeetingDetailTab = .onePage
  @Published public var libraryListScrollPosition: String?
  /// 四页签各自的正文滚动;只服务当前选中会议,换场由会议库视图清掉。
  /// 它是 app 生命周期内存，但不是观察状态：正文只在滚动结束/idle 时写回，不能为一个
  /// contentOffset 让主窗与菜单根视图广播失效。
  public var libraryTabScrollOffsets: [MeetingDetailTab: Double] = [:]
  /// 全库搜索关键词(08-17 #1):与选中/页签同级的用户上下文。remount 后由新 model
  /// 恢复并按当下磁盘重扫——保留的是 query,不缓存旧结果。
  @Published public var libraryGlobalSearchQuery: String = ""
  /// 「按客户分组」开关(08-17 R-b):纯呈现态,与选中/页签同层存活 remount;
  /// 分段每次由新 model 按当下磁盘现算,不缓存旧分组。
  @Published public var libraryGroupByClient = false
  /// 指挥台滤镜(批3-C,G3):随 ⌘L remount 存活的呈现态。
  @Published public var libraryQueueFilter = LibraryQueueFilter.all
  /// 设置打开请求(批4 容器收敛):菜单 ⌘, 经此路由到主窗 sheet。
  /// 用「挂起标志 + 挂载补发」而不是裸代次:无主窗时 openSettings 先触发重开主窗,
  /// 新视图首次挂载晚于代次递增,onChange(initial: false)会把基线记在已递增值上
  /// 丢掉这次请求——与 pendingEndMeetingRequest/flushPendingMenuRequests 同款先例。
  @Published public var pendingSettingsRequest = false
  /// 章节目录打开请求(批1 快捷键迁移):菜单 ⌘K 经此路由到当前 chrome 的 popover。
  /// 与 pendingSettingsRequest 同款:无主窗时命令先 openWindow,新视图 onAppear 消费。
  @Published public var pendingChapterDirectoryRequest = false

  public let meetingStore: MeetingStore
  public let postMeetingPipelineResolver: (() throws -> PostMeetingPipeline)?
  /// 会后长任务的唯一所有者。这里原先并列着一份续查专用的任务字典,已整体并入协调者
  /// ——两个字典就是两个去重源,启动续查会和手动精转对同一目录各跑一遍。
  public let postMeetingTasks: PostMeetingTaskCoordinator

  private var menuBar: MenuBarController?
  private weak var recordingSession: RecordingSession?
  private weak var mainWindow: NSWindow?
  /// 菜单栏「结束会议」路由到的确认流(08-14 捎带):主窗存活时由 MainWorkspaceView
  /// 注册自己的 `requestEndMeeting`(含「闲聊未封口」兜底确认);nil = 主窗不在。
  /// 08-15 G9/F-C4 起,nil 分支先查未封口闲聊:有则唤起主窗挂起请求走既有确认流,
  /// 没有才退回直接收尾。
  public private(set) var requestStartMeetingHandler: (() -> Void)?
  public private(set) var requestEndMeetingHandler: (() -> Void)?
  /// 菜单栏「标记重点」路由到的入口(08-15 G9/F-C7):与右栏补充记录区同一颗
  /// `NotesController.beginMark`,由 MainWorkspaceView onAppear 注册;nil = 主窗不在。
  public private(set) var requestMarkHandler: (() -> Void)?
  /// 菜单 ⌥⌘X「闲聊」路由到主窗同一套排除写入(批1):主窗存活时由
  /// MainWorkspaceView 注册 `toggleChatExclusion`;nil = 主窗不在。
  public private(set) var requestToggleChatHandler: (() -> Void)?
  /// 主窗关闭期间菜单栏攒下的待补发请求。主窗重新 onAppear 注册 handler 后,
  /// 由 `flushPendingMenuRequests` 异步补发(必须异步一拍:注册发生在 onAppear 前段,
  /// 排除区间等状态在 onAppear 后段才装载,同拍直调会让「闲聊未封口」确认被跳过——
  /// 那正是 F-C4 要修的病,不能从后门再放回来)。
  private var pendingStartMeetingRequest = false
  private var pendingEndMeetingRequest = false
  private var pendingMarkRequest = false
  private var pendingToggleChatRequest = false
  /// 热键/菜单栏标记成功后的不抢焦点回执:悬浮窗在场闪它,否则闪菜单栏图标。
  private var markOverlayVisible: (() -> Bool)?
  private var markFlashOverlay: (() -> Void)?
  /// 闲聊/暂停全局热键的文案回执(开/关两态);回调必须不激活任何窗口。
  private var actionFlashOverlay: ((String) -> Void)?
  /// Orphaned process states are a launch-time repair. Re-running it on every ⌘L navigation
  /// can misclassify a historical meeting that this process is actively reprocessing.
  private var didReconcileInterruptedMeetings = false
  private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier(
    "JustSaid.MainWorkspace"
  )

  public init(
    meetingStore: MeetingStore = MeetingStore(),
    postMeetingPipelineResolver: (() throws -> PostMeetingPipeline)? = nil,
    postMeetingTasks: PostMeetingTaskCoordinator? = nil
  ) {
    self.meetingStore = meetingStore
    self.postMeetingPipelineResolver = postMeetingPipelineResolver
    self.postMeetingTasks =
      postMeetingTasks
      ?? PostMeetingTaskCoordinator(
        meetingStore: meetingStore,
        pipelineResolver: postMeetingPipelineResolver
      )
    let store = meetingStore
    Task.detached(priority: .utility) {
      CompletenessBackfill.reconcile(in: store)
      await MainActor.run {
        self.libraryRefreshGeneration &+= 1
      }
    }
  }

  /// SwiftUI 主工作台解析到宿主窗口时登记到这里。窗口关闭后弱引用会自然失效;
  /// 新建的 `WindowGroup` 实例再次出现时会重新登记。
  public func registerMainWindow(_ window: NSWindow?) {
    window?.identifier = Self.mainWindowIdentifier
    mainWindow = window
  }

  /// 把最小尺寸钉到 NSWindow 本体(2026-07-31 实测):只在 SwiftUI 内容上写
  /// minWidth,窗口恢复旧的更小 frame 时内容会"居中裁两边"。窗口当前比最小值
  /// 窄就当场拉宽——布局契约必须由窗口而不是内容单方面兜底。
  public func enforceMainWindowMinSize(width: CGFloat, height: CGFloat = 640) {
    guard let window = mainWindow else { return }
    window.minSize = NSSize(width: width, height: height)
    var frame = window.frame
    if frame.width < width {
      frame.size.width = width
      window.setFrame(frame, display: true, animate: true)
    }
  }

  /// 主窗与菜单栏都登记同一录制会话；切到会议库时据此跳过仍在写入的当前目录。
  public func registerRecordingSession(_ recordingSession: RecordingSession) {
    self.recordingSession = recordingSession
  }

  /// 主窗出现时注册唯一的「开始会议」入口,消失时注销(传 nil)。
  public func registerRequestStartMeetingHandler(_ handler: (() -> Void)?) {
    requestStartMeetingHandler = handler
    flushPendingMenuRequests()
  }

  /// 主窗出现时注册自己的「结束会议」确认流,消失时注销(传 nil)。
  /// 与 registerMainWindow/registerRecordingSession 同一注册模式。
  public func registerRequestEndMeetingHandler(_ handler: (() -> Void)?) {
    requestEndMeetingHandler = handler
    flushPendingMenuRequests()
  }

  /// 主窗出现时注册「标记重点」入口(NotesController.beginMark),消失时注销。
  public func registerRequestMarkHandler(_ handler: (() -> Void)?) {
    requestMarkHandler = handler
    flushPendingMenuRequests()
  }

  /// 主窗出现时注册「闲聊」开关,消失时注销。
  public func registerRequestToggleChatHandler(_ handler: (() -> Void)?) {
    requestToggleChatHandler = handler
    flushPendingMenuRequests()
  }

  /// 主窗出现时挂上标记回执,消失时注销。回调必须不激活任何窗口。
  public func registerMarkFeedback(
    overlayVisible: (() -> Bool)?,
    flashOverlay: (() -> Void)?,
    flashOverlayMessage: ((String) -> Void)? = nil
  ) {
    markOverlayVisible = overlayVisible
    markFlashOverlay = flashOverlay
    actionFlashOverlay = flashOverlayMessage
  }

  /// 菜单栏「标记重点」与全局热键的同一入口。
  /// 门在 `.recording`:starting 态 startedAt 未落,标记会落到 00:00。
  /// 主窗存活时不把主窗拉到前台——共享屏幕盖住主窗正是这条路径的存在理由。
  public func requestMark() {
    guard recordingSession?.phase == .recording else { return }
    guard MarkTriggerGate.tryBegin() else { return }
    if let requestMark = requestMarkHandler {
      requestMark()
      presentMarkFeedback()
      return
    }
    // 主窗已关闭:标记状态机(NotesController)挂在主窗上,先唤起主窗,
    // onAppear 注册 handler 后由 flushPendingMenuRequests 补发这一颗标记。
    pendingMarkRequest = true
    activateMainWindow()
  }

  private func presentMarkFeedback() {
    if markOverlayVisible?() == true {
      markFlashOverlay?()
    } else {
      menuBar?.flashMarkConfirmation()
    }
  }

  private func presentActionFeedback(_ text: String) {
    if markOverlayVisible?() == true, let actionFlashOverlay {
      actionFlashOverlay(text)
    } else {
      menuBar?.flashActionConfirmation(tooltip: "JustSaid · \(text)")
    }
  }

  /// 菜单栏「开始会议」的唯一路由:主窗在就直接交给它的 start action(统一经模型准备门),
  /// 主窗不在就先攒下并唤起主窗,由注册回调补发。
  ///
  /// `.stopping` 不往下走(issue #28):上一场的 `stop()` 要跑完两路 writer 收尾与速记
  /// 收尾,长会议是秒级的;这段窗口里请求一路穿到 `RecordingSession.start()`,会被它
  /// 自己的相位门**静默 return**——不建目录、不写盘、不留 `recording.start` 账本事件、
  /// 也不留启动轨迹,菜单栏那一次点击因此变成一个事后查不出来的空转
  /// (「结束会议后立刻开始新会议,似乎失败」)。
  ///
  /// 但**必须保留 `activateMainWindow()`**:主窗工具栏两处主按钮早就把 `.stopping` 画成
  /// 禁用的「正在保存…」,把主窗拉到前台正是用户唯一看得见的解释。连窗都不唤起等于
  /// 把仅有的回执也拿掉,那比原来的空转还糟。
  public func requestStartMeeting() {
    let phase = recordingSession?.phase
    guard phase != .recording, phase != .starting else { return }
    if phase == .stopping {
      activateMainWindow()
      return
    }
    if let requestStartMeeting = requestStartMeetingHandler {
      activateMainWindow()
      requestStartMeeting()
      return
    }
    pendingStartMeetingRequest = true
    activateMainWindow()
  }

  /// 补发主窗关闭期间攒下的菜单栏请求。录制已不在进行时直接作废——
  /// 挂起的「结束会议」打到 stopping/idle 上会绕过 stop() 的相位门,
  /// 挂起的「标记」会落在 00:00。
  private func flushPendingMenuRequests() {
    let phase = recordingSession?.phase
    if pendingStartMeetingRequest {
      pendingStartMeetingRequest = false
      // 攒着的「开始会议」在这期间已经开上了就作废,不补一次重复开会;
      // `.stopping` 同样作废,与 `requestStartMeeting` 保持同一句判词——补发到那一
      // 相位上会被 `RecordingSession.start()` 静默吞掉。(`requestStartMeeting` 修好后
      // 这一路已经攒不出 `.stopping` 期间的请求了,这里是判据一致,不是第二个入口。)
      if phase != .recording, phase != .starting, phase != .stopping,
        let requestStartMeetingHandler
      {
        Task { @MainActor in requestStartMeetingHandler() }
      }
    }
    guard recordingSession?.phase == .recording else {
      pendingEndMeetingRequest = false
      pendingMarkRequest = false
      pendingToggleChatRequest = false
      return
    }
    if pendingEndMeetingRequest, let requestEndMeetingHandler {
      pendingEndMeetingRequest = false
      Task { @MainActor in requestEndMeetingHandler() }
    }
    if pendingMarkRequest, let requestMarkHandler {
      pendingMarkRequest = false
      Task { @MainActor in requestMarkHandler() }
    }
    if pendingToggleChatRequest, let requestToggleChatHandler {
      pendingToggleChatRequest = false
      Task { @MainActor in requestToggleChatHandler() }
    }
  }

  /// 菜单 ⌥⌘X:与顶栏/轨上闲聊按钮同一 `toggleChatExclusion`。
  /// 相位门与按钮 `.disabled` 同口径——非 recording 或还没有 startedAt 则不写。
  /// 返回新的「闲聊中」态;相位门未过、双投被门住、或主窗不在(挂起)时返回 nil。
  @discardableResult
  public func requestToggleChat() -> Bool? {
    guard recordingSession?.phase == .recording, recordingSession?.startedAt != nil else {
      return nil
    }
    if let requestToggleChatHandler, let recordingSession {
      guard HotkeyTriggerGate.tryBegin(.chat) else { return nil }
      let wasOpen = hasOpenChatRange(recordingSession: recordingSession)
      requestToggleChatHandler()
      let isOpen = hasOpenChatRange(recordingSession: recordingSession)
      if wasOpen == isOpen { return nil }
      return isOpen
    }
    pendingToggleChatRequest = true
    activateMainWindow()
    return nil
  }

  /// 菜单 ⌥⌘P:直调 RecordingSession,不经 View。相位门与按钮 `.disabled` 同口径。
  /// 返回新的暂停态;相位门未过、双投被门住、或 Core 拒绝时返回 nil。
  @discardableResult
  public func requestToggleMicrophonePause() -> Bool? {
    guard let recordingSession, recordingSession.phase == .recording else { return nil }
    guard HotkeyTriggerGate.tryBegin(.pauseMicrophone) else { return nil }
    if recordingSession.isMicrophonePaused {
      guard recordingSession.resumeMicrophone() else { return nil }
      return false
    }
    guard recordingSession.pauseMicrophone() else { return nil }
    return true
  }

  /// 菜单 ⌘K:挂起后由主窗把当前 chrome 的章节 popover 打开。
  /// 空闲态无章节按钮,不得预置 true,否则开录那一瞬会弹出空目录。
  public func requestChapterDirectory() {
    let phase = recordingSession?.phase
    guard phase == .recording || phase == .stopping else { return }
    pendingChapterDirectoryRequest = true
  }

  /// 主窗不在时判断本场有没有未封口闲聊区间:直读 meeting.json,
  /// 与主窗 ChatExclusionBanner 同一事实源、同一 openRange 判定。
  private func hasOpenChatRange(recordingSession: RecordingSession) -> Bool {
    guard let directory = recordingSession.currentMeetingDirectory,
      let metadata = try? meetingStore.read(from: MeetingPaths(directory: directory))
    else {
      return false
    }
    return ExclusionUI.openRange(in: metadata.excludedRanges ?? []) != nil
  }

  /// 打开主窗内的会议库;`focus` 传入某场会议目录时直接选中它(刚结束的那一场)。
  /// 孤儿状态只在本进程第一次进入相关入口时修正，后续 ⌘L 纯导航。
  public func openLibrary(focus: URL? = nil) {
    reconcileInterruptedMeetingsIfNeeded()
    // 迁移前 ⌘L / 菜单栏进库会把会议库 model 整个 remount,终态横幅、失败保留的纪要
    // 草稿与导入错误随之清空。所有权搬到 app 生命周期协调者后要自己补回这个边界,
    // 否则它们会粘死一整个会话(快照优先于磁盘,还会遮住磁盘真相)。
    // 只收已经结算完的呈现态,运行中的任务与散会待处理输入一律不碰。
    postMeetingTasks.dismissSettledFeedback()
    libraryFocus = focus?.standardizedFileURL
    libraryRefreshGeneration &+= 1
    workspaceMode = .library
    activateMainWindow()
  }

  /// 回到会中驾驶舱。这个动作只换主窗内容,不触碰录音与转写任务。
  public func showCockpit() {
    workspaceMode = .cockpit
    activateMainWindow()
  }

  /// ⌘L 在驾驶舱与会议库之间切换;录制期间也只是导航,不会调用 `stop()`。
  public func toggleWorkspaceMode() {
    switch workspaceMode {
    case .cockpit:
      openLibrary()
    case .library:
      showCockpit()
    }
  }

  /// 启动时先找出有 request_id 的精转任务，再修复真正的孤儿过程态；顺序不能反，
  /// 否则尚可续查的会议会先被误标 interrupted。
  public func reconcileInterruptedMeetings() {
    didReconcileInterruptedMeetings = true
    let recoveries =
      postMeetingPipelineResolver == nil
      ? [] : meetingStore.pendingPostMeetingRecoveries()
    var activeDirectories = Set(
      recoveries.map { $0.paths.directory.standardizedFileURL }
    )
    // `PostMeetingPipeline.run` 先清 requestID 再置 `.processing`,这段窗口里会议对
    // 恢复扫描不可见(jobs 为空),不并进排除集就会被当场改写成 `.interrupted`。
    // 长会议这个窗口是分钟级,一次性闩锁挡不住 `reconcileInterruptedMeetings()` 的公开调用。
    activeDirectories.formUnion(postMeetingTasks.activeDirectories)
    if let recordingDirectory = recordingSession?.currentMeetingDirectory {
      activeDirectories.insert(recordingDirectory.standardizedFileURL)
    }
    meetingStore.reconcileInterruptedMeetings(excludingAnyOf: activeDirectories)
    startPostMeetingRecoveries(recoveries)
  }

  private func reconcileInterruptedMeetingsIfNeeded() {
    guard !didReconcileInterruptedMeetings else { return }
    reconcileInterruptedMeetings()
  }

  /// 续查的所有权、抢占语义(`superseded` 静默退出)与失败写盘都在协调者里;
  /// 这里只负责登记并刷新一次会议库。完成后的刷新由会议库自己订阅协调者完成,
  /// 不再 bump `libraryRefreshGeneration`——终态已不依赖任何 View 存活。
  private func startPostMeetingRecoveries(
    _ candidates: [PostMeetingRecoveryCandidate]
  ) {
    for candidate in candidates where postMeetingTasks.startRecovery(candidate) {
      libraryRefreshGeneration &+= 1
    }
  }

  /// 唤起主工作台窗口。优先使用工作台自己登记的窗口(批4 后设置只剩主窗 sheet,
  /// 无独立设置窗可误前置);主窗真被关掉时再走 SwiftUI 的重开动作。
  public func activateMainWindow() {
    let application = NSApplication.shared
    application.activate(ignoringOtherApps: true)
    let registeredWindow =
      mainWindow
      ?? application.windows.first { $0.identifier == Self.mainWindowIdentifier }
    if let registeredWindow {
      mainWindow = registeredWindow
      if registeredWindow.isMiniaturized {
        registeredWindow.deminiaturize(nil)
      }
      registeredWindow.makeKeyAndOrderFront(nil)
      return
    }

    application.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
  }

  /// 打开设置:挂起设置请求并唤起主窗(批4:设置唯一容器)。
  /// 主窗在场走 onChange 即时弹;刚被重开的主窗在 onAppear 消费挂起标志补发。
  /// 无主窗的重开不在这里做——`newWindowForTab` 对本 App 是空转(真机实测),
  /// 由菜单命令侧用 SwiftUI openWindow(id:) 重开,见 JustSaidApp。
  public func openSettings() {
    activateMainWindow()
    pendingSettingsRequest = true
  }

  /// 主窗当前是否可见(菜单命令用它决定走前置还是 openWindow 重开)。
  public var hasVisibleMainWindow: Bool {
    NSApplication.shared.windows.contains {
      $0.identifier == Self.mainWindowIdentifier && $0.isVisible
    }
  }


  public func installMenuBarIfNeeded(
    recordingSession: RecordingSession,
    summaryFeed: LiveSummaryFeed,
    providerSettings _: ProviderSettingsStore
  ) {
    registerRecordingSession(recordingSession)
    // 先续跑仍有 request_id 的精转；其余过程态才是上次留下的孤儿。
    reconcileInterruptedMeetingsIfNeeded()

    guard menuBar == nil else { return }

    let controller = MenuBarController(
      recordingSession: recordingSession,
      onStartMeeting: { [weak self] in
        self?.requestStartMeeting()
      },
      onEndMeeting: { [weak self, weak recordingSession, weak summaryFeed] in
        guard let recordingSession else { return }
        // 与主窗「结束会议」按钮同一入口(08-14 捎带):未封口的闲聊会先弹
        // 「封口并结束/撤销并结束/返回」确认。
        if let requestEndMeeting = self?.requestEndMeetingHandler {
          // 先把主窗唤到前台:确认对话挂在主窗上,窗口最小化/被压在后面时
          // 对话弹在看不见的地方,菜单点击看起来毫无反应(与 onStartMeeting
          // 前置 showCockpit 同一先例)。
          self?.activateMainWindow()
          requestEndMeeting()
          return
        }
        // F-C4(08-15):主窗不在且有未封口闲聊时,不再静默 stop——唤起主窗并挂起请求,
        // 主窗 onAppear 注册 handler 后异步补发,走与主窗完全一致的确认流。
        // 没有未封口闲聊(或元数据读不出来)才退回直接收尾:那种情况下确认流本来就会
        // 直通 endMeeting,没有内容会丢。
        if let self, self.hasOpenChatRange(recordingSession: recordingSession) {
          self.pendingEndMeetingRequest = true
          self.activateMainWindow()
          return
        }
        Task { @MainActor in
          await recordingSession.stop()
          summaryFeed?.ingest(recordingSession.liveSegments)
          let directory = recordingSession.currentMeetingDirectory
          summaryFeed?.stop(runPostMeeting: false)
          if recordingSession.phase == .completed {
            summaryFeed?.startPostMeetingProcessing(for: directory)
          }
          // 从菜单栏结束会议时主窗可能是关着的,直接把这场会议的产物页摆到用户面前。
          self?.openLibrary(focus: directory)
        }
      },
      onMarkNote: { [weak self] in
        // 与右栏补充记录区「标记重点」同一入口(G9/F-C7);全局热键也走 requestMark()。
        self?.requestMark()
      },
      onActivateMainWindow: { [weak self] in
        self?.activateMainWindow()
      },
      onOpenLibrary: { [weak self] focus in
        self?.openLibrary(focus: focus)
      }
    )
    controller.install()
    menuBar = controller
    GlobalHotkeyManager.shared.install { [weak self] action in
      switch action {
      case .mark:
        self?.requestMark()
      case .chat:
        if let nowOpen = self?.requestToggleChat() {
          self?.presentActionFeedback(nowOpen ? "闲聊中" : "闲聊结束")
        }
      case .pauseMicrophone:
        if let nowPaused = self?.requestToggleMicrophonePause() {
          self?.presentActionFeedback(nowPaused ? "麦克风已暂停" : "麦克风已恢复")
        }
      }
    }
  }
}

/// 关闭最后一个窗口不终止应用——菜单栏常驻,后台录音继续(T11)。
/// 必须通过 SwiftUI 的 `@NSApplicationDelegateAdaptor` 安装:直接赋值 `NSApp.delegate`
/// 会在 AppKit 初始化早期触发 abort(2026-07-29 崩溃日志实证:
/// NSApplication.init → _NSInitializeAppContext → _RegisterApplication → abort)。
/// 另一个坑(2026-08-16 实证):这个 adaptor delegate 的 `applicationDidFinishLaunching`
/// **不会被调用**(哨兵曾接在这里,三次真机运行零启动痕迹)——写在这里的启动逻辑
/// 是无声的死代码。启动期副作用一律走 `JustSaidApp` 的静态引导。
public final class JustSaidAppDelegate: NSObject, NSApplicationDelegate {
  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
