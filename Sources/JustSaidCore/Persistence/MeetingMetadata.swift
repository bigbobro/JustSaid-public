import Foundation

public enum MeetingStatus: String, Codable, Sendable {
  case recording
  case processing
  case completed
  case failed
  /// 上次未正常结束:状态写下 `recording`/`processing` 之后进程就没了(退出、崩溃、强杀),
  /// 收尾那一步从没跑到。启动时由 `MeetingStore.reconcileInterruptedMeetings` 修正——
  /// 否则会议库会一直显示「录制中」,而实际上什么都没在录(2026-07-29 用户实测发现)。
  case interrupted
}

public struct CloudUsageRecord: Codable, Equatable, Identifiable, Sendable {
  /// `outcome` 的失败取值(08-20 传输韧性单 R3)。固定字符串,不做枚举——
  /// String 枚举加值会让旧版本解码整份 meeting.json 失败。
  public static let failedOutcome = "failed"

  /// `purpose` 的认名提取取值(08-20 naming-first)。同上,固定字符串不做枚举。
  public static let speakerNamingPurpose = "speakerNaming"

  public let id: UUID
  public let role: ProviderRole
  public let provider: String
  public let model: String
  public let timestamp: Date
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let audioDurationSeconds: Double?
  /// 这次调用的结局(08-20 传输韧性单 R3)。nil = 成功(既有档案语义不变,
  /// 成功路径不写此键);`failedOutcome` = 请求已发出但没有完成——钱可能已花,
  /// token 数拿不到就保持 nil,绝不用 0 兜底(「没拿到」≠「没花钱」)。
  public let outcome: String?
  /// 这笔调用的用途细分(08-20 naming-first design 决策 4 定案)。nil = 该角色的本务
  /// (既有档案语义不变,成功路径不写此键);`speakerNamingPurpose` = 会后认名提取——
  /// 它借用会中总结的渠道与模型(flash 档),role 照记 `liveSummaryLLM`,靠本字段区分。
  /// **不给 `ProviderRole` 添新 case**:role 是严格 String 枚举,加值会让旧版本解码
  /// 整份 meeting.json 失败(实测钉在 MeetingStoreVerification;本仓库 MeetingStatus/
  /// PartialArtifactFailure/PostMeetingStageEvent/outcome 四处同判例)。
  public let purpose: String?

  public init(
    id: UUID = UUID(),
    role: ProviderRole,
    provider: String,
    model: String,
    timestamp: Date = Date(),
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    audioDurationSeconds: Double? = nil,
    outcome: String? = nil,
    purpose: String? = nil
  ) {
    self.id = id
    self.role = role
    self.provider = provider
    self.model = model
    self.timestamp = timestamp
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.audioDurationSeconds = audioDurationSeconds
    self.outcome = outcome
    self.purpose = purpose
  }
}

public struct PostMeetingFailureAttempt: Codable, Equatable, Sendable {
  public let source: AudioSource
  public let requestID: String
  public let detail: String
  public let logID: String?
  public let failedAt: Date

  public init(
    source: AudioSource,
    requestID: String,
    detail: String,
    logID: String?,
    failedAt: Date = Date()
  ) {
    self.source = source
    self.requestID = requestID
    self.detail = detail
    self.logID = logID
    self.failedAt = failedAt
  }
}

/// 纪要 LLM 单跳调用失败的留痕(08-20 传输韧性单 R2)。与 `PostMeetingFailureAttempt`
/// (ASR 续查终态账本,source/requestID 形状)语义不同,刻意不复用——硬塞是造假字段。
/// 只追加不清理:失败痕与失败账一样是长期对账凭据。
public struct MinutesFailureAttempt: Codable, Equatable, Sendable {
  /// 纪要输出语种(`MeetingLanguage.rawValue`:"zh"/"en")。
  public let language: String
  /// 第几跳(1 = 原始调用,2 = 自动重试)。
  public let attempt: Int
  /// 分类器给出的稳定分类:"transport"(可重试传输族)/ "terminal"。
  public let kind: String
  /// 人话失败原因(底层错误描述)。
  public let detail: String
  public let failedAt: Date

  public init(
    language: String,
    attempt: Int,
    kind: String,
    detail: String,
    failedAt: Date = Date()
  ) {
    self.language = language
    self.attempt = attempt
    self.kind = kind
    self.detail = detail
    self.failedAt = failedAt
  }
}

/// 精转流水线的一次阶段迁移(08-13 可观测单 R2)。落盘在 `postMeetingStageHistory`,
/// 事后可还原整条时间线;相邻同名事件由写入方去重(轮询期只在 vendorState 变化时追加)。
/// `stage` 用固定字符串而非枚举:String 枚举加值会让旧版本解码整份 meeting.json 失败。
public struct PostMeetingStageEvent: Codable, Equatable, Sendable {
  public let stage: String
  public let at: Date
  public let detail: String?

  public init(stage: String, at: Date = Date(), detail: String? = nil) {
    self.stage = stage
    self.at = at
    self.detail = detail
  }
}

/// 已提交精转任务的稳定身份。F 单后的正常形态只有一条 system job（单文件立体声）；
/// 历史双单声道兜底会同时留下 microphone/system 两条。恢复逻辑只消费这份统一投影，
/// 不假设一场会议固定有几单。
public struct PostMeetingRecoveryJob: Equatable, Hashable, Sendable {
  public let source: AudioSource
  public let requestID: String

  public init(source: AudioSource, requestID: String) {
    self.source = source
    self.requestID = requestID
  }
}

/// 主产物已成功、但某份附加产物没生成出来。
/// 整场 status 仍为 `completed`;失败只挂可重试的局部记录,不推翻会议状态。
/// 刻意不给 `MeetingStatus` 加新 case——String 枚举加值会让旧版本解码整份 meeting.json 失败。
/// `artifact` 用固定字符串取值(短期不扩张),避免嵌套 String 枚举加值带来的解码风险。
public struct PartialArtifactFailure: Codable, Equatable, Sendable {
  /// 英文版纪要(`minutes-en.md`)。当前唯一附加产物取值。
  public static let englishMinutes = "englishMinutes"

  /// 哪份产物没生成出来。当前固定取值见 `englishMinutes`。
  public let artifact: String
  /// 人话失败原因(可展示在纪要页提示条)。
  public let detail: String
  public let failedAt: Date

  public init(
    artifact: String,
    detail: String,
    failedAt: Date = Date()
  ) {
    self.artifact = artifact
    self.detail = detail
    self.failedAt = failedAt
  }

  /// 纪要页提示条共用同一句用户话术。
  public var displayDescription: String {
    switch artifact {
    case Self.englishMinutes:
      return "英文版纪要未生成：\(detail)"
    default:
      return "附加产物未生成：\(detail)"
    }
  }
}

/// 单路采集失败的定性记录(08-05 事故:system 路死、mic 路完好,整场却被标 failed,
/// 会后流水线不跑)。存在本字段即"部分完成":整场 status 仍为 `completed`,
/// 会后流水线照常放行;两路全失败才是 `failed`,此时不写本字段。
/// 刻意不给 `MeetingStatus` 加新 case——String 枚举加值会让旧版本解码整份 meeting.json 失败。
public struct CaptureLegFailure: Codable, Equatable, Sendable {
  public enum Leg: String, Codable, Sendable {
    case microphone
    case systemAudio
  }

  public let leg: Leg
  /// 会议开始后第几秒首次失败;nil = 无法确定(如错误到 stop 阶段才暴露)。
  public let firstFailureSecondsIntoMeeting: Double?
  public let message: String

  public init(
    leg: Leg,
    firstFailureSecondsIntoMeeting: Double?,
    message: String
  ) {
    self.leg = leg
    self.firstFailureSecondsIntoMeeting = firstFailureSecondsIntoMeeting
    self.message = message
  }

  /// 缺失一路的用户话术;横幅、会议库与速记纪要共用同一套词,不各说各话。
  public var legDisplayName: String {
    switch leg {
    case .microphone: return "你的麦克风声音"
    case .systemAudio: return "系统播放声音"
    }
  }

  /// 保住的那一路的用户话术("已保住什么"是文案红线的一半)。
  public var preservedLegDescription: String {
    switch leg {
    case .microphone: return "系统播放声音的完整录音"
    case .systemAudio: return "你的麦克风完整录音"
    }
  }

  /// 缺失起点的 mm:ss(超一小时为 h:mm:ss);无法确定起点时为 nil。
  public var firstFailureTimecode: String? {
    Self.timecode(secondsIntoMeeting: firstFailureSecondsIntoMeeting)
  }

  /// 会议内秒数 → mm:ss(超一小时 h:mm:ss)。partial 结算横幅与会中 legHealth
  /// 横幅共用同一换算(文案口径一致红线);无效输入为 nil,不编造时刻。
  public static func timecode(secondsIntoMeeting seconds: Double?) -> String? {
    guard
      let seconds,
      seconds.isFinite,
      seconds >= 0
    else {
      return nil
    }
    let total = Int(seconds.rounded())
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remainder = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%02d:%02d", minutes, remainder)
  }

  /// "哪路自何时起缺失"的一句话;起点未知时如实说明,不编造时刻。
  public var missingDescription: String {
    if let timecode = firstFailureTimecode {
      return "\(legDisplayName)自 \(timecode) 起缺失"
    }
    return "\(legDisplayName)在本场部分缺失(起点未能确定)"
  }
}

/// 自动重建额度耗尽后的一段采集中断。它与 `CaptureLegFailure` 分开：
/// failure 表示 stop 阶段暴露的路级错误；interruption 表示看门狗曾确认该路停摆，
/// 即使稍后恢复也要留下可审计记录。旧档案缺字段即 nil，无迁移。
public struct CaptureInterruption: Codable, Equatable, Sendable {
  public static let rebuildExhaustedReason = "rebuildExhausted"

  public let leg: CaptureLegFailure.Leg
  /// 看门狗最后一次确认该路正常推进的会议内秒数。
  public let lastGoodSecondsIntoMeeting: Double
  /// 重新观察到合格帧的会议内秒数；nil = 停止前未观测到恢复。
  public var recoveredSecondsIntoMeeting: Double?
  /// 使用稳定字符串而非封闭枚举，后续新增原因不会让旧版本整份解码失败。
  public let reason: String

  public init(
    leg: CaptureLegFailure.Leg,
    lastGoodSecondsIntoMeeting: Double,
    recoveredSecondsIntoMeeting: Double? = nil,
    reason: String = Self.rebuildExhaustedReason
  ) {
    self.leg = leg
    self.lastGoodSecondsIntoMeeting = lastGoodSecondsIntoMeeting
    self.recoveredSecondsIntoMeeting = recoveredSecondsIntoMeeting
    self.reason = reason
  }

  public var legDisplayName: String {
    switch leg {
    case .microphone: return "你的麦克风声音"
    case .systemAudio: return "系统播放声音"
    }
  }

  public var lastGoodTimecode: String? {
    CaptureLegFailure.timecode(secondsIntoMeeting: lastGoodSecondsIntoMeeting)
  }

  public var recoveredTimecode: String? {
    CaptureLegFailure.timecode(secondsIntoMeeting: recoveredSecondsIntoMeeting)
  }

  /// 会议库悬停与收尾提示共用同一句，不把已恢复的缺口说成永久丢失。
  public var displayDescription: String {
    let start = lastGoodTimecode ?? "未知时刻"
    if let recoveredSecondsIntoMeeting {
      let end =
        CaptureLegFailure.timecode(
          secondsIntoMeeting: max(lastGoodSecondsIntoMeeting, recoveredSecondsIntoMeeting)
        ) ?? "未知时刻"
      return "\(legDisplayName)约在 \(start)–\(end) 中断，随后已恢复"
    }
    return "\(legDisplayName)自 \(start) 起中断，停止前未观测到恢复"
  }
}

public struct MeetingCaptureLossStats: Codable, Equatable, Sendable {
  public let microphone: CaptureLossStats
  public let systemAudio: CaptureLossStats

  public init(
    microphone: CaptureLossStats,
    systemAudio: CaptureLossStats
  ) {
    self.microphone = microphone
    self.systemAudio = systemAudio
  }
}

/// 一次麦克风单路暂停在会议音频时间轴上的区间。
/// `end == nil` 表示录制仍在暂停；母带在此区间写等长静音。
public struct MicrophonePauseInterval: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let start: TimeInterval
  public var end: TimeInterval?

  public init(
    id: UUID = UUID(),
    start: TimeInterval,
    end: TimeInterval? = nil
  ) {
    self.id = id
    self.start = start
    self.end = end
  }
}

/// 一个权威转写说话人标签在两条录音来源上的有效发言时长。
/// 来源只作提示，不代表真人身份；UI 自行决定「本侧为主 / 远端为主 / 混合」阈值。
public struct SpeakerChannelStats: Codable, Equatable, Sendable {
  public let microphoneDurationSeconds: TimeInterval
  public let systemAudioDurationSeconds: TimeInterval

  public init(
    microphoneDurationSeconds: TimeInterval,
    systemAudioDurationSeconds: TimeInterval
  ) {
    self.microphoneDurationSeconds = microphoneDurationSeconds
    self.systemAudioDurationSeconds = systemAudioDurationSeconds
  }

  public var totalDurationSeconds: TimeInterval {
    microphoneDurationSeconds + systemAudioDurationSeconds
  }

  public var microphoneShare: Double? {
    guard totalDurationSeconds > 0 else { return nil }
    return microphoneDurationSeconds / totalDurationSeconds
  }
}

/// 去回声后的权威句级声学观测。按原始说话人标签分组写入 meeting.json，
/// 只供后续候选与呈现消费，不改变 transcript.md。
public struct SpeakerAcousticObservation: Codable, Equatable, Sendable {
  public let t0: TimeInterval
  public let t1: TimeInterval
  public let source: AudioSource
  public let volumeDB: Int?
  public let gender: SpeakerGender?

  public init(
    t0: TimeInterval,
    t1: TimeInterval,
    source: AudioSource,
    volumeDB: Int? = nil,
    gender: SpeakerGender? = nil
  ) {
    self.t0 = t0
    self.t1 = t1
    self.source = source
    self.volumeDB = volumeDB
    self.gender = gender
  }
}

public struct MeetingMetadata: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var title: String
  public var startedAt: Date
  public var endedAt: Date?
  public var language: MeetingLanguage
  public var status: MeetingStatus
  public var providers: [RoleProviderBinding]
  public var cloudUsage: [CloudUsageRecord]
  public var finalized: Bool
  public var postMeetingFailureReason: String?
  public var postMeetingFailureLogID: String?
  public var postMeetingFailedAt: Date?
  public var postMeetingMicrophoneRequestID: String?
  public var postMeetingSystemRequestID: String?
  public var postMeetingFailureAttempts: [PostMeetingFailureAttempt]?
  /// 本轮精转任务提交成功的时刻(08-13 可观测单 R2/R3)。nil 的语义按新旧档区分:
  /// `postMeetingStageHistory` 非空 = 新档,nil 即「request_id 已落盘但从未提交成功」,
  /// 启动恢复可安全重走上传+提交;`postMeetingStageHistory` 为 nil = 旧档
  /// (request_id 落盘晚于 submit 的年代),必须当作已提交,只许 query。
  public var postMeetingSubmittedAt: Date?
  /// 精转阶段迁移史(08-13 可观测单 R2):事后可还原整条时间线,成功后长期保留。
  /// 旧档案缺字段解码为 nil。
  public var postMeetingStageHistory: [PostMeetingStageEvent]?
  public var speakerNames: [String: String]?
  /// 单段说话人更正(N2):键 = `TranscriptSpeakerNaming.overrideKey`(时间戳 + 行序),
  /// 值 = 这一段真正的说话人。全局改名覆盖不了「分错人」的段落,用户实测约 40% 的
  /// 更正工作卡在这里。旧配置没有这个字段,故保持 Optional 以便无迁移读取。
  public var speakerOverrides: [String: String]?
  /// 被用户点「不是」拒绝的认名建议(08-17 #7),元素 = `"<label>|<name>"`。
  /// 拒绝只作用于本场会议(不同会议证据独立,跨场同名建议照出)。
  /// 旧档案缺字段解码为 nil;空集不写出(nil),无迁移。
  public var dismissedSpeakerSuggestions: [String]?
  /// 权威转写标签在麦克风/系统声上的发言时长；重新精转时整表覆盖。
  /// nil = 旧会议或本轮没有可统计的有效段落。
  public var speakerChannelStats: [String: SpeakerChannelStats]?
  /// 去回声后的句级音量/性别观测；键与 transcript.md 的原始说话人标签同源。
  /// nil = 旧会议或供应商未返回可用观测。
  public var speakerAcousticObservations: [String: [SpeakerAcousticObservation]]?
  /// 不进入总结与纪要的会议时间段。nil = 没有排除；旧档案无需迁移。
  public var excludedRanges: [ExcludedRange]?
  /// 整人排除使用权威转写里的原始说话人标签，不使用呈现层改名。
  public var excludedSpeakers: [String]?
  public var batchLanguageDecision: BatchLanguageDecision?
  /// 麦克风单路暂停区间；nil = 旧会议或本场从未暂停。
  public var microphonePauseIntervals: [MicrophonePauseInterval]?
  public var captureLossStats: MeetingCaptureLossStats?
  /// 单路采集失败清单(部分完成语义)。旧档案缺字段解码为 nil = 无路级失败。
  public var captureLegFailures: [CaptureLegFailure]?
  /// 自动重建额度耗尽后确认过的中断区间；恢复后仍保留历史。nil = 无此类中断。
  public var captureInterruptions: [CaptureInterruption]?
  /// 主产物已成功、但某份附加产物没生成出来。nil = 没有局部缺失。
  /// 旧档案缺字段解码为 nil,与「没有局部缺失」语义一致,无需迁移。
  public var partialArtifactFailures: [PartialArtifactFailure]?
  /// 纪要 LLM 调用失败留痕(08-20 传输韧性单 R2):每跳一条、只追加不清理。
  /// nil = 旧档或从未失败;旧档案缺字段解码为 nil,零迁移。
  public var minutesFailureAttempts: [MinutesFailureAttempt]?
  /// 外部导入的录音。true = 导入;nil/false = 本机录制。
  /// Optional,不得用 MeetingStatus 新 case(String 枚举加值会让旧版本整份解码失败)。
  public var importedRecording: Bool?
  /// 导入源真实容器/格式(火山 `audio.format` 透传用)。nil = 按 m4a 处理(本机录制)。
  public var importedAudioFormat: String?
  /// 客户标签(08-17 R-b 数据层):用户手填的自由字符串,同名即同组,不做词表。
  /// 模式抄 `speakerNames`:可选、trim 与空归 nil 收在 `MeetingStore.updateTags`、
  /// nil 不写出——旧 meeting.json round-trip 不长出新键,旧档案缺字段解码为 nil。
  public var client: String?
  /// 项目标签,规格同 `client`。
  public var project: String?

  public init(
    id: UUID = UUID(),
    title: String,
    startedAt: Date = Date(),
    endedAt: Date? = nil,
    language: MeetingLanguage,
    status: MeetingStatus = .recording,
    providers: [RoleProviderBinding],
    cloudUsage: [CloudUsageRecord] = [],
    finalized: Bool = false,
    postMeetingFailureReason: String? = nil,
    postMeetingFailureLogID: String? = nil,
    postMeetingFailedAt: Date? = nil,
    postMeetingMicrophoneRequestID: String? = nil,
    postMeetingSystemRequestID: String? = nil,
    postMeetingFailureAttempts: [PostMeetingFailureAttempt]? = nil,
    postMeetingSubmittedAt: Date? = nil,
    postMeetingStageHistory: [PostMeetingStageEvent]? = nil,
    speakerNames: [String: String]? = nil,
    speakerOverrides: [String: String]? = nil,
    dismissedSpeakerSuggestions: [String]? = nil,
    speakerChannelStats: [String: SpeakerChannelStats]? = nil,
    speakerAcousticObservations: [String: [SpeakerAcousticObservation]]? = nil,
    excludedRanges: [ExcludedRange]? = nil,
    excludedSpeakers: [String]? = nil,
    batchLanguageDecision: BatchLanguageDecision? = nil,
    microphonePauseIntervals: [MicrophonePauseInterval]? = nil,
    captureLossStats: MeetingCaptureLossStats? = nil,
    captureLegFailures: [CaptureLegFailure]? = nil,
    captureInterruptions: [CaptureInterruption]? = nil,
    partialArtifactFailures: [PartialArtifactFailure]? = nil,
    minutesFailureAttempts: [MinutesFailureAttempt]? = nil,
    importedRecording: Bool? = nil,
    importedAudioFormat: String? = nil,
    client: String? = nil,
    project: String? = nil
  ) {
    self.id = id
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.language = language
    self.status = status
    self.providers = providers
    self.cloudUsage = cloudUsage
    self.finalized = finalized
    self.postMeetingFailureReason = postMeetingFailureReason
    self.postMeetingFailureLogID = postMeetingFailureLogID
    self.postMeetingFailedAt = postMeetingFailedAt
    self.postMeetingMicrophoneRequestID = postMeetingMicrophoneRequestID
    self.postMeetingSystemRequestID = postMeetingSystemRequestID
    self.postMeetingFailureAttempts = postMeetingFailureAttempts
    self.postMeetingSubmittedAt = postMeetingSubmittedAt
    self.postMeetingStageHistory = postMeetingStageHistory
    self.speakerNames = speakerNames
    self.speakerOverrides = speakerOverrides
    self.dismissedSpeakerSuggestions = dismissedSpeakerSuggestions
    self.speakerChannelStats = speakerChannelStats
    self.speakerAcousticObservations = speakerAcousticObservations
    self.excludedRanges = excludedRanges
    self.excludedSpeakers = excludedSpeakers
    self.batchLanguageDecision = batchLanguageDecision
    self.microphonePauseIntervals = microphonePauseIntervals
    self.captureLossStats = captureLossStats
    self.captureLegFailures = captureLegFailures
    self.captureInterruptions = captureInterruptions
    self.partialArtifactFailures = partialArtifactFailures
    self.minutesFailureAttempts = minutesFailureAttempts
    self.importedRecording = importedRecording
    self.importedAudioFormat = importedAudioFormat
    self.client = client
    self.project = project
  }

  /// 本场最后一次实际提交的精转模型。设置快照只代表开会时的配置，不能替代用量事实；
  /// 重新精转追加新记录后，这个投影会自然指向新模型。
  public var latestBatchASRModelDisplayName: String? {
    cloudUsage
      .filter { $0.role == .batchASR }
      .max { $0.timestamp < $1.timestamp }
      .map { ASRModelNaming.displayName(for: $0.model) }
  }

  /// 本场最后一次实际生成纪要所用的 LLM 模型。只认用量事实，不读设置快照；
  /// LLM 模型名本身可读，原样展示，不做供应商相关映射。
  public var latestMinutesLLMModelName: String? {
    cloudUsage
      .filter { $0.role == .minutesLLM }
      .max { $0.timestamp < $1.timestamp }?
      .model
  }

  /// 把 F 单单任务与历史双任务统一成有序 jobs；空白 ID 不参与恢复。
  public var postMeetingRecoveryJobs: [PostMeetingRecoveryJob] {
    var jobs: [PostMeetingRecoveryJob] = []
    if let requestID = Self.nonEmptyRequestID(postMeetingMicrophoneRequestID) {
      jobs.append(PostMeetingRecoveryJob(source: .me, requestID: requestID))
    }
    if let requestID = Self.nonEmptyRequestID(postMeetingSystemRequestID) {
      jobs.append(PostMeetingRecoveryJob(source: .others, requestID: requestID))
    }
    return jobs
  }

  /// 「从未提交成功」判定(08-13 可观测单 D3)。为 true 时启动恢复可安全重走上传+提交
  /// (火山侧从未计费);为 false 时只许 query 原任务。三层判据,逐层保守:
  /// - `postMeetingSubmittedAt` 非空 = 确证已提交 → false;
  /// - 阶段史为 nil = 旧档(request_id 落盘晚于 submit 的年代)→ 必须当已提交 → false;
  /// - 阶段史只含提交前阶段(processingStarted/composing/uploading/submitting,
  ///   忽略 failed)才判从未提交。**不能只看「有史 + 无 submittedAt」**:续查(resume)
  ///   会写入 vendorQueued/resultReceived 等阶段却从不写 submittedAt,那种史意味着
  ///   任务确实在火山侧存在过,误判成未提交会自动重新 submit——重复计费。
  public var hasNeverSubmittedPostMeetingJob: Bool {
    guard
      postMeetingSubmittedAt == nil,
      let history = postMeetingStageHistory
    else {
      return false
    }
    let preSubmitStages: Set<String> = [
      "processingStarted", "composing", "uploading", "submitting",
    ]
    return history.map(\.stage)
      .filter { $0 != "failed" }
      .allSatisfy { preSubmitStages.contains($0) }
  }

  /// 当前 request_id 已经拿到供应商终态失败；下次启动不能再把它当 pending 自动续查，
  /// 应保留失败横幅与用户主动「重新精转」入口。
  public var hasTerminalFailureForCurrentPostMeetingJobs: Bool {
    let failedJobs = Set(
      (postMeetingFailureAttempts ?? []).map {
        PostMeetingRecoveryJob(source: $0.source, requestID: $0.requestID)
      }
    )
    return postMeetingRecoveryJobs.contains { failedJobs.contains($0) }
  }

  /// 新一轮全量重跑的起点清理:任务身份、提交时刻与阶段史从零记。
  /// **不清 `postMeetingFailureAttempts`**(08-13 可观测单 R2):失败任务照样计费,
  /// attempts 是长期对账账本;重跑生成新 request_id 后旧 attempt 自然不再匹配当前 jobs,
  /// 不会挡住任何自动续查。
  public mutating func clearPostMeetingDiagnostics() {
    postMeetingFailureReason = nil
    postMeetingFailureLogID = nil
    postMeetingFailedAt = nil
    postMeetingMicrophoneRequestID = nil
    postMeetingSystemRequestID = nil
    postMeetingSubmittedAt = nil
    postMeetingStageHistory = nil
    // 全量重跑会后处理时一并清掉局部缺失提示;附加产物重试成功只清对应条目。
    partialArtifactFailures = nil
  }

  /// 精转成功收尾时的清理(08-13 可观测单 R2):只清失败横幅与局部缺失提示,
  /// request_id、submittedAt、阶段史与失败 attempts 全部保留作对账凭据。
  public mutating func clearPostMeetingFailureBanner() {
    postMeetingFailureReason = nil
    postMeetingFailureLogID = nil
    postMeetingFailedAt = nil
    partialArtifactFailures = nil
  }

  /// 追加一条阶段事件;相邻同名去重(轮询期只在 vendorState 变化时追加,避免每 30s 写盘)。
  /// - Returns: 是否真的追加了(调用方据此决定要不要写盘)。
  @discardableResult
  public mutating func appendPostMeetingStage(
    _ stage: String,
    at date: Date = Date(),
    detail: String? = nil
  ) -> Bool {
    var history = postMeetingStageHistory ?? []
    guard history.last?.stage != stage else { return false }
    history.append(PostMeetingStageEvent(stage: stage, at: date, detail: detail))
    postMeetingStageHistory = history
    return true
  }

  /// 清掉指定附加产物的局部失败记录;全部清完后字段回到 nil。
  public mutating func clearPartialArtifactFailure(artifact: String) {
    guard var failures = partialArtifactFailures else { return }
    failures.removeAll { $0.artifact == artifact }
    partialArtifactFailures = failures.isEmpty ? nil : failures
  }

  private static func nonEmptyRequestID(_ value: String?) -> String? {
    guard
      let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }
}
