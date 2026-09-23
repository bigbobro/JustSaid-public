import AppKit
import JustSaidCore
import SwiftUI

/// The recording title owns its edit session; recording and persistence stay in RecordingSession.
struct CurrentMeetingTitleField: View {
  @ObservedObject var session: RecordingSession
  @Binding var title: String
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField("会议名称", text: $title)
      .textFieldStyle(.plain)
      .font(.system(size: Tokens.FontSize.body, weight: .semibold))
      .foregroundStyle(Tokens.Color.ink)
      .frame(width: 180)
      .padding(.horizontal, Tokens.Spacing.xs)
      .padding(.vertical, Tokens.Spacing.hairline)
      .background(Tokens.Color.pane, in: RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.chipLarge)
          .stroke(isFocused ? Tokens.Color.ac : Tokens.Color.line, lineWidth: 1)
      )
      .focused($isFocused)
      .onSubmit {
        isFocused = false
        commit()
      }
      .background(TitleEditingBoundary(isEditing: isFocused, onEndEditing: commit))
      .onChange(of: isFocused) { _, focused in
        if !focused { commit() }
      }
      .onChange(of: session.currentTitle) { _, current in
        if let current, !isFocused { title = current }
      }
      .onAppear { title = session.currentTitle ?? title }
      .accessibilityLabel("当前会议名称，可编辑")
      .runtimeAccessibilityIdentifier("cockpit.meeting-title")
  }

  private func commit() {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let desired = trimmed.isEmpty ? "会议" : trimmed
    guard desired != session.currentTitle else {
      title = desired
      return
    }
    if session.renameCurrentMeeting(to: desired) {
      title = desired
    } else {
      title = session.currentTitle ?? desired
    }
  }
}

/// Blank SwiftUI views are not focus targets. End just this editor before an outside mouseDown
/// reaches its destination, so buttons and other text fields still receive the original event.
private struct TitleEditingBoundary: NSViewRepresentable {
  let isEditing: Bool
  let onEndEditing: () -> Void

  func makeNSView(context: Context) -> BoundaryView { BoundaryView() }

  func updateNSView(_ view: BoundaryView, context: Context) {
    view.onEndEditing = onEndEditing
    view.isEditing = isEditing
  }

  static func dismantleNSView(_ view: BoundaryView, coordinator: ()) {
    view.isEditing = false
  }

  final class BoundaryView: NSView {
    var isEditing = false { didSet { updateMonitor() } }
    var onEndEditing: () -> Void = {}
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateMonitor()
    }

    private func updateMonitor() {
      if isEditing, window != nil {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
          [weak self] event in
          guard let self, let window = self.window, event.window === window,
            !self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
            let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
            self.bounds.intersects(editor.convert(editor.bounds, to: self))
          else { return event }
          // Only resign this title, before the destination has acquired focus. Do not also
          // clear SwiftUI FocusState here: its deferred update can steal the new field's focus.
          if window.makeFirstResponder(nil) {
            // A destination button can unmount this view before SwiftUI observes lost focus.
            self.onEndEditing()
          }
          return event
        }
      } else if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }

    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}
