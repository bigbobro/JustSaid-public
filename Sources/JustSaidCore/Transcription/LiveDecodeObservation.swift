import Foundation

/// 会中一次实际解码的观察。只在内存中流转:不持久化、不 Codable。
///
/// `TranscriptSegment`、`results`、`transcript-live.jsonl` 与 `liveSegments` 的合同不变;
/// 观察是 `results` 的超集,额外送达两类旧路径在发射前就丢掉的信息:
/// partial 实际解码的音频范围(本地引擎只解码预览尾部),以及文本为空或与上一条
/// partial 相同、因而没有发出 segment 的解码。
public struct LiveDecodeObservation: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case partial
    case final
  }

  public let source: AudioSource
  public let kind: Kind
  /// 本次解码实际送入识别器的音频范围,与 `TranscriptSegment.t0/t1` 同一时钟。
  public let decodedRange: ClosedRange<TimeInterval>
  /// 识别器本次返回的文本(去首尾空白,可为空);与上一条相同也照样送达。
  public let text: String
  /// 本次解码按旧路径发出的 segment,与 `results` 中的那一条完全相同;没有发出时为 nil。
  public let emittedSegment: TranscriptSegment?

  public init(
    source: AudioSource,
    kind: Kind,
    decodedRange: ClosedRange<TimeInterval>,
    text: String,
    emittedSegment: TranscriptSegment?
  ) {
    self.source = source
    self.kind = kind
    self.decodedRange = decodedRange
    self.text = text
    self.emittedSegment = emittedSegment
  }
}

/// 能按解码逐条送出观察的会中引擎。消费方只迭代 `decodeObservations`,不再另起任务读 `results`。
public protocol LiveDecodeObservationProviding: TranscriberEngine {
  /// 按发生顺序每次解码一条;在引擎 `stop()` 送出最后的终稿之后结束。
  /// 首次读取时才建立(之后无界缓冲,不丢其中的 segment);只读 `results` 的调用方不保留任何观察。
  /// 须在送入音频之前读取,读取之前发生的解码不会补发。
  var decodeObservations: AsyncStream<LiveDecodeObservation> { get }
  /// 截至调用时该路已交给引擎的音频末端,与 `decodedRange` 同一时钟;尚未送入时为 nil。
  /// 只增不减,作为重新开启屏障只允许偏晚:本地引擎含重采样取整余量,不早于已送入音频的任何解码终点;
  /// Apple 按送入时长累计,分析器输入丢块只会让它更晚,格式转换取整见引擎说明。
  func inputAudioEnd(for source: AudioSource) -> TimeInterval?
}

/// 按需建立的观察通道:没有消费方时 `yield` 直接丢弃,不为只读 `results` 的调用方积压整场解码。
/// Safety invariant: stream/continuation/isFinished are lock-protected by `lock`;
/// `AsyncStream.Continuation` itself is thread-safe, so yield/finish run outside the lock.
final class LiveDecodeObservationChannel: @unchecked Sendable {
  private let lock = NSLock()
  private var stream: AsyncStream<LiveDecodeObservation>?
  private var continuation: AsyncStream<LiveDecodeObservation>.Continuation?
  private var isFinished = false

  var observations: AsyncStream<LiveDecodeObservation> {
    lock.lock()
    defer { lock.unlock() }
    if let stream {
      return stream
    }
    let made = AsyncStream.makeStream(
      of: LiveDecodeObservation.self,
      bufferingPolicy: .unbounded
    )
    if isFinished {
      made.continuation.finish()
    }
    stream = made.stream
    continuation = made.continuation
    return made.stream
  }

  var hasConsumer: Bool {
    lock.lock()
    defer { lock.unlock() }
    return continuation != nil
  }

  func yield(_ observation: LiveDecodeObservation) {
    lock.lock()
    let continuation = continuation
    lock.unlock()
    continuation?.yield(observation)
  }

  func finish() {
    lock.lock()
    isFinished = true
    let continuation = continuation
    lock.unlock()
    continuation?.finish()
  }
}
