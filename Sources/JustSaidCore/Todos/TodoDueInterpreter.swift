import Foundation

public enum TodoDueChoiceReason: String, Equatable, Sendable {
  /// 「…前」是否把当天算进去。
  case inclusiveBoundary
  /// 「三天内」这一类是否把参照日当天算进去。
  case withinIncludesReferenceDay
  /// 没写年份，参照日之前的月日可能是今年或明年。
  case missingYear
  case boundaryAndYear

  public var detail: String {
    switch self {
    case .inclusiveBoundary:
      return "「前」是否包含当天还没确定"
    case .withinIncludesReferenceDay:
      return "「以内」是否包含当天还没确定"
    case .missingYear:
      return "没写年份，可能是今年或明年"
    case .boundaryAndYear:
      return "「前」和年份都还没确定"
    }
  }
}

public enum TodoDueResolution: Equatable, Sendable {
  case day(TodoDay)
  case choose([TodoDay], TodoDueChoiceReason)
  case unresolved
}

public enum TodoCalendar {
  public static func gregorian(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  public static func dayString(of date: Date, timeZone: TimeZone) -> String? {
    let parts = gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
    return format(year: year, month: month, day: day)
  }

  public static func make(year: Int, month: Int, day: Int, timeZone: TimeZone) -> String? {
    guard let date = gregorian(timeZone).date(from: DateComponents(
      year: year, month: month, day: day, hour: 0, minute: 0, second: 0
    )) else { return nil }
    let read = gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
    guard read.year == year, read.month == month, read.day == day else { return nil }
    return format(year: year, month: month, day: day)
  }

  public static func start(of day: String, timeZone: TimeZone) -> Date? {
    let parts = day.split(separator: "-")
    guard parts.count == 3,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let dayNumber = Int(parts[2])
    else { return nil }
    guard make(year: year, month: month, day: dayNumber, timeZone: timeZone) == day else { return nil }
    return gregorian(timeZone).date(from: DateComponents(
      year: year, month: month, day: dayNumber, hour: 0, minute: 0, second: 0
    ))
  }

  public static func addingDays(_ days: Int, to day: String, timeZone: TimeZone) -> String? {
    guard let date = start(of: day, timeZone: timeZone),
      let shifted = gregorian(timeZone).date(byAdding: .day, value: days, to: date)
    else { return nil }
    return dayString(of: shifted, timeZone: timeZone)
  }

  public static func isValid(_ day: TodoDay) -> Bool {
    guard let timeZone = TimeZone(identifier: day.timeZoneIdentifier) else { return false }
    let parts = day.day.split(separator: "-")
    guard parts.count == 3,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let dayNumber = Int(parts[2])
    else { return false }
    return make(year: year, month: month, day: dayNumber, timeZone: timeZone) == day.day
  }

  /// 当天在该时区结束后才算逾期：到期日的日历日严格早于 `now` 的日历日。
  public static func isOverdue(day: String, timeZone: TimeZone, now: Date) -> Bool {
    guard let today = dayString(of: now, timeZone: timeZone) else { return false }
    return day < today
  }

  /// 两个 `yyyy-MM-dd` 相差的日历日。用 UTC 的日历日，不用当地零点的瞬时，
  /// 避免零点被跳过的时区（如 America/Santiago 2026-09-06）少算一天。
  public static func dayCount(from earlier: String, to later: String) -> Int? {
    guard let start = parts(earlier), let end = parts(later) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    guard
      let fromDate = calendar.date(from: DateComponents(year: start.year, month: start.month, day: start.day)),
      let toDate = calendar.date(from: DateComponents(year: end.year, month: end.month, day: end.day))
    else { return nil }
    return calendar.dateComponents([.day], from: fromDate, to: toDate).day
  }

  public static func parts(_ day: String) -> (year: Int, month: Int, day: Int)? {
    let pieces = day.split(separator: "-")
    guard pieces.count == 3,
      let year = Int(pieces[0]),
      let month = Int(pieces[1]),
      let dayNumber = Int(pieces[2])
    else { return nil }
    return (year, month, dayNumber)
  }

  public static func weekStart(containing day: String, timeZone: TimeZone) -> String? {
    guard let date = start(of: day, timeZone: timeZone) else { return nil }
    let weekday = gregorian(timeZone).component(.weekday, from: date)
    let mondayOffset = (weekday + 5) % 7
    return addingDays(-mondayOffset, to: day, timeZone: timeZone)
  }

  public static func lastDay(year: Int, month: Int, timeZone: TimeZone) -> String? {
    var nextYear = year
    var nextMonth = month + 1
    if nextMonth > 12 {
      nextMonth = 1
      nextYear += 1
    }
    guard let firstOfNext = make(year: nextYear, month: nextMonth, day: 1, timeZone: timeZone) else {
      return nil
    }
    return addingDays(-1, to: firstOfNext, timeZone: timeZone)
  }

  private static func format(year: Int, month: Int, day: Int) -> String {
    String(format: "%04d-%02d-%02d", year, month, day)
  }
}

public enum TodoDueInterpreter {
  /// 参照日是这场会的 `startedAt` 在 `timeZone` 里的日历日，不是电脑上的今天。
  public static func interpret(
    text: String,
    reference: Date,
    timeZone: TimeZone
  ) -> TodoDueResolution {
    let basis = reference
    guard let referenceDay = TodoCalendar.dayString(of: basis, timeZone: timeZone) else {
      return .unresolved
    }
    let compact = String(text.unicodeScalars.filter {
      !CharacterSet.whitespacesAndNewlines.contains($0)
    })
    if compact.isEmpty || isHourLevel(compact) || vague.contains(compact) {
      return .unresolved
    }
    let (core, hasBoundary) = strippingBoundary(compact)
    let resolved = interpretCore(core, referenceDay: referenceDay, timeZone: timeZone)
    guard hasBoundary else { return resolved }
    return applyingBoundary(resolved, timeZone: timeZone)
  }

  public static func isBeforeReference(
    _ day: TodoDay,
    reference: Date,
    timeZone: TimeZone
  ) -> Bool {
    guard let referenceDay = TodoCalendar.dayString(of: reference, timeZone: timeZone) else {
      return false
    }
    return day.day < referenceDay
  }

  private static let vague: Set<String> = ["尽快", "尽早", "马上", "随时", "节前", "年前", "尽快完成", "尽快处理"]

  private static func isHourLevel(_ text: String) -> Bool {
    if text.contains("点") || text.contains("分钟") || text.contains("小时") { return true }
    return text.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil
  }

  private static func strippingBoundary(_ text: String) -> (String, Bool) {
    for suffix in ["之前", "以前", "前"] where text.hasSuffix(suffix) && text.count > suffix.count {
      let base = String(text.dropLast(suffix.count))
      if !base.isEmpty { return (base, true) }
    }
    return (text, false)
  }

  private static func interpretCore(
    _ text: String,
    referenceDay: String,
    timeZone: TimeZone
  ) -> TodoDueResolution {
    guard let referenceParts = TodoCalendar.parts(referenceDay) else { return .unresolved }
    switch text {
    case "今天":
      return .day(makeDay(referenceDay, timeZone))
    case "明天":
      return shift(1, from: referenceDay, timeZone: timeZone)
    case "后天":
      return shift(2, from: referenceDay, timeZone: timeZone)
    case "月底", "本月底":
      guard let last = TodoCalendar.lastDay(
        year: referenceParts.year, month: referenceParts.month, timeZone: timeZone
      ) else { return .unresolved }
      return .day(makeDay(last, timeZone))
    case "下月底":
      var month = referenceParts.month + 1
      var year = referenceParts.year
      if month > 12 {
        month = 1
        year += 1
      }
      guard let last = TodoCalendar.lastDay(year: year, month: month, timeZone: timeZone) else {
        return .unresolved
      }
      return .day(makeDay(last, timeZone))
    default:
      break
    }
    if let token = captures(#"(?:本周|这周|本星期|这星期|本礼拜|这礼拜)([一二三四五六日天])"#, text)?.first {
      return weekday(token, nextWeek: false, referenceDay: referenceDay, timeZone: timeZone)
    }
    if let token = captures(#"(?:下周|下星期|下礼拜)([一二三四五六日天])"#, text)?.first {
      return weekday(token, nextWeek: true, referenceDay: referenceDay, timeZone: timeZone)
    }
    if captures(#"(?:周|星期|礼拜)([一二三四五六日天])"#, text) != nil {
      return .unresolved
    }
    if let token = captures(#"(\d+|[一二两三四五六七八九十])天内"#, text)?.first {
      return within(token, referenceDay: referenceDay, timeZone: timeZone)
    }
    if let groups = captures(#"下个?月(\d{1,2})(?:日|号)"#, text), let day = Int(groups[0]) {
      return nextMonth(day, reference: referenceParts, timeZone: timeZone)
    }
    if let groups = captures(#"本月(\d{1,2})(?:日|号)"#, text), let day = Int(groups[0]) {
      return explicit(
        year: referenceParts.year, month: referenceParts.month, day: day, timeZone: timeZone
      )
    }
    if let groups = captures(#"(\d{4})年(\d{1,2})月(\d{1,2})(?:日|号)"#, text),
      let year = Int(groups[0]), let month = Int(groups[1]), let day = Int(groups[2])
    {
      return explicit(year: year, month: month, day: day, timeZone: timeZone)
    }
    if let groups = captures(#"(\d{1,2})月(\d{1,2})(?:日|号)"#, text),
      let month = Int(groups[0]), let day = Int(groups[1])
    {
      return missingYear(month: month, day: day, referenceDay: referenceDay, timeZone: timeZone)
    }
    if let groups = captures(#"(\d{4})[./-](\d{1,2})[./-](\d{1,2})"#, text),
      let year = Int(groups[0]), let month = Int(groups[1]), let day = Int(groups[2])
    {
      return explicit(year: year, month: month, day: day, timeZone: timeZone)
    }
    return .unresolved
  }

  private static func weekday(
    _ token: String,
    nextWeek: Bool,
    referenceDay: String,
    timeZone: TimeZone
  ) -> TodoDueResolution {
    guard let monday = TodoCalendar.weekStart(containing: referenceDay, timeZone: timeZone),
      let offset = weekdayOffset(token)
    else { return .unresolved }
    return shift((nextWeek ? 7 : 0) + offset, from: monday, timeZone: timeZone)
  }

  private static func weekdayOffset(_ token: String) -> Int? {
    switch token {
    case "一": return 0
    case "二": return 1
    case "三": return 2
    case "四": return 3
    case "五": return 4
    case "六": return 5
    case "日", "天": return 6
    default: return nil
    }
  }

  private static func within(
    _ token: String,
    referenceDay: String,
    timeZone: TimeZone
  ) -> TodoDueResolution {
    guard let count = smallNumber(token), count > 0,
      let included = TodoCalendar.addingDays(count - 1, to: referenceDay, timeZone: timeZone),
      let excluded = TodoCalendar.addingDays(count, to: referenceDay, timeZone: timeZone)
    else { return .unresolved }
    return .choose(
      [makeDay(included, timeZone), makeDay(excluded, timeZone)],
      .withinIncludesReferenceDay
    )
  }

  private static func smallNumber(_ token: String) -> Int? {
    if let value = Int(token) { return value }
    switch token {
    case "一": return 1
    case "二", "两": return 2
    case "三": return 3
    case "四": return 4
    case "五": return 5
    case "六": return 6
    case "七": return 7
    case "八": return 8
    case "九": return 9
    case "十": return 10
    default: return nil
    }
  }

  private static func nextMonth(
    _ day: Int,
    reference: (year: Int, month: Int, day: Int),
    timeZone: TimeZone
  ) -> TodoDueResolution {
    var year = reference.year
    var month = reference.month + 1
    if month > 12 {
      month = 1
      year += 1
    }
    return explicit(year: year, month: month, day: day, timeZone: timeZone)
  }

  private static func missingYear(
    month: Int,
    day: Int,
    referenceDay: String,
    timeZone: TimeZone
  ) -> TodoDueResolution {
    guard let reference = TodoCalendar.parts(referenceDay),
      let thisYear = TodoCalendar.make(
        year: reference.year, month: month, day: day, timeZone: timeZone
      )
    else { return .unresolved }
    if thisYear >= referenceDay {
      return .day(makeDay(thisYear, timeZone))
    }
    guard let nextYear = TodoCalendar.make(
      year: reference.year + 1, month: month, day: day, timeZone: timeZone
    ) else {
      return .day(makeDay(thisYear, timeZone))
    }
    return .choose([makeDay(thisYear, timeZone), makeDay(nextYear, timeZone)], .missingYear)
  }

  private static func explicit(
    year: Int,
    month: Int,
    day: Int,
    timeZone: TimeZone
  ) -> TodoDueResolution {
    guard let day = TodoCalendar.make(year: year, month: month, day: day, timeZone: timeZone) else {
      return .unresolved
    }
    return .day(makeDay(day, timeZone))
  }

  private static func shift(_ days: Int, from day: String, timeZone: TimeZone) -> TodoDueResolution {
    guard let shifted = TodoCalendar.addingDays(days, to: day, timeZone: timeZone) else {
      return .unresolved
    }
    return .day(makeDay(shifted, timeZone))
  }

  private static func applyingBoundary(
    _ resolution: TodoDueResolution,
    timeZone: TimeZone
  ) -> TodoDueResolution {
    switch resolution {
    case .day(let day):
      guard let previous = TodoCalendar.addingDays(-1, to: day.day, timeZone: timeZone) else {
        return .unresolved
      }
      return .choose([makeDay(previous, timeZone), day], .inclusiveBoundary)
    case .choose(let days, let reason):
      var options: [TodoDay] = []
      for day in days {
        if let previous = TodoCalendar.addingDays(-1, to: day.day, timeZone: timeZone) {
          options.append(makeDay(previous, timeZone))
        }
        options.append(day)
      }
      let unique = dedupe(options)
      guard !unique.isEmpty else { return .unresolved }
      let combined: TodoDueChoiceReason = reason == .missingYear ? .boundaryAndYear : reason
      return .choose(unique, combined)
    case .unresolved:
      return .unresolved
    }
  }

  private static func makeDay(_ day: String, _ timeZone: TimeZone) -> TodoDay {
    TodoDay(day: day, timeZoneIdentifier: timeZone.identifier)
  }

  private static func dedupe(_ days: [TodoDay]) -> [TodoDay] {
    var seen: Set<String> = []
    return days.filter { seen.insert($0.day).inserted }.sorted { $0.day < $1.day }
  }

  private static func captures(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    return (1..<match.numberOfRanges).map { index in
      let group = match.range(at: index)
      guard group.location != NSNotFound, let swiftRange = Range(group, in: text) else { return "" }
      return String(text[swiftRange])
    }
  }
}
