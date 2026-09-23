import Foundation

/// 界面上的日期:中文措辞,**本机当前系统时区**。
///
/// ## 时区
/// 一律用 `SystemTimeZone.current` —— 使用者这台机器**系统偏好里选的**那个时区,
/// 不认 `TZ` 环境变量(那是启动进程的终端的事,不是使用者的设置)。
/// 盘上 `meeting.json` 存的是绝对时刻,显示时才换算——出差改了时区、夏令时切换,
/// 界面都跟着走。
///
/// 缓存**每次命中前先比一次当前系统时区**,变了当场丢弃重建,
/// 不用等重开 app,也不用挂通知。
///
/// ## 为什么要缓存
/// `DateFormatter()` 建一个实测 **156 µs**;复用是 **1.0 µs**,带时区校验是 **1.71 µs**。
/// 会议库一次列表重建约 75 次调用——每次新建就是 ~12 ms,逼近一帧预算(16.7 ms)。
/// 所以「跟随系统时区」本身不花钱,花钱的是原来那种每次新建的写法。
///
/// ## 为什么集中在这里
/// `Date.formatted(.dateTime…)` 跟系统语言走,开发机是英文时就成了「Sun, Sep 20」。
/// 同一个 bug 先后出现在会议库日期分隔条、首页顶栏、首页会议行三处,所以收到一处。
///
/// 调用方有主线程的视图,也有非隔离的静态助手,所以缓存用锁而不是 actor 隔离——
/// 一个格式化工具不该把隔离要求传染给每一个想显示日期的地方。
/// 锁是无争用的(实测量级 0.02 µs),相对 156 µs 的重建可以忽略。
public enum ChineseDateText {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

  /// 显示时区换了之后把缓存丢掉。缓存本身也按时区自检,这里是换的那一刻立刻生效,
  /// 不等下一次自检。
  public static func invalidateFormatterCache() {
    lock.lock()
    defer { lock.unlock() }
    cache.removeAll()
  }

  /// 固定 `dateFormat` 而不是 `setLocalizedDateFormatFromTemplate`:
  /// 后者对「Md」在 zh_Hans 下给的是「7/28」,设计稿要的是「9月16日」。
  private static func formatter(_ format: String) -> DateFormatter {
    let zone = SystemTimeZone.current
    lock.lock()
    defer { lock.unlock() }
    // 时区没变就复用。变了(改设置/出差/夏令时)当场重建,不用等重开 app。
    if let cached = cache[format], cached.timeZone == zone {
      return cached
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_Hans")
    f.calendar = SystemTimeZone.calendar
    f.timeZone = zone
    f.dateFormat = format
    cache[format] = f
    return f
  }

  /// 「9月20日 周日」。首页顶栏。
  public static func dayWithWeekday(_ date: Date = .now) -> String {
    formatter("M月d日 EEE").string(from: date)
  }

  /// 「9月20日 17:00」。列表行:同年不写年份。
  public static func dayAndTime(_ date: Date, now: Date = .now) -> String {
    let sameYear = SystemTimeZone.calendar.isDate(date, equalTo: now, toGranularity: .year)
    return formatter(sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm").string(from: date)
  }

  /// 「2026年9月20日 17:00」。会议详情页的完整写法,始终带年份。
  public static func fullDayAndTime(_ date: Date) -> String {
    formatter("yyyy年M月d日 HH:mm").string(from: date)
  }

  /// 「09-20 17:00」。会议库列表紧凑档:同年只留月日。
  public static func compactDayAndTime(_ date: Date, now: Date = .now) -> String {
    let sameYear = SystemTimeZone.calendar.isDate(date, equalTo: now, toGranularity: .year)
    return formatter(sameYear ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm").string(from: date)
  }

  /// 「17:00」。只要钟点。
  public static func time(_ date: Date) -> String {
    formatter("HH:mm").string(from: date)
  }

  /// 日期分组头:今天/昨天是人真正在找的两档,其余给「月日 + 周几」。
  /// 日历每次现取——今天/昨天的判定必须用此刻的系统时区定的日界。
  public static func dayHeader(_ day: Date, now: Date = .now) -> String {
    let calendar = SystemTimeZone.calendar
    if calendar.isDateInToday(day) { return "今天" }
    if calendar.isDateInYesterday(day) { return "昨天" }
    let sameYear = calendar.isDate(day, equalTo: now, toGranularity: .year)
    return formatter(sameYear ? "M月d日 EEE" : "yyyy年M月d日 EEE").string(from: day)
  }
}
