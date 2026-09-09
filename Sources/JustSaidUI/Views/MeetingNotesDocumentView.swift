import SwiftUI

/// 会后笔记保留原文顺序，只把 NotesWriter 已落盘的时间戳变成回跳入口。
struct MeetingNotesDocumentView: View {
  let entries: [MeetingNoteEntry]
  let emptyHint: String
  let onJumpToTranscript: (TimeInterval) -> Void
  var scrollOffset: Binding<CGFloat>? = nil
  var embedded: Bool = false

  @Environment(\.textScale) private var textScale

  private var notesStack: some View {
    LazyVStack(alignment: .leading, spacing: Tokens.Spacing.xsm) {
      ForEach(entries) { entry in
        HStack(alignment: .top, spacing: Tokens.Spacing.xsm) {
          if let seconds = entry.seconds, let timecode = entry.timecode {
            Button {
              onJumpToTranscript(seconds)
            } label: {
              TranscriptAnchorChip(label: shortLabel(timecode), fontSize: 10, chromeless: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回跳转写 \(timecode)")
          }
          Text(entry.text)
            .font(.system(size: textScale.size(Tokens.FontSize.body)))
            .foregroundStyle(Tokens.Color.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, Tokens.Spacing.xsm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.cardWash)
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.Radius.widget)
            .stroke(Tokens.Color.line, lineWidth: 1)
        )
      }
    }
    .frame(maxWidth: Tokens.Layout.readingContentWidth, alignment: .leading)
    .padding(Tokens.Spacing.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var body: some View {
    if entries.isEmpty {
      Text(emptyHint)
        .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
        .foregroundStyle(Tokens.Color.ink3)
        .multilineTextAlignment(embedded ? .leading : .center)
        .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity, alignment: embedded ? .leading : .center)
        .padding(Tokens.Spacing.lg)
    } else if embedded {
      notesStack
        .runtimeAccessibilityIdentifier("library.anchored-notes")
    } else {
      ScrollView {
        notesStack
      }
      .rememberedScrollOffset(scrollOffset)
      .runtimeAccessibilityIdentifier("library.anchored-notes")
    }
  }

  private func shortLabel(_ timecode: String) -> String {
    let parts = timecode.split(separator: ":")
    guard parts.count == 3, parts.first == "00" else { return timecode }
    return parts.dropFirst().joined(separator: ":")
  }
}
