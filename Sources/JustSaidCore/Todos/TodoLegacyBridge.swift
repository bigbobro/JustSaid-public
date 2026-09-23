import Foundation

public struct TodoLegacyMatch: Equatable, Sendable {
  public var index: Int
  public var candidateID: UUID?
  public var item: SummaryActionItem

  public init(index: Int, candidateID: UUID?, item: SummaryActionItem) {
    self.index = index
    self.candidateID = candidateID
    self.item = item
  }
}

public struct TodoLegacyHit: Equatable, Sendable {
  public var key: String
  public var matches: [TodoLegacyMatch]
  public var importedTodoID: UUID?

  public var ambiguous: Bool { matches.count > 1 }
  public var missingFromCurrent: Bool { matches.isEmpty }

  public init(key: String, matches: [TodoLegacyMatch], importedTodoID: UUID?) {
    self.key = key
    self.matches = matches
    self.importedTodoID = importedTodoID
  }
}

public enum TodoLegacyBridge {
  /// 只读旧勾选。命中与否都不创建待办；同文多条标成无法区分，不替用户挑选。
  public static func hits(
    completedActionItems: [String]?,
    items: [SummaryActionItem],
    ledger: MeetingCandidateLedger
  ) -> [TodoLegacyHit] {
    guard let completedActionItems else { return [] }
    return completedActionItems.map { key in
      let matches = items.enumerated().compactMap { index, item -> TodoLegacyMatch? in
        guard item.completionKey == key else { return nil }
        let candidateID = ledger.candidates.first { $0.snapshotIndex == index }?.id
        return TodoLegacyMatch(index: index, candidateID: candidateID, item: item)
      }
      return TodoLegacyHit(
        key: key,
        matches: matches,
        importedTodoID: ledger.legacyImported[key]
      )
    }
  }
}

public enum TodoMeetingLocation: Equatable, Sendable {
  case present(URL)
  case deleted
  case unavailable
  case ambiguous([URL])
}

public enum TodoMeetingLocator {
  /// 按会议 UUID 找目录。路径只是线索；同一个 UUID 出现多次时不挑其中一个。
  public static func locate(
    meetingID: UUID,
    in directories: [URL],
    deletedMeetingIDs: Set<UUID> = [],
    fileManager: FileManager = .default
  ) -> TodoMeetingLocation {
    let matches = directories.filter { directory in
      identity(in: directory, fileManager: fileManager) == meetingID
    }.sorted { $0.path < $1.path }
    if matches.count > 1 { return .ambiguous(matches) }
    if let only = matches.first { return .present(only) }
    if deletedMeetingIDs.contains(meetingID) { return .deleted }
    return .unavailable
  }

  private static func identity(in directory: URL, fileManager: FileManager) -> UUID? {
    let url = directory.appendingPathComponent("meeting.json")
    guard fileManager.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = object["id"] as? String
    else { return nil }
    return UUID(uuidString: raw)
  }
}
