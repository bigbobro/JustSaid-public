import AVFAudio
import Foundation
import Synchronization

public struct LiveEchoCancellationStatistics: Codable, Equatable, Sendable {
  public var state = "active"
  public var reason: String?
  public var referenceLeadMilliseconds = 100
  public var processedFrames: UInt64 = 0
  public var outOfRangeFrames: UInt64 = 0
  public var referenceAvailableFrames: UInt64 = 0
  public var referenceNoDataFrames: UInt64 = 0
  public var referenceTimeoutFrames: UInt64 = 0
  public var referenceMissingFrames: UInt64 = 0
  public var referenceFlushMissingFrames: UInt64 = 0
  /// Frames whose missing reference subsequently arrived, within the retained 5s window.
  /// This is a subset of missing frames, excluding reference-stream startup.
  public var referenceLateFrames: UInt64 = 0
  public var referenceStartFrames: UInt64 = 0
  public var referenceQueuedFrames: UInt64 = 0
  /// Cumulative ratio is retained for diagnostics; state uses the recent window.
  public var referenceLateRatio = 0.0
  public var referenceLateWindowSeconds = 30.0
  public var referenceWindowFrames: UInt64 = 0
  public var referenceLateWindowFrames: UInt64 = 0
  public var referenceLateWindowRatio = 0.0
  public var referenceLateDegradedMaximumSeconds = 0.0
  public var passthroughBuffers: UInt64 = 0
  public var overflowBuffers: UInt64 = 0
  public var referenceOverflowBuffers: UInt64 = 0
  public var inputBuffers: UInt64 = 0
  public var outputBuffers: UInt64 = 0
  public var inputSamples: UInt64 = 0
  public var outputSamples: UInt64 = 0
  public var conversionTailPaddingSamples: UInt64 = 0
  public var maximumPendingSeconds = 0.0
  public var waitP50Seconds: Double?
  public var waitP95Seconds: Double?
  public var waitMaximumSeconds = 0.0
  public var echoReturnLossDB: Double?
  public var echoReturnLossEnhancementDB: Double?
  public var estimatedDelayMilliseconds: Int?
  public var pendingMicrophoneSeconds = 0.0
  public var bypassedBuffers: UInt64 = 0
  public var bypassTransitions: UInt64 = 0
  public var bypassReason: String?
  public var microphoneReanchors: UInt64 = 0
  public var referenceReanchors: UInt64 = 0
  public var microphoneMaximumCaptureTimeJumpSeconds = 0.0
  public var referenceMaximumCaptureTimeJumpSeconds = 0.0
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case state
    case reason
    case referenceLeadMilliseconds
    case processedFrames
    case outOfRangeFrames
    case referenceAvailableFrames
    case referenceNoDataFrames
    case referenceTimeoutFrames
    case referenceMissingFrames
    case referenceFlushMissingFrames
    case referenceLateFrames
    case referenceStartFrames
    case referenceQueuedFrames
    case referenceLateRatio
    case referenceLateWindowSeconds
    case referenceWindowFrames
    case referenceLateWindowFrames
    case referenceLateWindowRatio
    case referenceLateDegradedMaximumSeconds
    case passthroughBuffers
    case overflowBuffers
    case referenceOverflowBuffers
    case inputBuffers
    case outputBuffers
    case inputSamples
    case outputSamples
    case conversionTailPaddingSamples
    case maximumPendingSeconds
    case waitP50Seconds
    case waitP95Seconds
    case waitMaximumSeconds
    case echoReturnLossDB
    case echoReturnLossEnhancementDB
    case estimatedDelayMilliseconds
    case pendingMicrophoneSeconds
    case bypassedBuffers
    case bypassTransitions
    case bypassReason
    case microphoneReanchors
    case referenceReanchors
    case microphoneMaximumCaptureTimeJumpSeconds
    case referenceMaximumCaptureTimeJumpSeconds
  }

  public init(from decoder: any Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    state = try values.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
    reason = try values.decodeIfPresent(String.self, forKey: .reason)
    referenceLeadMilliseconds =
      try values.decodeIfPresent(Int.self, forKey: .referenceLeadMilliseconds) ?? 100
    processedFrames = try values.decodeIfPresent(UInt64.self, forKey: .processedFrames) ?? 0
    outOfRangeFrames = try values.decodeIfPresent(UInt64.self, forKey: .outOfRangeFrames) ?? 0
    referenceAvailableFrames =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceAvailableFrames) ?? 0
    referenceNoDataFrames =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceNoDataFrames) ?? 0
    referenceTimeoutFrames =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceTimeoutFrames) ?? 0
    referenceMissingFrames =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceMissingFrames) ?? 0
    referenceFlushMissingFrames =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceFlushMissingFrames) ?? 0
    referenceLateFrames = try values.decodeIfPresent(UInt64.self, forKey: .referenceLateFrames) ?? 0
    referenceStartFrames =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceStartFrames) ?? 0
    referenceQueuedFrames =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceQueuedFrames) ?? 0
    referenceLateRatio = try values.decodeIfPresent(Double.self, forKey: .referenceLateRatio) ?? 0.0
    referenceLateWindowSeconds =
      try values.decodeIfPresent(Double.self, forKey: .referenceLateWindowSeconds) ?? 30.0
    referenceWindowFrames =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceWindowFrames) ?? 0
    referenceLateWindowFrames =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceLateWindowFrames) ?? 0
    referenceLateWindowRatio =
      try values.decodeIfPresent(Double.self, forKey: .referenceLateWindowRatio) ?? 0.0
    referenceLateDegradedMaximumSeconds =
      try values.decodeIfPresent(Double.self, forKey: .referenceLateDegradedMaximumSeconds) ?? 0.0
    passthroughBuffers = try values.decodeIfPresent(UInt64.self, forKey: .passthroughBuffers) ?? 0
    overflowBuffers = try values.decodeIfPresent(UInt64.self, forKey: .overflowBuffers) ?? 0
    referenceOverflowBuffers =
      try values.decodeIfPresent(UInt64.self, forKey: .referenceOverflowBuffers) ?? 0
    inputBuffers = try values.decodeIfPresent(UInt64.self, forKey: .inputBuffers) ?? 0
    outputBuffers = try values.decodeIfPresent(UInt64.self, forKey: .outputBuffers) ?? 0
    inputSamples = try values.decodeIfPresent(UInt64.self, forKey: .inputSamples) ?? 0
    outputSamples = try values.decodeIfPresent(UInt64.self, forKey: .outputSamples) ?? 0
    conversionTailPaddingSamples =
      try values.decodeIfPresent(UInt64.self, forKey: .conversionTailPaddingSamples) ?? 0
    maximumPendingSeconds =
      try values.decodeIfPresent(Double.self, forKey: .maximumPendingSeconds) ?? 0.0
    waitP50Seconds = try values.decodeIfPresent(Double.self, forKey: .waitP50Seconds)
    waitP95Seconds = try values.decodeIfPresent(Double.self, forKey: .waitP95Seconds)
    waitMaximumSeconds = try values.decodeIfPresent(Double.self, forKey: .waitMaximumSeconds) ?? 0.0
    echoReturnLossDB = try values.decodeIfPresent(Double.self, forKey: .echoReturnLossDB)
    echoReturnLossEnhancementDB = try values.decodeIfPresent(
      Double.self, forKey: .echoReturnLossEnhancementDB)
    estimatedDelayMilliseconds = try values.decodeIfPresent(
      Int.self, forKey: .estimatedDelayMilliseconds)
    pendingMicrophoneSeconds =
      try values.decodeIfPresent(Double.self, forKey: .pendingMicrophoneSeconds) ?? 0.0
    bypassedBuffers = try values.decodeIfPresent(UInt64.self, forKey: .bypassedBuffers) ?? 0
    bypassTransitions = try values.decodeIfPresent(UInt64.self, forKey: .bypassTransitions) ?? 0
    bypassReason = try values.decodeIfPresent(String.self, forKey: .bypassReason)
    microphoneReanchors = try values.decodeIfPresent(UInt64.self, forKey: .microphoneReanchors) ?? 0
    referenceReanchors = try values.decodeIfPresent(UInt64.self, forKey: .referenceReanchors) ?? 0
    microphoneMaximumCaptureTimeJumpSeconds =
      try values.decodeIfPresent(Double.self, forKey: .microphoneMaximumCaptureTimeJumpSeconds)
      ?? 0.0
    referenceMaximumCaptureTimeJumpSeconds =
      try values.decodeIfPresent(Double.self, forKey: .referenceMaximumCaptureTimeJumpSeconds)
      ?? 0.0
  }
}

/// Owns one AEC3 stream. Push copies and enqueues; all conversion, DSP, timers and
/// output callbacks run on this private serial queue. The sink must not block.
/// AEC is 16kHz mono; output is mono at each input's original rate and frame count,
/// retaining captureTime and duration even for 48kHz/512-frame capture buffers.
/// Flush after both producers drain and before stopping the downstream engine.
// Safety invariant: admission is Mutex-protected; mutable DSP, conversion and
// diagnostic state is owned by the private serial queue. Buffers are copied before enqueue.
public final class LiveEchoCancellationStage: @unchecked Sendable {
  // Step-0 hardware evidence: task research/c4-live-timing.md (2026-09-30).
  public static let defaultReferenceLeadMilliseconds = 100
  public static let referenceTimeoutSeconds = 0.2
  public static let referenceInactiveSeconds = 1.0
  public static let maximumPendingMicrophoneSeconds = 1.5
  private static let rate = 16_000
  private static let frame = 160
  private static let window = 5 * rate
  private static let jitter = 320  // 20ms, the C1 timestamp tolerance.
  private static let lateDegradationRatio = 0.1
  private static let lateDegradationMinimumFrames: UInt64 = 10
  private static let lateWindowSeconds = 30.0
  private static let lateWindowCapacity = 3_000  // At most 30s of 10ms DSP frames.

  private struct Admission {
    var microphone = 0.0
    var reference = 0.0
    var referenceJobs = 0
    var microphoneInputAudioEnd: Double?
    var requestedBypassReason: String?
  }
  private final class Microphone {
    let original: SendablePCMBuffer
    let captureTime: Double
    let admittedAt: Double
    let duration: Double
    let position: Int
    let samples: [Float]
    var cursor = 0
    var processed: [Float] = []
    init(
      original: SendablePCMBuffer, time: Double, admittedAt: Double, position: Int, samples: [Float]
    ) {
      self.original = original
      captureTime = time
      self.admittedAt = admittedAt
      duration = Double(original.value.frameLength) / original.value.format.sampleRate
      self.position = position
      self.samples = samples
    }
  }
  private struct Missing {
    let frameID: Int
    let position: Int
    let noData: Bool
    let missingSamples: [Int]
    let releasedAt: Double
    var resolved = false
  }
  private struct ReferenceObservation {
    let frameID: Int
    let releasedAt: Double
    var late = false
    var start = false
  }
  private let queue = DispatchQueue(label: "com.justsaid.live-aec", qos: .userInitiated)
  private let admission = Mutex(Admission())
  private let output: AudioPCMBufferHandler
  private let makeCanceller: @Sendable () -> any AcousticEchoCancelling
  private let lead: Int
  private let mono = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
  private lazy var microphoneConverter = PCMBufferConverter(outputFormat: mono, primeMethod: .none)
  private lazy var referenceConverter = PCMBufferConverter(outputFormat: mono, primeMethod: .none)
  private var outputConverter: PCMBufferConverter?
  private var outputRate: Double?
  private var canceller: (any AcousticEchoCancelling)?
  private var permanentlyDegraded = false
  private var permanentDegradationReason: String?
  private var bypassReason: String?
  private var report = LiveEchoCancellationStatistics()
  private var referenceSamples = [Float](repeating: 0, count: window)
  private var referenceTags = [Int](repeating: Int.min, count: window)
  private var referenceEnd: Int?
  private var microphoneEnd: Int?
  private var lastReferenceArrival: Double?
  private var referenceStartEnd: Int?
  private var pending: [Microphone] = []
  private var awaitingOutput: [Microphone] = []
  private var restoredSamples: [Float] = []
  private var restoredCursor = 0
  private var missing: [Missing] = []
  private var referenceObservations = [ReferenceObservation?](
    repeating: nil, count: lateWindowCapacity)
  private var lateDegradedAt: Double?
  private var waitHistogram = [UInt64](repeating: 0, count: 10_001)
  private var waitCount: UInt64 = 0
  private var timer: DispatchWorkItem?
  private var frames = 0
  private var drainEnqueued = false

  public init(
    referenceLeadMilliseconds: Int = defaultReferenceLeadMilliseconds,
    output: @escaping AudioPCMBufferHandler,
    makeCanceller: @escaping @Sendable () -> any AcousticEchoCancelling = {
      WebRTCEchoCanceller(sampleRateHz: 16_000)
    }
  ) {
    precondition((0...500).contains(referenceLeadMilliseconds))
    lead = referenceLeadMilliseconds * Self.rate / 1000
    self.output = output
    self.makeCanceller = makeCanceller
    report.referenceLeadMilliseconds = referenceLeadMilliseconds
    // Initialize before capture starts: native setup must not consume the first
    // microphone buffer's reference-wait budget. The queue owns the handle.
    queue.sync { ensureCanceller() }
  }

  public func pushMicrophone(_ buffer: AVAudioPCMBuffer, at captureTime: TimeInterval) {
    let admittedAt = Self.now
    let duration = Double(buffer.frameLength) / buffer.format.sampleRate
    let admitted = admission.withLock { value in
      if captureTime.isFinite, duration.isFinite {
        // One 16kHz sample of conservative rounding, matching the ASR re-arm contract.
        value.microphoneInputAudioEnd = max(
          value.microphoneInputAudioEnd ?? -.infinity, captureTime + duration + 1.0 / 16_000)
      }
      guard value.microphone + duration <= Self.maximumPendingMicrophoneSeconds else {
        return false
      }
      value.microphone += duration
      return true
    }
    do {
      let owned = try SendablePCMBuffer(copying: buffer)
      queue.async { [self] in
        report.inputBuffers += 1
        report.inputSamples += UInt64(owned.value.frameLength)
        report.maximumPendingSeconds = max(
          report.maximumPendingSeconds, admission.withLock { $0.microphone })
        guard admitted else {
          // Preserve ordering when admission is full; release the older waiters first.
          drain(force: true)
          finishNativeOutput()
          report.overflowBuffers += 1
          emitRaw(owned, time: captureTime, admittedAt: admittedAt, reserved: false)
          return
        }
        acceptMicrophone(owned, time: captureTime, admittedAt: admittedAt)
      }
    } catch {
      if admitted { admission.withLock { $0.microphone -= duration } }
      // Allocation failure cannot safely retain the caller's buffer. Synchronous
      // passthrough is the only ownership-safe recovery for this exceptional path.
      output(buffer, captureTime)
      queue.async { [self] in degrade("copyFailed") }
    }
  }

  /// Includes accepted microphone audio that is still waiting for reference/output.
  /// Read synchronously so a reminder re-arm cannot race the DSP queue.
  public var microphoneInputAudioEnd: TimeInterval? {
    admission.withLock { $0.microphoneInputAudioEnd }
  }
  public var pendingMicrophoneSeconds: TimeInterval {
    admission.withLock { $0.microphone }
  }

  /// Route publication precedes the next microphone push. A transition drains the
  /// old route before changing to zero-reference-wait, whole-buffer passthrough.
  public func setBypassed(_ bypassed: Bool, reason: String = "effectiveVPIO") {
    let requested = bypassed ? reason : nil
    admission.withLock { value in
      guard value.requestedBypassReason != requested else { return }
      value.requestedBypassReason = requested
      queue.async { [self] in
        guard bypassReason != requested else { return }
        timer?.cancel()
        timer = nil
        drain(force: true)
        finishNativeOutput()
        snapshotCanceller()
        finishLateDegradation(at: Self.now)
        bypassReason = requested
        report.bypassReason = requested
        report.bypassTransitions += 1
        microphoneEnd = nil
        if let requested {
          report.state = "bypassed"
          report.reason = requested
        } else {
          report.state = permanentlyDegraded ? "degraded" : "active"
          report.reason = permanentDegradationReason
          updateLateState()
        }
      }
    }
  }

  public func pushReference(_ buffer: AVAudioPCMBuffer, at captureTime: TimeInterval) {
    let arrival = Self.now
    let duration = Double(buffer.frameLength) / buffer.format.sampleRate
    let admitted = admission.withLock { value in
      guard value.reference + duration <= 5 else { return false }
      value.reference += duration
      return true
    }
    guard admitted else {
      queue.async { [self] in report.referenceOverflowBuffers += 1 }
      return
    }
    do {
      let owned = try SendablePCMBuffer(copying: buffer)
      admission.withLock { value in
        value.referenceJobs += 1
        // Publish the job under the admission lock so the DSP queue cannot
        // observe a pending reference before that reference is actually queued.
        queue.async { [self] in
          defer {
            admission.withLock {
              $0.reference -= duration
              $0.referenceJobs -= 1
            }
          }
          acceptReference(owned, time: captureTime, arrival: arrival)
        }
      }
    } catch {
      admission.withLock { $0.reference -= duration }
      queue.async { [self] in
        degrade("referenceCopyFailed")
        drain(force: true)
      }
    }
  }

  /// A queue barrier; all already-pushed microphone buffers reach the sink before return.
  /// Missing reference and the final partial AEC frame are padded with zero.
  public func flush() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        timer?.cancel()
        timer = nil
        drain(force: true)
        finishNativeOutput()
        snapshotCanceller()
        continuation.resume()
      }
    }
  }

  public func statistics() async -> LiveEchoCancellationStatistics {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        snapshotCanceller()
        var snapshot = report
        snapshot.pendingMicrophoneSeconds = admission.withLock { $0.microphone }
        snapshot.waitP50Seconds = percentile(0.5)
        snapshot.waitP95Seconds = percentile(0.95)
        continuation.resume(returning: snapshot)
      }
    }
  }

  private static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
  private static func slot(_ position: Int) -> Int { ((position % window) + window) % window }
  private func position(time: Double, expected: Int?, microphone: Bool) -> Int? {
    guard time.isFinite, abs(time) < Double(Int.max / Self.rate / 2) else { return nil }
    let measured = Int((time * Double(Self.rate)).rounded())
    if let expected, abs(measured - expected) <= Self.jitter { return expected }
    if let expected {
      let jump = Double(abs(measured - expected)) / Double(Self.rate)
      if microphone {
        report.microphoneReanchors += 1
        report.microphoneMaximumCaptureTimeJumpSeconds = max(
          report.microphoneMaximumCaptureTimeJumpSeconds, jump)
      } else {
        report.referenceReanchors += 1
        report.referenceMaximumCaptureTimeJumpSeconds = max(
          report.referenceMaximumCaptureTimeJumpSeconds, jump)
      }
    }
    return measured
  }
  private func ensureCanceller() {
    if canceller == nil { canceller = makeCanceller() }
    if let canceller, canceller.status != .active { degrade(String(describing: canceller.status)) }
  }
  private func degrade(_ reason: String) {
    if !permanentlyDegraded { permanentDegradationReason = reason }
    finishLateDegradation(at: Self.now)
    permanentlyDegraded = true
    report.state = bypassReason == nil ? "degraded" : "bypassed"
    report.reason = bypassReason ?? permanentDegradationReason
  }
  private func acceptReference(_ owned: SendablePCMBuffer, time: Double, arrival: Double) {
    guard !permanentlyDegraded else { return }
    do {
      let converted = try referenceConverter.convert(owned.value)
      guard let position = position(time: time, expected: referenceEnd, microphone: false),
        let data = converted.floatChannelData
      else {
        degrade("referenceConversionFailed")
        drain(force: true)
        return
      }
      let count = Int(converted.frameLength)
      if count == 0 { return }
      if lastReferenceArrival.map({ arrival - $0 >= Self.referenceInactiveSeconds }) ?? true {
        // Before the first playback (or after a silent producer gap), microphone
        // frames legitimately used zero reference. The first lead interval is
        // a stream-start transient, not evidence of continuously late delivery.
        referenceStartEnd = position + max(lead, Self.frame)
      }
      lastReferenceArrival = arrival
      let end = position + count
      for i in missing.indices where !missing[i].resolved {
        if missing[i].missingSamples.contains(where: { $0 >= position && $0 < end }) {
          missing[i].resolved = true
          let late = arrival > missing[i].releasedAt
          let start =
            missing[i].noData && late
            && missing[i].position < (referenceStartEnd ?? Int.min)
          if start {
            report.referenceStartFrames += 1
          } else if late {
            report.referenceLateFrames += 1
          } else {
            report.referenceQueuedFrames += 1
          }
          let slot = missing[i].frameID % Self.lateWindowCapacity
          if referenceObservations[slot]?.frameID == missing[i].frameID {
            referenceObservations[slot]?.late = late && !start
            referenceObservations[slot]?.start = start
          }
          if missing[i].noData { report.referenceNoDataFrames -= 1 }
        }
      }
      updateLateState()
      let latest = max(referenceEnd ?? end, end)
      for index in 0..<count {
        let p = position + index
        guard p >= latest - Self.window else { continue }
        let slot = Self.slot(p)
        // Drop overlapping/out-of-order reference samples rather than overwrite newer data.
        if referenceTags[slot] < p {
          referenceTags[slot] = p
          referenceSamples[slot] = data[0][index]
        }
      }
      referenceEnd = latest
      missing.removeAll { $0.position + Self.frame < latest - Self.window }
      requestDrain()
    } catch {
      degrade("referenceConversionFailed")
      drain(force: true)
    }
  }
  private func acceptMicrophone(_ owned: SendablePCMBuffer, time: Double, admittedAt: Double) {
    if bypassReason != nil {
      report.bypassedBuffers += 1
      emitRaw(owned, time: time, admittedAt: admittedAt, reserved: true)
      return
    }
    ensureCanceller()
    guard !permanentlyDegraded else {
      drain(force: true)
      finishNativeOutput()
      emitRaw(owned, time: time, admittedAt: admittedAt, reserved: true)
      return
    }
    do {
      let converted = try microphoneConverter.convert(owned.value)
      guard let position = position(time: time, expected: microphoneEnd, microphone: true),
        let data = converted.floatChannelData
      else {
        degrade("microphoneConversionFailed")
        drain(force: true)
        finishNativeOutput()
        emitRaw(owned, time: time, admittedAt: admittedAt, reserved: true)
        return
      }
      if let microphoneEnd, position != microphoneEnd {
        // Never frame across a pause/rebuild discontinuity. Keep AEC state, but
        // retain each input's own captureTime and do not emit synthetic gap audio.
        drain(force: true)
        finishNativeOutput()
      }
      let count = Int(converted.frameLength)
      pending.append(
        Microphone(
          original: owned, time: time, admittedAt: admittedAt, position: position,
          samples: Array(UnsafeBufferPointer(start: data[0], count: count))))
      microphoneEnd = position + count
      requestDrain()
    } catch {
      degrade("microphoneConversionFailed")
      drain(force: true)
      finishNativeOutput()
      emitRaw(owned, time: time, admittedAt: admittedAt, reserved: true)
    }
  }
  private func requestDrain() {
    guard !drainEnqueued else { return }
    drainEnqueued = true
    queue.async { [self] in
      drainEnqueued = false
      drain(force: false)
    }
  }
  private func drain(force: Bool) {
    timer?.cancel()
    timer = nil
    if permanentlyDegraded {
      // Discard incomplete processed copies: a failing buffer passes through in full.
      finishNativeOutput(raw: true)
      for item in pending {
        emitRaw(item.original, time: item.captureTime, admittedAt: item.admittedAt, reserved: true)
      }
      pending.removeAll()
      return
    }
    while let first = pending.first {
      let remaining = pending.reduce(0) { $0 + $1.samples.count - $1.cursor }
      let deadline =
        first.admittedAt + Double(lead) / Double(Self.rate) + Self.referenceTimeoutSeconds
      let expired = Self.now >= deadline
      if remaining == 0 {
        pending.removeFirst()
        restore(first)
        continue
      }
      let noData =
        lastReferenceArrival.map { Self.now - $0 >= Self.referenceInactiveSeconds } ?? true
      // A partial DSP frame may await the next capture callback, but an absent
      // reference never adds the L+timeout hold to that framing wait.
      let partialDeadline = noData ? min(deadline, first.admittedAt + 0.02) : deadline
      if remaining < Self.frame && !force && Self.now < partialDeadline {
        schedule(partialDeadline)
        return
      }
      let start = first.position + first.cursor + lead
      var reference = [Float](repeating: 0, count: Self.frame)
      var available = true
      var missingSamples: [Int] = []
      for i in 0..<Self.frame {
        let p = start + i
        let slot = Self.slot(p)
        if referenceTags[slot] == p {
          reference[i] = referenceSamples[slot]
        } else {
          available = false
          missingSamples.append(p)
        }
      }
      if !available && !force && !expired && admission.withLock({ $0.referenceJobs > 0 }) {
        // A received reference is waiting behind this DSP job. Yield to its
        // queued copy/conversion instead of treating our own queue as late I/O.
        requestDrain()
        return
      }
      if !available && !noData && !force && !expired {
        schedule(deadline)
        return
      }
      referenceObservations[frames % Self.lateWindowCapacity] = ReferenceObservation(
        frameID: frames, releasedAt: Self.now)
      if available {
        report.referenceAvailableFrames += 1
      } else {
        if noData {
          report.referenceNoDataFrames += 1
        } else if expired {
          report.referenceTimeoutFrames += 1
        } else {
          report.referenceFlushMissingFrames += 1
        }
        report.referenceMissingFrames += 1
        missing.append(
          Missing(
            frameID: frames, position: start, noData: noData, missingSamples: missingSamples,
            releasedAt: Self.now))
        if missing.count > Self.window / Self.frame {
          missing.removeFirst(missing.count - Self.window / Self.frame)
        }
      }
      var capture: [Float] = []
      for item in pending {
        capture.append(
          contentsOf: item.samples[
            item.cursor..<min(item.samples.count, item.cursor + Self.frame - capture.count)])
        if capture.count == Self.frame { break }
      }
      let valid = capture.count
      capture += repeatElement(0, count: Self.frame - valid)
      let processed = canceller!.process(capture: capture, reference: reference)
      guard canceller!.status == .active, processed.count == Self.frame,
        processed.allSatisfy(\.isFinite)
      else {
        degrade(String(describing: canceller!.status))
        drain(force: true)
        return
      }
      var cursor = 0
      while cursor < valid, let item = pending.first {
        let count = min(valid - cursor, item.samples.count - item.cursor)
        item.processed.append(contentsOf: processed[cursor..<cursor + count])
        item.cursor += count
        cursor += count
        if item.cursor == item.samples.count {
          pending.removeFirst()
          restore(item)
          if permanentlyDegraded {
            drain(force: true)
            return
          }
        }
      }
      frames += 1
      if frames % 1000 == 0 { snapshotCanceller() }
      if permanentlyDegraded {
        drain(force: true)
        return
      }
    }
    // Native-rate rounding can leave fewer than one mono sample's worth of
    // output after all DSP input has drained. Release it on the same bound.
    if let first = awaitingOutput.first {
      let noData =
        lastReferenceArrival.map { Self.now - $0 >= Self.referenceInactiveSeconds } ?? true
      let deadline =
        first.admittedAt
        + (noData ? 0.02 : Double(lead) / Double(Self.rate) + Self.referenceTimeoutSeconds)
      if force || Self.now >= deadline { finishNativeOutput() } else { schedule(deadline) }
    }
  }
  private func schedule(_ deadline: Double) {
    let work = DispatchWorkItem { [weak self] in self?.drain(force: false) }
    timer = work
    queue.asyncAfter(deadline: .now() + max(0, deadline - Self.now), execute: work)
  }
  private func restore(_ item: Microphone) {
    let rate = item.original.value.format.sampleRate
    if outputRate != rate {
      finishNativeOutput()
      outputRate = rate
      outputConverter = PCMBufferConverter(
        outputFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!,
        primeMethod: .none)
    }
    awaitingOutput.append(item)
    do {
      if !item.processed.isEmpty {
        let buffer = AVAudioPCMBuffer(
          pcmFormat: mono, frameCapacity: AVAudioFrameCount(item.processed.count))!
        buffer.frameLength = AVAudioFrameCount(item.processed.count)
        item.processed.withUnsafeBufferPointer {
          buffer.floatChannelData![0].update(from: $0.baseAddress!, count: item.processed.count)
        }
        let restored = try outputConverter!.convert(buffer)
        restoredSamples.append(
          contentsOf: UnsafeBufferPointer(
            start: restored.floatChannelData![0], count: Int(restored.frameLength)))
      }
      emitNativeReady()
    } catch {
      degrade("outputConversionFailed")
      finishNativeOutput(raw: true)
    }
  }
  private func emitNativeReady() {
    while let item = awaitingOutput.first {
      let count = Int(item.original.value.frameLength)
      guard restoredSamples.count - restoredCursor >= count else { break }
      let format = AVAudioFormat(
        standardFormatWithSampleRate: item.original.value.format.sampleRate, channels: 1)!
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: AVAudioFrameCount(max(count, 1)))
      else {
        degrade("outputAllocationFailed")
        finishNativeOutput(raw: true)
        return
      }
      buffer.frameLength = AVAudioFrameCount(count)
      for i in 0..<count { buffer.floatChannelData![0][i] = restoredSamples[restoredCursor + i] }
      restoredCursor += count
      awaitingOutput.removeFirst()
      emit(buffer, time: item.captureTime, admittedAt: item.admittedAt, reserved: true)
    }
    if restoredCursor > 16_000 {
      restoredSamples.removeFirst(restoredCursor)
      restoredCursor = 0
    }
  }
  private func finishNativeOutput(raw: Bool = false) {
    if raw {
      for item in awaitingOutput {
        emitRaw(item.original, time: item.captureTime, admittedAt: item.admittedAt, reserved: true)
      }
      awaitingOutput.removeAll()
    } else if !awaitingOutput.isEmpty {
      let required = awaitingOutput.reduce(0) { $0 + Int($1.original.value.frameLength) }
      let padding = max(0, required - (restoredSamples.count - restoredCursor))
      report.conversionTailPaddingSamples += UInt64(padding)
      restoredSamples += repeatElement(restoredSamples.last ?? 0, count: padding)
      emitNativeReady()
    }
    restoredSamples.removeAll(keepingCapacity: true)
    restoredCursor = 0
  }
  private func emitRaw(_ owned: SendablePCMBuffer, time: Double, admittedAt: Double, reserved: Bool)
  {
    report.passthroughBuffers += 1
    emit(owned.value, time: time, admittedAt: admittedAt, reserved: reserved)
  }
  private func emit(_ buffer: AVAudioPCMBuffer, time: Double, admittedAt: Double, reserved: Bool) {
    let duration = Double(buffer.frameLength) / buffer.format.sampleRate
    if reserved { admission.withLock { $0.microphone = max(0, $0.microphone - duration) } }
    let wait = max(0, Self.now - admittedAt)
    waitHistogram[min(10_000, Int(wait * 1000))] += 1
    waitCount += 1
    report.waitMaximumSeconds = max(report.waitMaximumSeconds, wait)
    report.outputBuffers += 1
    report.outputSamples += UInt64(buffer.frameLength)
    output(buffer, time)
  }
  private func percentile(_ fraction: Double) -> Double? {
    guard waitCount > 0 else { return nil }
    let target = UInt64(ceil(Double(waitCount) * fraction))
    var count: UInt64 = 0
    for i in waitHistogram.indices {
      count += waitHistogram[i]
      if count >= target { return Double(i) / 1000 }
    }
    return nil
  }
  private func updateLateState() {
    let total = report.referenceAvailableFrames + report.referenceMissingFrames
    report.referenceLateRatio = total == 0 ? 0 : Double(report.referenceLateFrames) / Double(total)
    let now = Self.now
    var windowFrames: UInt64 = 0
    var lateFrames: UInt64 = 0
    for index in referenceObservations.indices {
      guard let observation = referenceObservations[index] else { continue }
      if now - observation.releasedAt >= Self.lateWindowSeconds {
        referenceObservations[index] = nil
      } else if !observation.start {
        windowFrames += 1
        if observation.late { lateFrames += 1 }
      }
    }
    report.referenceWindowFrames = windowFrames
    report.referenceLateWindowFrames = lateFrames
    report.referenceLateWindowRatio =
      windowFrames == 0 ? 0 : Double(lateFrames) / Double(windowFrames)
    guard !permanentlyDegraded, bypassReason == nil else { return }
    if lateFrames >= Self.lateDegradationMinimumFrames
      && report.referenceLateWindowRatio > Self.lateDegradationRatio
    {
      if lateDegradedAt == nil { lateDegradedAt = now }
      report.state = "degraded"
      report.reason = "referenceLateRatio"
      report.referenceLateDegradedMaximumSeconds = max(
        report.referenceLateDegradedMaximumSeconds, now - lateDegradedAt!)
    } else {
      finishLateDegradation(at: now)
      if report.reason == "referenceLateRatio" {
        report.state = "active"
        report.reason = nil
      }
    }
  }
  private func finishLateDegradation(at now: Double) {
    if let start = lateDegradedAt {
      report.referenceLateDegradedMaximumSeconds = max(
        report.referenceLateDegradedMaximumSeconds, now - start)
      lateDegradedAt = nil
    }
  }
  private func snapshotCanceller() {
    updateLateState()
    if let stats = canceller?.statistics {
      report.processedFrames = stats.processedFrames
      report.outOfRangeFrames = stats.outOfRangeFrames
      report.echoReturnLossDB = stats.echoReturnLossDB
      report.echoReturnLossEnhancementDB = stats.echoReturnLossEnhancementDB
      report.estimatedDelayMilliseconds = stats.estimatedDelayMilliseconds
    }
    if let canceller, canceller.status != .active { degrade(String(describing: canceller.status)) }
  }
}
