import Foundation

public enum MeetingLanguageDetector {
  public static func detect(
    _ segments: [TranscriptSegment]
  ) -> BatchLanguageDecision {
    var latinCount = 0
    var cjkCount = 0

    for scalar in segments.filter(\.isFinal).flatMap(\.text.unicodeScalars) {
      if isLatin(scalar.value) {
        latinCount += 1
      } else if isCJK(scalar.value) {
        cjkCount += 1
      }
    }

    let total = latinCount + cjkCount
    guard total > 0 else {
      return .auto
    }
    if Double(latinCount) / Double(total) >= 0.9 {
      return .english
    }
    if Double(cjkCount) / Double(total) >= 0.9 {
      return .chinese
    }
    return .auto
  }

  private static func isLatin(_ value: UInt32) -> Bool {
    (0x0041...0x005A).contains(value)
      || (0x0061...0x007A).contains(value)
      || (0x00C0...0x024F).contains(value)
      || (0x1E00...0x1EFF).contains(value)
      || (0xFF21...0xFF3A).contains(value)
      || (0xFF41...0xFF5A).contains(value)
  }

  private static func isCJK(_ value: UInt32) -> Bool {
    (0x1100...0x11FF).contains(value)
      || (0x2E80...0x2FDF).contains(value)
      || (0x3040...0x30FF).contains(value)
      || (0x3130...0x318F).contains(value)
      || (0x31F0...0x31FF).contains(value)
      || (0x3400...0x4DBF).contains(value)
      || (0x4E00...0x9FFF).contains(value)
      || (0xA960...0xA97F).contains(value)
      || (0xAC00...0xD7AF).contains(value)
      || (0xD7B0...0xD7FF).contains(value)
      || (0xF900...0xFAFF).contains(value)
      || (0x20000...0x2FA1F).contains(value)
  }
}
