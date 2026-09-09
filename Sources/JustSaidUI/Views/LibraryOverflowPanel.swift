import SwiftUI

/// 库顶栏 ⋯ 溢出面板(08-21):popover 动作卡,不是原生 Menu。
/// 语言/缩放已平铺回库顶栏(08-21 拆分:有状态、常切换的控件不藏 popover),
/// 这里只留低频动作;headless 弹不出 popover,故 public 供单独摆页探针。
public struct LibraryOverflowPanel: View {
  private let onImport: (() -> Void)?
  private let onReload: (() -> Void)?

  public init(
    onImport: (() -> Void)? = nil,
    onReload: (() -> Void)? = nil
  ) {
    self.onImport = onImport
    self.onReload = onReload
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
      actionRow(
        title: "导入录音…",
        systemImage: "square.and.arrow.down",
        identifier: "library.toolbar.overflow.import",
        action: onImport
      )
      actionRow(
        title: "重新扫描",
        systemImage: "arrow.clockwise",
        identifier: "library.toolbar.overflow.reload",
        action: onReload
      )
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.md)
    .frame(width: Tokens.Layout.overflowPanelWidth, alignment: .leading)
    .background(Tokens.Color.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.widget))
    .tokenShadow(Tokens.Shadow.sh3)
    .runtimeAccessibilityIdentifier("library.toolbar.overflow.panel")
  }

  private func actionRow(
    title: String,
    systemImage: String,
    identifier: String,
    action: (() -> Void)?
  ) -> some View {
    Button {
      action?()
    } label: {
      HStack(spacing: Tokens.Spacing.sm) {
        Image(systemName: systemImage)
          .accessibilityHidden(true)
        Text(title)
        Spacer(minLength: 0)
      }
      .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      .foregroundStyle(Tokens.Color.ink2)
      .padding(.vertical, Tokens.Spacing.xs)
      .contentShape(Rectangle())
    }
    .buttonStyle(.textAction)
    .disabled(action == nil)
    .runtimeAccessibilityIdentifier(identifier)
  }
}
