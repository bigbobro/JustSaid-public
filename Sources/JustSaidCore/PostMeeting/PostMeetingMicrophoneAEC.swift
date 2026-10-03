import AVFoundation
import CoreMedia
import Foundation

/// One serial offline stream, one decode per track, bounded by AVAssetReader buffers.
enum PostMeetingMicrophoneAEC {
  static let sampleRate = 16_000
  static let frameSamples = sampleRate / 100
  // Fixed lead for old/new writer geometries; see task research/aec-lead-probe.md.
  static let referenceLeadMilliseconds = 250

  struct Report {
    var state = "disabled"
    var statistics: AcousticEchoCancellationStatistics?
    var elapsedSeconds = 0.0

    var detail: String {
      func label<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? "unknown" }
      return [
        "status=\(state)", "referenceLeadMS=\(referenceLeadMilliseconds)",
        "microphoneGain=1", "referenceGain=1",
        "processedFrames=\(label(statistics?.processedFrames))",
        "outOfRangeFrames=\(label(statistics?.outOfRangeFrames))",
        "outOfRangeRatio=\(label(outOfRangeRatio))",
        "erlDB=\(label(statistics?.echoReturnLossDB))",
        "erleDB=\(label(statistics?.echoReturnLossEnhancementDB))",
        "delayMS=\(label(statistics?.estimatedDelayMilliseconds))",
        String(format: "elapsedSeconds=%.6f", elapsedSeconds),
      ].joined(separator: "; ")
    }

    private var outOfRangeRatio: Double? {
      guard let statistics else { return nil }
      let total = statistics.processedFrames + statistics.outOfRangeFrames
      return total == 0 ? 0 : Double(statistics.outOfRangeFrames) / Double(total)
    }
  }

  private enum StepError: Error { case degraded, invalidPCM, readerFailed }

  static func makeCopy(
    microphoneURL: URL, systemURL: URL, outputURL: URL,
    makeCanceller: @Sendable () throws -> any AcousticEchoCancelling,
    report: inout Report
  ) async throws {
    let started = Date()
    defer { report.elapsedSeconds = Date().timeIntervalSince(started) }
    try Task.checkCancellation()
    let canceller = try makeCanceller()
    report.state = "fallback:\(String(describing: canceller.status))"
    guard canceller.status == .active else { throw StepError.degraded }
    report.state = "processing"
    let mic = try await Reader(url: microphoneURL)
    let reference = try await Reader(url: systemURL)
    _ = try reference.read(upTo: sampleRate * referenceLeadMilliseconds / 1000)
    let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
    let output = try AVAudioFile(forWriting: outputURL, settings: format.settings)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(frameSamples))!
    var frames = 0
    while true {
      try Task.checkCancellation()
      var capture = try mic.read(upTo: frameSamples)
      let validSamples = capture.count
      if validSamples == 0 { break }
      capture += repeatElement(0, count: frameSamples - capture.count)
      var render = try reference.read(upTo: frameSamples)
      render += repeatElement(0, count: frameSamples - render.count)
      // Raw amplitudes: #153 bypasses out-of-range pairs without disabling AEC.
      // Whole-track attenuation reduces cancellation; see aec-scaling-ablation.md.
      let processed = canceller.process(capture: capture, reference: render)
      guard canceller.status == .active else {
        report.state = "fallback:\(String(describing: canceller.status))"
        throw StepError.degraded
      }
      guard processed.count == frameSamples, processed.allSatisfy(\.isFinite) else {
        throw StepError.invalidPCM
      }
      for index in 0..<validSamples {
        buffer.floatChannelData![0][index] = processed[index]
      }
      buffer.frameLength = AVAudioFrameCount(validSamples)
      try output.write(from: buffer)
      frames += 1
      if frames % 1000 == 0 { try snapshot(canceller, report: &report) }
    }
    try snapshot(canceller, report: &report)
    report.state = "processed"
  }

  private static func snapshot(_ canceller: any AcousticEchoCancelling, report: inout Report) throws
  {
    if let stats = canceller.statistics { report.statistics = stats }
    guard canceller.status == .active else {
      report.state = "fallback:\(String(describing: canceller.status))"
      throw StepError.degraded
    }
  }

  /// Resampling and downmixing happen in the decoder, before 10 ms framing.
  private final class Reader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var cached: [Float] = []
    private var offset = 0

    init(url: URL) async throws {
      let asset = AVURLAsset(url: url)
      guard let track = try await PostMeetingAudioCompressor.firstAudioTrack(of: asset) else {
        throw StepError.readerFailed
      }
      reader = try AVAssetReader(asset: asset)
      output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ])
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { throw StepError.readerFailed }
      reader.add(output)
      guard reader.startReading() else { throw StepError.readerFailed }
    }

    deinit { if reader.status == .reading { reader.cancelReading() } }

    func read(upTo count: Int) throws -> [Float] {
      var result: [Float] = []
      result.reserveCapacity(count)
      while result.count < count {
        try Task.checkCancellation()
        if offset == cached.count {
          guard let sample = output.copyNextSampleBuffer() else {
            guard reader.status == .completed else { throw StepError.readerFailed }
            break
          }
          guard let block = CMSampleBufferGetDataBuffer(sample) else { throw StepError.invalidPCM }
          let bytes = CMBlockBufferGetDataLength(block)
          guard bytes == CMSampleBufferGetNumSamples(sample) * MemoryLayout<Float>.size else {
            throw StepError.invalidPCM
          }
          cached = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
          let status = cached.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(
              block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
          }
          guard status == kCMBlockBufferNoErr else { throw StepError.invalidPCM }
          offset = 0
          if cached.isEmpty { continue }
        }
        let end = min(cached.count, offset + count - result.count)
        result.append(contentsOf: cached[offset..<end])
        offset = end
      }
      return result
    }
  }
}
