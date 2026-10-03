import Combine
import Foundation

/// 会议检测提醒的偏好：总开关（默认开）与用户点过「不再提醒」的 App 家族。
/// 按 App 家族 key 存（`AppIdentity.key`），同时存显示名给设置页列表用；不存 bundle ID 之外的任何内容。
@MainActor
public final class MeetingDetectionPreferencesStore: ObservableObject {
  public enum Key {
    public static let enabled = "justsaid.meetingDetection.enabled"
    public static let excludedApps = "justsaid.meetingDetection.excludedApps"
  }

  public struct ExcludedApp: Equatable, Identifiable, Sendable {
    public var key: String
    public var name: String
    public var id: String { key }
  }

  @Published public private(set) var isEnabled: Bool
  /// key → 显示名。
  @Published public private(set) var excludedApps: [String: String]

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
    excludedApps = defaults.dictionary(forKey: Key.excludedApps) as? [String: String] ?? [:]
  }

  public var excludedKeys: Set<String> { Set(excludedApps.keys) }

  /// 设置页列表：按名字排序。
  public var excludedList: [ExcludedApp] {
    excludedApps.map { ExcludedApp(key: $0.key, name: $0.value) }
      .sorted { ($0.name, $0.key) < ($1.name, $1.key) }
  }

  public func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: Key.enabled)
  }

  public func exclude(key: String, name: String) {
    excludedApps[key] = name
    defaults.set(excludedApps, forKey: Key.excludedApps)
  }

  public func removeExclusion(key: String) {
    guard excludedApps.removeValue(forKey: key) != nil else { return }
    defaults.set(excludedApps, forKey: Key.excludedApps)
  }
}
