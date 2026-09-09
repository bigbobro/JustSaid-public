import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

/// 会议库:左侧历史会议列表,右侧单场会议详情(一页纸 / 纪要 / 完整转写 / 会中记录)。
///
/// 2026-07-29 实测反馈:结束会议后没有任何产品入口能看到产物,菜单栏那两项只是打开
/// Finder 目录和一个 .md 文件——那是文件系统,不是产品。会中记录页内两段承接
/// 总结留痕与补充记录,不把四种产物压成一份大文档。
public struct MeetingLibraryView: View {
  @StateObject var model: MeetingLibraryModel
  @Binding private var retainedSelectedMeetingID: String?
  @Binding private var retainedSelectedTab: MeetingDetailTab
  @Binding var retainedListScrollPosition: String?
  @Binding var retainedTabScrollOffsets: [MeetingDetailTab: Double]
  @Binding private var retainedGlobalSearchQuery: String
  @Binding private var retainedGroupByClient: Bool
  private let activeMeetingTitle: String?
  /// 生产由主工作台注入既有 `startMeeting`;nil 只服务不启动录制的隔离布局探针。
  let onStartRecording: (() -> Void)?
  /// 顶栏「会议库 · N 场」的 N;列表 reload 后回写,避免顶栏自己扫盘。
  let onMeetingsCountChange: ((Int) -> Void)?
  /// 顶栏 ⋯ popover 的导入/重扫入口;列表头不再放这两颗按钮。
  let onChromeActionsReady: ((@escaping () -> Void, @escaping () -> Void) -> Void)?
  @Environment(\.textScale) var textScale
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @FocusState var focusedMeetingTitleID: String?
  @FocusState var isTranscriptSearchFocused: Bool
  @FocusState var isLibrarySearchFocused: Bool
  @FocusState var focusedPane: LibraryKeyboardPane?
  @State var isTranscriptSearchPresented = false
  @State var transcriptSearchQuery = ""
  @State var isShowingChapterDirectory = false
  @State var returnTrailTask: Task<Void, Never>?
  /// 全库搜索:点开「还有 N 条」的会议组(呈现态,换 query 即收)。
  @State var expandedSearchGroups: Set<String> = []
  /// 全库搜索结果的说话人 chip 过滤(R4,纯呈现;换 query 即清)。
  @State var librarySearchSpeakerFilter: String?
  /// 鼠标点选与删除邻近选中保留列表位置;键盘 / 回程仍同步滚动。
  @State var suppressNextSelectionScroll = false
  @Binding var retainedQueueFilter: LibraryQueueFilter

  public init(
    meetingStore: MeetingStore = MeetingStore(),
    focus: URL? = nil,
    recordingSession: RecordingSession? = nil,
    postMeetingPipelineResolver: (() throws -> PostMeetingPipeline)? = nil,
    exportDestinationHistory: MeetingPackageDestinationHistory = .init(),
    diagnosticsDestinationHistory: MeetingDiagnosticsDestinationHistory = .init(),
    postMeetingTasks: PostMeetingTaskCoordinator? = nil,
    dictionaryStore: DictionaryStore = DictionaryStore(),
    selectedMeetingID: Binding<String?> = .constant(nil),
    selectedTab: Binding<MeetingDetailTab> = .constant(.onePage),
    listScrollPosition: Binding<String?> = .constant(nil),
    tabScrollOffsets: Binding<[MeetingDetailTab: Double]> = .constant([:]),
    globalSearchQuery: Binding<String> = .constant(""),
    groupByClient: Binding<Bool> = .constant(false),
    queueFilter: Binding<LibraryQueueFilter> = .constant(.all),
    onStartRecording: (() -> Void)? = nil,
    onMeetingsCountChange: ((Int) -> Void)? = nil,
    onChromeActionsReady: ((@escaping () -> Void, @escaping () -> Void) -> Void)? = nil
  ) {
    activeMeetingTitle = recordingSession?.currentTitle
    self.onStartRecording = onStartRecording
    self.onMeetingsCountChange = onMeetingsCountChange
    self.onChromeActionsReady = onChromeActionsReady
    _retainedSelectedMeetingID = selectedMeetingID
    _retainedSelectedTab = selectedTab
    _retainedListScrollPosition = listScrollPosition
    _retainedTabScrollOffsets = tabScrollOffsets
    _retainedGlobalSearchQuery = globalSearchQuery
    _retainedGroupByClient = groupByClient
    _retainedQueueFilter = queueFilter
    _model = StateObject(
      wrappedValue: MeetingLibraryModel(
        meetingStore: meetingStore,
        focus: focus,
        restoredSelectedID: selectedMeetingID.wrappedValue,
        restoredTab: selectedTab.wrappedValue,
        restoredSearchQuery: globalSearchQuery.wrappedValue,
        restoredGroupByClient: groupByClient.wrappedValue,
        restoredQueueFilter: queueFilter.wrappedValue,
        recordingSession: recordingSession,
        postMeetingPipelineResolver: postMeetingPipelineResolver,
        destinationHistory: exportDestinationHistory,
        diagnosticsDestinationHistory: diagnosticsDestinationHistory,
        postMeetingTasks: postMeetingTasks,
        dictionaryStore: dictionaryStore
      )
    )
  }

  public var body: some View {
    HSplitView {
      meetingList
        .frame(
          minWidth: Tokens.Layout.libraryListMinWidth,
          idealWidth: Tokens.Layout.libraryListIdealWidth,
          maxWidth: Tokens.Layout.libraryListMaxWidth
        )
      detail
        .frame(minWidth: Tokens.Layout.libraryDetailMinWidth)
    }
    .background(Tokens.Color.bg)
    .onAppear { model.reload() }
    .onAppear {
      onMeetingsCountChange?(model.meetings.count)
      onChromeActionsReady?({ pickImportFile() }, { model.reload() })
    }
    .onChange(of: model.meetings.count) { _, count in
      onMeetingsCountChange?(count)
    }
    .onAppear {
      if focusedPane == nil {
        focusedPane = .list
      }
    }
    .onDisappear {
      returnTrailTask?.cancel()
      model.cancelViewScopedWork()
    }
    .onChange(of: model.selectedID) { _, selectedID in
      retainedSelectedMeetingID = selectedID
      // 消费点击/成功删除的单次抑制;其余选中仍把目标带进视口。
      if suppressNextSelectionScroll {
        suppressNextSelectionScroll = false
      } else {
        retainedListScrollPosition = selectedID
      }
      // 换场后正文长度全变,上一场的四页签滚动不得带到下一场。
      retainedTabScrollOffsets = [:]
      closeTranscriptSearch()
      isShowingChapterDirectory = false
    }
    .onChange(of: model.returnTrail) { _, trail in
      scheduleReturnTrailDismissal(trail)
    }
    .onChange(of: model.librarySearchQuery) { _, query in
      // 回写 AppCoordinator(G3):⌘L 往返后新 model 用它恢复并重扫。
      retainedGlobalSearchQuery = query
      // 展开态与说话人 chip 是对某一次结果集的呈现选择,换词即清。
      expandedSearchGroups = []
      librarySearchSpeakerFilter = nil
    }
    .onChange(of: model.groupsByClient) { _, groups in
      // 回写 AppCoordinator(G3):分组开关随 remount 存活。
      retainedGroupByClient = groups
    }
    .onChange(of: model.queueFilter) { _, filter in
      // 回写 AppCoordinator(G3):指挥台滤镜随 remount 存活。
      retainedQueueFilter = filter
    }
    .onChange(of: model.tab) { _, tab in
      retainedSelectedTab = tab
      if tab != .transcript {
        closeTranscriptSearch()
      }
      isShowingChapterDirectory = false
    }
    .onChange(of: model.visibleOrderedMeetings.map(\.id)) { oldIDs, meetingIDs in
      guard
        let retainedListScrollPosition,
        !meetingIDs.contains(retainedListScrollPosition)
      else {
        return
      }
      self.retainedListScrollPosition = libraryScrollAnchor(
        retainedListScrollPosition, oldIDs: oldIDs, newIDs: meetingIDs)
    }
    .onChange(of: activeMeetingTitle) { _, title in
      model.syncActiveMeetingTitle(title)
    }
    .sheet(item: $model.pendingImportSheet) { sheet in
      ImportRecordingForm(
        suggestedTitle: sheet.suggestedTitle,
        probe: sheet.probe,
        onCancel: { model.pendingImportSheet = nil },
        onConfirm: { title, startedAt, language in
          model.confirmImport(
            title: title,
            startedAt: startedAt,
            language: language,
            acceptVolumeRisk: false
          )
        }
      )
    }
    .confirmationDialog(
      "这份录音较大且本机压不了",
      isPresented: Binding(
        get: { model.importVolumeRiskMessage != nil },
        set: { if !$0 { model.cancelVolumeRisk() } }
      ),
      titleVisibility: .visible
    ) {
      Button("仍然导入(失败也计费)", role: .destructive) {
        model.acceptVolumeRiskAndImport()
      }
      Button("取消", role: .cancel) {
        model.cancelVolumeRisk()
      }
    } message: {
      Text(model.importVolumeRiskMessage ?? "")
    }
  }

  /// F5:确认弹窗里选定份数后开跑。取 pending 与清 pending 只在这一处,
  /// 避免两个按钮各写一遍、漏清 pending 导致弹窗关不掉。
  func startMinutesGeneration(scope: MinutesGenerationScope) {
    guard let target = model.pendingMinutesGeneration else { return }
    model.pendingMinutesGeneration = nil
    model.generateMinutes(for: target, scope: scope)
  }

  /// 「生成纪要」弹窗提示的未决预填条数(08-20 naming-first R4 拍板②):
  /// 与建议横幅同一份规则口径——`namingSuggestionRows` 的 `.prefill` 行数,不另起数据源。
  var minutesDialogPendingNamingCount: Int {
    guard let target = model.pendingMinutesGeneration else { return 0 }
    return model.namingSuggestionRows(for: target).pendingPrefillCount
  }

  /// 弹窗〔去认名〕:收掉弹窗并复用页签切换通道跳到「完整转写」
  /// (与 tabBar 按钮同一条 `model.tab` 通道;命名行与建议横幅就在该页签顶部)。
  func goNamingFromMinutesDialog() {
    model.pendingMinutesGeneration = nil
    model.tab = .transcript
  }

  func pickImportFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowsOtherFileTypes = true
    panel.allowedContentTypes = [.audio, .movie]
    panel.message = "选择要导入的录音(将作为一场新会议补做精转)"
    panel.prompt = "导入"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.beginImport(sourceFileURL: url)
  }

  // 列表/全库搜索/详情/转写页签各区块见同名 +扩展文件(批3 拆分)。
}

enum LibraryKeyboardPane: Hashable {
  case list
  case detail
}

func libraryScrollAnchor(_ anchor: String, oldIDs: [String], newIDs: [String]) -> String? {
  let surviving = Set(newIDs)
  if surviving.contains(anchor) { return anchor }
  guard let index = oldIDs.firstIndex(of: anchor) else { return newIDs.first }
  return oldIDs.dropFirst(index + 1).first(where: surviving.contains)
    ?? oldIDs.prefix(index).reversed().first(where: surviving.contains)
    ?? newIDs.first
}
