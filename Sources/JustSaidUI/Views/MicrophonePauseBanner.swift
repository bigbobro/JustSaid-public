import SwiftUI

/// 「麦克风已暂停」常驻状态条(08-14 mic-only-pause 单)。
///
/// 定位差异(与「闲聊中」细带必须一眼区分,两者可同时激活、上下相邻不合并):
/// - **暂停 = 隐私工具**:暂停期间麦克风这一路什么都不记(母带按等长静音续写,
///   双路时间轴始终对齐),对方/系统声照常录制与转写;
/// - **闲聊 = 照录但不进纪要**(排除时间段体系,`ChatExclusionBanner`)。
/// 图标用 `mic.slash.fill`,与闲聊的 bubble 图标区分;文案直说「不再收音/仍在录」。
///
/// 显隐判断收在视图内部(验证红线 6),调用点无条件实例化;
/// `isPaused == false` 时整条结构不存在。样式对齐 legHealthBanner / 闲聊细带:
/// amber 底 + warn 字 + 底部细线,chrome 不走 textScale。
public struct MicrophonePauseBanner: View {
  /// 超时轻提醒的升级阈值:3 分钟。理由:一场会里「忘了恢复」超过两三分钟就开始
  /// 真实丢内容(本侧发言整段缺席);而短于 1 分钟的暂停是去倒水/关门这类正常
  /// 用法,不该烦人。升级只改视觉(追加「别忘了恢复」),不弹窗不发声。
  public static let reminderThreshold: TimeInterval = 180

  /// 是否处于暂停态——由 Core `RecordingSession.isMicrophonePaused` 驱动,
  /// UI 不持有第二份事实,也没有错误路径(暂停/恢复返回 false 时状态不变)。
  public let isPaused: Bool
  /// 暂停起点。**呈现层记账**:session 没有发布 pausedAt,由调用点在
  /// isMicrophonePaused 上升沿自记、恢复/换场清零;权威暂停区间在
  /// meeting.json 的 microphonePauseIntervals(采集层落盘),这里只用于
  /// 显示已暂停时长与超时轻提醒。
  public let pausedAt: Date?
  public let onResume: () -> Void

  public init(isPaused: Bool, pausedAt: Date?, onResume: @escaping () -> Void) {
    self.isPaused = isPaused
    self.pausedAt = pausedAt
    self.onResume = onResume
  }

  public var body: some View {
    if isPaused {
      HStack(spacing: Tokens.Spacing.xsm) {
        Image(systemName: "mic.slash.fill")
        Text("麦克风已暂停：本侧不再收音，对方/系统声仍在录")
        TimelineView(.periodic(from: pausedAt ?? .now, by: 1)) { context in
          let elapsed = context.date.timeIntervalSince(pausedAt ?? context.date)
          HStack(spacing: Tokens.Spacing.xxs) {
            Text("已暂停 \(ElapsedTime.shortLabel(elapsed))")
              .font(.system(size: Tokens.FontSize.bodyMinimum, weight: .semibold, design: .monospaced))
              .runtimeAccessibilityIdentifier("banner.mic-paused.elapsed")
            if elapsed >= Self.reminderThreshold {
              // 超时轻提醒:只把语气升一档,防「忘了恢复丢半场发言」。
              Text("别忘了恢复")
                .fontWeight(.semibold)
                .runtimeAccessibilityIdentifier("banner.mic-paused.reminder")
            }
          }
        }
        Spacer()
        Button("恢复麦克风", action: onResume)
          .buttonStyle(.textAction)
          .fontWeight(.semibold)
          .accessibilityLabel("恢复麦克风，本侧重新开始收音")
          .runtimeAccessibilityIdentifier("banner.mic-paused.resume")
      }
      .font(.system(size: Tokens.FontSize.uiEmphasis))
      .foregroundStyle(Tokens.Color.warn)
      .padding(.horizontal, Tokens.Spacing.md)
      .padding(.vertical, Tokens.Spacing.xs)
      .background(Tokens.Color.amber)
      .overlay(alignment: .bottom) {
        Rectangle().fill(Tokens.Color.amberLine).frame(height: 1)
      }
      .accessibilityElement(children: .contain)
      .runtimeAccessibilityIdentifier("banner.mic-paused")
    }
  }
}
