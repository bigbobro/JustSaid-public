import Foundation

public struct LocalOfflineTimelineGap: Equatable, Sendable {
  public let bufferStartSampleIndex: Int64
  public let skippedDuration: TimeInterval
  public let skippedSamples: Int64
  public let shouldFlushVAD: Bool

  public init(
    bufferStartSampleIndex: Int64,
    skippedDuration: TimeInterval,
    skippedSamples: Int64,
    shouldFlushVAD: Bool
  ) {
    self.bufferStartSampleIndex = bufferStartSampleIndex
    self.skippedDuration = skippedDuration
    self.skippedSamples = skippedSamples
    self.shouldFlushVAD = shouldFlushVAD
  }
}

public struct LocalOfflineTimelineTracker: Sendable {
  public static let sampleRate = 16_000
  public static let vadFlushGapThreshold: TimeInterval = 2

  private struct Anchor: Sendable {
    let sampleIndex: Int64
    let captureTime: TimeInterval
  }

  private var anchors: [Anchor] = []
  private var previousCaptureEnd: TimeInterval?

  public private(set) var cumulativeSampleIndex: Int64 = 0

  public init() {}

  @discardableResult
  public mutating func registerBuffer(
    sampleCount: Int,
    captureTime: TimeInterval,
    captureDuration: TimeInterval
  ) -> LocalOfflineTimelineGap {
    let bufferStartSampleIndex = cumulativeSampleIndex
    let rawGap = previousCaptureEnd.map { captureTime - $0 } ?? 0
    let skippedDuration =
      rawGap > IncrementalM4AWriter.gapThresholdSeconds ? rawGap : 0
    let skippedSamples = Int64(
      (skippedDuration * TimeInterval(Self.sampleRate)).rounded()
    )

    anchors.append(
      Anchor(
        sampleIndex: bufferStartSampleIndex,
        captureTime: captureTime
      )
    )
    cumulativeSampleIndex += Int64(max(sampleCount, 0))
    previousCaptureEnd = captureTime + max(captureDuration, 0)

    return LocalOfflineTimelineGap(
      bufferStartSampleIndex: bufferStartSampleIndex,
      skippedDuration: skippedDuration,
      skippedSamples: skippedSamples,
      shouldFlushVAD: skippedDuration > Self.vadFlushGapThreshold
    )
  }

  public func startTime(for sampleIndex: Int64) -> TimeInterval {
    timestamp(for: sampleIndex, includeEqualAnchor: true)
  }

  public func endTime(for sampleIndex: Int64) -> TimeInterval {
    timestamp(for: sampleIndex, includeEqualAnchor: false)
  }

  private func timestamp(
    for sampleIndex: Int64,
    includeEqualAnchor: Bool
  ) -> TimeInterval {
    guard
      let anchor = anchor(
        for: sampleIndex,
        includeEqual: includeEqualAnchor
      )
    else {
      return TimeInterval(sampleIndex) / TimeInterval(Self.sampleRate)
    }
    return anchor.captureTime
      + TimeInterval(sampleIndex - anchor.sampleIndex)
      / TimeInterval(Self.sampleRate)
  }

  private func anchor(
    for sampleIndex: Int64,
    includeEqual: Bool
  ) -> Anchor? {
    guard !anchors.isEmpty else {
      return nil
    }

    var lower = 0
    var upper = anchors.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      let candidate = anchors[middle]
      let belongsBeforeBoundary =
        includeEqual
        ? candidate.sampleIndex <= sampleIndex
        : candidate.sampleIndex < sampleIndex
      if belongsBeforeBoundary {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return anchors[max(0, lower - 1)]
  }
}

public enum LocalOfflineDecodeKind: Sendable {
  case partial
  case final
}

public enum LocalOfflineDecodingPolicy {
  public static let partialPreviewDuration: TimeInterval = 12
  public static let partialBacklogThreshold: TimeInterval = 1

  public static func shouldDecode(
    _ kind: LocalOfflineDecodeKind,
    pendingAudioDuration: TimeInterval
  ) -> Bool {
    switch kind {
    case .partial:
      return pendingAudioDuration <= partialBacklogThreshold
    case .final:
      return true
    }
  }

  public static func partialPreviewSamples(_ samples: [Float]) -> [Float] {
    let maximumSamples = Int(
      (partialPreviewDuration * TimeInterval(LocalOfflineTimelineTracker.sampleRate))
        .rounded()
    )
    return Array(samples.suffix(maximumSamples))
  }
}
