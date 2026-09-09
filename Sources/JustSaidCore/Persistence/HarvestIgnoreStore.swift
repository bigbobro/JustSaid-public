import Foundation

/// 收割箱忽略表(08-17 #4):被用户点「忽略」的词面集合,不再进收割箱重复打扰。
///
/// 与词典文件同目录(`~/JustSaid/dictionary-harvest-ignored.json`),模式抄
/// `DictionaryStore`(NSLock + 缺文件视为空表);落盘走 `StructuredArtifactCodec`
/// 统一文本边界——词面来自模型提取,属不可信输入。
/// 忽略只影响收割箱聚合呈现,不回写任何会议的 minutes.json。
public final class HarvestIgnoreStore: @unchecked Sendable {
  public let fileURL: URL

  private let fileManager: FileManager
  private let lock = NSLock()

  public init(
    fileURL: URL = HarvestIgnoreStore.defaultFileURL(),
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public static func defaultFileURL(
    fileManager: FileManager = .default
  ) -> URL {
    DictionaryStore.defaultFileURL(fileManager: fileManager)
      .deletingLastPathComponent()
      .appendingPathComponent("dictionary-harvest-ignored.json")
  }

  public func load() throws -> Set<String> {
    try synchronized {
      guard fileManager.fileExists(atPath: fileURL.path) else {
        return []
      }
      let data = try Data(contentsOf: fileURL)
      return Set(
        try StructuredArtifactCodec.decode([String].self, from: data)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
      )
    }
  }

  /// 追加一个忽略词面;已在表中为幂等成功。
  public func ignore(_ word: String) throws {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    try synchronized {
      var words: Set<String> = []
      if fileManager.fileExists(atPath: fileURL.path) {
        let data = try Data(contentsOf: fileURL)
        words = Set(try StructuredArtifactCodec.decode([String].self, from: data))
      }
      guard words.insert(trimmed).inserted else { return }
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoded = try StructuredArtifactCodec.encode(words.sorted())
      try encoded.write(to: fileURL, options: .atomic)
    }
  }

  private func synchronized<T>(_ work: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try work()
  }
}
