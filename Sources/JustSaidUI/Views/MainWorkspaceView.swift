import AppKit
import JustSaidCore
import SwiftUI

/// 会中工作台：三区布局（转写 / 常驻会中总结 / 笔记）+ 顶部工具栏 + 缩略置顶窗。
/// 对 `Feed: SummaryFeed` 泛型——`JustSaidApp` 在唯一的构造点决定用
/// `PreviewSummaryFeed`（当前）还是未来步骤 4 的真实引擎，界面代码无需改动。
public struct MainWorkspaceView<Feed: SummaryFeed>: View {
  let registry: ProviderRegistry
  @ObservedObject var providerSettings: ProviderSettingsStore
  @ObservedObject var recordingSession: RecordingSession
  @ObservedObject var summaryFeed: Feed
  @ObservedObject var appCoordinator: AppCoordinator
  @ObservedObject var modelAssetManager: LocalModelAssetManager

  @StateObject private var compactPanel = CompactPanelController()
  @StateObject private var notesController = NotesController()

  /// 保留既有 Bool 兼容字段；App 冷启动仍复位为 false，固定模式只存在本窗口实例。
  @AppStorage("justsaid.transcriptExpanded") var isTranscriptExpanded = false
  /// 转写区呈现用的片段：`liveSegments` 是原始双录记录（原样落盘，保证证据完整），
  /// 界面上则去掉麦克风把扬声器录进去产生的回声副本，否则每句话都会出现两遍。
  @State var displaySegments: [TranscriptSegment] = []
  @State private var displayEchoFilter = EchoDeduplicator.IncrementalFilter()
  // 新装默认 Auto(R4):会中引擎走自动路由,语言选择下发识别语种意图。
  // 已有用户 key 里已存 "en"/"zh",不受默认值变化影响。
  @AppStorage("justsaid.meeting.language") private var languageRaw: String = MeetingLanguage.auto
    .rawValue
  @State var isShowingSettings = false
  @State var isConfirmingDiscard = false
  @State var isShowingChapterDirectory = false
  @State var isShowingLibraryOverflow = false
  @State var meetingTitleDraft = ""
  @State var meetingTitle = "会议"
  @State var scrollRequest: UUID?
  @State private var transcriptPresentation: LiveTranscriptPresentationState

  @FocusState var isMeetingTitleFocused: Bool
  @AppStorage(TextScale.defaultsKey) private var textScaleRawValue = TextScale.standard.rawValue
  /// 本会话内用户是否手动选过语言:手选优先于「跟上一场走」的自动预填。
  @State var hasManuallyPickedLanguage = false
  /// 语言错配提示(P2-b):速记检测语言与所选不符时置为检测语言,首中即定格,
  /// 不随后续片段反复横跳;换场清零。
  @State var languageMismatch: MeetingLanguage?
  @State var isShowingLowRecognition = false
  @State var isLowRecognitionDismissed = false
  /// 「本场忽略」或已切换后,本场不再提示;换场清零。
  @State var isLanguageMismatchDismissed = false

  /// 「闲聊中」排除状态(08-14 单):本场 meeting.json 里的**原始**排除区间。
  /// 每次写入后与换场时重读;判定不用 `ExclusionPolicy`(它归并区间),
  /// 因为「封口找最近未封口」「撤销按 id」都要归并前的记录。
  @State var exclusionRanges: [ExcludedRange] = []
  /// 排除写入失败的内联提示;走与降级细带同一视觉语言,不打断录音。
  @State var exclusionError: String?
  /// 散会兜底(契约硬要求):有未封口区间时,「结束会议」先弹明示选择。
  @State var isConfirmingChatClose = false

  /// 麦克风暂停起点的呈现层记账(08-14 mic-only-pause):session 没有发布
  /// pausedAt,UI 在 isMicrophonePaused 上升沿自记、恢复/换场清零。
  /// 权威暂停区间在 meeting.json 的 microphonePauseIntervals(采集层落盘),
  /// 这里只服务状态条的时长显示与超时轻提醒。
  @State var microphonePausedAt: Date?

  /// 顶栏「会议库 · N 场」;由 MeetingLibraryView reload 回写。
  @State var libraryMeetingCount = 0
  @State var libraryImportAction: (() -> Void)?
  @State var libraryReloadAction: (() -> Void)?
  @State var preparationSessionActive = false
  @State var preparationDismissed = false
  @State var preparationCapabilityID: String?

  public init(
    registry: ProviderRegistry,
    providerSettings: ProviderSettingsStore,
    recordingSession: RecordingSession,
    summaryFeed: Feed,
    appCoordinator: AppCoordinator,
    modelAssetManager: LocalModelAssetManager
  ) {
    self.registry = registry
    self.providerSettings = providerSettings
    self.recordingSession = recordingSession
    self.summaryFeed = summaryFeed
    self.appCoordinator = appCoordinator
    self.modelAssetManager = modelAssetManager
    _transcriptPresentation = State(
      initialValue: LiveTranscriptPresentationState(
        isExpanded: UserDefaults.standard.bool(forKey: "justsaid.transcriptExpanded")
      )
    )
  }

  var textScale: TextScale { TextScale.persisted(textScaleRawValue) }

  var textScaleSelection: Binding<TextScale> {
    Binding(
      get: { textScale },
      set: {
        HangSentinel.shared.note("textScale:\($0.rawValue)")
        textScaleRawValue = $0.rawValue
      }
    )
  }

  /// 录制链路活跃(recording/stopping):与工具栏录制态分支同一判定。
  private var isRecordingActive: Bool {
    recordingSession.phase == .recording || recordingSession.phase == .stopping
  }

  /// G4(08-15):驾驶舱空态的相位分组,与工具栏主按钮同一口径——
  /// starting/recording/stopping = 会话活跃(空态保留「正在听…」);
  /// idle/completed/failed = 非录制(空态换「未在录制」+「开始记录」)。
  private var isSessionLive: Bool {
    switch recordingSession.phase {
    case .starting, .recording, .stopping:
      return true
    case .idle, .completed, .failed:
      return false
    }
  }

  /// R1:录制中身处会议库——切换钮升级为「返回驾驶舱」强调入口。
  var isReturnToCockpit: Bool {
    appCoordinator.workspaceMode == .library && isRecordingActive
  }

  /// R2' 短标签(08-09 第二轮):语言 UI 统一只显示「Auto/中/英」。
  func shortLabel(for language: MeetingLanguage) -> String {
    switch language {
    case .auto: return "Auto"
    case .chinese: return "中"
    case .english: return "英"
    }
  }

  var language: MeetingLanguage {
    get { MeetingLanguage(rawValue: languageRaw) ?? .auto }
    nonmutating set { languageRaw = newValue.rawValue }
  }

  var languageSelection: Binding<MeetingLanguage> {
    Binding(
      get: { MeetingLanguage(rawValue: languageRaw) ?? .auto },
      set: {
        hasManuallyPickedLanguage = true
        languageRaw = $0.rawValue
      }
    )
  }

  var currentLiveProviderID: String {
    providerSettings.bindings(for: language)
      .first(where: { $0.role == .liveTranscriber })?
      .providerID ?? LocalModelKnownIDs.qwenProvider
  }

  var visiblePreparationCapabilityID: String? {
    if let preparationCapabilityID { return preparationCapabilityID }
    return modelAssetManager.capability(forProviderID: currentLiveProviderID)
  }

  /// 准备页可见性判定。抽成纯函数是为了能被探针逐格断言:
  /// 「用户进库后不再被顶回准备页」这条只靠渲染探针点不到,过去就是在这里丢掉的。
  var isPreparationVisible: Bool {
    ModelPreparationVisibility.shouldShow(
      gate: modelAssetManager.startGate(forProviderID: currentLiveProviderID),
      isRecordingOrStarting: recordingSession.phase == .recording
        || recordingSession.phase == .starting,
      sessionActive: preparationSessionActive,
      dismissed: preparationDismissed
    )
  }

  public var body: some View {
    applyWorkspaceSheets(workspaceRoot)
  }

  var workspaceRoot: some View {
    // 驾驶舱 chrome ≠ 会议库 chrome(2026-08-19 R7):驾驶舱是「深色控制轨 + 瘦顶栏」,
    // 会议库仍用它原来的那条顶栏(含录制中「← 返回驾驶舱」cue 橙入口)。
    // 深色轨只属于驾驶舱,不铺进库;⌘L 只换内容与 chrome,不碰 `RecordingSession`。
    Group {
      if isPreparationVisible, let capabilityID = visiblePreparationCapabilityID {
        ModelPreparationView(
          manager: modelAssetManager,
          capabilityID: capabilityID,
          onDownload: {
            HangSentinel.shared.note("models:preparation:download")
            Task { await modelAssetManager.prepare(capabilityID: capabilityID) }
          },
          onCancel: {
            modelAssetManager.cancelActivePreparation()
          },
          onRetry: {
            HangSentinel.shared.note("models:preparation:retry")
            Task { await modelAssetManager.prepare(capabilityID: capabilityID) }
          },
          onOpenLibrary: {
            preparationSessionActive = false
            preparationDismissed = true
            appCoordinator.openLibrary()
          },
          onOpenSettings: {
            isShowingSettings = true
          },
          onStartMeeting: {
            startMeeting()
          }
        )
      } else {
        switch appCoordinator.workspaceMode {
        case .cockpit:
          cockpit
        case .library:
          library
        }
      }
    }
    .environment(\.textScale, textScale)
    .background(
      WindowAccessor { window in
        compactPanel.observe(mainWindow: window)
        appCoordinator.registerMainWindow(window)
        // 单一最小宽(2026-08-19 契约):转写抽屉走 overlay 不参与 flex,
        // 展开不再抬最小宽——旧的 920/1220 两档跳变随左栏转写一起撤销。
        appCoordinator.enforceMainWindowMinSize(width: Tokens.Layout.cockpitMinWidth)
      }
    )
    .onChange(of: transcriptPresentation.isExpanded) { _, expanded in
      isTranscriptExpanded = expanded
    }
    .onChange(of: recordingSession.currentMeetingDirectory) { _, directory in
      transcriptPresentation.resetForMeeting()
      scrollRequest = nil
      languageMismatch = nil
      isLanguageMismatchDismissed = false
      isShowingLowRecognition = false
      isLowRecognitionDismissed = false
      // 换场清零暂停记账(Core 起/停会时已把 isMicrophonePaused 归位,
      // 这里清的是呈现层的时长起点)。
      microphonePausedAt = nil
      displayEchoFilter.reset()
      displaySegments =
        displayEchoFilter.removeEcho(
          from: recordingSession.liveSegments
        ).segments
      notesController.attachWriter(directory: directory)
      summaryFeed.attach(meetingDirectory: directory)
      compactPanel.updateCurrentMeeting(directory: directory)
      reloadExclusionState()
    }
    // 录音起点由 Core 发布，界面只跟随：这样无论从主窗还是菜单栏开录，
    // 笔记时间戳与「标记」窗口都对得上（实测 bug：菜单栏开录时全部落在 00:00）。
    .onChange(of: recordingSession.startedAt) { _, startedAt in
      guard let startedAt else { return }
      notesController.bindRecordingStart(startedAt)
    }
    .onChange(of: recordingSession.currentTitle) { _, title in
      if let title, !isMeetingTitleFocused {
        meetingTitle = title
      }
    }
    .onChange(of: recordingSession.liveSegments) { _, segments in
      displaySegments = displayEchoFilter.removeEcho(from: segments).segments
      summaryFeed.ingest(segments)
      if recordingSession.phase == .recording,
        !isLanguageMismatchDismissed,
        languageMismatch == nil,
        // R4:Auto 下没有选择可错配,错配横幅只对中/英手动选择生效;
        // 低产出检测不看语言,Auto 下照常保留。
        language != .auto,
        let detected = LanguageMismatchBanner.detectMismatch(
          selected: language,
          segments: segments
        )
      {
        languageMismatch = detected
      }
      if recordingSession.phase == .recording,
        !isLowRecognitionDismissed,
        !isShowingLowRecognition,
        languageMismatch == nil,
        LanguageMismatchBanner.detectLowOutput(segments: segments)
      {
        isShowingLowRecognition = true
      }
    }
    .onChange(of: recordingSession.phase) { _, phase in
      compactPanel.updateRecordingActive(phase == .recording)
      if phase == .recording {
        appCoordinator.showCockpit()
        displayEchoFilter.reset()
        displaySegments =
          displayEchoFilter.removeEcho(
            from: recordingSession.liveSegments
          ).segments
        summaryFeed.start()
        summaryFeed.ingest(recordingSession.liveSegments)
      }
    }
    .onChange(of: recordingSession.isMicrophonePaused) { _, paused in
      // 呈现层记账:上升沿记暂停起点、恢复清零;权威区间在 meeting.json,
      // 这里不读不写。同步给缩略置顶窗(它与主窗共用同一份暂停态)。
      microphonePausedAt = paused ? Date() : nil
      compactPanel.overlayModel.isMicrophonePaused = paused
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .justSaidPostMeetingRecovered)
    ) { notification in
      guard
        let directory = notification.userInfo?["directory"] as? URL,
        let notice = notification.userInfo?["notice"] as? String,
        let feed = summaryFeed as? LiveSummaryFeed
      else { return }
      feed.reconcilePostMeetingRecovery(directory: directory, notice: notice)
    }
    .onChange(of: summaryFeed.now) { _, newState in
      compactPanel.overlayModel.update(from: newState)
    }
    .onAppear {
      appCoordinator.registerRecordingSession(recordingSession)
      // 菜单栏「结束会议」与主窗按钮走同一确认流(08-14 捎带):
      // 主窗在,就把自己的 requestEndMeeting(含闲聊未封口兜底)注册给菜单栏路径。
      appCoordinator.registerRequestStartMeetingHandler { startMeeting() }
      appCoordinator.registerRequestEndMeetingHandler { requestEndMeeting() }
      // 菜单栏「标记重点」(G9/F-C7)同模式:主窗在,就把右栏同一入口
      // beginMark 注册出去;主窗关闭期间的菜单点击由 AppCoordinator 挂起,
      // 此处注册后异步补发(补发在 onAppear 整段跑完之后,状态已装载)。
      appCoordinator.registerRequestMarkHandler { notesController.beginMark() }
      appCoordinator.registerRequestToggleChatHandler { toggleChatExclusion() }
      let overlayPanel = compactPanel
      appCoordinator.registerMarkFeedback(
        overlayVisible: { [weak overlayPanel] in overlayPanel?.isPanelVisible ?? false },
        flashOverlay: { [weak overlayPanel] in overlayPanel?.flashMarkConfirmation() },
        flashOverlayMessage: { [weak overlayPanel] text in
          overlayPanel?.flashActionConfirmation(text)
        }
      )
      if recordingSession.phase == .recording || recordingSession.phase == .stopping {
        appCoordinator.showCockpit()
      }
      // 默认语言跟上一场走(2026-07-30):用户连开两场英文会都停在中文没发现。
      // 只在空闲态、且本会话未手动改过时预填;手选永远优先。
      if recordingSession.phase == .idle || recordingSession.phase == .completed {
        if !hasManuallyPickedLanguage,
          let detected = MeetingStore().latestDetectedLanguage()
        {
          language = detected
        }
      }
      displaySegments =
        displayEchoFilter.removeEcho(
          from: recordingSession.liveSegments
        ).segments
      // 菜单栏开录 + 主窗后开的情况下，onChange 早已错过；出现时补一次绑定，
      // 否则这一场的笔记又会没有落盘目标、时间戳又会归零。
      if let startedAt = recordingSession.startedAt {
        notesController.bindRecordingStart(startedAt)
      }
      if let directory = recordingSession.currentMeetingDirectory {
        notesController.attachWriter(directory: directory)
        summaryFeed.attach(meetingDirectory: directory)
        compactPanel.updateCurrentMeeting(directory: directory)
        reloadExclusionState()
      }
      compactPanel.overlayModel.onMark = { notesController.beginMark() }
      // 悬浮窗的一键恢复直调 Core;暂停态可能由快捷键路径错过 onChange,
      // 出现时补一次同步(起点无从追溯就用当下时刻,只影响时长显示)。
      compactPanel.overlayModel.onResumeMicrophone = {
        recordingSession.resumeMicrophone()
      }
      compactPanel.overlayModel.isMicrophonePaused = recordingSession.isMicrophonePaused
      if recordingSession.isMicrophonePaused, microphonePausedAt == nil {
        microphonePausedAt = Date()
      }
      notesController.markDistillationHandler = { markID, start, end in
        try await summaryFeed.distillMark(id: markID, from: start, to: end)
      }
      // 本地模型检查只由 App 启动那一次负责:这里再发一次会让整包 1.2 GB 被并发重算两遍。
    }
    .onDisappear {
      // 主窗关闭后菜单栏「结束会议」「标记重点」退回 AppCoordinator 的
      // 挂起/直收路径(有无未封口闲聊分流,见 installMenuBarIfNeeded)。
      appCoordinator.registerRequestStartMeetingHandler(nil)
      appCoordinator.registerRequestEndMeetingHandler(nil)
      appCoordinator.registerRequestMarkHandler(nil)
      appCoordinator.registerRequestToggleChatHandler(nil)
      appCoordinator.registerMarkFeedback(overlayVisible: nil, flashOverlay: nil)
    }
    .onChange(of: appCoordinator.pendingSettingsRequest) { _, pending in
      // 菜单 ⌘,/「设置…」(批4):路由到主窗唯一的设置 sheet。
      guard pending else { return }
      isShowingSettings = true
      appCoordinator.pendingSettingsRequest = false
    }
    .onChange(of: appCoordinator.pendingChapterDirectoryRequest) { _, pending in
      // 菜单 ⌘K(批1):路由到当前 chrome 上那颗章节按钮的 popover。
      guard pending else { return }
      isShowingChapterDirectory = true
      appCoordinator.pendingChapterDirectoryRequest = false
    }
    .onAppear {
      // 无主窗按 ⌘,:菜单命令 openWindow 重开主窗,新视图挂载后在这里消费挂起请求
      //(onChange initial 不触发,漏了这步就是「窗开了、设置不弹」)。
      // 真机实测:首帧内直接置 isShowingSettings 会被 SwiftUI 静默丢弃(窗口尚未就绪),
      // 推迟一拍再弹。
      if appCoordinator.pendingSettingsRequest {
        appCoordinator.pendingSettingsRequest = false
        DispatchQueue.main.async {
          isShowingSettings = true
        }
      }
      if appCoordinator.pendingChapterDirectoryRequest {
        appCoordinator.pendingChapterDirectoryRequest = false
        DispatchQueue.main.async {
          isShowingChapterDirectory = true
        }
      }
    }

  }

  /// 主工作台永久挂在窗口根部，⌘L 只切换这里的内容。录音、总结、笔记和缩略窗的
  /// 生命周期监听都留在外层，因此浏览会议库不会暂停任何一条录制链路。
  ///
  /// 视觉顺序固定为(R1):控制轨 → 顶栏 → 此刻舞台 → 系统横幅 → 整理区与右栏 → 底栏转写。
  /// 从会议窗口回来第一眼必须是「当前正在聊」,然后才是整理区。
  private var cockpit: some View {
    HStack(spacing: 0) {
      // 轨要压过主列(原型 `.rail { z-index: 8 }`):闲聊/暂停的悬停卡画在轨的 overlay 里、
      // 从 56pt 外沿探进主列的地盘。HStack 里后画的兄弟默认盖住先画的,轨是第 0 个子节点,
      // 不在**这一层**抬 zIndex 的话卡片会被主列吃掉——轨内部再怎么排都救不回来。
      cockpitRail
        .zIndex(1)
      VStack(spacing: 0) {
        cockpitToolbar
        Divider()
        // 录音异常是唯一允许打断用户的情况(ui-spec §6),所以它——也只有它——
        // 允许压在舞台之上;其余系统横幅一律排到舞台之下,不挡「回来一眼」。
        recordingFailureBanner
        NowPaneView(
          state: summaryFeed.now,
          isSessionLive: isSessionLive,
          onJumpToTranscript: showTranscript
        )
        .frame(height: Tokens.Layout.nowStageHeight)
        .runtimeAccessibilityIdentifier("dashboard.current")
        .runtimeAccessibilityIdentifier("cockpit.now-stage")
        Divider()
        systemBanners
        SummaryPaneView(
          feed: summaryFeed,
          notesController: notesController,
          scrollRequest: $scrollRequest,
          onSaveSourceAsNote: { notesController.addSourceQuote($0) },
          onJumpToTranscript: showTranscript,
          onExcludeBulletAnchor: canWriteExclusions ? { excludeBulletAnchor($0) } : nil,
          onExcludeTopicRange: canWriteExclusions ? { excludeTopicRange($0) } : nil,
          // G4:空态两态切换;「开始记录」复用既有 startMeeting 入口,不新造开始路径。
          isSessionLive: isSessionLive,
          transcriptPresentation: $transcriptPresentation,
          transcriptSegments: displaySegments,
          transcriptExcludedRanges: exclusionRanges,
          onMarkChatFrom: canWriteExclusions ? { markChatExcluded(from: $0) } : nil,
          onRemoveExclusion: canWriteExclusions ? { removeExclusion(id: $0) } : nil
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // 布局契约:轨 56 + 整理区 ≥520 + 右栏 332 → 单一最小宽 920。
    // 转写抽屉是 overlay,展开不再把最小宽抬到 1220。
    .frame(minWidth: Tokens.Layout.cockpitMinWidth)
  }

  private var cockpitRail: some View {
    CockpitRailView(
      recordingSession: recordingSession,
      openChatRangeStart: openChatRange?.start,
      microphonePausedAt: microphonePausedAt,
      transcriptPresentation: $transcriptPresentation,
      isShowingChapterDirectory: $isShowingChapterDirectory,
      chapterTopics: summaryFeed.topics,
      chapterNowCoveredLabel: summaryFeed.now.coveredUntilLabel,
      onSelectChapter: {
        transcriptPresentation.close()
        scrollRequest = $0
      },
      onToggleChat: { toggleChatExclusion() },
      onCloseChat: { closeChatExclusion() },
      onToggleMicrophonePause: {
        if recordingSession.isMicrophonePaused {
          recordingSession.resumeMicrophone()
        } else {
          recordingSession.pauseMicrophone()
        }
      },
      onResumeMicrophone: { recordingSession.resumeMicrophone() },
      onOpenLibrary: { appCoordinator.toggleWorkspaceMode() },
      onOpenSettings: { isShowingSettings = true }
    )
  }

  /// 会议库 chrome:顶栏归位后 5/4 件;深色控制轨不铺进来。
  private var library: some View {
    VStack(spacing: 0) {
      libraryToolbar
      Divider()
      recordingFailureBanner
      systemBanners
      MeetingLibraryView(
        meetingStore: appCoordinator.meetingStore,
        focus: appCoordinator.libraryFocus,
        recordingSession: recordingSession,
        postMeetingPipelineResolver: appCoordinator.postMeetingPipelineResolver,
        postMeetingTasks: appCoordinator.postMeetingTasks,
        selectedMeetingID: $appCoordinator.librarySelectedMeetingID,
        selectedTab: $appCoordinator.librarySelectedTab,
        listScrollPosition: $appCoordinator.libraryListScrollPosition,
        tabScrollOffsets: Binding(
          get: { appCoordinator.libraryTabScrollOffsets },
          set: { appCoordinator.libraryTabScrollOffsets = $0 }
        ),
        globalSearchQuery: $appCoordinator.libraryGlobalSearchQuery,
        groupByClient: $appCoordinator.libraryGroupByClient,
        queueFilter: $appCoordinator.libraryQueueFilter,
        onStartRecording: { startMeeting() },
        onMeetingsCountChange: { libraryMeetingCount = $0 },
        onChromeActionsReady: { importRecording, reload in
          libraryImportAction = importRecording
          libraryReloadAction = reload
        }
      )
      .id(appCoordinator.libraryRefreshGeneration)
    }
  }

  /// 排除入口只在「有一场可写的会议」时挂载:没有目录就没有 meeting.json 可写,
  /// 菜单挂上去也是点了没反应的死入口。
  var canWriteExclusions: Bool {
    currentMeetingPaths() != nil
  }

  // MARK: - Actions

  func startMeeting() {
    HangSentinel.shared.note("meeting-start:requested")
    let trimmedTitle = meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    meetingTitle = trimmedTitle.isEmpty ? "会议" : trimmedTitle
    let bindings = providerSettings.bindings(for: language)
    let providerID =
      bindings.first(where: { $0.role == .liveTranscriber })?.providerID
      ?? LocalModelKnownIDs.qwenProvider
    let title = meetingTitle
    let selectedLanguage = language
    let decision = modelAssetManager.startGate(forProviderID: providerID)
    if case .waitForLocalCheck = decision {
      Task {
        await modelAssetManager.refresh()
        continueStartMeeting(
          title: title,
          language: selectedLanguage,
          providers: bindings,
          providerID: providerID
        )
      }
      return
    }
    applyStartGate(
      decision,
      title: title,
      language: selectedLanguage,
      providers: bindings
    )
  }

  private func continueStartMeeting(
    title: String,
    language: MeetingLanguage,
    providers: [RoleProviderBinding],
    providerID: String
  ) {
    applyStartGate(
      modelAssetManager.startGate(forProviderID: providerID),
      title: title,
      language: language,
      providers: providers
    )
  }

  private func applyStartGate(
    _ decision: LocalModelStartGateDecision,
    title: String,
    language: MeetingLanguage,
    providers: [RoleProviderBinding]
  ) {
    switch decision {
    case .ready, .systemManaged:
      HangSentinel.shared.note("meeting-start:allowed")
      preparationSessionActive = false
      Task {
        await recordingSession.start(title: title, language: language, providers: providers)
      }
    case .waitForLocalCheck:
      preparationDismissed = false
      preparationSessionActive = true
    case .showPreparation(let capabilityID):
      HangSentinel.shared.note("meeting-start:blocked-preparation")
      preparationCapabilityID = capabilityID
      preparationDismissed = false
      preparationSessionActive = true
    case .configurationFailed:
      HangSentinel.shared.note("meeting-start:blocked-config")
      preparationDismissed = false
      preparationSessionActive = true
    }
  }

  /// 所有溯源入口写入同一个具有独立身份的定位命令。
  private func showTranscript(at elapsed: TimeInterval) {
    transcriptPresentation.show(at: elapsed)
  }

  func commitCurrentMeetingTitle() {
    let trimmed = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let desired = trimmed.isEmpty ? "会议" : trimmed
    guard desired != recordingSession.currentTitle else { return }
    if recordingSession.renameCurrentMeeting(to: desired) {
      meetingTitle = desired
    } else {
      meetingTitle = recordingSession.currentTitle ?? desired
    }
  }

  /// 废弃并结束(T15)。顺序要紧:先让总结引擎放弃本场(停两级任务、不落速记纪要、
  /// 撤掉排队中的会后处理),再停采集并删目录——反过来会有在飞的慢通道把 summary-history
  /// 重新写回刚删掉的目录。
  func discardMeeting() {
    summaryFeed.abandon()
    Task {
      await recordingSession.discardCurrentMeeting()
      notesController.attachWriter(directory: nil)
    }
  }

  func endMeeting() {
    Task {
      await recordingSession.stop()
      let completedDirectory = recordingSession.currentMeetingDirectory
      summaryFeed.ingest(recordingSession.liveSegments)
      let canRunPostMeeting = recordingSession.phase == .completed
      summaryFeed.stop(runPostMeeting: false)
      guard canRunPostMeeting else {
        summaryFeed.discardPostMeetingProcessing(for: completedDirectory)
        return
      }
      await notesController.flushPendingWrites()
      summaryFeed.startPostMeetingProcessing(for: completedDirectory)
      appCoordinator.openLibrary(focus: completedDirectory)
    }
  }
}

/// 工具栏里的会议内容阅读缩放。它只改 `TextScale` 选择，不从环境读取字号，
/// 因此控件自身不会跟着会议正文一起放大。
public struct ContentScaleControl: View {
  @Binding private var selection: TextScale

  public init(selection: Binding<TextScale>) {
    _selection = selection
  }

  public var body: some View {
    HStack(spacing: 0) {
      Button("A−") {
        if let previous = selection.previous {
          selection = previous
        }
      }
      .disabled(selection.previous == nil)
      .accessibilityLabel("缩小会议内容，当前 \(selection.displayName)")
      .runtimeAccessibilityIdentifier("toolbar.content-scale.decrease")

      Divider()
        .frame(height: 16)

      Menu {
        ForEach(TextScale.allCases) { candidate in
          Button {
            selection = candidate
          } label: {
            if candidate == selection {
              Label(candidate.displayName, systemImage: "checkmark")
            } else {
              Text(candidate.displayName)
            }
          }
        }
      } label: {
        // 等宽数字(2026-08-20 用户实测):系统字体默认按比例排数字,「110%」比「100%」窄 3pt,
        // 控件宽度随档位变,顶栏里它右侧的按钮就被来回挤——调字号时看着整条工具栏在跳。
        // `minWidth: 34` 挡不住(自然宽度超过下限时照样变);裸 `.monospacedDigit()` 也挡不住
        // ——外层 HStack 那句 `.font(...)` 会把它设的字体环境整个覆盖掉(实测宽度一字未变)。
        // 只有把等宽数字写进**这颗 Text 自己的显式字体**才压得住。
        Text(selection.displayName)
          .font(.system(size: Tokens.FontSize.secondary, weight: .semibold).monospacedDigit())
          .frame(minWidth: 34)
      }
      .menuStyle(.button)
      .buttonStyle(IconHoverButtonStyle(base: Tokens.Color.ink2, hover: Tokens.Color.ink))
      .menuIndicator(.hidden)
      .accessibilityLabel("会议内容字号，当前 \(selection.displayName)，可直接选择")
      .runtimeAccessibilityIdentifier("toolbar.content-scale.value")

      Divider()
        .frame(height: 16)

      Button("A+") {
        if let next = selection.next {
          selection = next
        }
      }
      .disabled(selection.next == nil)
      .accessibilityLabel("放大会议内容，当前 \(selection.displayName)")
      .runtimeAccessibilityIdentifier("toolbar.content-scale.increase")
    }
    // 顶栏这组三件此前是唯一没有悬停反馈的 chrome:同一排的胶囊钮全是 toolbarPill。
    // 走 iconHover 并把 base 钉在原来的 ink2 上——静止态逐像素不变,只多一档扫过加深。
    .buttonStyle(IconHoverButtonStyle(base: Tokens.Color.ink2, hover: Tokens.Color.ink))
    .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
    .padding(.horizontal, Tokens.Spacing.xxs)
    .padding(.vertical, Tokens.Spacing.hairline)
    .background(Tokens.Color.pane, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(Tokens.Color.line, lineWidth: 1)
    )
    .runtimeAccessibilityIdentifier("toolbar.content-scale")
  }
}
