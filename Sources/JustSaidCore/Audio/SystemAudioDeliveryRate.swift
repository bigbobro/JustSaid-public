import AVFAudio
import Foundation

/// Measures the rate at which one system-audio activation really delivers frames,
/// against the host clock its timestamps come from.
///
/// Core Audio can keep reporting 48 kHz for the tap and the aggregate's selected
/// stream while the aggregate runs on the output device's 44.1 kHz clock. A WeChat
/// call recorded on 2026-10-16 delivered 44,100 frames per host second for 22 minutes
/// under a 48 kHz label: the file played about 8.8% fast and the writer inserted
/// about 21 ms of zeros every 0.27 s to stay on real time, so the far side no longer
/// matched its echo in the microphone. The declared rate is therefore trusted only
/// while this measurement agrees with it.
///
/// Safety invariant: queue-confined; only the activation's serial callback queue calls it.
final class SystemAudioDeliveryRateMonitor: @unchecked Sendable {
  static let standardSampleRates: [Double] = [
    8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000,
    88_200, 96_000, 176_400, 192_000,
  ]
  /// Block pairs pooled per verdict. 0.5 s holds about 43 pairs of 512-frame blocks.
  static let windowSeconds: TimeInterval = 0.5
  /// Consecutive verdicts that must name the same new rate before it is adopted, so a
  /// single disturbed window cannot change how the rest of the recording is labeled.
  static let requiredAgreements = 2
  /// Relative distance within which a measurement names a standard rate.
  static let snapTolerance = 0.01

  let declaredSampleRate: Double
  private(set) var deliveredSampleRate: Double
  private var previousBlock: (captureTime: TimeInterval, frames: Double)?
  private var pairRates: [Double] = []
  private var pooledSeconds: TimeInterval = 0
  private var candidate: Double?
  private var agreements = 0

  init(declaredSampleRate: Double) {
    self.declaredSampleRate = declaredSampleRate
    deliveredSampleRate = declaredSampleRate
  }

  /// Feeds one delivered block in IO order. Returns the newly adopted delivered rate
  /// when the verdict changes, otherwise nil.
  func observe(captureTime: TimeInterval, frameCount: AVAudioFrameCount) -> Double? {
    let frames = Double(frameCount)
    defer { previousBlock = (captureTime, frames) }
    guard let previous = previousBlock, previous.frames > 0, frames > 0 else {
      return nil
    }
    let elapsed = captureTime - previous.captureTime
    let declaredDuration = previous.frames / declaredSampleRate
    // A skipped cycle, a host clock jump or a restart is not a rate. The bounds still
    // admit every standard rate from a quarter to four times the declared one.
    guard elapsed > declaredDuration * 0.25, elapsed < declaredDuration * 4 else {
      discardWindow()
      return nil
    }
    pairRates.append(previous.frames / elapsed)
    pooledSeconds += elapsed
    guard pooledSeconds >= Self.windowSeconds else {
      return nil
    }
    // The median ignores the odd late callback that a mean would turn into a new rate.
    // Sorting in place keeps the IO thread free of allocation once the window has grown.
    pairRates.sort()
    let measured = pairRates[pairRates.count / 2]
    discardWindow()
    guard
      let snapped = Self.standardRate(near: measured),
      !Self.sameRate(snapped, deliveredSampleRate)
    else {
      candidate = nil
      agreements = 0
      return nil
    }
    if let candidate, Self.sameRate(candidate, snapped) {
      agreements += 1
    } else {
      candidate = snapped
      agreements = 1
    }
    guard agreements >= Self.requiredAgreements else {
      return nil
    }
    deliveredSampleRate = snapped
    candidate = nil
    agreements = 0
    return snapped
  }

  /// A block that could not be read breaks the measurement chain.
  func interrupt() {
    previousBlock = nil
    discardWindow()
  }

  static func standardRate(near measured: Double) -> Double? {
    guard measured.isFinite, measured > 0 else { return nil }
    let nearest = standardSampleRates.min { abs($0 - measured) < abs($1 - measured) }
    guard let nearest, abs(nearest - measured) / nearest <= snapTolerance else {
      return nil
    }
    return nearest
  }

  static func sameRate(_ lhs: Double, _ rhs: Double) -> Bool {
    abs(lhs - rhs) <= max(lhs, rhs) * snapTolerance
  }

  private func discardWindow() {
    pairRates.removeAll(keepingCapacity: true)
    pooledSeconds = 0
  }
}

/// Restores the real speed of blocks whose declared rate is wrong. The samples keep
/// their bytes, are relabeled with the delivered rate and are converted back into the
/// writer's fixed format, so the file and every live consumer keep one format while
/// the sound keeps its real speed.
///
/// Safety invariant: queue-confined; only the activation's serial processing queue calls it.
final class SystemAudioRateCorrector: @unchecked Sendable {
  let outputFormat: AVAudioFormat
  private var converter: PCMBufferConverter?

  init(outputFormat: AVAudioFormat) {
    self.outputFormat = outputFormat
  }

  /// Returns the block in `outputFormat`. It can hold fewer frames than the input
  /// implies, or none: the converter's filter keeps a little look-ahead and releases it
  /// with the next block.
  func correct(
    _ buffer: AVAudioPCMBuffer,
    deliveredSampleRate: Double
  ) throws -> AVAudioPCMBuffer {
    let relabeled = try Self.relabel(buffer, sampleRate: deliveredSampleRate)
    let converter = converter ?? PCMBufferConverter(outputFormat: outputFormat)
    self.converter = converter
    return try converter.convert(relabeled)
  }

  /// Forget converter history once blocks stop needing correction, so a later
  /// correction does not replay stale samples across the gap.
  func reset() {
    converter = nil
  }

  private static func relabel(
    _ buffer: AVAudioPCMBuffer,
    sampleRate: Double
  ) throws -> AVAudioPCMBuffer {
    var description = buffer.format.streamDescription.pointee
    description.mSampleRate = sampleRate
    let format: AVAudioFormat? =
      if let layout = buffer.format.channelLayout {
        AVAudioFormat(streamDescription: &description, channelLayout: layout)
      } else {
        AVAudioFormat(streamDescription: &description)
      }
    guard
      let format,
      let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength)
    else {
      throw SystemAudioRateCorrectionError.relabelFailed("无法分配缓冲区")
    }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard source.count == destination.count else {
      throw SystemAudioRateCorrectionError.relabelFailed("缓冲区数量不一致")
    }
    for index in 0..<source.count {
      let byteCount = Int(source[index].mDataByteSize)
      guard
        byteCount <= Int(destination[index].mDataByteSize),
        let from = source[index].mData,
        let to = destination[index].mData
      else {
        throw SystemAudioRateCorrectionError.relabelFailed("缓冲区大小不一致")
      }
      memcpy(to, from, byteCount)
      destination[index].mDataByteSize = UInt32(byteCount)
    }
    return copy
  }
}

enum SystemAudioRateCorrectionError: LocalizedError {
  case relabelFailed(String)

  var errorDescription: String? {
    switch self {
    case .relabelFailed(let detail):
      return "系统音频按实测采样率改标失败：\(detail)"
    }
  }
}
