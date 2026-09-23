import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

// 2026-08-20 批3 拆分:自 MeetingLibraryView.swift 按 MARK 边界机械迁出,零行为变更。
// MARK: - 会议名称

struct EditableMeetingTitle: View {
  let id: String
  let title: String
  let focus: FocusState<String?>.Binding
  let onCommit: (String) -> String

  @State private var draft: String
  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  init(
    id: String,
    title: String,
    focus: FocusState<String?>.Binding,
    onCommit: @escaping (String) -> String
  ) {
    self.id = id
    self.title = title
    self.focus = focus
    self.onCommit = onCommit
    _draft = State(initialValue: title)
  }

  var body: some View {
    HStack(spacing: Tokens.V1.Space.s2xs) {
      TextField("会议名称", text: $draft)
        .textFieldStyle(.plain)
        .lineLimit(1)
        .font(.system(size: Tokens.V1.Text.barTitle.size, weight: .semibold))
        .foregroundStyle(Tokens.V1.Color.ink)
        .focused(focus, equals: id)
        .onSubmit { commit() }
        .onChange(of: focus.wrappedValue) { previous, current in
          if previous == id && current != id {
            commit()
          }
        }
        .onChange(of: title) { _, newTitle in
          if !isFocused {
            draft = newTitle
          }
        }
        .runtimeAccessibilityIdentifier("library.meeting-title")
      Image(systemName: "pencil")
        .font(.system(size: Tokens.V1.Text.meta.size, weight: .semibold))
        .foregroundStyle(Tokens.V1.Color.ink3)
        .opacity(isHovering || isFocused ? 1 : 0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
    .background(
      RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
        .fill(isHovering || isFocused ? Tokens.V1.Color.paper2 : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: Tokens.V1.Motion.fast), value: isHovering)
    .help("单击编辑会议名称")
  }

  private var isFocused: Bool {
    focus.wrappedValue == id
  }

  private func commit() {
    draft = onCommit(draft)
  }
}

// MARK: - 客户/项目标签(08-17 R-b)

/// 标签 chip 的界面词(内部枚举归 Model 层,界面词与标识收在 View 层)。
extension MeetingTagKind {
  fileprivate var displayLabel: String {
    switch self {
    case .client: return "客户"
    case .project: return "项目"
    }
  }

  fileprivate var symbolName: String {
    switch self {
    case .client: return "building.2"
    case .project: return "folder"
    }
  }

  fileprivate var chipIdentifier: String {
    switch self {
    case .client: return "library.detail.tag.client"
    case .project: return "library.detail.tag.project"
    }
  }
}

/// Meeting tags use the same searchable directory and visible affordance as todo forms.
struct EditableTagChip: View {
  let kind: MeetingTagKind
  let value: String?
  var client = ""
  @ObservedObject var directory = ClientProjectDirectory()
  let onCommit: (String) -> Void

  var body: some View {
    V1ComboBox(
      label: kind.displayLabel, value: value ?? "",
      suggestions: kind == .client ? directory.clients : directory.projects(for: client),
      size: .compact, identifier: kind.chipIdentifier, onSelect: onCommit
    )
    .frame(maxWidth: Tokens.V1.Size.panelWidth)
  }
}

// MARK: - 单段更正的「新名字…」

/// 右键选了「新名字…」之后就地弹出的一格输入。回车提交、Esc 或点「取消」放弃。
///
/// 名单里没有的人(会中途进来、或 ASR 从头到尾就没分出他)只能靠这一格补进来;
/// 提交后这个名字会自动出现在其他段落的右键候选里——它已经是这场会的说话人之一了。
struct NewSpeakerNameField: View {
  let line: TranscriptSpeechLine
  let onCommit: (String) -> Void
  let onCancel: () -> Void

  @State private var draft = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      Text("[\(line.timestamp)] 这段的说话人是")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
      TextField("真名", text: $draft)
        .textFieldStyle(.plain)
        .font(.system(size: Tokens.FontSize.uiEmphasis))
        .frame(width: 110)
        .focused($isFocused)
        .onSubmit { commit() }
        .onKeyPress(.escape) {
          onCancel()
          return .handled
        }
        .padding(.horizontal, Tokens.Spacing.xsm)
        .padding(.vertical, Tokens.Spacing.xxs)
        .background(Tokens.Color.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .stroke(isFocused ? Tokens.Color.ac : Tokens.Color.line, lineWidth: 1)
        )
        .accessibilityLabel("给这一段填写说话人真名")
      Button("确定") { commit() }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("取消", action: onCancel)
      Spacer(minLength: 0)
    }
    .buttonStyle(.textAction)
    .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
    .foregroundStyle(Tokens.Color.acDeep)
    .onAppear { isFocused = true }
  }

  private func commit() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      onCancel()
      return
    }
    onCommit(trimmed)
  }
}

// MARK: - 说话人声道来源提示

/// 发言人声道来源副提示(08-14 展示半单,数据层 commit 6f67205):
/// 告诉用户这个**转写标签**的语音主要来自本侧麦克风还是远端系统声,辅助归并/排除决策。
/// 纯提示——不改写发言人身份、不做自动归并(「来源≠身份」红线)。
public enum SpeakerChannelHint {
  /// 三态。双单声道回退路径两任务同号折叠时,同一标签在两路都有时长,「混合」是真实态。
  public enum Kind: String, Sendable {
    case microphoneDominant = "mic-dominant"
    case systemDominant = "system-dominant"
    case mixed = "mixed"
  }

  /// 一个 chip 副提示的呈现:文案 + .help 解释 + 带态后缀的运行时探针标识
  /// (三态可分别断言,参照 `library.row.<transcription|minutes>.<state>` 先例)。
  public struct Presentation: Equatable, Sendable {
    public let text: String
    public let help: String
    public let probeIdentifier: String
  }

  /// 三态判定。阈值取 2:1 时间占比(≥2/3 判本侧为主、≤1/3 判远端为主),不用 50% 中点:
  /// 一句话在另一路漏识别就足以让 51%/49% 横跳,2:1 才配叫「为主」;
  /// 整数比阈值也便于向用户口头解释。stats 缺失(旧会议)或总时长为 0 都返回 nil = 不渲染。
  public static func presentation(for stats: SpeakerChannelStats?) -> Presentation? {
    guard let share = stats?.microphoneShare else { return nil }
    let kind: Kind
    if share >= 2.0 / 3.0 {
      kind = .microphoneDominant
    } else if share <= 1.0 / 3.0 {
      kind = .systemDominant
    } else {
      kind = .mixed
    }
    return Presentation(
      text: text(for: kind),
      help: help(for: kind),
      probeIdentifier: "library.speaker-chip.channel-hint." + kind.rawValue
    )
  }

  private static func text(for kind: Kind) -> String {
    switch kind {
    case .microphoneDominant: return "· 本侧为主"
    case .systemDominant: return "· 远端为主"
    case .mixed: return "· 混合"
    }
  }

  private static func help(for kind: Kind) -> String {
    switch kind {
    case .microphoneDominant:
      return "这个标签的发言时长大部分来自本侧麦克风(仅提示，不影响归并)"
    case .systemDominant:
      return "这个标签的发言时长大部分来自远端系统声(仅提示，不影响归并)"
    case .mixed:
      return "这个标签在本侧麦克风与远端系统声上的发言时长接近(仅提示，不影响归并)"
    }
  }
}

// MARK: - 说话人输入框

/// 一个「发言人 N」对应一个内联输入框:失焦或回车即写回 `meeting.json`。
///
/// 每个框自持焦点状态,而不是整行共用一个:共用的话得在焦点跳转时反推「刚才离开的是哪个框」,
/// 多写一层账、还容易把名字记到隔壁人头上。
struct SpeakerNameField: View {
  let label: String
  let name: String
  /// 高亮通读态(08-14 chip 交互单):label 单击进/出高亮,高亮中 chip 用 ac 描边 +
  /// acSoft 底作信号色。只占 chrome 不重排文字,与排除态(0.6 透明度+灰阶徽章)可共存。
  var isHighlighted: Bool = false
  var onToggleHighlight: (() -> Void)? = nil
  /// 排除态(08-14,纯增量):整体排除的说话人降透明度 + 「不参会」灰阶徽章,
  /// 右键给「恢复」。只占灰阶不占色相,方便发言人高亮叠加。
  var isExcluded: Bool = false
  var onToggleExcluded: (() -> Void)? = nil
  /// 「只看」入口(右键第二动作);nil = 不显示该项。
  var onFilter: (() -> Void)? = nil
  /// 声道来源副提示(08-14);nil = 无统计/零时长,不渲染。显隐判定收在本视图内部,
  /// 调用点无条件传入计算结果(红线 6)。
  var channelHint: SpeakerChannelHint.Presentation? = nil
  let onCommit: (String) -> Void

  @State private var draft: String
  /// 只有用户自己敲过的草稿才允许提交。
  ///
  /// 没有这一位会丢数据:面板打开时焦点自动落在第一个输入框,此时采纳一条认名建议,
  /// 外部同步被 `if !isFocused` 挡住,草稿仍是空串;关面板失焦触发 `onCommit("")`,
  /// 把刚写进 meeting.json 的名字清掉(owner 2026-09-20 实拍:计数 5 退回 7、
  /// 正文仍是「发言人 1」、meeting.json 的 speakerNames 从有值变回 None)。
  @State private var userDidEdit = false
  @FocusState private var isFocused: Bool

  init(
    label: String,
    name: String,
    isHighlighted: Bool = false,
    isExcluded: Bool = false,
    channelHint: SpeakerChannelHint.Presentation? = nil,
    onToggleHighlight: (() -> Void)? = nil,
    onToggleExcluded: (() -> Void)? = nil,
    onFilter: (() -> Void)? = nil,
    onCommit: @escaping (String) -> Void
  ) {
    self.label = label
    self.name = name
    self.isHighlighted = isHighlighted
    self.isExcluded = isExcluded
    self.channelHint = channelHint
    self.onToggleHighlight = onToggleHighlight
    self.onToggleExcluded = onToggleExcluded
    self.onFilter = onFilter
    self.onCommit = onCommit
    _draft = State(initialValue: name)
  }

  var body: some View {
    // 标识只在高亮中的 chip 上挂(空串会给每个 chip 都塞一个探针占位视图)。
    if isHighlighted {
      chip.runtimeAccessibilityIdentifier("library.speaker-chip.highlighted")
    } else {
      chip
    }
  }

  private var chip: some View {
    HStack(spacing: Tokens.Spacing.xxs) {
      // 右键菜单只挂标签一侧:挂在整个 chip 上会吃掉 TextField 的编辑菜单
      // (剪切/拷贝/粘贴),那是既有交互,不能动。
      HStack(spacing: Tokens.Spacing.xxs) {
        // 单击 label = 高亮通读(主路径);悬停态走 textAction 的下划线纪律。
        // 热区刻意只包 label,TextField 的失焦/回车改名行为零变化。
        if let onToggleHighlight {
          Button(action: onToggleHighlight) {
            Text(label)
              .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
              .foregroundStyle(Tokens.Color.others)
              .contentShape(Rectangle())
          }
          .buttonStyle(.textAction)
          .help("单击高亮此人的发言并逐处跳转，再点一次退出；右键可「只看」")
          .accessibilityLabel(
            isHighlighted ? "退出对「\(label)」的高亮" : "高亮「\(label)」的发言"
          )
        } else {
          Text(label)
            .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
            .foregroundStyle(Tokens.Color.others)
        }
        if isExcluded {
          Text("不参会")
            .font(.system(size: Tokens.FontSize.micro, weight: .semibold))
            .foregroundStyle(Tokens.Color.ink4)
            .padding(.horizontal, Tokens.Spacing.xxs)
            .padding(.vertical, Tokens.Spacing.hairline)
            .overlay(Capsule().stroke(Tokens.Color.line, lineWidth: 1))
            .runtimeAccessibilityIdentifier("library.speaker-chip.excluded")
        }
      }
      .contentShape(Rectangle())
      .contextMenu {
        if let onFilter {
          Button("只看「\(displayName)」的发言") {
            onFilter()
          }
        }
        if let onToggleExcluded {
          Button(isExcluded ? "恢复此人的纪要参与" : "此人不参会，整体排除") {
            onToggleExcluded()
          }
        }
      }
      // 声道来源副提示(08-14):挂在 label 一侧的小字,样式与「不参会」徽章同档(ink4 小字),
      // 不抢改名框的戏;不进右键菜单热区,既有交互零变化。nil(旧会议无统计)整条不渲染。
      if let channelHint {
        Text(channelHint.text)
          .font(.system(size: Tokens.FontSize.micro))
          .foregroundStyle(Tokens.Color.ink4)
          .help(channelHint.help)
          .runtimeAccessibilityIdentifier(channelHint.probeIdentifier)
      }
      TextField("填真名", text: $draft)
        .textFieldStyle(.plain)
        .font(.system(size: Tokens.FontSize.uiEmphasis))
        .frame(width: 88)
        .focused($isFocused)
        .onChange(of: draft) { _, _ in
          if isFocused { userDidEdit = true }
        }
        .onSubmit { commitDraft() }
        .onChange(of: isFocused) { _, focused in
          if !focused { commitDraft() }
        }
        .accessibilityLabel("给\(label)填写真名")
    }
    .padding(.horizontal, Tokens.Spacing.xsm)
    .padding(.vertical, Tokens.Spacing.xxs)
    .background(
      Tokens.Color.card,
      in: RoundedRectangle(cornerRadius: Tokens.Radius.control)
    )
    .background {
      if isHighlighted {
        RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(Tokens.Color.acSoft)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.control)
        .stroke(
          isFocused || isHighlighted ? Tokens.Color.ac : Tokens.Color.line,
          lineWidth: 1
        )
    )
    .opacity(isExcluded ? 0.6 : 1)
    // 外部改名(换了一场会、采纳了认名建议、单段更正回写)一律把草稿拉回真值。
    // 这里不再看有没有焦点——原来带 `if !isFocused` 守卫,而面板打开时焦点正好
    // 落在第一个输入框上,于是采纳的名字同步不进来,失焦又被空草稿写回去。
    // 用户自己敲过的不覆盖,由 `userDidEdit` 判。
    .onChange(of: name) { _, newValue in
      guard !userDidEdit else { return }
      draft = newValue
    }
  }

  /// 提交:只有用户自己改过才写。没改过就把草稿对回真值,绝不拿一个没同步过的
  /// 空草稿去清掉已经存好的名字。
  private func commitDraft() {
    guard userDidEdit else {
      draft = name
      return
    }
    onCommit(draft)
    userDidEdit = false
  }

  /// 右键菜单里按显示名说人话(填过真名就用真名),桶口径与单击高亮一致。
  private var displayName: String {
    name.isEmpty ? label : name
  }
}
