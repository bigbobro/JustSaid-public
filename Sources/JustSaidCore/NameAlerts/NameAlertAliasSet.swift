import Foundation

/// 用户显式配置的名字/昵称,预编译成可直接匹配的形态。
///
/// 编译只做一次:规整、去重、判定严格度、生成拼音读音集合与 Metaphone 编码。
/// 之后每条新转写只调用 `occurrences(in:)`,不回写原文、不写日志。
/// 严格度沿用 CueMeIn 原生 App 的自动推导:含汉字且不超过 2 字、或纯拉丁不超过 4 个字母为
/// strict,其余为 medium;阈值表沿用 CueMeIn 的 pinyin/phonetic/fuzzy 三腿数值,
/// 只作为起点,必须用 JustSaid 引擎的实际转写重测。
public struct NameAlertAliasSet: Sendable {
  public struct Options: Sendable, Equatable {
    /// 别名侧额外加入 ICU 人名读音(姓氏多音字,例如「单」读 shan),与默认读音取高分。
    public var aliasNameReadings: Bool
    /// 短名字与词边界护栏:近似命中不得短于 3 个字母、不得只是前缀延伸(静音 e/h 除外)、
    /// 跨 token 拼接的每段至少 2 个字母,strict 别名的近似命中还须保持元音骨架;
    /// 拼音同长窗口另按音节对位计分。字面命中不受影响。关闭只用于消融对照。
    public var shortNameGuards: Bool
    public var enabledLegs: Set<NameAlertMatchLeg>

    public init(
      aliasNameReadings: Bool = true,
      shortNameGuards: Bool = true,
      enabledLegs: Set<NameAlertMatchLeg> = Set(NameAlertMatchLeg.allCases)
    ) {
      self.aliasNameReadings = aliasNameReadings
      self.shortNameGuards = shortNameGuards
      self.enabledLegs = enabledLegs
    }
  }

  public enum RejectionReason: Equatable, Sendable {
    case empty
    case duplicate(ofInputIndex: Int)
    case noMatchableText
  }

  public struct Rejection: Equatable, Sendable {
    public let inputIndex: Int
    public let reason: RejectionReason
  }

  public let aliases: [NameAlertAlias]
  public let rejections: [Rejection]
  public let options: Options

  public init(_ inputs: [String], options: Options = Options()) {
    var aliases: [NameAlertAlias] = []
    var rejections: [Rejection] = []
    var firstIndexByKey: [[UInt32]: Int] = [:]
    for (inputIndex, input) in inputs.enumerated() {
      let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        rejections.append(Rejection(inputIndex: inputIndex, reason: .empty))
        continue
      }
      let view = NameAlertText(trimmed)
      guard !view.tokens.isEmpty else {
        rejections.append(Rejection(inputIndex: inputIndex, reason: .noMatchableText))
        continue
      }
      let key = Array(view.tokens.map(\.form).joined(separator: [0x20]))
      if let first = firstIndexByKey[key] {
        rejections.append(
          Rejection(inputIndex: inputIndex, reason: .duplicate(ofInputIndex: first)))
        continue
      }
      firstIndexByKey[key] = inputIndex
      aliases.append(NameAlertAlias(id: inputIndex, text: trimmed, view: view, options: options))
    }
    self.aliases = aliases
    self.rejections = rejections
    self.options = options
  }

  public var isEmpty: Bool { aliases.isEmpty }

  /// 找出原文中所有点名出现位置。同一位置的多条腿、多个别名合并为一个出现;
  /// 互不重叠的位置各自保留,因此同一句里的两次点名是两个出现。
  public func occurrences(in text: String) -> [NameAlertOccurrence] {
    guard !aliases.isEmpty else { return [] }
    let context = NameAlertMatchContext(text: text, aliases: aliases)
    guard !context.tokens.isEmpty else { return [] }
    var matches: [NameAlertAliasMatch] = []
    for alias in aliases {
      matches.append(contentsOf: context.matches(for: alias, options: options))
    }
    return NameAlertOccurrence.group(matches)
  }

  /// 诊断用:每个别名每条腿在合格窗口上的最高分(未过阈值也报告),对应 CueMeIn 的近失分。
  public func legScores(in text: String) -> [NameAlertLegScores] {
    let context = NameAlertMatchContext(text: text, aliases: aliases)
    return aliases.map { alias in
      var scores: [NameAlertMatchLeg: Double] = [:]
      for leg in alias.legs where options.enabledLegs.contains(leg) {
        scores[leg] = 0
      }
      for candidate in context.candidates(for: alias, options: options, applyThresholds: false) {
        scores[candidate.leg] = max(scores[candidate.leg] ?? 0, candidate.score)
      }
      return NameAlertLegScores(aliasID: alias.id, strictness: alias.strictness, scores: scores)
    }
  }
}

public enum NameAlertMatchLeg: String, CaseIterable, Sendable {
  /// 含汉字的别名:拼音音节窗口比较,覆盖同音/近音字与罗马拼音转写。
  case pinyin
  /// 纯拉丁别名:Metaphone 编码相同才进入,分数取词面相似度。
  case phonetic
  /// 所有别名:规整后的整词/整字窗口相似度,字面出现时为 100。
  case fuzzy
}

public enum NameAlertStrictness: String, Sendable {
  case strict
  case medium

  public func threshold(for leg: NameAlertMatchLeg) -> Double {
    switch (leg, self) {
    case (.pinyin, .strict): return 95
    case (.pinyin, .medium): return 80
    case (.phonetic, .strict): return 78
    case (.phonetic, .medium): return 76
    case (.fuzzy, .strict): return 92
    case (.fuzzy, .medium): return 88
    }
  }
}

public struct NameAlertAlias: Sendable, Identifiable {
  /// 别名在输入列表中的下标;同一份配置内稳定,配置改变即整体失效。
  public let id: Int
  public let text: String
  public let strictness: NameAlertStrictness
  public let legs: [NameAlertMatchLeg]

  let containsHan: Bool
  let tokenCount: Int
  let compactForm: [UInt32]
  let letterCount: Int
  /// 拼音读音集合,每项为逐 token 音节;第一项为默认上下文读音,可选第二项为人名读音。
  let syllableVariants: [[[UInt32]]]
  /// 与 `syllableVariants` 一一对应、以空格连接的整串,用于与 CueMeIn 相同的整串比率。
  let joinedSyllableVariants: [[UInt32]]
  let metaphoneCode: String

  init(id: Int, text: String, view: NameAlertText, options: NameAlertAliasSet.Options) {
    self.id = id
    self.text = text
    let tokens = view.tokens
    let hanCount = tokens.filter { $0.kind == .han }.count
    containsHan = hanCount > 0
    tokenCount = tokens.count
    compactForm = Array(tokens.map(\.form).joined())
    letterCount = compactForm.count
    if containsHan {
      strictness = letterCount <= 2 ? .strict : .medium
      var variants: [[[UInt32]]] = []
      var transforms: [StringTransform] = [.mandarinToLatin]
      if options.aliasNameReadings {
        transforms.append(Self.nameReadingTransform)
      }
      for transform in transforms {
        let syllables = view.hanSyllables(transform: transform)
        let variant = tokens.indices.map { syllables[$0] ?? tokens[$0].form }
        if !variants.contains(variant) {
          variants.append(variant)
        }
      }
      syllableVariants = variants
      joinedSyllableVariants = variants.map { Array($0.joined(separator: [0x20])) }
      metaphoneCode = ""
      legs = hanCount >= 2 ? [.pinyin, .fuzzy] : [.fuzzy]
    } else {
      strictness = letterCount <= 4 ? .strict : .medium
      syllableVariants = []
      joinedSyllableVariants = []
      metaphoneCode = NameAlertPhonetics.metaphone(
        lowercasedScalars: compactForm.compactMap(Unicode.Scalar.init))
      legs = letterCount >= 3 && !metaphoneCode.isEmpty ? [.phonetic, .fuzzy] : [.fuzzy]
    }
  }

  private static let nameReadingTransform = StringTransform("Han-Latin/Names")
}

public struct NameAlertLegScores: Sendable, Equatable {
  public let aliasID: Int
  public let strictness: NameAlertStrictness
  public let scores: [NameAlertMatchLeg: Double]
}

/// 一次点名在原文中的位置,以及在此处命中的全部别名。
public struct NameAlertOccurrence: Sendable, Equatable {
  /// 只对传入 `occurrences(in:)` 的那个字符串有效;不保留原字符串时改用 `utf16Range`。
  public let range: Range<String.Index>
  public let utf16Range: Range<Int>
  /// 按别名 id 排序,每个别名至多一条。出现按起点排序;只有跨在两次点名之间的另一个别名
  /// 并入前一次时,相邻出现的区间才可能部分重叠。
  public let matches: [NameAlertAliasMatch]

  static func group(_ matches: [NameAlertAliasMatch]) -> [NameAlertOccurrence] {
    let sorted = matches.sorted {
      ($0.utf16Range.lowerBound, $0.utf16Range.upperBound, $0.aliasID)
        < ($1.utf16Range.lowerBound, $1.utf16Range.upperBound, $1.aliasID)
    }
    var occurrences: [NameAlertOccurrence] = []
    var pending: [NameAlertAliasMatch] = []
    func flush() {
      guard let first = pending.first else { return }
      let lower = pending.map(\.range.lowerBound).min() ?? first.range.lowerBound
      let upper = pending.map(\.range.upperBound).max() ?? first.range.upperBound
      let utf16Lower = pending.map(\.utf16Range.lowerBound).min() ?? 0
      let utf16Upper = pending.map(\.utf16Range.upperBound).max() ?? 0
      occurrences.append(
        NameAlertOccurrence(
          range: lower..<upper,
          utf16Range: utf16Lower..<utf16Upper,
          matches: pending.sorted { $0.aliasID < $1.aliasID }
        ))
      pending = []
    }
    // 同一别名的主窗口互不重叠,各自是真实的一次点名;另一个别名跨在两次之间
    // (林木林木 中的 木林)只并入先出现的那次,不能把两次串成一个出现。
    for match in sorted {
      if let currentUpper = pending.map(\.utf16Range.upperBound).max(),
        match.utf16Range.lowerBound >= currentUpper
          || pending.contains(where: { $0.aliasID == match.aliasID })
      {
        flush()
      }
      pending.append(match)
    }
    flush()
    return occurrences
  }
}

public struct NameAlertAliasMatch: Sendable, Equatable {
  public let aliasID: Int
  public let range: Range<String.Index>
  public let utf16Range: Range<Int>
  /// 规整后的窗口与别名字面相同(大小写、全角、变音、连接符差异不计)。
  public let isLiteral: Bool
  /// 同一位置每条过阈值的腿至多一条证据,按分数从高到低。
  public let evidence: [NameAlertMatchEvidence]

  public var bestScore: Double { evidence.map(\.score).max() ?? 0 }
}

public struct NameAlertMatchEvidence: Sendable, Equatable {
  public let leg: NameAlertMatchLeg
  public let score: Double
  public let threshold: Double
  /// 该腿实际比较的窗口在原文中的 UTF-16 位置,可能与别名匹配的主窗口略有差异。
  public let utf16Range: Range<Int>
}
