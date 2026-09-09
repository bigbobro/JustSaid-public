import Foundation

/// 一场会议的「会中总结留痕」快照(summary-history/NNN-HHmmss.md)。
public struct MeetingSummarySnapshot: Identifiable, Equatable, Sendable {
  /// 文件名,天然唯一且可排序。
  public let id: String
  public let sequence: Int
  /// 面向人的版本标签,如「第 3 版 · 11:07」。
  public let label: String
  public let content: String
  /// 同名 JSON sidecar 里的无损类型化卡片；旧会议只有 Markdown 时为 nil。
  public let structuredTopics: [SummaryTopic]?
  public let actionItems: [SummaryActionItem]

  public init(
    id: String,
    sequence: Int,
    label: String,
    content: String,
    structuredTopics: [SummaryTopic]? = nil,
    actionItems: [SummaryActionItem] = []
  ) {
    self.id = id
    self.sequence = sequence
    self.label = label
    self.content = content
    self.structuredTopics = structuredTopics
    self.actionItems = actionItems
  }

  public var hasStructuredContent: Bool { structuredTopics != nil }
}

/// 会议详情页要读的四种产物(spec §3:录音 / 转写 / 人工笔记 / 纪要 不许压扁)。
/// 只读快照:每次打开某场会议时现读磁盘,不做缓存——会后精转会改写 transcript.md 与 minutes.md,
/// 缓存只会让用户看到过期内容。
public struct MeetingArtifacts: Sendable {
  /// 纪要正文:被编辑过的完整版(minutes-full.md)优先,否则 minutes.md。
  public let minutes: String?
  /// 纪要来自 minutes-full.md(即速记版已被用户编辑过,自动管线另存了完整版)。
  public let minutesIsSeparateFullVersion: Bool
  /// 英文完整版纪要(minutes-en.md);生成失败或旧会议没有该文件时为空。
  public let minutesEnglish: String?
  /// 被接受的中文正式纪要结构；旧会议、损坏 sidecar 或仅有速记版时为空。
  public let structuredMinutes: MeetingMinutesDocument?
  /// 认名建议(08-20 naming-first):`speaker-suggestions.json` 优先(指纹匹配时),
  /// 否则回落 `structuredMinutes.speakerSuggestions`;两源绝不合并。
  /// 结算逻辑收在 `SpeakerSuggestionsSidecar.resolvedSuggestions`,此处只是读取快照。
  public let speakerNamingSuggestions: [SpeakerNameSuggestion]
  /// 权威转写(会后精转产物);精转未完成时为空。
  public let transcript: String?
  /// 人工笔记(会中在右栏敲下的内容)。
  public let notes: String?
  /// 会中总结留痕,按版本从早到晚。
  public let summarySnapshots: [MeetingSummarySnapshot]
  /// 纪要版本历史,按版本从早到晚;无 `minutes-history/` 时为空(老会议)。
  public let minutesRevisions: [MinutesHistoryRevision]
  public let hasMicrophoneAudio: Bool
  public let hasSystemAudio: Bool

  public init(
    minutes: String?,
    minutesIsSeparateFullVersion: Bool,
    minutesEnglish: String?,
    structuredMinutes: MeetingMinutesDocument? = nil,
    speakerNamingSuggestions: [SpeakerNameSuggestion] = [],
    transcript: String?,
    notes: String?,
    summarySnapshots: [MeetingSummarySnapshot],
    minutesRevisions: [MinutesHistoryRevision] = [],
    hasMicrophoneAudio: Bool,
    hasSystemAudio: Bool
  ) {
    self.minutes = minutes
    self.minutesIsSeparateFullVersion = minutesIsSeparateFullVersion
    self.minutesEnglish = minutesEnglish
    self.structuredMinutes = structuredMinutes
    self.speakerNamingSuggestions = speakerNamingSuggestions
    self.transcript = transcript
    self.notes = notes
    self.summarySnapshots = summarySnapshots
    self.minutesRevisions = minutesRevisions
    self.hasMicrophoneAudio = hasMicrophoneAudio
    self.hasSystemAudio = hasSystemAudio
  }

  public static func read(
    from paths: MeetingPaths,
    fileManager: FileManager = .default
  ) -> MeetingArtifacts {
    let full = nonEmptyContents(of: paths.minutesFull, fileManager: fileManager)
    let quick = nonEmptyContents(of: paths.minutes, fileManager: fileManager)
    let structuredMinutes = readStructuredMinutes(
      from: paths.minutesStructured,
      fileManager: fileManager
    )
    return MeetingArtifacts(
      // 历史会议仍可能有 minutes-full.md:读路径必须保留,否则旧纪要凭空消失。
      minutes: full ?? quick,
      minutesIsSeparateFullVersion: full != nil,
      minutesEnglish: nonEmptyContents(of: paths.minutesEnglish, fileManager: fileManager),
      structuredMinutes: structuredMinutes,
      speakerNamingSuggestions: SpeakerSuggestionsSidecar.resolvedSuggestions(
        paths: paths
      ) {
        structuredMinutes?.speakerSuggestions
      },
      transcript: nonEmptyContents(of: paths.transcript, fileManager: fileManager),
      notes: nonEmptyContents(of: paths.notes, fileManager: fileManager),
      summarySnapshots: readSnapshots(in: paths.summaryHistory, fileManager: fileManager),
      minutesRevisions: MinutesHistoryWriter.readRevisions(
        in: paths.minutesHistory,
        fileManager: fileManager
      ),
      hasMicrophoneAudio: fileManager.fileExists(atPath: paths.microphoneAudio.path),
      hasSystemAudio: fileManager.fileExists(atPath: paths.systemAudio.path)
    )
  }

  private static func nonEmptyContents(
    of url: URL,
    fileManager: FileManager
  ) -> String? {
    guard
      fileManager.fileExists(atPath: url.path),
      let text = try? String(contentsOf: url, encoding: .utf8),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return text
  }

  private static func readStructuredMinutes(
    from url: URL,
    fileManager: FileManager
  ) -> MeetingMinutesDocument? {
    guard
      fileManager.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    return try? StructuredArtifactCodec.decode(
      MeetingMinutesDocument.self,
      from: data
    )
  }

  private static func readSnapshots(
    in directory: URL,
    fileManager: FileManager
  ) -> [MeetingSummarySnapshot] {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    return
      entries
      .filter { $0.pathExtension.lowercased() == "md" }
      .compactMap { url -> MeetingSummarySnapshot? in
        guard let content = nonEmptyContents(of: url, fileManager: fileManager) else {
          return nil
        }
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let sequence = Int(parts.first ?? "") ?? 0
        let sidecarURL =
          url.deletingPathExtension()
          .appendingPathExtension("json")
        let sidecar: SummaryHistorySidecar? = {
          guard let data = try? Data(contentsOf: sidecarURL) else {
            return nil
          }
          return try? StructuredArtifactCodec.decode(
            SummaryHistorySidecar.self,
            from: data
          )
        }()
        return MeetingSummarySnapshot(
          id: url.lastPathComponent,
          sequence: sequence,
          label: snapshotLabel(
            sequence: sequence, timeToken: parts.count > 1 ? String(parts[1]) : ""),
          content: content,
          structuredTopics: sidecar?.topics,
          actionItems: sidecar?.actionItems ?? []
        )
      }
      .sorted { $0.sequence < $1.sequence }
  }

  /// `001-110309` → 「第 1 版 · 11:03」;文件名不符合约定时退回只标版本号。
  private static func snapshotLabel(sequence: Int, timeToken: String) -> String {
    let digits = timeToken.filter(\.isNumber)
    guard digits.count >= 4 else {
      return "第 \(max(sequence, 1)) 版"
    }
    let hour = digits.prefix(2)
    let minute = digits.dropFirst(2).prefix(2)
    return "第 \(max(sequence, 1)) 版 · \(hour):\(minute)"
  }
}
