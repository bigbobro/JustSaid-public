import JustSaidCore
import SwiftUI

/// The row ellipsis and the contextual menu use exactly the same native menu content.
struct TodoRowMenu: View {
  @ObservedObject var model: TodoPageModel
  let item: TodoItem

  var body: some View {
    Button("编辑") { model.beginEdit(item.id) }
      .runtimeAccessibilityIdentifier("todos.menu.edit")
    Menu("设截止") {
      dueShortcut("今天", offset: 0)
      dueShortcut("明天", offset: 1)
      Button("下周") {
        if let day = TodoDeadlineShortcuts.nextWeek(now: model.now, zone: TodoClock.zone(of: item))
        {
          model.setDue(
            item.id,
            due: .date(TodoDay(day: day, timeZoneIdentifier: TodoClock.zone(of: item).identifier)))
        }
      }
      Button("无期限") { model.setDue(item.id, due: .none) }
      Button("截止待确认") { model.setDue(item.id, due: .pending) }
      Divider()
      Button("选择日期…") {
        model.beginEdit(item.id)
        model.requestEditorFocus(.due)
      }
    }
    .runtimeAccessibilityIdentifier("todos.menu.due")
    Menu("设优先级") {
      ForEach([TodoPriority.high, .normal, .low], id: \.rawValue) { priority in
        Button {
          model.setPriority(item.id, priority: priority)
        } label: {
          if item.priority == priority {
            Label(TodoText.priority(priority), systemImage: "checkmark")
          } else {
            Text(TodoText.priority(priority))
          }
        }
      }
    }
    .runtimeAccessibilityIdentifier("todos.menu.priority")
    Menu("移到象限…") {
      ForEach(
        [
          TodoQuadrant.importantUrgent, .importantNotUrgent, .urgentNotImportant, .neither,
          .duePending,
        ], id: \.rawValue
      ) { target in
        Button(TodoText.quadrantTitle(target)) { model.beginQuadrantMove(item.id, to: target) }
          .disabled(
            item.status != .open || TodoOrdering.quadrant(of: item, now: model.now) == target
          )
          .runtimeAccessibilityIdentifier("todos.menu.move.\(target.rawValue)")
      }
    }
    .disabled(item.status != .open)
    Divider()
    Button {
      model.remove(item.id)
    } label: {
      Text("移除").foregroundStyle(Tokens.V1.Color.danger)
    }
    .runtimeAccessibilityIdentifier("todos.menu.remove")
  }

  private func dueShortcut(_ title: String, offset: Int) -> some View {
    Button(title) {
      let zone = TodoClock.zone(of: item)
      if let day = TodoDeadlineShortcuts.day(now: model.now, zone: zone, offset: offset) {
        model.setDue(item.id, due: .date(TodoDay(day: day, timeZoneIdentifier: zone.identifier)))
      }
    }
  }
}
