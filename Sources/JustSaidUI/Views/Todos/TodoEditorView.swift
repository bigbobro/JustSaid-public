import JustSaidCore
import SwiftUI

struct TodoEditorView: View {
  @ObservedObject var model: TodoPageModel
  var onOpenSource: (URL, TimeInterval?) -> Void = { _, _ in }
  var usesInspectorPin = false
  @FocusState private var focused: Field?
  private enum Field: Hashable { case title, assignee, name, client, project, note }

  private var size: V1FormSize { model.isCreating ? .regular : .compact }

  var body: some View {
    VStack(spacing: 0) {
      if model.isCreating {
        HStack {
          Text("新增待办").font(Tokens.V1.Text.heading.font)
          Spacer()
          Button {
            model.cancelCreate()
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.v1Icon).accessibilityLabel("取消新增待办")
        }.padding(Tokens.V1.Space.md)
        Divider()
      }
      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
          if model.isCreating {
            property("事项名称") {
              V1TextField(
                placeholder: "写下要跟进的事", text: text(\.title), multiline: true,
                minimumLines: 2, focusRequested: true, identifier: "todos.editor.title")
            }
            HStack(alignment: .top, spacing: Tokens.V1.Space.sm) {
              property("负责人") { assignee }
              property("优先级") { priority }
            }
            HStack(alignment: .top, spacing: Tokens.V1.Space.sm) {
              property("客户") { client }
              property("项目") { project }
            }
            property("截止") { deadline }
            property("备注") { note }
            origin
          } else {
            titleHeader
            origin
            VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
              property("负责人") { assignee }
              property("优先级") { priority }
              property("客户") { client }
              property("项目") { project }
              property("截止") { deadline }
              property("备注") { note }
            }.runtimeAccessibilityIdentifier("todos.editor.properties")
          }
          if let error = model.editor?.error {
            VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
              Text(error).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.warn)
              Button("重试") { _ = model.saveEditor() }.buttonStyle(.v1Outline)
            }.runtimeAccessibilityIdentifier("todos.editor.error")
          }
          TodoSourceSection(
            model: model, sources: model.editor?.itemID.flatMap(model.item)?.sources ?? [],
            onOpenSource: onOpenSource)
        }
        .font(Tokens.V1.Text.body.font).foregroundStyle(Tokens.V1.Color.ink)
        .padding(Tokens.V1.Space.md)
      }
      if model.isCreating {
        Divider()
        HStack {
          Spacer()
          Button("取消") { model.cancelCreate() }.buttonStyle(.v1Quiet)
            .runtimeAccessibilityIdentifier("todos.new.cancel")
          Button("加入待办") { _ = model.saveEditor() }.buttonStyle(.v1Primary)
            .disabled(
              model.editor?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            )
            .runtimeAccessibilityIdentifier("todos.new.add")
        }.padding(Tokens.V1.Space.md)
      }
    }
    .onAppear { applyRequestedFocus() }
    .onChange(of: model.editorFocus) { _, _ in applyRequestedFocus() }
    .onChange(of: model.editorFocusRequest) { _, _ in applyRequestedFocus() }
    .onChange(of: focused) { previous, _ in
      if previous != nil { model.saveExistingEditor() }
    }
    .onSubmit { model.saveExistingEditor() }
    .runtimeAccessibilityIdentifier("todos.editor")
  }

  private var priority: some View {
    V1Dropdown(
      value: TodoText.priorityPhrase(model.editor?.priority ?? .normal), size: size,
      identifier: "todos.editor.priority"
    ) {
      ForEach([TodoPriority.high, .normal, .low], id: \.self) { priority in
        Button {
          model.updateEditor { $0.priority = priority }
          model.saveExistingEditor()
        } label: {
          menuOption(
            TodoText.priorityPhrase(priority), selected: model.editor?.priority == priority)
        }
      }
    }.accessibilityLabel("优先级")
  }

  private var client: some View {
    V1ComboBox(
      label: "客户", value: model.editor?.client ?? "", suggestions: model.tagDirectory.clients,
      size: size, identifier: "todos.editor.client", onSelect: model.selectEditorClient)
  }

  private var project: some View {
    V1ComboBox(
      label: "项目", value: model.editor?.project ?? "",
      suggestions: model.tagDirectory.projects(for: model.editor?.client ?? ""),
      size: size, identifier: "todos.editor.project", onSelect: model.selectEditorProject)
  }

  private var note: some View {
    V1TextField(
      placeholder: "添加备注", text: text(\.note), size: size, multiline: true,
      minimumLines: model.isCreating ? 3 : 2, identifier: "todos.editor.note",
      onCommit: model.saveExistingEditor)
  }

  private var deadline: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      if model.isCreating {
        HStack(spacing: 0) {
          shortcut("今天", offset: 0)
          shortcut("明天", offset: 1)
          Button("下周") {
            let zone =
              TimeZone(identifier: model.editor?.timeZoneIdentifier ?? "") ?? SystemTimeZone.current
            if let day = TodoDeadlineShortcuts.nextWeek(now: model.now, zone: zone) {
              due.wrappedValue = .date(TodoDay(day: day, timeZoneIdentifier: zone.identifier))
            }
          }.buttonStyle(.v1Quiet)
          Button("无期限") { due.wrappedValue = .none }.buttonStyle(.v1Quiet)
        }
      }
      TodoDeadlinePicker(
        due: due, now: model.now,
        timeZoneIdentifier: model.editor?.timeZoneIdentifier ?? SystemTimeZone.current.identifier,
        identifier: "todos.editor.due", focusRequested: model.editorFocus == .due,
        focusRequest: model.editorFocusRequest, compact: !model.isCreating)
    }
  }

  private func shortcut(_ title: String, offset: Int) -> some View {
    Button(title) {
      let zone =
        TimeZone(identifier: model.editor?.timeZoneIdentifier ?? "") ?? SystemTimeZone.current
      if let day = TodoDeadlineShortcuts.day(now: model.now, zone: zone, offset: offset) {
        due.wrappedValue = .date(TodoDay(day: day, timeZoneIdentifier: zone.identifier))
      }
    }.buttonStyle(.v1Quiet)
  }

  private var titleHeader: some View {
    HStack(alignment: .top, spacing: Tokens.V1.Space.xs) {
      if let item = model.editor?.itemID.flatMap(model.item) {
        Button {
          model.toggleComplete(item.id)
        } label: {
          Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(
              item.status == .done ? Tokens.V1.Color.accent : Tokens.V1.Color.controlRule)
        }
        .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
        .accessibilityLabel(item.status == .done ? "标为未完成" : "标记为完成")
        .runtimeAccessibilityIdentifier("todos.editor.complete")
      }
      TextField("写下要跟进的事", text: text(\.title), axis: .vertical)
        .textFieldStyle(.plain).font(Tokens.V1.Text.title.font)
        .lineLimit(1...).focused($focused, equals: .title)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("点击编辑事项标题")
        .accessibilityLabel("事项标题")
        .runtimeAccessibilityIdentifier("todos.editor.title")
      if usesInspectorPin {
        Button {
          model.inspectorPinned.toggle()
        } label: {
          Image(systemName: model.inspectorPinned ? "pin.fill" : "pin")
            .foregroundStyle(model.inspectorPinned ? Tokens.V1.Color.accent : Tokens.V1.Color.ink3)
        }
        .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
        .help(model.inspectorPinned ? "取消常驻详情栏" : "钉住详情栏")
        .accessibilityLabel(model.inspectorPinned ? "取消常驻详情栏" : "钉住详情栏")
        .runtimeAccessibilityIdentifier("todos.inspector.pin")
      } else if let item = model.editor?.itemID.flatMap(model.item), item.status == .open {
        Button {
          model.togglePin(item.id)
        } label: {
          Image(systemName: item.pinnedAt == nil ? "pin" : "pin.fill")
            .foregroundStyle(item.pinnedAt == nil ? Tokens.V1.Color.ink3 : Tokens.V1.Color.accent)
        }
        .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
        .help(item.pinnedAt == nil ? "钉住待办" : "取消钉住")
        .accessibilityLabel(item.pinnedAt == nil ? "钉住待办" : "取消钉住")
        .runtimeAccessibilityIdentifier("todos.editor.pin")
      }
      Button {
        model.closeLayer()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
      .help("关闭").accessibilityLabel("关闭")
      .runtimeAccessibilityIdentifier("todos.inspector.close")
    }
    .runtimeAccessibilityIdentifier("todos.editor.header")
  }

  private var origin: some View {
    Group {
      if let source = model.editor?.itemID.flatMap(model.item)?.sources.first {
        switch model.location(of: source) {
        case .present, .ambiguous:
          Button("来源：" + (source.meetingTitle?.nilIfBlank ?? "来源会议")) {
            model.openSource(source, navigate: onOpenSource)
          }
          .buttonStyle(.plain).foregroundStyle(Tokens.V1.Color.accent)
        case .deleted, .unavailable:
          Text("来源：" + (source.meetingTitle?.nilIfBlank ?? "来源会议")).foregroundStyle(
            Tokens.V1.Color.ink3)
        }
      } else {
        Text("来源：手工新增").foregroundStyle(Tokens.V1.Color.ink3)
      }
    }
    .font(Tokens.V1.Text.meta.font)
    .runtimeAccessibilityIdentifier("todos.editor.origin")
  }

  private var assignee: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      V1Dropdown(value: assigneeLabel, size: size, identifier: "todos.editor.assignee") {
        assigneeOption("我", kind: .me)
        assigneeOption("指定的人…", kind: .named)
        assigneeOption("待确认", kind: .pending)
      }
      .focused($focused, equals: .assignee).accessibilityLabel("负责人")
      if model.editor?.assigneeKind == .named {
        V1TextField(
          placeholder: "填写姓名", text: text(\.assigneeName), size: size,
          identifier: "todos.editor.assignee-name", onCommit: model.saveExistingEditor
        )
        .focused($focused, equals: .name)
      }
    }
  }

  private var assigneeLabel: String {
    switch model.editor?.assigneeKind ?? .me {
    case .me: "我"
    case .named: model.editor?.assigneeName.nilIfBlank ?? "指定的人…"
    case .pending: "待确认"
    }
  }

  private func assigneeOption(_ title: String, kind: TodoEditorDraft.AssigneeKind) -> some View {
    Button {
      model.updateEditor { $0.assigneeKind = kind }
      if kind == .named { focused = .name } else { model.saveExistingEditor() }
    } label: {
      menuOption(title, selected: model.editor?.assigneeKind == kind)
    }
  }

  @ViewBuilder
  private func menuOption(_ title: String, selected: Bool) -> some View {
    if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
  }

  private var due: Binding<TodoDue> {
    Binding(
      get: {
        guard let draft = model.editor else { return .pending }
        switch draft.dueKind {
        case .none: return .none
        case .pending: return .pending
        case .date:
          return .date(
            TodoDay(
              day: TodoClock.dayString(from: draft.dueDate),
              timeZoneIdentifier: draft.timeZoneIdentifier))
        }
      },
      set: { value in
        model.updateEditor { draft in
          switch value {
          case .none: draft.dueKind = .none
          case .pending: draft.dueKind = .pending
          case .date(let day):
            draft.dueKind = .date
            draft.dueDate = TodoClock.pickerDate(day: day.day)
            draft.timeZoneIdentifier = day.timeZoneIdentifier
          }
        }
        model.saveExistingEditor()
      })
  }

  private func applyRequestedFocus() {
    switch model.editorFocus {
    case .title: if !model.isCreating { focused = .title }
    case .assignee: focused = model.editor?.assigneeKind == .named ? .name : .assignee
    case .due, nil: break
    }
  }

  private func property<Content: View>(_ label: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    Group {
      if model.isCreating {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
          Text(label).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
          content()
        }.frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(alignment: .top, spacing: Tokens.V1.Space.sm) {
          Text(label).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
            .frame(
              width: Tokens.V1.Size.libraryColProject, height: size.height, alignment: .leading)
          content().frame(maxWidth: .infinity, minHeight: size.height, alignment: .leading)
        }
      }
    }.runtimeAccessibilityIdentifier("todos.editor.property.\(label)")
  }

  private func text(_ keyPath: WritableKeyPath<TodoEditorDraft, String>) -> Binding<String> {
    Binding(
      get: { model.editor?[keyPath: keyPath] ?? "" },
      set: { value in model.updateEditor { $0[keyPath: keyPath] = value } })
  }
}
