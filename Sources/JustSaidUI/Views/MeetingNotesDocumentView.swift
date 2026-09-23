import SwiftUI

/// 会后笔记保留原文顺序，只把 NotesWriter 已落盘的时间戳变成回跳入口。
struct MeetingNotesDocumentView: View {
  let entries: [MeetingNoteEntry]
  let emptyHint: String
  let onJumpToTranscript: (TimeInterval) -> Void
  var scrollOffset: Binding<CGFloat>? = nil
  var embedded: Bool = false
  /// 放进右栏(300 宽)时用。正文那份留白是给整页宽度准备的,栏里再铺一次就
  /// 把 56 的时间戳列推成一条空沟,文字挤在右边一小条里。
  var compact: Bool = false

  @Environment(\.textScale) private var textScale

  private var notesStack: some View {
    // 原来每条笔记各自一张描边卡。这一页外面已经是一块内容区,里面再铺一堆小卡就是卡中卡
    // (F2 明写「没有卡中卡」,会议页 2026-09-20 已按这条拆过一轮)。
    // 改成细线分隔的行:笔记是一条条流水,不是一张张卡片。
    LazyVStack(alignment: .leading, spacing: .zero) {
      ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
        HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.sm) {
          if let seconds = entry.seconds, let timecode = entry.timecode {
            Button {
              onJumpToTranscript(seconds)
            } label: {
              Text(shortLabel(timecode))
                .font(Tokens.V1.Text.timecode.font)
                .foregroundStyle(Tokens.V1.Color.accent)
                .frame(width: Tokens.V1.Size.meetingAnchorWidth, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回跳转写 \(timecode)")
            .help("回跳到这一刻的转写")
          } else {
            // 没有时间戳的笔记也要对齐,否则整列文字会左右错开。
            Color.clear.frame(width: Tokens.V1.Size.meetingAnchorWidth, height: 1)
          }
          Text(entry.text)
            .font(.system(size: textScale.size(Tokens.FontSize.body)))
            .foregroundStyle(Tokens.V1.Color.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Tokens.V1.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
          if index > 0 {
            Rectangle().fill(Tokens.V1.Color.rule).frame(height: 1)
          }
        }
      }
    }
    .frame(maxWidth: compact ? .infinity : Tokens.V1.Size.reading, alignment: .leading)
    .padding(.horizontal, compact ? .zero : Tokens.V1.Space.lg)
    .padding(.vertical, Tokens.V1.Space.xs)
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
