import Foundation

/// 词典的一行:一个主体,外加它的真实称呼。
///
/// 行语法 `主体=称呼1,称呼2,…`;不含 `=` 的纯词行是术语(示例公司、示例产品名)或没有别称的主体。
/// 例:`张三=三儿,老张,San,Zhang`——右边是**别人真的这么叫**的称呼,
/// **不是 ASR 错写清单**(2026-07-30 用户拍板:错写是机器噪声,无限且不该由人维护;
/// 变种由纪要模型拿着名册+上下文在阅读时推断,存储层只记事实)。
///
/// 用途:①主体与全部称呼都进 ASR 热词(它们都是会被说出口的词);
/// ②纪要/总结提示词注入人物名册,署名统一用主体名;③说话人命名的候选名册。
/// **任何地方都不做转写文本替换。**
///
/// 分隔符同时收半角与全角:这个文件是给中文用户手写的,输入法给出的逗号多半是「，」。
public struct DictionaryEntry: Equatable, Sendable {
  public let canonical: String
  public let appellations: [String]

  public init(canonical: String, appellations: [String] = []) {
    self.canonical = canonical
    self.appellations = appellations
  }

  /// 主体 + 称呼(去重保序),即该条目应进热词的全部词面。
  public var allSpokenForms: [String] {
    var seen = Set<String>()
    return ([canonical] + appellations).filter { seen.insert($0).inserted }
  }

  public static func parse(_ line: String) -> DictionaryEntry? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: "=", maxSplits: 1)
    let canonical = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonical.isEmpty else { return nil }
    guard parts.count == 2 else {
      return DictionaryEntry(canonical: canonical)
    }
    let appellations =
      parts[1]
      .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && $0 != canonical }
    return DictionaryEntry(canonical: canonical, appellations: appellations)
  }

  public static func parseAll(_ lines: [String]) -> [DictionaryEntry] {
    var seen = Set<String>()
    return lines.compactMap(parse).filter { seen.insert($0.canonical).inserted }
  }
}
