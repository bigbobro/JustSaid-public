import AVFAudio
import Synchronization

/// The capture callback admits audio; only a successful engine.feed accepts it into
/// ASR. This ledger is shared by the two capture queues and the live AEC output queue.
final class RecordingTranscriptionDelivery: Sendable {
  struct Counts: Sendable {
    var admitted: UInt64 = 0
    var fed: UInt64 = 0
    var rejected: UInt64 = 0
    var pending: UInt64 { admitted - min(admitted, fed + rejected) }
  }
  private let counts = Mutex<[AudioSource: Counts]>([:])

  func admit(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
    counts.withLock { $0[source, default: Counts()].admitted += UInt64(buffer.frameLength) }
  }
  func fed(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
    counts.withLock { $0[source, default: Counts()].fed += UInt64(buffer.frameLength) }
  }
  func rejected(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
    counts.withLock { $0[source, default: Counts()].rejected += UInt64(buffer.frameLength) }
  }
  func snapshot(_ source: AudioSource) -> Counts {
    counts.withLock { $0[source] ?? Counts() }
  }
}
