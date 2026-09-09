import Foundation

/// flow 的提示词条款。**会中慢通道与会后骨架共用同一份字面量，不许各抄一份。**
///
/// 抄第二份的具体代价:D1 的方向约定(spec `ui/design-system.md`「flow 原语」)
/// 一旦两处措辞漂开，同一场会的会中图与一页纸图可能方向相反——而渲染端只判层序、
/// 不判语义，**无从发现**。上限(8/12)与负例克制(线性流程用 chain/steps)同理:
/// 两条链路对「什么时候该出 flow」给出不同口径，等于同一个模型被要求守两套契约。
///
/// 位置在 wire 旁边是刻意的:提示词与解码器是同一份契约的两头(spec
/// `core/justsaidcore-architecture.md`「会中慢通道的 viz 更新契约(prompt 侧)」)。
///
/// 看护:`SummaryEngineVerification` 钉慢通道系统提示词含三条锚点、
/// `BatchPipelineVerification` 钉会后中文纪要提示词含同样三条。
enum SummaryVisualizationPrompt {
  static let flowClause = """
    flow 用 nodes+edges，只在讨论里出现「分支之后又汇到一起」「多个东西共用同一个
    上游」「A 影响 B、B 又回过来影响 A」这三类结构时用——一条线能讲完就用 chain
    或 steps，不要把线性流程画成 flow。nodes 按出现顺序编号 n1、n2……，同一张图内
    id 不重复；edges 的 from/to 只能引用这些 id。
    **箭头方向一律顺着事情走**：从上游指向下游、从提供方指向使用方。
    `{"from":"A","to":"B"}` 读作「A 之后到 B」或「A 供给 B」，与 steps、chain 的
    阅读方向一致。不要按「谁依赖谁」反着标：说「移动端依赖统一认证」时，
    边要写成 `统一认证 → 移动端`。闭合回路的那条边加 "feedback": true。
    节点最多 8 个、边最多 12 条；超了说明这张图太密，换 chain 或改用要点。
    """
}

/// LLM 边界使用的宽松 tagged payload。会中总结与会后骨架共用同一个解码器，
/// 避免两条生成链路各自解释一遍六原语。
struct SummaryVisualizationWire: Decodable {
  struct Item: Decodable {
    let timeLabel: String?
    let title: String?
    let detail: String?
    let isPrerequisite: Bool?
    let value: String?
    let label: String?
    let context: String?
    let relationToNext: String?
    let owner: String?
    let interval: String?
    let anchor: String?
    let evidence: String?
  }

  struct Node: Decodable {
    let title: String
    let detail: String?
    let children: [Node]
    let anchor: String?
    let evidence: String?

    private enum CodingKeys: String, CodingKey {
      case title
      case detail
      case children
      case anchor
      case evidence
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      title = try container.decode(String.self, forKey: .title)
      detail = try container.decodeIfPresent(String.self, forKey: .detail)
      children = try container.decodeIfPresent([Node].self, forKey: .children) ?? []
      anchor = try container.decodeIfPresent(String.self, forKey: .anchor)
      evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
    }
  }

  /// flow 的节点。字段全部可选，合不合格交给归一化判定——`Node.title` 那种
  /// 非可选写法会让整个 wire 解码失败落到 `malformed`，flow 的降级判定就永远
  /// 走不到（缺 title 的节点必须能进边表，见 design §4.2/§4.3）。
  struct FlowNode: Decodable {
    let id: String?
    let title: String?
    let detail: String?
    let anchor: String?
    let evidence: String?
  }

  struct Edge: Decodable {
    let from: String?
    let to: String?
    let label: String?
    let feedback: Bool?
  }

  struct Row: Decodable {
    let cells: [String]
    let anchor: String?
    let evidence: String?

    private enum CodingKeys: String, CodingKey {
      case cells
      case anchor
      case evidence
    }

    init(from decoder: Decoder) throws {
      if let values = try? decoder.singleValueContainer().decode([String].self) {
        cells = values
        anchor = nil
        evidence = nil
        return
      }
      let container = try decoder.container(keyedBy: CodingKeys.self)
      cells = try container.decode([String].self, forKey: .cells)
      anchor = try container.decodeIfPresent(String.self, forKey: .anchor)
      evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
    }
  }

  /// 归一化分发与解码分发**必须用同一个口径**。两边一个比原串、一个比小写串时，
  /// `"Flow"` 会既按 tree 把 `nodes` 解成 `roots`、又按 flow 分发出去。
  static let flowType = "flow"

  let type: String
  let title: String?
  let headers: [String]?
  let rows: [Row]?
  let items: [Item]?
  let roots: [Node]?
  let flowNodes: [FlowNode]?
  let edges: [Edge]?

  private enum CodingKeys: String, CodingKey {
    case type
    case title
    case headers
    case rows
    case items
    case roots
    case nodes
    case edges
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(String.self, forKey: .type)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    headers = try container.decodeIfPresent([String].self, forKey: .headers)
    rows = try? container.decode([Row].self, forKey: .rows)
    items = try? container.decode([Item].self, forKey: .items)
    // **`nodes` 键在 tree 那边是 `roots` 的别名**，而 flow 的节点也带 `title`，
    // 不按 `type` 分发就会**静默**解成一棵扁平树：`id` 被忽略、`children` 缺省为空，
    // 边全部悬空。先按 type 分发容器，再解码——tree 的两条别名路径逐字未动。
    if type.lowercased() == Self.flowType {
      roots = nil
      flowNodes = try? container.decode([FlowNode].self, forKey: .nodes)
      edges = try? container.decode([Edge].self, forKey: .edges)
    } else {
      roots =
        (try? container.decode([Node].self, forKey: .roots))
        ?? (try? container.decode([Node].self, forKey: .nodes))
      flowNodes = nil
      edges = nil
    }
  }
}

/// 归一化过程中的结构性诊断。**只记录类型名、字段名与条数**——不含字段值、
/// 转写正文、endpoint 或 provider 原始响应体。
struct VizDiagnostic {
  /// 清洁性丢弃的原因。都是刻意的净化策略,剩下的图没有撒谎。
  enum CleanReason: String {
    case citationColumn
    case blankHeader
    case blankRow
  }

  /// flow 走降级的原因。第一个命中的原因进 `flowDegraded`,供统计降级率。
  enum FlowDegradation: String {
    case nodeMissingFields
    case duplicateNodeID
    case edgeMissingFields
    case danglingEdge
    case nodesOverLimit
    case edgesOverLimit
  }

  enum Kind {
    case unknownType(String)
    case missingRequiredFields(type: String, fields: [String])
    case itemsDroppedByContract(type: String, kept: Int, dropped: Int)
    case emptyAfterNormalization(type: String)
    case foreignFieldsPresent(type: String, fields: [String])
    case itemsCleaned(type: String, reason: CleanReason, dropped: Int)
    case depthTruncated(type: String, dropped: Int)
    // flow 的六条(design §4.4 词表)。**全部非契约性**——理由见 isContractFailure。
    case flowDegraded(reason: FlowDegradation)
    case flowNodesOverLimit(count: Int)
    case flowEdgesOverLimit(count: Int)
    case flowDanglingEdge(edge: String)
    case flowDuplicateNodeID(id: String)
    case flowItemMissingFields(scope: String, fields: [String])

    /// 契约性 = 「丢弃会让剩下的图撒谎」。只有这一类拒收整图,让上游沿用上一版;
    /// 清洁性丢弃与结构上限截断一律保持现行为,否则模型带一列「来源」就会把
    /// 今天能干净渲染的表整张打回去。
    ///
    /// **flow 的六条全部归非契约性,这是 D2「安静退成三列边表」能成立的前提。**
    /// 归它们为契约性会让 `rejectedByContract` 为真,`LiveSummaryFeed.resolveViz`
    /// 与 `PostMeetingPipeline.normalizedSkeleton` 的守卫随即把那张已经造好的
    /// 边表丢掉、退回沿用上一版 —— 降级通道整条死掉,而边表本身一条边都没丢,
    /// 剩下的产物并没有撒谎。真正「什么都渲染不出来」的 flow(没有 edges、
    /// 一个节点 title 都解不出)照旧走 `missingRequiredFields` /
    /// `emptyAfterNormalization` 拒收,所以 `visualization == nil` 与
    /// `rejectedByContract` 同真同假这条不变式仍然成立。
    var isContractFailure: Bool {
      switch self {
      case .unknownType, .missingRequiredFields, .itemsDroppedByContract,
        .emptyAfterNormalization:
        return true
      case .foreignFieldsPresent, .itemsCleaned, .depthTruncated,
        .flowDegraded, .flowNodesOverLimit, .flowEdgesOverLimit,
        .flowDanglingEdge, .flowDuplicateNodeID, .flowItemMissingFields:
        return false
      }
    }
  }

  let kind: Kind

  /// 落日志用的结构化描述。刻意只拼闭合词汇 + 字段名 + 条数。
  var summary: String {
    switch kind {
    case .unknownType(let type):
      return "unknownType type=\(type)"
    case .missingRequiredFields(let type, let fields):
      return "missingRequiredFields type=\(type) fields=\(fields.joined(separator: ","))"
    case .itemsDroppedByContract(let type, let kept, let dropped):
      return "itemsDroppedByContract type=\(type) kept=\(kept) dropped=\(dropped)"
    case .emptyAfterNormalization(let type):
      return "emptyAfterNormalization type=\(type)"
    case .foreignFieldsPresent(let type, let fields):
      return "foreignFieldsPresent type=\(type) fields=\(fields.joined(separator: ","))"
    case .itemsCleaned(let type, let reason, let dropped):
      return "itemsCleaned type=\(type) reason=\(reason.rawValue) dropped=\(dropped)"
    case .depthTruncated(let type, let dropped):
      return "depthTruncated type=\(type) dropped=\(dropped)"
    case .flowDegraded(let reason):
      return "flowDegraded reason=\(reason.rawValue)"
    case .flowNodesOverLimit(let count):
      return "flowNodesOverLimit count=\(count)"
    case .flowEdgesOverLimit(let count):
      return "flowEdgesOverLimit count=\(count)"
    case .flowDanglingEdge(let edge):
      return "flowDanglingEdge edge=\(edge)"
    case .flowDuplicateNodeID(let id):
      return "flowDuplicateNodeId id=\(id)"
    case .flowItemMissingFields(let scope, let fields):
      return "flowItemMissingFields scope=\(scope) fields=\(fields.joined(separator: ","))"
    }
  }
}

/// 归一化结果。诊断跟着返回值走而不是注入日志回调:归一化被会中慢通道与
/// 会后骨架两条链路共用,返回值是唯一能让两边都拿到诊断、又不给纯函数
/// 带上生命周期的方式。
struct VizNormalization {
  let visualization: SummaryVisualization?
  let diagnostics: [VizDiagnostic]

  /// 上游据此决定「沿用上一版」还是「按新图渲染」。
  /// 不变式:`visualization == nil` 与 `rejectedByContract` 同真同假。
  var rejectedByContract: Bool {
    diagnostics.contains { $0.kind.isContractFailure }
  }

  fileprivate static func rejected(_ diagnostics: [VizDiagnostic]) -> VizNormalization {
    VizNormalization(visualization: nil, diagnostics: diagnostics)
  }
}

enum SummaryVisualizationNormalizer {
  /// `Item` 是六原语共用的宽松袋子,所以「这一型该填哪些字段」只能外挂校验。
  /// `anchor` / `evidence` 六型都消费,不进异类字段。
  private static let allItemFields = [
    "timeLabel", "title", "detail", "isPrerequisite",
    "value", "label", "context", "relationToNext",
    "owner", "interval",
  ]
  private static let allContainerFields = ["headers", "rows", "items", "roots"]

  static func make(_ wire: SummaryVisualizationWire) -> VizNormalization {
    switch wire.type.lowercased() {
    case "steps":
      return itemBased(
        wire,
        type: "steps",
        containers: ["items"],
        itemFields: ["title", "detail", "isPrerequisite"],
        build: { item -> SummaryStepItem? in
          guard
            let title = nonEmpty(item.title),
            let detail = nonEmpty(item.detail)
          else {
            return nil
          }
          return SummaryStepItem(
            title: title,
            detail: detail,
            isPrerequisite: item.isPrerequisite ?? false,
            anchor: anchor(item.anchor),
            evidence: evidence(item.evidence)
          )
        },
        wrap: { .steps(title: nonEmpty(wire.title) ?? "步骤", items: $0) }
      )

    case "table":
      return table(wire)

    case "timeline":
      return itemBased(
        wire,
        type: "timeline",
        containers: ["items"],
        // 必需字段仍只有 `timeLabel + title`:detail / owner / interval /
        // relationToNext 都是可选增益,缺席不是残图,不进必需判定——按必需判定
        // 会把今天的正常 timeline 全部拒收。
        itemFields: [
          "timeLabel", "title", "detail", "relationToNext", "owner", "interval",
        ],
        build: { item -> SummaryTimelineItem? in
          guard
            let timeLabel = nonEmpty(item.timeLabel),
            let title = nonEmpty(item.title)
          else {
            return nil
          }
          // `owner` 不做名册匹配、`interval` 不解析日期:逐字纪律由提示词兜,
          // 归一化不替模型改字。解析自由原文必然有失败率,解析失败时
          // 「8/12–8/16」被画成多长的条都是撒谎。
          return SummaryTimelineItem(
            timeLabel: timeLabel,
            title: title,
            detail: nonEmpty(item.detail),
            owner: nonEmpty(item.owner),
            interval: nonEmpty(item.interval),
            relationToNext: nonEmpty(item.relationToNext),
            anchor: anchor(item.anchor),
            evidence: evidence(item.evidence)
          )
        },
        wrap: { .timeline(title: nonEmpty(wire.title) ?? "时间线", items: $0) }
      )

    case "tree":
      return tree(wire)

    case "nums":
      return itemBased(
        wire,
        type: "nums",
        containers: ["items"],
        // `context ?? detail`:detail 是 nums 真正消费的回退字段,不算异类。
        itemFields: ["value", "label", "context", "detail"],
        build: { item -> SummaryNumberItem? in
          guard
            let value = nonEmpty(item.value),
            let label = nonEmpty(item.label)
          else {
            return nil
          }
          return SummaryNumberItem(
            value: value,
            label: label,
            context: nonEmpty(item.context ?? item.detail),
            anchor: anchor(item.anchor),
            evidence: evidence(item.evidence)
          )
        },
        wrap: { .nums(title: nonEmpty(wire.title) ?? "数字带", items: $0) }
      )

    case "chain":
      return itemBased(
        wire,
        type: "chain",
        containers: ["items"],
        // `relationToNext` 刻意不在必需列:链条的最后一个节点天然没有
        // 「到下一节点的关系」,按必需判定会让每一条合法 chain 都被拒收。
        itemFields: ["title", "detail", "relationToNext"],
        build: { item -> SummaryChainItem? in
          guard let title = nonEmpty(item.title) else {
            return nil
          }
          return SummaryChainItem(
            title: title,
            detail: nonEmpty(item.detail),
            relationToNext: nonEmpty(item.relationToNext),
            anchor: anchor(item.anchor),
            evidence: evidence(item.evidence)
          )
        },
        wrap: { .chain(title: nonEmpty(wire.title) ?? "链条", items: $0) }
      )

    case SummaryVisualizationWire.flowType:
      return flow(wire)

    default:
      return .rejected([.init(kind: .unknownType(clamped(wire.type)))])
    }
  }

  /// 诊断词汇里**不闭合、由模型任意填的串**只有两处:六型之外的 `type`,
  /// 以及 flow 的节点 id。两者都会被原样写进 `.public` 日志行,而 `sanitize`
  /// 只摘链接、不限长,所以这里再截一刀:模型把整句转写正文写进 `type` 或 `id` 时
  /// 不至于顺着诊断漏出去(R7)。
  private static func clamped(_ value: String) -> String {
    let cleaned = sanitize(value)
    guard cleaned.count > 24 else { return cleaned }
    return cleaned.prefix(24) + "…"
  }

  /// steps / timeline / nums / chain 的共同形状:一个 `items` 容器 + 逐条必需字段。
  /// 判定顺序:异类字段(只记录) → 容器缺失 → 逐条构造 → 契约性丢弃拒收整图。
  private static func itemBased<Element>(
    _ wire: SummaryVisualizationWire,
    type: String,
    containers: Set<String>,
    itemFields: Set<String>,
    build: (SummaryVisualizationWire.Item) -> Element?,
    wrap: ([Element]) -> SummaryVisualization
  ) -> VizNormalization {
    let items = wire.items ?? []
    var diagnostics = foreignDiagnostics(
      wire,
      type: type,
      containers: containers,
      itemFields: itemFields,
      items: items
    )
    // `items` 解码失败也落在这里:结构上同样是「这一型没有可用的 items」。
    guard !items.isEmpty else {
      diagnostics.append(
        .init(kind: .missingRequiredFields(type: type, fields: ["items"]))
      )
      return .rejected(diagnostics)
    }
    let built = items.compactMap(build)
    let dropped = items.count - built.count
    guard dropped == 0 else {
      // 5 条剩 1 条的时间线看上去仍是一条完整的时间线——残图以缺失撒谎。
      diagnostics.append(
        .init(
          kind: .itemsDroppedByContract(type: type, kept: built.count, dropped: dropped)
        )
      )
      return .rejected(diagnostics)
    }
    return VizNormalization(visualization: wrap(built), diagnostics: diagnostics)
  }

  private static func table(_ wire: SummaryVisualizationWire) -> VizNormalization {
    var diagnostics = foreignDiagnostics(
      wire,
      type: "table",
      containers: ["headers", "rows"],
      itemFields: [],
      items: []
    )
    guard let headers = wire.headers, !headers.isEmpty else {
      diagnostics.append(
        .init(kind: .missingRequiredFields(type: "table", fields: ["headers"]))
      )
      return .rejected(diagnostics)
    }
    // 提示词明令禁止「来源 / 出处 / 引用」列,但模型仍会写。剔除后表格完好,
    // 所以这是清洁性丢弃:只记诊断,不拒收整图。
    let citationColumns = headers.indices.filter {
      TextAssetSanitizer.isCitationHeader(headers[$0])
    }
    let blankColumns = headers.indices.filter {
      !TextAssetSanitizer.isCitationHeader(headers[$0]) && nonEmpty(headers[$0]) == nil
    }
    let keptColumns = headers.indices.filter {
      !citationColumns.contains($0) && !blankColumns.contains($0)
    }
    if !citationColumns.isEmpty {
      diagnostics.append(
        .init(
          kind: .itemsCleaned(
            type: "table",
            reason: .citationColumn,
            dropped: citationColumns.count
          )
        )
      )
    }
    if !blankColumns.isEmpty {
      diagnostics.append(
        .init(
          kind: .itemsCleaned(
            type: "table",
            reason: .blankHeader,
            dropped: blankColumns.count
          )
        )
      )
    }
    guard !keptColumns.isEmpty else {
      diagnostics.append(.init(kind: .emptyAfterNormalization(type: "table")))
      return .rejected(diagnostics)
    }
    let rawRows = wire.rows ?? []
    guard !rawRows.isEmpty else {
      diagnostics.append(
        .init(kind: .missingRequiredFields(type: "table", fields: ["rows"]))
      )
      return .rejected(diagnostics)
    }
    let rows = rawRows.compactMap { row -> SummaryTableRow? in
      let cells = keptColumns.map {
        SummaryRichText.plain(
          sanitize(row.cells.indices.contains($0) ? row.cells[$0] : "")
        )
      }
      guard cells.contains(where: { !$0.plainText.isEmpty }) else {
        return nil
      }
      return SummaryTableRow(
        cells: cells,
        anchor: anchor(row.anchor),
        evidence: evidence(row.evidence)
      )
    }
    let blankRows = rawRows.count - rows.count
    if blankRows > 0 {
      diagnostics.append(
        .init(kind: .itemsCleaned(type: "table", reason: .blankRow, dropped: blankRows))
      )
    }
    // A header-only/blank table is not a skeleton. Treat it as uncertainty so
    // the one-page view can fall back to reliable text points.
    guard !rows.isEmpty else {
      diagnostics.append(.init(kind: .emptyAfterNormalization(type: "table")))
      return .rejected(diagnostics)
    }
    return VizNormalization(
      visualization: .table(
        title: nonEmpty(wire.title) ?? "表格",
        table: SummaryTable(
          headers: keptColumns.map { sanitize(headers[$0]) },
          rows: rows
        )
      ),
      diagnostics: diagnostics
    )
  }

  private static func tree(_ wire: SummaryVisualizationWire) -> VizNormalization {
    var diagnostics = foreignDiagnostics(
      wire,
      type: "tree",
      containers: ["roots"],
      itemFields: [],
      items: []
    )
    let rawRoots = wire.roots ?? []
    guard !rawRoots.isEmpty else {
      diagnostics.append(
        .init(kind: .missingRequiredFields(type: "tree", fields: ["roots"]))
      )
      return .rejected(diagnostics)
    }
    var counters = TreeCounters()
    let roots = rawRoots.compactMap { treeNode($0, depth: 0, counters: &counters) }
    // 深度上限是我们自己施加的渲染约束,不是模型没满足契约:顶几层就是骨架,
    // 一棵好的三层树不该被第四层拖累而整体拒收。只记诊断。
    if counters.truncatedByDepth > 0 {
      diagnostics.append(
        .init(kind: .depthTruncated(type: "tree", dropped: counters.truncatedByDepth))
      )
    }
    guard counters.droppedByContract == 0 else {
      diagnostics.append(
        .init(
          kind: .itemsDroppedByContract(
            type: "tree",
            kept: counters.kept,
            dropped: counters.droppedByContract
          )
        )
      )
      return .rejected(diagnostics)
    }
    return VizNormalization(
      visualization: .tree(title: nonEmpty(wire.title) ?? "结构树", roots: roots),
      diagnostics: diagnostics
    )
  }

  /// flow 的密度上限(design §3)。超限**不截断**:丢掉 n9 之后 `n2→n9→n5`
  /// 这条路径在图上表现为 n2 没有后继 —— 那不是「少了点信息」,是连接关系被改写。
  /// 与 tree 的深度截断不同,flow 没有等价的安全截断面,所以整图降级成边表。
  static let flowMaxNodes = 8
  static let flowMaxEdges = 12

  /// flow 归一化。**降级判定就落在这一层**(design §4.4bis 的 Core 方案):
  /// 契约校验不过时直接产出标准 `.table` 三列边表,`flow` 这个 type 根本到不了 UI,
  /// 徽标自然显示 `table` —— 它此刻就是一张表(D2「安静降级,不加提示条」)。
  private static func flow(_ wire: SummaryVisualizationWire) -> VizNormalization {
    let type = SummaryVisualizationWire.flowType
    var diagnostics = foreignDiagnostics(
      wire,
      type: type,
      containers: [],
      itemFields: [],
      items: []
    )
    let title = nonEmpty(wire.title) ?? "关系图"
    let rawNodes = wire.flowNodes ?? []
    let rawEdges = wire.edges ?? []

    // 容器级缺失 = 契约性失败,拒收整图。没有边的 flow 不是 flow(design §1.2),
    // 而边表的单元格内容取自节点 title,没有 nodes 时表里只剩模型内部 id。
    var missingContainers: [String] = []
    if rawNodes.isEmpty { missingContainers.append("nodes") }
    if rawEdges.isEmpty { missingContainers.append("edges") }
    guard missingContainers.isEmpty else {
      diagnostics.append(
        .init(kind: .missingRequiredFields(type: type, fields: missingContainers))
      )
      return .rejected(diagnostics)
    }

    var degradation: VizDiagnostic.FlowDegradation?
    func degrade(
      _ kind: VizDiagnostic.Kind,
      _ reason: VizDiagnostic.FlowDegradation
    ) {
      diagnostics.append(.init(kind: kind))
      if degradation == nil { degradation = reason }
    }

    // 节点:载荷内唯一的非空 id + 非空 title。id 只做 trim 不做 sanitize ——
    // 判重与边引用命中必须比同一个串,sanitize 摘链接会让两侧比出不同结果。
    var titleByID: [String: String] = [:]
    var nodes: [SummaryFlowNode] = []
    for node in rawNodes {
      guard let id = trimmed(node.id), let nodeTitle = nonEmpty(node.title) else {
        degrade(
          .flowItemMissingFields(scope: "nodes", fields: ["id", "title"]),
          .nodeMissingFields
        )
        continue
      }
      guard titleByID[id] == nil else {
        degrade(.flowDuplicateNodeID(id: clamped(id)), .duplicateNodeID)
        continue
      }
      titleByID[id] = nodeTitle
      nodes.append(
        SummaryFlowNode(
          nodeID: id,
          title: nodeTitle,
          detail: nonEmpty(node.detail),
          anchor: anchor(node.anchor),
          evidence: evidence(node.evidence)
        )
      )
    }

    // 边:from/to 必须命中已登记的节点 id。悬空边不进图模型,但照样进边表(§4.3)。
    var edges: [SummaryFlowEdge] = []
    for edge in rawEdges {
      guard let from = trimmed(edge.from), let to = trimmed(edge.to) else {
        degrade(
          .flowItemMissingFields(scope: "edges", fields: ["from", "to"]),
          .edgeMissingFields
        )
        continue
      }
      guard titleByID[from] != nil, titleByID[to] != nil else {
        degrade(
          .flowDanglingEdge(edge: "\(clamped(from))->\(clamped(to))"),
          .danglingEdge
        )
        continue
      }
      edges.append(
        SummaryFlowEdge(
          from: from,
          to: to,
          label: nonEmpty(edge.label),
          feedbackMarked: edge.feedback ?? false
        )
      )
    }

    if rawNodes.count > flowMaxNodes {
      degrade(.flowNodesOverLimit(count: rawNodes.count), .nodesOverLimit)
    }
    if rawEdges.count > flowMaxEdges {
      degrade(.flowEdgesOverLimit(count: rawEdges.count), .edgesOverLimit)
    }

    guard let degradation else {
      return VizNormalization(
        visualization: .flow(title: title, nodes: nodes, edges: edges),
        diagnostics: diagnostics
      )
    }

    // 一个 title 都解析不出来时,边表里只剩模型内部 id —— 那不是「不丢字」,
    // 是「只剩没有意义的字」。与 table 全列被清空同型,按契约性失败拒收。
    guard !titleByID.isEmpty else {
      diagnostics.append(.init(kind: .emptyAfterNormalization(type: type)))
      return .rejected(diagnostics)
    }
    diagnostics.append(.init(kind: .flowDegraded(reason: degradation)))
    return VizNormalization(
      visualization: .table(
        title: title,
        table: flowEdgeTable(rawEdges: rawEdges, titleByID: titleByID)
      ),
      diagnostics: diagnostics
    )
  }

  /// 降级产物就是标准 `.table`(design §4.1):三列「从 / 关系 / 到」,每行一条边。
  ///
  /// 无 `label` 的边**关系列留空**:从 / 到两列的排列已经承载了方向,那个「→」
  /// 不携带任何信息,是纯装饰 —— 正落回 design-system「不用文本字符图标」想禁的那类。
  /// 悬空端显示**原始 id**,不静默丢行(§4.3):用户看到 `n9` 能知道模型产出了
  /// 一个引用错误,这比行数对不上更能支持排障。
  private static func flowEdgeTable(
    rawEdges: [SummaryVisualizationWire.Edge],
    titleByID: [String: String]
  ) -> SummaryTable {
    func cell(_ raw: String?) -> SummaryRichText {
      guard let id = trimmed(raw) else { return .plain("") }
      return .plain(titleByID[id] ?? sanitize(id))
    }
    return SummaryTable(
      headers: ["从", "关系", "到"],
      rows: rawEdges.map { edge in
        SummaryTableRow(
          cells: [cell(edge.from), .plain(nonEmpty(edge.label) ?? ""), cell(edge.to)]
        )
      }
    )
  }

  /// 异类字段只记录、不参与拒收:多余字段不会让图撒谎,但它是「模型把 nums
  /// 填成表格」这类跨类型混用的唯一线索。
  private static func foreignDiagnostics(
    _ wire: SummaryVisualizationWire,
    type: String,
    containers: Set<String>,
    itemFields: Set<String>,
    items: [SummaryVisualizationWire.Item]
  ) -> [VizDiagnostic] {
    let presentContainers = presentContainerFields(wire)
    var foreign: [String] = allContainerFields.filter {
      !containers.contains($0) && presentContainers.contains($0)
    }
    if !items.isEmpty {
      let present = presentItemFields(items)
      foreign += allItemFields.filter {
        !itemFields.contains($0) && present.contains($0)
      }
    }
    guard !foreign.isEmpty else { return [] }
    return [.init(kind: .foreignFieldsPresent(type: type, fields: foreign))]
  }

  private static func presentContainerFields(
    _ wire: SummaryVisualizationWire
  ) -> Set<String> {
    var present: Set<String> = []
    if wire.headers != nil { present.insert("headers") }
    if wire.rows != nil { present.insert("rows") }
    if wire.items != nil { present.insert("items") }
    if wire.roots != nil { present.insert("roots") }
    return present
  }

  private static func presentItemFields(
    _ items: [SummaryVisualizationWire.Item]
  ) -> Set<String> {
    var present: Set<String> = []
    for item in items {
      if item.timeLabel != nil { present.insert("timeLabel") }
      if item.title != nil { present.insert("title") }
      if item.detail != nil { present.insert("detail") }
      if item.isPrerequisite != nil { present.insert("isPrerequisite") }
      if item.value != nil { present.insert("value") }
      if item.label != nil { present.insert("label") }
      if item.context != nil { present.insert("context") }
      if item.relationToNext != nil { present.insert("relationToNext") }
      if item.owner != nil { present.insert("owner") }
      if item.interval != nil { present.insert("interval") }
    }
    return present
  }

  private struct TreeCounters {
    var kept = 0
    var droppedByContract = 0
    var truncatedByDepth = 0
  }

  private static func treeNode(
    _ wire: SummaryVisualizationWire.Node,
    depth: Int,
    counters: inout TreeCounters
  ) -> SummaryTreeNode? {
    guard depth < 4 else {
      counters.truncatedByDepth += 1
      return nil
    }
    guard let title = nonEmpty(wire.title) else {
      counters.droppedByContract += 1
      return nil
    }
    counters.kept += 1
    return SummaryTreeNode(
      title: title,
      detail: nonEmpty(wire.detail),
      children: wire.children.compactMap {
        treeNode($0, depth: depth + 1, counters: &counters)
      },
      anchor: anchor(wire.anchor),
      evidence: evidence(wire.evidence)
    )
  }

  private static func sanitize(_ value: String) -> String {
    TextAssetSanitizer.sanitize(value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = sanitize(value)
    return cleaned.isEmpty ? nil : cleaned
  }

  /// 只去首尾空白、**不** sanitize。给 flow 的节点 id 用:判重与边引用命中必须
  /// 比同一个串,而 `sanitize` 会摘链接,两侧摘出来的结果可能不一样。
  private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
  }

  private static func anchor(_ value: String?) -> TranscriptAnchor? {
    guard let timecode = nonEmpty(value) else { return nil }
    let anchor = TranscriptAnchor(timecode: timecode)
    return anchor.seconds == nil ? nil : anchor
  }

  private static func evidence(_ value: String?) -> SummaryEvidenceMark? {
    switch value?.lowercased() {
    case "confirmed":
      return .confirmed
    case "toverify", "to_verify", "to-verify":
      return .toVerify
    case "corrected":
      return .corrected
    default:
      return nil
    }
  }
}

/// 验证入口(先例:`SummaryMarkdownRenderer.visualizationLines`)。
///
/// `SummaryVisualizationWire` 与 `SummaryVisualizationNormalizer` 都是 internal,
/// 走查夹具够不到。没有这个口子,夹具就只能自己抄一份平行的解码 + 校验 ——
/// 抄出来的那份绿了也不说明生产是绿的。这里只暴露「一份 wire JSON 进、
/// 归一化结果 + 诊断串出」,不放开内部类型。
public enum SummaryVisualizationProbe {
  public struct Outcome {
    public let visualization: SummaryVisualization?
    public let diagnostics: [String]
    public let rejectedByContract: Bool
  }

  public static func normalize(wireJSON: Data) throws -> Outcome {
    let wire = try JSONDecoder().decode(SummaryVisualizationWire.self, from: wireJSON)
    let normalization = SummaryVisualizationNormalizer.make(wire)
    return Outcome(
      visualization: normalization.visualization,
      diagnostics: normalization.diagnostics.map(\.summary),
      rejectedByContract: normalization.rejectedByContract
    )
  }
}
