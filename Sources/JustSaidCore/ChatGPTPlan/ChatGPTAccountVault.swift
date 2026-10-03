import Foundation

/// 调用开始时绑定的账户身份。取令牌时代际或身份不符即停,**绝不换成另一个账户继续**。
public struct ChatGPTCallIdentity: Equatable, Sendable {
  public let account: String
  public let generation: UInt64
  public let clientID: String
  public let subject: String
}

public enum ChatGPTAccountState: String, Equatable, Sendable {
  /// 没有可用令牌(从未登录,或已退出;注册映射可能仍在)。
  case signedOut
  /// 身份有效,但授权里没有计划用量许可;不能推理。
  case signedInWithoutPlan
  case ready
  /// 刷新被拒或会话已撤销,令牌已清,需重新登录。
  case reauthRequired
  /// 本机凭证尚未清除,禁止推理并保留重试退出入口。
  case cleanupPending
}

/// 给界面与客户端工厂的只读快照;不含任何令牌。
public struct ChatGPTAccountSnapshot: Equatable, Sendable {
  public let account: String
  public let state: ChatGPTAccountState
  public let email: String?
  /// 是否保留着可复用的注册(再次登录不必重新注册)。
  public let hasRegistration: Bool
  /// 仅 `ready` 时有值。
  public let identity: ChatGPTCallIdentity?
}

public struct ChatGPTSignOutResult: Equatable, Sendable {
  /// 远端撤销得到确认(空 200);false 时须如实告诉用户可在 ChatGPT 设置里断开。
  public let remoteRevocationConfirmed: Bool
  public let localTokensCleared: Bool
}

/// 一个账户注册的凭证所有者:读写只经这里,刷新串行,登录与退出按代际隔离。
///
/// 不变量:
/// - 新凭证**写盘成功后**才在内存生效(登录与刷新都是);写盘失败就报失败。
/// - 同一代际只有一个在途刷新,并发取令牌共享它;刷新结果回来时代际已变(退出/重新登录)即丢弃。
/// - 暂时性失败(网络、5xx、钥匙串读失败)保留凭证;只有终止性刷新错误清令牌、要求重新登录。
public actor ChatGPTAccountVault {
  public nonisolated let account: String
  private let store: any ChatGPTCredentialStore
  private let authorizer: ChatGPTAuthorizer
  private var record: ChatGPTCredentialRecord?
  private var loaded = false
  private var reauthRequired = false
  private var signingOut = false
  /// 本地清除失败时仍阻断推理,保留原记录/读取机会供用户再次退出时重试。
  private var cleanupPending = false
  private var generation: UInt64 = 0
  private var refreshing: (generation: UInt64, task: Task<String, Error>)?
  /// 收到用量上限后的本地退避截止时刻;重新登录清除。
  private var usageLimitPausedUntil: Date?
  /// 用量上限后的退避时长:限制无效请求的频率,不代表套餐何时恢复。
  static let usageLimitBackoff: TimeInterval = 600

  /// 距到期不足这么多秒就先刷新。
  static let refreshMargin: TimeInterval = 120
  /// 响应没给 `expires_in` 时按文档的一小时估算。
  static let assumedLifetime: TimeInterval = 3_600

  init(account: String, store: any ChatGPTCredentialStore, authorizer: ChatGPTAuthorizer) {
    self.account = account
    self.store = store
    self.authorizer = authorizer
  }

  private func ensureLoaded() throws {
    guard !loaded else { return }
    do {
      record = try store.load(account: account)
    } catch {
      throw ChatGPTPlanUnavailable.credentialsUnavailable
    }
    loaded = true
  }

  public func snapshot() throws -> ChatGPTAccountSnapshot {
    // 读与删除都失败时也必须能呈现待清理状态;重读由下一次退出执行。
    if !cleanupPending { try ensureLoaded() }
    return currentSnapshot()
  }

  /// 删除渠道前由认证所有者调用,不能用 UI 的缓存快照代替持久存储确认。
  func canRemoveAccount() throws -> Bool {
    try ensureLoaded()
    guard !signingOut, !cleanupPending, record?.hasTokens != true else { return false }
    do {
      return try store.load(account: account)?.hasTokens != true
    } catch {
      throw ChatGPTPlanUnavailable.credentialsUnavailable
    }
  }

  private func currentSnapshot() -> ChatGPTAccountSnapshot {
    let state: ChatGPTAccountState
    if cleanupPending {
      state = .cleanupPending
    } else if signingOut {
      state = .signedOut
    } else if reauthRequired {
      state = .reauthRequired
    } else if let record, record.hasTokens {
      state = record.planUsageGranted ? .ready : .signedInWithoutPlan
    } else {
      state = .signedOut
    }
    let identity =
      state == .ready
      ? record.map {
        ChatGPTCallIdentity(
          account: account, generation: generation, clientID: $0.clientID, subject: $0.subject)
      } : nil
    return ChatGPTAccountSnapshot(
      account: account, state: state, email: record?.email, hasRegistration: record != nil,
      identity: identity)
  }

  /// 已保存的注册(含已退出但保留映射的),用于再次授权。
  func registration() throws -> ChatGPTCredentialRecord? {
    try ensureLoaded()
    guard !cleanupPending, !signingOut else {
      throw ChatGPTPlanUnavailable.credentialsUnavailable
    }
    return record
  }

  /// 授权成功后的启用:先写盘,成功才替换内存状态并开新代际;失败不改变当前账户。
  func adopt(_ newRecord: ChatGPTCredentialRecord) throws -> ChatGPTAccountSnapshot {
    try Task.checkCancellation()
    try ensureLoaded()
    if let existing = record,
      existing.subject != newRecord.subject || existing.issuer != newRecord.issuer
    {
      throw ChatGPTAuthorizationError.accountMismatch
    }
    do {
      try store.save(newRecord, account: account)
    } catch {
      throw ChatGPTAuthorizationError.persistenceFailed
    }
    record = newRecord
    loaded = true
    reauthRequired = false
    signingOut = false
    cleanupPending = false
    usageLimitPausedUntil = nil
    generation &+= 1
    refreshing = nil
    return currentSnapshot()
  }

  /// 一次调用收到 `subscription_sharing_usage_limit_exceeded` 后由客户端报告。
  func noteUsageLimit(now: Date = Date()) {
    usageLimitPausedUntil = now.addingTimeInterval(Self.usageLimitBackoff)
  }

  /// 为一次推理取 access token;必要时串行刷新。抛出的都是推理前失败,不产生推理用量。
  public func accessToken(for identity: ChatGPTCallIdentity, now: Date = Date()) async throws
    -> String
  {
    try ensureLoaded()
    guard identity.account == account, identity.generation == generation,
      let record, record.clientID == identity.clientID, record.subject == identity.subject
    else { throw ChatGPTPlanUnavailable.accountChanged }
    guard !signingOut, !cleanupPending else { throw ChatGPTPlanUnavailable.notSignedIn }
    guard !reauthRequired else { throw ChatGPTPlanUnavailable.reauthorizationRequired }
    guard record.hasTokens, let accessToken = record.accessToken else {
      throw ChatGPTPlanUnavailable.notSignedIn
    }
    guard record.planUsageGranted else { throw ChatGPTPlanUnavailable.planUsageNotGranted }
    if let until = usageLimitPausedUntil, now < until {
      throw ChatGPTPlanUnavailable.usageLimitPaused
    }
    let expiresAt =
      record.accessTokenExpiresAt ?? record.savedAt.addingTimeInterval(Self.assumedLifetime)
    let stillValid = expiresAt > now.addingTimeInterval(5)
    let tooEarly = record.earliestRefreshAt.map { $0 > now } ?? false
    if expiresAt > now.addingTimeInterval(Self.refreshMargin) || (stillValid && tooEarly) {
      return accessToken
    }
    if let refreshing, refreshing.generation == generation {
      return try await refreshing.task.value
    }
    let startGeneration = generation
    let task = Task { try await self.performRefresh(from: record, generation: startGeneration) }
    refreshing = (startGeneration, task)
    return try await task.value
  }

  private func finishRefresh(_ startGeneration: UInt64) {
    if refreshing?.generation == startGeneration { refreshing = nil }
  }

  private func performRefresh(
    from current: ChatGPTCredentialRecord, generation startGeneration: UInt64
  )
    async throws -> String
  {
    let response: ChatGPTTokenResponse
    do {
      response = try await authorizer.refresh(current)
    } catch ChatGPTRefreshFailure.terminal {
      finishRefresh(startGeneration)
      if generation == startGeneration {
        reauthRequired = true
        let cleared = current.signedOut(at: authorizer.now())
        do {
          try store.save(cleared, account: account)
          record = cleared
        } catch {
          // 清除写入失败时尝试删除;两者均失败必须报告存储故障,不能假称已清。
          do {
            try store.delete(account: account)
            record = nil
          } catch {
            record = current
            cleanupPending = true
            throw ChatGPTPlanUnavailable.credentialsUnavailable
          }
        }
      }
      throw ChatGPTPlanUnavailable.reauthorizationRequired
    } catch ChatGPTRefreshFailure.clientConfiguration {
      finishRefresh(startGeneration)
      throw ChatGPTPlanUnavailable.clientConfigurationInvalid
    } catch is CancellationError {
      finishRefresh(startGeneration)
      throw CancellationError()
    } catch {
      finishRefresh(startGeneration)
      throw ChatGPTPlanUnavailable.credentialsUnavailable
    }
    guard generation == startGeneration, record?.subject == current.subject else {
      // 退出或重新登录发生在刷新途中:旧结果不得复活会话;新发的 refresh token 尽量撤销。
      finishRefresh(startGeneration)
      if let issued = response.refreshToken {
        let authorizer = self.authorizer
        let clientID = current.clientID
        Task {
          _ = await authorizer.revoke(refreshToken: issued, clientID: clientID, retryDelays: [])
        }
      }
      throw ChatGPTPlanUnavailable.accountChanged
    }
    var next = current
    next.accessToken = response.accessToken
    if let refreshToken = response.refreshToken { next.refreshToken = refreshToken }
    if let idToken = response.idToken { next.idToken = idToken }
    let now = authorizer.now()
    next.accessTokenExpiresAt = response.expiresAt ?? now.addingTimeInterval(Self.assumedLifetime)
    next.earliestRefreshAt = response.earliestRefreshAt
    if let scopes = response.scopes { next.scopes = scopes }
    next.savedAt = now
    do {
      try store.save(next, account: account)
    } catch {
      // 轮换后的令牌没能落盘:不在内存里冒充已恢复;下次取令牌会以旧 refresh token 再试并如实失败。
      finishRefresh(startGeneration)
      throw ChatGPTPlanUnavailable.credentialsUnavailable
    }
    record = next
    finishRefresh(startGeneration)
    guard next.planUsageGranted else { throw ChatGPTPlanUnavailable.planUsageNotGranted }
    return response.accessToken
  }

  /// 退出:先停新请求(换代际),再尝试远端撤销,最后清本地令牌并保留注册映射。
  func signOut() async -> ChatGPTSignOutResult {
    generation &+= 1
    let myGeneration = generation
    signingOut = true
    refreshing?.task.cancel()
    refreshing = nil
    do {
      try ensureLoaded()
    } catch {
      // 无法读取令牌时不能确认远端撤销,仍尝试按账户删除本地项。
      let localCleared: Bool
      do {
        try store.delete(account: account)
        localCleared = true
      } catch {
        localCleared = false
      }
      record = nil
      loaded = localCleared
      cleanupPending = !localCleared
      reauthRequired = false
      signingOut = false
      return ChatGPTSignOutResult(
        remoteRevocationConfirmed: false, localTokensCleared: localCleared)
    }
    guard let current = record, current.hasTokens || reauthRequired || cleanupPending else {
      reauthRequired = false
      signingOut = false
      cleanupPending = false
      return ChatGPTSignOutResult(remoteRevocationConfirmed: true, localTokensCleared: true)
    }
    var remote = true
    if let refreshToken = current.refreshToken {
      remote = await authorizer.revoke(refreshToken: refreshToken, clientID: current.clientID)
    }
    // 撤销期间若已重新登录,不能清掉新会话。
    guard generation == myGeneration else {
      return ChatGPTSignOutResult(remoteRevocationConfirmed: remote, localTokensCleared: true)
    }
    let cleared = current.signedOut(at: authorizer.now())
    var localCleared = true
    var remaining: ChatGPTCredentialRecord? = cleared
    do {
      try store.save(cleared, account: account)
    } catch {
      // 保留注册映射写不进去时,退而删除整条记录;令牌必须离开本机存储。
      do {
        try store.delete(account: account)
        remaining = nil
      } catch {
        localCleared = false
      }
    }
    // 清除未落盘时不能丢掉用于再次撤销/清盘的记录,但该账户已禁止推理。
    record = localCleared ? remaining : current
    cleanupPending = !localCleared
    reauthRequired = false
    signingOut = false
    return ChatGPTSignOutResult(remoteRevocationConfirmed: remote, localTokensCleared: localCleared)
  }
}
