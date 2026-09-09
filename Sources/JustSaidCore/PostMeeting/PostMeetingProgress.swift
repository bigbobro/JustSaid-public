import Foundation

/// 会后处理的瞬时进度事件。进度状态本身不进 meeting.json;
/// 纪要正文流式写入版本文件是**产物**,见 D1 / design §8。
public enum PostMeetingProgress: Sendable, Equatable {
  case composing
  case uploading
  case submitting
  case awaitingTranscription(
    vendorState: VendorState,
    origin: AwaitingOrigin,
    elapsed: TimeInterval
  )
  case writingTranscript
  case cleaningRemote
  /// 推理档:尚无正文字符,但 reasoning 已在到。
  case minutesThinking(language: MeetingLanguage, elapsed: TimeInterval)
  /// 正文已开始写出。**带上已生成的正文本身**,界面据此把正文一行行铺出来
  /// (AC13:用户要看见"在生成什么",不只是"有东西在动")。
  ///
  /// 字数**不再单独传**,一律由 `accumulated.count` 算出——两个字段分开传就会出现
  /// "说 1200 字、正文其实只有 800"的撒谎形态,与账本纪律同源。
  /// token 仍然不报:它只在末帧 usage 里,实时估算等于编数字。
  case minutesWriting(language: MeetingLanguage, accumulated: String, elapsed: TimeInterval)
  /// R1(08-20 传输韧性单):传输类失败后的自动重试,`attempt` 是即将开始的第几跳
  /// (自动重试即 2)。重试是又一次完整计费调用,必须对用户可见,不得静默花钱。
  case minutesRetrying(language: MeetingLanguage, attempt: Int)

  public enum VendorState: Sendable, Equatable {
    case pending
    case processing
  }

  public enum AwaitingOrigin: Sendable, Equatable {
    case newSubmission
    case recovery
  }

  /// UI 文案。只陈述已知事实:阶段名、语种、字数、已用时长;不含百分比或预计剩余。
  public var displayText: String {
    switch self {
    case .composing:
      return "合成立体声…"
    case .uploading:
      return "上传录音…"
    case .submitting:
      return "提交精转任务…"
    case .awaitingTranscription(let vendorState, let origin, let elapsed):
      let vendorLabel: String =
        switch vendorState {
        case .pending: "火山排队中"
        case .processing: "火山处理中"
        }
      let prefix =
        switch origin {
        case .newSubmission: "已提交"
        case .recovery: "继续查询原任务"
        }
      return "\(prefix)，\(vendorLabel) · 已等 \(Self.formatElapsed(elapsed))"
    case .writingTranscript:
      return "写入转写…"
    case .cleaningRemote:
      return "清理云端临时文件…"
    case .minutesThinking(let language, let elapsed):
      return "\(Self.languageLabel(language)) · 思考中 · 已用 \(Self.formatElapsed(elapsed))"
    case .minutesWriting(let language, let accumulated, let elapsed):
      return
        "\(Self.languageLabel(language)) · 已生成 \(Self.formatCharacterCount(accumulated.count)) 字 · 已用 \(Self.formatElapsed(elapsed))"
    case .minutesRetrying(let language, let attempt):
      return "\(Self.languageLabel(language)) · 网络中断，自动重试中（第 \(attempt) 次尝试）"
    }
  }

  /// 正在写出的纪要正文(仅 `minutesWriting` 有)。界面用它实时铺正文;
  /// 这是**瞬时 UI 用的副本**,落盘的产物由管线自己写进 `.md.partial`。
  public var minutesLiveContent: String? {
    if case .minutesWriting(_, let accumulated, _) = self {
      return accumulated
    }
    return nil
  }

  /// 精转六阶段的稳定标识(用于断言顺序);纪要进度不在此列。
  public var transcriptionStageID: String? {
    switch self {
    case .composing: return "composing"
    case .uploading: return "uploading"
    case .submitting: return "submitting"
    case .awaitingTranscription: return "awaitingTranscription"
    case .writingTranscript: return "writingTranscript"
    case .cleaningRemote: return "cleaningRemote"
    case .minutesThinking, .minutesWriting, .minutesRetrying: return nil
    }
  }

  public var minutesLanguage: MeetingLanguage? {
    switch self {
    case .minutesThinking(let language, _), .minutesWriting(let language, _, _),
      .minutesRetrying(let language, _):
      return language
    default:
      return nil
    }
  }

  private static func languageLabel(_ language: MeetingLanguage) -> String {
    switch language {
    case .chinese: return "中文纪要"
    case .english: return "英文纪要"
    // 进度条展示文案,auto 不进纪要生成路径;给个中性兜底,不为展示层断言。
    case .auto: return "纪要"
    }
  }

  private static func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remaining = total % 60
    if hours > 0 {
      return "\(hours) 小时 \(minutes) 分 \(remaining) 秒"
    }
    if minutes > 0 {
      return "\(minutes) 分 \(String(format: "%02d", remaining)) 秒"
    }
    return "\(remaining) 秒"
  }

  private static func formatCharacterCount(_ count: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: max(0, count))) ?? "\(max(0, count))"
  }
}

/// LLM 流式增量的轻量出口。只报字符维度;token 只在末帧 usage 里,不得实时估算。
/// `accumulatedContent` 给管线做产物流式落盘,不是给 UI 估算 token 用的。
public enum LLMStreamProgress: Sendable, Equatable {
  case thinking
  case writing(characters: Int, accumulatedContent: String)
}

/// 把同步的管线进度回调桥接成单一有序消费流。`AsyncStream` 会缓冲回调事件，
/// UI 因而不会为每一帧各起一个无序 Task，也不会在管线结束后被迟到事件覆盖终态。
public final class PostMeetingProgressChannel: Sendable {
  public let events: AsyncStream<PostMeetingProgress>
  private let continuation: AsyncStream<PostMeetingProgress>.Continuation

  public init() {
    let pair = AsyncStream<PostMeetingProgress>.makeStream()
    events = pair.stream
    continuation = pair.continuation
  }

  public func yield(_ progress: PostMeetingProgress) {
    continuation.yield(progress)
  }

  public func finish() {
    continuation.finish()
  }

  deinit {
    continuation.finish()
  }
}

extension PostMeetingStage {
  /// 仅更新仍在运行的阶段；相同文案不重复发布，避免 SwiftUI 无意义重绘。
  @discardableResult
  public mutating func updateRunningDetail(from progress: PostMeetingProgress) -> Bool {
    guard isRunning else { return false }
    let detail = progress.displayText
    guard runningDetail != detail else { return false }
    self = .running(detail: detail)
    return true
  }
}
