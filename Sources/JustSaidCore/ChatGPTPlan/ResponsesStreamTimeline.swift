import Foundation
import Synchronization

/// 一次 Responses 调用的流时间线(10-06):只记时间、计数与固定事件类型,不碰正文。
/// Anthropic Messages 适配器(10-08)共用同一份时间线与白名单。
///
/// 成功与失败的 `modelCall.finish` 都从这里取数,失败时也能看出被切断前模型在思考还是在写正文、
/// 服务端多久没发字节。所有更新都在短临界区内完成,不跨 await,也不回调外部代码。
final class ResponsesStreamTimeline: Sendable {
  /// 白名单外的事件类型记 `other`,避免把服务端新增或异常的字符串原样写进账本。
  static let knownEventTypes: Set<String> = [
    "response.created", "response.in_progress", "response.queued",
    "response.output_item.added", "response.output_item.done",
    "response.reasoning_summary_part.added", "response.reasoning_summary_part.done",
    "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
    "response.content_part.added", "response.content_part.done",
    "response.output_text.delta", "response.output_text.done",
    "response.refusal.delta", "response.refusal.done",
    "response.completed", "response.failed", "response.incomplete", "error",
    // Anthropic Messages(10-08)。
    "message_start", "content_block_start", "content_block_delta", "content_block_stop",
    "message_delta", "message_stop", "ping",
  ]

  /// 账本里 `lastEventType` 允许的全部取值:已知事件类型,加时间线自己写的 `comment` 与 `other`。
  static let recordableEventTypes = knownEventTypes.union(["comment", "other"])

  struct Snapshot: Sendable {
    var firstFrameMs: Int?
    var responseBytes: Int
    var firstReasoningMs: Int?
    var firstOutputMs: Int?
    var reasoningSummaryEvents: Int
    var outputDeltaEvents: Int
    var keepaliveLines: Int
    var maxGapMs: Int?
    var lastByteAgoMs: Int?
    var lastEventType: String?
  }

  private struct State {
    var openedAt: Date?
    var lastLineAt: Date?
    var firstFrameAt: Date?
    var firstReasoningAt: Date?
    var firstOutputAt: Date?
    var bytes = 0
    var reasoningSummaryEvents = 0
    var outputDeltaEvents = 0
    var keepaliveLines = 0
    var maxGap: TimeInterval?
    var lastEventType: String?
  }

  private let startedAt: Date
  private let state = Mutex(State())

  init(startedAt: Date) {
    self.startedAt = startedAt
  }

  /// 开流成功(响应头已到)、开始读第一行之前。
  func opened(at now: Date = Date()) {
    state.withLock { $0.openedAt = now }
  }

  /// 收到一行(含空行与注释行)。间隔从开流时刻算起。
  func line(bytes: Int, isComment: Bool, at now: Date = Date()) {
    state.withLock { state in
      state.bytes += bytes
      if let previous = state.lastLineAt ?? state.openedAt {
        let gap = now.timeIntervalSince(previous)
        state.maxGap = max(state.maxGap ?? 0, gap)
      }
      state.lastLineAt = now
      if isComment {
        state.keepaliveLines += 1
        state.lastEventType = "comment"
      }
    }
  }

  /// 第一个带负载的事件。
  func firstFrame(at now: Date = Date()) {
    state.withLock { state in
      if state.firstFrameAt == nil { state.firstFrameAt = now }
    }
  }

  func event(_ type: String) {
    let safe = Self.knownEventTypes.contains(type) ? type : "other"
    state.withLock { $0.lastEventType = safe }
  }

  /// 协议层心跳事件(Anthropic 的 `ping`);注释行心跳由 `line(bytes:isComment:)` 计入。
  func keepalive() {
    state.withLock { $0.keepaliveLines += 1 }
  }

  /// 非空的推理摘要增量。
  func reasoningDelta(at now: Date = Date()) {
    state.withLock { state in
      state.reasoningSummaryEvents += 1
      if state.firstReasoningAt == nil { state.firstReasoningAt = now }
    }
  }

  /// 非空的正文增量。
  func outputDelta(at now: Date = Date()) {
    state.withLock { state in
      state.outputDeltaEvents += 1
      if state.firstOutputAt == nil { state.firstOutputAt = now }
    }
  }

  /// 流是否已打开(2xx 响应头已到、开始读行)。开流前的非 2xx 不会走到这里。
  var streamOpened: Bool { state.withLock { $0.openedAt != nil } }

  func snapshot(at now: Date = Date()) -> Snapshot {
    let startedAt = self.startedAt
    func ms(_ date: Date?) -> Int? { date.map { Int($0.timeIntervalSince(startedAt) * 1_000) } }
    return state.withLock { state in
      Snapshot(
        firstFrameMs: ms(state.firstFrameAt),
        responseBytes: state.bytes,
        firstReasoningMs: ms(state.firstReasoningAt),
        firstOutputMs: ms(state.firstOutputAt),
        reasoningSummaryEvents: state.reasoningSummaryEvents,
        outputDeltaEvents: state.outputDeltaEvents,
        keepaliveLines: state.keepaliveLines,
        maxGapMs: state.maxGap.map { Int($0 * 1_000) },
        lastByteAgoMs: (state.lastLineAt ?? state.openedAt).map {
          Int(now.timeIntervalSince($0) * 1_000)
        },
        lastEventType: state.lastEventType)
    }
  }
}
