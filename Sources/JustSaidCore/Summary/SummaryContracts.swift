import Combine
import Foundation

// MARK: - Rich text runs

/// 富文本片段的样式：加粗实体（数字/术语/人名）或点名高亮（拍板 V9/V10 的语义载体，
/// 颜色之外必须能独立表达语义）。渲染层负责把 `.strong` 映射为加粗、`.callout` 映射为琥珀高亮。
public enum SummaryTextStyle: String, Codable, Equatable, Sendable {
  case plain
  case strong
  case callout
}

public struct SummaryTextRun: Codable, Equatable, Sendable {
  public let text: String
  public let style: SummaryTextStyle

  public init(_ text: String, style: SummaryTextStyle = .plain) {
    self.text = text
    self.style = style
  }
}

/// 会中总结引擎（design.md §4）按 JSON schema 输出的要点/当前行文本：一组带样式的片段，
/// 而非完整 Markdown——避免在客户端引入通用 Markdown 解析器这类没人要求的灵活性。
public struct SummaryRichText: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
  public let runs: [SummaryTextRun]

  public init(runs: [SummaryTextRun]) {
    self.runs = runs
  }

  public init(stringLiteral value: String) {
    runs = [SummaryTextRun(value)]
  }

  public static func plain(_ text: String) -> SummaryRichText {
    SummaryRichText(stringLiteral: text)
  }

  public var plainText: String {
    runs.map(\.text).joined()
  }
}

// MARK: - 溯源（E1 sourceRefs）

public struct SummaryQuotedLine: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let source: AudioSource
  public let timestamp: TimeInterval
  public let text: String

  public init(
    id: UUID = UUID(),
    source: AudioSource,
    timestamp: TimeInterval,
    text: String
  ) {
    self.id = id
    self.source = source
    self.timestamp = timestamp
    self.text = text
  }
}

/// 一个总结要点对应的转写片段（design.md 的 `sourceRefs`，已解析为可直接展示的引文）。
public struct SummarySourceReference: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let sourceLabel: String
  public let rangeLabel: String
  public let lines: [SummaryQuotedLine]
  public let transcriptAnchor: TimeInterval

  public init(
    id: UUID = UUID(),
    sourceLabel: String,
    rangeLabel: String,
    lines: [SummaryQuotedLine],
    transcriptAnchor: TimeInterval
  ) {
    self.id = id
    self.sourceLabel = sourceLabel
    self.rangeLabel = rangeLabel
    self.lines = lines
    self.transcriptAnchor = transcriptAnchor
  }
}

// MARK: - 仪表盘标注、修订、分歧与行动

/// 可点击回跳的转写时间。LLM 与 sidecar 都保留字符串，避免把 `7~10`、`8/31`
/// 一类业务数字误当成浮点数处理；界面需要定位时再读取 `seconds`。
public struct TranscriptAnchor: Codable, Equatable, Sendable {
  public let timecode: String

  public init(timecode: String) {
    self.timecode = timecode
  }

  public init(seconds: TimeInterval) {
    let total = max(0, Int(seconds.rounded(.down)))
    timecode = String(
      format: "%02d:%02d:%02d",
      total / 3_600,
      (total % 3_600) / 60,
      total % 60
    )
  }

  public var seconds: TimeInterval? {
    let components = timecode.split(
      separator: ":",
      omittingEmptySubsequences: false
    )
    guard
      components.count == 2 || components.count == 3,
      components.allSatisfy({ !$0.isEmpty }),
      components.allSatisfy({ $0.allSatisfy(\.isNumber) })
    else {
      return nil
    }
    let values = components.compactMap { Int($0) }
    guard
      values.count == components.count,
      values.allSatisfy({ $0 >= 0 }),
      values.last.map({ $0 < 60 }) == true
    else {
      return nil
    }
    if values.count == 2 {
      return TimeInterval(values[0] * 60 + values[1])
    }
    guard values[1] < 60 else { return nil }
    return TimeInterval(values[0] * 3_600 + values[1] * 60 + values[2])
  }

  private enum CodingKeys: String, CodingKey {
    case timecode
  }

  public init(from decoder: Decoder) throws {
    if let value = try? decoder.singleValueContainer().decode(String.self) {
      timecode = value
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    timecode = try container.decode(String.self, forKey: .timecode)
  }
}

public enum SummaryEvidenceMark: String, Codable, Equatable, Sendable {
  case confirmed
  case toVerify
  case corrected
}

/// D1 的五种视觉标注；`toVerify` 是同一套数据在一页纸里的 `[待核]` 状态。
public enum SummaryAnnotationKind: String, Codable, Equatable, Sendable {
  case highlight
  case disagreement
  case convergence
  case revision
  case inProgress
  case toVerify
}

public struct SummaryAnnotation: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let kind: SummaryAnnotationKind
  public let label: String?
  public let anchor: TranscriptAnchor?

  public init(
    id: UUID = UUID(),
    kind: SummaryAnnotationKind,
    label: String? = nil,
    anchor: TranscriptAnchor? = nil
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.anchor = anchor
  }
}

public struct SummaryRevisionTrace: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let originalText: String
  public let reason: String?
  public let revisedAt: TranscriptAnchor?

  public init(
    id: UUID = UUID(),
    originalText: String,
    reason: String? = nil,
    revisedAt: TranscriptAnchor? = nil
  ) {
    self.id = id
    self.originalText = originalText
    self.reason = reason
    self.revisedAt = revisedAt
  }
}

public struct SummaryDisagreementPosition: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let speaker: String
  public let text: String
  public let anchor: TranscriptAnchor?

  public init(
    id: UUID = UUID(),
    speaker: String,
    text: String,
    anchor: TranscriptAnchor? = nil
  ) {
    self.id = id
    self.speaker = speaker
    self.text = text
    self.anchor = anchor
  }
}

public enum SummaryDisagreementStatus: String, Codable, Equatable, Sendable {
  case open
  case resolved
}

public struct SummaryDisagreement: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let status: SummaryDisagreementStatus
  public let positions: [SummaryDisagreementPosition]
  public let resolution: String?
  public let resolvedAt: TranscriptAnchor?

  public init(
    id: UUID = UUID(),
    status: SummaryDisagreementStatus,
    positions: [SummaryDisagreementPosition],
    resolution: String? = nil,
    resolvedAt: TranscriptAnchor? = nil
  ) {
    self.id = id
    self.status = status
    self.positions = positions
    self.resolution = resolution
    self.resolvedAt = resolvedAt
  }
}

public enum SummaryActionKind: String, Codable, Equatable, Sendable {
  case commitment
  case todo
}

public enum SummaryActionOwnership: String, Codable, Equatable, Sendable {
  case me
  case other
  case unknown
}

public enum SummaryActionOrigin: String, Codable, Equatable, Sendable {
  case automatic
  case manualMark
}

public struct SummaryActionUpdate: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let text: String
  public let anchor: TranscriptAnchor?

  public init(
    id: UUID = UUID(),
    text: String,
    anchor: TranscriptAnchor? = nil
  ) {
    self.id = id
    self.text = text
    self.anchor = anchor
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case text
    case anchor
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    text = try container.decode(String.self, forKey: .text)
    anchor = try container.decodeIfPresent(TranscriptAnchor.self, forKey: .anchor)
  }
}

public struct SummaryActionItem: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let text: String
  public let owner: String?
  public let deadline: String?
  public let topicTitle: String?
  public let kind: SummaryActionKind
  public let ownership: SummaryActionOwnership
  public let recordedAt: TranscriptAnchor?
  public let updates: [SummaryActionUpdate]
  public let evidence: SummaryEvidenceMark?
  public let origin: SummaryActionOrigin

  public init(
    id: UUID = UUID(),
    text: String,
    owner: String? = nil,
    deadline: String? = nil,
    topicTitle: String? = nil,
    kind: SummaryActionKind = .todo,
    ownership: SummaryActionOwnership = .unknown,
    recordedAt: TranscriptAnchor? = nil,
    updates: [SummaryActionUpdate] = [],
    evidence: SummaryEvidenceMark? = nil,
    origin: SummaryActionOrigin = .automatic
  ) {
    self.id = id
    self.text = text
    self.owner = owner
    self.deadline = Self.nonEmpty(deadline)
    self.topicTitle = topicTitle
    self.kind = kind
    self.ownership = ownership
    self.recordedAt = recordedAt
    self.updates = updates
    self.evidence = evidence
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case text
    case owner
    case deadline
    case topicTitle
    case kind
    case ownership
    case recordedAt
    case updates
    case evidence
    case origin
    case anchor
  }

  public init(from decoder: Decoder) throws {
    if let text = try? decoder.singleValueContainer().decode(String.self) {
      id = UUID()
      self.text = text
      owner = nil
      deadline = nil
      topicTitle = nil
      kind = .todo
      ownership = .unknown
      recordedAt = nil
      updates = []
      evidence = nil
      origin = .automatic
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    text = try container.decode(String.self, forKey: .text)
    owner = try container.decodeIfPresent(String.self, forKey: .owner)
    deadline = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .deadline))
    topicTitle = try container.decodeIfPresent(String.self, forKey: .topicTitle)
    kind =
      (try? container.decodeIfPresent(SummaryActionKind.self, forKey: .kind))
      ?? .todo
    ownership =
      (try? container.decodeIfPresent(SummaryActionOwnership.self, forKey: .ownership))
      ?? .unknown
    recordedAt =
      (try? container.decode(TranscriptAnchor.self, forKey: .recordedAt))
      ?? (try? container.decode(TranscriptAnchor.self, forKey: .anchor))
    updates =
      try container.decodeIfPresent([SummaryActionUpdate].self, forKey: .updates) ?? []
    evidence = try? container.decode(SummaryEvidenceMark.self, forKey: .evidence)
    origin =
      (try? container.decodeIfPresent(SummaryActionOrigin.self, forKey: .origin))
      ?? .automatic
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(text, forKey: .text)
    try container.encodeIfPresent(owner, forKey: .owner)
    try container.encodeIfPresent(deadline, forKey: .deadline)
    try container.encodeIfPresent(topicTitle, forKey: .topicTitle)
    try container.encode(kind, forKey: .kind)
    try container.encode(ownership, forKey: .ownership)
    try container.encodeIfPresent(recordedAt, forKey: .recordedAt)
    try container.encode(updates, forKey: .updates)
    try container.encodeIfPresent(evidence, forKey: .evidence)
    try container.encode(origin, forKey: .origin)
  }

  public var displayOwner: String {
    Self.nonEmpty(owner) ?? "责任人待确认"
  }

  public static func mineFirst(_ items: [SummaryActionItem]) -> [SummaryActionItem] {
    items.filter { $0.ownership == .me }
      + items.filter { $0.ownership != .me }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public struct SummaryCurrentTranscriptLine: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let speaker: String
  public let text: String
  public let anchor: TranscriptAnchor?

  public init(
    id: UUID = UUID(),
    speaker: String,
    text: String,
    anchor: TranscriptAnchor? = nil
  ) {
    self.id = id
    self.speaker = speaker
    self.text = text
    self.anchor = anchor
  }
}

/// 右栏「当前区」只承载一眼信息，不复制左侧完整话题卡。
public struct SummaryNowContext: Codable, Equatable, Sendable {
  public let topicTitle: String
  public let speaker: String?
  public let speakingAbout: String?
  public let recentLines: [SummaryCurrentTranscriptLine]

  public init(
    topicTitle: String,
    speaker: String? = nil,
    speakingAbout: String? = nil,
    recentLines: [SummaryCurrentTranscriptLine] = []
  ) {
    self.topicTitle = topicTitle
    self.speaker = speaker
    self.speakingAbout = speakingAbout
    self.recentLines = recentLines
  }
}

// MARK: - 可视化部件（六原语：steps / timeline / table / tree / nums / chain）

public struct SummaryStepItem: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let detail: String
  public let isPrerequisite: Bool
  public let anchor: TranscriptAnchor?
  public let evidence: SummaryEvidenceMark?

  public init(
    id: UUID = UUID(),
    title: String,
    detail: String,
    isPrerequisite: Bool = false,
    anchor: TranscriptAnchor? = nil,
    evidence: SummaryEvidenceMark? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.isPrerequisite = isPrerequisite
    self.anchor = anchor
    self.evidence = evidence
  }
}

public struct SummaryTableRow: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let cells: [SummaryRichText]
  public let anchor: TranscriptAnchor?
  public let evidence: SummaryEvidenceMark?

  public init(
    id: UUID = UUID(),
    cells: [SummaryRichText],
    anchor: TranscriptAnchor? = nil,
    evidence: SummaryEvidenceMark? = nil
  ) {
    self.id = id
    self.cells = cells
    self.anchor = anchor
    self.evidence = evidence
  }
}

public struct SummaryTable: Codable, Equatable, Sendable {
  public let headers: [String]
  public let rows: [SummaryTableRow]

  public init(headers: [String], rows: [SummaryTableRow]) {
    self.headers = headers
    self.rows = rows
  }
}

/// `detail` / `owner` / `interval` / `relationToNext` 都是可选增益,缺席不是残图:
/// 旧 sidecar 里没有这几个键,合成 `Codable` 会解成 nil,历史会议的时间线照旧渲染。
/// `interval` 是区间**原文**,不解析、不推算——只承担「这是区间不是点」一个语义。
public struct SummaryTimelineItem: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let timeLabel: String
  public let title: String
  public let detail: String?
  public let owner: String?
  public let interval: String?
  public let relationToNext: String?
  public let anchor: TranscriptAnchor?
  public let evidence: SummaryEvidenceMark?

  public init(
    id: UUID = UUID(),
    timeLabel: String,
    title: String,
    detail: String? = nil,
    owner: String? = nil,
    interval: String? = nil,
    relationToNext: String? = nil,
    anchor: TranscriptAnchor? = nil,
    evidence: SummaryEvidenceMark? = nil
  ) {
    self.id = id
    self.timeLabel = timeLabel
    self.title = title
    self.detail = detail
    self.owner = owner
    self.interval = interval
    self.relationToNext = relationToNext
    self.anchor = anchor
    self.evidence = evidence
  }
}

public struct SummaryTreeNode: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let detail: String?
  public let children: [SummaryTreeNode]
  public let anchor: TranscriptAnchor?
  public let evidence: SummaryEvidenceMark?

  public init(
    id: UUID = UUID(),
    title: String,
    detail: String? = nil,
    children: [SummaryTreeNode] = [],
    anchor: TranscriptAnchor? = nil,
    evidence: SummaryEvidenceMark? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.children = children
    self.anchor = anchor
    self.evidence = evidence
  }
}

public struct SummaryNumberItem: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  /// 必须是字符串，原样保留 `7~10`、`8/31`、百分比、金额等业务口径。
  public let value: String
  public let label: String
  public let context: String?
  public let anchor: TranscriptAnchor?
  public let evidence: SummaryEvidenceMark?

  public init(
    id: UUID = UUID(),
    value: String,
    label: String,
    context: String? = nil,
    anchor: TranscriptAnchor? = nil,
    evidence: SummaryEvidenceMark? = nil
  ) {
    self.id = id
    self.value = value
    self.label = label
    self.context = context
    self.anchor = anchor
    self.evidence = evidence
  }
}

public struct SummaryChainItem: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let detail: String?
  public let relationToNext: String?
  public let anchor: TranscriptAnchor?
  public let evidence: SummaryEvidenceMark?

  public init(
    id: UUID = UUID(),
    title: String,
    detail: String? = nil,
    relationToNext: String? = nil,
    anchor: TranscriptAnchor? = nil,
    evidence: SummaryEvidenceMark? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.relationToNext = relationToNext
    self.anchor = anchor
    self.evidence = evidence
  }
}

/// flow 原语的节点（第七种可视化：唯一节点 + 显式有向边）。
///
/// **两个 id 不是一回事，不许混用**：`id` 是 SwiftUI 用的 UUID（与其余六原语同规格），
/// `nodeID` 是模型在载荷里给的字符串标识，边靠它引用节点。归一化判重与边引用命中
/// 判定都只看 `nodeID`。
public struct SummaryFlowNode: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let nodeID: String
  public let title: String
  public let detail: String?
  public let anchor: TranscriptAnchor?
  public let evidence: SummaryEvidenceMark?

  public init(
    id: UUID = UUID(),
    nodeID: String,
    title: String,
    detail: String? = nil,
    anchor: TranscriptAnchor? = nil,
    evidence: SummaryEvidenceMark? = nil
  ) {
    self.id = id
    self.nodeID = nodeID
    self.title = title
    self.detail = detail
    self.anchor = anchor
    self.evidence = evidence
  }
}

/// flow 原语的有向边。`from` / `to` 引用 `SummaryFlowNode.nodeID`。
///
/// `feedbackMarked` 只是**模型的提示**：渲染端不得依赖它判定反向边，最终由几何
/// 权威决定（层号 ≤ 源层号即按反向边画）。模型标漏、标反都真实发生过。
public struct SummaryFlowEdge: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let from: String
  public let to: String
  public let label: String?
  public let feedbackMarked: Bool

  public init(
    id: UUID = UUID(),
    from: String,
    to: String,
    label: String? = nil,
    feedbackMarked: Bool = false
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.label = label
    self.feedbackMarked = feedbackMarked
  }
}

public enum SummaryVisualization: Identifiable, Codable, Equatable, Sendable {
  case steps(title: String, items: [SummaryStepItem])
  case table(title: String, table: SummaryTable)
  case timeline(title: String, items: [SummaryTimelineItem])
  case tree(title: String, roots: [SummaryTreeNode])
  case nums(title: String, items: [SummaryNumberItem])
  case chain(title: String, items: [SummaryChainItem])
  /// 第七种：唯一节点 + 显式有向边。表达六原语画不出的分支后汇合、多对多共享
  /// 依赖与反馈回路。画不出来时归一化层已经把它降级成 `.table` 三列边表，
  /// 所以 UI 拿到 `.flow` 就意味着这张图通过了全部契约校验。
  case flow(title: String, nodes: [SummaryFlowNode], edges: [SummaryFlowEdge])

  public var id: String {
    switch self {
    case .steps(let title, _):
      return "steps-\(title)"
    case .table(let title, _):
      return "table-\(title)"
    case .timeline(let title, _):
      return "timeline-\(title)"
    case .tree(let title, _):
      return "tree-\(title)"
    case .nums(let title, _):
      return "nums-\(title)"
    case .chain(let title, _):
      return "chain-\(title)"
    case .flow(let title, _, _):
      return "flow-\(title)"
    }
  }

  public var title: String {
    switch self {
    case .steps(let title, _), .table(let title, _), .timeline(let title, _),
      .tree(let title, _), .nums(let title, _), .chain(let title, _):
      return title
    case .flow(let title, _, _):
      return title
    }
  }

  public var badgeLabel: String {
    switch self {
    case .steps:
      return "steps"
    case .table:
      return "table"
    case .timeline:
      return "timeline"
    case .tree:
      return "tree"
    case .nums:
      return "nums"
    case .chain:
      return "chain"
    case .flow:
      return "flow"
    }
  }
}

// MARK: - 话题块与「当前」行

public struct SummaryBullet: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let text: SummaryRichText
  public let sourceRef: SummarySourceReference?
  public let annotations: [SummaryAnnotation]
  public let revision: SummaryRevisionTrace?
  public let disagreement: SummaryDisagreement?

  public init(
    id: UUID = UUID(),
    text: SummaryRichText,
    sourceRef: SummarySourceReference? = nil,
    annotations: [SummaryAnnotation] = [],
    revision: SummaryRevisionTrace? = nil,
    disagreement: SummaryDisagreement? = nil
  ) {
    self.id = id
    self.text = text
    self.sourceRef = sourceRef
    self.annotations = annotations
    self.revision = revision
    self.disagreement = disagreement
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case text
    case sourceRef
    case annotations
    case revision
    case disagreement
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    text = try container.decode(SummaryRichText.self, forKey: .text)
    sourceRef = try container.decodeIfPresent(SummarySourceReference.self, forKey: .sourceRef)
    annotations =
      try container.decodeIfPresent([SummaryAnnotation].self, forKey: .annotations) ?? []
    revision = try container.decodeIfPresent(SummaryRevisionTrace.self, forKey: .revision)
    disagreement =
      try container.decodeIfPresent(SummaryDisagreement.self, forKey: .disagreement)
  }
}

/// 历史区（顺序时间线）里的一个话题块——design.md 慢通道输出的 `blocks[]` 元素。
/// 章节配色按其在 `topics` 数组中的位置循环取色（视图职责），不在数据里重复存一份。
public struct SummaryTopic: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let timeRangeLabel: String
  public let bullets: [SummaryBullet]
  public let visualizations: [SummaryVisualization]
  public let annotations: [SummaryAnnotation]
  public let revisions: [SummaryRevisionTrace]
  public let disagreements: [SummaryDisagreement]
  public let actionItems: [SummaryActionItem]

  public init(
    id: UUID = UUID(),
    title: String,
    timeRangeLabel: String,
    bullets: [SummaryBullet],
    visualizations: [SummaryVisualization] = [],
    annotations: [SummaryAnnotation] = [],
    revisions: [SummaryRevisionTrace] = [],
    disagreements: [SummaryDisagreement] = [],
    actionItems: [SummaryActionItem] = []
  ) {
    self.id = id
    self.title = title
    self.timeRangeLabel = timeRangeLabel
    self.bullets = bullets
    self.visualizations = visualizations
    self.annotations = annotations
    self.revisions = revisions
    self.disagreements = disagreements
    self.actionItems = actionItems
  }

  public var hasVisualization: Bool { !visualizations.isEmpty }
  public var isInProgress: Bool {
    annotations.contains { $0.kind == .inProgress }
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case timeRangeLabel
    case bullets
    case visualizations
    case annotations
    case revisions
    case disagreements
    case actionItems
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    title = try container.decode(String.self, forKey: .title)
    timeRangeLabel = try container.decode(String.self, forKey: .timeRangeLabel)
    bullets = try container.decodeIfPresent([SummaryBullet].self, forKey: .bullets) ?? []
    visualizations =
      try container.decodeIfPresent([SummaryVisualization].self, forKey: .visualizations) ?? []
    annotations =
      try container.decodeIfPresent([SummaryAnnotation].self, forKey: .annotations) ?? []
    revisions =
      try container.decodeIfPresent([SummaryRevisionTrace].self, forKey: .revisions) ?? []
    disagreements =
      try container.decodeIfPresent([SummaryDisagreement].self, forKey: .disagreements) ?? []
    actionItems =
      try container.decodeIfPresent([SummaryActionItem].self, forKey: .actionItems) ?? []
  }
}

public struct SummaryNowLine: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let text: SummaryRichText

  public init(id: UUID = UUID(), text: SummaryRichText) {
    self.id = id
    self.text = text
  }
}

/// 「当前正在聊」专区快照——design.md 快通道输出，末端标注覆盖到的时间点（拍板 B1）。
public struct SummaryNowState: Equatable, Sendable {
  public let coveredUntilLabel: String
  /// Meeting-relative coverage boundary used for transcript jumps. The formatted label is a
  /// wall-clock display and must never be parsed back into elapsed time.
  public let coveredUntil: TimeInterval?
  public let lines: [SummaryNowLine]
  public let context: SummaryNowContext?
  public let updatedAt: Date

  public init(
    coveredUntilLabel: String,
    coveredUntil: TimeInterval? = nil,
    lines: [SummaryNowLine],
    context: SummaryNowContext? = nil,
    updatedAt: Date = Date()
  ) {
    self.coveredUntilLabel = coveredUntilLabel
    self.coveredUntil = coveredUntil
    self.lines = lines
    self.context = context
    self.updatedAt = updatedAt
  }

  public var hasCurrentContent: Bool {
    !lines.isEmpty || context != nil
  }

  public var sourceAnchorSeconds: TimeInterval? {
    context?.recentLines.reversed().compactMap { $0.anchor?.seconds }.first
      ?? coveredUntil
  }

  public static let empty = SummaryNowState(coveredUntilLabel: "--:--", lines: [])
}

/// 降级说的是**哪一路**。会中总结的快慢两条 lane 完全独立，把它们 OR 成一个布尔，
/// 健康的一路就会被连坐（08-10 实测：慢通道已把话题推进到 07:35，横幅仍在喊
/// 「最后更新 00:32」——那是快通道自己的时间戳）。
public enum SummaryDegradationSource: String, Equatable, Sendable {
  /// 快通道：「当前正在聊」与最近原话。
  case liveNow = "live-now"
  /// 慢通道：整理区的话题块与「替你记」。
  case organizer
  /// 会后处理。它另有专属横幅，这里只负责说明与重试入口。
  case postMeeting = "post-meeting"

  public var displayName: String {
    switch self {
    case .liveNow: return "「当前正在聊」"
    case .organizer: return "话题整理"
    case .postMeeting: return "会后处理"
    }
  }
}

/// 失败原因的闭合枚举。界面只要能回答一句话：该去改配置，还是等网络。
/// 原来这些类别只写进 OSLog，`unavailable` 只带一个时间标签，用户唯一的排查手段
/// 就是换模型试错（08-10 实测浪费约 30 分钟）。
public enum SummaryDegradationCause: String, Equatable, Sendable {
  case configuration
  case timeout
  case service
  case invalidResponse = "invalid-response"
  case persistence
  case unknown

  public var displayText: String {
    switch self {
    case .configuration: return "渠道或模型配置有问题，需要到设置里改"
    case .timeout: return "模型迟迟没有响应"
    case .service: return "模型服务暂时不可用（网络或服务端）"
    case .invalidResponse: return "模型返回的内容不合约定格式"
    case .persistence: return "本地写盘失败"
    case .unknown: return "未知错误"
    }
  }

  /// 整理区表头那颗 chip 只有一行的位置，用短句。
  public var shortText: String {
    switch self {
    case .configuration: return "配置有问题"
    case .timeout: return "没有响应"
    case .service: return "服务不可用"
    case .invalidResponse: return "输出不合规"
    case .persistence: return "写盘失败"
    case .unknown: return "未知错误"
    }
  }
}

/// 这一路此刻在不在重试。原来界面上没有这个维度：重试正在飞和什么都没发生
/// 长得一模一样，用户点完只能盯着不动的横幅（08-10 实测）。
public enum SummaryRetryState: String, Equatable, Sendable {
  /// 等下一次固定节拍。
  case waiting
  /// 已排一次提前的自动重试。
  case autoRetryScheduled = "auto-retry-scheduled"
  /// 用户点过「重试」，这一轮马上开始。
  case manualRetryQueued = "manual-retry-queued"
  /// 本轮正在飞。
  case retrying

  /// `nil` = 这一态没什么可说的。`waiting` 刻意不给文案:会中它是"等下一轮"、
  /// 散会后是"再也不会有下一轮"、会后管线压根没有节拍——一句话说不成真话,
  /// 就不要说(能不能重试由那颗按钮在不在回答)。
  public var displayText: String? {
    switch self {
    case .waiting: return nil
    case .autoRetryScheduled: return "即将自动重试"
    case .manualRetryQueued: return "已排队重试"
    case .retrying: return "正在重试"
    }
  }
}

/// 一路的降级实况。时间戳只能是**这一路自己的**覆盖进度——横幅上的标签与它所声称的
/// 对象必须是同一个，否则就会出现「标签说 00:32、下方内容已到 07:35」。
public struct SummaryDegradationIssue: Equatable, Sendable {
  public let source: SummaryDegradationSource
  public let cause: SummaryDegradationCause
  /// 这一路最后一次成功覆盖到哪里；`nil` = 还没有成功过。
  public let lastUpdatedLabel: String?
  /// 会后处理带原文诊断；快慢两条 lane 一律 nil（恢复日志只允许闭合枚举）。
  public let detail: String?
  public let retryState: SummaryRetryState
  /// 连续失败次数，成功即清零。用来把「一直失败」与「抖了一下」分开。
  public let consecutiveFailures: Int

  public init(
    source: SummaryDegradationSource,
    cause: SummaryDegradationCause,
    lastUpdatedLabel: String?,
    detail: String? = nil,
    retryState: SummaryRetryState,
    consecutiveFailures: Int
  ) {
    self.source = source
    self.cause = cause
    self.lastUpdatedLabel = lastUpdatedLabel
    self.detail = detail
    self.retryState = retryState
    self.consecutiveFailures = consecutiveFailures
  }

  public var text: String {
    var parts = ["\(source.displayName)暂不可用"]
    parts.append(detail ?? cause.displayText)
    if let lastUpdatedLabel {
      parts.append("上次更新 \(lastUpdatedLabel)")
    } else if source != .postMeeting {
      parts.append("本场还没有过成果")
    }
    if let retryText = retryState.displayText {
      parts.append(retryText)
    }
    if consecutiveFailures >= SummaryDegradation.escalationThreshold {
      parts.append("已连续失败 \(consecutiveFailures) 次，不像是临时抖动")
    }
    return parts.joined(separator: " · ")
  }
}

/// 降级横幅的全部依据。哪几路挂了、各自的原因与时间戳、现在是不是在重试，
/// 以及**这颗「重试」按下去会不会真的发生事情**——散会后两条 lane 都已取消，
/// 那颗按钮此前仍挂着，按下去可证明毫无作用（08-10 D3）。
public struct SummaryDegradation: Equatable, Sendable {
  /// 连续失败到这个次数就升级提示，与单次抖动区分开。
  public static let escalationThreshold = 3

  public let issues: [SummaryDegradationIssue]
  /// 整理区活文档真实覆盖到哪里。快慢两条 lane 都会往话题卡上写，所以它取两者的较大值：
  /// 快通道挂掉时它仍随慢通道推进，健康的一路不许被标成「停在 00:32」。
  public let organizerCoveredLabel: String
  /// 现在点「重试」是否真的会发生事情。false 时界面**不得**画那颗按钮。
  public let canRetry: Bool

  public init(
    issues: [SummaryDegradationIssue],
    organizerCoveredLabel: String,
    canRetry: Bool
  ) {
    self.issues = issues
    self.organizerCoveredLabel = organizerCoveredLabel
    self.canRetry = canRetry
  }

  /// 有重试正在飞或已排队。此时「重试」按不出新东西，界面改说「重试中…」。
  public var isRetryInFlight: Bool {
    issues.contains { $0.retryState == .retrying || $0.retryState == .manualRetryQueued }
  }

  /// 连续失败已达阈值：不是抖动，值得提示用户去动手。
  public var isPersistent: Bool {
    issues.contains { $0.consecutiveFailures >= Self.escalationThreshold }
  }

  public var affectsOrganizer: Bool {
    issues.contains { $0.source == .organizer }
  }

  /// 降级细带的正文。一路一句，各说各的时间戳。
  public var bannerText: String {
    issues.map(\.text).joined(separator: "\n")
  }

  /// 整理区表头那颗 chip 的文字。它说的是**整理区自己**的进度：
  /// 快通道失败不许把这里说成「不可用」，但也不能与健康态长得一模一样。
  public var organizerStatusText: String {
    if let organizerIssue = issues.first(where: { $0.source == .organizer }) {
      return "整理停在 \(organizerCoveredLabel) · \(organizerIssue.cause.shortText)"
    }
    let others = issues.map(\.source.displayName).joined(separator: "、")
    return "已跟进到 \(organizerCoveredLabel) · \(others)降级"
  }
}

/// 三态状态语言（拍板 V8）：生成中 / 运行中 / 静默；`unavailable` 对应 §6 失败态
/// （云端失败降级，历史卡片保留不清空）。这是引擎运行状态，不落盘，因此不需要 Codable。
public enum SummaryEngineStatus: Equatable, Sendable {
  case generatingNewTopic
  case running
  case idle(lastFollowedLabel: String)
  /// 速记长时间不再推进 = 录音这一侧断了,会中总结在原地停着等。
  /// 它排在 `.unavailable` 前面:总结降级是下游现象,用户要先知道上游断了
  /// (2026-09-04 事故里屏幕上只说得出「降级」,说不出「已经 8 小时没录到东西」)。
  case recordingInterrupted(lastFollowedLabel: String)
  case unavailable(SummaryDegradation)

  /// 整理区表头 chip 的文字；`nil` 表示这一态渲染的是「AI 分析中」呼吸点。
  /// `.idle` 与 `.unavailable` 必须落在**不同的句子**上——两者曾渲染成同一句
  /// 「已跟进到 X」，健康态与降级态因此长得一样（08-10 D1）。
  public var organizerStatusText: String? {
    switch self {
    case .running, .generatingNewTopic:
      return nil
    case .idle(let label):
      return "已跟进到 \(label)"
    case .recordingInterrupted(let label):
      return "录音已中断 · 已跟进到 \(label)"
    case .unavailable(let degradation):
      return degradation.organizerStatusText
    }
  }

  public var isDegraded: Bool {
    switch self {
    case .unavailable, .recordingInterrupted:
      return true
    case .running, .generatingNewTopic, .idle:
      return false
    }
  }

  /// chip 的运行时标识。三条互斥:健康 / 录音已中断 / 引擎降级。
  public var engineChipIdentifier: String {
    switch self {
    case .recordingInterrupted:
      return "dashboard.engine-chip.recording-interrupted"
    case .unavailable:
      return "dashboard.engine-chip.degraded"
    case .running, .generatingNewTopic, .idle:
      return "dashboard.engine-chip.idle"
    }
  }
}

/// 会后处理(云端精转 → 权威转写 → 完整版纪要)的进行态。
/// 会前只有「成功提示」与「失败原因」两个字段,界面因此无法表达「正在跑」——
/// 用户点完「结束会议」看不到任何后续动静(2026-07-29 实测反馈)。
///
/// `running` 的 `detail` 是瞬时进度文案(阶段名 / 字数 / 已用时长),由真实
/// `PostMeetingProgress` 事件驱动;无事件时为 nil,界面不得自行编造阶段名。
public enum PostMeetingStage: Equatable, Sendable {
  case none
  case running(detail: String?)
  case finished(notice: String)
  case failed(reason: String)

  /// 无进度细节的「进行中」。比较是否在跑请用 `isRunning`,不要用 `== .running`
  /// (detail 非 nil 时 `== .running` 为 false)。
  public static var running: PostMeetingStage { .running(detail: nil) }

  public var isRunning: Bool {
    if case .running = self { return true }
    return false
  }

  public var runningDetail: String? {
    if case .running(let detail) = self { return detail }
    return nil
  }
}

public enum SummaryFeedError: LocalizedError, Sendable {
  case markUnavailable

  public var errorDescription: String? {
    "当前总结数据源不支持标记提炼"
  }
}

/// 会中总结数据源契约（design.md §4 的“会中总结引擎”客户端视角）。真实引擎（步骤 4）与
/// 本阶段的预览数据源（`PreviewSummaryFeed`）都实现该协议；视图对其做泛型引用，
/// 替换实现即可接入真实引擎，无需改动界面代码。
@MainActor
public protocol SummaryFeed: ObservableObject {
  var topics: [SummaryTopic] { get }
  var now: SummaryNowState { get }
  var engineStatus: SummaryEngineStatus { get }
  var postMeetingNotice: String? { get }
  var postMeetingStage: PostMeetingStage { get }
  /// 当前会后横幅指的是哪一场会议(标准化目录)。「查看本场会议」必须在**渲染横幅时**
  /// 捕获它:点下去那一刻再读 `RecordingSession.currentMeetingDirectory`,拿到的可能
  /// 已经是新开的下一场。
  var postMeetingDirectory: URL? { get }
  var actionItems: [SummaryActionItem] { get }

  /// 会议开始/结束的生命周期钩子，与 `RecordingSession.start()/stop()` 同步调用；
  /// 真实引擎据此接入速记流，预览数据源据此重置/播放示例内容。
  func start()
  func stop()
  func stop(runPostMeeting: Bool)
  /// 废弃本场会议(T15):停引擎、不落速记纪要、不排队会后处理。
  func abandon()
  func startPostMeetingProcessing(for meetingDirectory: URL?)
  func discardPostMeetingProcessing(for meetingDirectory: URL?)

  /// 总结不可用时的“重试”动作。
  func retry()

  /// 只接数据源、不改变视觉：工作台把当前会议目录和速记快照送入真实引擎。
  func attach(meetingDirectory: URL?)
  func ingest(_ segments: [TranscriptSegment])

  /// 用户点「查看本场会议」:成功提示当场收掉,不等展示门那 5 秒。
  /// 运行中与失败态不收——那两种要一直看得见。
  func dismissPostMeetingNotice()

  /// 「标记」使用最近 60–90 秒速记做一次轻量提炼；重试复用同一个 `id`。
  func distillMark(
    id: UUID,
    from start: TimeInterval,
    to end: TimeInterval
  ) async throws -> String
}

extension SummaryFeed {
  public var postMeetingNotice: String? { nil }
  public var postMeetingStage: PostMeetingStage { .none }
  public var postMeetingDirectory: URL? { nil }
  public var actionItems: [SummaryActionItem] { [] }

  public func dismissPostMeetingNotice() {}

  public func stop(runPostMeeting: Bool) {
    stop()
  }

  public func abandon() {
    stop(runPostMeeting: false)
  }

  public func startPostMeetingProcessing(for meetingDirectory: URL?) {}
  public func discardPostMeetingProcessing(for meetingDirectory: URL?) {}

  public func attach(meetingDirectory: URL?) {}
  public func ingest(_ segments: [TranscriptSegment]) {}

  public func distillMark(
    id: UUID,
    from start: TimeInterval,
    to end: TimeInterval
  ) async throws -> String {
    throw SummaryFeedError.markUnavailable
  }
}
