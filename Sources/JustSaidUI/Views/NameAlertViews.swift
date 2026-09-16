import JustSaidCore
import SwiftUI

// MARK: - 名字区(C)

/// 点名名字区:差异色块里放「有人叫你」与名字,「知道了」在色块外独立一列。
/// 按钮闭包捕获渲染时的事件 id,点击时不会确认后来到达的新事件。
struct NameAlertNameRow: View {
  let event: NameAlertEvent
  let onAcknowledge: (NameAlertEvent.ID) -> Void

  var body: some View {
    let eventID = event.id
    HStack(spacing: Tokens.Spacing.sm) {
      HStack(spacing: Tokens.Spacing.xs) {
        Image(systemName: "bell.fill")
          .font(.system(size: Tokens.FontSize.caption, weight: .semibold))
          .foregroundStyle(Tokens.Color.ac)
          .accessibilityHidden(true)
        Text("有人叫你")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.acDeep)
          .fixedSize()
        Text(event.aliasText)
          .font(.system(size: Tokens.FontSize.headingSmall, weight: .bold))
          .foregroundStyle(Tokens.Color.ink)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(event.aliasText)
          .runtimeAccessibilityIdentifier("name-alert.name")
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Tokens.Spacing.sm)
      .padding(.vertical, Tokens.Spacing.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Tokens.Color.acSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.control)
          .stroke(Tokens.Color.acLine, lineWidth: 1)
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel("有人叫你：\(event.aliasText)")

      Button {
        onAcknowledge(eventID)
      } label: {
        Text("知道了")
          .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .bold))
          .foregroundStyle(Tokens.Color.acDeep)
      }
      .buttonStyle(.compactPillAccent)
      .fixedSize()
      .accessibilityLabel("知道了，确认这次点名")
      .runtimeAccessibilityIdentifier("name-alert.acknowledge")
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - 纵向卡片名字区(C)

/// 悬浮卡片与独立强提醒共用的 C 名字区:「有人叫你」与名字上下排,「知道了」独立在右;
/// 长名字最多两行后省略。按钮闭包捕获渲染时的事件 id,不会确认后来到达的新事件。
struct NameAlertNameZone: View {
  let event: NameAlertEvent
  let onAcknowledge: (NameAlertEvent.ID) -> Void

  var body: some View {
    let eventID = event.id
    HStack(alignment: .center, spacing: Tokens.Spacing.xl) {
      VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
        Text("有人叫你")
          .font(.system(size: Tokens.FontSize.ui, weight: .medium))
          .foregroundStyle(Tokens.Color.acDeep)
        Text(event.aliasText)
          .font(.system(size: Tokens.FontSize.headline, weight: .bold))
          .foregroundStyle(Tokens.Color.ink)
          .lineLimit(2)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: true)
          .help(event.aliasText)
          .runtimeAccessibilityIdentifier("name-alert.name")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("有人叫你：\(event.aliasText)")

      Button {
        onAcknowledge(eventID)
      } label: {
        Text("知道了")
          .padding(.horizontal, Tokens.Spacing.xxs)
          .padding(.vertical, Tokens.Spacing.hairline)
      }
      .buttonStyle(AcknowledgeButtonStyle())
      .fixedSize()
      .accessibilityLabel("知道了，确认这次点名")
      .runtimeAccessibilityIdentifier("name-alert.acknowledge")
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// 「知道了」深青实底白字(已确认 C):浅色取 acDeep、深色取浅色档 ac,两种外观下白字都够对比;
/// 悬停提亮一档,与组件库胶囊同一悬停纪律(0.12s easeOut、减少动态效果不动画)。
private struct AcknowledgeButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    AcknowledgeBody(configuration: configuration)
  }

  private struct AcknowledgeBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
        .foregroundStyle(Tokens.Color.onAccent)
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, Tokens.Spacing.xxs)
        .background(
          RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .fill(
              isHovering
                ? Color(light: 0x0f76_6e, dark: 0x1486_7d)
                : Color(light: 0x0b5d_57, dark: 0x0f76_6e))
        )
        .opacity(configuration.isPressed ? 0.75 : 1)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
    }
  }
}

// MARK: - 独立强提醒

/// 后台强提醒卡:只有名字与「知道了」,不含摘要、不超时、不抢焦点。与卡片同一套亮边与高光;
/// 卡片只在有未确认点名时存在,确认后由面板淡出。
struct NameAlertStrongCard: View {
  let event: NameAlertEvent
  let onAcknowledge: (NameAlertEvent.ID) -> Void

  var body: some View {
    HStack(spacing: Tokens.Spacing.md) {
      Image(systemName: "bell.fill")
        .font(.system(size: Tokens.FontSize.displaySmall, weight: .semibold))
        .foregroundStyle(Tokens.Color.ac)
        .frame(width: 42, height: 42)
        .background(Tokens.Color.acSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .accessibilityHidden(true)
      NameAlertNameZone(event: event, onAcknowledge: onAcknowledge)
    }
    .padding(Tokens.Spacing.lg)
    .frame(width: MeetingPresenceMetrics.strongCardWidth, alignment: .leading)
    .background(Tokens.Color.card)
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.compactPanel))
    .overlay { PresenceCardRim(isPending: true) }
    .runtimeAccessibilityIdentifier("name-alert.strong-card")
  }
}

enum MeetingPresenceMetrics {
  static let strongCardWidth: CGFloat = Tokens.Layout.compactOverlayWidth
}

// MARK: - 点名亮边与慢速高光

private struct PresenceDecorationActiveKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// 承载它的悬浮面板此刻是否在屏上。false(隐藏、会议结束、非面板宿主)时高光与声波不走帧。
  var presenceDecorationActive: Bool {
    get { self[PresenceDecorationActiveKey.self] }
    set { self[PresenceDecorationActiveKey.self] = newValue }
  }
}

/// 高光沿轮廓行进的相位与颜色(已确认 B 亮边的淡薄荷白与青色柔光)。
enum PresenceHighlight {
  /// 高光段占轮廓全长的比例。
  static let segment: CGFloat = 0.18
  static let rim = Color(red: 220 / 255, green: 252 / 255, blue: 245 / 255)
  static let glow = Color(red: 95 / 255, green: 208 / 255, blue: 196 / 255)
  static let head = Color(red: 229 / 255, green: 1, blue: 248 / 255)

  /// 亮度/淡入淡出过渡:减少动态效果时只保留短淡入淡出。
  static func fade(reduceMotion: Bool) -> Animation {
    .easeInOut(
      duration: reduceMotion
        ? Tokens.Motion.presenceReducedFade : Tokens.Motion.presenceTransition)
  }

  static func phase(at date: Date) -> CGFloat {
    let period = Tokens.Motion.presenceHighlight
    return CGFloat(
      date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
  }
}

/// 纵向卡片与强提醒卡轮廓:常态细边;点名时整圈稳定亮边(明暗过渡),其上一段高光约 6s 绕行。
/// 只有面板在屏、存在点名且未开减少动态效果时才走帧;减少动态效果下只留静态亮边。
struct PresenceCardRim: View {
  let isPending: Bool
  @Environment(\.presenceDecorationActive) private var isActive
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: Tokens.Radius.compactPanel)
  }

  var body: some View {
    ZStack {
      shape.strokeBorder(Tokens.Color.line, lineWidth: 1)
      ZStack {
        shape.strokeBorder(Tokens.Color.ac.opacity(0.14), lineWidth: 5)
        shape.strokeBorder(Tokens.Color.ac, lineWidth: 2)
        if !reduceMotion {
          TimelineView(.animation(paused: !(isPending && isActive))) { context in
            let phase = PresenceHighlight.phase(at: context.date)
            GeometryReader { proxy in
              let outline = shape.inset(by: 1).path(in: CGRect(origin: .zero, size: proxy.size))
              closedHighlight(outline, phase: phase)
            }
          }
        }
      }
      .opacity(isPending ? 1 : 0)
    }
    .animation(PresenceHighlight.fade(reduceMotion: reduceMotion), value: isPending)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func closedHighlight(_ outline: Path, phase: CGFloat) -> some View {
    let length = PresenceHighlight.segment
    return ZStack {
      wrappedTrim(outline, from: phase, length: length)
        .stroke(PresenceHighlight.glow.opacity(0.45), lineWidth: 2)
      wrappedTrim(outline, from: phase + length * 0.55, length: length * 0.45)
        .stroke(PresenceHighlight.head, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
    .shadow(color: PresenceHighlight.glow.opacity(0.6), radius: 2.5)
  }

  /// 闭合路径上从 `start` 起长 `length` 的一段;越过终点的部分接回起点。
  private func wrappedTrim(_ outline: Path, from start: CGFloat, length: CGFloat) -> Path {
    let head = start.truncatingRemainder(dividingBy: 1)
    let tail = head + length
    var path = outline.trimmedPath(from: head, to: min(tail, 1))
    if tail > 1 {
      path.addPath(outline.trimmedPath(from: 0, to: tail - 1))
    }
    return path
  }
}

// MARK: - Dock 把手

/// 已确认画廊 B 的外壳路径:沿边 84、微肩 s=8/r=14,肩高为深度的 0.28。贴屏幕一侧是开口。
/// 路径画在面板自身坐标里(面板深度固定为拉出深度),`depth` 是当前露出深度;
/// 外壳、玻璃裁切、亮边与高光都从同一个 `depth` 推出,拉出/收回时一起过渡。
struct DockNotchShape: Shape {
  var edge: DockEdge
  var depth: CGFloat
  /// true 沿屏幕边闭合(填充/裁切);false 为不含贴边线的开放轮廓(描边)。
  var closed: Bool

  var animatableData: CGFloat {
    get { depth }
    set { depth = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let length = edge.isVertical ? rect.height : rect.width
    let panelDepth = edge.isVertical ? rect.width : rect.height
    let d = min(depth, panelDepth)
    let s: CGFloat = 8
    let r: CGFloat = 14
    let y1 = d * 0.28
    let x1 = s
    let x2 = s + r
    let x3 = length - (s + r)
    let x4 = length - s
    // (u 沿边, v 离开屏幕边的深度) → 面板坐标(SwiftUI 左上原点)。
    func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
      switch edge {
      case .top: CGPoint(x: rect.minX + u, y: rect.minY + v)
      case .bottom: CGPoint(x: rect.minX + u, y: rect.maxY - v)
      case .left: CGPoint(x: rect.minX + v, y: rect.minY + u)
      case .right: CGPoint(x: rect.maxX - v, y: rect.minY + u)
      }
    }
    var path = Path()
    path.move(to: point(0, 0))
    path.addCurve(
      to: point(x1, y1), control1: point(s * 0.4, 0), control2: point(s * 0.8, y1 * 0.4))
    path.addCurve(
      to: point(x2, d), control1: point(x1 + r * 0.2, d * 0.7), control2: point(x1 + r * 0.5, d))
    path.addLine(to: point(x3, d))
    path.addCurve(
      to: point(x4, y1), control1: point(length - x1 - r * 0.5, d),
      control2: point(length - x1 - r * 0.2, d * 0.7))
    path.addCurve(
      to: point(length, 0), control1: point(length - s * 0.8, y1 * 0.4),
      control2: point(length - s * 0.4, 0))
    if closed {
      path.closeSubpath()
    }
    return path
  }
}

/// Dock 把手外观(已确认画廊 B):深色玻璃胶囊以微肩接入屏幕边,贴边一侧开口不描边;
/// 左右边红点在上、声波竖排,上下边红点在左、声波横排。未确认点名时整条可见轮廓稳定亮起,
/// 一段高光沿开放轮廓慢速行进,在两端渐隐,不横穿屏幕接缝。声波是示意起伏,不是音频电平。
struct DockHandleVisual: View {
  let edge: DockEdge
  let isPulled: Bool
  let isPending: Bool
  let isRecording: Bool
  let isVisible: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DockHandleBody(
      edge: edge,
      depth: isPulled ? DockGeometry.pulledDepth : DockGeometry.restDepth,
      pendingLevel: isPending ? 1 : 0,
      isPending: isPending,
      isRecording: isRecording,
      isVisible: isVisible,
      reduceMotion: reduceMotion
    )
    // 拉出/收回与亮度各自过渡;可中断,从当前呈现值转向新目标。减少动态效果时不移动,只短淡入淡出。
    .animation(
      reduceMotion ? nil : .easeInOut(duration: Tokens.Motion.presenceTransition), value: isPulled
    )
    .animation(PresenceHighlight.fade(reduceMotion: reduceMotion), value: isPending)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isPending ? "有未确认的点名，点击查看会议内容" : "侧边吸附，点击查看会议内容")
  }
}

private struct DockHandleBody: View, Animatable {
  let edge: DockEdge
  var depth: CGFloat
  var pendingLevel: CGFloat
  let isPending: Bool
  let isRecording: Bool
  let isVisible: Bool
  let reduceMotion: Bool
  @Environment(\.colorScheme) private var colorScheme

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(depth, pendingLevel) }
    set {
      depth = newValue.first
      pendingLevel = newValue.second
    }
  }

  private static let waveColor = Color(red: 95 / 255, green: 208 / 255, blue: 196 / 255)
  private static let dotColor = Color(red: 230 / 255, green: 57 / 255, blue: 70 / 255)
  private static let barLengths: [CGFloat] = [3.5, 7.5, 7.5, 3.5]

  var body: some View {
    let isDark = colorScheme == .dark
    let fillShape = DockNotchShape(edge: edge, depth: depth, closed: true)
    let rimShape = DockNotchShape(edge: edge, depth: depth, closed: false)
    ZStack {
      fillShape.fill(.ultraThinMaterial)
      fillShape.fill(
        isDark
          ? Color(red: 18 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.86)
          : Color(red: 30 / 255, green: 34 / 255, blue: 40 / 255).opacity(0.76))
      fillShape.fill(Tokens.Color.ac.opacity(0.15 * pendingLevel))
      rimShape.stroke(Color.white.opacity(isDark ? 0.22 : 0.32), lineWidth: 0.85)
      rimShape.stroke(Color.white.opacity((isDark ? 0.45 : 0.75) * 0.85), lineWidth: 0.75)
      rimShape
        .stroke(PresenceHighlight.rim.opacity(0.98), lineWidth: 1.35)
        .shadow(color: PresenceHighlight.glow.opacity(0.72), radius: 2.5)
        .opacity(pendingLevel)
      if !reduceMotion && pendingLevel > 0 {
        TimelineView(.animation(paused: !(isPending && isVisible))) { context in
          openHighlight(rimShape, phase: PresenceHighlight.phase(at: context.date))
        }
        .opacity(pendingLevel)
      }
      TimelineView(
        .animation(
          minimumInterval: 1.0 / 30.0, paused: !(isRecording && isVisible && !reduceMotion))
      ) { context in
        cluster(time: context.date.timeIntervalSinceReferenceDate)
      }
    }
  }

  /// 开放轮廓上的高光:段头从路径起点出发、整段离开终点后回到起点,靠近两端时渐隐,
  /// 循环衔接处不可见,也不横穿屏幕边上的开口。
  private func openHighlight(_ rim: DockNotchShape, phase: CGFloat) -> some View {
    let length = PresenceHighlight.segment
    let headPosition = phase * (1 + length)
    let center = headPosition - length / 2
    let fade = max(0, min(1, min(center, 1 - center) / 0.12))
    return ZStack {
      rim.trim(from: max(0, headPosition - length), to: min(1, max(0, headPosition)))
        .stroke(PresenceHighlight.glow.opacity(0.5), lineWidth: 1.6)
      rim.trim(
        from: max(0, headPosition - length * 0.45), to: min(1, max(0, headPosition))
      )
      .stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
    }
    .shadow(color: PresenceHighlight.glow.opacity(0.8), radius: 3)
    .opacity(fade)
  }

  /// 红点与四根声波条排成一组,中心落在当前露出区域中线上(随深度过渡一起移动)。
  private func cluster(time: TimeInterval) -> some View {
    let animated = isRecording && isVisible && !reduceMotion
    let scales: [CGFloat] = Self.barLengths.indices.map { index in
      guard animated else { return 1 }
      let wave = sin(time * 2 * .pi / 1.1 + Double(index) * 0.9)
      return CGFloat(0.45 + 0.55 * (0.5 + 0.5 * wave))
    }
    let bars = ForEach(Self.barLengths.indices, id: \.self) { index in
      RoundedRectangle(cornerRadius: 0.8)
        .fill(Self.waveColor.opacity(0.88))
        .frame(
          width: edge.isVertical ? Self.barLengths[index] * scales[index] : 1.6,
          height: edge.isVertical ? 1.6 : Self.barLengths[index] * scales[index]
        )
    }
    let dot = Circle()
      .fill(isRecording ? Self.dotColor : Tokens.Color.railInkDisabled)
      .frame(width: 4.2, height: 4.2)
    let group =
      edge.isVertical
      ? AnyView(
        VStack(spacing: 3.4) {
          dot
          VStack(spacing: 1.4) { bars }.frame(width: 7.5)
        })
      : AnyView(
        HStack(spacing: 3.4) {
          dot
          HStack(spacing: 1.4) { bars }.frame(height: 7.5)
        })
    // 面板深度固定为拉出深度;组中心离屏幕边 depth/2,沿边比中点偏 2pt(红点在前)。
    let inward = DockGeometry.pulledDepth / 2 - depth / 2
    let offset: CGSize =
      switch edge {
      case .right: CGSize(width: inward, height: -2)
      case .left: CGSize(width: -inward, height: -2)
      case .top: CGSize(width: -2, height: -inward)
      case .bottom: CGSize(width: -2, height: inward)
      }
    return group.offset(offset)
  }
}

// MARK: - 主窗内联提醒

/// 主窗(驾驶舱此刻舞台 / 会议库)内联接续同一个未确认事件。
public struct NameAlertInlineAlert: View {
  @ObservedObject var session: NameAlertSession

  public init(session: NameAlertSession) {
    self.session = session
  }

  public var body: some View {
    if let event = session.pendingEvent {
      NameAlertNameRow(event: event) { session.acknowledge(eventID: $0) }
        .runtimeAccessibilityIdentifier("name-alert.inline")
    }
  }
}

/// 驾驶舱「此刻舞台」上的点名接续:整个舞台轮廓高亮,名字区贴在舞台右下,不压标题与新鲜度。
struct NameAlertStageOverlay: View {
  @ObservedObject var session: NameAlertSession

  var body: some View {
    if let event = session.pendingEvent {
      ZStack(alignment: .bottomTrailing) {
        Rectangle()
          .stroke(Tokens.Color.ac, lineWidth: 2)
          .allowsHitTesting(false)
        NameAlertNameRow(event: event) { session.acknowledge(eventID: $0) }
          .frame(maxWidth: Tokens.Layout.compactOverlayWidth)
          .padding(.horizontal, Tokens.Spacing.xxl)
          .padding(.vertical, Tokens.Spacing.smd)
      }
      .runtimeAccessibilityIdentifier("cockpit.name-alert")
    }
  }
}

/// 录制中浏览会议库时的点名接续:工具栏下方一条,与驾驶舱共享同一个未确认事件。
struct NameAlertLibraryStrip: View {
  @ObservedObject var session: NameAlertSession

  var body: some View {
    if let event = session.pendingEvent {
      VStack(spacing: 0) {
        NameAlertNameRow(event: event) { session.acknowledge(eventID: $0) }
          .padding(.horizontal, Tokens.Spacing.lg)
          .padding(.vertical, Tokens.Spacing.xs)
        Rectangle().fill(Tokens.Color.acLine).frame(height: 1)
      }
      .background(Tokens.Color.card)
      .runtimeAccessibilityIdentifier("library.name-alert")
    }
  }
}

// MARK: - 会中工具栏开关

/// 驾驶舱与会议库顶栏共用的点名提醒菜单,与设置读写同一份偏好。
struct NameAlertToolbarMenu: View {
  @ObservedObject var preferences: NameAlertPreferencesStore
  let session: NameAlertSession?
  let onOpenSettings: () -> Void

  var body: some View {
    if let session {
      NameAlertReminderStateReader(session: session) { state in
        NameAlertToolbarMenuContent(
          preferences: preferences, reminderState: state, onOpenSettings: onOpenSettings)
      }
    } else {
      NameAlertToolbarMenuContent(
        preferences: preferences, reminderState: .notRecording, onOpenSettings: onOpenSettings)
    }
  }
}

private struct NameAlertReminderStateReader<Content: View>: View {
  @ObservedObject var session: NameAlertSession
  @ViewBuilder let content: (NameAlertReminderState) -> Content

  var body: some View {
    content(session.reminderState)
  }
}

private struct NameAlertToolbarMenuContent: View {
  @ObservedObject var preferences: NameAlertPreferencesStore
  let reminderState: NameAlertReminderState
  let onOpenSettings: () -> Void

  private var hasValidAliases: Bool {
    !NameAlertAliasSet(preferences.preferences.aliases).isEmpty
  }

  private enum Status {
    case active
    case paused
    case needsAliases
    case idleReady
  }

  private var status: Status {
    switch reminderState {
    case .active: return .active
    case .paused: return .paused
    case .needsAliases: return .needsAliases
    case .notRecording:
      if !hasValidAliases { return .needsAliases }
      return preferences.preferences.remindersEnabled ? .idleReady : .paused
    }
  }

  private var title: String {
    switch status {
    case .active: return "点名提醒中"
    case .paused: return "点名已暂停"
    case .needsAliases: return "点名需设置名字"
    case .idleReady: return "点名提醒"
    }
  }

  private var detail: String {
    switch status {
    case .active: return "录制中，系统声音叫到你的名字会提醒"
    case .paused: return "提醒已暂停；录制时仍在本机识别以免恢复后重复提醒"
    case .needsAliases: return "还没有有效的名字或昵称，不会提醒"
    case .idleReady: return "开始录制后生效"
    }
  }

  private var symbol: String {
    switch status {
    case .active, .idleReady: return "bell.fill"
    case .paused: return "bell.slash"
    case .needsAliases: return "bell.badge"
    }
  }

  var body: some View {
    Menu {
      Toggle(
        "点名提醒",
        isOn: Binding(
          get: { preferences.preferences.remindersEnabled },
          set: { preferences.setRemindersEnabled($0) }
        )
      )
      Text(detail)
      Divider()
      Picker(
        "悬浮显示",
        selection: Binding(
          get: { preferences.preferences.displayMode },
          set: { preferences.setDisplayMode($0) }
        )
      ) {
        Text("侧边吸附").tag(NameAlertPreferences.DisplayMode.dock)
        Text("悬浮小窗").tag(NameAlertPreferences.DisplayMode.window)
        Text("关闭悬浮显示").tag(NameAlertPreferences.DisplayMode.off)
      }
      .pickerStyle(.inline)
      Picker(
        "提醒方式",
        selection: Binding(
          get: { preferences.preferences.reminderStyle },
          set: { preferences.setReminderStyle($0) }
        )
      ) {
        Text("静默高亮").tag(NameAlertPreferences.ReminderStyle.quiet)
        Text("独立强提醒").tag(NameAlertPreferences.ReminderStyle.strong)
      }
      .pickerStyle(.inline)
      Toggle(
        "提示音",
        isOn: Binding(
          get: { preferences.preferences.soundEnabled },
          set: { preferences.setSoundEnabled($0) }
        )
      )
      Divider()
      Button("设置名字与提醒…", action: onOpenSettings)
    } label: {
      HStack(spacing: Tokens.Spacing.xxs) {
        Image(systemName: symbol)
          .foregroundStyle(status == .needsAliases ? Tokens.Color.warn : Tokens.Color.ink2)
          .accessibilityHidden(true)
        Text(title)
          .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink2)
      }
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.toolbarPill)
    .fixedSize()
    .help(detail)
    .accessibilityLabel("\(title)，\(detail)")
  }
}

// MARK: - 设置卡

/// 通用设置里的点名提醒卡:开关、显式名字列表、显示模式、提醒方式与提示音。
struct NameAlertSettingsCard: View {
  @ObservedObject var preferences: NameAlertPreferencesStore
  @State private var draft = ""

  private var aliases: [String] { preferences.preferences.aliases }
  private var hasValidAliases: Bool { !NameAlertAliasSet(aliases).isEmpty }

  var body: some View {
    RoleCardShell(title: "点名提醒", subtitle: "录制会议时，系统声音里叫到你的名字或昵称会提醒你") {
      Toggle(
        "点名提醒",
        isOn: Binding(
          get: { preferences.preferences.remindersEnabled },
          set: { preferences.setRemindersEnabled($0) }
        )
      )
      .toggleStyle(.switch)
      .runtimeAccessibilityIdentifier("settings.name-alerts.enabled")

      Text("暂停提醒时不弹出、不发声，录制中仍在本机识别；恢复后不补发已识别的点名，新到达的识别可能来自几秒前的说话。")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
        Text("名字或昵称")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink2)
        HStack(spacing: Tokens.Spacing.sm) {
          TextField("输入名字或昵称后按回车添加", text: $draft)
            .textFieldStyle(.plain)
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, Tokens.Spacing.xs)
            .insetPanel()
            .onSubmit(addDraft)
            .runtimeAccessibilityIdentifier("settings.name-alerts.alias-input")
          Button("添加", action: addDraft)
            .buttonStyle(.toolbarPillAccent)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .runtimeAccessibilityIdentifier("settings.name-alerts.alias-add")
        }
        ForEach(Array(aliases.enumerated()), id: \.offset) { index, alias in
          HStack(spacing: Tokens.Spacing.sm) {
            Text(alias)
              .font(.system(size: Tokens.FontSize.body))
              .foregroundStyle(Tokens.Color.ink)
              .lineLimit(1)
              .truncationMode(.tail)
              .help(alias)
            Spacer(minLength: Tokens.Spacing.sm)
            Button("删除") {
              var updated = aliases
              updated.remove(at: index)
              preferences.setAliases(updated)
            }
            .buttonStyle(.textAction)
            .runtimeAccessibilityIdentifier("settings.name-alerts.alias-remove.\(index)")
          }
          .runtimeAccessibilityIdentifier("settings.name-alerts.alias.\(index)")
        }
        if !hasValidAliases {
          HintText(text: "还没有有效的名字或昵称，添加后才会提醒")
            .runtimeAccessibilityIdentifier("settings.name-alerts.needs-aliases")
        }
      }

      Picker(
        "悬浮显示",
        selection: Binding(
          get: { preferences.preferences.displayMode },
          set: { preferences.setDisplayMode($0) }
        )
      ) {
        Text("侧边吸附").tag(NameAlertPreferences.DisplayMode.dock)
        Text("悬浮小窗").tag(NameAlertPreferences.DisplayMode.window)
        Text("关闭悬浮显示").tag(NameAlertPreferences.DisplayMode.off)
      }
      .pickerStyle(.segmented)
      .runtimeAccessibilityIdentifier("settings.name-alerts.display-mode")

      Picker(
        "提醒方式",
        selection: Binding(
          get: { preferences.preferences.reminderStyle },
          set: { preferences.setReminderStyle($0) }
        )
      ) {
        Text("静默高亮").tag(NameAlertPreferences.ReminderStyle.quiet)
        Text("独立强提醒").tag(NameAlertPreferences.ReminderStyle.strong)
      }
      .pickerStyle(.segmented)
      .runtimeAccessibilityIdentifier("settings.name-alerts.reminder-style")

      Toggle(
        "提示音",
        isOn: Binding(
          get: { preferences.preferences.soundEnabled },
          set: { preferences.setSoundEnabled($0) }
        )
      )
      .toggleStyle(.switch)
      .runtimeAccessibilityIdentifier("settings.name-alerts.sound")

      Text("名字只保存在本机，识别在本机完成；独立强提醒在投屏时仍可能被共享。")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .runtimeAccessibilityIdentifier("settings.name-alerts")
  }

  private func addDraft() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if !aliases.contains(trimmed) {
      preferences.setAliases(aliases + [trimmed])
    }
    draft = ""
  }
}
