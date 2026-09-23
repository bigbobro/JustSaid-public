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
    // 状态驱动:没填名的人 + 待采纳的建议都归零时,这颗按钮消失,
    // 读原文时工具行只剩搜索和目录(Fable 评审 2026-09-20)。
    let todo = model.namingTodoCount(for: item)
    return HStack(spacing: Tokens.Spacing.xs) {
      if todo > 0 || showsSpeakerNaming {
        Button {
          showsSpeakerNaming = true
        } label: {
          HStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: "person.text.rectangle")
              .accessibilityHidden(true)
            Text(todo > 0 ? "认名 \(todo)" : "认名")
              .runtimeAccessibilityIdentifier("transcript.naming.todo.\(todo)")
          }
        }
        .buttonStyle(.toolbarPill)
        .help("给说话人填真名")
        .runtimeAccessibilityIdentifier("transcript.naming.trigger")
        // 面板不挂在这颗按钮上:认名要靠读正文回忆「这人说了什么」,
        // 浮层和 sheet 都会挡住正文(owner 2026-09-20)。它去占右栏的位置,
        // 见 MeetingLibraryView+DetailPane 的 meetingActionRail 分支。
      }
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
  /// 认名面板。原来这三块常驻在转写首屏:说话人输入框一行、一句常驻说明、认名建议两行。
  /// 说明那句还是无条件显示的(只有报错才被替换),纯系统自言自语占一整行。
  /// 认名是一次性任务,做完就不再需要,所以收进这里;读原文时那一页只剩正文。
  @ViewBuilder
  func speakerNamingPanel(_ item: MeetingLibraryItem) -> some View {
    let roster = model.speakerRoster(for: item)
    let suggestions = model.namingSuggestionRows(for: item)
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      SectionHeaderRow(title: "这场会有谁", count: roster.count)
      SpeakerNamingSuggestionBanner(
        rows: suggestions,
        onAdopt: { model.adoptNamingSuggestion($0, of: item) },
        onDismiss: { model.dismissNamingSuggestion($0, of: item) },
        onJump: model.jumpToTranscript,
        resolve: { model.namingEvidence($0, of: item) }
      )
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        ForEach(roster) { entry in
          VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
            HStack(spacing: Tokens.V1.Space.xs) {
              // 字段自己画标签 chip 与输入框,还带高亮/只看/不参会;这里不再重复画标签。
              // 300 宽的栏里一行放不下 chip + 输入框 + 段数,段数挪到样本那一行。
              SpeakerNameField(
                label: entry.label,
                name: entry.name,
                isHighlighted: model.speakerHighlight
                  == (entry.name.isEmpty ? entry.label : entry.name),
                isExcluded: item.excludedSpeakers.contains(entry.label),
                channelHint: SpeakerChannelHint.presentation(
                  for: item.channelStats?[entry.label]),
                onToggleHighlight: {
                  model.toggleSpeakerHighlight(entry.name.isEmpty ? entry.label : entry.name)
                },
                onToggleExcluded: {
                  model.setSpeakerExcluded(
                    entry.label,
                    excluded: !item.excludedSpeakers.contains(entry.label),
                    of: item)
                },
                onFilter: {
                  model.toggleSpeakerFilter(entry.name.isEmpty ? entry.label : entry.name)
                },
                onCommit: { model.setSpeakerName($0, for: entry.label, of: item) }
              )
              Spacer(minLength: .zero)
              // 段数留着,样本原话删了(owner 2026-09-20:「肯定要回原文去看」)。
              // 上一轮按 Fable 的意见在每个人下面铺一句最长原话,想让人不回正文就能认出
              // 是谁;实拍下来九个人就是九段引文,面板全是字,反而看不见建议。
              // 段数本身当跳转入口:点它落到这个人说得最长的那一处,回正文认人。
              Button {
                if let seconds = entry.longestLineSeconds { model.jumpToTranscript(seconds) }
              } label: {
                Text("\(entry.segmentCount) 段")
                  .font(Tokens.V1.Text.meta.font)
                  .foregroundStyle(Tokens.V1.Color.ink3)
                  .monospacedDigit()
              }
              .buttonStyle(.plain)
              .disabled(entry.longestLineSeconds == nil)
              .help("跳到他说得最长的那一段")
            }
          }
          .padding(.vertical, Tokens.V1.Space.s2xs)
        }
      }
      if let error = model.speakerNameError {
        Text(error)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
      }
      // 填完名字任务还没完:纪要里仍是「发言人 1」。给一个出口,
      // 但走既有的份数与计费确认弹窗,不一点就跑(Fable 评审)。
      if model.namingTodoCount(for: item) == 0, item.hasFormalMinutes {
        Divider()
        HStack(spacing: Tokens.V1.Space.xs) {
          Text("纪要里还是旧名字")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
          Spacer(minLength: .zero)
          Button("重新生成纪要…") {
            showsSpeakerNaming = false
            model.pendingMinutesGeneration = item
          }
          .buttonStyle(.v1Outline)
          .disabled(!model.canGenerateMinutes(for: item))
        }
      }
      Divider()
      HStack(spacing: Tokens.V1.Space.xs) {
        Spacer(minLength: .zero)
        Button("完成") { showsSpeakerNaming = false }
          .buttonStyle(.v1Primary)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Tokens.V1.Space.md)
    .frame(width: Tokens.V1.Size.meetingRailWidth, alignment: .leading)
  }
}
