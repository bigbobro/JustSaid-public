import Foundation

/// 「通话中」检测与提醒候选的纯逻辑：输入是带时间的进程快照，没有时钟、线程、系统调用。
///
/// 判定（design「检测」）：
/// - 通话中 = 同一 App 家族的输入与输出连续同开满 `startHold`；只有输入不算（语音消息、听写、命令行录音）。
/// - 结束 = 输入输出都停（或家族从快照里消失）满 `endHold`。家族消失按「两路都停」处理，
///   与 helper 进程反复起落、pid 重启保持一致：瞬断不算结束。
/// - 静音时输入可能松开，但输出仍在，所以不结束。
public struct MeetingCallDetector {
  public struct Thresholds: Equatable, Sendable {
    public var startHold: TimeInterval
    public var endHold: TimeInterval
    public init(startHold: TimeInterval = 5, endHold: TimeInterval = 3) {
      self.startHold = startHold
      self.endHold = endHold
    }
  }

  private enum Phase {
    case idle
    case arming(since: Date)
    case inCall(startedAt: Date, stoppedSince: Date?)
  }

  private struct Family {
    var identity: AppIdentity
    var excluded: Bool
    var input = false
    var output = false
    /// 自上次两路都空闲以来是否出现过输入；输出起停只在这之后写诊断。
    var sawInput = false
    var phase = Phase.idle
    var ignored = false
  }

  public var thresholds: Thresholds
  /// 用户点过「不再提醒」的 App 家族 key（`AppIdentity.key`），不按 bundle ID：找不到宿主的 WebKit helper
  /// 各自成家、bundle ID 相同，按 bundle 存会一次排掉所有这类 App（#157 复审 N12）。
  public var userExcludedAppKeys: Set<String> = []

  private let resolver: MeetingAppIdentityResolver
  private var families: [String: Family] = [:]
  private var isRecording = false
  /// 正在记录时被跟踪的 App（结束提醒只发给它）。
  public private(set) var trackedAppKey: String?

  public init(resolver: MeetingAppIdentityResolver, thresholds: Thresholds = .init()) {
    self.resolver = resolver
    self.thresholds = thresholds
  }

  // MARK: 输出（level）

  /// 可以弹「开始记录」提醒的通话，按开始时间先到先显示。正在记录时为空。
  public var promptCandidates: [MeetingCallInfo] {
    guard !isRecording else { return [] }
    return inCallInfos(includeIgnored: false)
  }

  private func inCallInfos(includeIgnored: Bool) -> [MeetingCallInfo] {
    families.values
      .compactMap { family -> MeetingCallInfo? in
        guard !family.excluded, case .inCall(let startedAt, _) = family.phase else { return nil }
        if family.ignored && !includeIgnored { return nil }
        return MeetingCallInfo(app: family.identity, startedAt: startedAt)
      }
      .sorted { ($0.startedAt, $0.app.key) < ($1.startedAt, $1.app.key) }
  }

  // MARK: 输入（用户动作与录制状态）

  /// 忽略这次通话的开始提醒；通话结束后再进入通话才重新提醒。
  public mutating func ignore(appKey: String) {
    families[appKey]?.ignored = true
  }

  /// 记录开始。`tracking` 是由提醒启动时被确认的 App；手动开始时为 nil，
  /// 领养此刻已在通话中最早开始的 App（用户错过或忽略了提醒再手动开始的常见流程），
  /// 没有则等录制期间第一个进入通话的 App。
  public mutating func recordingDidStart(tracking: String? = nil) {
    // 多个 App 在通话时领养界面上显示的那个（最早的未忽略通话）；只有被忽略的才退回它。
    let adopted =
      inCallInfos(includeIgnored: false).first ?? inCallInfos(includeIgnored: true).first
    isRecording = true
    trackedAppKey = tracking ?? adopted?.app.key
  }

  /// 丢掉对进程的观察（正在进行的通话、计时），保留录制状态、被跟踪的 App 与用户排除清单。
  public mutating func resetObservations() {
    families = [:]
    resolver.prune(keeping: [])
  }

  public mutating func recordingDidStop() {
    isRecording = false
    trackedAppKey = nil
  }

  // MARK: 快照

  public mutating func ingest(_ samples: [AudioProcessSample], at now: Date)
    -> [MeetingDetectionEvent]
  {
    var events: [MeetingDetectionEvent] = []
    var seen: [String: (identity: AppIdentity, input: Bool, output: Bool)] = [:]
    var pids: Set<Int32> = []

    for sample in samples where sample.isRunningInput || sample.isRunningOutput {
      pids.insert(sample.pid)
      guard case .app(let identity) = resolver.resolve(sample) else { continue }
      var entry = seen[identity.key] ?? (identity, false, false)
      entry.input = entry.input || sample.isRunningInput
      entry.output = entry.output || sample.isRunningOutput
      seen[identity.key] = entry
    }
    resolver.prune(keeping: pids)

    for (key, entry) in seen where families[key] == nil {
      families[key] = Family(identity: entry.identity, excluded: false)
    }
    for key in families.keys.sorted() {
      var family = families[key]!
      let input = seen[key]?.input ?? false
      let output = seen[key]?.output ?? false
      // 排除状态每拍重算：用户在通话中途点「不再提醒」时，静默丢弃该家族的通话状态。
      family.excluded = isListed(family.identity)
      if family.excluded {
        family.phase = .idle
        family.ignored = false
      }

      Self.emitActivity(&family, input: input, output: output, at: now, into: &events)
      if !family.excluded {
        step(&family, input: input, output: output, at: now, into: &events)
      }
      family.input = input
      family.output = output
      if !input && !output {
        family.sawInput = false
        if case .idle = family.phase {
          families[key] = nil
          continue
        }
      }
      families[key] = family
    }
    return events
  }

  private func isListed(_ identity: AppIdentity) -> Bool {
    if userExcludedAppKeys.contains(identity.key) { return true }
    guard let bundleID = identity.bundleID, !bundleID.isEmpty else { return false }
    return MeetingDetectionExclusions.builtInBundleIDs.contains(bundleID)
  }

  private static func emitActivity(
    _ family: inout Family, input: Bool, output: Bool, at now: Date,
    into events: inout [MeetingDetectionEvent]
  ) {
    func activity(_ kind: AudioActivityKind, _ active: Bool) -> MeetingDetectionEvent {
      .activity(
        AudioActivity(
          app: family.identity, kind: kind, isActive: active, at: now, isExcluded: family.excluded))
    }
    let inputEdge = input != family.input
    let outputEdge = output != family.output
    if inputEdge {
      if input { family.sawInput = true }
      events.append(activity(.input, input))
    }
    // 输出起停只在该家族出现过输入后才记，否则每次通知音、视频声都会占诊断日额。
    guard family.sawInput else { return }
    if outputEdge {
      events.append(activity(.output, output))
    } else if inputEdge && input && output {
      // 输出在输入之前就开着：输入起时补记一条，日志里才有完整的一对。
      events.append(activity(.output, true))
    }
  }

  private mutating func step(
    _ family: inout Family, input: Bool, output: Bool, at now: Date,
    into events: inout [MeetingDetectionEvent]
  ) {
    switch family.phase {
    case .idle:
      if input && output { family.phase = .arming(since: now) }
    case .arming(let since):
      guard input && output else {
        family.phase = .idle
        return
      }
      if now.timeIntervalSince(since) >= thresholds.startHold {
        family.phase = .inCall(startedAt: since, stoppedSince: nil)
        events.append(.callStarted(MeetingCallInfo(app: family.identity, startedAt: since)))
        if isRecording && trackedAppKey == nil { trackedAppKey = family.identity.key }
      }
    case .inCall(let startedAt, let stoppedSince):
      if input || output {
        family.phase = .inCall(startedAt: startedAt, stoppedSince: nil)
        return
      }
      let stopped = stoppedSince ?? now
      if now.timeIntervalSince(stopped) >= thresholds.endHold {
        let info = MeetingCallInfo(app: family.identity, startedAt: startedAt)
        events.append(.callEnded(info, endedAt: stopped))
        if isRecording && trackedAppKey == family.identity.key {
          events.append(.stopPromptDue(info, endedAt: stopped))
        }
        family.phase = .idle
      } else {
        family.phase = .inCall(startedAt: startedAt, stoppedSince: stopped)
      }
    }
  }
}
