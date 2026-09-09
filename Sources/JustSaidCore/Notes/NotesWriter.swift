import Foundation

public enum NotesWriterError: LocalizedError, Sendable {
  case emptyText
  case unknownMarkPlaceholder

  public var errorDescription: String? {
    switch self {
    case .emptyText:
      return "笔记内容不能为空"
    case .unknownMarkPlaceholder:
      return "找不到待更新的标记占位行"
    }
  }
}

public struct NotesMarkToken: Hashable, Sendable {
  fileprivate let id: UUID

  fileprivate init(id: UUID = UUID()) {
    self.id = id
  }
}

/// 会中笔记落盘：自由文本 + 自动会议时间戳（拍板 B6），格式与 design.md §3 一致：
/// `- [HH:MM:SS] 自由文本`。与 `LiveTranscriptWriter` 同构（actor + 原子写入 + 追加即持久化）。
public actor NotesWriter {
  private let fileURL: URL
  private var lines: [String] = []
  private var markLineIndexes: [UUID: Int] = [:]

  public init(fileURL: URL) throws {
    self.fileURL = fileURL

    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
      lines =
        existing
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
    } else {
      try Data().write(to: fileURL, options: .atomic)
    }
  }

  /// 追加一条笔记；`elapsed` 为相对会议开始的秒数，`suffix` 为可选的来源标注（如“来自标记”）。
  @discardableResult
  public func append(
    elapsed: TimeInterval,
    text: String,
    suffix: String? = nil
  ) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NotesWriterError.emptyText
    }

    let timestamp = Self.formatTimestamp(elapsed)
    let suffixText = suffix.map { "（\($0)）" } ?? ""
    let line = "- [\(timestamp)] \(trimmed)\(suffixText)"
    lines.append(line)
    try persist()
    return line
  }

  /// 「标记」先落一个可见占位行；重试时复用原 token 原地替换，避免产生重复笔记。
  public func writeMarkPlaceholder(
    token: NotesMarkToken? = nil,
    elapsed: TimeInterval
  ) throws -> NotesMarkToken {
    let token = token ?? NotesMarkToken()
    let line = "- [\(Self.formatTimestamp(elapsed))] 已标记，提炼中…"
    if let index = markLineIndexes[token.id], lines.indices.contains(index) {
      lines[index] = line
    } else {
      markLineIndexes[token.id] = lines.count
      lines.append(line)
    }
    try persist()
    return token
  }

  public func resolveMark(
    token: NotesMarkToken,
    text: String
  ) throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NotesWriterError.emptyText
    }
    guard
      let index = markLineIndexes[token.id],
      lines.indices.contains(index)
    else {
      throw NotesWriterError.unknownMarkPlaceholder
    }
    let timestamp = Self.timestamp(from: lines[index]) ?? "00:00:00"
    let previousLine = lines[index]
    lines[index] = "- [\(timestamp)] \(trimmed)（来自标记）"
    do {
      try persist()
      markLineIndexes.removeValue(forKey: token.id)
    } catch {
      lines[index] = previousLine
      throw error
    }
  }

  public func failMark(token: NotesMarkToken) throws {
    guard
      let index = markLineIndexes[token.id],
      lines.indices.contains(index)
    else {
      throw NotesWriterError.unknownMarkPlaceholder
    }
    let timestamp = Self.timestamp(from: lines[index]) ?? "00:00:00"
    lines[index] = "- [\(timestamp)] 标记于 \(timestamp)（提炼失败，可重试）"
    try persist()
  }

  private func persist() throws {
    let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    guard let data = content.data(using: .utf8) else {
      return
    }
    try data.write(to: fileURL, options: .atomic)
  }

  private static func formatTimestamp(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded(.down)))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let remainingSeconds = totalSeconds % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
  }

  private static func timestamp(from line: String) -> String? {
    guard
      let start = line.firstIndex(of: "["),
      let end = line[start...].firstIndex(of: "]")
    else {
      return nil
    }
    return String(line[line.index(after: start)..<end])
  }
}
