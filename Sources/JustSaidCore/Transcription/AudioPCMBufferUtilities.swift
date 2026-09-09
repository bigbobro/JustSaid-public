import AVFAudio
import AudioToolbox
import Foundation
import Synchronization

enum TranscriptionAudioError: LocalizedError {
  case bufferAllocationFailed
  case converterUnavailable
  case conversionFailed(String)

  var errorDescription: String? {
    switch self {
    case .bufferAllocationFailed:
      return "无法为速记复制音频缓冲区"
    case .converterUnavailable:
      return "无法创建速记音频格式转换器"
    case .conversionFailed(let detail):
      return "速记音频格式转换失败：\(detail)"
    }
  }
}

final class SendablePCMBuffer: @unchecked Sendable {
  let value: AVAudioPCMBuffer

  init(copying buffer: AVAudioPCMBuffer) throws {
    guard
      let copy = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: buffer.frameLength
      )
    else {
      throw TranscriptionAudioError.bufferAllocationFailed
    }

    copy.frameLength = buffer.frameLength
    let sourceBuffers = UnsafeMutableAudioBufferListPointer(
      buffer.mutableAudioBufferList
    )
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(
      copy.mutableAudioBufferList
    )
    guard sourceBuffers.count == destinationBuffers.count else {
      throw TranscriptionAudioError.bufferAllocationFailed
    }

    for index in sourceBuffers.indices {
      let source = sourceBuffers[index]
      var destination = destinationBuffers[index]
      let byteCount = Int(source.mDataByteSize)
      guard
        let sourceData = source.mData,
        let destinationData = destination.mData,
        byteCount <= Int(destination.mDataByteSize)
      else {
        throw TranscriptionAudioError.bufferAllocationFailed
      }
      memcpy(destinationData, sourceData, byteCount)
      destination.mDataByteSize = source.mDataByteSize
      destinationBuffers[index] = destination
    }

    value = copy
  }
}

final class PCMBufferConverter: @unchecked Sendable {
  let outputFormat: AVAudioFormat

  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?

  init(outputFormat: AVAudioFormat) {
    self.outputFormat = outputFormat
  }

  func convert(_ input: sending AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    if input.format == outputFormat {
      return try SendablePCMBuffer(copying: input).value
    }

    if inputFormat != input.format {
      inputFormat = input.format
      converter = AVAudioConverter(from: input.format, to: outputFormat)
    }
    guard let converter else {
      throw TranscriptionAudioError.converterUnavailable
    }

    let rateRatio = outputFormat.sampleRate / input.format.sampleRate
    let frameCapacity = AVAudioFrameCount(
      ceil(Double(input.frameLength) * rateRatio) + 32
    )
    guard
      let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: max(frameCapacity, 1)
      )
    else {
      throw TranscriptionAudioError.bufferAllocationFailed
    }

    // The converter pulls its input synchronously through a Sendable block. The caller hands the
    // buffer over (`sending`), it waits in a mutex, and the block takes it out exactly once, so the
    // block owns nothing it did not take and a second pull reports no data.
    let pendingInput = Mutex<AVAudioPCMBuffer?>(input)
    var conversionError: NSError?
    let status = converter.convert(
      to: output,
      error: &conversionError
    ) { _, inputStatus in
      let buffer = pendingInput.withLock { pending in
        defer { pending = nil }
        return pending
      }
      guard let buffer else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      inputStatus.pointee = .haveData
      return buffer
    }

    if status == .error || conversionError != nil {
      throw TranscriptionAudioError.conversionFailed(
        conversionError?.localizedDescription ?? "未知错误"
      )
    }
    return output
  }
}
