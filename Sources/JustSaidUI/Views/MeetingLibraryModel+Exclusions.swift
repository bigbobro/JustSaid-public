import AppKit
import Foundation
import JustSaidCore
import SwiftUI

// 2026-08-20 批3 拆分:自 MeetingLibraryModel.swift 按 MARK 边界机械迁出,零行为变更;
// 存储属性依 Swift 约束全部留在主文件(恰好锁死零行为)。
extension MeetingLibraryModel {
  // MARK: - 高亮通读(08-14 chip 交互单)

  /// chip 单击:进入该显示名的高亮通读;同人再点退出。
  /// 进入时清掉「只看」(互斥),并自动滚到此人的首次发言。
  /// 显示名口径 = `speakerNames[label]` 非空 ? 真名 : 原始标签(与 `displaySpeakers`
  /// 的主映射一致;单段 override 属少数,不按它建桶)。
  public func toggleSpeakerHighlight(_ speaker: String) {
    if speakerHighlight == speaker {
      clearSpeakerHighlight()
      return
    }
    speakerHighlight = speaker
    speakerHighlightIndex = 0
    speakerFilter = nil
    guard let selectedItem,
      let first = highlightAnchors(for: selectedItem).first
    else { return }
    tab = .transcript
    transcriptJumpRequest = TranscriptJumpRequest(seconds: first)
  }

  /// ✕ / Esc / 再点 chip 三条退出路径都落到这一处。
  public func clearSpeakerHighlight() {
    speakerHighlight = nil
    speakerHighlightIndex = 0
  }

  /// 「上一处/下一处」:**循环遍历**(末尾再下一条回首条)——通读是反复对照的场景,
  /// 停在末条还得自己手动滚回首段,比环回更别扭。跳转复用 `transcriptJumpRequest`,
  /// 不为高亮新铺管道。
  public func stepSpeakerHighlight(by delta: Int, of item: MeetingLibraryItem) {
    guard speakerHighlight != nil else { return }
    let anchors = highlightAnchors(for: item)
    guard !anchors.isEmpty else { return }
    speakerHighlightIndex =
      (speakerHighlightIndex + delta + anchors.count) % anchors.count
    transcriptJumpRequest = TranscriptJumpRequest(seconds: anchors[speakerHighlightIndex])
  }

  /// 「第 k/n 处」的展示口径:k 随导航走,n 从当前行集现算(改名/单段更正会改桶大小)。
  /// index 越界(桶变小)时收进范围内——展示层不该看见 17/16。
  func speakerHighlightProgress(for item: MeetingLibraryItem) -> (index: Int, count: Int)? {
    guard speakerHighlight != nil else { return nil }
    let anchors = highlightAnchors(for: item)
    guard !anchors.isEmpty else { return nil }
    return (min(speakerHighlightIndex, anchors.count - 1), anchors.count)
  }

  /// 高亮对象各行发言的锚点(秒),按行序——跳转目标与 k/n 计数同一份事实。
  private func highlightAnchors(for item: MeetingLibraryItem) -> [TimeInterval] {
    guard let speakerHighlight else { return [] }
    return TranscriptDocumentView.highlightAnchors(
      in: transcriptRows(for: item),
      of: speakerHighlight
    )
  }

  /// 单段更正(N2)。`name` 为空即撤销这一段的覆盖,回到全局映射结算的结果。
  /// 只写 `meeting.json`,`transcript.md` 一个字节都不碰。
  func setSpeakerOverride(
    _ name: String?,
    for line: TranscriptSpeechLine,
    of item: MeetingLibraryItem
  ) {
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else { return }
    do {
      let metadata = try meetingStore.setSpeakerOverride(
        name,
        forSegment: line.overrideKey,
        at: item.paths
      )
      meetings[index].speakerOverrides = metadata.speakerOverrides ?? [:]
      invalidateTranscriptPresentation(forMeetingID: item.id)
      speakerNameError = nil
      // 刻意不让筛选跟着改后的人跑:典型动作是「只看张三 → 挑出不是他的那几段改掉」,
      // 每改一段就把视图甩到另一个人身上,等于每次都把人从复核队列里踢出去。
    } catch {
      speakerNameError = "这一段的更正没能存进 meeting.json:\(error.localizedDescription)"
    }
    pendingOverrideLine = nil
  }

  /// 失焦即存。只写 `meeting.json`,不碰 `transcript.md`(F2 红线:权威转写保持产物纯净)。
  public func setSpeakerName(_ name: String, for label: String, of item: MeetingLibraryItem) {
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != (item.speakerNames[label] ?? "") else { return }
    // 改名跟随(验收硬项):高亮/只看都按生效后的显示名建桶,名字一换,
    // 旧桶名就再也命中不了任何行——必须把状态换到新显示名上(清名则回退标签本身)。
    let oldDisplayName = item.speakerNames[label].flatMap { $0.isEmpty ? nil : $0 } ?? label
    let newDisplayName = trimmed.isEmpty ? label : trimmed
    do {
      let metadata = try meetingStore.setSpeakerName(
        trimmed.isEmpty ? nil : trimmed,
        for: label,
        at: item.paths
      )
      meetings[index].speakerNames = metadata.speakerNames ?? [:]
      invalidateTranscriptPresentation(forMeetingID: item.id)
      if speakerHighlight == oldDisplayName {
        speakerHighlight = newDisplayName
        speakerHighlightIndex = 0
      }
      if speakerFilter == oldDisplayName {
        speakerFilter = newDisplayName
      }
      speakerNameError = nil
    } catch {
      speakerNameError = "这个名字没能存进 meeting.json:\(error.localizedDescription)"
    }
  }

  // MARK: - 排除时间段(08-14)

  /// 会后选段排除(postSelect):起点取该行时间戳,终点取到下一条发言行**之前**;
  /// 已是最后一条时兜底 +30 秒(与会中 bullet 排除同一口径)。
  /// 只写 `meeting.json` 的排除记录,`transcript.md` 一个字节都不碰。
  func excludeTranscriptLine(_ line: TranscriptSpeechLine, of item: MeetingLibraryItem) {
    guard
      let index = meetings.firstIndex(where: { $0.id == item.id }),
      let start = TranscriptAnchor(timecode: line.timestamp).seconds
    else { return }
    let nextSpeechStart = transcriptRows(for: item).compactMap { row -> TimeInterval? in
      guard case .speech(let other) = row, other.index > line.index else { return nil }
      return TranscriptAnchor(timecode: other.timestamp).seconds
    }.min()
    // Core 按闭区间 + 行首锚点判归属:end 恰等于下一行锚点会把下一行也吞掉。
    // 时间戳分辨率 1 秒,退 1 秒正好盖住本行到下一行之间的所有锚点;
    // 下一行与本行同秒时退成点区间 [start, start](同秒本就无法区分)。
    let end = nextSpeechStart.map { max(start, $0 - 1) } ?? start + 30
    do {
      let range = try meetingStore.addExcludedRange(
        start: start,
        end: end,
        origin: ExclusionUI.Origin.postSelect,
        at: item.paths
      )
      // add 只回区间不回整份 metadata;按 MeetingStore 的追加语义本地补齐,
      // 与 `setSpeakerOverride` 的局部更新同款,不整表 reload。
      meetings[index].excludedRanges.append(range)
      exclusionError = nil
    } catch {
      exclusionError = "这段排除没能存进 meeting.json:\(error.localizedDescription)"
    }
  }

  /// 批量选段排除(08-14 exclusion-batch-select):把 [first, last] 闭区间(按行序,
  /// 乱序传入会先归一)写成**一条** postSelect 记录——撤销一次整段恢复,不用新机制。
  /// start = 首行锚点;end 遵守 exclusion-ranges-contract 的相邻行陷阱:取末行之后
  /// 第一条发言行锚点 − 1 秒(直接取下一行锚点会把下一行吞进过滤;同秒退化成点区间,
  /// 时间戳分辨率 1 秒,同秒本就无法区分)。末行已是全文最后一条发言时兜底 +30 秒:
  /// `TranscriptSpeechLine` 没有 t1,段落真实结束时刻不可得,与 `excludeTranscriptLine`
  /// 的末条兜底保持同一口径。写成功后清选区——灰显由既有排除渲染自动接管;
  /// 写失败保留选区,原因走既有 exclusionError。
  /// public:探针直接驱动它断言一条 postSelect 区间的 end 口径与落盘。
  public func excludeTranscriptRange(
    from first: TranscriptSpeechLine,
    to last: TranscriptSpeechLine,
    of item: MeetingLibraryItem
  ) {
    let ordered = first.index <= last.index ? (first, last) : (last, first)
    guard
      let index = meetings.firstIndex(where: { $0.id == item.id }),
      let start = TranscriptAnchor(timecode: ordered.0.timestamp).seconds,
      let lastStart = TranscriptAnchor(timecode: ordered.1.timestamp).seconds
    else { return }
    let nextSpeechStart = transcriptRows(for: item).compactMap { row -> TimeInterval? in
      guard case .speech(let other) = row, other.index > ordered.1.index else { return nil }
      return TranscriptAnchor(timecode: other.timestamp).seconds
    }.min()
    let end = nextSpeechStart.map { max(lastStart, $0 - 1) } ?? lastStart + 30
    do {
      let range = try meetingStore.addExcludedRange(
        start: start,
        end: end,
        origin: ExclusionUI.Origin.postSelect,
        at: item.paths
      )
      // 与 excludeTranscriptLine 同款:按 MeetingStore 追加语义本地补齐,不整表 reload。
      meetings[index].excludedRanges.append(range)
      exclusionError = nil
      transcriptSelection = nil
    } catch {
      exclusionError = "这段排除没能存进 meeting.json:\(error.localizedDescription)"
    }
  }

  /// Esc / 动作条 ✕ / 切会议 / 切页签共用的清选区入口。public:探针驱动。
  public func clearTranscriptSelection() {
    transcriptSelection = nil
  }

  /// 撤销一段排除(按 id)。判定「哪条区间覆盖这行」在视图侧(`ExclusionUI.coveringRange`)。
  /// public:探针驱动「批量选段一次撤销整段」断言。
  public func removeExclusion(id: UUID, of item: MeetingLibraryItem) {
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else { return }
    do {
      let metadata = try meetingStore.removeExcludedRange(id: id, at: item.paths)
      meetings[index].excludedRanges = metadata.excludedRanges ?? []
      exclusionError = nil
    } catch {
      exclusionError = "撤销排除没能存进 meeting.json:\(error.localizedDescription)"
    }
  }

  /// 发言人整体排除/恢复。`label` 是转写原始标签,不是改名后的显示名(契约红线)。
  func setSpeakerExcluded(_ label: String, excluded: Bool, of item: MeetingLibraryItem) {
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else { return }
    do {
      let metadata = try meetingStore.setSpeakerExcluded(
        label,
        excluded: excluded,
        at: item.paths
      )
      meetings[index].excludedSpeakers = metadata.excludedSpeakers ?? []
      exclusionError = nil
    } catch {
      exclusionError = "发言人排除状态没能存进 meeting.json:\(error.localizedDescription)"
    }
  }

  func document(for item: MeetingLibraryItem, tab: MeetingDetailTab) -> MeetingDocument {
    let artifacts = artifacts(for: item)
    switch tab {
    case .onePage:
      return MeetingDocument(
        body: onePager(for: item).map {
          OnePagerMarkdownRenderer.render(
            title: item.title,
            startedAt: item.startedAt,
            endedAt: item.endedAt,
            participants: displaySpeakers(for: item),
            shortCoveredSeconds: item.shortCoveredSeconds,
            document: $0
          )
        },
        emptyHint: "一页纸会在中文版纪要生成后出现；拿不准会议骨架时会直接显示要点列表。"
      )
    case .minutes:
      // AC13:正在生成的那一版直接铺实时正文,让用户看见"在生成什么"。
      // 排版投影由 `MinutesDocumentPane` 做;这里保留 body = 缓冲区原文,
      // 供「复制当前页全文」等读 body 的路径拿到与盘上 partial 同一份的内容。
      if let draft = activeLiveMinutesDraft(for: item) {
        return MeetingDocument(
          body: draft.content.isEmpty ? nil : draft.content,
          emptyHint: "正在生成\(minutesVariant == .chinese ? "中文" : "英文")版纪要，正文马上开始写出…"
        )
      }
      // 中英两版彻底对称:选哪一版就只看哪一版的文件、只说哪一版的话。
      // 刻意不做「英文版没有就悄悄回落中文版」——那会让点了 EN 的人对着中文发愣;
      // 明说这一版还没有,比给他一版他没要的东西诚实。
      switch minutesVariant {
      case .chinese:
        let body: String? = {
          if let minutesRevisionID,
            let revision = artifacts.minutesRevisions.first(where: { $0.id == minutesRevisionID })
          {
            return revision.content
          }
          return artifacts.minutes
        }()
        let structuredMinutes: MeetingMinutesDocument?
        let onJumpToTranscript: ((TimeInterval) -> Void)?
        if minutesRevisionID == nil {
          structuredMinutes = artifacts.structuredMinutes
          onJumpToTranscript = { [weak self] seconds in
            self?.jumpToTranscript(seconds)
          }
        } else {
          structuredMinutes = nil
          onJumpToTranscript = nil
        }
        return MeetingDocument(
          body: body,
          emptyHint: chineseMinutesEmptyHint(for: item),
          // 历史修订只有 Markdown、没有对应 sidecar；拿最新结构渲染旧版会所见非所得。
          structuredMinutes: structuredMinutes,
          onJumpToTranscript: onJumpToTranscript
        )
      case .english:
        return MeetingDocument(
          body: artifacts.minutesEnglish,
          emptyHint: englishMinutesEmptyHint(for: item)
        )
      }
    case .transcript:
      return MeetingDocument(
        // 呈现层套真名;落盘的 transcript.md 一个字都没动。
        body: artifacts.transcript.map {
          TranscriptSpeakerNaming.applyingNames(
            item.speakerNames,
            overrides: item.speakerOverrides,
            to: $0
          )
        },
        emptyHint: transcriptEmptyHint(for: item)
      )
    case .inMeeting:
      let selectedSnapshot =
        artifacts.summarySnapshots.first { $0.id == snapshotID }
        ?? artifacts.summarySnapshots.last
      var parts: [String] = []
      if let history = selectedSnapshot?.content, !history.isEmpty {
        parts.append(history)
      }
      if let notes = artifacts.notes, !notes.isEmpty {
        parts.append(notes)
      }
      return MeetingDocument(
        body: parts.isEmpty ? nil : parts.joined(separator: "\n\n"),
        emptyHint: "这场会议没有会中记录。"
      )
    }
  }

  /// 定稿锁的提示语对两版独立(design.md D3):`commitFormalMinutes` 与 `commitEnglishMinutes`
  /// 各自检查 `finalized`,所以「为什么这一版没有」的答案也必须分版本说,不能共用一句话。
  private func chineseMinutesEmptyHint(for item: MeetingLibraryItem) -> String {
    if item.finalized {
      return "这场会议已定稿，中文版纪要不会再被自动生成覆盖；当前目录里没有中文版正文。"
    }
    if item.status == .failed {
      return "这场会议的会后处理没跑完，所以还没有中文版纪要。检查设置里的模型与对象存储配置后可以重新精转。"
    }
    let hasTranscript = artifacts(for: item).transcript != nil
    if hasTranscript {
      return "权威转写已就绪。可先改发言人名字，再点「生成纪要」(只花纪要模型费用，不重新精转)。"
    }
    return "中文版纪要还没生成。结束会议后会先出一版速记纪要；精转完成后可点「生成纪要」。"
  }

  /// 当前应铺到纪要页签上的生成中缓冲区(单一事实源):
  /// 只在语种对得上时铺——英文正文铺到中文版下面比不铺更糟;
  /// 也只在「最新」视角下铺:用户翻到某个历史版本时,不该被生成中的内容顶掉。
  func activeLiveMinutesDraft(for item: MeetingLibraryItem) -> PostMeetingLiveMinutesDraft? {
    guard
      let draft = postMeetingTasks.liveMinutesDraft(for: item.paths.directory),
      MinutesVariant(minutesLanguage: draft.language) == minutesVariant,
      minutesRevisionID == nil
    else {
      return nil
    }
    return draft
  }

  func inMeetingNotesEmptyHint() -> String {
    "这场会议没有补充记录。会中在右栏随手记一句，系统会自动带上「第几分钟」的时间戳。"
  }

  func inMeetingHistoryEmptyHint() -> String {
    "这场会议没有留下会中总结。"
  }

  /// 核对入口门:有规范化 minutes.json 且结构化视图真能构造。与 MinutesDocumentPane 同一口径。
  func canOpenCheckWorkbench(for item: MeetingLibraryItem) -> Bool {
    let document = document(for: item, tab: .minutes)
    guard
      let structuredMinutes = document.structuredMinutes,
      let body = document.body
    else {
      return false
    }
    return MinutesStructuredView.canRender(
      document: structuredMinutes,
      minutesMarkdown: body
    )
  }

  /// 核对工作台上下文(08-17 R-a):队列/指纹/已存判定/转写行/台账上下文一次备齐。
  /// 队列从 minutes.json 纯派生;判定只写 check.json——纪要与转写产物零写入。
  /// nil = 没有规范化 sidecar(旧会议),入口整行缺席。public:探针断言有/无 sidecar 两态。
  public func checkContext(for item: MeetingLibraryItem) -> MinutesCheckContext? {
    // 队列与指纹必须出自**同一份字节**:拿缓存的结构化文档配新鲜指纹,纪要刚换代而
    // artifactCache 未失效的窗口里,判定会挂到不属于它的指纹上(静默错版,R3 大忌)。
    guard
      let sidecarBytes = try? Data(contentsOf: item.paths.minutesStructured),
      let structuredMinutes = try? StructuredArtifactCodec.decode(
        MeetingMinutesDocument.self,
        from: sidecarBytes
      )
    else {
      return nil
    }
    let store = meetingStore
    let paths = item.paths
    return MinutesCheckContext(
      meetingID: item.id,
      queue: CheckQueueBuilder.build(from: structuredMinutes),
      currentFingerprint: MinutesFingerprint.hex(of: sidecarBytes),
      storedRecord: store.loadCheckRecord(at: paths),
      transcriptRows: transcriptRows(for: item),
      ledgerContext: CheckLedgerContext(
        directoryName: paths.directory.lastPathComponent,
        title: item.title,
        startedAt: item.startedAt,
        endedAt: item.endedAt,
        // 台账口径:语言以耳朵为准;auto 在台账行留空由用户填,不 machine 猜。
        language: item.language
      ),
      save: { record in
        do {
          try store.saveCheckRecord(record, at: paths)
          return nil
        } catch {
          return "判定没能存进 check.json:\(error.localizedDescription)"
        }
      },
      reportCopy: { [weak self] notice in
        self?.reportCopySuccess(notice)
      }
    )
  }

  /// 有权威转写、未定稿、这场会没有任何会后任务在跑 → 可生成纪要。
  ///
  /// 「在不在跑」统一问协调者:分裂成三个本地字典时,同一个 model 实例内就能一边
  /// 流式写纪要一边启动全量重精转,remount 一次更是直接把守卫清空。
  func canGenerateMinutes(for item: MeetingLibraryItem) -> Bool {
    guard postMeetingTasks.hasPipelineResolver else { return false }
    guard !item.finalized else { return false }
    guard item.status != .recording && item.status != .processing else { return false }
    guard !postMeetingTasks.isRunning(directory: item.paths.directory) else { return false }
    return artifacts(for: item).transcript != nil
  }

  /// 纪要生成阶段只读协调者快照(app 生命周期,关窗/remount 都还在)。
  /// 刻意**不**做磁盘兜底:重启后盘上留着的 `.md.partial` 只说明"上一轮没跑完",
  /// 把它读成"正在跑"是编造进行中状态。
  func minutesGenerationStage(for item: MeetingLibraryItem) -> PostMeetingStage {
    postMeetingTasks.stage(for: item.paths.directory, kinds: [.minutes]) ?? .none
  }

  /// 独立生成纪要:复用 `regenerateMinutes`,不上传、不 submit、不追加 batchASR。
  ///
  /// F5:出几份由调用方(确认弹窗)当场给定,不再读 `batchLanguageDecision` 替用户决定
  /// ——该字段为 nil 或 `auto` 时会判成"要英文",让中文会白花一份钱。
  func generateMinutes(
    for item: MeetingLibraryItem,
    scope: MinutesGenerationScope
  ) {
    guard canGenerateMinutes(for: item) else { return }
    // 中文必出(主产物);英文只在用户这一次明确要了才出。
    guard
      postMeetingTasks.startMinutes(
        at: item.paths,
        languages: scope.languages,
        kind: .minutes
      )
    else {
      return
    }
    // AC13:正文马上就要往外写了,把用户带到能看见它的地方。
    // 生成一律从中文起(中文是主产物),所以变体也复位到中文、版本回到「最新」;
    // 原始数据开关也复位——新一轮默认先看排版投影。
    // 导航留在这里(按钮按下的当场),协调者完成时不得改动用户当前选择的会议。
    tab = .minutes
    minutesVariant = .chinese
    minutesRevisionID = nil
    showsRawLiveMinutes = false
  }

  private func englishMinutesEmptyHint(for item: MeetingLibraryItem) -> String {
    if item.finalized {
      return "这场会议已定稿，英文版纪要(minutes-en.md)不会再被自动生成覆盖。"
    }
    if let partial = item.englishMinutesPartialFailure {
      return "英文版纪要上次没生成成功：\(partial.detail)。可点下方重试，不会重新计费精转。"
    }
    return item.status == .failed
      ? "这场会议的会后处理没跑完，所以还没有英文版纪要。重新精转会把中英两版一起再生成一次。"
      : "英文版纪要还没生成。它由完整版纪要阶段独立从转写产出，不是中文版的译文。"
  }

  func englishMinutesRetryStage(for item: MeetingLibraryItem) -> PostMeetingStage {
    postMeetingTasks.stage(for: item.paths.directory, kinds: [.englishMinutes]) ?? .none
  }

  func canRetryEnglishMinutes(for item: MeetingLibraryItem) -> Bool {
    item.canRetryEnglishMinutes && postMeetingTasks.hasPipelineResolver
      && !postMeetingTasks.isRunning(directory: item.paths.directory)
  }

  /// 只重试英文版纪要:走 `regenerateMinutes(languages: [.english])`,
  /// 不上传、不 submit、不追加 batchASR 用量。
  func retryEnglishMinutes(for item: MeetingLibraryItem) {
    guard canRetryEnglishMinutes(for: item) else { return }
    postMeetingTasks.startMinutes(
      at: item.paths,
      languages: [.english],
      kind: .englishMinutes,
      successNotice: "英文版纪要已重新生成"
    )
  }

  func postMeetingStage(for item: MeetingLibraryItem) -> PostMeetingStage {
    if let stage = postMeetingTasks.stage(
      for: item.paths.directory,
      kinds: [.fullPostMeeting, .recovery]
    ) {
      return stage
    }
    if item.status == .processing {
      return .running
    }
    guard item.status == .failed else {
      return .none
    }
    return .failed(
      reason: item.postMeetingFailureReason ?? "这场会议没有留下具体失败原因"
    )
  }

  /// 会后处理失败的原因。会议库详情不再挂顶部状态横幅(08-10 用户改判:状态属于某一场
  /// 会议,该跟着那一行走),所以失败诊断改挂在详情头、紧邻「重新精转」入口。
  /// 事实源与行内记号、驾驶舱横幅完全一致:协调者快照优先、磁盘兜底,不新增第三套。
  func postMeetingFailureReason(for item: MeetingLibraryItem) -> String? {
    guard case .failed(let reason) = postMeetingStage(for: item) else { return nil }
    return reason
  }

  /// 「精」记号:进行中 → 失败 → 磁盘事实。失败优先于「盘上还有上一轮的转写」——
  /// 最近一次精转失败了这件事必须看得见,那正是用户要找的入口。
  func transcriptionProgress(for item: MeetingLibraryItem) -> MeetingArtifactProgress {
    let stage = postMeetingStage(for: item)
    if stage.isRunning {
      return .inProgress
    }
    if case .failed = stage {
      return .failed
    }
    return item.hasAuthoritativeTranscript ? .completed : .notStarted
  }

  /// 「纪」记号。失败只认**主产物**那一路(`.minutes`)的快照:
  /// 英文版是附加产物,08-07 契约明写「只在纪要页提示,不惊动会议库列表与状态徽章」,
  /// 所以英文重试只贡献「进行中」,不贡献「失败」。
  ///
  /// 纪要类失败按 08-07 不写 `failed` 状态,因此它**只有协调者快照这一个来源**,
  /// 随 ⌘L 的 `dismissSettledFeedback()` 一起结算(与 `MinutesGenerationStatusBanner`
  /// 的既有行为一致);收掉之后回落磁盘事实 = 「未做」,不会变成假的「完成」。
  func minutesProgress(for item: MeetingLibraryItem) -> MeetingArtifactProgress {
    let minutesStage = minutesGenerationStage(for: item)
    if minutesStage.isRunning || englishMinutesRetryStage(for: item).isRunning {
      return .inProgress
    }
    if case .failed = minutesStage {
      return .failed
    }
    return item.hasFormalMinutes ? .completed : .notStarted
  }

  func canRetryPostMeeting(for item: MeetingLibraryItem) -> Bool {
    item.canRetryPostMeeting && postMeetingTasks.hasPipelineResolver
      && !postMeetingTasks.isRunning(directory: item.paths.directory)
  }

  /// 全量重新精转。清诊断、重建输入、跑管线、终态写盘与成功广播全在协调者里,
  /// 关窗或 remount 都不影响它跑完。
  func retryPostMeeting(for item: MeetingLibraryItem) {
    guard canRetryPostMeeting(for: item) else { return }
    postMeetingTasks.startRetranscription(at: item.paths)
  }

  func artifacts(for item: MeetingLibraryItem) -> MeetingArtifacts {
    if let cached = artifactCache[item.id] {
      return cached
    }
    scheduleArtifactLoad(for: item)
    return .emptyLibrarySnapshot
  }

}
