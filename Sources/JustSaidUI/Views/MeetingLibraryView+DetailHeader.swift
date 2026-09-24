import JustSaidCore
import SwiftUI

extension MeetingLibraryView {
  /// 只留一枚箭头。原来是「‹ 会议库」文字按钮,和会名抢同一行,而图标轨上「会议库」
  /// 本来就亮着——你在哪已经说过一遍了(owner 2026-09-20「感觉跟整个 app 不自然」)。
  /// 见 docs/design-system/README.md「往里走一层」。
  var meetingBackButton: some View {
    Group {
      if returnsToTodos {
        Button {
          onReturnToTodos?()
        } label: {
          HStack(spacing: Tokens.V1.Space.s2xs) {
            Image(systemName: "chevron.left")
            Text("我的待办")
          }
        }
        .buttonStyle(.v1Quiet)
        .help("返回我的待办")
        .accessibilityLabel("返回我的待办")
        .keyboardShortcut("[", modifiers: .command)
        .runtimeAccessibilityIdentifier("meeting.back-to-todos")
      } else {
        Button(action: returnToMeetingLibrary) {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.v1Icon)
        .help("返回会议库 ⌘[")
        .accessibilityLabel("返回会议库")
        .keyboardShortcut("[", modifiers: .command)
        .runtimeAccessibilityIdentifier("meeting.back-to-library")
      }
    }
  }

  func detailHeader(_ item: MeetingLibraryItem) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
      HStack(spacing: Tokens.V1.Space.sm) {
        meetingBackButton
        EditableMeetingTitle(
          id: item.id, title: item.title, focus: $focusedMeetingTitleID,
          onCommit: { model.rename(item, to: $0) }
        )
        .id(item.id)
        .frame(maxWidth: Tokens.V1.Size.meetingTitleMaxWidth, alignment: .leading)
        .help(item.title)
        // 这里原来还挂一颗只读的客户胶囊。它和下面那枚可编辑的客户标签是同一个值,
        // 而标题有最大宽度,于是它既重复又飘在顶栏正中(owner 2026-09-20 圈了这一处)。
        // 留可编辑的那一枚,删这一枚。
        Spacer(minLength: Tokens.V1.Space.xs)
        headerNextActions(item)
      }
      .frame(minHeight: Tokens.V1.Size.barHeight)
      // 一条会议身份信息原来被切成三截:时间事实一行、流水线条一行、归属标签一行,
      // 三行各占一条,谁也没说清(owner 2026-09-20「排列不好看」)。合成一行——
      // 左边是这场会什么时候、多久、怎么来的,一道细线之后是它属于谁。
      // 「·」是同类项之间的分隔,标签是另一类东西,所以不用「·」接下去。
      HStack(spacing: Tokens.V1.Space.xs) {
        Text(item.compactStartedLabel)
        Text("·")
        Text(item.compactDurationLabel)
        Text("·")
        Text(item.isImportedRecording ? "导入录音" : "本机录制")
        if item.hasPartialCapture { PartialCaptureBadge(summary: item.partialCaptureSummary) }
        Divider().frame(height: Tokens.V1.Text.meta.size)
        let directory = todoPage?.tagDirectory ?? model.tagDirectory
        EditableTagChip(
          kind: .client,
          value: item.client, directory: directory,
          onCommit: { model.selectTag(.client, value: $0, of: item, directory: directory) }
        )
        EditableTagChip(
          kind: .project,
          value: item.project, client: item.client ?? "", directory: directory,
          onCommit: { model.selectTag(.project, value: $0, of: item, directory: directory) }
        )
        if let tagError = model.tagError {
          Text(tagError)
            .font(.system(size: Tokens.V1.Text.meta.size))
            .foregroundStyle(Tokens.V1.Color.warn)
            .runtimeAccessibilityIdentifier("library.detail.tag.error")
        }
        Spacer(minLength: .zero)
      }
      .font(Tokens.V1.Text.meta.font)
      .foregroundStyle(Tokens.V1.Color.ink3)
      .id(item.id)
      .runtimeAccessibilityIdentifier("library.metadata-row")
      if model.shouldShowPipelineStrip(for: item) {
        pipelineStrip(item)
      }
      if model.postMeetingStage(for: item).isRunning {
        HStack(spacing: Tokens.V1.Space.xs) {
          ProgressView().controlSize(.small)
          Text(model.transcriptionStatusLabel(for: item))
          Spacer()
          if let requestIDSuffix = model.livePostMeetingRequestIDSuffix(for: item) {
            Text("任务 …\(requestIDSuffix)")
              .font(Tokens.V1.Text.timecode.font)
              .foregroundStyle(Tokens.V1.Color.ink3)
              .textSelection(.enabled)
              .runtimeAccessibilityIdentifier("library.live-request-id")
          }
        }
        .font(Tokens.V1.Text.body.font)
        .padding(Tokens.V1.Space.sm)
        .background(Tokens.V1.Color.paper2, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
        .runtimeAccessibilityIdentifier("meeting.processing")
      }
      if let failureReason = model.postMeetingFailureReason(for: item) {
        HStack(spacing: Tokens.V1.Space.xs) {
          Image(systemName: "exclamationmark.triangle")
          Text("会后处理未完成 · \(failureReason)")
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: Tokens.V1.Space.xs)
          Button("重新精转…") { model.pendingReprocess = item }
            .buttonStyle(.v1Outline)
            .disabled(!model.canRetryPostMeeting(for: item) || model.postMeetingStage(for: item).isRunning)
            .runtimeAccessibilityIdentifier("meeting.failure.retry")
        }
        .font(Tokens.V1.Text.body.font)
        .foregroundStyle(Tokens.V1.Color.warn)
        .padding(Tokens.V1.Space.sm)
        .background(Tokens.V1.Color.warnSoft, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
        .runtimeAccessibilityIdentifier("library.failure-reason")
      }
      if let titleError = model.titleError {
        Text(titleError)
          .font(.system(size: Tokens.V1.Text.meta.size))
          .foregroundStyle(Tokens.V1.Color.warn)
      }
      CompletenessDetailCard(
        item: item,
        ackError: model.completenessAckError,
        onAcknowledge: { gap, reason, note in
          model.acknowledgeCompletenessGap(gap, reason: reason, note: note, for: item)
        },
        onRevoke: { gapKey in
          model.revokeCompletenessAck(gapKey: gapKey, for: item)
        }
      )
    }
    .padding(.horizontal, Tokens.V1.Space.lg)
    .padding(.vertical, Tokens.V1.Space.sm)
  }

  /// 精转确认框的动作名跟着这场会的状态走,从没精转过叫「精转」。
  private var reprocessActionTitle: String {
    model.pendingReprocess.map { model.pipelineState(for: $0).transcriptionActionTitle } ?? "精转"
  }

  func meetingActionDialogs<Content: View>(_ content: Content) -> some View {
    content
    .confirmationDialog(
      "\(reprocessActionTitle)「\(model.pendingReprocess?.title ?? "")」?",
      isPresented: Binding(
        get: { model.pendingReprocess != nil },
        set: { if !$0 { model.pendingReprocess = nil } }
      ),
      titleVisibility: .visible,
      presenting: model.pendingReprocess
    ) { target in
      Button("\(reprocessActionTitle)（按全时长计费）", role: .destructive) {
        model.pendingReprocess = nil
        model.retryPostMeeting(for: target)
      }
      Button("取消", role: .cancel) {}
    } message: { target in
      if model.pipelineState(for: target).transcription == .notStarted {
        Text("会上传录音做精转并按全时长计费 ASR。结果替换现有转写时会先备份；新转写的人物标注需要确认。")
      } else {
        Text(
          "会重新上传录音并按全时长计费 ASR。重跑结果可能与上次不同(包括数字与措辞)。"
            + "新结果替换时会备份旧转写和人物标注；新转写的人物标注需重新确认。"
            + "若只是改了发言人名字，请改用「生成纪要」(不重新精转)。"
        )
      }
    }
    .confirmationDialog(
      "为「\(model.pendingMinutesGeneration?.title ?? "")」生成纪要",
      isPresented: Binding(
        get: { model.pendingMinutesGeneration != nil },
        set: { if !$0 { model.pendingMinutesGeneration = nil } }
      ),
      titleVisibility: .visible,
      presenting: model.pendingMinutesGeneration
    ) { target in
      Button(MinutesGenerationScope.chineseOnly.actionTitle) {
        startMinutesGeneration(for: target, scope: .chineseOnly)
      }
      Button(MinutesGenerationScope.bilingual.actionTitle) {
        startMinutesGeneration(for: target, scope: .bilingual)
      }
      Button("取消", role: .cancel) {}
    } message: { _ in
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        Text("一种语言一次模型调用。只按盘上的转写生成，不重新精转、不按录音时长计费。")
        MinutesDialogNamingHint(
          pendingCount: minutesDialogPendingNamingCount,
          onGoNaming: goNamingFromMinutesDialog
        )
      }
    }
  }

  /// 右上角只放两样:一颗 ⋯ 收全部低频与重做入口,外加一颗**只在真有事要做时才出现**的主按钮。
  ///
  /// 原来「生成纪要」是钉死的主按钮,等于假设你每次打开都要生成纪要;已经有纪要的场次
  /// 点开还杵着一颗主按钮(owner 2026-09-20:「已经有纪要的时候我就不会去生成纪要」)。
  /// 显性按钮的含义只有一个——**这场会还差一件事,点它就做掉**;全齐了就不该有按钮。
  /// 这条和 F2 v3 第 5 条(列表行「有下一步动作就是按钮,否则一枚状态字形」)同源,
  /// 两边共用同一个 `pipelineState.nextAction`,不各说各话。
  ///
  /// 「去确认」不在这里出现:完备度卡就在本页下方,不需要一颗按钮把你送到自己身上。
  /// 它只属于首页与会议库那种「你还不在这一页」的入口。
  private func headerNextActions(_ item: MeetingLibraryItem) -> some View {
    let state = model.pipelineState(for: item)
    return HStack(spacing: Tokens.V1.Space.xs) {
      Menu {
        Button("\(state.transcriptionActionTitle)…（按全时长计费）") { model.pendingReprocess = item }
          .disabled(!model.canRetryPostMeeting(for: item) || model.postMeetingStage(for: item).isRunning)
          .runtimeAccessibilityIdentifier("library.reprocess-secondary")
        Button("重新生成纪要…") { model.pendingMinutesGeneration = item }
          .disabled(!model.canGenerateMinutes(for: item) || model.minutesGenerationStage(for: item).isRunning)
        Divider()
        Button("复制当前页全文") {
          guard let text = model.textForCopy(for: item, tab: model.tab) else { return }
          NSPasteboard.general.clearContents()
          if NSPasteboard.general.setString(text, forType: .string) {
            model.reportCopySuccess("已复制当前页全文")
          }
        }
        .disabled(model.document(for: item, tab: model.tab).body == nil)
        Button("在 Finder 中显示") {
          NSWorkspace.shared.activateFileViewerSelecting([item.paths.directory])
        }
        // 「导出会议包」在右栏底也有一份,但右栏在**没有待办、也没有未决**时整栏不画
        // (owner 定的「空栏不画」),认名面板打开时右栏又被整个替换——两种情况下
        // 导出就够不着了。我删页脚时漏了这条路,台账写的「同样常驻可达」不成立。
        // 右上角这颗 ⋯ 本来就是「对这场会做什么」,把它并进来,不动右栏的规矩。
        // 「复制行动清单」同理:右栏现在跟着页签走(2026-09-20),
        // 在完整转写和会中记录上根本没有那一栏,这条路就断了。
        // ⋯ 是「对这场会做什么」的常驻入口,两条带走的路都收在这里。
        Button("复制行动清单") {
          guard let text = model.actionItemsCopyText(for: item) else { return }
          if NSPasteboard.general.setString(text, forType: .string) {
            model.reportCopySuccess("已复制 \(model.actionItemCount(for: item)) 条")
          }
        }
        .disabled(model.actionItemsCopyText(for: item) == nil)
        .runtimeAccessibilityIdentifier("library.copy-actions.overflow")
        exportMeetingPackageMenu(item)
        exportMeetingDiagnosticsMenu(item)
        Divider()
        Button("处理信息…") { processingInfoMeeting = item }
          .runtimeAccessibilityIdentifier("library.processing-info.open")
      } label: { Image(systemName: "ellipsis") }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("更多会议操作")
      .runtimeAccessibilityIdentifier("library.more")
      headerPrimaryAction(item, state)
    }
    .font(Tokens.V1.Text.label.font)
  }

  @ViewBuilder
  private func headerPrimaryAction(
    _ item: MeetingLibraryItem, _ state: MeetingPipelineState
  ) -> some View {
    switch state.nextAction {
    case .retryTranscription:
      Button(state.transcriptionActionTitle) { model.pendingReprocess = item }
        .buttonStyle(.v1Primary)
        .disabled(!model.canRetryPostMeeting(for: item))
        .runtimeAccessibilityIdentifier("library.reprocess-primary")
    case .generateMinutes:
      Button("生成纪要") { model.pendingMinutesGeneration = item }
        .buttonStyle(.v1Primary)
        .disabled(!model.canGenerateMinutes(for: item))
        .runtimeAccessibilityIdentifier("library.generate-minutes")
    case .regenerateMinutes:
      // 上一次生成失败,这确实还是「还差一件事」,不是重做。
      Button("重新生成纪要") { model.pendingMinutesGeneration = item }
        .buttonStyle(.v1Primary)
        .disabled(!model.canGenerateMinutes(for: item))
        .runtimeAccessibilityIdentifier("library.generate-minutes")
    case .confirmCompleteness, .none:
      EmptyView()
    }
  }

  func pipelineStrip(_ item: MeetingLibraryItem) -> some View {
    let pipeline = model.pipelineState(for: item)
    return HStack(spacing: Tokens.V1.Space.xs) {
      pipelineStep(
        label: "精转",
        key: "transcription",
        progress: pipeline.transcription,
        help: model.transcriptionStatusLabel(for: item)
      )
      pipelineChevron
      pipelineStep(
        label: "纪要",
        key: "minutes",
        progress: pipeline.minutes,
        help: nil
      )
      pipelineChevron
      completenessStep(pipeline.completeness)
    }
    .padding(.top, Tokens.V1.Space.s3xs)
    .accessibilityElement(children: .contain)
    .runtimeAccessibilityIdentifier("library.detail.pipeline")
  }

  private var pipelineChevron: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: Tokens.V1.Text.micro.size, weight: .semibold))
      .foregroundStyle(Tokens.V1.Color.ink4)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private func pipelineStep(
    label: String,
    key: String,
    progress: MeetingArtifactProgress,
    help: String?
  ) -> some View {
    HStack(spacing: Tokens.V1.Space.s3xs) {
      if progress == .inProgress {
        BreathingDots()
      } else {
        Circle()
          .fill(pipelineColor(progress))
          .frame(width: Tokens.V1.Space.s2xs, height: Tokens.V1.Space.s2xs)
      }
      Text(label)
        .font(.system(size: Tokens.V1.Text.meta.size, weight: .semibold))
        .foregroundStyle(pipelineColor(progress))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label):\(pipelineStateLabel(progress))")
    .help(help ?? "\(label)·\(pipelineStateLabel(progress))")
    .runtimeAccessibilityIdentifier("library.detail.pipeline.\(key)-\(progress.rawValue)")
  }

  @ViewBuilder
  private func completenessStep(_ verdict: EffectiveCompletenessVerdict?) -> some View {
    let (text, color): (String, Color) = {
      switch verdict {
      case .green: return ("完备", Tokens.V1.Color.ok)
      case .acknowledged: return ("已确认", Tokens.V1.Color.ok)
      case .red: return ("有缺口", Tokens.V1.Color.warn)
      case .undetermined, nil: return ("未查", Tokens.V1.Color.ink4)
      }
    }()
    HStack(spacing: Tokens.V1.Space.s3xs) {
      Circle()
        .fill(color)
        .frame(width: Tokens.V1.Space.s2xs, height: Tokens.V1.Space.s2xs)
      Text(text)
        .font(.system(size: Tokens.V1.Text.meta.size, weight: .semibold))
        .foregroundStyle(color)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("完备度：\(text)")
    .help("散会后自动检测录音/转写/纪要是否齐整；详情见下方完备度卡")
    .runtimeAccessibilityIdentifier(
      "library.detail.pipeline.completeness-\(verdict?.rawValue ?? "none")"
    )
  }

  private func pipelineColor(_ progress: MeetingArtifactProgress) -> Color {
    switch progress {
    case .completed: return Tokens.V1.Color.ok
    case .inProgress: return Tokens.V1.Color.accent
    case .failed: return Tokens.V1.Color.warn
    case .notStarted: return Tokens.V1.Color.ink4
    }
  }

  private func pipelineStateLabel(_ progress: MeetingArtifactProgress) -> String {
    switch progress {
    case .completed: return "完成"
    case .inProgress: return "进行中"
    case .failed: return "失败"
    case .notStarted: return "未做"
    }
  }
}

/// 模型事实只从这场会的用量快照读取，不以当前设置补齐历史空值。
public struct MeetingProcessingInfoView: View {
  private let item: MeetingLibraryItem
  @Environment(\.dismiss) private var dismiss

  public init(item: MeetingLibraryItem) { self.item = item }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      Text("处理信息").font(Tokens.V1.Text.heading.font)
      Text(item.title)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
      modelRow("转写模型", value: item.batchASRModelDisplayName, id: "library.asr-model")
      modelRow("纪要模型", value: item.minutesLLMModelName, id: "library.minutes-model")
      HStack {
        Spacer()
        Button("完成") { dismiss() }
          .buttonStyle(.v1Outline)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Tokens.V1.Space.lg)
    .frame(
      idealWidth: Tokens.V1.Size.settingsForm, maxWidth: Tokens.V1.Size.settingsForm,
      alignment: .leading
    )
    .foregroundStyle(Tokens.V1.Color.ink)
    .background(Tokens.V1.Color.paper)
    .runtimeAccessibilityIdentifier("library.processing-info")
  }

  private func modelRow(_ title: String, value: String?, id: String) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
      Text(title).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
      if let value {
        Text(value)
          .font(Tokens.V1.Text.body.font)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier(id)
      } else {
        Text("暂无用量记录")
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
          .runtimeAccessibilityIdentifier(id + ".empty")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
