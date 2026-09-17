import AudioToolbox
import Foundation

/// Direct mother-track decoding; no intermediate AAC or whole-file PCM allocation.
final class PostMeetingEchoPCMReader {
  private var file: ExtAudioFileRef?
  let estimatedSamples: Int64

  init(url: URL) throws {
    var opened: ExtAudioFileRef?
    try check(ExtAudioFileOpenURL(url as CFURL, &opened))
    guard let opened else { throw PostMeetingEchoReductionError.invalidAudio }
    file = opened
    do {
      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      try check(
        ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileDataFormat, &size, &format))
      guard format.mSampleRate.isFinite, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
        throw PostMeetingEchoReductionError.invalidAudio
      }
      var frames: Int64 = 0
      size = UInt32(MemoryLayout<Int64>.size)
      try check(
        ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileLengthFrames, &size, &frames))
      estimatedSamples = Int64(ceil(Double(frames) * 16_000 / format.mSampleRate))
      var client = AudioStreamBasicDescription(
        mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
      try check(
        ExtAudioFileSetProperty(
          opened, kExtAudioFileProperty_ClientDataFormat,
          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
    } catch {
      ExtAudioFileDispose(opened)
      file = nil
      throw error
    }
  }

  deinit { if let file { ExtAudioFileDispose(file) } }

  func read(_ count: Int = 160) throws -> [Float] {
    guard let file else { throw PostMeetingEchoReductionError.invalidAudio }
    var samples = [Float](repeating: 0, count: count)
    var frames = UInt32(count)
    try samples.withUnsafeMutableBytes { bytes in
      var list = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
      try check(ExtAudioFileRead(file, &frames, &list))
    }
    guard frames <= count else { throw PostMeetingEchoReductionError.invalidAudio }
    samples.removeLast(count - Int(frames))
    guard samples.allSatisfy(\.isFinite) else { throw PostMeetingEchoReductionError.invalidAudio }
    return samples
  }
}

private func check(_ status: OSStatus) throws {
  guard status == noErr else { throw PostMeetingEchoReductionError.invalidAudio }
}

/// A decoded sample spans [n / 16000, (n + 1) / 16000). Mask every sample
/// intersecting a persisted pause, including fractional boundaries and open tails.
struct PostMeetingEchoPauseMask {
  private let ranges: [Range<Int64>]

  init(_ intervals: [MicrophonePauseInterval]) throws {
    // The WAV writer rejects longer output; clipping here also avoids integer overflow
    // for finite metadata times beyond the end of any supported recording.
    let maximumSample = Int64((UInt32.max - 36) / 2)
    var ranges: [Range<Int64>] = []
    for interval in intervals {
      guard interval.start.isFinite, interval.start >= 0,
        interval.end.map({ $0.isFinite && $0 >= interval.start }) ?? true
      else { throw PostMeetingEchoReductionError.invalidAudio }
      if interval.end == interval.start { continue }
      let first = Int64(floor(min(interval.start * 16_000, Double(maximumSample))))
      let last =
        interval.end.map {
          Int64(ceil(min($0 * 16_000, Double(maximumSample))))
        } ?? maximumSample
      if first < last { ranges.append(first..<last) }
    }
    self.ranges = ranges
  }

  func apply(to samples: inout [Int16], firstSample: Int64, sampleCount: Int) {
    let endSample = firstSample + Int64(sampleCount)
    for range in ranges {
      let first = max(firstSample, range.lowerBound)
      let last = min(endSample, range.upperBound)
      guard first < last else { continue }
      for index in Int(first - firstSample)..<Int(last - firstSample) { samples[index] = 0 }
    }
  }
}
