import Foundation
import JustSaidCore

/// App 自己删掉的会议 UUID。来源定位只在这份名单里才说「已删除」，
/// 其余找不到的目录仍是「来源暂不可用」。文件不存在就是空名单，不会顺手建目录。
/// Safety invariant: 存储属性全是 `let`；账本文件的读写都在 `lock` 内完成（lock-protected）。
public final class TodoDeletedMeetingLedger: @unchecked Sendable {
  public let fileURL: URL
  private let lock = NSLock()
  private let fileManager: FileManager

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
    TodoStore.defaultFileURL(fileManager: fileManager)
      .deletingLastPathComponent()
      .appendingPathComponent("deleted-meetings.json")
  }

  public func load() -> Set<UUID> {
    lock.lock()
    defer { lock.unlock() }
    return readAssumingLock()
  }

  public func record(_ id: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    var ids = readAssumingLock()
    guard ids.insert(id).inserted else { return }
    let payload = DeletedMeetingFile(ids: ids.map(\.uuidString).sorted())
    let data = try JSONEncoder.ledger.encode(payload)
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
  }

  private func readAssumingLock() -> Set<UUID> {
    guard fileManager.fileExists(atPath: fileURL.path),
      let data = try? Data(contentsOf: fileURL),
      let payload = try? JSONDecoder().decode(DeletedMeetingFile.self, from: data)
    else { return [] }
    return Set(payload.ids.compactMap(UUID.init(uuidString:)))
  }
}

private struct DeletedMeetingFile: Codable {
  var ids: [String]
}

extension JSONEncoder {
  fileprivate static let ledger: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()
}
