import AVFAudio
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

/// 把两路母带先压成 16 kHz 单声道，再从同一零点离线渲染成 AAC 立体声。
///
/// 两个 player 均从 frame 0 开始；离线渲染固定跑到较长轨道的帧数，较短 player 结束后
/// 引擎自然输出静音。先复用单声道压缩器可确保多声道系统母带完整降混；最终 64 kbps
/// 与旧管线两份 32 kbps 上传副本体积同量级。
enum PostMeetingStereoAudioComposer {
  private static let sampleRate = 16_000.0
  private static let bitRate = 64_000
  private static let maximumFrameCount: AVAudioFrameCount = 4_096

  static func makeUploadCopy(
    microphoneURL: URL,
    systemURL: URL
  ) async throws -> URL {
    let microphoneMono = try await PostMeetingAudioCompressor.makeUploadCopy(
      of: microphoneURL
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
      return outputURL
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
