import SwiftUI

/// 缩略置顶窗（V7）：主窗失焦 1.5s 后出现，内容=当前正在聊最新 1–2 条（非转写）+
/// 覆盖时间 + 标记重点 + 回主窗。ui-final-v2.html 未画出关闭按钮的具体样式，
/// 这里用一个低调的右上角「✕」承载“本场会议不再自动弹”的必要出口。
public struct CompactOverlayView: View {
  @ObservedObject var model: CompactOverlayViewModel
  @Environment(\.textScale) private var textScale

  public init(model: CompactOverlayViewModel) {
    self.model = model
  }

  public var body: some View {
    HStack(alignment: .top, spacing: Tokens.Spacing.smd) {
      PulsingDot(color: Tokens.Color.rec, size: 7, isPulsing: false)
        .padding(.top, Tokens.Spacing.hairline)

      VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
        // 麦克风暂停小条(08-14 mic-only-pause):显隐收在视图内部(红线 6)。
        if model.isMicrophonePaused {
          microphonePausedStrip
        }
        header
        summaryContent
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .layoutPriority(1)

      VStack(alignment: .trailing, spacing: Tokens.Spacing.xs) {
        if let text = model.actionConfirmation {
          Text(text)
            .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
            .foregroundStyle(Tokens.Color.acDeep)
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
            .fixedSize(horizontal: true, vertical: false)
            .runtimeAccessibilityIdentifier("compact.action-confirmation")
            .allowsHitTesting(false)
        }
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
        .runtimeAccessibilityIdentifier("compact.mark")

        Button(action: model.onReturnToMain) {
          HStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
              .accessibilityHidden(true)
            Text("回主窗")
          }
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink2)
        }
        .buttonStyle(.compactPill)
        .runtimeAccessibilityIdentifier("compact.return-main")
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .padding(.horizontal, Tokens.Spacing.xl)
    .padding(.vertical, Tokens.Spacing.smd)
    .frame(
      width: Tokens.Layout.compactOverlayWidth,
      height: Tokens.Layout.compactOverlayHeight,
      alignment: .topLeading
    )
    .clipped()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.compactPanel))
    .overlay {
      RoundedRectangle(cornerRadius: Tokens.Radius.compactPanel)
        .stroke(Tokens.Color.line, lineWidth: 1)
    }
    .overlay(alignment: .topTrailing) {
      Button(action: model.onClose) {
        Image(systemName: "xmark")
          .font(.system(size: Tokens.FontSize.micro, weight: .bold))
          .padding(Tokens.Spacing.xxs)
      }
      .buttonStyle(IconHoverButtonStyle(base: Tokens.Color.ink4, hover: Tokens.Color.ink2))
      .accessibilityLabel("关闭悬浮窗，本场会议不再自动弹出")
      .runtimeAccessibilityIdentifier("compact.close")
      .help("关闭后本场会议不再自动弹出")
      .padding(Tokens.Spacing.xxs)
    }
    .accessibilityElement(children: .contain)
  }

  private var header: some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Text("当前正在聊")
        .font(.system(size: Tokens.FontSize.secondary, weight: .bold))
        .foregroundStyle(Tokens.Color.ac)
      Text("覆盖至 \(model.coveredUntilLabel)")
        .font(.system(size: Tokens.FontSize.caption, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink4)
    }
    .lineLimit(1)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .runtimeAccessibilityIdentifier("compact.header")
  }

  private var summaryContent: some View {
    Group {
      if model.lines.isEmpty {
        Text("正在听…")
          .font(.system(size: textScale.size(Tokens.FontSize.body)))
          .foregroundStyle(Tokens.Color.ink4)
          .runtimeAccessibilityIdentifier("compact.content.text")
      } else {
        VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
          ForEach(model.lines) { line in
            RichText(line.text)
              .font(.system(size: textScale.size(Tokens.FontSize.body)))
              .foregroundStyle(Tokens.Color.ink)
              .runtimeAccessibilityIdentifier("compact.content.text")
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .clipped()
    .runtimeAccessibilityIdentifier("compact.content")
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
    .runtimeAccessibilityIdentifier("compact.mic-paused")
  }
}
