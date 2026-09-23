import JustSaidCore
import SwiftUI

struct TodoRowView: View {
  @ObservedObject var model: TodoPageModel
  let item: TodoItem
  var narrow: Bool = false
  var popoverTrailingOffset: CGFloat = 0
  var onOpenSource: (URL, TimeInterval?) -> Void
  @State private var hovering = false
  @FocusState private var rowFocused: Bool
  @State private var rowWidth = Tokens.V1.Size.sideWidth
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var selected: Bool { model.selectedID == item.id }
  private var placeholder: Bool { model.activeDraggingID == item.id }
  private var confirming: Bool { model.move?.itemID == item.id }
  private var due: (primary: String, secondary: String?, emphasized: Bool) {
    TodoText.due(of: item, now: model.now)
  }

  var body: some View {
    HStack(alignment: .top, spacing: Tokens.V1.Space.sm) {
      completeButton.padding(.top, Tokens.V1.Space.s2xs)
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
        HStack(alignment: .top, spacing: Tokens.V1.Space.xs) {
          TodoHighlightedText(text: item.title, query: model.query)
            .font(Tokens.V1.Text.body.font)
            .foregroundStyle(item.status == .done ? Tokens.V1.Color.ink3 : Tokens.V1.Color.ink)
            .strikethrough(item.status == .done)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusable()
            .focused($rowFocused)
            .onKeyPress(.return) {
              model.showDetail(item.id)
              return .handled
            }
            .onKeyPress(.space) {
              model.showPopover(item.id)
              return .handled
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(item.title)
            .accessibilityAction { select() }
            .accessibilityAction(named: "快速编辑") { model.showPopover(item.id) }
            .accessibilityAction(named: "展开详情") { model.showDetail(item.id) }
            .runtimeAccessibilityIdentifier("todos.row.\(item.id.uuidString)")
          actions
        }
        metadata.runtimeAccessibilityIdentifier("todos.row.metadata.\(item.id.uuidString)")
        if let match = model.searchMatch(for: item) {
          if match.fields.contains(.note) {
            TodoHighlightedText(text: item.note, query: model.query)
              .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
              .fixedSize(horizontal: false, vertical: true)
              .runtimeAccessibilityIdentifier("todos.match.note.\(item.id.uuidString)")
          }
          ForEach(match.sourceMeetingTitles, id: \.self) { title in
            HStack(alignment: .top, spacing: Tokens.V1.Space.xs) {
              Text("命中来源：").foregroundStyle(Tokens.V1.Color.ink3)
              TodoHighlightedText(text: title, query: model.query)
            }
            .font(Tokens.V1.Text.meta.font)
            .runtimeAccessibilityIdentifier("todos.match.source.\(item.id.uuidString)")
          }
        }
      }
    }
    .padding(.vertical, Tokens.V1.Space.sm)
    .padding(.horizontal, Tokens.V1.Space.xs)
    .background(
      selected || hovering ? Tokens.V1.Color.paper2 : .clear,
      in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
    )
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .opacity(placeholder ? 0 : (confirming ? Tokens.V1.Feedback.disabledOpacity : 1))
    .overlay {
      if placeholder {
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
          .strokeBorder(
            Tokens.V1.Color.controlRule,
            style: StrokeStyle(
              lineWidth: Tokens.V1.Size.controlRuleWidth,
              dash: [Tokens.V1.Space.xs, Tokens.V1.Space.xs])
          )
          .allowsHitTesting(false)
          .runtimeAccessibilityIdentifier("todos.drag.placeholder.\(item.id.uuidString)")
      } else if confirming {
        Color.clear.allowsHitTesting(false)
          .runtimeAccessibilityIdentifier("todos.move.source-dim.\(item.id.uuidString)")
      }
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      rowWidth = $0
    }
    .animation(.easeOut(duration: Tokens.V1.Motion.fast), value: placeholder)
    .animation(
      .easeOut(duration: reduceMotion ? Tokens.V1.Motion.fast : Tokens.V1.Motion.base),
      value: confirming
    )
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.showDetail(item.id) }
    .onTapGesture { select() }
    .onHover { hovering = $0 }
    .modifier(
      TodoNativeDragSource(
        model: model, item: item, width: rowWidth, selected: selected || hovering)
    )
    .contextMenu { TodoRowMenu(model: model, item: item) }
    .modifier(TodoMovePopoverAnchor(model: model, anchor: .row(item.id)))
    // The reserved trailing gutter keeps the native arrow beside the row without covering text.
    .popover(
      isPresented: Binding(
        get: { model.popoverID == item.id },
        set: { if !$0 && model.popoverID == item.id { model.closePopover() } }),
      attachmentAnchor: .rect(
        .rect(
          CGRect(
            x: rowWidth + popoverTrailingOffset, y: Tokens.V1.Space.sm,
            width: Tokens.V1.Size.controlRuleWidth, height: Tokens.V1.Size.controlSm))),
      arrowEdge: .trailing
    ) {
      TodoEditorView(model: model, onOpenSource: onOpenSource)
        .frame(width: Tokens.V1.Size.todoPopoverWidth, height: Tokens.V1.Size.settingsForm)
        .background(Tokens.V1.Color.raised)
        .onExitCommand { model.closePopover() }
        .runtimeAccessibilityIdentifier("todos.row-popover")
    }
  }

  private func select() {
    model.selectItem(item.id)
    rowFocused = true
  }

  private var completeButton: some View {
    Button {
      model.toggleComplete(item.id)
    } label: {
      Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
        .font(.system(size: Tokens.V1.Size.checkBox))
        .foregroundStyle(item.status == .done ? Tokens.V1.Color.ink3 : Tokens.V1.Color.controlRule)
        .frame(width: Tokens.V1.Size.checkBox, height: Tokens.V1.Size.checkBox)
    }
    .buttonStyle(.plain)
    .disabled(!model.canMutate || item.removedAt != nil)
    .help(item.status == .done ? "标为未完成" : "标记为完成")
    .accessibilityLabel(item.status == .done ? "标为未完成：\(item.title)" : "标记为完成：\(item.title)")
    .runtimeAccessibilityIdentifier("todos.check.\(item.id.uuidString)")
  }

  private var metadata: some View {
    TodoMetadataFlow {
      TodoHighlightedText(
        text: item.assignee == .pending ? "负责人待确认" : TodoText.assignee(item.assignee),
        query: model.query
      )
      .foregroundStyle(item.assignee == .pending ? Tokens.V1.Color.warn : Tokens.V1.Color.ink2)
      Text(due.secondary.map { "\(due.primary) · \($0)" } ?? due.primary)
        .fontWeight(due.emphasized ? Tokens.V1.Text.strong.weight : Tokens.V1.Text.body.weight)
        .foregroundStyle(
          due.emphasized
            ? Tokens.V1.Color.ink
            : (item.due == .pending ? Tokens.V1.Color.warn : Tokens.V1.Color.ink3))
      Text(TodoText.priorityPhrase(item.priority))
        .fontWeight(
          item.priority == .high ? Tokens.V1.Text.strong.weight : Tokens.V1.Text.body.weight
        )
        .foregroundStyle(item.priority == .high ? Tokens.V1.Color.ink : Tokens.V1.Color.ink3)
      if let project = TodoText.clientProject(item) {
        Text(project).foregroundStyle(Tokens.V1.Color.ink3)
      }
      if let source = item.sources.first {
        sourceLink(source)
      } else {
        Text(TodoText.manualSource).foregroundStyle(Tokens.V1.Color.ink3)
      }
      if item.status == .done {
        Text(item.completedAt.map { "完成于\(ChineseDateText.dayWithWeekday($0))" } ?? "完成时间未知")
          .foregroundStyle(Tokens.V1.Color.ink3)
      }
    }
    .font(Tokens.V1.Text.meta.font)
  }

  @ViewBuilder
  private func sourceLink(_ source: TodoSource) -> some View {
    let title =
      source.anchor?.nilIfBlank.map(TodoClock.sourceTime) ?? source.meetingTitle?.nilIfBlank
      ?? "来源会议"
    switch model.location(of: source) {
    case .present, .ambiguous:
      Button(title) { model.openSource(source, navigate: onOpenSource) }
        .buttonStyle(.plain).foregroundStyle(Tokens.V1.Color.accent)
        .help(source.meetingTitle ?? "来源会议")
        .runtimeAccessibilityIdentifier("todos.source.\(source.id.uuidString)")
    case .deleted:
      Text("\(title) · 已删除").foregroundStyle(Tokens.V1.Color.ink3)
        .runtimeAccessibilityIdentifier("todos.source.deleted.\(source.id.uuidString)")
    case .unavailable:
      Text("\(title) · 来源暂不可用").foregroundStyle(Tokens.V1.Color.ink3)
        .runtimeAccessibilityIdentifier("todos.source.unavailable.\(source.id.uuidString)")
    }
  }

  private var actions: some View {
    HStack(spacing: Tokens.V1.Space.s2xs) {
      if selected {
        Button {
          model.showPopover(item.id)
        } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
        .help("快速编辑（空格）").accessibilityLabel("快速编辑")
        .runtimeAccessibilityIdentifier("todos.info.\(item.id.uuidString)")

      }
      if model.scope == .pending && !model.isSearching {
        Button("补全") { model.beginCompletion(item.id) }
          .buttonStyle(.v1Outline.height(Tokens.V1.Size.controlSm))
          .runtimeAccessibilityIdentifier("todos.complete-fields.\(item.id.uuidString)")
      }
      if item.status == .open, item.pinnedAt != nil || hovering || selected {
        Button {
          model.togglePin(item.id)
        } label: {
          Image(systemName: item.pinnedAt == nil ? "pin" : "pin.fill")
            .foregroundStyle(item.pinnedAt == nil ? Tokens.V1.Color.ink3 : Tokens.V1.Color.accent)
        }
        .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
        .help(item.pinnedAt == nil ? "钉住待办" : "取消钉住")
        .accessibilityLabel(item.pinnedAt == nil ? "钉住待办" : "取消钉住")
        .runtimeAccessibilityIdentifier("todos.pin.\(item.id.uuidString)")
      }
      Menu {
        TodoRowMenu(model: model, item: item)
      } label: {
        Image(systemName: "ellipsis").foregroundStyle(Tokens.V1.Color.ink3)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: Tokens.V1.Size.controlSm, height: Tokens.V1.Size.controlSm)
      .disabled(!model.canMutate)
      .accessibilityLabel("待办操作")
      .runtimeAccessibilityIdentifier("todos.menu.\(item.id.uuidString)")
    }
    .font(Tokens.V1.Text.body.font)
  }
}
