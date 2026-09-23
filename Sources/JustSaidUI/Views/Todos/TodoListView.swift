import JustSaidCore
import SwiftUI

struct TodoListView: View {
  @ObservedObject var model: TodoPageModel
  var narrow: Bool = false
  var onOpenSource: (URL, TimeInterval?) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
        if model.isSearching {
          group(
            "未完成", items: model.openSections.flatMap(\.items), identifier: "todos.group.search-open"
          )
          group(
            "已完成", items: model.completed.known + model.completed.unknownTime,
            identifier: "todos.group.search-done")
        } else if model.scope == .done {
          group("已完成", items: model.completed.known, identifier: "todos.group.done")
          group(
            "完成时间未知", items: model.completed.unknownTime, identifier: "todos.group.done-unknown")
        } else if model.scope == .pending {
          VStack(spacing: 0) { rows(model.visibleItems) }
          Text("补全后会回到它该在的分组")
            .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
        } else {
          ForEach(model.openSections, id: \.group) { section in
            VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
              header(
                section.group == .pinned ? "" : TodoText.groupTitle(section.group),
                count: section.group == .pinned ? "\(model.pinCensus.total)/3" : nil,
                pinned: section.group == .pinned,
                identifier: "todos.group.\(section.group.rawValue)")
              VStack(spacing: 0) { rows(section.items) }
            }
          }
        }
      }
      .padding(Tokens.V1.Space.lg)
    }
    .rememberedScrollOffset(Binding(get: { model.scrollOffset }, set: { model.scrollOffset = $0 }))
    .runtimeAccessibilityIdentifier("todos.list")
  }

  @ViewBuilder
  private func group(_ title: String, items: [TodoItem], identifier: String) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        header(title, count: "\(items.count)", pinned: false, identifier: identifier)
        VStack(spacing: 0) { rows(items) }
      }
    }
  }

  private func rows(_ items: [TodoItem]) -> some View {
    ForEach(items) { item in
      TodoRowView(model: model, item: item, narrow: narrow, onOpenSource: onOpenSource)
    }
  }

  private func header(_ title: String, count: String?, pinned: Bool, identifier: String)
    -> some View
  {
    HStack(spacing: Tokens.V1.Space.xs) {
      if pinned { Image(systemName: "pin.fill") }
      if !title.isEmpty { Text(title) }
      if let count { Text(count).monospacedDigit() }
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .font(Tokens.V1.Text.meta.font).fontWeight(Tokens.V1.Text.strong.weight)
    .foregroundStyle(pinned ? Tokens.V1.Color.accent : Tokens.V1.Color.ink3)
    .runtimeAccessibilityIdentifier(identifier)
  }
}
