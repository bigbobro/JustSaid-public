import AVFoundation
import Foundation

enum PostMeetingStereoAudioComposerError: LocalizedError {
  case cannotCreateFormat
  case renderingFailed(String)

  var errorDescription: String? {
    switch self {
    case .cannotCreateFormat:
      return "立体声上传副本无法创建 16 kHz 双声道格式"
    case .renderingFailed(let detail):
      return "立体声上传副本渲染失败：\(detail)"
    }
  }
}

/// 按配置先生成麦克风 AEC 临时副本，失败改用完整原麦克风；
/// 再把两路输入压成 16 kHz 单声道，从同一零点合成 AAC 立体声。
///
/// 两路均从 frame 0 开始，合成到较长轨道的帧数，较短轨道尾部补静音。
/// 复用单声道压缩器可确保多声道系统母带完整降混；最终 64 kbps
/// 与旧管线两份 32 kbps 上传副本体积同量级。
enum PostMeetingStereoAudioComposer {
  private static let sampleRate = 16_000.0
  private static let bitRate = 64_000
  private static let maximumFrameCount: AVAudioFrameCount = 4_096

  static func makeUploadCopy(
    microphoneURL: URL,
    systemURL: URL,
    echoCancellationEnabled: Bool,
    makeCanceller: @Sendable () throws -> any AcousticEchoCancelling
  ) async throws -> (url: URL, echoCancellation: PostMeetingMicrophoneAEC.Report) {
    var report = PostMeetingMicrophoneAEC.Report()
    var microphoneInput = microphoneURL
    let processedURL = try makeOutputURL().deletingPathExtension().appendingPathExtension("caf")
    defer { try? FileManager.default.removeItem(at: processedURL) }
    if echoCancellationEnabled {
      do {
        try await PostMeetingMicrophoneAEC.makeCopy(
          microphoneURL: microphoneURL, systemURL: systemURL, outputURL: processedURL,
          makeCanceller: makeCanceller, report: &report
        )
        microphoneInput = processedURL
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        // AEC is optional; discard the partial copy and compose from the whole original mic.
        if !report.state.hasPrefix("fallback:") {
          let failure = error as NSError
          report.state = "fallback:aecStepFailed(domain=\(failure.domain),code=\(failure.code))"
        }
      }
    }
    try Task.checkCancellation()
    let microphoneMono = try await PostMeetingAudioCompressor.makeUploadCopy(
      of: microphoneInput
    )
    let systemMono: URL
    do {
      systemMono = try await PostMeetingAudioCompressor.makeUploadCopy(of: systemURL)
    } catch {
      try? FileManager.default.removeItem(at: microphoneMono)
      throw error
    }
    defer {
      try? FileManager.default.removeItem(at: microphoneMono)
      try? FileManager.default.removeItem(at: systemMono)
    }

    let microphoneFile = try AVAudioFile(forReading: microphoneMono)
    let systemFile = try AVAudioFile(forReading: systemMono)
    guard
      let outputFormat = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 2
      )
    else {
      throw PostMeetingStereoAudioComposerError.cannotCreateFormat
    }

    let outputURL = try makeOutputURL()
    do {
      let outputFile = try AVAudioFile(
        forWriting: outputURL,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: 2,
          AVEncoderBitRateKey: bitRate,
        ],
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )
      let totalFrames = max(microphoneFile.length, systemFile.length)
      guard
        totalFrames > 0,
        let microphoneBuffer = AVAudioPCMBuffer(
          pcmFormat: microphoneFile.processingFormat,
          frameCapacity: maximumFrameCount
        ),
        let systemBuffer = AVAudioPCMBuffer(
          pcmFormat: systemFile.processingFormat,
          frameCapacity: maximumFrameCount
        ),
        let stereoBuffer = AVAudioPCMBuffer(
          pcmFormat: outputFormat,
          frameCapacity: maximumFrameCount
        ),
        let stereoChannels = stereoBuffer.floatChannelData
      else {
        throw PostMeetingStereoAudioComposerError.renderingFailed("输入音频为空")
      }

      var writtenFrames: AVAudioFramePosition = 0
      while writtenFrames < totalFrames {
        try Task.checkCancellation()
        let remaining = totalFrames - writtenFrames
        let frameCount = AVAudioFrameCount(
          min(AVAudioFramePosition(maximumFrameCount), remaining)
        )
        microphoneBuffer.frameLength = 0
        systemBuffer.frameLength = 0
        if microphoneFile.framePosition < microphoneFile.length {
          try microphoneFile.read(
            into: microphoneBuffer,
            frameCount: AVAudioFrameCount(
              min(
                AVAudioFramePosition(frameCount),
                microphoneFile.length - microphoneFile.framePosition
              )
            )
          )
        }
        if systemFile.framePosition < systemFile.length {
          try systemFile.read(
            into: systemBuffer,
            frameCount: AVAudioFrameCount(
              min(
                AVAudioFramePosition(frameCount),
                systemFile.length - systemFile.framePosition
              )
            )
          )
        }
        guard
          let microphoneChannels = microphoneBuffer.floatChannelData,
          let systemChannels = systemBuffer.floatChannelData
        else {
          throw PostMeetingStereoAudioComposerError.renderingFailed(
            "单声道上传副本不是 Float32 PCM"
          )
        }

        let byteCount = Int(frameCount) * MemoryLayout<Float>.size
        memset(stereoChannels[0], 0, byteCount)
        memset(stereoChannels[1], 0, byteCount)
        memcpy(
          stereoChannels[0],
          microphoneChannels[0],
          Int(microphoneBuffer.frameLength) * MemoryLayout<Float>.size
        )
        memcpy(
          stereoChannels[1],
          systemChannels[0],
          Int(systemBuffer.frameLength) * MemoryLayout<Float>.size
        )
        stereoBuffer.frameLength = frameCount
        try outputFile.write(from: stereoBuffer)
        writtenFrames += AVAudioFramePosition(frameCount)
      }
      return (outputURL, report)
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
  }

  private static func makeOutputURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JustSaid-PostMeeting-Uploads", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return
      directory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("m4a")
  }
}
