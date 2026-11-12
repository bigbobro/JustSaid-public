import JustSaidCore
import SwiftUI

private let bottomSentinelID = "history-bottom-sentinel"

/// 整理区：每个话题是一张持续更新的活文档卡；最后一张进行中卡置底。
/// 用户上翻即停止跟随并浮出「↓ 回到最新」，`scrollRequest` 由章节目录触发。
struct HistoryPaneView: View {
  let topics: [SummaryTopic]
  let engineStatus: SummaryEngineStatus
  @Binding var scrollRequest: UUID?
  let onSaveSourceAsNote: (SummarySourceReference) -> Void
  let onJumpToTranscript: (TimeInterval) -> Void
  /// 排除入口(08-14):bullet 右键排除锚定段、话题块头部右键整块排除。
  /// optional——会议库留痕页不传,那里不出菜单。
  var onExcludeBulletAnchor: ((TimeInterval) -> Void)? = nil
  var onExcludeTopicRange: ((ClosedRange<TimeInterval>) -> Void)? = nil

  @Environment(\.textScale) private var textScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isFollowing = true
  @State private var openSourceBulletID: UUID?
  @State private var highlightedTopicID: UUID?
  @State private var isLegendHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 头部要整体压在时间线之上。「图例」悬停卡是 topBar 内的 overlay,越界往下画,
      // 但 VStack 里后面的兄弟(时间线)默认画在前面的兄弟之上——于是浮卡被话题行
      // 穿过来盖住,看着像这层是半透明的(owner 2026-09-21 实测:「跟背后那个进行中叠在一起」)。
      // legend 自己那句 zIndex(1) 只在 topBar 的 HStack 内排序,管不到这一层。
      topBar
        .zIndex(1)
      ScrollViewReader { proxy in
        ZStack(alignment: .bottom) {
          ScrollView {
            timeline
              .padding(.horizontal, Tokens.V1.Space.lg)
          }
          .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height
              >= geometry.contentSize.height - 32
          } action: { _, atBottom in
            isFollowing = atBottom
          }
          .onChange(of: topics) { _, _ in
            guard isFollowing else { return }
            scrollToBottom(proxy)
          }
          .onChange(of: engineStatus) { _, _ in
            guard isFollowing else { return }
            scrollToBottom(proxy)
          }
          .onChange(of: scrollRequest) { _, request in
            guard let request else { return }
            handleScrollRequest(request, proxy: proxy)
          }
          .onAppear {
            if let request = scrollRequest {
              handleScrollRequest(request, proxy: proxy)
            } else {
              scrollToBottom(proxy, animated: false)
            }
          }

          if !isFollowing {
            JumpToLatestButton {
              scrollToBottom(proxy)
              isFollowing = true
            }
            .padding(.bottom, Tokens.Spacing.sm)
          }
        }
      }
    }
    .background(Tokens.V1.Color.paper)
  }

  private func handleScrollRequest(_ topicID: UUID, proxy: ScrollViewProxy) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: Tokens.Motion.scroll)) {
      proxy.scrollTo(topicID, anchor: .top)
    }
    highlightedTopicID = topicID
    Task {
      try? await Task.sleep(for: .seconds(1.2))
      if highlightedTopicID == topicID {
        highlightedTopicID = nil
      }
    }
    scrollRequest = nil
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
    if animated && !reduceMotion {
      withAnimation(.easeOut(duration: Tokens.Motion.scroll)) {
        proxy.scrollTo(bottomSentinelID, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(bottomSentinelID, anchor: .bottom)
    }
  }

  /// 整理区头部。**图例不常驻**（2026-08-19 R8）：五枚徽章是「第一次见时的说明」，
  /// 常驻一整行就成了每次开会都要跳过的噪声——收进「图例」悬停卡，需要时才浮出。
  private var topBar: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Text("整理区")
        .font(Tokens.V1.Text.strong.font)
        .foregroundStyle(Tokens.V1.Color.ink)
      EngineStatusChip(status: engineStatus)
      Spacer()
      legend
    }
    .padding(.horizontal, Tokens.V1.Space.lg)
    .frame(height: Tokens.V1.Size.controlLg)
  }

  private var legend: some View {
    Text("图例")
      .font(Tokens.V1.Text.meta.font)
      .foregroundStyle(isLegendHovering ? Tokens.V1.Color.ink2 : Tokens.V1.Color.ink3)
      .contentShape(Rectangle())
      .onHover { isLegendHovering = $0 }
      .overlay(alignment: .topTrailing) {
        if isLegendHovering {
          SummaryMarkerLegendCard()
            .offset(y: Tokens.Spacing.lg)
        }
      }
      .zIndex(1)
      .accessibilityLabel("五种标注词汇图例")
  }

  private var timeline: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
        SummaryTopicCardView(
          topic: topic,
          accent: Tokens.Color.chapterAccent(index),
          isHighlighted: highlightedTopicID == topic.id,
          fontSize: textScale.size(Tokens.FontSize.body),
          // P3 层级:「最新」= topics 末张(一个布尔,不动数据);旧卡退成 calm。
          tier: index == topics.count - 1 ? .focus : .calm,
          openSourceBulletID: $openSourceBulletID,
          onSaveSourceAsNote: onSaveSourceAsNote,
          onJumpToTranscript: onJumpToTranscript,
          onExcludeBulletAnchor: onExcludeBulletAnchor,
          onExcludeTopicRange: onExcludeTopicRange,
          // 细线只画在两块普通话题之间:浅井自己有边界,它的上下都不再压一条线。
          showsTopRule: index > 0 && !topic.isInProgress && !topics[index - 1].isInProgress
        )
        .id(topic.id)
        .transition(reduceMotion ? .identity : .topicCardEntrance)
      }

      if case .generatingNewTopic = engineStatus {
        // 它占的是下一块的位置:前一块不是浅井时,同样以一条细线隔开。
        GeneratingTopicNode(showsTopRule: topics.last.map { !$0.isInProgress } ?? false)
      }

      Color.clear.frame(height: 1).id(bottomSentinelID)
    }
    .padding(.bottom, Tokens.Spacing.md)
    .frame(maxWidth: Tokens.Layout.historyContentWidth, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    // 新卡片入场淡入+上移 160ms（ui-spec §4）；用 `topics.count` 而非整个数组作为
    // 动画触发键，这样“已有卡片内容变更”命中同一 count、不会被误动画（另一条 §4 规则）。
    .animation(
      reduceMotion ? nil : .easeOut(duration: Tokens.Motion.listShift), value: topics.count)
  }
}

extension AnyTransition {
  fileprivate static var topicCardEntrance: AnyTransition {
    .modifier(
      active: TopicCardEntranceModifier(progress: 0),
      identity: TopicCardEntranceModifier(progress: 1)
    )
  }
}

private struct TopicCardEntranceModifier: ViewModifier {
  let progress: Double

  func body(content: Content) -> some View {
    content
      .opacity(progress)
      .offset(y: (1 - progress) * 4)
  }
}

/// 整理区表头那颗状态 chip。它说的是**整理区自己**跟进到哪儿——
/// 文案与配色都由 `SummaryEngineStatus.organizerStatusText` 单一来源给出，
/// 健康态与降级态因此不会再渲染成同一句「已跟进到 X」（08-10：慢通道明明在正常出话题，
/// 这里与上方横幅一起把它说成了不可用）。
private struct EngineStatusChip: View {
  let status: SummaryEngineStatus

  var body: some View {
    // 跟在「整理区」后面的一句元信息,不画胶囊:它是这一栏的状态,不是一颗能点的东西。
    Group {
      if let text = status.organizerStatusText {
        Text(text)
          .foregroundStyle(status.isDegraded ? Tokens.V1.Color.warn : Tokens.V1.Color.ink3)
          .runtimeAccessibilityIdentifier(status.engineChipIdentifier)
      } else {
        HStack(spacing: Tokens.V1.Space.s2xs) {
          BreathingDots()
          Text("AI 分析中")
        }
        .foregroundStyle(Tokens.V1.Color.accent)
        .runtimeAccessibilityIdentifier("dashboard.engine-chip.analyzing")
      }
    }
    .font(Tokens.V1.Text.meta.font)
    .accessibilityElement(children: .combine)
  }
}

/// 话题块整体排除(08-14):时间范围解析不出时置灰而不是藏掉——
/// 藏起来用户会以为这个功能不存在。没有回调则整条菜单不存在(不是空菜单)。
private struct TopicExcludeContextMenu: ViewModifier {
  let timeRangeLabel: String
  let onExcludeTopicRange: ((ClosedRange<TimeInterval>) -> Void)?

  func body(content: Content) -> some View {
    if let onExcludeTopicRange {
      let range = ExclusionUI.topicRangeSeconds(timeRangeLabel)
      content.contextMenu {
        Button("这个话题是闲聊，整块排除") {
          if let range { onExcludeTopicRange(range) }
        }
        .disabled(range == nil)
      }
    } else {
      content
    }
  }
}

struct SummaryTopicCardView: View {
  let topic: SummaryTopic
  let accent: Color
  let isHighlighted: Bool
  let fontSize: CGFloat
  /// 话题卡层级(P3,用户拍板原型 08-驾驶舱卡片层级-v1):驾驶舱时间线由调用方
  /// 按「末张 focus、旧卡 calm」传入;会议库留痕页保持 .standard,视觉零变化。
  var tier: Tokens.CardTier = .standard
  @Binding var openSourceBulletID: UUID?
  let onSaveSourceAsNote: ((SummarySourceReference) -> Void)?
  let onJumpToTranscript: (TimeInterval) -> Void
  /// 排除入口(08-14),optional:留痕页不传 = 无菜单,不污染只读留痕。
  var onExcludeBulletAnchor: ((TimeInterval) -> Void)? = nil
  var onExcludeTopicRange: ((ClosedRange<TimeInterval>) -> Void)? = nil
  /// 去掉内层那一圈底色与描边,由调用方统一套外框。
  ///
  /// 原来是「裸标题在块外 + 要点区自己一个 card 底和描边」,和「这场会」那边的积木
  /// (细边 + paper-2 + 大圆角、标题在块内)不是一套,同一个会议页里两种盒子
  /// (owner 2026-09-20:要跟前面这些页天然融合一体)。默认 false,驾驶舱零变化。
  var chromeless: Bool = false
  /// 平铺画法下块顶那条 1 点细线。第一块、进行中的浅井、紧跟浅井的那一块不画,由调用方算好传入。
  var showsTopRule: Bool = false

  /// 会中整理区(focus / calm)按设计系统「板块隔离」平铺:话题块之间一条细线,
  /// 进行中的那一块是浅井。会议页留痕(standard)仍是原来的盒子。
  private var isFlat: Bool { tier != .standard }

  var body: some View {
    Group {
      if isFlat { flatBlock } else { boxedCard }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("话题：\(topic.title)，\(topic.timeRangeLabel)")
    .runtimeAccessibilityIdentifier(tier.accessibilityID)
  }

  /// 2026-11-11 设计走查(截图「驾驶舱-细条」):原来每个话题是标题在外、要点在一只带描边
  /// 与投影的盒子里,最新一张再加 3 点墨青左缘与 1.5 点墨青描边。README 写的是话题块之间
  /// 只用细线、进行中的那一块用浅井、不用左侧竖条也不用粗边表示状态;`live.html` 同此。
  private var flatBlock: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      titleRow
      content
    }
    .padding(.top, Tokens.V1.Space.xs)
    .padding(.horizontal, Tokens.V1.Space.md)
    .padding(.bottom, Tokens.V1.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    // 浅井用 surface2(浅色 paper-2、深色 paper-3):深色下 paper-2 与纸面只差 7 级,井几乎看不见。
    .background(
      topic.isInProgress ? Tokens.Color.surface2 : Color.clear,
      in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
    )
    .overlay {
      // 章节目录跳过来时闪一下的定位框,1.2 秒后由调用方收回。
      if isHighlighted {
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
          .strokeBorder(Tokens.V1.Color.focus, lineWidth: Tokens.V1.Size.focusWidth)
      }
    }
    .overlay(alignment: .top) {
      if showsTopRule {
        Rectangle()
          .fill(Tokens.V1.Color.rule)
          .frame(height: Tokens.V1.Size.controlRuleWidth)
      }
    }
  }

  private var boxedCard: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      titleRow
      content
        .padding(.horizontal, chromeless ? .zero : Tokens.Spacing.smd)
        .padding(.vertical, chromeless ? .zero : Tokens.Spacing.sm)
        .background(
          chromeless ? Color.clear : Tokens.Color.card,
          in: RoundedRectangle(cornerRadius: Tokens.Radius.card)
        )
        .overlay {
          if !chromeless {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
              .stroke(
                // 录制中/章节定位强调的优先级高于默认描边。
                topic.isInProgress || isHighlighted ? Tokens.Color.ac : Tokens.Color.line,
                lineWidth: topic.isInProgress || isHighlighted ? 1.5 : 1
              )
          }
        }
        .tokenShadow(chromeless ? (color: .clear, radius: 0, y: 0) : Tokens.Shadow.sh1)
    }
    .padding(.bottom, chromeless ? .zero : Tokens.Spacing.xsm)
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xsm) {
      if !isFlat {
        RoundedRectangle(cornerRadius: 2)
          .fill(topic.isInProgress ? Tokens.Color.ac : accent)
          .frame(width: 5, height: 14)
      }
      Text(topic.title)
        .font(.system(size: fontSize, weight: isFlat ? .semibold : .bold))
        .foregroundStyle(titleColor)
      Text(topic.timeRangeLabel)
        .font(.system(size: Tokens.FontSize.caption, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink3)
      if topic.hasVisualization {
        ChapterVisualizationTag()
      }
      ForEach(topic.annotations.filter { $0.kind != .inProgress }) { annotation in
        HStack(spacing: Tokens.Spacing.hairline) {
          SummaryMarkerBadge(kind: annotation.kind, label: annotation.label)
          TranscriptAnchorButton(
            anchor: annotation.anchor,
            onJump: onJumpToTranscript
          )
        }
      }
      Spacer(minLength: 0)
      if isFlat {
        // 状态用设计系统的状态字形(勾 / 环),名字在悬停提示与无障碍标签里。
        StatusGlyph(
          topic.isInProgress ? .running : .done,
          label: topic.isInProgress ? "进行中" : "已沉淀",
          width: Tokens.V1.Size.controlSm)
      } else if topic.isInProgress {
        SummaryMarkerBadge(kind: .inProgress)
      } else {
        Text("已沉淀")
          .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink3)
      }
    }
    // 留痕页不传 onExcludeTopicRange,原来仍然挂着 .contextMenu,右键弹出一个**空菜单**。
    // 空菜单比没有菜单更糟:它让人以为这里本该有东西、是坏了。没有回调就整条不挂。
    .modifier(
      TopicExcludeContextMenu(
        timeRangeLabel: topic.timeRangeLabel,
        onExcludeTopicRange: onExcludeTopicRange
      ))
  }

  /// 平铺画法:进行中的那一块标题与要点都用正文色;其余要点 ink-2,旧块标题也降到 ink-2
  /// (`live.html` 的 is-calm)。要点不再降到 ink-3:活文档是拿来读的。
  private var titleColor: Color {
    isFlat && topic.isInProgress ? Tokens.V1.Color.ink : tier.titleColor
  }

  private var bodyColor: Color {
    isFlat && topic.isInProgress ? Tokens.V1.Color.ink : Tokens.V1.Color.ink2
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      ForEach(topic.bullets) { bullet in
        BulletRow(
          bullet: bullet,
          fontSize: fontSize,
          textColor: bodyColor,
          isSourceOpen: openSourceBulletID == bullet.id,
          onToggleSource: {
            openSourceBulletID = openSourceBulletID == bullet.id ? nil : bullet.id
          },
          onSaveSourceAsNote: onSaveSourceAsNote,
          onJumpToTranscript: onJumpToTranscript,
          onExcludeBulletAnchor: onExcludeBulletAnchor
        )
      }

      ForEach(Array(topic.visualizations.enumerated()), id: \.offset) { _, visualization in
        visualization.makeView(onJumpToTranscript: onJumpToTranscript)
      }

      ForEach(topic.revisions) { revision in
        RevisionTraceView(
          revision: revision,
          onJumpToTranscript: onJumpToTranscript
        )
      }

      ForEach(topic.disagreements) { disagreement in
        DisagreementTraceView(
          disagreement: disagreement,
          onJumpToTranscript: onJumpToTranscript
        )
      }
    }
  }
}

extension Tokens.CardTier {
  /// 层级进标识:断言直接区分「末张 focus / 旧卡 calm / 留痕 standard」。
  fileprivate var accessibilityID: String {
    switch self {
    case .standard: return "dashboard.topic-card"
    case .focus: return "dashboard.topic-card.focus"
    case .calm: return "dashboard.topic-card.calm"
    }
  }
}

private struct BulletRow: View {
  let bullet: SummaryBullet
  let fontSize: CGFloat
  var textColor: Color = Tokens.Color.ink2
  let isSourceOpen: Bool
  let onToggleSource: () -> Void
  let onSaveSourceAsNote: ((SummarySourceReference) -> Void)?
  let onJumpToTranscript: (TimeInterval) -> Void
  /// bullet 右键排除(08-14):回调 `sourceRef.transcriptAnchor`;无锚点的
  /// bullet 不出这个菜单项——锚不到时间轴的排除区间是瞎排。
  var onExcludeBulletAnchor: ((TimeInterval) -> Void)? = nil
  @State private var isRevisionExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      HStack(alignment: .top, spacing: Tokens.Spacing.xsm) {
        Circle()
          .fill(Tokens.Color.ink4)
          .frame(width: 4, height: 4)
          .padding(.top, Tokens.Spacing.xs)
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
          WrappingBulletText(
            bullet: bullet,
            fontSize: fontSize,
            textColor: textColor,
            isSourceOpen: isSourceOpen,
            onToggleSource: onToggleSource,
            onSaveSourceAsNote: onSaveSourceAsNote,
            onJumpToTranscript: onJumpToTranscript
          )
          HStack(spacing: Tokens.Spacing.xxs) {
            ForEach(bullet.annotations) { annotation in
              HStack(spacing: Tokens.Spacing.hairline) {
                SummaryMarkerBadge(kind: annotation.kind, label: annotation.label)
                TranscriptAnchorButton(
                  anchor: annotation.anchor,
                  onJump: onJumpToTranscript
                )
              }
            }
            if let revision = bullet.revision {
              RevisionDisclosureButton(
                revision: revision,
                isExpanded: $isRevisionExpanded
              )
            }
          }
        }
      }

      if isRevisionExpanded, let revision = bullet.revision {
        RevisionTraceView(
          revision: revision,
          onJumpToTranscript: onJumpToTranscript
        )
        .padding(.leading, Tokens.Spacing.smd)
      }
      if let disagreement = bullet.disagreement {
        DisagreementTraceView(
          disagreement: disagreement,
          onJumpToTranscript: onJumpToTranscript
        )
        .padding(.leading, Tokens.Spacing.smd)
      }
    }
    .contextMenu {
      if let onExcludeBulletAnchor, let anchor = bullet.sourceRef?.transcriptAnchor {
        Button("这段是闲聊，排除") {
          onExcludeBulletAnchor(anchor)
        }
      }
    }
  }
}

/// 要点文本 + 行内「来自」溯源标签；标签本身用 `.popover` 承载溯源内容。
private struct WrappingBulletText: View {
  let bullet: SummaryBullet
  let fontSize: CGFloat
  var textColor: Color = Tokens.Color.ink2
  let isSourceOpen: Bool
  let onToggleSource: () -> Void
  let onSaveSourceAsNote: ((SummarySourceReference) -> Void)?
  let onJumpToTranscript: (TimeInterval) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      RichText(bullet.text)
        .font(.system(size: fontSize))
        .foregroundStyle(textColor)
        .fixedSize(horizontal: false, vertical: true)
      if let sourceRef = bullet.sourceRef {
        Button(action: onToggleSource) {
          SourceTagLabel(isActive: isSourceOpen)
        }
        .buttonStyle(.plain)
        .padding(.leading, Tokens.Spacing.xxs)
        .popover(isPresented: sourcePopoverBinding, arrowEdge: .trailing) {
          SourcePopoverView(
            reference: sourceRef,
            onSaveAsNote: onSaveSourceAsNote.map { saveSourceAsNote in
              {
                saveSourceAsNote(sourceRef)
                onToggleSource()
              }
            },
            onJumpToTranscript: {
              onJumpToTranscript(sourceRef.transcriptAnchor)
              onToggleSource()
            }
          )
        }
        .accessibilityLabel("来自转写，展开查看原文")
      }
    }
  }

  private var sourcePopoverBinding: Binding<Bool> {
    Binding(get: { isSourceOpen }, set: { newValue in if !newValue { onToggleSource() } })
  }
}

struct SummaryMarkerBadge: View {
  let kind: SummaryAnnotationKind
  var label: String?
  /// 可点徽标(修订展开)在悬停时描边微亮;不可点场景保持 false 零成本。
  var isHovering: Bool = false

  private var appearance: (text: String, foreground: Color, background: Color) {
    switch kind {
    case .highlight:
      return (label ?? "★ 重点", Tokens.Color.warn, Tokens.Color.amber)
    case .disagreement:
      return (
        label ?? "⚑ 分歧",
        Tokens.V1.Color.disagreement,
        Tokens.V1.Color.disagreementSoft
      )
    case .convergence:
      return (label ?? "✓ 已收敛", Tokens.Color.resolved, Tokens.Color.resolvedSoft)
    case .revision:
      return (label ?? "✎ 已修正", Tokens.Color.revision, Tokens.Color.revisionSoft)
    case .inProgress:
      return (label ?? "● 进行中", Tokens.Color.ac, Tokens.Color.acSoft)
    case .toVerify:
      return (label ?? "[待核]", Tokens.Color.warn, Tokens.Color.amber)
    }
  }

  /// P3 徽章权重分级(用户拍板原型 08-驾驶舱卡片层级-v1):★⚑[待核] 保软底
  /// (需要行动),✓✎● 降描边款(只是状态)——扫屏时不再五个色块抢注意力。
  private var usesOutlineChrome: Bool {
    switch kind {
    case .convergence, .revision, .inProgress:
      return true
    case .highlight, .disagreement, .toVerify:
      return false
    }
  }

  var body: some View {
    Text(appearance.text)
      .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
      .foregroundStyle(usesOutlineChrome ? Tokens.Color.ink3 : appearance.foreground)
      .padding(.horizontal, Tokens.Spacing.xs)
      .padding(.vertical, Tokens.Spacing.hairline)
      .background(usesOutlineChrome ? Color.clear : appearance.background)
      .overlay(
        Capsule().stroke(
          usesOutlineChrome
            ? (isHovering ? Tokens.Color.ink2 : Tokens.Color.line)
            : appearance.foreground.opacity(isHovering ? 0.55 : 0),
          lineWidth: 1
        )
      )
      .clipShape(Capsule())
  }
}

struct RevisionDisclosureButton: View {
  let revision: SummaryRevisionTrace
  @Binding var isExpanded: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      SummaryMarkerBadge(
        kind: .revision,
        label: revision.revisedAt.map { "已修正 · \($0.timecode)" },
        isHovering: isHovering
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
    .accessibilityLabel("展开修订原说法")
  }
}

struct RevisionTraceView: View {
  let revision: SummaryRevisionTrace
  let onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      HStack(spacing: Tokens.Spacing.xxs) {
        SummaryMarkerBadge(
          kind: .revision,
          label: revision.revisedAt.map { "已修正 · \($0.timecode)" }
        )
        TranscriptAnchorButton(
          anchor: revision.revisedAt,
          onJump: onJumpToTranscript
        )
        if let reason = revision.reason, !reason.isEmpty {
          Text(reason)
            .font(.system(size: textScale.size(Tokens.FontSize.badge)))
            .foregroundStyle(Tokens.Color.revision)
        }
      }
      Text("原说法：\(revision.originalText)")
        .font(.system(size: textScale.size(Tokens.FontSize.secondary)))
        .foregroundStyle(Tokens.Color.ink3)
        .strikethrough()
    }
    .padding(.horizontal, Tokens.Spacing.xsm)
    .padding(.vertical, Tokens.Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tokens.Color.revisionSoft)
    .overlay(alignment: .leading) {
      Rectangle().fill(Tokens.Color.revision).frame(width: 2)
    }
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge))
  }
}

struct DisagreementTraceView: View {
  let disagreement: SummaryDisagreement
  let onJumpToTranscript: ((TimeInterval) -> Void)?
  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      SummaryMarkerBadge(
        kind: disagreement.status == .resolved ? .convergence : .disagreement
      )
      ForEach(disagreement.positions) { position in
        HStack(alignment: .top, spacing: Tokens.Spacing.xxs) {
          Text(position.speaker)
            .font(.system(size: textScale.size(Tokens.FontSize.caption), weight: .semibold))
            .foregroundStyle(Tokens.Color.ink2)
          Text(position.text)
            .font(.system(size: textScale.size(Tokens.FontSize.secondary)))
            .foregroundStyle(Tokens.Color.ink2)
          TranscriptAnchorButton(
            anchor: position.anchor,
            onJump: onJumpToTranscript
          )
        }
      }
      if let resolution = disagreement.resolution, !resolution.isEmpty {
        HStack(spacing: Tokens.Spacing.xxs) {
          Text("收敛：\(resolution)")
            .font(.system(size: textScale.size(Tokens.FontSize.secondary), weight: .medium))
            .foregroundStyle(Tokens.Color.resolved)
          TranscriptAnchorButton(
            anchor: disagreement.resolvedAt,
            onJump: onJumpToTranscript
          )
        }
      }
    }
    .padding(.horizontal, Tokens.Spacing.xsm)
    .padding(.vertical, Tokens.Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      disagreement.status == .resolved
        ? Tokens.Color.resolvedSoft
        : Tokens.V1.Color.disagreementSoft
    )
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge))
  }
}

private struct GeneratingTopicNode: View {
  var showsTopRule = false

  var body: some View {
    // 与话题块同一套内边距(上 8、左右 16、下 12),骨架三行落在纸面上。
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      HStack(spacing: Tokens.Spacing.xsm) {
        Circle()
          .strokeBorder(Tokens.Color.ink4, lineWidth: 2.5)
          .frame(width: 11, height: 11)
        Text("正在归纳新话题…")
          .font(.system(size: Tokens.FontSize.body, weight: .medium))
          .foregroundStyle(Tokens.Color.ink3)
      }
      SkeletonCard()
    }
    .padding(.top, Tokens.V1.Space.xs)
    .padding(.horizontal, Tokens.V1.Space.md)
    .padding(.bottom, Tokens.V1.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) {
      if showsTopRule {
        Rectangle()
          .fill(Tokens.V1.Color.rule)
          .frame(height: Tokens.V1.Size.controlRuleWidth)
      }
    }
    .accessibilityLabel("正在归纳新话题")
  }
}

private struct JumpToLatestButton: View {
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  init(action: @escaping () -> Void) {
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: Tokens.Spacing.xxs) {
        Image(systemName: "arrow.down")
        Text("回到最新")
      }
      .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      .foregroundStyle(Tokens.Color.acDeep)
      .padding(.horizontal, Tokens.Spacing.smd)
      .padding(.vertical, Tokens.Spacing.xxs)
      .background(.thinMaterial, in: Capsule())
      .overlay(
        Capsule().stroke(isHovering ? Tokens.Color.acDeep : Tokens.Color.acLine, lineWidth: 1)
      )
      .tokenShadow(Tokens.Shadow.sh2)
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
    }
    .buttonStyle(.plain)
  }
}

/// 五标注词汇图例卡（2026-08-19）：从整理区常驻头部收进悬停层。
/// 词汇本身不变（★重点/⚑分歧/✓已收敛/✎已修正/●进行中），只换承载位置。
/// 独立类型是为了验证能单独摆一页探针——headless 布局弹不出悬停层。
public struct SummaryMarkerLegendCard: View {
  public init() {}

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      SummaryMarkerBadge(kind: .highlight)
      SummaryMarkerBadge(kind: .disagreement)
      SummaryMarkerBadge(kind: .convergence)
      SummaryMarkerBadge(kind: .revision)
      SummaryMarkerBadge(kind: .inProgress)
    }
    .padding(Tokens.Spacing.smd)
    .cardShell()
    .tokenShadow(Tokens.Shadow.sh2)
    // 浮层锚点是窄小的「图例」按钮；固定为内容理想宽度，避免 overlay
    // 把五枚徽章按锚点提案压成看似空白的卡片。
    .fixedSize(horizontal: true, vertical: true)
    .accessibilityElement(children: .contain)
    .runtimeAccessibilityIdentifier("dashboard.organizer.legend")
  }
}
