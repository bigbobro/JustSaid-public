import Foundation

/// Nonsecret intent only. Directory updates and temporary fallbacks never write this key.
@MainActor
public final class MicrophoneInputSettings {
  public static let defaultsKey = "justsaid.microphone.inputPreference"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> MicrophoneInputPreference {
    guard let data = defaults.data(forKey: Self.defaultsKey),
      let preference = try? JSONDecoder().decode(MicrophoneInputPreference.self, from: data)
    else { return .automatic }
    if case .device(let uid, _) = preference, uid.rawValue.isEmpty { return .automatic }
    return preference
  }

  func save(_ preference: MicrophoneInputPreference) {
    guard let data = try? JSONEncoder().encode(preference) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }
}
