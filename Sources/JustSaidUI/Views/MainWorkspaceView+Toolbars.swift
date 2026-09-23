import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-21 批0 拆分:自 MainWorkspaceView.swift 按 MARK 边界机械迁出,零行为变更.
extension MainWorkspaceView {

  // MARK: - Toolbar

  /// 驾驶舱顶栏。2026-08-19 定的是「顶栏=会议身份与终止,左轨=会话开关」;
  /// 2026-09-21 owner 按设计稿 `live.html` 改成「左轨=状态,顶栏=动作」:
  /// 闲聊与暂停麦克风从轨上搬到这里,点名提醒从这里搬到轨上(它带一盏指示灯,
  /// 和录制块的红点是同一类东西)。这一条也和会议页「右上角 ⋯ = 对这场会做什么」对齐。
  ///
  /// 计时仍随红点在轨上,所以这里的会名不带计时器。
  /// 闲聊 ⌥⌘X / 暂停 ⌥⌘P 的全局热键不受位置变动影响。
  var cockpitToolbar: some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      meetingIdentity

      Spacer()

      chatToolbarButton
      microphonePauseToolbarButton
      languageControl
      ContentScaleControl(selection: textScaleSelection)
      primaryActionButton
    }
    .padding(.horizontal, Tokens.Spacing.md)
    .frame(height: Tokens.Layout.toolbarHeight)
    .background(
      LinearGradient(
        colors: [Tokens.Color.toolbarTop, Tokens.Color.toolbarBottom],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .runtimeAccessibilityIdentifier("cockpit.toolbar")
  }

  /// R2':录制中语言只读(改选不能中途改识别语种),空闲态才是三选一。两套 chrome 共用。
  @ViewBuilder
  private var languageControl: some View {
    if recordingSession.phase == .recording || recordingSession.phase == .stopping {
      // R2':录制中只读标签同样只显示「Auto/中/英」,不带「语言」前缀。
      Text(shortLabel(for: language))
        .font(.system(size: Tokens.FontSize.uiEmphasis))
        .foregroundStyle(Tokens.Color.ink2)
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, Tokens.Spacing.xxs)
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(
            Tokens.Color.line, lineWidth: 1))
    } else {
      // R2':隐藏 Picker 标签(原来「说话语言」在工具栏被截成「说…」),只留三个 segment。
      V1SegmentedPicker(
        "说话语言", selection: languageSelection,
        options: MeetingLanguage.allCases.map { .init($0, shortLabel(for: $0)) }
      )
      .fixedSize()
      .disabled(recordingSession.phase.isBusy)
    }
  }

  /// 会议库顶栏(2026-08-21 批2 归位;同日拆分修订):空闲 7 件 / 录制中 6 件。
  /// 闲聊/暂停/章节/转写/micStatus 随舱走;语言/缩放平铺顶栏(有状态、常切换,
  /// 状态要一眼可见、一步可调),导入/重扫进 ⋯ popover(无状态、低频动作)。
  var libraryToolbar: some View {
    WorkspaceTopBar("会议库", detail: "\(libraryMeetingCount) 场") {
      if isReturnToCockpit { libraryRecordingCapsule }
      Button("导入录音") { libraryImportAction?() }
        .buttonStyle(.v1Outline)
        .runtimeAccessibilityIdentifier("library.toolbar.import")
      if !isReturnToCockpit { libraryPrimaryAction }
      // 面板常驻之后这颗只是开关,原来看不出当前是展开还是收起(owner 2026-09-20)。
      // 展开时用 outline 压住,收起时回到 quiet,一眼分得出状态。
      Button { libraryFilterAction?() } label: {
        Label("筛选", systemImage: "line.3.horizontal.decrease")
      }
      .buttonStyle(
        libraryFilterPanelShown ? V1ButtonStyle.v1Outline : V1ButtonStyle.v1Quiet)
      .accessibilityAddTraits(libraryFilterPanelShown ? [.isSelected] : [])
      .runtimeAccessibilityIdentifier("library.toolbar.filter")
    }
    .runtimeAccessibilityIdentifier("library.toolbar")
  }

  /// 闲聊。轨上原来那一格搬过来的,判定与文案一字不改——
  /// ⌥⌘X 的唯一 owner 仍在 app 菜单命令(批1),按钮只管点击。
  @ViewBuilder
  private var chatToolbarButton: some View {
    if isCockpitSessionActive {
      Button {
        toggleChatExclusion()
      } label: {
        Label(openChatRange != nil ? "结束闲聊" : "闲聊", systemImage: "bubble.left.and.exclamationmark.bubble.right")
      }
      .buttonStyle(openChatRange != nil ? V1ButtonStyle.v1Outline : V1ButtonStyle.v1Quiet)
      .disabled(recordingSession.startedAt == nil || recordingSession.phase != .recording)
      .help(
        openChatRange != nil
          ? "结束闲聊：从这里起的内容重新进纪要"
          : "标记闲聊开始：之后的内容不进纪要，再按一次结束"
      )
      .accessibilityLabel(openChatRange != nil ? "结束闲聊" : "标记闲聊开始")
      .runtimeAccessibilityIdentifier("toolbar.chat")
    }
  }

  /// 暂停麦克风。同上,从轨上搬来,判定与文案不变;⌥⌘P 的 owner 仍在菜单命令。
  @ViewBuilder
  private var microphonePauseToolbarButton: some View {
    if isCockpitSessionActive {
      Button {
        if recordingSession.isMicrophonePaused {
          recordingSession.resumeMicrophone()
        } else {
          recordingSession.pauseMicrophone()
        }
      } label: {
        Label(
          recordingSession.isMicrophonePaused ? "恢复麦克风" : "暂停麦克风",
          systemImage: "mic.slash.fill")
      }
      .buttonStyle(
        recordingSession.isMicrophonePaused ? V1ButtonStyle.v1Outline : V1ButtonStyle.v1Quiet)
      .disabled(recordingSession.phase != .recording)
      .help(
        recordingSession.isMicrophonePaused
          ? "恢复麦克风：本侧重新开始收音"
          : "暂停麦克风：本侧不再收音（对方/系统声仍在录），再按一次恢复"
      )
      .accessibilityLabel(recordingSession.isMicrophonePaused ? "恢复麦克风" : "暂停麦克风")
      .runtimeAccessibilityIdentifier("toolbar.mic-pause")
    }
  }

  /// 与轨上同一判定(recording/stopping)。
  private var isCockpitSessionActive: Bool {
    recordingSession.phase == .recording || recordingSession.phase == .stopping
  }

  private var libraryContextTitle: some View {
    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xsm) {
      Text("会议库")
        .font(.system(size: Tokens.FontSize.headingSmall, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink)
      Text("\(libraryMeetingCount) 场")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("会议库，\(libraryMeetingCount) 场")
    .runtimeAccessibilityIdentifier("library.toolbar.context")
  }

  /// cue 橙录制胶囊:会名 · 计时 · 返回驾驶舱合一,点击回舱、不断录。
  /// 规格走 `.toolbarPillRecording`(cue 描边/文字/扫光),色值不自创。
  private var libraryRecordingCapsule: some View {
    Button {
      appCoordinator.showCockpit()
    } label: {
      HStack(spacing: Tokens.Spacing.xsm) {
        PulsingDot(color: Tokens.Color.rec, size: 7)
        Text(recordingSession.currentTitle ?? meetingTitle)
          .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: 180, alignment: .leading)
        Text("·")
          .foregroundStyle(Tokens.Color.cue)
        TimelineView(.periodic(from: recordingSession.startedAt ?? .now, by: 1)) { context in
          Text(
            ElapsedTime.shortLabel(
              context.date.timeIntervalSince(recordingSession.startedAt ?? context.date)
            )
          )
          .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .bold, design: .monospaced))
        }
        .fixedSize()
        Text("返回会中")
          .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
        KeycapView(label: "⌘L")
      }
    }
    .buttonStyle(.toolbarPillRecording)
    .help("返回会中，录制仍在进行")
    .accessibilityLabel("返回会中，录制仍在进行")
    .runtimeAccessibilityIdentifier("library.toolbar.recording-capsule")
  }

  private var libraryOverflowMenu: some View {
    Button {
      isShowingLibraryOverflow = true
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: Tokens.FontSize.body, weight: .semibold))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.iconHover)
    .popover(isPresented: $isShowingLibraryOverflow, arrowEdge: .bottom) {
      LibraryOverflowPanel(
        onImport: wrappedOverflowAction(libraryImportAction),
        onReload: wrappedOverflowAction(libraryReloadAction)
      )
    }
    .help("更多：导入录音、重新扫描")
    .accessibilityLabel("更多，导入录音、重新扫描")
    .runtimeAccessibilityIdentifier("library.toolbar.overflow")
    .onDisappear {
      isShowingLibraryOverflow = false
    }
  }

  private func wrappedOverflowAction(_ action: (() -> Void)?) -> (() -> Void)? {
    guard let action else { return nil }
    return {
      isShowingLibraryOverflow = false
      action()
    }
  }

  @ViewBuilder
  private var libraryPrimaryAction: some View {
    switch recordingSession.phase {
    case .starting, .stopping:
      Button(recordingSession.phase == .starting ? "正在启动…" : "正在保存…") {}
        .buttonStyle(.toolbarPillAccent)
        .disabled(true)
    case .idle, .completed, .failed:
      // 与首页那颗同款主按钮(v1Primary,近黑)。原来用 .toolbarPillAccent 画成墨绿实心,
      // 同一颗「开始记录」在两个页面两个样;而且 accent 在设计系统里只落在记号和点上,
      // 不做主按钮底色。
      Button("开始记录") {
        startMeeting()
      }
      .buttonStyle(V1ButtonStyle.v1Primary)
      .runtimeAccessibilityIdentifier("library.toolbar.start-recording")
    case .recording:
      EmptyView()
    }
  }

  /// 会名(录制中可改名)。驾驶舱顶栏用;计时器在控制轨与库态录制胶囊上,
  /// 这里不再并列第二只表。
  @ViewBuilder
  private var meetingIdentity: some View {
    switch recordingSession.phase {
    case .recording, .stopping:
      CurrentMeetingTitleField(session: recordingSession, title: $meetingTitle)
        .disabled(recordingSession.phase == .stopping)
    default:
      TextField("会议名称", text: $meetingTitleDraft)
        .textFieldStyle(.plain)
        .font(.system(size: Tokens.FontSize.body))
        .frame(width: 180)
        .padding(.horizontal, Tokens.Spacing.xsm)
        .padding(.vertical, Tokens.Spacing.xxs)
        .background(
          RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge).fill(Tokens.Color.pane)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge)
            .stroke(Tokens.Color.line, lineWidth: 1)
        )
        .disabled(recordingSession.phase.isBusy)
        .accessibilityLabel("会议名称，未填写时默认使用“会议”")
    }
  }

  @ViewBuilder
  private var primaryActionButton: some View {
    switch recordingSession.phase {
    case .recording:
      // 「废弃」放在「结束会议」左侧、用低调样式：它是不可逆动作，
      // 不该和正常收尾长得一样醒目，但录到一半发现没用时必须一步能到（T15）。
      Button("废弃") {
        isConfirmingDiscard = true
      }
      .buttonStyle(.toolbarPill)
      .help("废弃这场会议：停止录音，不做精转、不生成纪要，并删除本场录音与补充记录")
      .accessibilityLabel("废弃并结束当前会议")

      Button("结束会议") {
        requestEndMeeting()
      }
      .buttonStyle(.toolbarPillAccent)

    case .starting, .stopping:
      Button(recordingSession.phase == .starting ? "正在启动…" : "正在保存…") {}
        .buttonStyle(.toolbarPillAccent)
        .disabled(true)

    case .idle, .completed, .failed:
      EmptyView()
    }
  }
}
