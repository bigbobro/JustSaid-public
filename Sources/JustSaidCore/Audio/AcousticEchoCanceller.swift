#if canImport(JustSaidWebRTCApm)
  import JustSaidWebRTCApm
#endif

public enum AcousticEchoCancellationFallback: Equatable, Sendable {
  case libraryUnavailable
  case unsupportedSampleRate(Int)
  case initializationFailed
  case invalidFrame
  case processingFailed(Int32)
  case nonFiniteOutput
  case statisticsFailed(Int32)
}

public enum AcousticEchoCancellationStatus: Equatable, Sendable {
  case active
  case passthrough(AcousticEchoCancellationFallback)
}

public struct AcousticEchoCancellationStatistics: Equatable, Sendable {
  public let processedFrames: UInt64
  /// Finite out-of-range frames bypassed on both tracks, once per frame.
  public let outOfRangeFrames: UInt64
  public let echoReturnLossDB: Double?
  public let echoReturnLossEnhancementDB: Double?
  public let estimatedDelayMilliseconds: Int?
}

/// One instance per stream, owned and called serially (including statistics).
/// The reference and capture tracks must already share a sample timeline.
public protocol AcousticEchoCancelling: AnyObject {
  var status: AcousticEchoCancellationStatus { get }
  var statistics: AcousticEchoCancellationStatistics? { get }
  /// Mono finite float PCM, exactly 10 ms at the configured rate. The C library
  /// accepts [-1, 1]; this wrapper also accepts finite excursions via bypass.
  /// Offline callers keep raw amplitudes, without peak scanning or scaling:
  /// attenuation weakens AEC3 (task research/aec-scaling-ablation.md).
  /// A finite out-of-range frame returns capture unchanged, skips BOTH tracks
  /// without destroying state, and increments statistics.outOfRangeFrames.
  /// Inputs stay unchanged. Invalid lengths, non-finite input or processing
  /// errors permanently degrade: this and all subsequent frames return capture.
  func process(capture: [Float], reference: [Float]) -> [Float]
}

/// AEC3 only: no devices, files, noise suppression or automatic gain control.
/// Missing the binary module in an alternate build compiles to passthrough.
public final class WebRTCEchoCanceller: AcousticEchoCancelling {
  public private(set) var status: AcousticEchoCancellationStatus
  private let frameSampleCount: Int
  private var outOfRangeFrames: UInt64 = 0
  #if canImport(JustSaidWebRTCApm)
    private var handle: OpaquePointer?
  #endif

  public init(sampleRateHz: Int) {
    frameSampleCount = sampleRateHz / 100
    guard [16_000, 32_000, 48_000].contains(sampleRateHz) else {
      status = .passthrough(.unsupportedSampleRate(sampleRateHz))
      return
    }
    #if canImport(JustSaidWebRTCApm)
      handle = js_apm_create(Int32(sampleRateHz))
      status = handle == nil ? .passthrough(.initializationFailed) : .active
    #else
      status = .passthrough(.libraryUnavailable)
    #endif
  }

  deinit {
    #if canImport(JustSaidWebRTCApm)
      js_apm_destroy(handle)
    #endif
  }

  public func process(capture: [Float], reference: [Float]) -> [Float] {
    guard status == .active else { return capture }
    guard capture.count == frameSampleCount, reference.count == frameSampleCount else {
      degrade(.invalidFrame)
      return capture
    }
    #if canImport(JustSaidWebRTCApm)
      // Only finite amplitude overflow is recoverable. Keep non-finite samples
      // on the existing C error path, even when the frame also has high peaks.
      if capture.allSatisfy(\.isFinite), reference.allSatisfy(\.isFinite),
        capture.contains(where: { abs($0) > 1 }) || reference.contains(where: { abs($0) > 1 })
      {
        outOfRangeFrames += 1
        // Skip the paired frame before either stream enters AEC3. Preserve the
        // handle and do not advance only one side of its sample timeline.
        return capture
      }
      var output = [Float](repeating: 0, count: frameSampleCount)
      let result = reference.withUnsafeBufferPointer { render in
        capture.withUnsafeBufferPointer { near in
          output.withUnsafeMutableBufferPointer { processed in
            // Offline/already-aligned tracks have zero buffering delay. AEC3
            // estimates the remaining acoustic delay from the two signals.
            js_apm_process(
              handle, render.baseAddress, near.baseAddress, frameSampleCount, 0,
              processed.baseAddress
            )
          }
        }
      }
      guard result == 0 else {
        degrade(.processingFailed(result))
        return capture
      }
      guard output.allSatisfy(\.isFinite) else {
        degrade(.nonFiniteOutput)
        return capture
      }
      return output
    #else
      return capture
    #endif
  }

  /// Poll at diagnostic cadence, rather than for every audio frame: upstream
  /// statistics use aggregation windows. Unavailable measurements remain nil.
  public var statistics: AcousticEchoCancellationStatistics? {
    #if canImport(JustSaidWebRTCApm)
      guard status == .active else { return nil }
      var measured = JSApmStats()
      let result = js_apm_get_stats(handle, &measured)
      guard result == 0 else {
        degrade(.statisticsFailed(result))
        return nil
      }
      return AcousticEchoCancellationStatistics(
        processedFrames: measured.processed_frames,
        outOfRangeFrames: outOfRangeFrames,
        echoReturnLossDB: measured.echo_return_loss_db.isFinite
          ? measured.echo_return_loss_db : nil,
        echoReturnLossEnhancementDB: measured.echo_return_loss_enhancement_db.isFinite
          ? measured.echo_return_loss_enhancement_db : nil,
        estimatedDelayMilliseconds: measured.delay_ms >= 0 ? Int(measured.delay_ms) : nil
      )
    #else
      return nil
    #endif
  }

  private func degrade(_ reason: AcousticEchoCancellationFallback) {
    #if canImport(JustSaidWebRTCApm)
      js_apm_destroy(handle)
      handle = nil
    #endif
    status = .passthrough(reason)
  }
}
