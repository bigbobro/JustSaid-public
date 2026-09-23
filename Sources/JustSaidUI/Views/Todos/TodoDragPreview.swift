import JustSaidCore
import SwiftUI

/// The native drag image is also a standalone presentation component, without session simulation.
public struct TodoDragPreview: View {
  public let item: TodoItem
  public let now: Date
  public var query: String
  public var width: CGFloat
  public var selected: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(item: TodoItem, now: Date, query: String = "", width: CGFloat, selected: Bool = false)
  {
    self.item = item
    self.now = now
    self.query = query
    self.width = width
    self.selected = selected
  }

  public var body: some View {
    HStack(alignment: .top, spacing: Tokens.V1.Space.sm) {
      Image(systemName: "circle")
        .font(.system(size: Tokens.V1.Size.checkBox))
        .foregroundStyle(Tokens.V1.Color.controlRule)
        .frame(width: Tokens.V1.Size.checkBox, height: Tokens.V1.Size.checkBox)
        .padding(.top, Tokens.V1.Space.s2xs)
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
        HStack(alignment: .top, spacing: Tokens.V1.Space.xs) {
          TodoHighlightedText(text: item.title, query: query)
            .font(Tokens.V1.Text.body.font).foregroundStyle(Tokens.V1.Color.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          if item.pinnedAt != nil {
            Image(systemName: "pin.fill").foregroundStyle(Tokens.V1.Color.accent)
              .frame(width: Tokens.V1.Size.controlSm, height: Tokens.V1.Size.controlSm)
          }
          Image(systemName: "ellipsis").foregroundStyle(Tokens.V1.Color.ink3)
            .frame(width: Tokens.V1.Size.controlSm, height: Tokens.V1.Size.controlSm)
        }
        metadata
      }
    }
    .padding(.vertical, Tokens.V1.Space.sm)
    .padding(.horizontal, Tokens.V1.Space.xs)
    .frame(width: width, alignment: .leading)
    .background(
      selected ? Tokens.V1.Color.paper2 : Tokens.V1.Color.paper,
      in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
    )
    .tokenShadow(Tokens.V1.Shadow.popNear)
    .tokenShadow(Tokens.V1.Shadow.popFar)
    .scaleEffect(reduceMotion ? 1 : Tokens.V1.Size.dragPreviewScale)
    .allowsHitTesting(false)
    .runtimeAccessibilityIdentifier("todos.drag.preview.\(item.id.uuidString)")
  }

  private var metadata: some View {
    let due = TodoText.due(of: item, now: now)
    return TodoMetadataFlow {
      TodoHighlightedText(
        text: item.assignee == .pending ? "负责人待确认" : TodoText.assignee(item.assignee),
        query: query
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
        Text(
          source.anchor?.nilIfBlank.map(TodoClock.sourceTime)
            ?? source.meetingTitle?.nilIfBlank ?? "来源会议"
        )
        .foregroundStyle(Tokens.V1.Color.accent)
      } else {
        Text(TodoText.manualSource).foregroundStyle(Tokens.V1.Color.ink3)
      }
    }
    .font(Tokens.V1.Text.meta.font)
  }
}

struct TodoNativeDragSource: ViewModifier {
  @ObservedObject var model: TodoPageModel
  let item: TodoItem
  let width: CGFloat
  var selected = false

  @ViewBuilder
  func body(content: Content) -> some View {
    if item.status == .open && item.removedAt == nil && model.canMutate {
      if #available(macOS 26.0, *) {
        source(content)
          .onDragSessionUpdated { session in
            switch session.phase {
            case .active: model.setActiveDragging(item.id)
            case .ended, .dataTransferCompleted: model.endDragging(item.id)
            case .initial: break
            @unknown default: break
            }
          }
      } else {
        // Earlier systems have no reliable cancellation callback. Source identity supports
        // isTargeted feedback, but never drives a placeholder or a dimmed pending shelf.
        source(content)
      }
    } else {
      content
    }
  }

  private func source(_ content: Content) -> some View {
    content.onDrag {
      _ = model.recordDragSource(item.id)
      return NSItemProvider(object: item.id.uuidString as NSString)
    } preview: {
      TodoDragPreview(
        item: item, now: model.now, query: model.query, width: width, selected: selected)
    }
  }
}
