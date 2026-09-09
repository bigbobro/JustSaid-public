import JustSaidCore
import SwiftUI

/// 驾驶舱控制轨（2026-08-19 A+C 混搭）：窗口最左侧的墨色定宽轨，承载全部会话开关。
///
/// **为什么把开关从顶栏搬到轨上**：旧顶栏一条横排同时挂「会议身份 + 会话开关 + 阅读设置
/// + 终止动作」四类东西，多轮增量后按钮排到十几个，重要度全平；轨把「录制中才有意义的
/// 会话开关」立起来单独成列，顶栏只剩会议身份与终止动作，回来一眼落到舞台而不是按钮丛。
///
/// **闲聊/暂停不再铺横幅到舞台上方**（R2）：轨上图标带状态点，悬停浮出可操作卡片
/// （`RailChatStatusCard` / `RailMicPauseStatusCard`）。两张卡是独立类型，因为 headless
/// 布局弹不出悬停层——验证只能各自单独摆一页探针，这与章节目录/溯源弹层同一处理。
///
/// **轨只属于驾驶舱**（R7）：会议库仍用它自己的顶栏，深色轨不铺进库。
struct CockpitRailView: View {
  @ObservedObject var recordingSession: RecordingSession
  /// 未封口闲聊区间的起点（会议时间轴秒）；nil = 没有闲聊在进行。
  let openChatRangeStart: TimeInterval?
  /// 麦克风暂停起点（呈现层记账，权威区间在 meeting.json）。
  let microphonePausedAt: Date?
  @Binding var transcriptPresentation: LiveTranscriptPresentationState
  @Binding var isShowingChapterDirectory: Bool
  let chapterTopics: [SummaryTopic]
  let chapterNowCoveredLabel: String
  let onSelectChapter: (UUID) -> Void
  let onToggleChat: () -> Void
  let onCloseChat: () -> Void
  let onToggleMicrophonePause: () -> Void
  let onResumeMicrophone: () -> Void
  let onOpenLibrary: () -> Void
  let onOpenSettings: () -> Void

  /// 悬停卡只在会话开关上出现；同一时刻至多一张。
  @State private var hoveredStatusSlot: StatusSlot?

  private enum StatusSlot {
    case chat
    case microphonePause
  }

  /// 会话开关只在录制链路活跃时可用——与旧顶栏同一判定（recording/stopping）。
  private var isSessionActive: Bool {
    recordingSession.phase == .recording || recordingSession.phase == .stopping
  }

  var body: some View {
    VStack(spacing: 0) {
      recordingIndicator
      microphoneIndicator
      Spacer().frame(height: Tokens.Spacing.xl)

      chatSlot
      Spacer().frame(height: Tokens.Spacing.xxs)
      microphonePauseSlot
      Spacer().frame(height: Tokens.Spacing.xxs)
      chapterSlot
      Spacer().frame(height: Tokens.Spacing.xxs)
      transcriptSlot

      Spacer(minLength: 0)

      Rectangle()
        .fill(Tokens.Color.railInkDivider)
        .frame(width: 22, height: 1)
        .padding(.vertical, Tokens.Spacing.xs)
      librarySlot
      Spacer().frame(height: Tokens.Spacing.xxs)
      settingsSlot
    }
    .padding(.vertical, Tokens.Spacing.smd)
    .frame(width: Tokens.Layout.commandRailWidth)
    .frame(maxHeight: .infinity)
    .background(Tokens.Color.rail)
    // 轨底两态同色是刻意的（墨色=控制台锚点），代价是暗色下窗口底色也偏墨、
    // 两个面几乎并成一块；补一条右缘细线，让「最左是一条轨」在暗色下也画得出来。
    .overlay(alignment: .trailing) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("会话控制")
    .runtimeAccessibilityIdentifier("cockpit.rail")
  }

  // MARK: - 状态指示（不可点）

  /// 录制红点 + 计时。基准仍是 `RecordingSession.startedAt`（meeting.json 的权威起点），
  /// 与旧顶栏计时器同源——菜单栏开录时界面自记的时刻会永远停在 00:00。
  @ViewBuilder
  private var recordingIndicator: some View {
    if isSessionActive, let startedAt = recordingSession.startedAt {
      TimelineView(.periodic(from: startedAt, by: 1)) { context in
        VStack(spacing: Tokens.Spacing.xs) {
          PulsingDot(color: Tokens.Color.rec, size: 8)
          Text(ElapsedTime.shortLabel(context.date.timeIntervalSince(startedAt)))
            .font(.system(size: Tokens.FontSize.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(Tokens.Color.rec)
            .lineLimit(1)
            .fixedSize()
        }
      }
      .padding(.bottom, Tokens.Spacing.xsm)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("正在录制")
      .runtimeAccessibilityIdentifier("cockpit.rail.recording")
    }
  }

  /// Checkmarks express intent; the visible status comes only from the session's binding.
  private var microphoneIndicator: some View {
    VStack(spacing: Tokens.Spacing.xs) {
      Menu {
        microphoneChoice(.automatic, title: "自动跟随系统")
        Divider()
        ForEach(recordingSession.microphoneInputDevices) { device in
          microphoneChoice(.device(uid: device.uid, name: device.name), title: device.name)
        }
        if case .device(let uid, let name) = recordingSession.microphoneInputPreference,
          !recordingSession.microphoneInputDevices.contains(where: { $0.uid == uid })
        {
          let state = recordingSession.microphoneInputDirectoryIsKnown ? "未连接" : "状态未知"
          Label("\(name ?? "首选麦克风")（\(state)）", systemImage: "checkmark")
        }
      } label: {
        Image(systemName: "mic.fill")
          .font(.system(size: Tokens.FontSize.headingSmall))
          .foregroundStyle(Tokens.Color.railInk)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .tint(Tokens.Color.railInk)
      .environment(\.colorScheme, .dark)
      .accessibilityLabel("选择麦克风输入")
      .runtimeAccessibilityIdentifier("cockpit.rail.mic.menu")
      Text(recordingSession.microphoneInputStatus.text)
        .font(.system(size: Tokens.FontSize.micro))
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .runtimeAccessibilityIdentifier("cockpit.rail.mic.status")
      if recordingSession.phase == .recording {
        MicLevelBar(level: recordingSession.microphoneLevel)
      }
    }
    .foregroundStyle(Tokens.Color.railInk)
    .padding(.vertical, Tokens.Spacing.xxs)
    .padding(.horizontal, Tokens.Spacing.xxs)
    .fixedSize(horizontal: false, vertical: true)
    .hoverRowBackground()
    .disabled(recordingSession.phase == .stopping)
    .help(recordingSession.microphoneInputStatus.text)
    .accessibilityLabel("麦克风输入，\(recordingSession.microphoneInputStatus.text)")
    .runtimeAccessibilityIdentifier("cockpit.rail.mic")
  }

  private func microphoneChoice(_ preference: MicrophoneInputPreference, title: String) -> some View
  {
    Button {
      recordingSession.selectMicrophoneInput(preference)
    } label: {
      if isSelected(preference) { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
  }

  private func isSelected(_ preference: MicrophoneInputPreference) -> Bool {
    switch (preference, recordingSession.microphoneInputPreference) {
    case (.automatic, .automatic): return true
    case (.device(let uid, _), .device(let selected, _)): return uid == selected
    default: return false
    }
  }

  // MARK: - 会话开关

  @ViewBuilder
  private var chatSlot: some View {
    if isSessionActive {
      railSlot(
        statusSlot: .chat,
        content: {
          RailButton(
            systemImage: "bubble.left.and.exclamationmark.bubble.right",
            label: "闲聊",
            isOn: openChatRangeStart != nil,
            statusDotIdentifier: openChatRangeStart != nil ? "cockpit.rail.chat.open" : nil,
            action: onToggleChat
          )
          // ⌥⌘X 的唯一 owner 在 app 菜单命令(批1),按钮只管点击。
          .disabled(recordingSession.startedAt == nil || recordingSession.phase != .recording)
          .help(
            openChatRangeStart != nil
              ? "结束闲聊：从这里起的内容重新进纪要"
              : "标记闲聊开始：之后的内容不进纪要，再按一次结束"
          )
          .accessibilityLabel(openChatRangeStart != nil ? "结束闲聊" : "标记闲聊开始")
          .runtimeAccessibilityIdentifier("cockpit.rail.chat")
        },
        card: {
          RailChatStatusCard(openRangeStart: openChatRangeStart, onClose: onCloseChat)
        }
      )
    }
  }

  @ViewBuilder
  private var microphonePauseSlot: some View {
    if isSessionActive {
      railSlot(
        statusSlot: .microphonePause,
        content: {
          RailButton(
            systemImage: "mic.slash.fill",
            label: "暂停",
            isOn: recordingSession.isMicrophonePaused,
            statusDotIdentifier: recordingSession.isMicrophonePaused
              ? "cockpit.rail.mic-pause.on" : nil,
            action: onToggleMicrophonePause
          )
          // ⌥⌘P 的唯一 owner 在 app 菜单命令(批1),按钮只管点击。
          .disabled(recordingSession.phase != .recording)
          .help(
            recordingSession.isMicrophonePaused
              ? "恢复麦克风：本侧重新开始收音"
              : "暂停麦克风：本侧不再收音（对方/系统声仍在录），再按一次恢复"
          )
          .accessibilityLabel(recordingSession.isMicrophonePaused ? "恢复麦克风" : "暂停麦克风")
          .runtimeAccessibilityIdentifier("cockpit.rail.mic-pause")
        },
        card: {
          RailMicPauseStatusCard(
            isPaused: recordingSession.isMicrophonePaused,
            pausedAt: microphonePausedAt,
            onResume: onResumeMicrophone
          )
        }
      )
    }
  }

  @ViewBuilder
  private var chapterSlot: some View {
    if isSessionActive {
      RailButton(
        systemImage: "list.bullet",
        label: "章节",
        isOn: false,
        statusDotIdentifier: nil
      ) {
        isShowingChapterDirectory = true
      }
      // ⌘K 的唯一 owner 在 app 菜单命令(批1),按钮只管点击。
      .popover(isPresented: $isShowingChapterDirectory, arrowEdge: .trailing) {
        ChapterDirectoryView(
          topics: chapterTopics,
          nowCoveredLabel: chapterNowCoveredLabel
        ) { topicID in
          onSelectChapter(topicID)
          isShowingChapterDirectory = false
        }
      }
      .help("章节目录：跳到任意已聊过的话题")
      .accessibilityLabel("章节目录")
      .runtimeAccessibilityIdentifier("cockpit.rail.chapters")
    }
  }

  @ViewBuilder
  private var transcriptSlot: some View {
    if isSessionActive {
      LiveTranscriptRailButton(presentation: $transcriptPresentation)
    }
  }

  private var librarySlot: some View {
    RailButton(
      systemImage: "tray.full",
      label: "会议库",
      isOn: false,
      statusDotIdentifier: nil,
      action: onOpenLibrary
    )
    // ⌘L 的唯一 owner 在 app 菜单命令(批1),按钮只管点击。
    .help("切换到会议库，查看历史会议的纪要、转写与补充记录")
    .accessibilityLabel("切换到会议库，查看历史会议的纪要、转写与补充记录")
    .runtimeAccessibilityIdentifier("cockpit.rail.library")
  }

  private var settingsSlot: some View {
    RailButton(
      systemImage: "gearshape",
      label: "设置",
      isOn: false,
      statusDotIdentifier: nil,
      action: onOpenSettings
    )
    // ⌘, 的唯一 owner 在 app 菜单命令(批4 容器收敛),按钮只管点击。
    .accessibilityLabel("打开设置")
    .runtimeAccessibilityIdentifier("cockpit.rail.settings")
  }

  // MARK: - 悬停卡承载

  /// 轨槽 = 按钮 + 右侧悬停卡。卡片画在轨的 overlay 里并靠 `zIndex` 压过主列——
  /// HStack 里后画的兄弟默认盖住先画的，不抬 zIndex 的话 56pt 轨外的卡片会被主列吃掉。
  private func railSlot<Content: View, Card: View>(
    statusSlot: StatusSlot,
    @ViewBuilder content: () -> Content,
    @ViewBuilder card: () -> Card
  ) -> some View {
    content()
      .onHover { hovering in
        if hovering {
          hoveredStatusSlot = statusSlot
        } else if hoveredStatusSlot == statusSlot {
          hoveredStatusSlot = nil
        }
      }
      .overlay(alignment: .topLeading) {
        if hoveredStatusSlot == statusSlot {
          card()
            .frame(width: Tokens.Layout.railHoverCardWidth, alignment: .leading)
            .offset(x: Tokens.Layout.commandRailWidth - Tokens.Spacing.xs, y: 0)
            .onHover { hovering in
              if !hovering, hoveredStatusSlot == statusSlot {
                hoveredStatusSlot = nil
              }
            }
        }
      }
      .zIndex(1)
  }
}

/// 轨上一颗按钮：18pt 图标 + 9pt 中文标签，44×46 命中区。
/// 轨底恒为墨色（`Tokens.Color.rail` 两态同色），所以前景色也必须固定
/// （`railInk` / `railInkActive`）——跟随外观反转会在暗色下变成墨底配深灰字。
struct RailButton: View {
  let systemImage: String
  let label: String
  let isOn: Bool
  /// 非 nil 时右上角画状态点，并以该标识入可访问层级（闲聊未封口 / 麦克风暂停）。
  let statusDotIdentifier: String?
  let action: () -> Void

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      VStack(spacing: Tokens.Spacing.hairline) {
        Image(systemName: systemImage)
          .font(.system(size: Tokens.FontSize.headline, weight: .regular))
          .accessibilityHidden(true)
        Text(label)
          .font(.system(size: Tokens.FontSize.micro))
          .lineLimit(1)
      }
      .foregroundStyle(foreground)
      .frame(width: 44, height: 46)
      .background(
        RoundedRectangle(cornerRadius: Tokens.Radius.widget)
          .fill(background)
      )
      .overlay(alignment: .topTrailing) {
        if let statusDotIdentifier {
          Circle()
            .fill(Tokens.Color.warn)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(Tokens.Color.rail, lineWidth: 2))
            .padding(.top, Tokens.Spacing.hairline)
            .padding(.trailing, Tokens.Spacing.xs)
            .accessibilityHidden(true)
            .runtimeAccessibilityIdentifier(statusDotIdentifier)
        }
      }
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
    }
    .buttonStyle(.plain)
    .frame(width: Tokens.Layout.commandRailWidth)
  }

  private var foreground: Color {
    if !isEnabled { return Tokens.Color.railInkDisabled }
    if isOn { return Tokens.Color.railInkActive }
    return isHovering ? Tokens.Color.onAccent : Tokens.Color.railInk
  }

  private var background: Color {
    if !isEnabled { return .clear }
    if isOn { return Tokens.Color.railInkOnState }
    return isHovering ? Tokens.Color.acHi : .clear
  }
}

/// 麦克风电平条：0~1 电平填充胶囊。绿色用「我」的说话人色——这是"我这一路"的信号。
/// 08-19 从顶栏迁到控制轨；驾驶舱与会议库顶栏共用同一颗，取值与动画节拍不变。
struct MicLevelBar: View {
  let level: Float

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Tokens.Color.railInkTrack)
        Capsule()
          .fill(Tokens.Color.me)
          .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
          .animation(reduceMotion ? nil : .linear(duration: Tokens.Motion.hover), value: level)
      }
    }
    .frame(width: 26, height: 4)
    .accessibilityHidden(true)
  }
}

/// 「闲聊中」轨上悬停卡（R2）：把原横幅的三件事——**是什么状态、从几点起、怎么收尾**——
/// 原样搬进卡片，只换承载形态。文案与 `ChatExclusionBanner` 同口径，不另起一套说法。
public struct RailChatStatusCard: View {
  /// 未封口区间起点；nil = 没有闲聊在进行，卡片只说明这颗开关做什么。
  public let openRangeStart: TimeInterval?
  public let onClose: () -> Void

  public init(openRangeStart: TimeInterval?, onClose: @escaping () -> Void) {
    self.openRangeStart = openRangeStart
    self.onClose = onClose
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      if let openRangeStart {
        Text("闲聊中")
          .font(.system(size: Tokens.FontSize.bodyMinimum, weight: .bold))
          .foregroundStyle(Tokens.Color.warn)
        Text("从 \(TranscriptAnchor(seconds: openRangeStart).timecode) 起的内容不进纪要")
          .font(.system(size: Tokens.FontSize.uiEmphasis))
          .foregroundStyle(Tokens.Color.ink2)
          .fixedSize(horizontal: false, vertical: true)
        Button("结束闲聊", action: onClose)
          .buttonStyle(.toolbarPillAccent)
          .accessibilityLabel("结束闲聊，之后的会议内容重新进纪要")
          .runtimeAccessibilityIdentifier("cockpit.rail.chat.end")
      } else {
        Text("标记闲聊开始")
          .font(.system(size: Tokens.FontSize.bodyMinimum, weight: .bold))
          .foregroundStyle(Tokens.Color.ink)
        Text("之后的内容不进纪要，再按一次结束")
          .font(.system(size: Tokens.FontSize.uiEmphasis))
          .foregroundStyle(Tokens.Color.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(Tokens.Spacing.smd)
    .cardShell()
    .tokenShadow(Tokens.Shadow.sh2)
    .accessibilityElement(children: .contain)
    .runtimeAccessibilityIdentifier("cockpit.rail.chat.card")
  }
}

/// 「麦克风已暂停」轨上悬停卡（R2）：与 `MicrophonePauseBanner` 同口径——
/// 直说「本侧不再收音、对方/系统声仍在录」，带已暂停时长与超时轻提醒。
public struct RailMicPauseStatusCard: View {
  public let isPaused: Bool
  public let pausedAt: Date?
  public let onResume: () -> Void

  public init(isPaused: Bool, pausedAt: Date?, onResume: @escaping () -> Void) {
    self.isPaused = isPaused
    self.pausedAt = pausedAt
    self.onResume = onResume
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      if isPaused {
        Text("麦克风已暂停")
          .font(.system(size: Tokens.FontSize.bodyMinimum, weight: .bold))
          .foregroundStyle(Tokens.Color.warn)
        Text("本侧不再收音，对方/系统声仍在录")
          .font(.system(size: Tokens.FontSize.uiEmphasis))
          .foregroundStyle(Tokens.Color.ink2)
          .fixedSize(horizontal: false, vertical: true)
        TimelineView(.periodic(from: pausedAt ?? .now, by: 1)) { context in
          let elapsed = context.date.timeIntervalSince(pausedAt ?? context.date)
          HStack(spacing: Tokens.Spacing.xxs) {
            Text("已暂停 \(ElapsedTime.shortLabel(elapsed))")
              .font(
                .system(size: Tokens.FontSize.uiEmphasis, weight: .semibold, design: .monospaced)
              )
              .foregroundStyle(Tokens.Color.warn)
              .runtimeAccessibilityIdentifier("cockpit.rail.mic-pause.elapsed")
            if elapsed >= MicrophonePauseBanner.reminderThreshold {
              Text("别忘了恢复")
                .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
                .foregroundStyle(Tokens.Color.warn)
                .runtimeAccessibilityIdentifier("cockpit.rail.mic-pause.reminder")
            }
          }
        }
        Button("恢复麦克风", action: onResume)
          .buttonStyle(.toolbarPillAccent)
          .accessibilityLabel("恢复麦克风，本侧重新开始收音")
          .runtimeAccessibilityIdentifier("cockpit.rail.mic-pause.resume")
      } else {
        Text("暂停麦克风")
          .font(.system(size: Tokens.FontSize.bodyMinimum, weight: .bold))
          .foregroundStyle(Tokens.Color.ink)
        Text("本侧不再收音（对方/系统声仍在录），再按一次恢复")
          .font(.system(size: Tokens.FontSize.uiEmphasis))
          .foregroundStyle(Tokens.Color.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(Tokens.Spacing.smd)
    .cardShell()
    .tokenShadow(Tokens.Shadow.sh2)
    .accessibilityElement(children: .contain)
    .runtimeAccessibilityIdentifier("cockpit.rail.mic-pause.card")
  }
}
