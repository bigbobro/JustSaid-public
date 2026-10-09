import Foundation

/// 本次提问带上的一场历史会议(同客户、同项目)。`index` 是提示词里的编号:M1 是最近的一场。
public struct MeetingQAPastMeeting: Hashable, Sendable {
  public let index: Int
  public let meetingID: UUID
  public let directory: URL
  public let title: String
  public let startedAt: Date

  public init(index: Int, meetingID: UUID, directory: URL, title: String, startedAt: Date) {
    self.index = index
    self.meetingID = meetingID
    self.directory = directory
    self.title = title
    self.startedAt = startedAt
  }
}

/// 回答末尾「来源：」行里的一个标记,已按本次提供的上下文校验过。
public enum MeetingQASource: Hashable, Sendable {
  /// 本场转写里的时刻(会议计时,秒)。
  case thisMeeting(TimeInterval)
  case pastMeeting(MeetingQAPastMeeting)
  case generalKnowledge

  /// 写进 `qa.jsonl` 的形式,与提示词约定的标记同形。
  public var token: String {
    switch self {
    case .thisMeeting(let seconds):
      return "本场 \(MeetingQATimeLabel.format(seconds))"
    case .pastMeeting(let meeting):
      return "会议 M\(meeting.index)"
    case .generalKnowledge:
      return "通用知识"
    }
  }
}

/// 一轮已经答完的问答,只用于下一问理解指代。
public struct MeetingQAExchange: Equatable, Sendable {
  public let question: String
  public let answer: String

  public init(question: String, answer: String) {
    self.question = question
    self.answer = answer
  }
}

/// 一场会一段问答。「新问题」之后,之前的问答不再随提问发出。
public struct MeetingQASession: Sendable {
  /// 每次提问带上的最近轮数。
  public static let historyWindow = 5

  public private(set) var exchangesSinceReset: [MeetingQAExchange] = []

  public init() {}

  public var recentHistory: [MeetingQAExchange] {
    Array(exchangesSinceReset.suffix(Self.historyWindow))
  }

  public mutating func record(_ exchange: MeetingQAExchange) {
    exchangesSinceReset.append(exchange)
  }

  public mutating func reset() {
    exchangesSinceReset.removeAll()
  }
}

/// 会议计时的显示形式:不到一小时 `mm:ss`,满一小时 `h:mm:ss`。提示词里的转写行与来源标记同一口径。
public enum MeetingQATimeLabel {
  public static func format(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
  }

  /// 接受 `m:ss`、`mm:ss`、`h:mm:ss`;分、秒超过 59 或不是数字时返回 nil。
  public static func parse(_ text: String) -> TimeInterval? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(
      separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3 else { return nil }
    var values: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.count <= 2, let value = Int(part), value >= 0 else { return nil }
      values.append(value)
    }
    if values.count == 2 {
      guard values[1] < 60 else { return nil }
      return TimeInterval(values[0] * 60 + values[1])
    }
    guard values[1] < 60, values[2] < 60 else { return nil }
    return TimeInterval(values[0] * 3_600 + values[1] * 60 + values[2])
  }
}

extension MeetingPaths {
  /// 会中问答记录(10-09 实验性)。会议包导出按名单挑文件,不在名单里;纪要、笔记、待办都不读它。
  public var meetingQALog: URL { directory.appendingPathComponent("qa.jsonl") }
}

/// `qa.jsonl` 的一行。只追加,不改写。
public struct MeetingQALogEntry: Codable, Equatable, Sendable {
  public static let turnKind = "turn"
  public static let resetKind = "reset"

  public let kind: String
  /// 提问时的会议计时(秒)。
  public let askedAt: TimeInterval?
  /// 「新问题」分隔时的会议计时(秒)。
  public let at: TimeInterval?
  public let question: String?
  public let answer: String?
  public let sources: [String]?
  public let model: String?
  /// nil = 答完;`CloudUsageRecord.failedOutcome` = 没答完。
  public let outcome: String?
  public let recordedAt: Date

  public static func turn(
    askedAt: TimeInterval, question: String, answer: String, sources: [MeetingQASource],
    model: String, failed: Bool, recordedAt: Date = Date()
  ) -> Self {
    Self(
      kind: turnKind, askedAt: askedAt, at: nil, question: question, answer: answer,
      sources: sources.map(\.token), model: model,
      outcome: failed ? CloudUsageRecord.failedOutcome : nil, recordedAt: recordedAt)
  }

  public static func reset(at: TimeInterval, recordedAt: Date = Date()) -> Self {
    Self(
      kind: resetKind, askedAt: nil, at: at, question: nil, answer: nil, sources: nil, model: nil,
      outcome: nil, recordedAt: recordedAt)
  }
}

public enum MeetingQALog {
  private static let lock = NSLock()

  public static func append(_ entry: MeetingQALogEntry, to paths: MeetingPaths) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var line = try encoder.encode(entry)
    line.append(0x0A)
    lock.lock()
    defer { lock.unlock() }
    let url = paths.meetingQALog
    if !FileManager.default.fileExists(atPath: url.path) {
      try line.write(to: url, options: .atomic)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }
}
