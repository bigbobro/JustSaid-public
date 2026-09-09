import Foundation

extension MeetingPaths {
  /// 核对工作台判定 sidecar(08-17 R-a)。纯新增文件:旧版本 app 不认识它也不受影响,
  /// 删除即清空判定,不伤任何既有产物。
  public var check: URL {
    directory.appendingPathComponent("check.json")
  }
}

/// 核对分类,对齐台账两条曲线(research/acceptance/ledger.md):
/// `keyInfo` = 决定/待办(关键信息单),`number` = 其余入队条目(数字单)。
public enum CheckCategory: String, Codable, Equatable, Sendable {
  case number
  case keyInfo
}

/// 三键判定。判定永远是用户做的,产品只搬运和记账。
public enum CheckVerdict: String, Codable, Equatable, Sendable {
  case correct
  case wrong
  case doubt
}

/// 一条纪要条目的判定记录。`itemKey` 与 `CheckQueueItem.itemKey` 同一套稳定身份。
public struct CheckItemRecord: Codable, Equatable, Sendable {
  public let itemKey: String
  public let category: CheckCategory
  public var verdict: CheckVerdict?
  public var note: String?
  public var decidedAt: Date?
  /// 判定时的条目原文快照与板块名:只服务纪要再生后「对应旧版纪要」的只读展示——
  /// 旧 minutes.json 已被覆盖,不存快照旧判定就只剩一串不可读的 key。
  /// 指纹匹配时一律以现算队列为准,不读这两个字段。
  public var text: String?
  public var sectionLabel: String?

  public init(
    itemKey: String,
    category: CheckCategory,
    verdict: CheckVerdict? = nil,
    note: String? = nil,
    decidedAt: Date? = nil,
    text: String? = nil,
    sectionLabel: String? = nil
  ) {
    self.itemKey = itemKey
    self.category = category
    self.verdict = verdict
    self.note = note
    self.decidedAt = decidedAt
    self.text = text
    self.sectionLabel = sectionLabel
  }
}

/// 补漏登记:「JustSaid 漏了」的条目,用户手动添加。时间戳是用户填的,可选——不发明时间。
public struct CheckMissEntry: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var text: String
  public var atSeconds: Double?
  public var addedAt: Date

  public init(
    id: UUID = UUID(),
    text: String,
    atSeconds: Double? = nil,
    addedAt: Date = Date()
  ) {
    self.id = id
    self.text = text
    self.atSeconds = atSeconds
    self.addedAt = addedAt
  }
}

/// `check.json` 的唯一 payload。判定只写这里,绝不改写 minutes.md / minutes.json /
/// transcript.md(R3 红线)。
public struct MeetingCheckRecord: Codable, Equatable, Sendable {
  public var version: Int
  /// 判定所对应 minutes.json 的字节 SHA-256。纪要再生后指纹不符 → 旧判定标
  /// 「对应旧版纪要」留存展示(`supersededItems`),不静默丢弃,不自动搬移。
  public var minutesFingerprint: String
  public var items: [CheckItemRecord]
  public var misses: [CheckMissEntry]
  /// 纪要再生后被替换下来的旧判定(靠 `text`/`sectionLabel` 快照可读),只读留存。
  public var supersededItems: [CheckItemRecord]?

  public init(
    version: Int = 1,
    minutesFingerprint: String,
    items: [CheckItemRecord] = [],
    misses: [CheckMissEntry] = [],
    supersededItems: [CheckItemRecord]? = nil
  ) {
    self.version = version
    self.minutesFingerprint = minutesFingerprint
    self.items = items
    self.misses = misses
    self.supersededItems = supersededItems
  }
}

extension MeetingStore {
  /// 读核对记录:文件不存在或损坏都返回 nil——核对是纯附加能力,坏 sidecar 不该
  /// 挡住纪要页本身。
  public func loadCheckRecord(at paths: MeetingPaths) -> MeetingCheckRecord? {
    guard let data = try? Data(contentsOf: paths.check) else { return nil }
    return try? StructuredArtifactCodec.decode(MeetingCheckRecord.self, from: data)
  }

  /// 写核对记录:走 StructuredArtifactCodec(继承非法浮点与文本清理边界)+ 原子写,
  /// 模式照抄 minutes.json 的写路径。只写 check.json,不碰任何既有产物。
  public func saveCheckRecord(
    _ record: MeetingCheckRecord,
    at paths: MeetingPaths
  ) throws {
    let data = try StructuredArtifactCodec.encode(record)
    try data.write(to: paths.check, options: .atomic)
  }
}
