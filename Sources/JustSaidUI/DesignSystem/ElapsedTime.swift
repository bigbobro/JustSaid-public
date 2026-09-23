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

  /// 会议时长:一律写成分钟数加「m」——「31m」「90m」,不足 1 分钟记「1m」
  /// (owner 2026-09-21:不写「几小时几分钟」,也不写「分钟」,用 m 就好)。
  /// 带单位,不会和旁边的开始时间「14:33」混:原来的 `0:31` 就是因为长得像时间点被拿掉的
  /// (owner 2026-09-20)。会议库列表与会议页头部共用,同一场会两处写法一致。
  static func minutesLabel(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int(seconds.rounded(.down)) / 60)
    return "\(minutes)m"
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
