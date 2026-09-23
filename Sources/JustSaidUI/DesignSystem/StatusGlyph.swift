import SwiftUI

/// A fixed status column. Callers supply the full, contextual spoken/hover description.
public struct StatusGlyph: View {
  public enum State: String, CaseIterable {
    case done, running, attention, confirmed, none

    public var systemImage: String {
      switch self {
      case .done: return "checkmark"
      case .running: return "clock.arrow.circlepath"
      case .attention: return "exclamationmark.triangle"
      case .confirmed: return "checkmark.circle"
      case .none: return "minus"
      }
    }

    fileprivate var color: Color {
      switch self {
      case .done: return Tokens.V1.Color.ink3
      case .running: return Tokens.V1.Color.accent
      case .attention: return Tokens.V1.Color.warn
      case .confirmed: return Tokens.V1.Color.ink2
      case .none: return Tokens.V1.Color.ink4
      }
    }
  }

  public let state: State
  public let label: String

  public init(_ state: State, label: String) {
    self.state = state
    self.label = label
  }

  public var body: some View {
    Image(systemName: state.systemImage)
      .font(Tokens.V1.Text.label.font)
      .foregroundStyle(state.color)
      .frame(width: Tokens.V1.Size.statusGlyphWidth)
      .help(label)
      .accessibilityLabel(label)
      .runtimeAccessibilityIdentifier("v1.status-glyph.\(state.rawValue)")
  }
}
