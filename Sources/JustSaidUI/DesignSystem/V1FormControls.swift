import SwiftUI

/// Shared form geometry mirrors .field / .popup; call sites choose a size, never restyle the frame.
enum V1FormSize {
  case regular, compact
  var height: CGFloat { self == .compact ? Tokens.V1.Size.controlSm : Tokens.V1.Size.control }
  var inset: CGFloat { self == .compact ? Tokens.V1.Space.xs : Tokens.V1.Space.sm }
  var font: Font { self == .compact ? Tokens.V1.Text.meta.font : Tokens.V1.Text.body.font }
}

struct V1FormSurface: ViewModifier {
  var focused = false
  var hovered = false
  @Environment(\.isEnabled) private var enabled

  func body(content: Content) -> some View {
    content
      .background(
        hovered && enabled ? Tokens.V1.Color.paper2 : Tokens.V1.Color.raised,
        in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
          .strokeBorder(
            focused ? Tokens.V1.Color.focus : Tokens.V1.Color.controlRule,
            lineWidth: focused ? Tokens.V1.Size.focusWidth : Tokens.V1.Size.controlRuleWidth)
      }
      .opacity(enabled ? 1 : Tokens.V1.Feedback.disabledOpacity)
  }
}

struct V1TextField: View {
  let placeholder: String
  @Binding var text: String
  var size: V1FormSize = .regular
  var multiline = false
  var minimumLines = 1
  var focusRequested = false
  var identifier: String
  var onCommit: () -> Void = {}
  @FocusState private var focused: Bool

  var body: some View {
    TextField(
      placeholder, text: $text,
      prompt: Text(placeholder).foregroundColor(Tokens.V1.Color.ink3),
      axis: multiline ? .vertical : .horizontal
    )
    .textFieldStyle(.plain)
    .font(size.font).foregroundStyle(Tokens.V1.Color.ink)
    .lineLimit(multiline ? minimumLines...Int.max : 1...1)
    .padding(.horizontal, size.inset)
    .padding(.vertical, multiline ? Tokens.V1.Space.xs : 0)
    .frame(maxWidth: .infinity, minHeight: size.height, alignment: .leading)
    .focused($focused)
    .modifier(V1FormSurface(focused: focused))
    .onAppear { if focusRequested { focused = true } }
    .onSubmit(onCommit)
    .onChange(of: focused) { wasFocused, isFocused in
      if wasFocused && !isFocused { onCommit() }
    }
    .accessibilityLabel(placeholder)
    .runtimeAccessibilityIdentifier(identifier)
    .runtimeAccessibilityIdentifier("\(identifier).control.input")
  }
}

struct V1PopupLabel: View {
  let value: String
  var placeholder = false
  var size: V1FormSize = .regular
  var symbol = "chevron.down"

  var body: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Text(value).lineLimit(1)
        .foregroundStyle(placeholder ? Tokens.V1.Color.ink3 : Tokens.V1.Color.ink)
      Spacer(minLength: 0)
      Image(systemName: symbol).font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3).accessibilityHidden(true)
    }
    .font(size.font)
    .padding(.leading, size.inset)
    .padding(.trailing, size == .compact ? Tokens.V1.Space.s2xs : Tokens.V1.Space.xs)
    .frame(maxWidth: .infinity, minHeight: size.height, alignment: .leading)
    .contentShape(Rectangle())
  }
}

struct V1Dropdown<Options: View>: View {
  let value: String
  var size: V1FormSize = .regular
  var identifier: String
  @ViewBuilder var options: () -> Options
  @State private var hovering = false
  @FocusState private var focused: Bool

  var body: some View {
    Menu(content: options) {
      V1PopupLabel(value: value, size: size)
        .modifier(V1FormSurface(focused: focused, hovered: hovering))
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    .focused($focused)
    .onHover { hovering = $0 }
    .runtimeAccessibilityIdentifier(identifier)
    .runtimeAccessibilityIdentifier("\(identifier).control.dropdown")
  }
}

/// Search is local to the popover. Only selecting or explicitly creating commits a value.
struct V1ComboBox: View {
  let label: String
  let value: String
  let suggestions: [String]
  /// 选项右侧的一行灰字说明，例如负责人列表里「会议里说的」。
  var details: [String: String] = [:]
  var size: V1FormSize = .regular
  var identifier: String
  /// 「补全」等入口要直接展开时用，与日期框同一套请求方式。
  var focusRequested = false
  var focusRequest = 0
  var onSelect: (String) -> Void
  @State private var presented = false
  @State private var hovering = false
  @FocusState private var focused: Bool

  var body: some View {
    Button {
      presented = true
    } label: {
      V1PopupLabel(
        value: value.isEmpty ? "选择\(label)" : value, placeholder: value.isEmpty, size: size
      )
      .modifier(V1FormSurface(focused: focused || presented, hovered: hovering))
    }
    .buttonStyle(.plain).focused($focused)
    .onHover { hovering = $0 }
    .accessibilityLabel("\(label)：\(value.isEmpty ? "选择或新建" : value)")
    .runtimeAccessibilityIdentifier(identifier)
    .runtimeAccessibilityIdentifier("\(identifier).control.combo")
    .onAppear { if focusRequested { presented = true } }
    .onChange(of: focusRequested) { _, value in if value { presented = true } }
    .onChange(of: focusRequest) { _, _ in if focusRequested { presented = true } }
    .popover(isPresented: $presented, arrowEdge: .bottom) {
      V1ComboOptions(
        label: label, value: value, suggestions: suggestions, details: details,
        identifier: identifier
      ) {
        onSelect($0)
        presented = false
      }
    }
  }
}

struct V1ComboOptions: View {
  let label: String
  let value: String
  let suggestions: [String]
  var details: [String: String] = [:]
  let identifier: String
  var onSelect: (String) -> Void
  @State private var query = ""
  @State private var listHeight: CGFloat = 0
  @Environment(\.dismiss) private var dismiss

  private var name: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var matches: [String] {
    suggestions.filter { name.isEmpty || $0.localizedStandardContains(name) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      V1TextField(
        placeholder: "搜索或新建\(label)", text: $query, focusRequested: true,
        identifier: "\(identifier).search", onCommit: {}
      )
      .onSubmit {
        if let exact = suggestions.first(where: { $0 == name }) {
          onSelect(exact)
        } else if !name.isEmpty {
          onSelect(name)
        }
      }
      ScrollView {
        VStack(spacing: Tokens.V1.Space.s3xs) {
          ForEach(matches, id: \.self) { option in
            Button {
              onSelect(option)
            } label: {
              HStack {
                Text(option)
                Spacer(minLength: Tokens.V1.Space.xs)
                if let detail = details[option] {
                  Text(detail).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
                }
                if option == value { Image(systemName: "checkmark") }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.v1Quiet)
            .runtimeAccessibilityIdentifier("\(identifier).option.\(option)")
          }
          if matches.isEmpty {
            Text("没有匹配的\(label)").font(Tokens.V1.Text.meta.font)
              .foregroundStyle(Tokens.V1.Color.ink3)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        // 偏好值传不出 macOS 的 ScrollView，直接量内容高度。
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
      }
      // 列表按内容收放（最多 side-w 高再滚动），输入新名字时弹层跟着变矮，不留一块空白。
      .frame(height: min(listHeight, Tokens.V1.Size.sideWidth))
      Divider()
      Button(name.isEmpty ? "新建\(label)…" : "新建「\(name)」") { onSelect(name) }
        .buttonStyle(.v1Quiet)
        .disabled(name.isEmpty || suggestions.contains(name))
        .runtimeAccessibilityIdentifier("\(identifier).create")
      if !value.isEmpty {
        Button("清除\(label)") { onSelect("") }.buttonStyle(.v1Quiet)
          .runtimeAccessibilityIdentifier("\(identifier).clear")
      }
    }
    .padding(Tokens.V1.Space.sm)
    .frame(width: Tokens.V1.Size.sideWidth)
    .background(Tokens.V1.Color.raised)
    .onExitCommand { dismiss() }
    .runtimeAccessibilityIdentifier("\(identifier).options")
  }
}
