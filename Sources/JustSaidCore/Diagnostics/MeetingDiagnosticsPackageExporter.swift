import CryptoKit
import Foundation

public enum MeetingDiagnosticsExportError: LocalizedError, Sendable {
  case destinationIsNotDirectory
  case sourceIsSymlink
  case metadataUnreadable
  case invalidMeetingDirectory
  case stagingFailed(String)
  case archiveFailed(Int32)

  public var errorDescription: String? {
    switch self {
    case .destinationIsNotDirectory:
      return "请选择一个已有文件夹作为诊断包导出位置"
    case .sourceIsSymlink:
      return "本场诊断包拒绝读取符号链接"
    case .metadataUnreadable:
      return "这场会议的结构化诊断记录无法读取"
    case .invalidMeetingDirectory:
      return "无效的会议目录"
    case .stagingFailed(let detail):
      return "本场诊断包暂时无法生成：" + detail
    case .archiveFailed(let status):
      return "本场诊断包压缩失败（ditto " + String(status) + "）"
    }
  }
}

public struct MeetingDiagnosticsPackageReport: Equatable, Sendable {
  public let archiveURL: URL
  public let meetingHash: String
  public let includedNames: [String]
  public let notes: [String]

  public init(
    archiveURL: URL,
    meetingHash: String,
    includedNames: [String],
    notes: [String]
  ) {
    self.archiveURL = archiveURL
    self.meetingHash = meetingHash
    self.includedNames = includedNames
    self.notes = notes
  }
}

/// 单场会议的脱敏诊断导出器。
///
/// 只读取 `meeting.json` 的白名单字段和会中失败 JSONL 的闭合字段；不会复制任何
/// meeting artifact。输出先写入 staging，再压成 ZIP，失败时清理所有临时文件。
public struct MeetingDiagnosticsPackageExporter: @unchecked Sendable {
  public let fileManager: FileManager
  public let diagnosticsRoot: URL
  public let applicationBundle: Bundle
  public let now: Date

  public init(
    fileManager: FileManager = .default,
    diagnosticsRoot: URL = DiagnosticEventLedger.defaultRootDirectory(),
    applicationBundle: Bundle = .main,
    now: Date = Date()
  ) {
    self.fileManager = fileManager
    self.diagnosticsRoot = diagnosticsRoot
    self.applicationBundle = applicationBundle
    self.now = now
  }

  public static func defaultFileName(startedAt: Date, meetingHash: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyyMMdd-HHmm"
    return "JustSaid-本场诊断-\(formatter.string(from: startedAt))-\(meetingHash).zip"
  }

  @discardableResult
  public func export(
    paths: MeetingPaths,
    to destinationDirectory: URL
  ) throws -> URL {
    let exportLedger = DiagnosticEventLedger(rootDirectory: diagnosticsRoot)
    let exportCorrelationID = UUID().uuidString.lowercased()
    exportLedger.append(
      event: "diagnosticsExport.start",
      source: "MeetingDiagnosticsPackageExporter",
      correlationID: exportCorrelationID,
      fields: DiagnosticEventFields(
        family: "diagnostics",
        operation: "meetingExport",
        purpose: "export",
        origin: "meetingDetail",
        outcome: "started"
      )
    )
    guard isDirectory(destinationDirectory), !isSymlink(destinationDirectory) else {
      appendExportFailure(
        exportLedger, correlationID: exportCorrelationID,
        error: MeetingDiagnosticsExportError.destinationIsNotDirectory)
      throw MeetingDiagnosticsExportError.destinationIsNotDirectory
    }
    guard !isSymlink(paths.directory) else {
      appendExportFailure(
        exportLedger, correlationID: exportCorrelationID,
        error: MeetingDiagnosticsExportError.sourceIsSymlink)
      throw MeetingDiagnosticsExportError.sourceIsSymlink
    }
    guard paths.directory.lastPathComponent != "meetings" else {
      appendExportFailure(
        exportLedger, correlationID: exportCorrelationID,
        error: MeetingDiagnosticsExportError.invalidMeetingDirectory)
      throw MeetingDiagnosticsExportError.invalidMeetingDirectory
    }

    let metadata: MeetingMetadata
    do {
      metadata = try MeetingStore(fileManager: fileManager).read(from: paths)
    } catch {
      appendExportFailure(exportLedger, correlationID: exportCorrelationID, error: error)
      throw MeetingDiagnosticsExportError.metadataUnreadable
    }

    let meetingHash = Self.meetingHash(for: metadata.id)
    let finalURL = uniqueArchiveURL(
      parent: destinationDirectory,
      startedAt: metadata.startedAt,
      meetingHash: meetingHash
    )
    let stagingDirectory = destinationDirectory.appendingPathComponent(
      ".justsaid-meeting-diagnostics-\(UUID().uuidString)",
      isDirectory: true
    )
    let stagingArchive = destinationDirectory.appendingPathComponent(
      ".\(finalURL.lastPathComponent).\(UUID().uuidString).partial"
    )
    var notes: [String] = []
    do {
      try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
      let summary = makeSummary(
        metadata: metadata,
        paths: paths,
        meetingHash: meetingHash
      )
      try writeJSON(summary, to: stagingDirectory.appendingPathComponent("meeting-summary.json"))

      let projection = makeLegacyProjection(metadata: metadata)
      try writeJSON(
        projection, to: stagingDirectory.appendingPathComponent("legacy-projection.json"))

      let localEvents = readLocalEvents(
        from: paths,
        metadata: metadata,
        meetingHash: meetingHash,
        notes: &notes
      )
      try writeJSONLines(localEvents, to: stagingDirectory.appendingPathComponent("events.jsonl"))

      let globalEvents = DiagnosticEventLedger(rootDirectory: diagnosticsRoot).events()
        .filter { $0.fields.meetingHash == meetingHash }
      try writeJSONLines(
        globalEvents,
        to: stagingDirectory.appendingPathComponent("global-events.jsonl")
      )
      if globalEvents.isEmpty {
        notes.append("没有找到与本场 hash 关联的统一全局事件；未伪造事件")
      }

      let manifest = makeManifest(
        metadata: metadata,
        meetingHash: meetingHash,
        localEventCount: localEvents.count,
        globalEventCount: globalEvents.count,
        stagingDirectory: stagingDirectory,
        notes: notes
      )
      try writeJSON(manifest, to: stagingDirectory.appendingPathComponent("manifest.json"))

      try runDittoArchive(from: stagingDirectory, to: stagingArchive)
      try fileManager.moveItem(at: stagingArchive, to: finalURL)
      try? fileManager.removeItem(at: stagingDirectory)
      exportLedger.append(
        event: "diagnosticsExport.finish",
        source: "MeetingDiagnosticsPackageExporter",
        correlationID: exportCorrelationID,
        fields: DiagnosticEventFields(
          family: "diagnostics",
          operation: "meetingExport",
          purpose: "export",
          origin: "meetingDetail",
          meetingHash: meetingHash,
          stage: "archive",
          outcome: "success",
          category: "success"
        )
      )
      return finalURL
    } catch let error as MeetingDiagnosticsExportError {
      try? fileManager.removeItem(at: stagingDirectory)
      try? fileManager.removeItem(at: stagingArchive)
      appendExportFailure(
        exportLedger,
        correlationID: exportCorrelationID,
        meetingHash: meetingHash,
        error: error
      )
      throw error
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      try? fileManager.removeItem(at: stagingArchive)
      appendExportFailure(
        exportLedger,
        correlationID: exportCorrelationID,
        meetingHash: meetingHash,
        error: error
      )
      throw MeetingDiagnosticsExportError.stagingFailed(
        DiagnosticSanitizer.summary(error.localizedDescription))
    }
  }

  public static func meetingHash(for id: UUID) -> String {
    let digest = SHA256.hash(data: Data(id.uuidString.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
  }

  private struct MeetingSummary: Codable {
    let schemaVersion: Int
    let meetingHash: String
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: Int?
    let status: String
    let language: String
    let finalized: Bool
    let build: String
    let source: String
    let hasTranscript: Bool
    let hasMinutes: Bool
    let hasLocalDiagnostics: Bool
  }

  private struct LegacyProjection: Codable {
    let schemaVersion: Int
    let meetingHash: String
    let cloudUsage: [UsageProjection]
    let postMeetingFailures: [PostMeetingFailureProjection]
    let minutesFailures: [MinutesFailureProjection]
    let stages: [StageProjection]
    let capture: CaptureProjection?
    let captureLegFailures: [CaptureFailureProjection]
    let partialArtifacts: [PartialArtifactProjection]
  }

  private struct UsageProjection: Codable {
    let timestamp: Date
    let role: String
    let provider: String
    let model: String
    let purpose: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let audioDurationSeconds: Double?
    let outcome: String?
  }

  private struct PostMeetingFailureProjection: Codable {
    let failedAt: Date
    let source: String
    let requestSuffix: String
    let logSuffix: String?
    let category: String
  }

  private struct MinutesFailureProjection: Codable {
    let failedAt: Date
    let language: String
    let attempt: Int
    let kind: String
    let category: String
  }

  private struct StageProjection: Codable {
    let at: Date
    let stage: String
  }

  private struct CaptureProjection: Codable {
    let microphone: CaptureLegProjection
    let systemAudio: CaptureLegProjection
  }

  private struct CaptureLegProjection: Codable {
    let capturedFrames: UInt64
    let writtenFrames: UInt64
    let gapFrames: UInt64
    let droppedByBackpressure: UInt64
    let droppedByOverload: UInt64
    let droppedOutOfOrder: UInt64
    let asrFedFrames: UInt64
    let asrSkippedFrames: UInt64
  }

  private struct CaptureFailureProjection: Codable {
    let leg: String
    let firstFailureSeconds: Double?
    let category: String
  }

  private struct PartialArtifactProjection: Codable {
    let artifact: String
    let failedAt: Date
    let category: String
  }

  private struct Manifest: Codable {
    let collector: String
    let schemaVersion: Int
    let generatedAt: Date
    let meetingHash: String
    let sources: [String: Source]
    let redactions: [String]
    let notes: [String]

    struct Source: Codable {
      let status: String
      let recordCount: Int
      let byteCount: Int
      let droppedCount: Int
      let redacted: Bool
      let unified: Bool
    }
  }

  private func makeSummary(
    metadata: MeetingMetadata,
    paths: MeetingPaths,
    meetingHash: String
  ) -> MeetingSummary {
    let duration = metadata.endedAt.map { max(0, Int($0.timeIntervalSince(metadata.startedAt))) }
    return MeetingSummary(
      schemaVersion: 1,
      meetingHash: meetingHash,
      startedAt: metadata.startedAt,
      endedAt: metadata.endedAt,
      durationSeconds: duration,
      status: metadata.status.rawValue,
      language: metadata.language.rawValue,
      finalized: metadata.finalized,
      build: applicationBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "unknown",
      source: "JustSaid",
      hasTranscript: nonEmptyFile(paths.transcript),
      hasMinutes: nonEmptyFile(paths.minutes) || nonEmptyFile(paths.minutesFull),
      hasLocalDiagnostics: readableLocalDiagnostics(at: paths)
    )
  }

  private func readableLocalDiagnostics(at paths: MeetingPaths) -> Bool {
    guard !isSymlink(paths.diagnostics),
      fileManager.fileExists(atPath: paths.liveSummaryFailureDiagnostics.path)
    else { return false }
    return (try? Data(contentsOf: paths.liveSummaryFailureDiagnostics)) != nil
  }

  private func makeLegacyProjection(metadata: MeetingMetadata) -> LegacyProjection {
    LegacyProjection(
      schemaVersion: 1,
      meetingHash: Self.meetingHash(for: metadata.id),
      cloudUsage: metadata.cloudUsage.map {
        UsageProjection(
          timestamp: $0.timestamp,
          role: $0.role.rawValue,
          provider: DiagnosticSanitizer.token($0.provider, fallback: "unknown"),
          model: DiagnosticSanitizer.token($0.model, fallback: "unknown"),
          purpose: $0.purpose.map { DiagnosticSanitizer.token($0, fallback: "unknown") },
          inputTokens: $0.inputTokens,
          outputTokens: $0.outputTokens,
          audioDurationSeconds: $0.audioDurationSeconds,
          outcome: $0.outcome.map { DiagnosticSanitizer.token($0, fallback: "unknown") }
        )
      },
      postMeetingFailures: (metadata.postMeetingFailureAttempts ?? []).map {
        PostMeetingFailureProjection(
          failedAt: $0.failedAt,
          source: $0.source.rawValue,
          requestSuffix: String($0.requestID.suffix(8)),
          logSuffix: $0.logID.map { String($0.suffix(8)) },
          category: category(from: $0.detail)
        )
      },
      minutesFailures: (metadata.minutesFailureAttempts ?? []).map {
        MinutesFailureProjection(
          failedAt: $0.failedAt,
          language: DiagnosticSanitizer.token($0.language, fallback: "unknown"),
          attempt: $0.attempt,
          kind: DiagnosticSanitizer.token($0.kind, fallback: "unknown"),
          category: category(from: $0.detail)
        )
      },
      stages: (metadata.postMeetingStageHistory ?? []).map {
        StageProjection(at: $0.at, stage: DiagnosticSanitizer.token($0.stage, fallback: "unknown"))
      },
      capture: metadata.captureLossStats.map {
        CaptureProjection(
          microphone: captureProjection($0.microphone),
          systemAudio: captureProjection($0.systemAudio)
        )
      },
      captureLegFailures: (metadata.captureLegFailures ?? []).map {
        CaptureFailureProjection(
          leg: $0.leg.rawValue,
          firstFailureSeconds: $0.firstFailureSecondsIntoMeeting,
          category: category(from: $0.message)
        )
      },
      partialArtifacts: (metadata.partialArtifactFailures ?? []).map {
        PartialArtifactProjection(
          artifact: DiagnosticSanitizer.token($0.artifact, fallback: "unknown"),
          failedAt: $0.failedAt,
          category: category(from: $0.detail)
        )
      }
    )
  }

  private func captureProjection(_ stats: CaptureLossStats) -> CaptureLegProjection {
    CaptureLegProjection(
      capturedFrames: stats.capturedFrames,
      writtenFrames: stats.writtenFrames,
      gapFrames: stats.gapFrames,
      droppedByBackpressure: stats.droppedByBackpressure,
      droppedByOverload: stats.droppedByOverload,
      droppedOutOfOrder: stats.droppedOutOfOrder,
      asrFedFrames: stats.asrFedFrames,
      asrSkippedFrames: stats.asrSkippedFrames
    )
  }

  private func readLocalEvents(
    from paths: MeetingPaths,
    metadata: MeetingMetadata,
    meetingHash: String,
    notes: inout [String]
  ) -> [DiagnosticEvent] {
    guard !isSymlink(paths.diagnostics),
      let data = try? Data(contentsOf: paths.liveSummaryFailureDiagnostics)
    else {
      notes.append("本场会中解析诊断不存在或不可读")
      return []
    }
    var events: [DiagnosticEvent] = []
    for line in data.split(separator: 0x0A) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
      else {
        notes.append("本场会中解析诊断有无法解析的行，已丢弃")
        continue
      }
      let lane = object["lane"] as? String ?? "unknown"
      let category = object["category"] as? String ?? "invalidResponse"
      let error = object["error"] as? String ?? "解析失败"
      let date = (object["ts"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? now
      let fields = DiagnosticEventFields(
        family: "llm",
        operation: "parse",
        purpose: "liveSummary",
        meetingHash: meetingHash,
        stage: "parse",
        outcome: "failure",
        category: DiagnosticSanitizer.token(category, fallback: "invalidResponse"),
        parseShape: DiagnosticSanitizer.token(lane, fallback: "unknown"),
        droppedCount: object["responsePrefix"] == nil ? nil : 1,
        errorSummary: DiagnosticSanitizer.summary(error)
      )
      events.append(
        DiagnosticEvent(
          event: "modelCall", severity: .error, source: "meeting", ts: date, fields: fields))
    }
    _ = metadata
    return events
  }

  private func makeManifest(
    metadata: MeetingMetadata,
    meetingHash: String,
    localEventCount: Int,
    globalEventCount: Int,
    stagingDirectory: URL,
    notes: [String]
  ) -> Manifest {
    let localStatus = localEventCount == 0 ? "empty" : "included"
    let globalStatus = globalEventCount == 0 ? "empty" : "included"
    func byteCount(_ name: String) -> Int {
      (try? stagingDirectory
        .appendingPathComponent(name)
        .resourceValues(forKeys: [.fileSizeKey])
        .fileSize) ?? 0
    }
    return Manifest(
      collector: "JustSaid MeetingDiagnosticsPackageExporter",
      schemaVersion: 1,
      generatedAt: now,
      meetingHash: meetingHash,
      sources: [
        "meetingProjection": .init(
          status: "included",
          recordCount: 1,
          byteCount: byteCount("meeting-summary.json"),
          droppedCount: 0,
          redacted: true,
          unified: false
        ),
        "liveSummaryFailures": .init(
          status: localStatus,
          recordCount: localEventCount,
          byteCount: byteCount("events.jsonl"),
          droppedCount: notes.filter { $0.contains("会中解析诊断有无法解析") }.count,
          redacted: true,
          unified: true
        ),
        "globalLedger": .init(
          status: globalStatus,
          recordCount: globalEventCount,
          byteCount: byteCount("global-events.jsonl"),
          droppedCount: 0,
          redacted: true,
          unified: true
        ),
        "meetingJSON": .init(
          status: "projected",
          recordCount: metadata.cloudUsage.count,
          byteCount: byteCount("legacy-projection.json"),
          droppedCount: 0,
          redacted: true,
          unified: false
        ),
      ],
      redactions: [
        "不包含标题、路径、prompt、转写、原始响应/body、responsePrefix、音频、sidecar、history、密钥",
        "仅导出结构化失败分类、状态、计数和限长错误摘要",
      ],
      notes: notes
    )
  }

  private func category(from detail: String) -> String {
    if detail.localizedCaseInsensitiveContains("HTTP 400") { return "http4xx" }
    if detail.localizedCaseInsensitiveContains("HTTP 5") { return "http5xx" }
    if detail.localizedCaseInsensitiveContains("超时") { return "timeout" }
    return "unknown"
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder.diagnostic
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .withoutOverwriting)
  }

  private func writeJSONLines<T: Encodable>(_ values: [T], to url: URL) throws {
    let encoder = JSONEncoder.diagnostic
    encoder.outputFormatting = [.sortedKeys]
    var data = Data()
    for value in values {
      data.append(try encoder.encode(value))
      data.append(0x0A)
    }
    try data.write(to: url, options: .withoutOverwriting)
  }

  private func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private func nonEmptyFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true
    else { return false }
    return (values.fileSize ?? 0) > 0
  }

  private func uniqueArchiveURL(parent: URL, startedAt: Date, meetingHash: String) -> URL {
    let base = Self.defaultFileName(startedAt: startedAt, meetingHash: meetingHash)
    var candidate = parent.appendingPathComponent(base)
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = parent.appendingPathComponent(
        String(base.dropLast(4)) + "-\(suffix).zip"
      )
      suffix += 1
    }
    return candidate
  }

  private func runDittoArchive(from staging: URL, to archive: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--norsrc", "--noextattr", staging.path, archive.path]
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw MeetingDiagnosticsExportError.archiveFailed(-1)
    }
    guard process.terminationStatus == 0 else {
      throw MeetingDiagnosticsExportError.archiveFailed(process.terminationStatus)
    }
  }

  private func appendExportFailure(
    _ ledger: DiagnosticEventLedger,
    correlationID: String,
    meetingHash: String? = nil,
    error: Error
  ) {
    ledger.append(
      event: "diagnosticsExport.finish",
      severity: .error,
      source: "MeetingDiagnosticsPackageExporter",
      correlationID: correlationID,
      fields: DiagnosticEventFields(
        family: "diagnostics",
        operation: "meetingExport",
        purpose: "export",
        origin: "meetingDetail",
        meetingHash: meetingHash,
        stage: "archive",
        outcome: "failure",
        category: DiagnosticSanitizer.category(for: error),
        errorSummary: DiagnosticSanitizer.summary(error.localizedDescription)
      )
    )
  }
}

extension JSONEncoder {
  fileprivate static var diagnostic: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
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
