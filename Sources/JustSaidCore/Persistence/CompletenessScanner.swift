import Foundation
import os

public enum CompletenessVerdict: String, Codable, Sendable, Hashable {
  case green
  case red
  case undetermined
}

public struct CompletenessGap: Codable, Equatable, Sendable {
  public var startSeconds: Int
  public var endSeconds: Int
  public var durationSeconds: Int
  public var rangeLabel: String
  public var kind: String
  public var detail: String
}

/// 双轨母带各自的 afinfo 时长(取整秒),互补轨提示的数据源(08-21 ack 单):
/// 单轨死亡的场次,UI 用另一轨覆盖秒数帮用户判断实际损失,不在 UI 层再跑 afinfo。
/// nil = 该轨缺失或不可读。
public struct CompletenessTrackCoverage: Codable, Equatable, Sendable {
  public var micSeconds: Int?
  public var systemSeconds: Int?

  public init(micSeconds: Int?, systemSeconds: Int?) {
    self.micSeconds = micSeconds
    self.systemSeconds = systemSeconds
  }
}

public struct CompletenessReport: Codable, Equatable, Sendable {
  public var verdict: CompletenessVerdict
  public var redReasons: [String]
  public var gaps: [CompletenessGap]
  public var blocking: [String]
  public var scannedAt: Date
  /// 双轨时长(v3 增补)。旧快照无此字段按 nil 解码,UI 隐藏互补轨行。
  public var trackCoverage: CompletenessTrackCoverage?
  /// 判定逻辑版本(见 `CompletenessScanner.version`)。旧快照无此字段,按 1 解码;
  /// `CompletenessBackfill.reconcile` 见版本落后即按新口径重新裁决。
  public var scannerVersion: Int

  public init(
    verdict: CompletenessVerdict,
    redReasons: [String],
    gaps: [CompletenessGap],
    blocking: [String],
    scannedAt: Date,
    trackCoverage: CompletenessTrackCoverage? = nil,
    scannerVersion: Int = CompletenessScanner.version
  ) {
    self.verdict = verdict
    self.redReasons = redReasons
    self.gaps = gaps
    self.blocking = blocking
    self.scannedAt = scannedAt
    self.trackCoverage = trackCoverage
    self.scannerVersion = scannerVersion
  }

  /// 兼容旧快照:缺 `scannerVersion` 视为版本 1;缺 `trackCoverage` 视为 nil,
  /// 都不解码失败。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    verdict = try container.decode(CompletenessVerdict.self, forKey: .verdict)
    redReasons = try container.decode([String].self, forKey: .redReasons)
    gaps = try container.decode([CompletenessGap].self, forKey: .gaps)
    blocking = try container.decode([String].self, forKey: .blocking)
    scannedAt = try container.decode(Date.self, forKey: .scannedAt)
    trackCoverage = try container.decodeIfPresent(
      CompletenessTrackCoverage.self, forKey: .trackCoverage)
    scannerVersion = try container.decodeIfPresent(Int.self, forKey: .scannerVersion) ?? 1
  }

  /// 报告**已判**有效母带覆盖短欠时的实际覆盖秒数(= `trackCoverage` 两轨的较大者)。
  /// nil = 报告没判短欠,或旧快照没有 `trackCoverage` —— 两种情况都照旧按会话跨度报时长。
  ///
  /// 判定**不在这里重算**:scanner 拿未取整的音频秒数比阈值,写进 `trackCoverage` 的却是
  /// 四舍五入后的整数,重算会在阈值附近与报告给出相反结论(见
  /// `CompletenessScanner.coverageShortfallReasonPrefix`)。所以只认报告自己记下的红因。
  /// 会议库时长标签(#50)与导出会议包的文件头共用这一处判定,两条路径不会各说各话:
  /// 这个口径出现时,完整性卡片里必然有对应的缺口说明。
  public var shortCoveredSeconds: Int? {
    guard
      redReasons.contains(where: {
        $0.hasPrefix(CompletenessScanner.coverageShortfallReasonPrefix)
      }),
      let trackCoverage
    else {
      return nil
    }
    return [trackCoverage.micSeconds, trackCoverage.systemSeconds].compactMap { $0 }.max()
  }

  public static func load(from paths: MeetingPaths) -> CompletenessReport? {
    guard let data = try? Data(contentsOf: paths.completeness) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(CompletenessReport.self, from: data)
  }
}

/// 口径对齐 `Scripts/acceptance-completeness.py`(late 60s / gap 300s + live 旁证)。
public struct CompletenessScanner: Sendable {
  /// 判定逻辑版本:改判定口径必须 +1,reconcile 才会对旧快照重新裁决。
  /// v1(08-19 首版);v2(08-21):①洞内 live 旁证只算「洞中段」(t0 ≥ 洞起点+60s),
  /// 洞口边界句不再被当成洞内有声的证据(08-03 实证:543s 洞仅洞口 3 段被误判中断);
  /// ②notes.md 用户会中记录命中缺口 → `user_annotated` 不判红(08-14 实证:
  /// 用户标注"接电话不要放进来"、精转按指示排除,却被判丢段)。
  /// v3(08-21 ack 单):判定口径不变;report 增补 `trackCoverage` 双轨时长
  /// (互补轨提示的数据源)。借版本门让存量 green/red 快照重扫一次补齐字段,
  /// 否则 red 终态永不重扫,单轨死亡的存量场次(本字段的目标用户)永远看不到它。
  /// v4(08-26):判定口径不变;将用户可见的 startedAt→endedAt 术语统一为本次录音时长,
  /// 让旧快照通过 reconcile 重写文案。
  public static let version = 4
  public static let lateThreshold: TimeInterval = 60
  public static let gapThreshold: TimeInterval = 300
  /// 「有效母带覆盖短欠」红因的固定前缀。会议库的时长标签靠它**复用本判定**,
  /// 而不是拿报告里的 `trackCoverage` 重算一遍阈值:判定用的是未取整的音频秒数,
  /// 落进 `trackCoverage` 的却是四舍五入后的整数,两者在阈值附近会给出相反结论
  /// (跨度 1800s、两轨 1739.8s:判定短欠 60.2s > 60s 成立,重算得 1800-1740=60
  /// 不成立)。文案不变,仅把前缀提成常量供两处共用。
  public static let coverageShortfallReasonPrefix = "有效母带覆盖短欠"

  public init() {}

  @discardableResult
  public func scan(paths: MeetingPaths, now: Date = Date()) -> CompletenessReport {
    let report = evaluate(paths: paths, now: now)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(report) {
      try? data.write(to: paths.completeness, options: .atomic)
    }
    return report
  }

  public func evaluate(paths: MeetingPaths, now: Date = Date()) -> CompletenessReport {
    var blocking: [String] = []
    var redReasons: [String] = []
    var gaps: [CompletenessGap] = []

    guard
      let metadata = try? MeetingStore(rootDirectory: paths.directory).read(from: paths)
    else {
      return CompletenessReport(
        verdict: .undetermined,
        redReasons: [],
        gaps: [],
        blocking: ["缺 meeting.json 或无法解析"],
        scannedAt: now
      )
    }

    if metadata.status == .recording {
      return CompletenessReport(
        verdict: .undetermined,
        redReasons: [],
        gaps: [],
        blocking: ["会议仍在录制中,完整性检测只对已结束会议有效"],
        scannedAt: now
      )
    }

    var recordingDuration: TimeInterval?
    if let endedAt = metadata.endedAt, endedAt > metadata.startedAt {
      recordingDuration = endedAt.timeIntervalSince(metadata.startedAt)
    } else {
      blocking.append("meeting.json 起止时间不可用,本次录音时长对比未执行")
    }

    let mic = audioDuration(at: paths.microphoneAudio)
    let system = audioDuration(at: paths.systemAudio)
    let okDurations = [mic, system].compactMap { pair -> TimeInterval? in
      pair.state == .ok ? pair.seconds : nil
    }
    guard let effective = okDurations.max() else {
      return CompletenessReport(
        verdict: .undetermined,
        redReasons: [],
        gaps: [],
        blocking: ["缺母带: mic.m4a 与 system.m4a 均缺失或不可读,无法检测"],
        scannedAt: now
      )
    }
    // 双轨时长(v3):afinfo 已经跑过,顺手落进 report 供互补轨提示直读。
    let trackCoverage = CompletenessTrackCoverage(
      micSeconds: mic.state == .ok ? mic.seconds.map { Int($0.rounded()) } : nil,
      systemSeconds: system.state == .ok ? system.seconds.map { Int($0.rounded()) } : nil
    )

    if let recordingDuration {
      func consider(name: String, sample: AudioSample) {
        if sample.state == .ok, let seconds = sample.seconds {
          let shortfall = recordingDuration - seconds
          if shortfall > Self.lateThreshold {
            let trackSeconds = Int(seconds.rounded())
            let expectedSeconds = Int(recordingDuration.rounded())
            let detail =
              "\(name).m4a 录到 \(trackSeconds)s，本次录音共 \(expectedSeconds)s，短欠 \(Int(shortfall.rounded()))s(可能晚开/早停缺段,起止侧需人工听音定位)"
            redReasons.append(detail)
            gaps.append(
              CompletenessGap(
                startSeconds: 0,
                endSeconds: Int(shortfall.rounded()),
                durationSeconds: Int(shortfall.rounded()),
                rangeLabel: "\(name) 短欠",
                kind: "late",
                detail: detail
              )
            )
          }
        } else {
          let label = sample.state == .missing ? "缺失" : "不可读(0字节或损坏)"
          let detail = "\(name).m4a \(label)——该轨覆盖整场丢失"
          redReasons.append(detail)
          gaps.append(
            CompletenessGap(
              startSeconds: 0,
              endSeconds: Int(recordingDuration.rounded()),
              durationSeconds: Int(recordingDuration.rounded()),
              rangeLabel: "\(name) \(label)",
              kind: "track_fail",
              detail: detail
            )
          )
        }
      }
      consider(name: "mic", sample: mic)
      consider(name: "system", sample: system)
      if (recordingDuration - effective) > Self.lateThreshold {
        redReasons.insert(
          "\(Self.coverageShortfallReasonPrefix) "
            + "\(Int((recordingDuration - effective).rounded()))s > 阈值 \(Int(Self.lateThreshold))s",
          at: 0
        )
      }
    }

    let timestamps = transcriptTimestamps(at: paths.transcript)
    let live = liveSegments(at: paths.liveTranscript)
    let notes = noteEntries(at: paths.notes)
    // issue #27:这两行是直接给用户看的(会议库详情「完整性 · 未知」卡里逐行渲染),
    // 所以不留文件名与内部术语——说清「为什么查不了」和「什么时候会自己查」。
    if timestamps == nil {
      blocking.append("完整转写还没产出(精转未完成或失败),无法检查录音有没有缺口;精转成功后会自动重查")
    } else if let timestamps, timestamps.count < 2 {
      blocking.append("完整转写不足 2 行,不够用来检查录音有没有缺口;重新精转后会自动重查")
    } else if let timestamps {
      for (a, b) in zip(timestamps, timestamps.dropFirst()) {
        let gap = b - a
        if Double(gap) > Self.gapThreshold {
          // notes 旁证优先:缺口(±60s)内有用户会中手动记录 → 用户知情/授意的缺口
          // (如"接了个电话,不要放进来"),不判红;留在 gaps 里供 UI 展示。
          let annotations = notes.filter { note in
            note.seconds >= Double(a) - Self.lateThreshold
              && note.seconds <= Double(b) + Self.lateThreshold
          }
          if !annotations.isEmpty {
            let joined = annotations.map(\.text).joined(separator: "；")
            gaps.append(
              CompletenessGap(
                startSeconds: a,
                endSeconds: b,
                durationSeconds: gap,
                rangeLabel: "\(hms(a)) → \(hms(b))",
                kind: "user_annotated",
                detail: "\(hms(a)) → \(hms(b)) \(gap)s(缺口内有用户标注,视为知情):\(joined)"
              )
            )
            continue
          }
          // live 旁证只算「洞中段」(t0 ≥ 洞起点+60s,60 与 lateThreshold 同源):
          // 洞口边界句本身就是造成洞的那句话,不是洞内有声的证据。
          let inside = countLive(
            live,
            start: TimeInterval(a) + Self.lateThreshold,
            end: TimeInterval(b)
          )
          let verdict: String
          let kind: String
          if inside == nil {
            verdict = "无 live 旁证 → 需人工抽听确认"
            kind = "uncorroborated"
            redReasons.append(
              "转写空洞 \(hms(a)) → \(hms(b)) \(gap)s,无 live 旁证 → 需人工抽听确认"
            )
          } else if (inside ?? 0) > 0 {
            verdict = "疑似中断丢段"
            kind = "interruption"
            redReasons.append(
              "转写空洞 \(hms(a)) → \(hms(b)) \(gap)s,同期 live 有 \(inside ?? 0) 段 → 疑似中断丢段"
            )
          } else {
            verdict = "疑似自然静默"
            kind = "silence"
          }
          if kind != "silence" {
            gaps.append(
              CompletenessGap(
                startSeconds: a,
                endSeconds: b,
                durationSeconds: gap,
                rangeLabel: "\(hms(a)) → \(hms(b))",
                kind: kind,
                detail: "\(hms(a)) → \(hms(b)) \(gap)s(\(verdict))"
              )
            )
          }
        }
      }
      if let last = timestamps.last {
        let tailShort = effective - TimeInterval(last)
        let liveAfter = countLive(
          live,
          start: TimeInterval(last) + 5,
          end: effective + 1
        )
        if tailShort > Self.lateThreshold, (liveAfter ?? 0) > 0 {
          let detail =
            "转写止于 \(hms(last)),距母带末尾 \(Int(tailShort.rounded()))s,且 live 在后面还有 \(liveAfter ?? 0) 段 → 结尾丢段"
          redReasons.append(detail)
          gaps.append(
            CompletenessGap(
              startSeconds: last,
              endSeconds: Int(effective.rounded()),
              durationSeconds: Int(tailShort.rounded()),
              rangeLabel: "\(hms(last)) → 母带末尾",
              kind: "tail",
              detail: detail
            )
          )
        }
      }
    }

    let verdict: CompletenessVerdict
    if !redReasons.isEmpty {
      verdict = .red
    } else if !blocking.isEmpty {
      verdict = .undetermined
    } else {
      verdict = .green
    }
    return CompletenessReport(
      verdict: verdict,
      redReasons: redReasons,
      gaps: gaps,
      blocking: blocking,
      scannedAt: now,
      trackCoverage: trackCoverage
    )
  }

  private struct AudioSample {
    var seconds: TimeInterval?
    var state: AudioState
  }

  private enum AudioState {
    case ok
    case missing
    case unreadable
  }

  private func audioDuration(at url: URL) -> AudioSample {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
      return AudioSample(seconds: nil, state: .missing)
    }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if size == 0 { return AudioSample(seconds: nil, state: .unreadable) }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    process.arguments = [url.path]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return AudioSample(seconds: nil, state: .unreadable)
    }
    guard process.terminationStatus == 0 else {
      return AudioSample(seconds: nil, state: .unreadable)
    }
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard
      let match = text.range(
        of: #"estimated duration:\s*([\d.]+)\s*sec"#,
        options: .regularExpression
      )
    else {
      return AudioSample(seconds: nil, state: .unreadable)
    }
    let snippet = String(text[match])
    let number = snippet.split(whereSeparator: { !$0.isNumber && $0 != "." }).first
      .flatMap { TimeInterval($0) }
    guard let number else { return AudioSample(seconds: nil, state: .unreadable) }
    return AudioSample(seconds: number, state: .ok)
  }

  private func transcriptTimestamps(at url: URL) -> [Int]? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var values = Set<Int>()
    let regex = try? NSRegularExpression(
      pattern: #"^\[(\d+):(\d+):(\d+)\]"#, options: .anchorsMatchLines)
    let full = NSRange(text.startIndex..., in: text)
    regex?.enumerateMatches(in: text, range: full) { match, _, _ in
      guard let match, match.numberOfRanges == 4,
        let h = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
        let m = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
        let s = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) })
      else { return }
      values.insert(h * 3600 + m * 60 + s)
    }
    return values.sorted()
  }

  private func liveSegments(at url: URL) -> [(TimeInterval, TimeInterval)]? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var segs: [(TimeInterval, TimeInterval)] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty,
        let data = trimmed.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let t0 = jsonNumber(object["t0"]),
        let t1 = jsonNumber(object["t1"])
      else { continue }
      segs.append((t0, t1))
    }
    return segs
  }

  /// notes.md 的 `- [HH:MM:SS] 文本` 行(`NotesWriter` 落盘格式)。
  /// 文件缺失/空返回空数组;text 为「[HH:MM:SS] 原文」形态,供 detail 直接引用。
  private func noteEntries(at url: URL) -> [(seconds: Double, text: String)] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var entries: [(seconds: Double, text: String)] = []
    let regex = try? NSRegularExpression(
      pattern: #"^- \[(\d+):(\d+):(\d+)\]\s*(.*)$"#, options: .anchorsMatchLines)
    let full = NSRange(text.startIndex..., in: text)
    regex?.enumerateMatches(in: text, range: full) { match, _, _ in
      guard let match, match.numberOfRanges == 5,
        let h = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
        let m = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
        let s = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) }),
        let body = Range(match.range(at: 4), in: text).map({ String(text[$0]) })
      else { return }
      let total = h * 3600 + m * 60 + s
      entries.append((Double(total), "\(hms(total)) \(body)"))
    }
    return entries
  }

  private func countLive(
    _ segs: [(TimeInterval, TimeInterval)]?,
    start: TimeInterval,
    end: TimeInterval
  ) -> Int? {
    guard let segs else { return nil }
    return segs.filter { t0, t1 in t0 >= start && t1 <= end }.count
  }

  private func jsonNumber(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? Int { return Double(number) }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
  }

  private func hms(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "[%02d:%02d:%02d]", s / 3600, (s % 3600) / 60, s % 60)
  }
}

public enum CompletenessBackfill {
  private static let logger = Logger(subsystem: "com.justsaid.app", category: "Completeness")

  /// 启动对账。`undetermined` 是「输入未齐,结论待定」的临时态,不是终态:
  /// 同版本快照的 green/red 一个字节不动;undetermined 只在出现晚于快照的新输入时重扫
  /// (纯 stat 判定,不触发 afinfo——真缺转写的场次没有新输入,永不重算,仍如实报缺)。
  /// 版本例外(08-21 v2,对「green/red 不动」原则的显式修订):`scannerVersion` 落后于
  /// `CompletenessScanner.version` 的快照,green/red 也重扫——原则防的是结论随输入
  /// mtime 抖动来回翻;判定口径本身升级属于裁决依据变了,旧结论必须按新口径重算一次,
  /// 算完落新版本号即恢复终态。
  public static func reconcile(in store: MeetingStore) {
    let scanner = CompletenessScanner()
    let fileManager = FileManager.default
    for record in store.listMeetings() {
      let paths = record.paths
      guard fileManager.fileExists(atPath: paths.completeness.path) else {
        _ = scanner.scan(paths: paths)
        continue
      }
      guard let report = CompletenessReport.load(from: paths) else {
        logger.info(
          "完整性重扫 \(paths.directory.lastPathComponent, privacy: .public):快照无法解析"
        )
        _ = scanner.scan(paths: paths)
        continue
      }
      if report.scannerVersion < CompletenessScanner.version {
        logger.info(
          "完整性重扫 \(paths.directory.lastPathComponent, privacy: .public):快照版本 \(report.scannerVersion) < \(CompletenessScanner.version),按新口径重新裁决"
        )
        _ = scanner.scan(paths: paths)
        continue
      }
      guard report.verdict == .undetermined else { continue }
      let inputs = [
        paths.metadata, paths.transcript, paths.microphoneAudio,
        paths.systemAudio, paths.liveTranscript,
      ]
      let hasNewerInput = inputs.contains { url in
        guard
          let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        else { return false }
        return mtime > report.scannedAt
      }
      guard hasNewerInput else { continue }
      logger.info(
        "完整性重扫 \(paths.directory.lastPathComponent, privacy: .public):undetermined 快照之后有新输入"
      )
      _ = scanner.scan(paths: paths)
    }
  }
}
