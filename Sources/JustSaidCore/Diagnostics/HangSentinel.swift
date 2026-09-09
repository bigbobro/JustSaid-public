import Darwin
import Foundation
import os

/// 主线程卡死哨兵(08-16 加固):专用线程周期性 ping 主线程,无响应超过阈值时把
/// 面包屑轨迹与内存水位**立即**写入 `~/JustSaid/diagnostics/`——分发机器上复发时
/// 自动留下我方证据,不再依赖系统 cpu_resource.diag 的零星采样。恢复后追加恢复行。
///
/// 纪律:
/// - stall 期间不重复投递 ping,不往饿死的主队列灌积压;
/// - 事故文件在判定当刻落盘(force-quit 也要留得下证据);
/// - `note(_:)` 热路径只写内存环形缓冲,零磁盘 I/O;
/// - 落盘失败不重试不崩,降级为统一日志——挂了能从日志看出死在哪一步。
public final class HangSentinel: @unchecked Sendable {

  public static let shared = HangSentinel()

  private struct Crumb {
    let wallClock: Date
    let message: String
  }

  private static let crumbCapacity = 64

  private let pingQueue: DispatchQueue
  private let interval: TimeInterval
  private let threshold: TimeInterval
  private let directory: URL
  private let logger = Logger(subsystem: "com.justsaid.app", category: "HangSentinel")

  private let lock = NSLock()
  private var lastPong: TimeInterval = 0
  private var pingInFlight = false
  private var stallDetectedAt: TimeInterval?
  private var processStartedAtUptime: TimeInterval = 0
  private var incidentFile: URL?
  private var crumbs: [Crumb] = []
  private var started = false
  private var stopped = false

  /// 默认参数即生产配置;验证场景注入短周期与可阻塞队列做真实闭环。
  public init(
    directory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("JustSaid", isDirectory: true)
      .appendingPathComponent("diagnostics", isDirectory: true),
    pingQueue: DispatchQueue = .main,
    interval: TimeInterval = 1.0,
    threshold: TimeInterval = 5.0
  ) {
    self.directory = directory
    self.pingQueue = pingQueue
    self.interval = interval
    self.threshold = threshold
  }

  public func start(processStartedAt: Date = Date()) {
    lock.lock()
    if started {
      lock.unlock()
      return
    }
    let nowUptime = Self.uptimeNow()
    started = true
    lastPong = nowUptime
    processStartedAtUptime =
      nowUptime - max(0, Date().timeIntervalSince(processStartedAt))
    lock.unlock()
    let thread = Thread { [weak self] in
      while let self, !self.isStopped {
        Thread.sleep(forTimeInterval: self.interval)
        self.tick()
      }
    }
    thread.name = "HangSentinel"
    thread.qualityOfService = .utility
    thread.start()
    logger.info("哨兵启动:interval=\(self.interval)s threshold=\(self.threshold)s")
  }

  /// 只给验证场景用:停掉探测线程,生产路径不调用。
  public func stopForVerification() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  /// 面包屑:短字符串,如 `tab:transcript` / `textScale:140` / `scroll-commit:420`。
  public func note(_ message: String) {
    let crumb = Crumb(wallClock: Date(), message: message)
    lock.lock()
    crumbs.append(crumb)
    if crumbs.count > Self.crumbCapacity {
      crumbs.removeFirst(crumbs.count - Self.crumbCapacity)
    }
    lock.unlock()
  }

  // MARK: - 探测

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func tick() {
    let now = Self.uptimeNow()
    lock.lock()
    let shouldPing = !pingInFlight
    if shouldPing {
      pingInFlight = true
    }
    let age = now - lastPong
    lock.unlock()

    if shouldPing {
      pingQueue.async { [weak self] in
        guard let self else { return }
        self.lock.lock()
        self.lastPong = Self.uptimeNow()
        self.pingInFlight = false
        self.lock.unlock()
      }
    }

    if age >= threshold {
      beginStallIfNeeded(age: age)
    } else {
      endStallIfNeeded()
    }
  }

  private func beginStallIfNeeded(age: TimeInterval) {
    lock.lock()
    let alreadyStalled = stallDetectedAt != nil
    let detectedAtUptime = Self.uptimeNow()
    if !alreadyStalled {
      stallDetectedAt = detectedAtUptime
    }
    let processStartDistance = max(0, detectedAtUptime - processStartedAtUptime)
    let snapshot = crumbs
    lock.unlock()
    guard !alreadyStalled else { return }
    writeIncident(
      age: age,
      processStartDistance: processStartDistance,
      crumbs: snapshot
    )
  }

  private func endStallIfNeeded() {
    lock.lock()
    guard let detectedAt = stallDetectedAt else {
      lock.unlock()
      return
    }
    stallDetectedAt = nil
    let file = incidentFile
    incidentFile = nil
    lock.unlock()
    // 卡顿总时长 ≈ 判定前已积累的阈值 + 判定后持续的时间,精度半个探测周期,够用。
    let stalledFor = Self.uptimeNow() - detectedAt + threshold
    let footprint = Self.footprintMB().map { String(format: "%.1f MB", $0) } ?? "未知"
    appendLine(
      to: file,
      "恢复:\(Self.timestamp()) 主线程恢复响应,卡顿总时长约 "
        + "\(String(format: "%.1f", stalledFor))s,恢复时内存 \(footprint)"
    )
    DiagnosticEventLedger(rootDirectory: directory).append(
      event: "hang.recovered",
      source: "HangSentinel",
      fields: DiagnosticEventFields(
        family: "app",
        operation: "mainThreadHang",
        purpose: "lifecycle",
        origin: "hangSentinel",
        stage: "recovery",
        outcome: "recovered",
        latencyMs: Int(stalledFor * 1_000)
      )
    )
    logger.warning("主线程恢复响应,卡顿约 \(stalledFor, format: .fixed(precision: 1))s")
  }

  // MARK: - 落盘

  private func writeIncident(
    age: TimeInterval,
    processStartDistance: TimeInterval,
    crumbs: [Crumb]
  ) {
    let build =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "非 app 环境"
    let footprint = Self.footprintMB().map { String(format: "%.1f MB", $0) } ?? "未知"
    var lines: [String] = [
      "JustSaid 主线程卡死报告",
      "构建:\(build)",
      "系统:\(ProcessInfo.processInfo.operatingSystemVersionString)",
      "判定:\(Self.timestamp()) 主线程已 \(String(format: "%.1f", age))s 无响应"
        + "(阈值 \(String(format: "%.0f", threshold))s)",
      "内存 phys_footprint:\(footprint)",
      "",
      "最近操作(旧→新,最多 \(Self.crumbCapacity) 条):",
    ]
    if crumbs.isEmpty {
      lines.append("  (无)")
      lines.append("判定时距进程启动 \(String(format: "%.1f", processStartDistance))s")
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "HH:mm:ss.SSS"
      for crumb in crumbs {
        lines.append("  \(formatter.string(from: crumb.wallClock))  \(crumb.message)")
      }
    }
    lines.append("")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("hang-\(Self.fileStamp()).log")
      try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
      lock.lock()
      incidentFile = url
      lock.unlock()
      logger.fault(
        "主线程无响应 \(age, format: .fixed(precision: 1))s,事故文件:\(url.path)"
      )
      DiagnosticEventLedger(rootDirectory: directory).append(
        event: "hang.detected",
        severity: .fault,
        source: "HangSentinel",
        fields: DiagnosticEventFields(
          family: "app",
          operation: "mainThreadHang",
          purpose: "lifecycle",
          origin: "hangSentinel",
          stage: "detection",
          outcome: "detected",
          latencyMs: Int(age * 1_000)
        )
      )
    } catch {
      logger.error("事故文件写入失败:\(error.localizedDescription)——证据仅剩本条日志")
    }
  }

  private func appendLine(to url: URL?, _ line: String) {
    guard let url else { return }
    do {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data((line + "\n").utf8))
    } catch {
      logger.error("恢复行追加失败:\(error.localizedDescription);内容:\(line)")
    }
  }

  // MARK: - 工具

  private static func uptimeNow() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.string(from: Date())
  }

  private static func fileStamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  private static func footprintMB() -> Double? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kern = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kern == KERN_SUCCESS else { return nil }
    return Double(info.phys_footprint) / 1_048_576
  }
}
