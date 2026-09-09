import Foundation

/// 用户显式配置的音频保留期。默认不删除——这是 04 票母带红线的例外,不是翻案。
public enum AudioRetentionPolicy: String, CaseIterable, Identifiable, Sendable {
  case never
  case days7
  case days15
  case days30
  case days90
  case days180

  public var id: String { rawValue }

  public static let defaultsKey = "justsaid.audioRetentionPolicy"

  public var dayCount: Int? {
    switch self {
    case .never: return nil
    case .days7: return 7
    case .days15: return 15
    case .days30: return 30
    case .days90: return 90
    case .days180: return 180
    }
  }

  public var displayName: String {
    switch self {
    case .never: return "不删除"
    case .days7: return "保留 7 天"
    case .days15: return "保留 15 天"
    case .days30: return "保留 1 个月"
    case .days90: return "保留 3 个月"
    case .days180: return "保留 6 个月"
    }
  }

  public static func current(in defaults: UserDefaults = .standard) -> AudioRetentionPolicy {
    guard let raw = defaults.string(forKey: defaultsKey) else { return .never }
    return AudioRetentionPolicy(rawValue: raw) ?? .never
  }

  public static func save(_ policy: AudioRetentionPolicy, in defaults: UserDefaults = .standard) {
    defaults.set(policy.rawValue, forKey: defaultsKey)
  }
}
