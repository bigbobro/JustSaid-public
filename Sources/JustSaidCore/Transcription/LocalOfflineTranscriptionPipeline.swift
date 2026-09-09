import AVFAudio
import Foundation
import OSLog
import SherpaOnnx

protocol OfflineSpeechRecognizer: Sendable {
  func decode(_ samples: [Float]) async -> String
}

enum LocalOfflineTranscriptionPolicy {
  static let maximumSpeechSegmentDuration: TimeInterval = 30
}

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
  private let sourceStats: [AudioSource: LocalOfflineSourceStatsBox]
  private let stateLock = NSLock()
  private var pipelines: [AudioSource: LocalOfflineSourcePipeline] = [:]
  private var hasStarted = false
  private var hasStopped = false

  var results: AsyncStream<TranscriptSegment> { stream }

  init(engineDisplayName: String, loggerCategory: String) {
    self.engineDisplayName = engineDisplayName
    self.loggerCategory = loggerCategory
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

  func start(
    vadModelURL: URL,
    makeRecognizer: () throws -> any OfflineSpeechRecognizer
  ) throws {
    guard beginStart() else {
      throw TranscriberEngineError.invalidState(
        "\(engineDisplayName) 已启动或停止"
      )
    }

    do {
      let recognizer = try makeRecognizer()
      let vadModel = SileroVADModelFile(url: vadModelURL)
      if vadModel == nil {
        Logger(
          subsystem: "com.justsaid.app",
          category: loggerCategory
        ).warning(
          "Silero VAD 模型缺失：\(vadModelURL.path, privacy: .public)；本场退回 10 秒定长切片"
        )
      }
      let newPipelines = Dictionary(
        uniqueKeysWithValues: AudioSource.allCases.map { source in
          (
            source,
            LocalOfflineSourcePipeline(
              source: source,
              recognizer: recognizer,
              vadModel: vadModel,
              stats: sourceStats[source]!,
              engineDisplayName: engineDisplayName,
              loggerCategory: loggerCategory
            ) { [streamContinuation] segment in
              streamContinuation.yield(segment)
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
    pipeline.feed(
      LocalOfflineTimedInput(
        buffer: try SendablePCMBuffer(copying: pcmBuffer),
        captureTime: captureTime,
        captureDuration: TimeInterval(pcmBuffer.frameLength)
          / max(pcmBuffer.format.sampleRate, 1),
        captureSampleRate: pcmBuffer.format.sampleRate
      )
    )
  }

  func asrAnchorGapFrames(for source: AudioSource) -> UInt64 {
    sourceStats[source]?.anchorGapFrames ?? 0
  }

  func liveEmissionStats(for source: AudioSource) -> LiveEmissionStats {
    sourceStats[source]?.liveEmissionStats ?? LiveEmissionStats()
  }

  func stop() async {
    guard let activePipelines = takePipelinesForStop() else {
      return
    }
    for pipeline in activePipelines {
      await pipeline.stop()
    }
    streamContinuation.finish()
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
    vadModel: SileroVADModelFile?,
    stats: LocalOfflineSourceStatsBox,
    engineDisplayName: String,
    loggerCategory: String,
    emit: @escaping @Sendable (TranscriptSegment) -> Void
  ) {
    // 发射统计在唯一出口计数,覆盖正常与兜底两条路的 partial/final。
    let countingEmit: @Sendable (TranscriptSegment) -> Void = { segment in
      if segment.isFinal {
        stats.recordFinalEmitted()
      } else {
        stats.recordPartialEmitted()
      }
      emit(segment)
    }
    let processor = LocalOfflineSourceProcessor(
      source: source,
      recognizer: recognizer,
      vadModel: vadModel,
      stats: stats,
      engineDisplayName: engineDisplayName,
      loggerCategory: loggerCategory,
      emit: countingEmit
    )
    let rawInputs = AsyncStream.makeStream(
      of: LocalOfflineTimedInput.self,
      bufferingPolicy: .unbounded
    )
    rawInputContinuation = rawInputs.continuation
    let pendingAudioDuration = pendingAudioDuration
    processingTask = Task {
      for await input in rawInputs.stream {
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
  private static let idlePreviewSamples = 10 * windowSamples
  private static let maximumSegmentSamples =
    Int(LocalOfflineTranscriptionPolicy.maximumSpeechSegmentDuration)
    * sampleRate

  private let source: AudioSource
  private let recognizer: any OfflineSpeechRecognizer
  private let stats: LocalOfflineSourceStatsBox
  private let engineDisplayName: String
  private let loggerCategory: String
  private let emit: @Sendable (TranscriptSegment) -> Void
  private let vad: SherpaOnnxVoiceActivityDetectorWrapper?
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

  init(
    source: AudioSource,
    recognizer: any OfflineSpeechRecognizer,
    vadModel: SileroVADModelFile?,
    stats: LocalOfflineSourceStatsBox,
    engineDisplayName: String,
    loggerCategory: String,
    emit: @escaping @Sendable (TranscriptSegment) -> Void
  ) {
    self.source = source
    self.recognizer = recognizer
    self.stats = stats
    self.engineDisplayName = engineDisplayName
    self.loggerCategory = loggerCategory
    self.emit = emit

    if let vadModel {
      let silero = sherpaOnnxSileroVadModelConfig(
        model: vadModel.url.path,
        threshold: 0.5,
        minSilenceDuration: 0.5,
        minSpeechDuration: 0.25,
        windowSize: Self.windowSamples,
        maxSpeechDuration: Float(
          LocalOfflineTranscriptionPolicy.maximumSpeechSegmentDuration
        )
      )
      var config = sherpaOnnxVadModelConfig(
        sileroVad: silero,
        sampleRate: Int32(Self.sampleRate),
        numThreads: 1,
        provider: "cpu",
        debug: 0
      )
      vad = SherpaOnnxVoiceActivityDetectorWrapper(
        config: &config,
        buffer_size_in_seconds: Float(
          LocalOfflineTranscriptionPolicy.maximumSpeechSegmentDuration * 2
        )
      )
    } else {
      vad = nil
    }
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
      emitFallbackFinal(await recognizer.decode(fallbackSamples))
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
    await emitAvailableFinals()
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

    if vad.isSpeechDetected(),
      previewSamples.count >= Self.maximumSegmentSamples
    {
      // sherpa-onnx's max duration raises its threshold to encourage a split;
      // an uninterrupted speaker can still stay above that threshold. Flush is
      // the hard latency ceiling and the next window starts a fresh VAD segment.
      vad.flush()
    }

    if !vad.isEmpty() {
      await emitAvailableFinals()
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
          let text = await recognizer.decode(samples)
          emitPartialIfChanged(text)
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

  private func emitAvailableFinals() async {
    guard let vad else { return }
    while !vad.isEmpty() {
      let segment = vad.front()
      vad.pop()
      let text = await recognizer.decode(segment.samples)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        continue
      }
      let startSample = Int64(segment.start)
      let endSample = startSample + Int64(segment.n)
      emit(
        TranscriptSegment(
          t0: timeline.startTime(for: startSample),
          t1: timeline.endTime(for: endSample),
          text: text,
          isFinal: true,
          source: source
        )
      )
    }
  }

  private func emitPartialIfChanged(_ rawText: String) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text != lastPartialText else {
      return
    }
    lastPartialText = text
    emit(
      TranscriptSegment(
        t0: timeline.startTime(
          for: Int64(acceptedSampleCount - previewSamples.count)
        ),
        t1: timeline.endTime(for: Int64(acceptedSampleCount)),
        text: text,
        isFinal: false,
        source: source
      )
    )
  }

  private func processFallback(
    _ newSamples: [Float],
    pendingAudioDuration: TimeInterval
  ) async {
    fallbackSamples.append(contentsOf: newSamples)

    if fallbackSamples.count >= Self.fallbackFinalSamples {
      emitFallbackFinal(await recognizer.decode(fallbackSamples))
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
        emitFallbackPartialIfChanged(text)
      } else {
        recordSkippedPartialDecode()
      }
      nextPartialCount += Self.partialSamples
    }
  }

  private func emitFallbackPartialIfChanged(_ rawText: String) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text != lastPartialText else {
      return
    }
    lastPartialText = text
    emit(
      TranscriptSegment(
        t0: timeline.startTime(for: fallbackSegmentStartSample),
        t1: timeline.endTime(
          for: fallbackSegmentStartSample + Int64(fallbackSamples.count)
        ),
        text: text,
        isFinal: false,
        source: source
      )
    )
  }

  private func emitFallbackFinal(_ rawText: String) {
    let decoded = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = decoded.isEmpty ? lastPartialText : decoded
    if !text.isEmpty {
      let endSample = fallbackSegmentStartSample + Int64(fallbackSamples.count)
      emit(
        TranscriptSegment(
          t0: timeline.startTime(for: fallbackSegmentStartSample),
          t1: timeline.endTime(for: endSample),
          text: text,
          isFinal: true,
          source: source
        )
      )
      fallbackSegmentStartSample = endSample
    } else {
      fallbackSegmentStartSample += Int64(fallbackSamples.count)
    }
    lastPartialText = ""
  }

  private func flushForDiscontinuity(
    nextSegmentStartSample: Int64
  ) async {
    guard let vad else {
      if fallbackSamples.count >= 4_800 {
        emitFallbackFinal(await recognizer.decode(fallbackSamples))
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
    await emitAvailableFinals()
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
