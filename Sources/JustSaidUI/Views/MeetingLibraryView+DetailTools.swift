import JustSaidCore
import SwiftUI

extension MeetingLibraryView {
  func tabBar(_ item: MeetingLibraryItem) -> some View {
    let namingPendingCount = model.namingSuggestionRows(for: item).pendingPrefillCount
    return HStack(spacing: Tokens.Spacing.xs) {
      ForEach(MeetingDetailTab.allCases) { tab in
        LibraryDetailTabButton(
          tab: tab,
          isSelected: model.tab == tab,
          isEmpty: !model.hasContent(for: item, tab: tab),
          namingPendingCount: tab == .transcript ? namingPendingCount : 0
        ) {
          model.tab = tab
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.xs)
  }

  func hasMinutesToolContent(_ item: MeetingLibraryItem) -> Bool {
    if model.hasEnglishMinutes(for: item) { return true }
    if model.minutesVariant == .chinese, model.minutesRevisions.count > 1 {
      return true
    }
    return model.activeLiveMinutesDraft(for: item) == nil
      && model.canOpenCheckWorkbench(for: item)
  }

  @ViewBuilder
  func minutesToolRow(_ item: MeetingLibraryItem) -> some View {
    HStack(spacing: Tokens.Spacing.xs) {
      if model.hasEnglishMinutes(for: item) {
        Picker("纪要语言", selection: $model.minutesVariant) {
          ForEach(MinutesVariant.allCases) { variant in
            Text(variant.title).tag(variant)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 96)
        .accessibilityLabel("切换纪要语言，中文版或英文版")
      }
      if model.minutesVariant == .chinese, model.minutesRevisions.count > 1 {
        Picker("纪要版本", selection: $model.minutesRevisionID) {
          Text("最新").tag(nil as String?)
          ForEach(model.minutesRevisions.reversed()) { revision in
            Text(revision.label).tag(revision.id as String?)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 168)
        .runtimeAccessibilityIdentifier("library.minutes-revision-picker")
      }
      Spacer(minLength: 0)
      if model.activeLiveMinutesDraft(for: item) == nil,
        model.canOpenCheckWorkbench(for: item)
      {
        Toggle("核对", isOn: $model.showsCheckWorkbench)
          .toggleStyle(.checkbox)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink3)
          .help(
            "把待核数字、决定与待办列成核对队列，与转写原话并排逐条判定；"
              + "判定只写 check.json，纪要与转写产物一个字节不动"
          )
          .runtimeAccessibilityIdentifier("library.minutes.check-toggle")
      }
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.xxs)
    .background(Tokens.Color.pane)
    .runtimeAccessibilityIdentifier("library.minutes.tools")
  }

  func transcriptToolRow(_ item: MeetingLibraryItem) -> some View {
    HStack(spacing: Tokens.Spacing.xs) {
      Button {
        showTranscriptSearch()
      } label: {
        HStack(spacing: Tokens.Spacing.xxs) {
          Image(systemName: "magnifyingglass")
            .accessibilityHidden(true)
          Text("搜索")
        }
      }
      .buttonStyle(.toolbarPill)
      .keyboardShortcut("f", modifiers: .command)
      .help("搜索完整转写 ⌘F")
      .runtimeAccessibilityIdentifier("transcript.search.trigger")
      Button {
        isShowingChapterDirectory = true
      } label: {
        HStack(spacing: Tokens.Spacing.xxs) {
          Image(systemName: "list.bullet")
            .accessibilityHidden(true)
          Text("章节目录")
        }
      }
      .buttonStyle(.toolbarPill)
      .popover(isPresented: $isShowingChapterDirectory, arrowEdge: .bottom) {
        ChapterDirectoryView(topics: model.selectedHistoryTopics) { topicID in
          selectPostMeetingChapter(topicID)
        }
      }
      .runtimeAccessibilityIdentifier("library.chapter-directory.trigger")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.xxs)
    .background(Tokens.Color.pane)
    .runtimeAccessibilityIdentifier("library.transcript.tools")
  }
}

private struct LibraryDetailTabButton: View {
  let tab: MeetingDetailTab
  let isSelected: Bool
  let isEmpty: Bool
  let namingPendingCount: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      // 键帽不进页签(2026-08-21 用户拍板):opacity 占位版会让选中底拖一截空色尾,
      // 快捷键提示走 .help,选中色块只包实际内容、宽度与悬停彻底解耦。
      HStack(spacing: Tokens.Spacing.xxs) {
        Text(tab.title)
        if tab == .transcript {
          TranscriptTabNamingBadge(pendingCount: namingPendingCount)
        }
        if isEmpty {
          SectionCountBadge(label: "空", quiet: true)
        }
      }
      .font(
        .system(
          size: Tokens.FontSize.uiEmphasis,
          weight: isSelected ? .semibold : .regular
        )
      )
      .foregroundStyle(isSelected ? Tokens.Color.acDeep : Tokens.Color.ink2)
      .padding(.horizontal, Tokens.Spacing.sm)
      .padding(.vertical, Tokens.Spacing.xxs)
      .background(
        RoundedRectangle(cornerRadius: Tokens.Radius.control)
          .fill(isSelected ? Tokens.Color.acSoft : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.control)
          .stroke(isSelected ? Tokens.Color.acLine : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .keyboardShortcut(tab.keyboardEquivalent, modifiers: .command)
    .runtimeAccessibilityIdentifier("library.tab.\(tab.rawValue)")
    .hoverRowBackground(cornerRadius: Tokens.Radius.control)
    .help("\(tab.title) \(tab.keycapLabel)")
    .accessibilityHint(tab.keycapLabel)
  }
}
