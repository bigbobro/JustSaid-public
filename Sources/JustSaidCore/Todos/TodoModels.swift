import Foundation

/// 待办文件当前只认识这一版。比它新，或根本对不上，都按读不出处理，不能降级写回。
public enum TodoSchema {
  public static let current = 2
}

/// 日历日。只存 `yyyy-MM-dd` 和 IANA 时区名，不存瞬时，避免换时区把一天挪到前一天。
public struct TodoDay: Codable, Equatable, Hashable, Sendable {
  public var day: String
  public var timeZoneIdentifier: String

  public init(day: String, timeZoneIdentifier: String) {
    self.day = day
    self.timeZoneIdentifier = timeZoneIdentifier
  }

  private enum CodingKeys: String, CodingKey {
    case day
    case timeZoneIdentifier = "timeZone"
  }
}

public enum TodoAssignee: Equatable, Sendable {
  case me
  case named(String)
  case pending
}

extension TodoAssignee: Codable {
  private enum Kind: String, Codable {
    case me
    case named
    case pending
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case name
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .me:
      self = .me
    case .pending:
      self = .pending
    case .named:
      self = .named(try container.decode(String.self, forKey: .name))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .me:
      try container.encode(Kind.me, forKey: .kind)
    case .pending:
      try container.encode(Kind.pending, forKey: .kind)
    case .named(let name):
      try container.encode(Kind.named, forKey: .kind)
      try container.encode(name, forKey: .name)
    }
  }
}

public enum TodoDue: Equatable, Sendable {
  case date(TodoDay)
  case none
  case pending
}

extension TodoDue: Codable {
  private enum Kind: String, Codable {
    case date
    case none
    case pending
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case day
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .none:
      self = .none
    case .pending:
      self = .pending
    case .date:
      self = .date(try container.decode(TodoDay.self, forKey: .day))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .none:
      try container.encode(Kind.none, forKey: .kind)
    case .pending:
      try container.encode(Kind.pending, forKey: .kind)
    case .date(let day):
      try container.encode(Kind.date, forKey: .kind)
      try container.encode(day, forKey: .day)
    }
  }
}

public enum TodoPriority: String, Codable, Equatable, Sendable {
  case high
  case normal
  case low
}

public enum TodoStatus: String, Codable, Equatable, Sendable {
  case open
  case done
}

/// 加入当时的参照日和时区。之后改会议日期不会倒推已保存的期限。
public struct TodoDueBasis: Codable, Equatable, Sendable {
  public var referenceDay: String
  public var timeZoneIdentifier: String

  public init(referenceDay: String, timeZoneIdentifier: String) {
    self.referenceDay = referenceDay
    self.timeZoneIdentifier = timeZoneIdentifier
  }

  private enum CodingKeys: String, CodingKey {
    case referenceDay
    case timeZoneIdentifier = "timeZone"
  }
}

/// 来源快照。后来改会名、标签或纪要，都不改这里已经记下的原文。
public struct TodoSource: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var meetingID: UUID
  public var directoryHint: String?
  public var meetingTitle: String?
  public var meetingStartedAt: Date?
  public var client: String?
  public var project: String?
  public var candidateID: UUID?
  public var candidateText: String?
  public var ownerText: String?
  public var deadlineText: String?
  public var evidence: String?
  public var anchor: String?
  public var minutesFingerprint: String?
  public var dueBasis: TodoDueBasis?
  public var legacyKey: String?
  public var addedAt: Date

  public init(
    id: UUID = UUID(),
    meetingID: UUID,
    directoryHint: String? = nil,
    meetingTitle: String? = nil,
    meetingStartedAt: Date? = nil,
    client: String? = nil,
    project: String? = nil,
    candidateID: UUID? = nil,
    candidateText: String? = nil,
    ownerText: String? = nil,
    deadlineText: String? = nil,
    evidence: String? = nil,
    anchor: String? = nil,
    minutesFingerprint: String? = nil,
    dueBasis: TodoDueBasis? = nil,
    legacyKey: String? = nil,
    addedAt: Date
  ) {
    self.id = id
    self.meetingID = meetingID
    self.directoryHint = directoryHint
    self.meetingTitle = meetingTitle
    self.meetingStartedAt = meetingStartedAt
    self.client = client
    self.project = project
    self.candidateID = candidateID
    self.candidateText = candidateText
    self.ownerText = ownerText
    self.deadlineText = deadlineText
    self.evidence = evidence
    self.anchor = anchor
    self.minutesFingerprint = minutesFingerprint
    self.dueBasis = dueBasis
    self.legacyKey = legacyKey
    self.addedAt = addedAt
  }
}

public struct TodoItem: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var title: String
  public var note: String
  public var assignee: TodoAssignee
  public var due: TodoDue
  public var priority: TodoPriority
  public var client: String?
  public var project: String?
  public var status: TodoStatus
  public var createdAt: Date
  public var updatedAt: Date
  public var completedAt: Date?
  public var completionTimeUnknown: Bool
  public var pinnedAt: Date?
  public var removedAt: Date?
  public var sources: [TodoSource]

  public init(
    id: UUID = UUID(),
    title: String,
    note: String = "",
    assignee: TodoAssignee = .pending,
    due: TodoDue = .pending,
    priority: TodoPriority = .normal,
    client: String? = nil,
    project: String? = nil,
    status: TodoStatus = .open,
    createdAt: Date,
    updatedAt: Date,
    completedAt: Date? = nil,
    completionTimeUnknown: Bool = false,
    pinnedAt: Date? = nil,
    removedAt: Date? = nil,
    sources: [TodoSource] = []
  ) {
    self.id = id
    self.title = title
    self.note = note
    self.assignee = assignee
    self.due = due
    self.priority = priority
    self.client = client
    self.project = project
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.completedAt = completedAt
    self.completionTimeUnknown = completionTimeUnknown
    self.pinnedAt = pinnedAt
    self.removedAt = removedAt
    self.sources = sources
  }
}

/// 用户确认过、属于同一条候选的一种说法。严格签名用这些字段，不用待办标题。
public struct CandidateVariant: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var text: String
  public var owner: String?
  public var ownership: SummaryActionOwnership
  public var deadline: String?
  public var kind: SummaryActionKind
  public var anchor: String?
  public var evidence: String?
  public var updatesSummary: String
  public var fingerprint: String

  public init(
    id: UUID = UUID(),
    text: String,
    owner: String? = nil,
    ownership: SummaryActionOwnership = .unknown,
    deadline: String? = nil,
    kind: SummaryActionKind = .todo,
    anchor: String? = nil,
    evidence: String? = nil,
    updatesSummary: String = "∅",
    fingerprint: String
  ) {
    self.id = id
    self.text = text
    self.owner = owner
    self.ownership = ownership
    self.deadline = deadline
    self.kind = kind
    self.anchor = anchor
    self.evidence = evidence
    self.updatesSummary = updatesSummary
    self.fingerprint = fingerprint
  }
}

public enum CandidateDisposition: Equatable, Sendable {
  case pending
  case added(todoIDs: [UUID])
  case ignored

  public var todoIDs: [UUID] {
    if case .added(let ids) = self { return ids }
    return []
  }
}

extension CandidateDisposition: Codable {
  private enum Kind: String, Codable {
    case pending
    case added
    case ignored
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case todoIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .pending:
      self = .pending
    case .ignored:
      self = .ignored
    case .added:
      self = .added(todoIDs: try container.decode([UUID].self, forKey: .todoIDs))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pending:
      try container.encode(Kind.pending, forKey: .kind)
    case .ignored:
      try container.encode(Kind.ignored, forKey: .kind)
    case .added(let todoIDs):
      try container.encode(Kind.added, forKey: .kind)
      try container.encode(todoIDs, forKey: .todoIDs)
    }
  }
}

public struct CandidateRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var variants: [CandidateVariant]
  /// 用户确认过的关联对象。比对可以记下，但不能据此继承处理状态。
  public var suspectedCandidateIDs: [UUID]
  public var disposition: CandidateDisposition
  public var decidedAt: Date?
  public var firstSeenFingerprint: String
  public var lastSeenFingerprint: String
  /// 最近一份成功读到的快照里的位置。不在这份快照里则为空。
  public var snapshotIndex: Int?

  public var todoIDs: [UUID] { disposition.todoIDs }

  public init(
    id: UUID,
    variants: [CandidateVariant],
    suspectedCandidateIDs: [UUID] = [],
    disposition: CandidateDisposition,
    decidedAt: Date? = nil,
    firstSeenFingerprint: String,
    lastSeenFingerprint: String,
    snapshotIndex: Int? = nil
  ) {
    self.id = id
    self.variants = variants
    self.suspectedCandidateIDs = suspectedCandidateIDs
    self.disposition = disposition
    self.decidedAt = decidedAt
    self.firstSeenFingerprint = firstSeenFingerprint
    self.lastSeenFingerprint = lastSeenFingerprint
    self.snapshotIndex = snapshotIndex
  }
}

public struct MeetingCandidateLedger: Codable, Equatable, Sendable {
  public var lastFingerprint: String?
  public var candidates: [CandidateRecord]
  public var legacyImported: [String: UUID]

  public init(
    lastFingerprint: String? = nil,
    candidates: [CandidateRecord] = [],
    legacyImported: [String: UUID] = [:]
  ) {
    self.lastFingerprint = lastFingerprint
    self.candidates = candidates
    self.legacyImported = legacyImported
  }
}

public struct TodoState: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var revision: Int
  public var todos: [TodoItem]
  /// 永久删除只留下 UUID；不能保存标题、来源或删除时间。
  public var tombstones: Set<UUID>
  /// 键是会议 UUID 的字符串（`UUID.uuidString`，大写）。这样编码成对象，`sortedKeys` 后字节稳定。
  public var meetings: [String: MeetingCandidateLedger]

  public init(
    schemaVersion: Int = TodoSchema.current,
    revision: Int,
    todos: [TodoItem],
    meetings: [String: MeetingCandidateLedger],
    tombstones: Set<UUID> = []
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.todos = todos
    self.meetings = meetings
    self.tombstones = tombstones
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, revision, todos, tombstones, meetings
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    revision = try container.decode(Int.self, forKey: .revision)
    todos = try container.decode([TodoItem].self, forKey: .todos)
    meetings = try container.decode([String: MeetingCandidateLedger].self, forKey: .meetings)
    let ids =
      schemaVersion == 1
      ? try container.decodeIfPresent([UUID].self, forKey: .tombstones) ?? []
      : try container.decode([UUID].self, forKey: .tombstones)
    guard Set(ids).count == ids.count, schemaVersion != 1 || ids.isEmpty else {
      throw DecodingError.dataCorruptedError(
        forKey: .tombstones, in: container, debugDescription: "无效墓碑集合")
    }
    tombstones = Set(ids)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(revision, forKey: .revision)
    try container.encode(todos, forKey: .todos)
    try container.encode(meetings, forKey: .meetings)
    // v1 用于旧档迁移与回退验证，保留旧版确实写出的键集。
    if schemaVersion != 1 || !tombstones.isEmpty {
      try container.encode(tombstones.sorted { $0.uuidString < $1.uuidString }, forKey: .tombstones)
    }
  }

  public func isPermanentlyDeleted(_ disposition: CandidateDisposition) -> Bool {
    let ids = disposition.todoIDs
    return !ids.isEmpty && ids.allSatisfy { tombstones.contains($0) }
  }

  public static var empty: TodoState {
    TodoState(schemaVersion: TodoSchema.current, revision: 0, todos: [], meetings: [:])
  }

  public func ledger(for meetingID: UUID) -> MeetingCandidateLedger? {
    meetings[meetingID.uuidString]
  }

  public mutating func setLedger(_ ledger: MeetingCandidateLedger?, for meetingID: UUID) {
    let key = meetingID.uuidString
    if let ledger {
      meetings[key] = ledger
    } else {
      meetings.removeValue(forKey: key)
    }
  }

  /// 仍按会议 UUID 取台账的调用方用这个。
  public var ledgersByMeetingID: [UUID: MeetingCandidateLedger] {
    var result: [UUID: MeetingCandidateLedger] = [:]
    result.reserveCapacity(meetings.count)
    for (key, ledger) in meetings {
      guard let id = UUID(uuidString: key) else { continue }
      result[id] = ledger
    }
    return result
  }
}

public struct TodoSnapshot: Equatable, Sendable {
  public var state: TodoState
  public var fileURL: URL

  public init(state: TodoState, fileURL: URL) {
    self.state = state
    self.fileURL = fileURL
  }
}

public enum TodoStoreError: LocalizedError, Equatable, Sendable {
  case conflict(current: TodoSnapshot)
  case unreadable(url: URL, reason: String)
  case staleSource(expectedFingerprint: String, actualFingerprint: String?)
  case invalid(String)
  case pinLimit(existing: [UUID])
  case needsConfirmation(String)
  case missingTodo(UUID)
  case missingCandidate(UUID)

  public var errorDescription: String? {
    switch self {
    case .conflict(let current):
      return "待办文件已被更新（修订 \(current.state.revision)），这次提交没有写入"
    case .unreadable(_, let reason):
      return reason
    case .staleSource:
      return "纪要已经更新，请先看过差异再加入"
    case .invalid(let reason):
      return reason
    case .pinLimit:
      return "未完成的钉住已经有 3 条，先取消一条再钉"
    case .needsConfirmation(let reason):
      return reason
    case .missingTodo:
      return "要关联的待办不在文件里"
    case .missingCandidate:
      return "这条候选不在会议台账里"
    }
  }
}
