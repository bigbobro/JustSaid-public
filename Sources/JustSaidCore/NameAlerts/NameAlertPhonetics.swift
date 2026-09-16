import Foundation

/// 点名匹配用到的两个纯函数:英文 Metaphone 编码与归一化 Indel 相似度。
///
/// 两者都以 CueMeIn 锁定依赖为参考实现:Metaphone 对齐 jellyfish 1.2.1 实际导出的
/// Rust 实现(包内纯 Python 版在词尾 `gh`/`gn`/`mb` 等处与之不同,不作为参考);
/// 相似度对齐 rapidfuzz 3.14.5 的 `fuzz.ratio`,即 `200 × LCS / (|a| + |b|)`。
/// 阈值表只在这一比率下成立,不能换成 Levenshtein 等其他距离后沿用。
public enum NameAlertPhonetics {
  /// 经典 Metaphone 编码,输出大写;空格折叠为单个空格,其他非字母字符不产生编码。
  public static func metaphone(_ text: String) -> String {
    let scalars = Array(text.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars)
    return metaphone(lowercasedScalars: scalars)
  }

  /// 按 Unicode 标量计算的归一化 Indel 相似度(0...100)。两者皆空为 100,仅一方为空为 0。
  public static func indelRatio(_ lhs: String, _ rhs: String) -> Double {
    indelRatio(Array(lhs.unicodeScalars.map(\.value)), Array(rhs.unicodeScalars.map(\.value)))
  }

  static func indelRatio(_ lhs: [UInt32], _ rhs: [UInt32]) -> Double {
    if lhs.isEmpty && rhs.isEmpty { return 100 }
    if lhs.isEmpty || rhs.isEmpty { return 0 }
    return 200.0 * Double(longestCommonSubsequence(lhs, rhs)) / Double(lhs.count + rhs.count)
  }

  /// 两串长度差决定的相似度上限,用于在计算 LCS 前剪掉不可能过阈值的窗口。
  static func indelRatioUpperBound(_ lhsCount: Int, _ rhsCount: Int) -> Double {
    guard lhsCount + rhsCount > 0 else { return 100 }
    return 200.0 * Double(min(lhsCount, rhsCount)) / Double(lhsCount + rhsCount)
  }

  static func longestCommonSubsequence(_ lhs: [UInt32], _ rhs: [UInt32]) -> Int {
    let (short, long) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
    var previous = [Int](repeating: 0, count: short.count + 1)
    var current = previous
    for element in long {
      for index in 0..<short.count {
        current[index + 1] =
          short[index] == element
          ? previous[index] + 1
          : max(previous[index + 1], current[index])
      }
      swap(&previous, &current)
    }
    return previous[short.count]
  }

  static func metaphone(lowercasedScalars input: [Unicode.Scalar]) -> String {
    var characters = input
    if characters.count >= 2,
      skippedInitialPairs.contains(String(String.UnicodeScalarView(characters[0...1])))
    {
      characters.removeFirst()
    }
    let count = characters.count
    func scalar(at index: Int) -> Unicode.Scalar? {
      index < count ? characters[index] : nil
    }
    func isVowel(_ value: Unicode.Scalar?) -> Bool {
      guard let value else { return false }
      return "aeiou".unicodeScalars.contains(value)
    }
    func isOneOf(_ value: Unicode.Scalar?, _ set: String) -> Bool {
      guard let value else { return false }
      return set.unicodeScalars.contains(value)
    }

    var result = String.UnicodeScalarView()
    var index = 0
    while index < count {
      let current = characters[index]
      let next = scalar(at: index + 1)
      let afterNext = scalar(at: index + 2)
      let previous = index > 0 ? characters[index - 1] : nil

      if current == next && current != "c" {
        index += 1
        continue
      }

      switch current {
      case "a", "e", "i", "o", "u":
        if index == 0 || previous == " " { result.append(current) }
      case "b":
        if previous != "m" || next != nil { result.append("b") }
      case "c":
        if (next == "i" && afterNext == "a") || next == "h" {
          result.append("x")
          index += 1
        } else if isOneOf(next, "iey") {
          result.append("s")
          index += 1
        } else {
          result.append("k")
        }
      case "d":
        if next == "g" && isOneOf(afterNext, "iey") {
          result.append("j")
          index += 2
        } else {
          result.append("t")
        }
      case "f", "j", "l", "m", "n", "r":
        result.append(current)
      case "g":
        if isOneOf(next, "iey") {
          result.append("j")
        } else if next == "h" && afterNext != nil && !isVowel(afterNext) {
          index += 1
        } else if next == "n" && afterNext == nil {
          index += 1
        } else {
          result.append("k")
        }
      case "h":
        if index == 0 || isVowel(next) || !isVowel(previous) { result.append("h") }
      case "k":
        if index == 0 || previous != "c" { result.append("k") }
      case "p":
        if next == "h" {
          result.append("f")
          index += 1
        } else {
          result.append("p")
        }
      case "q":
        result.append("k")
      case "s":
        if next == "h" {
          result.append("x")
          index += 1
        } else if next == "i" && isOneOf(afterNext, "oa") {
          result.append("x")
          index += 2
        } else {
          result.append("s")
        }
      case "t":
        if next == "i" && isOneOf(afterNext, "oa") {
          result.append("x")
        } else if next == "h" {
          result.append("0")
          index += 1
        } else if !(next == "c" && afterNext == "h") {
          result.append("t")
        }
      case "v":
        result.append("f")
      case "w":
        if index == 0 && next == "h" {
          index += 1
          result.append("w")
        } else if isVowel(next) {
          result.append("w")
        }
      case "x":
        if index == 0 {
          if next == "h" || (next == "i" && isOneOf(afterNext, "oa")) {
            result.append("x")
          } else {
            result.append("s")
          }
        } else {
          result.append("k")
          result.append("s")
        }
      case "y":
        if isVowel(next) { result.append("y") }
      case "z":
        result.append("s")
      case " ":
        if let last = result.last, last != " " { result.append(" ") }
      default:
        break
      }
      index += 1
    }
    return String(result).uppercased()
  }

  private static let skippedInitialPairs: Set<String> = ["kn", "gn", "pn", "wr", "ae"]
}
