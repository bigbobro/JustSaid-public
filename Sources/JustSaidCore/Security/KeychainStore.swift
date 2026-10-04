import Foundation
import Security

public protocol ProviderSecretStore: Sendable {
  func save(_ secret: String, account: String) throws
  func contains(account: String) -> Bool
  func load(account: String) throws -> String?
}

public enum KeychainError: LocalizedError {
  case unexpectedStatus(OSStatus)
  case corrupted
  case corruptedLegacy

  public var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      switch status {
      case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
        return "无法访问钥匙串（错误码 \(status)）。请解锁登录钥匙串，在设置中重新点「保存」并在系统弹窗中允许访问；或重启 JustSaid 后在系统弹窗中允许访问。"
      default:
        return "钥匙串操作失败（错误码 \(status)）。请在设置中重新点「保存」，或重启应用后重试。"
      }
    case .corrupted:
      return
        "钥匙串中的密钥记录已损坏，本次未改动原数据。可在「钥匙串访问」中找到「JustSaid 凭证(全部)」并手动备份内容；删除该条目后需重新填写全部密钥。也可到 GitHub Issues 求助：https://github.com/bigbobro/JustSaid-public/issues，请勿附上密钥。"
    case .corruptedLegacy:
      return
        "旧版独立密钥记录已损坏，本次未改动原数据。请在设置中重新填写该密钥并保存；也可到 GitHub Issues 求助：https://github.com/bigbobro/JustSaid-public/issues，请勿附上密钥。"
    }
  }
}

/// 凭证统一存放于**单个** Keychain 条目(内含一份 account → secret 的 JSON)。
///
/// 为什么这么做:每个条目都有独立 ACL,应用重新签名后系统会**逐条**索要授权;
/// 4 个角色的密钥就意味着开机后连弹 4 次以上(2026-07-29 用户实测反馈)。
/// 合并成一条后,授权只需一次;条目内部再按 account 键取值。
/// 旧的多条目格式仍会被读取(向后兼容),读到后自动并入合并条目。
/// 进程内缓存:成功值与读取错误分开保存；失败阻断普通读取，主动保存才重试。
/// 目的是消除"一轮下来被问好几次"的体验(每次 SecItemCopyMatching 都可能触发授权框)。
/// Safety invariant: registryLock 保护 service 注册表；每个 service 的 lock 保护
/// cached 与整个读取/合并/写入。注册表锁不跨 Keychain IO，私有读写 helper 由调用方持锁。
private final class KeychainServiceState: @unchecked Sendable {
  private static let registryLock = NSLock()
  private static var services: [String: KeychainServiceState] = [:]

  let lock = NSLock()
  var cached: Result<[String: String], KeychainError>?

  static func shared(for service: String) -> KeychainServiceState {
    registryLock.lock()
    defer { registryLock.unlock() }
    if let state = services[service] { return state }
    let state = KeychainServiceState()
    services[service] = state
    return state
  }
}

public struct KeychainStore: ProviderSecretStore, Sendable {
  public static let defaultService = "com.justsaid.provider-api-keys"
  public static let bundleAccount = "__justsaid_all_secrets__"

  private let service: String
  private let security: any SecurityItemAccess
  private let state: KeychainServiceState

  public init(service: String = KeychainStore.defaultService) {
    self.service = service
    security = SystemSecurityItemAccess()
    state = .shared(for: service)
  }

  @_spi(KeychainVerification)
  public init(service: String, security: any SecurityItemAccess) {
    self.service = service
    self.security = security
    state = .shared(for: service)
  }

  // MARK: - 合并条目读写

  private func recordReadFailure(_ error: KeychainError) -> KeychainError {
    state.cached = .failure(error)
    return error
  }

  private func loadBundle() throws -> [String: String] {
    if let cached = state.cached { return try cached.get() }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: Self.bundleAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = security.copyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [:] }
    guard status == errSecSuccess else {
      throw recordReadFailure(.unexpectedStatus(status))
    }
    guard let data = result as? Data,
      let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    else {
      throw recordReadFailure(.corrupted)
    }
    state.cached = .success(decoded)
    return decoded
  }

  private func writeBundle(_ bundle: [String: String]) throws {
    let data = try JSONEncoder().encode(bundle)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: Self.bundleAccount,
    ]
    let status = security.update(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if status == errSecItemNotFound {
      var newItem = query
      newItem[kSecValueData as String] = data
      newItem[kSecAttrLabel as String] = "JustSaid 凭证(全部)"
      let status = security.add(newItem as CFDictionary, nil)
      guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    } else {
      guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }
    state.cached = .success(bundle)
  }

  public func save(_ secret: String, account: String) throws {
    state.lock.lock()
    defer { state.lock.unlock() }
    // 只有用户主动保存解除读取阻断；必须重新读取，不能把失败当成空包。
    if case .failure? = state.cached { state.cached = nil }
    var bundle = try loadBundle()
    bundle[account] = secret
    try writeBundle(bundle)
  }

  public func contains(account: String) -> Bool {
    state.lock.lock()
    defer { state.lock.unlock() }
    // 展示用查询保留 Bool 接口；读取失败后不再访问总包或其他旧项。
    guard let bundle = try? loadBundle() else { return false }
    if bundle[account] != nil { return true }
    // 兼容旧的独立条目
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: false,
    ]
    let status = security.copyMatching(query as CFDictionary, nil)
    if status == errSecSuccess { return true }
    if status != errSecItemNotFound { _ = recordReadFailure(.unexpectedStatus(status)) }
    return false
  }

  /// 供界面摘要与运行时配置的普通读取；读取失败后由主动保存解除阻断。
  /// 密钥本身不应在读回后落盘或写日志。
  public func load(account: String) throws -> String? {
    state.lock.lock()
    defer { state.lock.unlock() }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var bundle = try loadBundle()
    if let merged = bundle[account] {
      return merged
    }
    var result: AnyObject?
    let status = security.copyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data,
        let secret = String(data: data, encoding: .utf8)
      else {
        throw recordReadFailure(.corruptedLegacy)
      }
      // 旧格式读到后并入合并条目,后续不再逐条索要授权。
      bundle[account] = secret
      try? writeBundle(bundle)
      return secret
    case errSecItemNotFound:
      return nil
    default:
      throw recordReadFailure(.unexpectedStatus(status))
    }
  }
}
