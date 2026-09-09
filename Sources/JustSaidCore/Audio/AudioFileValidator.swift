import AVFoundation
import CoreMedia
import Foundation

public struct AudioFileValidationResult: Sendable {
  public let fileURL: URL
  public let fileExists: Bool
  public let durationSeconds: Double
  public let decodedFrameCount: Int64
  public let isDecodable: Bool
  public let errorDescription: String?

  public var isValid: Bool {
    fileExists
      && durationSeconds.isFinite
      && durationSeconds > 0
      && decodedFrameCount > 0
      && isDecodable
  }
}

public enum AudioFileValidator {
  public static func validate(_ fileURL: URL) async -> AudioFileValidationResult {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return AudioFileValidationResult(
        fileURL: fileURL,
        fileExists: false,
        durationSeconds: 0,
        decodedFrameCount: 0,
        isDecodable: false,
        errorDescription: "文件不存在"
      )
    }

    do {
      let asset = AVURLAsset(url: fileURL)
      let duration = try await asset.load(.duration)
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      guard let audioTrack = tracks.first else {
        throw AudioFileValidationError.noAudioTrack
      }

      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(
        track: audioTrack,
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsNonInterleaved: false,
        ]
      )
      guard reader.canAdd(output) else {
        throw AudioFileValidationError.cannotAddReaderOutput
      }
      reader.add(output)
      guard reader.startReading() else {
        throw reader.error ?? AudioFileValidationError.cannotStartReader
      }

      var decodedFrameCount: Int64 = 0
      while let sampleBuffer = output.copyNextSampleBuffer() {
        decodedFrameCount += Int64(CMSampleBufferGetNumSamples(sampleBuffer))
      }
      guard reader.status == .completed else {
        throw reader.error
          ?? AudioFileValidationError.decodeDidNotComplete(reader.status.rawValue)
      }

      let durationSeconds = CMTimeGetSeconds(duration)
      return AudioFileValidationResult(
        fileURL: fileURL,
        fileExists: true,
        durationSeconds: durationSeconds.isFinite ? durationSeconds : 0,
        decodedFrameCount: decodedFrameCount,
        isDecodable: decodedFrameCount > 0,
        errorDescription: nil
      )
    } catch {
      return AudioFileValidationResult(
        fileURL: fileURL,
        fileExists: true,
        durationSeconds: 0,
        decodedFrameCount: 0,
        isDecodable: false,
        errorDescription: error.localizedDescription
      )
    }
  }
}

private enum AudioFileValidationError: LocalizedError {
  case noAudioTrack
  case cannotAddReaderOutput
  case cannotStartReader
  case decodeDidNotComplete(Int)

  var errorDescription: String? {
    switch self {
    case .noAudioTrack:
      return "文件中没有音频轨道"
    case .cannotAddReaderOutput:
      return "无法创建 PCM 解码输出"
    case .cannotStartReader:
      return "无法开始解码音频文件"
    case .decodeDidNotComplete(let status):
      return "PCM 全量解码未完成（状态 \(status)）"
    }
  }
}
