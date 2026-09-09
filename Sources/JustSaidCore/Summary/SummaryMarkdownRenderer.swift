import Foundation

public enum SummaryMarkdownRenderer {
  /// 各版留痕通常是当前全部话题的快照，但早期实产也有只写增量的版本。按落盘顺序合并，
  /// 同标题用新版替换、新标题接在末尾，与会中慢通道的合并规则一致。
  public static func topics(
    fromHistorySnapshots snapshots: [MeetingSummarySnapshot]
  ) -> [SummaryTopic] {
    var merged: [SummaryTopic] = []
    for snapshot in snapshots {
      // 新留痕优先读取同名 JSON sidecar；旧会议没有 sidecar 时只恢复本渲染器曾经
      // 稳定落盘的 Markdown 形状。拿不准的子章节也会退成要点，不再静默丢失。
      let snapshotTopics =
        snapshot.structuredTopics
        ?? topics(fromHistorySnapshot: snapshot.content)
      for topic in snapshotTopics {
        if let index = merged.firstIndex(where: { $0.title == topic.title }) {
          merged[index] = topic
        } else {
          merged.append(topic)
        }
      }
    }
    return merged
  }

  /// 旧留痕没有类型 sidecar，但 Markdown 是本渲染器自己写出的固定格式。只识别能
  /// 唯一判定的编号步骤、表格、时间线与数字表；其他 `###` 子章节逐行退成普通要点，
  /// 确保真实 07-29/07-30 留痕不会因为一个未知形状整段消失。
  private static func topics(fromHistorySnapshot markdown: String) -> [SummaryTopic] {
    var topics: [SummaryTopic] = []
    var title: String?
    var timeRangeLabel: String?
    var bullets: [SummaryBullet] = []
    var visualizations: [SummaryVisualization] = []

    func appendCurrentTopic() {
      guard
        let title,
        !title.isEmpty,
        let timeRangeLabel,
        !timeRangeLabel.isEmpty
      else {
        return
      }
      topics.append(
        SummaryTopic(
          title: title,
          timeRangeLabel: timeRangeLabel,
          bullets: bullets,
          visualizations: visualizations
        )
      )
    }

    let lines = markdown.components(separatedBy: .newlines)
    var index = 0
    while index < lines.count {
      let rawLine = lines[index]
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("## ") {
        appendCurrentTopic()
        title = String(line.dropFirst(3))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        timeRangeLabel = nil
        bullets = []
        visualizations = []
      } else if line.hasPrefix("时间：") {
        timeRangeLabel = String(line.dropFirst(3))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      } else if line.hasPrefix("### "), title != nil {
        let sectionTitle = String(line.dropFirst(4))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        index += 1
        var sectionLines: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          if candidate.hasPrefix("## ") || candidate.hasPrefix("### ") {
            break
          }
          sectionLines.append(lines[index])
          index += 1
        }
        if let visualization = legacyVisualization(
          title: sectionTitle,
          lines: sectionLines
        ) {
          visualizations.append(visualization)
        } else {
          bullets.append(
            contentsOf: fallbackBullets(
              sectionTitle: sectionTitle,
              lines: sectionLines
            )
          )
        }
        continue
      } else if line.hasPrefix("- "), title != nil, timeRangeLabel != nil {
        let text = String(line.dropFirst(2))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          bullets.append(SummaryBullet(text: .plain(text)))
        }
      }
      index += 1
    }
    appendCurrentTopic()
    return topics
  }

  private static func legacyVisualization(
    title: String,
    lines: [String]
  ) -> SummaryVisualization? {
    let contentLines = lines.filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    if let markdownTable = parseMarkdownTable(contentLines) {
      if markdownTable.headers == ["时间", "事件"] {
        return .timeline(
          title: title,
          items: markdownTable.rows.map {
            SummaryTimelineItem(timeLabel: $0[0], title: $0[1])
          }
        )
      }
      if markdownTable.headers == ["指标", "数值", "语境"] {
        return .nums(
          title: title,
          items: markdownTable.rows.map {
            SummaryNumberItem(
              value: $0[1],
              label: $0[0],
              context: $0[2].isEmpty ? nil : $0[2]
            )
          }
        )
      }
      return .table(
        title: title,
        table: SummaryTable(
          headers: markdownTable.headers,
          rows: markdownTable.rows.map { row in
            SummaryTableRow(cells: row.map(SummaryRichText.plain))
          }
        )
      )
    }

    let numbered = contentLines.compactMap(parseNumberedLine)
    guard
      !numbered.isEmpty,
      numbered.count == contentLines.count,
      numbered.enumerated().allSatisfy({ offset, item in
        item.number == offset + 1
      })
    else {
      return nil
    }

    // chain 的箭头或无详情节点不会由 steps 渲染器产生，因此可以可靠区分；
    // 只有 `：详情` 的编号块沿用 07-29/07-30 的 legacy steps 解释。
    let isChain =
      numbered.contains { $0.remainder.contains(" → ") || $0.remainder.isEmpty }
    if isChain {
      let items = numbered.compactMap(parseChainItem)
      guard items.count == numbered.count else { return nil }
      return .chain(title: title, items: items)
    }

    let items = numbered.compactMap(parseStepItem)
    guard items.count == numbered.count else { return nil }
    return .steps(title: title, items: items)
  }

  private static func parseMarkdownTable(
    _ lines: [String]
  ) -> (headers: [String], rows: [[String]])? {
    guard
      lines.count >= 3,
      let headers = parseMarkdownTableRow(lines[0]),
      let separators = parseMarkdownTableRow(lines[1]),
      !headers.isEmpty,
      separators.count == headers.count,
      separators.allSatisfy(isMarkdownSeparator)
    else {
      return nil
    }

    let rows = lines.dropFirst(2).compactMap(parseMarkdownTableRow)
    guard
      rows.count == lines.count - 2,
      !rows.isEmpty,
      rows.allSatisfy({ $0.count == headers.count })
    else {
      return nil
    }
    return (headers, rows)
  }

  private static func parseMarkdownTableRow(_ rawLine: String) -> [String]? {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.first == "|", line.last == "|" else { return nil }

    var cells: [String] = []
    var cell = ""
    var isEscaped = false
    for character in line.dropFirst().dropLast() {
      if isEscaped {
        if character != "|" {
          cell.append("\\")
        }
        cell.append(character)
        isEscaped = false
      } else if character == "\\" {
        isEscaped = true
      } else if character == "|" {
        cells.append(decodedTableCell(cell))
        cell = ""
      } else {
        cell.append(character)
      }
    }
    if isEscaped {
      cell.append("\\")
    }
    cells.append(decodedTableCell(cell))
    return cells
  }

  private static func decodedTableCell(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "<br>", with: "\n")
  }

  private static func isMarkdownSeparator(_ value: String) -> Bool {
    let core = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    return core.count >= 3 && core.allSatisfy { $0 == "-" }
  }

  private static func parseNumberedLine(
    _ rawLine: String
  ) -> (number: Int, title: String, remainder: String)? {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let dot = line.firstIndex(of: "."),
      let number = Int(line[..<dot])
    else {
      return nil
    }
    let afterDot = line.index(after: dot)
    guard afterDot < line.endIndex, line[afterDot].isWhitespace else {
      return nil
    }
    let payload = line[line.index(after: afterDot)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard payload.hasPrefix("**") else { return nil }
    let titleStart = payload.index(payload.startIndex, offsetBy: 2)
    guard
      let closing = payload.range(
        of: "**",
        range: titleStart..<payload.endIndex
      )
    else {
      return nil
    }
    let title = String(payload[titleStart..<closing.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    let remainder = String(payload[closing.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (number, title, remainder)
  }

  private static func parseStepItem(
    _ item: (number: Int, title: String, remainder: String)
  ) -> SummaryStepItem? {
    var remainder = item.remainder
    let isPrerequisite = remainder.hasPrefix("（前置）")
    if isPrerequisite {
      remainder.removeFirst("（前置）".count)
    }
    guard remainder.hasPrefix("：") else { return nil }
    remainder.removeFirst()
    return SummaryStepItem(
      title: item.title,
      detail: remainder.trimmingCharacters(in: .whitespacesAndNewlines),
      isPrerequisite: isPrerequisite
    )
  }

  private static func parseChainItem(
    _ item: (number: Int, title: String, remainder: String)
  ) -> SummaryChainItem? {
    var detailAndRelation = item.remainder
    var relation: String?
    if let arrow = detailAndRelation.range(of: " → ") {
      let value = detailAndRelation[arrow.upperBound...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return nil }
      relation = value
      detailAndRelation = String(detailAndRelation[..<arrow.lowerBound])
    }

    let detail: String?
    if detailAndRelation.isEmpty {
      detail = nil
    } else {
      guard detailAndRelation.hasPrefix("：") else { return nil }
      detailAndRelation.removeFirst()
      let value = detailAndRelation.trimmingCharacters(in: .whitespacesAndNewlines)
      detail = value.isEmpty ? nil : value
    }
    return SummaryChainItem(
      title: item.title,
      detail: detail,
      relationToNext: relation
    )
  }

  private static func fallbackBullets(
    sectionTitle: String,
    lines: [String]
  ) -> [SummaryBullet] {
    var values = sectionTitle.isEmpty ? [] : [sectionTitle]
    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }

      if let cells = parseMarkdownTableRow(line) {
        guard !cells.allSatisfy(isMarkdownSeparator) else { continue }
        values.append(cells.joined(separator: " · "))
      } else if let numbered = parseNumberedLine(line) {
        values.append(
          "\(numbered.title)\(numbered.remainder)"
            .replacingOccurrences(of: "**", with: "")
        )
      } else if line.hasPrefix("- ") {
        values.append(
          String(line.dropFirst(2))
            .replacingOccurrences(of: "**", with: "")
        )
      } else {
        values.append(line.replacingOccurrences(of: "**", with: ""))
      }
    }
    return values.filter { !$0.isEmpty }.map {
      SummaryBullet(text: .plain($0))
    }
  }

  public static func historySnapshot(
    topics: [SummaryTopic],
    coveredUntilLabel: String
  ) -> String {
    var lines = [
      "# 会中总结留痕",
      "",
      "> 覆盖至 \(coveredUntilLabel)",
      "",
    ]

    for topic in topics {
      lines.append("## \(TextAssetSanitizer.sanitize(topic.title))")
      lines.append("")
      lines.append("时间：\(TextAssetSanitizer.sanitize(topic.timeRangeLabel))")
      lines.append("")
      for bullet in topic.bullets {
        lines.append("- \(TextAssetSanitizer.sanitize(bullet.text.plainText))")
      }
      if !topic.bullets.isEmpty {
        lines.append("")
      }
      for visualization in topic.visualizations {
        lines.append(contentsOf: render(visualization))
        lines.append("")
      }
    }

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      + "\n"
  }

  public static func chapters(_ topics: [SummaryTopic]) -> String {
    guard !topics.isEmpty else {
      return "## 章节视图\n\n- 本场会议没有可用的会中总结留痕。\n"
    }
    var lines = ["## 章节视图", ""]
    for topic in topics {
      let summary = TextAssetSanitizer.sanitize(
        topic.bullets.first?.text.plainText ?? "无摘要"
      )
      lines.append(
        "- **\(TextAssetSanitizer.sanitize(topic.timeRangeLabel)) · "
          + "\(TextAssetSanitizer.sanitize(topic.title))**：\(summary)"
      )
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// 验证入口:让断言能直接量「加深字段是否流到这个出口」。
  /// 2026-08-12 对抗验证发现 timeline 的 owner/interval/detail/relationToNext
  /// 在这一层被静默丢弃,补了断言就必须能从外部调到渲染结果。
  public static func visualizationLines(_ visualization: SummaryVisualization) -> [String] {
    render(visualization)
  }

  private static func render(_ visualization: SummaryVisualization) -> [String] {
    switch visualization {
    case .steps(let title, let items):
      var lines = ["### \(TextAssetSanitizer.sanitize(title))", ""]
      for (index, item) in items.enumerated() {
        let prerequisite = item.isPrerequisite ? "（前置）" : ""
        lines.append(
          "\(index + 1). **\(TextAssetSanitizer.sanitize(item.title))**"
            + "\(prerequisite)：\(TextAssetSanitizer.sanitize(item.detail))"
        )
      }
      return lines

    case .table(let title, let table):
      guard !table.headers.isEmpty else {
        return [
          "### \(TextAssetSanitizer.sanitize(title))",
          "",
          "- 表格内容不可用",
        ]
      }
      var lines = [
        "### \(TextAssetSanitizer.sanitize(title))",
        "",
        "| \(table.headers.map(sanitizedTableCell).joined(separator: " | ")) |",
        "| \(table.headers.map { _ in "---" }.joined(separator: " | ")) |",
      ]
      for row in table.rows {
        let cells = row.cells.map { sanitizedTableCell($0.plainText) }
        lines.append("| \(cells.joined(separator: " | ")) |")
      }
      return lines

    case .timeline(let title, let items):
      // 加深字段按需成列:留痕 markdown 同时是 sidecar 缺失时的恢复源,
      // 只写「时间 / 事件」会让 owner/interval 在恢复路径上永久丢失。
      // 列按「本图是否真有该字段」增减,旧数据仍是原来的两列。
      let hasOwner = items.contains { $0.owner != nil }
      let hasDetail = items.contains { $0.detail != nil }
      let hasRelation = items.contains { $0.relationToNext != nil }
      var headers = ["时间", "事件"]
      if hasOwner { headers.append("负责人") }
      if hasDetail { headers.append("说明") }
      if hasRelation { headers.append("与下一节点") }
      var lines = [
        "### \(TextAssetSanitizer.sanitize(title))",
        "",
        "| \(headers.joined(separator: " | ")) |",
        "| \(headers.map { _ in "---" }.joined(separator: " | ")) |",
      ]
      for item in items {
        // interval 与 timeLabel 都是逐字原文,两者都在时一起呈现,不做解析取舍。
        let stamp =
          item.interval.map { "\(sanitizedTableCell($0))（\(sanitizedTableCell(item.timeLabel)) 起）" }
          ?? sanitizedTableCell(item.timeLabel)
        var cells = [stamp, sanitizedTableCell(item.title)]
        if hasOwner { cells.append(item.owner.map(sanitizedTableCell) ?? "") }
        if hasDetail { cells.append(item.detail.map(sanitizedTableCell) ?? "") }
        if hasRelation { cells.append(item.relationToNext.map(sanitizedTableCell) ?? "") }
        lines.append("| \(cells.joined(separator: " | ")) |")
      }
      return lines

    case .tree(let title, let roots):
      var lines = ["### \(TextAssetSanitizer.sanitize(title))", ""]
      func append(_ nodes: [SummaryTreeNode], depth: Int) {
        for node in nodes {
          let detail =
            node.detail.map { "：\(TextAssetSanitizer.sanitize($0))" } ?? ""
          lines.append(
            "\(String(repeating: "  ", count: depth))- "
              + "**\(TextAssetSanitizer.sanitize(node.title))**\(detail)"
          )
          append(node.children, depth: depth + 1)
        }
      }
      append(roots, depth: 0)
      return lines

    case .nums(let title, let items):
      var lines = [
        "### \(TextAssetSanitizer.sanitize(title))",
        "",
        "| 指标 | 数值 | 语境 |",
        "| --- | --- | --- |",
      ]
      for item in items {
        lines.append(
          "| \(sanitizedTableCell(item.label)) | \(sanitizedTableCell(item.value)) | "
            + "\(sanitizedTableCell(item.context ?? "")) |"
        )
      }
      return lines

    case .chain(let title, let items):
      var lines = ["### \(TextAssetSanitizer.sanitize(title))", ""]
      for (index, item) in items.enumerated() {
        let detail =
          item.detail.map { "：\(TextAssetSanitizer.sanitize($0))" } ?? ""
        let relation =
          item.relationToNext.map { " → \(TextAssetSanitizer.sanitize($0))" } ?? ""
        lines.append(
          "\(index + 1). **\(TextAssetSanitizer.sanitize(item.title))**\(detail)\(relation)"
        )
      }
      return lines

    case .flow(let title, let nodes, let edges):
      // 留痕这条路**故意不出 Mermaid**,与会议包导出不对称(08-13 拍板):
      // 留痕 markdown 同时是 **sidecar 缺失时的恢复源**,而 `legacyVisualization`
      // 只认 markdown 表格。换成 Mermaid 之后整段会掉进 `fallbackBullets` ——
      // 连 ``` 围栏都变成要点文本,恢复结果比今天(退成 `.table`)更差,而留痕
      // 又从不外发,拿不到 Mermaid 的好处。要改先写 Mermaid 解析器,那是另一单。
      // 表本身与归一化层的降级形态**同一张**(从 / 关系 / 到),不另发明第二种投影。
      let titleByID = Dictionary(
        nodes.map { ($0.nodeID, $0.title) },
        uniquingKeysWith: { first, _ in first }
      )
      var lines = [
        "### \(TextAssetSanitizer.sanitize(title))",
        "",
        "| 从 | 关系 | 到 |",
        "| --- | --- | --- |",
      ]
      for edge in edges {
        let from = titleByID[edge.from] ?? edge.from
        let to = titleByID[edge.to] ?? edge.to
        lines.append(
          "| \(sanitizedTableCell(from)) | \(sanitizedTableCell(edge.label ?? "")) | "
            + "\(sanitizedTableCell(to)) |"
        )
      }
      return lines
    }
  }

  private static func sanitizedTableCell(_ value: String) -> String {
    escapeTableCell(TextAssetSanitizer.sanitize(value))
  }

  private static func escapeTableCell(_ value: String) -> String {
    value
      .replacingOccurrences(of: "|", with: "\\|")
      .replacingOccurrences(of: "\n", with: "<br>")
  }
}

struct SummaryHistorySidecar: Codable {
  let version: Int
  let coveredUntilLabel: String
  let topics: [SummaryTopic]
  let actionItems: [SummaryActionItem]

  init(
    coveredUntilLabel: String,
    topics: [SummaryTopic],
    actionItems: [SummaryActionItem]
  ) {
    version = 1
    self.coveredUntilLabel = coveredUntilLabel
    self.topics = topics
    self.actionItems = actionItems
  }
}

struct SummaryHistoryWriter {
  let directory: URL

  func write(
    topics: [SummaryTopic],
    actionItems: [SummaryActionItem] = [],
    coveredUntilLabel: String,
    sequence: Int,
    date: Date
  ) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HHmmss"
    let stem = String(format: "%03d-%@", sequence, formatter.string(from: date))
    let url = directory.appendingPathComponent(stem).appendingPathExtension("md")
    let sidecarURL = directory.appendingPathComponent(stem).appendingPathExtension("json")
    let content = SummaryMarkdownRenderer.historySnapshot(
      topics: topics,
      coveredUntilLabel: coveredUntilLabel
    )
    let sidecar = SummaryHistorySidecar(
      coveredUntilLabel: coveredUntilLabel,
      topics: topics,
      actionItems: actionItems
    )
    // 先写 sidecar：若 Markdown 随后失败，孤立 JSON 不会被读取；反过来则会产生
    // 看似成功却永久丢掉类型信息的留痕。
    try StructuredArtifactCodec.encode(sidecar).write(to: sidecarURL, options: .atomic)
    try Data(content.utf8).write(to: url, options: .atomic)
    return url
  }
}
