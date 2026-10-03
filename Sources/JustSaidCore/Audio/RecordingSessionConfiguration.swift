import Foundation

/// Verification can disable the optional live stage or supply a failing processor.
/// Product sessions use the default AEC3 configuration; this is not a user setting.
public struct RecordingSessionConfiguration: Sendable {
  public var liveEchoCancellationEnabled: Bool
  public var makeEchoCanceller: @Sendable () -> any AcousticEchoCancelling

  public init(
    liveEchoCancellationEnabled: Bool = true,
    makeEchoCanceller: @escaping @Sendable () -> any AcousticEchoCancelling = {
      WebRTCEchoCanceller(sampleRateHz: 16_000)
    }
  ) {
    self.liveEchoCancellationEnabled = liveEchoCancellationEnabled
    self.makeEchoCanceller = makeEchoCanceller
  }
}
