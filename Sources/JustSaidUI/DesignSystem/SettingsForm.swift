import SwiftUI

// 正文卡片样式限定在 SettingsPage，配置 sheet 沿用紧凑表单。
private struct SettingsCardLayoutKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var settingsCardLayout: Bool {
    get { self[SettingsCardLayoutKey.self] }
    set { self[SettingsCardLayoutKey.self] = newValue }
  }
}

public struct SettingsFormGroup<Content: View, Accessory: View>: View {
  let title: String
  var hint: String?
  @Environment(\.settingsCardLayout) private var cardLayout
  @ViewBuilder var content: () -> Content
  @ViewBuilder var accessory: () -> Accessory

  public init(
    _ title: String, hint: String? = nil,
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    self.title = title
    self.hint = hint
    self.content = content
    self.accessory = accessory
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: cardLayout ? Tokens.V1.Space.sm : Tokens.V1.Space.xs) {
      HStack(alignment: .center, spacing: Tokens.V1.Space.sm) {
        if cardLayout {
          VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
            titleLabel
            hintLabel
          }
        } else {
          titleLabel
          if let hint, !hint.isEmpty {
            Text(hint).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
              .lineLimit(1)
          }
        }
        Spacer(minLength: .zero)
        accessory()
      }
      .padding(.horizontal, cardLayout ? .zero : Tokens.V1.Space.s2xs)
      .runtimeAccessibilityIdentifier("settings.group.\(title).heading")
      VStack(spacing: .zero) { content() }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardLayout ? Tokens.V1.Color.raised : Tokens.V1.Color.paper2)
        .clipShape(
          RoundedRectangle(cornerRadius: cardLayout ? Tokens.V1.Radius.lg : Tokens.V1.Radius.md)
        )
        .overlay {
          RoundedRectangle(cornerRadius: cardLayout ? Tokens.V1.Radius.lg : Tokens.V1.Radius.md)
            .strokeBorder(Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
        }
        .runtimeAccessibilityIdentifier("settings.group.\(title).box")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .runtimeAccessibilityIdentifier("settings.group.\(title).card")
  }
  private var titleLabel: some View {
    Text(title).font(Tokens.V1.Text.heading.font).foregroundStyle(Tokens.V1.Color.ink)
  }

  @ViewBuilder private var hintLabel: some View {
    if let hint, !hint.isEmpty {
      Text(hint).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

}

extension SettingsFormGroup where Accessory == EmptyView {
  public init(
    _ title: String, hint: String? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(title, hint: hint, content: content) { EmptyView() }
  }
}

/// 表单里的一行:左标签定宽,右控件。控件下面可以再带一行只读的当前值。
///
/// `labelWidth` 传 nil 时标签按内容取宽、控件靠右——渠道那种「一行一个东西 + 右侧动作」
/// 的表用这一档;四个角色组用定宽档,两档控件均贴右。
public struct SettingsFormRow<Label: View, Content: View>: View {
  /// 标签列宽。`.standard` = 标签定宽、控件贴右;
  /// `.fit` = 标签按内容取宽、控件靠右(渠道那种「一行一个东西 + 右侧动作」的表)。
  public enum LabelWidth: Equatable, Sendable {
    case standard
    case fit

    var points: CGFloat? {
      switch self {
      case .standard: return Tokens.V1.Size.settingsLabel
      case .fit: return nil
      }
    }
  }

  @Environment(\.settingsCardLayout) private var cardLayout
  var labelWidth: LabelWidth
  /// 控件下面的只读当前值。**只在它和你刚选的不一样时才给**——
  /// 一样的时候说一遍就够了(设计系统:没有状态就什么都不显示)。
  var value: String?
  /// 行间细线。第一行不画。
  var isFirst: Bool
  @ViewBuilder var label: () -> Label
  @ViewBuilder var content: () -> Content

  public init(
    labelWidth: LabelWidth = .standard,
    value: String? = nil,
    isFirst: Bool = false,
    @ViewBuilder label: @escaping () -> Label,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.labelWidth = labelWidth
    self.value = value
    self.isFirst = isFirst
    self.label = label
    self.content = content
  }

  public var body: some View {
    Group {
      if cardLayout { cardRowContent } else { rowContent }
    }
    .padding(.horizontal, cardLayout ? Tokens.V1.Space.md : Tokens.V1.Space.sm)
    .padding(.vertical, cardLayout ? Tokens.V1.Space.xs : Tokens.V1.Space.s3xs)
    .frame(
      minHeight: cardLayout
        ? Tokens.V1.Size.controlLg + Tokens.V1.Space.md : Tokens.V1.Size.settingsRow
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) {
      if !isFirst {
        Rectangle()
          .fill(Tokens.V1.Color.rule)
          .frame(height: Tokens.V1.Size.controlRuleWidth)
      }
    }
  }

  private var cardRowContent: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: Tokens.V1.Space.md) {
        cardLabel.fixedSize(horizontal: true, vertical: false)
        Spacer(minLength: Tokens.V1.Space.xs)
        cardControls.fixedSize(horizontal: true, vertical: false)
      }
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        cardLabel.fixedSize(horizontal: false, vertical: true)
        cardControls.frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var cardLabel: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
      label()
      if labelWidth == .fit { valueText }
    }
  }

  private var cardControls: some View {
    VStack(alignment: .trailing, spacing: Tokens.V1.Space.s2xs) {
      HStack(spacing: Tokens.V1.Space.xs) { content() }
      if labelWidth != .fit { valueText }
    }
  }

  @ViewBuilder
  private var rowContent: some View {
    switch labelWidth {
    case .standard:
      // 标准档:控件作为一组贴右,只读当前值跟随同一右边缘。
      HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.sm) {
        label()
          .frame(width: Tokens.V1.Size.settingsLabel, alignment: .leading)
        VStack(alignment: .trailing, spacing: Tokens.V1.Space.s3xs) {
          HStack(spacing: Tokens.V1.Space.xs) {
            content()
          }
          valueText
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    case .fit:
      // 表档(渠道、名字清单):左边是这一行说的**那个东西**,副行跟着它;
      // 右边是对它的动作,各行右端必须对齐成一列——
      // 副行一长一短就把动作推得参差,眼睛要沿着锯齿找「删除」。
      HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.sm) {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
          label()
          valueText
        }
        Spacer(minLength: Tokens.V1.Space.xs)
        HStack(spacing: Tokens.V1.Space.xs) {
          content()
        }
        .fixedSize()
      }
    }
  }

  @ViewBuilder
  private var valueText: some View {
    if let value, !value.isEmpty {
      Text(value)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

/// 定宽档的标签:一行标题,底下可以再挂一行小字(如「按全长计费」)。
public struct SettingsFormRowLabel: View {
  let label: String
  var detail: String?

  public init(label: String, detail: String? = nil) {
    self.label = label
    self.detail = detail
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: .zero) {
      Text(label)
        .font(Tokens.V1.Text.body.font)
        .foregroundStyle(Tokens.V1.Color.ink2)
      // 行副标签用 meta 12/400。原来是 micro 11/600——副标签比主标签(13/400)还粗,是反的。
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
      }
    }
  }
}

extension SettingsFormRow where Label == SettingsFormRowLabel {
  public init(
    _ label: String,
    labelDetail: String? = nil,
    value: String? = nil,
    isFirst: Bool = false,
    labelWidth: LabelWidth = .standard,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      labelWidth: labelWidth,
      value: value,
      isFirst: isFirst,
      label: { SettingsFormRowLabel(label: label, detail: labelDetail) },
      content: content)
  }
}

/// 密钥尾号徽标。照 `styles.css` 的 `.key`:一把锁 + 后四位,锁用 ok 色。
/// 没存密钥时换成 warn 的一句话——这是设置页唯一需要用户回头处理的状态。
public struct SettingsKeyBadge: View {
  let suffix: String?

  public init(suffix: String?) {
    self.suffix = suffix
  }

  public var body: some View {
    if let suffix, !suffix.isEmpty {
      HStack(spacing: Tokens.V1.Space.s3xs) {
        Image(systemName: "lock.fill")
          .font(Tokens.V1.Text.micro.font)
          .foregroundStyle(Tokens.V1.Color.accent)
        Text("····\(suffix)")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink2)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("密钥已存，尾号 \(suffix)")
    } else {
      Text("未存密钥")
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.warn)
    }
  }
}

/// 表单里整行宽的一句话。**只用于有后果的提示**——
/// 「选到中高推理档会缺轮」是后果,「渠道在这里统一维护」是解释,后者不上画面。
public struct SettingsFormNote: View {
  public enum Tone { case meta, warn }

  let text: String
  var tone: Tone = .meta
  var isFirst: Bool = false

  public init(_ text: String, tone: Tone = .meta, isFirst: Bool = false) {
    self.text = text
    self.tone = tone
    self.isFirst = isFirst
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
      if tone == .warn {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(Tokens.V1.Text.micro.font)
          .foregroundStyle(Tokens.V1.Color.warn)
      }
      Text(text)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(tone == .warn ? Tokens.V1.Color.warn : Tokens.V1.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: .zero)
    }
    .padding(.horizontal, Tokens.V1.Space.sm)
    .padding(.vertical, Tokens.V1.Space.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) {
      if !isFirst {
        Rectangle()
          .fill(Tokens.V1.Color.rule)
          .frame(height: Tokens.V1.Size.controlRuleWidth)
      }
    }
  }
}

/// 设置页浮层的外壳:页名一条、内容、底下一个「完成」。
/// 凭证、模型清单这类**配置一次就不再看**的东西放进来,
/// 主表单上只留一行「现在是什么 + 去配置」——表单是给你改主意用的,不是给你填表用的。
public struct SettingsSheetShell<Content: View>: View {
  let title: String
  var subtitle: String?
  let onDone: () -> Void
  @ViewBuilder var content: () -> Content

  public init(
    _ title: String,
    subtitle: String? = nil,
    onDone: @escaping () -> Void,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.onDone = onDone
    self.content = content
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: .zero) {
      HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
        Text(title)
          .font(Tokens.V1.Text.barTitle.font)
          .foregroundStyle(Tokens.V1.Color.ink)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
        }
        Spacer(minLength: Tokens.V1.Space.xs)
      }
      .padding(.horizontal, Tokens.V1.Space.md)
      .frame(minHeight: Tokens.V1.Size.barHeight)
      .overlay(alignment: .bottom) {
        Rectangle().fill(Tokens.V1.Color.rule)
          .frame(height: Tokens.V1.Size.controlRuleWidth)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
          content()
        }
        .padding(Tokens.V1.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Spacer()
        Button("完成", action: onDone)
          .buttonStyle(.v1Primary)
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, Tokens.V1.Space.md)
      .padding(.vertical, Tokens.V1.Space.sm)
      .overlay(alignment: .top) {
        Rectangle().fill(Tokens.V1.Color.rule)
          .frame(height: Tokens.V1.Size.controlRuleWidth)
      }
    }
    .frame(minWidth: Tokens.V1.Size.settingsForm, minHeight: Tokens.V1.Size.settingsSheetMinHeight)
    .background(Tokens.V1.Color.paper)
  }
}

/// 前三页共用居中单列，词典双区使用全部可用宽度。
enum SettingsPageGeometry {
  static func inset(for width: CGFloat, fullWidth: Bool = false) -> CGFloat {
    fullWidth
      ? Tokens.V1.Space.xl : max(Tokens.V1.Space.md, (width - Tokens.V1.Size.settingsContent) / 2)
  }
}

struct SettingsPage<Content: View>: View {
  var fullWidth = false
  var title: String? = nil
  var subtitle: String? = nil
  @ViewBuilder var content: () -> Content

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
          if let title {
            VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
              Text(title).font(Tokens.V1.Text.title.font).foregroundStyle(Tokens.V1.Color.ink)
              if let subtitle {
                Text(subtitle).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
              }
            }
            .runtimeAccessibilityIdentifier("settings.page-title")
          }
          content()
          SettingsBuildFooter()
        }
        .frame(
          width: max(
            .zero,
            geometry.size.width - SettingsPageGeometry.inset(
              for: geometry.size.width, fullWidth: fullWidth) * 2),
          alignment: .leading
        )
        .runtimeAccessibilityIdentifier("settings.form-column")
        .padding(
          .horizontal, SettingsPageGeometry.inset(for: geometry.size.width, fullWidth: fullWidth)
        )
        .padding(.bottom, Tokens.V1.Space.md)
      }
    }
    .environment(\.settingsCardLayout, true)
    .background(Tokens.V1.Color.paper)
    .tint(Tokens.V1.Color.accent)
  }
}

struct SettingsBuildFooter: View {
  var body: some View {
    Text(ProviderSettingsView.buildLabel)
      .font(Tokens.V1.Text.meta.font.monospaced())
      .foregroundStyle(Tokens.V1.Color.ink3)
      .textSelection(.enabled)
      .runtimeAccessibilityIdentifier("settings.build-footer")
  }
}
