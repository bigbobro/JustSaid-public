import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-21 批0 拆分:自 MainWorkspaceView.swift 按 MARK 边界机械迁出,零行为变更.
extension MainWorkspaceView {

  // MARK: - 排除时间段(08-14)

  func currentMeetingPaths() -> MeetingPaths? {
    recordingSession.currentMeetingDirectory.map { MeetingPaths(directory: $0) }
  }

  /// 当前会议时刻(会议时间轴秒)。以 `RecordingSession.startedAt` 为权威起点,
  /// 与转写 `[HH:MM:SS]` 同轴;计时器同一基准。
  private func meetingElapsed() -> TimeInterval? {
    recordingSession.startedAt.map { Date().timeIntervalSince($0) }
  }

  /// 「闲聊中」= 当前会议存在任何 end==nil 的区间(不限 origin)。
  var openChatRange: ExcludedRange? {
    ExclusionUI.openRange(in: exclusionRanges)
  }

  /// 每次写入后与换场时重读。实时过滤由 `LiveSummaryFeed.ingest` 每轮自己读盘,
  /// 这里的 @State 只服务呈现(灰显/细带/开关态),不需要更快。
  func reloadExclusionState() {
    guard
      let paths = currentMeetingPaths(),
      let metadata = try? appCoordinator.meetingStore.read(from: paths)
    else {
      exclusionRanges = []
      return
    }
    exclusionRanges = metadata.excludedRanges ?? []
  }

  func requestEndMeeting() {
    if openChatRange != nil {
      isConfirmingChatClose = true
    } else {
      endMeeting()
    }
  }

  func toggleChatExclusion() {
    if openChatRange != nil {
      closeChatExclusion()
    } else {
      guard let elapsed = meetingElapsed() else { return }
      addChatExclusion(start: elapsed, origin: ExclusionUI.Origin.liveToggle)
    }
  }

  /// 追溯标记(liveRetro):起点取该段 t0,不封口——由「闲聊中」开关/细带一键封。
  func markChatExcluded(from start: TimeInterval) {
    addChatExclusion(start: start, origin: ExclusionUI.Origin.liveRetro)
  }

  private func addChatExclusion(start: TimeInterval, origin: String) {
    guard let paths = currentMeetingPaths() else { return }
    do {
      _ = try appCoordinator.meetingStore.addExcludedRange(
        start: start,
        end: nil,
        origin: origin,
        at: paths
      )
      exclusionError = nil
    } catch {
      exclusionError = "排除标记没能存进 meeting.json:\(error.localizedDescription)"
    }
    reloadExclusionState()
  }

  func closeChatExclusion() {
    guard
      let range = openChatRange,
      let paths = currentMeetingPaths(),
      let elapsed = meetingElapsed()
    else { return }
    do {
      _ = try appCoordinator.meetingStore.closeExcludedRange(
        id: range.id,
        end: elapsed,
        at: paths
      )
      exclusionError = nil
    } catch {
      exclusionError = "闲聊封口没能存进 meeting.json:\(error.localizedDescription)"
    }
    reloadExclusionState()
  }

  func removeExclusion(id: UUID) {
    guard let paths = currentMeetingPaths() else { return }
    do {
      _ = try appCoordinator.meetingStore.removeExcludedRange(id: id, at: paths)
      exclusionError = nil
    } catch {
      exclusionError = "撤销排除没能存进 meeting.json:\(error.localizedDescription)"
    }
    reloadExclusionState()
  }

  /// bullet 右键排除(bulletMark):锚点落进哪段实时转写就排哪段([t0, t1]);
  /// 段还没出来时兜底 [anchor, anchor+30]——宁可窄一点,也不误伤相邻内容。
  func excludeBulletAnchor(_ anchor: TimeInterval) {
    guard let paths = currentMeetingPaths() else { return }
    let segment = displaySegments.filter { $0.t0 <= anchor }.max { $0.t0 < $1.t0 }
    let start = segment?.t0 ?? anchor
    let end = segment.map { max($0.t1, $0.t0) } ?? anchor + 30
    do {
      _ = try appCoordinator.meetingStore.addExcludedRange(
        start: start,
        end: end,
        origin: ExclusionUI.Origin.bulletMark,
        at: paths
      )
      exclusionError = nil
    } catch {
      exclusionError = "这段排除没能存进 meeting.json:\(error.localizedDescription)"
    }
    reloadExclusionState()
  }

  /// 话题块整体排除(bulletMark):范围已由 `ExclusionUI.topicRangeSeconds` 解析好。
  func excludeTopicRange(_ range: ClosedRange<TimeInterval>) {
    guard let paths = currentMeetingPaths() else { return }
    do {
      _ = try appCoordinator.meetingStore.addExcludedRange(
        start: range.lowerBound,
        end: range.upperBound,
        origin: ExclusionUI.Origin.bulletMark,
        at: paths
      )
      exclusionError = nil
    } catch {
      exclusionError = "这个话题的排除没能存进 meeting.json:\(error.localizedDescription)"
    }
    reloadExclusionState()
  }
}
