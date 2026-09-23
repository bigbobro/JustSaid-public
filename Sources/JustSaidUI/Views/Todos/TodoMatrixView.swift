import JustSaidCore
import SwiftUI

struct TodoMatrixView: View {
  @ObservedObject var model: TodoPageModel
  var onOpenSource: (URL, TimeInterval?) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shelfContentHeight = Tokens.V1.Size.controlLg + Tokens.V1.Space.md * 2

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            cell(
              .importantUrgent, items: model.board.importantUrgent, rule: .both,
              popoverOffset: geometry.size.width / 2)
            cell(.importantNotUrgent, items: model.board.importantNotUrgent, rule: .bottom)
          }.frame(maxHeight: .infinity)
          HStack(spacing: 0) {
            cell(
              .urgentNotImportant, items: model.board.urgentNotImportant, rule: .trailing,
              popoverOffset: geometry.size.width / 2)
            cell(.neither, items: model.board.neither, rule: .none)
          }.frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        shelf(maxHeight: geometry.size.height / 3)
      }
    }
    .runtimeAccessibilityIdentifier("todos.matrix")
  }

  private enum CellRule: Equatable { case both, bottom, trailing, none }

  private func cell(
    _ quadrant: TodoQuadrant, items: [TodoItem], rule: CellRule, popoverOffset: CGFloat = 0
  ) -> some View {
    let hovering = model.dragHoverTarget == quadrant && model.canTargetDrag(quadrant)
    let confirming = model.move?.target == quadrant
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      HStack(spacing: Tokens.V1.Space.xs) {
        Text(TodoText.quadrantTitle(quadrant)).font(Tokens.V1.Text.heading.font)
        Text("\(items.count)").font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
        Spacer(minLength: 0)
        if hovering {
          Text("松手后确认要改的字段")
            .font(Tokens.V1.Text.micro.font).foregroundStyle(Tokens.V1.Color.accent)
            .runtimeAccessibilityIdentifier("todos.drag.target-hint.\(quadrant.rawValue)")
        }
      }
      .help(TodoText.quadrantHint(quadrant))
      .modifier(TodoMovePopoverAnchor(model: model, anchor: .quadrant(quadrant)))
      if items.isEmpty {
        Text(model.filtering ? TodoText.quadrantFiltered : TodoText.quadrantEmpty)
          .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .runtimeAccessibilityIdentifier("todos.quadrant.\(quadrant.rawValue).empty")
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(items) { item in
              TodoRowView(
                model: model, item: item, narrow: true, popoverTrailingOffset: popoverOffset,
                onOpenSource: onOpenSource
              )
              .runtimeAccessibilityIdentifier(
                "todos.cell.\(quadrant.rawValue).\(item.id.uuidString)")
            }
          }
        }
      }
    }
    .padding(Tokens.V1.Space.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(hovering ? Tokens.V1.Color.accentSoft : .clear)
    .contentShape(Rectangle())
    .overlay(alignment: .trailing) {
      if rule == .both || rule == .trailing {
        Rectangle().fill(Tokens.V1.Color.rule).frame(width: Tokens.V1.Size.controlRuleWidth)
      }
    }
    .overlay(alignment: .bottom) {
      if rule == .both || rule == .bottom {
        Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
      }
    }
    .overlay {
      if hovering {
        Rectangle().strokeBorder(Tokens.V1.Color.accent, lineWidth: Tokens.V1.Size.controlRuleWidth)
          .allowsHitTesting(false)
          .runtimeAccessibilityIdentifier("todos.drag.target.\(quadrant.rawValue)")
      } else if confirming {
        Rectangle().strokeBorder(Tokens.V1.Color.accent, lineWidth: Tokens.V1.Size.controlRuleWidth)
          .allowsHitTesting(false)
          .runtimeAccessibilityIdentifier("todos.move.target.\(quadrant.rawValue)")
      }
    }
    .animation(.easeOut(duration: Tokens.V1.Motion.fast), value: hovering)
    .animation(
      .easeOut(duration: reduceMotion ? Tokens.V1.Motion.fast : Tokens.V1.Motion.base),
      value: confirming
    )
    .dropDestination(for: String.self) { values, _ in
      guard let raw = values.first, let id = UUID(uuidString: raw) else { return false }
      defer { model.endDragging(id) }
      return model.beginQuadrantMove(id, to: quadrant)
    } isTargeted: { targeted in
      model.updateDragHover(quadrant, isTargeted: targeted)
    }
    .runtimeAccessibilityIdentifier("todos.quadrant.\(quadrant.rawValue)")
  }

  private func shelf(maxHeight: CGFloat) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        Text("截止待确认 · \(model.board.duePending.count)")
          .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
          .runtimeAccessibilityIdentifier("todos.quadrant.duePending")
          .modifier(TodoMovePopoverAnchor(model: model, anchor: .quadrant(.duePending)))
        if model.board.duePending.isEmpty {
          Text(TodoText.quadrantEmpty).font(Tokens.V1.Text.meta.font).foregroundStyle(
            Tokens.V1.Color.ink3)
        } else {
          VStack(spacing: 0) {
            ForEach(model.board.duePending) { item in
              TodoRowView(model: model, item: item, narrow: true, onOpenSource: onOpenSource)
                .runtimeAccessibilityIdentifier("todos.cell.duePending.\(item.id.uuidString)")
            }
          }
        }
      }
      .padding(Tokens.V1.Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        shelfContentHeight = $0
      }
    }
    .frame(height: min(maxHeight, shelfContentHeight))
    .contentShape(Rectangle())
    .overlay(alignment: .top) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .overlay {
      if model.move?.target == .duePending {
        Rectangle().strokeBorder(Tokens.V1.Color.accent, lineWidth: Tokens.V1.Size.controlRuleWidth)
          .allowsHitTesting(false)
          .runtimeAccessibilityIdentifier("todos.move.target.duePending")
      }
    }
    .opacity(model.activeDraggingID == nil ? 1 : Tokens.V1.Feedback.disabledOpacity)
    .overlay {
      if model.activeDraggingID != nil {
        Color.clear.allowsHitTesting(false)
          .runtimeAccessibilityIdentifier("todos.drag.pending-dim")
      }
    }
    .animation(.easeOut(duration: Tokens.V1.Motion.fast), value: model.activeDraggingID)
  }
}
