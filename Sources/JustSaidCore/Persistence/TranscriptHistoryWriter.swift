import Foundation

extension MeetingPaths {
  /// 每次替换转写前保存的本地原件；不参与会议包导出。
  public var transcriptHistory: URL {
    directory.appendingPathComponent("transcript-history", isDirectory: true)
  }
}

/// 只供转写发布边界使用。唯一目录不覆盖；receipt 最后写，半份档案不会影响建议读取。
struct TranscriptHistoryWriter {
  let paths: MeetingPaths
  let fileManager: FileManager

  private struct Receipt: Codable {
    let version: Int
    let archivedAt: Date
    let transcriptFingerprint: String?
  }

  func archive(transcript: Data?, metadata: Data, suggestions: Data?) throws {
    try requireDirectory(paths.directory)
    if fileManager.fileExists(atPath: paths.transcriptHistory.path) {
      try requireDirectory(paths.transcriptHistory)
    } else {
      // attributesOfItem also detects dangling symlinks that fileExists misses.
      try requireMissingOrRegular(paths.transcriptHistory)
      try fileManager.createDirectory(
        at: paths.transcriptHistory, withIntermediateDirectories: false)
    }
    let revision = paths.transcriptHistory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: revision, withIntermediateDirectories: false)
    try requireDirectory(revision)
    try metadata.write(
      to: revision.appendingPathComponent("meeting.json"), options: .withoutOverwriting)
    if let suggestions {
      try suggestions.write(
        to: revision.appendingPathComponent("speaker-suggestions.json"),
        options: .withoutOverwriting)
    }
    if let transcript {
      try transcript.write(
        to: revision.appendingPathComponent("transcript.md"), options: .withoutOverwriting)
    }
    let receipt = Receipt(
      version: 1, archivedAt: Date(), transcriptFingerprint: transcript.map(MinutesFingerprint.hex))
    try StructuredArtifactCodec.encode(receipt).write(
      to: revision.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
  }

  /// 完整归档且当前正文已不同，才阻止无版本凭据的旧 minutes 建议。
  /// 准备归档后失败/回滚仍是旧正文，不会仅因目录存在改变旧会议行为。
  static func hasReplacedTranscript(at paths: MeetingPaths, transcriptData: Data) -> Bool {
    let writer = Self(paths: paths, fileManager: .default)
    guard (try? writer.requireDirectory(paths.transcriptHistory)) != nil,
      let entries = try? writer.fileManager.contentsOfDirectory(
        at: paths.transcriptHistory, includingPropertiesForKeys: nil)
    else { return false }
    let current = MinutesFingerprint.hex(of: transcriptData)
    return entries.contains { entry in
      guard UUID(uuidString: entry.lastPathComponent) != nil,
        (try? writer.requireDirectory(entry)) != nil,
        let data = try? writer.readRegularIfPresent(entry.appendingPathComponent("receipt.json")),
        let receipt = try? StructuredArtifactCodec.decode(Receipt.self, from: data),
        receipt.version == 1
      else { return false }
      return receipt.transcriptFingerprint != current
    }
  }

  func readRegularIfPresent(_ url: URL) throws -> Data? {
    try requireMissingOrRegular(url) ? Data(contentsOf: url) : nil
  }

  @discardableResult
  func requireMissingOrRegular(_ url: URL) throws -> Bool {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: url.path)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return false
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw MeetingStoreError.unsafeTranscriptPublicationPath
    }
    return true
  }

  func requireDirectory(_ url: URL) throws {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw MeetingStoreError.unsafeTranscriptPublicationPath
    }
  }
}
