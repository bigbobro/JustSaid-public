import AVFAudio
import Foundation

public struct AudioFilePlaybackReport: Sendable {
  public let audioDuration: TimeInterval
  public let wallDuration: TimeInterval
  public let bufferCount: Int

  public init(
    audioDuration: TimeInterval,
    wallDuration: TimeInterval,
    bufferCount: Int
  ) {
    self.audioDuration = audioDuration
    self.wallDuration = wallDuration
    self.bufferCount = bufferCount
  }
}

public struct AudioFileRealtimeDriver: Sendable {
  public init() {}

  public func play(
    fileURL: URL,
    into engine: any TranscriberEngine,
    source: AudioSource = .others,
    maximumDuration: TimeInterval? = nil,
    realtimeRate: Double = 1,
    chunkDuration: TimeInterval = 0.32
  ) async throws -> AudioFilePlaybackReport {
    guard realtimeRate > 0, chunkDuration > 0 else {
      throw TranscriberEngineError.invalidState("文件回放速率与分块时长必须大于零")
    }

    let audioFile = try AVAudioFile(forReading: fileURL)
    let format = audioFile.processingFormat
    let requestedFrames = maximumDuration.map {
      AVAudioFramePosition(($0 * format.sampleRate).rounded(.down))
    }
    let maximumFramePosition = min(
      audioFile.length,
      requestedFrames ?? audioFile.length
    )
    let chunkFrames = max(
      AVAudioFrameCount((chunkDuration * format.sampleRate).rounded()),
      1
    )

    let startedAt = Date()
    var processedFrames = AVAudioFramePosition(0)
    var bufferCount = 0

    while processedFrames < maximumFramePosition {
      try Task.checkCancellation()

      let targetWallTime =
        Double(processedFrames) / format.sampleRate / realtimeRate
      let delay = targetWallTime - Date().timeIntervalSince(startedAt)
      if delay > 0 {
        try await Task.sleep(
          nanoseconds: UInt64(delay * 1_000_000_000)
        )
      }

      let remaining = maximumFramePosition - processedFrames
      let framesToRead = AVAudioFrameCount(
        min(AVAudioFramePosition(chunkFrames), remaining)
      )
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: framesToRead
        )
      else {
        throw TranscriptionAudioError.bufferAllocationFailed
      }

      try audioFile.read(into: buffer, frameCount: framesToRead)
      guard buffer.frameLength > 0 else {
        break
      }
      try engine.feed(
        buffer,
        source: source,
        at: Double(processedFrames) / format.sampleRate
      )
      processedFrames += AVAudioFramePosition(buffer.frameLength)
      bufferCount += 1
    }

    return AudioFilePlaybackReport(
      audioDuration: Double(processedFrames) / format.sampleRate,
      wallDuration: Date().timeIntervalSince(startedAt),
      bufferCount: bufferCount
    )
  }
}
