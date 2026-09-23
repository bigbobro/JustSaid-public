import Foundation
import JustSaidCore

public enum MeetingCandidateFold: String, Equatable, CaseIterable {
  case added
  case ignored
  case legacy
}

public enum MeetingCandidateSurface: Equatable {
  case meeting
  case clean
  case reconcile
  case receipt
}

public struct MeetingCandidateNotice: Equatable, Identifiable {
  public var id: String
  public var text: String

  public init(id: String, text: String) {
    self.id = id
    self.text = text
  }
}

public struct MeetingCandidateContext: Equatable {
  public var meetingID: UUID
  public var title: String
  public var startedAt: Date
  public var client: String?
  public var project: String?
  public var directoryHint: String?
  public var fingerprint: String
  public var referenceDay: String
  public var timeZoneIdentifier: String
  public var completedActionItems: [String]
}

public struct MeetingCandidateCleanLine: Equatable, Identifiable {
  public var id: UUID
  public var candidateID: UUID?
  public var legacyKey: String?
  public var draft: TodoEditorDraft
  public var sourceText: String
  public var ownerText: String?
  public var deadlineText: String?
  public var anchor: String?
  public var resolution: TodoDueResolution
  public var chosenDay: String?
  public var markCompleted: Bool
  public var missingContext: Bool
  public var removed = false
  public var confirmedAssignee: TodoAssignee?
  public var isReadding = false
}

public enum MeetingCandidateUndo: Equatable {
  case candidate(UUID)
  case legacyOnly(todoID: UUID, key: String, previousTodoID: UUID?)
}

public struct MeetingCandidateReceipt: Equatable {
  public var message: String
  public var steps: [MeetingCandidateUndo]
  public var canUndo: Bool
}

public struct MeetingCandidateLineVM: Equatable, Identifiable {
  public var id: UUID
  public var title: String
  public var owner: String
  public var deadline: String
  public var anchor: TranscriptAnchor?
  public var primaryTitle: String
  public var primaryIdentifier: String
  public var note: String?
  public var permanentlyDeleted = false
}

public struct MeetingLegacyLineVM: Equatable, Identifiable {
  public var id: Int
  public var title: String
  public var detail: String
  public var canImport: Bool
  public var permanentlyDeleted = false
}

public struct MeetingCandidateBoard: Equatable {
  public var notices: [MeetingCandidateNotice] = []
  public var pending: [MeetingCandidateLineVM] = []
  public var added: [MeetingCandidateLineVM] = []
  public var ignored: [MeetingCandidateLineVM] = []
  public var legacy: [MeetingLegacyLineVM] = []
  public var questions: [(id: UUID, text: String, anchor: TranscriptAnchor?)] = []
  public var selection: Set<UUID> = []
  public var expanded: Set<MeetingCandidateFold> = []
  public var error: String?

  public static func == (lhs: MeetingCandidateBoard, rhs: MeetingCandidateBoard) -> Bool {
    lhs.notices == rhs.notices && lhs.pending == rhs.pending && lhs.added == rhs.added
      && lhs.ignored == rhs.ignored && lhs.legacy == rhs.legacy && lhs.selection == rhs.selection
      && lhs.expanded == rhs.expanded && lhs.error == rhs.error
      && lhs.questions.map(\.id) == rhs.questions.map(\.id)
      && lhs.questions.map(\.text) == rhs.questions.map(\.text)
  }
}

extension TodoPageModel {
  public func selectCleanClient(_ value: String, lineID: UUID) {
    guard let line = cleanLines.first(where: { $0.id == lineID }) else { return }
    let pair = tagDirectory.selectingClient(value, project: line.draft.project)
    updateCleanLine(lineID) {
      $0.draft.client = pair.client
      $0.draft.project = pair.project
    }
    tagDirectory.remember(client: pair.client, project: pair.project)
  }

  public func selectCleanProject(_ value: String, lineID: UUID) {
    guard let line = cleanLines.first(where: { $0.id == lineID }) else { return }
    let pair = tagDirectory.selectingProject(value, client: line.draft.client)
    updateCleanLine(lineID) {
      $0.draft.client = pair.client
      $0.draft.project = pair.project
    }
    tagDirectory.remember(client: pair.client, project: pair.project)
  }

  /// 验证进程不得读写用户家里的待办文件。临时路径和正式 App 照常落盘。
  var persistsCandidateLedger: Bool {
    let standard = TodoStore.defaultFileURL().standardizedFileURL.resolvingSymlinksInPath().path
    let mine = store.fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    if mine != standard { return true }
    return ProcessInfo.processInfo.processName == "JustSaid"
  }

  public var cleanSaveEnabled: Bool {
    let active = cleanLines.filter { !$0.removed }
    return candidateWritable && !active.isEmpty && active.allSatisfy(lineCanSave)
  }

  public var cleanSaveTitle: String {
    if cleanRetry { return "重新保存" }
    let count = cleanLines.filter { !$0.removed }.count
    return count > 1 ? "加入 \(count) 条" : "加入待办"
  }

  public var candidateBoard: MeetingCandidateBoard {
    var board = MeetingCandidateBoard()
    board.notices = roundNotices
    board.selection = candidateSelection
    board.expanded = expandedFolds
    board.error = candidateActionError
    let legacyIDs = Set(legacyHits.flatMap { $0.matches.compactMap(\.candidateID) })
    for row in candidateRows {
      guard let line = lineVM(row) else { continue }
      switch row.disposition {
      case .pending:
        if row.snapshotIndex == nil {
          continue
        }
        if legacyIDs.contains(row.id) { continue }
        board.pending.append(line)
      case .added:
        board.added.append(line)
      case .ignored:
        board.ignored.append(line)
      }
    }
    board.legacy = legacyHits.enumerated().map { index, hit in
      MeetingLegacyLineVM(
        id: index,
        title: legacyTitle(hit),
        detail: legacyDetail(hit),
        canImport: canImport(hit),
        permanentlyDeleted: hit.importedTodoID.map {
          snapshot?.state.tombstones.contains($0) == true
        } ?? false
      )
    }
    board.questions = candidateQuestions.map { ($0.id, $0.content.text, $0.content.anchor) }
    return board
  }

  public func reconcileOpenedMeeting(
    meetingID: UUID,
    title: String,
    startedAt: Date,
    client: String?,
    project: String?,
    directoryHint: String?,
    minutesData: Data?,
    completedActionItems: [String]
  ) {
    let keptZone =
      candidateContext?.meetingID == meetingID
      ? candidateContext?.timeZoneIdentifier
      : nil
    let zoneID = keptZone ?? SystemTimeZone.current.identifier
    let zone = TimeZone(identifier: zoneID) ?? SystemTimeZone.current
    let referenceDay = TodoCalendar.dayString(of: startedAt, timeZone: zone) ?? ""
    if candidateContext?.meetingID != meetingID {
      candidateSelection = []
      expandedFolds = []
      candidateSurface = .meeting
      cleanLines = []
      candidateReceipt = nil
      reconcileID = nil
      cleanError = nil
      cleanRetry = false
    }
    guard persistsCandidateLedger else {
      candidateWritable = false
      installEphemeral(
        meetingID: meetingID, title: title, startedAt: startedAt, client: client, project: project,
        directoryHint: directoryHint, minutesData: minutesData,
        completedActionItems: completedActionItems,
        referenceDay: referenceDay, zoneID: zone.identifier
      )
      return
    }
    if phase != .ready || snapshot == nil {
      reloadSynchronously()
    }
    guard phase == .ready, snapshot != nil else {
      candidateWritable = false
      candidateActionError = "无法读取待办。原文件已保留，重新读取前暂停更改"
      return
    }
    candidateWritable = true
    guard let minutesData else {
      candidateItems = []
      candidateQuestions = []
      candidateRows = []
      roundNotices = []
      let ledger = snapshot?.state.ledger(for: meetingID) ?? MeetingCandidateLedger()
      legacyHits = TodoLegacyBridge.hits(
        completedActionItems: completedActionItems, items: [], ledger: ledger)
      candidateContext = MeetingCandidateContext(
        meetingID: meetingID, title: title, startedAt: startedAt, client: client, project: project,
        directoryHint: directoryHint, fingerprint: ledger.lastFingerprint ?? "",
        referenceDay: referenceDay, timeZoneIdentifier: zone.identifier,
        completedActionItems: completedActionItems
      )
      candidateActionError = nil
      return
    }
    let document: MeetingMinutesDocument
    let reconciliation: TodoReconciliation
    do {
      document = try StructuredArtifactCodec.decode(MeetingMinutesDocument.self, from: minutesData)
      let ledger = snapshot?.state.ledger(for: meetingID) ?? MeetingCandidateLedger()
      reconciliation = try TodoCandidateReconciler.reconcile(
        ledger: ledger, minutesData: minutesData)
    } catch {
      candidateActionError = "纪要还没读出来，这次没有改待办"
      return
    }
    let previousFingerprint = snapshot?.state.ledger(for: meetingID)?.lastFingerprint
    do {
      let saved = try acceptReconciliation(meetingID: meetingID, reconciliation: reconciliation)
      apply(saved)
    } catch {
      candidateActionError = TodoText.reason(of: error)
      return
    }
    let fingerprint =
      reconciliation.ledger.lastFingerprint ?? MinutesFingerprint.hex(of: minutesData)
    candidateActionError = nil
    candidateRows = reconciliation.rows
    candidateItems = document.actionItems
    candidateQuestions = document.openQuestions
    let ledger = snapshot?.state.ledger(for: meetingID) ?? reconciliation.ledger
    legacyHits = TodoLegacyBridge.hits(
      completedActionItems: completedActionItems, items: document.actionItems, ledger: ledger)
    if let previousFingerprint, previousFingerprint != fingerprint {
      let live = Set(reconciliation.rows.map(\.id))
      candidateSelection = candidateSelection.intersection(live)
      roundNotices = Self.roundNotices(from: reconciliation.rows)
    } else if previousFingerprint == nil {
      roundNotices = []
    }
    candidateContext = MeetingCandidateContext(
      meetingID: meetingID, title: title, startedAt: startedAt, client: client, project: project,
      directoryHint: directoryHint, fingerprint: fingerprint, referenceDay: referenceDay,
      timeZoneIdentifier: zone.identifier, completedActionItems: completedActionItems
    )
  }

  /// 刷新纪要只落候选台账。不在这里新增、改写或删除待办，也不自动关联疑似项。
  func acceptReconciliation(
    meetingID: UUID,
    reconciliation: TodoReconciliation
  ) throws -> TodoSnapshot {
    do {
      return try store.applyReconciliation(
        meetingID: meetingID, reconciliation: reconciliation, expectedRevision: revision)
    } catch let error as TodoStoreError {
      guard case .conflict(let current) = error else { throw error }
      apply(current)
      return try store.applyReconciliation(
        meetingID: meetingID, reconciliation: reconciliation,
        expectedRevision: current.state.revision)
    }
  }

  public func toggleCandidateSelection(_ id: UUID) {
    if candidateSelection.contains(id) {
      candidateSelection.remove(id)
    } else {
      candidateSelection.insert(id)
    }
  }

  public func toggleCandidateFold(_ fold: MeetingCandidateFold) {
    if expandedFolds.contains(fold) {
      expandedFolds.remove(fold)
    } else {
      expandedFolds.insert(fold)
    }
  }

  public func beginCandidateClean(_ ids: [UUID]) {
    guard candidateWritable else { return }
    let suspects = ids.filter { row($0)?.relation == .suspect }
    let plain = ids.filter { id in
      guard let row = row(id), row.disposition == .pending, row.snapshotIndex != nil else {
        return false
      }
      return row.relation != .suspect
    }
    if plain.isEmpty {
      if let first = suspects.first { beginReconcile(first) }
      return
    }
    candidateActionError = suspects.isEmpty ? nil : "疑似同一条的不进批量，请单独核对"
    cleanLines = plain.compactMap { makeCleanLine(candidateID: $0) }
    openClean()
  }

  public func beginCandidateReadd(_ id: UUID) {
    guard candidateWritable, let row = row(id),
      snapshot?.state.isPermanentlyDeleted(row.disposition) == true,
      var line = makeCleanLine(candidateID: id)
    else { return }
    line.isReadding = true
    cleanLines = [line]
    openClean()
  }

  public func beginSeparateClean(_ id: UUID) {
    guard candidateWritable, let line = makeCleanLine(candidateID: id) else { return }
    cleanLines = [line]
    openClean()
  }

  public func beginLegacyImport(_ index: Int) {
    guard candidateWritable, legacyHits.indices.contains(index) else { return }
    let hit = legacyHits[index]
    guard canImport(hit) else { return }
    var line = makeLegacyLine(hit)
    line.isReadding =
      hit.importedTodoID.map { snapshot?.state.tombstones.contains($0) == true } ?? false
    cleanLines = [line]
    openClean()
  }

  public func beginReconcile(_ id: UUID) {
    guard candidateWritable, row(id)?.relation == .suspect else { return }
    reconcileID = id
    cleanError = nil
    cleanRetry = false
    candidateReceipt = nil
    candidateSurface = .reconcile
  }

  public func returnToCandidates() {
    candidateSurface = .meeting
    cleanError = nil
    cleanRetry = false
    candidateReceipt = nil
    reconcileID = nil
  }

  public func updateCleanLine(_ id: UUID, _ body: (inout MeetingCandidateCleanLine) -> Void) {
    guard let index = cleanLines.firstIndex(where: { $0.id == id }) else { return }
    var line = cleanLines[index]
    let previousAssignee = assignee(from: line.draft)
    body(&line)
    if assignee(from: line.draft) != previousAssignee { line.confirmedAssignee = nil }
    cleanLines[index] = line
    cleanError = nil
  }

  public func cleanNeedsAssigneeConfirmation(_ line: MeetingCandidateCleanLine) -> Bool {
    let selected = assignee(from: line.draft)
    return TodoAssigneeConflict.requiresConfirmation(
      sourceOwnerText: line.ownerText, assignee: selected)
      && line.confirmedAssignee != selected
  }

  public var cleanReviewedCount: Int {
    cleanLines.filter { !$0.removed && lineCanSave($0) }.count
  }

  public func confirmCleanAssignee(_ id: UUID, useOriginal: Bool) {
    guard let index = cleanLines.firstIndex(where: { $0.id == id }) else { return }
    if useOriginal, let original = cleanLines[index].ownerText?.nilIfBlank {
      cleanLines[index].draft.assigneeKind = original == "我" || original == "本人" ? .me : .named
      cleanLines[index].draft.assigneeName = original
    }
    cleanLines[index].confirmedAssignee = assignee(from: cleanLines[index].draft)
    cleanError = nil
  }

  public func setCandidateTimeZone(_ identifier: String) {
    guard var context = candidateContext, TimeZone(identifier: identifier) != nil else { return }
    context.timeZoneIdentifier = identifier
    context.referenceDay =
      TodoCalendar.dayString(of: context.startedAt, timeZone: TimeZone(identifier: identifier)!)
      ?? context.referenceDay
    candidateContext = context
    for index in cleanLines.indices {
      let deadline = cleanLines[index].deadlineText
      let resolution = interpret(deadline)
      cleanLines[index].resolution = resolution
      cleanLines[index].chosenDay = nil
      applyResolution(resolution, to: &cleanLines[index])
    }
  }

  public func removeCleanLine(_ id: UUID) {
    updateCleanLine(id) { $0.removed = true }
  }

  @discardableResult
  public func saveClean() -> Bool {
    let active = cleanLines.filter { !$0.removed }
    guard candidateWritable, let context = candidateContext, !active.isEmpty,
      active.allSatisfy(lineCanSave)
    else {
      return false
    }
    if active.contains(where: {
      $0.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) {
      cleanError = TodoText.saveFailure("事项不能为空")
      cleanRetry = true
      return false
    }
    let drafts = active.map { draft(from: $0, context: context) }
    let previousLegacyImported =
      snapshot?.state.ledger(for: context.meetingID)?.legacyImported ?? [:]
    do {
      let result: TodoAddResult
      if active.count == 1, active[0].isReadding {
        result = try store.readd(drafts[0], expectedRevision: revision, now: now)
      } else {
        result = try store.add(drafts, expectedRevision: revision, now: now)
      }
      apply(result.snapshot)
      refreshRowsFromSnapshot()
      var steps: [MeetingCandidateUndo] = []
      for (line, todoID) in zip(active, result.todoIDs) {
        if let candidateID = line.candidateID {
          steps.append(.candidate(candidateID))
        } else if let key = line.legacyKey {
          steps.append(
            .legacyOnly(todoID: todoID, key: key, previousTodoID: previousLegacyImported[key]))
        }
      }
      let count = result.todoIDs.count
      candidateReceipt = MeetingCandidateReceipt(
        message: count == 1 ? "已加入 1 条" : "已加入 \(count) 条",
        steps: steps,
        canUndo: !steps.isEmpty
      )
      candidateSelection.subtract(active.compactMap(\.candidateID))
      candidateSurface = .receipt
      cleanError = nil
      cleanRetry = false
      return true
    } catch {
      cleanError = TodoText.saveFailure(TodoText.reason(of: error))
      cleanRetry = true
      return false
    }
  }

  public func linkExisting(candidateID: UUID, todoID: UUID) {
    guard candidateWritable, let context = candidateContext, let item = actionItem(candidateID)
    else { return }
    let before = self.item(todoID)
    let variant = TodoCandidateSignature.variant(
      from: item, fingerprint: context.fingerprint, id: UUID())
    let source = sourceSnapshot(
      for: item, candidateID: candidateID, legacyKey: nil, context: context)
    do {
      let saved = try store.linkCandidate(
        meetingID: context.meetingID, candidateID: candidateID, todoID: todoID, variant: variant,
        source: source, expectedRevision: revision, expectedMinutesFingerprint: context.fingerprint,
        now: now)
      apply(saved)
      refreshRowsFromSnapshot()
      if let before, let after = self.item(todoID) {
        let same =
          before.title == after.title && before.assignee == after.assignee
          && before.due == after.due && before.status == after.status
          && before.priority == after.priority
        if !same {
          candidateActionError = "关联改动了待办内容"
        }
      }
      candidateReceipt = MeetingCandidateReceipt(
        message: "已关联到现有待办，事项没有改动", steps: [], canUndo: false)
      candidateSurface = .receipt
      cleanError = nil
    } catch {
      cleanError = TodoText.saveFailure(TodoText.reason(of: error))
      cleanRetry = true
    }
  }

  public func ignoreCandidate(_ id: UUID) {
    guard candidateWritable, let meetingID = candidateContext?.meetingID else { return }
    do {
      let saved = try store.ignoreCandidate(
        meetingID: meetingID, candidateID: id, expectedRevision: revision, now: now)
      apply(saved)
      candidateSelection.remove(id)
      refreshRowsFromSnapshot()
      if candidateSurface == .reconcile { candidateSurface = .meeting }
      candidateActionError = nil
    } catch {
      candidateActionError = TodoText.reason(of: error)
    }
  }

  public func restoreIgnored(_ id: UUID) {
    guard candidateWritable, let meetingID = candidateContext?.meetingID else { return }
    do {
      let saved = try store.unignoreCandidate(
        meetingID: meetingID, candidateID: id, expectedRevision: revision)
      apply(saved)
      refreshRowsFromSnapshot()
      candidateActionError = nil
    } catch {
      candidateActionError = TodoText.reason(of: error)
    }
  }

  public func undoAddedCandidate(_ id: UUID) {
    guard candidateWritable, let meetingID = candidateContext?.meetingID else { return }
    do {
      let saved = try store.undoAdd(
        meetingID: meetingID, candidateID: id, expectedRevision: revision)
      apply(saved)
      refreshRowsFromSnapshot()
      candidateActionError = nil
    } catch {
      candidateActionError = TodoText.reason(of: error)
    }
  }

  public func undoCandidateReceipt() {
    guard candidateWritable, let receipt = candidateReceipt,
      let meetingID = candidateContext?.meetingID
    else { return }
    do {
      for step in receipt.steps.reversed() {
        switch step {
        case .candidate(let id):
          apply(
            try store.undoAdd(meetingID: meetingID, candidateID: id, expectedRevision: revision))
        case .legacyOnly(let todoID, let key, let previousTodoID):
          apply(
            try store.commit(expectedRevision: revision) { state in
              state.todos.removeAll { $0.id == todoID }
              if var ledger = state.ledger(for: meetingID) {
                ledger.legacyImported[key] = previousTodoID
                state.setLedger(ledger, for: meetingID)
              }
            })
        }
      }
      refreshRowsFromSnapshot()
      candidateReceipt = nil
      candidateSurface = .meeting
      cleanError = nil
    } catch {
      cleanError = TodoText.saveFailure(TodoText.reason(of: error))
      cleanRetry = true
    }
  }

  public func deferReconcile() {
    candidateSurface = .meeting
    reconcileID = nil
  }

  public func reconcileComparison() -> MeetingReconcileComparison? {
    guard let id = reconcileID, let row = row(id), let item = actionItem(id),
      let context = candidateContext, let ledger = snapshot?.state.ledger(for: context.meetingID)
    else { return nil }
    let current = TodoCandidateSignature.variant(
      from: item, fingerprint: context.fingerprint, id: item.id)
    let cards = row.suspects.compactMap { suspect -> MeetingReconcileCard? in
      guard let record = ledger.candidates.first(where: { $0.id == suspect.candidateID }),
        let old = record.variants.last
      else { return nil }
      let todos = record.disposition.todoIDs.compactMap { self.item($0) }
      return MeetingReconcileCard(
        suspectID: suspect.candidateID,
        disposition: suspect.disposition,
        reason: suspect.reason,
        old: old,
        todos: todos
      )
    }
    return MeetingReconcileComparison(
      candidateID: id, meetingTitle: context.title, referenceDay: context.referenceDay,
      current: current, cards: cards)
  }

  private func openClean() {
    cleanError = nil
    cleanRetry = false
    candidateReceipt = nil
    reconcileID = nil
    candidateSurface = .clean
  }

  private func installEphemeral(
    meetingID: UUID,
    title: String,
    startedAt: Date,
    client: String?,
    project: String?,
    directoryHint: String?,
    minutesData: Data?,
    completedActionItems: [String],
    referenceDay: String,
    zoneID: String
  ) {
    let document = minutesData.flatMap {
      try? StructuredArtifactCodec.decode(MeetingMinutesDocument.self, from: $0)
    }
    let items = document?.actionItems ?? []
    candidateItems = items
    candidateQuestions = document?.openQuestions ?? []
    candidateRows = items.enumerated().map { index, item in
      TodoCandidateRow(
        id: item.id, snapshotIndex: index, disposition: .pending, relation: .newItem,
        newlyIntroduced: false, suspects: [], hiddenSuspectCount: 0)
    }
    let ledger = MeetingCandidateLedger()
    legacyHits = TodoLegacyBridge.hits(
      completedActionItems: completedActionItems, items: items, ledger: ledger)
    roundNotices = []
    candidateContext = MeetingCandidateContext(
      meetingID: meetingID, title: title, startedAt: startedAt, client: client, project: project,
      directoryHint: directoryHint, fingerprint: "", referenceDay: referenceDay,
      timeZoneIdentifier: zoneID, completedActionItems: completedActionItems
    )
    candidateActionError = nil
  }

  private func refreshRowsFromSnapshot() {
    guard let meetingID = candidateContext?.meetingID,
      let ledger = snapshot?.state.ledger(for: meetingID)
    else { return }
    candidateRows = candidateRows.map { row in
      guard let record = ledger.candidates.first(where: { $0.id == row.id }) else { return row }
      return TodoCandidateRow(
        id: row.id, snapshotIndex: record.snapshotIndex, disposition: record.disposition,
        relation: row.relation, newlyIntroduced: row.newlyIntroduced, suspects: row.suspects,
        hiddenSuspectCount: row.hiddenSuspectCount
      )
    }
    legacyHits = TodoLegacyBridge.hits(
      completedActionItems: candidateContext?.completedActionItems,
      items: candidateItems,
      ledger: ledger
    )
  }

  private func lineVM(_ row: TodoCandidateRow) -> MeetingCandidateLineVM? {
    let item = row.snapshotIndex.flatMap {
      candidateItems.indices.contains($0) ? candidateItems[$0] : nil
    }
    let variant = record(row.id)?.variants.last
    let title = item?.text ?? variant?.text ?? ""
    guard !title.isEmpty else { return nil }
    let owner = displayOwner(
      item?.owner ?? variant?.owner, ownership: item?.ownership ?? variant?.ownership ?? .unknown)
    let deadline = item?.deadline ?? variant?.deadline
    let anchor =
      item?.recordedAt
      ?? variant?.anchor.flatMap { value in
        value == "无" ? nil : TranscriptAnchor(timecode: value)
      }
    let primary = row.relation == .suspect ? "核对" : "加入待办"
    let primaryID =
      row.relation == .suspect
      ? "meeting.candidates.review.\(row.id.uuidString)"
      : "meeting.candidates.add.\(row.id.uuidString)"
    var note: String?
    if row.snapshotIndex == nil, case .added = row.disposition {
      note = "原纪要已更新，本条未再出现"
    }
    if row.relation == .suspect {
      note = suspectPhrase(row)
    }
    let permanentlyDeleted = snapshot?.state.isPermanentlyDeleted(row.disposition) == true
    if permanentlyDeleted { note = "待办已永久删除" }
    return MeetingCandidateLineVM(
      id: row.id, title: title, owner: owner,
      deadline: deadline.map { "原截止：\($0)" } ?? "原截止：待确认",
      anchor: anchor, primaryTitle: primary, primaryIdentifier: primaryID, note: note,
      permanentlyDeleted: permanentlyDeleted
    )
  }

  private func suspectPhrase(_ row: TodoCandidateRow) -> String {
    let dispositions = row.suspects.map(\.disposition)
    if dispositions.contains(where: {
      if case .added = $0 { return true }
      return false
    }) {
      return "可能已加入"
    }
    if dispositions.contains(where: {
      if case .ignored = $0 { return true }
      return false
    }) {
      return "可能曾忽略"
    }
    return "原话有更新"
  }

  private func legacyTitle(_ hit: TodoLegacyHit) -> String {
    if let item = hit.matches.first?.item { return item.text }
    return hit.key
  }

  private func legacyDetail(_ hit: TodoLegacyHit) -> String {
    if let id = hit.importedTodoID {
      return snapshot?.state.tombstones.contains(id) == true ? "待办已永久删除" : "此前在会议中勾选过 · 已带入"
    }
    if hit.ambiguous { return "此前在会议中勾选过 · 无法区分是哪一条" }
    if hit.missingFromCurrent { return "此前在会议中勾选过 · 原负责人、截止和位置无法恢复" }
    return "此前在会议中勾选过"
  }

  private func canImport(_ hit: TodoLegacyHit) -> Bool {
    if hit.ambiguous { return false }
    if let id = hit.importedTodoID {
      return candidateWritable && snapshot?.state.tombstones.contains(id) == true
    }
    if let id = hit.matches.first?.candidateID, let row = row(id), row.disposition != .pending {
      return false
    }
    return candidateWritable
  }

  private func makeCleanLine(candidateID: UUID) -> MeetingCandidateCleanLine? {
    let item: SummaryActionItem
    if let current = actionItem(candidateID) {
      item = current
    } else if let variant = record(candidateID)?.variants.last {
      item = SummaryActionItem(
        text: variant.text, owner: variant.owner, deadline: variant.deadline,
        ownership: variant.ownership,
        recordedAt: variant.anchor.flatMap { $0 == "无" ? nil : TranscriptAnchor(timecode: $0) })
    } else {
      return nil
    }
    return fill(item, candidateID: candidateID, legacyKey: nil, missing: false)
  }

  private func makeLegacyLine(_ hit: TodoLegacyHit) -> MeetingCandidateCleanLine {
    if let match = hit.matches.first, !hit.ambiguous {
      var line = fill(
        match.item, candidateID: match.candidateID, legacyKey: hit.key, missing: false)
      line.markCompleted = true
      line.id = match.candidateID ?? UUID()
      return line
    }
    var draft = TodoEditorDraft()
    draft.title = hit.key
    draft.assigneeKind = .pending
    draft.dueKind = .pending
    draft.client = candidateContext?.client ?? ""
    draft.project = candidateContext?.project ?? ""
    draft.timeZoneIdentifier =
      candidateContext?.timeZoneIdentifier ?? SystemTimeZone.current.identifier
    return MeetingCandidateCleanLine(
      id: UUID(), candidateID: nil, legacyKey: hit.key, draft: draft, sourceText: hit.key,
      ownerText: nil, deadlineText: nil, anchor: nil, resolution: .unresolved, chosenDay: nil,
      markCompleted: true, missingContext: true
    )
  }

  private func fill(
    _ item: SummaryActionItem,
    candidateID: UUID?,
    legacyKey: String?,
    missing: Bool
  ) -> MeetingCandidateCleanLine {
    var draft = TodoEditorDraft()
    draft.title = item.text
    switch item.ownership {
    case .me:
      draft.assigneeKind = .me
    case .other:
      if let owner = item.owner, !owner.isEmpty {
        draft.assigneeKind = .named
        draft.assigneeName = owner
      } else {
        draft.assigneeKind = .pending
      }
    case .unknown:
      draft.assigneeKind = .pending
    }
    draft.client = candidateContext?.client ?? ""
    draft.project = candidateContext?.project ?? ""
    draft.timeZoneIdentifier =
      candidateContext?.timeZoneIdentifier ?? SystemTimeZone.current.identifier
    let resolution = interpret(item.deadline)
    var line = MeetingCandidateCleanLine(
      id: candidateID ?? UUID(), candidateID: candidateID, legacyKey: legacyKey, draft: draft,
      sourceText: item.text, ownerText: item.owner, deadlineText: item.deadline,
      anchor: item.recordedAt?.timecode, resolution: resolution, chosenDay: nil,
      markCompleted: false, missingContext: missing
    )
    applyResolution(resolution, to: &line)
    return line
  }

  private func applyResolution(
    _ resolution: TodoDueResolution, to line: inout MeetingCandidateCleanLine
  ) {
    switch resolution {
    case .day(let day):
      line.draft.dueKind = .date
      line.draft.dueDate = TodoClock.pickerDate(day: day.day)
      line.draft.timeZoneIdentifier = day.timeZoneIdentifier
      line.chosenDay = day.day
    case .choose(let days, _):
      line.draft.dueKind = .date
      if let show = days.last {
        line.draft.dueDate = TodoClock.pickerDate(day: show.day)
        line.draft.timeZoneIdentifier = show.timeZoneIdentifier
      }
      line.chosenDay = nil
    case .unresolved:
      line.draft.dueKind = .pending
      line.chosenDay = nil
    }
  }

  private func lineCanSave(_ line: MeetingCandidateCleanLine) -> Bool {
    guard !line.removed else { return true }
    guard !line.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    if line.draft.assigneeKind == .named, line.draft.assigneeName.nilIfBlank == nil { return false }
    if cleanNeedsAssigneeConfirmation(line) { return false }
    guard case .choose = line.resolution else { return true }
    switch line.draft.dueKind {
    case .pending, .none: return true
    case .date: return line.chosenDay != nil
    }
  }

  private func draft(from line: MeetingCandidateCleanLine, context: MeetingCandidateContext)
    -> TodoDraft
  {
    let item = line.candidateID.flatMap(actionItem)
    return TodoDraft(
      title: line.draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
      note: line.draft.note,
      assignee: assignee(from: line.draft),
      due: due(of: line),
      priority: line.draft.priority,
      client: line.draft.client.nilIfBlank,
      project: line.draft.project.nilIfBlank,
      status: line.markCompleted ? .done : .open,
      completionTimeUnknown: line.markCompleted && line.legacyKey != nil,
      meetingID: context.meetingID,
      candidateID: line.candidateID,
      source: item.map {
        sourceSnapshot(
          for: $0, candidateID: line.candidateID, legacyKey: line.legacyKey, context: context)
      }
        ?? legacySource(line, context: context),
      expectedMinutesFingerprint: context.fingerprint.isEmpty ? nil : context.fingerprint,
      legacyKey: line.legacyKey
    )
  }

  private func due(of line: MeetingCandidateCleanLine) -> TodoDue {
    switch line.draft.dueKind {
    case .none: return .none
    case .pending: return .pending
    case .date:
      let day = line.chosenDay ?? TodoClock.dayString(from: line.draft.dueDate)
      let zone =
        line.draft.timeZoneIdentifier.isEmpty
        ? (candidateContext?.timeZoneIdentifier ?? SystemTimeZone.current.identifier)
        : line.draft.timeZoneIdentifier
      return .date(TodoDay(day: day, timeZoneIdentifier: zone))
    }
  }

  private func legacySource(_ line: MeetingCandidateCleanLine, context: MeetingCandidateContext)
    -> TodoSource
  {
    TodoSource(
      meetingID: context.meetingID, directoryHint: context.directoryHint,
      meetingTitle: context.title,
      meetingStartedAt: context.startedAt, client: context.client, project: context.project,
      candidateID: line.candidateID, candidateText: line.sourceText,
      ownerText: line.ownerText, deadlineText: line.deadlineText, anchor: line.anchor,
      dueBasis: TodoDueBasis(
        referenceDay: context.referenceDay, timeZoneIdentifier: context.timeZoneIdentifier),
      legacyKey: line.legacyKey,
      addedAt: now
    )
  }

  private func sourceSnapshot(
    for item: SummaryActionItem,
    candidateID: UUID?,
    legacyKey: String?,
    context: MeetingCandidateContext
  ) -> TodoSource {
    TodoSource(
      meetingID: context.meetingID, directoryHint: context.directoryHint,
      meetingTitle: context.title,
      meetingStartedAt: context.startedAt, client: context.client, project: context.project,
      candidateID: candidateID, candidateText: item.text, ownerText: item.owner,
      deadlineText: item.deadline,
      anchor: item.recordedAt?.timecode,
      minutesFingerprint: context.fingerprint.isEmpty ? nil : context.fingerprint,
      dueBasis: TodoDueBasis(
        referenceDay: context.referenceDay, timeZoneIdentifier: context.timeZoneIdentifier),
      legacyKey: legacyKey, addedAt: now
    )
  }

  private func interpret(_ deadline: String?) -> TodoDueResolution {
    guard let deadline, !deadline.isEmpty, let context = candidateContext,
      let zone = TimeZone(identifier: context.timeZoneIdentifier)
    else { return .unresolved }
    return TodoDueInterpreter.interpret(
      text: deadline, reference: context.startedAt, timeZone: zone)
  }

  private func actionItem(_ id: UUID) -> SummaryActionItem? {
    if let row = row(id), let index = row.snapshotIndex, candidateItems.indices.contains(index) {
      return candidateItems[index]
    }
    return candidateItems.first { $0.id == id }
  }

  private func row(_ id: UUID) -> TodoCandidateRow? {
    candidateRows.first { $0.id == id }
  }

  private func record(_ id: UUID) -> CandidateRecord? {
    guard let meetingID = candidateContext?.meetingID else { return nil }
    return snapshot?.state.ledger(for: meetingID)?.candidates.first { $0.id == id }
  }

  private func displayOwner(_ owner: String?, ownership: SummaryActionOwnership) -> String {
    if let owner, !owner.isEmpty { return owner }
    return ownership == .me ? "我" : "待确认"
  }

  private static func roundNotices(from rows: [TodoCandidateRow]) -> [MeetingCandidateNotice] {
    var notices: [MeetingCandidateNotice] = []
    if rows.contains(where: \.newlyIntroduced) {
      notices.append(MeetingCandidateNotice(id: "new", text: "新候选"))
    }
    let suspects = rows.filter { $0.relation == .suspect }
    if suspects.contains(where: {
      $0.suspects.contains {
        if case .added = $0.disposition { return true }
        return false
      }
    }) {
      notices.append(MeetingCandidateNotice(id: "maybe-added", text: "可能已加入"))
    }
    if suspects.contains(where: {
      $0.suspects.contains {
        if case .ignored = $0.disposition { return true }
        return false
      }
    }) {
      notices.append(MeetingCandidateNotice(id: "maybe-ignored", text: "可能曾忽略"))
    }
    if suspects.contains(where: { row in
      !row.suspects.contains {
        if case .added = $0.disposition { return true }
        return false
      }
        && !row.suspects.contains {
          if case .ignored = $0.disposition { return true }
          return false
        }
    }) {
      notices.append(MeetingCandidateNotice(id: "updated", text: "原话有更新"))
    }
    if rows.contains(where: { $0.relation == .absentPending }) {
      notices.append(MeetingCandidateNotice(id: "absent", text: "本轮未再出现"))
    }
    return notices
  }
}

public struct MeetingReconcileCard: Equatable, Identifiable {
  public var suspectID: UUID
  public var disposition: CandidateDisposition
  public var reason: TodoSuspectReason
  public var old: CandidateVariant
  public var todos: [TodoItem]
  public var id: UUID { suspectID }
}

public struct MeetingReconcileComparison: Equatable {
  public var candidateID: UUID
  public var meetingTitle: String
  public var referenceDay: String
  public var current: CandidateVariant
  public var cards: [MeetingReconcileCard]
}

enum MeetingCandidateCopy {
  static func choiceLabel(day: TodoDay, reason: TodoDueChoiceReason, options: [TodoDay]) -> String {
    let date = TodoText.monthDay(day.day)
    switch reason {
    case .inclusiveBoundary:
      let latest = options.map(\.day).max()
      return day.day == latest ? "包含当天 · \(date)" : "截至前一天 · \(date)"
    case .withinIncludesReferenceDay:
      let earliest = options.map(\.day).min()
      return day.day == earliest ? "包含当天 · \(date)" : "不含当天 · \(date)"
    case .missingYear:
      let year = TodoCalendar.parts(day.day)?.year ?? 0
      return "\(year)年 · \(date)"
    case .boundaryAndYear:
      return "截至 \(day.day)"
    }
  }

  static func fieldRows(_ variant: CandidateVariant) -> [(
    key: String, label: String, value: String
  )] {
    [
      ("text", "事项", variant.text),
      ("owner", "负责人", variant.owner?.nilIfBlank ?? (variant.ownership == .me ? "我" : "待确认")),
      ("deadline", "原截止", variant.deadline?.nilIfBlank ?? "待确认"),
      ("anchor", "来源时间", variant.anchor?.nilIfBlank ?? "无"),
    ]
  }
}
