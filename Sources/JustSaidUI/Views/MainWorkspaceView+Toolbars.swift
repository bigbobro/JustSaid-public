import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-21 批0 拆分:自 MainWorkspaceView.swift 按 MARK 边界机械迁出,零行为变更.
extension MainWorkspaceView {

  // MARK: - Toolbar

  /// 驾驶舱顶栏(2026-08-19 A+C 混搭):只留**会议身份与终止动作**——会名、语言、
  /// 阅读缩放、废弃/结束会议。会话开关(计时/麦克风/闲聊/暂停/章节/转写/会议库/设置)
  /// 全部迁到左侧控制轨;计时随红点一起在轨上,所以这里的会名不再带计时器。
  var cockpitToolbar: some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      meetingIdentity

      Spacer()

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
      Picker("说话语言", selection: languageSelection) {
        ForEach(MeetingLanguage.allCases) { language in
          Text(shortLabel(for: language)).tag(language)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 148)
      .accessibilityLabel("说话语言")
      .disabled(recordingSession.phase.isBusy)
    }
  }

  /// 会议库顶栏(2026-08-21 批2 归位;同日拆分修订):空闲 7 件 / 录制中 6 件。
  /// 闲聊/暂停/章节/转写/micStatus 随舱走;语言/缩放平铺顶栏(有状态、常切换,
  /// 状态要一眼可见、一步可调),导入/重扫进 ⋯ popover(无状态、低频动作)。
  var libraryToolbar: some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      libraryContextTitle
      Spacer()
      if isReturnToCockpit {
        libraryRecordingCapsule
      }
      languageControl
        .runtimeAccessibilityIdentifier("library.toolbar.language")
      ContentScaleControl(selection: textScaleSelection)
        .runtimeAccessibilityIdentifier("library.toolbar.scale")
      libraryOverflowMenu
      Button {
        isShowingSettings = true
      } label: {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.iconHover)
      .accessibilityLabel("打开设置")
      .runtimeAccessibilityIdentifier("library.toolbar.settings")
      if !isReturnToCockpit {
        libraryPrimaryAction
      }
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
    .runtimeAccessibilityIdentifier("library.toolbar")
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
        Text("返回驾驶舱")
          .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
        KeycapView(label: "⌘L")
      }
    }
    .buttonStyle(.toolbarPillRecording)
    .help("返回会中驾驶舱，录制仍在进行")
    .accessibilityLabel("返回会中驾驶舱，录制仍在进行")
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
      Button("开始记录") {
        startMeeting()
      }
      .buttonStyle(.toolbarPillAccent)
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
      HStack(spacing: Tokens.Spacing.xsm) {
        TextField(
          "会议名称",
          text: Binding(
            get: { meetingTitle },
            set: { meetingTitle = $0 }
          )
        )
        .textFieldStyle(.plain)
        .font(.system(size: Tokens.FontSize.body, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink)
        .frame(width: 180)
        .padding(.horizontal, Tokens.Spacing.xs)
        .padding(.vertical, Tokens.Spacing.hairline)
        .background(Tokens.Color.pane, in: RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge))
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge)
            .stroke(
              isMeetingTitleFocused ? Tokens.Color.ac : Tokens.Color.line,
              lineWidth: 1
            )
        )
        .focused($isMeetingTitleFocused)
        .onSubmit(commitCurrentMeetingTitle)
        .onChange(of: isMeetingTitleFocused) { _, focused in
          if !focused {
            commitCurrentMeetingTitle()
          }
        }
        .disabled(recordingSession.phase == .stopping)
        .accessibilityLabel("当前会议名称，可编辑")
      }
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
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge).stroke(Tokens.Color.line, lineWidth: 1))
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
      // 驾驶舱内「开始记录」的**唯一入口**(2026-08-19 用户拍板收敛):
      // G4 曾在舞台与整理区空态各摆一颗,舞台升格后与这颗贴脸,同屏三处同名按钮。
      // 标识用于运行时数「恰好一个」,与 `notes.mark` 同款钉法。
      Button("开始记录") {
        startMeeting()
      }
      .buttonStyle(.toolbarPillAccent)
      .runtimeAccessibilityIdentifier("cockpit.start-recording")
    }
  }
}
