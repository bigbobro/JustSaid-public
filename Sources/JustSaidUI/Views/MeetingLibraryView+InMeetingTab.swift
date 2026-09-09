import JustSaidCore
import SwiftUI

extension MeetingLibraryView {
  /// 会中记录页:总结留痕在上、补充记录在下。两段功能(版本回看、时间戳回跳)不丢。
  func inMeetingPage(_ item: MeetingLibraryItem) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
        inMeetingHistorySection(item)
        Divider()
        inMeetingNotesSection(item)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .rememberedScrollOffset(tabScrollBinding(for: .inMeeting))
    .runtimeAccessibilityIdentifier("library.in-meeting")
  }

  private func inMeetingHistorySection(_ item: MeetingLibraryItem) -> some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      HStack(spacing: Tokens.Spacing.xs) {
        Text("总结留痕")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink3)
        if !model.selectedHistoryTopics.isEmpty {
          SectionCountBadge(value: model.selectedHistoryTopics.count)
        }
        if model.snapshots.count > 1 {
          Picker("版本", selection: $model.snapshotID) {
            Text("全部留痕").tag(nil as String?)
            ForEach(model.snapshots) { snapshot in
              Text(snapshot.label).tag(snapshot.id as String?)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 148)
          .runtimeAccessibilityIdentifier("library.in-meeting.history-revision-picker")
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Tokens.Spacing.lg)
      .padding(.top, Tokens.Spacing.sm)
      SummaryTopicCardsDocumentView(
        topics: model.selectedHistoryTopics,
        emptyHint: model.inMeetingHistoryEmptyHint(),
        onJumpToTranscript: model.jumpToTranscript,
        embedded: true
      )
    }
  }

  private func inMeetingNotesSection(_ item: MeetingLibraryItem) -> some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      HStack(spacing: Tokens.Spacing.xs) {
        Text("补充记录")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink3)
        let noteCount = model.noteEntries(for: item).count
        if noteCount > 0 {
          SectionCountBadge(value: noteCount)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Tokens.Spacing.lg)
      MeetingNotesDocumentView(
        entries: model.noteEntries(for: item),
        emptyHint: model.inMeetingNotesEmptyHint(),
        onJumpToTranscript: model.jumpToTranscript,
        embedded: true
      )
    }
  }
}
