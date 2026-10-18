import AVFAudio
import Foundation
import OSLog
import SherpaOnnx
import SherpaOnnxC
import Synchronization

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
  LiveLanguageSwitching,
  LiveEngineEventProviding,
  TranscriberLiveEngineReporting,
  @unchecked Sendable
{
  /// 清单里的模型资产 ID,写进 `liveEngineReport`。
  public static let standardModelAssetID = "qwen3-asr-0.6b-int8"
  public static let proModelAssetID = "qwen3-asr-1.7b-q8-gguf"

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
  /// 本场当前语种。每个 decode stream 新建时读一次,会中切换从下一段起生效。
  private let languageBox = Qwen3ASRLanguageBox()
  /// internal 仅供验证核对实例实际取得的段长;调用方仍只经公开 API 使用。
  let runtime = LocalOfflineTranscriptionRuntime(
    engineDisplayName: "Qwen3-ASR",
    loggerCategory: "Qwen3ASRTranscriber",
    maximumSpeechSegmentDuration: Qwen3ASRTranscriberEngine.maximumSpeechSegmentDuration
  )

  public var results: AsyncStream<TranscriptSegment> { runtime.results }
  public var usesCaptureTime: Bool { true }

  public var decodeObservations: AsyncStream<LiveDecodeObservation> {
    runtime.decodeObservations
  }

  /// 每个真实 decode stream 通过 sherpa C API 读回的 language option。
  /// `.auto` 必须记录为 `hasLanguageOption == false`，不是空字符串 option。
  /// Pro 开时记的是每次 GPU 调用实际传给 transcribe_run 的语言码(`en` / `zh` / 不传),
  /// 交给热备的段不记(热备 stream 的读回在它自己那里,不与 GPU 所传混在一起)。
  public var languageObservations: [Qwen3ASRStreamLanguageObservation] {
    observationBox.languageObservations
  }

  /// 数字静音在创建 Qwen stream 前被挡下的次数。只用于运行时取证与定向验证。
  /// Pro 开时数的是复合识别器挡在 GPU 之外的数字静音 decode(含回退之后的)。
  public var digitalSilenceSkippedDecodeCount: UInt64 {
    observationBox.digitalSilenceSkippedDecodeCount
  }

  /// 本场走 Pro(PR-07)时 1.7B 从哪里来;nil 就是标准识别,与没有 Pro 时逐字相同。
  private let pro: ProRecognizerConfiguration?
  /// start 时建好的复合识别器,stop 时取走并让它放掉 1.7B;Pro 关、还没 start 或已 stop 为 nil。
  private let proComposite = Mutex<ProGPUPrimaryRecognizer?>(nil)
  /// Pro 开时报告用的接手读回与回退序号,复合识别器写、`liveEngineReport` 任意线程读。
  private let proState = Qwen3ASRProStateBox()
  private let engineEventStream: AsyncStream<LiveEngineEvent>
  private let engineEventContinuation: AsyncStream<LiveEngineEvent>.Continuation

  /// 本场的回退事件(Pro 模式),stop() 返回前结束。Pro 关时从不送出。
  public var engineEvents: AsyncStream<LiveEngineEvent> { engineEventStream }

  public var liveEngineReport: TranscriberLiveEngineReport {
    guard pro != nil else {
      return TranscriberLiveEngineReport(
        modelAssetID: Self.standardModelAssetID,
        fellBack: false,
        fallbackCallIndex: nil,
        deviceName: nil,
        deviceDescription: nil,
        hasTensor: nil,
        requestedThreads: nil
      )
    }
    let (readiness, fallbackCallIndex) = proState.snapshot
    return TranscriberLiveEngineReport(
      modelAssetID: Self.proModelAssetID,
      fellBack: fallbackCallIndex != nil,
      fallbackCallIndex: fallbackCallIndex,
      deviceName: readiness?.deviceInfo?.name,
      deviceDescription: readiness?.deviceInfo?.description,
      hasTensor: readiness?.hasTensor,
      requestedThreads: readiness?.requestedThreads,
      proLoadSeconds: readiness?.loadSeconds,
      proWarmupSeconds: readiness?.warmupSeconds,
      proReadyAfterSeconds: readiness?.readyAfterSeconds
    )
  }

  /// 验证用:1.7B 接手时的读回(含接手时刻);Pro 关、还没接手或没能装好为 nil。
  @_spi(Verification) public var proReadiness: ProGPUReadiness? {
    proState.snapshot.readiness
  }

  /// 验证用:等 1.7B 的后台加载结束(装好、失败或被取消)。Pro 关、还没 start 或已 stop 时立刻返回。
  @_spi(Verification) public func proLoadingFinished() async {
    guard let composite = proComposite.withLock({ $0 }) else { return }
    await composite.loadingFinished()
  }

  /// `pro` 非 nil 时本场走 Pro(GPU 主 + 0.6B 热备,1.7B 开录时在后台加载);nil 时与原来完全相同。
  public init(
    modelDirectory: URL = Qwen3ASRTranscriberEngine.defaultModelDirectory(),
    vadModelURL: URL = Qwen3ASRTranscriberEngine.defaultVADModelURL(),
    pro: ProRecognizerConfiguration? = nil
  ) {
    self.modelDirectory = modelDirectory
    self.vadModelURL = vadModelURL
    self.pro = pro
    let events = AsyncStream.makeStream(
      of: LiveEngineEvent.self,
      bufferingPolicy: .unbounded
    )
    engineEventStream = events.stream
    engineEventContinuation = events.continuation
  }

  public func start(language: MeetingLanguage) async throws {
    languageBox.language = language
    try runtime.start(vadModelURL: vadModelURL) { [self] in
      guard let pro else {
        let modelFiles = try Qwen3ASRModelFiles(directory: modelDirectory)
        return Qwen3ASRRecognizer(
          modelFiles: modelFiles,
          languageBox: languageBox,
          observationBox: observationBox
        )
      }
      // Pro 开:0.6B 照常同步装好(缺文件报错同标准识别),作热备,开录头几秒由它出字;
      // 1.7B 在下面放进后台加载,装好后接手。
      let hotSpare: any ProHotSpareDecoding =
        try pro.hotSpareOverride ?? Qwen3ASRHotSpare(modelDirectory: modelDirectory)
      let composite = makeProRecognizer(pro, hotSpare: hotSpare)
      proComposite.withLock { $0 = composite }
      return composite
    }
    if let composite = proComposite.withLock({ $0 }) {
      await composite.beginLoading()
    }
  }

  /// 复合识别器每次 decode 读 `languageBox`(#212 会中切换逐段生效),GPU 所传语种与静音计数
  /// 记进本引擎的观察盒,接手读回与回退序号记进 `proState`。
  private func makeProRecognizer(
    _ pro: ProRecognizerConfiguration,
    hotSpare: any ProHotSpareDecoding
  ) -> ProGPUPrimaryRecognizer {
    ProGPUPrimaryRecognizer(
      hotSpare: hotSpare,
      configuration: pro,
      language: { [languageBox] in languageBox.language },
      events: engineEventContinuation,
      hooks: ProRecognizerHooks(
        gpuLanguage: { [observationBox] observation in
          if observationBox.recordLanguageObservation(observation) {
            let value = observation.languageOptionValue ?? "none"
            Logger(
              subsystem: "com.justsaid.app",
              category: "Qwen3ASRTranscriber"
            ).notice(
              "Qwen3-ASR Pro GPU 语种 selected=\(observation.selectedLanguage.rawValue, privacy: .public) language=\(value, privacy: .public)"
            )
          }
        },
        digitalSilence: { [observationBox] in
          observationBox.recordDigitalSilenceSkip()
        },
        ready: { [proState] readiness in
          proState.recordReady(readiness)
        },
        fellBack: { [proState] callIndex in
          proState.recordFallback(callIndex)
        }
      )
    )
  }

  /// 会中改语言(owner 2026-10-16 定)。language 本来就是每段 stream 的 option,
  /// 这里只换下一段新建 stream 时读到的值:引擎、VAD 和音频链路都不重启。
  /// 已在解码的那一段仍按旧语种出结果。
  public func switchLanguage(to language: MeetingLanguage) {
    languageBox.language = language
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
    // Pro:两路排空之后再停加载任务、放掉 1.7B(散会即卸);stop 返回时本引擎不再持有它。
    let composite = proComposite.withLock { current in
      let taken = current
      current = nil
      return taken
    }
    await composite?.shutdown()
    engineEventContinuation.finish()
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

/// 验证专用(Pro 探针):与会中同一个识别器(同一配置、静音门与协议头清理),但不经 VAD,
/// 一次解一整段样本。构造即同步加载模型;缺文件抛 `TranscriberEngineError.missingLocalModel`。
@_spi(Verification)
public struct Qwen3ASRSegmentDecoder: Sendable {
  private let recognizer: Qwen3ASRRecognizer

  public init(
    modelDirectory: URL = Qwen3ASRTranscriberEngine.defaultModelDirectory(),
    language: MeetingLanguage
  ) throws {
    let languageBox = Qwen3ASRLanguageBox()
    languageBox.language = language
    recognizer = Qwen3ASRRecognizer(
      modelFiles: try Qwen3ASRModelFiles(directory: modelDirectory),
      languageBox: languageBox,
      observationBox: Qwen3ASRObservationBox()
    )
  }

  public func decode(_ samples: [Float]) async -> String {
    await recognizer.decode(samples)
  }
}

/// Pro 模式的热备(PR-07):与会中标准识别同一个识别器(同一配置、静音门与协议头清理),
/// 语种由复合识别器逐次给出,不读引擎的语种盒。它有自己的观察盒,读回不进引擎的
/// `languageObservations`(Pro 开时那里记的是 GPU 所传的语言码)。
struct Qwen3ASRHotSpare: ProHotSpareDecoding {
  private let recognizer: Qwen3ASRRecognizer

  /// 同步加载 0.6B;缺文件抛 `TranscriberEngineError.missingLocalModel`,逐项列出。
  init(modelDirectory: URL) throws {
    recognizer = Qwen3ASRRecognizer(
      modelFiles: try Qwen3ASRModelFiles(directory: modelDirectory),
      languageBox: Qwen3ASRLanguageBox(),
      observationBox: Qwen3ASRObservationBox()
    )
  }

  func decode(_ samples: [Float], language: MeetingLanguage) async -> String {
    await recognizer.decode(samples, pinnedLanguage: language)
  }
}

private actor Qwen3ASRRecognizer: OfflineSpeechRecognizer {
  private static let digitalSilenceRMSThreshold: Double = 0.000_05

  private let recognizer: SherpaOnnxOfflineRecognizer
  private let languageBox: Qwen3ASRLanguageBox
  private let observationBox: Qwen3ASRObservationBox

  init(
    modelFiles: Qwen3ASRModelFiles,
    languageBox: Qwen3ASRLanguageBox,
    observationBox: Qwen3ASRObservationBox
  ) {
    self.languageBox = languageBox
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
    decode(samples, pinnedLanguage: nil)
  }

  /// `pinnedLanguage` 非 nil 时(Pro 热备)用它代替语种盒:复合识别器把这一次 decode 读到的会中语种
  /// 原样交过来,两段并发进来时各用各的,不经共享的盒子互相覆盖。
  func decode(_ samples: [Float], pinnedLanguage: MeetingLanguage?) -> String {
    guard !Self.isDigitalSilence(samples) else {
      observationBox.recordDigitalSilenceSkip()
      return ""
    }

    // 每段只读一次,同一 stream 的 option 与观察记录必然是同一个语种。
    let selectedLanguage = pinnedLanguage ?? languageBox.language
    let languageOption = Qwen3ASRTranscriberEngine.languageOption(for: selectedLanguage)
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
        "Qwen3-ASR 语种选项 selected=\(selectedLanguage.rawValue, privacy: .public) hasLanguageOption=\(hasLanguageOption, privacy: .public) languageOption=\(valueDescription, privacy: .public)"
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
    return Qwen3ASRTranscriberEngine.removingProtocolHeaders(
      from: recognizer.getResult(stream: stream).text)
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

/// Safety invariant: `storage` is lock-protected by `lock`; 会中切换(主线程)与解码(识别器 actor)并发读写。
private final class Qwen3ASRLanguageBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: MeetingLanguage = .auto

  var language: MeetingLanguage {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
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

  /// 返回 true 表示首个真实 decode stream 或会中切换后的首个 stream，调用方据此只记一条 notice。
  func recordLanguageObservation(
    _ observation: Qwen3ASRStreamLanguageObservation
  ) -> Bool {
    lock.lock()
    let isNewLanguage = observations.last?.selectedLanguage != observation.selectedLanguage
    observations.append(observation)
    lock.unlock()
    return isNewLanguage
  }

  func recordDigitalSilenceSkip() {
    lock.lock()
    silenceSkipCount += 1
    lock.unlock()
  }
}

/// Pro 开时报告用的状态:接手读回(装好那一刻写一次)与回退序号(失败那一刻写一次,每场至多一次)。
/// 复合识别器写,`liveEngineReport` 任意线程读;只存读回,引擎不因此持有 GPU 会话。
private final class Qwen3ASRProStateBox: Sendable {
  private struct State {
    var readiness: ProGPUReadiness?
    var fallbackCallIndex: Int?
  }

  private let storage = Mutex(State())

  var snapshot: (readiness: ProGPUReadiness?, fallbackCallIndex: Int?) {
    storage.withLock { ($0.readiness, $0.fallbackCallIndex) }
  }

  func recordReady(_ readiness: ProGPUReadiness) {
    storage.withLock { current in
      if current.readiness == nil {
        current.readiness = readiness
      }
    }
  }

  func recordFallback(_ index: Int) {
    storage.withLock { current in
      if current.fallbackCallIndex == nil {
        current.fallbackCallIndex = index
      }
    }
  }
}
