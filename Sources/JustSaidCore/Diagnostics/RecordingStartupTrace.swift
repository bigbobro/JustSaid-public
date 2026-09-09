import Foundation
import os

/// 一次录音启动的分阶段轨迹(08-20 失败可自证单,design §1)。
///
/// 内存累积各 stage 完成时刻;三种形态会落盘到
/// `diagnosticsRoot/start-failures-YYYYMMDD.log`(诊断包整目录收集,证据自动进包):
/// - **failure**:启动抛错/超时——catch 里第一件事就是这次同步写盘,
///   所有 `await` 与 HAL 调用必须排在其后(若根因正是 HAL 楔住,
///   排后面的清理可能自己挂死;诊断不能死在它要诊断的那个故障上);
/// - **stuck**:启动看门狗超阈值先行 flush(裸 await 卡死不抛异常、
///   HangSentinel 也不触发——actor suspension 不是主线程卡死);
/// - **terminal**:stuck 之后到达的终态(成功/失败)追加终态行,慢成功即由此留痕。
///
/// 失败 flush 之后**继续接收同一世代的迟到上报**并追加 `late` 行:
/// 「startRunning 在 12.3s 才返回」与「永不返回」是完全不同的诊断结论。
///
/// 脱敏纪律(R6):只写 stage 名、耗时、路由决策、设备摘要、错误描述;
/// **不写**会议正文、说话人姓名、密钥、会议目录路径(目录名含会议标题)。
/// 写盘失败降级为 `logger.error`,绝不遮蔽原始启动错误。
///
/// 增长上限(AC9):按天分文件;每日事故行数带上限;只保留最近 N 天的
/// `start-failures-*.log`(其余 diagnostics 文件不归本类管)。
public final class RecordingStartupTrace: @unchecked Sendable {

  private struct Entry {
    let stage: String
    let elapsed: TimeInterval
    let detail: String?
  }

  private enum State {
    case pending
    case stuckFlushed
    case terminal
  }

  /// 每日事故行上限;迟到行/终态行不受此限但各自天然有界
  /// (终态行每场至多一条;迟到行由 `maximumLateLines` 单独封顶)。
  static let maximumIncidentLinesPerDay = 200
  /// 单场轨迹允许追加的迟到行上限。
  static let maximumLateLines = 8
  /// `start-failures-*.log` 的保留天数。
  static let retentionDays = 14

  private let startedAt: Date
  private let device: AudioInputDeviceSummary
  private let diagnosticsRoot: URL
  private let fileManager = FileManager.default
  private let logger = Logger(
    subsystem: "com.justsaid.app",
    category: "RecordingStartupTrace"
  )

  private let lock = NSLock()
  private var entries: [Entry] = []
  private var pendingStage: String?
  private var state: State = .pending
  private var hasWrittenIncident = false
  private var lateLineCount = 0

  public init(
    startedAt: Date,
    device: AudioInputDeviceSummary,
    diagnosticsRoot: URL
  ) {
    self.startedAt = startedAt
    self.device = device
    self.diagnosticsRoot = diagnosticsRoot
  }

  /// 标记「即将进入某个可能挂起的步骤」。stuck/failure 记录用它指出卡在哪个 await,
  /// 这比只看最后一个完成 stage 更准(裸 await 卡死时完成列表停在上一步)。
  public func begin(stage: String) {
    lock.lock()
    pendingStage = stage
    lock.unlock()
  }

  /// 某 stage 完成。已 flush 之后的完成即「迟到上报」,追加 `late` 行。
  public func complete(stage: String, detail: String? = nil) {
    let elapsed = Date().timeIntervalSince(startedAt)
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .pending:
      entries.append(Entry(stage: stage, elapsed: elapsed, detail: detail))
      if pendingStage == stage {
        pendingStage = nil
      }
    case .stuckFlushed, .terminal:
      guard hasWrittenIncident, lateLineCount < Self.maximumLateLines else { return }
      lateLineCount += 1
      let suffix = detail.map { "(\(Self.sanitize($0)))" } ?? ""
      appendLineLocked(
        "\(Self.isoStamp(Date())) late startedAt=\(Self.isoStamp(startedAt)) "
          + "stage=\(Self.sanitize(stage)) "
          + "elapsed=\(Self.format(elapsed))\(suffix)",
        countsTowardDailyCap: false
      )
    }
  }

  /// 启动失败:同步写盘。重复调用无操作(内外层 catch 都会调,先到先写);
  /// stuck 已先行落盘时改为追加终态失败行。
  public func flushFailure(errorDescription: String) {
    let now = Date()
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .pending:
      state = .terminal
      let line =
        "\(Self.isoStamp(now)) outcome=failure startedAt=\(Self.isoStamp(startedAt)) "
        + "failedStage=\(Self.sanitize(pendingStage ?? "unknown")) "
        + "\(device.logDescription) "
        + "stages=[\(stagesDescriptionLocked())] "
        + "error=\(Self.sanitize(errorDescription))"
      appendLineLocked(line, countsTowardDailyCap: true)
    case .stuckFlushed:
      state = .terminal
      guard hasWrittenIncident else { return }
      appendLineLocked(
        "\(Self.isoStamp(now)) terminal=failure startedAt=\(Self.isoStamp(startedAt)) "
          + "total=\(Self.format(now.timeIntervalSince(startedAt))) "
          + "error=\(Self.sanitize(errorDescription))",
        countsTowardDailyCap: false
      )
    case .terminal:
      break
    }
  }

  /// 看门狗触发:启动超阈值仍未到终态,先行落盘(文件标记 stuck)。
  /// 终态已到则无操作。
  public func flushStuck() {
    let now = Date()
    lock.lock()
    defer { lock.unlock() }
    guard state == .pending else { return }
    state = .stuckFlushed
    let line =
      "\(Self.isoStamp(now)) outcome=stuck startedAt=\(Self.isoStamp(startedAt)) "
      + "pendingStage=\(Self.sanitize(pendingStage ?? "unknown")) "
      + "elapsed=\(Self.format(now.timeIntervalSince(startedAt))) "
      + "\(device.logDescription) "
      + "stages=[\(stagesDescriptionLocked())]"
    appendLineLocked(line, countsTowardDailyCap: true)
  }

  /// 启动成功。快成功(未曾 stuck)不写任何文件;stuck 之后的慢成功追加终态行——
  /// 对「偶发」缺陷,慢成功样本正是最有信息量的对照组(G4)。
  public func markSuccess() {
    let now = Date()
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .pending:
      state = .terminal
    case .stuckFlushed:
      state = .terminal
      guard hasWrittenIncident else { return }
      appendLineLocked(
        "\(Self.isoStamp(now)) terminal=success startedAt=\(Self.isoStamp(startedAt)) "
          + "total=\(Self.format(now.timeIntervalSince(startedAt)))",
        countsTowardDailyCap: false
      )
    case .terminal:
      break
    }
  }

  // MARK: - 落盘(调用方须已持锁)

  private func stagesDescriptionLocked() -> String {
    entries.map { entry in
      let suffix = entry.detail.map { "(\(Self.sanitize($0)))" } ?? ""
      return "\(entry.stage):\(Self.format(entry.elapsed))\(suffix)"
    }.joined(separator: " ")
  }

  private func appendLineLocked(_ line: String, countsTowardDailyCap: Bool) {
    let now = Date()
    do {
      try fileManager.createDirectory(
        at: diagnosticsRoot,
        withIntermediateDirectories: true
      )
      let url = diagnosticsRoot.appendingPathComponent(
        "start-failures-\(Self.dayStamp(now)).log"
      )
      if countsTowardDailyCap, let existing = try? Data(contentsOf: url) {
        let lineCount = existing.reduce(0) { count, byte in
          byte == UInt8(ascii: "\n") ? count + 1 : count
        }
        guard lineCount < Self.maximumIncidentLinesPerDay else {
          logger.error("start-failures 当日事故行已达上限,本条证据仅剩统一日志:\(line, privacy: .public)")
          return
        }
      }
      let data = Data((line + "\n").utf8)
      if fileManager.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } else {
        try data.write(to: url, options: .withoutOverwriting)
      }
      hasWrittenIncident = true
      if countsTowardDailyCap {
        pruneOldFilesLocked(now: now)
      }
    } catch {
      // 写盘失败绝不遮蔽原始启动错误:这里只降级为统一日志(HangSentinel 同款纪律)。
      logger.error(
        "启动轨迹写盘失败:\(error.localizedDescription, privacy: .public);内容:\(line, privacy: .public)"
      )
    }
  }

  /// 只清理本类自己的 `start-failures-*.log`(AC9 不加新债);
  /// hang-*/retention-* 的保留期是既有债,另立小单,不在这里顺手扫。
  private func pruneOldFilesLocked(now: Date) {
    guard
      let names = try? fileManager.contentsOfDirectory(atPath: diagnosticsRoot.path)
    else {
      return
    }
    guard
      let cutoff = Calendar(identifier: .gregorian).date(
        byAdding: .day,
        value: -Self.retentionDays,
        to: now
      )
    else {
      return
    }
    let cutoffStamp = Self.dayStamp(cutoff)
    for name in names {
      guard name.hasPrefix("start-failures-"), name.hasSuffix(".log") else { continue }
      let stamp =
        name
        .replacingOccurrences(of: "start-failures-", with: "")
        .replacingOccurrences(of: ".log", with: "")
      guard stamp.count == 8, stamp.allSatisfy(\.isNumber) else { continue }
      guard stamp < cutoffStamp else { continue }
      do {
        try fileManager.removeItem(
          at: diagnosticsRoot.appendingPathComponent(name)
        )
      } catch {
        logger.error(
          "start-failures 过期文件清理失败:\(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  // MARK: - 工具

  private static func sanitize(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }

  private static func format(_ seconds: TimeInterval) -> String {
    String(format: "%.2fs", seconds)
  }

  private static func isoStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  private static func dayStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: date)
  }
}
