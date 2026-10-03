import Foundation

/// 内置默认排除清单：这些进程占麦克风不是开会。清单按 bundle ID 精确匹配，
/// 同时检查进程自己的 bundle ID 与归并后的主程序 bundle ID。
/// 用户点过的「不再提醒」另存，由检测器的 `userExcludedAppKeys` 传入。
///
/// 来源：`.trellis/tasks/09-27-meeting-detection-prompt/research/prototype-research.md` §3，
/// 「本机」= 2026-09-30 在开发机进程列表或 ControlCenter 日志实测。
public enum MeetingDetectionExclusions {
  public static let builtInBundleIDs: Set<String> = [
    // JustSaid 自身（另按 pid 与进程后代排除，见 MeetingAppIdentityResolver）。
    "com.justsaid.app",
    // Typeless 听写（本机）。
    "now.typeless.desktop",
    "now.typeless.desktop.helper",
    "now.typeless.desktop.helper.Plugin",
    // 豆包输入法（本机，日志 14 次）。
    "com.bytedance.inputmethod.doubaoime",
    // 腾讯 Chatterfly 输入法（本机，日志 6 次）。
    "com.tencent.inputmethod.chatterfly",
    // 微信输入法 WeType（外部资料，未在本机观察到）。
    "com.tencent.inputmethod.wetype",
    // 语音备忘录（系统 App Info.plist）。
    "com.apple.VoiceMemos",
    // Apple 语音与系统进程（本机进程列表中出现，未验证哪些会在听写时占麦）。
    "com.apple.CoreSpeech",
    "com.apple.assistantd",
    "com.apple.accessibility.heard",
    "com.apple.universalaccessd",
    "com.apple.controlcenter",
    // 听写工具（外部资料：Homebrew cask quit key）。
    "com.superduper.superwhisper",
    "com.goodsnooze.MacWhisper",
  ]
  // 刻意不含 Krisp、Granola：它们与会议相关，是否排除是产品决定。
}
