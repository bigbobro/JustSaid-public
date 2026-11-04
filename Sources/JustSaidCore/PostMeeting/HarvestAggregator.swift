import Foundation

/// 一场会议里的一条收割候选，带上聚合需要的会议身份。
///
/// `variants` 为空表示旧档：转写写法只有 `text`。新档的 `variants` 是转写里核对过的写法。
/// 合并和名册过滤仍用 `text` 加上全部 variants；分档和「转写里写作」只用转写写法。
public struct HarvestSourceCandidate: Equatable, Sendable {
  public let text: String
  public let variants: [String]
  public let count: Int
  public let anchor: TranscriptAnchor?
  public let meeting: HarvestMeetingRef

  public init(
    text: String,
    variants: [String] = [],
    count: Int,
    anchor: TranscriptAnchor? = nil,
    meeting: HarvestMeetingRef
  ) {
    self.text = text
    self.variants = variants
    self.count = count
    self.anchor = anchor
    self.meeting = meeting
  }
}

/// 候选所在的会议。最近一次出现要带目录，回跳才能打开那场转写。
public struct HarvestMeetingRef: Equatable, Sendable {
  public let directory: URL
  public let title: String
  public let startedAt: Date

  public init(directory: URL, title: String, startedAt: Date) {
    self.directory = directory
    self.title = title
    self.startedAt = startedAt
  }
}

/// 最近一次出现：开始时间最晚的那场，带它自己的锚点。
public struct HarvestRecentMeeting: Equatable, Sendable {
  public let directory: URL
  public let title: String
  public let startedAt: Date
  public let anchor: TranscriptAnchor?

  public init(directory: URL, title: String, startedAt: Date, anchor: TranscriptAnchor?) {
    self.directory = directory
    self.title = title
    self.startedAt = startedAt
    self.anchor = anchor
  }
}

/// 收割箱一行：共有写法的候选合并之后的结果。
public struct HarvestBoxItem: Identifiable, Equatable, Sendable {
  /// 显示写法。各场 `text` 里出现场次最多的那个，平手取最近一场。
  public let text: String
  /// 合并后的全部写法（`text` 加 variants）。忽略和恢复都写这一列。
  public let forms: [String]
  /// 转写写法。新档是 variants；旧档（variants 为空）贡献它自己的 `text`。
  public let transcriptForms: [String]
  /// 全库合计出现次数（模型报告值求和，展示用，不当真值）。
  public let totalCount: Int
  /// 出现过任一写法的会议数。
  public let meetingCount: Int
  public let recent: HarvestRecentMeeting

  public var id: String { text }

  public init(
    text: String,
    forms: [String],
    transcriptForms: [String],
    totalCount: Int,
    meetingCount: Int,
    recent: HarvestRecentMeeting
  ) {
    self.text = text
    self.forms = forms
    self.transcriptForms = transcriptForms
    self.totalCount = totalCount
    self.meetingCount = meetingCount
    self.recent = recent
  }
}

/// 聚合的三段输出。组头和角标只数 `actionable`。
public struct HarvestBoxSections: Equatable, Sendable {
  public let actionable: [HarvestBoxItem]
  public let singleMeeting: [HarvestBoxItem]
  public let ignored: [HarvestBoxItem]

  public static let empty = HarvestBoxSections(actionable: [], singleMeeting: [], ignored: [])

  public init(
    actionable: [HarvestBoxItem],
    singleMeeting: [HarvestBoxItem],
    ignored: [HarvestBoxItem]
  ) {
    self.actionable = actionable
    self.singleMeeting = singleMeeting
    self.ignored = ignored
  }

  public var isEmpty: Bool {
    actionable.isEmpty && singleMeeting.isEmpty && ignored.isEmpty
  }
}

/// 收割箱聚合：全库候选 − 名册词面，再按忽略表分到「已忽略」。
///
/// 纯函数。名册过滤在这里再做一遍是刻意的：生成侧已经滤过，但入册发生在生成之后，
/// 昨天写进 minutes.json 的候选今天可能已在册，必须按当前名册现算。
/// 只要有一个写法在名册里，整个候选就不出现，既不进收割箱，也不进已忽略。
public enum HarvestAggregator {
  public static func aggregate(
    sources: [HarvestSourceCandidate],
    rosterForms: [String],
    ignored: Set<String>
  ) -> HarvestBoxSections {
    let roster = Set(rosterForms.map(normalizedFace))
    let ignoredFaces = Set(ignored.map(normalizedFace))
    let groups = mergedGroups(sources)
    var actionable: [HarvestBoxItem] = []
    var singleMeeting: [HarvestBoxItem] = []
    var ignoredItems: [HarvestBoxItem] = []
    for group in groups {
      let spellings = group.flatMap(mergeSpellings)
      let faces = Set(spellings.map(normalizedFace))
      guard !faces.isEmpty, faces.isDisjoint(with: roster) else { continue }
      guard let item = makeItem(group) else { continue }
      if !faces.isDisjoint(with: ignoredFaces) {
        ignoredItems.append(item)
      } else if isActionable(item) {
        actionable.append(item)
      } else {
        singleMeeting.append(item)
      }
    }
    return HarvestBoxSections(
      actionable: sorted(actionable),
      singleMeeting: sorted(singleMeeting),
      ignored: sorted(ignoredItems)
    )
  }

  /// 旧档只有一种转写写法，只能靠场次进第一档。转写写法至少两种，或显示写法不在
  /// 转写写法里，也进第一档。这里只看转写写法，不把建议写法算进去。
  private static func isActionable(_ item: HarvestBoxItem) -> Bool {
    let transcriptFaces = Set(item.transcriptForms.map(normalizedFace))
    return item.meetingCount >= 2
      || transcriptFaces.count >= 2
      || !transcriptFaces.contains(normalizedFace(item.text))
  }

  private static func sorted(_ items: [HarvestBoxItem]) -> [HarvestBoxItem] {
    items.sorted { lhs, rhs in
      if lhs.meetingCount != rhs.meetingCount { return lhs.meetingCount > rhs.meetingCount }
      if lhs.totalCount != rhs.totalCount { return lhs.totalCount > rhs.totalCount }
      return lhs.recent.startedAt > rhs.recent.startedAt
    }
  }

  /// 共有任一规范化写法就并成一组，合并可传递。
  private static func mergedGroups(_ sources: [HarvestSourceCandidate])
    -> [[HarvestSourceCandidate]]
  {
    var parent = Array(sources.indices)
    func find(_ index: Int) -> Int {
      var index = index
      while parent[index] != index {
        parent[index] = parent[parent[index]]
        index = parent[index]
      }
      return index
    }
    func unite(_ lhs: Int, _ rhs: Int) {
      let left = find(lhs)
      let right = find(rhs)
      if left != right { parent[right] = left }
    }
    var owner: [String: Int] = [:]
    for (index, source) in sources.enumerated() {
      let faces = mergeSpellings(source).map(normalizedFace)
      guard !faces.isEmpty else { continue }
      for face in faces {
        if let existing = owner[face] {
          unite(existing, index)
        } else {
          owner[face] = index
        }
      }
    }
    var grouped: [Int: [HarvestSourceCandidate]] = [:]
    for (index, source) in sources.enumerated() where !mergeSpellings(source).isEmpty {
      grouped[find(index), default: []].append(source)
    }
    return grouped.keys.sorted().map { grouped[$0, default: []] }
  }

  private static func makeItem(_ sources: [HarvestSourceCandidate]) -> HarvestBoxItem? {
    guard let display = displayText(of: sources) else { return nil }
    var forms: [String] = []
    var seen = Set<String>()
    func append(_ value: String) {
      guard seen.insert(value).inserted else { return }
      forms.append(value)
    }
    append(display)
    for source in sources {
      for spelling in mergeSpellings(source) { append(spelling) }
    }
    var transcriptForms: [String] = []
    var seenTranscript = Set<String>()
    for source in sources {
      for spelling in transcriptSpellings(source) where seenTranscript.insert(spelling).inserted {
        transcriptForms.append(spelling)
      }
    }
    var meetings = Set<String>()
    var totalCount = 0
    for source in sources {
      meetings.insert(source.meeting.directory.standardizedFileURL.path)
      totalCount += max(1, source.count)
    }
    guard let recentSource = recentSource(in: sources, display: display) else { return nil }
    return HarvestBoxItem(
      text: display,
      forms: forms,
      transcriptForms: transcriptForms,
      totalCount: totalCount,
      meetingCount: meetings.count,
      recent: HarvestRecentMeeting(
        directory: recentSource.meeting.directory,
        title: recentSource.meeting.title,
        startedAt: recentSource.meeting.startedAt,
        anchor: recentSource.anchor
      )
    )
  }

  /// 各场 `text` 按出现的会议数取最多；平手取这些会议里开始时间最晚的那场的写法。
  private static func displayText(of sources: [HarvestSourceCandidate]) -> String? {
    struct Tally {
      var meetings = Set<String>()
      var latest = Date.distantPast
    }
    var tallies: [String: Tally] = [:]
    for source in sources {
      let text = trimmed(source.text)
      guard !text.isEmpty else { continue }
      var tally = tallies[text, default: Tally()]
      tally.meetings.insert(source.meeting.directory.standardizedFileURL.path)
      if source.meeting.startedAt > tally.latest { tally.latest = source.meeting.startedAt }
      tallies[text] = tally
    }
    if let best = tallies.max(by: { lhs, rhs in
      if lhs.value.meetings.count != rhs.value.meetings.count {
        return lhs.value.meetings.count < rhs.value.meetings.count
      }
      return lhs.value.latest < rhs.value.latest
    }) {
      return best.key
    }
    return sources.lazy.compactMap { mergeSpellings($0).first }.first
  }

  private static func recentSource(
    in sources: [HarvestSourceCandidate],
    display: String
  ) -> HarvestSourceCandidate? {
    guard let latest = sources.map(\.meeting.startedAt).max() else { return nil }
    let candidates = sources.filter { $0.meeting.startedAt == latest }
    return candidates.first { trimmed($0.text) == display } ?? candidates.first
  }

  /// 合并、名册和忽略用的全部写法：建议写法加上 variants。
  private static func mergeSpellings(_ source: HarvestSourceCandidate) -> [String] {
    uniqueSpellings([source.text] + source.variants)
  }

  /// 转写写法。旧档没有 variants，贡献自己的 `text`；新档只算 variants，不把没出现过的建议写法算进去。
  private static func transcriptSpellings(_ source: HarvestSourceCandidate) -> [String] {
    let raw = source.variants.isEmpty ? [source.text] : source.variants
    return uniqueSpellings(raw)
  }

  private static func uniqueSpellings(_ raw: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in raw {
      let text = trimmed(value)
      guard !text.isEmpty, seen.insert(text).inserted else { continue }
      result.append(text)
    }
    return result
  }

  private static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 词面合并口径：去首尾空白 + 大小写折叠。
  private static func normalizedFace(_ value: String) -> String {
    trimmed(value).lowercased()
  }
}
