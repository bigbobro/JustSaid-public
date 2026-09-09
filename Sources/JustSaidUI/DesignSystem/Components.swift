import AppKit
import SwiftUI

/// SwiftUI's accessibility tree is not materialized by the headless verification executable on
/// every macOS release. Keep the real accessibility identifier and mirror it onto an invisible
/// AppKit view so UIHierarchyVerification can inspect the conditional, rendered subtree.
private struct RuntimeAccessibilityMarker: NSViewRepresentable {
  let identifier: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    configure(view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    configure(nsView)
  }

  private func configure(_ view: NSView) {
    view.identifier = NSUserInterfaceItemIdentifier(identifier)
    view.setAccessibilityElement(false)
  }
}

extension View {
  func runtimeAccessibilityIdentifier(_ identifier: String) -> some View {
    accessibilityIdentifier(identifier)
      .background(
        RuntimeAccessibilityMarker(identifier: identifier)
          .allowsHitTesting(false)
      )
  }
}

/// 降级提示细带（ui-spec §6）：墨黄底 + 可选“重试”，已有内容全部保留不清空。
/// 总结不可用（云端失败）与速记引擎异常共用同一视觉语言，只是挂载位置不同。
struct DegradedBanner: View {
  let text: String
  var retryAction: (() -> Void)?
  /// 「重试」的运行时探针标识。只有真的画出按钮时才挂,验证据此断言
  /// "散会后不存在按下无反应的重试"。
  var retryIdentifier: String?
  /// 没有可点的重试、但确实有一轮正在飞时显示的只读说明（如「重试中…」）。
  var trailingNote: String?

  var body: some View {
    HStack {
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      if let retryAction {
        retryButton(retryAction)
      } else if let trailingNote {
        Text(trailingNote)
          .fontWeight(.semibold)
      }
    }
    .font(.system(size: Tokens.FontSize.uiEmphasis))
    .foregroundStyle(Tokens.Color.warn)
    .padding(.horizontal, Tokens.Spacing.md)
    .padding(.vertical, Tokens.Spacing.xs)
    .background(Tokens.Color.amber)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.Color.amberLine).frame(height: 1)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func retryButton(_ action: @escaping () -> Void) -> some View {
    let button = Button("重试", action: action)
      .buttonStyle(.textAction)
      .fontWeight(.semibold)
    if let retryIdentifier {
      button.runtimeAccessibilityIdentifier(retryIdentifier)
    } else {
      button
    }
  }
}

/// 骨架屏微光：1.5s/轮横扫（ui-spec §4）。开启系统“减弱动态效果”时降级为静态浅灰块。
struct ShimmerLine: View {
  var widthFraction: CGFloat = 1
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var animate = false

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width * widthFraction
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: Tokens.Radius.chip).fill(Tokens.Color.line2)
        if !reduceMotion {
          RoundedRectangle(cornerRadius: Tokens.Radius.chip)
            .fill(
              LinearGradient(
                colors: [.clear, Tokens.Color.shimmer.opacity(0.85), .clear],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: max(width * 0.5, 1))
            .offset(x: animate ? width : -width * 0.5)
        }
      }
      .frame(width: width, alignment: .leading)
      .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip))
    }
    .frame(height: 10)
    .accessibilityHidden(true)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.linear(duration: Tokens.Motion.shimmer).repeatForever(autoreverses: false)) {
        animate = true
      }
    }
  }
}

/// 「正在归纳新话题…」骨架卡片，用于历史区末端表示慢通道正在生成下一个话题块。
struct SkeletonCard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      ShimmerLine(widthFraction: 0.86)
      ShimmerLine(widthFraction: 0.68)
      ShimmerLine(widthFraction: 0.44)
    }
    .padding(.horizontal, Tokens.Spacing.smd)
    .padding(.vertical, Tokens.Spacing.sm)
    .background(Tokens.Color.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.card)
        .stroke(Tokens.Color.line, lineWidth: 1)
    )
    .tokenShadow(Tokens.Shadow.sh1)
  }
}

/// 脉冲圆点：录制中指示灯 / 「当前正在聊」活跃指示灯共用，1.8s ease-in-out。
struct PulsingDot: View {
  var color: Color
  var size: CGFloat = 7
  var haloColor: Color?
  /// false 时画同一颗点但**不呼吸**(2026-08-21 走查 N-5):脉冲的语义是「这里正在发生事情」,
  /// 空闲态还在呼吸就是拿动效撒谎。默认 true = 既有调用点行为不变。
  var isPulsing = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dimmed = false

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: size, height: size)
      .background(alignment: .center) {
        if let haloColor {
          Circle().fill(haloColor).frame(width: size + 7, height: size + 7)
        }
      }
      .opacity(reduceMotion || !isPulsing ? 1 : (dimmed ? 0.3 : 1))
      .onAppear {
        guard !reduceMotion, isPulsing else { return }
        withAnimation(.easeInOut(duration: Tokens.Motion.pulse).repeatForever(autoreverses: true)) {
          dimmed = true
        }
      }
      .accessibilityHidden(true)
  }
}

/// 「AI 分析中」三点呼吸：`Motion.breath` 循环，依次延迟 `Motion.breathStagger`。
struct BreathingDots: View {
  var color: Color = Tokens.Color.ac
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var animate = false

  var body: some View {
    HStack(spacing: Tokens.Spacing.hairline) {
      ForEach(0..<3, id: \.self) { index in
        Circle()
          .fill(color)
          .frame(width: 3.5, height: 3.5)
          .opacity(reduceMotion ? 1 : (animate ? 1 : 0.3))
          .offset(y: reduceMotion ? 0 : (animate ? -2.5 : 0))
          .animation(
            reduceMotion
              ? nil
              : .easeInOut(duration: Tokens.Motion.breath)
                .repeatForever(autoreverses: true)
                .delay(Double(index) * Tokens.Motion.breathStagger),
            value: animate
          )
      }
    }
    .onAppear { animate = true }
    .accessibilityHidden(true)
  }
}

/// 快捷键内联展示（`.kbd`）：等宽字体 + 浅底描边，不写成说明文字。
struct KeycapView: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
      .foregroundStyle(Tokens.Color.ink4)
      .padding(.horizontal, Tokens.Spacing.xxs)
      .padding(.vertical, Tokens.Spacing.hairline)
      .background(
        // P1:键帽是浮在卡片上的最小单元,深色走 surface2 亮一档,不然沉入底里。
        RoundedRectangle(cornerRadius: 4)
          .fill(Tokens.Color.surface2)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(Tokens.Color.surface2Line, lineWidth: 1)
      )
  }
}

/// 工具栏胶囊按钮样式（`.btn` / `.btn.acc`）。
struct ToolbarPillButtonStyle: ButtonStyle {
  var isAccent = false
  /// 录制语义强调档(08-09 R1/R1'''):录制中身处会议库时,「返回驾驶舱」用中性底 +
  /// cue 橙描边/文字 + 流动扫光(周期渐变扫过,传达"回去继续开会")。
  /// 色彩口径:用户拍板不用录制红(过重且与 rec 录制指示语义混淆),也不用 warn
  /// 警示橙,定 Claude 品牌橙 cue;扫光在 Reduce Motion 下退化为静态描边。
  var isRecording = false

  func makeBody(configuration: Configuration) -> some View {
    PillBody(configuration: configuration, isAccent: isAccent, isRecording: isRecording)
  }

  /// 悬停态要存 `@State`，而 `ButtonStyle` 自己不是 `View`、存不住状态——
  /// 所以样式的实体落在这个内嵌视图里。
  ///
  /// 桌面端「能点的东西鼠标扫过去要有反应」是 macOS 的基本礼貌：原先只有按压态，
  /// 移上去毫无动静，一排胶囊看着像标签而不是按钮。
  private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let isAccent: Bool
    let isRecording: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// 禁用态（「正在启动…」「正在保存…」）不给悬停反馈：它不可点，亮起来是撒谎。
    private var isHighlighted: Bool { isHovering && isEnabled }

    private var isEmphasized: Bool { isAccent || isRecording }

    private var fillColor: Color {
      if isAccent {
        return isHighlighted ? Tokens.Color.acHi : Tokens.Color.ac
      }
      // 录制档底色与中性胶囊一致,强调交给描边/文字/扫光(R1' 用户实测:纯红底过重)。
      return isHighlighted ? Tokens.Color.pane : Tokens.Color.card
    }

    private var strokeColor: Color {
      if isRecording {
        return Tokens.Color.cue
      }
      if isAccent {
        return Tokens.Color.acDeep
      }
      return isHighlighted ? Tokens.Color.hoverStroke : Tokens.Color.line
    }

    private var labelColor: Color {
      if isAccent {
        return Tokens.Color.onAccent
      }
      if isRecording {
        return Tokens.Color.cue
      }
      return Tokens.Color.ink2
    }

    var body: some View {
      configuration.label
        .opacity(isEnabled ? 1 : 0.45)
        .font(
          .system(size: Tokens.FontSize.uiEmphasis, weight: isEmphasized ? .semibold : .regular)
        )
        .foregroundStyle(labelColor)
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, Tokens.Spacing.xxs)
        .background(
          RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .fill(fillColor)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .stroke(strokeColor, lineWidth: 1)
        )
        .overlay {
          // 流动扫光:cue 橙渐变带 1.4s 扫过一次(带宽 0.7,峰值 0.45)。
          // 用 TimelineView 驱动:ButtonStyle 内嵌视图的 onAppear+withAnimation 会被
          // 首次渲染事务吞掉(实测不动),TimelineView 只要可见就持续走帧,没有这个坑。
          // Reduce Motion 下不挂这层,保留静态橙描边/橙字。
          if isRecording && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
              let period: TimeInterval = Tokens.Motion.sweep
              let phase =
                context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
              // 扫光带从胶囊左外(-0.7)匀速移向右外(1.0):带尾出界即一轮结束。
              let leading = -0.7 + phase * 1.7
              RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(
                  LinearGradient(
                    colors: [.clear, Tokens.Color.cue.opacity(0.45), .clear],
                    startPoint: UnitPoint(x: leading, y: 0.5),
                    endPoint: UnitPoint(x: leading + 0.7, y: 0.5)
                  )
                )
                .allowsHitTesting(false)
            }
          }
        }
        .opacity(configuration.isPressed ? 0.7 : 1)
        .tokenShadow(Tokens.Shadow.sh1)
        .onHover { isHovering = $0 }
        .animation(
          reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHighlighted)
    }
  }
}

extension ButtonStyle where Self == ToolbarPillButtonStyle {
  static var toolbarPill: ToolbarPillButtonStyle { ToolbarPillButtonStyle() }
  static var toolbarPillAccent: ToolbarPillButtonStyle { ToolbarPillButtonStyle(isAccent: true) }
  static var toolbarPillRecording: ToolbarPillButtonStyle {
    ToolbarPillButtonStyle(isRecording: true)
  }
}

/// 纯文字动作按钮的悬停态:没有描边 chrome 的文字按钮(横幅动作、行内「重试」)
/// 扫过加下划线,120ms easeOut,按压降不透明度——下划线不增布局尺寸,
/// 横幅高度断言不受影响。与 ToolbarPillButtonStyle 分工:有 chrome 的用 toolbarPill,
/// 纯文字的用这个。
struct TextActionHoverStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverBody(configuration: configuration)
  }

  private struct HoverBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isHighlighted: Bool { isHovering && isEnabled }

    var body: some View {
      configuration.label
        // 批4:自定义样式没有系统置灰,禁用态用不透明度表达(原 .bordered 的系统行为等价)。
        .opacity(isEnabled ? 1 : 0.45)
        .underline(isHighlighted)
        .opacity(configuration.isPressed ? 0.7 : 1)
        .onHover { isHovering = $0 }
        .animation(
          reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHighlighted)
    }
  }
}

extension ButtonStyle where Self == TextActionHoverStyle {
  static var textAction: TextActionHoverStyle { TextActionHoverStyle() }
}

/// 图标按钮悬停态:扫过颜色加深一档(ink3→ink,DictionarySettingsView 手写先例的
/// 组件化),120ms easeOut;禁用态不加亮——不可点的东西亮起来是撒谎。
struct IconHoverButtonStyle: ButtonStyle {
  var base: Color = Tokens.Color.ink3
  var hover: Color = Tokens.Color.ink

  func makeBody(configuration: Configuration) -> some View {
    HoverBody(configuration: configuration, base: base, hover: hover)
  }

  private struct HoverBody: View {
    let configuration: ButtonStyleConfiguration
    let base: Color
    let hover: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isHighlighted: Bool { isHovering && isEnabled }

    var body: some View {
      configuration.label
        .opacity(isEnabled ? 1 : 0.45)
        .foregroundStyle(isHighlighted ? hover : base)
        .opacity(configuration.isPressed ? 0.7 : 1)
        .onHover { isHovering = $0 }
        .animation(
          reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHighlighted)
    }
  }
}

extension ButtonStyle where Self == IconHoverButtonStyle {
  static var iconHover: IconHoverButtonStyle { IconHoverButtonStyle() }
}

/// 行级悬停底洗(列表行/目录行):扫过铺一层 line2 底,120ms easeOut。
/// 只加背景、不动内容布局;行内 padding 由行自己持有。
private struct HoverRowBackgroundModifier: ViewModifier {
  var cornerRadius: CGFloat = Tokens.Radius.widget

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(isHovering ? Tokens.Color.line2 : .clear)
      )
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
  }
}

extension View {
  func hoverRowBackground(cornerRadius: CGFloat = Tokens.Radius.widget) -> some View {
    modifier(HoverRowBackgroundModifier(cornerRadius: cornerRadius))
  }
}

/// 悬停描边(自带**不透明底**的小件用,2026-08-21 走查 P-7):扫过在原描边之上再叠一圈
/// `hoverStroke`,120ms easeOut。`hoverRowBackground` 在这类件上看不见——件自己的
/// 不透明底(cardWash / surface2 / acSoft)把行级洗色整个盖住了。
/// 静止态叠的是 `Color.clear`,不改任何像素。
private struct HoverStrokeOutlineModifier: ViewModifier {
  var cornerRadius: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius)
          .stroke(isHovering ? Tokens.Color.hoverStroke : Color.clear, lineWidth: 1)
      )
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
  }
}

extension View {
  func hoverStrokeOutline(cornerRadius: CGFloat = Tokens.Radius.control) -> some View {
    modifier(HoverStrokeOutlineModifier(cornerRadius: cornerRadius))
  }
}

public enum HorizontalOverflowGeometry {
  public static let minimumThumbWidth: CGFloat = 36

  public static func clampedOffset(_ offset: CGFloat, maxOffset: CGFloat) -> CGFloat {
    min(maxOffset, max(0, offset))
  }

  public static func thumbWidth(
    trackWidth: CGFloat,
    containerWidth: CGFloat,
    contentWidth: CGFloat
  ) -> CGFloat {
    let ratio = contentWidth > 0 ? min(1, max(0.12, containerWidth / contentWidth)) : 1
    return min(trackWidth, max(minimumThumbWidth, trackWidth * ratio))
  }

  public static func dragTarget(
    location: CGFloat,
    thumbWidth: CGFloat,
    trackWidth: CGFloat,
    maxOffset: CGFloat
  ) -> CGFloat {
    let travel = max(0, trackWidth - thumbWidth)
    guard travel > 0 else { return 0 }
    let progress = (location - thumbWidth / 2) / travel
    return maxOffset * min(1, max(0, progress))
  }

  public static func pageTarget(
    offset: CGFloat,
    maxOffset: CGFloat,
    containerWidth: CGFloat,
    direction: CGFloat
  ) -> CGFloat {
    let page = max(minimumThumbWidth, containerWidth * 0.8)
    return clampedOffset(offset + direction * page, maxOffset: maxOffset)
  }
}

/// 应用拥有的局部横向溢出视口。系统滚动条仍关闭，但只有内容真正超出容器时才显示
/// 可拖动、可点击且可辅助功能定位的轨道；渐隐只是轨道出现前的次级提示。
struct HorizontalOverflowViewport<Content: View>: View {

  private struct Metrics: Equatable {
    var contentWidth: CGFloat = 0
    var containerWidth: CGFloat = 0
    var offset: CGFloat = 0

    var maxOffset: CGFloat { max(0, contentWidth - containerWidth) }
    var hasOverflow: Bool { maxOffset > 1 }
  }

  let identifier: String
  let fadeColor: Color
  @ViewBuilder let content: () -> Content

  @State private var position = ScrollPosition()
  @State private var metrics = Metrics()

  init(
    identifier: String,
    fadeColor: Color = Tokens.Color.cardWash,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.identifier = identifier
    self.fadeColor = fadeColor
    self.content = content
  }

  var body: some View {
    VStack(spacing: Tokens.Spacing.xxs) {
      ScrollView(.horizontal, showsIndicators: false) {
        content()
          .fixedSize(horizontal: true, vertical: false)
      }
      .scrollPosition($position)
      .onScrollGeometryChange(for: Metrics.self) { geometry in
        Metrics(
          contentWidth: geometry.contentSize.width,
          containerWidth: geometry.containerSize.width,
          offset: geometry.contentOffset.x
        )
      } action: { _, newMetrics in
        updateMetrics(newMetrics)
      }
      .overlay(alignment: .trailing) {
        if metrics.hasOverflow && metrics.offset < metrics.maxOffset - 1 {
          LinearGradient(
            colors: [fadeColor.opacity(0), fadeColor],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: Tokens.Spacing.xl)
          .allowsHitTesting(false)
        }
      }
      if metrics.hasOverflow {
        overflowRail
      }
    }
    .runtimeAccessibilityIdentifier(identifier)
  }

  private var overflowRail: some View {
    GeometryReader { proxy in
      let trackWidth = max(
        HorizontalOverflowGeometry.minimumThumbWidth,
        proxy.size.width - Tokens.Spacing.xs * 2
      )
      let thumbWidth = HorizontalOverflowGeometry.thumbWidth(
        trackWidth: trackWidth,
        containerWidth: metrics.containerWidth,
        contentWidth: metrics.contentWidth
      )
      let travel = max(0, trackWidth - thumbWidth)
      let thumbOffset =
        metrics.maxOffset > 0
        ? travel * min(1, max(0, metrics.offset / metrics.maxOffset))
        : 0
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Tokens.Color.line2)
          .accessibilityHidden(true)
        Capsule()
          .fill(Tokens.Color.ac)
          .frame(width: thumbWidth)
          .offset(x: thumbOffset)
          .runtimeAccessibilityIdentifier("\(identifier).thumb")
      }
      .frame(width: trackWidth, height: 6)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let target =
              HorizontalOverflowGeometry.dragTarget(
                location: value.location.x,
                thumbWidth: thumbWidth,
                trackWidth: trackWidth,
                maxOffset: metrics.maxOffset
              )
            position.scrollTo(x: target)
          }
      )
      .padding(.horizontal, Tokens.Spacing.xs)
      .padding(.vertical, Tokens.Spacing.hairline)
      .background(fadeColor.opacity(0.92), in: Capsule())
      .runtimeAccessibilityIdentifier("\(identifier).rail")
      .focusable()
      .onMoveCommand { direction in
        switch direction {
        case .left: movePage(by: -1)
        case .right: movePage(by: 1)
        default: break
        }
      }
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: movePage(by: 1)
        case .decrement: movePage(by: -1)
        @unknown default: break
        }
      }
    }
    .frame(height: 12)
    .accessibilityLabel("横向内容滚动轨道")
    .accessibilityValue(
      metrics.maxOffset > 0
        ? "\(Int((metrics.offset / metrics.maxOffset) * 100))%"
        : "0%"
    )
  }

  private func updateMetrics(_ newMetrics: Metrics) {
    metrics = newMetrics
    let clampedOffset = HorizontalOverflowGeometry.clampedOffset(
      newMetrics.offset,
      maxOffset: newMetrics.maxOffset
    )
    if abs(newMetrics.offset - clampedOffset) > 1 {
      position.scrollTo(x: clampedOffset)
    }
  }

  private func movePage(by direction: CGFloat) {
    let target = HorizontalOverflowGeometry.pageTarget(
      offset: metrics.offset,
      maxOffset: metrics.maxOffset,
      containerWidth: metrics.containerWidth,
      direction: direction
    )
    position.scrollTo(x: target)
  }
}

/// 「来自」溯源标签（`.src` / `.src.on`）。
struct SourceTagLabel: View {
  var isActive: Bool = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  /// 已展开时描边本就是强调色，不再叠悬停；未展开时鼠标扫过描边微亮，
  /// 告诉用户「这个小标签是能点开看原文的」。
  private var strokeColor: Color {
    if isActive {
      return Tokens.Color.acLine
    }
    return isHovering ? Tokens.Color.hoverStroke : Tokens.Color.line
  }

  var body: some View {
    HStack(spacing: Tokens.Spacing.hairline) {
      Text(isActive ? "来自 · 溯源" : "来自")
      Image(systemName: "arrow.up.right")
        .font(.system(size: Tokens.FontSize.glyphMicro, weight: .bold))
    }
    .font(.system(size: Tokens.FontSize.badge, weight: isActive ? .semibold : .regular))
    .foregroundStyle(isActive ? Tokens.Color.ac : Tokens.Color.ink4)
    .padding(.horizontal, Tokens.Spacing.xxs)
    .padding(.vertical, Tokens.Spacing.hairline)
    .background(
      Capsule().fill(isActive ? Tokens.Color.acSoft : Color.clear)
    )
    .overlay(
      Capsule().stroke(strokeColor, lineWidth: 1)
    )
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
  }
}

/// 「图表」章节标记（`.vzt`）。
struct ChapterVisualizationTag: View {
  var body: some View {
    Text("图表")
      .font(.system(size: Tokens.FontSize.micro, weight: .semibold))
      .foregroundStyle(Tokens.Color.ac)
      .padding(.horizontal, Tokens.Spacing.xxs)
      .background(Tokens.Color.acSoft)
      .overlay(RoundedRectangle(cornerRadius: 3).stroke(Tokens.Color.acLine, lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 3))
  }
}

/// 转写锚点 chip:时钟 SF Symbol + 时间码——「⏱」文本字符的组件化替代
/// (图标一律 SF Symbol 纪律)。悬停描边微亮/色深一档,120ms easeOut;
/// chromeless 变体用于会后笔记行内(无底无框)。
struct TranscriptAnchorChip: View {
  let label: String
  var fontSize: CGFloat = Tokens.FontSize.badge
  var weight: Font.Weight = .medium
  var chromeless = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Tokens.Spacing.xxs) {
      Image(systemName: "clock")
        .font(.system(size: max(fontSize - 1, 1), weight: .semibold))
        .accessibilityHidden(true)
      Text(label)
    }
    .font(.system(size: fontSize, weight: weight, design: .monospaced))
    .foregroundStyle(isHovering ? Tokens.Color.acDeep : Tokens.Color.ac)
    .padding(.horizontal, chromeless ? 0 : Tokens.Spacing.xxs)
    .padding(.vertical, chromeless ? 0 : Tokens.Spacing.hairline)
    .background(chromeless ? Color.clear : Tokens.Color.acSoft)
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.chip)
        .stroke(isHovering && !chromeless ? Tokens.Color.acLine : Color.clear, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip))
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
  }
}

/// 状态胶囊徽章(2026-08-20 批2 收编:库三个同构手写徽章的公共结构)。
/// 语义色由调用方给;描边统一 0.45 半透(收敛此前 0.4/0.45 两种手写 alpha);
/// 需要垫底的(完备度徽章)传 fill,纯描边的不传。
public struct StatusCapsuleBadge: View {
  public let label: String
  public let color: Color
  public var fontSize: CGFloat = Tokens.FontSize.secondary
  public var fill: Color?

  public init(
    label: String,
    color: Color,
    fontSize: CGFloat? = nil,
    fill: Color? = nil
  ) {
    self.label = label
    self.color = color
    self.fontSize = fontSize ?? Tokens.FontSize.secondary
    self.fill = fill
  }

  public var body: some View {
    Text(label)
      .font(.system(size: fontSize, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, Tokens.Spacing.xsm)
      .padding(.vertical, Tokens.Spacing.hairline)
      .background {
        if let fill {
          Capsule().fill(fill)
        }
      }
      .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
  }
}

/// 区块计数徽章(2026-08-21 批5):9.5 bold acSoft 胶囊,全 app 同画法。
/// `quiet` 给「空」一类非数字标记,几何同、色降到 ink4/cardWash。
struct SectionCountBadge: View {
  let label: String
  var quiet: Bool = false

  init(value: Int) {
    self.label = "\(value)"
    self.quiet = false
  }

  init(label: String, quiet: Bool = false) {
    self.label = label
    self.quiet = quiet
  }

  var body: some View {
    Text(label)
      .font(.system(size: Tokens.FontSize.badge, weight: .bold))
      .foregroundStyle(quiet ? Tokens.Color.ink4 : Tokens.Color.acDeep)
      .padding(.horizontal, Tokens.Spacing.xxs)
      .padding(.vertical, Tokens.Spacing.hairline)
      .background(
        Capsule().fill(quiet ? Tokens.Color.cardWash : Tokens.Color.acSoft)
      )
      .overlay(
        Capsule().stroke(quiet ? Tokens.Color.line : Tokens.Color.acLine, lineWidth: 1)
      )
  }
}

/// 区块头(2026-08-21 批5):11 semibold ink3,chrome 不跟 textScale。
struct SectionHeaderRow: View {
  let title: String
  var count: Int? = nil
  var subtitle: String? = nil
  var subtitleIdentifier: String? = nil

  var body: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      Text(title)
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink3)
      if let count {
        SectionCountBadge(value: count)
      }
      if let subtitle, !subtitle.isEmpty {
        Spacer(minLength: 0)
        Text(subtitle)
          .font(.system(size: Tokens.FontSize.caption))
          .foregroundStyle(Tokens.Color.ink4)
          .modifier(OptionalIdentifier(subtitleIdentifier))
      }
    }
  }
}

private struct OptionalIdentifier: ViewModifier {
  let identifier: String?
  init(_ identifier: String?) { self.identifier = identifier }
  func body(content: Content) -> some View {
    if let identifier {
      content.runtimeAccessibilityIdentifier(identifier)
    } else {
      content
    }
  }
}

/// 小号轮廓动作钮(2026-08-20 批2 收编:转写抽屉「关闭/折叠」两份手写复制)。
/// 图标+文字、chip 圆角描边、悬停加深(120ms easeOut,Reduce Motion 兜底),悬停态自持。
public struct OutlineActionButton: View {
  public let icon: String
  public let title: String
  public var keyboardShortcut: KeyboardShortcut?
  public let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  public init(
    icon: String,
    title: String,
    keyboardShortcut: KeyboardShortcut? = nil,
    action: @escaping () -> Void
  ) {
    self.icon = icon
    self.title = title
    self.keyboardShortcut = keyboardShortcut
    self.action = action
  }

  public var body: some View {
    let button = Button(action: action) {
      HStack(spacing: Tokens.Spacing.xxs) {
        Image(systemName: icon)
          .accessibilityHidden(true)
        Text(title)
      }
      .font(.system(size: Tokens.FontSize.secondary))
      .foregroundStyle(isHovering ? Tokens.Color.ink2 : Tokens.Color.ink4)
      .padding(.horizontal, Tokens.Spacing.xxs)
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.chip)
          .stroke(
            isHovering ? Tokens.Color.hoverStroke : Tokens.Color.line,
            lineWidth: 1
          )
      )
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
    }
    .buttonStyle(.plain)

    if let keyboardShortcut {
      button.keyboardShortcut(keyboardShortcut)
    } else {
      button
    }
  }
}

/// 缩略窗胶囊按钮样式(2026-08-20 批2 由 CompactOverlayView 本地实现并入组件库,
/// 与 toolbarPill 家族同一悬停纪律:0.12s easeOut、Reduce Motion 不动画)。
/// 强调款(标记)悬停软底加深一档;素款悬停从透明底浮出面板底,
/// 让 .ultraThinMaterial 上的描边框读作「能点的按钮」而不是标签。
public struct CompactPillButtonStyle: ButtonStyle {
  public var isAccent = false

  public init(isAccent: Bool = false) {
    self.isAccent = isAccent
  }

  public func makeBody(configuration: Configuration) -> some View {
    PillBody(configuration: configuration, isAccent: isAccent)
  }

  private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let isAccent: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var fillColor: Color {
      if isAccent {
        return isHovering ? Tokens.Color.washMark : Tokens.Color.acSoft
      }
      return isHovering ? Tokens.Color.pane : Color.clear
    }

    private var strokeColor: Color {
      if isAccent {
        return isHovering ? Tokens.Color.acHi : Tokens.Color.acLine
      }
      return isHovering ? Tokens.Color.hoverStroke : Tokens.Color.line
    }

    var body: some View {
      configuration.label
        .opacity(isEnabled ? 1 : 0.45)
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, Tokens.Spacing.xxs)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(fillColor))
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(strokeColor, lineWidth: 1)
        )
        .opacity(configuration.isPressed ? 0.7 : 1)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
    }
  }
}

extension ButtonStyle where Self == CompactPillButtonStyle {
  /// 缩略窗素款胶囊。
  public static var compactPill: CompactPillButtonStyle { CompactPillButtonStyle() }
  /// 缩略窗强调款胶囊(标记重点)。
  public static var compactPillAccent: CompactPillButtonStyle {
    CompactPillButtonStyle(isAccent: true)
  }
}

extension View {
  /// surface2 输入井/嵌板(2026-08-20 批2 收编三处同形手写:control 圆角 surface2 底 + surface2Line 描边)。
  public func insetPanel() -> some View {
    background(RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(Tokens.Color.surface2))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(
          Tokens.Color.surface2Line, lineWidth: 1)
      )
  }

  /// 卡片外壳(批2 收编同形手写:card 底 + card 圆角 + line 描边;阴影语义各站点自带)。
  public func cardShell() -> some View {
    background(Tokens.Color.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.card).stroke(Tokens.Color.line, lineWidth: 1)
      )
  }
}
