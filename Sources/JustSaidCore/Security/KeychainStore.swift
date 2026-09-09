import Foundation
import Security

public protocol ProviderSecretStore: Sendable {
  func save(_ secret: String, account: String) throws
  func contains(account: String) -> Bool
  func load(account: String) throws -> String?
}

public enum KeychainError: LocalizedError {
  case unexpectedStatus(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      return "无法写入 macOS Keychain（错误码 \(status)）"
    }
  }
}

/// 凭证统一存放于**单个** Keychain 条目(内含一份 account → secret 的 JSON)。
///
/// 为什么这么做:每个条目都有独立 ACL,应用重新签名后系统会**逐条**索要授权;
/// 4 个角色的密钥就意味着开机后连弹 4 次以上(2026-07-29 用户实测反馈)。
/// 合并成一条后,授权只需一次;条目内部再按 account 键取值。
/// 旧的多条目格式仍会被读取(向后兼容),读到后自动并入合并条目。
/// 进程内缓存:同一次运行中,合并条目只从 Keychain 读一次。
/// 目的是消除"一轮下来被问好几次"的体验(每次 SecItemCopyMatching 都可能触发授权框)。
private final class KeychainBundleCache: @unchecked Sendable {
  static let shared = KeychainBundleCache()
  private let lock = NSLock()
  private var cached: [String: [String: String]] = [:]

  func value(for service: String) -> [String: String]? {
    lock.lock()
    defer { lock.unlock() }
    return cached[service]
  }

  func set(_ bundle: [String: String], for service: String) {
    lock.lock()
    cached[service] = bundle
    lock.unlock()
  }
}

public struct KeychainStore: ProviderSecretStore, Sendable {
  public static let defaultService = "com.justsaid.provider-api-keys"
  public static let bundleAccount = "__justsaid_all_secrets__"

  private let service: String

  public init(service: String = KeychainStore.defaultService) {
    self.service = service
  }

  // MARK: - 合并条目读写

  private func loadBundle() -> [String: String] {
    if let cached = KeychainBundleCache.shared.value(for: service) {
      return cached
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: Self.bundleAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard
      SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    else {
      KeychainBundleCache.shared.set([:], for: service)
      return [:]
    }
    KeychainBundleCache.shared.set(decoded, for: service)
    return decoded
  }

  private func writeBundle(_ bundle: [String: String]) throws {
    let data = try JSONEncoder().encode(bundle)
    KeychainBundleCache.shared.set(bundle, for: service)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: Self.bundleAccount,
    ]
    if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
      let status = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    } else {
      var newItem = query
      newItem[kSecValueData as String] = data
      newItem[kSecAttrLabel as String] = "JustSaid 凭证(全部)"
      let status = SecItemAdd(newItem as CFDictionary, nil)
      guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }
  }

  public func save(_ secret: String, account: String) throws {
    var bundle = loadBundle()
    bundle[account] = secret
    try writeBundle(bundle)
  }

  public func contains(account: String) -> Bool {
    if loadBundle()[account] != nil { return true }
    // 兼容旧的独立条目
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: false,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  /// 读回已保存的密钥。仅用于界面显示“末四位”这类最小可验证提示，
  /// 密钥本身不应在读回后落盘或写日志。
  public func load(account: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if let merged = loadBundle()[account] {
      return merged
    }
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data,
        let secret = String(data: data, encoding: .utf8)
      else {
        return nil
      }
      // 旧格式读到后并入合并条目,后续不再逐条索要授权。
      var bundle = loadBundle()
      bundle[account] = secret
      try? writeBundle(bundle)
      return secret
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError.unexpectedStatus(status)
    }
  }
}
