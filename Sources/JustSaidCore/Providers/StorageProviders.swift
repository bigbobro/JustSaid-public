import CryptoKit
import Foundation

public enum StorageProviderError: LocalizedError, Sendable {
  case invalidConfiguration(String)
  case unreadableFile(URL)
  case invalidObjectURL

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let detail):
      return "对象存储配置无效：\(detail)"
    case .unreadableFile(let url):
      return "无法读取待上传录音：\(url.lastPathComponent)"
    case .invalidObjectURL:
      return "无法生成对象存储地址"
    }
  }
}

private let storageHealthCheckTimeout: TimeInterval = 15

private func performStorageHealthCheck(
  providerID: String,
  endpoint: URL,
  request: URLRequest,
  transport: any HTTPTransport
) async throws -> StorageHealthCheckResult {
  do {
    try Task.checkCancellation()
    let (_, response) = try await transport.data(for: request)
    return try storageHealthCheckResult(
      providerID: providerID,
      endpoint: endpoint,
      statusCode: response.statusCode
    )
  } catch let error as StorageHealthCheckError {
    throw error
  } catch is CancellationError {
    throw CancellationError()
  } catch let error as URLError where error.code == .cancelled {
    throw CancellationError()
  } catch HTTPTransportError.nonHTTPResponse {
    throw StorageHealthCheckError.nonHTTPResponse(providerID: providerID)
  } catch HTTPTransportError.unsuccessfulStatus(let statusCode, _) {
    return try storageHealthCheckResult(
      providerID: providerID,
      endpoint: endpoint,
      statusCode: statusCode
    )
  } catch {
    throw storageConnectionError(from: error, endpoint: endpoint)
  }
}

private func storageHealthCheckResult(
  providerID: String,
  endpoint: URL,
  statusCode: Int
) throws -> StorageHealthCheckResult {
  switch statusCode {
  case 200..<300:
    return StorageHealthCheckResult(providerID: providerID, endpoint: endpoint)
  case 401, 403:
    throw StorageHealthCheckError.invalidCredentials(
      providerID: providerID,
      statusCode: statusCode
    )
  case 400:
    // 400 与 401/403 在 S3 兼容存储上含义不同:400 = 头没解析成功(多为凭证含空白),
    // 401/403 = 格式没问题但签名或权限不对。混为一谈会把用户引去重生成好端端的密钥。
    throw StorageHealthCheckError.malformedRequest(providerID: providerID)
  case 404:
    throw StorageHealthCheckError.containerNotFound(providerID: providerID)
  default:
    throw StorageHealthCheckError.unexpectedResponse(
      providerID: providerID,
      statusCode: statusCode
    )
  }
}

private func storageConnectionError(
  from error: Error,
  endpoint: URL
) -> StorageHealthCheckError {
  let host = endpoint.host ?? "未知地址"
  let underlying = error as NSError
  guard underlying.domain == NSURLErrorDomain else {
    return .endpointUnreachable(host: host)
  }

  switch URLError.Code(rawValue: underlying.code) {
  case .cannotFindHost, .dnsLookupFailed, .redirectToNonExistentLocation:
    return .dnsOrAccountUnreachable(host: host)
  case .secureConnectionFailed,
    .serverCertificateHasBadDate,
    .serverCertificateUntrusted,
    .serverCertificateHasUnknownRoot,
    .serverCertificateNotYetValid,
    .clientCertificateRejected,
    .clientCertificateRequired:
    return .tlsHandshakeFailed(host: host)
  default:
    return .endpointUnreachable(host: host)
  }
}

// MARK: - Azure Blob REST + SAS

public struct AzureBlobStorageConfiguration: Equatable, Sendable {
  public let containerURL: URL
  public let managementSASToken: String
  public let readOnlySASToken: String
  public let readSASAccountKey: String?
  public let apiVersion: String

  public init(
    containerURL: URL,
    managementSASToken: String,
    readOnlySASToken: String,
    apiVersion: String = "2023-11-03"
  ) {
    self.containerURL = containerURL
    self.managementSASToken = managementSASToken
    self.readOnlySASToken = readOnlySASToken
    self.readSASAccountKey = nil
    self.apiVersion = apiVersion
  }

  public init(
    containerURL: URL,
    managementSASToken: String,
    readSASAccountKey: String,
    apiVersion: String = "2023-11-03"
  ) {
    self.containerURL = containerURL
    self.managementSASToken = managementSASToken
    self.readOnlySASToken = ""
    self.readSASAccountKey = readSASAccountKey
    self.apiVersion = apiVersion
  }

  /// 仅凭账户共享密钥配置:管理操作(HEAD/PUT/DELETE)用账户级 SAS 现场派生,
  /// 只读直链仍用单 Blob SAS。用户因此只需填账户密钥,无需另行准备管理 SAS。
  public init(
    containerURL: URL,
    accountSharedKey: String,
    apiVersion: String = "2023-11-03"
  ) {
    self.containerURL = containerURL
    self.managementSASToken = ""
    self.readOnlySASToken = ""
    self.readSASAccountKey = accountSharedKey
    self.apiVersion = apiVersion
  }

  /// 未配置管理 SAS 且持有账户密钥时,管理操作改由账户密钥派生。
  var derivesManagementSASFromAccountKey: Bool {
    managementSASToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (readSASAccountKey?.isEmpty == false)
  }
}

public struct AzureBlobStorageProvider: StorageProvider {
  public let providerID = "azure-blob"

  private let configuration: AzureBlobStorageConfiguration
  private let transport: any HTTPTransport
  private let now: @Sendable () -> Date

  public init(
    configuration: AzureBlobStorageConfiguration,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.transport = transport
    self.now = now
  }

  public func healthCheck() async throws -> StorageHealthCheckResult {
    let endpoint = try validatedContainerURL()
    var components = URLComponents(
      url: endpoint,
      resolvingAgainstBaseURL: false
    )
    var queryItems = components?.queryItems ?? []
    queryItems.removeAll { $0.name.caseInsensitiveCompare("restype") == .orderedSame }
    queryItems.append(URLQueryItem(name: "restype", value: "container"))
    components?.queryItems = queryItems
    guard let containerProbeURL = components?.url else {
      throw StorageProviderError.invalidObjectURL
    }

    var request = URLRequest(
      url: try appendSAS(
        try resolvedManagementSAS(),
        to: containerProbeURL
      ),
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: storageHealthCheckTimeout
    )
    request.httpMethod = "HEAD"
    request.setValue(configuration.apiVersion, forHTTPHeaderField: "x-ms-version")
    return try await performStorageHealthCheck(
      providerID: providerID,
      endpoint: endpoint,
      request: request,
      transport: transport
    )
  }

  public func upload(fileURL: URL, objectName: String) async throws -> StoredObject {
    guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
      throw StorageProviderError.unreadableFile(fileURL)
    }
    let objectURL = try makeObjectURL(objectName: objectName)
    var request = URLRequest(
      url: try appendSAS(
        try resolvedManagementSAS(),
        to: objectURL
      )
    )
    request.httpMethod = "PUT"
    request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
    request.setValue(configuration.apiVersion, forHTTPHeaderField: "x-ms-version")
    request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
    _ = try await transport.validatedUpload(
      for: request,
      fromFile: fileURL
    )
    return StoredObject(identifier: objectName, objectURL: objectURL)
  }

  public func signedReadURL(
    for object: StoredObject,
    expiresIn: TimeInterval
  ) async throws -> URL {
    if let accountSharedKey = configuration.readSASAccountKey {
      return try makePerBlobReadSASURL(
        for: object,
        expiresIn: expiresIn,
        accountSharedKey: accountSharedKey
      )
    }
    try validateReadOnlySAS(expiresIn: expiresIn)
    return try appendSAS(
      configuration.readOnlySASToken,
      to: object.objectURL
    )
  }

  public func delete(_ object: StoredObject) async throws {
    var request = URLRequest(
      url: try appendSAS(
        try resolvedManagementSAS(),
        to: object.objectURL
      )
    )
    request.httpMethod = "DELETE"
    request.setValue(configuration.apiVersion, forHTTPHeaderField: "x-ms-version")
    request.setValue("include", forHTTPHeaderField: "x-ms-delete-snapshots")
    try await transport.validatedDeletion(for: request)
  }

  private func makeObjectURL(objectName: String) throws -> URL {
    let containerURL = try validatedContainerURL()
    let name = objectName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !name.isEmpty else {
      throw StorageProviderError.invalidConfiguration("对象名为空")
    }
    return containerURL.appendingPathComponent(name)
  }

  private func validatedContainerURL() throws -> URL {
    guard
      let components = URLComponents(
        url: configuration.containerURL,
        resolvingAgainstBaseURL: false
      ),
      configuration.containerURL.scheme?.lowercased() == "https",
      configuration.containerURL.host != nil,
      components.query == nil,
      components.fragment == nil,
      components.user == nil,
      components.password == nil
    else {
      throw StorageProviderError.invalidConfiguration(
        "Azure 容器 URL 必须是无 SAS、无用户信息的 HTTPS 地址"
      )
    }
    return configuration.containerURL
  }

  /// SAS 签名是 base64,可能含 `+` `/` `=`;查询串中的 `+` 会被服务端解读为空格并导致
  /// 「Signature fields not well formed」(且仅在签名恰好含 `+` 时发生,呈间歇性)。
  /// 因此签名必须显式百分号编码。2026-07-29 真机实测确认。
  private static func percentEncodedSASSignature(_ signature: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return signature.addingPercentEncoding(withAllowedCharacters: allowed) ?? signature
  }

  private func appendSAS(_ sasToken: String, to url: URL) throws -> URL {
    guard url.scheme?.lowercased() == "https" else {
      throw StorageProviderError.invalidConfiguration("Azure 对象 URL 必须使用 HTTPS")
    }
    let token = sasToken.trimmingCharacters(
      in: CharacterSet(charactersIn: "?&")
    )
    guard !token.isEmpty else {
      throw StorageProviderError.invalidConfiguration("Azure SAS 为空")
    }
    let separator = url.absoluteString.contains("?") ? "&" : "?"
    guard let signedURL = URL(string: url.absoluteString + separator + token) else {
      throw StorageProviderError.invalidObjectURL
    }
    return signedURL
  }

  /// 管理操作用的 SAS:优先使用用户显式配置的管理 SAS;
  /// 未配置但有账户密钥时,现场派生一个短效账户级 SAS(读写删列,仅 blob 服务)。
  private func resolvedManagementSAS() throws -> String {
    let explicit = configuration.managementSASToken
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !explicit.isEmpty {
      return explicit
    }
    guard
      let accountKey = configuration.readSASAccountKey,
      !accountKey.isEmpty
    else {
      throw StorageProviderError.invalidConfiguration("Azure SAS 为空")
    }
    return try makeAccountSAS(accountSharedKey: accountKey, lifetime: 900)
  }

  /// 账户级 SAS(StringToSign 依 Azure 规范:账户名/权限/服务/资源类型/起止/IP/协议/版本/加密范围)。
  private func makeAccountSAS(
    accountSharedKey: String,
    lifetime: TimeInterval
  ) throws -> String {
    let containerURL = try validatedContainerURL()
    guard
      let host = containerURL.host,
      let accountName = host.split(separator: ".").first.map(String.init),
      !accountName.isEmpty
    else {
      throw StorageProviderError.invalidConfiguration("无法从容器地址推断 Azure 账户名")
    }
    let encodedKey = accountSharedKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let key = Data(base64Encoded: encodedKey),
      !key.isEmpty
    else {
      throw StorageProviderError.invalidConfiguration("Azure 账户共享密钥不是有效的 Base64")
    }
    let issuedAt = now()
    let signedStart = Self.azureSASTimestamp(issuedAt.addingTimeInterval(-300))
    let signedExpiry = Self.azureSASTimestamp(issuedAt.addingTimeInterval(max(60, lifetime)))
    let signedPermissions = "rwdl"
    let signedServices = "b"
    let signedResourceTypes = "co"
    let signedVersion = "2021-08-06"
    let stringToSign = [
      accountName,
      signedPermissions,
      signedServices,
      signedResourceTypes,
      signedStart,
      signedExpiry,
      "",
      "https",
      signedVersion,
      "",
      "",
    ].joined(separator: "\n")
    let authenticationCode = HMAC<SHA256>.authenticationCode(
      for: Data(stringToSign.utf8),
      using: SymmetricKey(data: key)
    )
    let signature = Data(authenticationCode).base64EncodedString()
    let encodedFields = [
      "sv=\(signedVersion)",
      "ss=\(signedServices)",
      "srt=\(signedResourceTypes)",
      "sp=\(signedPermissions)",
      "st=\(Self.percentEncodedSASSignature(signedStart))",
      "se=\(Self.percentEncodedSASSignature(signedExpiry))",
      "spr=https",
      "sig=\(Self.percentEncodedSASSignature(signature))",
    ]
    return encodedFields.joined(separator: "&")
  }

  private func makePerBlobReadSASURL(
    for object: StoredObject,
    expiresIn: TimeInterval,
    accountSharedKey: String
  ) throws -> URL {
    guard expiresIn.isFinite else {
      throw StorageProviderError.invalidConfiguration("Azure 只读 SAS 有效期无效")
    }
    let (objectURL, canonicalizedResource) = try validatedBlobURL(object.objectURL)
    let encodedKey = accountSharedKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let key = Data(base64Encoded: encodedKey),
      !key.isEmpty
    else {
      throw StorageProviderError.invalidConfiguration("Azure 账户共享密钥不是有效的 Base64")
    }

    let issuedAt = now()
    let signedStart = Self.azureSASTimestamp(
      issuedAt.addingTimeInterval(-300)
    )
    let signedExpiry = Self.azureSASTimestamp(
      issuedAt.addingTimeInterval(max(1, expiresIn))
    )
    let signedVersion = "2021-08-06"
    let stringToSign = [
      "r",
      signedStart,
      signedExpiry,
      canonicalizedResource,
      "",
      "",
      "https",
      signedVersion,
      "b",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
    ].joined(separator: "\n")
    let authenticationCode = HMAC<SHA256>.authenticationCode(
      for: Data(stringToSign.utf8),
      using: SymmetricKey(data: key)
    )
    let signature = Data(authenticationCode).base64EncodedString()

    guard
      var components = URLComponents(
        url: objectURL,
        resolvingAgainstBaseURL: false
      )
    else {
      throw StorageProviderError.invalidObjectURL
    }
    components.percentEncodedQuery = [
      "sp=r",
      "st=\(Self.percentEncodedSASSignature(signedStart))",
      "se=\(Self.percentEncodedSASSignature(signedExpiry))",
      "spr=https",
      "sv=\(signedVersion)",
      "sr=b",
      "sig=\(Self.percentEncodedSASSignature(signature))",
    ].joined(separator: "&")
    guard let signedURL = components.url else {
      throw StorageProviderError.invalidObjectURL
    }
    return signedURL
  }

  private func validatedBlobURL(_ objectURL: URL) throws -> (URL, String) {
    let containerURL = try validatedContainerURL()
    guard
      let containerComponents = URLComponents(
        url: containerURL,
        resolvingAgainstBaseURL: false
      ),
      let objectComponents = URLComponents(
        url: objectURL,
        resolvingAgainstBaseURL: false
      ),
      let containerHost = containerComponents.host,
      let objectHost = objectComponents.host,
      containerHost.caseInsensitiveCompare(objectHost) == .orderedSame,
      containerComponents.port == objectComponents.port,
      objectComponents.scheme?.lowercased() == "https",
      objectComponents.query == nil,
      objectComponents.fragment == nil,
      objectComponents.user == nil,
      objectComponents.password == nil
    else {
      throw StorageProviderError.invalidConfiguration(
        "Azure 对象地址必须属于已配置的 HTTPS 容器"
      )
    }

    let containerPath = containerComponents.percentEncodedPath
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let objectPath = objectComponents.percentEncodedPath
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard
      !containerPath.isEmpty,
      objectPath.hasPrefix(containerPath + "/"),
      objectPath.count > containerPath.count + 1
    else {
      throw StorageProviderError.invalidConfiguration(
        "Azure 对象地址必须指向已配置容器内的 Blob"
      )
    }

    guard
      let accountName = containerHost.split(separator: ".").first,
      !accountName.isEmpty
    else {
      throw StorageProviderError.invalidConfiguration("无法从 Azure 地址解析账户名")
    }
    let decodedPath =
      objectComponents.percentEncodedPath.removingPercentEncoding
      ?? objectComponents.path
    return (
      objectURL,
      "/blob/\(accountName.lowercased())\(decodedPath)"
    )
  }

  private func validateReadOnlySAS(expiresIn: TimeInterval) throws {
    let token = configuration.readOnlySASToken.trimmingCharacters(
      in: CharacterSet(charactersIn: "?&")
    )
    guard
      let components = URLComponents(string: "https://sas.invalid/?\(token)")
    else {
      throw StorageProviderError.invalidConfiguration("Azure 只读 SAS 无法解析")
    }
    var values: [String: String] = [:]
    for item in components.queryItems ?? [] {
      values[item.name.lowercased()] = item.value ?? ""
    }
    let permissions = Set(values["sp"] ?? "")
    guard permissions == Set("r") else {
      throw StorageProviderError.invalidConfiguration(
        "交给 ASR 的 Azure SAS 必须只有 r 权限"
      )
    }
    guard values["sr"] == "b" else {
      throw StorageProviderError.invalidConfiguration(
        "交给 ASR 的 Azure SAS 必须限定到单个 Blob（sr=b）"
      )
    }
    guard
      let expiryText = values["se"],
      let expiry = Self.iso8601Date(from: expiryText)
    else {
      throw StorageProviderError.invalidConfiguration("Azure 只读 SAS 缺少有效 se 过期时间")
    }
    let remaining = expiry.timeIntervalSince(now())
    let requested = max(1, expiresIn)
    guard remaining >= requested else {
      throw StorageProviderError.invalidConfiguration("Azure 只读 SAS 会在 ASR 读取窗口结束前过期")
    }
    guard remaining <= requested + 300 else {
      throw StorageProviderError.invalidConfiguration("Azure 只读 SAS 的有效期超过请求窗口")
    }
  }

  private static func iso8601Date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
      ?? ISO8601DateFormatter().date(from: value)
  }

  private static func azureSASTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
  }
}

// MARK: - S3-style SigV4 / TOS4 shared signing

/// 火山 TOS 与 AWS S3/R2 的签名差异配置。密钥派生链同构,只换这些常量。
/// **禁止**为 R2 再复制一份 dateKey→regionKey→serviceKey→signingKey 逻辑。
struct S3StyleSigningProfile: Equatable, Sendable {
  let algorithm: String
  /// AWS/R2 为 `"AWS4"`;TOS 为空串(直接用 secretKey)。
  let secretKeyPrefix: String
  let service: String
  let terminator: String
  /// 预签名查询参数前缀:`X-Amz-` / `X-Tos-`。
  let queryPrefix: String

  static let volcengineTOS = S3StyleSigningProfile(
    algorithm: "TOS4-HMAC-SHA256",
    secretKeyPrefix: "",
    service: "tos",
    terminator: "request",
    queryPrefix: "X-Tos-"
  )

  static let awsS3Compatible = S3StyleSigningProfile(
    algorithm: "AWS4-HMAC-SHA256",
    secretKeyPrefix: "AWS4",
    service: "s3",
    terminator: "aws4_request",
    queryPrefix: "X-Amz-"
  )

  func credentialScope(day: String, region: String) -> String {
    "\(day)/\(region)/\(service)/\(terminator)"
  }
}

/// 与供应商无关的 SigV4/TOS4 纯函数:hmac、哈希、编码、密钥派生与签名。
enum S3StyleSigning {
  static func signature(
    secretKey: String,
    day: String,
    region: String,
    stringToSign: String,
    profile: S3StyleSigningProfile
  ) -> String {
    let keyMaterial = profile.secretKeyPrefix + secretKey
    let dateKey = hmac(key: Data(keyMaterial.utf8), value: day)
    let regionKey = hmac(key: dateKey, value: region)
    let serviceKey = hmac(key: regionKey, value: profile.service)
    let signingKey = hmac(key: serviceKey, value: profile.terminator)
    return hmac(key: signingKey, value: stringToSign).hexString
  }

  static func hmac(key: Data, value: String) -> Data {
    let code = HMAC<SHA256>.authenticationCode(
      for: Data(value.utf8),
      using: SymmetricKey(data: key)
    )
    return Data(code)
  }

  static func sha256Hex(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).hexString
  }

  static func sha256Hex(contentsOf url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      guard !data.isEmpty else { break }
      hash.update(data: data)
    }
    return Data(hash.finalize()).hexString
  }

  static func canonicalQuery(_ values: [String: String]) -> String {
    let encoded: [(String, String)] = values.map {
      (percentEncode($0.key), percentEncode($0.value))
    }
    let sorted = encoded.sorted {
      $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
    }
    return sorted.map { pair in
      pair.0 + "=" + pair.1
    }.joined(separator: "&")
  }

  static func percentEncode(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
      )
    ) ?? value
  }

  static func percentEncodePath(_ value: String) -> String {
    value.split(separator: "/", omittingEmptySubsequences: false)
      .map { percentEncode(String($0)) }
      .joined(separator: "/")
  }

  static func percentEncodedPath(of url: URL) -> String {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
      ?? url.path
  }

  static func format(_ date: Date, as format: String) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
}

// MARK: - Volcengine TOS REST + TOS4-HMAC-SHA256

public struct VolcengineTOSConfiguration: Equatable, Sendable {
  public let region: String
  public let bucket: String
  public let accessKey: String
  public let secretKey: String
  public let securityToken: String?
  public let endpointSuffix: String

  public init(
    region: String,
    bucket: String,
    accessKey: String,
    secretKey: String,
    securityToken: String? = nil,
    endpointSuffix: String = "volces.com"
  ) {
    self.region = region
    self.bucket = bucket
    self.accessKey = accessKey
    self.secretKey = secretKey
    self.securityToken = securityToken
    self.endpointSuffix = endpointSuffix
  }
}

public struct VolcengineTOSStorageProvider: StorageProvider {
  public let providerID = "volcengine-tos"

  private static let signingProfile = S3StyleSigningProfile.volcengineTOS

  private let configuration: VolcengineTOSConfiguration
  private let transport: any HTTPTransport
  private let now: @Sendable () -> Date

  public init(
    configuration: VolcengineTOSConfiguration,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.transport = transport
    self.now = now
  }

  public func healthCheck() async throws -> StorageHealthCheckResult {
    let endpoint = try makeBucketURL()
    var request = URLRequest(
      url: endpoint,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: storageHealthCheckTimeout
    )
    request.httpMethod = "HEAD"
    signHeaders(
      request: &request,
      payloadHash: S3StyleSigning.sha256Hex(Data()),
      at: now()
    )
    return try await performStorageHealthCheck(
      providerID: providerID,
      endpoint: endpoint,
      request: request,
      transport: transport
    )
  }

  public func upload(fileURL: URL, objectName: String) async throws -> StoredObject {
    guard
      FileManager.default.isReadableFile(atPath: fileURL.path),
      let payloadHash = try? S3StyleSigning.sha256Hex(contentsOf: fileURL)
    else {
      throw StorageProviderError.unreadableFile(fileURL)
    }
    let objectURL = try makeObjectURL(objectName: objectName)
    var request = URLRequest(url: objectURL)
    request.httpMethod = "PUT"
    request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
    signHeaders(request: &request, payloadHash: payloadHash, at: now())
    _ = try await transport.validatedUpload(
      for: request,
      fromFile: fileURL
    )
    return StoredObject(identifier: objectName, objectURL: objectURL)
  }

  public func signedReadURL(
    for object: StoredObject,
    expiresIn: TimeInterval
  ) async throws -> URL {
    let profile = Self.signingProfile
    let date = now()
    let timestamp = S3StyleSigning.format(date, as: "yyyyMMdd'T'HHmmss'Z'")
    let day = S3StyleSigning.format(date, as: "yyyyMMdd")
    let scope = profile.credentialScope(day: day, region: configuration.region)
    var parameters = [
      "\(profile.queryPrefix)Algorithm": profile.algorithm,
      "\(profile.queryPrefix)Credential": "\(configuration.accessKey)/\(scope)",
      "\(profile.queryPrefix)Date": timestamp,
      "\(profile.queryPrefix)Expires": String(Int(min(max(expiresIn, 1), 604_800))),
      "\(profile.queryPrefix)SignedHeaders": "host",
    ]
    if let token = configuration.securityToken, !token.isEmpty {
      parameters["\(profile.queryPrefix)Security-Token"] = token
    }
    let canonicalQuery = S3StyleSigning.canonicalQuery(parameters)
    guard let host = object.objectURL.host else {
      throw StorageProviderError.invalidObjectURL
    }
    let canonicalRequest = [
      "GET",
      S3StyleSigning.percentEncodedPath(of: object.objectURL),
      canonicalQuery,
      "host:\(host)\n",
      "host",
      "UNSIGNED-PAYLOAD",
    ].joined(separator: "\n")
    let stringToSign = [
      profile.algorithm,
      timestamp,
      scope,
      S3StyleSigning.sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    let signature = S3StyleSigning.signature(
      secretKey: configuration.secretKey,
      day: day,
      region: configuration.region,
      stringToSign: stringToSign,
      profile: profile
    )
    let query = canonicalQuery + "&\(profile.queryPrefix)Signature=\(signature)"
    guard let url = URL(string: object.objectURL.absoluteString + "?" + query) else {
      throw StorageProviderError.invalidObjectURL
    }
    return url
  }

  public func delete(_ object: StoredObject) async throws {
    var request = URLRequest(url: object.objectURL)
    request.httpMethod = "DELETE"
    signHeaders(
      request: &request,
      payloadHash: S3StyleSigning.sha256Hex(Data()),
      at: now()
    )
    try await transport.validatedDeletion(for: request)
  }

  private func makeObjectURL(objectName: String) throws -> URL {
    let name = objectName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !name.isEmpty else {
      throw StorageProviderError.invalidConfiguration("对象名为空")
    }
    guard
      var components = URLComponents(
        url: try makeBucketURL(),
        resolvingAgainstBaseURL: false
      )
    else {
      throw StorageProviderError.invalidObjectURL
    }
    components.percentEncodedPath =
      "/"
      + S3StyleSigning.percentEncodePath(
        name
      )
    guard let url = components.url else {
      throw StorageProviderError.invalidObjectURL
    }
    return url
  }

  private func makeBucketURL() throws -> URL {
    let region = configuration.region.trimmingCharacters(in: .whitespacesAndNewlines)
    let bucket = configuration.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    let endpointSuffix = configuration.endpointSuffix.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !region.isEmpty, !bucket.isEmpty, !endpointSuffix.isEmpty else {
      throw StorageProviderError.invalidConfiguration("TOS 桶、区域或端点后缀为空")
    }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "\(bucket).tos-\(region).\(endpointSuffix)"
    components.percentEncodedPath = "/"
    guard let url = components.url else {
      throw StorageProviderError.invalidObjectURL
    }
    return url
  }

  private func signHeaders(
    request: inout URLRequest,
    payloadHash: String,
    at date: Date
  ) {
    guard let url = request.url, let host = url.host else { return }
    let profile = Self.signingProfile
    let timestamp = S3StyleSigning.format(date, as: "yyyyMMdd'T'HHmmss'Z'")
    let day = S3StyleSigning.format(date, as: "yyyyMMdd")
    request.setValue(host, forHTTPHeaderField: "Host")
    request.setValue(timestamp, forHTTPHeaderField: "x-tos-date")
    request.setValue(payloadHash, forHTTPHeaderField: "x-tos-content-sha256")
    if let token = configuration.securityToken, !token.isEmpty {
      request.setValue(token, forHTTPHeaderField: "x-tos-security-token")
    }

    var canonicalHeaderPairs = [
      ("host", host),
      ("x-tos-content-sha256", payloadHash),
      ("x-tos-date", timestamp),
    ]
    if let token = configuration.securityToken, !token.isEmpty {
      canonicalHeaderPairs.append(("x-tos-security-token", token))
    }
    canonicalHeaderPairs.sort { $0.0 < $1.0 }
    let canonicalHeaders =
      canonicalHeaderPairs.map { "\($0.0):\($0.1)" }
      .joined(separator: "\n") + "\n"
    let signedHeaders = canonicalHeaderPairs.map(\.0).joined(separator: ";")
    let canonicalRequest = [
      request.httpMethod ?? "GET",
      S3StyleSigning.percentEncodedPath(of: url),
      url.query ?? "",
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].joined(separator: "\n")
    let scope = profile.credentialScope(day: day, region: configuration.region)
    let stringToSign = [
      profile.algorithm,
      timestamp,
      scope,
      S3StyleSigning.sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    let signature = S3StyleSigning.signature(
      secretKey: configuration.secretKey,
      day: day,
      region: configuration.region,
      stringToSign: stringToSign,
      profile: profile
    )
    request.setValue(
      "\(profile.algorithm) Credential=\(configuration.accessKey)/\(scope), "
        + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
      forHTTPHeaderField: "Authorization"
    )
  }
}

// MARK: - Cloudflare R2 (S3-compatible)

public struct CloudflareR2Configuration: Equatable, Sendable {
  public let accountID: String
  public let bucket: String
  public let accessKey: String
  public let secretKey: String
  /// R2 固定用 `auto`;保留参数便于测试注入,产品路径传默认值。
  public let region: String

  public init(
    accountID: String,
    bucket: String,
    accessKey: String,
    secretKey: String,
    region: String = "auto"
  ) {
    self.accountID = accountID
    self.bucket = bucket
    self.accessKey = accessKey
    self.secretKey = secretKey
    self.region = region
  }
}

public struct CloudflareR2StorageProvider: StorageProvider {
  public let providerID = "cloudflare-r2"

  private static let signingProfile = S3StyleSigningProfile.awsS3Compatible

  private let configuration: CloudflareR2Configuration
  private let transport: any HTTPTransport
  private let now: @Sendable () -> Date

  public init(
    configuration: CloudflareR2Configuration,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.transport = transport
    self.now = now
  }

  public func healthCheck() async throws -> StorageHealthCheckResult {
    let endpoint = try makeBucketURL()
    var request = URLRequest(
      url: endpoint,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: storageHealthCheckTimeout
    )
    request.httpMethod = "HEAD"
    signHeaders(
      request: &request,
      payloadHash: S3StyleSigning.sha256Hex(Data()),
      at: now()
    )
    return try await performStorageHealthCheck(
      providerID: providerID,
      endpoint: endpoint,
      request: request,
      transport: transport
    )
  }

  public func upload(fileURL: URL, objectName: String) async throws -> StoredObject {
    guard
      FileManager.default.isReadableFile(atPath: fileURL.path),
      let payloadHash = try? S3StyleSigning.sha256Hex(contentsOf: fileURL)
    else {
      throw StorageProviderError.unreadableFile(fileURL)
    }
    let objectURL = try makeObjectURL(objectName: objectName)
    var request = URLRequest(url: objectURL)
    request.httpMethod = "PUT"
    request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
    signHeaders(request: &request, payloadHash: payloadHash, at: now())
    _ = try await transport.validatedUpload(
      for: request,
      fromFile: fileURL
    )
    return StoredObject(identifier: objectName, objectURL: objectURL)
  }

  public func signedReadURL(
    for object: StoredObject,
    expiresIn: TimeInterval
  ) async throws -> URL {
    let profile = Self.signingProfile
    let date = now()
    let timestamp = S3StyleSigning.format(date, as: "yyyyMMdd'T'HHmmss'Z'")
    let day = S3StyleSigning.format(date, as: "yyyyMMdd")
    let scope = profile.credentialScope(day: day, region: configuration.region)
    let parameters = [
      "\(profile.queryPrefix)Algorithm": profile.algorithm,
      "\(profile.queryPrefix)Credential": "\(configuration.accessKey)/\(scope)",
      "\(profile.queryPrefix)Date": timestamp,
      "\(profile.queryPrefix)Expires": String(Int(min(max(expiresIn, 1), 604_800))),
      "\(profile.queryPrefix)SignedHeaders": "host",
    ]
    let canonicalQuery = S3StyleSigning.canonicalQuery(parameters)
    guard let host = object.objectURL.host else {
      throw StorageProviderError.invalidObjectURL
    }
    let canonicalRequest = [
      "GET",
      S3StyleSigning.percentEncodedPath(of: object.objectURL),
      canonicalQuery,
      "host:\(host)\n",
      "host",
      "UNSIGNED-PAYLOAD",
    ].joined(separator: "\n")
    let stringToSign = [
      profile.algorithm,
      timestamp,
      scope,
      S3StyleSigning.sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    let signature = S3StyleSigning.signature(
      secretKey: configuration.secretKey,
      day: day,
      region: configuration.region,
      stringToSign: stringToSign,
      profile: profile
    )
    let query = canonicalQuery + "&\(profile.queryPrefix)Signature=\(signature)"
    guard let url = URL(string: object.objectURL.absoluteString + "?" + query) else {
      throw StorageProviderError.invalidObjectURL
    }
    return url
  }

  public func delete(_ object: StoredObject) async throws {
    var request = URLRequest(url: object.objectURL)
    request.httpMethod = "DELETE"
    signHeaders(
      request: &request,
      payloadHash: S3StyleSigning.sha256Hex(Data()),
      at: now()
    )
    try await transport.validatedDeletion(for: request)
  }

  private func makeObjectURL(objectName: String) throws -> URL {
    let name = objectName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let bucket = configuration.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw StorageProviderError.invalidConfiguration("对象名为空")
    }
    guard
      var components = URLComponents(
        url: try makeBucketURL(),
        resolvingAgainstBaseURL: false
      )
    else {
      throw StorageProviderError.invalidObjectURL
    }
    // path-style:`/<bucket>/<key>`
    components.percentEncodedPath =
      "/" + S3StyleSigning.percentEncodePath(bucket) + "/"
      + S3StyleSigning.percentEncodePath(name)
    guard let url = components.url else {
      throw StorageProviderError.invalidObjectURL
    }
    return url
  }

  private func makeBucketURL() throws -> URL {
    let accountID = configuration.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    let bucket = configuration.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !accountID.isEmpty, !bucket.isEmpty else {
      throw StorageProviderError.invalidConfiguration("R2 Account ID 或 Bucket 为空")
    }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "\(accountID).r2.cloudflarestorage.com"
    components.percentEncodedPath = "/" + S3StyleSigning.percentEncodePath(bucket)
    guard let url = components.url else {
      throw StorageProviderError.invalidObjectURL
    }
    return url
  }

  private func signHeaders(
    request: inout URLRequest,
    payloadHash: String,
    at date: Date
  ) {
    guard let url = request.url, let host = url.host else { return }
    let profile = Self.signingProfile
    let timestamp = S3StyleSigning.format(date, as: "yyyyMMdd'T'HHmmss'Z'")
    let day = S3StyleSigning.format(date, as: "yyyyMMdd")
    request.setValue(host, forHTTPHeaderField: "Host")
    request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
    request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

    var canonicalHeaderPairs = [
      ("host", host),
      ("x-amz-content-sha256", payloadHash),
      ("x-amz-date", timestamp),
    ]
    canonicalHeaderPairs.sort { $0.0 < $1.0 }
    let canonicalHeaders =
      canonicalHeaderPairs.map { "\($0.0):\($0.1)" }
      .joined(separator: "\n") + "\n"
    let signedHeaders = canonicalHeaderPairs.map(\.0).joined(separator: ";")
    let canonicalRequest = [
      request.httpMethod ?? "GET",
      S3StyleSigning.percentEncodedPath(of: url),
      url.query ?? "",
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].joined(separator: "\n")
    let scope = profile.credentialScope(day: day, region: configuration.region)
    let stringToSign = [
      profile.algorithm,
      timestamp,
      scope,
      S3StyleSigning.sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    let signature = S3StyleSigning.signature(
      secretKey: configuration.secretKey,
      day: day,
      region: configuration.region,
      stringToSign: stringToSign,
      profile: profile
    )
    request.setValue(
      "\(profile.algorithm) Credential=\(configuration.accessKey)/\(scope), "
        + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
      forHTTPHeaderField: "Authorization"
    )
  }
}

extension Data {
  fileprivate var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
