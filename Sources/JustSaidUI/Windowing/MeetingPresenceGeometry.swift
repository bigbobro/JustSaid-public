import CoreGraphics
import JustSaidCore

/// 会中悬浮呈现一次只选一个载体。
public enum MeetingPresenceSurface: Equatable, Sendable {
  case none
  case dock
  case window
  case strongAlert
}

/// 呈现优先级(design「Presentation and Window Ownership」):非 recording 隐藏 →
/// 主窗前台只在主窗内联 → 后台 strong + pending 只显示独立卡片 → 所选 Dock/小窗/关闭。
enum MeetingPresencePolicy {
  static func surface(
    isRecording: Bool,
    isMainForeground: Bool,
    hasPending: Bool,
    displayMode: NameAlertPreferences.DisplayMode,
    reminderStyle: NameAlertPreferences.ReminderStyle
  ) -> MeetingPresenceSurface {
    guard isRecording, !isMainForeground else { return .none }
    if hasPending, reminderStyle == .strong {
      return .strongAlert
    }
    switch displayMode {
    case .dock: return .dock
    case .window: return .window
    case .off: return .none
    }
  }
}

enum DockEdge: String, CaseIterable, Sendable {
  case left
  case right
  case top
  case bottom

  /// 左右边的把手竖排,上下边横排。
  var isVertical: Bool { self == .left || self == .right }
}

/// 本场 Dock 位置:边与沿边比例(0 = 左/下端,1 = 右/上端),屏幕按显示器编号记忆。
struct DockPlacement: Equatable, Sendable {
  var edge: DockEdge
  var along: CGFloat
  var displayID: UInt32?

  static let initial = DockPlacement(edge: .right, along: 0.72, displayID: nil)
}

/// Dock 与小窗的几何。数值是布局算法参数(与 FlowMetrics 同类),不进取距 token;
/// 尺寸沿用已确认 B(沿边 84、静息露出 17、拉出 26)。把手面板按拉出深度摆放,
/// 静息/拉出之间的露出深度由把手外壳过渡(`DockHandleVisual`),面板本身不改尺寸。
enum DockGeometry {
  static let handleLength: CGFloat = 84
  static let restDepth: CGFloat = 17
  static let pulledDepth: CGFloat = 26
  static let contentGap: CGFloat = 8
  static let windowInset: CGFloat = 24

  /// 把手贴着可用区域(`visibleFrame`,已排除菜单栏与系统 Dock)的所选边。
  static func handleFrame(_ placement: DockPlacement, depth: CGFloat, in visible: CGRect) -> CGRect
  {
    let along = min(max(placement.along, 0), 1)
    switch placement.edge {
    case .left, .right:
      let length = min(handleLength, visible.height)
      let y = visible.minY + along * (visible.height - length)
      let x = placement.edge == .left ? visible.minX : visible.maxX - depth
      return CGRect(x: x, y: y, width: depth, height: length)
    case .top, .bottom:
      let length = min(handleLength, visible.width)
      let x = visible.minX + along * (visible.width - length)
      let y = placement.edge == .bottom ? visible.minY : visible.maxY - depth
      return CGRect(x: x, y: y, width: length, height: depth)
    }
  }

  /// 内容朝屏幕内侧展开,居中对齐把手并限制在可用区域内。
  static func contentFrame(size: CGSize, handle: CGRect, edge: DockEdge, in visible: CGRect)
    -> CGRect
  {
    var origin: CGPoint
    switch edge {
    case .right:
      origin = CGPoint(x: handle.minX - contentGap - size.width, y: handle.midY - size.height / 2)
    case .left:
      origin = CGPoint(x: handle.maxX + contentGap, y: handle.midY - size.height / 2)
    case .top:
      origin = CGPoint(x: handle.midX - size.width / 2, y: handle.minY - contentGap - size.height)
    case .bottom:
      origin = CGPoint(x: handle.midX - size.width / 2, y: handle.maxY + contentGap)
    }
    return clamp(CGRect(origin: origin, size: size), to: visible)
  }

  /// 按指针位置求最近边与沿边比例;拖动把手时换边与沿边移动共用。
  static func placement(nearest point: CGPoint, in visible: CGRect, displayID: UInt32?)
    -> DockPlacement
  {
    let distances: [(DockEdge, CGFloat)] = [
      (.left, abs(point.x - visible.minX)),
      (.right, abs(visible.maxX - point.x)),
      (.bottom, abs(point.y - visible.minY)),
      (.top, abs(visible.maxY - point.y)),
    ]
    let edge = distances.min { $0.1 < $1.1 }?.0 ?? .right
    let along: CGFloat
    if edge.isVertical {
      let travel = max(visible.height - handleLength, 1)
      along = (point.y - handleLength / 2 - visible.minY) / travel
    } else {
      let travel = max(visible.width - handleLength, 1)
      along = (point.x - handleLength / 2 - visible.minX) / travel
    }
    return DockPlacement(edge: edge, along: min(max(along, 0), 1), displayID: displayID)
  }

  /// 整个框限制在可用区域内;比区域大时贴左上。
  static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
    var result = frame
    result.origin.x = min(
      max(frame.minX, visible.minX), max(visible.maxX - frame.width, visible.minX))
    result.origin.y = min(
      max(frame.minY, visible.minY), max(visible.maxY - frame.height, visible.minY))
    return result
  }

  /// 小窗首次出现:可用区域右上角。
  static func defaultWindowFrame(size: CGSize, in visible: CGRect) -> CGRect {
    clamp(
      CGRect(
        x: visible.maxX - size.width - windowInset,
        y: visible.maxY - size.height - windowInset,
        width: size.width,
        height: size.height
      ),
      to: visible
    )
  }

  /// 独立强提醒卡:可用区域顶部居中偏右,不遮主窗中心。
  static func strongAlertFrame(size: CGSize, in visible: CGRect) -> CGRect {
    defaultWindowFrame(size: size, in: visible)
  }
}
