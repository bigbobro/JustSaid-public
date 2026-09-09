import CryptoKit
import Foundation

/// 核对队列里的一项:从 minutes.json 纯派生,只读不落盘。
public struct CheckQueueItem: Identifiable, Equatable, Sendable {
  /// 稳定身份:有 UUID 的条目用 `uuid:<UUID>`;keyDiscussions 无 UUID,用
  /// `kd:<板块>:<SHA-256(text) 前 16 位>`——纪要未变时重开队列判定不丢。
  public let itemKey: String
  public let category: CheckCategory
  /// 所属板块(核心结论/关键讨论/决定/待办/未决),与纪要五节标题同词面。
  public let sectionLabel: String
  /// 展示原文;决定类拼 问题/决策依据 摘要。
  public let text: String
  public let anchor: TranscriptAnchor?
  public let evidence: SummaryEvidenceMark?
  /// 该条目在纪要里是否已标 [待核]。台账口径:标了 [待核] 的判「错」不计捏造
  /// (标注=诚实,不标=捏造)。
  public let isMarkedToVerify: Bool

  public var id: String { itemKey }

  public init(
    itemKey: String,
    category: CheckCategory,
    sectionLabel: String,
    text: String,
    anchor: TranscriptAnchor? = nil,
    evidence: SummaryEvidenceMark? = nil,
    isMarkedToVerify: Bool = false
  ) {
    self.itemKey = itemKey
    self.category = category
    self.sectionLabel = sectionLabel
    self.text = text
    self.anchor = anchor
    self.evidence = evidence
    self.isMarkedToVerify = isMarkedToVerify
  }
}

/// 队列生成(PRD R1,纯函数):
/// - 入队:全部标 [待核] 的条目;全部决定、全部待办;核心结论/关键讨论/未决中含数字的条目。
/// - 分类:决定/待办 = `keyInfo`,其余 = `number`。
/// - 顺序:按纪要五节顺序,节内按文档顺序;同 key 条目合并保留首条。
public enum CheckQueueBuilder {
  public static let coreConclusionsLabel = "核心结论"
  public static let keyDiscussionsLabel = "关键讨论"
  public static let decisionsLabel = "决定"
  public static let actionItemsLabel = "待办"
  public static let openQuestionsLabel = "未决"

  public static func build(from document: MeetingMinutesDocument) -> [CheckQueueItem] {
    var seenKeys: Set<String> = []
    var queue: [CheckQueueItem] = []

    func append(_ item: CheckQueueItem) {
      guard seenKeys.insert(item.itemKey).inserted else { return }
      queue.append(item)
    }

    for conclusion in document.coreConclusions {
      let marked = conclusion.content.evidence == .toVerify
      guard marked || containsDecimalDigit(conclusion.content.text) else { continue }
      append(
        CheckQueueItem(
          itemKey: "uuid:\(conclusion.id.uuidString)",
          category: .number,
          sectionLabel: coreConclusionsLabel,
          text: conclusion.content.text,
          anchor: conclusion.content.anchor,
          evidence: conclusion.content.evidence,
          isMarkedToVerify: marked
        )
      )
    }

    for discussion in document.keyDiscussions {
      let marked = discussion.evidence == .toVerify
      guard marked || containsDecimalDigit(discussion.text) else { continue }
      append(
        CheckQueueItem(
          itemKey: "kd:\(keyDiscussionsLabel):\(textHashPrefix(discussion.text))",
          category: .number,
          sectionLabel: keyDiscussionsLabel,
          text: discussion.text,
          anchor: discussion.anchor,
          evidence: discussion.evidence,
          isMarkedToVerify: marked
        )
      )
    }

    // 决定与待办全量入队(关键信息单的地盘),一个 decision 一项(MVP 粒度)。
    for decision in document.decisions {
      append(
        CheckQueueItem(
          itemKey: "uuid:\(decision.id.uuidString)",
          category: .keyInfo,
          sectionLabel: decisionsLabel,
          text: "问题：\(decision.issue)；决策依据：\(decision.rationale)",
          anchor: decision.anchor,
          evidence: nil,
          isMarkedToVerify: false
        )
      )
    }

    for action in document.actionItems {
      append(
        CheckQueueItem(
          itemKey: "uuid:\(action.id.uuidString)",
          category: .keyInfo,
          sectionLabel: actionItemsLabel,
          text: action.text,
          anchor: action.recordedAt,
          evidence: action.evidence,
          isMarkedToVerify: action.evidence == .toVerify
        )
      )
    }

    for question in document.openQuestions {
      // openQuestions 的 [待核] 机制是 kind == .toVerify(B1 契约);evidence 兜底同判。
      let marked = question.kind == .toVerify || question.content.evidence == .toVerify
      guard marked || containsDecimalDigit(question.content.text) else { continue }
      append(
        CheckQueueItem(
          itemKey: "uuid:\(question.id.uuidString)",
          category: .number,
          sectionLabel: openQuestionsLabel,
          text: question.content.text,
          anchor: question.content.anchor,
          evidence: question.content.evidence,
          isMarkedToVerify: marked
        )
      )
    }

    return queue
  }

  /// 「含数字」= 文本含任一 Unicode 十进制数字(Nd),含日期/金额/百分比。
  /// 不做更聪明的 NLP——规则要能在单测里一句话说清。
  public static func containsDecimalDigit(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
  }

  /// keyDiscussions 稳定身份的哈希段(SHA-256 前 16 位 hex)。public 供验证程序
  /// 按同一契约推导期望 key。
  public static func textHashPrefix(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
  }
}

/// minutes.json 字节指纹:判定与哪一版纪要对应的唯一凭据。
public enum MinutesFingerprint {
  public static func hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// 汇总口径(队列头部与台账行共用同一份事实):
/// - 捏造数 = number 类、判「错」、且原条目未标 [待核] 的条数;
/// - 漏关键数 = 补漏条数;存疑数 = 判「存疑」的条数。
public struct CheckTally: Equatable, Sendable {
  public let decided: Int
  public let total: Int
  public let fabricated: Int
  public let missed: Int
  public let doubts: Int

  public static func compute(
    record: MeetingCheckRecord,
    queue: [CheckQueueItem]
  ) -> CheckTally {
    let recordsByKey = Dictionary(
      record.items.map { ($0.itemKey, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var decided = 0
    var fabricated = 0
    var doubts = 0
    for item in queue {
      guard let verdict = recordsByKey[item.itemKey]?.verdict else { continue }
      decided += 1
      if verdict == .doubt {
        doubts += 1
      }
      if verdict == .wrong, item.category == .number, !item.isMarkedToVerify {
        fabricated += 1
      }
    }
    return CheckTally(
      decided: decided,
      total: queue.count,
      fabricated: fabricated,
      missed: record.misses.count,
      doubts: doubts
    )
  }

  public init(decided: Int, total: Int, fabricated: Int, missed: Int, doubts: Int) {
    self.decided = decided
    self.total = total
    self.fabricated = fabricated
    self.missed = missed
    self.doubts = doubts
  }
}

/// 台账行上下文:全部来自 meeting.json 与目录名,不 machine 猜。
public struct CheckLedgerContext: Sendable {
  public let directoryName: String
  public let title: String
  public let startedAt: Date
  public let endedAt: Date?
  public let language: MeetingLanguage

  public init(
    directoryName: String,
    title: String,
    startedAt: Date,
    endedAt: Date?,
    language: MeetingLanguage
  ) {
    self.directoryName = directoryName
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.language = language
  }
}

/// 「复制台账行」:输出与 research/acceptance/ledger.md 表头**同构**的一行 markdown。
/// 完整单/三单全绿/修复列不冒填(脚本与人的地盘);空洞数列同属脚本地盘,
/// 只按 design 约定放「存疑 N」备注,由人核对后替换为脚本 hole_count。
public enum CheckLedgerRow {
  /// 与 research/acceptance/ledger.md 台账表头逐字同构;列序即输出列序。
  public static let headerColumns: [String] = [
    "#", "日期", "会议(目录/标题)", "时长", "语言", "捏造数", "漏关键数", "空洞数",
    "数字单", "关键信息单", "完整单", "三单全绿", "场间上线的修复",
  ]

  public static func markdown(
    context: CheckLedgerContext,
    record: MeetingCheckRecord,
    queue: [CheckQueueItem]
  ) -> String {
    let tally = CheckTally.compute(record: record, queue: queue)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    let date = formatter.string(from: context.startedAt)
    let duration: String = {
      guard let endedAt = context.endedAt, endedAt > context.startedAt else { return "" }
      let minutes = Int((endedAt.timeIntervalSince(context.startedAt) / 60).rounded())
      return "\(minutes)min"
    }()
    // 台账口径:语言以耳朵为准——auto 留空让用户填,不 machine 猜。
    let language: String = {
      switch context.language {
      case .chinese: return "zh"
      case .english: return "en"
      case .auto: return ""
      }
    }()
    let doubtsNote = tally.doubts > 0 ? "存疑 \(tally.doubts)" : ""
    let cells: [String] = [
      "",
      date,
      "\(context.directoryName) / \(context.title)",
      duration,
      language,
      "\(tally.fabricated)",
      "\(tally.missed)",
      doubtsNote,
      tally.fabricated == 0 ? "绿" : "红",
      tally.missed == 0 ? "绿" : "红",
      "",
      "",
      "",
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }
}
