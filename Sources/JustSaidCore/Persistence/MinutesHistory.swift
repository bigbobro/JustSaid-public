import Foundation

/// 纪要版本来源:LLM 生成 vs 用户在 `minutes.md` 上的手工编辑被归档。
public enum MinutesHistorySource: String, Codable, Equatable, Sendable {
  case generated
  case userEdited
}

/// `minutes-history/NNN-HHmmss.json` 的 sidecar。
public struct MinutesHistorySidecar: Codable, Equatable, Sendable {
  public let version: Int
  public let source: MinutesHistorySource
  /// 仅 `generated` 时有;用户编辑归档通常只有 Markdown 正文。
  public let document: MeetingMinutesDocument?

  public init(
    source: MinutesHistorySource,
    document: MeetingMinutesDocument? = nil
  ) {
    version = 1
    self.source = source
    self.document = document
  }
}

/// 纪要版本历史中的一版(供详情页 Picker 与读盘投影)。
public struct MinutesHistoryRevision: Identifiable, Equatable, Sendable {
  /// 文件名,天然唯一且可排序。
  public let id: String
  public let sequence: Int
  /// 面向人的版本标签,如「第 3 版 · 11:07」;手工编辑会加标注。
  public let label: String
  public let content: String
  public let source: MinutesHistorySource?

  public init(
    id: String,
    sequence: Int,
    label: String,
    content: String,
    source: MinutesHistorySource? = nil
  ) {
    self.id = id
    self.sequence = sequence
    self.label = label
    self.content = content
    self.source = source
  }
}

/// 中文纪要流式写入的临时会话。partial 后缀在 `.md` **之后**,使
/// `pathExtension == "md"` 的版本扫描看不见半成品(design §8.1)。
public struct StreamingChineseMinutesSession: Sendable, Equatable {
  public let sequence: Int
  public let stem: String
  /// `minutes-history/NNN-HHMMSS.md.partial`
  public let partialURL: URL
  /// 定稿后的正式版 `…/NNN-HHMMSS.md`
  public let formalURL: URL
  /// 同名 sidecar `…/NNN-HHMMSS.json`
  public let sidecarURL: URL
}

/// 写入 `minutes-history/`。**先 sidecar 后 Markdown**,纪律与 `SummaryHistoryWriter` 相同。
public struct MinutesHistoryWriter {
  public let directory: URL
  private let fileManager: FileManager

  /// 流式半成品后缀:必须让 `pathExtension` 变成 `partial` 而非 `md`。
  public static let streamingPartialSuffix = "partial"

  public init(directory: URL, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileManager = fileManager
  }

  /// 目录内已有最大序号 +1;空目录从 1 起。
  public func nextSequence() -> Int {
    Self.maxSequence(in: directory, fileManager: fileManager) + 1
  }

  /// 触发生成时立刻建出临时版本文件(可为空),随后流式覆写内容。
  public func beginStreamingPartial(date: Date = Date()) throws -> StreamingChineseMinutesSession {
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let seq = nextSequence()
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HHmmss"
    let stem = String(format: "%03d-%@", seq, formatter.string(from: date))
    let formalURL = directory.appendingPathComponent(stem).appendingPathExtension("md")
    // `stem.md.partial` → pathExtension 为 partial,扫描器过滤掉。
    let partialURL = formalURL.appendingPathExtension(Self.streamingPartialSuffix)
    let sidecarURL = directory.appendingPathComponent(stem).appendingPathExtension("json")
    try Data().write(to: partialURL, options: .atomic)
    return StreamingChineseMinutesSession(
      sequence: seq,
      stem: stem,
      partialURL: partialURL,
      formalURL: formalURL,
      sidecarURL: sidecarURL
    )
  }

  /// 把当前已生成正文写入临时文件(全量覆写,避免 UTF-8 半截追加)。
  public func writeStreamingContent(
    _ content: String,
    session: StreamingChineseMinutesSession
  ) throws {
    try Data(content.utf8).write(to: session.partialURL, options: .atomic)
  }

  /// 定稿:先 sidecar 后正式 Markdown,再删 partial。半成品绝不会进 readRevisions。
  public func finalizeStreaming(
    session: StreamingChineseMinutesSession,
    content: String,
    source: MinutesHistorySource,
    document: MeetingMinutesDocument? = nil
  ) throws {
    let sidecar = MinutesHistorySidecar(source: source, document: document)
    try StructuredArtifactCodec.encode(sidecar).write(
      to: session.sidecarURL,
      options: .atomic
    )
    try Data(content.utf8).write(to: session.formalURL, options: .atomic)
    try? fileManager.removeItem(at: session.partialURL)
  }

  @discardableResult
  public func write(
    content: String,
    source: MinutesHistorySource,
    document: MeetingMinutesDocument? = nil,
    sequence: Int? = nil,
    date: Date = Date()
  ) throws -> URL {
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let seq = sequence ?? nextSequence()
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HHmmss"
    let stem = String(format: "%03d-%@", seq, formatter.string(from: date))
    let url = directory.appendingPathComponent(stem).appendingPathExtension("md")
    let sidecarURL = directory.appendingPathComponent(stem).appendingPathExtension("json")
    let sidecar = MinutesHistorySidecar(source: source, document: document)
    // 先写 sidecar：若 Markdown 随后失败，孤立 JSON 不会被读取；反过来则会产生
    // 看似成功却永久丢掉类型信息的留痕。
    try StructuredArtifactCodec.encode(sidecar).write(to: sidecarURL, options: .atomic)
    try Data(content.utf8).write(to: url, options: .atomic)
    return url
  }

  /// 最新一版正文;无历史时为 nil。
  public func latestContent() -> String? {
    Self.readRevisions(in: directory, fileManager: fileManager).last?.content
  }

  /// 比对前归一化:统一行尾并去掉首尾空白,避免编辑器随手加换行就凭空多一版。
  public static func normalizeForComparison(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 速记占位(会中总结本地拼装)不入版本历史。
  public static func isQuickDraftPlaceholder(_ text: String) -> Bool {
    [
      "速记版·权威转写完成后可生成正式纪要",
      "速记版·可点「生成纪要」生成正式版",
      "速记版·完整版生成中",
    ].contains { text.contains($0) }
  }

  /// 权威转写落盘后只切换速记占位的状态行；正文与用户追加内容保持原字节语义。
  /// 返回 nil 表示当前不是已知速记占位，调用方不得改写正式纪要。
  public static func updatingQuickDraftForTranscriptReady(_ text: String) -> String? {
    guard isQuickDraftPlaceholder(text) else { return nil }
    return
      text
      .replacingOccurrences(
        of: "> **速记版·权威转写完成后可生成正式纪要**",
        with: "> **速记版·可点「生成纪要」生成正式版**"
      )
      .replacingOccurrences(
        of: "> **速记版·完整版生成中**",
        with: "> **速记版·可点「生成纪要」生成正式版**"
      )
      .replacingOccurrences(
        of: "> 此版本仅由本地会中总结与速记拼装，待权威转写和正式纪要完成后更新。",
        with: "> 此版本仅由本地会中总结与速记拼装；权威转写已就绪，可点「生成纪要」生成正式版。"
      )
      .replacingOccurrences(
        of: "> 此版本仅由本地会中总结与速记拼装；待权威转写就绪后再生成正式纪要。",
        with: "> 此版本仅由本地会中总结与速记拼装；权威转写已就绪，可点「生成纪要」生成正式版。"
      )
  }

  public static func maxSequence(
    in directory: URL,
    fileManager: FileManager = .default
  ) -> Int {
    readRevisions(in: directory, fileManager: fileManager).map(\.sequence).max() ?? 0
  }

  public static func readRevisions(
    in directory: URL,
    fileManager: FileManager = .default
  ) -> [MinutesHistoryRevision] {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    return
      entries
      .filter { $0.pathExtension.lowercased() == "md" }
      .compactMap { url -> MinutesHistoryRevision? in
        guard
          let content = try? String(contentsOf: url, encoding: .utf8),
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return nil
        }
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let sequence = Int(parts.first ?? "") ?? 0
        let timeToken = parts.count > 1 ? String(parts[1]) : ""
        let sidecarURL =
          url.deletingPathExtension()
          .appendingPathExtension("json")
        let source: MinutesHistorySource? = {
          guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
          return try? StructuredArtifactCodec.decode(
            MinutesHistorySidecar.self,
            from: data
          ).source
        }()
        return MinutesHistoryRevision(
          id: url.lastPathComponent,
          sequence: sequence,
          label: revisionLabel(
            sequence: sequence,
            timeToken: timeToken,
            source: source
          ),
          content: content,
          source: source
        )
      }
      .sorted { $0.sequence < $1.sequence }
  }

  /// `001-110309` → 「第 1 版 · 11:03」;手工编辑加标注。
  private static func revisionLabel(
    sequence: Int,
    timeToken: String,
    source: MinutesHistorySource?
  ) -> String {
    let digits = timeToken.filter(\.isNumber)
    let timePart: String
    if digits.count >= 4 {
      let hh = digits.prefix(2)
      let mm = digits.dropFirst(2).prefix(2)
      timePart = " · \(hh):\(mm)"
    } else {
      timePart = ""
    }
    let base = "第 \(sequence) 版\(timePart)"
    if source == .userEdited {
      return base + " · 手工编辑"
    }
    return base
  }
}
