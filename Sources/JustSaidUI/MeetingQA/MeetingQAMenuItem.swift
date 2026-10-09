import JustSaidCore
import SwiftUI

/// 会议菜单「问这场会」⌘J(10-09 实验性)。开关关着时不出现;会话进行中才可用。
/// 动作:由调用方先把主窗切到驾驶舱,这里再切到「问答」页并把光标放进输入框。
public struct MeetingQAMenuItem: View {
  @AppStorage(MeetingQASettings.defaultsKey) private var enabled = false
  private let isSessionActive: Bool
  private let showCockpit: () -> Void

  public init(isSessionActive: Bool, showCockpit: @escaping () -> Void) {
    self.isSessionActive = isSessionActive
    self.showCockpit = showCockpit
  }

  public var body: some View {
    if enabled {
      Button("问这场会") {
        showCockpit()
        MeetingQAControllerRegistry.shared.requestFocus()
      }
      .keyboardShortcut("j", modifiers: .command)
      .disabled(!isSessionActive)
    }
  }
}
