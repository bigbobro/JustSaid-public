import JustSaidCore
import SwiftUI

struct TodoEditorView: View {
  @ObservedObject var model: TodoPageModel
  var onOpenSource: (URL, TimeInterval?) -> Void = { _, _ in }
  var usesInspectorPin = false
  @FocusState private var focused: Field?
  private enum Field: Hashable { case title, client, project, note }

  private var size: V1FormSize { model.isCreating ? .regular : .compact }

  var body: some View {
    Group {
      if model.isCreating { creating } else { editing }
    }
    .background(Tokens.V1.Color.paper2)
    .onAppear { applyRequestedFocus() }
    .onChange(of: model.editorFocus) { _, _ in applyRequestedFocus() }
    .onChange(of: model.editorFocusRequest) { _, _ in applyRequestedFocus() }
    .onChange(of: focused) { previous, _ in
      if previous != nil { model.saveExistingEditor() }
    }
    .onSubmit { model.saveExistingEditor() }
    .runtimeAccessibilityIdentifier("todos.editor")
  }

  /// 新增与会议「加入待办」是同一个表单（TodoComposeForm），这里只给顶栏和确认条。
  private var creating: some View {
    VStack(spacing: 0) {
      HStack(spacing: Tokens.V1.Space.sm) {
        Text("新增待办")
          .font(Tokens.V1.Text.barTitle.font)
          .foregroundStyle(Tokens.V1.Color.ink)
        Spacer()
        Button {
          model.cancelCreate()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.v1Icon).help("取消 Esc").accessibilityLabel("取消新增待办")
      }
      .padding(.horizontal, Tokens.V1.Space.md)
      .frame(height: Tokens.V1.Size.barHeight)
      .overlay(alignment: .bottom) {
        Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
      }
      ScrollView {
        TodoComposeForm(
          draft: draft, due: due, identifiers: .newTodo,
          assigneeSuggestions: model.assigneeSuggestions(), clients: model.tagDirectory.clients,
          projects: model.tagDirectory.projects(for: model.editor?.client ?? ""),
          onSelectClient: model.selectEditorClient, onSelectProject: model.selectEditorProject,
          now: model.now, focusTitle: true
        )
        .padding(Tokens.V1.Space.md)
      }
      .frame(maxHeight: .infinity, alignment: .top)
      TodoComposeFooter(
        error: model.editor?.error, errorIdentifier: "todos.editor.error",
        saveTitle: model.editor?.isRetry == true ? "重新保存" : "加入待办",
        saveEnabled: model.editor?.title.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty == false,
        cancelIdentifier: "todos.new.cancel", saveIdentifier: "todos.new.add",
        disabledSaveIdentifier: nil, onCancel: model.cancelCreate,
        onSave: { _ = model.saveEditor() })
    }
    .onExitCommand { model.cancelCreate() }
  }

  /// 已有待办：自动保存、左标签右值，属性收在与新增同款的「执行与归属」组里。
  private var editing: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
          titleHeader
          origin
        }
        TodoComposeGroup("执行与归属") {
          VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
            property("负责人") { assignee }
            property("截止") { deadline }
            property("优先级") { priority }
            property("客户") { client }
            property("项目") { project }
          }.runtimeAccessibilityIdentifier("todos.editor.properties")
        }
        TodoComposeField("备注") { note }
          .runtimeAccessibilityIdentifier("todos.editor.property.备注")
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
      minimumLines: 2, identifier: "todos.editor.note", onCommit: model.saveExistingEditor)
  }

  private var deadline: some View {
    TodoDeadlinePicker(
      due: due, now: model.now,
      timeZoneIdentifier: model.editor?.timeZoneIdentifier ?? SystemTimeZone.current.identifier,
      identifier: "todos.editor.due", focusRequested: model.editorFocus == .due,
      focusRequest: model.editorFocusRequest, compact: !model.isCreating)
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
    TodoAssigneeComboBox(
      draft: draft, suggestions: model.assigneeSuggestions(), size: size,
      identifier: "todos.editor.assignee", focusRequested: model.editorFocus == .assignee,
      focusRequest: model.editorFocusRequest, onCommit: model.saveExistingEditor)
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
    case .assignee, .due, nil: break
    }
  }

  private func property<Content: View>(_ label: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    HStack(alignment: .top, spacing: Tokens.V1.Space.sm) {
      Text(label).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
        .frame(width: Tokens.V1.Size.libraryColProject, height: size.height, alignment: .leading)
      content().frame(maxWidth: .infinity, minHeight: size.height, alignment: .leading)
    }.runtimeAccessibilityIdentifier("todos.editor.property.\(label)")
  }

  private var draft: Binding<TodoEditorDraft> {
    Binding(
      get: { model.editor ?? TodoEditorDraft() },
      set: { value in model.updateEditor { $0 = value } })
  }

  private func text(_ keyPath: WritableKeyPath<TodoEditorDraft, String>) -> Binding<String> {
    Binding(
      get: { model.editor?[keyPath: keyPath] ?? "" },
      set: { value in model.updateEditor { $0[keyPath: keyPath] = value } })
  }
}
