import Foundation

/// 一次提问实际带给模型的材料。来源校验只认这里列出的转写范围与历史会议。
public struct MeetingQAContext: Sendable {
  /// 本场转写部分(含标题行),已按上限截取。
  public let transcriptSection: String
  /// 本场话题部分;没有话题时为空串。
  public let topicsSection: String
  /// 历史会议纪要部分;没有可带的历史会议时为空串。
  public let pastMeetingsSection: String
  /// 本次提供的转写覆盖的会议计时;没有转写时为 nil。
  public let transcriptRange: ClosedRange<TimeInterval>?
  public let pastMeetings: [MeetingQAPastMeeting]
  /// 转写超过上限,开头被截去。
  public let transcriptTruncated: Bool

  public init(
    transcriptSection: String, topicsSection: String, pastMeetingsSection: String,
    transcriptRange: ClosedRange<TimeInterval>?, pastMeetings: [MeetingQAPastMeeting],
    transcriptTruncated: Bool
  ) {
    self.transcriptSection = transcriptSection
    self.topicsSection = topicsSection
    self.pastMeetingsSection = pastMeetingsSection
    self.transcriptRange = transcriptRange
    self.pastMeetings = pastMeetings
    self.transcriptTruncated = transcriptTruncated
  }
}

/// 组装上下文:本场转写 + 本场话题 + 同客户同项目最近 3 场的纪要。会读盘,不要在主线程调用。
public enum MeetingQAContextBuilder {
  /// 转写超过这个字符数时只保留最近的部分(一小时中文会议约 2 到 3 万字)。
  public static let transcriptCharacterLimit = 120_000
  public static let pastMeetingLimit = 3
  /// 单场历史纪要的字符上限,防止一份异常长的纪要挤掉本场。
  public static let pastMinutesCharacterLimit = 20_000

  public static func build(
    segments: [TranscriptSegment],
    topics: [SummaryTopic],
    meetingPaths: MeetingPaths?,
    store: MeetingStore
  ) -> MeetingQAContext {
    let metadata = meetingPaths.flatMap { try? store.read(from: $0) }
    let exclusion = metadata.map(ExclusionPolicy.init(metadata:)) ?? .none
    let lines =
      segments
      .filter { $0.isFinal && !exclusion.isExcluded(time: $0.t0) }
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted { $0.t0 < $1.t0 }
    let transcript = transcriptSection(lines)
    let past = metadata.map { pastMeetings(for: $0, store: store) } ?? ([], "")
    return MeetingQAContext(
      transcriptSection: transcript.text,
      topicsSection: topicsSection(topics),
      pastMeetingsSection: past.1,
      transcriptRange: transcript.range,
      pastMeetings: past.0,
      transcriptTruncated: transcript.truncated
    )
  }

  private static func transcriptSection(_ segments: [TranscriptSegment])
    -> (text: String, range: ClosedRange<TimeInterval>?, truncated: Bool)
  {
    guard !segments.isEmpty else {
      return ("【本场转写】\n（还没有转写内容）", nil, false)
    }
    // 从最新往前取,直到上限;保留的是最近的部分。
    var kept: [(TranscriptSegment, String)] = []
    var total = 0
    for segment in segments.reversed() {
      let speaker = segment.source == .me ? "我" : "其他人"
      let line = "[\(MeetingQATimeLabel.format(segment.t0))] \(speaker)：\(segment.text)"
      if total + line.count > transcriptCharacterLimit, !kept.isEmpty { break }
      kept.append((segment, line))
      total += line.count + 1
    }
    kept.reverse()
    let truncated = kept.count < segments.count
    let first = kept.first!.0
    let last = kept.last!.0
    var header = "【本场转写】到 \(MeetingQATimeLabel.format(last.t1)) 为止"
    if truncated {
      header += "；会议较长，\(MeetingQATimeLabel.format(first.t0)) 之前的部分没有带上"
    }
    let text = ([header] + kept.map(\.1)).joined(separator: "\n")
    return (text, first.t0...max(first.t0, last.t1), truncated)
  }

  private static func topicsSection(_ topics: [SummaryTopic]) -> String {
    guard !topics.isEmpty else { return "" }
    let lines = topics.map { topic -> String in
      let bullets = topic.bullets.map(\.text.plainText).filter { !$0.isEmpty }
      let range = topic.timeRangeLabel.isEmpty ? "" : "（\(topic.timeRangeLabel)）"
      return "- \(topic.title)\(range)" + (bullets.isEmpty ? "" : "：" + bullets.joined(separator: "；"))
    }
    return (["【本场话题】会中总结整理的，只帮你定位；回答以转写原话为准"] + lines).joined(separator: "\n")
  }

  /// 同客户且同项目(两者都填了)、开始得比本场早的会议,按开始时间倒序取有纪要的 3 场。
  private static func pastMeetings(for metadata: MeetingMetadata, store: MeetingStore)
    -> ([MeetingQAPastMeeting], String)
  {
    guard let client = nonEmpty(metadata.client), let project = nonEmpty(metadata.project) else {
      return ([], "")
    }
    var meetings: [MeetingQAPastMeeting] = []
    var blocks: [String] = []
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "zh_CN")
    dateFormatter.dateFormat = "yyyy-MM-dd"
    for record in store.listMeetings() {
      guard meetings.count < pastMeetingLimit else { break }
      let candidate = record.metadata
      guard candidate.id != metadata.id, candidate.startedAt < metadata.startedAt,
        nonEmpty(candidate.client) == client, nonEmpty(candidate.project) == project,
        let minutes = try? String(contentsOf: record.paths.minutes, encoding: .utf8),
        !minutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      let meeting = MeetingQAPastMeeting(
        index: meetings.count + 1, meetingID: candidate.id, directory: record.paths.directory,
        title: candidate.title, startedAt: candidate.startedAt)
      meetings.append(meeting)
      let body =
        minutes.count > pastMinutesCharacterLimit
        ? String(minutes.prefix(pastMinutesCharacterLimit)) + "\n（纪要较长，后面的部分没有带上）"
        : minutes
      blocks.append(
        "[会议 M\(meeting.index) · \(dateFormatter.string(from: candidate.startedAt)) · \(candidate.title)]\n"
          + body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard !meetings.isEmpty else { return ([], "") }
    let header =
      "【历史会议纪要】同客户「\(client)」、同项目「\(project)」之前的 \(meetings.count) 场，M1 最近；"
      + "和本场说法不一致时以本场为准"
    return (meetings, ([header] + blocks).joined(separator: "\n\n"))
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}
