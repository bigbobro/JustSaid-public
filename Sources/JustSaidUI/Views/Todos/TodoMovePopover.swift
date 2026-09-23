import JustSaidCore
import SwiftUI

/// Both entry points use the same native popover and transaction. Only its visible anchor differs.
struct TodoMovePopoverAnchor: ViewModifier {
  enum Anchor {
    case row(UUID)
    case quadrant(TodoQuadrant)
  }

  @ObservedObject var model: TodoPageModel
  let anchor: Anchor

  private var isPresented: Bool {
    guard let move = model.move else { return false }
    switch anchor {
    case .row(let id): return model.displayedLayout == .list && move.itemID == id
    case .quadrant(let quadrant):
      return model.displayedLayout == .matrix && move.target == quadrant
    }
  }

  private var identifier: String {
    switch anchor {
    case .row(let id): "todos.move.anchor.row.\(id.uuidString)"
    case .quadrant(let quadrant): "todos.move.anchor.quadrant.\(quadrant.rawValue)"
    }
  }

  func body(content: Content) -> some View {
    content
      .runtimeAccessibilityIdentifier(identifier)
      .popover(
        isPresented: Binding(
          get: { isPresented },
          set: { if !$0 && isPresented { model.cancelMove() } }),
        attachmentAnchor: .rect(.bounds), arrowEdge: .bottom
      ) {
        TodoMovePopover(model: model)
      }
  }
}

struct TodoMovePopover: View {
  @ObservedObject var model: TodoPageModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsCalendar = false
  @State private var appeared = false

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      if let move = model.move, let item = model.item(move.itemID) {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
          Text("移到\(TodoText.quadrantTitle(move.target))")
            .font(Tokens.V1.Text.heading.font)
          Text(item.title).font(Tokens.V1.Text.body.font)
            .fixedSize(horizontal: false, vertical: true)
        }
        if move.changesPriority {
          priorityChange(move)
        }
        if move.changesDue {
          VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
            changeRow("截止", before: TodoDeadlineCalendar.label(move.original.due)) {
              Text(afterDue(move)).foregroundStyle(Tokens.V1.Color.ink)
            }
            .runtimeAccessibilityIdentifier("todos.move.due")
            if move.target != .duePending {
              dateChoices(move)
            }
          }
        }
        if let error = move.error {
          Text(error).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.warn)
            .fixedSize(horizontal: false, vertical: true)
            .runtimeAccessibilityIdentifier("todos.move.error")
        }
        Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
        HStack(spacing: Tokens.V1.Space.s2xs) {
          Text("重要＝高优先级，紧急＝≤明天")
            .font(Tokens.V1.Text.micro.font).foregroundStyle(Tokens.V1.Color.ink3)
            .fixedSize()
          Spacer(minLength: 0)
          Button("取消") { model.cancelMove() }
            .buttonStyle(.v1Quiet.height(Tokens.V1.Size.controlSm))
            .runtimeAccessibilityIdentifier("todos.move.cancel")
          Button("移动") { model.saveMove() }
            .buttonStyle(.v1Primary.height(Tokens.V1.Size.controlSm))
            .disabled(!model.canSaveMove)
            .runtimeAccessibilityIdentifier("todos.move.save")
        }
      }
    }
    .foregroundStyle(Tokens.V1.Color.ink)
    .padding(Tokens.V1.Space.md)
    .frame(width: Tokens.V1.Size.sideWidth)
    .background(Tokens.V1.Color.raised)
    .opacity(appeared ? 1 : 0)
    .onAppear {
      withAnimation(
        .easeOut(duration: reduceMotion ? Tokens.V1.Motion.fast : Tokens.V1.Motion.slow)
      ) {
        appeared = true
      }
    }
    .runtimeAccessibilityIdentifier("todos.move.confirm")
  }

  private func priorityChange(_ move: TodoQuadrantMove) -> some View {
    changeRow("优先级", before: TodoText.priority(move.original.priority)) {
      if move.priority == .high {
        Text(TodoText.priority(move.priority)).fontWeight(Tokens.V1.Text.strong.weight)
      } else {
        Menu {
          Button("普通") { model.updateMove { $0.priority = .normal } }
          Button("低") { model.updateMove { $0.priority = .low } }
        } label: {
          Text(TodoText.priority(move.priority))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
    }
    .runtimeAccessibilityIdentifier("todos.move.priority")
  }

  private func changeRow<Value: View>(
    _ label: String, before: String, @ViewBuilder value: () -> Value
  ) -> some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Text(label).foregroundStyle(Tokens.V1.Color.ink3)
      Text(before).strikethrough().foregroundStyle(Tokens.V1.Color.ink3)
      Image(systemName: "arrow.right").foregroundStyle(Tokens.V1.Color.ink3)
      value()
      Spacer(minLength: 0)
    }
    .font(Tokens.V1.Text.body.font)
  }

  @ViewBuilder
  private func dateChoices(_ move: TodoQuadrantMove) -> some View {
    let zone = TimeZone(identifier: move.timeZoneIdentifier) ?? SystemTimeZone.current
    if move.target == .importantUrgent || move.target == .urgentNotImportant {
      HStack(spacing: Tokens.V1.Space.xs) {
        dayChoice(
          "今天", day: TodoDeadlineShortcuts.day(now: model.now, zone: zone, offset: 0),
          identifier: "today", move: move)
        dayChoice(
          "明天", day: TodoDeadlineShortcuts.day(now: model.now, zone: zone, offset: 1),
          identifier: "tomorrow", move: move)
        calendarChoice(move)
      }
    } else {
      VStack(spacing: Tokens.V1.Space.xs) {
        HStack(spacing: Tokens.V1.Space.xs) {
          dayChoice(
            "后天", day: TodoDeadlineShortcuts.day(now: model.now, zone: zone, offset: 2),
            identifier: "day-after-tomorrow", move: move, includesDate: true)
          dayChoice(
            "下周一", day: TodoDeadlineShortcuts.nextWeek(now: model.now, zone: zone),
            identifier: "next-monday", move: move, includesDate: true)
        }
        HStack(spacing: Tokens.V1.Space.xs) {
          choice("无期限", selected: move.dueMode == .none) { choose(.none) }
            .runtimeAccessibilityIdentifier("todos.move.none")
          calendarChoice(move)
        }
      }
    }
  }

  private func dayChoice(
    _ title: String, day: String?, identifier: String, move: TodoQuadrantMove,
    includesDate: Bool = false
  ) -> some View {
    let due = day.map {
      TodoDue.date(TodoDay(day: $0, timeZoneIdentifier: move.timeZoneIdentifier))
    }
    let rejection = due.flatMap(model.moveDueRejection)
    return choice(
      includesDate ? "\(title) \(day.map(TodoText.monthDay) ?? "")" : title,
      selected: move.dueMode == .date && day == move.day
    ) {
      if let due { choose(due) }
    }
    .disabled(due == nil || rejection != nil)
    .help(rejection ?? day ?? "日期不可用")
    .runtimeAccessibilityIdentifier("todos.move.\(identifier)")
  }

  private func calendarChoice(_ move: TodoQuadrantMove) -> some View {
    choice("选日期…", selected: showsCalendar) { showsCalendar = true }
      .runtimeAccessibilityIdentifier("todos.move.date")
      .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
        TodoDeadlineCalendar(
          due: Binding(
            get: { selectedDue },
            set: {
              choose($0)
              showsCalendar = false
            }),
          now: model.now, timeZoneIdentifier: move.timeZoneIdentifier,
          identifier: "todos.move.date", showsShortcuts: false, showsPending: false,
          dateRejection: { model.moveDueRejection(.date($0)) })
      }
  }

  private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(Tokens.V1.Text.meta.font)
        .foregroundStyle(selected ? Tokens.V1.Color.accent : Tokens.V1.Color.ink)
        .frame(maxWidth: .infinity, minHeight: Tokens.V1.Size.control)
        .background(
          selected ? Tokens.V1.Color.accentSoft : Tokens.V1.Color.raised,
          in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
            .strokeBorder(
              selected ? Tokens.V1.Color.accent : Tokens.V1.Color.controlRule,
              lineWidth: Tokens.V1.Size.controlRuleWidth))
    }
    .buttonStyle(.plain)
  }

  private var selectedDue: TodoDue {
    guard let move = model.move else { return .pending }
    switch move.dueMode {
    case .none: return .none
    case .pending: return .pending
    case .date:
      guard !move.day.isEmpty else { return .pending }
      return .date(TodoDay(day: move.day, timeZoneIdentifier: move.timeZoneIdentifier))
    }
  }

  private func afterDue(_ move: TodoQuadrantMove) -> String {
    if move.dueMode == .date && move.day.isEmpty { return "选一个" }
    return TodoDeadlineCalendar.label(selectedDue)
  }

  private func choose(_ due: TodoDue) {
    guard model.moveDueRejection(due) == nil else { return }
    model.updateMove { move in
      switch due {
      case .pending: move.dueMode = .pending
      case .none: move.dueMode = .none
      case .date(let day):
        move.dueMode = .date
        move.day = day.day
        move.timeZoneIdentifier = day.timeZoneIdentifier
      }
    }
  }
}
