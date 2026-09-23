import Foundation

public enum TodoCandidateRelation: Equatable, Sendable {
  case sameSnapshot
  case strictCarry
  case newItem
  case suspect
  case absentPending
  case absentAdded
  case absentIgnored
  case retainedAsHint
}

public enum TodoSuspectReason: Equatable, Sendable {
  case sameTextDifferentFields
  case nearAnchor(TimeInterval)
  case similarText
  case ambiguousStrict
}

public struct TodoSuspect: Equatable, Sendable, Identifiable {
  public var candidateID: UUID
  public var disposition: CandidateDisposition
  public var reason: TodoSuspectReason

  public var id: UUID { candidateID }

  public init(candidateID: UUID, disposition: CandidateDisposition, reason: TodoSuspectReason) {
    self.candidateID = candidateID
    self.disposition = disposition
    self.reason = reason
  }
}

public struct TodoCandidateRow: Equatable, Sendable, Identifiable {
  public var id: UUID
  public var snapshotIndex: Int?
  public var disposition: CandidateDisposition
  public var relation: TodoCandidateRelation
  public var newlyIntroduced: Bool
  public var suspects: [TodoSuspect]
  public var hiddenSuspectCount: Int

  public init(
    id: UUID,
    snapshotIndex: Int?,
    disposition: CandidateDisposition,
    relation: TodoCandidateRelation,
    newlyIntroduced: Bool,
    suspects: [TodoSuspect],
    hiddenSuspectCount: Int
  ) {
    self.id = id
    self.snapshotIndex = snapshotIndex
    self.disposition = disposition
    self.relation = relation
    self.newlyIntroduced = newlyIntroduced
    self.suspects = suspects
    self.hiddenSuspectCount = hiddenSuspectCount
  }
}

public struct TodoReconciliation: Equatable, Sendable {
  public var ledger: MeetingCandidateLedger
  public var rows: [TodoCandidateRow]
  public var hadPreviousSnapshot: Bool

  public init(ledger: MeetingCandidateLedger, rows: [TodoCandidateRow], hadPreviousSnapshot: Bool) {
    self.ledger = ledger
    self.rows = rows
    self.hadPreviousSnapshot = hadPreviousSnapshot
  }
}

public enum TodoSourceNotice: Equatable, Sendable {
  case minutesUpdatedItemGone(candidateID: UUID)
}

public enum TodoSourceNotices {
  public static func notices(
    for todo: TodoItem,
    ledgers: [UUID: MeetingCandidateLedger]
  ) -> [TodoSourceNotice] {
    todo.sources.compactMap { source in
      guard let candidateID = source.candidateID,
        let ledger = ledgers[source.meetingID],
        let record = ledger.candidates.first(where: { $0.id == candidateID }),
        case .added = record.disposition,
        record.snapshotIndex == nil,
        !isHinted(record, in: ledger)
      else { return nil }
      return .minutesUpdatedItemGone(candidateID: candidateID)
    }
  }

  private static func isHinted(_ record: CandidateRecord, in ledger: MeetingCandidateLedger) -> Bool {
    ledger.candidates.contains { $0.suspectedCandidateIDs.contains(record.id) }
  }
}

public enum TodoCandidateSignature {
  public static func normalizedText(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
      .joined(separator: " ")
  }

  public static func nonWhitespaceCount(_ text: String) -> Int {
    normalizedText(text).filter { !$0.isWhitespace }.count
  }

  public static func dice(_ left: String, _ right: String) -> Double {
    let leftPairs = bigrams(normalizedText(left))
    let rightPairs = bigrams(normalizedText(right))
    let total = leftPairs.count + rightPairs.count
    guard total > 0 else { return 0 }
    var counts: [String: Int] = [:]
    for pair in leftPairs {
      counts[pair, default: 0] += 1
    }
    var overlap = 0
    for pair in rightPairs {
      guard let count = counts[pair], count > 0 else { continue }
      overlap += 1
      counts[pair] = count - 1
    }
    return (2 * Double(overlap)) / Double(total)
  }

  public static func strict(_ item: SummaryActionItem) -> String {
    strict(
      text: item.text,
      owner: item.owner,
      ownership: item.ownership,
      deadline: item.deadline,
      kind: item.kind,
      anchor: item.recordedAt?.timecode,
      evidence: item.evidence?.rawValue,
      updatesSummary: updatesSummary(item.updates)
    )
  }

  public static func strict(_ variant: CandidateVariant) -> String {
    strict(
      text: variant.text,
      owner: variant.owner,
      ownership: variant.ownership,
      deadline: variant.deadline,
      kind: variant.kind,
      anchor: variant.anchor,
      evidence: variant.evidence,
      updatesSummary: variant.updatesSummary
    )
  }

  public static func updatesSummary(_ updates: [SummaryActionUpdate]) -> String {
    guard !updates.isEmpty else { return "∅" }
    return updates.map { update in
      "\(normalizedText(update.text))@\(anchorToken(update.anchor?.timecode))"
    }.joined(separator: "\u{1E}")
  }

  public static func variant(
    from item: SummaryActionItem,
    fingerprint: String,
    id: UUID
  ) -> CandidateVariant {
    CandidateVariant(
      id: id,
      text: item.text,
      owner: item.owner,
      ownership: item.ownership,
      deadline: item.deadline,
      kind: item.kind,
      anchor: item.recordedAt?.timecode,
      evidence: item.evidence?.rawValue,
      updatesSummary: updatesSummary(item.updates),
      fingerprint: fingerprint
    )
  }

  /// 正文以外的字段都在签名里。只比正文会把换了负责人或期限的要求当成同一条。
  public static func strict(
    text: String,
    owner: String?,
    ownership: SummaryActionOwnership,
    deadline: String?,
    kind: SummaryActionKind,
    anchor: String?,
    evidence: String?,
    updatesSummary: String
  ) -> String {
    let textPart = "text:\(normalizedText(text))"
    let ownerPart = "owner:\(original(owner))"
    let ownershipPart = "ownership:\(ownership.rawValue)"
    let deadlinePart = "deadline:\(original(deadline))"
    let kindPart = "kind:\(kind.rawValue)"
    let anchorPart = "anchor:\(anchorToken(anchor))"
    let evidencePart = "evidence:\(original(evidence))"
    let updatesPart = "updates:\(updatesSummary.isEmpty ? "∅" : updatesSummary)"
    return [
      textPart, ownerPart, ownershipPart, deadlinePart, kindPart, anchorPart, evidencePart, updatesPart,
    ].joined(separator: "\u{1F}")
  }

  private static func original(_ value: String?) -> String {
    guard let value else { return "∅" }
    let trimmed = value.precomposedStringWithCanonicalMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "∅" : trimmed
  }

  private static func anchorToken(_ timecode: String?) -> String {
    guard let timecode else { return "无" }
    let trimmed = timecode.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "无" : trimmed
  }

  private static func bigrams(_ text: String) -> [String] {
    let characters = Array(text)
    guard characters.count >= 2 else { return [] }
    return (0..<(characters.count - 1)).map { String(characters[$0]) + String(characters[$0 + 1]) }
  }
}

public enum TodoCandidateReconciler {
  /// 只有 minutes 字节能完整解码时才比对。解码失败直接抛出，不会变成一份空快照。
  public static func reconcile(
    ledger: MeetingCandidateLedger,
    minutesData: Data,
    makeID: () -> UUID = { UUID() }
  ) throws -> TodoReconciliation {
    let document = try StructuredArtifactCodec.decode(MeetingMinutesDocument.self, from: minutesData)
    return reconcile(
      ledger: ledger,
      items: document.actionItems,
      fingerprint: MinutesFingerprint.hex(of: minutesData),
      makeID: makeID
    )
  }

  public static func reconcile(
    ledger: MeetingCandidateLedger,
    items: [SummaryActionItem],
    fingerprint: String,
    makeID: () -> UUID = { UUID() }
  ) -> TodoReconciliation {
    if let last = ledger.lastFingerprint, last == fingerprint {
      return TodoReconciliation(
        ledger: ledger,
        rows: buildRows(ledger: ledger, items: items, fingerprint: fingerprint, sameSnapshot: true),
        hadPreviousSnapshot: true
      )
    }
    let hadPrevious = ledger.lastFingerprint != nil
    let updated = regenerate(
      ledger: ledger,
      items: items,
      fingerprint: fingerprint,
      makeID: makeID
    )
    return TodoReconciliation(
      ledger: updated,
      rows: buildRows(ledger: updated, items: items, fingerprint: fingerprint, sameSnapshot: false),
      hadPreviousSnapshot: hadPrevious
    )
  }

  private static func regenerate(
    ledger: MeetingCandidateLedger,
    items: [SummaryActionItem],
    fingerprint: String,
    makeID: () -> UUID
  ) -> MeetingCandidateLedger {
    var newToOld: [Int: [UUID]] = [:]
    var oldToNew: [UUID: [Int]] = [:]
    for (index, item) in items.enumerated() {
      let signature = TodoCandidateSignature.strict(item)
      let hits = ledger.candidates.filter { candidate in
        candidate.variants.contains { TodoCandidateSignature.strict($0) == signature }
      }.map(\.id)
      newToOld[index] = hits
      for id in hits {
        oldToNew[id, default: []].append(index)
      }
    }

    var carried: [Int: UUID] = [:]
    for (index, hits) in newToOld {
      guard hits.count == 1, let id = hits.first, oldToNew[id]?.count == 1 else { continue }
      carried[index] = id
    }

    var ordered: [CandidateRecord] = []
    var consumed: Set<UUID> = []
    for (index, item) in items.enumerated() {
      if let id = carried[index], let existing = ledger.candidates.first(where: { $0.id == id }) {
        var record = existing
        record.snapshotIndex = index
        record.lastSeenFingerprint = fingerprint
        record.suspectedCandidateIDs = []
        ordered.append(record)
        consumed.insert(id)
        continue
      }
      let links = suspectIDs(for: item, in: ledger.candidates)
      let keptDisposition: CandidateDisposition = .pending
      ordered.append(CandidateRecord(
        id: makeID(),
        variants: [
          TodoCandidateSignature.variant(from: item, fingerprint: fingerprint, id: makeID())
        ],
        suspectedCandidateIDs: links,
        disposition: keptDisposition,
        firstSeenFingerprint: fingerprint,
        lastSeenFingerprint: fingerprint,
        snapshotIndex: index
      ))
    }
    for candidate in ledger.candidates where !consumed.contains(candidate.id) {
      var retained = candidate
      retained.snapshotIndex = nil
      ordered.append(retained)
    }
    return MeetingCandidateLedger(
      lastFingerprint: fingerprint,
      candidates: ordered,
      legacyImported: ledger.legacyImported
    )
  }

  private static func suspectIDs(
    for item: SummaryActionItem,
    in candidates: [CandidateRecord]
  ) -> [UUID] {
    var links: [(UUID, TodoSuspectReason)] = []
    for candidate in candidates {
      var reason: TodoSuspectReason?
      for variant in candidate.variants {
        guard let next = suspectReason(item: item, variant: variant) else { continue }
        reason = better(reason, next)
      }
      if let reason {
        links.append((candidate.id, reason))
      }
    }
    return links.sorted { lhs, rhs in
      let left = rank(lhs.1)
      let right = rank(rhs.1)
      if left != right { return left < right }
      return lhs.0.uuidString < rhs.0.uuidString
    }.map(\.0)
  }

  private static func suspectReason(
    item: SummaryActionItem,
    variant: CandidateVariant
  ) -> TodoSuspectReason? {
    let projected = TodoCandidateSignature.variant(from: item, fingerprint: "", id: UUID())
    return suspectReason(projected, variant)
  }

  private static func anchorDistance(_ left: String?, _ right: String?) -> TimeInterval? {
    guard let left, let right,
      let start = TranscriptAnchor(timecode: left).seconds,
      let end = TranscriptAnchor(timecode: right).seconds
    else { return nil }
    return abs(start - end)
  }

  private static func better(
    _ current: TodoSuspectReason?,
    _ next: TodoSuspectReason
  ) -> TodoSuspectReason {
    guard let current else { return next }
    let left = rank(current)
    let right = rank(next)
    if left != right { return right < left ? next : current }
    if case .nearAnchor(let currentDistance) = current, case .nearAnchor(let nextDistance) = next {
      return nextDistance < currentDistance ? next : current
    }
    return current
  }

  private static func rank(_ reason: TodoSuspectReason) -> Int {
    switch reason {
    case .sameTextDifferentFields: return 0
    case .ambiguousStrict: return 1
    case .nearAnchor: return 2
    case .similarText: return 3
    }
  }

  private static func buildRows(
    ledger: MeetingCandidateLedger,
    items: [SummaryActionItem],
    fingerprint: String,
    sameSnapshot: Bool
  ) -> [TodoCandidateRow] {
    let previousGeneration = ledger.candidates.contains { $0.firstSeenFingerprint != fingerprint }
    var rows: [TodoCandidateRow] = []
    let current = items.indices.compactMap { index in
      ledger.candidates.first { $0.snapshotIndex == index }
    }
    for record in current {
      rows.append(row(record, in: ledger, fingerprint: fingerprint, sameSnapshot: sameSnapshot, previousGeneration: previousGeneration))
    }
    for record in ledger.candidates where record.snapshotIndex == nil {
      rows.append(row(record, in: ledger, fingerprint: fingerprint, sameSnapshot: sameSnapshot, previousGeneration: previousGeneration))
    }
    return rows
  }

  private static func row(
    _ record: CandidateRecord,
    in ledger: MeetingCandidateLedger,
    fingerprint: String,
    sameSnapshot: Bool,
    previousGeneration: Bool
  ) -> TodoCandidateRow {
    let hinted = ledger.candidates.contains { $0.suspectedCandidateIDs.contains(record.id) }
    let relation: TodoCandidateRelation
    if record.snapshotIndex == nil {
      if hinted {
        relation = .retainedAsHint
      } else {
        switch record.disposition {
        case .pending: relation = .absentPending
        case .added: relation = .absentAdded
        case .ignored: relation = .absentIgnored
        }
      }
    } else if !record.suspectedCandidateIDs.isEmpty {
      relation = .suspect
    } else if sameSnapshot {
      relation = .sameSnapshot
    } else if record.firstSeenFingerprint == fingerprint {
      relation = .newItem
    } else {
      relation = .strictCarry
    }
    let links = suspectLinks(record, in: ledger)
    let shown = Array(links.prefix(3))
    let introduced = relation == .newItem && previousGeneration
    return TodoCandidateRow(
      id: record.id,
      snapshotIndex: record.snapshotIndex,
      disposition: record.disposition,
      relation: relation,
      newlyIntroduced: introduced,
      suspects: shown,
      hiddenSuspectCount: max(0, links.count - shown.count)
    )
  }

  private static func suspectLinks(
    _ record: CandidateRecord,
    in ledger: MeetingCandidateLedger
  ) -> [TodoSuspect] {
    record.suspectedCandidateIDs.compactMap { id in
      guard let target = ledger.candidates.first(where: { $0.id == id }) else { return nil }
      return TodoSuspect(
        candidateID: id,
        disposition: target.disposition,
        reason: reason(between: record, and: target)
      )
    }
  }

  private static func reason(between source: CandidateRecord, and target: CandidateRecord) -> TodoSuspectReason {
    var best: TodoSuspectReason?
    for left in source.variants {
      for right in target.variants {
        guard let next = suspectReason(left, right) else { continue }
        best = better(best, next)
      }
    }
    return best ?? .similarText
  }

  private static func suspectReason(
    _ left: CandidateVariant,
    _ right: CandidateVariant
  ) -> TodoSuspectReason? {
    if TodoCandidateSignature.strict(left) == TodoCandidateSignature.strict(right) {
      return .ambiguousStrict
    }
    if TodoCandidateSignature.normalizedText(left.text) == TodoCandidateSignature.normalizedText(right.text) {
      return .sameTextDifferentFields
    }
    let score = TodoCandidateSignature.dice(left.text, right.text)
    if let distance = anchorDistance(left.anchor, right.anchor), distance <= 15, score >= 0.4 {
      return .nearAnchor(distance)
    }
    if score >= 0.85,
      TodoCandidateSignature.nonWhitespaceCount(left.text) >= 8,
      TodoCandidateSignature.nonWhitespaceCount(right.text) >= 8
    {
      return .similarText
    }
    return nil
  }
}
