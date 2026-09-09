import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

// 2026-08-20 批3 拆分:自 MeetingLibraryView.swift 按 MARK 边界机械迁出,零行为变更。
extension MeetingLibraryView {
  // MARK: - 详情

  @ViewBuilder
  var detail: some View {
    if let selected = model.selectedItem {
      VStack(alignment: .leading, spacing: 0) {
        detailHeader(selected)
        Divider()
        minutesGenerationBanner(selected)
        tabBar(selected)
        if model.tab == .minutes, hasMinutesToolContent(selected) {
          minutesToolRow(selected)
        }
        if model.tab == .transcript {
          transcriptToolRow(selected)
        }
        Divider()
        LibraryReturnTrailBanner(
          trail: model.returnTrail,
          onBack: followReturnTrail,
          onDismiss: { model.returnTrail = nil }
        )
        if model.tab == .transcript {
          speakerNamingRow(selected)
          // 认名预填(08-17 #7):无条件实例化,显隐判断收在视图内部(红线 6)。
          SpeakerNamingSuggestionBanner(
            rows: model.namingSuggestionRows(for: selected),
            onAdopt: { model.adoptNamingSuggestion($0, of: selected) },
            onDismiss: { model.dismissNamingSuggestion($0, of: selected) },
            onJump: model.jumpToTranscript
          )
          transcriptFilterRow(selected)
        }
        if model.tab == .onePage, let onePager = model.onePager(for: selected) {
          OnePagerView(
            document: onePager,
            isLegacyFallback: model.isLegacyOnePager(selected),
            topics: model.selectedHistoryTopics,
            onJumpToTranscript: model.jumpToTranscript,
            scrollOffset: tabScrollBinding(for: .onePage)
          )
        } else if model.tab == .transcript,
          model.hasContent(for: selected, tab: .transcript)
        {
          let presentation = model.transcriptPresentation(for: selected)
          TranscriptDocumentView(
            rows: presentation.rows,
            speakerFilter: model.speakerFilter,
            searchQuery: transcriptSearchQuery,
            speakers: presentation.displaySpeakers,
            onSelectSpeaker: { model.toggleSpeakerFilter($0) },
            onOverride: { line, name in
              model.setSpeakerOverride(name, for: line, of: selected)
            },
            onRequestNewName: { model.pendingOverrideLine = $0 },
            excludedRanges: selected.excludedRanges,
            excludedSpeakers: selected.excludedSpeakers,
            onExcludeLine: { model.excludeTranscriptLine($0, of: selected) },
            onRemoveExclusion: { model.removeExclusion(id: $0, of: selected) },
            onSetSpeakerExcluded: { label, excluded in
              model.setSpeakerExcluded(label, excluded: excluded, of: selected)
            },
            highlightedSpeaker: model.speakerHighlight,
            selection: $model.transcriptSelection,
            onExcludeRange: { first, last in
              model.excludeTranscriptRange(from: first, to: last, of: selected)
            },
            scrollOffset: tabScrollBinding(for: .transcript),
            jumpRequest: $model.transcriptJumpRequest
          )
          // Esc 先退搜索,再沿用 0.7 的“清选段 → 清高亮”顺序。
          // 输入框内的 Esc 在字段级先行消费。
          .onExitCommand {
            handleLibraryExitCommand()
          }
        } else if model.tab == .inMeeting {
          inMeetingPage(selected)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            // 附加产物局部失败:只在纪要·英文版页签内提示 + 重试,不惊动全局状态(D2)。
            if model.tab == .minutes,
              model.minutesVariant == .english,
              selected.englishMinutesPartialFailure != nil
            {
              partialEnglishMinutesBanner(selected)
            }
            if model.tab == .minutes {
              // 无条件实例化(红线 6):生成中投影/原始数据/盘上产物三态的
              // 显隐判断全部收在 `MinutesDocumentPane` 内部。
              minutesPane(selected)
            } else {
              MeetingDocumentView(
                document: model.document(for: selected, tab: model.tab),
                scrollOffset: tabScrollBinding(for: model.tab)
              )
            }
          }
        }
        Divider()
        detailFooter(selected)
      }
      .focusable(true)
      .focused($focusedPane, equals: .detail)
      .focusEffectDisabled()
      .onExitCommand {
        handleLibraryExitCommand()
      }
      .overlay {
        if model.isArtifactsLoading(for: selected) {
          VStack(spacing: Tokens.Spacing.xs) {
            ProgressView()
            Text("正在读取会议内容…")
              .font(.system(size: Tokens.FontSize.ui))
              .foregroundStyle(Tokens.Color.ink3)
          }
          .padding(Tokens.Spacing.md)
          .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
              .fill(Tokens.Color.card.opacity(0.94))
          )
          .runtimeAccessibilityIdentifier("library.loading-detail-content")
        }
      }
      .background(Tokens.Color.card)
    } else {
      VStack(spacing: Tokens.Spacing.xsm) {
        Text("从左边选一场会议")
          .font(.system(size: textScale.size(Tokens.FontSize.headingSmall), weight: .semibold))
          .foregroundStyle(Tokens.Color.ink2)
        Text("可以看这场会的纪要、完整转写，以及会中记录。")
          .font(.system(size: textScale.size(Tokens.FontSize.uiEmphasis)))
          .foregroundStyle(Tokens.Color.ink3)
      }
      .runtimeAccessibilityIdentifier("library.empty-detail-content")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Tokens.Color.card)
    }
  }

  /// 纪要页签正文(08-08 渐进渲染):生成中缓冲区与盘上产物都交给 pane,
  /// 由它内部决定画哪个、怎么画;缓冲区取自 `activeLiveMinutesDraft`(单一事实源)。
  private func minutesPane(_ item: MeetingLibraryItem) -> some View {
    let draft = model.activeLiveMinutesDraft(for: item)
    return MinutesDocumentPane(
      language: draft?.language
        ?? (model.minutesVariant == .english ? .english : .chinese),
      liveBuffer: draft?.content,
      document: model.document(for: item, tab: .minutes),
      showsRaw: $model.showsRawLiveMinutes,
      scrollOffset: tabScrollBinding(for: .minutes),
      checkContext: model.checkContext(for: item),
      showsCheck: $model.showsCheckWorkbench,
      embedsCheckToggle: false
    )
  }

  /// 独立「生成纪要」状态条:运行中 / 成功 / 失败都必须可见(F1)。
  /// 这里**不做任何显隐判断**——`.none` 收成空由 `MinutesGenerationStatusBanner` 负责,
  /// 判断点只留一处,才能被 UIHierarchy 的变异验证真正守住。
  private func minutesGenerationBanner(_ item: MeetingLibraryItem) -> some View {
    MinutesGenerationStatusBanner(stage: model.minutesGenerationStage(for: item)) {
      // 重试同样走选择弹窗:上一次选了什么不该替这一次做主,重试也是花钱的。
      model.pendingMinutesGeneration = item
    }
  }

  /// 英文版纪要局部缺失提示条:主产物已成功,只缺这一份;重试不重新计费精转。
  @ViewBuilder
  private func partialEnglishMinutesBanner(_ item: MeetingLibraryItem) -> some View {
    let stage = model.englishMinutesRetryStage(for: item)
    HStack(spacing: Tokens.Spacing.xsm) {
      switch stage {
      case .running(let detail):
        BreathingDots()
        Text(detail ?? "正在重新生成英文版纪要…")
      case .finished(let notice):
        Image(systemName: "checkmark.circle.fill")
        Text(notice)
      case .failed(let reason):
        Image(systemName: "exclamationmark.triangle.fill")
        Text("英文版重试未成功 · \(reason)")
      case .none:
        Image(systemName: "exclamationmark.triangle.fill")
        Text(
          item.englishMinutesPartialFailure.map(\.displayDescription)
            ?? "英文版纪要未生成"
        )
      }

      Spacer()

      // 按钮始终露出(只要有局部失败且未在跑),无管线时 disable——避免验证/只读打开时
      // 提示条「看得见却点不到」被误判成静默吞掉。
      if !stage.isRunning, item.canRetryEnglishMinutes {
        Button("重试英文版") {
          model.retryEnglishMinutes(for: item)
        }
        .buttonStyle(.textAction)
        .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
        .disabled(!model.canRetryEnglishMinutes(for: item))
        .runtimeAccessibilityIdentifier("library.retry-english-minutes")
      }
    }
    .font(.system(size: Tokens.FontSize.bodyMinimum))
    .foregroundStyle(isEnglishRetrySuccess(stage) ? Tokens.Color.acDeep : Tokens.Color.warn)
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.xs)
    .background(isEnglishRetrySuccess(stage) ? Tokens.Color.acSoft : Tokens.Color.amber)
    .overlay(alignment: .bottom) { Divider() }
    .runtimeAccessibilityIdentifier("library.partial-english-minutes")
  }

  private func isEnglishRetrySuccess(_ stage: PostMeetingStage) -> Bool {
    if case .finished = stage {
      return true
    }
    return false
  }

  private func detailFooter(_ item: MeetingLibraryItem) -> some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      if model.isExporting {
        HStack(spacing: Tokens.Spacing.xs) {
          ProgressView()
            .controlSize(.small)
          Text(model.exportProgressText ?? "正在导出…")
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.ink3)
          Button("取消") {
            model.cancelExport()
          }
          .buttonStyle(.textAction)
          .runtimeAccessibilityIdentifier("library.export.cancel")
        }
        .runtimeAccessibilityIdentifier("library.export.progress")
      }
      if let exportError = model.exportError {
        Text(exportError)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.warn)
      } else if let exportNotice = model.exportNotice {
        Text(exportNotice)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.resolved)
      }
      HStack(spacing: Tokens.Spacing.md) {
        Button("在 Finder 中显示") {
          NSWorkspace.shared.activateFileViewerSelecting([item.paths.directory])
        }
        Button("复制当前页全文") {
          let document = model.document(for: item, tab: model.tab)
          guard let text = document.body else { return }
          NSPasteboard.general.clearContents()
          if NSPasteboard.general.setString(text, forType: .string) {
            model.reportCopySuccess("已复制当前页全文")
          }
        }
        .disabled(model.document(for: item, tab: model.tab).body == nil)
        ActionItemsCopyButton(text: model.actionItemsCopyText(for: item)) {
          model.reportCopySuccess("已复制 \(model.actionItemCount(for: item)) 条")
        }
        .help(
          model.actionItemsCopyDisabledHelp(for: item)
            ?? "复制这场会议的结构化行动清单"
        )
        exportMeetingPackageMenu(item)
        exportMeetingDiagnosticsMenu(item)
        Spacer()
        if item.hasAudio {
          Text("录音已保留")
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.ink4)
        }
      }
    }
    .buttonStyle(.textAction)
    .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
    .foregroundStyle(Tokens.Color.acDeep)
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.sm)
  }

  private func exportMeetingPackageMenu(_ item: MeetingLibraryItem) -> some View {
    Menu {
      ForEach(
        Array(model.recentExportDestinations.enumerated()),
        id: \.offset
      ) { index, destination in
        let parentName = destination.deletingLastPathComponent().lastPathComponent
        let destinationName = destination.lastPathComponent
        Button {
          model.exportMeetingPackage(for: item, to: destination)
        } label: {
          Text(parentName.isEmpty ? destinationName : "\(parentName)/\(destinationName)")
        }
        .help(destination.deletingLastPathComponent().path)
        .runtimeAccessibilityIdentifier("library.export-package.recent-\(index)")
      }
      if !model.recentExportDestinations.isEmpty {
        Divider()
      }
      Button("选择其他文件夹…") {
        chooseExportDestination(for: item)
      }
      .runtimeAccessibilityIdentifier("library.export-package.chooser")
    } label: {
      Text("导出会议包")
    }
    .disabled(!model.canExport(item))
    .help(model.exportDisabledReason(for: item) ?? "导出完整会议包")
    .runtimeAccessibilityIdentifier("library.export-package")
  }

  private func chooseExportDestination(for item: MeetingLibraryItem) {
    let panel = NSOpenPanel()
    panel.title = "选择会议包导出位置"
    panel.prompt = "导出"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    model.exportMeetingPackage(for: item, to: destination)
  }

  private func exportMeetingDiagnosticsMenu(_ item: MeetingLibraryItem) -> some View {
    Menu {
      ForEach(
        Array(model.recentDiagnosticsDestinations.enumerated()),
        id: \.offset
      ) { index, destination in
        let parentName = destination.deletingLastPathComponent().lastPathComponent
        let destinationName = destination.lastPathComponent
        Button {
          model.exportMeetingDiagnostics(for: item, to: destination)
        } label: {
          Text(parentName.isEmpty ? destinationName : "\(parentName)/\(destinationName)")
        }
        .help(destination.deletingLastPathComponent().path)
        .runtimeAccessibilityIdentifier("library.export-meeting-diagnostics.recent-\(index)")
      }
      if !model.recentDiagnosticsDestinations.isEmpty {
        Divider()
      }
      Button("选择其他文件夹…") {
        chooseDiagnosticsDestination(for: item)
      }
      .runtimeAccessibilityIdentifier("library.export-meeting-diagnostics.chooser")
    } label: {
      Text("导出本场诊断包")
    }
    .disabled(model.isExporting)
    .help(model.isExporting ? (model.exportProgressText ?? "正在导出") : "导出本场会议的脱敏诊断信息")
    .runtimeAccessibilityIdentifier("library.export-meeting-diagnostics")
  }

  private func chooseDiagnosticsDestination(for item: MeetingLibraryItem) {
    let panel = NSOpenPanel()
    panel.title = "选择本场诊断包导出位置"
    panel.prompt = "导出"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    model.exportMeetingDiagnostics(for: item, to: destination)
  }

  var normalizedTranscriptSearchQuery: String {
    transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func showTranscriptSearch() {
    isTranscriptSearchPresented = true
    Task { @MainActor in
      await Task.yield()
      isTranscriptSearchFocused = true
    }
  }

  func closeTranscriptSearch() {
    isTranscriptSearchFocused = false
    isTranscriptSearchPresented = false
    transcriptSearchQuery = ""
  }

  func exclusionStateLabel(rangeCount: Int, speakerCount: Int) -> String {
    var parts: [String] = []
    if rangeCount > 0 {
      parts.append("排除 \(rangeCount) 段")
    }
    if speakerCount > 0 {
      parts.append("排除 \(speakerCount) 人")
    }
    return "排除态：\(parts.joined(separator: " · "))（灰显保留）"
  }

  func selectPostMeetingChapter(_ topicID: UUID) {
    guard let topic = model.selectedHistoryTopics.first(where: { $0.id == topicID }) else {
      return
    }
    guard let seconds = ChapterNavigation.startSeconds(for: topic) else { return }
    isShowingChapterDirectory = false
    closeTranscriptSearch()
    model.jumpToTranscript(seconds)
  }

  func tabScrollBinding(for tab: MeetingDetailTab) -> Binding<CGFloat> {
    Binding(
      get: { CGFloat(retainedTabScrollOffsets[tab] ?? 0) },
      set: { retainedTabScrollOffsets[tab] = Double($0) }
    )
  }

  func scheduleReturnTrailDismissal(_ trail: LibraryReturnTrail?) {
    returnTrailTask?.cancel()
    guard trail != nil else { return }
    returnTrailTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(LibraryReturnTrail.displayDuration))
      guard !Task.isCancelled else { return }
      model.returnTrail = nil
    }
  }

  private func followReturnTrail() {
    guard let source = model.returnTrail?.sourceTab else { return }
    model.returnTrail = nil
    model.tab = source
  }

  private func handleLibraryExitCommand() {
    if isTranscriptSearchPresented {
      closeTranscriptSearch()
    } else if model.transcriptSelection != nil {
      model.clearTranscriptSelection()
    } else if model.speakerHighlight != nil {
      model.clearSpeakerHighlight()
    } else {
      focusedPane = .list
    }
  }
}
