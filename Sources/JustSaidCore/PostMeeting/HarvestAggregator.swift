import Foundation

/// 收割箱一行:同一词面跨会议合并后的候选。
public struct HarvestBoxItem: Identifiable, Equatable, Sendable {
  /// 展示词面(取首次出现的拼写)。
  public let text: String
  /// 全库合计出现次数(模型报告值求和,展示用,不当真值)。
  public let totalCount: Int
  /// 出现过该词面的会议数。
  public let meetingCount: Int

  public var id: String { text }

  public init(text: String, totalCount: Int, meetingCount: Int) {
    self.text = text
    self.totalCount = totalCount
    self.meetingCount = meetingCount
  }
}

/// 收割箱聚合(08-17 #4):全库 minutes.json 的 unknownProperNouns
/// − 名册词面 − 忽略表,按词面(大小写折叠)合并。纯函数,验证程序直接断言。
///
/// 名册过滤在这里**再做一遍**是刻意的:生成侧 normalize 已过滤过一次,但入册发生在
/// 生成之后——昨天收进 minutes.json 的候选今天可能已被用户入册,聚合时必须按
/// 当前名册现算,否则已在册的词还赖在箱里。
public enum HarvestAggregator {
  public static func aggregate(
    candidatesByMeeting: [[HarvestCandidate]],
    rosterForms: [String],
    ignored: Set<String>
  ) -> [HarvestBoxItem] {
    let excluded = Set(
      (rosterForms + Array(ignored)).map(normalizedFace)
    )
    struct Accumulated {
      var text: String
      var totalCount: Int
      var meetingCount: Int
      var firstSeen: Int
    }
    var accumulated: [String: Accumulated] = [:]
    var order = 0
    for candidates in candidatesByMeeting {
      var seenInMeeting: Set<String> = []
      for candidate in candidates {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let face = normalizedFace(text)
        guard !excluded.contains(face) else { continue }
        if var existing = accumulated[face] {
          existing.totalCount += max(1, candidate.count)
          if seenInMeeting.insert(face).inserted {
            existing.meetingCount += 1
          }
          accumulated[face] = existing
        } else {
          seenInMeeting.insert(face)
          accumulated[face] = Accumulated(
            text: text,
            totalCount: max(1, candidate.count),
            meetingCount: 1,
            firstSeen: order
          )
          order += 1
        }
      }
    }
    return
      accumulated.values
      .sorted {
        if $0.totalCount != $1.totalCount {
          return $0.totalCount > $1.totalCount
        }
        return $0.firstSeen < $1.firstSeen
      }
      .map {
        HarvestBoxItem(
          text: $0.text,
          totalCount: $0.totalCount,
          meetingCount: $0.meetingCount
        )
      }
  }

  /// 词面合并口径与生成侧 normalize 一致:去首尾空白 + 大小写折叠。
  private static func normalizedFace(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
