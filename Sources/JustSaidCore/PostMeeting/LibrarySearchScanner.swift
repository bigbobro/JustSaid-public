import Foundation

/// 全库搜索(08-17 #1「谁说过 X」)的一条命中:某场会议权威转写里的一行发言。
public struct LibrarySearchHit: Equatable, Sendable {
  /// 在 `transcript.md` 里的行序,与 `TranscriptSpeechLine.index` 同源。
  public let lineIndex: Int
  /// 原话行时间戳词面;直落定位时再换算秒数,不在这里解析。
  public let timestamp: String
  /// **结算后**的显示名(全局改名 + 单段覆盖已生效)——与用户点进详情看到的完全一致。
  public let speaker: String
  /// 整行发言正文;关键词加亮与片段截断由 UI 端做,这里不改一个字。
  public let text: String

  public init(lineIndex: Int, timestamp: String, speaker: String, text: String) {
    self.lineIndex = lineIndex
    self.timestamp = timestamp
    self.speaker = speaker
    self.text = text
  }
}

/// 一场会议的命中组。`meetingID` 与会议库列表行同一身份类型(目录标准化路径)。
public struct LibrarySearchResult: Equatable, Sendable {
  public let meetingID: String
  public let hits: [LibrarySearchHit]

  public init(meetingID: String, hits: [LibrarySearchHit]) {
    self.meetingID = meetingID
    self.hits = hits
  }
}

/// 全库搜索的纯匹配层:零索引、零写入。文件枚举/加载与逐场编排在 UI 层 model,
/// Core 只对**已结算**的行做匹配——不在这里再造一层「全库」概念,也不写第二个转写解析器。
public enum LibrarySearchScanner {
  /// 单场会议的行匹配(纯函数,表驱动单测入口)。
  ///
  /// - 大小写不敏感(`String.range(of:options:)` 带 `.caseInsensitive`),CJK 子串直接命中;
  /// - **只匹配发言正文**:「谁说过 X」搜的是说的内容,说话人名与时间戳不参与匹配;
  /// - 同一行出现多次关键词计**一条**命中;
  /// - 空白 query(trim 后空)= 不搜索,返回空;query 不分词,整串子串匹配。
  public static func matches(
    rows: [TranscriptDisplayRow],
    query: String
  ) -> [LibrarySearchHit] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return rows.compactMap { row in
      guard
        case .speech(let line) = row,
        line.text.range(of: trimmed, options: [.caseInsensitive]) != nil
      else {
        return nil
      }
      return LibrarySearchHit(
        lineIndex: line.index,
        timestamp: line.timestamp,
        speaker: line.speaker,
        text: line.text
      )
    }
  }
}
