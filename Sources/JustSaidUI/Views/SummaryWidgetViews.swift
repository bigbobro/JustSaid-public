import AppKit
import JustSaidCore
import SwiftUI

/// E3 三类可视化部件的容器外壳（`.wg`/`.wgh`/`.wgb`）：标题 + 类型徽标 + 内容。
struct SummaryWidgetContainer<Content: View>: View {
  let title: String
  let badge: String
  @ViewBuilder let content: () -> Content
  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      HStack(spacing: Tokens.Spacing.xs) {
        Text(title)
          .font(.system(size: textScale.size(Tokens.FontSize.secondary), weight: .semibold))
          .foregroundStyle(Tokens.Color.ink2)
        Text(badge)
          .font(.system(size: Tokens.FontSize.glyphSmall, design: .monospaced))
          .foregroundStyle(Tokens.Color.ink4)
          .padding(.horizontal, Tokens.Spacing.xxs)
          .background(Tokens.Color.card)
          .overlay(RoundedRectangle(cornerRadius: 3).stroke(Tokens.Color.line, lineWidth: 1))
      }
      content()
    }
    .padding(.horizontal, Tokens.Spacing.sm)
    .padding(.vertical, Tokens.Spacing.xsm)
    // 部件外壳一律铺满所在列:tree/少列 table/flow 降级边表这类**纵向内容**没有
    // 自带 `maxWidth: .infinity` 的横排条目,不钉这一句就缩成内容宽,同一张话题卡里
    // 与 timeline/nums/chain 的右缘对不齐(2026-08-21 走查 P-3,实拍 tree 只有邻卡的三成宽)。
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tokens.Color.cardWash)
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.widget).stroke(Tokens.Color.line, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.widget))
  }
}

/// steps 部件：横排流程箱 + 细线尖角连接（ui-spec §3.8：不用字符“→”）。
struct StepsWidgetView: View {
  let title: String
  let items: [SummaryStepItem]
  var onJumpToTranscript: ((TimeInterval) -> Void)?

  var body: some View {
    SummaryWidgetContainer(title: title, badge: "steps") {
      if items.count <= 4 {
        // 少量步骤先把卡片等分到所在列；最小详情宽度仍放不下时改为纵向堆叠，
        // 确保窄窗完整展示正文而不是裁切或强迫用户横向寻找下一张卡。
        ViewThatFits(in: .horizontal) {
          stepsTrack(expandsToFit: true)
          verticalStepsTrack
        }
      } else {
        HorizontalOverflowViewport(identifier: "summary.widget.steps.overflow") {
          stepsTrack(expandsToFit: false)
        }
      }
    }
  }

  @ViewBuilder
  private func stepsTrack(expandsToFit: Bool) -> some View {
    if expandsToFit {
      StepsHorizontalLayout(itemCount: items.count) {
        stepsTrackContent(expandsToFit: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      HStack(alignment: .top, spacing: 0) {
        stepsTrackContent(expandsToFit: false)
      }
    }
  }

  @ViewBuilder
  private func stepsTrackContent(expandsToFit: Bool) -> some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      if index > 0 {
        StepConnector()
      }
      StepBox(
        item: item,
        expandsToFit: expandsToFit,
        onJumpToTranscript: onJumpToTranscript
      )
    }
  }

  private var verticalStepsTrack: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          StepConnector(vertical: true)
        }
        StepBox(
          item: item,
          expandsToFit: true,
          onJumpToTranscript: onJumpToTranscript
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 宽度自适应的横向 steps 轨道。`ViewThatFits` 需要一个有确定最小宽度的
/// 首选项，普通 HStack 的无限宽 frame 会被误判为永远不适配；这个 Layout
/// 在有限提案下直接把卡片分配到可用宽度，只有小于最小卡宽时才让外层选择纵向形态。
private struct StepsHorizontalLayout: Layout {
  private let itemCount: Int
  private let minimumCardWidth: CGFloat = 112
  private let connectorWidth: CGFloat = 17

  init(itemCount: Int) {
    self.itemCount = itemCount
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let layout = metrics(proposedWidth: proposal.width, subviews: subviews)
    return layout.size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let layout = metrics(proposedWidth: bounds.width, subviews: subviews)
    var x = bounds.minX
    for (index, subview) in subviews.enumerated() {
      let width = index.isMultiple(of: 2) ? layout.cardWidth : connectorWidth
      let childSize = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      subview.place(
        at: CGPoint(
          x: x,
          y: bounds.minY + max(0, (bounds.height - childSize.height) / 2)
        ),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: width, height: nil)
      )
      x += width
    }
  }

  private func metrics(
    proposedWidth: CGFloat?,
    subviews: Subviews
  ) -> (size: CGSize, cardWidth: CGFloat) {
    let count = max(0, itemCount)
    guard count > 0 else { return (CGSize.zero, 0) }
    let connectorCount = max(0, count - 1)
    let minimumWidth =
      CGFloat(count) * minimumCardWidth
      + CGFloat(connectorCount) * connectorWidth
    let availableWidth = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? minimumWidth
    let totalWidth = max(minimumWidth, availableWidth)
    let cardWidth = (totalWidth - CGFloat(connectorCount) * connectorWidth) / CGFloat(count)

    var height: CGFloat = 0
    for (index, subview) in subviews.enumerated() {
      let width = index.isMultiple(of: 2) ? cardWidth : connectorWidth
      height = max(
        height,
        subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
      )
    }
    return (CGSize(width: totalWidth, height: height), cardWidth)
  }
}

private struct StepBox: View {
  let item: SummaryStepItem
  let expandsToFit: Bool
  let onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  var body: some View {
    Group {
      if expandsToFit {
        cardContent
          .frame(minWidth: 112, maxWidth: .infinity, alignment: .leading)
      } else {
        // 溢出轨道内使用确定宽度，正文才会在卡片内部换行，而不是按理想宽度测量后被截断。
        cardContent
          .frame(width: 180, alignment: .leading)
      }
    }
    .background(
      item.isPrerequisite ? Tokens.Color.amber : Tokens.Color.card
    )
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.control)
        .stroke(item.isPrerequisite ? Tokens.Color.amberLine : Tokens.Color.line, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      item.isPrerequisite ? "前置条件：\(item.title)，\(item.detail)" : "\(item.title)，\(item.detail)")
  }

  private var cardContent: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      HStack(alignment: .top, spacing: Tokens.Spacing.xxs) {
        Text(item.title)
          .font(.system(size: textScale.size(Tokens.FontSize.secondary), weight: .semibold))
          .foregroundStyle(Tokens.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(1)
        EvidenceBadge(mark: item.evidence)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(item.detail)
        .font(.system(size: textScale.size(Tokens.FontSize.caption)))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .runtimeAccessibilityIdentifier("summary.widget.steps.body.\(item.id.uuidString)")
      TranscriptAnchorButton(anchor: item.anchor, onJump: onJumpToTranscript)
    }
    .padding(.horizontal, Tokens.Spacing.xsm)
    .padding(.vertical, Tokens.Spacing.xs)
  }
}

/// 细线 + 尖角连接件，替代字符“→”（ui-spec §3.8）。
private struct StepConnector: View {
  let vertical: Bool

  init(vertical: Bool = false) {
    self.vertical = vertical
  }

  var body: some View {
    Group {
      if vertical {
        VStack(spacing: 0) {
          Rectangle()
            .fill(Tokens.Color.ink4)
            .frame(width: 1, height: 9)
          Chevron()
            .stroke(
              Tokens.Color.ink4,
              style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )
            .rotationEffect(.degrees(90))
            .frame(width: 4, height: 4)
        }
        .frame(width: 4, height: 17)
      } else {
        HStack(spacing: 0) {
          Rectangle()
            .fill(Tokens.Color.ink4)
            .frame(width: 9, height: 1)
          Chevron()
            .stroke(
              Tokens.Color.ink4,
              style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 4, height: 4)
        }
        .frame(width: 17)
      }
    }
    .accessibilityHidden(true)
  }
}

private struct Chevron: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: rect.width, y: rect.height / 2))
    path.addLine(to: CGPoint(x: 0, y: rect.height))
    return path
  }
}

/// table 部件：等宽数字沿用调用方字体设置，表头/斑马线遵循 tokens。
struct TableWidgetView: View {
  let title: String
  let table: SummaryTable
  var onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  var body: some View {
    SummaryWidgetContainer(title: title, badge: "table") {
      Grid(alignment: .leading, horizontalSpacing: 7, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
            Text(header)
              .font(.system(size: textScale.size(Tokens.FontSize.caption), weight: .semibold))
              .foregroundStyle(Tokens.Color.ink3)
              .padding(.vertical, Tokens.Spacing.xxs)
          }
        }
        Divider().gridCellColumns(max(table.headers.count, 1))
        ForEach(table.rows) { row in
          GridRow {
            ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
              VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
                RichText(cell)
                  .font(.system(size: textScale.size(Tokens.FontSize.ui)))
                  .foregroundStyle(Tokens.Color.ink2)
                  .runtimeAccessibilityIdentifier(
                    "summary.widget.table.body.\(row.id.uuidString).\(index)"
                  )
                if index == row.cells.count - 1 {
                  HStack(spacing: Tokens.Spacing.xxs) {
                    EvidenceBadge(mark: row.evidence)
                    TranscriptAnchorButton(anchor: row.anchor, onJump: onJumpToTranscript)
                  }
                }
              }
              .padding(.vertical, Tokens.Spacing.xxs)
            }
          }
          Divider().gridCellColumns(max(table.headers.count, 1))
        }
      }
    }
  }
}

/// timeline 部件：部件级里程碑时间线（与历史区自身的时间线是两回事）。
/// ui-final-v2.html 未给出该类型的像素示例，样式按既有 token 语言（细轴 + 节点）延伸；
/// 详见实施报告“待设计确认”。
struct TimelineWidgetView: View {
  let title: String
  let items: [SummaryTimelineItem]
  var onJumpToTranscript: ((TimeInterval) -> Void)?

  /// 单行直接铺排的里程碑数上限（SHA-55）。超过就套横向滚动（与 steps/chain
  /// 同款），列与脊线按内容理想宽度排布，不再被均分压扁。≤4 保持既有单行
  /// 弹性脊线形态——裸列无宽度约束、脊线弹性拉伸都是旧数据像素的一部分。
  private static let singleRowLimit = 4

  var body: some View {
    SummaryWidgetContainer(title: title, badge: "timeline") {
      if items.count <= Self.singleRowLimit {
        milestoneTrack
      } else {
        HorizontalOverflowViewport(identifier: "summary.widget.timeline.overflow") {
          milestoneTrack
        }
      }
    }
  }

  private var milestoneTrack: some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          // 关系文字标在脊线段**下方**：标在上方会把脊线压离两侧圆心。
          TimelineSpineSegment(
            label: items[index - 1].relationToNext,
            identifier: "summary.widget.timeline.relation.\(items[index - 1].id.uuidString)"
          )
        }
        TimelineColumn(item: item, onJumpToTranscript: onJumpToTranscript)
      }
    }
  }
}

/// 两个条目之间的脊线段。无 `relationToNext` 时只有裸线，与加深前完全一致。
private struct TimelineSpineSegment: View {
  let label: String?
  let identifier: String
  @Environment(\.textScale) private var textScale

  private var spine: some View {
    Rectangle()
      .fill(Tokens.Color.acLine)
      .frame(height: 1.5)
      .padding(.top, Tokens.Spacing.xxs)
  }

  var body: some View {
    if let label {
      VStack(spacing: Tokens.Spacing.hairline) {
        spine
        Text(label)
          .font(.system(size: textScale.size(Tokens.FontSize.glyphSmall)))
          .foregroundStyle(Tokens.Color.ink4)
          .frame(maxWidth: 96)
          .fixedSize(horizontal: false, vertical: true)
          .help(label)
          .runtimeAccessibilityIdentifier(identifier)
      }
    } else {
      spine
    }
  }
}

/// 单个里程碑列。加深字段全部条件渲染：缺席就是没有这一行，不留空位、不占位符。
private struct TimelineColumn: View {
  let item: SummaryTimelineItem
  let onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  /// 宽度约束**只对加深列生效**。无条件加 maxWidth 会改变旧数据的换行点，
  /// 让只有 timeLabel + title 的历史会议时间线整张变形。
  private var isDeepened: Bool {
    item.detail != nil || item.owner != nil || item.interval != nil
  }

  var body: some View {
    if isDeepened {
      column.frame(width: 180, alignment: .leading)
    } else {
      column
    }
  }

  private var column: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      // 区间条目把圆点换成同色同高的固定宽胶囊。宽度不与区间长短挂钩：
      // timeLabel/interval 是逐字原文（「Q3 内」这类），解析失败时条画多长都是撒谎。
      if item.interval != nil {
        RoundedRectangle(cornerRadius: 4)
          .fill(Tokens.Color.ac)
          .frame(width: 22, height: 8)
      } else {
        Circle()
          .fill(Tokens.Color.ac)
          .frame(width: 8, height: 8)
      }
      // 等宽槽位与 timeLabel 同规格（9.5 等宽、不走 textScale）：
      // 等宽数字是定位信息不是正文。两者都给时 interval 在上、timeLabel 在下。
      if let interval = item.interval {
        Text(interval)
          .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
          .foregroundStyle(Tokens.Color.ink4)
          // 定位信息也必须完整可见；列宽不足时在列内换行，不用尾部省略号隐藏原文。
          .fixedSize(horizontal: false, vertical: true)
          .help(interval)
          .runtimeAccessibilityIdentifier(
            "summary.widget.timeline.interval.\(item.id.uuidString)"
          )
      }
      Text(item.timeLabel)
        .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink4)
        .fixedSize(horizontal: false, vertical: true)
        .help(item.timeLabel)
      Text(item.title)
        .font(.system(size: textScale.size(Tokens.FontSize.secondary), weight: .medium))
        .foregroundStyle(Tokens.Color.ink)
        .fixedSize(horizontal: false, vertical: true)
        .runtimeAccessibilityIdentifier(
          "summary.widget.timeline.body.\(item.id.uuidString)"
        )
      // owner 独占一行、不并入 detail：结构化字段要在屏幕上留下自己的证据。
      // 也不做徽章——EvidenceBadge 的词汇是核验状态，owner 不是核验状态。
      if let owner = item.owner {
        HStack(spacing: Tokens.Spacing.xxs) {
          Image(systemName: "person")
            .font(.system(size: Tokens.FontSize.glyphSmall))
            .foregroundStyle(Tokens.Color.ink2)
          Text(owner)
            .font(.system(size: textScale.size(Tokens.FontSize.caption), weight: .medium))
            .foregroundStyle(Tokens.Color.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .help(owner)
        }
        .runtimeAccessibilityIdentifier(
          "summary.widget.timeline.owner.\(item.id.uuidString)"
        )
      }
      if let detail = item.detail {
        // 详情在列内完整换行；sidecar 是持久化来源，不是隐藏 UI 正文的理由。
        Text(detail)
          .font(.system(size: textScale.size(Tokens.FontSize.caption)))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .help(detail)
          .runtimeAccessibilityIdentifier(
            "summary.widget.timeline.detail.\(item.id.uuidString)"
          )
      }
      HStack(spacing: Tokens.Spacing.xxs) {
        EvidenceBadge(mark: item.evidence)
        TranscriptAnchorButton(anchor: item.anchor, onJump: onJumpToTranscript)
      }
      // 徽章与锚点 chip 都是小尺寸定长件(合计约 90pt < 180 上限),按内在宽度画。
      // 不钉这一句时窄列会把「[待核]」拆成两行、把「01:02」拆成五行(走查 P-1)。
      .fixedSize()
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// tree 原语：递归层级只负责结构，不把树退化成缩进 Markdown。
struct TreeWidgetView: View {
  let title: String
  let roots: [SummaryTreeNode]
  var onJumpToTranscript: ((TimeInterval) -> Void)?

  var body: some View {
    SummaryWidgetContainer(title: title, badge: "tree") {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
        ForEach(roots) { node in
          TreeNodeView(
            node: node,
            depth: 0,
            onJumpToTranscript: onJumpToTranscript
          )
        }
      }
    }
  }
}

private struct TreeNodeView: View {
  let node: SummaryTreeNode
  let depth: Int
  let onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(depth == 0 ? Tokens.Color.ac : Tokens.Color.acLine)
          .frame(width: 5, height: 5)
          .padding(.top, Tokens.Spacing.xxs)
        VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
          HStack(spacing: Tokens.Spacing.xxs) {
            Text(node.title)
              .font(
                .system(
                  size: textScale.size(Tokens.FontSize.secondary),
                  weight: depth == 0 ? .semibold : .medium)
              )
              .foregroundStyle(Tokens.Color.ink)
            EvidenceBadge(mark: node.evidence)
            TranscriptAnchorButton(anchor: node.anchor, onJump: onJumpToTranscript)
          }
          if let detail = node.detail, !detail.isEmpty {
            Text(detail)
              .font(.system(size: textScale.size(Tokens.FontSize.caption)))
              .foregroundStyle(Tokens.Color.ink3)
              .runtimeAccessibilityIdentifier("summary.widget.tree.body.\(node.id.uuidString)")
          }
        }
      }
      if !node.children.isEmpty {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
          ForEach(node.children) { child in
            TreeNodeView(
              node: child,
              depth: depth + 1,
              onJumpToTranscript: onJumpToTranscript
            )
          }
        }
        .padding(.leading, Tokens.Spacing.md)
        .overlay(alignment: .leading) {
          Rectangle().fill(Tokens.Color.line).frame(width: 1)
        }
      }
    }
  }
}

/// nums 原语：数字仍是字符串，并与语境、核验状态和原话锚点长在同一张卡里。
struct NumbersWidgetView: View {
  let title: String
  let items: [SummaryNumberItem]
  var onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  /// 单行均分的条目数上限（SHA-55）。超过就换成自适应网格换行，卡片保最低
  /// 可读宽度，不再被均分压成逐字竖条。≤4 保持既有单行均分形态，
  /// 历史会议像素不变。
  private static let singleRowLimit = 4
  /// 换行网格里每张卡的最小可读宽度（与 steps/chain 卡片 112–180 同一词汇，
  /// 取距档位管的是 padding/spacing，卡片几何沿用本文件的既有字面量先例）。
  private static let cardMinimumWidth: CGFloat = 120

  var body: some View {
    SummaryWidgetContainer(title: title, badge: "nums") {
      if items.count <= Self.singleRowLimit {
        HStack(alignment: .top, spacing: Tokens.Spacing.xsm) {
          ForEach(items) { item in
            card(item)
          }
        }
      } else {
        LazyVGrid(
          columns: [
            GridItem(
              .adaptive(minimum: Self.cardMinimumWidth),
              spacing: Tokens.Spacing.xsm,
              alignment: .top
            )
          ],
          spacing: Tokens.Spacing.xsm
        ) {
          ForEach(items) { item in
            card(item)
          }
        }
      }
    }
  }

  private func card(_ item: SummaryNumberItem) -> some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      HStack(spacing: Tokens.Spacing.xxs) {
        Text(item.value)
          .font(
            .system(
              size: textScale.size(Tokens.FontSize.displaySmall), weight: .bold, design: .rounded)
          )
          .foregroundStyle(Tokens.Color.ink)
          .runtimeAccessibilityIdentifier("summary.widget.nums.body.\(item.id.uuidString)")
        EvidenceBadge(mark: item.evidence)
      }
      Text(item.label)
        .font(.system(size: textScale.size(Tokens.FontSize.secondary), weight: .semibold))
        .foregroundStyle(Tokens.Color.ink2)
      if let context = item.context, !context.isEmpty {
        Text(context)
          .font(.system(size: textScale.size(Tokens.FontSize.badge)))
          .foregroundStyle(Tokens.Color.ink3)
      }
      TranscriptAnchorButton(anchor: item.anchor, onJump: onJumpToTranscript)
    }
    // maxHeight 让同一网格行里带 context 的卡与不带的等高:只给 maxWidth 时
    // 20 张卡的网格每行底缘参差约 14pt(走查 P-4,骨架溢出页实拍)。
    // ≤4 条的单行分支走的是同一个 card(),单行内本来就等高,逐像素不变。
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .padding(Tokens.Spacing.xsm)
    .background(Tokens.Color.card)
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(Tokens.Color.line, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
  }
}

/// chain 原语：节点与关系分开呈现，适合“痛点 → 方案 → 价值”这类因果链。
struct ChainWidgetView: View {
  let title: String
  let items: [SummaryChainItem]
  var onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  var body: some View {
    SummaryWidgetContainer(title: title, badge: "chain") {
      HorizontalOverflowViewport(identifier: "summary.widget.chain.overflow") {
        HStack(alignment: .center, spacing: Tokens.Spacing.xs) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
              HStack(spacing: Tokens.Spacing.xxs) {
                Text(item.title)
                  .font(.system(size: textScale.size(Tokens.FontSize.secondary), weight: .semibold))
                  .foregroundStyle(Tokens.Color.ink)
                  .fixedSize(horizontal: false, vertical: true)
                  .layoutPriority(1)
                EvidenceBadge(mark: item.evidence)
              }
              if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                  .font(.system(size: textScale.size(Tokens.FontSize.caption)))
                  .foregroundStyle(Tokens.Color.ink3)
                  .fixedSize(horizontal: false, vertical: true)
                  .runtimeAccessibilityIdentifier(
                    "summary.widget.chain.body.\(item.id.uuidString)"
                  )
              }
              TranscriptAnchorButton(anchor: item.anchor, onJump: onJumpToTranscript)
            }
            .padding(Tokens.Spacing.xsm)
            .frame(width: 180, alignment: .leading)
            .background(Tokens.Color.card)
            .overlay(
              RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(
                Tokens.Color.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))

            if index < items.count - 1 {
              VStack(spacing: Tokens.Spacing.hairline) {
                Text(item.relationToNext ?? "")
                  .font(.system(size: textScale.size(Tokens.FontSize.glyphSmall)))
                  .foregroundStyle(Tokens.Color.ink4)
                  .frame(maxWidth: 96)
                  .fixedSize(horizontal: false, vertical: true)
                  .help(item.relationToNext ?? "")
                  .runtimeAccessibilityIdentifier(
                    "summary.widget.chain.relation.\(item.id.uuidString)"
                  )
                StepConnector()
              }
            }
          }
        }
      }
    }
  }
}

// MARK: - flow 原语（第七种）

/// flow 的几何常量。**这些是布局算法的参数，不是取距 token** —— 把它们塞进
/// `Tokens.Spacing` 会改动几何，进而让 ② 建起来的落点/沟高断言整体漂掉。
///
/// 沟内槽位（08-12-flow-label-routing）把「层间沟里已经占了什么」从画笔里提出来
/// 变成可登记的槽位，这些常量就是槽位的尺寸。
public enum FlowMetrics {
  /// 同一源盒扇出多条边时，水平段在沟里最多分几条槽（lane）。
  /// 出度 ≥3 时第 3 条起共用最后一条 lane —— 已知限制，现有夹具最大出度是 2。
  public static let maxLanes = 2
  /// 同源出边落到目标盒顶边的左右错开步长（design §2.4「扇形分开」）。
  public static let fanOutStep: CGFloat = 8
  /// 同一目标盒上两个落点的最小间距。见 `FlowLayouter.spreadLandings`。
  public static let minLandingGap: CGFloat = 10
  /// 层间沟的下限（design §2.5 的 xxl 24）。
  public static let minGutter: CGFloat = 24
  /// 左通道宽（design §2.5：每条反馈边一条通道）。
  public static let channelWidth: CGFloat = 14
  public static let gutterTopPad: CGFloat = 5
  public static let gutterBottomPad: CGFloat = 3
  public static let labelFontSize: CGFloat = 8.5
  /// 标签与自己那条水平段之间、标签与下一条 lane 之间的呼吸。
  public static let labelLead: CGFloat = 2
  public static let labelTail: CGFloat = 2
  /// 不带标签的 lane 只要放得下线本身。
  public static let bareLaneHeight: CGFloat = 9
  /// 避让余量：标签之间、标签与线、标签与盒各留多少。
  public static let labelClearance: CGFloat = 2
  public static let strokeClearance: CGFloat = 1.5
  public static let boxClearance: CGFloat = 1

  /// 标签行高。实测 8.5pt 系统字的 `ascender - descender` = 10.01，取整到 11
  /// 留 1pt 余量；140% 档 11.9pt 同法得 15，所以沟高随 textScale 一起长。
  public static func labelHeight(_ scaledSize: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: scaledSize)
    return ceil(font.ascender - font.descender + font.leading)
  }

  /// 一条要放标签的 lane = 线(1) + 呼吸 + 标签行 + 呼吸。
  public static func labeledLaneHeight(_ scaledSize: CGFloat) -> CGFloat {
    1 + labelLead + labelHeight(scaledSize) + labelTail
  }
}

/// 一条层间沟的槽位登记：每条 lane 有没有被占、要不要放标签。
///
/// **沟高由此推出。** 24pt 装不下两条都要放标签的 lane：一条 lane 是线 1 +
/// 标签约 11 + 上下呼吸 4 ≈ 16，两条要 5+16+16+3 = 40。硬塞进 24pt 时标签只能
/// 一条朝下一条朝上互相穿插，于是必然出现「A 的标签压在 B 的线上」。
/// 层内左右次序、层号一律不动 —— 这里长的是层与层之间的呼吸，不是交叉优化。
public struct FlowGutterSlots: Sendable {
  public var laneUsed: [Bool]
  public var laneLabeled: [Bool]

  public static let empty = FlowGutterSlots(
    laneUsed: Array(repeating: false, count: FlowMetrics.maxLanes),
    laneLabeled: Array(repeating: false, count: FlowMetrics.maxLanes))
}

public struct FlowLayoutPlan {
  /// 每层一组节点 id，层内按 nodes 数组声明序；不做 barycenter 交叉优化。
  public let layers: [[String]]
  /// 节点 → 层号。
  public let layerOfNode: [String: Int]
  /// 按反向边渲染的边下标（虚线 + 左通道），几何判定与模型标记无关。
  public let backwardEdges: Set<Int>
  /// 每条反向边一条左通道，通道序号 = 边在 edges 声明序中的相对次序。
  public let channelOf: [Int: Int]
  public let channelCount: Int
  /// 前向边 → 它在层间沟里占的 lane（同源出边按声明序分槽）。
  public let laneOfEdge: [Int: Int]
  /// 前向边 → 落到目标盒顶边的 x 偏移（相对 `target.midX`）。
  public let landingOffsetOfEdge: [Int: CGFloat]
  /// 每条层间沟的槽位登记，索引 = 上层层号。
  public let gutters: [FlowGutterSlots]
  /// 标记与几何不一致的诊断（只记录，画面按几何走）。
  ///
  /// **这条诊断只活在 UI**：它是分层完成后才判得出来的几何事实，Core 的归一化
  /// 层没有层号。所以它**不进** `LiveSummaryFeed` / `PostMeetingPipeline` 那两条
  /// 日志链路 —— ① 明确否决了往纯函数里注入回调，这里也不新开一条 UI→Core 的回传路。
  public let diagnostics: [String]
}

/// flow 的分层布局。纯几何，不碰数据：输入是已经通过 Core 契约校验的节点与边。
public enum FlowLayouter {
  public static func plan(
    nodes: [SummaryFlowNode],
    edges: [SummaryFlowEdge]
  ) -> FlowLayoutPlan {
    // 1. 模型标了 feedback 的边先移出分层图（design §2.2 步骤 1）。
    var removed = Set(edges.indices.filter { edges[$0].feedbackMarked })
    // 2. 渲染是全函数：模型标漏的环在这里自己抓。每轮找一个环，移除环上
    //    「声明序最靠后的 source」那条边，继续，直到分层用图是 DAG。
    //    **不能只删 DFS 撞见的回边**：naive 规则会把正向边误判成回边（F5b 实测：
    //    DFS 先经移动端摸到分析平台，Web→分析就成了「回边」），6 节点被拉成 6 层、
    //    依赖方向视觉颠倒。环里至少有一条声明序下降的边（下标绕环不可能单调递增），
    //    删它确定、终止、保叙述序。
    //    **规则的正式契约在 `.trellis/spec/ui/design-system.md`「flow 剪圈规则」**；
    //    判别性夹具是 `Verification/UIScreenshots/FlowFixtures.swift` 的 F5b。
    while let cycleEdge = findCycleRemovalCandidate(nodes: nodes, edges: edges, removed: removed) {
      removed.insert(cycleEdge)
    }
    // 3. 最长路径分层：层号 = 到任一源点的最长路径长度。
    var incoming: [String: [String]] = [:]
    for (index, edge) in edges.enumerated() where !removed.contains(index) {
      incoming[edge.to, default: []].append(edge.from)
    }
    var memo: [String: Int] = [:]
    func layer(of id: String) -> Int {
      if let cached = memo[id] { return cached }
      // 图已是 DAG，递归必然终止；孤立节点（无入边）落在第 0 层。
      let value = (incoming[id] ?? []).map { layer(of: $0) + 1 }.max() ?? 0
      memo[id] = value
      return value
    }
    var layerOf: [String: Int] = [:]
    for node in nodes { layerOf[node.nodeID] = layer(of: node.nodeID) }

    let declarationOrder = Dictionary(
      uniqueKeysWithValues: nodes.enumerated().map { ($0.element.nodeID, $0.offset) })
    let maxLayer = layerOf.values.max() ?? 0
    var layers: [[String]] = (0...maxLayer).map { _ in [] }
    for node in nodes {
      layers[layerOf[node.nodeID] ?? 0].append(node.nodeID)
    }
    for index in layers.indices {
      layers[index].sort { (declarationOrder[$0] ?? 0) < (declarationOrder[$1] ?? 0) }
    }

    // 4. 几何最终权威（design §5.3）：凡 target 层号 ≤ source 层号的边按反向边
    //    渲染，与模型标记无关；不一致记 feedbackMarkMismatch，画面不变。
    var backwardEdges = Set<Int>()
    var diagnostics: [String] = []
    for (index, edge) in edges.enumerated() {
      let backward = (layerOf[edge.to] ?? 0) <= (layerOf[edge.from] ?? 0)
      if backward { backwardEdges.insert(index) }
      if backward != edge.feedbackMarked {
        diagnostics.append("feedbackMarkMismatch edge=\(edge.from)->\(edge.to)")
      }
    }
    var channelOf: [Int: Int] = [:]
    for (channel, edgeIndex) in edges.indices.filter({ backwardEdges.contains($0) }).enumerated() {
      channelOf[edgeIndex] = channel
    }

    // 5. 沟内槽位登记：同源出边按声明序分 lane；落点先按扇形错开，再按
    //    「要么完全重合、要么拉开」整形；沟里有几条带标签的 lane 决定沟要多高。
    var outCount: [String: Int] = [:]
    var outPort: [Int: Int] = [:]
    for (index, edge) in edges.enumerated() where !backwardEdges.contains(index) {
      outPort[index] = outCount[edge.from, default: 0]
      outCount[edge.from, default: 0] += 1
    }
    var laneOfEdge: [Int: Int] = [:]
    var landingOffsetOfEdge: [Int: CGFloat] = [:]
    for (index, edge) in edges.enumerated() where !backwardEdges.contains(index) {
      let port = outPort[index] ?? 0
      let count = outCount[edge.from] ?? 1
      laneOfEdge[index] = min(port, FlowMetrics.maxLanes - 1)
      landingOffsetOfEdge[index] =
        count > 1 ? (CGFloat(port) - CGFloat(count - 1) / 2) * FlowMetrics.fanOutStep : 0
    }
    landingOffsetOfEdge = spreadLandings(
      edges: edges, backwardEdges: backwardEdges, offsets: landingOffsetOfEdge)

    var gutters = Array(repeating: FlowGutterSlots.empty, count: max(0, layers.count - 1))
    for (index, edge) in edges.enumerated() where !backwardEdges.contains(index) {
      let gutter = layerOf[edge.from] ?? 0
      guard gutters.indices.contains(gutter), let lane = laneOfEdge[index] else { continue }
      gutters[gutter].laneUsed[lane] = true
      if !(edge.label ?? "").isEmpty { gutters[gutter].laneLabeled[lane] = true }
    }

    return FlowLayoutPlan(
      layers: layers,
      layerOfNode: layerOf,
      backwardEdges: backwardEdges,
      channelOf: channelOf,
      channelCount: backwardEdges.count,
      laneOfEdge: laneOfEdge,
      landingOffsetOfEdge: landingOffsetOfEdge,
      gutters: gutters,
      diagnostics: diagnostics)
  }

  /// 同一目标盒上的落点整形：**要么完全重合，要么至少差 `minLandingGap`**。
  ///
  /// 完全重合正是 design §2.4 要的「汇入」（F1 四条边落同一点，是「汇合不复制节点」
  /// 的画面证据），所以不拆。要治的是「差一点点」：两个箭头几乎并成一个。
  /// 以最靠中线的那个落点为锚（通常就是中线本身，直行边因此保持笔直），
  /// 其余按原有左右次序向外推开。锚点取 |offset| 最小者，并列时取下标小者 ——
  /// 同一份 wire 两次渲染必须给出同一张图（design §2.2「画面不抖」）。
  private static func spreadLandings(
    edges: [SummaryFlowEdge],
    backwardEdges: Set<Int>,
    offsets: [Int: CGFloat]
  ) -> [Int: CGFloat] {
    var result = offsets
    var byTarget: [String: [Int]] = [:]
    for index in edges.indices where !backwardEdges.contains(index) {
      byTarget[edges[index].to, default: []].append(index)
    }
    for target in byTarget.keys.sorted() {
      let group = byTarget[target] ?? []
      var distinct: [CGFloat] = []
      for value in group.compactMap({ offsets[$0] }).sorted()
      where !distinct.contains(where: { abs($0 - value) < 0.01 }) {
        distinct.append(value)
      }
      guard distinct.count > 1 else { continue }
      var anchor = 0
      for index in distinct.indices where abs(distinct[index]) < abs(distinct[anchor]) {
        anchor = index
      }
      var moved = distinct
      for index in (anchor + 1)..<moved.count {
        moved[index] = max(moved[index], moved[index - 1] + FlowMetrics.minLandingGap)
      }
      for index in stride(from: anchor - 1, through: 0, by: -1) {
        moved[index] = min(moved[index], moved[index + 1] - FlowMetrics.minLandingGap)
      }
      for edgeIndex in group {
        guard let value = offsets[edgeIndex],
          let slot = distinct.firstIndex(where: { abs($0 - value) < 0.01 })
        else { continue }
        result[edgeIndex] = moved[slot]
      }
    }
    return result
  }

  /// 在（移除已判定反馈边之后的）分层用图上找一个环，返回环上声明序最靠后
  /// 的 source 所属边；找不到环（已是 DAG）返回 nil。
  private static func findCycleRemovalCandidate(
    nodes: [SummaryFlowNode],
    edges: [SummaryFlowEdge],
    removed: Set<Int>
  ) -> Int? {
    var adjacency: [String: [(edge: Int, target: String)]] = [:]
    for (index, edge) in edges.enumerated() where !removed.contains(index) {
      adjacency[edge.from, default: []].append((index, edge.to))
    }
    let declarationOrder = Dictionary(
      uniqueKeysWithValues: nodes.enumerated().map { ($0.element.nodeID, $0.offset) })
    // 0 = 未访问，1 = 在栈上（灰），2 = 已完成（黑）。
    var state: [String: Int] = [:]
    for seed in nodes where state[seed.nodeID, default: 0] == 0 {
      state[seed.nodeID] = 1
      // arrivedVia：经哪条边进栈，找回路时把树边捞回来。
      var stack: [(node: String, nextChild: Int, arrivedVia: Int?)] = [(seed.nodeID, 0, nil)]
      while let top = stack.last {
        let children = adjacency[top.node] ?? []
        guard top.nextChild < children.count else {
          state[top.node] = 2
          stack.removeLast()
          continue
        }
        stack[stack.count - 1].nextChild += 1
        let child = children[top.nextChild]
        let childState = state[child.target, default: 0]
        if childState == 1 {
          // 回边 top.node -> child.target：环 = 栈上 child.target 到栈顶的路径 + 这条边。
          var cycleEdges = [child.edge]
          if let cycleStart = stack.firstIndex(where: { $0.node == child.target }) {
            cycleEdges += stack[(cycleStart + 1)...].compactMap(\.arrivedVia)
          }
          return cycleEdges.max {
            (declarationOrder[edges[$0].from] ?? 0) < (declarationOrder[edges[$1].from] ?? 0)
          }
        }
        if childState == 0 {
          state[child.target] = 1
          stack.append((child.target, 0, child.edge))
        }
      }
    }
    return nil
  }
}

/// 一条已画线段的登记项。`isLane` 是这条边自己的水平段（标签就贴在它下面，
/// 不算自己撞自己）；`isChannel` 是左通道虚线竖段（特意让它从反馈边标签
/// 身上穿过去建立关联，那是设计不是碰撞）。
private struct FlowStroke {
  let rect: CGRect
  let edgeIndex: Int
  let isLane: Bool
  let isChannel: Bool
}

/// 标签轨道：这条边的标签允许在哪条线附近找位置。
private enum FlowLabelTrack {
  /// 横轨：标签落在自己那条 lane 的标签行（`top` 已按沟内槽位算好），沿水平段找 x。
  case horizontal(xFrom: CGFloat, xTo: CGFloat, top: CGFloat)
  /// 竖轨：标签贴在竖段旁边，先右后左，沿竖段找 y。
  case vertical(x: CGFloat, yFrom: CGFloat, yTo: CGFloat)
  /// 左通道：x 钉在通道区左端，只在 y 上往上叠。
  case channel(x: CGFloat, yAnchor: CGFloat)

  /// 越不自由越先放：通道标签 x 是钉死的，竖轨只有左右两侧，横轨越长余地越大。
  var freedom: CGFloat {
    switch self {
    case .horizontal(let xFrom, let xTo, _): return abs(xTo - xFrom)
    case .vertical: return 0.5
    case .channel: return 0
    }
  }

  var ignoresChannelStrokes: Bool {
    if case .channel = self { return true }
    return false
  }

  /// 候选位按偏好排序。横轨的第一候选是**水平段中点** —— design §2.4 的原文位置，
  /// 撞了才沿段向两侧一步步挪（每步半个标签宽 + 6，保证挪一步就真的错开）。
  func candidates(size: CGSize) -> [CGRect] {
    switch self {
    case .horizontal(let xFrom, let xTo, let top):
      let mid = (xFrom + xTo) / 2
      let step = size.width / 2 + 6
      var centers = [mid]
      for offset in 1...6 {
        centers.append(mid + CGFloat(offset) * step)
        centers.append(mid - CGFloat(offset) * step)
      }
      return centers.map {
        CGRect(x: $0 - size.width / 2, y: top, width: size.width, height: size.height)
      }
    case .vertical(let x, let yFrom, let yTo):
      let mid = (yFrom + yTo) / 2
      let step = size.height + 3
      var centers = [mid]
      for offset in 1...2 {
        centers.append(mid - CGFloat(offset) * step)
        centers.append(mid + CGFloat(offset) * step)
      }
      return centers.flatMap { center -> [CGRect] in
        let top = center - size.height / 2
        return [
          CGRect(x: x + 4, y: top, width: size.width, height: size.height),
          CGRect(x: x - 4 - size.width, y: top, width: size.width, height: size.height),
        ]
      }
    case .channel(let x, let yAnchor):
      let step = size.height + 3
      var bottoms: [CGFloat] = []
      for offset in 0...3 { bottoms.append(yAnchor - CGFloat(offset) * step) }
      for offset in 1...3 { bottoms.append(yAnchor + CGFloat(offset) * step) }
      return bottoms.map {
        CGRect(x: x, y: $0 - size.height, width: size.width, height: size.height)
      }
    }
  }
}

/// 一条边的走线 + 它的标签轨道。「算几何」与「放标签」拆成两趟：
/// 先把所有边的线段算完并登记，再放标签 —— 放的时候沟里有什么已经全知道了。
private struct FlowRoute {
  let edgeIndex: Int
  let path: Path
  let arrow: Path
  let dashed: Bool
  let strokes: [FlowStroke]
  let label: String
  let track: FlowLabelTrack
}

/// 标签避让登记簿。盒子、线段、已放下的标签全登记在案，新标签逐个候选位试，
/// 取第一个不撞的；全都撞就取最轻的。
private struct FlowLabelRegistry {
  let boxes: [CGRect]
  let strokes: [FlowStroke]
  let bounds: CGRect
  var labels: [CGRect] = []

  /// 撞得有多狠。**盒子权重压倒一切** —— 标签被盒子吞掉是修过的老 bug，
  /// 兜底时宁可与线相交也绝不退回盒子底下；出界同罪。
  func cost(of rect: CGRect, route: FlowRoute) -> CGFloat {
    var total: CGFloat = 0
    for box in boxes {
      total +=
        100
        * Self.overlap(
          rect, box.insetBy(dx: -FlowMetrics.boxClearance, dy: -FlowMetrics.boxClearance))
    }
    for label in labels {
      total +=
        4
        * Self.overlap(
          rect, label.insetBy(dx: -FlowMetrics.labelClearance, dy: -FlowMetrics.labelClearance))
    }
    for stroke in strokes {
      if stroke.isChannel, route.track.ignoresChannelStrokes { continue }
      if stroke.isLane, stroke.edgeIndex == route.edgeIndex { continue }
      total += Self.overlap(
        rect,
        stroke.rect.insetBy(dx: -FlowMetrics.strokeClearance, dy: -FlowMetrics.strokeClearance))
    }
    return total + 100 * Self.outside(rect, bounds)
  }

  private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let box = lhs.intersection(rhs)
    guard !box.isNull, box.width > 0, box.height > 0 else { return 0 }
    return box.width * box.height
  }

  private static func outside(_ rect: CGRect, _ bounds: CGRect) -> CGFloat {
    let inside = rect.intersection(bounds)
    let insideArea = inside.isNull ? 0 : inside.width * inside.height
    return max(0, rect.width * rect.height - insideArea)
  }
}

/// 每个节点盒的边界，供边绘制层取几何。
private struct FlowNodeRectsKey: PreferenceKey {
  static let defaultValue: [String: Anchor<CGRect>] = [:]
  static func reduce(
    value: inout [String: Anchor<CGRect>],
    nextValue: () -> [String: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// flow 原语：唯一节点 + 显式有向边。自上而下分层，层 = 行。
///
/// 拿到 `.flow` 就意味着 Core 的契约校验已经过了 —— 画不出来的载荷在归一化层
/// 就被降级成 `.table` 三列边表了，这里不做第二套降级判定。
struct FlowWidgetView: View {
  let title: String
  let nodes: [SummaryFlowNode]
  let edges: [SummaryFlowEdge]
  var onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  private var plan: FlowLayoutPlan {
    FlowLayouter.plan(nodes: nodes, edges: edges)
  }

  private var nodeByID: [String: SummaryFlowNode] {
    Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeID, $0) })
  }

  var body: some View {
    let plan = plan
    SummaryWidgetContainer(title: title, badge: "flow") {
      // 左通道预留在行区之外：通道数在布局阶段已知，先占宽再画行，
      // 边绘制层的坐标系因此能覆盖通道区。
      HStack(spacing: 0) {
        Spacer()
          .frame(width: CGFloat(plan.channelCount) * FlowMetrics.channelWidth)
        // 层间沟不是固定 24：沟里有几条要放标签的 lane，沟就有多高。
        VStack(spacing: 0) {
          ForEach(Array(plan.layers.enumerated()), id: \.offset) { layerIndex, layer in
            HStack(alignment: .top, spacing: Tokens.Spacing.xsm) {
              ForEach(layer, id: \.self) { id in
                if let node = nodeByID[id] {
                  FlowNodeBoxView(node: node, onJumpToTranscript: onJumpToTranscript)
                    .anchorPreference(key: FlowNodeRectsKey.self, value: .bounds) {
                      [id: $0]
                    }
                }
              }
            }
            .padding(
              .bottom,
              layerIndex < plan.layers.count - 1 ? gutterHeight(plan, layerIndex) : 0)
          }
        }
      }
      .backgroundPreferenceValue(FlowNodeRectsKey.self) { anchors in
        GeometryReader { geometry in
          Canvas { context, _ in
            drawEdges(plan: plan, context: context, geometry: geometry, anchors: anchors)
          }
          .allowsHitTesting(false)
        }
      }
    }
  }

  // MARK: 沟高与 lane 的 y

  private var labelHeight: CGFloat {
    FlowMetrics.labelHeight(textScale.size(FlowMetrics.labelFontSize))
  }

  private var labeledLaneHeight: CGFloat {
    FlowMetrics.labeledLaneHeight(textScale.size(FlowMetrics.labelFontSize))
  }

  private func laneHeight(_ slots: FlowGutterSlots, lane: Int) -> CGFloat {
    guard slots.laneUsed.indices.contains(lane), slots.laneUsed[lane] else { return 0 }
    return slots.laneLabeled[lane] ? labeledLaneHeight : FlowMetrics.bareLaneHeight
  }

  /// 一条层间沟要多高：装得下它登记的每条 lane（带标签的要留出标签行）。
  private func gutterHeight(_ plan: FlowLayoutPlan, _ index: Int) -> CGFloat {
    guard plan.gutters.indices.contains(index) else { return FlowMetrics.minGutter }
    let slots = plan.gutters[index]
    var total = FlowMetrics.gutterTopPad + FlowMetrics.gutterBottomPad
    for lane in slots.laneUsed.indices { total += laneHeight(slots, lane: lane) }
    return max(FlowMetrics.minGutter, total)
  }

  /// lane 的水平段离源盒底边多远：前面每条被占的 lane 各让出自己那一格。
  private func laneOffset(_ plan: FlowLayoutPlan, gutter: Int, lane: Int) -> CGFloat {
    guard plan.gutters.indices.contains(gutter) else { return FlowMetrics.gutterTopPad }
    let slots = plan.gutters[gutter]
    var offset = FlowMetrics.gutterTopPad
    for earlier in 0..<max(0, lane) { offset += laneHeight(slots, lane: earlier) }
    return offset
  }

  // MARK: 两趟绘制：先算线并登记，再放标签

  private func drawEdges(
    plan: FlowLayoutPlan,
    context: GraphicsContext,
    geometry: GeometryProxy,
    anchors: [String: Anchor<CGRect>]
  ) {
    var rects: [String: CGRect] = [:]
    for (id, anchor) in anchors { rects[id] = geometry[anchor] }
    let routes = buildRoutes(plan: plan, rects: rects)
    for route in routes {
      context.stroke(
        route.path,
        with: .color(Tokens.Color.ink4),
        style: route.dashed
          ? StrokeStyle(lineWidth: 1, dash: [4, 3]) : StrokeStyle(lineWidth: 1))
      context.stroke(
        route.arrow,
        with: .color(Tokens.Color.ink4),
        style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }
    // 盒子按 nodes 声明序取，不迭代字典 —— 同一份 wire 连续两轮渲染必须给出
    // 同一张图（design §2.2「画面不抖」），字典序不可依赖。
    placeLabels(
      context: context,
      routes: routes,
      boxes: nodes.compactMap { rects[$0.nodeID] },
      bounds: CGRect(origin: .zero, size: geometry.size))
  }

  private func buildRoutes(plan: FlowLayoutPlan, rects: [String: CGRect]) -> [FlowRoute] {
    var routes: [FlowRoute] = []
    for (index, edge) in edges.enumerated() {
      guard let from = rects[edge.from], let to = rects[edge.to] else { continue }
      if plan.backwardEdges.contains(index), let channel = plan.channelOf[index] {
        routes.append(
          backwardRoute(
            plan: plan, index: index, edge: edge, from: from, to: to, channel: channel))
      } else {
        routes.append(forwardRoute(plan: plan, index: index, edge: edge, from: from, to: to))
      }
    }
    return routes
  }

  /// 前向边（design §2.2 步骤 4）：源盒底边中点 → 下行到自己那条 lane →
  /// 水平移到落点 x → 下行入盒顶边，目标端一枚向下箭头。
  private func forwardRoute(
    plan: FlowLayoutPlan,
    index: Int,
    edge: SummaryFlowEdge,
    from: CGRect,
    to: CGRect
  ) -> FlowRoute {
    let lane = plan.laneOfEdge[index] ?? 0
    let gutter = plan.layerOfNode[edge.from] ?? 0
    let source = CGPoint(x: from.midX, y: from.maxY)
    let target = CGPoint(x: to.midX + (plan.landingOffsetOfEdge[index] ?? 0), y: to.minY)
    let laneY = source.y + laneOffset(plan, gutter: gutter, lane: lane)
    let isStraight = abs(source.x - target.x) < 0.5
    var path = Path()
    path.move(to: source)
    var strokes: [FlowStroke] = []
    var track: FlowLabelTrack
    if isStraight {
      path.addLine(to: target)
      strokes.append(vertical(x: source.x, y0: source.y, y1: target.y, edge: index))
      track = .vertical(x: source.x, yFrom: source.y, yTo: target.y)
    } else {
      path.addLine(to: CGPoint(x: source.x, y: laneY))
      path.addLine(to: CGPoint(x: target.x, y: laneY))
      path.addLine(to: target)
      strokes.append(vertical(x: source.x, y0: source.y, y1: laneY, edge: index))
      strokes.append(horizontal(y: laneY, x0: source.x, x1: target.x, edge: index))
      strokes.append(vertical(x: target.x, y0: laneY, y1: target.y, edge: index))
      track = .horizontal(
        xFrom: source.x, xTo: target.x, top: laneY + 1 + FlowMetrics.labelLead)
    }
    var arrow = Path()
    arrow.move(to: CGPoint(x: target.x - 2.5, y: target.y - 3.5))
    arrow.addLine(to: target)
    arrow.addLine(to: CGPoint(x: target.x + 2.5, y: target.y - 3.5))
    return FlowRoute(
      edgeIndex: index,
      path: path,
      arrow: arrow,
      dashed: false,
      strokes: strokes,
      label: edge.label ?? "",
      track: track)
  }

  /// 反向边（design §5.1）：源盒左缘中点 → 左通道 → 垂直上行 → 水平进目标盒
  /// 左缘中点，末端箭头方向不变（仍指真实流向）。1pt 虚线 dash 4/3，色 ink4。
  ///
  /// 标签钉在通道区左端（虚线竖段从它身上穿过，关联靠这个），y 交给登记簿往上叠。
  private func backwardRoute(
    plan: FlowLayoutPlan,
    index: Int,
    edge: SummaryFlowEdge,
    from: CGRect,
    to: CGRect,
    channel: Int
  ) -> FlowRoute {
    let channelX =
      CGFloat(plan.channelCount - channel) * FlowMetrics.channelWidth
      - FlowMetrics.channelWidth / 2
    let source = CGPoint(x: from.minX, y: from.midY)
    let target = CGPoint(x: to.minX, y: to.midY)
    var path = Path()
    path.move(to: source)
    path.addLine(to: CGPoint(x: channelX, y: source.y))
    path.addLine(to: CGPoint(x: channelX, y: target.y))
    path.addLine(to: target)
    var arrow = Path()
    arrow.move(to: CGPoint(x: target.x - 3.5, y: target.y - 2.5))
    arrow.addLine(to: target)
    arrow.addLine(to: CGPoint(x: target.x - 3.5, y: target.y + 2.5))
    let strokes = [
      horizontal(y: source.y, x0: source.x, x1: channelX, edge: index, isChannel: true),
      vertical(x: channelX, y0: source.y, y1: target.y, edge: index, isChannel: true),
      horizontal(y: target.y, x0: channelX, x1: target.x, edge: index, isChannel: true),
    ]
    return FlowRoute(
      edgeIndex: index,
      path: path,
      arrow: arrow,
      dashed: true,
      strokes: strokes,
      label: edge.label ?? "",
      track: .channel(x: 4, yAnchor: from.minY - 5))
  }

  /// 标签放置：最不自由的先放，每条边逐个候选位试，取第一个不撞的；
  /// 全都撞就取最轻的（绝不丢标签，也绝不把标签退回盒子底下）。
  private func placeLabels(
    context: GraphicsContext,
    routes: [FlowRoute],
    boxes: [CGRect],
    bounds: CGRect
  ) {
    var registry = FlowLabelRegistry(
      boxes: boxes, strokes: routes.flatMap(\.strokes), bounds: bounds)
    let ordered = routes.filter { !$0.label.isEmpty }
      .sorted {
        $0.track.freedom == $1.track.freedom
          ? $0.edgeIndex < $1.edgeIndex : $0.track.freedom < $1.track.freedom
      }
    for route in ordered {
      let text = Text(route.label)
        .font(.system(size: textScale.size(FlowMetrics.labelFontSize)))
        .foregroundStyle(Tokens.Color.ink4)
      let resolved = context.resolve(text)
      let size = resolved.measure(in: CGSize(width: bounds.width, height: bounds.height))
      let candidates = route.track.candidates(size: size)
      var best = candidates.first ?? CGRect(origin: .zero, size: size)
      var bestCost = CGFloat.greatestFiniteMagnitude
      for candidate in candidates {
        let cost = registry.cost(of: candidate, route: route)
        if cost <= 0 {
          best = candidate
          bestCost = 0
          break
        }
        if cost < bestCost {
          best = candidate
          bestCost = cost
        }
      }
      context.draw(resolved, in: best)
      registry.labels.append(best)
    }
  }

  private func vertical(
    x: CGFloat, y0: CGFloat, y1: CGFloat, edge: Int, isChannel: Bool = false
  ) -> FlowStroke {
    FlowStroke(
      rect: CGRect(x: x - 0.5, y: min(y0, y1), width: 1, height: abs(y1 - y0)),
      edgeIndex: edge,
      isLane: false,
      isChannel: isChannel)
  }

  private func horizontal(
    y: CGFloat, x0: CGFloat, x1: CGFloat, edge: Int, isChannel: Bool = false
  ) -> FlowStroke {
    FlowStroke(
      rect: CGRect(x: min(x0, x1), y: y - 0.5, width: abs(x1 - x0), height: 1),
      edgeIndex: edge,
      isLane: !isChannel,
      isChannel: isChannel)
  }
}

/// 节点盒：复用 StepBox 的视觉词汇（design §2.3）—— card 底、line 描边、圆角 7。
/// flow 盒宽下限更小，因此标题与 detail 都在盒内完整换行；不以省略号隐藏图中证据。
private struct FlowNodeBoxView: View {
  let node: SummaryFlowNode
  let onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      HStack(spacing: Tokens.Spacing.xxs) {
        Text(node.title)
          .font(.system(size: textScale.size(Tokens.FontSize.secondary), weight: .semibold))
          .foregroundStyle(Tokens.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(1)
          .help(node.title)
          .runtimeAccessibilityIdentifier("summary.widget.flow.body.\(node.id.uuidString)")
        EvidenceBadge(mark: node.evidence)
      }
      if let detail = node.detail, !detail.isEmpty {
        Text(detail)
          .font(.system(size: textScale.size(Tokens.FontSize.caption)))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .help(detail)
      }
      TranscriptAnchorButton(anchor: node.anchor, onJump: onJumpToTranscript)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, Tokens.Spacing.xsm)
    .padding(.vertical, Tokens.Spacing.xs)
    .background(Tokens.Color.card)
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(Tokens.Color.line, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
  }
}

extension SummaryVisualization {
  @ViewBuilder
  @MainActor
  func makeView(
    onJumpToTranscript: ((TimeInterval) -> Void)? = nil
  ) -> some View {
    switch self {
    case .steps(let title, let items):
      StepsWidgetView(
        title: title,
        items: items,
        onJumpToTranscript: onJumpToTranscript
      )
    case .table(let title, let table):
      TableWidgetView(
        title: title,
        table: table,
        onJumpToTranscript: onJumpToTranscript
      )
    case .timeline(let title, let items):
      TimelineWidgetView(
        title: title,
        items: items,
        onJumpToTranscript: onJumpToTranscript
      )
    case .tree(let title, let roots):
      TreeWidgetView(
        title: title,
        roots: roots,
        onJumpToTranscript: onJumpToTranscript
      )
    case .nums(let title, let items):
      NumbersWidgetView(
        title: title,
        items: items,
        onJumpToTranscript: onJumpToTranscript
      )
    case .chain(let title, let items):
      ChainWidgetView(
        title: title,
        items: items,
        onJumpToTranscript: onJumpToTranscript
      )
    case .flow(let title, let nodes, let edges):
      FlowWidgetView(
        title: title,
        nodes: nodes,
        edges: edges,
        onJumpToTranscript: onJumpToTranscript
      )
    }
  }
}

/// 部件内的核验记号。字形与 accessibility 文案沿用标注词汇表(★⚑✓✎●[待核] 是
/// spec 立的语义记号,不是「文本字符当图标」),**只统一 chrome**:
/// 原先是 `Text(…).background(…)` 裸写——没有内边距、没有圆角、没有显式字号,
/// 底色紧贴字形外框画成一个直角小色块,与同一 app 里 `SummaryMarkerBadge`(胶囊+内边距)
/// 和 `EvidenceText`(纯文字)完全不是一套(2026-08-21 走查 P-5)。
/// 几何对齐 `SummaryMarkerBadge`,措辞一字未动。
private struct EvidenceBadge: View {
  let mark: SummaryEvidenceMark?

  private var appearance: (text: String, label: String, foreground: Color, background: Color)? {
    switch mark {
    case .toVerify:
      return ("[待核]", "待核", Tokens.Color.warn, Tokens.Color.amber)
    case .corrected:
      return ("✎", "已修正", Tokens.Color.revision, Tokens.Color.revisionSoft)
    case .confirmed:
      return ("✓", "已确认", Tokens.Color.resolved, Tokens.Color.resolvedSoft)
    case nil:
      return nil
    }
  }

  var body: some View {
    if let appearance {
      Text(appearance.text)
        .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
        .foregroundStyle(appearance.foreground)
        .padding(.horizontal, Tokens.Spacing.xxs)
        .padding(.vertical, Tokens.Spacing.hairline)
        .background(appearance.background)
        .clipShape(Capsule())
        .accessibilityLabel(appearance.label)
    }
  }
}

struct TranscriptAnchorButton: View {
  let anchor: TranscriptAnchor?
  let onJump: ((TimeInterval) -> Void)?

  var body: some View {
    if let anchor, let seconds = anchor.seconds, let onJump {
      Button {
        onJump(seconds)
      } label: {
        TranscriptAnchorChip(label: shortLabel(anchor.timecode))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("回跳转写 \(anchor.timecode)")
    }
  }

  private func shortLabel(_ timecode: String) -> String {
    let parts = timecode.split(separator: ":")
    guard parts.count == 3, parts.first == "00" else { return timecode }
    return parts.dropFirst().joined(separator: ":")
  }
}
