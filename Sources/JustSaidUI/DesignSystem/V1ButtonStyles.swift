import AppKit
import SwiftUI

/// Five visual hierarchies sharing the same native Button interaction and focus behavior.
public struct V1ButtonStyle: ButtonStyle {
  fileprivate enum Kind: String { case primary, outline, quiet, icon, destructiveText, entry }
  fileprivate let kind: Kind
  fileprivate var controlHeight: CGFloat = Tokens.V1.Size.control
  fileprivate var labelFont: Font = Tokens.V1.Text.label.font

  public func makeBody(configuration: Configuration) -> some View {
    StyledBody(
      configuration: configuration, kind: kind, controlHeight: controlHeight, labelFont: labelFont)
  }

  func height(_ height: CGFloat) -> Self {
    var style = self
    style.controlHeight = height
    return style
  }

  /// 标签字号。首页那一对大按钮用 type-heading,其余按钮保持 type-label。
  func labelFont(_ font: Font) -> Self {
    var style = self
    style.labelFont = font
    return style
  }

  private struct StyledBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: Kind
    let controlHeight: CGFloat
    let labelFont: Font
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var foreground: Color {
      switch kind {
      case .primary: return Tokens.V1.Color.onPrimary
      case .entry: return Tokens.V1.Color.accentInk
      case .destructiveText: return Tokens.V1.Color.danger
      default: return Tokens.V1.Color.ink2
      }
    }

    /// 首页那一对 44 高的大按钮(开始记录 / 导入录音)圆角大一档,其余按钮 radius-sm
    /// (owner 2026-09-21:「开始记录那个绿色条,圆角可以再切大一点」)。
    private var cornerRadius: CGFloat {
      controlHeight >= Tokens.V1.Size.homeEntryButton ? Tokens.V1.Radius.lg : Tokens.V1.Radius.sm
    }

    /// 实底的两档(黑底主按钮、首页墨青主入口):悬停提亮、键盘焦点换边的画法一样。
    private var isSolid: Bool { kind == .primary || kind == .entry }

    private var background: Color {
      switch kind {
      case .primary: return Tokens.V1.Color.primary
      case .entry: return Tokens.V1.Color.accent
      case .outline: return Tokens.V1.Color.raised
      default: return .clear
      }
    }

    var body: some View {
      configuration.label
        .font(labelFont)
        .lineLimit(1)
        .foregroundStyle(foreground)
        .padding(.horizontal, kind == .icon ? 0 : Tokens.V1.Space.sm)
        .frame(width: kind == .icon ? Tokens.V1.Size.control : nil, height: controlHeight)
        .background {
          RoundedRectangle(cornerRadius: cornerRadius)
            .fill(background)
            .overlay {
              RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isSolid ? Tokens.V1.Color.onPrimary : Tokens.V1.Color.scrim)
                .opacity(
                  isEnabled && isHovering
                    ? (isSolid ? Tokens.V1.Feedback.primaryHoverOpacity : 1) : 0)
            }
            .animation(
              reduceMotion ? nil : .easeOut(duration: Tokens.V1.Motion.fast), value: isHovering)
        }
        .overlay {
          // 焦点态换掉 outline 自己那条描边,不在外面再画一圈:两条同心描边就是
          // owner 2026-09-20 说的「用这个绿色再包一层,好丑」。
          // 另外四种按钮本来没有描边,焦点态什么都不画。凭空加一条边的代价是:
          // isFocused 取的是最近的可聚焦祖先,按钮不在焦点链上时它跟着容器走,
          // 于是一屏按钮会同时长边——上一轮那 27 个墨青方框正是这么来的。
          // 系统「键盘导航」关着(本机默认)时按钮根本进不了焦点链,isFocused 报的是
          // 外面那个可聚焦容器:在会议页正文里点一下,右栏底两颗按钮就同时换成墨青边
          // (owner 2026-09-21 截图「好丑」)。只有键盘导航开着时这个值才是按钮自己的。
          let focused = isEnabled && isFocused && NSApplication.shared.isFullKeyboardAccessEnabled
          if kind == .outline || (focused && isSolid) {
            RoundedRectangle(cornerRadius: cornerRadius)
              .strokeBorder(
                focused ? Tokens.V1.Color.focus : Tokens.V1.Color.controlRule,
                lineWidth: focused ? Tokens.V1.Size.focusWidth : Tokens.V1.Size.controlRuleWidth)
          }
        }
        .opacity(
          isEnabled
            ? (configuration.isPressed ? Tokens.V1.Feedback.pressedOpacity : 1)
            : Tokens.V1.Feedback.disabledOpacity
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onHover { isHovering = $0 }
        .runtimeAccessibilityIdentifier("v1.button.\(kind.rawValue)")
    }
  }
}

extension ButtonStyle where Self == V1ButtonStyle {
  public static var v1Primary: V1ButtonStyle { V1ButtonStyle(kind: .primary) }
  public static var v1Outline: V1ButtonStyle { V1ButtonStyle(kind: .outline) }
  public static var v1Quiet: V1ButtonStyle { V1ButtonStyle(kind: .quiet) }
  public static var v1Icon: V1ButtonStyle { V1ButtonStyle(kind: .icon) }
  public static var v1DestructiveText: V1ButtonStyle { V1ButtonStyle(kind: .destructiveText) }
  /// 首页主入口:墨青实底、44 高、type-heading 字(owner 2026-09-21 第二版首页参考稿)。
  /// 全应用只有首页「开始记录 / 返回会议」用这一档。
  public static var v1Entry: V1ButtonStyle {
    V1ButtonStyle(
      kind: .entry, controlHeight: Tokens.V1.Size.homeEntryButton,
      labelFont: Tokens.V1.Text.heading.font)
  }
}
