import JustSaidCore
import SwiftUI

/// 通用设置里的会中问答开关(10-09 实验性,默认关)。撤回时连同 `GeneralSettingsPane` 里的一行引用删除。
struct MeetingQASettingsCard: View {
  // 默认值与 `MeetingQASettings.isEnabled` 键缺失分支一致(默认关)。
  @AppStorage(MeetingQASettings.defaultsKey) private var enabled = false

  var body: some View {
    SettingsFormGroup(
      "会中问答", hint: "会议进行中在右栏向 AI 提问；模型在「模型与服务」里选。"
    ) {
      SettingsFormRow("会中问答", labelDetail: "实验性功能", isFirst: true) {
        Toggle("会中问答", isOn: $enabled)
          .toggleStyle(.v1Switch)
          .labelsHidden()
          .runtimeAccessibilityIdentifier("settings.meeting-qa")
      }
    }
    .runtimeAccessibilityIdentifier("settings.meeting-qa.card")
  }
}
