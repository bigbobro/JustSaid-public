import JustSaidCore
import SwiftUI

extension MeetingLibraryView {
  func detailHeader(_ item: MeetingLibraryItem) -> some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: Tokens.Spacing.xsm) {
          EditableMeetingTitle(
            id: item.id,
            title: item.title,
            focus: $focusedMeetingTitleID,
            onCommit: { model.rename(item, to: $0) }
          )
          .id(item.id)
          // 保持宽窗的一行形态，但不允许元信息先被压成只有分隔点。
          headerMetadataChain(item)
          Spacer(minLength: Tokens.Spacing.xxs)
          headerNextActions(item)
        }
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
          HStack(alignment: .center, spacing: Tokens.Spacing.xsm) {
            EditableMeetingTitle(
              id: item.id,
              title: item.title,
              focus: $focusedMeetingTitleID,
              onCommit: { model.rename(item, to: $0) }
            )
            .id(item.id)
            Spacer(minLength: Tokens.Spacing.xxs)
            headerNextActions(item)
          }
          // 窄窗把元信息移到自己的可换行行，不与标题/操作按钮争抢宽度。
          headerMetadataChain(item, compact: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if model.shouldShowPipelineStrip(for: item) {
        pipelineStrip(item)
      }
      HStack(spacing: Tokens.Spacing.xs) {
        EditableTagChip(
          kind: .client,
          value: item.client,
          onCommit: { model.updateTag(.client, to: $0, of: item) }
        )
        EditableTagChip(
          kind: .project,
          value: item.project,
          onCommit: { model.updateTag(.project, to: $0, of: item) }
        )
        if let tagError = model.tagError {
          Text(tagError)
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.warn)
            .runtimeAccessibilityIdentifier("library.detail.tag.error")
        }
      }
      .id(item.id)
      if let failureReason = model.postMeetingFailureReason(for: item) {
        HStack(spacing: Tokens.Spacing.xxs) {
          Image(systemName: "exclamationmark.triangle.fill")
            .accessibilityHidden(true)
          // issue #27:这一行旁边没有按钮,所以下一步动作只能写进文案里。
          // 「重新精转」的说法与转写空态提示、上方的次级入口同名,用户能对上。
          Text(
            "会后处理未完成 · \(trimmedFailureReason(failureReason))。"
              + "录音已保留，可点上方「重新精转」重试。"
          )
        }
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.warn)
        .accessibilityElement(children: .combine)
        .runtimeAccessibilityIdentifier("library.failure-reason")
      }
      if let titleError = model.titleError {
        Text(titleError)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.warn)
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
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.sm)
    .confirmationDialog(
      "重新精转「\(model.pendingReprocess?.title ?? "")」?",
      isPresented: Binding(
        get: { model.pendingReprocess != nil },
        set: { if !$0 { model.pendingReprocess = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("重新精转(按全时长计费)", role: .destructive) {
        if let target = model.pendingReprocess {
          model.pendingReprocess = nil
          model.retryPostMeeting(for: target)
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        "会重新上传录音并按全时长计费 ASR。重跑结果可能与上次不同(包括数字与措辞)。"
          + "若只是改了发言人名字，请改用「生成纪要」(不重新精转)。"
      )
    }
    .confirmationDialog(
      "为「\(model.pendingMinutesGeneration?.title ?? "")」生成纪要",
      isPresented: Binding(
        get: { model.pendingMinutesGeneration != nil },
        set: { if !$0 { model.pendingMinutesGeneration = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(MinutesGenerationScope.chineseOnly.actionTitle) {
        startMinutesGeneration(scope: .chineseOnly)
      }
      Button(MinutesGenerationScope.bilingual.actionTitle) {
        startMinutesGeneration(scope: .bilingual)
      }
      Button("取消", role: .cancel) {}
    } message: {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
        Text("一种语言一次模型调用。只按盘上的转写生成，不重新精转、不按录音时长计费。")
        MinutesDialogNamingHint(
          pendingCount: minutesDialogPendingNamingCount,
          onGoNaming: goNamingFromMinutesDialog
        )
      }
    }
  }

  private func headerMetadataChain(_ item: MeetingLibraryItem, compact: Bool = false) -> some View {
    Group {
      if compact {
        compactMetadataRows(item)
      } else {
        singleMetadataRow(item)
      }
    }
    .runtimeAccessibilityIdentifier("library.metadata-row")
    .font(.system(size: Tokens.FontSize.ui))
    .foregroundStyle(Tokens.Color.ink3)
  }

  private func singleMetadataRow(_ item: MeetingLibraryItem) -> some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Text(item.compactStartedLabel)
      Text("·")
      Text(item.compactDurationLabel)
      if let client = item.client, !client.isEmpty {
        Text("·")
        Text(client)
      }
      Text("·")
      ParticipantHoverLabel(names: model.displaySpeakers(for: item))
      Text("·")
      Text(item.languageLabel)
      if [.inProgress, .failed].contains(model.transcriptionProgress(for: item)) {
        Text("·")
        Text(model.transcriptionStatusLabel(for: item))
      }
      if let requestIDSuffix = model.livePostMeetingRequestIDSuffix(for: item) {
        Text("·")
        Text("任务 …\(requestIDSuffix)")
          .textSelection(.enabled)
          .runtimeAccessibilityIdentifier("library.live-request-id")
      }
      modelMetadata(item)
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private func compactMetadataRows(_ item: MeetingLibraryItem) -> some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      compactPrimaryMetadata(item)
      HStack(spacing: Tokens.Spacing.xsm) {
        if [.inProgress, .failed].contains(model.transcriptionProgress(for: item)) {
          Text(model.transcriptionStatusLabel(for: item))
        }
        if let requestIDSuffix = model.livePostMeetingRequestIDSuffix(for: item) {
          Text("任务 …\(requestIDSuffix)")
            .textSelection(.enabled)
            .runtimeAccessibilityIdentifier("library.live-request-id")
        }
      }
      modelMetadata(item, compact: true)
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func compactPrimaryMetadata(_ item: MeetingLibraryItem) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Tokens.Spacing.xsm) {
        primaryMetadataContents(item)
      }
      .fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
        HStack(spacing: Tokens.Spacing.xsm) {
          Text(item.compactStartedLabel)
          Text("·")
          Text(item.compactDurationLabel)
        }
        HStack(spacing: Tokens.Spacing.xsm) {
          if let client = item.client, !client.isEmpty {
            Text(client)
              .fixedSize(horizontal: false, vertical: true)
          }
          Text("·")
          ParticipantHoverLabel(names: model.displaySpeakers(for: item))
          Text("·")
          Text(item.languageLabel)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func primaryMetadataContents(_ item: MeetingLibraryItem) -> some View {
    Text(item.compactStartedLabel)
    Text("·")
    Text(item.compactDurationLabel)
    if let client = item.client, !client.isEmpty {
      Text("·")
      Text(client)
    }
    Text("·")
    ParticipantHoverLabel(names: model.displaySpeakers(for: item))
    Text("·")
    Text(item.languageLabel)
  }

  @ViewBuilder
  private func modelMetadata(_ item: MeetingLibraryItem, compact: Bool = false) -> some View {
    if item.batchASRModelDisplayName != nil || item.minutesLLMModelName != nil {
      if compact {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xsm) {
            modelMetadataLabels(item, fixedWidth: true, withSeparators: false)
          }
          VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            modelMetadataLabels(item, fixedWidth: false, withSeparators: false)
          }
        }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xsm) {
          modelMetadataLabels(item, fixedWidth: true, withSeparators: true)
        }
      }
    }
  }

  @ViewBuilder
  private func modelMetadataLabels(
    _ item: MeetingLibraryItem,
    fixedWidth: Bool,
    withSeparators: Bool
  ) -> some View {
    if let batchASRModelDisplayName = item.batchASRModelDisplayName {
      if withSeparators { Text("·") }
      Text("ASR 模型：\(batchASRModelDisplayName)")
        .fixedSize(horizontal: fixedWidth, vertical: true)
        .runtimeAccessibilityIdentifier("library.asr-model")
    }
    if let minutesLLMModelName = item.minutesLLMModelName {
      if withSeparators { Text("·") }
      Text("纪要模型：\(minutesLLMModelName)")
        .fixedSize(horizontal: fixedWidth, vertical: true)
        .runtimeAccessibilityIdentifier("library.minutes-model")
    }
  }

  @ViewBuilder
  private func headerNextActions(_ item: MeetingLibraryItem) -> some View {
    let nextAction = model.pipelineState(for: item).nextAction
    if model.canGenerateMinutes(for: item) {
      let generateButton = Button {
        model.pendingMinutesGeneration = item
      } label: {
        HStack(spacing: Tokens.Spacing.xxs) {
          Image(systemName: "doc.text")
            .accessibilityHidden(true)
          Text(
            model.minutesGenerationStage(for: item).isRunning
              ? "生成中…"
              : "生成纪要"
          )
        }
      }
      Group {
        if nextAction == .retryTranscription {
          generateButton
            .buttonStyle(.borderless)
            .font(.system(size: Tokens.FontSize.ui))
            .foregroundStyle(Tokens.Color.ink3)
        } else {
          generateButton
            .buttonStyle(.toolbarPill)
        }
      }
      .disabled(model.minutesGenerationStage(for: item).isRunning)
      .help("只根据盘上的转写生成纪要，不重新精转、不按录音时长计费；点开选出中文还是中英")
      .runtimeAccessibilityIdentifier("library.generate-minutes")
    }
    if model.canRetryPostMeeting(for: item)
      && !model.postMeetingStage(for: item).isRunning
    {
      let reprocessButton = Button {
        model.pendingReprocess = item
      } label: {
        HStack(spacing: Tokens.Spacing.xxs) {
          Image(systemName: "arrow.triangle.2.circlepath")
            .accessibilityHidden(true)
          Text("重新精转")
        }
      }
      Group {
        if nextAction == .retryTranscription {
          reprocessButton
            .buttonStyle(.toolbarPill)
        } else {
          reprocessButton
            .buttonStyle(.borderless)
            .font(.system(size: Tokens.FontSize.ui))
            .foregroundStyle(Tokens.Color.ink3)
        }
      }
      .help("会按录音全时长重新计费 ASR；改发言人后只需点「生成纪要」")
      .runtimeAccessibilityIdentifier("library.reprocess-secondary")
    }
    Color.clear
      .frame(width: 0, height: 0)
      .runtimeAccessibilityIdentifier("library.detail.next-action.\(nextAction.rawValue)")
    if item.hasPartialCapture {
      PartialCaptureBadge(summary: item.partialCaptureSummary)
    }
    MeetingStatusBadge(status: model.effectiveStatus(for: item), finalized: item.finalized)
  }

  func pipelineStrip(_ item: MeetingLibraryItem) -> some View {
    let pipeline = model.pipelineState(for: item)
    return HStack(spacing: Tokens.Spacing.xs) {
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
    .padding(.top, Tokens.Spacing.hairline)
    .accessibilityElement(children: .contain)
    .runtimeAccessibilityIdentifier("library.detail.pipeline")
  }

  private var pipelineChevron: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: Tokens.FontSize.glyphTiny, weight: .semibold))
      .foregroundStyle(Tokens.Color.ink4)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private func pipelineStep(
    label: String,
    key: String,
    progress: MeetingArtifactProgress,
    help: String?
  ) -> some View {
    HStack(spacing: Tokens.Spacing.hairline) {
      if progress == .inProgress {
        BreathingDots()
      } else {
        Circle()
          .fill(pipelineColor(progress))
          .frame(width: 5, height: 5)
      }
      Text(label)
        .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
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
      case .green: return ("完备", Tokens.Color.resolved)
      case .acknowledged: return ("已确认", Tokens.Color.resolved)
      case .red: return ("有缺口", Tokens.Color.warn)
      case .undetermined, nil: return ("未查", Tokens.Color.ink4)
      }
    }()
    HStack(spacing: Tokens.Spacing.hairline) {
      Circle()
        .fill(color)
        .frame(width: 5, height: 5)
      Text(text)
        .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
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
    case .completed: return Tokens.Color.resolved
    case .inProgress: return Tokens.Color.ac
    case .failed: return Tokens.Color.warn
    case .notStarted: return Tokens.Color.ink4
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

private struct ParticipantHoverLabel: View {
  let names: [String]
  @State private var isHovering = false

  var body: some View {
    Text(label)
      .underline(isHovering, color: Tokens.Color.ink4)
      .onHover { isHovering = $0 }
      .overlay(alignment: .topLeading) {
        if isHovering, !names.isEmpty {
          VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
              Text(name)
                .font(.system(size: Tokens.FontSize.secondary))
                .foregroundStyle(name == "我" ? Tokens.Color.me : Tokens.Color.ink2)
            }
          }
          .padding(.horizontal, Tokens.Spacing.xsm)
          .padding(.vertical, Tokens.Spacing.xxs)
          .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
              .fill(Tokens.Color.card)
          )
          .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
              .stroke(Tokens.Color.line, lineWidth: 1)
          )
          .shadow(
            color: Tokens.Shadow.sh2.color,
            radius: Tokens.Shadow.sh2.radius,
            y: Tokens.Shadow.sh2.y
          )
          .offset(y: Tokens.Spacing.lg)
          .zIndex(8)
        }
      }
      .runtimeAccessibilityIdentifier("one-page.participants")
      .accessibilityLabel(accessibilityText)
  }

  private var label: String {
    names.isEmpty ? "待识别" : "\(names.count) 人"
  }

  private var accessibilityText: String {
    names.isEmpty ? "参会人：待识别" : "参会人：\(names.joined(separator: "、"))"
  }
}
