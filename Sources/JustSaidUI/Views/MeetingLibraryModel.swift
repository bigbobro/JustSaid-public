import Combine
import Foundation
import JustSaidCore
import SwiftUI
import os

/// 全库搜索性能打点(08-17 #1):只记场数/命中数/耗时,不落 query 与转写正文。
let librarySearchLogger = Logger(
  subsystem: "com.justsaid.app",
  category: "library-search"
)

/// 一页纸是会后默认首屏；其余页签保留各自权威产物，不把内容压扁。
/// 2026-08-21 批4:五签改四签。「会中记录」= 总结留痕 + 补充记录(页内两段)。
public enum MeetingDetailTab: String, CaseIterable, Identifiable, Hashable, Sendable {
  case onePage
  case minutes
  case transcript
  case inMeeting

  public var id: String { rawValue }

  /// 旧 raw(`summaryHistory` / `notes`)映射到会中记录,G3 残留与探针旧值不炸。
  public init?(rawValue: String) {
    switch rawValue {
    case "onePage": self = .onePage
    case "minutes": self = .minutes
    case "transcript": self = .transcript
    case "inMeeting", "summaryHistory", "notes": self = .inMeeting
    default: return nil
    }
  }

  public var rawValue: String {
    switch self {
    case .onePage: "onePage"
    case .minutes: "minutes"
    case .transcript: "transcript"
    case .inMeeting: "inMeeting"
    }
  }

  public var title: String {
    switch self {
    case .onePage: return "一页纸"
    case .minutes: return "纪要"
    case .transcript: return "完整转写"
    case .inMeeting: return "会中记录"
    }
  }

  /// ⌘1-⌘4 与界面页签顺序同一套,不另开编号。
  public var keyboardEquivalent: KeyEquivalent {
    switch self {
    case .onePage: "1"
    case .minutes: "2"
    case .transcript: "3"
    case .inMeeting: "4"
    }
  }

  var keycapLabel: String {
    switch self {
    case .onePage: return "⌘1"
    case .minutes: return "⌘2"
    case .transcript: return "⌘3"
    case .inMeeting: return "⌘4"
    }
  }
}

/// ⏱/溯源跳转后的临时回程。只记来源页签;滚动态走 AppCoordinator 的四页签记忆。
/// 4 秒后由视图收掉,不得做成常驻条。
public struct LibraryReturnTrail: Equatable, Sendable {
  public let sourceTab: MeetingDetailTab
  public static let displayDuration: TimeInterval = 4

  public init(sourceTab: MeetingDetailTab) {
    self.sourceTab = sourceTab
  }
}

/// 纪要页签的中/英两版(F3)。英文版是独立从转写生成的,不是中文版的译文;
/// `minutes-en.md` 不存在时切换整体隐藏。
enum MinutesVariant: String, CaseIterable, Identifiable {
  case chinese
  case english

  var id: String { rawValue }

  var title: String {
    switch self {
    case .chinese: return "中"
    case .english: return "EN"
    }
  }

  /// 实时副本只在中/英两轮生成中产生;`auto` 已被管线入口过滤,不对应任何版本。
  init?(minutesLanguage: MeetingLanguage) {
    switch minutesLanguage {
    case .chinese: self = .chinese
    case .english: self = .english
    case .auto: return nil
    }
  }
}

/// 会议行里「精」「纪」两个记号各自的状态(08-10:会后状态归行,不再飘在顶部)。
///
/// 是从磁盘事实与协调者快照**算**出来的呈现类型,不落盘,所以加 case 没有解码兼容问题。
/// `rawValue` 直接进 `runtimeAccessibilityIdentifier`,改名等于改断言。
public enum MeetingArtifactProgress: String, Equatable {
  case completed
  case inProgress = "in-progress"
  case failed
  case notStarted = "not-started"
}

/// 指挥台滤镜(2026-08-20 批3-C):库列表按「还欠什么加工」过滤。寻路器不是第二舞台——
/// 只过滤既有事实,零 IO、零写盘;呈现态归 AppCoordinator(G3),活过 ⌘L remount。
public enum LibraryQueueFilter: String, CaseIterable, Equatable, Sendable {
  case all
  case transcriptionFailed = "transcription-failed"
  case awaitingMinutes = "awaiting-minutes"
  case completenessRed = "completeness-red"

  public var title: String {
    switch self {
    case .all: return "全部"
    case .transcriptionFailed: return "精转失败"
    case .awaitingMinutes: return "待纪要"
    case .completenessRed: return "完备度缺"
    }
  }

  /// 纯谓词:一场会是否落在本 lane。验证矩阵直接驱动;
  /// 进行中的场次 transcription/minutes 不是 failed/notStarted,天然不进欠账 lane。
  public func matches(_ pipeline: MeetingPipelineState) -> Bool {
    switch self {
    case .all: return true
    case .transcriptionFailed: return pipeline.transcription == .failed
    case .awaitingMinutes:
      // 欠纪要 = 有权威转写、盘上无正式纪要、且不在生成中(评审修正:纪要生成
      // 刚失败且盘上无纪要的场,快照结算前同样欠着,不能三个 lane 都不收)。
      return pipeline.transcription == .completed
        && !pipeline.hasFormalMinutes
        && pipeline.minutes != .inProgress
    case .completenessRed: return pipeline.completeness == .red
    }
  }
}

/// 列表行与详情头共用的一场会议摘要。
/// public 但成员基本保持 internal:验证探针只需要拿着 `selectedItem` 回传给 model 方法,
/// 不需要逐字段读它。唯一的例外是 `compactDurationLabel`(理由见该处)。
public struct MeetingLibraryItem: Identifiable, Sendable {
  /// 目录路径:会议目录名唯一,比 metadata.id 更稳(旧会议可能没写 id 就崩过)。
  /// public 仅因 Identifiable 要求;其余成员保持 internal,探针只拿实例回传。
  public let id: String
  let paths: MeetingPaths
  var title: String
  let startedAt: Date
  let endedAt: Date?
  let status: MeetingStatus
  let finalized: Bool
  let language: MeetingLanguage
  let hasAudio: Bool
  /// `reload()` 时从产物快照预载；列表 LazyVStack 只读内存，不逐行碰磁盘。
  let hasAuthoritativeTranscript: Bool
  /// 中文正式纪要是否存在；一页纸只从这一份或其结构化 sidecar 构建。
  let hasChineseMinutes: Bool
  /// 任一正式纪要存在；沿用历史队列语义，英文独立成功也算纪要已产出。
  let hasFormalMinutes: Bool
  /// 英文正式纪要是否存在；选择默认版本只读这个轻量事实，不同步加载全文。
  let hasEnglishMinutes: Bool
  /// 会中总结历史是否至少有一份非空 Markdown。
  let hasSummaryHistory: Bool
  /// 人工笔记是否非空。
  let hasNotes: Bool
  /// 至少一路非空音频存在(导入会议可能只有 system;丢了一路的本机录制也能重转)。
  let hasUsableAudioChannel: Bool
  /// 来自 meeting.json 的实际 batchASR 用量记录，不读取 providers 配置快照。
  let batchASRModelDisplayName: String?
  /// 来自 meeting.json 的实际 minutesLLM 用量记录，模型名原样展示。
  let minutesLLMModelName: String?
  let postMeetingFailureReason: String?
  /// 失败对应的火山 logid(可提工单的凭据),随失败原因一起展示(08-13 可观测单 R1)。
  let postMeetingFailureLogID: String?
  /// 最近一次精转任务 request_id 的后 8 位(system 优先,历史双单兜底取 mic)。
  /// nil = 盘上没有任务身份。
  let postMeetingRequestIDSuffix: String?
  /// 该任务是否提交成功过(08-13 可观测单 R3):有任务身份且未命中
  /// `hasNeverSubmittedPostMeetingJob`(判据在 `MeetingMetadata`,与启动自愈分叉同源)。
  let hasSubmittedPostMeetingJob: Bool
  /// 单路采集失败清单(部分完成语义,08-05 事故)。旧档案无此字段 = 空数组。
  let captureLegFailures: [CaptureLegFailure]
  /// 看门狗重建额度耗尽后确认过的中断；恢复后仍保留历史。旧档案 = 空数组。
  let captureInterruptions: [CaptureInterruption]
  /// 附加产物局部失败清单(英文纪要等)。旧档案无此字段 = 空数组。
  /// 整场 status 仍是 completed;只在纪要页提示,不惊动会议库列表与状态徽章。
  let partialArtifactFailures: [PartialArtifactFailure]
  /// 外部导入的录音。
  let isImportedRecording: Bool
  /// 「发言人 N」→ 真名(F2)。改名后要立刻在转写里生效,所以是 var:
  /// 走整表 `reload()` 会连带丢掉当前页签与滚动位置,填个名字不该付这个代价。
  var speakerNames: [String: String]
  /// 单段说话人更正(N2):键 = `TranscriptSpeakerNaming.overrideKey`。全局改名覆盖不了
  /// 「分错人」的段落——那是用户估算约 40% 的更正工作。同样是 var,理由与 `speakerNames` 同。
  var speakerOverrides: [String: String]
  /// 被拒绝的认名建议(08-17 #7),元素 = `"<label>|<name>"`。拒绝后要立刻收起那一行,
  /// 所以是 var,理由与 `speakerNames` 同(整表 reload 会丢页签与滚动位置)。
  var dismissedSpeakerSuggestions: [String]
  /// 纪要排除区间(08-14),**原始记录**(未归并):撤销按 id、灰显按覆盖判定都要它。
  /// 与 `speakerNames` 同为 var:排除/撤销后只局部更新,不整表 reload。
  var excludedRanges: [ExcludedRange]
  /// 整体排除的说话人**原始标签**(如「发言人 4」);按 originalSpeaker 匹配。
  var excludedSpeakers: [String]
  /// 每个**原始标签**的双路发言时长统计(08-14 声道来源提示,数据层 commit 6f67205)。
  /// nil = 旧会议没有统计,UI 不渲染任何来源提示。UI 只读不写,且没有局部刷新路径——
  /// 精转终态落盘走 `artifactsChanged` → 整表 `reload()`(见 `handlePostMeetingTaskEvent`),
  /// 重新精转后自然刷新,所以是 `let`。
  let channelStats: [String: SpeakerChannelStats]?
  /// 客户标签(08-17 R-b 数据层):详情页行内编辑后就地更新,不整表 reload
  /// (与 `speakerNames` 同理:填个标签不该赔上页签与滚动位置),所以是 var。
  var client: String?
  /// 项目标签,规格同 `client`。
  var project: String?
  /// 完整性(08-19 N1;08-21 ack 单改合成裁决):reload 时读 completeness.json 与
  /// completeness-ack.json 预载,不在行视图做 IO。nil = 无报告。
  /// var:放行/撤销走就地更新(与 `speakerNames` 同理:点个放行不该赔上页签与滚动位置)。
  var effectiveCompleteness: EffectiveCompleteness?
  /// 放行 sidecar 全量(含孤儿),详情卡按 gapKey 查放行原因/备注展示。var 同上。
  var completenessAcks: [CompletenessAck]
  /// **报告已判有效母带覆盖短欠时**的实际覆盖秒数(= `trackCoverage` 两轨的较大者)。
  /// nil = 报告没判短欠、无报告、或旧快照没有 `trackCoverage` —— 三种情况时长都照旧
  /// 按会话跨度显示。
  ///
  /// 判定**不在这里重算**:scanner 用未取整的音频秒数比阈值,写进 `trackCoverage` 的
  /// 却是四舍五入后的整数,拿整数重算会在阈值附近与报告给出相反结论。所以这里只认
  /// 报告自己记下的红因(`CompletenessScanner.coverageShortfallReasonPrefix`),
  /// 标签与完整性卡片必然同进同退。与 `effectiveCompleteness` 同一次预载读出,
  /// 不额外碰盘;`let`:重扫走整表 reload。
  let shortCoveredSeconds: Int?

  /// 失败当然能重跑;完成/中断的也能(升级重跑:换模型、换热词、提示词更新后翻新旧会议
  /// ——2026-07-30 实测需求)。录制中/精转中不行;已定稿不许自动改写(铁律)。
  /// 至少一路音频即可(导入单路 / 本机丢一路都能重转)。
  var canRetryPostMeeting: Bool {
    status != .recording && status != .processing && !finalized && hasUsableAudioChannel
  }

  var startedLabel: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    return formatter.string(from: startedAt)
  }

  /// 会议库列表紧凑档(P4,用户拍板 08-会议库列表密度-v1):同年只留「月-日 时:分」,
  /// 跨年补回全年——扫列表时一眼分出远近。
  var compactStartedLabel: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    let sameYear = Calendar.current.isDate(startedAt, equalTo: Date(), toGranularity: .year)
    formatter.dateFormat = sameYear ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
    return formatter.string(from: startedAt)
  }

  var durationLabel: String {
    guard let endedAt, endedAt > startedAt else {
      return status == .recording ? "进行中" : "时长未知"
    }
    let label = ElapsedTime.shortLabel(endedAt.timeIntervalSince(startedAt))
    // 被打断的会议,结束时间是按录音最后写入时间推的,标出来别让人当成准确时长。
    return status == .interrupted ? "约 \(label)" : label
  }

  /// 紧凑时长(P4):`h:mm`。「进行中/时长未知/约(打断)」三档语义照 `durationLabel`。
  ///
  /// **忘了关停的一场会不能按会话跨度报时长**(#50):采集在半路停摆、会话却一直挂到
  /// 人想起来才点结束时,`endedAt - startedAt` 是 9:23,而盘上母带只有 1:21——库里
  /// 这行数字于是把「录了 9 小时」写进了用户脑子里。所以 completeness 一旦判定有效
  /// 母带覆盖短欠,这里改报**实际录到的时长**并标「录到」。判据不重算,直接认报告
  /// 自己记下的「有效母带覆盖短欠」红因(见 `shortCoveredSeconds`),两处因此不会
  /// 各说各话:这个标记出现时,完整性卡片里必然有对应的缺口说明。此时数字来自
  /// 音频文件本身、不是推算,所以不叠加打断态的「约」。
  ///
  /// 成员里唯一的 public:这行文案本身就是 #50 的症状,得能被验证直读断言。
  /// SwiftUI 的 `Text` 在 headless 布局里不落成可访问元素(行还套了
  /// `children: .combine`),照层级探针那条路取不到渲染出来的字。
  public var compactDurationLabel: String {
    guard let endedAt, endedAt > startedAt else {
      return status == .recording ? "进行中" : "时长未知"
    }
    if let shortCoveredSeconds {
      return "录到 \(ElapsedTime.hourMinuteLabel(TimeInterval(shortCoveredSeconds)))"
    }
    let label = ElapsedTime.hourMinuteLabel(endedAt.timeIntervalSince(startedAt))
    return status == .interrupted ? "约 \(label)" : label
  }

  var languageLabel: String {
    switch language {
    case .auto: return "Auto"
    case .chinese: return "中文为主"
    case .english: return "英文为主"
    }
  }

  /// 部分录音:整场 completed 但有单路失败或曾耗尽重建额度。老 failed 会议
  /// 没有这些字段,不会误挂这个标识；已恢复的中断仍保留历史提示。
  var hasPartialCapture: Bool {
    !captureLegFailures.isEmpty || !captureInterruptions.isEmpty
  }

  /// 部分录音标识的悬停详情:永久缺失与已恢复区间使用各自准确话术。
  var partialCaptureSummary: String {
    (captureLegFailures.map(\.missingDescription)
      + captureInterruptions.map(\.displayDescription)).joined(separator: "；")
  }

  /// 附加产物局部缺失:整场 completed 但某份附加产物(如英文纪要)没生成。
  var hasPartialArtifact: Bool {
    !partialArtifactFailures.isEmpty
  }

  /// 英文版纪要局部失败记录(若有)。
  var englishMinutesPartialFailure: PartialArtifactFailure? {
    partialArtifactFailures.first {
      $0.artifact == PartialArtifactFailure.englishMinutes
    }
  }

  /// 附加产物局部缺失的悬停/提示文案。
  var partialArtifactSummary: String {
    partialArtifactFailures.map(\.displayDescription).joined(separator: "；")
  }

  /// 能否单独重试英文版纪要:已有转写、未定稿、且英文版缺失或曾失败。
  var canRetryEnglishMinutes: Bool {
    status != .recording && status != .processing && !finalized
      && englishMinutesPartialFailure != nil
  }
}

/// 详情页要渲染的一份文档;`body == nil` 表示这一类产物还不存在,由 `emptyHint` 解释原因。
///
/// 转写页的正文由 `TranscriptDocumentView` 直接吃结构化行,不走这里;但它的 `body`
/// 仍然有用——「复制当前页全文」和「这一页有没有内容」都读它。
/// public 是为了 `MinutesDocumentPane` 的公开构造(UIHierarchy 探针要直接构造它)。
public struct MeetingDocument {
  public let body: String?
  public let emptyHint: String
  public let structuredMinutes: MeetingMinutesDocument?
  public let onJumpToTranscript: ((TimeInterval) -> Void)?

  public init(
    body: String?,
    emptyHint: String,
    structuredMinutes: MeetingMinutesDocument? = nil,
    onJumpToTranscript: ((TimeInterval) -> Void)? = nil
  ) {
    self.body = body
    self.emptyHint = emptyHint
    self.structuredMinutes = structuredMinutes
    self.onJumpToTranscript = onJumpToTranscript
  }
}

public struct TranscriptJumpRequest: Identifiable, Equatable {
  public let id = UUID()
  public let seconds: TimeInterval

  public init(seconds: TimeInterval) {
    self.seconds = seconds
  }
}

/// 会后转写的批量选段(08-14 exclusion-batch-select):锚点/焦点都按**全文行序**
/// (`TranscriptSpeechLine.index`)记录,不按可见行序——「只看」筛选抽掉中间行,
/// 但被排除的是一段连续时间,藏起来的行同样落在区间里。
/// 改名/单段更正只换显示名,index 与 timestamp 不变,选区天然存活;重精转会
/// 重排行序,由视图侧在 rows 变化时校验清除。Shift+单击与拖拽拉选共用这一个模型。
public struct TranscriptLineSelection: Equatable, Sendable {
  public var anchorIndex: Int
  public var focusIndex: Int

  public init(anchorIndex: Int, focusIndex: Int) {
    self.anchorIndex = anchorIndex
    self.focusIndex = focusIndex
  }
}

/// 一次权威转写事实的完整呈现快照。逐行结算、原始标签与最终显示名都从同一轮 parser
/// 结果派生，避免详情头、工具行与正文各自重新拆整份 `transcript.md`。
public struct TranscriptPresentation: Equatable, Sendable {
  public let rows: [TranscriptDisplayRow]
  public let speakerLabels: [String]
  public let displaySpeakers: [String]
}

struct MeetingNoteEntry: Identifiable, Equatable {
  let id: Int
  let timecode: String?
  let text: String

  var seconds: TimeInterval? {
    timecode.flatMap { TranscriptAnchor(timecode: $0).seconds }
  }
}

/// 「按客户分组」的一段(08-17 R-b):`client == nil` 即「未标注」段。纯呈现投影,
/// 不迁移、不重命名任何目录与文件。public:UIHierarchy 探针断言分段顺序与段内容。
public struct MeetingClientSection: Identifiable {
  public let id: String
  /// nil = 无客户标签的会议归到这一段。
  public let client: String?
  public let items: [MeetingLibraryItem]

  public var title: String { client ?? "未标注" }
}

/// 详情页可编辑的两类标签(08-17 R-b)。public:探针驱动 `updateTag` 断言就地更新。
public enum MeetingTagKind: Sendable {
  case client
  case project
}

/// public:UIHierarchy 探针要直接驱动它断言高亮/只看互斥与改名跟随
/// (整页 probe 预置不了 `@StateObject` 的内部状态)。
@MainActor
public final class MeetingLibraryModel: ObservableObject {
  @Published var meetings: [MeetingLibraryItem] = []
  @Published public private(set) var isReloading = false
  /// 异步 artifact cache 安装后的轻量发布源；正文值本身仍只存在 `artifactCache`。
  @Published private var artifactLoadRevision = 0
  @Published public internal(set) var isExporting = false
  @Published public internal(set) var exportProgressText: String?
  @Published var selectedID: String? {
    didSet {
      if oldValue != selectedID {
        HangSentinel.shared.note("meeting:\(selectedID ?? "nil")")
      }
    }
  }
  /// public:探针断言「进高亮自动落到转写页」。
  /// didSet:换页签清掉批量选段——选区绑的是转写行序,离开转写页还留着,
  /// 回来时对着的可能已是另一份心境下的旧选区。
  @Published public var tab: MeetingDetailTab = .onePage {
    didSet {
      if oldValue != tab {
        transcriptSelection = nil
        HangSentinel.shared.note("tab:\(tab.rawValue)")
      }
    }
  }
  @Published var snapshotID: String?
  /// 纪要版本历史当前选中的文件名;nil = 显示最新/盘上 minutes.md。
  @Published var minutesRevisionID: String?
  @Published var minutesVariant: MinutesVariant = .chinese
  /// 说话人改名写盘失败时的原因,直接挂在命名行上——静默失败等于骗用户名字存上了。
  @Published var speakerNameError: String?
  /// 排除/撤销写盘失败的原因(08-14),挂在转写页筛选行;同 speakerNameError 的纪律。
  @Published var exclusionError: String?
  /// 只看某个说话人(N4);nil = 看全部。按**生效后的显示名**筛。
  /// public:探针要断言它与 speakerHighlight 互斥。
  @Published public var speakerFilter: String?
  /// 高亮通读模式(08-14 chip 交互单):按**生效后的显示名**命中着色,全文保留可见。
  /// 与 `speakerFilter` 互斥——两者都是「盯住一个人」的隐蔽状态,同存会让人
  /// 分不清自己此刻在哪个模式里;互斥在两个 toggle 方法里结算,别处不许直接写。
  @Published public internal(set) var speakerHighlight: String?
  /// 当前定位到第几处(0-based,展示时 +1),随「上一处/下一处」循环移动。
  @Published public internal(set) var speakerHighlightIndex = 0
  /// 右键选了「新名字…」的那一段:非空时转写页顶上出现一个就地输入框。
  /// 刻意不用 sheet/alert——这一步只是填个名字,不值得盖住整页转写。
  @Published var pendingOverrideLine: TranscriptSpeechLine?
  /// 批量选段(08-14 exclusion-batch-select):非空时转写行渲染选中态、底部浮出
  /// 「标为闲聊」动作条。单击时间戳设锚、Shift+单击/拖拽推进焦点,两条路径都写这里。
  /// public:探针直接预置选区驱动 model 级断言(预置不了整页 probe 的内部状态)。
  @Published public var transcriptSelection: TranscriptLineSelection?
  /// 待确认删除的会议(T6「整场删除」;确认框由视图层挂载,不可逆动作必须过确认)。
  @Published var pendingDeletion: MeetingLibraryItem?
  /// 待确认的「重新精转」(重跑会重新计费,入口在详情头部,过一次确认防误触)。
  @Published var pendingReprocess: MeetingLibraryItem?
  /// F5:点「生成纪要」先落到这里弹选择,由用户决定出几份,而不是直接开跑。
  @Published var pendingMinutesGeneration: MeetingLibraryItem?
  /// D3:「查看原始数据」开关。切会议、开新一轮生成时复位到排版视图。
  @Published var showsRawLiveMinutes = false
  /// R-a 核对工作台(08-17):开启后纪要正文区切换为核对队列。纯呈现态,不落盘,
  /// 换场复位——重开默认关(design 拍板)。public:探针断言换场复位。
  @Published public var showsCheckWorkbench = false
  @Published private(set) var deletionError: String?
  @Published var titleError: String?
  /// 标签写盘失败的原因,挂在详情头标签行旁——静默失败等于骗用户标签存上了
  /// (与 `titleError` 同一纪律)。
  @Published var tagError: String?
  /// 完整性放行/撤销写盘失败的原因,挂在完备度卡上;同 `tagError` 的纪律。
  @Published var completenessAckError: String?
  /// 「按客户分组」(08-17 R-b):纯呈现开关,默认关(满库列表零变化)。与选中/页签
  /// 同级的用户上下文(G3):状态由 AppCoordinator 持有存活 remount,这里只是工作副本。
  /// public:视图开关直接绑定,探针驱动分组断言。
  @Published public var groupsByClient = false
  /// 指挥台滤镜(批3-C):呈现态,G3 模式随 AppCoordinator 存活 remount。
  @Published public var queueFilter: LibraryQueueFilter = .all {
    didSet { queueSnapshotCache = nil }
  }
  /// 指挥台快照缓存(批3 评审修正):body 求值高频调用 queueCount/queueFilteredMeetings,
  /// 无缓存时每次全库扫 pipelineState(实测 N=300 单项 22ms 超帧预算)。
  /// 失效点:reload、滤镜切换、协调者 stateChanged(实时阶段影响 lane 归属)。
  private var queueSnapshotCache:
    (counts: [LibraryQueueFilter: Int], filtered: [MeetingLibraryItem])?
  /// public:探针断言「进高亮/上一处下一处」发出的跳转秒数。
  @Published public var transcriptJumpRequest: TranscriptJumpRequest?
  /// 最近一次跨页签 ⏱ 跳转的回程;同页跳转不写。换场时清掉。
  @Published public var returnTrail: LibraryReturnTrail?
  @Published var exportNotice: String?
  @Published var exportError: String?
  @Published var recentExportDestinations: [URL]
  @Published var recentDiagnosticsDestinations: [URL]
  /// 全库搜索关键词(08-17 #1「谁说过 X」)。与选中/页签同级的**用户上下文**(G3):
  /// 进出详情、换选中都不清;remount 由 AppCoordinator 持有的副本恢复,恢复的只是
  /// query,结果按当下磁盘重扫——不缓存旧数据。public:视图 TextField 直接绑定,
  /// 探针预置查询驱动 model 级断言。
  @Published public var librarySearchQuery = "" {
    didSet {
      guard oldValue != librarySearchQuery else { return }
      scheduleLibrarySearch(debounce: true)
    }
  }
  /// 按会议分组的命中,流式逐场追加;顺序与库列表一致(开始时间倒序)。
  @Published public internal(set) var librarySearchResults: [LibrarySearchResult] = []
  /// 还有会议没扫完时为 true(搜索行 spinner 用)。
  @Published public internal(set) var isLibrarySearching = false
  var librarySearchTask: Task<Void, Never>?

  let meetingStore: MeetingStore
  private let snapshotLoader: MeetingLibrarySnapshotLoader
  private let artifactLoader: MeetingArtifactSnapshotLoader
  let exportService: MeetingLibraryExportService
  private var reloadTask: Task<Void, Never>?
  private var reloadGeneration: UInt = 0
  private var artifactGeneration: UInt = 0
  private var artifactLoadTasks: [String: Task<Void, Never>] = [:]
  var exportTask: Task<Void, Never>?
  var exportGeneration: UInt = 0
  /// 认名预填的名册来源(08-20 naming-first R2:addressed+名册命中才预填)。
  /// 只读词典;懒加载 + reload 失效,见 `rosterForms(neededFor:)`。
  let dictionaryStore: DictionaryStore
  /// 名册词面缓存:nil = 尚未加载。转写页头部每帧都会算建议行,不能帧帧读盘。
  var cachedRosterForms: [String]?
  let destinationHistory: MeetingPackageDestinationHistory
  let diagnosticsDestinationHistory: MeetingDiagnosticsDestinationHistory
  let recordingSession: RecordingSession?
  /// 会后长任务的唯一所有者(app 生命周期)。本 model 挂在
  /// `.id(libraryRefreshGeneration)` 上,⌘L 就会被整个重建——所以启动守卫、阶段快照
  /// 与实时纪要草稿一律不能存在这里,否则 remount 一次就能把同一场会启动第二次。
  let postMeetingTasks: PostMeetingTaskCoordinator
  private var taskObservation: AnyCancellable?
  /// 导入落地后要不要导航,由**发起导入的这个实例**说了算:
  /// remount 出来的新实例不导航(与迁移前弱引用被释放的行为一致),
  /// 用户在拷贝期间自己翻去别的会议也不导航——协调者完成时不得改动当前选中的会议。
  /// (真正丢不得的链式精转已经在协调者里,与导航无关。)
  private var awaitsImportNavigation = false
  private var importSelectionAnchor: String?
  private var pendingFocus: URL?
  /// 每场会议只读一次磁盘;`reload()` 会整体丢弃缓存,因为会后精转会改写 transcript.md / minutes.md。
  var artifactCache: [String: MeetingArtifacts] = [:]
  /// 与 artifactCache 同生命周期的转写呈现快照；排除、高亮、搜索与后台阶段不失效。
  private var transcriptPresentationCache: [String: TranscriptPresentation] = [:]
  /// public 只用于判别性 verification：同一 artifact revision 应恰好构建一次。
  public private(set) var transcriptPresentationBuildCount = 0
  var copyNoticeTask: Task<Void, Never>?
  private var presentedEnglishFailureNavigations: Set<EnglishFailureNavigationKey> = []

  private struct EnglishFailureNavigationKey: Hashable {
    let meetingID: String
    let detail: String
    let failedAt: Date
  }

  public init(
    meetingStore: MeetingStore,
    focus: URL?,
    restoredSelectedID: String? = nil,
    restoredTab: MeetingDetailTab = .onePage,
    restoredSearchQuery: String = "",
    restoredGroupByClient: Bool = false,
    restoredQueueFilter: LibraryQueueFilter = .all,
    recordingSession: RecordingSession? = nil,
    postMeetingPipelineResolver: (() throws -> PostMeetingPipeline)?,
    destinationHistory: MeetingPackageDestinationHistory = .init(),
    diagnosticsDestinationHistory: MeetingDiagnosticsDestinationHistory = .init(),
    postMeetingTasks: PostMeetingTaskCoordinator? = nil,
    dictionaryStore: DictionaryStore = DictionaryStore(),
    snapshotLoader: MeetingLibrarySnapshotLoader = .live,
    artifactLoader: MeetingArtifactSnapshotLoader = .live,
    exportService: MeetingLibraryExportService = .live
  ) {
    self.meetingStore = meetingStore
    self.snapshotLoader = snapshotLoader
    self.artifactLoader = artifactLoader
    self.exportService = exportService
    self.dictionaryStore = dictionaryStore
    selectedID = restoredSelectedID
    tab = restoredTab
    // init 阶段不触发 didSet:恢复的 query 由首次 reload() 统一起扫。
    librarySearchQuery = restoredSearchQuery
    groupsByClient = restoredGroupByClient
    queueFilter = restoredQueueFilter
    self.destinationHistory = destinationHistory
    recentExportDestinations = destinationHistory.destinations()
    self.diagnosticsDestinationHistory = diagnosticsDestinationHistory
    recentDiagnosticsDestinations = diagnosticsDestinationHistory.destinations()
    self.pendingFocus = focus
    self.recordingSession = recordingSession
    // 生产里由 `AppCoordinator` 注入同一个实例;不传时自建一个,让纯布局探针
    // 与截图工具无需改动即可编译。
    self.postMeetingTasks =
      postMeetingTasks
      ?? PostMeetingTaskCoordinator(
        meetingStore: meetingStore,
        pipelineResolver: postMeetingPipelineResolver
      )
    taskObservation = self.postMeetingTasks.changes.sink { [weak self] event in
      self?.handlePostMeetingTaskEvent(event)
    }
  }

  /// 协调者是变更后通知:阶段/草稿变了只重画;终态落盘了才整表 `reload()`。
  private func handlePostMeetingTaskEvent(_ event: PostMeetingTaskEvent) {
    switch event {
    case .stateChanged:
      queueSnapshotCache = nil
      objectWillChange.send()
    case .artifactsChanged:
      reload()
    case .imported(let directory):
      if awaitsImportNavigation, selectedID == importSelectionAnchor {
        awaitsImportNavigation = false
        pendingFocus = directory
      }
      reload()
    }
  }

  public var selectedItem: MeetingLibraryItem? {
    meetings.first { $0.id == selectedID }
  }

  public func libraryItem(atDirectory directory: URL) -> MeetingLibraryItem? {
    let id = directory.standardizedFileURL.path
    return meetings.first { $0.id == id }
  }

  var snapshots: [MeetingSummarySnapshot] {
    guard let selectedItem else { return [] }
    return artifacts(for: selectedItem).summarySnapshots
  }

  var minutesRevisions: [MinutesHistoryRevision] {
    guard let selectedItem else { return [] }
    return artifacts(for: selectedItem).minutesRevisions
  }

  var selectedHistoryTopics: [SummaryTopic] {
    guard let selectedItem else { return [] }
    let snapshots = artifacts(for: selectedItem).summarySnapshots
    if let snapshotID,
      let snapshot = snapshots.first(where: { $0.id == snapshotID })
    {
      return SummaryMarkdownRenderer.topics(fromHistorySnapshots: [snapshot])
    }
    return SummaryMarkdownRenderer.topics(fromHistorySnapshots: snapshots)
  }

  public func reload() {
    reloadGeneration &+= 1
    let generation = reloadGeneration
    reloadTask?.cancel()
    invalidateArtifactLoads()
    resetReloadScopedPresentationState()
    isReloading = true

    let loader = snapshotLoader
    let store = meetingStore
    reloadTask = Task { [weak self] in
      let items = await loader.load(from: store)
      guard
        !Task.isCancelled,
        let self,
        self.reloadGeneration == generation
      else { return }
      self.applyReloadSnapshot(items, generation: generation)
    }
  }

  /// Verification seam: production callers start reload and keep rendering; probes can await the
  /// current generation without putting disk IO back onto MainActor.
  public func waitForReload() async {
    let task = reloadTask
    await task?.value
    if let selectedItem {
      await waitForArtifacts(for: selectedItem)
    }
  }

  public func waitForArtifacts(for item: MeetingLibraryItem) async {
    scheduleArtifactLoad(for: item)
    let task = artifactLoadTasks[item.id]
    await task?.value
  }

  public func cancelViewScopedWork() {
    reloadGeneration &+= 1
    reloadTask?.cancel()
    reloadTask = nil
    isReloading = false
    invalidateArtifactLoads()
    librarySearchTask?.cancel()
    librarySearchTask = nil
    isLibrarySearching = false
    cancelExport()
  }

  public func isArtifactsLoading(for item: MeetingLibraryItem) -> Bool {
    artifactCache[item.id] == nil && artifactLoadTasks[item.id] != nil
  }

  public func hasLoadedArtifacts(for item: MeetingLibraryItem) -> Bool {
    artifactCache[item.id] != nil
  }

  func scheduleArtifactLoad(for item: MeetingLibraryItem) {
    guard artifactCache[item.id] == nil, artifactLoadTasks[item.id] == nil else { return }
    let generation = artifactGeneration
    let loader = artifactLoader
    let paths = item.paths
    let itemID = item.id
    artifactLoadTasks[itemID] = Task { [weak self] in
      let snapshot = await loader.load(from: paths)
      guard
        !Task.isCancelled,
        let self,
        self.artifactGeneration == generation,
        self.meetings.contains(where: { $0.id == itemID })
      else { return }
      self.artifactCache[itemID] = snapshot
      self.transcriptPresentationCache.removeValue(forKey: itemID)
      self.artifactLoadTasks[itemID] = nil
      self.artifactLoadRevision &+= 1
    }
  }

  private func applyReloadSnapshot(_ items: [MeetingLibraryItem], generation: UInt) {
    guard reloadGeneration == generation else { return }
    meetings = items
    // 后台化 reload 后 SwiftUI body 会在 loading 态用空表先把快照缓存写成全零;
    // reload() 起点的那次 reset 救不了它。不清掉这次毒化,指挥台会一直按零计数
    // 把滤镜回落 .all、lane 行收空——正好打在本函数下方「滤镜激活不得选中被
    // 隐藏会议」的选择不变量上。
    queueSnapshotCache = nil
    reloadTask = nil
    isReloading = false

    if let pendingFocus {
      self.pendingFocus = nil
      select(pendingFocus.standardizedFileURL.path)
    }
    if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) {
      // 兜底选中取可视首场；滤镜激活时不得选中一场被隐藏的会议。
      select(visibleOrderedMeetings.first?.id ?? meetings.first?.id)
    } else if let selectedItem {
      scheduleArtifactLoad(for: selectedItem)
    }

    // 搜索跟随当前 generation 的完整快照重扫，绝不复活旧结果。
    scheduleLibrarySearch(debounce: false)
  }

  private func resetReloadScopedPresentationState() {
    queueSnapshotCache = nil
    liveRequestIDSuffixCache = [:]
    cachedRosterForms = nil
    speakerFilter = nil
    speakerHighlight = nil
    speakerHighlightIndex = 0
    pendingOverrideLine = nil
    transcriptSelection = nil
    transcriptJumpRequest = nil
    copyNoticeTask?.cancel()
    exportNotice = nil
    exportError = nil
  }

  private func invalidateArtifactLoads() {
    artifactGeneration &+= 1
    for task in artifactLoadTasks.values {
      task.cancel()
    }
    artifactLoadTasks.removeAll(keepingCapacity: true)
    artifactCache.removeAll(keepingCapacity: true)
    transcriptPresentationCache.removeAll(keepingCapacity: true)
  }

  /// 逐缺口放行(08-21 ack 单):写 sidecar 后就地更新该场的合成裁决与计数缓存,
  /// 不整表 reload(保住页签与滚动位置)。只写 completeness-ack.json,
  /// 不碰 transcript / 母带 / completeness.json 任何字节(红线)。
  /// public:探针驱动放行→撤销闭环断言(headless 点不了 Menu)。
  public func acknowledgeCompletenessGap(
    _ gap: CompletenessGap,
    reason: CompletenessAckReason,
    note: String?,
    for item: MeetingLibraryItem
  ) {
    do {
      let acks = try CompletenessAckStore.acknowledge(
        gapKey: gap.gapKey, reason: reason, note: note, in: item.paths)
      applyCompletenessAcks(acks, to: item)
    } catch {
      completenessAckError = "放行未能写入磁盘：\(error.localizedDescription)"
    }
  }

  public func revokeCompletenessAck(gapKey: String, for item: MeetingLibraryItem) {
    do {
      let acks = try CompletenessAckStore.revoke(gapKey: gapKey, in: item.paths)
      applyCompletenessAcks(acks, to: item)
    } catch {
      completenessAckError = "撤销放行未能写入磁盘：\(error.localizedDescription)"
    }
  }

  private func applyCompletenessAcks(_ acks: [CompletenessAck], to item: MeetingLibraryItem) {
    completenessAckError = nil
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else { return }
    meetings[index].completenessAcks = acks
    meetings[index].effectiveCompleteness = CompletenessReport.load(from: item.paths).map {
      EffectiveCompleteness.resolve(report: $0, acks: acks)
    }
    // 合成裁决变了,「完备度缺」lane 的计数/命中集合随之失效。
    queueSnapshotCache = nil
  }

  /// 在录/在精转的会议不许删:录音进行中删除等于拔硬盘,精转进行中删除会留下野任务。
  func isDeletable(_ item: MeetingLibraryItem) -> Bool {
    item.status != .recording && item.status != .processing
  }

  /// item 由对话框 presenting 按值传入,不回读 pendingDeletion——关框动作先于本
  /// Task 清空它,回读版曾静默空转(2026-08-21 终验收实测)。
  func confirmDeletion(of item: MeetingLibraryItem, willChangeSelection: () -> Void = {}) async {
    pendingDeletion = nil
    guard isDeletable(item) else {
      deletionError = "这场会议正在录制或精转中，不能删除。"
      return
    }
    let adjacentSelectionID: String? = {
      // 邻近 = **可视顺序**的邻居(08-17 R-b):分组开着时时间序邻居可能在另一段,
      // 删除后选中会视觉跳段;分组关着 `visibleOrderedMeetings` 就是 `meetings`,零变化。
      let ordered = visibleOrderedMeetings
      guard
        selectedID == item.id,
        let index = ordered.firstIndex(where: { $0.id == item.id })
      else {
        return nil
      }
      if ordered.indices.contains(index + 1) {
        return ordered[index + 1].id
      }
      if index > ordered.startIndex {
        return ordered[index - 1].id
      }
      return nil
    }()
    var didDeleteSelectedItem = false
    // 完备度落盘收敛契约(spec):删除目录前先收敛在飞写盘。句柄属于最近一场 stop
    // 的会议,与本次删除目标常无关,但无条件收敛最简、代价毫秒级,不留匹配漏洞。
    await recordingSession?.settlePendingCompletenessScan()
    do {
      try meetingStore.deleteMeeting(at: item.paths)
      deletionError = nil
      if selectedID == item.id {
        willChangeSelection()
        selectedID = adjacentSelectionID
        didDeleteSelectedItem = true
      }
    } catch {
      deletionError = "删除失败：\(error.localizedDescription)"
    }
    if didDeleteSelectedItem, let adjacentSelectionID {
      pendingFocus = URL(fileURLWithPath: adjacentSelectionID)
    }
    reload()
  }

  /// 生效滤镜:选中 lane 的计数掉到 0(任务跑完/会议删除)即回落「全部」,
  /// 不留幽灵空列表;AppCoordinator 里存的原始选择不动,lane 再有货即恢复。
  public var effectiveQueueFilter: LibraryQueueFilter {
    guard queueFilter != .all else { return .all }
    return queueCount(for: queueFilter) > 0 ? queueFilter : .all
  }

  public func queueCount(for filter: LibraryQueueFilter) -> Int {
    guard filter != .all else { return meetings.count }
    return queueSnapshot().counts[filter, default: 0]
  }

  /// 滤镜后的列表事实(批3-C):列表体、分组投影、方向键遍历、删除邻近选中
  /// 全部从这一份出发——可视顺序与遍历顺序**必须**同源(守卫断言看护),
  /// 否则过滤中删除会选中一场被隐藏的会。
  public var queueFilteredMeetings: [MeetingLibraryItem] {
    effectiveQueueFilter == .all ? meetings : queueSnapshot().filtered
  }

  /// 一次全库扫描同时算出各 lane 计数与当前滤镜命中集合;缓存到下一个失效点。
  private func queueSnapshot() -> (
    counts: [LibraryQueueFilter: Int], filtered: [MeetingLibraryItem]
  ) {
    if let cached = queueSnapshotCache { return cached }
    var counts: [LibraryQueueFilter: Int] = [:]
    var filtered: [MeetingLibraryItem] = []
    for item in meetings {
      let pipeline = pipelineState(for: item)
      for lane in LibraryQueueFilter.allCases where lane != .all && lane.matches(pipeline) {
        counts[lane, default: 0] += 1
        if lane == queueFilter { filtered.append(item) }
      }
    }
    let snapshot = (counts: counts, filtered: filtered)
    queueSnapshotCache = snapshot
    return snapshot
  }

  /// 「按客户分组」的分段投影(08-17 R-b):段序 = 客户在时间倒序列表里的首现序
  /// (最近谈过的客户在前),无标签段固定殿后;段内保持时间倒序(与满库现状一致)。
  /// 纯呈现,每次从同一份列表事实(滤镜后)现算,不另存第二份列表。
  public var clientSections: [MeetingClientSection] {
    var sections: [(client: String, items: [MeetingLibraryItem])] = []
    var indexByClient: [String: Int] = [:]
    var untagged: [MeetingLibraryItem] = []
    for item in queueFilteredMeetings {
      guard let client = item.client else {
        untagged.append(item)
        continue
      }
      if let index = indexByClient[client] {
        sections[index].items.append(item)
      } else {
        indexByClient[client] = sections.count
        sections.append((client, [item]))
      }
    }
    var projected = sections.map {
      MeetingClientSection(id: "client:\($0.client)", client: $0.client, items: $0.items)
    }
    if !untagged.isEmpty {
      projected.append(MeetingClientSection(id: "untagged", client: nil, items: untagged))
    }
    return projected
  }

  /// 列表的**可视顺序**:分组开着时跨段连续(方向键遍历用它,B5 契约),
  /// 关着时就是满库时间倒序——现状零变化。
  public var visibleOrderedMeetings: [MeetingLibraryItem] {
    groupsByClient ? clientSections.flatMap(\.items) : queueFilteredMeetings
  }

  public func selectAdjacent(offset: Int) {
    let ordered = visibleOrderedMeetings
    guard !ordered.isEmpty else { return }
    // 选中不在可视集合(滤镜把它藏了/尚无选中)时,任一方向键都落到可视首场
    //(批3 评审修正:旧写法 ?? 0 会让 ↓ 跳过首行、↑ 变死键)。
    guard
      let currentIndex = selectedID.flatMap({ id in ordered.firstIndex(where: { $0.id == id }) })
    else {
      select(ordered.first?.id)
      return
    }
    let nextIndex = currentIndex + offset
    guard ordered.indices.contains(nextIndex) else { return }
    select(ordered[nextIndex].id)
  }

  public func select(_ id: String?) {
    selectedID = id
    snapshotID = nil
    minutesRevisionID = nil
    minutesVariant = .chinese
    showsRawLiveMinutes = false
    showsCheckWorkbench = false
    speakerNameError = nil
    exclusionError = nil
    titleError = nil
    tagError = nil
    completenessAckError = nil
    speakerFilter = nil
    speakerHighlight = nil
    speakerHighlightIndex = 0
    pendingOverrideLine = nil
    transcriptSelection = nil
    transcriptJumpRequest = nil
    returnTrail = nil
    copyNoticeTask?.cancel()
    exportNotice = nil
    exportError = nil
    guard let item = meetings.first(where: { $0.id == id }) else { return }
    // 默认落签只依赖 reload 已经预读的轻量文件事实；完整正文继续在后台加载。
    tab = preferredLandingTab(for: item)
    if item.hasEnglishMinutes, !item.hasChineseMinutes {
      minutesVariant = .english
    } else {
      minutesVariant = .chinese
    }
    scheduleArtifactLoad(for: item)
    // 英文版局部失败:同一场同一失败首次选中时落到纪要·EN,否则提示条藏在未选中的
    // 页签里等于静默吞掉(D2/R2);后续选中不再强拉,新失败(以 failedAt 区分)再提示一次。
    if let failure = item.englishMinutesPartialFailure {
      let navigationKey = EnglishFailureNavigationKey(
        meetingID: item.id,
        detail: failure.detail,
        failedAt: failure.failedAt
      )
      guard presentedEnglishFailureNavigations.insert(navigationKey).inserted else {
        return
      }
      tab = .minutes
      minutesVariant = .english
    }
  }

  func hasContent(for item: MeetingLibraryItem, tab: MeetingDetailTab) -> Bool {
    switch tab {
    case .onePage: return item.hasChineseMinutes
    case .minutes: return item.hasChineseMinutes || item.hasEnglishMinutes
    case .transcript: return item.hasAuthoritativeTranscript
    case .inMeeting: return item.hasSummaryHistory || item.hasNotes
    }
  }

  /// 选中落签使用列表快照中的轻量事实，不为了决定页签同步读取完整正文。
  public func preferredLandingTab(for item: MeetingLibraryItem) -> MeetingDetailTab {
    if item.hasChineseMinutes { return .onePage }
    if item.hasSummaryHistory { return .inMeeting }
    if item.hasAuthoritativeTranscript { return .transcript }
    if item.hasNotes { return .inMeeting }
    if item.hasEnglishMinutes { return .minutes }
    return .onePage
  }

  func shouldShowPipelineStrip(for item: MeetingLibraryItem) -> Bool {
    let pipeline = pipelineState(for: item)
    if pipeline.transcription == .failed || pipeline.minutes == .failed {
      return true
    }
    if pipeline.transcription != .completed || pipeline.minutes != .completed {
      return true
    }
    // 已确认(acknowledged)与绿同判:缺口已由用户放行销账,不再欠加工(批4 门的延伸)。
    return pipeline.completeness != .green && pipeline.completeness != .acknowledged
  }

  /// 英文版纪要存在、或有英文版局部失败记录时,显示「中/EN」切换。
  /// 局部失败时也要露出 EN 页签,才能挂提示条 + 重试(不得静默吞掉)。
  func hasEnglishMinutes(for item: MeetingLibraryItem) -> Bool {
    item.hasEnglishMinutes || item.englishMinutesPartialFailure != nil
  }

  /// 这场会的转写里出现过的说话人标签,顺序即出场顺序;永远读**原始**转写。
  func speakerLabels(for item: MeetingLibraryItem) -> [String] {
    transcriptPresentation(for: item).speakerLabels
  }

  func speakerName(_ label: String, for item: MeetingLibraryItem) -> String {
    item.speakerNames[label] ?? ""
  }

  /// 这场会转写里**生效后**的说话人显示名,按出场顺序(含「我」)。
  /// 配色位次与右键候选名都从它来:两个原始标签被更正成同一个真名,就是同一个人。
  func displaySpeakers(for item: MeetingLibraryItem) -> [String] {
    transcriptPresentation(for: item).displaySpeakers
  }

  /// 详情头状态行(08-13 可观测单 R1):进行中以协调者实时阶段文案为准
  /// ("已提交,火山排队中 · 已等 X 分 X 秒"),不再让冻结的磁盘快照顶替实时进展;
  /// 无实时运行时才回落磁盘推导。
  func transcriptionStatusLabel(for item: MeetingLibraryItem) -> String {
    if case .running(let detail) = postMeetingStage(for: item) {
      return detail ?? "精转中"
    }
    if item.hasAuthoritativeTranscript {
      return "精转完成"
    }
    switch item.status {
    case .processing:
      return "精转中"
    case .failed:
      return "精转失败"
    case .recording:
      return "录制中"
    case .completed, .interrupted:
      return "精转未完成"
    }
  }

  /// 状态徽章/状态点用的有效状态(08-13 可观测单 R1):精转进行中时,
  /// 「上次未正常结束」等磁盘快照让位于实时阶段——徽章显示「会后处理中」。
  func effectiveStatus(for item: MeetingLibraryItem) -> MeetingStatus {
    postMeetingStage(for: item).isRunning ? .processing : item.status
  }

  /// 进行中精转的 request_id 后 8 位(08-13 可观测单 D2:「有没有拿到 ID」一眼可见)。
  /// 只在协调者确有精转类任务在跑时读盘,按 runID 缓存——新一轮任务换 ID 不会读到旧值,
  /// 恢复流的纪要流式帧也不会逐帧砸磁盘。
  private var liveRequestIDSuffixCache: [String: String] = [:]

  func livePostMeetingRequestIDSuffix(for item: MeetingLibraryItem) -> String? {
    guard
      let snapshot = postMeetingTasks.snapshot(for: item.paths.directory),
      snapshot.stage.isRunning,
      snapshot.kind == .fullPostMeeting || snapshot.kind == .recovery
    else {
      return nil
    }
    let key = "\(item.id)#\(snapshot.runID)"
    if let cached = liveRequestIDSuffixCache[key] {
      return cached
    }
    guard
      let metadata = try? meetingStore.read(from: item.paths),
      let requestID = metadata.postMeetingSystemRequestID
        ?? metadata.postMeetingMicrophoneRequestID
    else {
      return nil
    }
    let suffix = String(requestID.suffix(8))
    liveRequestIDSuffixCache[key] = suffix
    return suffix
  }

  /// 完整转写空态(08-13 可观测单 R1):不再是死常量——进行中给当前阶段,失败给原因
  /// 与 logid,中断给「下一步会发生什么」;其余保持既有文案。
  func transcriptEmptyHint(for item: MeetingLibraryItem) -> String {
    if case .running(let detail) = postMeetingStage(for: item) {
      return "精转进行中：\(detail ?? "正在处理")。完成后权威转写会出现在这里。"
    }
    if item.status == .failed {
      let reason = item.postMeetingFailureReason ?? "没有留下具体失败原因"
      let logID = item.postMeetingFailureLogID.map { "(logid \($0))" } ?? ""
      return "精转失败：\(reason)\(logID)。可在上方点「重新精转」。"
    }
    if item.status == .interrupted {
      if let suffix = item.postMeetingRequestIDSuffix {
        return item.hasSubmittedPostMeetingJob
          ? "上次精转中断：任务(…\(suffix))已提交，重新打开 App 会自动继续查询；也可点「重新精转」。"
          : "上次精转中断且未提交成功(任务 …\(suffix))：重新打开 App 会自动重新上传提交；也可点「重新精转」。"
      }
      return "上次未正常结束，精转未提交成功；可点「重新精转」重新提交。"
    }
    return "权威转写来自会后精转，还没跑完。会中的实时速记不会写进这里——它精度不够，不当证据用。"
  }

  /// 转写页正文的结构化行(全局改名 + 单段覆盖都已结算)。
  func transcriptRows(for item: MeetingLibraryItem) -> [TranscriptDisplayRow] {
    transcriptPresentation(for: item).rows
  }

  /// 同一场会议一次只结算一份快照。public 供独立 verification 直接证明缓存失效边界。
  public func transcriptPresentation(for item: MeetingLibraryItem) -> TranscriptPresentation {
    if let cached = transcriptPresentationCache[item.id] {
      return cached
    }
    guard let transcript = artifacts(for: item).transcript else {
      let empty = TranscriptPresentation(rows: [], speakerLabels: [], displaySpeakers: [])
      transcriptPresentationCache[item.id] = empty
      return empty
    }
    let rows = TranscriptSpeakerNaming.rows(
      in: transcript,
      names: item.speakerNames,
      overrides: item.speakerOverrides
    )
    var seenLabels: Set<String> = []
    var labels: [String] = []
    var seenDisplayNames: Set<String> = []
    var displayNames: [String] = []
    for case .speech(let line) in rows {
      if line.originalSpeaker != TranscriptSpeakerNaming.selfSpeakerLabel,
        seenLabels.insert(line.originalSpeaker).inserted
      {
        labels.append(line.originalSpeaker)
      }
      if seenDisplayNames.insert(line.speaker).inserted {
        displayNames.append(line.speaker)
      }
    }
    let presentation = TranscriptPresentation(
      rows: rows,
      speakerLabels: labels,
      displaySpeakers: displayNames
    )
    transcriptPresentationCache[item.id] = presentation
    transcriptPresentationBuildCount += 1
    return presentation
  }

  func invalidateTranscriptPresentation(forMeetingID id: String) {
    transcriptPresentationCache.removeValue(forKey: id)
  }

  func onePager(for item: MeetingLibraryItem) -> MeetingMinutesDocument? {
    MeetingArtifactProjection.onePager(from: artifacts(for: item))
  }

  func actionItemsCopyText(for item: MeetingLibraryItem) -> String? {
    guard let document = artifacts(for: item).structuredMinutes else { return nil }
    return ActionItemsRenderer.renderPlainText(title: item.title, document: document)
  }

  func actionItemCount(for item: MeetingLibraryItem) -> Int {
    guard let document = artifacts(for: item).structuredMinutes else { return 0 }
    return SummaryActionItem.mineFirst(document.actionItems).count
  }

  func actionItemsCopyDisabledHelp(for item: MeetingLibraryItem) -> String? {
    guard artifacts(for: item).structuredMinutes != nil else {
      return "旧会议无结构化行动项，可在纪要页复制"
    }
    return actionItemsCopyText(for: item) == nil
      ? "这场会议没有明确行动项"
      : nil
  }

  func reportCopySuccess(_ notice: String) {
    copyNoticeTask?.cancel()
    exportError = nil
    exportNotice = notice
    copyNoticeTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled, self?.exportNotice == notice else { return }
      self?.exportNotice = nil
    }
  }

  func isLegacyOnePager(_ item: MeetingLibraryItem) -> Bool {
    artifacts(for: item).structuredMinutes == nil
  }

  func noteEntries(for item: MeetingLibraryItem) -> [MeetingNoteEntry] {
    guard let notes = artifacts(for: item).notes else { return [] }
    return notes.components(separatedBy: .newlines).enumerated().compactMap { index, rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { return nil }
      let pattern = #"^[-*]\s+\[(\d{2}:\d{2}:\d{2})\]\s*(.*)$"#
      guard
        let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: line,
          range: NSRange(line.startIndex..., in: line)
        ),
        let timeRange = Range(match.range(at: 1), in: line),
        let textRange = Range(match.range(at: 2), in: line)
      else {
        return MeetingNoteEntry(id: index, timecode: nil, text: line)
      }
      return MeetingNoteEntry(
        id: index,
        timecode: String(line[timeRange]),
        text: String(line[textRange])
      )
    }
  }

  public func jumpToTranscript(_ seconds: TimeInterval) {
    if tab != .transcript {
      returnTrail = LibraryReturnTrail(sourceTab: tab)
    }
    speakerFilter = nil
    pendingOverrideLine = nil
    tab = .transcript
    transcriptJumpRequest = TranscriptJumpRequest(seconds: seconds)
  }

  // 全库搜索/认名预填/高亮与排除 见同名 +扩展文件(批3 拆分);导入段含存储属性留此。

  // MARK: - 导入外部录音

  /// 选文件后的只读探测错误。探测不落盘、不花钱,丢了也只是这张表单没弹出来,
  /// 所以留在窗口级 model;真正的导入任务错误在协调者上。
  @Published private var probeImportError: String?
  @Published var importVolumeRiskMessage: String?
  /// 体积闸门待确认时暂存的请求。
  private var pendingImportRequest: ExternalRecordingImport.Request?

  var importError: String? { probeImportError ?? postMeetingTasks.importError }

  var isImporting: Bool { postMeetingTasks.isImporting }

  func beginImport(sourceFileURL: URL) {
    probeImportError = nil
    postMeetingTasks.clearImportError()
    importVolumeRiskMessage = nil
    pendingImportRequest = nil
    Task { [weak self] in
      guard let self else { return }
      guard let probe = await ExternalRecordingImport.probe(sourceFileURL: sourceFileURL) else {
        await MainActor.run {
          self.probeImportError =
            ExternalRecordingImport.ImportError.emptySource.localizedDescription
        }
        return
      }
      await MainActor.run {
        self.pendingImportSheet = ImportSheetState(
          sourceFileURL: sourceFileURL,
          suggestedTitle: sourceFileURL.deletingPathExtension().lastPathComponent,
          probe: probe
        )
      }
    }
  }

  @Published var pendingImportSheet: ImportSheetState?

  struct ImportSheetState: Identifiable {
    let id = UUID()
    let sourceFileURL: URL
    let suggestedTitle: String
    let probe: ExternalRecordingImport.ProbeResult
  }

  func confirmImport(
    title: String,
    startedAt: Date,
    language: MeetingLanguage,
    acceptVolumeRisk: Bool
  ) {
    guard let sheet = pendingImportSheet else { return }
    let request = ExternalRecordingImport.Request(
      sourceFileURL: sheet.sourceFileURL,
      title: title,
      startedAt: startedAt,
      language: language,
      acceptVolumeRisk: acceptVolumeRisk
    )
    if sheet.probe.exceedsVolumeGate, !acceptVolumeRisk {
      importVolumeRiskMessage =
        ExternalRecordingImport.ImportError.volumeRiskRequiresConfirmation(
          bytes: sheet.probe.fileSizeBytes
        ).localizedDescription
      pendingImportRequest = request
      return
    }
    pendingImportSheet = nil
    importVolumeRiskMessage = nil
    pendingImportRequest = nil
    runImport(request)
  }

  func acceptVolumeRiskAndImport() {
    guard let pending = pendingImportRequest else { return }
    let request = ExternalRecordingImport.Request(
      sourceFileURL: pending.sourceFileURL,
      title: pending.title,
      startedAt: pending.startedAt,
      language: pending.language,
      acceptVolumeRisk: true
    )
    pendingImportRequest = nil
    importVolumeRiskMessage = nil
    pendingImportSheet = nil
    runImport(request)
  }

  func cancelVolumeRisk() {
    pendingImportRequest = nil
    importVolumeRiskMessage = nil
  }

  /// 导入与「导入后自动开精转」的所有权都在协调者:迁移前这条链挂在本 model 的
  /// 弱引用上,导入落地期间 model 被 remount 就把链式启动静默丢了
  /// (全套里唯一真正丢工作的地方)。
  private func runImport(_ request: ExternalRecordingImport.Request) {
    probeImportError = nil
    let providers =
      meetingStore.listMeetings().first?.metadata.providers
      ?? ProviderRegistry().defaultConfiguration().bindings
    // 导航锚点在按下按钮的当场记下:落地时用户还停在这里才跟着跳。
    importSelectionAnchor = selectedID
    awaitsImportNavigation = postMeetingTasks.startImport(request, providers: providers)
  }

}
