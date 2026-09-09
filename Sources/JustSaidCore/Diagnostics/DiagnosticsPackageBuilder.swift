import Darwin
import Foundation

public enum DiagnosticsPackageError: LocalizedError, Sendable {
  case destinationParentMissing
  case stagingFailed(String)
  case dittoFailed(Int32)
  case refusedMeetingsPath

  public var errorDescription: String? {
    switch self {
    case .destinationParentMissing:
      return "无法写入所选位置"
    case .stagingFailed(let detail):
      return "诊断包收集失败：\(detail)"
    case .dittoFailed(let status):
      return "压缩诊断包失败（ditto \(status)）"
    case .refusedMeetingsPath:
      return "诊断包拒绝收集会议目录"
    }
  }
}

public struct DiagnosticsPackageReport: Sendable, Equatable {
  public var includedNames: [String]
  public var notes: [String]
  public var sources: [String: DiagnosticLedgerSourceSummary]

  public init(
    includedNames: [String],
    notes: [String],
    sources: [String: DiagnosticLedgerSourceSummary] = [:]
  ) {
    self.includedNames = includedNames
    self.notes = notes
    self.sources = sources
  }
}

private struct DiagnosticsManifest: Codable {
  let collector: String
  let schemaVersion: Int
  let generatedAt: Date
  let sources: [String: Source]

  struct Source: Codable {
    let status: String
    let recordCount: Int
    let byteCount: Int
    let droppedCount: Int
    let redacted: Bool
    let note: String?
  }
}

/// 白名单制诊断包。永不枚举 `~/JustSaid/meetings/`。
public struct DiagnosticsPackageBuilder {
  public var homeDirectory: URL
  public var applicationBundle: Bundle
  public var settingsSnapshotText: String
  public var osLogTimeout: TimeInterval
  /// `log show --last` 的时间窗(08-20 评审更正:收集超时的主开销是时间窗扫描,
  /// 不是谓词求值——24h 全量扫在 30s 超时下实测必挂;缩窗才省时间)。
  public var osLogWindow: String
  public var fileManager: FileManager
  public var now: Date

  public init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    applicationBundle: Bundle = .main,
    settingsSnapshotText: String,
    osLogTimeout: TimeInterval = 60,
    osLogWindow: String = "4h",
    fileManager: FileManager = .default,
    now: Date = Date()
  ) {
    self.homeDirectory = homeDirectory
    self.applicationBundle = applicationBundle
    self.settingsSnapshotText = settingsSnapshotText
    self.osLogTimeout = osLogTimeout
    self.osLogWindow = osLogWindow
    self.fileManager = fileManager
    self.now = now
  }

  /// `log show` 参数,独立成可测函数供参数级断言钉红线:
  /// - `--info` 必须在场(缺它收不到 info 级面包屑;`.notice` 落地后是冗余保险);
  /// - 谓词必须保持 `process ==` 维度,**不得**改成 subsystem——那会把同进程的
  ///   AVFoundation / CoreAudio 框架日志全部滤掉,正是查 startRunning 卡死
  ///   最值钱的证据(08-20 评审)。
  public static func osLogArguments(window: String) -> [String] {
    [
      "show",
      "--last", window,
      "--info",
      "--style", "compact",
      "--predicate", "process == \"JustSaid\"",
    ]
  }

  public static func defaultFileName(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmm"
    return "JustSaid-诊断包-\(formatter.string(from: now)).zip"
  }

  public func export(to zipURL: URL) throws -> DiagnosticsPackageReport {
    try rejectMeetingsPath(zipURL)
    let parent = zipURL.deletingLastPathComponent()
    var parentIsDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
      parentIsDirectory.boolValue
    else {
      throw DiagnosticsPackageError.destinationParentMissing
    }

    let staging = parent.appendingPathComponent(
      "justsaid-diagnostics-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: staging) }

    var included: [String] = []
    var notes: [String] = []
    var sources: [String: DiagnosticLedgerSourceSummary] = [:]

    try writeBuildInfo(to: staging)
    included.append("build-info.txt")

    try settingsSnapshotText.write(
      to: staging.appendingPathComponent("settings.txt"),
      atomically: true,
      encoding: .utf8
    )
    included.append("settings.txt")

    try writeSystemInfo(to: staging)
    included.append("system.txt")

    switch try copyDiagnosticsDirectory(to: staging) {
    case .copied:
      included.append("diagnostics/")
      let ledger = DiagnosticEventLedger(
        rootDirectory:
          homeDirectory
          .appendingPathComponent("JustSaid", isDirectory: true)
          .appendingPathComponent("diagnostics", isDirectory: true)
      ).sourceSummary()
      sources["diagnosticLedger"] = ledger
      notes.append(
        "统一事件账本: \(ledger.status), records=\(ledger.recordCount), bytes=\(ledger.byteCount), dropped=\(ledger.droppedCount)"
      )
    case .missing:
      notes.append("diagnostics 目录不存在，已跳过")
      sources["diagnosticLedger"] = DiagnosticLedgerSourceSummary(
        status: "missing",
        recordCount: 0,
        byteCount: 0,
        note: "diagnostics 目录不存在"
      )
    }

    if let osLogNote = collectOSLog(to: staging) {
      notes.append(osLogNote)
    } else {
      included.append(osLogFileName)
    }

    let generated = isoFormatter.string(from: now)
    var manifest = """
      JustSaid 诊断包
      生成时间: \(generated)
      内容清单:
      """
    for name in included {
      manifest += "\n- \(name)"
    }
    if !notes.isEmpty {
      manifest += "\n说明:"
      for note in notes {
        manifest += "\n- \(note)"
      }
    }
    manifest += "\n"
    try manifest.write(
      to: staging.appendingPathComponent("manifest.txt"),
      atomically: true,
      encoding: .utf8
    )
    included.append("manifest.txt")

    let ledger =
      sources["diagnosticLedger"]
      ?? DiagnosticLedgerSourceSummary(
        status: "missing",
        recordCount: 0,
        byteCount: 0,
        note: "diagnostics 目录不存在"
      )
    let hasOSLog = included.contains(osLogFileName)
    let manifestSources: [String: DiagnosticsManifest.Source] = [
      "buildInfo": .init(
        status: "included",
        recordCount: 1,
        byteCount: fileSize(in: staging, name: "build-info.txt"),
        droppedCount: 0,
        redacted: true,
        note: nil
      ),
      "settings": .init(
        status: "included",
        recordCount: 1,
        byteCount: fileSize(in: staging, name: "settings.txt"),
        droppedCount: 0,
        redacted: true,
        note: nil
      ),
      "system": .init(
        status: "included",
        recordCount: 1,
        byteCount: fileSize(in: staging, name: "system.txt"),
        droppedCount: 0,
        redacted: true,
        note: nil
      ),
      "diagnosticsDirectory": .init(
        status: included.contains("diagnostics/") ? "included" : "missing",
        recordCount: included.contains("diagnostics/") ? 1 : 0,
        byteCount: 0,
        droppedCount: 0,
        redacted: true,
        note: included.contains("diagnostics/") ? nil : "diagnostics 目录不存在"
      ),
      "diagnosticLedger": .init(
        status: ledger.status,
        recordCount: ledger.recordCount,
        byteCount: ledger.byteCount,
        droppedCount: ledger.droppedCount,
        redacted: ledger.redacted,
        note: ledger.note
      ),
      "osLog": .init(
        status: hasOSLog ? "included" : "missing",
        recordCount: hasOSLog ? 1 : 0,
        byteCount: hasOSLog ? fileSize(in: staging, name: osLogFileName) : 0,
        droppedCount: 0,
        redacted: true,
        note: hasOSLog ? nil : notes.first(where: { $0.contains("OSLog") })
      ),
    ]
    try writeJSON(
      DiagnosticsManifest(
        collector: "JustSaid DiagnosticsPackageBuilder",
        schemaVersion: 1,
        generatedAt: now,
        sources: manifestSources
      ),
      to: staging.appendingPathComponent("manifest.json")
    )
    included.append("manifest.json")

    if fileManager.fileExists(atPath: zipURL.path) {
      try fileManager.removeItem(at: zipURL)
    }
    try runDittoArchive(from: staging, to: zipURL)
    return DiagnosticsPackageReport(
      includedNames: included,
      notes: notes,
      sources: sources
    )
  }

  private enum DiagnosticsCopyResult {
    case copied
    case missing
  }

  private func copyDiagnosticsDirectory(to staging: URL) throws -> DiagnosticsCopyResult {
    let source =
      homeDirectory
      .appendingPathComponent("JustSaid", isDirectory: true)
      .appendingPathComponent("diagnostics", isDirectory: true)
    try rejectMeetingsPath(source)
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      !isSymlink(source)
    else {
      return .missing
    }

    let destination = staging.appendingPathComponent("diagnostics", isDirectory: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
    let entries = try fileManager.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    for entry in entries {
      try rejectMeetingsPath(entry)
      if isSymlink(entry) { continue }
      let values = try entry.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      try fileManager.copyItem(
        at: entry,
        to: destination.appendingPathComponent(entry.lastPathComponent)
      )
    }
    return .copied
  }

  private func writeBuildInfo(to staging: URL) throws {
    let info = applicationBundle.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "未知"
    let build = info?["CFBundleVersion"] as? String ?? "未知"
    let versionText = readNearbyVERSIONText() ?? "未知（未找到安装包内 VERSION.txt）"
    let text = """
      版本号: \(version)
      build: \(build)
      VERSION.txt:
      \(versionText)
      """
    try text.write(
      to: staging.appendingPathComponent("build-info.txt"),
      atomically: true,
      encoding: .utf8
    )
  }

  private func readNearbyVERSIONText() -> String? {
    let candidates = [
      applicationBundle.bundleURL.deletingLastPathComponent().appendingPathComponent("VERSION.txt"),
      applicationBundle.resourceURL?.appendingPathComponent("VERSION.txt"),
    ].compactMap { $0 }
    for candidate in candidates {
      if let data = try? Data(contentsOf: candidate),
        let text = String(data: data, encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return text
      }
    }
    return nil
  }

  private func writeSystemInfo(to staging: URL) throws {
    let processInfo = ProcessInfo.processInfo
    let version = processInfo.operatingSystemVersion
    let macos =
      "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    let model = sysctlString("hw.model") ?? "未知"
    let memoryBytes = processInfo.physicalMemory
    let memoryGiB = Double(memoryBytes) / 1_073_741_824.0
    let text = """
      macOS: \(macos) (\(processInfo.operatingSystemVersionString))
      机型: \(model)
      内存: \(String(format: "%.1f", memoryGiB)) GiB (\(memoryBytes) bytes)
      """
    try text.write(
      to: staging.appendingPathComponent("system.txt"),
      atomically: true,
      encoding: .utf8
    )
  }

  private var osLogFileName: String {
    "oslog-\(osLogWindow).txt"
  }

  /// 收集失败返回原因写进 manifest(既有行为,不得静默化);
  /// 即使这一路彻底失败,包里仍有 diagnostics/ 下的 start-failures-*.log 落盘证据。
  private func collectOSLog(to staging: URL) -> String? {
    let result = runCommand(
      executable: "/usr/bin/log",
      arguments: Self.osLogArguments(window: osLogWindow),
      timeout: osLogTimeout
    )
    guard let result else {
      return "近 \(osLogWindow) OSLog 超时或无法启动，已跳过"
    }
    guard result.status == 0 else {
      return "近 \(osLogWindow) OSLog 失败（exit \(result.status)），已跳过"
    }
    guard
      !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      // 空文件不算通过(AC2):空输出如实写原因,不出空壳。
      return "近 \(osLogWindow) OSLog 输出为空，已跳过"
    }
    do {
      try result.stdout.write(
        to: staging.appendingPathComponent(osLogFileName),
        atomically: true,
        encoding: .utf8
      )
      return nil
    } catch {
      return "近 \(osLogWindow) OSLog 写盘失败，已跳过"
    }
  }

  private func runDittoArchive(from staging: URL, to zipURL: URL) throws {
    let result = runCommand(
      executable: "/usr/bin/ditto",
      arguments: ["-c", "-k", "--norsrc", "--noextattr", staging.path, zipURL.path],
      timeout: 60
    )
    guard let result, result.status == 0 else {
      throw DiagnosticsPackageError.dittoFailed(result?.status ?? -1)
    }
  }

  private func fileSize(in directory: URL, name: String) -> Int {
    (try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize)
      ?? 0
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .withoutOverwriting)
  }

  private var isoFormatter: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }

  private func rejectMeetingsPath(_ url: URL) throws {
    let standardized = url.standardizedFileURL.path
    if standardized.contains("/JustSaid/meetings") || standardized.contains("/JustSaid/meetings/") {
      throw DiagnosticsPackageError.refusedMeetingsPath
    }
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
  }

  private func runCommand(
    executable: String,
    arguments: [String],
    timeout: TimeInterval
  ) -> (status: Int32, stdout: String)? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return nil
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
  }
}

// MARK: - 设置快照(不含密钥本体)

@MainActor
public enum DiagnosticsSettingsSnapshot {
  public static let audioRetentionDefaultsKey = AudioRetentionPolicy.defaultsKey

  public static func render(
    store: ProviderSettingsStore,
    defaults: UserDefaults = .standard
  ) -> String {
    var lines: [String] = ["# 设置快照（密钥只写已配置/未配置 + 末四位）"]
    lines.append("渠道:")
    if store.configuration.channels.isEmpty {
      lines.append("- （无）")
    }
    for channel in store.configuration.channels {
      let slots = secretSlots(for: channel)
      let secretBits = slots.map { slot in
        if store.hasSecret(slot: slot, forChannel: channel) {
          let suffix = store.secretSuffix(slot: slot, forChannel: channel) ?? "????"
          return "\(slot.rawValue)=已配置 ····\(suffix)"
        }
        return "\(slot.rawValue)=未配置"
      }.joined(separator: ", ")
      lines.append(
        "- \(channel.name) [\(channel.providerID)] \(channel.baseURL) 密钥:\(secretBits)"
      )
    }

    lines.append("角色选择:")
    for role in ProviderRole.allCases {
      let binding = store.binding(for: role)
      lines.append(
        "- \(role.displayName): 渠道/供应商=\(binding.providerID) 模型=\(binding.model)"
      )
    }

    let storage = store.configuration.storage
    lines.append(
      "对象存储: kind=\(storage.kind?.rawValue ?? "nil") tosBucket=\(storage.tosBucket) r2Bucket=\(storage.r2Bucket ?? "")"
    )
    let storageSlots: [ProviderSecretSlot] = [
      .tosAccessKey, .tosSecretKey, .r2AccessKey, .r2SecretKey, .azureAccountKey,
    ]
    let storageSecrets = storageSlots.map { slot -> String in
      let binding = store.binding(for: .batchASR)
      if store.hasSecret(slot: slot, for: binding) {
        let suffix = store.secretSuffix(slot: slot, for: binding) ?? "????"
        return "\(slot.rawValue)=已配置 ····\(suffix)"
      }
      return "\(slot.rawValue)=未配置"
    }.joined(separator: ", ")
    lines.append("存储密钥: \(storageSecrets)")

    let aec = MicrophoneAECSettings.isEnabled(in: defaults)
    let language =
      defaults.string(forKey: "justsaid.meeting.language") ?? MeetingLanguage.auto.rawValue
    let retention = AudioRetentionPolicy.current(in: defaults).displayName
    let hotkey = defaults.string(forKey: "justsaid.hotkey.mark") ?? "默认"
    let chatHotkey = defaults.string(forKey: "justsaid.hotkey.chat") ?? "默认"
    let pauseHotkey = defaults.string(forKey: "justsaid.hotkey.pause") ?? "默认"
    let textScale = defaults.string(forKey: "justsaid.textScale") ?? "未设置"
    lines.append("麦克风回声消除: \(aec ? "开" : "关")")
    lines.append("语言路由: \(language)")
    lines.append("音频保留期: \(retention)")
    lines.append("标记热键: \(hotkey)")
    lines.append("闲聊热键: \(chatHotkey)")
    lines.append("暂停麦克风热键: \(pauseHotkey)")
    lines.append("阅读缩放: \(textScale)")
    return lines.joined(separator: "\n") + "\n"
  }

  private static func secretSlots(for channel: ProviderChannel) -> [ProviderSecretSlot] {
    if channel.providerID.contains("volc") || channel.providerID.contains("seed") {
      return [.accessToken]
    }
    return [.apiKey]
  }
}
