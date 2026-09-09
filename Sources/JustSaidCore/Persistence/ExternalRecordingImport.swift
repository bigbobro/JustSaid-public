import Foundation

/// 导入外部录音:只落 `system.m4a`、预建骨架、最后写 `meeting.json`。
///
/// 顺序即安全边界——`listMeetings` 只认有 meeting.json 的目录,拷到一半崩溃的残目录不可见。
public enum ExternalRecordingImport {
  /// 体积闸门(字节)。超过且无法用 AVFoundation 压缩时弹窗告知风险(D1)。
  public static let volumeGateBytes: Int64 = 30 * 1_024 * 1_024

  public struct ProbeResult: Equatable, Sendable {
    public let durationSeconds: TimeInterval?
    public let fileSizeBytes: Int64
    /// 火山 `audio.format` 用的短码(m4a/mp3/wav/…)。
    public let audioFormat: String
    /// 是否超过体积闸门(导入 UI 决定是否弹风险确认)。
    public let exceedsVolumeGate: Bool

    public init(
      durationSeconds: TimeInterval?,
      fileSizeBytes: Int64,
      audioFormat: String,
      exceedsVolumeGate: Bool
    ) {
      self.durationSeconds = durationSeconds
      self.fileSizeBytes = fileSizeBytes
      self.audioFormat = audioFormat
      self.exceedsVolumeGate = exceedsVolumeGate
    }
  }

  public struct Request: Equatable, Sendable {
    public let sourceFileURL: URL
    public let title: String?
    public let startedAt: Date
    public let language: MeetingLanguage
    /// 用户已确认超阈值风险后为 true。
    public let acceptVolumeRisk: Bool

    public init(
      sourceFileURL: URL,
      title: String?,
      startedAt: Date,
      language: MeetingLanguage,
      acceptVolumeRisk: Bool = false
    ) {
      self.sourceFileURL = sourceFileURL
      self.title = title
      self.startedAt = startedAt
      self.language = language
      self.acceptVolumeRisk = acceptVolumeRisk
    }
  }

  public enum ImportError: LocalizedError, Equatable {
    case sourceUnreadable
    case emptySource
    case volumeRiskRequiresConfirmation(bytes: Int64)
    case copyFailed(String)

    public var errorDescription: String? {
      switch self {
      case .sourceUnreadable:
        return "无法读取所选录音文件"
      case .emptySource:
        return "所选文件是空的"
      case .volumeRiskRequiresConfirmation(let bytes):
        let mb = Double(bytes) / (1_024 * 1_024)
        return String(
          format: "这份录音约 %.0f MB 且本机压不了,直传有失败风险且失败也计费。确认后才会导入。",
          mb
        )
      case .copyFailed(let detail):
        return "拷贝录音失败：\(detail)"
      }
    }
  }

  public static func probe(sourceFileURL: URL) async -> ProbeResult? {
    guard
      let values = try? sourceFileURL.resourceValues(forKeys: [.fileSizeKey]),
      let size = values.fileSize,
      size > 0
    else {
      return nil
    }
    let duration = await PostMeetingPipeline.probeAudioDuration(at: sourceFileURL)
    let format = resolvedAudioFormat(for: sourceFileURL)
    return ProbeResult(
      durationSeconds: duration,
      fileSizeBytes: Int64(size),
      audioFormat: format,
      exceedsVolumeGate: Int64(size) > volumeGateBytes
    )
  }

  /// 建会并落盘。成功返回会议记录;失败时尽量清掉半截目录。
  public static func importRecording(
    _ request: Request,
    providers: [RoleProviderBinding],
    meetingStore: MeetingStore,
    fileManager: FileManager = .default
  ) async throws -> MeetingRecord {
    guard fileManager.isReadableFile(atPath: request.sourceFileURL.path) else {
      throw ImportError.sourceUnreadable
    }
    guard
      let probe = await probe(sourceFileURL: request.sourceFileURL)
    else {
      throw ImportError.emptySource
    }
    if probe.exceedsVolumeGate, !request.acceptVolumeRisk {
      throw ImportError.volumeRiskRequiresConfirmation(bytes: probe.fileSizeBytes)
    }

    let rawTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // 空标题落「会议」二字,否则 applySuggestedTitleIfNeeded 静默不生效(B5)。
    let title = rawTitle.isEmpty ? "会议" : rawTitle
    let batchDecision: BatchLanguageDecision =
      request.language == .chinese ? .chinese : .english
    let endedAt: Date? = {
      guard let duration = probe.durationSeconds, duration > 0 else { return nil }
      return request.startedAt.addingTimeInterval(duration)
    }()

    // 先建目录(尚无 meeting.json → listMeetings 看不见)。
    let directory = meetingStore.allocateMeetingDirectory(
      title: title,
      date: request.startedAt
    )
    let paths = MeetingPaths(directory: directory)
    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      // 只落 system.m4a(.others 语义);绝不造 0 字节 mic。
      try fileManager.copyItem(
        at: request.sourceFileURL,
        to: paths.systemAudio
      )
      // rebuild 在 ensureLocalSkeleton 之前读 live transcript,必须预建空文件。
      try Data().write(to: paths.liveTranscript, options: .atomic)
      try FileManager.default.createDirectory(
        at: paths.summaryHistory,
        withIntermediateDirectories: true
      )
      if !fileManager.fileExists(atPath: paths.notes.path) {
        try Data().write(to: paths.notes, options: .atomic)
      }

      // 最后写 meeting.json —— 半截拷贝的残目录不会进列表(R9)。
      let metadata = MeetingMetadata(
        title: title,
        startedAt: request.startedAt,
        endedAt: endedAt,
        language: request.language,
        status: .interrupted,
        providers: providers,
        batchLanguageDecision: batchDecision,
        importedRecording: true,
        importedAudioFormat: probe.audioFormat
      )
      try meetingStore.write(metadata, to: paths)
      return MeetingRecord(paths: paths, metadata: metadata)
    } catch {
      try? fileManager.removeItem(at: directory)
      if let importError = error as? ImportError {
        throw importError
      }
      throw ImportError.copyFailed(error.localizedDescription)
    }
  }

  /// 扩展名 → 火山 format 短码;未知回落 m4a。
  public static func resolvedAudioFormat(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "mp3":
      return "mp3"
    case "wav":
      return "wav"
    case "ogg", "opus":
      return "ogg"
    case "amr":
      return "amr"
    case "aac":
      return "aac"
    case "m4a", "mp4", "mov":
      return "m4a"
    case "pcm", "raw":
      return "raw"
    default:
      return "m4a"
    }
  }

  public static func batchLanguage(from language: MeetingLanguage) -> BatchLanguageDecision {
    switch language {
    case .chinese: return .chinese
    case .english: return .english
    // auto 直通:精转语言交给转写内容检测,与「自动识别」语义一致。
    case .auto: return .auto
    }
  }
}
