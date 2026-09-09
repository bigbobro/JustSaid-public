import AVFAudio
import AVFoundation
import CoreMedia
import Foundation

public enum IncrementalM4AWriterError: LocalizedError, Sendable {
  case outputAlreadyExists(URL)
  case invalidInputFormat(String)
  case inputFormatMismatch
  case invalidState(String)
  case backpressure
  case coreMedia(operation: String, status: OSStatus)
  case assetWriter(String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .outputAlreadyExists(let url):
      return "录音文件已存在：\(url.path)"
    case .invalidInputFormat(let detail):
      return "不支持的 PCM 输入格式：\(detail)"
    case .inputFormatMismatch:
      return "音频缓冲区格式与录音启动时的格式不一致"
    case .invalidState(let state):
      return "录音写入器当前状态不允许此操作：\(state)"
    case .backpressure:
      return "AAC 写入队列积压过多，已停止接收新的音频缓冲区"
    case .coreMedia(let operation, let status):
      return "\(operation)失败（Core Media \(status)）"
    case .assetWriter(let detail):
      return "AAC 写入失败：\(detail)"
    case .cancelled:
      return "录音写入已取消"
    }
  }
}

public final class IncrementalM4AWriter: @unchecked Sendable {
  private enum State: String {
    case writing
    case finishing
    case finished
    case cancelled
  }

  private typealias FinishContinuation = CheckedContinuation<Void, Error>

  public static let gapThresholdSeconds: TimeInterval = 0.25

  /// 系统 AAC-LC 编码器对低采样率有码率上限,超限时 `startWriting()` 直接失败
  /// 「无法编码媒体」(2026-08-18 AirPods Pro 麦克风 24kHz 单声道 × 128kbps 实录事故)。
  /// 实测包络:每声道约 3×采样率;取不超过它的最大标准档位,总码率封顶 128kbps。
  /// 48kHz 场景(内置麦克风/系统声)仍得 128kbps,既有产物码率不变。
  public static func aacBitRate(sampleRate: Double, channelCount: Int) -> Int {
    let standardRungs = [24_000, 32_000, 48_000, 64_000, 80_000, 96_000, 112_000, 128_000]
    let envelopeCap = min(128_000.0, 3 * sampleRate * Double(channelCount))
    return standardRungs.last { Double($0) <= envelopeCap } ?? standardRungs[0]
  }

  private static let maximumQueuedBufferCount = 512
  private static let preferredSilenceChunkDuration: TimeInterval = 1
  private static let retryDelay: DispatchTimeInterval = .milliseconds(5)

  private let outputURL: URL
  private let inputFormat: AVAudioFormat
  private let expectedFormat: AudioStreamBasicDescription
  private let formatDescription: CMAudioFormatDescription
  private let sampleTimeScale: CMTimeScale
  private let gapThresholdFrames: CMTimeValue
  private let assetWriter: AVAssetWriter
  private let assetWriterInput: AVAssetWriterInput
  private let writerQueue: DispatchQueue
  private let stateLock = NSLock()
  private let lossStatsBox: CaptureLossStatsBox

  private var state = State.writing
  private var nextSampleFrame: CMTimeValue = 0
  private var queuedBufferCount = 0
  private var terminalError: Error?
  /// Guarded by `stateLock`; filled in PTS order by `append` and moved to the writer queue
  /// by `enqueueStagedOnWriterQueue`, so the writer-queue job never captures sample buffers.
  private var stagedBuffers: [CMSampleBuffer] = []

  // Accessed only on writerQueue.
  private var pendingBuffers: [CMSampleBuffer] = []
  private var retryIsScheduled = false
  private var queueIsCancelled = false
  private var finishHasStarted = false
  private var finishContinuation: FinishContinuation?

  public convenience init(outputURL: URL, inputFormat: AVAudioFormat) throws {
    try self.init(
      outputURL: outputURL,
      inputFormat: inputFormat,
      lossStatsBox: CaptureLossStatsBox()
    )
  }

  init(
    outputURL: URL,
    inputFormat: AVAudioFormat,
    lossStatsBox: CaptureLossStatsBox
  ) throws {
    let streamDescription = inputFormat.streamDescription.pointee
    guard streamDescription.mFormatID == kAudioFormatLinearPCM else {
      throw IncrementalM4AWriterError.invalidInputFormat("必须是线性 PCM")
    }
    guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0 else {
      throw IncrementalM4AWriterError.invalidInputFormat("采样率无效")
    }
    guard (1...2).contains(Int(inputFormat.channelCount)) else {
      throw IncrementalM4AWriterError.invalidInputFormat("仅支持单声道或双声道")
    }
    guard streamDescription.mBytesPerFrame > 0 else {
      throw IncrementalM4AWriterError.invalidInputFormat("每帧字节数无效")
    }

    let roundedSampleRate = inputFormat.sampleRate.rounded()
    guard
      abs(roundedSampleRate - inputFormat.sampleRate) < 0.001,
      roundedSampleRate <= Double(CMTimeScale.max)
    else {
      throw IncrementalM4AWriterError.invalidInputFormat("采样率必须是有效整数")
    }

    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: outputURL.path) else {
      throw IncrementalM4AWriterError.outputAlreadyExists(outputURL)
    }
    try fileManager.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var createdFormatDescription: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: inputFormat.streamDescription,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &createdFormatDescription
    )
    guard formatStatus == noErr, let createdFormatDescription else {
      throw IncrementalM4AWriterError.coreMedia(
        operation: "创建 PCM 格式描述",
        status: formatStatus
      )
    }

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: inputFormat.sampleRate,
      AVNumberOfChannelsKey: inputFormat.channelCount,
      AVEncoderBitRateKey: Self.aacBitRate(
        sampleRate: roundedSampleRate,
        channelCount: Int(inputFormat.channelCount)
      ),
    ]
    guard writer.canApply(outputSettings: outputSettings, forMediaType: .audio) else {
      throw IncrementalM4AWriterError.invalidInputFormat("系统 AAC 编码器不接受此格式")
    }

    let writerInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: outputSettings,
      sourceFormatHint: createdFormatDescription
    )
    writerInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(writerInput) else {
      throw IncrementalM4AWriterError.assetWriter("无法添加音频输入")
    }
    writer.add(writerInput)

    let fragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    // Apple documents that movie fragments keep an unexpectedly interrupted
    // partial asset playable through every completed fragment interval:
    // https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval
    writer.movieFragmentInterval = fragmentInterval
    writer.initialMovieFragmentInterval = fragmentInterval

    guard writer.startWriting() else {
      let error = IncrementalM4AWriterError.assetWriter(
        writer.error?.localizedDescription ?? "无法开始写入"
      )
      writer.cancelWriting()
      try? fileManager.removeItem(at: outputURL)
      throw error
    }
    writer.startSession(atSourceTime: .zero)

    self.outputURL = outputURL
    self.inputFormat = inputFormat
    expectedFormat = streamDescription
    formatDescription = createdFormatDescription
    sampleTimeScale = CMTimeScale(roundedSampleRate)
    gapThresholdFrames = CMTimeValue(
      (Self.gapThresholdSeconds * roundedSampleRate).rounded()
    )
    assetWriter = writer
    assetWriterInput = writerInput
    self.lossStatsBox = lossStatsBox
    writerQueue = DispatchQueue(
      label: "com.justsaid.incremental-m4a-writer.\(UUID().uuidString)"
    )
  }

  public var captureLossStats: CaptureLossStats {
    lossStatsBox.snapshot()
  }

  public func append(
    _ buffer: AVAudioPCMBuffer,
    at captureTime: TimeInterval
  ) throws {
    guard buffer.frameLength > 0 else {
      return
    }

    stateLock.lock()
    defer { stateLock.unlock() }

    guard state == .writing else {
      throw IncrementalM4AWriterError.invalidState(state.rawValue)
    }
    if let terminalError {
      throw terminalError
    }
    guard Self.formatsMatch(buffer.format.streamDescription.pointee, expectedFormat) else {
      throw IncrementalM4AWriterError.inputFormatMismatch
    }
    let expectedFrameValue = captureTime * Double(sampleTimeScale)
    guard
      expectedFrameValue.isFinite,
      expectedFrameValue > Double(CMTimeValue.min),
      expectedFrameValue < Double(CMTimeValue.max)
    else {
      throw IncrementalM4AWriterError.invalidState("采集时间无效")
    }
    let expectedFrame = CMTimeValue(expectedFrameValue.rounded())
    let (frameDelta, deltaOverflowed) = expectedFrame.subtractingReportingOverflow(
      nextSampleFrame
    )
    guard !deltaOverflowed else {
      throw IncrementalM4AWriterError.invalidState("音频时间轴溢出")
    }
    if frameDelta < -gapThresholdFrames {
      lossStatsBox.recordOutOfOrderDrop()
      return
    }

    let gapFrames = frameDelta > gapThresholdFrames ? frameDelta : 0
    let silenceBufferCount = Self.silenceBufferCount(
      frameCount: gapFrames,
      sampleRate: sampleTimeScale
    )
    let buffersToQueue = silenceBufferCount + 1
    guard
      buffersToQueue <= Self.maximumQueuedBufferCount,
      queuedBufferCount <= Self.maximumQueuedBufferCount - buffersToQueue
    else {
      lossStatsBox.recordBackpressureDrop()
      throw IncrementalM4AWriterError.backpressure
    }

    let frameCount = CMTimeValue(buffer.frameLength)
    let presentationFrame = gapFrames > 0 ? expectedFrame : nextSampleFrame
    let (nextFrame, overflowed) = presentationFrame.addingReportingOverflow(frameCount)
    guard !overflowed else {
      throw IncrementalM4AWriterError.invalidState("音频时间轴溢出")
    }

    var sampleBuffers = try makeSilenceSampleBuffers(
      frameCount: gapFrames,
      presentationFrame: nextSampleFrame
    )
    let sampleBuffer = try makeCopiedSampleBuffer(
      from: buffer,
      presentationFrame: presentationFrame
    )
    sampleBuffers.append(sampleBuffer)
    nextSampleFrame = nextFrame
    queuedBufferCount += sampleBuffers.count
    lossStatsBox.recordWrittenFrames(UInt64(buffer.frameLength))
    lossStatsBox.recordGapFrames(UInt64(gapFrames))

    // Stage while holding stateLock so buffers keep the same order as their PTS; the
    // writer-queue job takes the staged batch under the same lock.
    stagedBuffers.append(contentsOf: sampleBuffers)
    writerQueue.async { [self] in
      enqueueStagedOnWriterQueue()
    }
  }

  public func finish() async throws {
    try await withCheckedThrowingContinuation { continuation in
      stateLock.lock()
      switch state {
      case .writing:
        state = .finishing
        writerQueue.async { [self] in
          requestFinishOnWriterQueue(continuation)
        }
      case .finished:
        continuation.resume()
      case .finishing:
        continuation.resume(
          throwing: IncrementalM4AWriterError.invalidState(state.rawValue)
        )
      case .cancelled:
        continuation.resume(throwing: IncrementalM4AWriterError.cancelled)
      }
      stateLock.unlock()
    }
  }

  public func cancel() {
    stateLock.lock()
    guard state != .finished, state != .cancelled else {
      stateLock.unlock()
      return
    }
    state = .cancelled
    stagedBuffers.removeAll()
    stateLock.unlock()

    writerQueue.async { [self] in
      queueIsCancelled = true
      pendingBuffers.removeAll()
      resetQueuedBufferCount()
      assetWriter.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      if !finishHasStarted {
        finishContinuation?.resume(throwing: IncrementalM4AWriterError.cancelled)
        finishContinuation = nil
      }
    }
  }

  private func makeCopiedSampleBuffer(
    from buffer: AVAudioPCMBuffer,
    presentationFrame: CMTimeValue
  ) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: sampleTimeScale),
      presentationTimeStamp: CMTime(
        value: presentationFrame,
        timescale: sampleTimeScale
      ),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    var sampleSize = Int(expectedFormat.mBytesPerFrame)
    let isInterleaved =
      expectedFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

    let creationStatus =
      if isInterleaved {
        CMSampleBufferCreate(
          allocator: kCFAllocatorDefault,
          dataBuffer: nil,
          dataReady: false,
          makeDataReadyCallback: nil,
          refcon: nil,
          formatDescription: formatDescription,
          sampleCount: Int(buffer.frameLength),
          sampleTimingEntryCount: 1,
          sampleTimingArray: &timing,
          sampleSizeEntryCount: 1,
          sampleSizeArray: &sampleSize,
          sampleBufferOut: &sampleBuffer
        )
      } else {
        CMSampleBufferCreate(
          allocator: kCFAllocatorDefault,
          dataBuffer: nil,
          dataReady: false,
          makeDataReadyCallback: nil,
          refcon: nil,
          formatDescription: formatDescription,
          sampleCount: Int(buffer.frameLength),
          sampleTimingEntryCount: 1,
          sampleTimingArray: &timing,
          sampleSizeEntryCount: 0,
          sampleSizeArray: nil,
          sampleBufferOut: &sampleBuffer
        )
      }
    guard creationStatus == noErr, let sampleBuffer else {
      throw IncrementalM4AWriterError.coreMedia(
        operation: "创建 PCM 样本",
        status: creationStatus
      )
    }

    // Core Media explicitly copies every AudioBufferList plane into owned memory.
    let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
      sampleBuffer,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      bufferList: buffer.audioBufferList
    )
    guard copyStatus == noErr else {
      throw IncrementalM4AWriterError.coreMedia(
        operation: "复制 PCM 数据",
        status: copyStatus
      )
    }

    let readyStatus = CMSampleBufferSetDataReady(sampleBuffer)
    guard readyStatus == noErr else {
      throw IncrementalM4AWriterError.coreMedia(
        operation: "标记 PCM 样本就绪",
        status: readyStatus
      )
    }
    return sampleBuffer
  }

  private func makeSilenceSampleBuffers(
    frameCount: CMTimeValue,
    presentationFrame: CMTimeValue
  ) throws -> [CMSampleBuffer] {
    guard frameCount > 0 else {
      return []
    }

    let maximumChunkFrames = Self.silenceChunkFrameCount(
      frameCount: frameCount,
      sampleRate: sampleTimeScale
    )
    var remainingFrames = frameCount
    var nextPresentationFrame = presentationFrame
    var sampleBuffers: [CMSampleBuffer] = []
    sampleBuffers.reserveCapacity(
      Self.silenceBufferCount(
        frameCount: frameCount,
        sampleRate: sampleTimeScale
      )
    )

    while remainingFrames > 0 {
      let chunkFrames = min(remainingFrames, maximumChunkFrames)
      guard
        chunkFrames <= CMTimeValue(AVAudioFrameCount.max),
        let silence = AVAudioPCMBuffer(
          pcmFormat: inputFormat,
          frameCapacity: AVAudioFrameCount(chunkFrames)
        )
      else {
        throw IncrementalM4AWriterError.invalidState("无法创建静音缓冲区")
      }
      silence.frameLength = AVAudioFrameCount(chunkFrames)
      for audioBuffer in UnsafeMutableAudioBufferListPointer(
        silence.mutableAudioBufferList
      ) {
        if let data = audioBuffer.mData {
          memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
      }
      sampleBuffers.append(
        try makeCopiedSampleBuffer(
          from: silence,
          presentationFrame: nextPresentationFrame
        )
      )
      remainingFrames -= chunkFrames
      nextPresentationFrame += chunkFrames
    }
    return sampleBuffers
  }

  private func enqueueStagedOnWriterQueue() {
    stateLock.lock()
    let sampleBuffers = stagedBuffers
    stagedBuffers.removeAll()
    stateLock.unlock()
    guard !sampleBuffers.isEmpty else {
      return
    }
    enqueueOnWriterQueue(sampleBuffers)
  }

  private func enqueueOnWriterQueue(_ sampleBuffers: [CMSampleBuffer]) {
    guard !queueIsCancelled else {
      decrementQueuedBufferCount(by: sampleBuffers.count)
      return
    }
    pendingBuffers.append(contentsOf: sampleBuffers)
    drainOnWriterQueue()
  }

  private func drainOnWriterQueue() {
    guard !queueIsCancelled, !finishHasStarted else {
      return
    }
    if let error = currentTerminalError() {
      failOnWriterQueue(error)
      return
    }

    switch assetWriter.status {
    case .writing:
      break
    case .failed:
      failOnWriterQueue(
        IncrementalM4AWriterError.assetWriter(
          assetWriter.error?.localizedDescription ?? "写入器失败"
        )
      )
      return
    case .cancelled:
      failOnWriterQueue(IncrementalM4AWriterError.cancelled)
      return
    default:
      failOnWriterQueue(
        IncrementalM4AWriterError.assetWriter(
          "写入器意外进入状态 \(assetWriter.status.rawValue)"
        )
      )
      return
    }

    while !pendingBuffers.isEmpty, assetWriterInput.isReadyForMoreMediaData {
      let sampleBuffer = pendingBuffers.removeFirst()
      guard assetWriterInput.append(sampleBuffer) else {
        failOnWriterQueue(
          IncrementalM4AWriterError.assetWriter(
            assetWriter.error?.localizedDescription ?? "无法追加 PCM 样本"
          )
        )
        return
      }
      decrementQueuedBufferCount()
    }

    if pendingBuffers.isEmpty {
      if finishContinuation != nil {
        beginFinishOnWriterQueue()
      }
    } else {
      scheduleRetryOnWriterQueue()
    }
  }

  private func scheduleRetryOnWriterQueue() {
    guard !retryIsScheduled else {
      return
    }
    retryIsScheduled = true
    writerQueue.asyncAfter(deadline: .now() + Self.retryDelay) { [self] in
      retryIsScheduled = false
      drainOnWriterQueue()
    }
  }

  private func requestFinishOnWriterQueue(_ continuation: FinishContinuation) {
    guard !queueIsCancelled else {
      continuation.resume(throwing: IncrementalM4AWriterError.cancelled)
      return
    }
    if let error = currentTerminalError() {
      continuation.resume(throwing: error)
      return
    }

    finishContinuation = continuation
    drainOnWriterQueue()
  }

  private func beginFinishOnWriterQueue() {
    guard !finishHasStarted, let continuation = finishContinuation else {
      return
    }
    finishHasStarted = true
    assetWriterInput.markAsFinished()
    assetWriter.finishWriting { [self] in
      writerQueue.async { [self] in
        finishContinuation = nil
        switch assetWriter.status {
        case .completed:
          stateLock.lock()
          let wasCancelled = state == .cancelled
          if !wasCancelled {
            state = .finished
          }
          stateLock.unlock()
          if wasCancelled {
            continuation.resume(throwing: IncrementalM4AWriterError.cancelled)
          } else {
            continuation.resume()
          }
        case .cancelled:
          continuation.resume(throwing: IncrementalM4AWriterError.cancelled)
        default:
          let error = IncrementalM4AWriterError.assetWriter(
            assetWriter.error?.localizedDescription ?? "无法完成写入"
          )
          recordTerminalError(error)
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func failOnWriterQueue(_ error: Error) {
    recordTerminalError(error)
    pendingBuffers.removeAll()
    resetQueuedBufferCount()
    assetWriter.cancelWriting()
    finishContinuation?.resume(throwing: error)
    finishContinuation = nil
  }

  private func recordTerminalError(_ error: Error) {
    stateLock.lock()
    if terminalError == nil {
      terminalError = error
    }
    stateLock.unlock()
  }

  private func currentTerminalError() -> Error? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return terminalError
  }

  private func decrementQueuedBufferCount(by count: Int = 1) {
    stateLock.lock()
    queuedBufferCount = max(0, queuedBufferCount - count)
    stateLock.unlock()
  }

  private func resetQueuedBufferCount() {
    stateLock.lock()
    queuedBufferCount = 0
    stateLock.unlock()
  }

  private static func formatsMatch(
    _ lhs: AudioStreamBasicDescription,
    _ rhs: AudioStreamBasicDescription
  ) -> Bool {
    lhs.mSampleRate == rhs.mSampleRate
      && lhs.mFormatID == rhs.mFormatID
      && lhs.mFormatFlags == rhs.mFormatFlags
      && lhs.mBytesPerPacket == rhs.mBytesPerPacket
      && lhs.mFramesPerPacket == rhs.mFramesPerPacket
      && lhs.mBytesPerFrame == rhs.mBytesPerFrame
      && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
      && lhs.mBitsPerChannel == rhs.mBitsPerChannel
  }

  private static func silenceBufferCount(
    frameCount: CMTimeValue,
    sampleRate: CMTimeScale
  ) -> Int {
    guard frameCount > 0 else {
      return 0
    }
    let maximumChunkFrames = silenceChunkFrameCount(
      frameCount: frameCount,
      sampleRate: sampleRate
    )
    let quotient = frameCount / maximumChunkFrames
    let count = quotient + (frameCount % maximumChunkFrames == 0 ? 0 : 1)
    return Int(count)
  }

  private static func silenceChunkFrameCount(
    frameCount: CMTimeValue,
    sampleRate: CMTimeScale
  ) -> CMTimeValue {
    let preferredChunkFrames = max(
      1,
      CMTimeValue(
        (preferredSilenceChunkDuration * Double(sampleRate)).rounded()
      )
    )
    let maximumSilenceBufferCount = CMTimeValue(maximumQueuedBufferCount - 1)
    let capacityChunkFrames =
      frameCount / maximumSilenceBufferCount
      + (frameCount % maximumSilenceBufferCount == 0 ? 0 : 1)
    return max(preferredChunkFrames, capacityChunkFrames)
  }
}
