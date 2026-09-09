import Foundation

extension MeetingPaths {
  /// 中文正式纪要被接受后写入的规范化结构；英文生成不得覆盖。
  public var minutesStructured: URL {
    directory.appendingPathComponent("minutes.json")
  }
}

public struct AnchoredText: Codable, Equatable, Sendable {
  public let text: String
  public let anchor: TranscriptAnchor?
  public let evidence: SummaryEvidenceMark?
  public let revision: SummaryRevisionTrace?

  public init(
    text: String,
    anchor: TranscriptAnchor? = nil,
    evidence: SummaryEvidenceMark? = nil,
    revision: SummaryRevisionTrace? = nil
  ) {
    self.text = text
    self.anchor = anchor
    self.evidence = evidence
    self.revision = revision
  }
}

public enum MeetingConclusionKind: String, Codable, Equatable, Sendable {
  case decision
  case consensus
  case direction
}

public struct MeetingConclusion: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let kind: MeetingConclusionKind
  public let content: AnchoredText

  public init(
    id: UUID = UUID(),
    kind: MeetingConclusionKind = .consensus,
    content: AnchoredText
  ) {
    self.id = id
    self.kind = kind
    self.content = content
  }
}

public struct MeetingDecisionOption: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let speaker: String
  public let proposal: String
  public let anchor: TranscriptAnchor?

  public init(
    id: UUID = UUID(),
    speaker: String,
    proposal: String,
    anchor: TranscriptAnchor? = nil
  ) {
    self.id = id
    self.speaker = speaker
    self.proposal = proposal
    self.anchor = anchor
  }
}

public struct MeetingDecision: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let issue: String
  public let options: [MeetingDecisionOption]
  public let rationale: String
  public let anchor: TranscriptAnchor?

  public init(
    id: UUID = UUID(),
    issue: String,
    options: [MeetingDecisionOption],
    rationale: String,
    anchor: TranscriptAnchor? = nil
  ) {
    self.id = id
    self.issue = issue
    self.options = options
    self.rationale = rationale
    self.anchor = anchor
  }
}

public enum MeetingOpenItemKind: String, Codable, Equatable, Sendable {
  case toVerify
  case disagreement
}

public struct MeetingOpenItem: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let kind: MeetingOpenItemKind
  public let content: AnchoredText
  public let disagreement: SummaryDisagreement?

  public init(
    id: UUID = UUID(),
    kind: MeetingOpenItemKind = .toVerify,
    content: AnchoredText,
    disagreement: SummaryDisagreement? = nil
  ) {
    self.id = id
    self.kind = kind
    self.content = content
    self.disagreement = disagreement
  }
}

/// 一页纸核心区。`semanticTemplate` 是开放字符串：新增会型只增加模型语义模板，
/// 不增加客户端渲染原语。
public struct MeetingSkeleton: Codable, Equatable, Sendable {
  public let semanticTemplate: String?
  public let blocks: [SummaryVisualization]
  public let fallbackPoints: [AnchoredText]

  public init(
    semanticTemplate: String? = nil,
    blocks: [SummaryVisualization],
    fallbackPoints: [AnchoredText] = []
  ) {
    self.semanticTemplate = semanticTemplate
    self.blocks = Array(blocks.prefix(2))
    self.fallbackPoints = fallbackPoints
  }
}

/// 生词收割候选(08-17 #4):纪要生成 pass 顺带报告的「不在名册中的专名」。
/// 只是待确认建议——入册永远由用户在收割箱里手动决定,绝不自动进词典。
public struct HarvestCandidate: Codable, Equatable, Sendable {
  /// 词面(转写里出现的原样拼写)。
  public let text: String
  /// 本场出现次数(模型报告,展示用,不当真值)。
  public let count: Int
  /// 首次出现处,可回跳;模型给不出就为 nil,不编时间。
  public let anchor: TranscriptAnchor?

  public init(text: String, count: Int, anchor: TranscriptAnchor? = nil) {
    self.text = text
    self.count = count
    self.anchor = anchor
  }
}

/// 说话人认名建议(08-17 #7):带证据的身份线索。只是预填建议——改名永远由用户确认,
/// 走既有 speakerNames 通道;无证据不预填(置信度不装)。
public struct SpeakerNameSuggestion: Codable, Equatable, Sendable {
  /// 证据级别:只有自我介绍级(selfIntro)才允许预填;称呼/第三方提及是弱证据。
  public enum Level: String, Codable, Sendable {
    case selfIntro
    case addressed
    case thirdParty
  }

  /// 原始说话人标签(如「发言人 2」),必须是本场转写里的真实标签。
  public let label: String
  /// 建议的真名/称呼。
  public let name: String
  /// 证据引文(转写原话)。
  public let evidenceQuote: String
  /// 证据所在处,可回跳。
  public let anchor: TranscriptAnchor?
  public let level: Level

  public init(
    label: String,
    name: String,
    evidenceQuote: String,
    anchor: TranscriptAnchor? = nil,
    level: Level
  ) {
    self.label = label
    self.name = name
    self.evidenceQuote = evidenceQuote
    self.anchor = anchor
    self.level = level
  }
}

/// `minutes.json` 的唯一规范化 payload。Markdown 仍是用户可编辑正文；本结构只为
/// 原生一页纸、回跳和导出复用同一份已接受的中文纪要数据。
///
/// version 2(08-17 #4+#7):新增两个可选字段 `unknownProperNouns` / `speakerSuggestions`,
/// 由既有纪要生成调用顺带产出(不发独立云调用)。v1 sidecar 缺字段解码为 nil,
/// 渲染路径零变化,完全向后兼容;revert 后旧 decode 忽略多余键,无迁移。
public struct MeetingMinutesDocument: Codable, Equatable, Sendable {
  public let version: Int
  public let suggestedTitle: String?
  public let topicTrail: [String]
  public let coreConclusions: [MeetingConclusion]
  public let keyDiscussions: [AnchoredText]
  public let decisions: [MeetingDecision]
  public let actionItems: [SummaryActionItem]
  public let openQuestions: [MeetingOpenItem]
  public let skeleton: MeetingSkeleton?
  /// 未入册专名候选(收割箱原料)。nil = v1 旧档或本轮没有提取。
  public let unknownProperNouns: [HarvestCandidate]?
  /// 说话人身份证据(认名预填原料)。nil = v1 旧档或本轮没有提取。
  public let speakerSuggestions: [SpeakerNameSuggestion]?

  public init(
    version: Int = 1,
    suggestedTitle: String? = nil,
    topicTrail: [String] = [],
    coreConclusions: [MeetingConclusion],
    keyDiscussions: [AnchoredText],
    decisions: [MeetingDecision],
    actionItems: [SummaryActionItem],
    openQuestions: [MeetingOpenItem],
    skeleton: MeetingSkeleton? = nil,
    unknownProperNouns: [HarvestCandidate]? = nil,
    speakerSuggestions: [SpeakerNameSuggestion]? = nil
  ) {
    self.version = version
    self.suggestedTitle = suggestedTitle
    self.topicTrail = topicTrail
    self.coreConclusions = coreConclusions
    self.keyDiscussions = keyDiscussions
    self.decisions = decisions
    self.actionItems = actionItems
    self.openQuestions = openQuestions
    self.skeleton = skeleton
    self.unknownProperNouns = unknownProperNouns
    self.speakerSuggestions = speakerSuggestions
  }
}
