import JustSaidCore
import SwiftUI

/// 会中悬浮内容(Dock 展开内容与悬浮小窗共用),已确认纵向卡片 C:顶部是拖动短线与右上角
/// 独占的关闭区;有未确认点名时顶部换成差异色名字区(名字与「知道了」分列,右侧让出关闭区),
/// 整圈亮边并有一段慢速高光绕行。下方依次是麦克风暂停小条、「当前正在聊 · 覆盖至」、
/// 最新 1–2 条总结(固定三行高度,动态更新不改面板几何)与底栏(标记重点 / 载体切换 / 回主窗)。
/// 关闭只关悬浮显示,不暂停提醒。
public struct CompactOverlayView: View {
  @ObservedObject var model: CompactOverlayViewModel
  @Environment(\.textScale) private var textScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(model: CompactOverlayViewModel) {
    self.model = model
  }

  /// 右上角关闭区宽度:名字区右侧留出,「知道了」不贴着 ×。
  static let closeZoneWidth = Tokens.Spacing.xxl + Tokens.Spacing.smd
  /// 无点名时顶部拖动/关闭条高度,与 × 的命中区(含上边距)一致,下方内容不压 ×。
  static let chromeHeight = Tokens.Spacing.xxl + Tokens.Spacing.xsm

  private var isPending: Bool { model.pendingEvent != nil }

  private var transition: Animation {
    .easeInOut(
      duration: reduceMotion ? Tokens.Motion.presenceReducedFade : Tokens.Motion.presenceTransition)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let event = model.pendingEvent {
        NameAlertNameZone(event: event, onAcknowledge: model.onAcknowledge)
          .padding(.leading, Tokens.Spacing.lg)
          .padding(.trailing, Self.closeZoneWidth)
          .padding(.top, Tokens.Spacing.lg)
          .padding(.bottom, Tokens.Spacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Tokens.Color.acSoft)
          .overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.Color.line).frame(height: 1)
          }
          .transition(.opacity)
          .runtimeAccessibilityIdentifier("compact.name-alert")
      } else {
        Color.clear.frame(height: Self.chromeHeight)
      }

      // 麦克风暂停小条(08-14 mic-only-pause):显隐收在视图内部(红线 6)。
      if model.isMicrophonePaused {
        microphonePausedStrip
          .padding(.horizontal, Tokens.Spacing.md)
          .padding(.top, isPending ? Tokens.Spacing.smd : 0)
          .transition(.opacity)
      }

      VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
        header
        summaryContent
        footer
      }
      .padding(.horizontal, Tokens.Spacing.lg)
      .padding(.top, isPending || model.isMicrophonePaused ? Tokens.Spacing.md : 0)
      .padding(.bottom, Tokens.Spacing.smd)
    }
    .frame(width: Tokens.Layout.compactOverlayWidth, alignment: .topLeading)
    // 面板高度在过渡中或被按住冻结时可能小于理想高度:卡片底与轮廓跟随面板边界,内容贴顶;
    // 让出的高度只从总结区收,名字区、关闭、知道了与底栏按钮保持完整可见。
    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    .background(Tokens.Color.card)
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.compactPanel))
    .overlay { PresenceCardRim(isPending: isPending) }
    .overlay(alignment: .top) {
      if model.carrier == .window {
        // 小窗可拖动的提示短线;拖动本身由面板根上的 WindowDragGesture 处理。
        Capsule()
          .fill(Tokens.Color.ink3.opacity(0.35))
          .frame(width: Tokens.Spacing.xxl, height: 3)
          .padding(.top, Tokens.Spacing.xs)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .topTrailing) { closeButton }
    .animation(transition, value: model.pendingEvent?.id)
    .animation(transition, value: model.isMicrophonePaused)
    .accessibilityElement(children: .contain)
  }

  /// 关闭独占右上角:不覆盖名字、「知道了」、时间与按钮。
  private var closeButton: some View {
    Button(action: model.onClose) {
      Image(systemName: "xmark")
        .font(.system(size: Tokens.FontSize.ui, weight: .bold))
        .frame(width: Tokens.Spacing.xxl, height: Tokens.Spacing.xxl)
        .contentShape(Rectangle())
    }
    .buttonStyle(IconHoverButtonStyle(base: Tokens.Color.ink3, hover: Tokens.Color.ink))
    .accessibilityLabel("关闭悬浮显示")
    .help("关闭悬浮显示；不改变点名提醒设置，录音与总结继续")
    .runtimeAccessibilityIdentifier("compact.close")
    .padding(.top, Tokens.Spacing.xs)
    .padding(.trailing, Tokens.Spacing.xs)
  }

  private var header: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      PulsingDot(color: Tokens.Color.rec, size: 6, isPulsing: false)
      Text("当前正在聊")
        .font(.system(size: Tokens.FontSize.ui, weight: .bold))
        .foregroundStyle(Tokens.Color.ac)
      Spacer(minLength: Tokens.Spacing.xs)
      Text("覆盖至 \(model.coveredUntilLabel)")
        .font(.system(size: Tokens.FontSize.caption, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink3)
    }
    .lineLimit(1)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .runtimeAccessibilityIdentifier("compact.header")
  }

  private var bodyFont: Font {
    .system(size: textScale.size(Tokens.FontSize.body))
  }

  /// 总结区固定三行高(随正文字号):一条时最多三行,两条时 2+1 行,超出以省略号收尾。
  private var summaryContent: some View {
    ZStack(alignment: .topLeading) {
      Text(verbatim: "\n\n")
        .font(bodyFont)
        .hidden()
        .accessibilityHidden(true)
      if model.lines.isEmpty {
        Text("正在听…")
          .font(bodyFont)
          .foregroundStyle(Tokens.Color.ink4)
          .runtimeAccessibilityIdentifier("compact.content.text")
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
            RichText(line.text)
              .font(bodyFont)
              .foregroundStyle(Tokens.Color.ink)
              .lineLimit(model.lines.count == 1 ? 3 : (index == 0 ? 2 : 1))
              .truncationMode(.tail)
              .runtimeAccessibilityIdentifier("compact.content.text")
          }
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: 0, alignment: .topLeading)
    .clipped()
    .layoutPriority(-1)
    .runtimeAccessibilityIdentifier("compact.content")
  }

  private var footer: some View {
    VStack(spacing: Tokens.Spacing.xs) {
      Rectangle().fill(Tokens.Color.line).frame(height: 1)
      HStack(spacing: Tokens.Spacing.xs) {
        Button(action: model.onMark) {
          HStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: model.markConfirmation == nil ? "flag.fill" : "checkmark")
              .accessibilityHidden(true)
            if model.markConfirmation == nil {
              Text("标记重点")
            } else {
              Text("已标记")
            }
          }
          .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .bold))
          .foregroundStyle(Tokens.Color.acDeep)
        }
        .buttonStyle(.compactPillAccent)
        .fixedSize()
        .runtimeAccessibilityIdentifier("compact.mark")

        if let text = model.actionConfirmation {
          Text(text)
            .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
            .foregroundStyle(Tokens.Color.acDeep)
            .lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, Tokens.Spacing.xxs)
            .background(
              Tokens.Color.acSoft,
              in: RoundedRectangle(cornerRadius: Tokens.Radius.control)
            )
            .overlay(
              RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .stroke(Tokens.Color.acLine, lineWidth: 1)
            )
            .runtimeAccessibilityIdentifier("compact.action-confirmation")
            .allowsHitTesting(false)
        }

        Spacer(minLength: Tokens.Spacing.xs)

        carrierButton

        Button(action: model.onReturnToMain) {
          HStack(spacing: Tokens.Spacing.xxs) {
            Text("回主窗")
            Image(systemName: "arrow.up.right")
              .accessibilityHidden(true)
          }
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink2)
        }
        .buttonStyle(.compactPill)
        .fixedSize()
        .runtimeAccessibilityIdentifier("compact.return-main")
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// Dock 内容里是「保持展开」(切小窗),小窗里是「收起到侧边」(切 Dock)。
  @ViewBuilder
  private var carrierButton: some View {
    switch model.carrier {
    case .dock:
      Button(action: model.onKeepOpen) {
        Image(systemName: "pin")
          .font(.system(size: Tokens.FontSize.caption, weight: .semibold))
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(IconHoverButtonStyle(base: Tokens.Color.ink3, hover: Tokens.Color.ink))
      .accessibilityLabel("保持展开，切换为悬浮小窗")
      .help("保持展开（切换为悬浮小窗）")
      .runtimeAccessibilityIdentifier("compact.keep-open")
    case .window:
      Button(action: model.onCollapseToSide) {
        Image(systemName: "sidebar.right")
          .font(.system(size: Tokens.FontSize.caption, weight: .semibold))
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(IconHoverButtonStyle(base: Tokens.Color.ink3, hover: Tokens.Color.ink))
      .accessibilityLabel("收起到侧边，切换为侧边吸附")
      .help("收起到侧边（切换为侧边吸附）")
      .runtimeAccessibilityIdentifier("compact.collapse-to-side")
    }
  }

  /// 麦克风暂停小条(08-14 mic-only-pause):暂停是进行中的隐私状态,悬浮窗必须
  /// 常驻可见并给一键恢复。与主窗 `MicrophonePauseBanner` 同文案口径
  /// (「麦克风已暂停」+「恢复麦克风」),图标同为 mic.slash.fill;
  /// amber 底 + warn 字与主条同一视觉语言。
  private var microphonePausedStrip: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      Image(systemName: "mic.slash.fill")
        .font(.system(size: Tokens.FontSize.caption, weight: .semibold))
        .accessibilityHidden(true)
      Text("麦克风已暂停")
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      Spacer(minLength: Tokens.Spacing.xs)
      Button(action: model.onResumeMicrophone) {
        Text("恢复麦克风")
          .font(.system(size: Tokens.FontSize.ui, weight: .bold))
          .foregroundStyle(Tokens.Color.acDeep)
      }
      .buttonStyle(.compactPillAccent)
      .accessibilityLabel("恢复麦克风，本侧重新开始收音")
      .runtimeAccessibilityIdentifier("compact.mic-paused.resume")
    }
    .foregroundStyle(Tokens.Color.warn)
    .padding(.horizontal, Tokens.Spacing.sm)
    .padding(.vertical, Tokens.Spacing.xxs)
    .background(Tokens.Color.amber, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
    .fixedSize(horizontal: false, vertical: true)
    .runtimeAccessibilityIdentifier("compact.mic-paused")
  }
}
