import Foundation

public enum MeetingStoreError: LocalizedError, Sendable {
  case finalized
  case editedFormalMinutesAlreadyExists
  case emptyTitle
  case formalMinutesPairRecoveryFailed

  public var errorDescription: String? {
    switch self {
    case .finalized:
      return "会议纪要已定稿"
    case .editedFormalMinutesAlreadyExists:
      return "已有被编辑的完整版纪要，自动管线不会覆盖"
    case .emptyTitle:
      return "会议名称不能为空"
    case .formalMinutesPairRecoveryFailed:
      return "纪要结构化文件写入失败，且正文回滚失败；请保留会议目录并重试"
    }
  }
}

public enum PostMeetingRecoveryError: LocalizedError, Equatable, Sendable {
  /// 启动时看到的 request_id 已被用户手动重转产生的新任务替换，或会议已经完成/定稿。
  /// 这是正常竞态，不应把新任务改成失败态，也不应向用户弹一条旧错误。
  case superseded

  public var errorDescription: String? {
    "这次自动续查已被更新的精转任务取代"
  }
}

public struct PostMeetingRecoveryCandidate: Sendable {
  public let paths: MeetingPaths
  public let jobs: [PostMeetingRecoveryJob]

  public init(paths: MeetingPaths, jobs: [PostMeetingRecoveryJob]) {
    self.paths = paths
    self.jobs = jobs
  }
}

public struct MeetingPaths: Sendable {
  public let directory: URL

  public var metadata: URL { directory.appendingPathComponent("meeting.json") }
  public var systemAudio: URL { directory.appendingPathComponent("system.m4a") }
  public var microphoneAudio: URL { directory.appendingPathComponent("mic.m4a") }
  public var liveTranscript: URL { directory.appendingPathComponent("transcript-live.jsonl") }
  public var transcript: URL { directory.appendingPathComponent("transcript.md") }
  public var completeness: URL { directory.appendingPathComponent("completeness.json") }
  /// 完整性缺口人工放行 sidecar(08-21 ack 单):scan 每次原子重写 completeness.json,
  /// 放行状态必须独立存活;缺失 = 无放行。见 `CompletenessAckStore`。
  public var completenessAck: URL { directory.appendingPathComponent("completeness-ack.json") }
  public var notes: URL { directory.appendingPathComponent("notes.md") }
  public var summaryHistory: URL {
    directory.appendingPathComponent("summary-history", isDirectory: true)
  }
  /// 纪要版本历史目录,形状同 `summary-history/`:`NNN-HHmmss.md` + 同名 `.json`。
  public var minutesHistory: URL {
    directory.appendingPathComponent("minutes-history", isDirectory: true)
  }
  public var minutes: URL { directory.appendingPathComponent("minutes.md") }
  public var minutesFull: URL { directory.appendingPathComponent("minutes-full.md") }
  public var minutesEnglish: URL { directory.appendingPathComponent("minutes-en.md") }
  /// 诊断目录(08-13 会中总结断流单):响应正文可能含会议内容,属用户本地数据,
  /// 与 m4a 同级,不上传;会议包导出按名单挑文件,天然不带它。
  public var diagnostics: URL {
    directory.appendingPathComponent("diagnostics", isDirectory: true)
  }
  /// 会中总结解析失败留证(JSONL,一行一条 `{ts, lane, category, error, responsePrefix}`)。
  public var liveSummaryFailureDiagnostics: URL {
    diagnostics.appendingPathComponent("live-summary-failures.jsonl")
  }

  public init(directory: URL) {
    self.directory = directory
  }
}

public struct MeetingRecord: Sendable {
  public let paths: MeetingPaths
  public var metadata: MeetingMetadata

  public init(paths: MeetingPaths, metadata: MeetingMetadata) {
    self.paths = paths
    self.metadata = metadata
  }
}

/// `MeetingStore` keeps synchronous file APIs because a large part of the persistence surface is
/// called from non-async code. Multiple store instances may nevertheless point at the same root
/// (previews, diagnostics and legacy convenience initializers do this), so an instance-owned lock
/// is not a sufficient transaction boundary. This registry gives every standardized meeting root
/// one recursive metadata lock without forcing audio/file append paths through an actor hop.
private final class MeetingStoreMetadataLockRegistry: @unchecked Sendable {
  static let shared = MeetingStoreMetadataLockRegistry()

  // Safety invariant for @unchecked Sendable: `locks` is touched only while `registryLock` is held;
  // returned NSRecursiveLock instances are themselves the synchronization primitive for metadata.
  private let registryLock = NSLock()
  private var locks: [String: NSRecursiveLock] = [:]

  func lock(for rootDirectory: URL) -> NSRecursiveLock {
    let key = rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    registryLock.lock()
    defer { registryLock.unlock() }
    if let existing = locks[key] { return existing }
    let created = NSRecursiveLock()
    locks[key] = created
    return created
  }
}

public final class MeetingStore: @unchecked Sendable {
  public let rootDirectory: URL

  private let fileManager: FileManager
  private let metadataLock: NSRecursiveLock

  public init(
    rootDirectory: URL = MeetingStore.defaultRootDirectory(),
    fileManager: FileManager = .default
  ) {
    self.rootDirectory = rootDirectory
    self.fileManager = fileManager
    self.metadataLock = MeetingStoreMetadataLockRegistry.shared.lock(for: rootDirectory)
  }

  public static func defaultRootDirectory(
    fileManager: FileManager = .default
  ) -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("JustSaid", isDirectory: true)
      .appendingPathComponent("meetings", isDirectory: true)
  }

  @discardableResult
  public func createMeeting(
    title: String,
    language: MeetingLanguage,
    providers: [RoleProviderBinding],
    startedAt: Date = Date()
  ) throws -> MeetingRecord {
    try fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )

    let directory = uniqueMeetingDirectory(title: title, date: startedAt)
    let paths = MeetingPaths(directory: directory)
    try fileManager.createDirectory(
      at: paths.summaryHistory,
      withIntermediateDirectories: true
    )

    let metadata = MeetingMetadata(
      title: title,
      startedAt: startedAt,
      language: language,
      providers: providers
    )
    try write(metadata, to: paths)
    return MeetingRecord(paths: paths, metadata: metadata)
  }

  /// 会议库列表:按开始时间倒序(最近的在最前)。
  /// `meeting.json` 缺失或损坏的目录直接跳过——一场坏会议不该挡住整个列表;
  /// 目录名也不参与排序,因为同一天多场会议靠 `-2` 后缀区分,字典序会把 `-10` 排到 `-2` 前面。
  /// 最近一场已完成会议的实际语言(供开录前的默认语言跟随;2026-07-30 用户拍板:
  /// 「每次都忘了选」——上一场开的什么语言,下一场就默认什么)。
  public func latestDetectedLanguage() -> MeetingLanguage? {
    listMeetings()
      // 导入会议不参与「下一场默认语言跟随」(AC4);避免 auto 遮蔽正常跟随。
      .filter { $0.metadata.status == .completed && $0.metadata.importedRecording != true }
      .sorted { $0.metadata.startedAt > $1.metadata.startedAt }
      .first
      .flatMap { record in
        switch record.metadata.batchLanguageDecision {
        case .english: return .english
        case .chinese: return .chinese
        case .auto, .none: return nil
        }
      }
  }

  public func listMeetings() -> [MeetingRecord] {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: rootDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    return
      entries
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .compactMap { directory -> MeetingRecord? in
        let paths = MeetingPaths(directory: directory)
        guard let metadata = try? read(from: paths) else { return nil }
        return MeetingRecord(paths: paths, metadata: metadata)
      }
      .sorted { $0.metadata.startedAt > $1.metadata.startedAt }
  }

  /// 启动恢复扫描：只挑「已有 request_id、尚未完成、未定稿、且供应商没有返回终态失败」
  /// 的会议。F 单正常只有 system job；历史双单声道兜底可有两条，调用方逐条续查即可。
  public func pendingPostMeetingRecoveries() -> [PostMeetingRecoveryCandidate] {
    listMeetings().compactMap { record in
      let metadata = record.metadata
      let jobs = metadata.postMeetingRecoveryJobs
      guard
        !metadata.finalized,
        metadata.status != .recording,
        metadata.status != .completed,
        !jobs.isEmpty,
        !metadata.hasTerminalFailureForCurrentPostMeetingJobs
      else {
        return nil
      }
      return PostMeetingRecoveryCandidate(paths: record.paths, jobs: jobs)
    }
  }

  /// 把「上次没正常结束」的会议改成 `interrupted`,并补一个尽力而为的 `endedAt`。
  ///
  /// `recording` / `processing` 都是**过程态**,只有本进程正在处理的那一场才可能是真的;
  /// 其余必然是上一次运行留下的孤儿(退出/崩溃/强杀时收尾没跑到)。不修的话会议库会
  /// 一直显示「录制中」——界面在说谎(2026-07-29 用户实测发现)。
  ///
  /// - Parameter activeDirectory: 当前会话正在录制或正在做会后处理的那一场,跳过不动。
  /// - Returns: 被修正的场次数。
  @discardableResult
  public func reconcileInterruptedMeetings(excluding activeDirectory: URL? = nil) -> Int {
    let active = activeDirectory.map { Set([$0.standardizedFileURL]) } ?? []
    return reconcileInterruptedMeetings(excludingAnyOf: active)
  }

  /// 启动时可能同时续查多场精转；这些目录仍有真实任务在跑，不能被孤儿修复误标 interrupted。
  @discardableResult
  public func reconcileInterruptedMeetings(excludingAnyOf activeDirectories: Set<URL>) -> Int {
    let active = Set(activeDirectories.map(\.standardizedFileURL))
    var repaired = 0
    for record in listMeetings() {
      guard record.metadata.status == .recording || record.metadata.status == .processing else {
        continue
      }
      guard !active.contains(record.paths.directory.standardizedFileURL) else { continue }
      let fallbackEnd = lastWriteDate(in: record.paths)
      _ = try? mutateMetadata(at: record.paths) {
        $0.status = .interrupted
        if $0.endedAt == nil {
          $0.endedAt = fallbackEnd
        }
      }
      repaired += 1
    }
    return repaired
  }

  /// 录音文件的最后写入时间,当作被打断那一刻的近似结束时间——比留空好,
  /// 至少会议库能显示一个大致时长。
  private func lastWriteDate(in paths: MeetingPaths) -> Date? {
    [paths.microphoneAudio, paths.systemAudio, paths.liveTranscript]
      .compactMap {
        try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      }
      .max()
  }

  /// 整场删除(拍板 T6「支持整会删除」;T15 的废弃动作用它收尾)。
  /// **不可逆**:调用方必须先向用户确认。
  public func deleteMeeting(at paths: MeetingPaths) throws {
    try synchronized {
      guard fileManager.fileExists(atPath: paths.directory.path) else { return }
      try fileManager.removeItem(at: paths.directory)
    }
  }

  /// 预分配会议目录路径(尚未创建、尚未写 meeting.json)。导入流程先拷音频再写元数据用。
  public func allocateMeetingDirectory(title: String, date: Date) -> URL {
    try? fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    return uniqueMeetingDirectory(title: title, date: date)
  }

  public func write(_ metadata: MeetingMetadata, to paths: MeetingPaths) throws {
    try synchronized {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(metadata)
      try data.write(to: paths.metadata, options: .atomic)
    }
  }

  public func read(from paths: MeetingPaths) throws -> MeetingMetadata {
    try synchronized {
      let data = try Data(contentsOf: paths.metadata)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(MeetingMetadata.self, from: data)
    }
  }

  /// 改会议名只更新 `meeting.json`。目录名是会议的稳定身份,录音、转写、笔记与纪要
  /// 都可能正被其他任务持有,所以这里绝不移动目录或重写任何产物文件。可选的当前标题
  /// 条件与写入共用同一把锁,避免后台自动命名覆盖同时发生的用户改名。
  @discardableResult
  public func renameMeeting(
    to title: String,
    at paths: MeetingPaths,
    ifCurrentTitleIs expectedTitle: String? = nil,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      throw MeetingStoreError.emptyTitle
    }
    let trimmedExpectedTitle = expectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    return try synchronized {
      var metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      if let trimmedExpectedTitle,
        metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
          != trimmedExpectedTitle
      {
        return metadata
      }
      guard metadata.title != trimmedTitle else {
        return metadata
      }
      metadata.title = trimmedTitle
      try write(metadata, to: paths)
      return metadata
    }
  }

  public func appendUsage(
    _ usage: CloudUsageRecord,
    to paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: $0)
      $0.cloudUsage.append(usage)
    }
  }

  @discardableResult
  public func recordBatchLanguageDecision(
    _ decision: BatchLanguageDecision,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      guard !$0.finalized else {
        throw MeetingStoreError.finalized
      }
      $0.batchLanguageDecision = decision
    }
  }

  @discardableResult
  public func setSpeakerName(
    _ name: String?,
    for speakerLabel: String,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      let label = speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !label.isEmpty else { return }
      var names = $0.speakerNames ?? [:]
      let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if trimmedName.isEmpty {
        names.removeValue(forKey: label)
      } else {
        names[label] = trimmedName
      }
      $0.speakerNames = names.isEmpty ? nil : names
    }
  }

  /// 客户/项目标签(08-17 R-b 数据层):`nil` = 不动该字段;非 nil 则 trim 后写入,
  /// 修剪后为空即清除(字段回 nil,不写空值键)。只写 `meeting.json`,走既有元数据
  /// 通道(原子写),不迁移、不重命名任何目录与文件。
  @discardableResult
  public func updateTags(
    client: String? = nil,
    project: String? = nil,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      if let client {
        let trimmed = client.trimmingCharacters(in: .whitespacesAndNewlines)
        $0.client = trimmed.isEmpty ? nil : trimmed
      }
      if let project {
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        $0.project = trimmed.isEmpty ? nil : trimmed
      }
    }
  }

  /// 拒绝一条认名建议(08-17 #7):记 `"<label>|<name>"`,该建议本场不再预填。
  /// 只写 `meeting.json`;空集保持 nil(旧档无迁移),重复拒绝幂等。
  @discardableResult
  public func dismissSpeakerSuggestion(
    label: String,
    name: String,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedLabel.isEmpty, !trimmedName.isEmpty else { return }
      let key = "\(trimmedLabel)|\(trimmedName)"
      var dismissed = $0.dismissedSpeakerSuggestions ?? []
      guard !dismissed.contains(key) else { return }
      dismissed.append(key)
      $0.dismissedSpeakerSuggestions = dismissed
    }
  }

  /// 单段说话人更正(N2)。`name` 为空即撤销这一段的覆盖,回落到全局映射。
  /// 与全局改名一样只写 `meeting.json`,`transcript.md` 一个字节都不碰。
  public func setSpeakerOverride(
    _ name: String?,
    forSegment key: String,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedKey.isEmpty else { return }
      var overrides = $0.speakerOverrides ?? [:]
      let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if trimmedName.isEmpty {
        overrides.removeValue(forKey: trimmedKey)
      } else {
        overrides[trimmedKey] = trimmedName
      }
      $0.speakerOverrides = overrides.isEmpty ? nil : overrides
    }
  }

  /// 精转提交权威转写时整表刷新来源统计；空结果会清掉上一轮统计。
  @discardableResult
  func recordSpeakerChannelStats(
    _ stats: [String: SpeakerChannelStats],
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: $0)
      guard !$0.finalized else {
        throw MeetingStoreError.finalized
      }
      $0.speakerChannelStats = stats.isEmpty ? nil : stats
    }
  }

  /// 精转提交权威转写时整表刷新句级声学观测；空结果清掉上一轮观测。
  @discardableResult
  func recordSpeakerAcousticObservations(
    _ observations: [String: [SpeakerAcousticObservation]],
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: $0)
      guard !$0.finalized else {
        throw MeetingStoreError.finalized
      }
      $0.speakerAcousticObservations = observations.isEmpty ? nil : observations
    }
  }

  /// 录制中整表刷新麦克风暂停区间；空数组恢复为旧档兼容的 nil。
  @discardableResult
  public func recordMicrophonePauseIntervals(
    _ intervals: [MicrophonePauseInterval],
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      $0.microphonePauseIntervals = intervals.isEmpty ? nil : intervals
    }
  }

  /// 新增一段纪要排除区间；只写 `meeting.json`，不触碰权威转写或母带。
  @discardableResult
  public func addExcludedRange(
    start: TimeInterval,
    end: TimeInterval? = nil,
    reason: String? = nil,
    origin: String,
    at paths: MeetingPaths
  ) throws -> ExcludedRange {
    let excludedRange = ExcludedRange(
      start: start,
      end: end,
      reason: reason,
      origin: origin
    )
    _ = try mutateMetadata(at: paths) {
      var ranges = $0.excludedRanges ?? []
      ranges.append(excludedRange)
      $0.excludedRanges = ranges
    }
    return excludedRange
  }

  /// 给会中尚未封口的排除区间补上结束时刻；找不到 id 时保持原样。
  @discardableResult
  public func closeExcludedRange(
    id: UUID,
    end: TimeInterval,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      guard
        var ranges = $0.excludedRanges,
        let index = ranges.firstIndex(where: { $0.id == id })
      else {
        return
      }
      ranges[index].end = end
      $0.excludedRanges = ranges
    }
  }

  @discardableResult
  public func removeExcludedRange(
    id: UUID,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      guard var ranges = $0.excludedRanges else { return }
      ranges.removeAll { $0.id == id }
      $0.excludedRanges = ranges.isEmpty ? nil : ranges
    }
  }

  /// `label` 必须是权威转写里的原始说话人标签；为空时不写入。
  @discardableResult
  public func setSpeakerExcluded(
    _ label: String,
    excluded: Bool,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      var speakers = $0.excludedSpeakers ?? []
      if excluded {
        if !speakers.contains(trimmed) {
          speakers.append(trimmed)
        }
      } else {
        speakers.removeAll { $0 == trimmed }
      }
      $0.excludedSpeakers = speakers.isEmpty ? nil : speakers
    }
  }

  @discardableResult
  public func clearPostMeetingDiagnostics(
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      $0.clearPostMeetingDiagnostics()
    }
  }

  @discardableResult
  public func beginPostMeetingProcessing(
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      guard !$0.finalized else {
        throw MeetingStoreError.finalized
      }
      $0.clearPostMeetingDiagnostics()
      $0.status = .processing
    }
  }

  /// 续查开始只清失败横幅并恢复 processing；绝不能调用 `clearPostMeetingDiagnostics()`，
  /// 因为 request_id 正是跨重启继续查询的唯一任务身份。
  @discardableResult
  public func beginPostMeetingRecovery(
    _ candidate: PostMeetingRecoveryCandidate
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: candidate.paths) {
      try Self.requireCurrentRecoveryJobs(candidate.jobs, in: $0)
      $0.postMeetingFailureReason = nil
      $0.postMeetingFailureLogID = nil
      $0.postMeetingFailedAt = nil
      $0.status = .processing
    }
  }

  /// 云端返回后、任何产物写盘前都重新读 meeting.json 做同一份快照校验。
  @discardableResult
  public func requireCurrentPostMeetingRecovery(
    _ candidate: PostMeetingRecoveryCandidate
  ) throws -> MeetingMetadata {
    try synchronized {
      let metadata = try read(from: candidate.paths)
      try Self.requireCurrentRecoveryJobs(candidate.jobs, in: metadata)
      return metadata
    }
  }

  @discardableResult
  public func recordPostMeetingRequestID(
    _ requestID: String,
    source: AudioSource,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      guard !$0.finalized else {
        throw MeetingStoreError.finalized
      }
      switch source {
      case .me:
        $0.postMeetingMicrophoneRequestID = requestID
      case .others:
        $0.postMeetingSystemRequestID = requestID
      }
    }
  }

  /// 提交成功的证据一次落盘(08-13 可观测单 R2):实际任务身份(provider 可能忽略注入
  /// 或返回服务端 task_id,以返回值为准覆盖)、提交时刻与「submitted」阶段事件同一笔写入,
  /// 避免两次写盘之间进程死亡留下「已提交却无凭据」的半状态。
  @discardableResult
  public func recordPostMeetingSubmission(
    requestID: String,
    source: AudioSource,
    submittedAt: Date = Date(),
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      guard !$0.finalized else {
        throw MeetingStoreError.finalized
      }
      switch source {
      case .me:
        $0.postMeetingMicrophoneRequestID = requestID
      case .others:
        $0.postMeetingSystemRequestID = requestID
      }
      $0.postMeetingSubmittedAt = submittedAt
      $0.appendPostMeetingStage(
        "submitted",
        at: submittedAt,
        detail: "request_id 后 8 位:\(String(requestID.suffix(8)))"
      )
    }
  }

  /// 追加一条精转阶段事件(08-13 可观测单 R2)。相邻同名去重且**去重时不写盘**——
  /// 轮询期每 30s 调一次,只有 vendorState 真变化才落一笔。
  @discardableResult
  public func appendPostMeetingStageEvent(
    _ stage: String,
    detail: String? = nil,
    timestamp: Date = Date(),
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    try synchronized {
      var metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard metadata.appendPostMeetingStage(stage, at: timestamp, detail: detail) else {
        return metadata
      }
      try write(metadata, to: paths)
      return metadata
    }
  }

  @discardableResult
  public func appendPostMeetingFailureAttempt(
    source: AudioSource,
    requestID: String,
    detail: String,
    failedAt: Date = Date(),
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: $0)
      guard !$0.finalized else {
        throw MeetingStoreError.finalized
      }
      var attempts = $0.postMeetingFailureAttempts ?? []
      attempts.append(
        PostMeetingFailureAttempt(
          source: source,
          requestID: requestID,
          detail: detail,
          logID: Self.logID(in: detail),
          failedAt: failedAt
        )
      )
      $0.postMeetingFailureAttempts = attempts
    }
  }

  /// 恢复续查拿到供应商终态失败时，把对账尝试与既有失败横幅一次落盘。
  /// 避免两次写盘之间再次退出后留下“已有终态失败、却仍是 processing”的半状态。
  @discardableResult
  public func failPostMeetingRecoveryJob(
    source: AudioSource,
    requestID: String,
    detail: String,
    reason: String,
    failedAt: Date = Date(),
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: $0)
      guard !$0.finalized else {
        throw MeetingStoreError.finalized
      }
      var attempts = $0.postMeetingFailureAttempts ?? []
      attempts.append(
        PostMeetingFailureAttempt(
          source: source,
          requestID: requestID,
          detail: detail,
          logID: Self.logID(in: detail),
          failedAt: failedAt
        )
      )
      $0.postMeetingFailureAttempts = attempts
      $0.status = .failed
      $0.postMeetingFailureReason = reason
      $0.postMeetingFailureLogID = Self.logID(in: reason)
      $0.postMeetingFailedAt = failedAt
      if $0.postMeetingStageHistory != nil {
        $0.appendPostMeetingStage("failed", at: failedAt, detail: reason)
      }
    }
  }

  /// 成功收尾**不再清任务身份**(08-13 可观测单 R2):request_id、submittedAt 与阶段史
  /// 长期保留在 meeting.json 作对账凭据;只清失败横幅与局部缺失提示,并原子补一条
  /// 「done」阶段事件。已 completed 的会议不会再被启动扫描当 pending(状态守卫在先)。
  @discardableResult
  public func finishPostMeetingProcessing(
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: $0)
      $0.clearPostMeetingFailureBanner()
      if !$0.finalized {
        $0.status = .completed
      }
      if $0.postMeetingStageHistory != nil {
        $0.appendPostMeetingStage("done")
      }
    }
  }

  /// 主产物已成功、附加产物失败时落盘局部缺失记录。
  ///
  /// **红线**:只写 `partialArtifactFailures`,绝不触碰 `postMeetingFailureAttempts`——
  /// attempts 是续查终态失败账本;往这里塞会让启动自动续查把会议当「已终态失败」跳过。
  @discardableResult
  public func recordPartialArtifactFailures(
    _ failures: [PartialArtifactFailure],
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: $0)
      guard !$0.finalized else {
        throw MeetingStoreError.finalized
      }
      guard !failures.isEmpty else {
        $0.partialArtifactFailures = nil
        return
      }
      $0.partialArtifactFailures = failures
    }
  }

  /// 附加产物重试成功后清掉对应局部失败条目。
  @discardableResult
  public func clearPartialArtifactFailure(
    artifact: String,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      $0.clearPartialArtifactFailure(artifact: artifact)
    }
  }

  /// 纪要 LLM 调用失败留痕(08-20 传输韧性单 R2):每一跳失败追加一条,只追加不清理。
  ///
  /// **红线**:与 `recordPartialArtifactFailures` 同款——绝不触碰
  /// `postMeetingFailureAttempts`,那是 ASR 续查终态账本,写错会让启动自动续查
  /// 把会议当「已终态失败」跳过。
  @discardableResult
  public func appendMinutesFailure(
    _ failure: MinutesFailureAttempt,
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: $0)
      var attempts = $0.minutesFailureAttempts ?? []
      attempts.append(failure)
      $0.minutesFailureAttempts = attempts
    }
  }

  @discardableResult
  public func failPostMeetingProcessing(
    reason: String,
    failedAt: Date = Date(),
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: $0)
      guard !$0.finalized else { return }
      $0.status = .failed
      $0.postMeetingFailureReason = reason
      $0.postMeetingFailureLogID = Self.logID(in: reason)
      $0.postMeetingFailedAt = failedAt
      if $0.postMeetingStageHistory != nil {
        $0.appendPostMeetingStage("failed", at: failedAt, detail: reason)
      }
    }
  }

  @discardableResult
  public func mutateMetadata(
    at paths: MeetingPaths,
    _ mutation: (inout MeetingMetadata) throws -> Void
  ) throws -> MeetingMetadata {
    try synchronized {
      var metadata = try read(from: paths)
      try mutation(&metadata)
      try write(metadata, to: paths)
      return metadata
    }
  }

  @discardableResult
  public func setFinalized(
    _ finalized: Bool,
    at paths: MeetingPaths
  ) throws -> MeetingMetadata {
    try mutateMetadata(at: paths) {
      $0.finalized = finalized
    }
  }

  /// 在与 `setFinalized` 相同的锁内检查定稿状态并提交正式版，防止应用内的
  /// “定稿”动作与自动生成发生 check-then-write 竞态。可选 sidecar 只在正文被接受后
  /// 原子写入,并与定稿检查共用这把锁;调用方传已经编码好的通用 `Data`,Store 不依赖业务类型。
  /// sidecar 失败时正文恢复到写前字节，避免新 Markdown 与旧 JSON 静默配对。
  public func commitFormalMinutes(
    _ content: String,
    expectedQuickDraft: String,
    structuredSidecar: Data? = nil,
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> Bool {
    try synchronized {
      let metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard !metadata.finalized else {
        throw MeetingStoreError.finalized
      }
      let currentDraft = try String(contentsOf: paths.minutes, encoding: .utf8)
      let wroteMinutesFull = currentDraft != expectedQuickDraft
      let target = wroteMinutesFull ? paths.minutesFull : paths.minutes
      var shouldWriteTarget = true
      if wroteMinutesFull, fileManager.fileExists(atPath: target.path) {
        let existing = try String(contentsOf: target, encoding: .utf8)
        guard existing == content else {
          throw MeetingStoreError.editedFormalMinutesAlreadyExists
        }
        shouldWriteTarget = false
      }

      let targetExisted = fileManager.fileExists(atPath: target.path)
      let previousTarget = targetExisted ? try Data(contentsOf: target) : nil
      var didWriteTarget = false
      do {
        if shouldWriteTarget {
          try Data(content.utf8).write(to: target, options: .atomic)
          didWriteTarget = true
        }
        if let structuredSidecar {
          try structuredSidecar.write(to: paths.minutesStructured, options: .atomic)
        }
      } catch {
        guard didWriteTarget else { throw error }
        do {
          if let previousTarget {
            try previousTarget.write(to: target, options: .atomic)
          } else if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
          }
        } catch {
          throw MeetingStoreError.formalMinutesPairRecoveryFailed
        }
        throw error
      }
      return wroteMinutesFull
    }
  }

  public func commitEnglishMinutes(
    _ content: String,
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws {
    try synchronized {
      let metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard !metadata.finalized else {
        throw MeetingStoreError.finalized
      }
      try Data(content.utf8).write(to: paths.minutesEnglish, options: .atomic)
    }
  }

  /// 英文流式临时文件:`minutes-en.md.partial`。不进版本历史(既有产品决策)。
  public func englishMinutesStreamingPartialURL(at paths: MeetingPaths) -> URL {
    paths.minutesEnglish.appendingPathExtension(MinutesHistoryWriter.streamingPartialSuffix)
  }

  /// 英文触发生成即建临时文件;定稿只写 `minutes-en.md`,绝不碰 `minutes.md`。
  public func beginStreamingEnglishMinutes(
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws -> URL {
    try synchronized {
      let metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard !metadata.finalized else {
        throw MeetingStoreError.finalized
      }
      let partial = englishMinutesStreamingPartialURL(at: paths)
      try fileManager.createDirectory(
        at: partial.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data().write(to: partial, options: .atomic)
      return partial
    }
  }

  public func writeStreamingEnglishMinutes(
    _ content: String,
    partialURL: URL
  ) throws {
    try Data(content.utf8).write(to: partialURL, options: .atomic)
  }

  public func finalizeStreamingEnglishMinutes(
    _ content: String,
    partialURL: URL,
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws {
    try synchronized {
      let metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard !metadata.finalized else {
        throw MeetingStoreError.finalized
      }
      try Data(content.utf8).write(to: paths.minutesEnglish, options: .atomic)
      try? fileManager.removeItem(at: partialURL)
    }
  }

  /// 分步「生成纪要」的中文落盘:覆盖 `minutes.md` + 写 `minutes.json` + 入版本历史。
  /// 不再写 `minutes-full.md`。生成前若 `minutes.md` 与历史最新版不一致,先归档为
  /// `userEdited`(速记占位与空历史下的速记不入版本)。
  public func commitGeneratedChineseMinutes(
    _ content: String,
    structuredSidecar: Data?,
    document: MeetingMinutesDocument?,
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil,
    now: Date = Date()
  ) throws {
    try synchronized {
      let metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard !metadata.finalized else {
        throw MeetingStoreError.finalized
      }

      let writer = MinutesHistoryWriter(
        directory: paths.minutesHistory,
        fileManager: fileManager
      )
      try archiveUserEditedMinutesIfNeeded(
        writer: writer,
        paths: paths,
        now: now
      )

      try writer.write(
        content: content,
        source: .generated,
        document: document,
        date: now
      )
      try Data(content.utf8).write(to: paths.minutes, options: .atomic)
      if let structuredSidecar {
        try structuredSidecar.write(to: paths.minutesStructured, options: .atomic)
      }
    }
  }

  /// 中文流式:先归档可能的用户编辑,再建 `NNN-HHMMSS.md.partial`。
  public func beginStreamingChineseMinutes(
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil,
    now: Date = Date()
  ) throws -> StreamingChineseMinutesSession {
    try synchronized {
      let metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard !metadata.finalized else {
        throw MeetingStoreError.finalized
      }
      let writer = MinutesHistoryWriter(
        directory: paths.minutesHistory,
        fileManager: fileManager
      )
      try archiveUserEditedMinutesIfNeeded(
        writer: writer,
        paths: paths,
        now: now
      )
      return try writer.beginStreamingPartial(date: now)
    }
  }

  public func writeStreamingChineseMinutes(
    _ content: String,
    session: StreamingChineseMinutesSession
  ) throws {
    let writer = MinutesHistoryWriter(
      directory: session.partialURL.deletingLastPathComponent(),
      fileManager: fileManager
    )
    try writer.writeStreamingContent(content, session: session)
  }

  /// 定稿中文流式:sidecar → 正式历史 md → 删 partial → 覆盖 minutes.md (+ 可选 structured)。
  public func finalizeStreamingChineseMinutes(
    session: StreamingChineseMinutesSession,
    content: String,
    structuredSidecar: Data?,
    document: MeetingMinutesDocument?,
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws {
    try synchronized {
      let metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard !metadata.finalized else {
        throw MeetingStoreError.finalized
      }
      let writer = MinutesHistoryWriter(
        directory: paths.minutesHistory,
        fileManager: fileManager
      )
      try writer.finalizeStreaming(
        session: session,
        content: content,
        source: .generated,
        document: document
      )
      try Data(content.utf8).write(to: paths.minutes, options: .atomic)
      if let structuredSidecar {
        try structuredSidecar.write(to: paths.minutesStructured, options: .atomic)
      }
    }
  }

  private func archiveUserEditedMinutesIfNeeded(
    writer: MinutesHistoryWriter,
    paths: MeetingPaths,
    now: Date
  ) throws {
    let currentMinutes =
      (try? String(contentsOf: paths.minutes, encoding: .utf8)) ?? ""
    let latestHistory = writer.latestContent()
    let normalizedCurrent = MinutesHistoryWriter.normalizeForComparison(currentMinutes)

    if let latestHistory {
      let normalizedLatest = MinutesHistoryWriter.normalizeForComparison(latestHistory)
      if !normalizedCurrent.isEmpty, normalizedCurrent != normalizedLatest {
        try writer.write(
          content: currentMinutes,
          source: .userEdited,
          document: nil,
          date: now
        )
      }
    } else if !normalizedCurrent.isEmpty,
      !MinutesHistoryWriter.isQuickDraftPlaceholder(currentMinutes)
    {
      // 老会议首次生成:盘上已有完整/编辑过的纪要但无历史,先归档再写新版。
      try writer.write(
        content: currentMinutes,
        source: .userEdited,
        document: nil,
        date: now.addingTimeInterval(-1)
      )
    }
  }

  public func commitQuickDraftIfAbsent(
    _ content: String,
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws {
    try synchronized {
      let metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard !metadata.finalized else {
        throw MeetingStoreError.finalized
      }
      guard !fileManager.fileExists(atPath: paths.minutes.path) else {
        return
      }
      try Data(content.utf8).write(to: paths.minutes, options: .atomic)
    }
  }

  /// 权威转写已落盘后，把仍存在的速记占位切到“可生成正式版”。
  /// 只替换已知占位行，用户在速记正文里的编辑原样保留；正式纪要完全不碰。
  public func markQuickDraftTranscriptReady(
    at paths: MeetingPaths,
    ifCurrentRecoveryJobs expectedJobs: [PostMeetingRecoveryJob]? = nil
  ) throws {
    try synchronized {
      let metadata = try read(from: paths)
      try Self.requireCurrentRecoveryJobs(expectedJobs, in: metadata)
      guard !metadata.finalized else {
        throw MeetingStoreError.finalized
      }
      guard fileManager.fileExists(atPath: paths.minutes.path) else {
        return
      }
      let current = try String(contentsOf: paths.minutes, encoding: .utf8)
      guard
        let updated = MinutesHistoryWriter.updatingQuickDraftForTranscriptReady(current),
        updated != current
      else { return }
      try Data(updated.utf8).write(to: paths.minutes, options: .atomic)
    }
  }

  /// request_id 校验与 transcript.md 原子替换共用 metadataLock。这样若用户此刻手动重转：
  /// 要么先换 ID，旧恢复被拒；要么旧恢复先写完，随后新任务再写，永远是新结果最终胜出。
  public func commitRecoveredTranscript(
    _ content: String,
    for candidate: PostMeetingRecoveryCandidate
  ) throws {
    try synchronized {
      let metadata = try read(from: candidate.paths)
      try Self.requireCurrentRecoveryJobs(candidate.jobs, in: metadata)
      try fileManager.createDirectory(
        at: candidate.paths.transcript.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(content.utf8).write(to: candidate.paths.transcript, options: .atomic)
    }
  }

  @discardableResult
  public func updateStatus(
    _ status: MeetingStatus,
    endedAt: Date?,
    captureLossStats: MeetingCaptureLossStats? = nil,
    captureLegFailures: [CaptureLegFailure]? = nil,
    captureInterruptions: [CaptureInterruption]? = nil,
    for record: MeetingRecord
  ) throws -> MeetingRecord {
    let metadata = try mutateMetadata(at: record.paths) {
      $0.status = status
      $0.endedAt = endedAt
      if let captureLossStats {
        $0.captureLossStats = captureLossStats
      }
      if let captureLegFailures {
        $0.captureLegFailures = captureLegFailures
      }
      if let captureInterruptions {
        $0.captureInterruptions = captureInterruptions
      }
    }
    return MeetingRecord(paths: record.paths, metadata: metadata)
  }

  private func uniqueMeetingDirectory(title: String, date: Date) -> URL {
    let dateFormatter = DateFormatter()
    dateFormatter.calendar = Calendar(identifier: .gregorian)
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "yyyy-MM-dd"

    let baseName = "\(dateFormatter.string(from: date))-\(slug(from: title))"
    var candidate = rootDirectory.appendingPathComponent(baseName, isDirectory: true)
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = rootDirectory.appendingPathComponent(
        "\(baseName)-\(suffix)",
        isDirectory: true
      )
      suffix += 1
    }
    return candidate
  }

  private func slug(from title: String) -> String {
    let collapsed =
      title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(
        of: "[^\\p{L}\\p{N}]+",
        with: "-",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    return String(collapsed.prefix(60)).isEmpty
      ? "meeting"
      : String(collapsed.prefix(60))
  }

  /// 从失败详情里提取火山 logid(`logid=xxx` 形态)。internal 供管线日志复用(D4)。
  static func logID(in detail: String) -> String? {
    guard
      let marker = detail.range(
        of: "logid=",
        options: [.caseInsensitive, .backwards]
      )
    else {
      return nil
    }
    let suffix = detail[marker.upperBound...]
    let value = suffix.prefix {
      !$0.isWhitespace && $0 != "；" && $0 != ";"
    }
    let logID = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
    return logID.isEmpty || logID == "无" ? nil : logID
  }

  private static func requireCurrentRecoveryJobs(
    _ expectedJobs: [PostMeetingRecoveryJob]?,
    in metadata: MeetingMetadata
  ) throws {
    guard let expectedJobs else { return }
    guard
      !metadata.finalized,
      metadata.status != .completed,
      metadata.postMeetingRecoveryJobs == expectedJobs
    else {
      throw PostMeetingRecoveryError.superseded
    }
  }

  private func synchronized<T>(_ work: () throws -> T) rethrows -> T {
    metadataLock.lock()
    defer { metadataLock.unlock() }
    return try work()
  }
}
