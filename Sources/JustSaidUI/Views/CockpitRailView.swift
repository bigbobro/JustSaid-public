import JustSaidCore
import SwiftUI

/// 主图标轨内的录制控件；不再拥有第二条轨的宽度、底色或导航入口。
struct CockpitRailControls: View {
  @ObservedObject var recordingSession: RecordingSession
  @Binding var transcriptPresentation: LiveTranscriptPresentationState
  @Binding var isShowingChapterDirectory: Bool
  let chapterTopics: [SummaryTopic]
  let chapterNowCoveredLabel: String
  let onSelectChapter: (UUID) -> Void
  let onReturnToMeeting: () -> Void
  let isSelected: Bool
  let onOpenSettings: () -> Void
  /// 点名提醒:与设置、会议库顶栏读写同一份偏好。
  let nameAlertPreferences: NameAlertPreferencesStore
  let nameAlertSession: NameAlertSession?

  @State private var isMicrophoneHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 会话开关只在录制链路活跃时可用——与旧顶栏同一判定（recording/stopping）。
  private var isSessionActive: Bool {
    recordingSession.phase == .recording || recordingSession.phase == .stopping
  }

  var body: some View {
    if isSessionActive {
      VStack(spacing: Tokens.V1.Space.s2xs) {
        recordingIndicator
        microphoneIndicator
        nameAlertSlot
        chapterSlot
        transcriptSlot
      }
    }
  }

  // MARK: - 录制与输入状态

  /// 录制红点 + 计时。基准仍是 `RecordingSession.startedAt`（meeting.json 的权威起点），
  /// 与旧顶栏计时器同源——菜单栏开录时界面自记的时刻会永远停在 00:00。
  @ViewBuilder
  private var recordingIndicator: some View {
    if isSessionActive, let startedAt = recordingSession.startedAt {
      Button(action: onReturnToMeeting) {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
          VStack(spacing: Tokens.V1.Space.s2xs) {
            PulsingDot(color: Tokens.V1.Color.rec, size: Tokens.V1.Space.xs)
            Text(ElapsedTime.shortLabel(context.date.timeIntervalSince(startedAt)))
              .font(Tokens.V1.Text.micro.font.monospacedDigit())
              .foregroundStyle(Tokens.V1.Color.rec)
              .lineLimit(1)
              .fixedSize()
            MicLevelBar(level: recordingSession.microphoneLevel, isPaused: recordingSession.isMicrophonePaused)
          }
          .frame(width: Tokens.V1.Size.recordBlock.width, height: Tokens.V1.Size.recordBlock.height)
          .background(isSelected ? Tokens.V1.Color.paper3 : .clear,
            in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md))
        }
      }
      .buttonStyle(.plain)
      .help("返回会议")
      .accessibilityLabel("正在录制，返回会议")
      .runtimeAccessibilityIdentifier("cockpit.rail.recording")
      .runtimeAccessibilityIdentifier("app.rail.recording")
    }
  }

  /// 选中与实际使用必须一眼可见(owner 2026-10-20:「我根本不知道选择了什么 mic」)。
  ///
  /// **为什么不用 `Label(_, systemImage: "checkmark")`**:本机实测(SwiftUI Menu /
  /// macOS 27)那颗 checkmark 在菜单里根本不渲染——截图没有勾,AX 里 7 个 `AXMenuItem`
  /// 的 `AXMenuItemMarkChar` 全为空。同一个探针里 `Toggle` 自带勾、纯文本 ✓ 也画得出来。
  /// 所以选中态改成**文字标记**:行首 `✓`,正在切换的那一项后面跟「（切换中）」。
  /// 意图(你要用哪个)与实际(who 正在录)分开写:两者不一致时用户最需要知道。
  ///
  /// **整格都是热区**(owner 2026-09-21):原来只有那颗 14pt 的 `mic.fill` 是 Menu 的 label,
  /// 格子仍按 railItem 整格画悬停底,点在高亮区里却不出菜单——同一条轨上的
  /// 点名 / 章节 / 转写(都是 `RailButton`)是整格可点的,只有这一格例外。
  /// 图标与状态字一起做 label,并借用 `RailButton` 的悬停画法(scrim + Radius.md);
  /// 之前那句 `hoverRowBackground()` 用的是 `line2` + 圆角 8,和邻居也对不上。
  private var microphoneIndicator: some View {
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
        Text("✓ \(name ?? "首选麦克风")（\(state)）")
      }
    } label: {
      VStack(spacing: Tokens.V1.Space.s2xs) {
        Image(systemName: "mic.fill")
          .font(.system(size: Tokens.V1.Size.railIcon))
          .accessibilityHidden(true)
        Text(microphoneStatusLabel)
          .font(Tokens.V1.Text.micro.font)
          .multilineTextAlignment(.center)
          .lineLimit(1)
          .runtimeAccessibilityIdentifier("cockpit.rail.mic.status")
        // 设备名**不**在这里加第三行:轨格固定 48×44(图标 + 一行状态已占满),
        // 再塞一行会被裁切,本机渲染验证里 OCR 直接读不到字。
        // 「用哪台」放在菜单里的「正在使用」标记 + 悬停提示 + 无障碍标签三处。
      }
      .foregroundStyle(Tokens.V1.Color.ink2)
      .frame(width: Tokens.V1.Size.railItem.width, height: Tokens.V1.Size.railItem.height)
      .background(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
          .fill(isMicrophoneHovering ? Tokens.V1.Color.scrim : .clear)
      )
      .contentShape(Rectangle())
      .onHover { isMicrophoneHovering = $0 }
      .animation(
        reduceMotion ? nil : .easeOut(duration: Tokens.V1.Motion.fast),
        value: isMicrophoneHovering)
    }
    // 不用 `.borderlessButton`:那个样式把 label 摊成一条横排(图标与状态字并排),
    // 还会撑破 rail 宽。默认样式 + `.buttonStyle(.plain)` 保留 VStack 的竖排。
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .tint(Tokens.V1.Color.ink2)
    .disabled(recordingSession.phase == .stopping)
    .help([recordingSession.microphoneInputStatus.text, recordingSession.microphoneInputStatus.notice]
      .compactMap { $0 }.joined(separator: "\n"))
    .accessibilityLabel("麦克风输入，\(recordingSession.microphoneInputStatus.text)")
    .runtimeAccessibilityIdentifier("cockpit.rail.mic.menu")
    .runtimeAccessibilityIdentifier("cockpit.rail.mic")
  }

  private var microphoneStatusLabel: String {
    switch recordingSession.microphoneInputStatus {
    case .idle: return "待开录"
    case .pending: return "切换中"
    case .active: return "使用中"
    case .unready: return "未就绪"
    }
  }

  /// 每一项写两件事:你的**选择**(偏好,行首 ✓)和**实况**(这台是不是正在录/正在切)。
  /// 2026-10-20 owner:「我根本不知道选择了什么 mic」——原来这两种信息都只能靠悬停提示。
  private func microphoneChoice(_ preference: MicrophoneInputPreference, title: String) -> some View
  {
    let selected = isSelected(preference)
    let live = liveMark(for: preference)
    return Button {
      recordingSession.selectMicrophoneInput(preference)
    } label: {
      Text((selected ? "✓ " : "") + title + (live.map { "（\($0)）" } ?? ""))
    }
  }

  /// 意图选中:偏好等于这一项。
  private func isSelected(_ preference: MicrophoneInputPreference) -> Bool {
    switch (preference, recordingSession.microphoneInputPreference) {
    case (.automatic, .automatic): return true
    case (.device(let uid, _), .device(let selected, _)): return uid == selected
    default: return false
    }
  }

  /// 实况标记:正在录制这一路时写「正在使用」,切过去的等待期写「切换中」,
  /// 其余不写。「正在使用」取**已确认的绑定**,不是偏好——意图和事实必须分开。
  private func liveMark(for preference: MicrophoneInputPreference) -> String? {
    switch recordingSession.microphoneInputStatus {
    case .active(let binding, _):
      switch preference {
      case .device(let uid, _): return binding.device.uid == uid ? "正在使用" : nil
      case .automatic: return nil
      }
    case .pending(let target):
      switch preference {
      case .device(let uid, _): return target.device.uid == uid ? "切换中" : nil
      case .automatic: return nil
      }
    case .idle, .unready:
      return nil
    }
  }

  // MARK: - 会话开关

  /// 点名提醒。菜单内容与会议库顶栏那颗完全相同,只是外面那层换成轨上的一格。
  @ViewBuilder
  private var nameAlertSlot: some View {
    NameAlertToolbarMenu(
      preferences: nameAlertPreferences,
      session: nameAlertSession,
      placement: .rail,
      onOpenSettings: onOpenSettings
    )
    .runtimeAccessibilityIdentifier("cockpit.rail.name-alerts")
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

}

/// 会话图标与主导航共用 v1 轨格、前景和选中背景。
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
      VStack(spacing: Tokens.V1.Space.s2xs) {
        Image(systemName: systemImage)
          .font(.system(size: Tokens.V1.Size.railIcon, weight: .regular))
          .accessibilityHidden(true)
        Text(label)
          .font(Tokens.V1.Text.micro.font)
          .lineLimit(1)
      }
      .foregroundStyle(foreground)
      .frame(width: Tokens.V1.Size.railItem.width, height: Tokens.V1.Size.railItem.height)
      .background(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
          .fill(background)
      )
      .overlay(alignment: .topTrailing) {
        if let statusDotIdentifier {
          Circle()
            .fill(Tokens.V1.Color.warn)
            .frame(width: Tokens.V1.Space.xs, height: Tokens.V1.Space.xs)
            .overlay(Circle().stroke(Tokens.V1.Color.rail, lineWidth: Tokens.V1.Size.focusWidth))
            .padding(.top, Tokens.V1.Space.s2xs)
            .padding(.trailing, Tokens.V1.Space.xs)
            .accessibilityHidden(true)
            .runtimeAccessibilityIdentifier(statusDotIdentifier)
        }
      }
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.V1.Motion.fast), value: isHovering)
    }
    .buttonStyle(.plain)
  }

  private var foreground: Color {
    Tokens.V1.Color.ink2.opacity(isEnabled ? 1 : Tokens.V1.Feedback.disabledOpacity)
  }

  private var background: Color {
    if !isEnabled { return .clear }
    if isOn { return Tokens.V1.Color.paper3 }
    return isHovering ? Tokens.V1.Color.scrim : .clear
  }
}

/// 录制块内的麦克风电平：正常用 v1 ok，暂停时显示 warn 短杠。
struct MicLevelBar: View {
  let level: Float
  var isPaused = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Tokens.V1.Color.rule)
        Capsule()
          .fill(isPaused ? Tokens.V1.Color.warn : Tokens.V1.Color.ok)
          .frame(width: geometry.size.width * (isPaused ? 1 : CGFloat(min(max(level, 0), 1))))
          .animation(reduceMotion ? nil : .linear(duration: Tokens.V1.Motion.fast), value: level)
      }
    }
    .frame(width: Tokens.V1.Size.control, height: Tokens.V1.Space.s2xs)
    .accessibilityHidden(true)
  }
}
