import JustSaidCore
import SwiftUI

/// 右栏页签(10-09 实验性)。默认「记录」,之后记住上次用的。
enum MeetingQASidebarTab: String {
  case records
  case qa
}

/// 驾驶舱交给问答的东西。nil = 这处不出问答(验证夹具、非会中)。
struct MeetingQAHost {
  let settings: ProviderSettingsStore
  let meetingDirectory: URL?
  let startedAt: Date?
  let onOpenMeeting: (URL) -> Void
}

/// 右栏整栏页签「记录 / 问答」。「记录」就是原来的替你记与补充记录,原样传进来。
/// 设计稿:`docs/design-system/screens/live-qa.html`,规格见设计系统 README「会中问答」。
struct MeetingQASidebar<Records: View>: View {
  let host: MeetingQAHost
  let segments: [TranscriptSegment]
  let topics: [SummaryTopic]
  let actionItemCount: Int
  let onJumpToTranscript: (TimeInterval) -> Void
  @ViewBuilder let records: () -> Records

  @ObservedObject private var controller: MeetingQAController
  @AppStorage(MeetingQASettings.sidebarTabDefaultsKey) private var tabRaw =
    MeetingQASidebarTab.records.rawValue
  /// 问答页期间替你记变多就亮,切回「记录」清掉。
  @State private var hasNewRecords = false
  @State private var seenActionItemCount = 0

  init(
    host: MeetingQAHost, segments: [TranscriptSegment], topics: [SummaryTopic],
    actionItemCount: Int, onJumpToTranscript: @escaping (TimeInterval) -> Void,
    @ViewBuilder records: @escaping () -> Records
  ) {
    self.host = host
    self.segments = segments
    self.topics = topics
    self.actionItemCount = actionItemCount
    self.onJumpToTranscript = onJumpToTranscript
    self.records = records
    _controller = ObservedObject(
      wrappedValue: MeetingQAControllerRegistry.shared.controller(for: host.meetingDirectory))
  }

  private var tab: MeetingQASidebarTab { MeetingQASidebarTab(rawValue: tabRaw) ?? .records }

  var body: some View {
    VStack(spacing: 0) {
      tabRow
      switch tab {
      case .records:
        records()
      case .qa:
        MeetingQAPaneView(
          controller: controller,
          snapshot: snapshot,
          host: host,
          onJumpToTranscript: onJumpToTranscript)
      }
    }
    .onAppear {
      seenActionItemCount = actionItemCount
      MeetingQAControllerRegistry.shared.consumePendingFocus(into: controller)
    }
    .onChange(of: actionItemCount) { _, count in
      if tab == .qa, count > seenActionItemCount { hasNewRecords = true }
      if tab == .records { seenActionItemCount = count }
    }
    .onChange(of: tabRaw) { _, _ in
      if tab == .records {
        hasNewRecords = false
        seenActionItemCount = actionItemCount
      }
    }
    .runtimeAccessibilityIdentifier("dashboard.meeting-qa.sidebar")
  }

  private var snapshot: () -> MeetingQASnapshot {
    let segments = segments
    let topics = topics
    let host = host
    return {
      MeetingQASnapshot(
        segments: segments, topics: topics, meetingDirectory: host.meetingDirectory,
        startedAt: host.startedAt)
    }
  }

  private var tabRow: some View {
    HStack(spacing: Tokens.V1.Space.md) {
      tabButton(.records, title: "记录", showsDot: hasNewRecords)
      tabButton(.qa, title: "问答", showsDot: false)
      Spacer(minLength: 0)
      if tab == .qa {
        Button("新问题") { controller.reset(snapshot: snapshot()) }
          .buttonStyle(.v1Quiet.height(Tokens.V1.Size.controlSm))
          .disabled(!controller.hasTurns || controller.isAnswering)
          .help("之后的提问不再带上前面的问答")
          .runtimeAccessibilityIdentifier("dashboard.meeting-qa.reset")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.sm)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
  }

  private func tabButton(_ value: MeetingQASidebarTab, title: String, showsDot: Bool)
    -> some View
  {
    let isSelected = tab == value
    return Button {
      tabRaw = value.rawValue
    } label: {
      HStack(spacing: Tokens.V1.Space.s2xs) {
        Text(title)
        if showsDot {
          Circle().fill(Tokens.V1.Color.accent)
            .frame(width: Tokens.V1.Space.xs, height: Tokens.V1.Space.xs)
            .accessibilityLabel("有新内容")
        }
      }
      .font(isSelected ? Tokens.V1.Text.strong.font : Tokens.V1.Text.label.font)
      .foregroundStyle(isSelected ? Tokens.V1.Color.ink : Tokens.V1.Color.ink3)
      .lineLimit(1)
      .padding(.vertical, Tokens.V1.Space.xs)
      .overlay(alignment: .bottom) {
        Rectangle().fill(isSelected ? Tokens.V1.Color.ink : .clear)
          .frame(height: Tokens.V1.Size.focusWidth)
      }
    }
    .buttonStyle(.v1Quiet)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .runtimeAccessibilityIdentifier("dashboard.meeting-qa.tab.\(value.rawValue)")
  }
}

/// 问答页:线程(问题靠右的气泡、回答左侧通栏)+ 底部输入框。
struct MeetingQAPaneView: View {
  @ObservedObject var controller: MeetingQAController
  let snapshot: () -> MeetingQASnapshot
  let host: MeetingQAHost
  let onJumpToTranscript: (TimeInterval) -> Void

  @FocusState private var inputFocused: Bool

  private static let examples = ["刚才定了哪几件事？", "上次会上这件事怎么说的？"]

  var body: some View {
    VStack(spacing: 0) {
      if controller.items.isEmpty {
        emptyState
      } else {
        thread
      }
      composer
    }
    .onAppear { if controller.focusToken > 0 { inputFocused = true } }
    .onChange(of: controller.focusToken) { _, _ in inputFocused = true }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      Spacer(minLength: 0)
      Text("只根据这场会、同项目之前的会和通用知识回答。")
        .font(Tokens.V1.Text.body.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: Tokens.V1.Space.s2xs) {
        ForEach(Self.examples, id: \.self) { example in
          Button {
            controller.draft = example
            inputFocused = true
          } label: {
            Text(example)
              .font(Tokens.V1.Text.micro.font)
              .foregroundStyle(Tokens.V1.Color.ink2)
              .lineLimit(1)
              .padding(.horizontal, Tokens.V1.Space.xs)
              .padding(.vertical, Tokens.V1.Space.s3xs)
              .overlay(
                Capsule().strokeBorder(
                  Tokens.V1.Color.controlRule, lineWidth: Tokens.V1.Size.controlRuleWidth))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(Tokens.V1.Space.sm)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
  }

  private var thread: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
          ForEach(controller.items) { item in
            switch item {
            case .turn(let turn):
              turnView(turn).id(turn.id)
            case .divider(let id):
              divider.id(id)
            }
          }
        }
        .padding(Tokens.V1.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // 新的一问在最下面;内容不满一屏时贴底。
      .defaultScrollAnchor(.bottom)
      .onChange(of: controller.items) { _, items in
        guard let last = items.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
      }
      .accessibilityLabel("本场问答")
      .runtimeAccessibilityIdentifier("dashboard.meeting-qa.thread")
    }
  }

  private var divider: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
      Text("新问题")
        .font(Tokens.V1.Text.micro.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .fixedSize()
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
  }

  private func turnView(_ turn: MeetingQATurn) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      question(turn)
      answer(turn)
    }
  }

  private func question(_ turn: MeetingQATurn) -> some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: Tokens.V1.Space.s3xs) {
        Text(turn.question)
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.accentInk)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Tokens.V1.Space.sm)
          .padding(.vertical, Tokens.V1.Space.s2xs)
          .background(
            UnevenRoundedRectangle(
              topLeadingRadius: Tokens.V1.Radius.lg, bottomLeadingRadius: Tokens.V1.Radius.lg,
              bottomTrailingRadius: Tokens.V1.Radius.xs, topTrailingRadius: Tokens.V1.Radius.lg
            )
            .fill(Tokens.V1.Color.accent))
        Text(MeetingQATimeLabel.format(turn.askedAt))
          .font(Tokens.V1.Text.timecode.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
      }
      // 气泡最宽为栏内宽的 84%。
      .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.84 }
    }
  }

  @ViewBuilder
  private func answer(_ turn: MeetingQATurn) -> some View {
    switch turn.state {
    case .answering(let partial):
      // 流式写出时末尾一枚墨青块形光标(与纪要生成中的光标同一写法)。
      (Text(partial) + Text("▌").foregroundStyle(Tokens.V1.Color.accent))
        .font(Tokens.V1.Text.body.font)
        .foregroundStyle(partial.hasPrefix("会里没提到") ? Tokens.V1.Color.ink3 : Tokens.V1.Color.ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(partial.isEmpty ? "正在回答" : partial)
    case .answered(let answer):
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
        answerText(answer.body.isEmpty ? "（模型没有给出正文）" : answer.body)
        if !answer.sources.isEmpty {
          sourceChips(answer.sources)
        }
      }
    case .failed(let advice, let message):
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        if let advice {
          LLMRecoveryNotice(
            advice: advice,
            paths: host.meetingDirectory.map(MeetingPaths.init(directory:)),
            affectedArea: "这一问没有答完")
        } else {
          Text(message)
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.warn)
            .fixedSize(horizontal: false, vertical: true)
        }
        Button("重试") {
          controller.retry(turnID: turn.id, snapshot: snapshot(), settings: host.settings)
        }
        .buttonStyle(.v1Outline.height(Tokens.V1.Size.controlSm))
        .disabled(controller.isAnswering)
        .runtimeAccessibilityIdentifier("dashboard.meeting-qa.retry")
      }
    }
  }

  private func answerText(_ text: String) -> some View {
    let isMiss = text.hasPrefix("会里没提到")
    return Text(text)
      .font(Tokens.V1.Text.body.font)
      .foregroundStyle(isMiss ? Tokens.V1.Color.ink3 : Tokens.V1.Color.ink)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sourceChips(_ sources: [MeetingQASource]) -> some View {
    // 胶囊不折行;放不下时整行换到下一行由 ViewThatFits 退成竖排。
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Tokens.V1.Space.s2xs) { chips(sources) }
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) { chips(sources) }
    }
  }

  @ViewBuilder
  private func chips(_ sources: [MeetingQASource]) -> some View {
    ForEach(sources, id: \.self) { source in
      switch source {
      case .thisMeeting(let seconds):
        Button {
          onJumpToTranscript(seconds)
        } label: {
          HStack(spacing: Tokens.V1.Space.s2xs) {
            Text("本场")
            Text(MeetingQATimeLabel.format(seconds)).font(Tokens.V1.Text.timecode.font)
          }
          .modifier(
            MeetingQAChip(background: Tokens.V1.Color.accentSoft, foreground: Tokens.V1.Color.accent))
        }
        .buttonStyle(.plain)
        .help("跳到转写原话")
      case .pastMeeting(let meeting):
        Button {
          host.onOpenMeeting(meeting.directory)
        } label: {
          Text("\(Self.dayLabel(meeting.startedAt)) \(meeting.title)")
            .truncationMode(.tail)
            .modifier(
              MeetingQAChip(background: Tokens.V1.Color.paper3, foreground: Tokens.V1.Color.ink2))
        }
        .buttonStyle(.plain)
        .help("打开这场会")
      case .generalKnowledge:
        Text("通用知识")
          .modifier(
            MeetingQAChip(background: Tokens.V1.Color.warnSoft, foreground: Tokens.V1.Color.warn))
          .help("这一条不是会上说的")
      }
    }
  }

  private static func dayLabel(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.month, .day], from: date)
    return "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
  }

  private var composer: some View {
    TextField(
      "问这场会，或同项目之前的会", text: $controller.draft,
      prompt: Text("问这场会，或同项目之前的会").foregroundColor(Tokens.V1.Color.ink3),
      axis: .vertical
    )
    .textFieldStyle(.plain)
    .font(Tokens.V1.Text.body.font)
    .foregroundStyle(Tokens.V1.Color.ink)
    .lineLimit(1...4)
    .padding(.horizontal, Tokens.V1.Space.sm)
    .padding(.vertical, Tokens.V1.Space.xs)
    .frame(maxWidth: .infinity, minHeight: Tokens.V1.Size.control, alignment: .leading)
    .focused($inputFocused)
    .modifier(V1FormSurface(focused: inputFocused))
    .onSubmit { controller.submitDraft(snapshot: snapshot(), settings: host.settings) }
    .help(controller.isAnswering ? "这一问答完后才能接着问" : "回车提问")
    .accessibilityLabel("问这场会，或同项目之前的会")
    .runtimeAccessibilityIdentifier("dashboard.meeting-qa.input")
    .padding(Tokens.V1.Space.sm)
    .overlay(alignment: .top) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
  }
}

/// 来源胶囊:`radius-pill`、`type-micro`、不折行;颜色只表示来源。
private struct MeetingQAChip: ViewModifier {
  let background: Color
  let foreground: Color

  func body(content: Content) -> some View {
    content
      .font(Tokens.V1.Text.micro.font)
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, Tokens.V1.Space.xs)
      .padding(.vertical, Tokens.V1.Space.s3xs)
      .background(Capsule().fill(background))
  }
}
