import CryptoKit
import Foundation
import os

/// 统一诊断事件的严重级别。事件字段均为结构化事实，不承载业务正文。
public enum DiagnosticSeverity: String, Codable, Sendable {
  case debug
  case notice
  case error
  case fault
}

/// 统一诊断事件的固定字段白名单。
///
/// 这里刻意不用 `[String: Any]`：Codable 的自由字典很容易把 prompt、响应正文或
/// provider body 顺手带进诊断包。新增字段必须先在这个类型里立契约。
public struct DiagnosticEventFields: Codable, Equatable, Sendable {
  public var family: String?
  public var operation: String?
  public var role: String?
  public var purpose: String?
  public var origin: String?
  public var meetingHash: String?
  public var providerID: String?
  public var model: String?
  public var endpointFingerprint: String?
  public var requestedReasoning: String?
  public var effectiveReasoning: String?
  public var wireReasoning: String?
  public var stream: Bool?
  public var expectsJSON: Bool?
  public var timeoutProfile: String?
  public var attempt: Int?
  public var retryGroup: String?
  public var stage: String?
  public var outcome: String?
  public var category: String?
  public var httpStatus: Int?
  public var providerErrorCode: String?
  public var inputSize: Int?
  public var outputSize: Int?
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var latencyMs: Int?
  public var firstFrameMs: Int?
  public var responseBytes: Int?
  public var parseShape: String?
  public var droppedCount: Int?
  public var charged: String?
  public var errorSummary: String?

  public init(
    family: String? = nil,
    operation: String? = nil,
    role: String? = nil,
    purpose: String? = nil,
    origin: String? = nil,
    meetingHash: String? = nil,
    providerID: String? = nil,
    model: String? = nil,
    endpointFingerprint: String? = nil,
    requestedReasoning: String? = nil,
    effectiveReasoning: String? = nil,
    wireReasoning: String? = nil,
    stream: Bool? = nil,
    expectsJSON: Bool? = nil,
    timeoutProfile: String? = nil,
    attempt: Int? = nil,
    retryGroup: String? = nil,
    stage: String? = nil,
    outcome: String? = nil,
    category: String? = nil,
    httpStatus: Int? = nil,
    providerErrorCode: String? = nil,
    inputSize: Int? = nil,
    outputSize: Int? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    latencyMs: Int? = nil,
    firstFrameMs: Int? = nil,
    responseBytes: Int? = nil,
    parseShape: String? = nil,
    droppedCount: Int? = nil,
    charged: String? = nil,
    errorSummary: String? = nil,
    safeErrorSummary: SafeErrorSummary? = nil
  ) {
    self.family = family
    self.operation = operation
    self.role = role
    self.purpose = purpose
    self.origin = origin
    self.meetingHash = meetingHash
    self.providerID = providerID
    self.model = model
    self.endpointFingerprint = endpointFingerprint
    self.requestedReasoning = requestedReasoning
    self.effectiveReasoning = effectiveReasoning
    self.wireReasoning = wireReasoning
    self.stream = stream
    self.expectsJSON = expectsJSON
    self.timeoutProfile = timeoutProfile
    self.attempt = attempt
    self.retryGroup = retryGroup
    self.stage = stage
    self.outcome = outcome
    self.category = category
    self.httpStatus = httpStatus
    self.providerErrorCode = providerErrorCode
    self.inputSize = inputSize
    self.outputSize = outputSize
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.latencyMs = latencyMs
    self.firstFrameMs = firstFrameMs
    self.responseBytes = responseBytes
    self.parseShape = parseShape
    self.droppedCount = droppedCount
    self.charged = charged
    // 出处靠类型，不靠文本形状：SafeErrorSummary 只能由本文件的 sanitizer 构造，因此按原样落库；
    // 任意 String 入口一律再脱敏一次（对所有其他调用方保持纵深防御）。
    self.errorSummary = safeErrorSummary?.value ?? errorSummary.map(DiagnosticSanitizer.summary)
  }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let ts: Date
  public let event: String
  public let severity: DiagnosticSeverity
  public let source: String
  public let correlationID: String
  public let fields: DiagnosticEventFields

  public init(
    event: String,
    severity: DiagnosticSeverity = .notice,
    source: String = "app",
    correlationID: String = UUID().uuidString.lowercased(),
    ts: Date = Date(),
    fields: DiagnosticEventFields = .init(),
    schemaVersion: Int = DiagnosticEvent.currentSchemaVersion
  ) {
    self.schemaVersion = schemaVersion
    self.ts = ts
    self.event = DiagnosticSanitizer.token(event, fallback: "unknown")
    self.severity = severity
    self.source = DiagnosticSanitizer.token(source, fallback: "app")
    self.correlationID = DiagnosticSanitizer.correlationID(correlationID)
    self.fields = fields
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DecodeKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    ts =
      try container.decodeIfPresent(Date.self, forKey: .ts)
      ?? container.decodeIfPresent(Date.self, forKey: .timestamp)
      ?? Date.distantPast
    event = DiagnosticSanitizer.token(
      try container.decodeIfPresent(String.self, forKey: .event) ?? "unknown",
      fallback: "unknown"
    )
    severity = try container.decodeIfPresent(DiagnosticSeverity.self, forKey: .severity) ?? .notice
    source = DiagnosticSanitizer.token(
      try container.decodeIfPresent(String.self, forKey: .source) ?? "legacy",
      fallback: "legacy"
    )
    correlationID = DiagnosticSanitizer.correlationID(
      try container.decodeIfPresent(String.self, forKey: .correlationID) ?? "legacy"
    )
    fields = try container.decodeIfPresent(DiagnosticEventFields.self, forKey: .fields) ?? .init()
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case ts
    case event
    case severity
    case source
    case correlationID
    case fields
  }

  private enum DecodeKeys: String, CodingKey {
    case schemaVersion
    case ts
    case timestamp
    case event
    case severity
    case source
    case correlationID
    case fields
  }
}

public struct DiagnosticLedgerLimits: Equatable, Sendable {
  public var maximumLineBytes: Int
  public var maximumDailyRecords: Int
  public var maximumDailyBytes: Int
  public var retentionDays: Int

  public init(
    maximumLineBytes: Int = 2_048,
    maximumDailyRecords: Int = 2_000,
    maximumDailyBytes: Int = 2 * 1_024 * 1_024,
    retentionDays: Int = 14
  ) {
    self.maximumLineBytes = max(256, maximumLineBytes)
    self.maximumDailyRecords = max(1, maximumDailyRecords)
    self.maximumDailyBytes = max(self.maximumLineBytes, maximumDailyBytes)
    self.retentionDays = max(1, retentionDays)
  }
}

public struct DiagnosticLedgerSourceSummary: Equatable, Sendable {
  public let status: String
  public let recordCount: Int
  public let byteCount: Int
  public let droppedCount: Int
  public let redacted: Bool
  public let note: String?

  public init(
    status: String,
    recordCount: Int,
    byteCount: Int,
    droppedCount: Int = 0,
    redacted: Bool = true,
    note: String? = nil
  ) {
    self.status = status
    self.recordCount = recordCount
    self.byteCount = byteCount
    self.droppedCount = droppedCount
    self.redacted = redacted
    self.note = note
  }
}

/// 有界、追加式的全局诊断事件账本。
///
/// `append` 永远是 best-effort：目录不可写、单行超限或达到预算时只增加丢弃计数并
/// 退回 OSLog，不会让录音、模型请求或会议落盘失败。
public struct DiagnosticEventLedger: @unchecked Sendable {
  public static let shared: DiagnosticEventLedger = {
    // SwiftPM verification 二进制不应把夹具事件写进用户真实 ~/JustSaid。
    // App bundle 才启用生产账本；验证通过显式注入临时 root 测完整写盘行为。
    if Bundle.main.bundleIdentifier == "com.justsaid.app" {
      return DiagnosticEventLedger()
    }
    return DiagnosticEventLedger(disabled: true)
  }()

  public let rootDirectory: URL
  public let limits: DiagnosticLedgerLimits

  private let store: Store

  public init(
    rootDirectory: URL = DiagnosticEventLedger.defaultRootDirectory(),
    limits: DiagnosticLedgerLimits = .init(),
    fileManager: FileManager = .default
  ) {
    self.rootDirectory = rootDirectory
    self.limits = limits
    self.store = Store(
      rootDirectory: rootDirectory,
      limits: limits,
      fileManager: fileManager
    )
  }

  public init(disabled: Bool) {
    rootDirectory = URL(fileURLWithPath: "/__justsaid_diagnostics_disabled__")
    limits = .init()
    store = Store(
      rootDirectory: rootDirectory,
      limits: limits,
      fileManager: .default,
      disabled: disabled
    )
  }

  public static func defaultRootDirectory(
    fileManager: FileManager = .default
  ) -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("JustSaid", isDirectory: true)
      .appendingPathComponent("diagnostics", isDirectory: true)
  }

  public func append(_ event: DiagnosticEvent) {
    store.append(event)
  }

  public func append(
    event: String,
    severity: DiagnosticSeverity = .notice,
    source: String = "app",
    correlationID: String = UUID().uuidString.lowercased(),
    ts: Date = Date(),
    fields: DiagnosticEventFields = .init()
  ) {
    append(
      DiagnosticEvent(
        event: event,
        severity: severity,
        source: source,
        correlationID: correlationID,
        ts: ts,
        fields: fields
      )
    )
  }

  public func events() -> [DiagnosticEvent] {
    store.events()
  }

  public func sourceSummary() -> DiagnosticLedgerSourceSummary {
    store.sourceSummary()
  }

  public func eventFiles() -> [URL] {
    store.eventFiles()
  }

  private final class Store: @unchecked Sendable {
    private let rootDirectory: URL
    private let limits: DiagnosticLedgerLimits
    private let fileManager: FileManager
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.justsaid.app", category: "DiagnosticsLedger")
    private let disabled: Bool

    init(
      rootDirectory: URL,
      limits: DiagnosticLedgerLimits,
      fileManager: FileManager,
      disabled: Bool = false
    ) {
      self.rootDirectory = rootDirectory
      self.limits = limits
      self.fileManager = fileManager
      self.disabled = disabled
    }

    func append(_ event: DiagnosticEvent) {
      guard !disabled else { return }
      lock.lock()
      defer { lock.unlock() }
      do {
        try ensureDirectory()
        try pruneOldFiles(now: event.ts)
        let data = try encodedLine(event)
        guard data.count <= limits.maximumLineBytes else {
          incrementDropped(now: event.ts)
          logger.notice("诊断事件过大，已丢弃 event=\(event.event, privacy: .public)")
          return
        }
        let url = eventURL(for: event.ts)
        let current = try currentFileStats(url)
        guard current.records < limits.maximumDailyRecords,
          current.bytes + data.count <= limits.maximumDailyBytes
        else {
          incrementDropped(now: event.ts)
          logger.notice("诊断账本达到每日上限，已丢弃 event=\(event.event, privacy: .public)")
          return
        }
        if fileManager.fileExists(atPath: url.path) {
          let handle = try FileHandle(forWritingTo: url)
          defer { try? handle.close() }
          try handle.seekToEnd()
          try handle.write(contentsOf: data)
        } else {
          try data.write(to: url, options: .withoutOverwriting)
        }
      } catch {
        incrementDropped(now: event.ts)
        logger.error("诊断事件写入失败，已降级 OSLog: \(Self.safeError(error), privacy: .public)")
      }
    }

    func events() -> [DiagnosticEvent] {
      guard !disabled else { return [] }
      lock.lock()
      defer { lock.unlock() }
      return eventFilesUnlocked().flatMap { url in
        guard let data = try? Data(contentsOf: url) else { return [DiagnosticEvent]() }
        return data.split(separator: 0x0A).compactMap { line in
          try? JSONDecoder.diagnostic.decode(DiagnosticEvent.self, from: Data(line))
        }
      }.sorted { $0.ts < $1.ts }
    }

    func eventFiles() -> [URL] {
      guard !disabled else { return [] }
      lock.lock()
      defer { lock.unlock() }
      return eventFilesUnlocked()
    }

    private func eventFilesUnlocked() -> [URL] {
      guard !disabled else { return [] }
      guard
        let entries = try? fileManager.contentsOfDirectory(
          at: rootDirectory,
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles]
        )
      else { return [] }
      return entries.filter { url in
        guard url.lastPathComponent.hasPrefix("diagnostic-events-"),
          url.pathExtension == "jsonl",
          (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return false }
        return true
      }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func sourceSummary() -> DiagnosticLedgerSourceSummary {
      guard !disabled else {
        return DiagnosticLedgerSourceSummary(
          status: "disabled",
          recordCount: 0,
          byteCount: 0,
          note: "非 App 进程未启用生产账本"
        )
      }
      lock.lock()
      defer { lock.unlock() }
      let files = eventFilesUnlocked()
      guard !files.isEmpty else {
        return DiagnosticLedgerSourceSummary(
          status: "missing",
          recordCount: 0,
          byteCount: 0,
          droppedCount: droppedCount(),
          note: "统一事件账本尚未生成"
        )
      }
      var records = 0
      var bytes = 0
      for file in files {
        let attributes = try? fileManager.attributesOfItem(atPath: file.path)
        bytes += (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if let data = try? Data(contentsOf: file) {
          records += data.split(separator: 0x0A).count
        }
      }
      return DiagnosticLedgerSourceSummary(
        status: "included",
        recordCount: records,
        byteCount: bytes,
        droppedCount: droppedCount(),
        note: "字段按白名单脱敏；按日轮转，保留 "
          + String(limits.retentionDays) + " 天"
      )
    }

    private func ensureDirectory() throws {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue,
          (try? rootDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw CocoaError(.fileReadNoSuchFile) }
        return
      }
      try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func encodedLine(_ event: DiagnosticEvent) throws -> Data {
      let encoder = JSONEncoder.diagnostic
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(event) + Data([0x0A])
    }

    private func eventURL(for date: Date) -> URL {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "yyyyMMdd"
      return rootDirectory.appendingPathComponent(
        "diagnostic-events-\(formatter.string(from: date)).jsonl"
      )
    }

    private func currentFileStats(_ url: URL) throws -> (records: Int, bytes: Int) {
      guard let data = try? Data(contentsOf: url) else { return (0, 0) }
      return (data.split(separator: 0x0A).count, data.count)
    }

    private func pruneOldFiles(now: Date) throws {
      let calendar = Calendar(identifier: .gregorian)
      let cutoff = calendar.date(byAdding: .day, value: -limits.retentionDays, to: now) ?? now
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "yyyyMMdd"
      let cutoffName = formatter.string(from: cutoff)
      for url in eventFilesUnlocked()
      where url.deletingPathExtension().lastPathComponent < "diagnostic-events-\(cutoffName)" {
        try? fileManager.removeItem(at: url)
      }
    }

    private func droppedURL() -> URL {
      rootDirectory.appendingPathComponent("diagnostic-events-dropped.json")
    }

    private func droppedCount() -> Int {
      guard let data = try? Data(contentsOf: droppedURL()),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let count = object["count"] as? Int
      else { return 0 }
      return count
    }

    private func incrementDropped(now: Date) {
      let next = droppedCount() + 1
      let object: [String: Any] = [
        "schemaVersion": DiagnosticEvent.currentSchemaVersion,
        "count": next,
        "updatedAt": ISO8601DateFormatter().string(from: now),
      ]
      guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      else { return }
      try? data.write(to: droppedURL(), options: .atomic)
    }

    private static func safeError(_ error: Error) -> String {
      DiagnosticSanitizer.summary(error.localizedDescription)
    }
  }
}

/// 已由 `DiagnosticSanitizer` 生成的错误摘要。初始化器是 fileprivate，本文件之外拿不到构造入口，
/// 所以账本收到它就等于收到「这串文本是本进程按固定规则生成的」这一编译期事实，无需再解析文本。
public struct SafeErrorSummary: Sendable {
  public let value: String

  fileprivate init(_ value: String) {
    self.value = value
  }
}

public enum DiagnosticSanitizer {
  public static func token(_ value: String, fallback: String) -> String {
    let result =
      value
      .components(separatedBy: .whitespacesAndNewlines)
      .joined(separator: "_")
      .filter { $0.isLetter || $0.isNumber || "._-".contains($0) }
    return result.isEmpty ? fallback : String(result.prefix(80))
  }

  public static func correlationID(_ value: String) -> String {
    let cleaned = value.filter { $0.isLetter || $0.isNumber || "-_".contains($0) }
    return String((cleaned.isEmpty ? UUID().uuidString.lowercased() : cleaned).prefix(80))
  }

  /// 错误摘要只允许固定事实；HTTP body、URL、密钥和正文均丢弃。
  public static func summary(_ value: String) -> String {
    var text = value.components(separatedBy: .newlines).joined(separator: " ")
    // 账本写入时会再脱敏一次（DiagnosticEventFields.init），固定文案按闭集合全等放行以免被重新收成
    // 常量；除此之外这里对任意文本一律 fail closed，不认任何可伪造的文本标记。
    if fixedSummaries.contains(text) { return text }
    if let range = text.range(of: "服务请求失败（HTTP ") {
      let suffix = text[range.upperBound...]
      if let end = suffix.firstIndex(of: "）") {
        text = "服务请求失败（HTTP \(suffix[..<end])）"
      }
    }
    let lowered = text.lowercased()
    if lowered.contains("timed out") || text.contains("超时") || text.contains("没有返回任何数据") {
      return "网络请求超时"
    }
    if text.contains("流式响应未正常结束") { return "模型流式响应被截断" }
    if text.contains("返回格式无法解析") { return "模型返回格式无法解析" }
    if text.contains("没有返回可用文本") { return "模型没有返回可用文本" }
    if text.contains("reasoning_content") { return "模型只返回推理内容，未返回最终正文" }
    if text.contains("必须使用 HTTPS") { return "模型地址不是 HTTPS" }
    if text.contains("无法组成 chat/completions") { return "模型地址格式无效" }
    if lowered.contains("cancel") || text.contains("取消") { return "操作已取消" }
    // 未识别的自由文本可能来自 provider body、会议正文或本地路径；不外发。
    return redactedSummary
  }

  /// 文案规则不命中时保留错误的固定身份：Swift 类型名 + `NSError` domain:code（可带 HTTP 状态）。
  /// 身份只由类型系统与受审批的域名组成，`localizedDescription` 原文、HTTP body、URL、本机路径
  /// 与密钥都进不来。返回类型化值，账本据此判断出处，不需要在文本里放任何可伪造的标记。
  public static func summary(for error: Error) -> SafeErrorSummary {
    let text = summary(error.localizedDescription)
    guard text == redactedSummary else { return SafeErrorSummary(text) }
    let nsError = error as NSError
    var tail = ":\(nsError.code)"
    if let status = (error as? HTTPTransportError)?.statusCode { tail += "#http\(status)" }
    // 80 字符按固定优先级分配，四段必须齐全：tail 与分隔符先占位；domain 令牌只能整块保留，放不下
    // 就整块换成定长哈希令牌（截半的 domain 既读不出来，又会让不同 domain 的失败错误地并进一组）；
    // 剩下的额度才给类型名，且至少留 minimumTypeBudget 位。tail 最长是两个十进制 Int（≤42 字符），
    // 加分隔符与定长令牌也远小于 80，所以额度不会算成负数。
    let domainBudget = identityLimit - tail.count - 1 - minimumTypeBudget
    var domain = domainToken(for: error)
    if domain.count > domainBudget { domain = hashedDomainToken(nsError.domain) }
    let typeName = identityComponent(String(describing: Swift.type(of: error)))
    let typeBudget = max(1, identityLimit - tail.count - 1 - domain.count)
    // 分隔符用 `|` 而不是 `@`：`类型@模块.类型` 整串是邮箱形状，会让仓库与导出物的隐私扫描器误报。
    return SafeErrorSummary(
      String((typeName.isEmpty ? "Error" : typeName).prefix(typeBudget)) + "|" + domain + tail)
  }

  /// domain 按出处判断，不按字符形状：只有系统域，或错误类型自身的 Swift 默认桥接域
  /// （`_domain` 缺省实现即 `String(reflecting:)` 出来的全限定类型名）才原样保留。其余 domain 是
  /// 调用方可以塞任意文本的字段（key / host / 路径），换成不含原文的分组令牌。
  private static func domainToken(for error: Error) -> String {
    let domain = (error as NSError).domain
    if approvedErrorDomains.contains(domain) || domain == String(reflecting: Swift.type(of: error)) {
      let readable = identityComponent(domain)
      if !readable.isEmpty { return readable }
    }
    return hashedDomainToken(domain)
  }

  /// 定长 opaque 分组令牌。承诺的是「不存 domain 原文」，不是不可逆：同一 domain 稳定映射到同一
  /// 令牌，所以可以用来分组，也因此对低熵 domain 可被字典枚举。
  private static func hashedDomainToken(_ domain: String) -> String {
    let digest = SHA256.hash(data: Data(domain.utf8))
    return "hashed-" + String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
  }

  static let redactedSummary = "错误详情已脱敏"

  /// 身份摘要的字符上限，以及类型名最少保留的位数：domain 令牌要给类型名留够这么多位才算放得下。
  private static let identityLimit = 80
  private static let minimumTypeBudget = 8

  private static let approvedErrorDomains: Set<String> = [
    NSURLErrorDomain,
    NSCocoaErrorDomain,
    NSPOSIXErrorDomain,
    NSOSStatusErrorDomain,
    NSMachErrorDomain,
  ]

  /// summary 自身可能返回的全部固定文案；重复脱敏时按常量全等放行，不做任何文本解析。
  private static let fixedSummaries: Set<String> = [
    redactedSummary,
    "网络请求超时",
    "模型流式响应被截断",
    "模型返回格式无法解析",
    "模型没有返回可用文本",
    "模型只返回推理内容，未返回最终正文",
    "模型地址不是 HTTPS",
    "模型地址格式无效",
    "操作已取消",
  ]

  /// 身份分量（类型名 / 已审批的 domain）只留字母数字与 `._-`；`|:#` 是格式分隔符，不来自输入。
  private static let identityComponentCharacters = Set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

  private static func identityComponent<S: StringProtocol>(_ value: S) -> String {
    String(value.filter { identityComponentCharacters.contains($0) })
  }

  public static func category(for error: Error) -> String {
    if let transport = error as? HTTPTransportError {
      switch transport {
      case .nonHTTPResponse: return "network"
      case .unsuccessfulStatus(let code, _):
        if (400..<500).contains(code) { return "http4xx" }
        if (500..<600).contains(code) { return "http5xx" }
        return "network"
      }
    }
    if let llm = error as? LLMClientError {
      switch llm {
      case .invalidEndpoint, .insecureEndpoint: return "configuration"
      case .firstFrameTimedOut, .progressTimedOut: return "timeout"
      case .streamTruncated, .streamFailed: return "stream"
      case .malformedResponse: return "invalidResponse"
      case .emptyResponse: return "empty"
      case .reasoningOnlyResponse: return "reasoningOnly"
      }
    }
    if error is CancellationError { return "cancelled" }
    if (error as NSError).domain == NSURLErrorDomain { return "network" }
    return "unknown"
  }
}

extension JSONEncoder {
  fileprivate static var diagnostic: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var diagnostic: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
