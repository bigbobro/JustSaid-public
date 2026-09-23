import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

struct HomeView<Notices: View>: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var tagDirectory: ClientProjectDirectory
  @ObservedObject var session: RecordingSession
  @ObservedObject var preferences: NameAlertPreferencesStore
  @StateObject var model: MeetingLibraryModel
  @Binding var title: String
  @Binding var client: String
  @Binding var project: String
  @Binding var language: MeetingLanguage
  @ObservedObject var modelManager: LocalModelAssetManager
  let preparationVisible: Bool
  let capabilityID: String?
  @State private var dropTargeted = false
  @State private var importHovering = false
  @FocusState private var searchFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  /// 进首页那一刻会是不是已经在录。只有「开着会、专门回来看一眼首页」才画录制态;
  /// 在首页上点开始记录的那一下,相位变成录制、驾驶舱马上接管,中间不该闪一下录制卡。
  /// 在 init 里取值而不是 onAppear:onAppear 在第一帧之后才跑,会先闪一帧闲时表单。
  @State private var arrivedDuringMeeting: Bool
  /// 正在废弃这一场:会已经不存在了,卡上不该再画它(废弃是先回首页、后台再删)。
  let discarding: Bool
  let notices: Notices
  let onStart: () -> Void

  init(
    coordinator: AppCoordinator, session: RecordingSession,
    title: Binding<String>, client: Binding<String>, project: Binding<String>,
    language: Binding<MeetingLanguage>,
    modelManager: LocalModelAssetManager, preparationVisible: Bool, capabilityID: String?,
    discarding: Bool = false,
    onStart: @escaping () -> Void,
    @ViewBuilder notices: () -> Notices
  ) {
    self.coordinator = coordinator
    tagDirectory = coordinator.todoPage.tagDirectory
    self.session = session
    preferences = coordinator.nameAlertPreferences
    _title = title
    _client = client
    _project = project
    _language = language
    self.notices = notices()
    self.onStart = onStart
    self.discarding = discarding
    _arrivedDuringMeeting = State(initialValue: session.phase == .recording)
    self.modelManager = modelManager
    self.preparationVisible = preparationVisible
    self.capabilityID = capabilityID
    // 首页的「最近的会」和会议库共用上一次扫盘的列表:先画出来,后台照常重扫。
    _model = StateObject(
      wrappedValue: {
        let model = MeetingLibraryModel(
          meetingStore: coordinator.meetingStore, focus: nil, recordingSession: session,
          postMeetingPipelineResolver: coordinator.postMeetingPipelineResolver,
          postMeetingTasks: coordinator.postMeetingTasks,
          initialMeetings: coordinator.libraryItemsCache)
        model.onSnapshotApplied = { [weak coordinator] items in
          coordinator?.libraryItemsCache = items
        }
        return model
      }())
  }

  var body: some View {
    VStack(spacing: 0) {
      // 顶栏只写「首页」和日期。搜索回到入口卡里:放在顶栏右端离所有东西都远,很割裂
      // (owner 2026-09-21)。首页这张卡回答的就是「你现在想干嘛」——开始、导入、搜索。
      WorkspaceTopBar("首页", detail: ChineseDateText.dayWithWeekday()) { EmptyView() }
        .runtimeAccessibilityIdentifier("home.top-bar")
        .onAppear { coordinator.todoPage.reloadSynchronously() }
      notices
      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
          // 录制态不再在入口卡下面另起一条同宽同圆角的「正在记录」栏——
          // 那条栏和入口卡是一对双胞胎,谁也压不住谁,而录制时入口卡本身整张是灰的
          // (开始记录禁用、会议名称禁用),于是这一页最重要的位置放着一块死牌
          // (owner 2026-09-21:「还是没有一种上面是最重要的这个入口」)。
          // 现在录制态由入口卡自己承担:一张卡,任何时候都只有一颗饱和主按钮。
          entryCard
          HomeMeetingsView(model: model, coordinator: coordinator)
        }
        // 内容区有上限、在宽窗里居中:没有上限时 1600 宽的窗里会议名称框撑到约 900,
        // 13 号字在里面显得很小(2026-09-21 定首页版式时量的)。
        .frame(maxWidth: Tokens.V1.Size.homeContentMax)
        .padding(.horizontal, Tokens.V1.Space.xl)
        .padding(.vertical, Tokens.V1.Space.lg)
        .frame(maxWidth: .infinity)
      }
    }
    .foregroundStyle(Tokens.V1.Color.ink)
    .background(Tokens.V1.Color.paper)
    .runtimeAccessibilityIdentifier("home")
    .onAppear { model.reload() }
    .onDisappear { model.cancelViewScopedWork() }
    .sheet(item: $model.pendingImportSheet) { sheet in
      ImportRecordingForm(
        suggestedTitle: sheet.suggestedTitle, probe: sheet.probe,
        onCancel: { model.pendingImportSheet = nil },
        onConfirm: { title, date, language in
          model.confirmImport(
            title: title, startedAt: date, language: language, acceptVolumeRisk: false)
        })
    }
    .confirmationDialog(
      "这份录音较大且本机压不了",
      isPresented: Binding(
        get: { model.importVolumeRiskMessage != nil },
        set: { if !$0 { model.cancelVolumeRisk() } }), titleVisibility: .visible
    ) {
      Button("仍然导入（失败也计费）", role: .destructive) { model.acceptVolumeRiskAndImport() }
      Button("取消", role: .cancel) { model.cancelVolumeRisk() }
    } message: {
      Text(model.importVolumeRiskMessage ?? "")
    }
  }

  // MARK: - 入口

  /// 首页入口,这一页的主角(owner 2026-09-21 第二版参考稿):两张卡并排、等高。
  /// 左卡「开始一场会议」:标题带副题、成行的开会表单、点名提醒一小块,底部一颗通栏的
  /// 墨青主按钮。右卡「查找会议」:搜索框,一条「或」,下面一小块「导入录音」。
  /// 录制时左卡换成正在录的这一场,主按钮换成「返回会议」——任何时候只有一颗饱和主按钮。
  /// 录音拖到两张卡的任意一处都能导入,落点高亮画在「导入录音」那一块上。
  var entryCard: some View {
    EntryCardsLayout(spacing: Tokens.V1.Space.lg) {
      startCard
      findCard
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard urls.count == 1, let url = urls.first, url.isFileURL else { return false }
      HangSentinel.shared.note("home:drop-import")
      model.beginImport(sourceFileURL: url)
      return true
    } isTargeted: {
      dropTargeted = $0
    }
    .runtimeAccessibilityIdentifier("home.entry")
  }

  /// 左卡:开一场会。表单在上,主按钮压在卡底、撑满卡宽。
  private var startCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 录制态中间那块「此刻」要吃掉多余的高度,优先级高过下面的 Spacer。
      if isRecording { recordingColumn.layoutPriority(1) } else { formColumn }
      // Spacer 单独算一格时 VStack 会在它两边各加一次间距,表单和按钮之间凭空多出 16。
      Spacer(minLength: Tokens.V1.Space.md)
      primaryAction
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(Tokens.V1.Space.lg)
    .background {
      entryBackground(
        artwork: HomeEntryArtwork.image, alignment: .topLeading, darkWash: Tokens.V1.Color.accent)
    }
    .modifier(EntryCardFrame())
  }

  /// 右卡:找以前的会,或者把一段录音导进来。搜索在上,「或」之下是放录音的虚线框,一直撑到卡底。
  private var findCard: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      HStack(spacing: Tokens.V1.Space.sm) {
        // 徽章本身是个按钮,带着 ⇧⌘F:它原来挂在顶栏的放大镜上,跟着搜索一起搬过来。
        Button {
          searchFocused = true
        } label: {
          entryBadge(
            systemImage: "magnifyingglass", size: Tokens.V1.Size.homeEntryBadge,
            iconSize: Tokens.V1.Size.railIcon, ink: Tokens.V1.Color.find)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .help("搜索全部会议的原话  ⇧⌘F")
        .accessibilityLabel("搜索全部会议的原话")
        entryTitles("查找会议", subtitle: "搜索已有会议，或导入录音进行转写")
      }
      searchField
      orDivider
      importDropZone
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(Tokens.V1.Space.lg)
    .background {
      entryBackground(artwork: HomeEntryArtwork.findImage, alignment: .center, darkWash: nil)
    }
    .modifier(EntryCardFrame())
  }

  /// 卡面:浅色下铺背景图(设计系统「主入口」档,全应用只有首页这两张卡用图),深色退回纯
  /// raised。左卡的图顶部左对齐裁切,只取上缘那片青绿亮区;右卡的浅蓝波纹居中裁切,上下两道
  /// 波纹都留在卡里。深色下左卡补一层墨青淡洗,否则两张卡和下面的列表卡长成同一块灰。
  private func entryBackground(artwork: NSImage?, alignment: Alignment, darkWash: Color?)
    -> some View
  {
    let shape = RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
    return ZStack {
      shape.fill(Tokens.V1.Color.raised)
      if colorScheme == .dark, let darkWash {
        LinearGradient(
          colors: [darkWash.opacity(Tokens.V1.Feedback.entryWash), .clear],
          startPoint: .topLeading, endPoint: .center)
      }
      if colorScheme == .light, let artwork {
        GeometryReader { geometry in
          Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: alignment)
            .clipped()
        }
        .accessibilityHidden(true)
      }
    }
    .clipShape(shape)
  }

  /// 闲时左卡:开会表单,标签在左。客户、项目挪到开会前填——开会前你恰恰知道
  /// 这场是谁的,原来只能进会议库事后补。
  private var formColumn: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      HStack(spacing: Tokens.V1.Space.sm) {
        entryBadge(
          systemImage: "video", size: Tokens.V1.Size.homeEntryBadge,
          iconSize: Tokens.V1.Size.railIcon, ink: Tokens.V1.Color.accent)
        entryTitles("开始一场会议", subtitle: "轻松设置，马上开始记录重要对话")
      }
      // 每行一个 HStack,只共用行首的标签列(定宽)。不用一张四列 Grid:Grid 会把第 2、4 列
      // 均分,于是设备名(长)和语言分段(短)拿到一样宽,在 1060 宽的窗里设备名被截成
      // 「MacBoo…」(2026-09-21 build 864 实机)。现在设备框吃掉这一行剩下的全部宽度,
      // 语言分段只占自己的宽;每行右缘仍然齐在同一条线上。
      // 控件 32 高、行距 8,是参考稿的比例:原来 36 高、行距 12,左卡比右卡内容高出约 56,
      // 右卡只能把那截高度空着(owner 2026-09-21「这个位置不还是空的吗」)。
      // 标签写进框里(owner 2026-09-21 第二份参考稿):左边不再单开一列 64 宽的标签,
      // 每个框自己说清是什么,输入框吃满整行。客户、项目两个框各占一半。
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        titleField
        HStack(spacing: Tokens.V1.Space.sm) {
          let directory = tagDirectory
          tagField(
            label: "客户", text: $client,
            suggestions: directory.clients, identifier: "home.client"
          ) { chosen in
            let pair = directory.selectingClient(chosen, project: project)
            client = pair.client
            project = pair.project
          }
          tagField(
            label: "项目", text: $project,
            suggestions: directory.projects(for: client), identifier: "home.project"
          ) { chosen in
            let pair = directory.selectingProject(chosen, client: client)
            client = pair.client
            project = pair.project
          }
        }
        HStack(spacing: Tokens.V1.Space.sm) {
          microphoneField
            .layoutPriority(1)
          // 行内标签只写「语言」:挨着「Auto / 中 / 英」不会有歧义,省下的两个字
          // 让给左边的设备名。控件自己的无障碍名仍是「说话语言」。
          formLabel("语言")
          // 摊成分段比下拉好:当前值与可选值一眼同时可见,改一次只要一次点击。
          // 用词全应用统一为 Auto / 中 / 英(owner 2026-09-21 定,和驾驶舱顶栏同一套)。
          // 选中那一格白底加一圈墨青边、墨青字,和旁边的输入框同高(参考稿)。
          V1SegmentedPicker(
            "说话语言", selection: $language,
            options: [.init(.auto, "Auto"), .init(.chinese, "中"), .init(.english, "英")],
            style: .accentOutline,
            segmentHeight: Tokens.V1.Size.homeField - Tokens.V1.Space.s2xs
          )
          .fixedSize()
          .disabled(session.phase.isBusy)
        }
        nameAlertBox
      }
    }
  }

  /// 录制中左卡(owner 2026-09-21:「在会议中的时候,首页展示的这个好像有点问题」):
  /// 头部和闲时同一个骨架(徽章 + H1 会名 + 一行副题),副题写「正在记录 · 几点开始 · 客户 · 项目」;
  /// 中间一块毛玻璃是「此刻」:麦克风电平与最近几句实时转写——证明它在录、录到了什么,
  /// 原来这里是一大片空白。下面是录音设备(录制中唯一还能改的一项),卡底「返回会议」。
  /// 计时仍只在轨上走:这里写的是开始时刻,不是跳动的秒数。
  private var recordingColumn: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      recordingHeadline
      liveNowBox
      microphoneField
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  /// 「此刻」:麦克风电平(和轨上录制块同一根电平条)加最近几句实时转写,只显示最新的那一截。
  private var liveNowBox: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      HStack(spacing: Tokens.V1.Space.xs) {
        MicLevelBar(level: session.microphoneLevel, isPaused: session.isMicrophonePaused)
        Text(session.isMicrophonePaused ? "麦克风已暂停" : "麦克风在收音")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(
            session.isMicrophonePaused ? Tokens.V1.Color.warn : Tokens.V1.Color.ink3)
      }
      Text(recentTranscript ?? "还没有转写到内容")
        .font(Tokens.V1.Text.body.font)
        .foregroundStyle(recentTranscript == nil ? Tokens.V1.Color.ink3 : Tokens.V1.Color.ink2)
        .lineLimit(4)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Tokens.V1.Space.sm)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .v1Glass(cornerRadius: Tokens.V1.Radius.lg)
    .accessibilityElement(children: .combine)
    .runtimeAccessibilityIdentifier("home.recording.live")
  }

  /// 最近几句实时转写连成一段;还没有就返回 nil。
  private var recentTranscript: String? {
    let text = session.liveSegments.suffix(4).map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// 左卡卡底的主按钮位:墨青实底、通栏、带图标(参考稿)。
  @ViewBuilder
  private var primaryAction: some View {
    if preparationVisible {
      HomeModelPreparationView(
        manager: modelManager, capabilityID: capabilityID, onStart: onStart)
    } else if isRecording {
      // 录制时主动作换成「返回会议」,而不是留一颗灰掉的「开始记录」。
      // 快捷键 ⌘L 由 app 菜单「会议 › 返回驾驶舱」持有,写进悬停提示,不画键帽。
      Button {
        coordinator.showCockpit()
      } label: {
        Label("返回会议", systemImage: "arrow.uturn.backward")
          .labelStyle(.titleAndIcon)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(V1ButtonStyle.v1Entry)
      .help("返回会议  ⌘L")
      .runtimeAccessibilityIdentifier("home.return-to-meeting")
    } else {
      // 这一页唯一的主动作。⌘R 由 app 菜单「会议 › 开始一场会议」持有,写进悬停提示。
      Button(action: onStart) {
        Label("开始记录", systemImage: "waveform")
          .labelStyle(.titleAndIcon)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(V1ButtonStyle.v1Entry)
      .help("开始记录  ⌘R")
      .disabled(session.phase.isBusy)
      .runtimeAccessibilityIdentifier("home.start-recording")
    }
  }

  /// 搜的是全部会议 transcript.md 里的原话——不搜会名、客户、项目,
  /// 所以占位字只说「原话」,不承诺它搜不到的东西。
  private var searchField: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(Tokens.V1.Color.ink3)
        .accessibilityHidden(true)
      TextField("搜索全部会议的原话", text: $model.librarySearchQuery)
        .textFieldStyle(.plain)
        .font(Tokens.V1.Text.body.font)
        .focused($searchFocused)
        .runtimeAccessibilityIdentifier("home.search")
    }
    .padding(.horizontal, Tokens.V1.Space.sm)
    // 和两颗大按钮同高:右卡的主角是这个搜索框,比左卡的表单框高一档(参考稿)。
    .frame(height: Tokens.V1.Size.homeEntryButton)
    .background(fieldFill, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
    .overlay(fieldStroke)
  }

  /// 搜索与导入之间的「或」:两件事是二选一的两个入口,不是上下两步。
  private var orDivider: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
      Text("或")
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .accessibilityHidden(true)
  }

  /// 导入录音:一整块虚线框,点一下选文件、把录音拖进来都行(owner 2026-09-21 第二份参考稿的
  /// 交互:上面搜已有的会,「或」之下是一块放录音的地方,两件事一眼分得开)。框本身就是按钮,
  /// 不再另放一颗「导入录音」——同一件事一个入口。它撑到卡底,两张卡等高时多出来的高度正好
  /// 是放录音的地方。拖着录音经过两张卡的任意一处都能导入,这时虚线换成焦点色。
  private var importDropZone: some View {
    Button(action: pickImportFile) {
      VStack(spacing: Tokens.V1.Space.xs) {
        entryBadge(
          systemImage: "square.and.arrow.up", size: Tokens.V1.Size.controlLg,
          iconSize: Tokens.V1.Size.railIcon * 0.8, ink: Tokens.V1.Color.find)
        // H3(type-heading 15):卡里的一小块,不能和「最近的会」(H2 17)一样大。
        Text("导入录音").font(Tokens.V1.Text.heading.font)
        VStack(spacing: Tokens.V1.Space.s3xs) {
          Text("点一下选文件，或把录音拖到这里")
            .foregroundStyle(Tokens.V1.Color.ink2)
          Text("支持 mp3、m4a、wav 等格式")
            .foregroundStyle(Tokens.V1.Color.ink3)
        }
        .font(Tokens.V1.Text.meta.font)
      }
      .multilineTextAlignment(.center)
      .foregroundStyle(Tokens.V1.Color.ink)
      .padding(Tokens.V1.Space.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg))
    }
    .buttonStyle(.plain)
    .background(
      Tokens.V1.Color.raised.opacity(Tokens.V1.Feedback.glassFill),
      in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
        .strokeBorder(
          dropTargeted
            ? Tokens.V1.Color.focus
            : (importHovering ? Tokens.V1.Color.accent : Tokens.V1.Color.controlRule),
          style: StrokeStyle(
            lineWidth: dropTargeted ? Tokens.V1.Size.focusWidth : Tokens.V1.Size.controlRuleWidth,
            dash: [Tokens.V1.Space.s2xs, Tokens.V1.Space.s2xs]))
    )
    .onHover { importHovering = $0 }
    .help("导入一段录音;也可以直接把录音文件拖到这两张卡上")
    .accessibilityLabel("导入录音")
    .runtimeAccessibilityIdentifier("home.import")
  }

  // MARK: - 入口卡的零件

  /// 卡标题(H1,type-hero 20)加一行副题。两张卡同一个级别:它们是这一页并列的两个入口。
  private func entryTitles(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
      Text(title).font(Tokens.V1.Text.hero.font)
      Text(subtitle)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .lineLimit(1)
    }
  }

  /// 标题前的方块徽章:毛玻璃底,透出卡面的背景图(参考稿)。左卡字形墨青,右卡字形蓝,
  /// 各随自己那张卡的色相。
  private func entryBadge(
    systemImage: String, size: CGFloat, iconSize: CGFloat, ink: Color
  ) -> some View {
    Image(systemName: systemImage)
      .font(.system(size: iconSize, weight: .medium))
      .foregroundStyle(ink)
      .frame(width: size, height: size)
      .v1Glass(cornerRadius: Tokens.V1.Radius.lg)
      .shadow(
        color: Tokens.Shadow.sh1.color, radius: Tokens.Shadow.sh1.radius,
        x: 0, y: Tokens.Shadow.sh1.y
      )
      .accessibilityHidden(true)
  }

  /// 贴着控件的行内标签(「语言」在分段左边)。
  private func formLabel(_ text: String) -> some View {
    Text(text)
      .font(Tokens.V1.Text.body.font)
      .foregroundStyle(Tokens.V1.Color.ink2)
      .lineLimit(1)
      .fixedSize()
  }

  /// 写在框里的标签:ink-2,比占位字(系统占位灰)深一档,两种灰分得开。
  private func inlineLabel(_ text: String) -> some View {
    Text(text)
      .font(Tokens.V1.Text.body.font)
      .foregroundStyle(Tokens.V1.Color.ink2)
      .lineLimit(1)
      .fixedSize()
  }

  /// 输入框的底:浅色下卡面是背景图,白底框浮在图上;深色下卡面是纯 raised,
  /// 框要内凹成 paper-2 才看得出边界。
  private var fieldFill: Color {
    colorScheme == .dark ? Tokens.V1.Color.paper2 : Tokens.V1.Color.raised
  }

  private var fieldStroke: some View {
    RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
      .strokeBorder(Tokens.V1.Color.controlRule, lineWidth: Tokens.V1.Size.controlRuleWidth)
  }

  /// 占位字说清不填会怎样,而不是重复左边的标签。
  private var titleField: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      inlineLabel("会议名称")
      TextField("不填就叫「会议」", text: $title)
        .textFieldStyle(.plain)
        .font(Tokens.V1.Text.body.font)
        .runtimeAccessibilityIdentifier("home.meeting-title")
    }
    .padding(.horizontal, Tokens.V1.Space.sm)
    .frame(height: Tokens.V1.Size.homeField)
    .background(fieldFill, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
    .overlay(fieldStroke)
    .disabled(session.phase.isBusy)
  }

  private func tagField(
    label: String, text: Binding<String>, suggestions: [String],
    identifier: String, onSelect: @escaping (String) -> Void
  ) -> some View {
    V1ComboBox(
      label: label, value: text.wrappedValue, suggestions: suggestions, identifier: identifier
    ) {
      onSelect($0)
      tagDirectory.remember(client: client, project: project)
    }
    .disabled(session.phase.isBusy)
  }

  /// 整个框都是热区(控制轨麦克风格的教训:只有图标能点,高亮区点了没反应)。
  /// 用 `.button` + `.plain`,不用 `.borderlessButton`——后者会把 label 摊平、撑破给定的框。
  private var microphoneField: some View {
    Menu {
      Button("自动跟随系统") { session.selectMicrophoneInput(.automatic) }
      ForEach(session.microphoneInputDevices) { device in
        Button(device.name) {
          session.selectMicrophoneInput(.device(uid: device.uid, name: device.name))
        }
      }
    } label: {
      // 框里不再画麦克风图标:左边的标签已经写了「录音设备」,图标占掉的二十来点
      // 正是设备名最缺的那一截(1060 宽窗口实测会被截成「MacBook…」)。
      HStack(spacing: Tokens.V1.Space.xs) {
        inlineLabel("录音设备")
        Text(microphoneName)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.down")
          .foregroundStyle(Tokens.V1.Color.ink3)
          .accessibilityHidden(true)
      }
      .font(Tokens.V1.Text.body.font)
      .foregroundStyle(Tokens.V1.Color.ink)
      .padding(.horizontal, Tokens.V1.Space.sm)
      .frame(maxWidth: .infinity)
      .frame(height: Tokens.V1.Size.homeField)
      .background(fieldFill, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
      .overlay(fieldStroke)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("录音设备，\(microphoneName)")
    .runtimeAccessibilityIdentifier("home.microphone")
  }

  /// 点名提醒自成一小块(参考稿):标签、开关、一句说明,开着时右端是提醒方式。
  /// 点名提醒是**这一场**的决定(这场开、下场可能不开),所以在入口卡。
  /// 提醒方式是「开了之后再选强度」:关着时它没有任何作用,所以开启后才出现。
  private var nameAlertBox: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Text("点名提醒")
        .font(Tokens.V1.Text.strong.font)
        .foregroundStyle(Tokens.V1.Color.ink)
        .fixedSize()
      Toggle(
        "点名提醒",
        isOn: Binding(
          get: { preferences.preferences.remindersEnabled },
          set: { preferences.setRemindersEnabled($0) })
      )
      .labelsHidden()
      .toggleStyle(.v1Switch)
      // 和设置页「录制时系统声音里叫到你的名字会提醒你」同一个说法,短到 1040 宽的窗里
      // 开着提醒方式时也放得下。
      Text("有人叫到你的名字时提醒你")
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(-1)
      Spacer(minLength: 0)
      if preferences.preferences.remindersEnabled {
        V1SegmentedPicker(
          "提醒方式",
          selection: Binding(
            get: { preferences.preferences.reminderStyle },
            set: { preferences.setReminderStyle($0) }),
          options: [.init(.quiet, "静默高亮"), .init(.strong, "独立强提醒")],
          // 选中的那一格墨青实底白字(owner 2026-09-21:「用墨绿色来做选中的高亮」)。
          style: .accentFill,
          segmentHeight: Tokens.V1.Size.homeField - Tokens.V1.Space.s2xs
        )
        .fixedSize()
        .transition(.opacity)
      }
    }
    .padding(.horizontal, Tokens.V1.Space.sm)
    // 开关关着时这一块里没有分段,高度不能跟着塌:定在控件高加上下各 6。
    .frame(minHeight: Tokens.V1.Size.homeField + Tokens.V1.Space.sm)
    .v1Glass(cornerRadius: Tokens.V1.Radius.lg)
    .animation(
      .easeOut(duration: Tokens.V1.Motion.fast), value: preferences.preferences.remindersEnabled)
  }

  private var microphoneName: String {
    switch session.microphoneInputStatus {
    case .idle(let target), .pending(let target): return target.device.name
    case .active(let binding, _): return binding.device.name
    case .unready: return "麦克风未就绪"
    }
  }

  /// 入口卡画「正在录的这一场」的条件。只认 `.recording`,不认 `.stopping`:结束或废弃的
  /// 收尾阶段这一场已经在退场,卡上接着画它就是那「一瞬间」的残影(owner 2026-09-21)。
  private var isRecording: Bool {
    arrivedDuringMeeting && session.phase == .recording && !discarding
  }

  /// 录制中左卡的头:和闲时同一个骨架。徽章里是一颗会呼吸的录制点(闲时是摄像机);
  /// 副题的位置写「正在记录 · 几点开始 · 客户 · 项目」,有才写。
  private var recordingHeadline: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      PulsingDot(color: Tokens.V1.Color.rec, size: Tokens.V1.Space.sm)
        .frame(width: Tokens.V1.Size.homeEntryBadge, height: Tokens.V1.Size.homeEntryBadge)
        .background(
          Tokens.V1.Color.recSoft, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        Text(session.currentTitle ?? "会议")
          .font(Tokens.V1.Text.hero.font)
          .lineLimit(1)
          .truncationMode(.tail)
        HStack(spacing: Tokens.V1.Space.xs) {
          Text("正在记录")
            .foregroundStyle(Tokens.V1.Color.rec)
          ForEach(recordingFacts, id: \.self) { fact in
            Text("·").foregroundStyle(Tokens.V1.Color.ink4)
            Text(fact).foregroundStyle(Tokens.V1.Color.ink3)
          }
        }
        .font(Tokens.V1.Text.meta.font)
        .lineLimit(1)
      }
    }
    .runtimeAccessibilityIdentifier("home.recording")
  }

  /// 副题里「正在记录」后面的几件事:几点开始(不是跳动的秒数)、客户、项目。
  private var recordingFacts: [String] {
    var facts: [String] = []
    if let startedAt = session.startedAt {
      facts.append("\(ChineseDateText.time(startedAt)) 开始")
    }
    if let subtitle = recordingSubtitle { facts.append(subtitle) }
    return facts
  }

  private var recordingSubtitle: String? {
    guard
      let item = model.meetings.first(where: {
        $0.paths.directory == session.currentMeetingDirectory
      })
    else { return nil }
    let parts = [item.client, item.project].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  func pickImportFile() {
    HangSentinel.shared.note("home:import")
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowsOtherFileTypes = true
    panel.allowedContentTypes = [.audio, .movie]
    panel.prompt = "导入"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.beginImport(sourceFileURL: url)
  }
}

/// 客户与项目的对应关系,全部从会议库里已有的会议推出来(owner 2026-09-21):
/// 两个都没选时各自列出全部;选了客户,项目只列这个客户下的;先选了项目,客户按它带出来。
/// 两张入口卡共用的边与投影。投影走 sh2(浮起元素),不走 sh3:sh3 的 18px 模糊铺在
/// 宽卡下面读成一圈光晕(owner 2026-09-21「太多发光了」)。深色底上黑影几乎看不出,
/// 两张卡的边界靠这条 1px rule。
private struct EntryCardFrame: ViewModifier {
  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
          .strokeBorder(Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
      )
      .shadow(
        color: Tokens.Shadow.sh2.color, radius: Tokens.Shadow.sh2.radius,
        x: 0, y: Tokens.Shadow.sh2.y)
  }
}

/// 两张入口卡的排法:右卡约占一行的 36%,夹在 `homeFindMin`…`homeFindMax` 之间,左卡吃掉剩下的;
/// 两张等高,按较高的那张定。窄窗口里右卡先让,左卡的设备名才装得下(build 878 实机)。
/// 用 Layout 而不是 HStack + fixedSize:比例分宽和等高要在同一次测量里定下来。
private struct EntryCardsLayout: Layout {
  static let findShare: CGFloat = 0.36
  var spacing: CGFloat

  private func widths(for total: CGFloat) -> (start: CGFloat, find: CGFloat) {
    let available = max(0, total - spacing)
    let find = min(
      max(available * Self.findShare, Tokens.V1.Size.homeFindMin), Tokens.V1.Size.homeFindMax)
    return (max(0, available - find), find)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 2 else { return .zero }
    let total = proposal.width ?? (Tokens.V1.Size.homeFindMax * 2 + spacing)
    let (start, find) = widths(for: total)
    let height = max(
      subviews[0].sizeThatFits(ProposedViewSize(width: start, height: nil)).height,
      subviews[1].sizeThatFits(ProposedViewSize(width: find, height: nil)).height)
    return CGSize(width: total, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard subviews.count == 2 else { return }
    let (start, find) = widths(for: bounds.width)
    subviews[0].place(
      at: bounds.origin, proposal: ProposedViewSize(width: start, height: bounds.height))
    subviews[1].place(
      at: CGPoint(x: bounds.minX + start + spacing, y: bounds.minY),
      proposal: ProposedViewSize(width: find, height: bounds.height))
  }
}
