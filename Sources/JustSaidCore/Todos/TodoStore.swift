import Foundation

public struct TodoEditable: Equatable, Sendable {
  public var title: String
  public var note: String
  public var assignee: TodoAssignee
  public var due: TodoDue
  public var priority: TodoPriority
  public var client: String?
  public var project: String?

  public init(
    title: String,
    note: String,
    assignee: TodoAssignee,
    due: TodoDue,
    priority: TodoPriority,
    client: String?,
    project: String?
  ) {
    self.title = title
    self.note = note
    self.assignee = assignee
    self.due = due
    self.priority = priority
    self.client = client
    self.project = project
  }
}

public struct TodoDraft: Equatable, Sendable {
  public var title: String
  public var note: String
  public var assignee: TodoAssignee
  public var due: TodoDue
  public var priority: TodoPriority
  public var client: String?
  public var project: String?
  public var status: TodoStatus
  public var completionTimeUnknown: Bool
  public var meetingID: UUID?
  public var candidateID: UUID?
  public var source: TodoSource?
  public var expectedMinutesFingerprint: String?
  public var legacyKey: String?

  public init(
    title: String,
    note: String = "",
    assignee: TodoAssignee = .pending,
    due: TodoDue = .pending,
    priority: TodoPriority = .normal,
    client: String? = nil,
    project: String? = nil,
    status: TodoStatus = .open,
    completionTimeUnknown: Bool = false,
    meetingID: UUID? = nil,
    candidateID: UUID? = nil,
    source: TodoSource? = nil,
    expectedMinutesFingerprint: String? = nil,
    legacyKey: String? = nil
  ) {
    self.title = title
    self.note = note
    self.assignee = assignee
    self.due = due
    self.priority = priority
    self.client = client
    self.project = project
    self.status = status
    self.completionTimeUnknown = completionTimeUnknown
    self.meetingID = meetingID
    self.candidateID = candidateID
    self.source = source
    self.expectedMinutesFingerprint = expectedMinutesFingerprint
    self.legacyKey = legacyKey
  }
}

public struct TodoAddResult: Equatable, Sendable {
  public var snapshot: TodoSnapshot
  public var todoIDs: [UUID]

  public init(snapshot: TodoSnapshot, todoIDs: [UUID]) {
    self.snapshot = snapshot
    self.todoIDs = todoIDs
  }
}

private final class TodoStoreLockRegistry: @unchecked Sendable {
  static let shared = TodoStoreLockRegistry()

  // Safety invariant: `locks` is lock-protected by `registryLock`，只在锁内读写；交出去的锁自己负责文件事务。
  private let registryLock = NSLock()
  private var locks: [String: NSRecursiveLock] = [:]

  func lock(for fileURL: URL) -> NSRecursiveLock {
    let key = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    registryLock.lock()
    defer { registryLock.unlock() }
    if let existing = locks[key] { return existing }
    let created = NSRecursiveLock()
    locks[key] = created
    return created
  }
}

/// Safety invariant: 磁盘事务与 `readFailure` 都 serialized by 同一路径共用的 `fileLock`
/// （`TodoStoreLockRegistry` 发放）；其余属性在初始化后不可变。
public final class TodoStore: @unchecked Sendable {
  public let fileURL: URL

  private let fileManager: FileManager
  private let fileLock: NSRecursiveLock
  private var readFailure: TodoStoreError?

  public init(
    fileURL: URL = TodoStore.defaultFileURL(),
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    self.fileLock = TodoStoreLockRegistry.shared.lock(for: fileURL)
  }

  public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
    DictionaryStore.defaultFileURL(fileManager: fileManager)
      .deletingLastPathComponent()
      .appendingPathComponent("todos", isDirectory: true)
      .appendingPathComponent("state.json")
  }

  public func load() throws -> TodoSnapshot {
    try synchronized {
      // 只有显式重新读取成功后，才允许失败态恢复写入。
      readFailure = nil
      return try loadAssumingLock()
    }
  }

  public func commit(
    expectedRevision: Int,
    _ change: (inout TodoState) throws -> Void
  ) throws -> TodoSnapshot {
    try synchronized {
      try commitAssumingLock(expectedRevision: expectedRevision, change)
    }
  }

  /// 整批一次提交。同一条候选再提交一次，返回原来的待办，不另建。空数组不写文件。
  public func add(_ drafts: [TodoDraft], expectedRevision: Int, now: Date) throws -> TodoAddResult {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      if drafts.isEmpty {
        return TodoAddResult(snapshot: current, todoIDs: [])
      }
      if Self.entirelyIdempotent(current.state, drafts) {
        return TodoAddResult(
          snapshot: current,
          todoIDs: drafts.map { Self.existingTodoID(current.state, $0)! }
        )
      }
      var todoIDs: [UUID] = []
      let snapshot = try commitAssumingLock(expectedRevision: expectedRevision) { state in
        for draft in drafts {
          todoIDs.append(try Self.apply(draft, to: &state, now: now))
        }
      }
      return TodoAddResult(snapshot: snapshot, todoIDs: todoIDs)
    }
  }

  /// 明确的重新加入入口。普通 add 永不复活墓碑；重加保留历史墓碑关联并创建新 UUID。
  public func readd(_ draft: TodoDraft, expectedRevision: Int, now: Date) throws -> TodoAddResult {
    try synchronized {
      var todoID: UUID?
      let snapshot = try commitAssumingLock(expectedRevision: expectedRevision) { state in
        let ids = Self.referencedTodoIDs(state, draft)
        guard !ids.isEmpty, ids.allSatisfy({ state.tombstones.contains($0) }) else {
          throw TodoStoreError.invalid("只有已永久删除的待办可以重新加入")
        }
        todoID = try Self.apply(draft, to: &state, now: now, readding: true)
      }
      return TodoAddResult(snapshot: snapshot, todoIDs: todoID.map { [$0] } ?? [])
    }
  }

  /// 调用方确认后执行。锁内按相同 revision 重选回收箱，整批原子删除，活动项一字不动。
  public func emptyRecycleBin(expectedRevision: Int) throws -> TodoSnapshot {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      guard current.state.todos.contains(where: { $0.removedAt != nil }) else { return current }
      return try commitAssumingLock(expectedRevision: expectedRevision) { state in
        let removed = state.todos.filter { $0.removedAt != nil }.map(\.id)
        state.tombstones.formUnion(removed)
        state.todos.removeAll { $0.removedAt != nil }
      }
    }
  }

  public func linkCandidate(
    meetingID: UUID,
    candidateID: UUID,
    todoID: UUID,
    variant: CandidateVariant,
    source: TodoSource,
    expectedRevision: Int,
    expectedMinutesFingerprint: String?,
    now: Date
  ) throws -> TodoSnapshot {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      guard current.state.todos.contains(where: { $0.id == todoID }) else {
        throw TodoStoreError.missingTodo(todoID)
      }
      if Self.linkIsNoOp(current.state, meetingID: meetingID, candidateID: candidateID, todoID: todoID, variant: variant),
        Self.fingerprintMatches(current.state, meetingID: meetingID, expected: expectedMinutesFingerprint)
      {
        return current
      }
      return try commitAssumingLock(expectedRevision: expectedRevision) { state in
        try Self.requireFingerprint(state, meetingID: meetingID, expected: expectedMinutesFingerprint)
        guard let todoIndex = state.todos.firstIndex(where: { $0.id == todoID }) else {
          throw TodoStoreError.missingTodo(todoID)
        }
        guard var ledger = state.ledger(for: meetingID),
          let candidateIndex = ledger.candidates.firstIndex(where: { $0.id == candidateID })
        else { throw TodoStoreError.missingCandidate(candidateID) }
        var record = ledger.candidates[candidateIndex]
        if !record.variants.contains(where: { TodoCandidateSignature.strict($0) == TodoCandidateSignature.strict(variant) }) {
          record.variants.append(variant)
        }
        var ids = record.disposition.todoIDs
        if !ids.contains(todoID) { ids.append(todoID) }
        record.disposition = .added(todoIDs: ids)
        record.decidedAt = record.decidedAt ?? now
        ledger.candidates[candidateIndex] = record
        state.setLedger(ledger, for: meetingID)
        var source = source
        source.meetingID = meetingID
        source.candidateID = candidateID
        source.addedAt = now
        if !state.todos[todoIndex].sources.contains(where: { $0.candidateID == candidateID && $0.meetingID == meetingID }) {
          state.todos[todoIndex].sources.append(source)
        }
        state.todos[todoIndex].updatedAt = now
      }
    }
  }

  public func ignoreCandidate(
    meetingID: UUID,
    candidateID: UUID,
    expectedRevision: Int,
    now: Date
  ) throws -> TodoSnapshot {
    try synchronized {
      try setDisposition(.ignored, meetingID: meetingID, candidateID: candidateID, expectedRevision: expectedRevision, now: now)
    }
  }

  public func unignoreCandidate(
    meetingID: UUID,
    candidateID: UUID,
    expectedRevision: Int
  ) throws -> TodoSnapshot {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      guard let record = current.state.ledger(for: meetingID)?.candidates.first(where: { $0.id == candidateID }) else {
        throw TodoStoreError.missingCandidate(candidateID)
      }
      guard case .ignored = record.disposition else {
        throw TodoStoreError.invalid("只有已忽略的候选可以恢复成未处理")
      }
      return try commitAssumingLock(expectedRevision: expectedRevision) { state in
        try Self.updateRecord(meetingID: meetingID, candidateID: candidateID, in: &state) { record in
          record.disposition = .pending
          record.decidedAt = nil
        }
      }
    }
  }

  public func undoAdd(
    meetingID: UUID,
    candidateID: UUID,
    expectedRevision: Int
  ) throws -> TodoSnapshot {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      guard
        let record = current.state.ledger(for: meetingID)?.candidates.first(where: {
          $0.id == candidateID
        })
      else {
        throw TodoStoreError.missingCandidate(candidateID)
      }
      let deletedIDs = record.todoIDs.filter { current.state.tombstones.contains($0) }
      let ids = record.todoIDs.filter { !current.state.tombstones.contains($0) }
      guard !ids.isEmpty else { throw TodoStoreError.invalid("这条候选还没有加入待办") }
      for id in ids {
        guard let todo = current.state.todos.first(where: { $0.id == id }) else {
          throw TodoStoreError.missingTodo(id)
        }
        let onlyThisSource =
          todo.sources.count == 1
          && todo.sources[0].candidateID == candidateID
          && todo.sources[0].meetingID == meetingID
        guard onlyThisSource && Self.untouchedSinceAdd(todo) else {
          throw TodoStoreError.needsConfirmation("这条待办已经改过或还有别的来源，不会连带回滚")
        }
      }
      return try commitAssumingLock(expectedRevision: expectedRevision) { state in
        let keys = state.todos.filter { ids.contains($0.id) }.flatMap(\.sources).compactMap(
          \.legacyKey)
        state.todos.removeAll { ids.contains($0.id) }
        try Self.updateRecord(meetingID: meetingID, candidateID: candidateID, in: &state) {
          record in
          record.disposition = deletedIDs.isEmpty ? .pending : .added(todoIDs: deletedIDs)
          if deletedIDs.isEmpty { record.decidedAt = nil }
        }
        if var ledger = state.ledger(for: meetingID) {
          for key in keys {
            ledger.legacyImported[key] = deletedIDs.last
          }
          state.setLedger(ledger, for: meetingID)
        }
      }
    }
  }

  public func updateTodo(
    _ id: UUID,
    expectedRevision: Int,
    now: Date,
    _ body: (inout TodoEditable) -> Void
  ) throws -> TodoSnapshot {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      guard let existing = current.state.todos.first(where: { $0.id == id }) else {
        throw TodoStoreError.missingTodo(id)
      }
      var editable = Self.editable(existing)
      body(&editable)
      let cleaned = try Self.cleaned(editable)
      guard cleaned != Self.editable(existing) else { return current }
      return try commitAssumingLock(expectedRevision: expectedRevision) { state in
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
          throw TodoStoreError.missingTodo(id)
        }
        state.todos[index].title = cleaned.title
        state.todos[index].note = cleaned.note
        state.todos[index].assignee = cleaned.assignee
        state.todos[index].due = cleaned.due
        state.todos[index].priority = cleaned.priority
        state.todos[index].client = cleaned.client
        state.todos[index].project = cleaned.project
        state.todos[index].updatedAt = now
      }
    }
  }

  public func setStatus(
    _ id: UUID,
    status: TodoStatus,
    expectedRevision: Int,
    now: Date
  ) throws -> TodoSnapshot {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      guard let existing = current.state.todos.first(where: { $0.id == id }) else {
        throw TodoStoreError.missingTodo(id)
      }
      if existing.removedAt != nil {
        throw TodoStoreError.invalid("已移除的待办要先恢复")
      }
      // 已经是目标状态就不动，包括「已完成且完成时间未知」的旧勾选。不能用这次的时间冒充完成日。
      if existing.status == status {
        return current
      }
      return try commitAssumingLock(expectedRevision: expectedRevision) { state in
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
          throw TodoStoreError.missingTodo(id)
        }
        if status == .done {
          state.todos[index].status = .done
          state.todos[index].completedAt = now
          state.todos[index].completionTimeUnknown = false
        } else {
          state.todos[index].status = .open
          state.todos[index].completedAt = nil
          state.todos[index].completionTimeUnknown = false
          if state.todos[index].pinnedAt != nil {
            let others = state.todos.filter {
              $0.id != id && $0.status == .open && $0.removedAt == nil && $0.pinnedAt != nil
            }
            if others.count >= 3 {
              state.todos[index].pinnedAt = nil
            }
          }
        }
        state.todos[index].updatedAt = now
      }
    }
  }

  public func setPinned(
    _ id: UUID,
    pinned: Bool,
    expectedRevision: Int,
    now: Date
  ) throws -> TodoSnapshot {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      guard let existing = current.state.todos.first(where: { $0.id == id }) else {
        throw TodoStoreError.missingTodo(id)
      }
      if pinned == (existing.pinnedAt != nil) { return current }
      if pinned {
        guard existing.status == .open, existing.removedAt == nil else {
          throw TodoStoreError.invalid("只能钉住未完成且未移除的待办")
        }
        let existingPins = current.state.todos.filter {
          $0.status == .open && $0.removedAt == nil && $0.pinnedAt != nil
        }
        if existingPins.count >= 3 {
          throw TodoStoreError.pinLimit(existing: existingPins.map(\.id))
        }
      }
      return try commitAssumingLock(expectedRevision: expectedRevision) { state in
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
          throw TodoStoreError.missingTodo(id)
        }
        state.todos[index].pinnedAt = pinned ? now : nil
        state.todos[index].updatedAt = now
      }
    }
  }

  public func setRemoved(
    _ id: UUID,
    removed: Bool,
    expectedRevision: Int,
    now: Date
  ) throws -> TodoSnapshot {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      guard current.state.todos.contains(where: { $0.id == id }) else {
        throw TodoStoreError.missingTodo(id)
      }
      if removed == (current.state.todos.first { $0.id == id }?.removedAt != nil) {
        return current
      }
      return try commitAssumingLock(expectedRevision: expectedRevision) { state in
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
          throw TodoStoreError.missingTodo(id)
        }
        if removed {
          state.todos[index].removedAt = now
        } else {
          state.todos[index].removedAt = nil
          if state.todos[index].status == .open, state.todos[index].pinnedAt != nil {
            let others = state.todos.filter {
              $0.id != id && $0.status == .open && $0.removedAt == nil && $0.pinnedAt != nil
            }
            if others.count >= 3 {
              state.todos[index].pinnedAt = nil
            }
          }
        }
        state.todos[index].updatedAt = now
      }
    }
  }

  /// 只替换这场会议的候选台账。待办正文、期限、负责人和完成状态保持不动。
  public func applyReconciliation(
    meetingID: UUID,
    reconciliation: TodoReconciliation,
    expectedRevision: Int
  ) throws -> TodoSnapshot {
    try synchronized {
      let current = try loadAssumingLock()
      guard current.state.revision == expectedRevision else {
        throw TodoStoreError.conflict(current: current)
      }
      var ledger = reconciliation.ledger
      let existing = current.state.ledger(for: meetingID) ?? MeetingCandidateLedger()
      for (key, id) in existing.legacyImported where ledger.legacyImported[key] == nil {
        ledger.legacyImported[key] = id
      }
      if current.state.ledger(for: meetingID) == ledger {
        return current
      }
      return try commitAssumingLock(expectedRevision: expectedRevision) { state in
        for record in ledger.candidates {
          for id in record.disposition.todoIDs
          where !state.todos.contains(where: { $0.id == id }) && !state.tombstones.contains(id) {
            throw TodoStoreError.missingTodo(id)
          }
        }
        state.setLedger(ledger, for: meetingID)
      }
    }
  }

  private func loadAssumingLock() throws -> TodoSnapshot {
    if let readFailure { throw readFailure }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch CocoaError.fileReadNoSuchFile {
      return TodoSnapshot(state: .empty, fileURL: fileURL)
    } catch {
      let failure = TodoStoreError.unreadable(url: fileURL, reason: "无法读取待办文件")
      readFailure = failure
      throw failure
    }
    do {
      var state = try decode(data)
      if state.schemaVersion == 1 {
        state.schemaVersion = TodoSchema.current
        let encoded = try Self.encode(state)
        // 不覆盖备份，且必须在原子替换之前保全原字节；失败时不进入可写状态。
        let backup = fileURL.deletingLastPathComponent()
          .appendingPathComponent("\(fileURL.lastPathComponent).v1-\(UUID().uuidString).backup")
        do {
          try data.write(to: backup, options: .withoutOverwriting)
          try write(encoded)
        } catch {
          throw TodoStoreError.unreadable(url: fileURL, reason: "待办升级未完成，原文件已保留；请检查备份和写入权限后重新读取")
        }
      }
      return TodoSnapshot(state: state, fileURL: fileURL)
    } catch let error as TodoStoreError {
      readFailure = error
      throw error
    }
  }

  private func commitAssumingLock(
    expectedRevision: Int,
    _ change: (inout TodoState) throws -> Void
  ) throws -> TodoSnapshot {
    let current = try loadAssumingLock()
    guard current.state.revision == expectedRevision else {
      throw TodoStoreError.conflict(current: current)
    }
    var next = current.state
    try change(&next)
    next.schemaVersion = TodoSchema.current
    next.revision = current.state.revision + 1
    try Self.validate(next)
    let encoded = try Self.encode(next)
    // 读回刚编码的字节再返回，这样调用方拿到的快照和磁盘一致（日期会被 ISO8601 收到整秒）。
    let persisted = try decode(encoded)
    try write(encoded)
    return TodoSnapshot(state: persisted, fileURL: fileURL)
  }

  private func decode(_ data: Data) throws -> TodoState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    struct Header: Decodable { var schemaVersion: Int }
    guard let header = try? decoder.decode(Header.self, from: data) else {
      throw TodoStoreError.unreadable(url: fileURL, reason: "无法解析待办文件")
    }
    guard (1...TodoSchema.current).contains(header.schemaVersion) else {
      let reason =
        header.schemaVersion > TodoSchema.current
        ? "待办文件版本比当前应用新，不能降级写回"
        : "待办文件版本无法识别，不能当作空表"
      throw TodoStoreError.unreadable(url: fileURL, reason: reason)
    }
    let state: TodoState
    do {
      state = try decoder.decode(TodoState.self, from: data)
    } catch {
      throw TodoStoreError.unreadable(url: fileURL, reason: "无法解析待办文件")
    }
    let canonical = try canonicalMeetings(state)
    do {
      try Self.validate(canonical)
    } catch {
      throw TodoStoreError.unreadable(url: fileURL, reason: "待办文件内容无效，原文件已保留")
    }
    return canonical
  }

  /// 键统一成 `UUID.uuidString`。大小写不同的同一 UUID 不能变成两条台账。
  private func canonicalMeetings(_ state: TodoState) throws -> TodoState {
    var copy = state
    var meetings: [String: MeetingCandidateLedger] = [:]
    meetings.reserveCapacity(state.meetings.count)
    for (key, ledger) in state.meetings {
      guard let id = UUID(uuidString: key) else {
        throw TodoStoreError.unreadable(url: fileURL, reason: "无法解析待办文件")
      }
      let canonical = id.uuidString
      if meetings[canonical] != nil {
        throw TodoStoreError.unreadable(url: fileURL, reason: "无法解析待办文件")
      }
      meetings[canonical] = ledger
    }
    copy.meetings = meetings
    return copy
  }

  /// 待办文件的字节形态只有这一处定义,验证夹具也用它,免得夹具写出 store 读不了的文件。
  /// 不经 `StructuredArtifactCodec`:待办正文是用户自己打的字,原样存、原样读。
  public static func encode(_ state: TodoState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(state)
  }

  private func write(_ data: Data) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
  }

  private func setDisposition(
    _ disposition: CandidateDisposition,
    meetingID: UUID,
    candidateID: UUID,
    expectedRevision: Int,
    now: Date
  ) throws -> TodoSnapshot {
    let current = try loadAssumingLock()
    guard current.state.revision == expectedRevision else {
      throw TodoStoreError.conflict(current: current)
    }
    guard let record = current.state.ledger(for: meetingID)?.candidates.first(where: { $0.id == candidateID }) else {
      throw TodoStoreError.missingCandidate(candidateID)
    }
    if case .added = record.disposition, case .ignored = disposition {
      throw TodoStoreError.invalid("已经加入的候选要先撤销关联，不能直接忽略")
    }
    if record.disposition == disposition {
      return current
    }
    return try commitAssumingLock(expectedRevision: expectedRevision) { state in
      try Self.updateRecord(meetingID: meetingID, candidateID: candidateID, in: &state) { record in
        record.disposition = disposition
        record.decidedAt = now
      }
    }
  }

  private func synchronized<T>(_ work: () throws -> T) rethrows -> T {
    fileLock.lock()
    defer { fileLock.unlock() }
    return try work()
  }

  private static func apply(
    _ draft: TodoDraft, to state: inout TodoState, now: Date, readding: Bool = false
  ) throws -> UUID {
    if let existing = existingTodoID(state, draft) { return existing }
    if !readding, referencedTodoIDs(state, draft).contains(where: { state.tombstones.contains($0) })
    {
      throw TodoStoreError.needsConfirmation("待办已永久删除，请明确选择重新加入")
    }
    let meetingID = draft.meetingID ?? draft.source?.meetingID
    if let meetingID, let candidateID = draft.candidateID,
      state.ledger(for: meetingID)?.candidates.contains(where: { $0.id == candidateID }) != true
    {
      throw TodoStoreError.missingCandidate(candidateID)
    }
    try requireFingerprint(state, meetingID: meetingID, expected: draft.expectedMinutesFingerprint)
    let cleaned = try cleaned(editable(draft))
    let completionUnknown = draft.completionTimeUnknown && draft.status == .done
    let todo = TodoItem(
      title: cleaned.title,
      note: cleaned.note,
      assignee: cleaned.assignee,
      due: cleaned.due,
      priority: cleaned.priority,
      client: cleaned.client,
      project: cleaned.project,
      status: draft.status,
      createdAt: now,
      updatedAt: now,
      completedAt: draft.status == .done && !completionUnknown ? now : nil,
      completionTimeUnknown: completionUnknown,
      sources: draftedSources(draft, meetingID: meetingID, now: now)
    )
    state.todos.append(todo)
    if let meetingID {
      try markAdded(
        meetingID: meetingID,
        candidateID: draft.candidateID,
        legacyKey: draft.legacyKey,
        todoID: todo.id,
        now: now,
        state: &state
      )
    }
    return todo.id
  }

  private static func draftedSources(_ draft: TodoDraft, meetingID: UUID?, now: Date) -> [TodoSource] {
    guard var source = draft.source else { return [] }
    if let meetingID { source.meetingID = meetingID }
    source.candidateID = draft.candidateID ?? source.candidateID
    source.legacyKey = draft.legacyKey ?? source.legacyKey
    source.addedAt = now
    return [source]
  }

  private static func markAdded(
    meetingID: UUID,
    candidateID: UUID?,
    legacyKey: String?,
    todoID: UUID,
    now: Date,
    state: inout TodoState
  ) throws {
    var ledger = state.ledger(for: meetingID) ?? MeetingCandidateLedger()
    if let candidateID {
      guard let index = ledger.candidates.firstIndex(where: { $0.id == candidateID }) else {
        throw TodoStoreError.missingCandidate(candidateID)
      }
      var record = ledger.candidates[index]
      var ids = record.todoIDs
      if !ids.contains(todoID) { ids.append(todoID) }
      record.disposition = .added(todoIDs: ids)
      record.decidedAt = record.decidedAt ?? now
      ledger.candidates[index] = record
    }
    if let legacyKey {
      ledger.legacyImported[legacyKey] = todoID
    }
    state.setLedger(ledger, for: meetingID)
  }

  private static func existingTodoID(_ state: TodoState, _ draft: TodoDraft) -> UUID? {
    referencedTodoIDs(state, draft).first { id in state.todos.contains { $0.id == id } }
  }

  private static func referencedTodoIDs(_ state: TodoState, _ draft: TodoDraft) -> [UUID] {
    let meetingID = draft.meetingID ?? draft.source?.meetingID
    guard let meetingID, let ledger = state.ledger(for: meetingID) else { return [] }
    var ids: [UUID] = []
    if let key = draft.legacyKey, let id = ledger.legacyImported[key] {
      ids.append(id)
    }
    if let candidateID = draft.candidateID,
      let record = ledger.candidates.first(where: { $0.id == candidateID })
    {
      ids.append(contentsOf: record.todoIDs)
    }
    return ids
  }

  private static func entirelyIdempotent(_ state: TodoState, _ drafts: [TodoDraft]) -> Bool {
    !drafts.isEmpty && drafts.allSatisfy { existingTodoID(state, $0) != nil }
  }

  private static func requireFingerprint(
    _ state: TodoState,
    meetingID: UUID?,
    expected: String?
  ) throws {
    guard let expected else { return }
    let actual = meetingID.flatMap { state.ledger(for: $0)?.lastFingerprint }
    guard actual == expected else {
      throw TodoStoreError.staleSource(expectedFingerprint: expected, actualFingerprint: actual)
    }
  }

  private static func fingerprintMatches(
    _ state: TodoState,
    meetingID: UUID,
    expected: String?
  ) -> Bool {
    guard let expected else { return true }
    return state.ledger(for: meetingID)?.lastFingerprint == expected
  }

  private static func linkIsNoOp(
    _ state: TodoState,
    meetingID: UUID,
    candidateID: UUID,
    todoID: UUID,
    variant: CandidateVariant
  ) -> Bool {
    guard let record = state.ledger(for: meetingID)?.candidates.first(where: { $0.id == candidateID }),
      record.todoIDs.contains(todoID),
      record.variants.contains(where: { TodoCandidateSignature.strict($0) == TodoCandidateSignature.strict(variant) }),
      state.todos.first(where: { $0.id == todoID })?.sources.contains(where: {
        $0.candidateID == candidateID && $0.meetingID == meetingID
      }) == true
    else { return false }
    return true
  }

  private static func updateRecord(
    meetingID: UUID,
    candidateID: UUID,
    in state: inout TodoState,
    _ body: (inout CandidateRecord) -> Void
  ) throws {
    guard var ledger = state.ledger(for: meetingID),
      let index = ledger.candidates.firstIndex(where: { $0.id == candidateID })
    else { throw TodoStoreError.missingCandidate(candidateID) }
    body(&ledger.candidates[index])
    state.setLedger(ledger, for: meetingID)
  }

  /// 自加入后没有被用户改过。普通加入一开始是未完成；旧勾选带入一开始是已完成且完成时间未知。
  private static func untouchedSinceAdd(_ todo: TodoItem) -> Bool {
    guard todo.updatedAt == todo.createdAt,
      todo.removedAt == nil,
      todo.pinnedAt == nil,
      todo.completedAt == nil
    else { return false }
    switch todo.status {
    case .open:
      return todo.completionTimeUnknown == false
    case .done:
      return todo.completionTimeUnknown
    }
  }

  private static func editable(_ item: TodoItem) -> TodoEditable {
    TodoEditable(
      title: item.title,
      note: item.note,
      assignee: item.assignee,
      due: item.due,
      priority: item.priority,
      client: item.client,
      project: item.project
    )
  }

  private static func editable(_ draft: TodoDraft) -> TodoEditable {
    TodoEditable(
      title: draft.title,
      note: draft.note,
      assignee: draft.assignee,
      due: draft.due,
      priority: draft.priority,
      client: draft.client,
      project: draft.project
    )
  }

  private static func cleaned(_ editable: TodoEditable) throws -> TodoEditable {
    let title = editable.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw TodoStoreError.invalid("事项不能为空") }
    let assignee: TodoAssignee
    switch editable.assignee {
    case .me:
      assignee = .me
    case .pending:
      assignee = .pending
    case .named(let name):
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw TodoStoreError.invalid("负责人姓名不能为空") }
      assignee = .named(trimmed)
    }
    if case .date(let day) = editable.due, !TodoCalendar.isValid(day) {
      throw TodoStoreError.invalid("截止日期不是有效的日历日")
    }
    return TodoEditable(
      title: title,
      note: editable.note.trimmingCharacters(in: .whitespacesAndNewlines),
      assignee: assignee,
      due: editable.due,
      priority: editable.priority,
      client: tag(editable.client),
      project: tag(editable.project)
    )
  }

  private static func tag(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func validate(_ state: TodoState) throws {
    guard (1...TodoSchema.current).contains(state.schemaVersion), state.revision >= 0 else {
      throw TodoStoreError.invalid("不能改写待办文件版本")
    }
    var seenTodos: Set<UUID> = []
    var openPins: [UUID] = []
    for todo in state.todos {
      guard seenTodos.insert(todo.id).inserted else {
        throw TodoStoreError.invalid("待办编号重复")
      }
      if todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw TodoStoreError.invalid("事项不能为空")
      }
      if case .named(let name) = todo.assignee,
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw TodoStoreError.invalid("负责人姓名不能为空")
      }
      if case .date(let day) = todo.due, !TodoCalendar.isValid(day) {
        throw TodoStoreError.invalid("截止日期不是有效的日历日")
      }
      if todo.status == .open, todo.removedAt == nil, todo.pinnedAt != nil {
        openPins.append(todo.id)
      }
    }
    if openPins.count > 3 {
      throw TodoStoreError.pinLimit(existing: openPins)
    }
    guard seenTodos.isDisjoint(with: state.tombstones) else {
      throw TodoStoreError.invalid("活动待办与永久删除编号重叠")
    }
    for ledger in state.meetings.values {
      var seenCandidates: Set<UUID> = []
      for record in ledger.candidates {
        guard seenCandidates.insert(record.id).inserted else {
          throw TodoStoreError.invalid("候选编号重复")
        }
        for id in record.todoIDs where !seenTodos.contains(id) && !state.tombstones.contains(id) {
          throw TodoStoreError.missingTodo(id)
        }
      }
      for id in ledger.legacyImported.values
      where !seenTodos.contains(id) && !state.tombstones.contains(id) {
        throw TodoStoreError.missingTodo(id)
      }
    }
  }
}
