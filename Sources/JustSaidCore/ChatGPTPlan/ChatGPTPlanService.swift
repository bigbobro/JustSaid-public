import Foundation

/// ChatGPT 计划用量账户的应用级所有者:每个 ChatGPT 渠道(按渠道 ID)一个凭证保管者,
/// 登录、退出与目录获取都经这里;界面只读发布的快照,拿不到令牌。
///
/// 钥匙串与网络都在保管者 actor 上进行,不在 MainActor 同步等待。
@MainActor
public final class ChatGPTPlanService: ObservableObject {
  /// 本机 host ID 的偏好键:首次登录前生成并持久化,同一台机器上的注册复用它。
  public static let hostIDDefaultsKey = "chatgpt-plan.ext-agent-host-id"

  /// 按渠道 ID 的账户快照;还没加载的渠道不在表里。
  @Published public private(set) var snapshots: [String: ChatGPTAccountSnapshot] = [:]
  @Published public private(set) var signingIn: Set<String> = []
  @Published public private(set) var signingOut: Set<String> = []

  public nonisolated let transport: any HTTPTransport
  private let store: any ChatGPTCredentialStore
  private let defaults: UserDefaults
  private let openBrowser: @Sendable (URL) async throws -> Void
  private let now: @Sendable () -> Date
  private let callbackTimeout: TimeInterval
  private let jwks: ChatGPTJWKSCache
  private var vaults: [String: ChatGPTAccountVault] = [:]
  /// 删除跨越 vault actor 的读取;预占期间禁止新认证,提交后拒绝旧界面的迟到操作。
  private var removingAccounts: Set<String> = []
  private var removedAccounts: Set<String> = []
  private var pendingListeners: [String: ChatGPTLoopbackListener] = [:]
  private var pendingAuthorizations: [String: Task<ChatGPTAccountSnapshot, Error>] = [:]
  private var authorizationAttempts: [String: UUID] = [:]
  /// 首次回调到换码成功之间的短期注册提示,不含令牌或未经验证的 subject。
  /// 换码失败后用户重试沿用正式 ID/host;服务生命周期内保留,成功验证后由凭证记录接管。
  private var retryRegistrations: [String: (clientID: String, hostID: String)] = [:]

  public init(
    store: any ChatGPTCredentialStore = KeychainChatGPTCredentialStore(),
    defaults: UserDefaults = .standard,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    callbackTimeout: TimeInterval = 600,
    now: @escaping @Sendable () -> Date = { Date() },
    openBrowser: @escaping @Sendable (URL) async throws -> Void
  ) {
    self.store = store
    self.defaults = defaults
    self.transport = transport
    self.callbackTimeout = callbackTimeout
    self.now = now
    self.openBrowser = openBrowser
    jwks = ChatGPTJWKSCache(transport: transport)
  }

  private var authorizer: ChatGPTAuthorizer {
    ChatGPTAuthorizer(
      transport: transport, jwks: jwks, now: now, callbackTimeout: callbackTimeout)
  }

  public func vault(for account: String) -> ChatGPTAccountVault {
    if let existing = vaults[account] { return existing }
    let vault = ChatGPTAccountVault(account: account, store: store, authorizer: authorizer)
    vaults[account] = vault
    return vault
  }

  /// 本机 host ID(`urn:uuid:`),不是凭证,也不含用户或机器信息;首次使用时生成并保存。
  public func hostID() -> String {
    if let saved = defaults.string(forKey: Self.hostIDDefaultsKey), saved.hasPrefix("urn:uuid:") {
      return saved
    }
    let created = "urn:uuid:" + UUID().uuidString.lowercased()
    defaults.set(created, forKey: Self.hostIDDefaultsKey)
    return created
  }

  /// 读取这些渠道的账户状态(启动时、渠道列表变化时)。读失败的渠道保持未加载。
  public func loadSnapshots(accounts: [String]) async {
    for account in accounts {
      await reloadSnapshot(account: account)
    }
  }

  /// 调用开始时的身份快照;未加载或未就绪返回对应的推理前错误。
  public func callIdentity(account: String) throws -> ChatGPTCallIdentity {
    guard !signingOut.contains(account), !removingAccounts.contains(account),
      !removedAccounts.contains(account)
    else { throw ChatGPTPlanUnavailable.notSignedIn }
    guard let snapshot = snapshots[account] else {
      throw ChatGPTPlanUnavailable.credentialsUnavailable
    }
    switch snapshot.state {
    case .ready:
      guard let identity = snapshot.identity else {
        throw ChatGPTPlanUnavailable.credentialsUnavailable
      }
      return identity
    case .signedOut: throw ChatGPTPlanUnavailable.notSignedIn
    case .signedInWithoutPlan: throw ChatGPTPlanUnavailable.planUsageNotGranted
    case .reauthRequired: throw ChatGPTPlanUnavailable.reauthorizationRequired
    case .cleanupPending: throw ChatGPTPlanUnavailable.credentialsUnavailable
    }
  }

  /// 登录或再次授权。成功写入钥匙串后才启用并更新快照;任何失败都不动当前账户。
  /// - Parameter requestConsent: 用户主动开启计划用量(此前拒绝过)时为 true。
  @discardableResult
  public func signIn(account: String, requestConsent: Bool = false) async throws
    -> ChatGPTAccountSnapshot
  {
    guard !signingOut.contains(account), !removingAccounts.contains(account),
      !removedAccounts.contains(account), signingIn.insert(account).inserted
    else { throw ChatGPTAuthorizationError.cancelled }
    let vault = vault(for: account)
    let listener = ChatGPTLoopbackListener()
    let attempt = UUID()
    authorizationAttempts[account] = attempt
    pendingListeners[account] = listener
    defer {
      signingIn.remove(account)
      pendingAuthorizations[account] = nil
      if authorizationAttempts[account] == attempt { authorizationAttempts[account] = nil }
      if pendingListeners[account] === listener { pendingListeners[account] = nil }
    }
    let authorizer = self.authorizer
    let openBrowser = self.openBrowser
    let localHostID = hostID()
    let retryRegistration = retryRegistrations[account]
    // 取消的所有权覆盖完整授权过程,不止浏览器回调。已消费回调后仍可取消换码/验签/启用。
    let task = Task { @MainActor in
      try Task.checkCancellation()
      let registration = try await vault.registration()
      try Task.checkCancellation()
      let attemptHostID = registration?.hostID ?? retryRegistration?.hostID ?? localHostID
      let prompt = ChatGPTAuthorizer.Prompt(
        registration: registration,
        retryClientID: registration == nil ? retryRegistration?.clientID : nil,
        hostID: attemptHostID,
        requestConsent: requestConsent)
      let record = try await authorizer.authorize(
        prompt, listener: listener,
        onIssuedClientID: { @MainActor [weak self] clientID in
          guard let self, self.authorizationAttempts[account] == attempt else { return }
          self.retryRegistrations[account] = (clientID: clientID, hostID: attemptHostID)
        }, openBrowser: openBrowser)
      do {
        try Task.checkCancellation()
        return try await vault.adopt(record)
      } catch {
        // 已领到但未启用的 renewable session 尽量撤销,不能用它覆盖有效账户。
        if let refreshToken = record.refreshToken {
          Task {
            _ = await authorizer.revoke(
              refreshToken: refreshToken, clientID: record.clientID, retryDelays: [])
          }
        }
        throw error
      }
    }
    pendingAuthorizations[account] = task
    do {
      let snapshot = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
        listener.cancel()
      }
      retryRegistrations[account] = nil
      if authorizationAttempts[account] != attempt {
        // adopt 的同步持久化是提交点;晚到的取消不能把已提交登录谎报成未登录。
        // 若退出已改变会话,只同步实际快照,不发布旧结果。
        let current = try await vault.snapshot()
        snapshots[account] = current
        guard current == snapshot else { throw ChatGPTAuthorizationError.cancelled }
        return current
      }
      snapshots[account] = snapshot
      return snapshot
    } catch {
      if task.isCancelled || Task.isCancelled { throw ChatGPTAuthorizationError.cancelled }
      throw error
    }
  }

  public func cancelSignIn(account: String) {
    authorizationAttempts[account] = nil
    pendingAuthorizations[account]?.cancel()
    pendingListeners[account]?.cancel()
  }

  /// 退出:停新请求,尽量撤销远端会话,清本地令牌并保留注册映射。
  public func signOut(account: String) async -> ChatGPTSignOutResult {
    guard !removingAccounts.contains(account), !removedAccounts.contains(account),
      signingOut.insert(account).inserted
    else {
      return ChatGPTSignOutResult(
        remoteRevocationConfirmed: false, localTokensCleared: removedAccounts.contains(account))
    }
    defer { signingOut.remove(account) }
    cancelSignIn(account: account)
    let vault = vault(for: account)
    let result = await vault.signOut()
    if let snapshot = try? await vault.snapshot() { snapshots[account] = snapshot }
    return result
  }

  /// 确认凭证已清后同步移除渠道。闭包必须重检配置引用,不能跨过另一个 await。
  /// 失败时保留账户管理入口;成功后封闭该 ID,防止已关闭的编辑器重新发起登录。
  func removeAccountIfSignedOut(account: String, performRemoval: () throws -> Void) async throws
    -> Bool
  {
    guard !signingIn.contains(account), !signingOut.contains(account),
      !removedAccounts.contains(account), removingAccounts.insert(account).inserted
    else { return false }
    defer { removingAccounts.remove(account) }
    guard try await vault(for: account).canRemoveAccount() else { return false }
    try performRemoval()
    removedAccounts.insert(account)
    snapshots[account] = nil
    retryRegistrations[account] = nil
    return true
  }

  /// 刷新快照(例如一次调用发现授权已失效之后)。
  public func reloadSnapshot(account: String) async {
    guard !removedAccounts.contains(account), !removingAccounts.contains(account) else { return }
    if let snapshot = try? await vault(for: account).snapshot(),
      !removedAccounts.contains(account), !removingAccounts.contains(account)
    {
      snapshots[account] = snapshot
    }
  }

  /// 获取当前账户的模型目录(带 Bearer 的 GET,不是推理)。
  public func fetchCatalog(account: String) async throws -> ChatGPTModelCatalog {
    let identity = try callIdentity(account: account)
    let vault = vault(for: account)
    let token = try await tokenSource(identity: identity)()
    var request = URLRequest(url: ChatGPTPlanContract.modelsURL, timeoutInterval: 30)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await transport.data(for: request)
    guard try await vault.snapshot().identity == identity else {
      throw ChatGPTPlanUnavailable.accountChanged
    }
    guard (200..<300).contains(response.statusCode) else {
      throw ChatGPTResponsesErrorMapper.serviceError(
        status: response.statusCode, body: data, requestID: response.requestID)
    }
    return try ChatGPTModelCatalogParser.parse(data)
  }

  /// 客户端收到用量上限错误时调用:该账户进入本地退避。
  public func usageLimitReporter(account: String) -> @Sendable () async -> Void {
    let vault = vault(for: account)
    let now = self.now
    return { await vault.noteUsageLimit(now: now()) }
  }

  /// 构造绑定到本次调用身份的令牌来源;身份在构造时冻结。
  public func tokenSource(identity: ChatGPTCallIdentity) -> @Sendable () async throws -> String {
    let vault = vault(for: identity.account)
    let now = self.now
    return { [weak self] in
      do {
        return try await vault.accessToken(for: identity, now: now())
      } catch let error as ChatGPTPlanUnavailable {
        if error == .reauthorizationRequired || error == .planUsageNotGranted
          || error == .credentialsUnavailable
        {
          await self?.reloadSnapshot(account: identity.account)
        }
        throw error
      }
    }
  }
}

extension HTTPURLResponse {
  /// OpenAI 响应头里的请求 ID;仅接受安全字符,其余丢弃。
  var requestID: String? {
    guard let raw = value(forHTTPHeaderField: "x-request-id"), raw.count <= 128,
      raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else { return nil }
    return raw
  }
}
