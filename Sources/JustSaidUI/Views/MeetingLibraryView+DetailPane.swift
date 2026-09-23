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
        if let failure = model.sourceJumpFailure {
          HStack(spacing: Tokens.V1.Space.sm) {
            Text(failure)
            Spacer()
            Button("重新定位", action: model.retrySourceJump)
              .buttonStyle(.v1Outline)
              .runtimeAccessibilityIdentifier("todos.source.retry")
          }
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.warn)
          .padding(Tokens.V1.Space.md)
          .background(Tokens.V1.Color.warnSoft)
          .runtimeAccessibilityIdentifier("todos.source.failure")
        }
        if model.hasFailedArtifacts(for: selected) {
          HStack(spacing: Tokens.V1.Space.sm) {
            Image(systemName: "exclamationmark.triangle")
            Text("未能读取这场会议。请返回会议库重新扫描。")
            Spacer()
            Button("重新扫描") { model.reload() }.buttonStyle(.v1Outline)
          }
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.warn)
          .padding(Tokens.V1.Space.md)
          .background(Tokens.V1.Color.warnSoft)
          .runtimeAccessibilityIdentifier("meeting.read-failure")
        }
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
        // 左读右做(owner 2026-09-20 选定方向 B):页签以下分成两栏,
        // 左边连续读,右边常驻「要你做的事」。原来「复制行动清单」「导出会议包」
        // 蹲在页脚,四个角都有东西(owner「太乱了」);现在动作只剩两处:
        // 右上角(对这场会做什么)与右栏底(带走)。
        ZStack {
        HStack(alignment: .top, spacing: .zero) {
        VStack(alignment: .leading, spacing: .zero) {
        if model.tab == .transcript {
          // 认名收进工具行那颗按钮弹出的面板,不再常驻首屏。它是一次性任务,
          // 原来却占掉四行:输入框一行、常驻说明一行、认名建议两行,而这一页的活
          // 是「找那句话」(owner 2026-09-20 走查完整转写)。
          transcriptFilterRow(selected)
        }
        if model.tab == .onePage, model.showsFormalMinutes {
          // 正式纪要:自带滚动区,所以是整块换,不嵌进一页纸的滚动区。
          // 中/EN 与历史版本都只管这一块,挂在它头上。
          formalMinutesSwitch(selected)
          if hasMinutesToolContent(selected) {
            minutesToolRow(selected)
          }
          minutesPane(selected)
        } else if model.tab == .onePage, let onePager = model.onePager(for: selected) {
          formalMinutesSwitch(selected)
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
            speakerFilters: model.speakerFilters,
            searchQuery: transcriptSearchQuery,
            speakers: presentation.displaySpeakers,
            onSelectSpeaker: { model.toggleSpeakerFilter($0) },
            onOverride: { line, name in
              model.setSpeakerOverride(name, for: line, of: selected)
            },
            onRequestNewName: { model.requestSpeakerOverride(for: $0, of: selected) },
            excludedRanges: selected.excludedRanges,
            excludedSpeakers: selected.excludedSpeakers,
            onExcludeLine: { model.excludeTranscriptLine($0, of: selected) },
            onRemoveExclusion: { model.removeExclusion(id: $0, of: selected) },
            onSetSpeakerExcluded: { label, excluded in
              model.setSpeakerExcluded(label, excluded: excluded, of: selected)
            },
            // 点正文里的名字 → 右栏认名面板;⌥点仍是「只看此人」。
            onRequestNaming: { _ in showsSpeakerNaming = true },
            onToggleSpeakerHighlight: { model.toggleSpeakerHighlight($0) },
            highlightedSpeaker: model.speakerHighlight,
            selection: $model.transcriptSelection,
            onExcludeRange: { first, last in
              model.excludeTranscriptRange(from: first, to: last, of: selected)
            },
            scrollOffset: tabScrollBinding(for: .transcript),
            onViewportAnchor: { model.transcriptViewportSeconds = $0 },
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 右栏跟着页签走(owner 2026-09-20 走查:「右侧栏不会跟着转到转写这里,
        // 转写这里就变成了一个长的,直接跳下去了,这个体验又不一致」)。
        // 原来不论在哪一页,右栏都是「我要做什么」——在完整转写和会中记录上,
        // 那一栏跟你当下在做的事没有关系,只是占着位置。
        //
        // 这场会/纪要 → 要你做的事;完整转写 → 认名(按需);会中记录 → 补充记录。
        detailRail(selected)
        }
        .onAppear { syncCandidates(selected) }
        .onChange(of: model.artifactLoadRevision) { _, _ in syncCandidates(selected) }
        }
      }
      .meetingCandidateCover(
        page: todoPage, meetingID: selected.meetingID, onShowTodos: { onShowTodos?() },
        onJump: model.jumpToTranscript, onRefresh: { syncCandidates(selected) })
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
              .fill(Tokens.V1.Color.raised)
          )
          .runtimeAccessibilityIdentifier("library.loading-detail-content")
        }
      }
      .background(Tokens.Color.card)
      .background { sourceJumpMarker }
    } else {
      VStack(spacing: Tokens.Spacing.xsm) {
        Text(model.isReloading ? "正在读取会议…" : "未能读取这场会议")
          .font(.system(size: textScale.size(Tokens.FontSize.headingSmall), weight: .semibold))
          .foregroundStyle(Tokens.Color.ink2)
        meetingBackButton
        Text("可以看这场会的纪要、完整转写，以及会中记录。")
          .font(.system(size: textScale.size(Tokens.FontSize.uiEmphasis)))
          .foregroundStyle(Tokens.Color.ink3)
      }
      .runtimeAccessibilityIdentifier("library.empty-detail-content")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Tokens.Color.card)
      .background { sourceJumpMarker }
    }
  }

  /// 仅标识请求发布；定位验收必须检查正文目标在原生滚动视口内。
  @ViewBuilder
  var sourceJumpMarker: some View {
    if returnsToTodos, let seconds = model.transcriptJumpRequest?.seconds {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityHidden(true)
        .runtimeAccessibilityIdentifier("todos.source.requested.\(Int(seconds.rounded()))")
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

  /// 复制与导出的回执。原来写在整页页脚里,方向 B 拆页脚时它跟着没了:点「复制行动清单」
  /// 没有任何回应,导出看不到进度、不能取消,失败也不说。放回右栏底按钮的正上方。
  @ViewBuilder
  private var exportStatusLine: some View {
    if model.isExporting {
      HStack(spacing: Tokens.V1.Space.xs) {
        ProgressView()
          .controlSize(.small)
        Text(model.exportProgressText ?? "正在导出…")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
        Button("取消") {
          model.cancelExport()
        }
        .buttonStyle(.v1Quiet)
        .runtimeAccessibilityIdentifier("library.export.cancel")
      }
      .runtimeAccessibilityIdentifier("library.export.progress")
    }
    if let exportError = model.exportError {
      Text(exportError)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.warn)
        .fixedSize(horizontal: false, vertical: true)
    } else if let exportNotice = model.exportNotice {
      Text(exportNotice)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ok)
    }
  }

  /// 顶栏 ⋯ 也要用它,所以不能是 private(private 在扩展里等于本文件可见)。
  /// `showsIndicator`:右栏底那颗描边按钮要画下拉箭头,说明点开是菜单;⋯ 里的子菜单不画。
  func exportMeetingPackageMenu(_ item: MeetingLibraryItem, showsIndicator: Bool = false) -> some View {
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
      if showsIndicator {
        HStack(spacing: Tokens.V1.Space.s2xs) {
          Text("导出会议包")
          Image(systemName: "chevron.down")
            .imageScale(.small)
            .accessibilityHidden(true)
        }
      } else {
        Text("导出会议包")
      }
    }
    .disabled(!model.canExport(item))
    .help(model.exportDisabledReason(for: item) ?? "导出完整会议包")
    .runtimeAccessibilityIdentifier("library.export-package")
  }

  func chooseExportDestination(for item: MeetingLibraryItem) {
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

  func exportMeetingDiagnosticsMenu(_ item: MeetingLibraryItem) -> some View {
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

extension MeetingLibraryView {
  /// 右栏按页签分派。每一页的右栏只放**你在这一页会用到的东西**:
  ///
  /// - 这场会 / 纪要:要你做的事(我要做什么、还没定),以及带走。
  /// - 完整转写:认名——按需打开,不常驻。这一页的活是「找那句话」,
  ///   平时整栏不画,正文占满,不做成一个跳到底的长条。
  /// - 会中记录:补充记录——左边是机器记的,右边是你写的,并排对着看。
  ///
  /// owner 2026-09-20 走查:「右侧栏不会跟着转到转写这里…这个体验又不一致」。
  @ViewBuilder
  func detailRail(_ item: MeetingLibraryItem) -> some View {
    switch model.tab {
    case .transcript:
      // 认名开着时正文保持原宽、可读可滚,一边扫正文一边填名
      // (owner 2026-09-20:「我认名一定是在下面看」)。
      if showsSpeakerNaming {
        speakerNamingRail(item)
      }
    case .inMeeting:
      inMeetingNotesRail(item)
    default:
      meetingActionRail(item)
    }
  }

  /// 右栏是待办候选。空的时候整栏不画,左栏自动占满。
  @ViewBuilder
  func meetingActionRail(_ item: MeetingLibraryItem) -> some View {
    let document = model.artifacts(for: item).structuredMinutes
    let hasMinutesWork = !(document?.actionItems.isEmpty ?? true) || !(document?.openQuestions.isEmpty ?? true)
    let hasLedger = todoPage.map {
      !$0.candidateRows.isEmpty || !$0.legacyHits.isEmpty || !$0.candidateQuestions.isEmpty
    } ?? false
    if hasMinutesWork || hasLedger || !item.completedActionItems.isEmpty {
      VStack(alignment: .leading, spacing: .zero) {
      ScrollView {
      Group {
        if let todoPage {
          MeetingCandidateModelRail(model: todoPage, onJump: model.jumpToTranscript) {
            syncCandidates(item)
          }
        } else {
          MeetingCandidateFallbackRail(
            document: document,
            completed: item.completedActionItems,
            onJump: model.jumpToTranscript
          )
        }
      }
      .padding(Tokens.V1.Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
      // 「带走」钉在栏底,不跟着滚:它是这一栏的出口,不是列表的一部分。
      // 按 meeting.html 的 b2-rail-foot 排成一行:主按钮撑满,导出是贴着它的描边菜单按钮。
      // 原来两颗按钮上下摞着、各按字数定宽再居中(owner 2026-09-21「放到这里好丑」)。
      Divider()
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        exportStatusLine
        HStack(spacing: Tokens.V1.Space.xs) {
          ActionItemsCopyButton(text: model.actionItemsCopyText(for: item), fillsWidth: true) {
            model.reportCopySuccess("已复制 \(model.actionItemCount(for: item)) 条")
          }
          .buttonStyle(.v1Primary)
          .help(model.actionItemsCopyDisabledHelp(for: item) ?? "复制这场会议的结构化行动清单")
          exportMeetingPackageMenu(item, showsIndicator: true)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.v1Outline)
            .fixedSize()
        }
      }
      .padding(.horizontal, Tokens.V1.Space.md)
      .padding(.vertical, Tokens.V1.Space.sm)
      }
      .frame(width: Tokens.V1.Size.meetingRailWidth, alignment: .leading)
      .frame(maxHeight: .infinity, alignment: .top)
      .background(Tokens.V1.Color.paper2)
      .overlay(alignment: .leading) {
        Rectangle().fill(Tokens.V1.Color.rule).frame(width: Tokens.V1.Size.controlRuleWidth)
      }
      .runtimeAccessibilityIdentifier("meeting.action-rail")
    }
  }
}


extension MeetingLibraryView {
  func syncCandidates(_ item: MeetingLibraryItem) {
    guard let todoPage else { return }
    let data = try? Data(contentsOf: item.paths.minutesStructured)
    todoPage.reconcileOpenedMeeting(
      meetingID: item.meetingID,
      title: item.title,
      startedAt: item.startedAt,
      client: item.client,
      project: item.project,
      directoryHint: item.paths.directory.path,
      minutesData: data,
      completedActionItems: item.completedActionItems
    )
  }
}

extension MeetingLibraryView {
  /// 「这场会」页内的两种看法:结构 / 正式纪要。一个入口,两种呈现——
  /// 它们是同一份结构化纪要,不是两份产物,所以不该是两个页签(owner 2026-09-20)。
  @ViewBuilder
  func formalMinutesSwitch(_ item: MeetingLibraryItem) -> some View {
    if item.hasFormalMinutes {
      HStack(spacing: Tokens.V1.Space.xs) {
        Spacer(minLength: .zero)
        V1SegmentedPicker(
          "这场会的看法",
          selection: Binding(
            get: { model.showsFormalMinutes },
            set: { model.showsFormalMinutes = $0 }
          ),
          options: [.init(false, "结构"), .init(true, "正式纪要")]
        )
        .runtimeAccessibilityIdentifier("meeting.view-switch")
      }
      .padding(.horizontal, Tokens.V1.Space.md)
      .padding(.top, Tokens.V1.Space.xs)
    }
  }
}


extension MeetingLibraryView {
  /// 认名面板占右栏的位置:有自己的滚动区,顶上带标题与关闭。
  @ViewBuilder
  func speakerNamingRail(_ item: MeetingLibraryItem) -> some View {
    VStack(alignment: .leading, spacing: .zero) {
      ScrollView { speakerNamingPanel(item) }
        .scrollBounceBehavior(.basedOnSize)
    }
    .frame(width: Tokens.V1.Size.meetingRailWidth, alignment: .leading)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Tokens.V1.Color.paper2)
    .overlay(alignment: .leading) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(width: Tokens.V1.Size.controlRuleWidth)
    }
    .runtimeAccessibilityIdentifier("meeting.naming-rail")
  }
}
