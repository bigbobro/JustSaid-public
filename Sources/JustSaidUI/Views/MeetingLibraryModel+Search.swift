import AppKit
import Foundation
import JustSaidCore
import SwiftUI

// 2026-08-20 批3 拆分:自 MeetingLibraryModel.swift 按 MARK 边界机械迁出,零行为变更;
// 存储属性依 Swift 约束全部留在主文件(恰好锁死零行为)。
extension MeetingLibraryModel {
  // MARK: - 全库搜索(08-17 #1「谁说过 X」)

  /// 「N 场 · M 条」计数的 M;流式追加中会逐场增长。public:探针断言计数口径。
  public var librarySearchTotalHitCount: Int {
    librarySearchResults.reduce(0) { $0 + $1.hits.count }
  }

  /// 后台扫描一场会议所需的全部输入,在主线程一次取齐(值拷贝),扫描不回头碰 model。
  private struct LibrarySearchScanInput: Sendable {
    let meetingID: String
    let transcriptURL: URL
    let speakerNames: [String: String]
    let speakerOverrides: [String: String]
  }

  /// query 变更(防抖 250ms)与 reload 重扫(不防抖)共用的唯一入口。
  /// 取消要真取消:新一轮先 cancel 上一轮,扫描循环在**会议之间**检查取消,
  /// 连续快速输入不会堆积全库扫。零索引、只读:结果每轮从磁盘现算。
  func scheduleLibrarySearch(debounce: Bool) {
    librarySearchTask?.cancel()
    let query = librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      librarySearchTask = nil
      librarySearchResults = []
      isLibrarySearching = false
      return
    }
    isLibrarySearching = true
    let inputs = meetings.map { item in
      LibrarySearchScanInput(
        meetingID: item.id,
        transcriptURL: item.paths.transcript,
        speakerNames: item.speakerNames,
        speakerOverrides: item.speakerOverrides
      )
    }
    librarySearchTask = Task { [weak self] in
      if debounce {
        try? await Task.sleep(for: .milliseconds(250))
      }
      guard !Task.isCancelled else { return }
      self?.librarySearchResults = []
      let clock = ContinuousClock()
      let scanStart = clock.now
      var hitLineCount = 0
      for input in inputs {
        // 会议间取消检查:上一轮被新输入取消后,不再多读一份文件。
        guard !Task.isCancelled else { return }
        let hits = await Self.scanTranscript(input, query: query)
        guard let self, !Task.isCancelled else { return }
        if !hits.isEmpty {
          hitLineCount += hits.count
          // 流式回填:每完成一场就追加上屏,首批结果不等全库扫完。
          librarySearchResults.append(
            LibrarySearchResult(meetingID: input.meetingID, hits: hits)
          )
        }
      }
      guard let self, !Task.isCancelled else { return }
      isLibrarySearching = false
      let elapsed = scanStart.duration(to: clock.now)
      let elapsedMilliseconds =
        Double(elapsed.components.seconds) * 1_000
        + Double(elapsed.components.attoseconds) / 1e15
      // 性能打点只记结构性信息(场数/命中数/耗时),不落 query 与转写正文。
      let summary =
        "全库搜索扫描完成：\(inputs.count) 场，"
        + "命中 \(librarySearchResults.count) 场 \(hitLineCount) 条，"
        + String(format: "耗时 %.0f ms", elapsedMilliseconds)
      librarySearchLogger.info("\(summary, privacy: .public)")
    }
  }

  /// 后台逐场扫描:读 `transcript.md`(与详情页同一份文件、同一非空判定)→
  /// `TranscriptSpeakerNaming.rows` 结算改名 → `LibrarySearchScanner.matches`。
  /// 不写第二个解析器——命中行显示的说话人名与用户点进详情看到的一致。
  /// nonisolated async:落在全局并发执行器上执行,不占主线程。
  private nonisolated static func scanTranscript(
    _ input: LibrarySearchScanInput,
    query: String
  ) async -> [LibrarySearchHit] {
    guard
      let transcript = try? String(contentsOf: input.transcriptURL, encoding: .utf8),
      !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return []
    }
    let rows = TranscriptSpeakerNaming.rows(
      in: transcript,
      names: input.speakerNames,
      overrides: input.speakerOverrides
    )
    return LibrarySearchScanner.matches(rows: rows, query: query)
  }

  /// 点全库搜索命中行:走既有 select(会议) → 切转写页签 → TranscriptJumpRequest 链,
  /// 不新造跳转;**不预置**场内 ⌘F 过滤(过滤会藏上下文,要过滤用户自己开)。
  /// 搜索 query 与结果都不清——回到列表态搜索现场还在(G3)。
  /// public:探针驱动「点命中 → 定位请求 + 搜索态保持」断言。
  public func openLibrarySearchHit(meetingID: String, hit: LibrarySearchHit) {
    guard meetings.contains(where: { $0.id == meetingID }) else { return }
    select(meetingID)
    if let seconds = TranscriptAnchor(timecode: hit.timestamp).seconds {
      jumpToTranscript(seconds)
    } else {
      // 时间戳词面解析不出秒数时不发明定位,只落到转写页。
      tab = .transcript
    }
  }

  @discardableResult
  func rename(_ item: MeetingLibraryItem, to title: String) -> String {
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else {
      return item.title
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      titleError = MeetingStoreError.emptyTitle.localizedDescription
      return item.title
    }
    guard trimmed != item.title else {
      titleError = nil
      return item.title
    }

    if recordingSession?.currentMeetingDirectory?.standardizedFileURL
      == item.paths.directory.standardizedFileURL
    {
      guard recordingSession?.renameCurrentMeeting(to: trimmed) == true else {
        titleError = "会议名称没能保存，录制仍在继续。"
        return item.title
      }
      meetings[index].title = recordingSession?.currentTitle ?? trimmed
      titleError = nil
      return meetings[index].title
    }

    do {
      let metadata = try meetingStore.renameMeeting(to: trimmed, at: item.paths)
      meetings[index].title = metadata.title
      titleError = nil
      return metadata.title
    } catch {
      titleError = "会议名称没能保存：\(error.localizedDescription)"
      return item.title
    }
  }

  /// 客户/项目标签编辑(08-17 R-b):trim 与空归 nil 收在 Store;成功后就地更新条目,
  /// 不整表 reload(与 `speakerNames` 同理:填个标签不该赔上页签与滚动位置)。
  /// 空值提交即清除标签。public:探针驱动断言写盘与就地更新。
  public func updateTag(
    _ kind: MeetingTagKind,
    to value: String,
    of item: MeetingLibraryItem
  ) {
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else { return }
    do {
      let metadata: MeetingMetadata
      switch kind {
      case .client:
        metadata = try meetingStore.updateTags(client: value, at: item.paths)
      case .project:
        metadata = try meetingStore.updateTags(project: value, at: item.paths)
      }
      meetings[index].client = metadata.client
      meetings[index].project = metadata.project
      tagError = nil
    } catch {
      tagError = "标签没能保存：\(error.localizedDescription)"
    }
  }

  func syncActiveMeetingTitle(_ title: String?) {
    guard
      let title,
      let directory = recordingSession?.currentMeetingDirectory?.standardizedFileURL,
      let index = meetings.firstIndex(where: {
        $0.paths.directory.standardizedFileURL == directory
      })
    else {
      return
    }
    meetings[index].title = title
  }

  func canExport(_ item: MeetingLibraryItem) -> Bool {
    guard !isExporting else { return false }
    guard item.hasAuthoritativeTranscript, item.hasChineseMinutes else { return false }
    guard let artifacts = artifactCache[item.id] else {
      scheduleArtifactLoad(for: item)
      return false
    }
    return MeetingArtifactProjection.onePager(from: artifacts) != nil
  }

  func exportDisabledReason(for item: MeetingLibraryItem) -> String? {
    if isExporting {
      return exportProgressText ?? "正在导出"
    }
    var missing: [String] = []
    if !item.hasAuthoritativeTranscript {
      missing.append("完整转写")
    }
    if !item.hasChineseMinutes {
      missing.append("中文版纪要")
    }
    if !missing.isEmpty {
      return "暂不能导出，还缺：\(missing.joined(separator: "、"))"
    }
    guard let artifacts = artifactCache[item.id] else {
      scheduleArtifactLoad(for: item)
      return "正在读取会议内容…"
    }
    if MeetingArtifactProjection.onePager(from: artifacts) == nil {
      return "暂不能导出，还缺：一页纸"
    }
    return nil
  }

  public func exportMeetingPackage(
    for item: MeetingLibraryItem,
    to destinationDirectory: URL
  ) {
    copyNoticeTask?.cancel()
    exportGeneration &+= 1
    let generation = exportGeneration
    exportTask?.cancel()
    isExporting = true
    exportProgressText = "正在导出会议包…"
    exportNotice = nil
    exportError = nil

    let request = MeetingPackageExportRequest(
      title: item.title,
      startedAt: item.startedAt,
      endedAt: item.endedAt,
      names: item.speakerNames,
      overrides: item.speakerOverrides,
      transcriptionStatus: transcriptionStatusLabel(for: item),
      paths: item.paths,
      destinationDirectory: destinationDirectory
    )
    exportTask = Task { [weak self] in
      do {
        guard let service = self?.exportService else { return }
        let directory = try await service.exportPackage(request)
        guard
          !Task.isCancelled,
          let self,
          self.exportGeneration == generation
        else { return }
        self.recentExportDestinations = self.destinationHistory.record(destinationDirectory)
        self.exportNotice = "已导出到 \(directory.lastPathComponent)"
        self.exportError = nil
        self.finishExport(generation: generation)
      } catch is CancellationError {
        guard let self, self.exportGeneration == generation else { return }
        self.finishExport(generation: generation)
      } catch {
        guard let self, self.exportGeneration == generation else { return }
        self.exportNotice = nil
        self.exportError = "导出失败：\(error.localizedDescription)"
        self.finishExport(generation: generation)
      }
    }
  }

  public func exportMeetingDiagnostics(
    for item: MeetingLibraryItem,
    to destinationDirectory: URL
  ) {
    copyNoticeTask?.cancel()
    exportGeneration &+= 1
    let generation = exportGeneration
    exportTask?.cancel()
    isExporting = true
    exportProgressText = "正在导出本场诊断包…"
    exportNotice = nil
    exportError = nil
    let paths = item.paths

    exportTask = Task { [weak self] in
      do {
        guard let service = self?.exportService else { return }
        let archive = try await service.exportDiagnostics(
          paths: paths,
          to: destinationDirectory
        )
        guard
          !Task.isCancelled,
          let self,
          self.exportGeneration == generation
        else { return }
        self.recentDiagnosticsDestinations =
          self.diagnosticsDestinationHistory.record(destinationDirectory)
        self.exportNotice = "已导出本场诊断包到 " + archive.lastPathComponent
        self.exportError = nil
        self.finishExport(generation: generation)
      } catch is CancellationError {
        guard let self, self.exportGeneration == generation else { return }
        self.finishExport(generation: generation)
      } catch {
        guard let self, self.exportGeneration == generation else { return }
        self.exportNotice = nil
        self.exportError = "本场诊断包导出失败：" + error.localizedDescription
        self.finishExport(generation: generation)
      }
    }
  }

  public func cancelExport() {
    exportGeneration &+= 1
    exportTask?.cancel()
    exportTask = nil
    isExporting = false
    exportProgressText = nil
  }

  public func waitForExport() async {
    let task = exportTask
    await task?.value
  }

  private func finishExport(generation: UInt) {
    guard exportGeneration == generation else { return }
    exportTask = nil
    isExporting = false
    exportProgressText = nil
  }

  /// 点说话人名字:同一个人再点一次就取消筛选。
  /// 与高亮互斥:进「只看」时把高亮清掉(语义统一——正文里点名字也是这条路径,
  /// 高亮随之退出是设计,不是副作用)。
  public func toggleSpeakerFilter(_ speaker: String) {
    let next = speakerFilter == speaker ? nil : speaker
    speakerFilter = next
    if next != nil {
      speakerHighlight = nil
      speakerHighlightIndex = 0
    }
  }
}
