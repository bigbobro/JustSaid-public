import Foundation
import OSLog

/// 允许去重器在只删除麦克风片段中的回声分句时，返回保留原元数据的文本副本。
public protocol EchoDeduplicatableSegment {
  func replacingEchoText(with text: String) -> Self
}

extension TranscriptSegment: EchoDeduplicatableSegment {
  public func replacingEchoText(with text: String) -> TranscriptSegment {
    TranscriptSegment(
      t0: t0,
      t1: t1,
      text: text,
      isFinal: isFinal,
      source: source
    )
  }
}

/// 双录回声去重。
///
/// 麦克风不戴耳机时会把扬声器放出来的对方语音一起录进去,于是同一句话在两路各出现一次,
/// 而麦克风那一份还被记成「我」说的。2026-07-29 的真实会议里这条几乎毁掉了全部可读性:
/// 9 分钟转写里每句话出现两遍、说话人归属全乱,会中总结也把对方的话写成「我确认……」。
///
/// 规则(方向不可反):
/// - **只丢麦克风侧**。系统侧不可能含用户自己的声音,永远保留;
/// - 麦克风长段按句读拆开逐句判定,只删确认是回声的分句,保留同段里的用户真话;
/// - 判定用「时间窗内的系统侧文本拼接」做包含/近似匹配,而不是逐条比对——
///   两路的断句点不一致,一条麦克风片段常横跨两条系统片段;
/// - 匹配不上就保留。宁可留一句重复,也不能吞掉用户自己说过的话。
public enum EchoDeduplicator {
  public struct Result<Segment> {
    public let segments: [Segment]
    public let droppedCount: Int
  }

  /// 两路时间轴各自独立,同一句话的时间戳实测相差 0~2 秒;取 5 秒窗留足余量。
  static let timeTolerance: TimeInterval = 5
  /// 水位线再留 1 秒余量，避免刚越过窗口边界的系统侧 partial 让结果过早冻结。
  private static let watermarkSafetyMargin: TimeInterval = 1
  /// 逐字相同才算回声的下限。同一时刻用词完全一致本身就是强信号,
  /// 所以这里可以放到 4 个字,才抓得住「喂，听不到吗？」这类短回声。
  static let minimumExactLength = 4
  /// 允许用词有差异的模糊判定下限。卡在 6 个字以上,是为了保住
  /// 「我觉得可以」这种短而有承诺含量的自述——它与对方的「你觉得可以吗」够像,
  /// 一旦放开模糊匹配就会被误删。
  static let minimumFuzzyLength = 6
  /// 三元组覆盖率阈值:同一句话经两路识别文字会有小差异
  /// (实测「还是怎么说话」/「还是怎么情况」、「梅梅能听到」/「没人能听到」),
  /// 卡得太严会漏掉一半回声。
  static let coverageThreshold = 0.62

  /// 会中两处消费者各持有一个实例。稳定前缀依据系统侧水位冻结，只有尾部重算；
  /// 若收到乱序修订，则撤销受影响的冻结结果，保证与同一快照的整批结果一致。
  public struct IncrementalFilter {
    private var frozenInput: [TranscriptSegment] = []
    private var frozenDecisions: [TranscriptDecision] = []
    private var indexedSystemSegments: [TranscriptSegment] = []
    private var systemIndex = SystemWindowIndex()
    private var lastInput: [TranscriptSegment] = []
    private var lastResult: Result<TranscriptSegment>?

    public init() {}

    public mutating func reset() {
      frozenInput = []
      frozenDecisions = []
      indexedSystemSegments = []
      systemIndex = SystemWindowIndex()
      lastInput = []
      lastResult = nil
    }

    public mutating func removeEcho(
      from segments: [TranscriptSegment]
    ) -> Result<TranscriptSegment> {
      if segments == lastInput, let lastResult {
        return lastResult
      }

      guard Self.isChronological(segments) else {
        reset()
        let result = EchoDeduplicator.removeEcho(from: segments)
        lastInput = segments
        lastResult = result
        return result
      }

      let systemSegments =
        segments
        .filter { $0.source == .others }
        .sorted(by: Self.systemSegmentOrder)
      let systemChange = updateSystemIndex(with: systemSegments)

      let unchangedFrozenCount = Self.commonPrefixCount(frozenInput, segments)
      if unchangedFrozenCount < frozenInput.count {
        truncateFrozen(to: unchangedFrozenCount)
      }
      if let systemChange {
        invalidateFrozenMicrophoneDecisions(overlapping: systemChange)
      }

      var decisions = frozenDecisions
      decisions.reserveCapacity(segments.count)
      for segment in segments.dropFirst(frozenDecisions.count) {
        decisions.append(EchoDeduplicator.evaluate(segment, systemIndex: systemIndex))
      }

      let watermark =
        systemSegments
        .filter(\.isFinal)
        .map(\.t1)
        .max()
      if let watermark {
        let frozenBefore =
          watermark - EchoDeduplicator.timeTolerance
          - EchoDeduplicator.watermarkSafetyMargin
        var nextFrozenCount = frozenDecisions.count
        while nextFrozenCount < segments.count {
          let segment = segments[nextFrozenCount]
          guard segment.isFinal, segment.t1 < frozenBefore else {
            break
          }
          nextFrozenCount += 1
        }
        if nextFrozenCount > frozenDecisions.count {
          frozenInput = Array(segments.prefix(nextFrozenCount))
          frozenDecisions = Array(decisions.prefix(nextFrozenCount))
        }
      }

      let result = Self.result(from: decisions)
      lastInput = segments
      lastResult = result
      return result
    }

    private mutating func updateSystemIndex(
      with segments: [TranscriptSegment]
    ) -> ClosedRange<TimeInterval>? {
      let commonCount = Self.commonPrefixCount(indexedSystemSegments, segments)
      guard
        commonCount != indexedSystemSegments.count
          || commonCount != segments.count
      else {
        return nil
      }

      let changed = indexedSystemSegments.dropFirst(commonCount) + segments.dropFirst(commonCount)
      let lowerBound = changed.map(\.t0).min() ?? 0
      let upperBound = changed.map(\.t1).max() ?? lowerBound

      indexedSystemSegments = segments
      systemIndex.replaceSuffix(
        keeping: commonCount,
        with: segments.dropFirst(commonCount)
      )
      return lowerBound...upperBound
    }

    private mutating func invalidateFrozenMicrophoneDecisions(
      overlapping changedRange: ClosedRange<TimeInterval>
    ) {
      guard
        let index = frozenInput.firstIndex(where: { segment in
          guard segment.source == .me else { return false }
          let windowStart = segment.t0 - EchoDeduplicator.timeTolerance
          let windowEnd = segment.t1 + EchoDeduplicator.timeTolerance
          return windowEnd >= changedRange.lowerBound
            && windowStart <= changedRange.upperBound
        })
      else {
        return
      }
      truncateFrozen(to: index)
    }

    private mutating func truncateFrozen(to count: Int) {
      frozenInput = Array(frozenInput.prefix(count))
      frozenDecisions = Array(frozenDecisions.prefix(count))
    }

    private static func result(
      from decisions: [TranscriptDecision]
    ) -> Result<TranscriptSegment> {
      Result(
        segments: decisions.compactMap(\.segment),
        droppedCount: decisions.reduce(into: 0) { count, decision in
          if decision.wasDropped {
            count += 1
          }
        }
      )
    }

    private static func commonPrefixCount(
      _ lhs: [TranscriptSegment],
      _ rhs: [TranscriptSegment]
    ) -> Int {
      let upperBound = min(lhs.count, rhs.count)
      var index = 0
      while index < upperBound, lhs[index] == rhs[index] {
        index += 1
      }
      return index
    }

    private static func isChronological(_ segments: [TranscriptSegment]) -> Bool {
      zip(segments, segments.dropFirst()).allSatisfy { lhs, rhs in
        lhs.t0 <= rhs.t0
      }
    }

    private static func systemSegmentOrder(
      _ lhs: TranscriptSegment,
      _ rhs: TranscriptSegment
    ) -> Bool {
      if lhs.t0 != rhs.t0 {
        return lhs.t0 < rhs.t0
      }
      return lhs.t1 < rhs.t1
    }
  }

  /// 会中实时流:`TranscriptSegment` 带 `source`。
  public static func removeEcho(
    from segments: [TranscriptSegment]
  ) -> Result<TranscriptSegment> {
    filter(
      segments,
      isMicrophone: { $0.source == .me },
      start: \.t0,
      end: \.t1,
      text: \.text
    )
  }

  /// 会后精转合并:调用方自带的合并结构。
  public static func removeEcho<Segment: EchoDeduplicatableSegment>(
    from segments: [Segment],
    isMicrophone: (Segment) -> Bool,
    start: (Segment) -> TimeInterval,
    end: (Segment) -> TimeInterval,
    text: (Segment) -> String
  ) -> Result<Segment> {
    filter(segments, isMicrophone: isMicrophone, start: start, end: end, text: text)
  }

  private static func filter<Segment: EchoDeduplicatableSegment>(
    _ segments: [Segment],
    isMicrophone: (Segment) -> Bool,
    start: (Segment) -> TimeInterval,
    end: (Segment) -> TimeInterval,
    text: (Segment) -> String
  ) -> Result<Segment> {
    let systemWindows = segments.compactMap { segment -> SystemWindow? in
      guard !isMicrophone(segment) else { return nil }
      return SystemWindow(
        start: start(segment),
        end: end(segment),
        normalized: normalize(text(segment))
      )
    }
    let systemIndex = SystemWindowIndex(windows: systemWindows)
    guard !systemIndex.isEmpty else {
      return Result(segments: segments, droppedCount: 0)
    }

    var kept: [Segment] = []
    kept.reserveCapacity(segments.count)
    var droppedCount = 0
    for segment in segments {
      guard isMicrophone(segment) else {
        kept.append(segment)
        continue
      }
      let decision = evaluate(
        segment,
        start: start(segment),
        end: end(segment),
        text: text(segment),
        systemIndex: systemIndex
      )
      if let output = decision.segment {
        kept.append(output)
      } else {
        droppedCount += 1
      }
    }
    return Result(segments: kept, droppedCount: droppedCount)
  }

  private static func evaluate(
    _ segment: TranscriptSegment,
    systemIndex: SystemWindowIndex
  ) -> TranscriptDecision {
    guard segment.source == .me else {
      return TranscriptDecision(segment: segment, wasDropped: false)
    }
    let decision = evaluate(
      segment,
      start: segment.t0,
      end: segment.t1,
      text: segment.text,
      systemIndex: systemIndex
    )
    return TranscriptDecision(segment: decision.segment, wasDropped: decision.segment == nil)
  }

  private static func evaluate<Segment: EchoDeduplicatableSegment>(
    _ segment: Segment,
    start: TimeInterval,
    end: TimeInterval,
    text: String,
    systemIndex: SystemWindowIndex
  ) -> SegmentDecision<Segment> {
    let normalized = normalize(text)
    guard normalized.count >= minimumExactLength else {
      return SegmentDecision(segment: segment)
    }
    guard
      let reference = systemIndex.reference(
        from: start - timeTolerance,
        through: end + timeTolerance
      ),
      reference.normalized.count >= minimumExactLength
    else {
      return SegmentDecision(segment: segment)
    }

    // 整段逐字包含仍是强信号；模糊判定必须落到各分句，否则回声占比稍高的混合段
    // 会在分句裁剪前把用户真话尾句一起吞掉。
    if reference.normalized.contains(normalized) {
      return SegmentDecision(segment: nil)
    }

    let fragments = sentenceFragments(text)
    var keptFragments: [String] = []
    keptFragments.reserveCapacity(fragments.count)
    var removedEcho = false
    var keptLexicalContent = false

    for fragment in fragments {
      let candidate = normalize(fragment)
      let shouldRemove =
        candidate.count >= minimumExactLength
        && isEcho(candidate: candidate, within: reference)
      if shouldRemove {
        removedEcho = true
      } else {
        keptFragments.append(fragment)
        keptLexicalContent = keptLexicalContent || !candidate.isEmpty
      }
    }

    guard removedEcho else {
      return SegmentDecision(segment: segment)
    }
    guard keptLexicalContent else {
      return SegmentDecision(segment: nil)
    }
    return SegmentDecision(
      segment: segment.replacingEchoText(with: keptFragments.joined())
    )
  }

  private static func isEcho(
    candidate: String,
    within reference: SystemReference
  ) -> Bool {
    if reference.normalized.contains(candidate) {
      return true
    }
    guard candidate.count >= minimumFuzzyLength else { return false }
    let grams = trigrams(candidate)
    guard !grams.isEmpty else { return false }
    let hits = grams.reduce(into: 0) { total, gram in
      if reference.trigrams.contains(gram) {
        total += 1
      }
    }
    return Double(hits) / Double(grams.count) >= coverageThreshold
  }

  /// 句读留在各自分句末尾；除常规标点外，只在「句末语气词 + 明显承接词」处补一个
  /// 保守边界，处理流式 ASR 偶尔完全不吐标点的连续中文。
  private static func sentenceFragments(_ text: String) -> [String] {
    let characters = Array(text)
    guard !characters.isEmpty else { return [text] }

    let punctuation: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "，", ",", "."]
    let questionMarks: Set<Character> = ["？", "?"]
    let particles: Set<Character> = ["嘛", "吗", "呢", "吧", "啊", "呀", "哦"]
    let connectors = ["所以说", "所以", "然后", "但是", "不过", "而且"]
    let choiceConnectors = ["还是", "或者", "或是"]
    var result: [String] = []
    var fragment = ""

    for index in characters.indices {
      let character = characters[index]
      fragment.append(character)

      let nextIndex = characters.index(after: index)
      let nextIsPunctuation =
        nextIndex < characters.endIndex
        && punctuation.contains(characters[nextIndex])
      let endsPunctuationRun = punctuation.contains(character) && !nextIsPunctuation
      let continuesChoiceQuestion =
        endsPunctuationRun
        && punctuationRun(
          endingAt: index,
          in: characters,
          punctuation: punctuation
        ).contains(where: questionMarks.contains)
        && startsWithConnector(
          characters,
          from: nextIndex,
          connectors: choiceConnectors
        )
      let punctuationBoundary = endsPunctuationRun && !continuesChoiceQuestion
      let semanticBoundary =
        particles.contains(character)
        && startsWithConnector(
          characters,
          from: nextIndex,
          connectors: connectors
        )
      if punctuationBoundary || semanticBoundary {
        result.append(fragment)
        fragment = ""
      }
    }
    if !fragment.isEmpty {
      result.append(fragment)
    }
    return result.isEmpty ? [text] : result
  }

  private static func punctuationRun(
    endingAt end: Int,
    in characters: [Character],
    punctuation: Set<Character>
  ) -> ArraySlice<Character> {
    var start = end
    while start > characters.startIndex {
      let previous = characters.index(before: start)
      guard punctuation.contains(characters[previous]) else {
        break
      }
      start = previous
    }
    return characters[start...end]
  }

  private static func startsWithConnector(
    _ characters: [Character],
    from start: Int,
    connectors: [String]
  ) -> Bool {
    var index = start
    while index < characters.count, characters[index].isWhitespace {
      index += 1
    }
    guard index < characters.count else { return false }
    return connectors.contains { connector in
      let connectorCharacters = Array(connector)
      guard index + connectorCharacters.count <= characters.count else {
        return false
      }
      return Array(characters[index..<(index + connectorCharacters.count)])
        == connectorCharacters
    }
  }

  /// 只留字母、数字与表意文字,去掉标点、空白与语气停顿带来的噪声差异。
  static func normalize(_ text: String) -> String {
    String(
      text.lowercased().unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .map(Character.init)
    )
  }

  private static func trigrams(_ text: String) -> [String] {
    let characters = Array(text)
    guard characters.count >= 3 else {
      return characters.isEmpty ? [] : [String(characters)]
    }
    return (0...(characters.count - 3)).map { String(characters[$0..<($0 + 3)]) }
  }

  private struct SegmentDecision<Segment> {
    let segment: Segment?
  }

  private struct TranscriptDecision {
    let segment: TranscriptSegment?
    let wasDropped: Bool
  }

  private struct SystemWindow {
    let start: TimeInterval
    let end: TimeInterval
    let normalized: String
  }

  private struct SystemReference {
    let normalized: String
    let trigrams: Set<String>
  }

  /// 按开始时间排序；`prefixMaximumEnds` 让开始、结束两端都能用二分缩小重叠区间，
  /// 即使偶尔有长片段包住若干短片段也不会漏匹配。
  private struct SystemWindowIndex {
    private var windows: [SystemWindow] = []
    private var prefixMaximumEnds: [TimeInterval] = []

    var isEmpty: Bool { windows.isEmpty }

    init() {}

    init(windows: [SystemWindow]) {
      self.windows = windows.sorted {
        if $0.start != $1.start {
          return $0.start < $1.start
        }
        return $0.end < $1.end
      }
      rebuildPrefixMaximumEnds()
    }

    mutating func replaceSuffix(
      keeping prefixCount: Int,
      with segments: ArraySlice<TranscriptSegment>
    ) {
      let retainedCount = min(prefixCount, windows.count)
      windows.removeSubrange(retainedCount...)
      prefixMaximumEnds.removeSubrange(retainedCount...)
      for segment in segments {
        append(
          SystemWindow(
            start: segment.t0,
            end: segment.t1,
            normalized: EchoDeduplicator.normalize(segment.text)
          )
        )
      }
    }

    func reference(
      from windowStart: TimeInterval,
      through windowEnd: TimeInterval
    ) -> SystemReference? {
      guard !windows.isEmpty else { return nil }
      let lower = firstPrefixEnding(atOrAfter: windowStart)
      let upper = firstWindowStarting(after: windowEnd)
      guard lower < upper else { return nil }

      var normalizedParts: [String] = []
      normalizedParts.reserveCapacity(upper - lower)
      for index in lower..<upper where windows[index].end >= windowStart {
        normalizedParts.append(windows[index].normalized)
      }
      guard !normalizedParts.isEmpty else { return nil }
      let normalized = normalizedParts.joined()
      return SystemReference(
        normalized: normalized,
        trigrams: Set(EchoDeduplicator.trigrams(normalized))
      )
    }

    private mutating func append(_ window: SystemWindow) {
      windows.append(window)
      prefixMaximumEnds.append(max(prefixMaximumEnds.last ?? window.end, window.end))
    }

    private mutating func rebuildPrefixMaximumEnds() {
      prefixMaximumEnds = []
      prefixMaximumEnds.reserveCapacity(windows.count)
      for window in windows {
        prefixMaximumEnds.append(max(prefixMaximumEnds.last ?? window.end, window.end))
      }
    }

    private func firstPrefixEnding(atOrAfter value: TimeInterval) -> Int {
      var lower = 0
      var upper = prefixMaximumEnds.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if prefixMaximumEnds[middle] >= value {
          upper = middle
        } else {
          lower = middle + 1
        }
      }
      return lower
    }

    private func firstWindowStarting(after value: TimeInterval) -> Int {
      var lower = 0
      var upper = windows.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if windows[middle].start <= value {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      return lower
    }
  }

  static let logger = Logger(subsystem: "com.justsaid.app", category: "echo-dedup")
}
