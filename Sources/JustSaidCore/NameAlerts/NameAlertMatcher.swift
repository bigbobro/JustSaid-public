import Foundation

/// 单条转写的匹配现场:token、拼音与窗口形态只算一次,供所有别名共享。
final class NameAlertMatchContext {
  struct Candidate {
    let start: Int
    let count: Int
    let leg: NameAlertMatchLeg
    let score: Double
    let threshold: Double
    let isLiteral: Bool
  }

  let tokens: [NameAlertText.Token]
  private let syllables: [[UInt32]?]
  /// `chainStart[i]`:与 token i 连成同一可窗口片段的最早 token 下标。
  private let chainStart: [Int]
  private var compactCache: [Int: [UInt32]] = [:]
  private var spacedCache: [Int: [UInt32]] = [:]
  private var metaphoneCache: [Int: String] = [:]

  init(text: String, aliases: [NameAlertAlias]) {
    let view = NameAlertText(text)
    tokens = view.tokens
    if aliases.contains(where: { $0.legs.contains(.pinyin) }) {
      syllables = view.hanSyllables()
    } else {
      syllables = []
    }
    var chainStart: [Int] = []
    chainStart.reserveCapacity(view.tokens.count)
    for (index, token) in view.tokens.enumerated() {
      chainStart.append(token.joinsPrevious && index > 0 ? chainStart[index - 1] : index)
    }
    self.chainStart = chainStart
  }

  func matches(for alias: NameAlertAlias, options: NameAlertAliasSet.Options)
    -> [NameAlertAliasMatch]
  {
    let candidates = candidates(for: alias, options: options, applyThresholds: true)
    guard !candidates.isEmpty else { return [] }

    // 先按分数挑互不重叠的主窗口(真实的多次出现各自保留),
    // 再把与主窗口重叠的其他腿/平移窗口并入该处证据,每条腿只留最高分。
    let ordered = candidates.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.isLiteral != rhs.isLiteral { return lhs.isLiteral }
      let lhsGap = abs(lhs.count - alias.tokenCount)
      let rhsGap = abs(rhs.count - alias.tokenCount)
      if lhsGap != rhsGap { return lhsGap < rhsGap }
      return lhs.start < rhs.start
    }
    var primaries: [Candidate] = []
    for candidate in ordered where !primaries.contains(where: { overlap($0, candidate) > 0 }) {
      primaries.append(candidate)
    }
    var evidenceByPrimary = [[NameAlertMatchLeg: Candidate]](repeating: [:], count: primaries.count)
    for candidate in ordered {
      var bestIndex: Int?
      var bestOverlap = 0
      for (index, primary) in primaries.enumerated() {
        let shared = overlap(primary, candidate)
        if shared > bestOverlap {
          bestOverlap = shared
          bestIndex = index
        }
      }
      guard let bestIndex else { continue }
      if let existing = evidenceByPrimary[bestIndex][candidate.leg],
        existing.score >= candidate.score
      {
        continue
      }
      evidenceByPrimary[bestIndex][candidate.leg] = candidate
    }

    return primaries.enumerated().map { index, primary in
      let evidence = evidenceByPrimary[index].values
        .sorted { ($0.score, $1.leg.rawValue) > ($1.score, $0.leg.rawValue) }
        .map { candidate in
          NameAlertMatchEvidence(
            leg: candidate.leg,
            score: candidate.score,
            threshold: candidate.threshold,
            utf16Range: utf16Range(start: candidate.start, count: candidate.count)
          )
        }
      return NameAlertAliasMatch(
        aliasID: alias.id,
        range: tokens[primary.start].range
          .lowerBound..<tokens[primary.start + primary.count - 1].range.upperBound,
        utf16Range: utf16Range(start: primary.start, count: primary.count),
        isLiteral: evidenceByPrimary[index].values.contains(where: \.isLiteral),
        evidence: evidence
      )
    }
  }

  func candidates(
    for alias: NameAlertAlias,
    options: NameAlertAliasSet.Options,
    applyThresholds: Bool
  ) -> [Candidate] {
    var result: [Candidate] = []
    func consider(
      _ leg: NameAlertMatchLeg, start: Int, count: Int, score: Double, isLiteral: Bool
    ) {
      let threshold = alias.strictness.threshold(for: leg)
      guard score > 0, !applyThresholds || score >= threshold else { return }
      result.append(
        Candidate(
          start: start, count: count, leg: leg, score: score, threshold: threshold,
          isLiteral: isLiteral))
    }
    let enabled = alias.legs.filter { options.enabledLegs.contains($0) }
    guard !enabled.isEmpty else { return [] }

    if alias.containsHan {
      for start in tokens.indices {
        if enabled.contains(.fuzzy), isWindow(start: start, count: alias.tokenCount) {
          let window = compactForm(start: start, count: alias.tokenCount)
          let threshold = applyThresholds ? alias.strictness.threshold(for: .fuzzy) : 0
          if NameAlertPhonetics.indelRatioUpperBound(window.count, alias.compactForm.count)
            >= threshold
          {
            let score = NameAlertPhonetics.indelRatio(alias.compactForm, window)
            consider(
              .fuzzy, start: start, count: alias.tokenCount, score: score,
              isLiteral: window == alias.compactForm)
          }
        }
        guard enabled.contains(.pinyin) else { continue }
        for count in [alias.tokenCount, alias.tokenCount - 1] where count >= 1 {
          guard isWindow(start: start, count: count) else { continue }
          // 少一个 token 的窗口只用于罗马拼音连写(如两个音节写成一个词),纯汉字窗口不放宽。
          if count != alias.tokenCount,
            !tokens[start..<(start + count)].contains(where: { $0.kind == .latin })
          {
            continue
          }
          let window = spacedSyllables(start: start, count: count)
          let threshold = applyThresholds ? alias.strictness.threshold(for: .pinyin) : 0
          // 整串比率允许跨音节借字(陈力你 对 陈艾力 得 80)。护栏开启时同长窗口还要
          // 逐音节对位计分并取较低者,音节整体缺失或错位的另一个名字不能凑够分数。
          let alignSyllables = options.shortNameGuards && count == alias.tokenCount
          var best = 0.0
          for (variantIndex, joined) in alias.joinedSyllableVariants.enumerated()
          where NameAlertPhonetics.indelRatioUpperBound(window.count, joined.count) >= threshold {
            var score = NameAlertPhonetics.indelRatio(joined, window)
            if alignSyllables, score >= threshold {
              score = min(
                score, alignedSyllableRatio(alias.syllableVariants[variantIndex], start: start))
            }
            best = max(best, score)
          }
          consider(
            .pinyin, start: start, count: count, score: best,
            isLiteral: compactForm(start: start, count: count) == alias.compactForm)
        }
      }
      return result
    }

    let guards = options.shortNameGuards
    for start in tokens.indices {
      for count in [alias.tokenCount, alias.tokenCount + 1, alias.tokenCount - 1] where count >= 1 {
        guard isWindow(start: start, count: count) else { continue }
        let span = tokens[start..<(start + count)]
        guard span.allSatisfy({ $0.kind == .latin }) else { continue }
        if guards, count != alias.tokenCount, span.contains(where: { $0.form.count < 2 }) {
          continue
        }
        let window = compactForm(start: start, count: count)
        let isLiteral = window == alias.compactForm
        if !isLiteral, guards {
          if Self.isPrefixExtension(window, alias.compactForm) { continue }
          // 短名字的编辑余量极小,Metaphone 又忽略元音:Jon/join、Paul/pole 这类常用词
          // 靠改动元音就能撞码。strict 别名的近似命中只允许不改变元音骨架的静音字母差异。
          if alias.strictness == .strict,
            Self.vowelSkeleton(window) != Self.vowelSkeleton(alias.compactForm)
          {
            continue
          }
        }
        if enabled.contains(.fuzzy) {
          let threshold = applyThresholds ? alias.strictness.threshold(for: .fuzzy) : 0
          if NameAlertPhonetics.indelRatioUpperBound(window.count, alias.compactForm.count)
            >= threshold
          {
            let score = NameAlertPhonetics.indelRatio(alias.compactForm, window)
            consider(.fuzzy, start: start, count: count, score: score, isLiteral: isLiteral)
          }
        }
        if enabled.contains(.phonetic) {
          if !isLiteral, guards, window.count < 3 { continue }
          let threshold = applyThresholds ? alias.strictness.threshold(for: .phonetic) : 0
          guard
            NameAlertPhonetics.indelRatioUpperBound(window.count, alias.compactForm.count)
              >= threshold,
            metaphone(start: start, count: count) == alias.metaphoneCode
          else { continue }
          let score = NameAlertPhonetics.indelRatio(alias.compactForm, window)
          consider(.phonetic, start: start, count: count, score: score, isLiteral: isLiteral)
        }
      }
    }
    return result
  }

  /// 一方是另一方的真前缀(Alex/Alexandria、Paul/Paula、Ann/Anna)视为不同的词或名字;
  /// 只多一个词尾静音 e 或 h 的拼写变体(Ann/Anne、Sara/Sarah)除外。
  static func isPrefixExtension(_ lhs: [UInt32], _ rhs: [UInt32]) -> Bool {
    let (short, long) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
    guard long.count > short.count, long.starts(with: short) else { return false }
    let extensionScalars = long[short.count...]
    if extensionScalars.count == 1,
      let last = extensionScalars.first,
      last == UInt32(UInt8(ascii: "e")) || last == UInt32(UInt8(ascii: "h"))
    {
      return false
    }
    return true
  }

  /// 词内元音序列(含 y);词尾紧跟辅音的单个静音 e 不计(Anne 与 Ann 相同)。
  static func vowelSkeleton(_ form: [UInt32]) -> [UInt32] {
    var letters = form[...]
    if letters.count >= 3, letters.last == vowelE, let beforeLast = letters.dropLast().last,
      !vowels.contains(beforeLast)
    {
      letters = letters.dropLast()
    }
    return letters.filter { vowels.contains($0) }
  }

  private static let vowelE = UInt32(UInt8(ascii: "e"))
  private static let vowels = Set("aeiouy".unicodeScalars.map(\.value))

  /// 逐音节对位的 Indel 比率:各位置 LCS 之和按全部音节字符数归一,不跨音节借字。
  private func alignedSyllableRatio(_ aliasSyllables: [[UInt32]], start: Int) -> Double {
    var shared = 0
    var total = 0
    for (offset, aliasSyllable) in aliasSyllables.enumerated() {
      let index = start + offset
      let windowSyllable = syllables[index] ?? tokens[index].form
      shared += NameAlertPhonetics.longestCommonSubsequence(aliasSyllable, windowSyllable)
      total += aliasSyllable.count + windowSyllable.count
    }
    return total == 0 ? 0 : 200.0 * Double(shared) / Double(total)
  }

  private func isWindow(start: Int, count: Int) -> Bool {
    let end = start + count - 1
    return count >= 1 && end < tokens.count && chainStart[end] <= start
  }

  private func overlap(_ lhs: Candidate, _ rhs: Candidate) -> Int {
    max(0, min(lhs.start + lhs.count, rhs.start + rhs.count) - max(lhs.start, rhs.start))
  }

  private func utf16Range(start: Int, count: Int) -> Range<Int> {
    tokens[start].utf16Range.lowerBound..<tokens[start + count - 1].utf16Range.upperBound
  }

  private func cacheKey(start: Int, count: Int) -> Int {
    start << 8 | min(count, 255)
  }

  private func compactForm(start: Int, count: Int) -> [UInt32] {
    let key = cacheKey(start: start, count: count)
    if let cached = compactCache[key] { return cached }
    let form = Array(tokens[start..<(start + count)].map(\.form).joined())
    compactCache[key] = form
    return form
  }

  private func spacedSyllables(start: Int, count: Int) -> [UInt32] {
    let key = cacheKey(start: start, count: count)
    if let cached = spacedCache[key] { return cached }
    let form = Array(
      (start..<(start + count)).map { syllables[$0] ?? tokens[$0].form }.joined(separator: [0x20]))
    spacedCache[key] = form
    return form
  }

  private func metaphone(start: Int, count: Int) -> String {
    let key = cacheKey(start: start, count: count)
    if let cached = metaphoneCache[key] { return cached }
    let code = NameAlertPhonetics.metaphone(
      lowercasedScalars: compactForm(start: start, count: count).compactMap(Unicode.Scalar.init))
    metaphoneCache[key] = code
    return code
  }
}
