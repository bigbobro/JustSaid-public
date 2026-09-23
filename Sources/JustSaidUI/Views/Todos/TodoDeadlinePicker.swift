import JustSaidCore
import SwiftUI

/// Shared day-only control. Pending values never acquire a selected date by opening the popover.
struct TodoDeadlinePicker: View {
  @Binding var due: TodoDue
  let now: Date
  let timeZoneIdentifier: String
  var identifier: String
  var focusRequested = false
  var focusRequest = 0
  var compact = false
  @State private var isPresented = false
  @State private var hovering = false
  @FocusState private var focused: Bool

  var body: some View {
    Button {
      isPresented = true
    } label: {
      V1PopupLabel(
        value: due == .pending ? "选择日期" : TodoDeadlineCalendar.label(due),
        placeholder: due == .pending, size: compact ? .compact : .regular, symbol: "calendar"
      )
      .modifier(V1FormSurface(focused: isPresented || focused, hovered: hovering))
    }
    .buttonStyle(.plain).focused($focused).onHover { hovering = $0 }
    .runtimeAccessibilityIdentifier("\(identifier).control.date")
    .runtimeAccessibilityIdentifier(identifier)
    .onAppear { if focusRequested { isPresented = true } }
    .onChange(of: focusRequested) { _, value in if value { isPresented = true } }
    .onChange(of: focusRequest) { _, _ in
      if focusRequested { isPresented = true }
    }
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      TodoDeadlineCalendar(
        due: $due, now: now, timeZoneIdentifier: timeZoneIdentifier, identifier: identifier)
    }
  }
}

struct TodoDeadlineCalendar: View {
  @Binding var due: TodoDue
  let now: Date
  let timeZoneIdentifier: String
  var identifier: String
  var showsShortcuts = true
  var showsPending = true
  var dateRejection: ((TodoDay) -> String?)?
  @State private var monthOffset = 0
  @State private var explicitDay = ""
  @State private var dateError: String?

  static func label(_ due: TodoDue) -> String {
    switch due {
    case .pending: "截止待确认"
    case .none: "无期限"
    case .date(let day): TodoText.monthDay(day.day)
    }
  }

  private var zone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? SystemTimeZone.current }
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.firstWeekday = 2
    return calendar
  }
  private var reference: Date {
    if case .date(let day) = due, let date = TodoCalendar.start(of: day.day, timeZone: zone) {
      return date
    }
    return now
  }
  private var month: Date {
    let parts = calendar.dateComponents([.year, .month], from: reference)
    let start = calendar.date(from: parts) ?? reference
    return calendar.date(byAdding: .month, value: monthOffset, to: start) ?? start
  }
  private var monthTitle: String {
    let parts = calendar.dateComponents([.year, .month], from: month)
    return "\(parts.year ?? 0) 年 \(parts.month ?? 0) 月"
  }
  private var daySlots: [Int?] {
    let leading = (calendar.component(.weekday, from: month) + 5) % 7
    let days = Array(calendar.range(of: .day, in: .month, for: month) ?? 1..<1)
    return Array(repeating: nil, count: leading) + days.map { Optional($0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      if showsShortcuts {
        HStack(spacing: Tokens.V1.Space.s2xs) {
          shortcut("今天", kind: "today", offset: 0)
          shortcut("明天", kind: "tomorrow", offset: 1)
          Button("下周") { choose(TodoDeadlineShortcuts.nextWeek(now: now, zone: zone)) }
            .buttonStyle(.v1Quiet)
            .runtimeAccessibilityIdentifier("\(identifier).next-week")
          Button("无期限") {
            due = .none
            explicitDay = ""
            dateError = nil
          }
          .buttonStyle(.v1Quiet)
          .runtimeAccessibilityIdentifier("\(identifier).none")
        }
        Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
      }
      HStack {
        Text(monthTitle).font(Tokens.V1.Text.strong.font)
        Spacer()
        Button {
          monthOffset -= 1
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.v1Icon)
        .accessibilityLabel("上个月")
        Button {
          monthOffset += 1
        } label: {
          Image(systemName: "chevron.right")
        }
        .buttonStyle(.v1Icon)
        .accessibilityLabel("下个月")
      }
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.V1.Space.s2xs), count: 7),
        spacing: Tokens.V1.Space.s2xs
      ) {
        ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) {
          index, label in
          Text(label).font(Tokens.V1.Text.micro.font).foregroundStyle(Tokens.V1.Color.ink3)
            .frame(height: Tokens.V1.Size.controlSm)
            .runtimeAccessibilityIdentifier("\(identifier).weekday.\(index)")
        }
        ForEach(Array(daySlots.enumerated()), id: \.offset) { _, day in
          if let day, let date = calendar.date(byAdding: .day, value: day - 1, to: month),
            let dayString = TodoCalendar.dayString(of: date, timeZone: zone)
          {
            Button {
              choose(dayString)
            } label: {
              Text("\(day)")
                .font(Tokens.V1.Text.body.font)
                .foregroundStyle(selected(dayString) ? Tokens.V1.Color.accent : Tokens.V1.Color.ink)
                .frame(maxWidth: .infinity, minHeight: Tokens.V1.Size.control)
                .background(
                  selected(dayString) ? Tokens.V1.Color.accentSoft : .clear,
                  in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
            }
            .buttonStyle(.plain)
            .disabled(rejection(for: dayString) != nil)
            .help(rejection(for: dayString) ?? dayString)
            .runtimeAccessibilityIdentifier("\(identifier).day.\(dayString)")
          } else {
            Color.clear.frame(height: Tokens.V1.Size.control).accessibilityHidden(true)
          }
        }
      }
      .runtimeAccessibilityIdentifier("\(identifier).calendar.monday-first")
      V1TextField(
        placeholder: "输入日期 YYYY-MM-DD", text: $explicitDay,
        identifier: "\(identifier).explicit", onCommit: { choose(explicitDay) })
      if let dateError {
        Text(dateError).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.warn)
          .runtimeAccessibilityIdentifier("\(identifier).error")
      }
      if showsPending {
        Button("截止待确认") {
          due = .pending
          explicitDay = ""
          dateError = nil
        }
        .buttonStyle(.v1Quiet)
        .runtimeAccessibilityIdentifier("\(identifier).pending")
      }
    }
    .padding(Tokens.V1.Space.md)
    .frame(width: Tokens.V1.Size.meetingRailWidth)
    .background(Tokens.V1.Color.raised)
    .onAppear { if case .date(let day) = due { explicitDay = day.day } }
    .runtimeAccessibilityIdentifier("\(identifier).popover")
  }

  private func selected(_ day: String) -> Bool {
    if case .date(let value) = due { return value.day == day }
    return false
  }

  private func rejection(for value: String) -> String? {
    dateRejection?(TodoDay(day: value, timeZoneIdentifier: zone.identifier))
  }

  private func shortcut(_ title: String, kind: String, offset: Int) -> some View {
    Button(title) { choose(TodoDeadlineShortcuts.day(now: now, zone: zone, offset: offset)) }
      .buttonStyle(.v1Quiet)
      .runtimeAccessibilityIdentifier("\(identifier).\(kind)")
  }

  private func choose(_ value: String?) {
    guard let value else { return }
    let day = TodoDay(
      day: value.trimmingCharacters(in: .whitespacesAndNewlines),
      timeZoneIdentifier: zone.identifier)
    guard TodoCalendar.isValid(day) else {
      dateError = "请输入有效日期，例如 2026-09-23"
      return
    }
    if let reason = dateRejection?(day) {
      dateError = reason
      return
    }
    due = .date(day)
    explicitDay = day.day
    monthOffset = 0
    dateError = nil
  }
}

enum TodoDeadlineShortcuts {
  static func day(now: Date, zone: TimeZone, offset: Int) -> String? {
    guard let today = TodoCalendar.dayString(of: now, timeZone: zone) else { return nil }
    return TodoCalendar.addingDays(offset, to: today, timeZone: zone)
  }

  static func nextWeek(now: Date, zone: TimeZone) -> String? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let weekdayFromMonday = (calendar.component(.weekday, from: now) + 5) % 7
    return day(now: now, zone: zone, offset: 7 - weekdayFromMonday)
  }
}

struct TodoFieldSurface: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(Tokens.V1.Color.raised, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
          .strokeBorder(Tokens.V1.Color.controlRule, lineWidth: Tokens.V1.Size.controlRuleWidth))
  }
}
