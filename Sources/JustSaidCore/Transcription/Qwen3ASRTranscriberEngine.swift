import AVFAudio
import Foundation
import OSLog
import SherpaOnnx
import SherpaOnnxC

public struct Qwen3ASRStreamLanguageObservation: Codable, Equatable, Sendable {
  public let selectedLanguage: MeetingLanguage
  public let hasLanguageOption: Bool
  public let languageOptionValue: String?

  public init(
    selectedLanguage: MeetingLanguage,
    hasLanguageOption: Bool,
    languageOptionValue: String?
  ) {
    self.selectedLanguage = selectedLanguage
    self.hasLanguageOption = hasLanguageOption
    self.languageOptionValue = languageOptionValue
  }
}

public final class Qwen3ASRTranscriberEngine: TranscriberEngine,
  TranscriberASRAnchorGapFramesProviding,
  TranscriberLiveEmissionStatsProviding,
  LiveDecodeObservationProviding,
  @unchecked Sendable
{
  /// 连续语音最长段。15 秒缩短长段终稿与其后 partial 的等待(AC8 点名延迟长尾);
  /// 属于会中分段本身,两路共用,不随点名提醒开关变化。SenseVoice 仍用共享默认 30 秒。
  public static let maximumSpeechSegmentDuration: TimeInterval = 15

  public static func defaultModelDirectory(
    fileManager: FileManager = .default
  ) -> URL {
    LocalOfflineModelPaths.modelsDirectory(fileManager: fileManager)
      .appendingPathComponent("Qwen3-ASR-0.6B", isDirectory: true)
  }

  public static func defaultVADModelURL(
    fileManager: FileManager = .default
  ) -> URL {
    LocalOfflineModelPaths.defaultVADModelURL(fileManager: fileManager)
  }

  public static func languageOption(
    for language: MeetingLanguage
  ) -> String? {
    switch language {
    case .auto:
      return nil
    case .chinese:
      return "Chinese"
    case .english:
      return "English"
    }
  }

  private let modelDirectory: URL
  private let vadModelURL: URL
  private let observationBox = Qwen3ASRObservationBox()
  /// internal 仅供验证核对实例实际取得的段长;调用方仍只经公开 API 使用。
  let runtime = LocalOfflineTranscriptionRuntime(
    engineDisplayName: "Qwen3-ASR",
    loggerCategory: "Qwen3ASRTranscriber",
    maximumSpeechSegmentDuration: Qwen3ASRTranscriberEngine.maximumSpeechSegmentDuration
  )

  public var results: AsyncStream<TranscriptSegment> { runtime.results }

  public var decodeObservations: AsyncStream<LiveDecodeObservation> {
    runtime.decodeObservations
  }

  /// 每个真实 decode stream 通过 sherpa C API 读回的 language option。
  /// `.auto` 必须记录为 `hasLanguageOption == false`，不是空字符串 option。
  public var languageObservations: [Qwen3ASRStreamLanguageObservation] {
    observationBox.languageObservations
  }

  /// 数字静音在创建 Qwen stream 前被挡下的次数。只用于运行时取证与定向验证。
  public var digitalSilenceSkippedDecodeCount: UInt64 {
    observationBox.digitalSilenceSkippedDecodeCount
  }

  public init(
    modelDirectory: URL = Qwen3ASRTranscriberEngine.defaultModelDirectory(),
    vadModelURL: URL = Qwen3ASRTranscriberEngine.defaultVADModelURL()
  ) {
    self.modelDirectory = modelDirectory
    self.vadModelURL = vadModelURL
  }

  public func start(language: MeetingLanguage) async throws {
    try runtime.start(vadModelURL: vadModelURL) { [self] in
      let modelFiles = try Qwen3ASRModelFiles(directory: modelDirectory)
      return Qwen3ASRRecognizer(
        modelFiles: modelFiles,
        selectedLanguage: language,
        languageOption: Self.languageOption(for: language),
        observationBox: observationBox
      )
    }
  }

  public func feed(
    _ pcmBuffer: AVAudioPCMBuffer,
    source: AudioSource,
    at captureTime: TimeInterval
  ) throws {
    try runtime.feed(pcmBuffer, source: source, at: captureTime)
  }

  public func asrAnchorGapFrames(for source: AudioSource) -> UInt64 {
    runtime.asrAnchorGapFrames(for: source)
  }

  public func liveEmissionStats(for source: AudioSource) -> LiveEmissionStats {
    runtime.liveEmissionStats(for: source)
  }

  public func inputAudioEnd(for source: AudioSource) -> TimeInterval? {
    runtime.inputAudioEnd(for: source)
  }

  public func stop() async {
    await runtime.stop()
  }
}

private struct Qwen3ASRModelFiles: Sendable {
  static let requiredRelativePaths = [
    "conv_frontend.onnx",
    "encoder.int8.onnx",
    "decoder.int8.onnx",
    "tokenizer/vocab.json",
    "tokenizer/merges.txt",
    "tokenizer/tokenizer_config.json",
  ]

  let convFrontend: URL
  let encoder: URL
  let decoder: URL
  let tokenizerDirectory: URL

  init(
    directory: URL,
    fileManager: FileManager = .default
  ) throws {
    let paths = Self.requiredRelativePaths.map { relativePath in
      (
        relativePath,
        directory.appendingPathComponent(relativePath)
      )
    }
    let missing = paths.compactMap { relativePath, url in
      fileManager.isReadableFile(atPath: url.path) ? nil : relativePath
    }
    guard missing.isEmpty else {
      throw TranscriberEngineError.missingLocalModel(
        engine: "Qwen3-ASR-0.6B INT8",
        directory: directory,
        missingFiles: missing
      )
    }

    convFrontend = directory.appendingPathComponent("conv_frontend.onnx")
    encoder = directory.appendingPathComponent("encoder.int8.onnx")
    decoder = directory.appendingPathComponent("decoder.int8.onnx")
    tokenizerDirectory = directory.appendingPathComponent(
      "tokenizer",
      isDirectory: true
    )
  }
}

private actor Qwen3ASRRecognizer: OfflineSpeechRecognizer {
  private static let digitalSilenceRMSThreshold: Double = 0.000_05

  private let recognizer: SherpaOnnxOfflineRecognizer
  private let selectedLanguage: MeetingLanguage
  private let languageOption: String?
  private let observationBox: Qwen3ASRObservationBox

  /// `languageOption` 故意不给默认值：`.auto` 的 nil 与漏传必须由调用点显式区分。
  init(
    modelFiles: Qwen3ASRModelFiles,
    selectedLanguage: MeetingLanguage,
    languageOption: String?,
    observationBox: Qwen3ASRObservationBox
  ) {
    self.selectedLanguage = selectedLanguage
    self.languageOption = languageOption
    self.observationBox = observationBox

    let qwen3ASR = sherpaOnnxOfflineQwen3ASRModelConfig(
      convFrontend: modelFiles.convFrontend.path,
      encoder: modelFiles.encoder.path,
      decoder: modelFiles.decoder.path,
      tokenizer: modelFiles.tokenizerDirectory.path,
      maxTotalLen: 512,
      maxNewTokens: 128,
      temperature: 1e-6,
      topP: 0.8,
      seed: 42,
      hotwords: ""
    )
    let model = sherpaOnnxOfflineModelConfig(
      tokens: "",
      numThreads: 2,
      provider: "cpu",
      debug: 0,
      qwen3Asr: qwen3ASR
    )
    let features = sherpaOnnxFeatureConfig(
      sampleRate: 16_000,
      featureDim: 128
    )
    var config = sherpaOnnxOfflineRecognizerConfig(
      featConfig: features,
      modelConfig: model
    )
    recognizer = SherpaOnnxOfflineRecognizer(config: &config)
  }

  func decode(_ samples: [Float]) -> String {
    guard !Self.isDigitalSilence(samples) else {
      observationBox.recordDigitalSilenceSkip()
      return ""
    }

    let stream = recognizer.createStream()
    if let languageOption {
      stream.setOption(key: "language", value: languageOption)
    }

    let hasLanguageOption = "language".withCString { keyPointer in
      SherpaOnnxOfflineStreamHasOption(stream.stream, keyPointer) != 0
    }
    let languageOptionValue: String?
    if hasLanguageOption {
      languageOptionValue = "language".withCString { keyPointer in
        guard
          let valuePointer = SherpaOnnxOfflineStreamGetOption(
            stream.stream,
            keyPointer
          )
        else {
          return nil
        }
        // C 侧返回的是 stream 内部字符串指针；stream 销毁前立即复制。
        return String(cString: valuePointer)
      }
    } else {
      languageOptionValue = nil
    }

    let observation = Qwen3ASRStreamLanguageObservation(
      selectedLanguage: selectedLanguage,
      hasLanguageOption: hasLanguageOption,
      languageOptionValue: languageOptionValue
    )
    if observationBox.recordLanguageObservation(observation) {
      let valueDescription = languageOptionValue ?? "none"
      Logger(
        subsystem: "com.justsaid.app",
        category: "Qwen3ASRTranscriber"
      ).notice(
        "Qwen3-ASR 语种选项 selected=\(self.selectedLanguage.rawValue, privacy: .public) hasLanguageOption=\(hasLanguageOption, privacy: .public) languageOption=\(valueDescription, privacy: .public)"
      )
    }

    stream.acceptWaveform(samples: samples, sampleRate: 16_000)
    // 原生推理的进出时刻:两条记录严格夹住同步的 `recognizer.decode(stream:)` 调用本身,
    // 不含外层 await、特征送入或结果读取,免得把等待时间当成推理时间。debug 构建才有。
    #if DEBUG
      LocalOfflineVerificationTrace.shared.record(
        event: "nativeStart", origin: "native", source: "recognizer",
        sampleCount: samples.count)
    #endif
    recognizer.decode(stream: stream)
    #if DEBUG
      LocalOfflineVerificationTrace.shared.record(
        event: "nativeReturn", origin: "native", source: "recognizer",
        sampleCount: samples.count)
    #endif
    return recognizer.getResult(stream: stream).text
  }

  private static func isDigitalSilence(_ samples: [Float]) -> Bool {
    guard !samples.isEmpty else {
      return true
    }
    let sumOfSquares = samples.reduce(into: 0.0) { partialResult, sample in
      let value = Double(sample)
      partialResult += value * value
    }
    let rms = sqrt(sumOfSquares / Double(samples.count))
    return rms < digitalSilenceRMSThreshold
  }
}

private final class Qwen3ASRObservationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [Qwen3ASRStreamLanguageObservation] = []
  private var silenceSkipCount: UInt64 = 0

  var languageObservations: [Qwen3ASRStreamLanguageObservation] {
    lock.lock()
    defer { lock.unlock() }
    return observations
  }

  var digitalSilenceSkippedDecodeCount: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return silenceSkipCount
  }

  /// 返回 true 表示这是首个真实 decode stream，调用方据此只记一条 notice。
  func recordLanguageObservation(
    _ observation: Qwen3ASRStreamLanguageObservation
  ) -> Bool {
    lock.lock()
    let isFirst = observations.isEmpty
    observations.append(observation)
    lock.unlock()
    return isFirst
  }

  func recordDigitalSilenceSkip() {
    lock.lock()
    silenceSkipCount += 1
    lock.unlock()
  }
}
