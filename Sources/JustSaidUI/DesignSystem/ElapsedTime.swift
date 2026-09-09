import Foundation

/// 会议内“相对录音开始的秒数”与显示文案之间的单一换算入口，转写区、笔记区、
/// 「当前」专区、标记占位行统一复用，避免各处各写一份格式化逻辑。
enum ElapsedTime {
  /// 短格式：≥1 小时用 `H:MM:SS`（如工具栏计时），否则 `MM:SS`。
  static func shortLabel(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remaining = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remaining)
    }
    return String(format: "%02d:%02d", minutes, remaining)
  }

  /// 会议库列表紧凑时长(P4):固定 `H:MM`(不足一小时 `0:MM`),只进列表行。
  static func hourMinuteLabel(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    return String(format: "%d:%02d", hours, minutes)
  }

  /// 落盘格式：固定 `HH:MM:SS`，与 `NotesWriter`/`LiveTranscriptWriter` 的时间戳文案一致。
  static func fullLabel(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remaining = total % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, remaining)
  }
}
