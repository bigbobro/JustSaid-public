import Foundation

/// 一段不进入总结与纪要的会议时间。时间轴与转写里的 `[HH:MM:SS]` 同轴。
public struct ExcludedRange: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var start: TimeInterval
  /// nil 表示会中仍未封口；执行过滤时按开区间处理到正无穷。
  public var end: TimeInterval?
  public var reason: String?
  public var origin: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    start: TimeInterval,
    end: TimeInterval? = nil,
    reason: String? = nil,
    origin: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.start = start
    self.end = end
    self.reason = reason
    self.origin = origin
    self.createdAt = createdAt
  }
}

/// `meeting.json` 排除记录的纯值投影。三个执行入口共用这一份确定性判定。
public struct ExclusionPolicy: Equatable, Sendable {
  public static let none = ExclusionPolicy()

  public let normalizedRanges: [ClosedRange<TimeInterval>]
  private let excludedSpeakerLabels: Set<String>

  public init(
    excludedRanges: [ExcludedRange] = [],
    excludedSpeakers: [String] = []
  ) {
    normalizedRanges = Self.normalized(excludedRanges)
    excludedSpeakerLabels = Set(
      excludedSpeakers.compactMap { label in
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
    )
  }

  public init(metadata: MeetingMetadata) {
    self.init(
      excludedRanges: metadata.excludedRanges ?? [],
      excludedSpeakers: metadata.excludedSpeakers ?? []
    )
  }

  public func isExcluded(time: TimeInterval) -> Bool {
    guard time.isFinite else { return false }
    return normalizedRanges.contains { $0.contains(time) }
  }

  public func isExcluded(speakerLabel: String) -> Bool {
    excludedSpeakerLabels.contains(
      speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// 只删能由固定行格式确定归属的发言；普通行与解析失败的行逐字保留。
  public func filterTranscript(_ content: String) -> String {
    guard !normalizedRanges.isEmpty || !excludedSpeakerLabels.isEmpty else {
      return content
    }

    let rawLines = content.components(separatedBy: "\n")
    let rows = TranscriptSpeakerNaming.rows(in: content)
    var output: [String] = []
    var omittedStart: String?
    var omittedEnd: String?

    func flushOmission() {
      guard let omittedStart, let omittedEnd else { return }
      output.append("[已省略闲聊 \(omittedStart)–\(omittedEnd)]")
    }

    for (rawLine, row) in zip(rawLines, rows) {
      if case .speech(let line) = row {
        let seconds = TranscriptAnchor(timecode: line.timestamp).seconds
        let excludedByTime = seconds.map(isExcluded(time:)) ?? false
        if excludedByTime || isExcluded(speakerLabel: line.originalSpeaker) {
          omittedStart = omittedStart ?? line.timestamp
          omittedEnd = line.timestamp
          continue
        }
      }

      if omittedStart != nil {
        flushOmission()
        omittedStart = nil
        omittedEnd = nil
      }
      output.append(rawLine)
    }
    flushOmission()
    return output.joined(separator: "\n")
  }

  /// 章节视图只按可靠锚点删除；无锚点要点保守保留，整块时间完全命中时才删。
  public func filterTopics(_ topics: [SummaryTopic]) -> [SummaryTopic] {
    guard !normalizedRanges.isEmpty else { return topics }

    return topics.compactMap { topic in
      if let topicRange = Self.topicRange(topic.timeRangeLabel),
        normalizedRanges.contains(where: {
          $0.lowerBound <= topicRange.lowerBound && $0.upperBound >= topicRange.upperBound
        })
      {
        return nil
      }

      let bullets = topic.bullets.filter { bullet in
        guard let anchor = bullet.sourceRef?.transcriptAnchor else { return true }
        return !isExcluded(time: anchor)
      }
      guard topic.bullets.isEmpty || !bullets.isEmpty else { return nil }
      guard bullets != topic.bullets else { return topic }
      return SummaryTopic(
        id: topic.id,
        title: topic.title,
        timeRangeLabel: topic.timeRangeLabel,
        bullets: bullets,
        visualizations: topic.visualizations,
        annotations: topic.annotations,
        revisions: topic.revisions,
        disagreements: topic.disagreements,
        actionItems: topic.actionItems
      )
    }
  }

  private static func normalized(
    _ ranges: [ExcludedRange]
  ) -> [ClosedRange<TimeInterval>] {
    let ordered = ranges.compactMap { range -> ClosedRange<TimeInterval>? in
      guard range.start.isFinite else { return nil }
      let lower = max(0, range.start)
      let upper: TimeInterval
      if let end = range.end {
        // 整段落在会前(end < 0)的区间不产生排除;钳成 0...0 会误删 t=0 的首行。
        guard end.isFinite, end >= 0 else { return nil }
        upper = max(lower, end)
      } else {
        upper = .infinity
      }
      return lower...upper
    }.sorted {
      if $0.lowerBound != $1.lowerBound {
        return $0.lowerBound < $1.lowerBound
      }
      return $0.upperBound < $1.upperBound
    }

    var merged: [ClosedRange<TimeInterval>] = []
    for range in ordered {
      guard let last = merged.last else {
        merged.append(range)
        continue
      }
      guard range.lowerBound <= last.upperBound else {
        merged.append(range)
        continue
      }
      merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
    }
    return merged
  }

  private static func topicRange(
    _ label: String
  ) -> ClosedRange<TimeInterval>? {
    let parts =
      label
      .components(separatedBy: CharacterSet(charactersIn: "–—-~至"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard
      parts.count == 2,
      let start = TranscriptAnchor(timecode: parts[0]).seconds,
      let end = TranscriptAnchor(timecode: parts[1]).seconds,
      start <= end
    else {
      return nil
    }
    return start...end
  }
}
