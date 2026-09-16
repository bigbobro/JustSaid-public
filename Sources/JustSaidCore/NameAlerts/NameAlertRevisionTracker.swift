import Foundation

/// 按实际解码范围在线维护的「点名出现次数下界账本」。
///
/// 依据修订观察契约 §5 的候选方案:每个解码窗口里的名字数,先由与窗口重叠的已有出现解释,
/// 解释不了的部分才是新点名。名字数按匹配器的出现计,不区分别名(同一个人的多个称呼,
/// 以及修订把一个别名改写成另一个,都不产生新点名)。已知取舍:
/// - 覆盖区内终稿多出的名字只确认不提醒(契约 PAIR-A),可能漏掉 partial 全部漏识的真实点名;
/// - 未覆盖尾部的名字照常提醒,无法区分 ASR 在尾部的幻听(PAIR-B);
/// - 更改别名时设屏障:起点早于屏障的窗口不提醒,屏障之后同一语音段内的点名要等窗口越过屏障或落在终稿尾部。
///   暂停/恢复提醒不重置账本,也不设屏障。
struct NameAlertRevisionTracker: Sendable {
  struct Occurrence: Sendable {
    let lowerBound: TimeInterval
    var upperBound: TimeInterval
    let unit: Int
    let fromPartial: Bool
    var trailingEdge: Bool
  }

  /// 已知出现至少与窗口重叠这么多音频才可解释该窗口里的名字。物理含义是引擎能从名字音频的
  /// 多小一段仍写出名字;契约探针默认值,尚未按真实引擎标定。
  static let minimumOverlap: TimeInterval = 0.05
  static let edgeTolerance: TimeInterval = 0.1
  static let retention: TimeInterval = 90

  private(set) var occurrences: [Occurrence] = []
  private var barrier: TimeInterval
  private var unit = 0
  private var progress = -TimeInterval.infinity
  private var lastPartial: (end: TimeInterval, tokens: [[UInt32]])?

  init(barrier: TimeInterval = -.infinity) {
    self.barrier = barrier
  }

  /// 返回本条观察新增的点名数。`names` 为该观察文本的匹配出现(按原文位置排序)。
  mutating func ingest(
    kind: LiveDecodeObservation.Kind,
    range: ClosedRange<TimeInterval>,
    text: String,
    names: [NameAlertOccurrence]
  ) -> Int {
    let tokens = NameAlertText(text).tokens
    // 解码窗口起点随音频推进(终稿起点回到本段开头,回退不超过一段语音);终点早于
    // 「已见最大窗口起点 − 保留时长」的出现不会再与之后的窗口重叠。每条观察都修剪,不依赖终稿节奏。
    progress = max(progress, range.lowerBound)
    occurrences.removeAll { $0.upperBound < progress - Self.retention }
    switch kind {
    case .partial:
      // RecordingSession 会滤掉空终稿与噪声终稿,下一段语音可能不经 final 就开始。
      // 同一段内相邻解码窗口至少重叠一个 3 秒节拍;与上一窗口不再重叠即视为新语音段。
      if let partial = lastPartial, range.lowerBound >= partial.end - Self.edgeTolerance {
        sealUnit()
      }
      lastPartial = (range.upperBound, tokens.map(\.form))
      guard !names.isEmpty, barrier - range.lowerBound < Self.minimumOverlap else { return 0 }
      let fresh =
        names.count
        - explained(
          names.count, firstTokenIsName: Self.startsWithName(names, tokens: tokens[...]),
          lower: range.lowerBound, upper: range.upperBound)
      return place(
        fresh, lower: range.lowerBound, upper: range.upperBound, fromPartial: true,
        lastTokenIsName: Self.endsWithName(names, tokens: tokens[...]))

    case .final:
      defer {
        confirmUnit(
          upperBound: range.upperBound, finalNameCount: names.count,
          finalEndsWithName: Self.endsWithName(names, tokens: tokens[...]))
        sealUnit()
      }
      // 被滤掉终稿之后的短语音段可能只有一条终稿:上一条 partial 不覆盖本段时不参与尾部对齐。
      if let partial = lastPartial, range.lowerBound >= partial.end - Self.edgeTolerance {
        sealUnit()
      }
      let tailStart = lastPartial?.end ?? range.lowerBound
      // 终稿没有 partial 未覆盖的音频:无论拼写、同义别名还是名字数变化,都是对已覆盖音频的修订,只确认。
      guard range.upperBound - tailStart >= Self.minimumOverlap else { return 0 }
      var tailIndex = 0
      if let partial = lastPartial {
        let expectedTail =
          Double(tokens.count) * max(0, range.upperBound - tailStart)
          / max(range.upperBound - range.lowerBound, 1e-6)
        tailIndex = Self.alignmentEnd(partial.tokens, tokens.map(\.form), expectedTail) + 1
      }
      let tailTokens = tokens[min(tailIndex, tokens.count)...]
      // 出现的外包区间可能被跨接的另一个别名拉到尾部之前;按各别名自己的位置判定是否在尾部。
      let tailNames =
        tailTokens.first.map { first in
          names.filter { occurrence in
            occurrence.matches.contains { $0.utf16Range.lowerBound >= first.utf16Range.lowerBound }
          }
        } ?? []
      // 与 partial 对不上任何 token 时无法定位名字在终稿中的位置:按整条终稿范围解释与判屏障,
      // 本段 partial 已计入的点名先抵扣,避免把改写当作尾部新点名。
      let lower = tailIndex == 0 ? range.lowerBound : tailStart
      guard !tailNames.isEmpty, barrier - lower < Self.minimumOverlap else { return 0 }
      let currentUnit = unit
      let existing = explained(
        tailNames.count, firstTokenIsName: Self.startsWithName(tailNames, tokens: tailTokens),
        lower: lower, upper: range.upperBound,
        including: { tailIndex == 0 || !($0.unit == currentUnit && $0.fromPartial) })
      return place(
        tailNames.count - existing, lower: tailStart, upper: range.upperBound, fromPartial: false,
        lastTokenIsName: Self.endsWithName(tailNames, tokens: tailTokens))
    }
  }

  /// 终稿确认本段:本段已有出现中不超过终稿名字数的那些(按创建先后)把终点收回到终稿终点。
  /// Apple 的临时结果窗口可越过随后终稿的终点,不收回会用上一段的出现解释下一段起始处的新点名;
  /// 超出终稿名字数的出现可能位于越界部分,保留原终点以免下一段重复计数。
  /// 终稿不以名字结尾时,被确认的出现也不再按「以名字结尾」参与边缘规则:创建它的 partial
  /// 可能恰好停在名字上,之后文本已经延续,留着会把下一段开头的新点名当作跨界的同一个名字。
  private mutating func confirmUnit(
    upperBound: TimeInterval, finalNameCount: Int, finalEndsWithName: Bool
  ) {
    var remaining = finalNameCount
    for index in occurrences.indices where remaining > 0 && occurrences[index].unit == unit {
      occurrences[index].upperBound = max(
        occurrences[index].lowerBound, min(occurrences[index].upperBound, upperBound))
      occurrences[index].trailingEdge = occurrences[index].trailingEdge && finalEndsWithName
      remaining -= 1
    }
  }

  private mutating func sealUnit() {
    lastPartial = nil
    unit += 1
  }

  private func explained(
    _ count: Int,
    firstTokenIsName: Bool,
    lower: TimeInterval,
    upper: TimeInterval,
    including include: (Occurrence) -> Bool = { _ in true }
  ) -> Int {
    func overlap(_ occurrence: Occurrence) -> TimeInterval {
      min(occurrence.upperBound, upper) - max(occurrence.lowerBound, lower)
    }
    let strong = occurrences.filter { include($0) && overlap($0) >= Self.minimumOverlap }.count
    // 相接而不重叠的出现:只有新窗口以名字开头、创建该出现的窗口以名字结尾时才可解释 1 次。
    let edge =
      firstTokenIsName
        && occurrences.contains {
          include($0) && $0.trailingEdge && overlap($0) > -Self.edgeTolerance
            && overlap($0) < Self.minimumOverlap
        } ? 1 : 0
    return min(count, strong + edge)
  }

  private mutating func place(
    _ count: Int,
    lower: TimeInterval,
    upper: TimeInterval,
    fromPartial: Bool,
    lastTokenIsName: Bool
  ) -> Int {
    guard count > 0 else { return 0 }
    for index in 0..<count {
      occurrences.append(
        Occurrence(
          lowerBound: lower, upperBound: upper, unit: unit, fromPartial: fromPartial,
          trailingEdge: lastTokenIsName && index == count - 1))
    }
    return count
  }

  private static func startsWithName(
    _ names: [NameAlertOccurrence],
    tokens: ArraySlice<NameAlertText.Token>
  ) -> Bool {
    guard let first = tokens.first else { return false }
    return names.contains { occurrence in
      occurrence.matches.contains {
        $0.utf16Range.lowerBound <= first.utf16Range.lowerBound
          && $0.utf16Range.upperBound > first.utf16Range.lowerBound
      }
    }
  }

  private static func endsWithName(
    _ names: [NameAlertOccurrence],
    tokens: ArraySlice<NameAlertText.Token>
  ) -> Bool {
    guard let last = tokens.last else { return false }
    return names.contains { occurrence in
      occurrence.matches.contains { $0.utf16Range.upperBound >= last.utf16Range.upperBound }
    }
  }

  /// 最后一条 partial 的 token 与终稿 token 做最长公共子序列对齐,返回对齐终点在终稿中的下标
  /// (无对齐为 −1)。多个等长对齐时,取留下的尾部 token 数最接近按未覆盖时长估计值的那个。
  static func alignmentEnd(
    _ partial: [[UInt32]],
    _ final: [[UInt32]],
    _ expectedTailTokens: Double
  ) -> Int {
    guard !partial.isEmpty, !final.isEmpty else { return -1 }
    var table = [[Int]](
      repeating: [Int](repeating: 0, count: final.count + 1), count: partial.count + 1)
    for i in 1...partial.count {
      for j in 1...final.count {
        table[i][j] =
          partial[i - 1] == final[j - 1]
          ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
      }
    }
    let total = table[partial.count][final.count]
    guard total > 0 else { return -1 }
    var best: Int?
    var bestDistance = Double.infinity
    for i in 1...partial.count {
      for j in 1...final.count
      where partial[i - 1] == final[j - 1] && table[i - 1][j - 1] + 1 == total {
        let end = j - 1
        let distance = abs(Double(final.count - 1 - end) - expectedTailTokens)
        if distance < bestDistance || (distance == bestDistance && end > (best ?? -1)) {
          best = end
          bestDistance = distance
        }
      }
    }
    return best ?? -1
  }
}
