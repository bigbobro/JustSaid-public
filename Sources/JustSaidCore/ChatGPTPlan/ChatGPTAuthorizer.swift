import Foundation

/// 登录(授权)过程的失败。全部发生在推理之前,不产生推理用量;**任何一种都不替换已有的有效账户**。
public enum ChatGPTAuthorizationError: LocalizedError, Equatable, Sendable {
  case randomUnavailable
  case listenerUnavailable
  case browserUnavailable
  case timedOut
  case cancelled
  /// 回调的 state 与本次尝试不符(过期标签页、重放或伪造),未换码。
  case stateMismatch
  /// 用户在授权页拒绝。
  case consentDeclined
  case authorizationFailed(code: String)
  /// 首次注册的回调没有带回正式 client ID。
  case registrationIncomplete
  /// 再次授权的回调带回了另一个 client ID。
  case clientMismatch
  /// 授权码被拒(invalid_grant),需重新发起。
  case codeRejected
  case tokenEndpointFailed(status: Int?, code: String?)
  case malformedTokenResponse
  case idTokenInvalid(reason: String)
  /// 再次授权得到的身份与该渠道已登记的账户不同。
  case accountMismatch
  case jwksUnavailable(status: Int?)
  /// 新凭证没能写入钥匙串;未启用新账户。
  case persistenceFailed

  public var errorDescription: String? {
    switch self {
    case .randomUnavailable: return "系统随机数不可用，无法发起 ChatGPT 登录"
    case .listenerUnavailable: return "无法在本机开启登录回调端口"
    case .browserUnavailable: return "无法打开浏览器完成 ChatGPT 登录"
    case .timedOut: return "ChatGPT 登录等待超时，请重新开始"
    case .cancelled: return "已取消 ChatGPT 登录"
    case .stateMismatch: return "登录回调与本次请求不符，已拒绝，请重新开始"
    case .consentDeclined: return "已在 ChatGPT 授权页拒绝，未登录"
    case .authorizationFailed(let code): return "ChatGPT 授权失败（\(code)）"
    case .registrationIncomplete: return "ChatGPT 没有返回本应用的注册信息，请重新登录"
    case .clientMismatch: return "ChatGPT 返回的应用注册与本渠道不符，已拒绝"
    case .codeRejected: return "ChatGPT 授权码已失效，请重新登录"
    case .tokenEndpointFailed(let status, let code):
      return "ChatGPT 令牌服务拒绝了请求" + (status.map { "（HTTP \($0)" } ?? "（")
        + (code.map { " \($0)" } ?? "") + "）"
    case .malformedTokenResponse: return "ChatGPT 令牌响应格式不对"
    case .idTokenInvalid(let reason): return "ChatGPT 身份令牌校验失败（\(reason)）"
    case .accountMismatch: return "重新登录的是另一个 ChatGPT 账户；如需使用它，请新建一个 ChatGPT 渠道"
    case .jwksUnavailable: return "暂时无法获取 ChatGPT 签名公钥，请稍后再试"
    case .persistenceFailed: return "ChatGPT 授权没能保存到钥匙串，未登录成功"
    }
  }
}

/// 刷新失败的两类后果:终止性(清令牌、需重新登录)与暂时性(保留凭证、稍后再试)。
enum ChatGPTRefreshFailure: Error, Equatable {
  case terminal(code: String)
  case clientConfiguration
  case transient
}

struct ChatGPTTokenResponse: Equatable {
  let accessToken: String
  let refreshToken: String?
  let idToken: String?
  let expiresAt: Date?
  let earliestRefreshAt: Date?
  /// nil 表示响应没带 scope 字段。
  let scopes: [String]?

  static func parse(_ data: Data, now: Date) throws -> ChatGPTTokenResponse {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = object["access_token"] as? String, !access.isEmpty
    else { throw ChatGPTAuthorizationError.malformedTokenResponse }
    let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue
    return ChatGPTTokenResponse(
      accessToken: access,
      refreshToken: (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      idToken: (object["id_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      expiresAt: expiresIn.map { now.addingTimeInterval($0) },
      earliestRefreshAt: Self.instant(object["earliest_refresh_at"], now: now),
      scopes: (object["scope"] as? String).map {
        $0.split(separator: " ").map(String.init).filter { !$0.isEmpty }
      }
    )
  }

  /// 文档只说明有该字段;数字按 Unix 秒(过小则视为相对秒),字符串按 ISO-8601,其余忽略。
  private static func instant(_ value: Any?, now: Date) -> Date? {
    if let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 {
      return number > 1_000_000_000
        ? Date(timeIntervalSince1970: number) : now.addingTimeInterval(number)
    }
    if let text = value as? String { return ISO8601DateFormatter().date(from: text) }
    return nil
  }

  /// OAuth 错误体的机器码:`{"error":"invalid_grant"}` 或 `{"error":{"code":…}}`。
  static func errorCode(_ data: Data) -> String? {
    guard data.count <= 16_384,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let code = object["error"] as? String {
      return DiagnosticSanitizer.token(code, fallback: "unknown")
    }
    if let nested = object["error"] as? [String: Any], let code = nested["code"] as? String {
      return DiagnosticSanitizer.token(code, fallback: "unknown")
    }
    return nil
  }
}

/// 一次登录尝试与令牌端点调用。无状态:持久化与启用由 `ChatGPTAccountVault` 负责。
struct ChatGPTAuthorizer: Sendable {
  let transport: any HTTPTransport
  let jwks: ChatGPTJWKSCache
  let now: @Sendable () -> Date
  /// 等浏览器回调的上限;过期即关闭监听。
  var callbackTimeout: TimeInterval = 600

  struct Prompt: Sendable {
    /// 已有注册(含已退出但保留映射的)时为再次授权,否则首次注册。
    let registration: ChatGPTCredentialRecord?
    /// 首次回调已注册但换码未成功,只保留正式 ID 供重试,不代表已验证身份。
    var retryClientID: String? = nil
    let hostID: String
    /// 用户主动开启计划用量(曾拒绝过)时要求重新同意。
    var requestConsent = false
  }

  /// 走完一次授权并返回已验证的新凭证记录;不写盘、不启用。
  func authorize(
    _ prompt: Prompt,
    listener: ChatGPTLoopbackListener = ChatGPTLoopbackListener(),
    onIssuedClientID: @Sendable (String) async -> Void = { _ in },
    openBrowser: @Sendable (URL) async throws -> Void
  ) async throws -> ChatGPTCredentialRecord {
    try Task.checkCancellation()
    let redirect: URL
    do {
      redirect = try await listener.start()
    } catch {
      throw ChatGPTAuthorizationError.listenerUnavailable
    }
    defer { listener.cancel() }
    try Task.checkCancellation()
    let state = try ChatGPTBase64URL.random()
    let nonce = try ChatGPTBase64URL.random()
    let verifier = try ChatGPTBase64URL.random()
    let requestClientID =
      prompt.registration?.clientID ?? prompt.retryClientID ?? ChatGPTPlanContract.dynamicClientID
    let url = Self.authorizationURL(
      clientID: requestClientID,
      newRegistration: requestClientID == ChatGPTPlanContract.dynamicClientID,
      hostID: prompt.hostID, redirect: redirect, state: state, nonce: nonce,
      codeChallenge: ChatGPTBase64URL.codeChallenge(for: verifier),
      idTokenHint: prompt.registration?.idToken, loginHint: prompt.registration?.email,
      requestConsent: prompt.requestConsent)
    do {
      try await openBrowser(url)
    } catch {
      listener.cancel()
      throw ChatGPTAuthorizationError.browserUnavailable
    }
    let items: [URLQueryItem]
    do {
      items = try await listener.waitForCallback(timeout: callbackTimeout)
    } catch ChatGPTLoopbackError.timedOut {
      throw ChatGPTAuthorizationError.timedOut
    } catch {
      throw ChatGPTAuthorizationError.cancelled
    }
    func value(_ name: String) -> String? {
      items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
    // state 先于一切:不符即拒,不读 code、不换码。
    guard value("state") == state else { throw ChatGPTAuthorizationError.stateMismatch }
    if let error = value("error") {
      throw error == "access_denied"
        ? ChatGPTAuthorizationError.consentDeclined
        : ChatGPTAuthorizationError.authorizationFailed(
          code: DiagnosticSanitizer.token(error, fallback: "unknown"))
    }
    guard let code = value("code") else {
      throw ChatGPTAuthorizationError.authorizationFailed(code: "missing_code")
    }
    let clientID: String
    if requestClientID != ChatGPTPlanContract.dynamicClientID {
      if let returned = value("client_id"), returned != requestClientID {
        throw ChatGPTAuthorizationError.clientMismatch
      }
      clientID = requestClientID
    } else {
      guard let issued = value("client_id"), issued != ChatGPTPlanContract.dynamicClientID else {
        throw ChatGPTAuthorizationError.registrationIncomplete
      }
      clientID = issued
    }

    if prompt.registration == nil { await onIssuedClientID(clientID) }
    try Task.checkCancellation()

    let tokens = try await exchange(
      code: code, clientID: clientID, verifier: verifier, redirect: redirect)
    var accepted = false
    defer {
      if !accepted, let refreshToken = tokens.refreshToken {
        Task {
          _ = await revoke(refreshToken: refreshToken, clientID: clientID, retryDelays: [])
        }
      }
    }
    try Task.checkCancellation()
    guard let idToken = tokens.idToken else {
      throw ChatGPTAuthorizationError.idTokenInvalid(reason: "missing")
    }
    let identity: ChatGPTVerifiedIdentity
    do {
      identity = try await ChatGPTIDTokenVerifier.verify(
        idToken, jwks: jwks, clientID: clientID, nonce: nonce, now: now())
    } catch let error as ChatGPTIDTokenError {
      throw ChatGPTAuthorizationError.idTokenInvalid(reason: "\(error)")
    }
    try Task.checkCancellation()
    if let registration = prompt.registration,
      registration.subject != identity.subject || registration.issuer != identity.issuer
    {
      throw ChatGPTAuthorizationError.accountMismatch
    }
    let planUsageGranted = tokens.scopes?.contains(ChatGPTPlanContract.planUsageScope) == true
    guard !planUsageGranted || tokens.refreshToken != nil else {
      throw ChatGPTAuthorizationError.malformedTokenResponse
    }
    accepted = true
    return ChatGPTCredentialRecord(
      issuer: identity.issuer, subject: identity.subject,
      email: identity.email ?? prompt.registration?.email, clientID: clientID,
      hostID: prompt.hostID, idToken: idToken, accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken, accessTokenExpiresAt: tokens.expiresAt,
      earliestRefreshAt: tokens.earliestRefreshAt, scopes: tokens.scopes ?? [], savedAt: now())
  }

  static func authorizationURL(
    clientID: String, newRegistration: Bool, hostID: String, redirect: URL, state: String,
    nonce: String, codeChallenge: String, idTokenHint: String?, loginHint: String?,
    requestConsent: Bool
  ) -> URL {
    var items: [(String, String)] = [
      ("client_id", clientID),
      ("ext_agent_host_id", hostID),
      ("response_type", "code"),
      ("redirect_uri", redirect.absoluteString),
      ("scope", ChatGPTPlanContract.scopes),
      ("resource", ChatGPTPlanContract.resource),
      ("state", state),
      ("nonce", nonce),
      ("code_challenge_method", "S256"),
      ("code_challenge", codeChallenge),
    ]
    if newRegistration {
      items.append(("agent_name_hint", ChatGPTPlanContract.agentNameHint))
    } else {
      if let idTokenHint { items.append(("id_token_hint", idTokenHint)) }
      if let loginHint { items.append(("login_hint", loginHint)) }
    }
    if requestConsent { items.append(("prompt", "consent")) }
    // 每个值都按 RFC 3986 非保留字符集严格编码(含 `+`、`:`、`/` 与空格)。
    let query = items.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
    return URL(string: ChatGPTPlanContract.authorizeURL.absoluteString + "?" + query)!
  }

  func exchange(code: String, clientID: String, verifier: String, redirect: URL) async throws
    -> ChatGPTTokenResponse
  {
    let (data, response) = try await postForm(
      ChatGPTPlanContract.tokenURL,
      [
        ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
        ("code_verifier", verifier), ("redirect_uri", redirect.absoluteString),
        ("resource", ChatGPTPlanContract.resource),
      ])
    guard (200..<300).contains(response.statusCode) else {
      let errorCode = ChatGPTTokenResponse.errorCode(data)
      if errorCode == "invalid_grant" { throw ChatGPTAuthorizationError.codeRejected }
      throw ChatGPTAuthorizationError.tokenEndpointFailed(
        status: response.statusCode, code: errorCode)
    }
    return try ChatGPTTokenResponse.parse(data, now: now())
  }

  /// 刷新:用正式 client ID 与当前 refresh token,不带 scope 以保留原授权。
  func refresh(_ record: ChatGPTCredentialRecord) async throws -> ChatGPTTokenResponse {
    guard let refreshToken = record.refreshToken else {
      throw ChatGPTRefreshFailure.terminal(code: "missing_refresh_token")
    }
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await postForm(
        ChatGPTPlanContract.tokenURL,
        [
          ("grant_type", "refresh_token"), ("client_id", record.clientID),
          ("refresh_token", refreshToken), ("resource", ChatGPTPlanContract.resource),
        ])
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ChatGPTRefreshFailure.transient
    }
    guard (200..<300).contains(response.statusCode) else {
      let code = ChatGPTTokenResponse.errorCode(data)
      if code == "invalid_client" { throw ChatGPTRefreshFailure.clientConfiguration }
      if let code, Self.terminalRefreshCodes.contains(code) {
        throw ChatGPTRefreshFailure.terminal(code: code)
      }
      // 5xx、429 与不认识的错误一律当暂时性:凭证保留,不误清。
      throw ChatGPTRefreshFailure.transient
    }
    do {
      return try ChatGPTTokenResponse.parse(data, now: now())
    } catch {
      throw ChatGPTRefreshFailure.transient
    }
  }

  static let terminalRefreshCodes: Set<String> = [
    "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
    "refresh_token_invalidated", "refresh_token_reused",
  ]

  /// 撤销 refresh token。空 200 即成功(含已失效);网络与 5xx 有界退避重试。
  func revoke(refreshToken: String, clientID: String, retryDelays: [TimeInterval] = [1, 2]) async
    -> Bool
  {
    var delays = retryDelays[...]
    while true {
      do {
        let (_, response) = try await postForm(
          ChatGPTPlanContract.revokeURL,
          [
            ("token", refreshToken), ("token_type_hint", "refresh_token"),
            ("client_id", clientID),
          ])
        if (200..<300).contains(response.statusCode) { return true }
        guard response.statusCode >= 500 else { return false }
      } catch {
        if error is CancellationError { return false }
      }
      guard let delay = delays.popFirst() else { return false }
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
  }

  private func postForm(_ url: URL, _ fields: [(String, String)]) async throws -> (
    Data, HTTPURLResponse
  ) {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data(
      fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }
        .joined(separator: "&").utf8)
    return try await transport.data(for: request)
  }

  /// application/x-www-form-urlencoded:只放行非保留字符,其余一律百分号编码。
  static func formEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}
