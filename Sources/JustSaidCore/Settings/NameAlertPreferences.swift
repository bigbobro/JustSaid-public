import Combine
import Foundation

/// 点名提醒的持久偏好。只保存用户显式设置的值;不读取设备账号、会议名册或其他应用的配置。
public struct NameAlertPreferences: Equatable, Sendable {
  public enum DisplayMode: String, CaseIterable, Sendable {
    case dock
    case window
    case off
  }

  public enum ReminderStyle: String, CaseIterable, Sendable {
    case quiet
    case strong
  }

  /// 提醒开关。关闭只暂停提醒:录制中且别名有效时仍在本地匹配、记账去重,恢复后不重放。
  public var remindersEnabled: Bool
  public var soundEnabled: Bool
  /// 用户输入的名字/昵称原文;有效性由 `NameAlertAliasSet` 编译时判定。
  public var aliases: [String]
  public var displayMode: DisplayMode
  public var reminderStyle: ReminderStyle

  public init(
    remindersEnabled: Bool = false,
    soundEnabled: Bool = false,
    aliases: [String] = [],
    displayMode: DisplayMode = .dock,
    reminderStyle: ReminderStyle = .quiet
  ) {
    self.remindersEnabled = remindersEnabled
    self.soundEnabled = soundEnabled
    self.aliases = aliases
    self.displayMode = displayMode
    self.reminderStyle = reminderStyle
  }
}

/// 每个偏好一个非秘密 UserDefaults 键;缺失或类型/枚举值不认识时回落默认值,读取不回写,
/// 写入只动对应的一个键,不触碰其他设置。
@MainActor
public final class NameAlertPreferencesStore: ObservableObject {
  public enum Key {
    public static let remindersEnabled = "justsaid.nameAlerts.remindersEnabled"
    public static let soundEnabled = "justsaid.nameAlerts.soundEnabled"
    public static let aliases = "justsaid.nameAlerts.aliases"
    public static let displayMode = "justsaid.nameAlerts.displayMode"
    public static let reminderStyle = "justsaid.nameAlerts.reminderStyle"
  }

  @Published public private(set) var preferences: NameAlertPreferences
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preferences = Self.load(from: defaults)
  }

  public static func load(from defaults: UserDefaults) -> NameAlertPreferences {
    NameAlertPreferences(
      remindersEnabled: boolean(defaults.object(forKey: Key.remindersEnabled)),
      soundEnabled: boolean(defaults.object(forKey: Key.soundEnabled)),
      aliases: (defaults.array(forKey: Key.aliases) as? [String]) ?? [],
      displayMode: defaults.string(forKey: Key.displayMode).flatMap(
        NameAlertPreferences.DisplayMode.init(rawValue:)) ?? .dock,
      reminderStyle: defaults.string(forKey: Key.reminderStyle).flatMap(
        NameAlertPreferences.ReminderStyle.init(rawValue:)) ?? .quiet
    )
  }

  /// 只认布尔类型;Foundation 会把数值 0/1 桥接成 Bool,这里按类型不符回落为关。
  private static func boolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return false
    }
    return number.boolValue
  }

  public func setRemindersEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Key.remindersEnabled)
    preferences.remindersEnabled = enabled
  }

  public func setSoundEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Key.soundEnabled)
    preferences.soundEnabled = enabled
  }

  public func setAliases(_ aliases: [String]) {
    defaults.set(aliases, forKey: Key.aliases)
    preferences.aliases = aliases
  }

  public func setDisplayMode(_ mode: NameAlertPreferences.DisplayMode) {
    defaults.set(mode.rawValue, forKey: Key.displayMode)
    preferences.displayMode = mode
  }

  public func setReminderStyle(_ style: NameAlertPreferences.ReminderStyle) {
    defaults.set(style.rawValue, forKey: Key.reminderStyle)
    preferences.reminderStyle = style
  }
}
