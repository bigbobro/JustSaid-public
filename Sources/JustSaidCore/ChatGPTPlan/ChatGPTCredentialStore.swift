import Foundation
import Security

/// 一个 ChatGPT 账户注册(正式 client ID + 已验证身份)的受保护凭证记录。
///
/// 令牌字段整体为 nil 表示已退出:注册映射(client ID、身份、本机 host ID)保留,
/// 下次登录复用同一注册。access/refresh/ID token、scope 与到期时间作为一个版本整体替换。
public struct ChatGPTCredentialRecord: Codable, Equatable, Sendable {
  public var issuer: String
  public var subject: String
  /// 仅用于显示与 `login_hint`;不作身份键。
  public var email: String?
  public var clientID: String
  public var hostID: String
  public var idToken: String?
  public var accessToken: String?
  public var refreshToken: String?
  public var accessTokenExpiresAt: Date?
  public var earliestRefreshAt: Date?
  public var scopes: [String]
  public var savedAt: Date

  public init(
    issuer: String, subject: String, email: String?, clientID: String, hostID: String,
    idToken: String?, accessToken: String?, refreshToken: String?,
    accessTokenExpiresAt: Date?, earliestRefreshAt: Date?, scopes: [String], savedAt: Date
  ) {
    self.issuer = issuer
    self.subject = subject
    self.email = email
    self.clientID = clientID
    self.hostID = hostID
    self.idToken = idToken
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.accessTokenExpiresAt = accessTokenExpiresAt
    self.earliestRefreshAt = earliestRefreshAt
    self.scopes = scopes
    self.savedAt = savedAt
  }

  /// 身份授权可能没有 offline_access/refresh token;退出时仍须清除 access/ID token。
  public var hasTokens: Bool { accessToken != nil || refreshToken != nil || idToken != nil }

  public var planUsageGranted: Bool { scopes.contains(ChatGPTPlanContract.planUsageScope) }

  /// 退出后的记录:清令牌,保留注册映射与 ID token 之外的显示信息。
  func signedOut(at now: Date) -> ChatGPTCredentialRecord {
    var copy = self
    copy.idToken = nil
    copy.accessToken = nil
    copy.refreshToken = nil
    copy.accessTokenExpiresAt = nil
    copy.earliestRefreshAt = nil
    copy.scopes = []
    copy.savedAt = now
    return copy
  }
}

/// 凭证持久化。写入失败必须抛错——调用方据此判定「登录/刷新未成功」,
/// 不能先改内存再写盘失败却报成功。
public protocol ChatGPTCredentialStore: Sendable {
  func load(account: String) throws -> ChatGPTCredentialRecord?
  func save(_ record: ChatGPTCredentialRecord, account: String) throws
  func delete(account: String) throws
}

public enum ChatGPTCredentialStoreError: LocalizedError, Equatable, Sendable {
  case keychain(OSStatus)
  case invalidAccount
  case corrupted

  public var errorDescription: String? {
    switch self {
    case .keychain(let status):
      return "钥匙串读写 ChatGPT 授权失败（\(status)）"
    case .invalidAccount:
      return "ChatGPT 授权记录的账户标识无效"
    case .corrupted:
      return "ChatGPT 授权记录已损坏"
    }
  }
}

enum ChatGPTCredentialCoding {
  static func encode(_ record: ChatGPTCredentialRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(record)
  }

  static func decode(_ data: Data) throws -> ChatGPTCredentialRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let record = try? decoder.decode(ChatGPTCredentialRecord.self, from: data) else {
      throw ChatGPTCredentialStoreError.corrupted
    }
    return record
  }

  static func validate(account: String) throws {
    guard !account.isEmpty, account.count <= 128,
      account.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
      })
    else { throw ChatGPTCredentialStoreError.invalidAccount }
  }
}

/// App 用:每个账户一个独立钥匙串通用密码项(服务名与现有 API Key 合并包分开),
/// 整份记录原子替换,删除可确认;没有进程级缓存,读到的就是系统里的值。
public struct KeychainChatGPTCredentialStore: ChatGPTCredentialStore {
  public static let service = "com.justsaid.chatgpt-plan"

  private let security: any SecurityItemAccess

  public init() { security = SystemSecurityItemAccess() }

  @_spi(KeychainVerification)
  public init(security: any SecurityItemAccess) { self.security = security }

  private func query(account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: account,
    ]
  }

  public func load(account: String) throws -> ChatGPTCredentialRecord? {
    try ChatGPTCredentialCoding.validate(account: account)
    var lookup = query(account: account)
    lookup[kSecReturnData] = true
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = security.copyMatching(lookup as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw ChatGPTCredentialStoreError.keychain(status)
    }
    guard let data = result as? Data else { throw ChatGPTCredentialStoreError.corrupted }
    return try ChatGPTCredentialCoding.decode(data)
  }

  public func save(_ record: ChatGPTCredentialRecord, account: String) throws {
    try ChatGPTCredentialCoding.validate(account: account)
    let data = try ChatGPTCredentialCoding.encode(record)
    let status = security.update(
      query(account: account) as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else {
      throw ChatGPTCredentialStoreError.keychain(status)
    }
    var item = query(account: account)
    item[kSecValueData] = data
    item[kSecAttrLabel] = "JustSaid ChatGPT 授权"
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = security.add(item as CFDictionary, nil)
    guard added == errSecSuccess else { throw ChatGPTCredentialStoreError.keychain(added) }
  }

  public func delete(account: String) throws {
    try ChatGPTCredentialCoding.validate(account: account)
    let status = security.delete(query(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ChatGPTCredentialStoreError.keychain(status)
    }
  }
}

/// 手动 Real 工具用:仓外 0700 目录里每个账户一个 0600 文件,原子写入。
/// 与 App 的钥匙串授权分开,工具自己登录、自己持有轮换后的 refresh token。
public struct FileChatGPTCredentialStore: ChatGPTCredentialStore {
  public let directory: URL

  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private func file(_ account: String) throws -> URL {
    try ChatGPTCredentialCoding.validate(account: account)
    return directory.appendingPathComponent("\(account).json")
  }

  public func load(account: String) throws -> ChatGPTCredentialRecord? {
    let url = try file(account)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try ChatGPTCredentialCoding.decode(Data(contentsOf: url))
  }

  public func save(_ record: ChatGPTCredentialRecord, account: String) throws {
    let url = try file(account)
    let temporary = directory.appendingPathComponent(".\(account).\(UUID().uuidString).tmp")
    let data = try ChatGPTCredentialCoding.encode(record)
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw ChatGPTCredentialStoreError.corrupted }
    // rename(2) 在同一目录内原子替换,目标不存在时同样成立。
    guard rename(temporary.path, url.path) == 0 else {
      try? FileManager.default.removeItem(at: temporary)
      throw ChatGPTCredentialStoreError.corrupted
    }
  }

  public func delete(account: String) throws {
    let url = try file(account)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}
