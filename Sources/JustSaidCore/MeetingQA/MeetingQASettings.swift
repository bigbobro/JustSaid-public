import Foundation

/// 会中问答(10-09 实验性,owner 按主观体验决定去留)。
///
/// 整块撤回时删除 `Sources/JustSaidCore/MeetingQA/`、`Sources/JustSaidUI/MeetingQA/`,
/// 以及 `.trellis/tasks/10-09-in-meeting-qa/implement.md`「撤回清单」列出的入口。
/// 开关键缺失 = 关:关着时界面上没有任何入口,也不发任何请求。
public enum MeetingQASettings {
  public static let defaultsKey = "justsaid.meetingQA.enabled"
  /// 右栏上次停留的页签(「记录」/「问答」);缺失 = 「记录」。
  public static let sidebarTabDefaultsKey = "justsaid.meetingQA.sidebarTab"

  public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
    guard defaults.object(forKey: defaultsKey) != nil else {
      return false
    }
    return defaults.bool(forKey: defaultsKey)
  }

  public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: defaultsKey)
  }
}
