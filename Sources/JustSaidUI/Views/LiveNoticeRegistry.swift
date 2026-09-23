import Foundation
import JustSaidCore

/// 会中系统提示的**唯一判定处**。
///
/// 为什么需要它:README 第 78 行要求仲裁——闲聊中与麦克风已暂停永远显示、不折叠,
/// 其余按警示 → 信息 → 中性只露第一条,其他收进「还有 N 条提示」。
/// 但今天 `MainWorkspaceView+Banners.swift` 的九个横幅各自在组件内部判显隐
/// (红线 6「显隐判断收在组件内部,调用点不加门」),**调用点根本不知道哪几条在场**,
/// 无从仲裁。要仲裁就得先把「哪些提示成立」变成一份数据。
///
/// 这对红线 6 是加强不是违反:今天显隐逻辑散在九个组件里,集中之后**仍然只有一个地方
/// 决定显隐**,而且可以脱离视图树单测——这正是红线 6 想要的「不在调用点重复判断」。
///
/// **本文件只做判定,不做渲染。** 条件逐条对照原组件搬来,不重写:漏一条就是
/// 「本该出现的提示不出现」,在录音路径上这比多显示一条严重得多。
public enum LiveNoticeLevel: Int, Comparable, Sendable {
  /// 整宽压在顶栏之下、舞台之上,同时弹一次系统提示。全 app 只有录音失败。
  case interrupt = 0
  /// 会丢内容或要你处理的事。
  case warn = 1
  /// 正在发生、不需要你做什么的事。
  case info = 2
  /// 只是建议,不自动改任何东西。不用警示色。
  case hint = 3

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 一条成立的提示。`id` 稳定,用于探针与折叠状态。
public struct LiveNotice: Identifiable, Equatable, Sendable {
  public let id: String
  public let level: LiveNoticeLevel
  /// 永不折叠。闲聊中与麦克风已暂停两条——忘封口会真丢内容,暂停是隐私工具;
  /// 外加会后处理进行中,理由见 `notices(for:)` 里那一条的注释。
  public let isPinned: Bool
  /// 同一级内部的先后。**Swift 的 `sorted` 不保证稳定**,不给显式次序的话
  /// 同级几条的上下顺序会飘,而「哪条露在外面」正是仲裁的全部意义。
  /// 排序依据:会丢多少东西。
  public let rank: Int

  public init(id: String, level: LiveNoticeLevel, isPinned: Bool = false, rank: Int) {
    self.id = id
    self.level = level
    self.isPinned = isPinned
    self.rank = rank
  }
}

/// 判定所需的全部输入。刻意用平铺的值而不是整个 session 对象,
/// 这样验证程序能直接驱动矩阵,不用搭起半个 app。
public struct LiveNoticeInputs: Equatable, Sendable {
  public var isRecording: Bool
  public var isFailed: Bool
  /// stopping 或 completed,会后横幅的那道 phase 门。
  public var isAfterMeeting: Bool
  public var hasIssue: Bool
  public var microphoneRouteNotice: String?
  public var hasLegHealthNotice: Bool
  public var openChatRangeStart: TimeInterval?
  public var isMicrophonePaused: Bool
  public var exclusionError: String?
  public var partialCaptureNotice: String?
  public var postMeetingStage: PostMeetingStage
  public var hasLanguageMismatch: Bool
  public var isShowingLowRecognition: Bool

  public init(
    isRecording: Bool = false,
    isFailed: Bool = false,
    isAfterMeeting: Bool = false,
    hasIssue: Bool = false,
    microphoneRouteNotice: String? = nil,
    hasLegHealthNotice: Bool = false,
    openChatRangeStart: TimeInterval? = nil,
    isMicrophonePaused: Bool = false,
    exclusionError: String? = nil,
    partialCaptureNotice: String? = nil,
    postMeetingStage: PostMeetingStage = .none,
    hasLanguageMismatch: Bool = false,
    isShowingLowRecognition: Bool = false
  ) {
    self.isRecording = isRecording
    self.isFailed = isFailed
    self.isAfterMeeting = isAfterMeeting
    self.hasIssue = hasIssue
    self.microphoneRouteNotice = microphoneRouteNotice
    self.hasLegHealthNotice = hasLegHealthNotice
    self.openChatRangeStart = openChatRangeStart
    self.isMicrophonePaused = isMicrophonePaused
    self.exclusionError = exclusionError
    self.partialCaptureNotice = partialCaptureNotice
    self.postMeetingStage = postMeetingStage
    self.hasLanguageMismatch = hasLanguageMismatch
    self.isShowingLowRecognition = isShowingLowRecognition
  }
}

public enum LiveNoticeRegistry {
  /// 所有可能出现的提示 id。定点验证用它逐条核对 registry 有没有漏。
  public static let allIdentifiers = [
    "recording-failure", "engine-issue", "microphone-route", "leg-health",
    "chat-open", "microphone-paused", "exclusion-error", "partial-capture",
    "post-meeting", "language-mismatch", "low-recognition",
  ]

  /// 当前成立的提示,已按「打断 → 警示 → 信息 → 中性」排好序。
  ///
  /// 每一条后面注明它搬自哪里。**改这里之前先回去看原处**——条件是逐字搬的。
  public static func notices(for inputs: LiveNoticeInputs) -> [LiveNotice] {
    var result: [LiveNotice] = []

    // recordingFailureBanner 的 if 支(Banners.swift:182)。
    if inputs.isFailed, inputs.hasIssue {
      result.append(.init(id: "recording-failure", level: .interrupt, rank: 0))
    }
    // recordingFailureBanner 的 else-if 支(同上 196):录制中带 issue = 引擎异常。
    if inputs.isRecording, inputs.hasIssue {
      result.append(.init(id: "engine-issue", level: .warn, rank: 2))
    }
    // MicrophoneInputRouteBanner(同上 210):status.notice 非空才画。
    if inputs.microphoneRouteNotice != nil {
      result.append(.init(id: "microphone-route", level: .warn, rank: 4))
    }
    // legHealthBanner(同上 99):录制中 + 有 startedAt + notices 非空。
    if inputs.isRecording, inputs.hasLegHealthNotice {
      result.append(.init(id: "leg-health", level: .warn, rank: 1))
    }
    // ChatExclusionBanner(ExclusionSupport.swift:94):有未封口区间。
    // 永不折叠:忘封口 = 后半场不进纪要,会真丢内容。
    if inputs.openChatRangeStart != nil {
      result.append(.init(id: "chat-open", level: .warn, isPinned: true, rank: 0))
    }
    // MicrophonePauseBanner(MicrophonePauseBanner.swift:37)。永不折叠:它是隐私工具,
    // 与闲聊定位不同(暂停 = 本侧什么都不记;闲聊 = 照录但不进纪要),两者可同时在场。
    if inputs.isMicrophonePaused {
      result.append(.init(id: "microphone-paused", level: .warn, isPinned: true, rank: 1))
    }
    // exclusionError(Banners.swift:31)。
    if inputs.exclusionError != nil {
      result.append(.init(id: "exclusion-error", level: .warn, rank: 3))
    }
    // partialCaptureNotice(同上 57):phase 为 completed/stopping 且单路缺失。
    if inputs.isAfterMeeting, inputs.partialCaptureNotice != nil {
      result.append(.init(id: "partial-capture", level: .warn, rank: 5))
    }
    // PostMeetingStatusBanner(同上 81):同一道 phase 门;`.none` 时整条结构不存在。
    // 失败是警示,进行中与完成是信息(README 第 73–74 行)。
    if inputs.isAfterMeeting, inputs.postMeetingStage != .none {
      let isFailure: Bool
      if case .failed = inputs.postMeetingStage { isFailure = true } else { isFailure = false }
      let level: LiveNoticeLevel = isFailure ? .warn : .info
      // **会后处理进行中永不折叠。** Banners.swift:38–40 那段注释是承重的:
      // 2026-07-29 实测反馈「点击结束之后看不到后续的内容了」——会后状态只在 Core 里
      // 有字段、界面从不呈现,且没有进入本场产物的入口。如果让「部分录音」(警示)
      // 把它(信息)压进折叠,就是把那个 bug 原样放回去。散会后这条是唯一的去向指引。
      result.append(.init(id: "post-meeting", level: level, isPinned: true, rank: 6))
    }
    // languageMismatchBanner(同上 139):录制中 + 检测到错配。
    if inputs.isRecording, inputs.hasLanguageMismatch {
      result.append(.init(id: "language-mismatch", level: .hint, rank: 0))
    }
    // lowRecognitionBanner(同上 160):录制中 + 低产出 + **错配不在场**(两者不叠加)。
    //
    // 这条留在警示级,不跟语言错配一起降中性。文案自己写着「可能选错了,
    // **或者麦克风没有进声**」——后半句是采集问题,而 legHealthBanner 只管帧停摆,
    // 静音但有帧的数据在它眼里是 healthy,所以低产出是「麦克风没进声」这个场景的
    // 唯一信号。一条横幅背着两种严重度,按最重的那种归级。
    // 真正的修是按电平把它拆成两条(电平近零 → 警示家族;电平正常但识别为空 → 中性),
    // 那要电平历史,是功能,不在本批。
    if inputs.isRecording, inputs.isShowingLowRecognition, !inputs.hasLanguageMismatch {
      result.append(.init(id: "low-recognition", level: .warn, rank: 6))
    }

    return result.sorted {
      $0.level == $1.level ? $0.rank < $1.rank : $0.level < $1.level
    }
  }

  /// 仲裁结果:永不折叠的全画,其余只露第一条,剩下的报个数(README 第 78 行)。
  ///
  /// 打断级不参与折叠——它有自己的位置(顶栏之下、舞台之上),也从不与别的并列。
  public static func arbitrate(
    _ notices: [LiveNotice],
    isExpanded: Bool = false
  ) -> (interrupt: LiveNotice?, visible: [LiveNotice], collapsedCount: Int) {
    let interrupt = notices.first { $0.level == .interrupt }
    let rest = notices.filter { $0.level != .interrupt }
    let pinned = rest.filter(\.isPinned)
    let foldable = rest.filter { !$0.isPinned }
    if isExpanded {
      return (interrupt, pinned + foldable, 0)
    }
    // 已经按级排过序,第一条就是最高级的那条。
    let lead = foldable.first.map { [$0] } ?? []
    return (interrupt, pinned + lead, max(0, foldable.count - lead.count))
  }
}
