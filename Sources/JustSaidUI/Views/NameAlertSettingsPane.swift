import JustSaidCore
import SwiftUI

/// 设置 · 点名提醒。两种方式的预览直接承担选择入口，预览复用实际提醒组件。
struct NameAlertSettingsPane: View {
  @ObservedObject var preferences: NameAlertPreferencesStore
  @State private var draft = ""

  private var aliases: [String] { preferences.preferences.aliases }
  private var hasValidAliases: Bool { !NameAlertAliasSet(aliases).isEmpty }
  private var remindersEnabled: Bool { preferences.preferences.remindersEnabled }

  /// 预览使用第一个已设名字，不编造会议内容。
  private var previewEvent: NameAlertEvent {
    NameAlertEvent(
      id: 1,
      meeting: 1,
      aliasID: 0,
      aliasText: aliases.first(where: { !$0.isEmpty }) ?? "你的名字",
      kind: .partial,
      decodedRange: 0...1,
      newCallCount: 1
    )
  }

  var body: some View {
    SettingsPage(title: "点名提醒", subtitle: "设置你希望被怎样叫到、怎样提醒。") {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
        remindGroup
        styleGroup
          .disabled(!remindersEnabled)
          .opacity(remindersEnabled ? 1 : Tokens.V1.Feedback.disabledOpacity)
        aliasGroup
          .disabled(!remindersEnabled)
          .opacity(remindersEnabled ? 1 : Tokens.V1.Feedback.disabledOpacity)
      }
    }
    .runtimeAccessibilityIdentifier("settings.name-alerts")
  }

  private var remindGroup: some View {
    SettingsFormGroup(
      "提醒", hint: "录制时，系统声音里叫到你的名字会提醒你。"
    ) {
      SettingsFormRow("点名提醒", labelDetail: "开关只控制提醒，名字设置会保留。", isFirst: true) {
        Toggle(
          "点名提醒",
          isOn: Binding(
            get: { preferences.preferences.remindersEnabled },
            set: { preferences.setRemindersEnabled($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.v1Switch)
        .runtimeAccessibilityIdentifier("settings.name-alerts.enabled")
      }
      SettingsFormRow("提示音", labelDetail: "有人叫到你时播放提示音。") {
        Toggle(
          "提示音",
          isOn: Binding(
            get: { preferences.preferences.soundEnabled },
            set: { preferences.setSoundEnabled($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.v1Switch)
        .runtimeAccessibilityIdentifier("settings.name-alerts.sound")
      }
      .disabled(!remindersEnabled)
      .opacity(remindersEnabled ? 1 : Tokens.V1.Feedback.disabledOpacity)
      if !remindersEnabled {
        SettingsFormNote(
          "暂停期间不弹出、不发声，录制中仍在本机识别；恢复后不补发已识别的点名。")
      }
    }
  }

  private var aliasGroup: some View {
    SettingsFormGroup(
      "名字或昵称", hint: "加入别人可能叫你的名字。"
    ) {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
        if !aliases.isEmpty {
          NameAlertAliasFlow {
            ForEach(Array(aliases.enumerated()), id: \.offset) { index, alias in
              aliasChip(alias, at: index)
            }
          }
          .runtimeAccessibilityIdentifier("settings.name-alerts.alias-chips")
        }
        HStack(spacing: Tokens.V1.Space.xs) {
          V1TextField(
            placeholder: "输入名字或昵称", text: $draft,
            identifier: "settings.name-alerts.alias-input"
          )
          .onSubmit(addDraft)
          Button("添加", action: addDraft)
            .buttonStyle(.v1Outline)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .runtimeAccessibilityIdentifier("settings.name-alerts.alias-add")
        }
        Text("输入后按回车添加。")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
      }
      .padding(Tokens.V1.Space.md)
      if !hasValidAliases {
        SettingsFormNote("还没有有效的名字或昵称，添加后才会提醒", tone: .warn)
          .runtimeAccessibilityIdentifier("settings.name-alerts.needs-aliases")
      }
      SettingsFormNote("名字只保存在本机，识别在本机完成。")
    }
  }

  private func aliasChip(_ alias: String, at index: Int) -> some View {
    HStack(spacing: Tokens.V1.Space.s2xs) {
      Text(alias)
        .font(Tokens.V1.Text.body.font)
        .foregroundStyle(Tokens.V1.Color.ink)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(alias)
      Button {
        var updated = aliases
        updated.remove(at: index)
        preferences.setAliases(updated)
      } label: {
        Image(systemName: "xmark")
          .font(Tokens.V1.Text.meta.font)
      }
      .buttonStyle(.v1Quiet)
      .accessibilityLabel("删除名字「\(alias)」")
      .runtimeAccessibilityIdentifier("settings.name-alerts.alias-remove.\(index)")
    }
    .padding(.leading, Tokens.V1.Space.sm)
    .padding(.trailing, Tokens.V1.Space.s2xs)
    .frame(height: Tokens.V1.Size.control)
    .background(Tokens.V1.Color.raised, in: Capsule())
    .overlay {
      Capsule().strokeBorder(Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
    }
    .runtimeAccessibilityIdentifier("settings.name-alerts.alias.\(index)")
  }

  private var styleGroup: some View {
    SettingsFormGroup(
      "显示与方式", hint: "选一种适合你的提醒方式。"
    ) {
      SettingsFormRow("悬浮显示", labelDetail: "主窗在后时，选择内容的显示位置。", isFirst: true) {
        V1SegmentedPicker(
          "悬浮显示",
          selection: Binding(
            get: { preferences.preferences.displayMode },
            set: { preferences.setDisplayMode($0) }
          ),
          options: [
            .init(NameAlertPreferences.DisplayMode.dock, "侧边吸附"),
            .init(NameAlertPreferences.DisplayMode.window, "悬浮小窗"),
            .init(NameAlertPreferences.DisplayMode.off, "关闭悬浮显示"),
          ]
        )
        .fixedSize()
        .runtimeAccessibilityIdentifier("settings.name-alerts.display-mode")
      }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Tokens.V1.Space.md) {
          previewCard(.quiet).frame(minWidth: previewMinimumWidth)
          previewCard(.strong).frame(minWidth: previewMinimumWidth)
        }
        VStack(spacing: Tokens.V1.Space.md) {
          previewCard(.quiet)
          previewCard(.strong)
        }
      }
      .padding(Tokens.V1.Space.md)
      .runtimeAccessibilityIdentifier("settings.name-alerts.previews")
      .runtimeAccessibilityIdentifier("settings.name-alerts.reminder-style")
      SettingsFormNote("独立强提醒在投屏时仍可能被共享。")
    }
  }

  private var previewMinimumWidth: CGFloat {
    Tokens.V1.Size.sideWidth - Tokens.V1.Space.lg - Tokens.V1.Space.md
  }

  private func previewCard(_ style: NameAlertPreferences.ReminderStyle) -> some View {
    let isCurrent = preferences.preferences.reminderStyle == style
    let title = style == .quiet ? "静默高亮" : "独立强提醒"
    let key = style == .quiet ? "quiet" : "strong"
    return Button {
      preferences.setReminderStyle(style)
    } label: {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
        HStack(spacing: Tokens.V1.Space.xs) {
          Text(title)
            .font(Tokens.V1.Text.strong.font)
            .foregroundStyle(Tokens.V1.Color.ink)
          Spacer(minLength: .zero)
          Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
            .font(Tokens.V1.Text.heading.font)
            .foregroundStyle(isCurrent ? Tokens.V1.Color.accent : Tokens.V1.Color.controlRule)
        }
        Text(style == .quiet ? "在现有界面中高亮提醒。" : "屏幕顶部显示一颗提醒胶囊。")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
        previewScene(style)
          .padding(.top, Tokens.V1.Space.sm)
      }
      .padding(Tokens.V1.Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: Tokens.V1.Radius.md))
    }
    .buttonStyle(NameAlertPreviewButtonStyle(isSelected: isCurrent))
    .accessibilityLabel(title)
    .accessibilityValue(isCurrent ? "已选择" : "未选择")
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    .runtimeAccessibilityIdentifier("settings.name-alerts.reminder-style.\(key)")
  }

  private func previewScene(_ style: NameAlertPreferences.ReminderStyle) -> some View {
    Group {
      if style == .quiet {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
          placeholderLine
          NameAlertNameZone(event: previewEvent) { _ in }
            .padding(Tokens.V1.Space.xs)
            .background(
              Tokens.V1.Color.accentSoft, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
          placeholderLine.padding(.trailing, Tokens.V1.Space.xl)
        }
      } else {
        NameAlertStrongCard(event: previewEvent, onAcknowledge: { _ in }, showsShadow: false)
      }
    }
    .padding(Tokens.V1.Space.xs)
    .frame(maxWidth: .infinity)
    .frame(height: Tokens.V1.Space.s2xl * 2)
    .background(Tokens.V1.Color.raised, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var placeholderLine: some View {
    Capsule()
      .fill(Tokens.V1.Color.rule)
      .frame(height: Tokens.V1.Space.s2xs)
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

private struct NameAlertPreviewButtonStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    PreviewBody(configuration: configuration, isSelected: isSelected)
  }

  private struct PreviewBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .background(
          isEnabled && isHovering ? Tokens.V1.Color.paper3 : Tokens.V1.Color.paper2,
          in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
        )
        .overlay {
          RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
            .strokeBorder(
              isSelected ? Tokens.V1.Color.accent : Tokens.V1.Color.rule,
              lineWidth: isSelected ? Tokens.V1.Size.focusWidth : Tokens.V1.Size.controlRuleWidth)
        }
        .opacity(configuration.isPressed ? Tokens.V1.Feedback.pressedOpacity : 1)
        .onHover { isHovering = $0 }
    }
  }
}

/// Chip 按真实文字宽度换行；长名字在一行可用宽度内截断。
private struct NameAlertAliasFlow: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(subviews, width: proposal.width ?? .infinity).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let arrangement = arrange(subviews, width: bounds.width)
    for (index, frame) in arrangement.frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
    let gap = Tokens.V1.Space.xs
    var x: CGFloat = .zero
    var y: CGFloat = .zero
    var rowHeight: CGFloat = .zero
    var usedWidth: CGFloat = .zero
    var frames: [CGRect] = []
    for subview in subviews {
      let ideal = subview.sizeThatFits(.unspecified)
      let size = subview.sizeThatFits(
        ProposedViewSize(width: min(width, ideal.width), height: ideal.height))
      if x > .zero && x + size.width > width {
        x = .zero
        y += rowHeight + gap
        rowHeight = .zero
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      usedWidth = max(usedWidth, x + size.width)
      rowHeight = max(rowHeight, size.height)
      x += size.width + gap
    }
    return (CGSize(width: usedWidth, height: y + rowHeight), frames)
  }
}
