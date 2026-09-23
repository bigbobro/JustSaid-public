import Foundation
import JustSaidCore

public enum TodoScope: String, CaseIterable, Identifiable, Equatable {
  case open
  case pending
  case today
  case overdue
  case pinned
  case done

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .open: "全部未完成"
    case .pending: "待补全"
    case .today: "今天"
    case .overdue: "逾期"
    case .pinned: "已钉住"
    case .done: "已完成"
    }
  }
}

public enum TodoLayout: String, CaseIterable, Identifiable, Equatable {
  case list
  case matrix

  public var id: String { rawValue }

  public var title: String {
    self == .list ? "列表" : "四象限"
  }
}

enum TodoText {
  static let matrixDisabledReason = "已完成按完成时间排列，不用四象限"
  static let readFailureBanner = "无法读取待办。原文件已保留，重新读取前暂停更改"
  static let readFailureTitle = "待办暂时打不开"
  static let readFailureDetail = "无法解析保存的内容"
  static let emptyTitle = "还没有待办"
  static let emptyDetail = "从会议中挑选要跟进的事，或新增一条"
  static let emptyAction = "查看会议"
  static let noOpenTitle = "没有未完成待办"
  static let noOpenDetail = "已完成的事项仍可查看和撤销"
  static let noOpenAction = "查看已完成"
  static let noMatchTitle = "没有符合条件的待办"
  static let noMatchDetail = "换个搜索词试试"
  static let noMatchAction = "清除搜索"
  static let loading = "正在读取待办…"
  static let pinLimit = "最多钉住 3 条，先取消一条再试"
  static let manualSource = "手工新增"
  static let noMeetingSource = "无会议来源"
  static let unavailable = "来源暂不可用"
  static let deleted = "已删除"
  static let quadrantEmpty = "这里还没有待办"
  static let quadrantFiltered = "当前范围没有这类待办"

  static func summary(count: Int, now: Date) -> String {
    "\(count) 条 · \(ChineseDateText.dayWithWeekday(now))"
  }

  static func assignee(_ assignee: TodoAssignee) -> String {
    switch assignee {
    case .me: "我"
    case .pending: "待确认"
    case .named(let name): name
    }
  }

  static func priority(_ priority: TodoPriority) -> String {
    switch priority {
    case .high: "高"
    case .normal: "普通"
    case .low: "低"
    }
  }

  static func priorityPhrase(_ priority: TodoPriority) -> String {
    switch priority {
    case .high: "高优先级"
    case .normal: "普通优先级"
    case .low: "低优先级"
    }
  }

  static func monthDay(_ day: String) -> String {
    guard let parts = TodoCalendar.parts(day) else { return day }
    return "\(parts.month)月\(parts.day)日"
  }

  static func groupTitle(_ group: TodoOpenGroup) -> String {
    switch group {
    case .overdue: "逾期"
    case .pinned: "钉住"
    case .dueToday: "今天到期"
    case .later: "以后"
    case .undated: "未设日期"
    }
  }

  static func quadrantTitle(_ quadrant: TodoQuadrant) -> String {
    switch quadrant {
    case .importantUrgent: "重要且紧急"
    case .importantNotUrgent: "重要但不紧急"
    case .urgentNotImportant: "不重要但紧急"
    case .neither: "不重要且不紧急"
    case .duePending: "截止待确认"
    }
  }

  static func quadrantHint(_ quadrant: TodoQuadrant) -> String {
    switch quadrant {
    case .importantUrgent: "先处理"
    case .importantNotUrgent: "安排时间"
    case .urgentNotImportant: "及时处理"
    case .neither: "稍后考虑"
    case .duePending: ""
    }
  }

  static func pinnedMeta(total: Int, overdue: Int) -> String {
    "\(total) / 3 · 含逾期 \(overdue) 条"
  }

  static func saveFailure(_ reason: String) -> String {
    "未能保存：\(reason)。填写内容已保留"
  }

  static func reason(of error: Error) -> String {
    if let todo = error as? TodoStoreError {
      return todo.errorDescription ?? "未能写入"
    }
    let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "未能写入" : text
  }

  /// 第一行是「逾期 N 天」或日期本身；逾期时第二行是真实日期。
  static func due(of item: TodoItem, now: Date) -> (
    primary: String, secondary: String?, emphasized: Bool
  ) {
    if item.status == .done, case .date(let day) = item.due {
      return ("原截止 \(monthDay(day.day))", nil, false)
    }
    if let count = TodoOrdering.overdueDayCount(item, now: now), case .date(let day) = item.due {
      return ("逾期 \(count) 天", monthDay(day.day), true)
    }
    switch item.due {
    case .none:
      return ("无期限", nil, false)
    case .pending:
      return ("截止待确认", nil, false)
    case .date(let day):
      let zone = TimeZone(identifier: day.timeZoneIdentifier)
      let today = zone.flatMap { TodoCalendar.dayString(of: now, timeZone: $0) }
      if today == day.day {
        return ("今天 · \(monthDay(day.day))", nil, false)
      }
      return (monthDay(day.day), nil, false)
    }
  }

  static func duePhrase(_ due: TodoDue, now: Date, item: TodoItem) -> String {
    let lines = TodoText.due(of: item, now: now)
    if let secondary = lines.secondary {
      return "\(lines.primary) · \(secondary)"
    }
    return lines.primary
  }

  static func clientProject(_ item: TodoItem) -> String? {
    switch (item.client?.nilIfBlank, item.project?.nilIfBlank) {
    case (let client?, let project?): "\(client) / \(project)"
    case (let client?, nil): client
    case (nil, let project?): project
    case (nil, nil): nil
    }
  }
}

enum TodoClock {
  static func sourceTime(_ timecode: String) -> String {
    let parts = timecode.split(separator: ":")
    guard parts.count == 3, parts.first == "00" else { return timecode }
    return parts.dropFirst().joined(separator: ":")
  }

  static func zone(of item: TodoItem) -> TimeZone {
    if case .date(let day) = item.due, let zone = TimeZone(identifier: day.timeZoneIdentifier) {
      return zone
    }
    return SystemTimeZone.current
  }

  static func tomorrow(after now: Date, zone: TimeZone) -> String? {
    guard let today = TodoCalendar.dayString(of: now, timeZone: zone) else { return nil }
    return TodoCalendar.addingDays(1, to: today, timeZone: zone)
  }

  static func isUrgentDay(_ day: String, now: Date, zone: TimeZone) -> Bool {
    guard let tomorrow = tomorrow(after: now, zone: zone) else { return false }
    return day <= tomorrow
  }

  static func pickerDate(day: String) -> Date {
    let zone = SystemTimeZone.current
    let start = TodoCalendar.start(of: day, timeZone: zone) ?? Date()
    return start.addingTimeInterval(12 * 60 * 60)
  }

  static func dayString(from date: Date) -> String {
    TodoCalendar.dayString(of: date, timeZone: SystemTimeZone.current) ?? ""
  }
}
