import Foundation

/// 会中出过的问题(2026-10-08,Shaobo「做」)。会中的提示都只在内存里,会议一结束就没了,
/// 会后打开会议看不出会中出过事,也想不到去导出诊断包。这里只记「哪类、什么原因、几次、
/// 什么时候」,散会时写进 meeting.json;不带错误正文、供应商原文或路径。
public struct InMeetingFailureRecord: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    /// 会中总结(快路或慢路)一次请求、解析或写盘失败。
    case liveSummary
    /// 本地速记启动失败或保存失败。
    case liveTranscriber
    /// 麦克风连续 30 秒纯静音。
    case microphoneSilent
    /// 按 App 录系统声音失败,改录全部系统声音也没恢复。
    case systemAudio
  }

  public let kind: Kind
  /// 闭合原因码:会中总结是 `LLMRecoveryAdvice.Cause` 的 rawValue(取不到时是失败分类);
  /// 其余类别为 nil。
  public let cause: String?
  public var count: Int
  public let firstAt: Date
  public var lastAt: Date

  public init(kind: Kind, cause: String?, count: Int = 1, firstAt: Date, lastAt: Date? = nil) {
    self.kind = kind
    self.cause = cause
    self.count = count
    self.firstAt = firstAt
    self.lastAt = lastAt ?? firstAt
  }

  public var title: String {
    switch kind {
    case .liveSummary: return "会中总结未更新"
    case .liveTranscriber: return "本地速记出错"
    case .microphoneSilent: return "麦克风长时间纯静音"
    case .systemAudio: return "系统声音可能没有录上"
    }
  }

  /// 会中总结结果没能写进本机(不是模型的问题)。
  public static let persistenceCause = "persistence"

  /// 一句原因;只有会中总结有,文字与会中提示同源。
  public var causeText: String? {
    guard kind == .liveSummary, let cause else { return nil }
    if cause == Self.persistenceCause { return "会中总结没能写进本机" }
    guard let llmCause = LLMRecoveryAdvice.Cause(rawValue: cause) else { return nil }
    return LLMRecoveryAdvice(
      cause: llmCause, context: LLMFailureContext(feature: .liveSummary, occurredAt: nil),
      httpStatus: nil, providerCode: nil, eventID: nil
    ).message
  }

  /// 把新的一批按「类别 + 原因」并进已有记录:次数相加,时间取首末。
  public static func merging(_ existing: [Self], with new: [Self]) -> [Self] {
    var merged = existing
    for record in new {
      if let index = merged.firstIndex(where: { $0.kind == record.kind && $0.cause == record.cause }) {
        merged[index].count += record.count
        merged[index].lastAt = max(merged[index].lastAt, record.lastAt)
      } else {
        merged.append(record)
      }
    }
    return merged
  }
}

/// 一场会议进行中的累计。只在拥有者的隔离域里用(LiveSummaryFeed / RecordingSession 都在主线程)。
public struct InMeetingFailureLog: Equatable, Sendable {
  public private(set) var records: [InMeetingFailureRecord] = []

  public init() {}

  public mutating func note(_ kind: InMeetingFailureRecord.Kind, cause: String? = nil, at date: Date = Date()) {
    records = InMeetingFailureRecord.merging(
      records, with: [InMeetingFailureRecord(kind: kind, cause: cause, firstAt: date)])
  }

  public mutating func reset() { records = [] }
}
