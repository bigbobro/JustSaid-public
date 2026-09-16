import Foundation

/// 点名匹配的文本视图:把原文切成可比较的 token,同时保留每个 token 在原文中的位置。
///
/// 规整只发生在检测侧,原文一字不动:
/// - 拉丁字母按字符做兼容规整、去变音、转小写,连续字母组成一个词 token;
/// - 每个汉字是一个音节 token;
/// - 空白、连字符、撇号和间隔号只连接相邻 token,其他标点、数字、别的文字与表情都会断开窗口。
struct NameAlertText {
  enum Kind: Equatable {
    case latin
    case han
  }

  struct Token {
    let kind: Kind
    /// 规整后的比较形态:拉丁为小写 ASCII 字母,汉字为规整后的单个标量。
    let form: [UInt32]
    let range: Range<String.Index>
    let utf16Range: Range<Int>
    /// 与前一个 token 之间只隔着连接符(或什么都不隔),可以同处一个匹配窗口。
    let joinsPrevious: Bool
    /// 与前一个汉字 token 紧邻、中间无任何字符,拼音转换时属于同一个上下文段。
    let continuesHanRun: Bool
  }

  let tokens: [Token]

  init(_ text: String) {
    var tokens: [Token] = []
    var utf16Offset = 0
    var pendingLatin: (form: [UInt32], start: String.Index, utf16Start: Int)?
    var gapAllowsJoin = true
    var gapIsEmpty = true

    func appendToken(_ token: Token) {
      tokens.append(token)
      gapAllowsJoin = true
      gapIsEmpty = true
    }
    func flushLatin(end: String.Index, utf16End: Int) {
      guard let latin = pendingLatin else { return }
      appendToken(
        Token(
          kind: .latin,
          form: latin.form,
          range: latin.start..<end,
          utf16Range: latin.utf16Start..<utf16End,
          joinsPrevious: !tokens.isEmpty && gapAllowsJoin,
          continuesHanRun: false
        ))
      pendingLatin = nil
    }

    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      let width = character.utf16.count
      switch Self.classify(character) {
      case .latin(let letters):
        if pendingLatin == nil {
          pendingLatin = (letters, index, utf16Offset)
        } else {
          pendingLatin?.form.append(contentsOf: letters)
        }
      case .han(let scalar):
        flushLatin(end: index, utf16End: utf16Offset)
        let previousIsHan = tokens.last?.kind == .han
        appendToken(
          Token(
            kind: .han,
            form: [scalar],
            range: index..<next,
            utf16Range: utf16Offset..<(utf16Offset + width),
            joinsPrevious: !tokens.isEmpty && gapAllowsJoin,
            continuesHanRun: previousIsHan && gapIsEmpty
          ))
      case .joiner:
        flushLatin(end: index, utf16End: utf16Offset)
        gapIsEmpty = false
      case .breaker:
        flushLatin(end: index, utf16End: utf16Offset)
        gapIsEmpty = false
        gapAllowsJoin = false
      }
      utf16Offset += width
      index = next
    }
    flushLatin(end: text.endIndex, utf16End: utf16Offset)
    self.tokens = tokens
  }

  /// 各汉字 token 的拼音音节(无声调,ü 记作 v);拉丁 token 为 nil。
  ///
  /// 每个连续汉字段整段转换,保留 Foundation 的上下文读音(例如词组里的多音字);
  /// 输出音节数与汉字数不一致时,该段退回逐字转换,不会把音节错配到别的字上。
  func hanSyllables(transform: StringTransform = .mandarinToLatin) -> [[UInt32]?] {
    var syllables = [[UInt32]?](repeating: nil, count: tokens.count)
    var runStart = 0
    while runStart < tokens.count {
      guard tokens[runStart].kind == .han else {
        runStart += 1
        continue
      }
      var runEnd = runStart + 1
      while runEnd < tokens.count, tokens[runEnd].continuesHanRun {
        runEnd += 1
      }
      let run = tokens[runStart..<runEnd].map { token in
        String(String.UnicodeScalarView(token.form.compactMap(Unicode.Scalar.init)))
      }
      let readings = Self.readings(of: run, transform: transform)
      for (offset, reading) in readings.enumerated() {
        syllables[runStart + offset] = reading
      }
      runStart = runEnd
    }
    return syllables
  }

  static func readings(of run: [String], transform: StringTransform) -> [[UInt32]] {
    let whole = syllables(of: run.joined(), transform: transform)
    if whole.count == run.count, whole.allSatisfy(isASCIILetters) {
      return whole
    }
    return run.map { character in
      let pieces = syllables(of: character, transform: transform)
      return pieces.count == 1 ? pieces[0] : character.unicodeScalars.map(\.value)
    }
  }

  private static func syllables(of text: String, transform: StringTransform) -> [[UInt32]] {
    guard let latin = text.applyingTransform(transform, reverse: false) else { return [] }
    var pieces: [[UInt32]] = []
    var current: [UInt32] = []
    var previousWasU = false
    for scalar in latin.decomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
      if scalar.properties.isWhitespace {
        if !current.isEmpty { pieces.append(current) }
        current = []
        previousWasU = false
        continue
      }
      if scalar.properties.generalCategory == .nonspacingMark {
        if scalar.value == 0x0308, previousWasU {
          current[current.count - 1] = UInt32(UInt8(ascii: "v"))
        }
        previousWasU = false
        continue
      }
      previousWasU = scalar == "u"
      current.append(scalar.value)
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
  }

  enum CharacterClass {
    case latin([UInt32])
    case han(UInt32)
    case joiner
    case breaker
  }

  static func classify(_ character: Character) -> CharacterClass {
    if let ascii = character.asciiValue {
      switch ascii {
      case UInt8(ascii: "a")...UInt8(ascii: "z"):
        return .latin([UInt32(ascii)])
      case UInt8(ascii: "A")...UInt8(ascii: "Z"):
        return .latin([UInt32(ascii + 32)])
      case UInt8(ascii: "-"), UInt8(ascii: "'"):
        return .joiner
      default:
        return character.isWhitespace ? .joiner : .breaker
      }
    }
    if character.isWhitespace || joinerCharacters.contains(character) {
      return .joiner
    }
    let meaningful = character.unicodeScalars.filter { !$0.properties.isVariationSelector }
    if meaningful.count == 1, let scalar = meaningful.first, isHan(scalar.value) {
      return .han(scalar.value)
    }
    let compatible = String(character).precomposedStringWithCompatibilityMapping
    let compatibleScalars = compatible.unicodeScalars.filter { !$0.properties.isVariationSelector }
    if compatibleScalars.count == 1, let scalar = compatibleScalars.first, isHan(scalar.value) {
      return .han(scalar.value)
    }
    guard character.isLetter else {
      if let letters = asciiLetters(compatible) { return .latin(letters) }
      return .breaker
    }
    if let letters = asciiLetters(compatible) {
      return .latin(letters)
    }
    if let folded = compatible.applyingTransform(latinToASCII, reverse: false),
      let letters = asciiLetters(folded)
    {
      return .latin(letters)
    }
    return .breaker
  }

  private static func isASCIILetters(_ form: [UInt32]) -> Bool {
    form.allSatisfy { (0x61...0x7A).contains($0) }
  }

  private static func asciiLetters(_ text: String) -> [UInt32]? {
    var letters: [UInt32] = []
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x61...0x7A:
        letters.append(scalar.value)
      case 0x41...0x5A:
        letters.append(scalar.value + 32)
      default:
        return nil
      }
    }
    return letters.isEmpty ? nil : letters
  }

  static func isHan(_ value: UInt32) -> Bool {
    switch value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
      return true
    default:
      return false
    }
  }

  private static let joinerCharacters: Set<Character> = ["’", "‘", "‐", "‑", "·", "‧", "・"]
  private static let latinToASCII = StringTransform("Latin-ASCII")
}
