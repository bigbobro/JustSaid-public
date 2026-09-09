#if canImport(Speech)
  import AVFAudio
  import CoreMedia
  import Foundation
  import OSLog
  import Speech

  @available(macOS 26.0, *)
  public final class SpeechAnalyzerTranscriberEngine: TranscriberEngine,
    @unchecked Sendable
  {
    private let stream: AsyncStream<TranscriptSegment>
    private let streamContinuation: AsyncStream<TranscriptSegment>.Continuation
    private let stateLock = NSLock()
    private var pipelines: [AudioSource: SpeechAnalyzerSourcePipeline] = [:]
    private var hasStarted = false
    private var hasStopped = false

    public var results: AsyncStream<TranscriptSegment> { stream }

    public init() {
      var capturedContinuation: AsyncStream<TranscriptSegment>.Continuation?
      stream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
        capturedContinuation = continuation
      }
      streamContinuation = capturedContinuation!
    }

    public func start(language: MeetingLanguage) async throws {
      guard beginStart() else {
        throw TranscriberEngineError.invalidState("SpeechAnalyzer 已启动或停止")
      }

      // Apple 引擎按 locale 走,行为与 08-10 之前逐字节一致(`.auto` 仍落在 zh-CN)。
      let localeIdentifier = language.transcriptionLocaleIdentifier
      var newPipelines: [AudioSource: SpeechAnalyzerSourcePipeline] = [:]
      do {
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard
          SpeechTranscriber.isAvailable,
          let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
          )
        else {
          throw TranscriberEngineError.unsupportedLocale(localeIdentifier)
        }

        let transcribers = Dictionary(
          uniqueKeysWithValues: AudioSource.allCases.map { source in
            (
              source,
              SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange]
              )
            )
          }
        )
        try await installAssetsIfNeeded(
          locale: locale,
          modules: Array(transcribers.values)
        )

        for source in AudioSource.allCases {
          guard let transcriber = transcribers[source] else {
            continue
          }
          let pipeline = try await SpeechAnalyzerSourcePipeline(
            source: source,
            transcriber: transcriber
          ) { [streamContinuation] segment in
            streamContinuation.yield(segment)
          }
          newPipelines[source] = pipeline
        }

        storePipelines(newPipelines)
      } catch {
        for pipeline in newPipelines.values {
          await pipeline.stop()
        }
        resetFailedStart()
        throw error
      }
    }

    public func feed(
      _ pcmBuffer: AVAudioPCMBuffer,
      source: AudioSource,
      at _: TimeInterval
    ) throws {
      guard let pipeline = activePipeline(for: source) else {
        throw TranscriberEngineError.invalidState("SpeechAnalyzer 尚未启动或已经停止")
      }
      let copiedBuffer = try SendablePCMBuffer(copying: pcmBuffer)
      pipeline.feed(copiedBuffer)
    }

    public func stop() async {
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
      _ newPipelines: [AudioSource: SpeechAnalyzerSourcePipeline]
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
    ) -> SpeechAnalyzerSourcePipeline? {
      stateLock.lock()
      defer { stateLock.unlock() }
      guard !hasStopped else {
        return nil
      }
      return pipelines[source]
    }

    private func takePipelinesForStop() -> [SpeechAnalyzerSourcePipeline]? {
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

    private func installAssetsIfNeeded(
      locale: Locale,
      modules: [SpeechTranscriber]
    ) async throws {
      let localeID = locale.identifier(.bcp47)
      let installedLocales = await SpeechTranscriber.installedLocales
      guard
        !installedLocales.contains(where: {
          $0.identifier(.bcp47) == localeID
        })
      else {
        return
      }

      if let request = try await AssetInventory.assetInstallationRequest(
        supporting: modules
      ) {
        try await request.downloadAndInstall()
      }
    }
  }

  @available(macOS 26.0, *)
  private final class SpeechAnalyzerSourcePipeline: @unchecked Sendable {
    private let logger = Logger(
      subsystem: "com.justsaid.app",
      category: "SpeechAnalyzerTranscriber"
    )
    private let analyzer: SpeechAnalyzer
    private let rawInputContinuation: AsyncStream<SendablePCMBuffer>.Continuation
    private let processingTask: Task<Void, Never>
    private let resultsTask: Task<Void, Never>

    init(
      source: AudioSource,
      transcriber: SpeechTranscriber,
      emit: @escaping @Sendable (TranscriptSegment) -> Void
    ) async throws {
      guard
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
          compatibleWith: [transcriber]
        )
      else {
        throw TranscriberEngineError.audioFormatUnavailable
      }

      let analyzer = SpeechAnalyzer(
        modules: [transcriber],
        options: SpeechAnalyzer.Options(
          priority: .userInitiated,
          modelRetention: .lingering
        )
      )
      try await analyzer.prepareToAnalyze(in: analyzerFormat)

      let analyzerInputs = AsyncStream.makeStream(of: AnalyzerInput.self)
      try await analyzer.start(inputSequence: analyzerInputs.stream)

      let rawInputs = AsyncStream.makeStream(
        of: SendablePCMBuffer.self,
        bufferingPolicy: .bufferingNewest(128)
      )
      self.analyzer = analyzer
      rawInputContinuation = rawInputs.continuation

      let converter = PCMBufferConverter(outputFormat: analyzerFormat)
      processingTask = Task {
        do {
          for await input in rawInputs.stream {
            let converted = try converter.convert(input.value)
            analyzerInputs.continuation.yield(
              AnalyzerInput(buffer: converted)
            )
          }
        } catch {
          Logger(
            subsystem: "com.justsaid.app",
            category: "SpeechAnalyzerTranscriber"
          ).error("SpeechAnalyzer 音频输入失败：\(error.localizedDescription, privacy: .public)")
        }
        analyzerInputs.continuation.finish()
      }

      resultsTask = Task {
        do {
          for try await result in transcriber.results {
            let text = String(result.text.characters)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
              continue
            }

            let start = max(0, result.range.start.seconds)
            let rawEnd = result.range.end.seconds
            let end = rawEnd.isFinite ? max(start, rawEnd) : start
            emit(
              TranscriptSegment(
                t0: start,
                t1: end,
                text: text,
                isFinal: result.isFinal,
                source: source
              )
            )
          }
        } catch is CancellationError {
          return
        } catch {
          Logger(
            subsystem: "com.justsaid.app",
            category: "SpeechAnalyzerTranscriber"
          ).error("SpeechAnalyzer 结果流失败：\(error.localizedDescription, privacy: .public)")
        }
      }
    }

    func feed(_ buffer: SendablePCMBuffer) {
      rawInputContinuation.yield(buffer)
    }

    func stop() async {
      rawInputContinuation.finish()
      await processingTask.value
      do {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask.value
      } catch {
        logger.error("SpeechAnalyzer 收尾失败：\(error.localizedDescription, privacy: .public)")
        await analyzer.cancelAndFinishNow()
        resultsTask.cancel()
      }
    }
  }
#endif
