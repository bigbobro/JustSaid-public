import Foundation

enum TextAssetSanitizer {
  static func sanitize(_ value: String) -> String {
    let withoutLinks =
      value
      .replacingOccurrences(
        of: #"!?\[([^\]]*)\]\(https?://[^)\s]+(?:\s+"[^"]*")?\)"#,
        with: "$1",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: #"https?://[^\s<>)\]]+"#,
        with: "[远程引用已移除]",
        options: [.regularExpression, .caseInsensitive]
      )
    let stripped = stripInputMarkers(stripFieldNameArtifacts(withoutLinks))
    guard stripped != withoutLinks else {
      return stripSegmentCitations(withoutLinks)
    }
    // 摘掉字段名/输入标记会留下空括号和双空格，先收拾一遍再交给编号清理（后者对
    // 不含 `#` 的文本会直接原样返回，收拾不到）。
    return stripSegmentCitations(tidy(stripped))
  }

  /// 表格里被模型加出来的「来源」列表头。整列删掉,不留空列。
  /// 判定放得比较宽:表头很短、且落在这几个词里,才算——正常业务表格不会用这些做列名。
  static func isCitationHeader(_ header: String) -> Bool {
    let normalized =
      header
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "")
    let citationHeaders: Set<String> = [
      "来源", "来源片段", "出处", "引用", "引用来源", "溯源", "依据", "原文", "原文位置",
      "source", "sources", "ref", "refs", "reference", "references", "citation", "citations",
    ]
    return citationHeaders.contains(normalized)
  }

  /// 去掉被当成正文写出来的 JSON 字段名(2026-07-30 实测:快通道正文尾巴上挂着
  /// `（sourceRefs:）`,占位符本身泄漏到了用户眼前)。
  ///
  /// 只清这三个字段名,**不清「来源」「引用」「出处」这类中文词**——
  /// 「（来源：客户访谈）」是正常业务写法,误删比留着糟；表格里的来源列由
  /// `isCitationHeader` 整列丢弃,两条路各管各的。
  private static func stripFieldNameArtifacts(_ value: String) -> String {
    let names = #"["'“”]?(?:sourceRefs?|segmentIndexes|bulletIndex)["'“”]?"#
    guard
      value.range(
        of: #"(?:sourceRefs?|segmentIndexes|bulletIndex)"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil
    else {
      return value
    }
    return
      value
      // ①整段被括号包起来:`（sourceRefs:）`、`(sourceRefs: 0, 1)`,连括号一起摘。
      .replacingOccurrences(
        of: #"[（(\[【][ \t]*"# + names + #"[ \t]*[:：]?[^)）\]】\n]*[)）\]】]"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      // ②裸字段名带值:`sourceRefs: [0, 1]`、`sourceRefs：0、1`。
      .replacingOccurrences(
        of: names + #"[ \t]*[:：][ \t]*(?:\[[^\]\n]*\]|[\d ,，、#\t]*)"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
  }

  /// `[附和]` 是喂给总结模型的输入侧标记(见 `LiveSummaryFeed.isBackchannel`),
  /// 模型有把输入标记照抄回输出的习惯。它不是会议内容,落到正文、留痕或纪要里
  /// 和 `（sourceRefs:）` 是同一类泄漏,一律摘掉。
  private static func stripInputMarkers(_ value: String) -> String {
    guard value.contains("附和") else { return value }
    return value.replacingOccurrences(
      of: #"[\[［【（(]\s*附和\s*[\]］】）)]"#,
      with: "",
      options: .regularExpression
    )
  }

  /// 摘走东西之后的收尾:空括号、连续空格、标点前的空格。
  private static func tidy(_ value: String) -> String {
    value
      .replacingOccurrences(of: #"[（(]\s*[)）]"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
      .replacingOccurrences(
        of: #"[ \t]+([。，、；：？！）】」])"#,
        with: "$1",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespaces)
  }

  /// 去掉「第几句话」式的速记编号引用(2026-07-29 实测反馈:正文里的
  /// `（[#0]–[#11]）` 只让人分心,读者无法据此做任何判断;溯源仍由「来自」标签给原文)。
  ///
  /// 模型的写法不统一,实测见过三种:带方括号的 `[#3]`、括号里的裸编号 `（#4, #5）`、
  /// 以及表格里整格只写 `#6, #7`。三种都清,但**裸 `#3` 出现在正文中间时不动**——
  /// 那可能是工单号、PR 号这类真内容,误删比留着更糟。
  private static func stripSegmentCitations(_ value: String) -> String {
    guard value.contains("#") else { return value }
    let bracketed = #"\[#\d+\]"#
    let anyCitation = #"(?:\[#\d+\]|#\d+)"#
    let separators = #"[\s,，、;；和及至到\-–—~～]*"#

    // 整格/整句只有编号(表格「来源」列漏掉表头识别时的兜底):直接清空。
    let onlyCitations = "^\(separators)(?:\(anyCitation)\(separators))+$"
    if value.range(of: onlyCitations, options: .regularExpression) != nil {
      return ""
    }

    return tidy(
      value
        // ①括号包起来的一组编号,连括号一起摘(裸编号仅在此形态下清除)。
        .replacingOccurrences(
          of: "[（(]\\s*(?:\(anyCitation)\(separators))+[)）]",
          with: "",
          options: .regularExpression
        )
        // ②散落在正文里的带方括号编号。
        .replacingOccurrences(
          of: "\(bracketed)(?:\(separators)\(bracketed))*",
          with: "",
          options: .regularExpression
        )
    )
  }
}
