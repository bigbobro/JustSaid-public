import Combine
import Foundation

/// 界面用哪个时区显示时间。
///
/// ## 为什么不直接跟系统走
/// 跟着系统走,出差一落地整个会议库的时间就集体挪位——上周那场「下午三点的评审」
/// 忽然变成「早上七点」。时刻没变,但人记的是墙上时间,这种跳动是坏体验
/// (owner 2026-09-21)。
///
/// 所以:**首次运行取一次本机时区存下来,此后界面一律按它显示**;
/// 每次启动比一次本机时区,变了**问使用者**要不要换,不自作主张。
///
/// ## 为什么不认 `TZ` 环境变量
/// `TimeZone.current` / `Calendar.current` 都认 `TZ`——那是启动这个进程的那个终端的
/// 设置,不是使用者的设置。检测本机时区一律读 `/etc/localtime`(系统偏好一改它就重指)。
@MainActor
public final class DisplayTimeZone: ObservableObject {
  public enum Key {
    /// 正在用的显示时区标识符。空 = 还没固定过(首次运行)。
    public static let pinned = "justsaid.timeZone.pinned"
    /// 使用者看过并选择「保留旧的」的那个检测值。避免同一个变化反复问。
    public static let declined = "justsaid.timeZone.declined"
  }

  /// 检测到本机时区与正在用的不一致,且使用者还没对这个值表过态。
  public struct Drift: Equatable, Sendable {
    public let pinned: TimeZone
    public let detected: TimeZone
  }

  @Published public private(set) var pinned: TimeZone
  /// 非 nil = 有一个待使用者决定的变化。
  @Published public private(set) var drift: Drift?

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let machine = Self.machineTimeZone()
    if let saved = defaults.string(forKey: Key.pinned),
      let zone = TimeZone(identifier: saved)
    {
      pinned = zone
    } else {
      // 首次运行:取本机的固定下来,不问——这时没有「变化」可言。
      pinned = machine
      defaults.set(machine.identifier, forKey: Key.pinned)
    }
    refreshDrift()
  }

  /// 本机此刻的系统时区。读 `/etc/localtime`,不认 `TZ`。
  /// 读不出来(不是软链/权限异常)才退回 Foundation 的判断。
  /// 不碰任何主 actor 状态,所以不随类隔离——格式化路径在任意线程都要取得到。
  public nonisolated static func machineTimeZone() -> TimeZone {
    guard
      let destination = try? FileManager.default.destinationOfSymbolicLink(
        atPath: "/etc/localtime")
    else { return TimeZone.current }
    let parts = URL(fileURLWithPath: destination).pathComponents
    guard parts.count >= 2 else { return TimeZone.current }
    return TimeZone(identifier: parts.suffix(2).joined(separator: "/"))
      ?? parts.last.flatMap(TimeZone.init(identifier:))
      ?? TimeZone.current
  }

  /// 重新比一次本机时区。启动时与设置页点「检测本机时区」时调用。
  public func refreshDrift() {
    let machine = Self.machineTimeZone()
    guard machine.identifier != pinned.identifier else {
      drift = nil
      return
    }
    // 已经对这个值说过「保留旧的」就不再打扰;换成第三个时区会重新问。
    if defaults.string(forKey: Key.declined) == machine.identifier {
      drift = nil
      return
    }
    drift = Drift(pinned: pinned, detected: machine)
  }

  /// 用检测到的新时区替换。
  public func adopt(_ zone: TimeZone) {
    pinned = zone
    defaults.set(zone.identifier, forKey: Key.pinned)
    defaults.removeObject(forKey: Key.declined)
    drift = nil
    ChineseDateText.invalidateFormatterCache()
  }

  /// 保留正在用的,并记住这个决定。
  public func keepPinned() {
    if let detected = drift?.detected {
      defaults.set(detected.identifier, forKey: Key.declined)
    }
    drift = nil
  }

  /// 设置页里那句「现在按 X 显示,而这台电脑在 Y」。一致时返回 nil。
  public var machineMismatchNote: String? {
    let machine = Self.machineTimeZone()
    guard machine.identifier != pinned.identifier else { return nil }
    return "这台电脑现在是 \(Self.displayName(machine))；会议时间仍按 \(Self.displayName(pinned)) 显示。"
  }

  /// 「上海（GMT+8）」。标识符里的下划线换成空格,末段够用,不写整串路径。
  public static func displayName(_ zone: TimeZone) -> String {
    let city =
      zone.localizedName(for: .generic, locale: Locale(identifier: "zh_Hans"))
      ?? zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
      ?? zone.identifier
    let hours = Double(zone.secondsFromGMT()) / 3600
    let sign = hours < 0 ? "-" : "+"
    let magnitude = abs(hours)
    let offset =
      magnitude == magnitude.rounded()
      ? "GMT\(sign)\(Int(magnitude))"
      : String(format: "GMT\(sign)%.1f", magnitude)
    return "\(city)（\(offset)）"
  }
}

/// 界面格式化取时区的入口。默认跟着 `DisplayTimeZone` 走;
/// 没装配时(截图装置、纯逻辑验证)退回本机时区。
public enum SystemTimeZone {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var resolver: (() -> TimeZone)?
  nonisolated(unsafe) private static var override: TimeZone?

  public static var current: TimeZone {
    lock.lock()
    let resolver = resolver
    let override = override
    lock.unlock()
    if let override { return override }
    if let resolver { return resolver() }
    return DisplayTimeZone.machineTimeZone()
  }

  /// 跟着显示时区走的日历。`Calendar.current` 同样认 TZ,
  /// 而「今天/昨天」「同不同年」的判定全靠日历的时区定日界——不能漏了它。
  public static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = current
    calendar.locale = Locale(identifier: "zh_Hans")
    return calendar
  }

  /// App 启动时把显示时区接进来。
  public static func use(_ store: DisplayTimeZone) {
    lock.lock()
    resolver = { MainActor.assumeIsolated { store.pinned } }
    lock.unlock()
    ChineseDateText.invalidateFormatterCache()
  }

  /// 仅供验证装置摆出不同时区。传 nil 还原。
  public static func setOverrideForVerification(_ zone: TimeZone?) {
    lock.lock()
    override = zone
    lock.unlock()
    ChineseDateText.invalidateFormatterCache()
  }
}
