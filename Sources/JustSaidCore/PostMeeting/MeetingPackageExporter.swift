import Foundation

public enum MeetingPackageExportError: LocalizedError {
  case destinationIsNotDirectory
  case missingTranscript
  case missingMinutes

  public var errorDescription: String? {
    switch self {
    case .destinationIsNotDirectory:
      return "请选择一个已有文件夹作为导出位置"
    case .missingTranscript:
      return "权威转写还没有生成，暂时不能导出会议包"
    case .missingMinutes:
      return "中文版纪要还没有生成，暂时不能导出会议包"
    }
  }
}

/// 导出严格限定为五份可交付文档。录音与内部 sidecar 不会被悄悄带出产品。
public struct MeetingPackageExporter {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  @discardableResult
  public func export(
    title: String,
    startedAt: Date,
    endedAt: Date? = nil,
    participants: [String] = [],
    transcriptionStatus: String? = nil,
    paths: MeetingPaths,
    document: MeetingMinutesDocument,
    hasStructuredMinutes: Bool,
    to destinationDirectory: URL
  ) throws -> URL {
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: destinationDirectory.path,
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue
    else {
      throw MeetingPackageExportError.destinationIsNotDirectory
    }

    guard let transcript = nonEmptyData(at: paths.transcript) else {
      throw MeetingPackageExportError.missingTranscript
    }
    guard
      let activeMinutes =
        nonEmptyData(at: paths.minutesFull)
        ?? nonEmptyData(at: paths.minutes)
    else {
      throw MeetingPackageExportError.missingMinutes
    }
    let notes: Data
    if fileManager.fileExists(atPath: paths.notes.path) {
      notes = try Data(contentsOf: paths.notes)
    } else {
      notes = Data()
    }

    let finalDirectory = uniqueDestination(
      title: title,
      startedAt: startedAt,
      parent: destinationDirectory
    )
    let stagingDirectory = destinationDirectory.appendingPathComponent(
      ".justsaid-export-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: false
      )
      try transcript.write(
        to: stagingDirectory.appendingPathComponent("transcript.md"),
        options: .withoutOverwriting
      )
      try activeMinutes.write(
        to: stagingDirectory.appendingPathComponent("minutes.md"),
        options: .withoutOverwriting
      )
      let onePager = OnePagerMarkdownRenderer.render(
        title: title,
        startedAt: startedAt,
        endedAt: endedAt,
        participants: participants,
        transcriptionStatus: transcriptionStatus,
        shortCoveredSeconds: CompletenessReport.load(from: paths)?.shortCoveredSeconds,
        document: document
      )
      try Data(onePager.utf8).write(
        to: stagingDirectory.appendingPathComponent("onepager.md"),
        options: .withoutOverwriting
      )
      let actions = ActionItemsRenderer.renderMarkdown(
        title: title,
        document: document,
        hasStructuredMinutes: hasStructuredMinutes
      )
      try Data(actions.utf8).write(
        to: stagingDirectory.appendingPathComponent("actions.md"),
        options: .withoutOverwriting
      )
      try notes.write(
        to: stagingDirectory.appendingPathComponent("notes.md"),
        options: .withoutOverwriting
      )
      try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
      return finalDirectory
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      throw error
    }
  }

  private func nonEmptyData(at url: URL) -> Data? {
    guard
      fileManager.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      !data.isEmpty
    else {
      return nil
    }
    return data
  }

  private func uniqueDestination(
    title: String,
    startedAt: Date,
    parent: URL
  ) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    let safeTitle = Self.safeFileName(title)
    let base = "\(formatter.string(from: startedAt))-\(safeTitle)"
    var candidate = parent.appendingPathComponent(base, isDirectory: true)
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = parent.appendingPathComponent(
        "\(base)-\(suffix)",
        isDirectory: true
      )
      suffix += 1
    }
    return candidate
  }

  private static func safeFileName(_ title: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\\0")
    let components = title.components(separatedBy: invalid)
    let joined = components.joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? "会议" : String(joined.prefix(80))
  }
}

public struct MeetingPackageDestinationHistory {
  private static let defaultsKey = "justsaid.export.recentDirectories.v1"
  private static let maximumCount = 5

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func destinations() -> [URL] {
    normalizedPaths(defaults.stringArray(forKey: Self.defaultsKey) ?? []).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
  }

  @discardableResult
  public func record(_ directory: URL) -> [URL] {
    let path = directory.standardizedFileURL.path
    let paths = normalizedPaths(
      [path] + (defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    )
    defaults.set(paths, forKey: Self.defaultsKey)
    return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  private func normalizedPaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for rawPath in paths {
      let path = URL(fileURLWithPath: rawPath, isDirectory: true)
        .standardizedFileURL.path
      guard seen.insert(path).inserted else { continue }
      result.append(path)
      if result.count == Self.maximumCount { break }
    }
    return result
  }
}

/// 本场诊断包使用独立的最近目录，避免内部诊断出口污染客户交付包的目录历史。
public struct MeetingDiagnosticsDestinationHistory {
  private static let defaultsKey = "justsaid.meetingDiagnostics.recentDirectories.v1"
  private static let maximumCount = 5

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func destinations() -> [URL] {
    normalizedPaths(defaults.stringArray(forKey: Self.defaultsKey) ?? []).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
  }

  @discardableResult
  public func record(_ directory: URL) -> [URL] {
    let path = directory.standardizedFileURL.path
    let paths = normalizedPaths(
      [path] + (defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    )
    defaults.set(paths, forKey: Self.defaultsKey)
    return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  private func normalizedPaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for rawPath in paths {
      let path = URL(fileURLWithPath: rawPath, isDirectory: true)
        .standardizedFileURL.path
      guard seen.insert(path).inserted else { continue }
      result.append(path)
      if result.count == Self.maximumCount { break }
    }
    return result
  }
}

public enum OnePagerMarkdownRenderer {
  /// `shortCoveredSeconds`:completeness 报告已判有效母带覆盖短欠时的实际覆盖秒数
  /// (判定见 `CompletenessReport.shortCoveredSeconds`,与会议库时长标签同源)。非 nil 时
  /// 文件头改报**实际录到的时长**并标「录到」——忘了关停的一场会不能按会话跨度报时长(#50)。
  public static func render(
    title: String,
    startedAt: Date,
    endedAt: Date? = nil,
    participants: [String] = [],
    transcriptionStatus: String? = nil,
    shortCoveredSeconds: Int? = nil,
    document: MeetingMinutesDocument
  ) -> String {
    var lines = ["# \(title)", ""]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    var header = [formatter.string(from: startedAt)]
    if let endedAt, endedAt > startedAt {
      // 数字量自母带本身、判据来自报告,时间格式仍是导出侧的 `HH:MM:SS`(列表行的紧凑
      // `H:MM` 是列表密度决定,不进导出文件):两处对齐的是口径,不是显示精度。
      if let shortCoveredSeconds {
        header.append("录到 \(durationLabel(TimeInterval(shortCoveredSeconds)))")
      } else {
        header.append("时长 \(durationLabel(endedAt.timeIntervalSince(startedAt)))")
      }
    } else {
      header.append("时长未知")
    }
    let participantLabel =
      participants.isEmpty
      ? "参会人 待识别"
      : "参会人 \(participants.joined(separator: "、"))"
    header.append(participantLabel)
    if let transcriptionStatus, !transcriptionStatus.isEmpty {
      header.append(transcriptionStatus)
    }
    lines.append("> \(header.joined(separator: " · "))")
    if !document.topicTrail.isEmpty {
      lines.append("> \(document.topicTrail.joined(separator: " → "))")
    }

    let conclusions = document.coreConclusions.enumerated().sorted { lhs, rhs in
      let lhsRank = rank(lhs.element.kind)
      let rhsRank = rank(rhs.element.kind)
      return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
    if !conclusions.isEmpty || !document.decisions.isEmpty {
      lines.append(contentsOf: ["", "## 结论带", ""])
      for conclusion in conclusions {
        lines.append(
          "- **\(label(conclusion.kind))** \(anchored(conclusion.content))"
        )
      }
    }
    if !document.decisions.isEmpty {
      lines.append(contentsOf: ["", "### 决策对账", ""])
      for decision in document.decisions {
        lines.append("- **\(decision.issue)**\(anchorSuffix(decision.anchor))")
        for option in decision.options {
          lines.append(
            "  - \(option.speaker)：\(option.proposal)\(anchorSuffix(option.anchor))"
          )
        }
        if !decision.rationale.isEmpty {
          lines.append("  - 依据：\(decision.rationale)")
        }
      }
    }

    lines.append(contentsOf: ["", "## 会议骨架", ""])
    if let semanticTemplate = document.skeleton?.semanticTemplate,
      !semanticTemplate.isEmpty
    {
      lines.append("> 形态：\(semanticTemplate)")
      lines.append("")
    }
    let blocks = document.skeleton?.blocks ?? []
    if blocks.isEmpty {
      let points =
        document.skeleton?.fallbackPoints.isEmpty == false
        ? document.skeleton?.fallbackPoints ?? []
        : document.keyDiscussions
      if points.isEmpty {
        lines.append("- 没有足够可靠的信息形成会议骨架。")
      } else {
        lines.append(contentsOf: points.map { "- \(anchored($0))" })
      }
    } else {
      for block in blocks {
        lines.append(contentsOf: render(block))
        lines.append("")
      }
      if lines.last == "" {
        lines.removeLast()
      }
    }

    let actions = document.actionItems.enumerated().sorted { lhs, rhs in
      let lhsRank = lhs.element.ownership == .me ? 0 : 1
      let rhsRank = rhs.element.ownership == .me ? 0 : 1
      return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
    if !actions.isEmpty {
      lines.append(contentsOf: ["", "## 替你记", ""])
      for action in actions {
        let prefix = action.ownership == .me ? "**我的** " : ""
        let owner = action.owner.map { "（\($0)）" } ?? ""
        lines.append(
          "- \(prefix)\(action.text)\(owner)\(evidenceSuffix(action.evidence))"
            + anchorSuffix(action.recordedAt)
        )
        for update in action.updates {
          lines.append("  - \(update.text)\(anchorSuffix(update.anchor))")
        }
      }
    }

    if !document.openQuestions.isEmpty {
      lines.append(contentsOf: ["", "## 遗留的活", ""])
      for item in document.openQuestions {
        let prefix = item.kind == .toVerify ? "[待核]" : "⚑"
        lines.append("- \(prefix) \(anchored(item.content))")
      }
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
    var lines = ["### \(visualization.title) `\(visualization.badgeLabel)`", ""]
    switch visualization {
    case .steps(_, let items):
      for (index, item) in items.enumerated() {
        lines.append(
          "\(index + 1). **\(item.title)** — \(item.detail)"
            + evidenceSuffix(item.evidence)
            + anchorSuffix(item.anchor)
        )
      }
    case .timeline(_, let items):
      for item in items {
        // 加深字段必须一起导出:owner/interval 是 0.3.0 的头牌能力,
        // 只写 timeLabel+title 会让会议包里的负责人与区间静默消失。
        let stamp = item.interval.map { "\($0)（\(item.timeLabel) 起）" } ?? item.timeLabel
        var line = "- **\(stamp)** \(item.title)"
        if let owner = item.owner { line += "｜负责人：\(owner)" }
        if let detail = item.detail { line += "｜\(detail)" }
        if let relation = item.relationToNext { line += "｜与下一节点：\(relation)" }
        lines.append(line + evidenceSuffix(item.evidence) + anchorSuffix(item.anchor))
      }
    case .table(_, let table):
      lines.append("| \(table.headers.map(escapeTable).joined(separator: " | ")) |")
      lines.append("| \(table.headers.map { _ in "---" }.joined(separator: " | ")) |")
      for row in table.rows {
        var cells = row.cells.map { escapeTable($0.plainText) }
        if let lastIndex = cells.indices.last {
          cells[lastIndex] += evidenceSuffix(row.evidence) + anchorSuffix(row.anchor)
        }
        lines.append("| \(cells.joined(separator: " | ")) |")
      }
    case .tree(_, let roots):
      for root in roots {
        appendTree(root, depth: 0, to: &lines)
      }
    case .nums(_, let items):
      for item in items {
        let context = item.context.map { " — \($0)" } ?? ""
        lines.append(
          "- **\(item.value) \(item.label)**\(context)"
            + evidenceSuffix(item.evidence)
            + anchorSuffix(item.anchor)
        )
      }
    case .chain(_, let items):
      for item in items {
        let detail = item.detail.map { " — \($0)" } ?? ""
        let relation = item.relationToNext.map { " _\($0)_" } ?? ""
        lines.append(
          "- **\(item.title)**\(detail)\(relation)"
            + evidenceSuffix(item.evidence)
            + anchorSuffix(item.anchor)
        )
      }
    case .flow(_, let nodes, let edges):
      // 会议包的 markdown 会被贴进 Notion / 飞书 / GitHub,那些地方原生渲染
      // ```mermaid 代码块 —— 所以导出侧不必再受「没有画布」的限制,直接给图。
      // **只消费已校验的 `edges`**:不让模型另写一份 Mermaid 文本,否则同一张图
      // 会有第二份节点文案与第二个方向口径。方向照 `from`→`to` 原样落,不翻转。
      //
      // 画不出图时退回三列边表(不产出空的 mermaid 块:markdown 里看不出错,
      // 只是图不出来)。节点自带的 detail/anchor/evidence 两条路径都单独成行,
      // 否则只挂在边上会把它们静默丢掉。
      let diagram =
        mermaidFlowchart(nodes: nodes, edges: edges)
        ?? flowEdgeTable(nodes: nodes, edges: edges)
      lines.append(contentsOf: diagram)
      lines.append("")
      for node in nodes {
        let detail = node.detail.map { " — \($0)" } ?? ""
        let suffix = evidenceSuffix(node.evidence) + anchorSuffix(node.anchor)
        guard !detail.isEmpty || !suffix.isEmpty else { continue }
        lines.append("- **\(node.title)**\(detail)\(suffix)")
      }
    }
    return lines
  }

  /// 从已校验的有向边确定性生成 Mermaid flowchart。**返回 nil = 这张图画不出来**,
  /// 调用方退回三列边表 —— 空的 mermaid 块在 markdown 源码里看不出错,只是图不出来。
  ///
  /// 节点标识符按声明序取 `n1…nN`,**不复用模型给的 `nodeID`**:归一化对 id 只要求
  /// 「载荷内唯一的非空字符串」,里面的空格、括号或中文会直接让整个代码块解析失败。
  /// 提示词本来就要求模型按声明序编 `n1…nN`,正常情况下两者逐字相同;标识符渲染后
  /// 也不可见,所以偏差不进用户视野。
  ///
  /// 方向照 `edges` 的 `from`→`to` 原样落,不做任何翻转:方向语义由 D1 的提示词约定
  /// (顺着事情走 / 从提供方指向使用方)一处决定,导出侧再解释一次就是第二份事实。
  /// `feedbackMarked` 同理不消费 —— App 内那条「几何最终权威」的纪律说明这个标记
  /// 本来就不可信,Mermaid 自己也会分层,按标记画虚线等于把模型的猜测当结论。
  private static func mermaidFlowchart(
    nodes: [SummaryFlowNode],
    edges: [SummaryFlowEdge]
  ) -> [String]? {
    guard !nodes.isEmpty, !edges.isEmpty else { return nil }

    // `SummaryVisualization` 是 Codable,sidecar 解码出来的 `.flow` 没有过归一化,
    // 重复 id 与悬空边都可能到这里。两者都退回边表:重复 id 会画出一个连不上的
    // 孤立盒子,悬空边则根本没有落点,而边表照样每条边占一行、悬空端显示原始 id。
    var identifierByNodeID: [String: String] = [:]
    for (index, node) in nodes.enumerated() {
      guard identifierByNodeID[node.nodeID] == nil else { return nil }
      identifierByNodeID[node.nodeID] = "n\(index + 1)"
    }

    var body: [String] = []
    for (index, node) in nodes.enumerated() {
      body.append("  n\(index + 1)[\"\(mermaidText(node.title))\"]")
    }
    for edge in edges {
      guard
        let from = identifierByNodeID[edge.from],
        let to = identifierByNodeID[edge.to]
      else {
        return nil
      }
      let label = edge.label.map { "|\"\(mermaidEdgeLabel($0))\"|" } ?? ""
      body.append("  \(from) -->\(label) \(to)")
    }
    return ["```mermaid", "flowchart TD"] + body + ["```"]
  }

  /// Mermaid 标签转义。**漏一个字符会让整个代码块渲染失败,而 markdown 源码里
  /// 看不出错 —— 只是图不出来**,所以这里宁可多转。
  ///
  /// 括号类(`(` `)` `[` `]` `{` `}`)和中文引号靠**整段套双引号**解决,那是 Mermaid
  /// 自己给的机制;套了引号还会咬人的只剩三类:
  /// - `"` 提前关掉引号,后面全成语法;
  /// - `<` `>` 在 htmlLabels 下会被当标签吞掉(「延迟 <b> 秒」会整段消失);
  /// - 换行把一条语句截成半行代码。节点标题按契约本来是单行,这里只是兜底成空格。
  ///
  /// 用实体码而不是换成形近字符:实体码万一不被某个渲染器认,最坏是盒子里显示
  /// `#34;` 字面量,图还在;裸引号漏出去则是整张图消失。取十进制形式是因为
  /// Mermaid 文档里给的例子就是十进制(`#9829;`)。
  private static func mermaidText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\"", with: "#34;")
      .replacingOccurrences(of: "<", with: "#60;")
      .replacingOccurrences(of: ">", with: "#62;")
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }

  /// 边标签比节点标题多躲一个 `|`:它是 `-->|标签|` 这个写法的定界符。
  private static func mermaidEdgeLabel(_ value: String) -> String {
    mermaidText(value).replacingOccurrences(of: "|", with: "#124;")
  }

  /// 画不出图时的保底形态:与归一化层的降级产物**同一张表**(从 / 关系 / 到),
  /// 不另发明第二种投影。悬空端显示原始 id,不静默丢行。
  private static func flowEdgeTable(
    nodes: [SummaryFlowNode],
    edges: [SummaryFlowEdge]
  ) -> [String] {
    let titleByID = Dictionary(
      nodes.map { ($0.nodeID, $0.title) },
      uniquingKeysWith: { first, _ in first }
    )
    var lines = ["| 从 | 关系 | 到 |", "| --- | --- | --- |"]
    for edge in edges {
      let from = titleByID[edge.from] ?? edge.from
      let to = titleByID[edge.to] ?? edge.to
      lines.append(
        "| \(escapeTable(from)) | \(escapeTable(edge.label ?? "")) | \(escapeTable(to)) |"
      )
    }
    return lines
  }

  private static func appendTree(
    _ node: SummaryTreeNode,
    depth: Int,
    to lines: inout [String]
  ) {
    let detail = node.detail.map { " — \($0)" } ?? ""
    lines.append(
      "\(String(repeating: "  ", count: depth))- **\(node.title)**\(detail)"
        + evidenceSuffix(node.evidence)
        + anchorSuffix(node.anchor)
    )
    for child in node.children {
      appendTree(child, depth: depth + 1, to: &lines)
    }
  }

  private static func anchored(_ content: AnchoredText) -> String {
    content.text + evidenceSuffix(content.evidence) + anchorSuffix(content.anchor)
  }

  private static func evidenceSuffix(_ mark: SummaryEvidenceMark?) -> String {
    switch mark {
    case .toVerify: return " [待核]"
    case .corrected: return " [已修正]"
    case .confirmed: return " [已确认]"
    case nil: return ""
    }
  }

  private static func anchorSuffix(_ anchor: TranscriptAnchor?) -> String {
    guard let anchor, anchor.seconds != nil else { return "" }
    return " ⏱\(anchor.timecode)"
  }

  private static func label(_ kind: MeetingConclusionKind) -> String {
    switch kind {
    case .decision: return "拍板"
    case .consensus: return "共识"
    case .direction: return "方向"
    }
  }

  private static func rank(_ kind: MeetingConclusionKind) -> Int {
    switch kind {
    case .decision: return 0
    case .consensus: return 1
    case .direction: return 2
    }
  }

  private static func durationLabel(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration.rounded()))
    return String(
      format: "%02d:%02d:%02d",
      total / 3_600,
      (total % 3_600) / 60,
      total % 60
    )
  }

  private static func escapeTable(_ value: String) -> String {
    value
      .replacingOccurrences(of: "|", with: "\\|")
      .replacingOccurrences(of: "\n", with: "<br>")
  }
}
