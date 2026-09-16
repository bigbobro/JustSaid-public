import AVFAudio
import Foundation
import OSLog
import SherpaOnnx
import SherpaOnnxC

protocol OfflineSpeechRecognizer: Sendable {
  func decode(_ samples: [Float]) async -> String
}

/// 本地管线使用的 VAD 操作面。生产实现是 sherpa-onnx Silero VAD;验证可注入脚本化 VAD,
/// 以便在无模型文件的情况下走真实处理器的 VAD 路径。
protocol LocalOfflineVoiceActivityDetector: AnyObject {
  func acceptWaveform(samples: [Float])
  func isSpeechDetected() -> Bool
  func isEmpty() -> Bool
  func frontSegment() -> (start: Int, samples: [Float])
  func pop()
  func flush()
  func clear()
}

extension SherpaOnnxVoiceActivityDetectorWrapper: LocalOfflineVoiceActivityDetector {
  func frontSegment() -> (start: Int, samples: [Float]) {
    let segment = front()
    return (segment.start, segment.samples)
  }
}

typealias LocalOfflineVoiceActivityDetectorFactory =
  @Sendable (AudioSource) -> any LocalOfflineVoiceActivityDetector

enum LocalOfflineTranscriptionPolicy {
  /// 运行时未显式指定时的共享默认值;Qwen 另传自己的常量。
  static let maximumSpeechSegmentDuration: TimeInterval = 30
}

/// 实际送入 sherpa-onnx VAD 构造器的配置与缓冲区时长。
struct LocalOfflineSileroVADConstruction {
  var config: SherpaOnnxVadModelConfig
  let bufferSizeInSeconds: Float

  var maxSpeechDuration: Float { config.silero_vad.max_speech_duration }
}

/// 生产为 sherpa-onnx 构造器;验证替换它读回实际构造参数,不加载模型。
typealias LocalOfflineSileroVADConstructor =
  @Sendable (LocalOfflineSileroVADConstruction) -> any LocalOfflineVoiceActivityDetector

enum LocalOfflineModelPaths {
  static func modelsDirectory(
    fileManager: FileManager = .default
  ) -> URL {
    let applicationSupport =
      fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return
      applicationSupport
      .appendingPathComponent("JustSaid", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
  }

  static func defaultVADModelURL(
    fileManager: FileManager = .default
  ) -> URL {
    modelsDirectory(fileManager: fileManager)
      .appendingPathComponent("Silero-VAD", isDirectory: true)
      .appendingPathComponent("silero_vad.onnx")
  }
}

final class LocalOfflineTranscriptionRuntime: @unchecked Sendable {
  private let engineDisplayName: String
  private let loggerCategory: String
  private let stream: AsyncStream<TranscriptSegment>
  private let streamContinuation: AsyncStream<TranscriptSegment>.Continuation
  private let observationChannel = LiveDecodeObservationChannel()
  /// 两路处理器并发发射;同一次解码的 results 与观察必须成对原子送出,
  /// 否则两个流里的 segment 先后可能不一致(会话按观察流顺序写盘与更新 liveSegments)。
  private let emissionLock = NSLock()
  private let sourceStats: [AudioSource: LocalOfflineSourceStatsBox]
  private let stateLock = NSLock()
  private var pipelines: [AudioSource: LocalOfflineSourcePipeline] = [:]
  private var inputAudioEnds: [AudioSource: TimeInterval] = [:]
  private var hasStarted = false
  private var hasStopped = false

  /// 两路共用;同一值决定 Silero 最长语音、VAD 缓冲区(两倍)与处理器硬切样本数。
  let maximumSpeechSegmentDuration: TimeInterval

  var results: AsyncStream<TranscriptSegment> { stream }

  /// 每次解码一条观察;首次读取才建立,见 `LiveDecodeObservationProviding`。
  var decodeObservations: AsyncStream<LiveDecodeObservation> { observationChannel.observations }

  var hasObservationConsumer: Bool { observationChannel.hasConsumer }

  init(
    engineDisplayName: String,
    loggerCategory: String,
    maximumSpeechSegmentDuration: TimeInterval =
      LocalOfflineTranscriptionPolicy.maximumSpeechSegmentDuration
  ) {
    self.engineDisplayName = engineDisplayName
    self.loggerCategory = loggerCategory
    self.maximumSpeechSegmentDuration = maximumSpeechSegmentDuration
    sourceStats = Dictionary(
      uniqueKeysWithValues: AudioSource.allCases.map { source in
        (source, LocalOfflineSourceStatsBox())
      }
    )
    var capturedContinuation: AsyncStream<TranscriptSegment>.Continuation?
    stream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
      capturedContinuation = continuation
    }
    streamContinuation = capturedContinuation!
  }

  /// `constructSileroVAD` 只供验证替换;生产使用 sherpa-onnx 构造器。
  func start(
    vadModelURL: URL,
    constructSileroVAD: @escaping LocalOfflineSileroVADConstructor = {
      LocalOfflineTranscriptionRuntime.constructSileroVAD($0)
    },
    makeRecognizer: () throws -> any OfflineSpeechRecognizer
  ) throws {
    try start(makeRecognizer: makeRecognizer) { [loggerCategory, maximumSpeechSegmentDuration] in
      guard let vadModel = SileroVADModelFile(url: vadModelURL) else {
        Logger(
          subsystem: "com.justsaid.app",
          category: loggerCategory
        ).warning(
          "Silero VAD 模型缺失：\(vadModelURL.path, privacy: .public)；本场退回 10 秒定长切片"
        )
        return nil
      }
      return { _ in
        LocalOfflineSourceProcessor.makeSileroVAD(
          model: vadModel,
          maximumSpeechSegmentDuration: maximumSpeechSegmentDuration,
          construct: constructSileroVAD
        )
      }
    }
  }

  static func constructSileroVAD(
    _ construction: LocalOfflineSileroVADConstruction
  ) -> any LocalOfflineVoiceActivityDetector {
    var config = construction.config
    return SherpaOnnxVoiceActivityDetectorWrapper(
      config: &config,
      buffer_size_in_seconds: construction.bufferSizeInSeconds
    )
  }

  /// `makeVoiceActivityDetectorFactory` 返回 nil 表示没有 VAD,退回 10 秒定长切片。
  func start(
    makeRecognizer: () throws -> any OfflineSpeechRecognizer,
    makeVoiceActivityDetectorFactory: () -> LocalOfflineVoiceActivityDetectorFactory?
  ) throws {
    guard beginStart() else {
      throw TranscriberEngineError.invalidState(
        "\(engineDisplayName) 已启动或停止"
      )
    }

    do {
      let recognizer = try makeRecognizer()
      let makeVoiceActivityDetector = makeVoiceActivityDetectorFactory()
      let newPipelines = Dictionary(
        uniqueKeysWithValues: AudioSource.allCases.map { source in
          (
            source,
            LocalOfflineSourcePipeline(
              source: source,
              recognizer: recognizer,
              makeVoiceActivityDetector: makeVoiceActivityDetector,
              maximumSpeechSegmentDuration: maximumSpeechSegmentDuration,
              stats: sourceStats[source]!,
              engineDisplayName: engineDisplayName,
              loggerCategory: loggerCategory
            ) { [streamContinuation, observationChannel, emissionLock] observation in
              emissionLock.lock()
              defer { emissionLock.unlock() }
              if let segment = observation.emittedSegment {
                streamContinuation.yield(segment)
              }
              observationChannel.yield(observation)
            }
          )
        }
      )
      storePipelines(newPipelines)
    } catch {
      resetFailedStart()
      throw error
    }
  }

  func feed(
    _ pcmBuffer: AVAudioPCMBuffer,
    source: AudioSource,
    at captureTime: TimeInterval
  ) throws {
    guard let pipeline = activePipeline(for: source) else {
      throw TranscriberEngineError.invalidState(
        "\(engineDisplayName) 尚未启动或已经停止"
      )
    }
    let captureDuration =
      TimeInterval(pcmBuffer.frameLength) / max(pcmBuffer.format.sampleRate, 1)
    let input = LocalOfflineTimedInput(
      buffer: try SendablePCMBuffer(copying: pcmBuffer),
      captureTime: captureTime,
      captureDuration: captureDuration,
      captureSampleRate: pcmBuffer.format.sampleRate
    )
    recordInputAudioEnd(
      captureTime + captureDuration + Self.inputAudioEndResamplingAllowance,
      for: source
    )
    pipeline.feed(input)
  }

  func asrAnchorGapFrames(for source: AudioSource) -> UInt64 {
    sourceStats[source]?.anchorGapFrames ?? 0
  }

  func liveEmissionStats(for source: AudioSource) -> LiveEmissionStats {
    sourceStats[source]?.liveEmissionStats ?? LiveEmissionStats()
  }

  /// 解码时间轴按转换后的 16 kHz 样本数推进,单块可比 captureDuration 多出重采样取整。
  /// `PCMBufferConverter` 每次输出容量为 ceil(输入帧 × 比率) + 32 帧,锚点在每块起点重置,
  /// 所以任一解码终点至多比所在块的 captureTime + captureDuration 晚 33 个 16 kHz 样本。
  static let inputAudioEndResamplingAllowance =
    TimeInterval(33) / TimeInterval(LocalOfflineTimelineTracker.sampleRate)

  /// 已交给该路管线的捕获时间末端(captureTime + 时长 + 重采样取整余量),与解码范围同一时钟;
  /// 只会偏晚,不早于已送入音频产生的任何解码范围终点。
  func inputAudioEnd(for source: AudioSource) -> TimeInterval? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return inputAudioEnds[source]
  }

  func stop() async {
    guard let activePipelines = takePipelinesForStop() else {
      return
    }
    for pipeline in activePipelines {
      await pipeline.stop()
    }
    emissionLock.withLock {
      streamContinuation.finish()
      observationChannel.finish()
    }
  }

  private func recordInputAudioEnd(_ end: TimeInterval, for source: AudioSource) {
    guard end.isFinite else { return }
    stateLock.lock()
    inputAudioEnds[source] = max(inputAudioEnds[source] ?? end, end)
    stateLock.unlock()
  }

  private func beginStart() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !hasStarted, !hasStopped else {
      return false
    }
    hasStarted = true
    return true
  }

  private func storePipelines(
    _ newPipelines: [AudioSource: LocalOfflineSourcePipeline]
  ) {
    stateLock.lock()
    pipelines = newPipelines
    stateLock.unlock()
  }

  private func resetFailedStart() {
    stateLock.lock()
    hasStarted = false
    stateLock.unlock()
  }

  private func activePipeline(
    for source: AudioSource
  ) -> LocalOfflineSourcePipeline? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !hasStopped else {
      return nil
    }
    return pipelines[source]
  }

  private func takePipelinesForStop() -> [LocalOfflineSourcePipeline]? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !hasStopped else {
      return nil
    }
    hasStopped = true
    let activePipelines = Array(pipelines.values)
    pipelines.removeAll()
    return activePipelines
  }
}

private struct SileroVADModelFile: Sendable {
  let url: URL

  init?(
    url: URL,
    fileManager: FileManager = .default
  ) {
    let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
    guard
      fileManager.isReadableFile(atPath: url.path),
      (size?.int64Value ?? 0) > 0
    else {
      return nil
    }
    self.url = url
  }
}

private struct LocalOfflineTimedInput: Sendable {
  let buffer: SendablePCMBuffer
  let captureTime: TimeInterval
  let captureDuration: TimeInterval
  let captureSampleRate: Double
}

private final class LocalOfflineSourceStatsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var asrAnchorGapFrames: UInt64 = 0
  private var asrSkippedDuration: TimeInterval = 0
  private var skippedPartialDecodeCount: UInt64 = 0
  private var partialsEmitted: UInt64 = 0
  private var finalsEmitted: UInt64 = 0

  var anchorGapFrames: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return asrAnchorGapFrames
  }

  var liveEmissionStats: LiveEmissionStats {
    lock.lock()
    defer { lock.unlock() }
    return LiveEmissionStats(
      partialsEmitted: partialsEmitted,
      partialsSkipped: skippedPartialDecodeCount,
      finalsEmitted: finalsEmitted
    )
  }

  func recordPartialEmitted() {
    lock.lock()
    partialsEmitted += 1
    lock.unlock()
  }

  func recordFinalEmitted() {
    lock.lock()
    finalsEmitted += 1
    lock.unlock()
  }

  func recordGap(
    skippedFrames: UInt64,
    skippedDuration: TimeInterval
  ) -> TimeInterval {
    lock.lock()
    asrAnchorGapFrames += skippedFrames
    asrSkippedDuration += skippedDuration
    let cumulativeDuration = asrSkippedDuration
    lock.unlock()
    return cumulativeDuration
  }

  func recordSkippedPartialDecode() -> (
    count: UInt64,
    shouldLog: Bool
  ) {
    lock.lock()
    skippedPartialDecodeCount += 1
    let count = skippedPartialDecodeCount
    lock.unlock()
    return (count, count == 1 || count.isMultiple(of: 20))
  }
}

#if DEBUG
  /// 验证专用取证记录点,只在 debug 构建编译;发布构建里整段不存在,运行时行为不变。
  ///
  /// 存在的唯一理由:把某条观察**实际由哪个分支产生**,以及它在同一单调时钟上的
  /// 出队 → 请求解码 → 原生解码进出 → 发布 各时间点,如实记下来,
  /// 免得验证侧只能事后按送达次序或时间窗口倒猜。不做判定、不分类、不影响调度。
  struct LocalOfflineVerificationTraceRecord: Sendable {
    /// dequeue | decodeRequest | nativeStart | nativeReturn | publish
    let event: String
    /// 产生分支:vadNormal | vadHardClose | vadFinish | vadDiscontinuity | vadPartial
    /// | fallbackFinal | fallbackPartial | sourcePipeline | native
    let origin: String
    let source: String
    /// 同一单调时钟(`ProcessInfo.processInfo.systemUptime`),与验证侧的事件时钟同源。
    let uptime: TimeInterval
    /// publish 事件在该 source 内的发布序号,从 0 起;其他事件为 -1。
    let sequence: Int
    /// dequeue 事件:该块音频的原始 captureTime,用于把单调时钟映射回原始采集时钟。
    let captureTime: TimeInterval?
    let sampleCount: Int?
    let decodedLower: TimeInterval?
    let decodedUpper: TimeInterval?
    /// 终稿在一次 `emitAvailableFinals()` 排空循环里的下标,从 0 起;
    /// 同一窗口可能排出不止一段,所以分支名必须落到每条终稿而不是每次调用。
    let drainIndex: Int?
    /// 本窗是否因为预览达到段长上限而主动 flush(硬切)。
    let flushedForMaxSegment: Bool?
  }

  /// Safety invariant: `enabled` and `records` are lock-protected by `lock`; the box is the only
  /// mutable state shared between the source pipeline task, the processor actor, the recognizer
  /// actor and the verification driver, and every accessor takes `lock` for its whole body.
  final class LocalOfflineVerificationTrace: @unchecked Sendable {
    static let shared = LocalOfflineVerificationTrace()

    private let lock = NSLock()
    private var enabled = false
    private var records: [LocalOfflineVerificationTraceRecord] = []

    /// 只有验证驱动显式打开后才记录;默认关闭,任何未开启的调用只做一次布尔读。
    func enable() {
      lock.lock()
      enabled = true
      records.removeAll()
      lock.unlock()
    }

    var snapshot: [LocalOfflineVerificationTraceRecord] {
      lock.lock()
      defer { lock.unlock() }
      return records
    }

    func record(
      event: String,
      origin: String,
      source: String,
      sequence: Int = -1,
      captureTime: TimeInterval? = nil,
      sampleCount: Int? = nil,
      decodedLower: TimeInterval? = nil,
      decodedUpper: TimeInterval? = nil,
      drainIndex: Int? = nil,
      flushedForMaxSegment: Bool? = nil
    ) {
      let uptime = ProcessInfo.processInfo.systemUptime
      lock.lock()
      if enabled {
        records.append(
          LocalOfflineVerificationTraceRecord(
            event: event, origin: origin, source: source, uptime: uptime, sequence: sequence,
            captureTime: captureTime, sampleCount: sampleCount, decodedLower: decodedLower,
            decodedUpper: decodedUpper, drainIndex: drainIndex,
            flushedForMaxSegment: flushedForMaxSegment))
      }
      lock.unlock()
    }
  }
#endif

private final class LocalOfflinePendingAudioDurationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var pendingDuration: TimeInterval = 0

  func enqueue(duration: TimeInterval) {
    lock.lock()
    pendingDuration += max(duration, 0)
    lock.unlock()
  }

  @discardableResult
  func remove(duration: TimeInterval) -> TimeInterval {
    lock.lock()
    pendingDuration = max(0, pendingDuration - max(duration, 0))
    let remaining = pendingDuration
    lock.unlock()
    return remaining
  }
}

private final class LocalOfflineSourcePipeline: @unchecked Sendable {
  private let rawInputContinuation: AsyncStream<LocalOfflineTimedInput>.Continuation
  private let pendingAudioDuration = LocalOfflinePendingAudioDurationBox()
  private let processingTask: Task<Void, Never>

  init(
    source: AudioSource,
    recognizer: any OfflineSpeechRecognizer,
    makeVoiceActivityDetector: LocalOfflineVoiceActivityDetectorFactory?,
    maximumSpeechSegmentDuration: TimeInterval,
    stats: LocalOfflineSourceStatsBox,
    engineDisplayName: String,
    loggerCategory: String,
    observe: @escaping @Sendable (LiveDecodeObservation) -> Void
  ) {
    // 发射统计在唯一出口计数,覆盖正常与兜底两条路的 partial/final;只数真正发出的 segment。
    let countingObserve: @Sendable (LiveDecodeObservation) -> Void = { observation in
      if let segment = observation.emittedSegment {
        if segment.isFinal {
          stats.recordFinalEmitted()
        } else {
          stats.recordPartialEmitted()
        }
      }
      observe(observation)
    }
    let processor = LocalOfflineSourceProcessor(
      source: source,
      recognizer: recognizer,
      makeVoiceActivityDetector: makeVoiceActivityDetector,
      maximumSpeechSegmentDuration: maximumSpeechSegmentDuration,
      stats: stats,
      engineDisplayName: engineDisplayName,
      loggerCategory: loggerCategory,
      observe: countingObserve
    )
    let rawInputs = AsyncStream.makeStream(
      of: LocalOfflineTimedInput.self,
      bufferingPolicy: .unbounded
    )
    rawInputContinuation = rawInputs.continuation
    let pendingAudioDuration = pendingAudioDuration
    processingTask = Task {
      for await input in rawInputs.stream {
        #if DEBUG
          LocalOfflineVerificationTrace.shared.record(
            event: "dequeue", origin: "sourcePipeline", source: source.rawValue,
            captureTime: input.captureTime)
        #endif
        let remainingDuration = pendingAudioDuration.remove(
          duration: input.captureDuration
        )
        do {
          try await processor.process(
            input,
            pendingAudioDuration: remainingDuration
          )
        } catch {
          Logger(
            subsystem: "com.justsaid.app",
            category: loggerCategory
          ).error(
            "\(engineDisplayName, privacy: .public) 处理音频失败：\(error.localizedDescription, privacy: .public)"
          )
        }
      }
      await processor.finish()
    }
  }

  func feed(_ input: LocalOfflineTimedInput) {
    pendingAudioDuration.enqueue(duration: input.captureDuration)
    switch rawInputContinuation.yield(input) {
    case .enqueued:
      break
    case .dropped(let dropped):
      pendingAudioDuration.remove(duration: dropped.captureDuration)
    case .terminated:
      pendingAudioDuration.remove(duration: input.captureDuration)
    @unknown default:
      pendingAudioDuration.remove(duration: input.captureDuration)
    }
  }

  func stop() async {
    rawInputContinuation.finish()
    await processingTask.value
  }
}

private actor LocalOfflineSourceProcessor {
  private static let sampleRate = 16_000
  private static let windowSamples = 512
  private static let partialSamples = 3 * sampleRate
  private static let fallbackFinalSamples = 10 * sampleRate
  private static let idlePreviewSamples = partialSamples

  private let maximumSegmentSamples: Int
  private let source: AudioSource
  private let recognizer: any OfflineSpeechRecognizer
  private let stats: LocalOfflineSourceStatsBox
  private let engineDisplayName: String
  private let loggerCategory: String
  private let observe: @Sendable (LiveDecodeObservation) -> Void
  private let vad: (any LocalOfflineVoiceActivityDetector)?
  private let converter = PCMBufferConverter(
    outputFormat: AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(sampleRate),
      channels: 1,
      interleaved: false
    )!
  )

  private var pendingSamples: [Float] = []
  private var pendingOffset = 0
  private var previewSamples: [Float] = []
  private var acceptedSampleCount = 0
  private var timeline = LocalOfflineTimelineTracker()
  private var lastPartialText = ""
  private var nextPartialCount = partialSamples
  private var fallbackSamples: [Float] = []
  private var fallbackSegmentStartSample: Int64 = 0
  #if DEBUG
    /// 发布序号只在 debug 下自增,验证侧据此把观察对回产生它的分支;发布构建里不存在。
    private var publishSequence = 0
  #endif

  init(
    source: AudioSource,
    recognizer: any OfflineSpeechRecognizer,
    makeVoiceActivityDetector: LocalOfflineVoiceActivityDetectorFactory?,
    maximumSpeechSegmentDuration: TimeInterval,
    stats: LocalOfflineSourceStatsBox,
    engineDisplayName: String,
    loggerCategory: String,
    observe: @escaping @Sendable (LiveDecodeObservation) -> Void
  ) {
    maximumSegmentSamples = Int(maximumSpeechSegmentDuration) * Self.sampleRate
    self.source = source
    self.recognizer = recognizer
    self.stats = stats
    self.engineDisplayName = engineDisplayName
    self.loggerCategory = loggerCategory
    self.observe = observe
    vad = makeVoiceActivityDetector?(source)
  }

  static func makeSileroVAD(
    model vadModel: SileroVADModelFile,
    maximumSpeechSegmentDuration: TimeInterval,
    construct: LocalOfflineSileroVADConstructor
  ) -> any LocalOfflineVoiceActivityDetector {
    let silero = sherpaOnnxSileroVadModelConfig(
      model: vadModel.url.path,
      threshold: 0.5,
      minSilenceDuration: 0.5,
      minSpeechDuration: 0.25,
      windowSize: Self.windowSamples,
      maxSpeechDuration: Float(maximumSpeechSegmentDuration)
    )
    let config = sherpaOnnxVadModelConfig(
      sileroVad: silero,
      sampleRate: Int32(Self.sampleRate),
      numThreads: 1,
      provider: "cpu",
      debug: 0
    )
    return construct(
      LocalOfflineSileroVADConstruction(
        config: config,
        bufferSizeInSeconds: Float(maximumSpeechSegmentDuration * 2)
      )
    )
  }

  func process(
    _ input: LocalOfflineTimedInput,
    pendingAudioDuration: TimeInterval
  ) async throws {
    let converted = try converter.convert(input.buffer.value)
    guard let channel = converted.floatChannelData?[0] else {
      throw TranscriptionAudioError.conversionFailed(
        "\(engineDisplayName) 需要 Float32 单声道"
      )
    }
    let convertedSamples = Array(
      UnsafeBufferPointer(
        start: channel,
        count: Int(converted.frameLength)
      )
    )

    let gap = timeline.registerBuffer(
      sampleCount: convertedSamples.count,
      captureTime: input.captureTime,
      captureDuration: input.captureDuration
    )
    if gap.skippedDuration > 0 {
      let skippedFrames = UInt64(
        (gap.skippedDuration * max(input.captureSampleRate, 1)).rounded()
      )
      let cumulativeDuration = stats.recordGap(
        skippedFrames: skippedFrames,
        skippedDuration: gap.skippedDuration
      )
      let gapDescription = String(format: "%.3f", gap.skippedDuration)
      let cumulativeDescription = String(format: "%.3f", cumulativeDuration)
      Logger(
        subsystem: "com.justsaid.app",
        category: loggerCategory
      ).info(
        "ASR 时间轴跳变 source=\(self.source.rawValue, privacy: .public) gapSeconds=\(gapDescription, privacy: .public) cumulativeSkippedSeconds=\(cumulativeDescription, privacy: .public)"
      )
      if gap.shouldFlushVAD {
        await flushForDiscontinuity(
          nextSegmentStartSample: gap.bufferStartSampleIndex
        )
      }
    }

    guard vad != nil else {
      await processFallback(
        convertedSamples,
        pendingAudioDuration: pendingAudioDuration
      )
      return
    }

    pendingSamples.append(contentsOf: convertedSamples)

    while pendingSamples.count - pendingOffset >= Self.windowSamples {
      let end = pendingOffset + Self.windowSamples
      let window = Array(pendingSamples[pendingOffset..<end])
      pendingOffset = end
      await accept(
        window,
        pendingAudioDuration: pendingAudioDuration
      )
    }

    if pendingOffset > 0,
      pendingOffset >= 8_192 || pendingOffset * 2 >= pendingSamples.count
    {
      pendingSamples.removeFirst(pendingOffset)
      pendingOffset = 0
    }
  }

  func finish() async {
    guard let vad else {
      guard fallbackSamples.count >= 4_800 else {
        return
      }
      observeFallbackFinal(await recognizer.decode(fallbackSamples))
      return
    }

    if pendingOffset < pendingSamples.count {
      let remainder = Array(pendingSamples[pendingOffset...])
      pendingSamples.removeAll(keepingCapacity: false)
      pendingOffset = 0
      vad.acceptWaveform(samples: remainder)
      acceptedSampleCount += remainder.count
    }
    vad.flush()
    await emitAvailableFinals(origin: "vadFinish")
    vad.clear()
    previewSamples.removeAll(keepingCapacity: false)
    lastPartialText = ""
  }

  private func accept(
    _ window: [Float],
    pendingAudioDuration: TimeInterval
  ) async {
    guard let vad else { return }
    vad.acceptWaveform(samples: window)
    acceptedSampleCount += window.count
    previewSamples.append(contentsOf: window)

    var flushedForMaxSegment = false
    if vad.isSpeechDetected(),
      previewSamples.count >= maximumSegmentSamples
    {
      // sherpa-onnx's max duration raises its threshold to encourage a split;
      // an uninterrupted speaker can still stay above that threshold. Flush is
      // the hard latency ceiling and the next window starts a fresh VAD segment.
      vad.flush()
      flushedForMaxSegment = true
    }

    if !vad.isEmpty() {
      await emitAvailableFinals(
        origin: flushedForMaxSegment ? "vadHardClose" : "vadNormal",
        flushedForMaxSegment: flushedForMaxSegment
      )
      resetPreview()
    } else if vad.isSpeechDetected() {
      if previewSamples.count >= nextPartialCount {
        if LocalOfflineDecodingPolicy.shouldDecode(
          .partial,
          pendingAudioDuration: pendingAudioDuration
        ) {
          let samples = LocalOfflineDecodingPolicy.partialPreviewSamples(
            previewSamples
          )
          #if DEBUG
            traceDecodeRequest(origin: "vadPartial", sampleCount: samples.count)
          #endif
          let text = await recognizer.decode(samples)
          observePartial(text, decodedSampleCount: samples.count)
        } else {
          recordSkippedPartialDecode()
        }
        nextPartialCount += Self.partialSamples
      }
    } else if previewSamples.count > Self.idlePreviewSamples {
      previewSamples.removeFirst(
        previewSamples.count - Self.idlePreviewSamples
      )
    }
  }

  /// `origin` 是调用点实际所处的产生分支;`flushedForMaxSegment` 说明本窗是否刚因段长上限硬切。
  /// 排空循环可能一次交出多段,所以分支与下标都落到每一条终稿上,而不是整次调用。
  private func emitAvailableFinals(
    origin: String = "vadNormal",
    flushedForMaxSegment: Bool = false
  ) async {
    guard let vad else { return }
    var drainIndex = 0
    while !vad.isEmpty() {
      let segment = vad.frontSegment()
      vad.pop()
      #if DEBUG
        traceDecodeRequest(origin: origin, sampleCount: segment.samples.count)
      #endif
      let text = await recognizer.decode(segment.samples)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let startSample = Int64(segment.start)
      let endSample = startSample + Int64(segment.samples.count)
      let t0 = timeline.startTime(for: startSample)
      let t1 = timeline.endTime(for: endSample)
      publish(
        LiveDecodeObservation(
          source: source,
          kind: .final,
          decodedRange: Self.range(t0, t1),
          text: text,
          emittedSegment: text.isEmpty
            ? nil
            : TranscriptSegment(
              t0: t0,
              t1: t1,
              text: text,
              isFinal: true,
              source: source
            )
        ),
        origin: origin,
        drainIndex: drainIndex,
        flushedForMaxSegment: flushedForMaxSegment
      )
      drainIndex += 1
    }
  }

  /// 每次 partial 解码都送出观察;只有文本非空且与上一条不同才附带 segment(旧抑制规则不变)。
  /// 范围起点按实际送入识别器的样本数计算,而 segment.t0 仍是预览起点。
  private func observePartial(_ rawText: String, decodedSampleCount: Int) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let t1 = timeline.endTime(for: Int64(acceptedSampleCount))
    var emittedSegment: TranscriptSegment?
    if !text.isEmpty, text != lastPartialText {
      lastPartialText = text
      emittedSegment = TranscriptSegment(
        t0: timeline.startTime(
          for: Int64(acceptedSampleCount - previewSamples.count)
        ),
        t1: t1,
        text: text,
        isFinal: false,
        source: source
      )
    }
    publish(
      LiveDecodeObservation(
        source: source,
        kind: .partial,
        decodedRange: Self.range(
          timeline.startTime(for: Int64(acceptedSampleCount - decodedSampleCount)),
          t1
        ),
        text: text,
        emittedSegment: emittedSegment
      ),
      origin: "vadPartial"
    )
  }

  /// 观察的唯一出口。debug 下先记下产生分支与发布时刻,再原样交给既有的 `observe`;
  /// 发布构建里它就是一次直接转发,不改变任何顺序或调度。
  private func publish(
    _ observation: LiveDecodeObservation,
    origin: String,
    drainIndex: Int? = nil,
    flushedForMaxSegment: Bool? = nil
  ) {
    #if DEBUG
      LocalOfflineVerificationTrace.shared.record(
        event: "publish", origin: origin, source: source.rawValue, sequence: publishSequence,
        decodedLower: observation.decodedRange.lowerBound,
        decodedUpper: observation.decodedRange.upperBound,
        drainIndex: drainIndex, flushedForMaxSegment: flushedForMaxSegment)
      publishSequence += 1
    #endif
    observe(observation)
  }

  #if DEBUG
    private func traceDecodeRequest(origin: String, sampleCount: Int) {
      LocalOfflineVerificationTrace.shared.record(
        event: "decodeRequest", origin: origin, source: source.rawValue,
        sampleCount: sampleCount)
    }
  #endif

  private static func range(
    _ lower: TimeInterval,
    _ upper: TimeInterval
  ) -> ClosedRange<TimeInterval> {
    lower...max(lower, upper)
  }

  private func processFallback(
    _ newSamples: [Float],
    pendingAudioDuration: TimeInterval
  ) async {
    fallbackSamples.append(contentsOf: newSamples)

    if fallbackSamples.count >= Self.fallbackFinalSamples {
      observeFallbackFinal(await recognizer.decode(fallbackSamples))
      fallbackSamples.removeAll(keepingCapacity: true)
      nextPartialCount = Self.partialSamples
    } else if fallbackSamples.count >= nextPartialCount {
      if LocalOfflineDecodingPolicy.shouldDecode(
        .partial,
        pendingAudioDuration: pendingAudioDuration
      ) {
        let samples = LocalOfflineDecodingPolicy.partialPreviewSamples(
          fallbackSamples
        )
        let text = await recognizer.decode(samples)
        observeFallbackPartial(text, decodedSampleCount: samples.count)
      } else {
        recordSkippedPartialDecode()
      }
      nextPartialCount += Self.partialSamples
    }
  }

  private func observeFallbackPartial(_ rawText: String, decodedSampleCount: Int) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let endSample = fallbackSegmentStartSample + Int64(fallbackSamples.count)
    let t1 = timeline.endTime(for: endSample)
    var emittedSegment: TranscriptSegment?
    if !text.isEmpty, text != lastPartialText {
      lastPartialText = text
      emittedSegment = TranscriptSegment(
        t0: timeline.startTime(for: fallbackSegmentStartSample),
        t1: t1,
        text: text,
        isFinal: false,
        source: source
      )
    }
    publish(
      LiveDecodeObservation(
        source: source,
        kind: .partial,
        decodedRange: Self.range(
          timeline.startTime(for: endSample - Int64(decodedSampleCount)),
          t1
        ),
        text: text,
        emittedSegment: emittedSegment
      ),
      origin: "fallbackPartial"
    )
  }

  /// 观察文本是本次终稿解码的原文;旧路径在解码为空时沿用上一条 partial 发出 segment,保持不变。
  private func observeFallbackFinal(_ rawText: String) {
    let decoded = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = decoded.isEmpty ? lastPartialText : decoded
    let endSample = fallbackSegmentStartSample + Int64(fallbackSamples.count)
    let t0 = timeline.startTime(for: fallbackSegmentStartSample)
    let t1 = timeline.endTime(for: endSample)
    publish(
      LiveDecodeObservation(
        source: source,
        kind: .final,
        decodedRange: Self.range(t0, t1),
        text: decoded,
        emittedSegment: text.isEmpty
          ? nil
          : TranscriptSegment(t0: t0, t1: t1, text: text, isFinal: true, source: source)
      ),
      origin: "fallbackFinal"
    )
    fallbackSegmentStartSample = endSample
    lastPartialText = ""
  }

  private func flushForDiscontinuity(
    nextSegmentStartSample: Int64
  ) async {
    guard let vad else {
      if fallbackSamples.count >= 4_800 {
        observeFallbackFinal(await recognizer.decode(fallbackSamples))
      }
      fallbackSamples.removeAll(keepingCapacity: true)
      fallbackSegmentStartSample = nextSegmentStartSample
      lastPartialText = ""
      nextPartialCount = Self.partialSamples
      return
    }

    if pendingOffset < pendingSamples.count {
      let remainder = Array(pendingSamples[pendingOffset...])
      vad.acceptWaveform(samples: remainder)
      acceptedSampleCount += remainder.count
    }
    pendingSamples.removeAll(keepingCapacity: true)
    pendingOffset = 0
    vad.flush()
    await emitAvailableFinals(origin: "vadDiscontinuity")
    resetPreview()
  }

  private func recordSkippedPartialDecode() {
    let result = stats.recordSkippedPartialDecode()
    guard result.shouldLog else {
      return
    }
    // notice 级才落盘可取证(08-08 调查:info 级导致 8-07 会议无法事后查证)。
    Logger(
      subsystem: "com.justsaid.app",
      category: loggerCategory
    ).notice(
      "\(self.engineDisplayName, privacy: .public) partial 过载降级 source=\(self.source.rawValue, privacy: .public) cumulativeSkippedPartials=\(result.count, privacy: .public)"
    )
  }

  private func resetPreview() {
    previewSamples.removeAll(keepingCapacity: true)
    lastPartialText = ""
    nextPartialCount = Self.partialSamples
  }
}
