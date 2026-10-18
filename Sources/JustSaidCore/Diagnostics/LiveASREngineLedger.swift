import Foundation

/// 会中速记引擎账本的一行(PR-08):每场散会写一行,记本场用了什么引擎、Pro 有没有接手与改用、
/// 1.7B 的设备读回与加载用时,以及散会的三个完成点。只有引擎与计时事实:不含会议标题、目录名、人名或文本,
/// 会议只以 `MeetingDiagnosticsPackageExporter.meetingHash` 出现。三个完成点只记录,不设上限。
public struct LiveASREngineLedgerEntry: Codable, Equatable, Sendable {
  public let recordedAt: Date
  public let meetingHash: String
  public let providerID: String
  /// 同 `LiveTranscriberRecord.model`。
  public let model: String
  public let mode: LiveTranscriberRecord.Mode
  /// 开会时定的 `LiveProPlan.diagnosticName`(off / pro / standardNeedsRepair / standardNotReady)。
  public let proPlan: String
  public let fellBack: Bool
  /// 回退发生在第几次 GPU 调用;0 = 开录后 1.7B 没能装好;没回退为 nil。
  public let fallbackCallIndex: Int?
  public let deviceName: String?
  public let deviceDescription: String?
  public let hasTensor: Bool?
  public let requestedThreads: Int32?
  /// 1.7B 加载、预热用时与开录后多久接手(秒);没接手为 nil。
  public let proLoadSeconds: Double?
  public let proWarmupSeconds: Double?
  public let proReadyAfterSeconds: Double?
  /// 从点停止起,两路采集停下、会中引擎 stop 返回(排空)、meeting.json 落盘各用了多少秒。
  public let captureStoppedAfterSeconds: Double?
  public let asrDrainedAfterSeconds: Double?
  public let persistedAfterSeconds: Double?

  public init(
    recordedAt: Date,
    meetingHash: String,
    record: LiveTranscriberRecord,
    proPlan: LiveProPlan,
    report: TranscriberLiveEngineReport?,
    captureStoppedAfterSeconds: Double?,
    asrDrainedAfterSeconds: Double?,
    persistedAfterSeconds: Double?
  ) {
    self.recordedAt = recordedAt
    self.meetingHash = meetingHash
    providerID = record.providerID
    model = record.model
    mode = record.mode
    self.proPlan = proPlan.diagnosticName
    fellBack = record.fellBack
    fallbackCallIndex = report?.fallbackCallIndex
    deviceName = report?.deviceName
    deviceDescription = report?.deviceDescription
    hasTensor = report?.hasTensor
    requestedThreads = report?.requestedThreads
    proLoadSeconds = report?.proLoadSeconds
    proWarmupSeconds = report?.proWarmupSeconds
    proReadyAfterSeconds = report?.proReadyAfterSeconds
    self.captureStoppedAfterSeconds = captureStoppedAfterSeconds
    self.asrDrainedAfterSeconds = asrDrainedAfterSeconds
    self.persistedAfterSeconds = persistedAfterSeconds
  }
}

/// `<diagnostics>/live-asr-engine.jsonl`,只留最近 200 行。诊断包整目录收集 diagnostics,这份账本随之进包。
public struct LiveASREngineLedger: Sendable {
  public static let fileName = "live-asr-engine.jsonl"
  public static let retainedLines = 200

  public let fileURL: URL

  public init(diagnosticsRoot: URL) {
    fileURL = diagnosticsRoot.appendingPathComponent(Self.fileName, isDirectory: false)
  }

  /// 追加一行并裁到最近 `retainedLines` 行,整份原子替换。读不懂的旧行原样保留。
  public func append(_ entry: LiveASREngineLedgerEntry) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let line = String(decoding: try encoder.encode(entry), as: UTF8.self)
    var lines = existingLines()
    lines.append(line)
    if lines.count > Self.retainedLines {
      lines.removeFirst(lines.count - Self.retainedLines)
    }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fileURL, options: .atomic)
  }

  /// 能解码的行,按写入顺序。
  public func entries() -> [LiveASREngineLedgerEntry] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return existingLines().compactMap {
      try? decoder.decode(LiveASREngineLedgerEntry.self, from: Data($0.utf8))
    }
  }

  private func existingLines() -> [String] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
  }
}
