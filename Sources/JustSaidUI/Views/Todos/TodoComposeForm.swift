import JustSaidCore
import SwiftUI

/// 会议原话：表单「来源与事项」组里的一行引用。手工新增没有来源。
struct TodoComposeSource {
  var text: String
  var anchor: String?
  var missingContext: Bool
  var identifier: String
}

/// 两处沿用各自原有的无障碍标识，验证场景按标识找控件。
struct TodoComposeIdentifiers {
  var title: String
  var assignee: String
  var due: String
  var priority: String
  var client: String
  var project: String
  var note: String

  static func meeting(_ id: UUID) -> Self {
    let suffix = id.uuidString
    return Self(
      title: "meeting.clean.title.\(suffix)", assignee: "meeting.clean.assignee.\(suffix)",
      due: "meeting.clean.due.\(suffix)", priority: "meeting.clean.priority.\(suffix)",
      client: "meeting.clean.client.\(suffix)", project: "meeting.clean.project.\(suffix)",
      note: "meeting.clean.note.\(suffix)")
  }

  static let newTodo = Self(
    title: "todos.editor.title", assignee: "todos.editor.assignee", due: "todos.editor.due",
    priority: "todos.editor.priority", client: "todos.editor.client",
    project: "todos.editor.project", note: "todos.editor.note")
}

/// 「加入待办表单」（docs/design-system README › 我的待办 › 加入待办表单）。
/// 会议右栏「加入待办」与我的待办「新增待办」共用；容器只管顶栏、滚动和确认条。
/// 会议独有的部分（歧义日期、负责人冲突、取消这一条、旧勾选的完成状态）由调用方从插槽传入。
struct TodoComposeForm<SourceAccessory: View, Followup: View, Trailing: View>: View {
  @Binding var draft: TodoEditorDraft
  @Binding var due: TodoDue
  var source: TodoComposeSource?
  var onJump: ((TimeInterval) -> Void)?
  var identifiers: TodoComposeIdentifiers
  var assigneeSuggestions: [String]
  var clients: [String]
  var projects: [String]
  var onSelectClient: (String) -> Void
  var onSelectProject: (String) -> Void
  var now: Date
  var dueHint: String?
  var dueBasis: TodoDeadlineBasis?
  var focusTitle = false
  /// 会议里说的负责人：在负责人列表里标「会议里说的」。
  var spokenAssignee: String?
  /// 在负责人框里亲手选了或新建了名字之后调用（会议里据此视为已确认，不再追问冲突）。
  var onAssigneeChosen: () -> Void = {}
  @ViewBuilder var sourceAccessory: () -> SourceAccessory
  @ViewBuilder var followup: () -> Followup
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      TodoComposeGroup(source == nil ? "事项" : "来源与事项", accessory: sourceAccessory) {
        if let source { sourceLine(source) }
        V1TextField(
          placeholder: "写下要跟进的事", text: $draft.title, multiline: true, minimumLines: 2,
          focusRequested: focusTitle, identifier: identifiers.title)
      }
      TodoComposeGroup("执行与归属") {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
          HStack(alignment: .top, spacing: Tokens.V1.Space.sm) {
            TodoComposeField("负责人") {
              TodoAssigneeComboBox(
                draft: $draft, suggestions: assigneeSuggestions,
                details: spokenAssignee.map { [$0: "会议里说的"] } ?? [:],
                identifier: identifiers.assignee, onCommit: onAssigneeChosen)
            }
            TodoComposeField("截止") {
              TodoDeadlinePicker(
                due: $due, now: now, timeZoneIdentifier: draft.timeZoneIdentifier,
                identifier: identifiers.due, basis: dueBasis)
              if let dueHint {
                Text(dueHint)
                  .font(Tokens.V1.Text.meta.font)
                  .foregroundStyle(Tokens.V1.Color.ink3)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          followup()
          TodoComposeField("优先级") {
            V1SegmentedPicker(
              "优先级", selection: $draft.priority,
              options: [TodoPriority.high, .normal, .low].map { .init($0, TodoText.priority($0)) },
              fills: true,
              optionIdentifier: { "\(identifiers.priority).\($0.rawValue)" }
            )
            .runtimeAccessibilityIdentifier(identifiers.priority)
          }
          HStack(alignment: .top, spacing: Tokens.V1.Space.sm) {
            TodoComposeField("客户") {
              V1ComboBox(
                label: "客户", value: draft.client, suggestions: clients,
                identifier: identifiers.client, onSelect: onSelectClient)
            }
            TodoComposeField("项目") {
              V1ComboBox(
                label: "项目", value: draft.project, suggestions: projects,
                identifier: identifiers.project, onSelect: onSelectProject)
            }
          }
        }
      }
      TodoComposeField("备注") {
        V1TextField(
          placeholder: "添加备注", text: $draft.note, multiline: true, minimumLines: 3,
          identifier: identifiers.note)
      }
      trailing()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sourceLine(_ source: TodoComposeSource) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
      HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
        Text("原话").foregroundStyle(Tokens.V1.Color.ink3)
        Text(source.text)
          .foregroundStyle(Tokens.V1.Color.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .runtimeAccessibilityIdentifier(source.identifier)
        if let anchor = source.anchor {
          // 点时间回跳转写，表单留在原处，对着原话填。
          let target = TranscriptAnchor(timecode: anchor)
          if TranscriptAnchorButton.canRender(target, onJump: onJump) {
            TranscriptAnchorButton(anchor: target, onJump: onJump)
          } else {
            Text(TodoClock.sourceTime(anchor))
              .font(Tokens.V1.Text.timecode.font)
              .foregroundStyle(Tokens.V1.Color.ink3)
          }
        }
      }
      if source.missingContext {
        Text("原负责人、截止和位置无法恢复").foregroundStyle(Tokens.V1.Color.ink2)
      }
    }
    .font(Tokens.V1.Text.meta.font)
  }
}

extension TodoComposeForm
where SourceAccessory == EmptyView, Followup == EmptyView, Trailing == EmptyView {
  init(
    draft: Binding<TodoEditorDraft>, due: Binding<TodoDue>, identifiers: TodoComposeIdentifiers,
    assigneeSuggestions: [String], clients: [String], projects: [String],
    onSelectClient: @escaping (String) -> Void, onSelectProject: @escaping (String) -> Void,
    now: Date, focusTitle: Bool
  ) {
    self.init(
      draft: draft, due: due, source: nil, onJump: nil, identifiers: identifiers,
      assigneeSuggestions: assigneeSuggestions, clients: clients, projects: projects,
      onSelectClient: onSelectClient, onSelectProject: onSelectProject, now: now, dueHint: nil,
      dueBasis: nil, focusTitle: focusTitle, spokenAssignee: nil, onAssigneeChosen: {},
      sourceAccessory: { EmptyView() },
      followup: { EmptyView() }, trailing: { EmptyView() })
  }
}

/// 表单里的一组：组标题加 raised 底、rule 细边、radius-lg 的框，无投影。详情栏的属性组也用它。
struct TodoComposeGroup<Accessory: View, Content: View>: View {
  let title: String
  @ViewBuilder var accessory: () -> Accessory
  @ViewBuilder var content: () -> Content

  init(
    _ title: String, @ViewBuilder accessory: @escaping () -> Accessory,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.accessory = accessory
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      HStack(alignment: .center) {
        Text(title)
          .font(Tokens.V1.Text.strong.font)
          .fontWeight(Tokens.V1.Text.strong.weight)
          .foregroundStyle(Tokens.V1.Color.ink)
        Spacer(minLength: Tokens.V1.Space.sm)
        accessory()
      }
      .frame(minHeight: Tokens.V1.Size.controlSm)
      content()
    }
    .padding(Tokens.V1.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tokens.V1.Color.raised, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg))
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
        .strokeBorder(Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
    )
  }
}

extension TodoComposeGroup where Accessory == EmptyView {
  init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
    self.init(title, accessory: { EmptyView() }, content: content)
  }
}

/// 标签在框上：meta 字 ink-3，与框距 space-xs。两列并排时各占一半，框顶框底对齐。
struct TodoComposeField<Content: View>: View {
  let label: String
  @ViewBuilder var content: () -> Content

  init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
    self.label = label
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      Text(label)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 「表单里的待确认行」：按提示的规矩画成一行，左边字形加一句话，右边贴右的 24 高小按钮。
/// 负责人冲突用警示（warn-soft 底、感叹号），「N 天内」用中性（paper-2 底、问号）。
struct TodoComposeNotice<Actions: View>: View {
  enum Level { case warn, neutral }

  let level: Level
  let text: String
  /// 按钮标签本身带要点（如两个日期）、一行放不下时，问句一行、按钮另起一行等分撑满。
  var stacked = false
  var identifier: String
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    Group {
      if stacked {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
          HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
            glyph
            message
          }
          HStack(spacing: Tokens.V1.Space.xs) { actions() }
        }
      } else {
        HStack(alignment: .center, spacing: Tokens.V1.Space.xs) {
          glyph
          message
          Spacer(minLength: Tokens.V1.Space.sm)
          // 按钮不省略；放不下时让左边那句话换行。
          HStack(spacing: Tokens.V1.Space.xs) { actions() }.fixedSize()
        }
      }
    }
    .font(Tokens.V1.Text.meta.font)
    .padding(.horizontal, Tokens.V1.Space.sm)
    .padding(.vertical, Tokens.V1.Space.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      level == .warn ? Tokens.V1.Color.warnSoft : Tokens.V1.Color.paper2,
      in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
    )
    .runtimeAccessibilityIdentifier(identifier)
  }

  private var glyph: some View {
    Image(
      systemName: level == .warn ? StatusGlyph.State.attention.systemImage : "questionmark.circle"
    )
    .foregroundStyle(level == .warn ? Tokens.V1.Color.warn : Tokens.V1.Color.ink3)
    .accessibilityHidden(true)
  }

  private var message: some View {
    Text(text)
      .foregroundStyle(Tokens.V1.Color.ink)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// 负责人只有一个框：「我」「待确认」加用过的名字，可搜索、Return 新建名字；清除即待确认。
struct TodoAssigneeComboBox: View {
  @Binding var draft: TodoEditorDraft
  let suggestions: [String]
  var details: [String: String] = [:]
  var size: V1FormSize = .regular
  var identifier: String
  var focusRequested = false
  var focusRequest = 0
  var onCommit: () -> Void = {}

  var body: some View {
    V1ComboBox(
      label: "负责人", value: draft.assigneeComboValue, suggestions: suggestions,
      details: details, size: size, identifier: identifier, focusRequested: focusRequested,
      focusRequest: focusRequest
    ) { value in
      draft.setAssignee(fromComboValue: value)
      onCommit()
    }
    .help("点开选人；列表里没有就直接输入名字，回车新建")
  }
}

extension TodoEditorDraft {
  static let assigneeMe = "我"
  static let assigneePending = "待确认"

  var assigneeComboValue: String {
    switch assigneeKind {
    case .me: Self.assigneeMe
    case .pending: Self.assigneePending
    case .named: assigneeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  mutating func setAssignee(fromComboValue value: String) {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch name {
    case "", Self.assigneePending: assigneeKind = .pending
    case Self.assigneeMe: assigneeKind = .me
    default:
      assigneeKind = .named
      assigneeName = name
    }
  }
}

/// 表单确认条：钉在栏底，错误原因紧贴按钮上方；按钮上不写快捷键字样，提示放悬停。
struct TodoComposeFooter: View {
  var error: String?
  var errorIdentifier: String
  var saveTitle: String
  var saveEnabled: Bool
  var cancelIdentifier: String
  var saveIdentifier: String
  var disabledSaveIdentifier: String?
  var onCancel: () -> Void
  var onSave: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      if let error {
        Text(error)
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier(errorIdentifier)
      }
      HStack(spacing: Tokens.V1.Space.sm) {
        Spacer()
        Button("取消", action: onCancel)
          .buttonStyle(.v1Quiet)
          .keyboardShortcut(.cancelAction)
          .help("Esc")
          .runtimeAccessibilityIdentifier(cancelIdentifier)
        Button(saveTitle, action: onSave)
          .buttonStyle(.v1Primary)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!saveEnabled)
          .help("⌘↩")
          .runtimeAccessibilityIdentifier(
            saveEnabled ? saveIdentifier : (disabledSaveIdentifier ?? saveIdentifier))
      }
    }
    .padding(.horizontal, Tokens.V1.Space.md)
    .padding(.vertical, Tokens.V1.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tokens.V1.Color.paper2)
    .overlay(alignment: .top) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
  }
}
