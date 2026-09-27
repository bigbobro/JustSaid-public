import JustSaidCore
import SwiftUI

extension MeetingLibraryView {
  func tabBar(_ item: MeetingLibraryItem) -> some View {
    let namingPendingCount = model.namingSuggestionRows(for: item).pendingPrefillCount
    return HStack(spacing: Tokens.Spacing.xs) {
      ForEach(MeetingDetailTab.visibleCases) { tab in
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
    // #94:入口藏起后「核对」不再给工具行贡献内容——漏掉这一半,工具行会剩一条
    // 空的 pane 色带,比拿掉入口更显眼。
    return model.verifyWorkbenchEnabled
      && model.activeLiveMinutesDraft(for: item) == nil
      && model.canOpenCheckWorkbench(for: item)
  }

  @ViewBuilder
  func minutesToolRow(_ item: MeetingLibraryItem) -> some View {
    HStack(spacing: Tokens.Spacing.xs) {
      if model.hasEnglishMinutes(for: item) {
        V1SegmentedPicker(
          "切换纪要语言，中文版或英文版", selection: $model.minutesVariant,
          options: MinutesVariant.allCases.map { .init($0, $0.title) }
        )
        .fixedSize()
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
      // #94(2026-09-11 owner 拍板「藏」):默认不渲染核对入口,代码与 check.json
      // 读写原样保留;内部开关 `justsaid.verifyWorkbenchEnabled` 置真即恢复改前行为。
      if model.verifyWorkbenchEnabled,
        model.activeLiveMinutesDraft(for: item) == nil,
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
    let todo = model.namingTodoCount(for: item)
    return HStack(spacing: Tokens.V1.Space.xs) {
      Button {
        showsSpeakerNaming = true
      } label: {
        Label(todo > 0 ? "发言人 · 待认名 \(todo)" : "发言人", systemImage: "person.text.rectangle")
      }
      .buttonStyle(.v1Outline)
      .disabled(model.speakerRoster(for: item).isEmpty)
      .help("查看发言、核对名字，并决定哪些内容不进纪要")
      .runtimeAccessibilityIdentifier("transcript.naming.trigger")
      Button {
        model.beginTranscriptBatch(of: item)
      } label: {
        Label("选段", systemImage: "text.badge.checkmark")
      }
      .buttonStyle(.v1Outline)
      .disabled(model.isTranscriptBatchSelecting || !model.canEditTranscript(for: item))
      .help("进入选段：点击起点，滚动后点击终点，再设为不进纪要")
      .runtimeAccessibilityIdentifier("transcript.batch.start")
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
        ChapterDirectoryView(
          topics: model.selectedHistoryTopics,
          showsBullets: true
        ) { topicID in
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
      .font(isSelected ? Tokens.V1.Text.strong.font : Tokens.V1.Text.label.font)
      .foregroundStyle(isSelected ? Tokens.V1.Color.ink : Tokens.V1.Color.ink3)
      .lineLimit(1)
      .padding(.vertical, Tokens.V1.Space.xs)
      .overlay(alignment: .bottom) {
        Rectangle().fill(isSelected ? Tokens.V1.Color.ink : .clear)
          .frame(height: Tokens.V1.Size.focusWidth)
      }
    }
    .buttonStyle(.v1Quiet)
    .keyboardShortcut(tab.keyboardEquivalent, modifiers: .command)
    .runtimeAccessibilityIdentifier("library.tab.\(tab.rawValue)")
    .help("\(tab.title) \(tab.keycapLabel)")
    .accessibilityHint(tab.keycapLabel)
  }
}


extension MeetingLibraryView {
  func speakerNamingPanel(_ item: MeetingLibraryItem) -> some View {
    let roster = model.speakerRoster(for: item)
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      HStack {
        SectionHeaderRow(title: "发言人核对", count: roster.count)
        Spacer(minLength: .zero)
        Button("收起") { showsSpeakerNaming = false }
          .buttonStyle(.v1Quiet)
          .runtimeAccessibilityIdentifier("transcript.naming.collapse")
      }
      Text("选人，翻看发言和上下文，再填名或调整纪要取材。名字在回车或失焦时保存。")
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(roster) { entry in
        speakerReviewRow(entry, item: item)
          .id(entry.label)
      }
      if let error = model.speakerNameError {
        Text(error)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier("transcript.naming.error")
      }
      if item.hasFormalMinutes {
        Divider()
        Text("如果改了名字或纪要取材，已有纪要不会自动更新。")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
        Button("重新生成纪要…") { model.pendingMinutesGeneration = item }
          .buttonStyle(.v1Outline)
          .disabled(!model.canGenerateMinutes(for: item))
          .runtimeAccessibilityIdentifier("transcript.naming.regenerate")
      }
    }
    .padding(Tokens.V1.Space.md)
    .frame(width: Tokens.V1.Size.meetingRailWidth, alignment: .leading)
  }

  private func speakerReviewRow(
    _ entry: MeetingLibraryModel.SpeakerRosterEntry, item: MeetingLibraryItem
  ) -> some View {
    let active = model.speakerReviewLabel == entry.label
    let contextRevision = model.transcriptContextRevision
    let suggestions = model.namingSuggestionRows(for: item).filter { row in
      switch row {
      case .prefill(let suggestion): return suggestion.label == entry.label
      case .conflict(let label, _): return label == entry.label
      }
    }
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      SpeakerNameField(
        label: entry.label, name: entry.name,
        isHighlighted: active,
        isExcluded: item.excludedSpeakers.contains(entry.label),
        channelHint: SpeakerChannelHint.presentation(for: item.channelStats?[entry.label]),
        onToggleHighlight: {
          closeTranscriptSearch()
          model.beginSpeakerReview(entry.label, of: item)
        },
        onToggleExcluded: {
          guard model.isCurrentTranscriptUIContext(for: item, revision: contextRevision)
          else { return }
          model.setSpeakerExcluded(
            entry.label, excluded: !item.excludedSpeakers.contains(entry.label), of: item)
        },
        onFilter: {
          if !active {
            closeTranscriptSearch()
            model.beginSpeakerReview(entry.label, of: item)
          }
          model.showOnlyReviewedSpeaker(of: item)
        },
        focusRequest: active ? model.speakerReviewFocusRequest : nil,
        savedDraft: model.speakerReviewDrafts[entry.label],
        canCommit: model.canEditTranscript(for: item),
        onDraftChange: { draft in
          guard model.isCurrentTranscriptUIContext(for: item, revision: contextRevision)
          else { return }
          model.speakerReviewDrafts[entry.label] = draft
        },
        onCommit: { value in
          guard model.isCurrentTranscriptUIContext(for: item, revision: contextRevision),
            model.canEditTranscript(for: item)
          else { return false }
          model.setSpeakerName(value, for: entry.label, of: item)
          return model.speakerNameError == nil
        }
      )
      .id("\(item.id):\(item.transcriptFingerprint ?? ""):\(entry.label)")
      Button("\(entry.segmentCount) 段") {
        if let seconds = entry.longestLineSeconds { model.jumpToTranscript(seconds) }
      }
      .buttonStyle(.v1Quiet)
      .disabled(entry.longestLineSeconds == nil)
      .help("跳到他说得最长的那一段")
      .runtimeAccessibilityIdentifier("transcript.naming.longest.\(entry.label)")
      if active {
        speakerReviewActions(entry, item: item)
      }
      SpeakerNamingSuggestionBanner(
        rows: suggestions,
        onAdopt: {
          guard model.isCurrentTranscriptUIContext(for: item, revision: contextRevision)
          else { return }
          if !active {
            closeTranscriptSearch()
            model.beginSpeakerReview(entry.label, of: item)
          }
          model.adoptNamingSuggestion($0, of: item)
        },
        onDismiss: { suggestion in
          guard model.isCurrentTranscriptUIContext(for: item, revision: contextRevision)
          else { return }
          model.dismissNamingSuggestion(suggestion, of: item)
        },
        onJump: { seconds in
          // Evidence may be spoken by someone else; keep the selected original-label target.
          if !active { model.beginSpeakerReview(entry.label, of: item) }
          closeTranscriptSearch()
          model.jumpToTranscript(seconds)
        },
        resolve: { model.namingEvidence($0, of: item) }
      )
      .disabled(!model.canEditTranscript(for: item))
    }
    .padding(.vertical, Tokens.V1.Space.xs)
  }

  private func speakerReviewActions(
    _ entry: MeetingLibraryModel.SpeakerRosterEntry, item: MeetingLibraryItem
  ) -> some View {
    let excluded = item.excludedSpeakers.contains(entry.label)
    let contextRevision = model.transcriptContextRevision
    let name = entry.name.isEmpty ? entry.label : entry.name
    let shared = model.speakerRoster(for: item).filter {
      ($0.name.isEmpty ? $0.label : $0.name) == name
    }.count
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      Text("当前核对：\(entry.label) · \(entry.segmentCount) 段")
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.accent)
        .runtimeAccessibilityIdentifier("transcript.naming.current")
      HStack(spacing: Tokens.V1.Space.xs) {
        Button("只看此人") { model.showOnlyReviewedSpeaker(of: item) }
          .buttonStyle(.v1Outline)
          .runtimeAccessibilityIdentifier("transcript.naming.only")
        Button("看上下文") {
          closeTranscriptSearch()
          model.showSpeakerReviewContext(of: item)
        }
        .buttonStyle(.v1Outline)
        .runtimeAccessibilityIdentifier("transcript.naming.context")
      }
      if let progress = model.speakerHighlightProgress(for: item), model.speakerHighlight == name {
        HStack(spacing: Tokens.V1.Space.xs) {
          Button("上一处") { model.stepSpeakerHighlight(by: -1, of: item) }
            .runtimeAccessibilityIdentifier("transcript.naming.previous")
          Text("\(progress.index + 1)/\(progress.count)")
            .monospacedDigit()
          Button("下一处") { model.stepSpeakerHighlight(by: 1, of: item) }
            .runtimeAccessibilityIdentifier("transcript.naming.next")
        }
        .font(Tokens.V1.Text.meta.font)
        .buttonStyle(.v1Quiet)
      } else {
        Text(model.speakerFilters.isEmpty ? "暂无可跟读发言" : "只看中；点“看上下文”逐处核对")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
      }
      if shared > 1 {
        Text("阅读包含 \(shared) 个同名分组；以下操作只针对 \(entry.label)。")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button(excluded ? "恢复这一组的纪要参与" : "这一组不进纪要") {
        guard model.isCurrentTranscriptUIContext(for: item, revision: contextRevision)
        else { return }
        model.setSpeakerExcluded(entry.label, excluded: !excluded, of: item)
      }
      .buttonStyle(.v1Outline)
      .disabled(!model.canEditTranscript(for: item))
      .runtimeAccessibilityIdentifier("transcript.naming.exclude")
      Text("作用于原始 \(entry.label) 的全部 \(entry.segmentCount) 段，含单段更正给他人的发言；原文保留。")
        .font(Tokens.V1.Text.micro.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
