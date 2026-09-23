import SwiftUI

/// 设计语言 v1 的分段控件,对应 `docs/design-system/styles.css` 的 `.seg`。
///
/// 不用系统的 `.pickerStyle(.segmented)`:那个的选中段填系统强调色(本机是蓝),
/// 与 V1 的墨绿不一致,而且设计系统里这个控件本来就不是着色填充——
/// 轨是 paper-3,选中段是一枚 raised 的浮起胶囊加 1 点细边,文字用 ink,
/// 未选中用 ink-2。全部取值自 `Tokens.V1`,不在这里造数值。
public struct V1SegmentedPicker<Value: Hashable>: View {
  public struct Option {
    public let value: Value
    public let title: String

    public init(_ value: Value, _ title: String) {
      self.value = value
      self.title = title
    }
  }

  @Binding private var selection: Value
  private let options: [Option]
  private let label: String
  /// 等分撑满容器宽度,对应设计系统的 `.seg-fill`。面板里放不下时,
  /// 按内容宽排会把「今天」压成省略号;等分则四格一起变窄,全部可读。
  private let fills: Bool
  private let style: Style
  private let segmentHeight: CGFloat
  private let optionIdentifier: (Value) -> String?
  private let optionEnabled: (Value) -> Bool
  private let optionHelp: (Value) -> String?
  @Environment(\.isEnabled) private var isEnabled

  /// 选中态的画法。`.standard` 是全应用默认(白块加细边)。首页入口卡浮在背景图上,
  /// 用另外两种,底座换成毛玻璃(owner 2026-09-21 参考稿):
  /// `.accentFill` 墨青实底白字(提醒方式),`.accentOutline` 白块加一圈墨青边、墨青字(说话语言)。
  public enum Style { case standard, accentFill, accentOutline }

  public init(
    _ label: String, selection: Binding<Value>, options: [Option], fills: Bool = false,
    style: Style = .standard,
    segmentHeight: CGFloat? = nil,
    optionIdentifier: @escaping (Value) -> String? = { _ in nil },
    optionEnabled: @escaping (Value) -> Bool = { _ in true },
    optionHelp: @escaping (Value) -> String? = { _ in nil }
  ) {
    self.label = label
    _selection = selection
    self.options = options
    self.fills = fills
    self.style = style
    self.segmentHeight = segmentHeight ?? (Tokens.V1.Size.control - Tokens.V1.Space.s2xs)
    self.optionIdentifier = optionIdentifier
    self.optionEnabled = optionEnabled
    self.optionHelp = optionHelp
  }

  public var body: some View {
    HStack(spacing: Tokens.V1.Space.s3xs) {
      ForEach(options.indices, id: \.self) { index in
        segment(options[index])
      }
    }
    .padding(Tokens.V1.Space.s3xs)
    .modifier(TrackSurface(glass: style != .standard))
    .opacity(isEnabled ? 1 : Tokens.V1.Feedback.disabledOpacity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }

  private func segment(_ option: Option) -> some View {
    let selected = option.value == selection
    return Button {
      selection = option.value
    } label: {
      Text(option.title)
        .font(
          .system(
            size: textSize,
            weight: selected ? .semibold : .medium)
        )
        .foregroundStyle(selected ? selectedInk : Tokens.V1.Color.ink2)
        .lineLimit(1)
        .padding(.horizontal, fills ? Tokens.V1.Space.xs : Tokens.V1.Space.sm)
        .frame(maxWidth: fills ? .infinity : nil)
        .frame(height: segmentHeight)
        .background {
          if selected {
            RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs)
              .fill(style == .accentFill ? Tokens.V1.Color.accent : Tokens.V1.Color.raised)
              .overlay(
                RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs)
                  .strokeBorder(selectedEdge, lineWidth: selectedEdgeWidth)
              )
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs))
    }
    .buttonStyle(.plain)
    .disabled(!optionEnabled(option.value))
    .modifier(SegmentHelp(text: optionHelp(option.value)))
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .modifier(SegmentRuntimeIdentifier(identifier: optionIdentifier(option.value)))
  }

  /// 默认 28 高的分段用 12 号字;调高了的(首页 36 高,和输入框同高)用 13 号,
  /// 和同一行的标签、输入框一个字号。
  private var textSize: CGFloat {
    segmentHeight > Tokens.V1.Size.control - Tokens.V1.Space.s2xs
      ? Tokens.V1.Text.body.size : Tokens.V1.Text.meta.size
  }

  private var selectedInk: Color {
    switch style {
    case .standard: return Tokens.V1.Color.ink
    case .accentFill: return Tokens.V1.Color.accentInk
    case .accentOutline: return Tokens.V1.Color.accent
    }
  }

  private var selectedEdge: Color {
    switch style {
    case .standard: return Tokens.V1.Color.rule
    case .accentFill: return .clear
    case .accentOutline: return Tokens.V1.Color.accent
    }
  }

  private var selectedEdgeWidth: CGFloat {
    style == .accentOutline ? Tokens.V1.Size.focusWidth : Tokens.V1.Size.controlRuleWidth
  }
}

/// 分段的底座:默认 paper-3 实底;首页入口卡上用毛玻璃,透出背景图。
private struct SegmentRuntimeIdentifier: ViewModifier {
  let identifier: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let identifier {
      content.runtimeAccessibilityIdentifier(identifier)
    } else {
      content
    }
  }
}

private struct SegmentHelp: ViewModifier {
  let text: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let text, !text.isEmpty {
      content.help(text)
    } else {
      content
    }
  }
}

private struct TrackSurface: ViewModifier {
  let glass: Bool

  func body(content: Content) -> some View {
    if glass {
      content.v1Glass(cornerRadius: Tokens.V1.Radius.sm)
    } else {
      content.background(
        Tokens.V1.Color.paper3, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
    }
  }
}
