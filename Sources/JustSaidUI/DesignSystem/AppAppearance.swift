import SwiftUI

/// JustSaid 的应用级外观偏好。`system` 不覆盖 macOS 的外观选择。
public enum AppAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  public static let defaultsKey = "justsaid.appearance"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .system:
      return "跟随系统"
    case .light:
      return "浅色"
    case .dark:
      return "深色"
    }
  }

  public var preferredColorScheme: ColorScheme? {
    switch self {
    case .system:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }

  public static func persisted(_ rawValue: String?) -> Self {
    guard let rawValue, let appearance = Self(rawValue: rawValue) else {
      return .system
    }
    return appearance
  }
}
