import Foundation
import JustSaidCore

/// A Sendable seam around the expensive meeting-library disk scan.  Production uses `live`;
/// verification can wrap it with deterministic suspension without teaching the UI about files.
public struct MeetingLibrarySnapshotLoader: Sendable {
  private let operation: @Sendable (MeetingStore) async -> [MeetingLibraryItem]

  public init(
    operation: @escaping @Sendable (MeetingStore) async -> [MeetingLibraryItem]
  ) {
    self.operation = operation
  }

  public func load(from store: MeetingStore) async -> [MeetingLibraryItem] {
    await operation(store)
  }

  public static let live = MeetingLibrarySnapshotLoader { store in
    let worker = Task.detached(priority: .userInitiated) {
      MeetingLibraryDiskSnapshot.makeItems(from: store)
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}

/// The full detail payload is deliberately independent from the list snapshot.  A large transcript
/// should not delay the first useful library frame.
public struct MeetingArtifactSnapshotLoader: Sendable {
  private let operation: @Sendable (MeetingPaths) async -> MeetingArtifacts

  public init(
    operation: @escaping @Sendable (MeetingPaths) async -> MeetingArtifacts
  ) {
    self.operation = operation
  }

  public func load(from paths: MeetingPaths) async -> MeetingArtifacts {
    await operation(paths)
  }

  public static let live = MeetingArtifactSnapshotLoader { paths in
    let worker = Task.detached(priority: .userInitiated) {
      MeetingArtifacts.read(from: paths)
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}

private enum MeetingLibraryDiskSnapshot {
  static func makeItems(from store: MeetingStore) -> [MeetingLibraryItem] {
    var items: [MeetingLibraryItem] = []
    for record in store.listMeetings() {
      guard !Task.isCancelled else { return [] }
      let paths = record.paths
      let microphoneOK = isNonEmptyFile(paths.microphoneAudio)
      let systemOK = isNonEmptyFile(paths.systemAudio)
      let completenessAcks = CompletenessAckStore.load(from: paths)
      let completenessReport = CompletenessReport.load(from: paths)
      let completeness = completenessReport.map {
        EffectiveCompleteness.resolve(report: $0, acks: completenessAcks)
      }
      // 判定在 Core(`CompletenessReport.shortCoveredSeconds`),与导出会议包的文件头共用。
      // 同一份已读出的报告里顺手取,行视图不为这个数字再碰一次盘。
      let shortCoveredSeconds = completenessReport?.shortCoveredSeconds
      let hasChineseMinutes = hasChineseMinutes(at: paths)
      let hasEnglishMinutes = isNonEmptyFile(paths.minutesEnglish)
      items.append(
        MeetingLibraryItem(
          id: paths.directory.standardizedFileURL.path,
          paths: paths,
          title: record.metadata.title,
          startedAt: record.metadata.startedAt,
          endedAt: record.metadata.endedAt,
          status: record.metadata.status,
          finalized: record.metadata.finalized,
          language: record.metadata.language,
          hasAudio: microphoneOK || systemOK,
          hasAuthoritativeTranscript: isNonEmptyFile(paths.transcript),
          hasChineseMinutes: hasChineseMinutes,
          hasFormalMinutes: hasChineseMinutes || hasEnglishMinutes,
          hasEnglishMinutes: hasEnglishMinutes,
          hasSummaryHistory: containsNonEmptyMarkdown(in: paths.summaryHistory),
          hasNotes: isNonEmptyFile(paths.notes),
          hasUsableAudioChannel: microphoneOK || systemOK,
          batchASRModelDisplayName: record.metadata.latestBatchASRModelDisplayName,
          minutesLLMModelName: record.metadata.latestMinutesLLMModelName,
          postMeetingFailureReason: record.metadata.postMeetingFailureReason,
          postMeetingFailureLogID: record.metadata.postMeetingFailureLogID,
          postMeetingRequestIDSuffix: (record.metadata.postMeetingSystemRequestID
            ?? record.metadata.postMeetingMicrophoneRequestID)
            .map { String($0.suffix(8)) },
          hasSubmittedPostMeetingJob: !record.metadata.postMeetingRecoveryJobs.isEmpty
            && !record.metadata.hasNeverSubmittedPostMeetingJob,
          captureLegFailures: record.metadata.captureLegFailures ?? [],
          captureInterruptions: record.metadata.captureInterruptions ?? [],
          partialArtifactFailures: record.metadata.partialArtifactFailures ?? [],
          isImportedRecording: record.metadata.importedRecording == true,
          speakerNames: record.metadata.speakerNames ?? [:],
          speakerOverrides: record.metadata.speakerOverrides ?? [:],
          dismissedSpeakerSuggestions: record.metadata.dismissedSpeakerSuggestions ?? [],
          excludedRanges: record.metadata.excludedRanges ?? [],
          excludedSpeakers: record.metadata.excludedSpeakers ?? [],
          channelStats: record.metadata.speakerChannelStats,
          client: record.metadata.client,
          project: record.metadata.project,
          effectiveCompleteness: completeness,
          completenessAcks: completenessAcks,
          shortCoveredSeconds: shortCoveredSeconds
        )
      )
    }
    return items
  }

  static func isNonEmptyFile(_ url: URL) -> Bool {
    guard
      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size > 0
    else {
      return false
    }
    return true
  }

  static func containsNonEmptyMarkdown(in directory: URL) -> Bool {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return false
    }
    return entries.contains { entry in
      entry.pathExtension.lowercased() == "md" && isNonEmptyFile(entry)
    }
  }

  /// Keep the list scan light: inspect only the files needed to decide whether a formal minutes
  /// artifact exists.  Full contents are loaded lazily by `MeetingArtifactSnapshotLoader`.
  static func hasChineseMinutes(at paths: MeetingPaths) -> Bool {
    if isNonEmptyFile(paths.minutesFull) {
      return true
    }
    if let data = try? Data(contentsOf: paths.minutesStructured),
      (try? JSONDecoder().decode(MeetingMinutesDocument.self, from: data)) != nil
    {
      return true
    }
    guard
      let text = try? String(contentsOf: paths.minutes, encoding: .utf8),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return false
    }
    return !MinutesHistoryWriter.isQuickDraftPlaceholder(text)
  }
}

extension MeetingArtifacts {
  static let emptyLibrarySnapshot = MeetingArtifacts(
    minutes: nil,
    minutesIsSeparateFullVersion: false,
    minutesEnglish: nil,
    structuredMinutes: nil,
    speakerNamingSuggestions: [],
    transcript: nil,
    notes: nil,
    summarySnapshots: [],
    minutesRevisions: [],
    hasMicrophoneAudio: false,
    hasSystemAudio: false
  )
}

enum MeetingArtifactProjection {
  static func onePager(from artifacts: MeetingArtifacts) -> MeetingMinutesDocument? {
    if let structured = artifacts.structuredMinutes {
      return structured
    }
    guard let minutes = artifacts.minutes else { return nil }
    let points = legacyOutline(from: minutes).map { AnchoredText(text: $0) }
    guard !points.isEmpty else { return nil }
    return MeetingMinutesDocument(
      coreConclusions: [],
      keyDiscussions: points,
      decisions: [],
      actionItems: [],
      openQuestions: [],
      skeleton: nil
    )
  }

  static func participants(
    transcript: String?,
    names: [String: String],
    overrides: [String: String]
  ) -> [String] {
    guard let transcript else { return [] }
    let rows = TranscriptSpeakerNaming.rows(
      in: transcript,
      names: names,
      overrides: overrides
    )
    var seen: Set<String> = []
    var participants: [String] = []
    for case .speech(let line) in rows where seen.insert(line.speaker).inserted {
      participants.append(line.speaker)
    }
    return participants
  }

  private static func legacyOutline(from markdown: String) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for rawLine in markdown.components(separatedBy: .newlines) {
      var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("- ") || line.hasPrefix("* ") {
        line = String(line.dropFirst(2))
      } else if line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix(">") {
        continue
      }
      line =
        line
        .replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !line.isEmpty,
        line != "---",
        !line.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }),
        seen.insert(line).inserted
      else {
        continue
      }
      result.append(line)
      if result.count == 12 { break }
    }
    return result
  }
}

public struct MeetingPackageExportRequest: Sendable {
  let title: String
  let startedAt: Date
  let endedAt: Date?
  let names: [String: String]
  let overrides: [String: String]
  let transcriptionStatus: String
  let paths: MeetingPaths
  let destinationDirectory: URL

  public init(
    title: String,
    startedAt: Date,
    endedAt: Date?,
    names: [String: String],
    overrides: [String: String],
    transcriptionStatus: String,
    paths: MeetingPaths,
    destinationDirectory: URL
  ) {
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.names = names
    self.overrides = overrides
    self.transcriptionStatus = transcriptionStatus
    self.paths = paths
    self.destinationDirectory = destinationDirectory
  }
}

public struct MeetingLibraryExportService: Sendable {
  private let packageOperation: @Sendable (MeetingPackageExportRequest) async throws -> URL
  private let diagnosticsOperation: @Sendable (MeetingPaths, URL) async throws -> URL

  public init(
    packageOperation: @escaping @Sendable (MeetingPackageExportRequest) async throws -> URL,
    diagnosticsOperation: @escaping @Sendable (MeetingPaths, URL) async throws -> URL
  ) {
    self.packageOperation = packageOperation
    self.diagnosticsOperation = diagnosticsOperation
  }

  public func exportPackage(_ request: MeetingPackageExportRequest) async throws -> URL {
    try await packageOperation(request)
  }

  public func exportDiagnostics(paths: MeetingPaths, to destination: URL) async throws -> URL {
    try await diagnosticsOperation(paths, destination)
  }

  public static let live = MeetingLibraryExportService(
    packageOperation: { try await MeetingLibraryExportWorker.exportPackage($0) },
    diagnosticsOperation: { paths, destination in
      try await MeetingLibraryExportWorker.exportDiagnostics(
        paths: paths,
        destinationDirectory: destination
      )
    }
  )
}

private enum MeetingLibraryExportWorker {
  static func exportPackage(_ request: MeetingPackageExportRequest) async throws -> URL {
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let artifacts = MeetingArtifacts.read(from: request.paths)
      guard let document = MeetingArtifactProjection.onePager(from: artifacts) else {
        throw MeetingPackageExportError.missingMinutes
      }
      let participants = MeetingArtifactProjection.participants(
        transcript: artifacts.transcript,
        names: request.names,
        overrides: request.overrides
      )
      let output = try MeetingPackageExporter().export(
        title: request.title,
        startedAt: request.startedAt,
        endedAt: request.endedAt,
        participants: participants,
        transcriptionStatus: request.transcriptionStatus,
        paths: request.paths,
        document: document,
        hasStructuredMinutes: artifacts.structuredMinutes != nil,
        to: request.destinationDirectory
      )
      if Task.isCancelled {
        try? FileManager.default.removeItem(at: output)
        throw CancellationError()
      }
      return output
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  static func exportDiagnostics(
    paths: MeetingPaths,
    destinationDirectory: URL
  ) async throws -> URL {
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let output = try MeetingDiagnosticsPackageExporter().export(
        paths: paths,
        to: destinationDirectory
      )
      if Task.isCancelled {
        try? FileManager.default.removeItem(at: output)
        throw CancellationError()
      }
      return output
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}
