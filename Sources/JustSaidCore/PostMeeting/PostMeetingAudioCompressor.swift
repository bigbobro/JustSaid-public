import AVFoundation
import CoreMedia
import Foundation

enum PostMeetingAudioCompressorError: LocalizedError {
  case noAudioTrack
  case cannotAddReaderOutput
  case cannotAddWriterInput
  case cannotStartReading
  case cannotStartWriting
  case readerFailed(String)
  case writerFailed(String)

  var errorDescription: String? {
    switch self {
    case .noAudioTrack:
      return "上传副本转码时没有找到音频轨道"
    case .cannotAddReaderOutput:
      return "上传副本转码无法创建解码输出"
    case .cannotAddWriterInput:
      return "上传副本转码无法创建 AAC 输入"
    case .cannotStartReading:
      return "上传副本转码无法开始读取原录音"
    case .cannotStartWriting:
      return "上传副本转码无法开始写入 AAC"
    case .readerFailed(let detail):
      return "上传副本解码失败：\(detail)"
    case .writerFailed(let detail):
      return "上传副本 AAC 写入失败：\(detail)"
    }
  }
}

enum PostMeetingAudioCompressor {
  private static let sampleRate = 16_000
  private static let bitRate = 32_000

  static func makeUploadCopy(of sourceURL: URL) async throws -> URL {
    let asset = AVURLAsset(url: sourceURL)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw PostMeetingAudioCompressorError.noAudioTrack
    }

    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JustSaid-PostMeeting-Uploads", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    let outputURL =
      temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("m4a")

    var activeReader: AVAssetReader?
    var activeWriter: AVAssetWriter?
    do {
      let reader = try AVAssetReader(asset: asset)
      activeReader = reader
      let readerOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
      )
      readerOutput.alwaysCopiesSampleData = false
      guard reader.canAdd(readerOutput) else {
        throw PostMeetingAudioCompressorError.cannotAddReaderOutput
      }
      reader.add(readerOutput)

      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
      activeWriter = writer
      let writerInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: bitRate,
        ]
      )
      writerInput.expectsMediaDataInRealTime = false
      guard writer.canAdd(writerInput) else {
        throw PostMeetingAudioCompressorError.cannotAddWriterInput
      }
      writer.add(writerInput)
      writer.shouldOptimizeForNetworkUse = true

      guard writer.startWriting() else {
        throw PostMeetingAudioCompressorError.cannotStartWriting
      }
      writer.startSession(atSourceTime: .zero)
      guard reader.startReading() else {
        writer.cancelWriting()
        throw PostMeetingAudioCompressorError.cannotStartReading
      }

      while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
        while !writerInput.isReadyForMoreMediaData {
          try Task.checkCancellation()
          guard writer.status == .writing else {
            throw PostMeetingAudioCompressorError.writerFailed(
              writer.error?.localizedDescription ?? "写入器提前终止"
            )
          }
          try await Task.sleep(for: .milliseconds(2))
        }
        guard writerInput.append(sampleBuffer) else {
          throw PostMeetingAudioCompressorError.writerFailed(
            writer.error?.localizedDescription ?? "无法追加音频样本"
          )
        }
      }
      guard reader.status == .completed else {
        throw PostMeetingAudioCompressorError.readerFailed(
          reader.error?.localizedDescription ?? "读取器未完成"
        )
      }

      writerInput.markAsFinished()
      await withCheckedContinuation { continuation in
        writer.finishWriting {
          continuation.resume()
        }
      }
      guard writer.status == .completed else {
        throw PostMeetingAudioCompressorError.writerFailed(
          writer.error?.localizedDescription ?? "写入器未完成"
        )
      }
      return outputURL
    } catch {
      activeReader?.cancelReading()
      activeWriter?.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
  }
}
