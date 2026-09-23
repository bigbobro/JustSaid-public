import Foundation

public enum TodoOpenGroup: String, Equatable, Sendable {
  case overdue
  case pinned
  case dueToday
  case later
  case undated
}

public struct TodoOpenSection: Equatable, Sendable {
  public var group: TodoOpenGroup
  public var items: [TodoItem]

  public init(group: TodoOpenGroup, items: [TodoItem]) {
    self.group = group
    self.items = items
  }
}

public struct TodoCompletedSections: Equatable, Sendable {
  public var known: [TodoItem]
  public var unknownTime: [TodoItem]

  public init(known: [TodoItem], unknownTime: [TodoItem]) {
    self.known = known
    self.unknownTime = unknownTime
  }
}

public enum TodoQuadrant: String, Equatable, Sendable {
  case importantUrgent
  case importantNotUrgent
  case urgentNotImportant
  case neither
  case duePending
}

public struct TodoQuadrantBoard: Equatable, Sendable {
  public var importantUrgent: [TodoItem]
  public var importantNotUrgent: [TodoItem]
  public var urgentNotImportant: [TodoItem]
  public var neither: [TodoItem]
  public var duePending: [TodoItem]

  public var total: Int {
    importantUrgent.count + importantNotUrgent.count + urgentNotImportant.count + neither.count
      + duePending.count
  }

  public init(
    importantUrgent: [TodoItem],
    importantNotUrgent: [TodoItem],
    urgentNotImportant: [TodoItem],
    neither: [TodoItem],
    duePending: [TodoItem]
  ) {
    self.importantUrgent = importantUrgent
    self.importantNotUrgent = importantNotUrgent
    self.urgentNotImportant = urgentNotImportant
    self.neither = neither
    self.duePending = duePending
  }
}

public enum TodoOrdering {
  public static func openGroup(of item: TodoItem, now: Date) -> TodoOpenGroup? {
    guard item.status == .open, item.removedAt == nil else { return nil }
    if let day = dated(item), let timeZone = timeZone(of: day),
      TodoCalendar.isOverdue(day: day.day, timeZone: timeZone, now: now)
    {
      return .overdue
    }
    if item.pinnedAt != nil { return .pinned }
    if let day = dated(item), let timeZone = timeZone(of: day),
      TodoCalendar.dayString(of: now, timeZone: timeZone) == day.day
    {
      return .dueToday
    }
    if dated(item) != nil { return .later }
    return .undated
  }

  public static func openSections(_ items: [TodoItem], now: Date) -> [TodoOpenSection] {
    sections(items, now: now, groups: [.overdue, .pinned, .dueToday, .later, .undated])
  }

  /// 逾期、今天到期、已钉住的并集。钉住的未来项留在钉住组里，并保留自己的日期。
  public static func todaySections(_ items: [TodoItem], now: Date) -> [TodoOpenSection] {
    sections(items, now: now, groups: [.overdue, .pinned, .dueToday])
  }

  public static func completedSections(_ items: [TodoItem]) -> TodoCompletedSections {
    let done = items.filter { $0.status == .done && $0.removedAt == nil }
    let unknown = done.filter(\.completionTimeUnknown).sorted(by: stableIdentity)
    let known = done.filter { !$0.completionTimeUnknown }.sorted { lhs, rhs in
      let left = lhs.completedAt ?? .distantPast
      let right = rhs.completedAt ?? .distantPast
      if left != right { return left > right }
      return stableIdentity(lhs, rhs)
    }
    return TodoCompletedSections(known: known, unknownTime: unknown)
  }

  public static func quadrant(of item: TodoItem, now: Date) -> TodoQuadrant? {
    guard item.status == .open, item.removedAt == nil else { return nil }
    if case .pending = item.due { return .duePending }
    let important = item.priority == .high
    let urgent = isUrgent(item, now: now)
    switch (important, urgent) {
    case (true, true): return .importantUrgent
    case (true, false): return .importantNotUrgent
    case (false, true): return .urgentNotImportant
    case (false, false): return .neither
    }
  }

  public static func quadrantBoard(_ items: [TodoItem], now: Date) -> TodoQuadrantBoard {
    func placed(_ quadrant: TodoQuadrant) -> [TodoItem] {
      items.filter { Self.quadrant(of: $0, now: now) == quadrant }
        .sorted { comesBefore($0, $1, now: now) }
    }
    return TodoQuadrantBoard(
      importantUrgent: placed(.importantUrgent),
      importantNotUrgent: placed(.importantNotUrgent),
      urgentNotImportant: placed(.urgentNotImportant),
      neither: placed(.neither),
      duePending: placed(.duePending)
    )
  }

  public static func overdueDayCount(_ item: TodoItem, now: Date) -> Int? {
    guard let day = dated(item), let timeZone = timeZone(of: day),
      TodoCalendar.isOverdue(day: day.day, timeZone: timeZone, now: now),
      let today = TodoCalendar.dayString(of: now, timeZone: timeZone)
    else { return nil }
    return TodoCalendar.dayCount(from: day.day, to: today)
  }

  /// 有明确日期，并且那个日期不晚于该时区的明天（逾期全部算紧急）。无期限不紧急。
  public static func isUrgent(_ item: TodoItem, now: Date) -> Bool {
    guard let day = dated(item), let timeZone = timeZone(of: day),
      let today = TodoCalendar.dayString(of: now, timeZone: timeZone),
      let tomorrow = TodoCalendar.addingDays(1, to: today, timeZone: timeZone)
    else { return false }
    return day.day <= tomorrow
  }

  public static func comesBefore(_ lhs: TodoItem, _ rhs: TodoItem, now: Date) -> Bool {
    let left = openGroup(of: lhs, now: now)
    let right = openGroup(of: rhs, now: now)
    if left != right { return rank(left) < rank(right) }
    switch left {
    case .overdue:
      return compare(dueDay(lhs), dueDay(rhs))
        || (dueDay(lhs) == dueDay(rhs) && comparePriority(lhs, rhs))
    case .pinned:
      return compare(lhs.pinnedAt, rhs.pinnedAt) || (lhs.pinnedAt == rhs.pinnedAt && stableIdentity(lhs, rhs))
    case .dueToday, .undated:
      return comparePriority(lhs, rhs)
    case .later:
      return compare(dueDay(lhs), dueDay(rhs))
        || (dueDay(lhs) == dueDay(rhs) && comparePriority(lhs, rhs))
    case nil:
      return stableIdentity(lhs, rhs)
    }
  }

  private static func sections(
    _ items: [TodoItem],
    now: Date,
    groups: [TodoOpenGroup]
  ) -> [TodoOpenSection] {
    groups.compactMap { group in
      let grouped = items.filter { openGroup(of: $0, now: now) == group }
        .sorted { comesBefore($0, $1, now: now) }
      return grouped.isEmpty ? nil : TodoOpenSection(group: group, items: grouped)
    }
  }

  private static func dated(_ item: TodoItem) -> TodoDay? {
    if case .date(let day) = item.due { return day }
    return nil
  }

  private static func timeZone(of day: TodoDay) -> TimeZone? {
    TimeZone(identifier: day.timeZoneIdentifier)
  }

  private static func dueDay(_ item: TodoItem) -> String {
    dated(item)?.day ?? ""
  }

  private static func rank(_ group: TodoOpenGroup?) -> Int {
    switch group {
    case .overdue: return 0
    case .pinned: return 1
    case .dueToday: return 2
    case .later: return 3
    case .undated: return 4
    case nil: return 5
    }
  }

  private static func priorityRank(_ priority: TodoPriority) -> Int {
    switch priority {
    case .high: return 0
    case .normal: return 1
    case .low: return 2
    }
  }

  private static func comparePriority(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
    let left = priorityRank(lhs.priority)
    let right = priorityRank(rhs.priority)
    if left != right { return left < right }
    return stableIdentity(lhs, rhs)
  }

  private static func compare(_ lhs: String, _ rhs: String) -> Bool {
    lhs < rhs
  }

  private static func compare(_ lhs: Date?, _ rhs: Date?) -> Bool {
    guard let lhs, let rhs, lhs != rhs else { return false }
    return lhs < rhs
  }

  private static func stableIdentity(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
