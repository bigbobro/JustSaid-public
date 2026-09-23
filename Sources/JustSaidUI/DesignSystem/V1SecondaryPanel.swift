import SwiftUI

/// Filters and smart views share one secondary-panel surface, distinct from the app rail.
struct V1SecondaryPanelSurface: ViewModifier {
  func body(content: Content) -> some View {
    content.frame(width: Tokens.V1.Size.panelWidth)
      .background(Tokens.V1.Color.paper)
      .overlay(alignment: .trailing) {
        Rectangle().fill(Tokens.V1.Color.rule).frame(width: Tokens.V1.Size.controlRuleWidth)
      }
  }
}

struct V1SecondaryPanelHeader<Accessory: View>: View {
  let title: String
  var titleIdentifier = "secondary-panel.heading"
  @ViewBuilder var accessory: () -> Accessory
  var body: some View {
    HStack {
      Text(title).font(Tokens.V1.Text.heading.font).foregroundStyle(Tokens.V1.Color.ink)
        .runtimeAccessibilityIdentifier(titleIdentifier)
      Spacer()
      accessory()
    }
    .padding(.horizontal, Tokens.V1.Space.xs)
    .frame(height: Tokens.V1.Size.barHeight)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
  }
}

struct V1SecondaryPanelRowSurface: ViewModifier {
  var selected: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hovering = false
  func body(content: Content) -> some View {
    content
      .foregroundStyle(selected ? Tokens.V1.Color.accent : Tokens.V1.Color.ink2)
      .background(
        selected
          ? Tokens.V1.Color.accentSoft : (hovering && enabled ? Tokens.V1.Color.paper2 : .clear),
        in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
      )
      .onHover { hovering = $0 }
  }
}

struct V1SecondaryPanelRowStyle: ButtonStyle {
  var selected: Bool
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Tokens.V1.Text.meta.font)
      .padding(.horizontal, Tokens.V1.Space.xs)
      .frame(height: Tokens.V1.Size.control, alignment: .leading)
      .contentShape(Rectangle())
      .modifier(V1SecondaryPanelRowSurface(selected: selected))
  }
}
