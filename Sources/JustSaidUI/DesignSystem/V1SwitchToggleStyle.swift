import AppKit
import SwiftUI

/// V1 switch appearance stays accent in inactive windows; only disabled controls dim.
/// A native Toggle supplies accessibility semantics without rendering the system switch.
public struct V1SwitchToggleStyle: ToggleStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    SwitchBody(configuration: configuration)
  }

  private struct SwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    private var showsFocus: Bool {
      isEnabled && isFocused && NSApplication.shared.isFullKeyboardAccessEnabled
    }

    var body: some View {
      LabeledContent {
        Capsule()
          .fill(configuration.isOn ? Tokens.V1.Color.accent : Tokens.V1.Color.paper3)
          .overlay {
            Capsule()
              .fill(configuration.isOn ? Tokens.V1.Color.accentInk : Tokens.V1.Color.scrim)
              .opacity(
                isEnabled && isHovering
                  ? (configuration.isOn ? Tokens.V1.Feedback.primaryHoverOpacity : 1) : 0)
          }
          .overlay {
            Capsule()
              .strokeBorder(
                showsFocus
                  ? Tokens.V1.Color.focus
                  : (configuration.isOn ? Tokens.V1.Color.accent : Tokens.V1.Color.controlRule),
                lineWidth: showsFocus ? Tokens.V1.Size.focusWidth : Tokens.V1.Size.controlRuleWidth)
          }
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle()
              .fill(Tokens.V1.Color.knob)
              .frame(width: Tokens.V1.Space.md, height: Tokens.V1.Space.md)
              .shadow(
                color: Tokens.V1.Shadow.control.color, radius: Tokens.V1.Shadow.control.radius,
                y: Tokens.V1.Shadow.control.y
              )
              .padding(.horizontal, Tokens.V1.Space.s3xs + Tokens.V1.Size.controlRuleWidth)
          }
          .frame(width: Tokens.V1.Size.chipsRowHeight, height: Tokens.V1.Size.controlSm)
          .accessibilityHidden(true)
      } label: {
        configuration.label
      }
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : Tokens.V1.Feedback.disabledOpacity)
      .focusable(isEnabled)
      .focusEffectDisabled()
      .focused($isFocused)
      .onTapGesture {
        guard isEnabled else { return }
        isFocused = true
        configuration.isOn.toggle()
      }
      .onKeyPress(.space) {
        guard isEnabled else { return .ignored }
        configuration.isOn.toggle()
        return .handled
      }
      .onHover { isHovering = $0 }
      .accessibilityRepresentation {
        Toggle(configuration)
          .toggleStyle(.switch)
          .labelsVisibility(.visible)
      }
      .animation(
        reduceMotion ? nil : .easeOut(duration: Tokens.V1.Motion.fast),
        value: configuration.isOn
      )
      .animation(
        reduceMotion ? nil : .easeOut(duration: Tokens.V1.Motion.fast), value: isHovering)
    }
  }
}

extension ToggleStyle where Self == V1SwitchToggleStyle {
  public static var v1Switch: V1SwitchToggleStyle { V1SwitchToggleStyle() }
}
