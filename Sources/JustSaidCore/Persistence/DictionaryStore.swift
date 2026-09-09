import Foundation

public final class DictionaryStore: @unchecked Sendable {
  public let fileURL: URL

  private let fileManager: FileManager
  private let lock = NSLock()

  public init(
    fileURL: URL = DictionaryStore.defaultFileURL(),
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public static func defaultFileURL(
    fileManager: FileManager = .default
  ) -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("JustSaid", isDirectory: true)
      .appendingPathComponent("词典.txt")
  }

  /// 解析为主体条目(主体=称呼 语法;纯词行=术语/无别称主体)。
  public func loadEntries() throws -> [DictionaryEntry] {
    DictionaryEntry.parseAll(try load())
  }

  public func load() throws -> [String] {
    try synchronized {
      guard fileManager.fileExists(atPath: fileURL.path) else {
        return []
      }
      return Self.normalized(
        try String(contentsOf: fileURL, encoding: .utf8)
          .components(separatedBy: .newlines)
      )
    }
  }

  public func save(_ words: [String]) throws {
    try synchronized {
      let normalized = Self.normalized(words)
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let content = normalized.isEmpty ? "" : normalized.joined(separator: "\n") + "\n"
      try Data(content.utf8).write(to: fileURL, options: .atomic)
    }
  }

  private static func normalized(_ words: [String]) -> [String] {
    var seen: Set<String> = []
    return words.flatMap { $0.components(separatedBy: .newlines) }.compactMap { word in
      let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
        return nil
      }
      return trimmed
    }
  }

  private func synchronized<T>(_ work: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try work()
  }
}
