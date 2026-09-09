import Foundation
import os

public struct AudioRetentionSweepResult: Sendable, Equatable {
  public var deletedFiles: [String]
  public var skippedMeetings: [String]

  public init(deletedFiles: [String] = [], skippedMeetings: [String] = []) {
    self.deletedFiles = deletedFiles
    self.skippedMeetings = skippedMeetings
  }
}

/// 按用户档位删除超期且已精转会议的顶层 m4a。不删文本,不碰会议库外目录。
public struct AudioRetentionSweeper {
  public var fileManager: FileManager
  public var calendar: Calendar

  public init(fileManager: FileManager = .default, calendar: Calendar = .current) {
    self.fileManager = fileManager
    self.calendar = calendar
  }

  @discardableResult
  public func sweep(
    meetingsRoot: URL,
    diagnosticsRoot: URL,
    policy: AudioRetentionPolicy,
    now: Date = Date()
  ) throws -> AudioRetentionSweepResult {
    let ledger = DiagnosticEventLedger(rootDirectory: diagnosticsRoot)
    ledger.append(
      event: "retention.start",
      source: "AudioRetentionSweeper",
      fields: DiagnosticEventFields(
        family: "persistence",
        operation: "audioRetention",
        purpose: "retention",
        origin: "scheduler",
        outcome: "started"
      )
    )
    guard let dayCount = policy.dayCount else {
      ledger.append(
        event: "retention.finish",
        source: "AudioRetentionSweeper",
        fields: DiagnosticEventFields(
          family: "persistence",
          operation: "audioRetention",
          purpose: "retention",
          origin: "scheduler",
          outcome: "skipped",
          category: "policyNever"
        )
      )
      return AudioRetentionSweepResult()
    }

    let store = MeetingStore(rootDirectory: meetingsRoot, fileManager: fileManager)
    let today = calendar.startOfDay(for: now)
    var result = AudioRetentionSweepResult()

    for record in store.listMeetings() {
      let meetingDay = calendar.startOfDay(for: record.metadata.startedAt)
      guard let expiry = calendar.date(byAdding: .day, value: dayCount, to: meetingDay),
        expiry < today
      else {
        result.skippedMeetings.append("\(record.paths.directory.lastPathComponent):未超期")
        continue
      }

      let artifacts = MeetingArtifacts.read(from: record.paths, fileManager: fileManager)
      guard artifacts.transcript != nil else {
        result.skippedMeetings.append("\(record.paths.directory.lastPathComponent):未精转豁免")
        continue
      }

      let audioFiles = try topLevelM4AFiles(in: record.paths.directory)
      for file in audioFiles {
        try fileManager.removeItem(at: file)
        let line = "\(record.paths.directory.lastPathComponent)/\(file.lastPathComponent)"
        result.deletedFiles.append(line)
        try appendLog(
          to: diagnosticsRoot,
          now: now,
          line:
            "\(isoFormatter.string(from: now)) policy=\(policy.rawValue) deleted \(line)"
        )
      }
    }
    ledger.append(
      event: "retention.finish",
      source: "AudioRetentionSweeper",
      fields: DiagnosticEventFields(
        family: "persistence",
        operation: "audioRetention",
        purpose: "retention",
        origin: "scheduler",
        outcome: "success",
        category: "success",
        outputSize: result.deletedFiles.count
      )
    )
    return result
  }

  private func topLevelM4AFiles(in directory: URL) throws -> [URL] {
    let entries = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    return entries.filter { url in
      url.pathExtension.lowercased() == "m4a"
        && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
  }

  private func appendLog(to diagnosticsRoot: URL, now: Date, line: String) throws {
    try fileManager.createDirectory(at: diagnosticsRoot, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    let url = diagnosticsRoot.appendingPathComponent(
      "retention-\(formatter.string(from: now)).log"
    )
    let data = Data((line + "\n").utf8)
    if fileManager.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } else {
      try data.write(to: url, options: .withoutOverwriting)
    }
  }

  private var isoFormatter: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }
}

/// 启动扫一次,之后每小时检查是否已过 24h。档位为「不删除」时什么都不做。
public final class AudioRetentionScheduler: @unchecked Sendable {
  public static let shared = AudioRetentionScheduler()
  public static let lastSweepDefaultsKey = "justsaid.audioRetention.lastSweepAt"

  /// Roots and defaults captured by one `start` call. `configurationLock` guards the scheduler's
  /// own copies (their lifetime and replacement) so the queued sweeps capture only `self`; it does
  /// not claim ownership of the shared `UserDefaults` object, whose thread-safety is relied upon
  /// as before.
  private struct Configuration {
    var meetingsRoot: URL
    var diagnosticsRoot: URL
    var defaults: UserDefaults
  }

  /// One accepted unit of sweep work: the configuration it was bound to when it was accepted
  /// (a `start` call or a timer fire) and whether it is the forced first sweep of a `start`.
  private struct PendingSweep {
    var configuration: Configuration
    var force: Bool
  }

  private let queue = DispatchQueue(label: "com.justsaid.audio-retention", qos: .utility)
  private let configurationLock = NSLock()
  /// Accepted sweeps in acceptance order, each bound to its own configuration under the lock, so
  /// a rapid restart still sweeps each `start` exactly once and a timer fire keeps the
  /// configuration of the timer that fired.
  private var pendingSweeps: [PendingSweep] = []
  /// Each `start` gets a generation; the timer it installs resolves its configuration through
  /// this map, so an old timer that fires before the main-thread replacement still means its own
  /// `start`, exactly like the closure capture it replaces. Entries are retired on replacement.
  private var timerConfigurations: [UInt64: Configuration] = [:]
  private var nextTimerGeneration: UInt64 = 0
  private var timer: Timer?
  private var installedTimerGeneration: UInt64?

  public func start(
    meetingsRoot: URL = MeetingStore.defaultRootDirectory(),
    diagnosticsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("JustSaid", isDirectory: true)
      .appendingPathComponent("diagnostics", isDirectory: true),
    defaults: UserDefaults = .standard
  ) {
    let configuration = Configuration(
      meetingsRoot: meetingsRoot,
      diagnosticsRoot: diagnosticsRoot,
      defaults: defaults
    )
    // Bind and enqueue while holding the lock so accepted sweeps run in acceptance order.
    configurationLock.lock()
    nextTimerGeneration += 1
    let generation = nextTimerGeneration
    timerConfigurations[generation] = configuration
    pendingSweeps.append(PendingSweep(configuration: configuration, force: true))
    queue.async {
      self.sweepNextPending()
    }
    configurationLock.unlock()
    DispatchQueue.main.async {
      self.timer?.invalidate()
      if let retired = self.installedTimerGeneration {
        self.retireTimerConfiguration(retired)
      }
      self.installedTimerGeneration = generation
      self.timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
        guard let self else { return }
        self.enqueueTimerSweep(generation: generation)
      }
    }
  }

  /// Binds a timer fire to the configuration of the `start` that installed that timer and
  /// enqueues it; a newer `start` whose timer replacement has not run yet cannot rebind it.
  private func enqueueTimerSweep(generation: UInt64) {
    configurationLock.lock()
    if let configuration = timerConfigurations[generation] {
      pendingSweeps.append(PendingSweep(configuration: configuration, force: false))
      queue.async {
        self.sweepNextPending()
      }
    }
    configurationLock.unlock()
  }

  /// Drops the configuration of a timer that has just been invalidated on the main thread.
  private func retireTimerConfiguration(_ generation: UInt64) {
    configurationLock.lock()
    timerConfigurations[generation] = nil
    configurationLock.unlock()
  }

  /// Runs the oldest accepted sweep with the configuration it was bound to.
  private func sweepNextPending() {
    configurationLock.lock()
    let pending = pendingSweeps.isEmpty ? nil : pendingSweeps.removeFirst()
    configurationLock.unlock()
    guard let pending else {
      return
    }
    sweepIfNeeded(
      meetingsRoot: pending.configuration.meetingsRoot,
      diagnosticsRoot: pending.configuration.diagnosticsRoot,
      defaults: pending.configuration.defaults,
      force: pending.force
    )
  }

  public func sweepIfNeeded(
    meetingsRoot: URL,
    diagnosticsRoot: URL,
    defaults: UserDefaults,
    force: Bool,
    now: Date = Date()
  ) {
    let policy = AudioRetentionPolicy.current(in: defaults)
    guard policy != .never else { return }
    if !force, let last = defaults.object(forKey: Self.lastSweepDefaultsKey) as? Date,
      now.timeIntervalSince(last) < 24 * 60 * 60
    {
      return
    }
    do {
      _ = try AudioRetentionSweeper().sweep(
        meetingsRoot: meetingsRoot,
        diagnosticsRoot: diagnosticsRoot,
        policy: policy,
        now: now
      )
      defaults.set(now, forKey: Self.lastSweepDefaultsKey)
    } catch {
      Logger(subsystem: "com.justsaid.app", category: "AudioRetention")
        .error("音频保留期扫描失败: \(error.localizedDescription, privacy: .public)")
    }
  }
}
