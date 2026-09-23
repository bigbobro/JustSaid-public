import JustSaidCore
import SwiftUI

/// 设置 · 通用里的「时区」分区。
///
/// 界面时间不跟着系统漂,而是按这里固定的时区显示。出差落地不会让整个会议库的
/// 时间集体挪位——换不换,由你按一次(owner 2026-09-21)。
struct TimeZoneSettingsCard: View {
  @ObservedObject var displayTimeZone: DisplayTimeZone
  @State private var justDetected: TimeZone?

  var body: some View {
    SettingsFormGroup(
      "时区", hint: "会议时间按这里显示，不随系统自动改变。"
    ) {
      SettingsFormRow("当前时区", isFirst: true) {
        Text(DisplayTimeZone.displayName(displayTimeZone.pinned))
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .runtimeAccessibilityIdentifier("settings.timezone.current")
        Button("检测本机时区") {
          displayTimeZone.refreshDrift()
          justDetected = DisplayTimeZone.machineTimeZone()
        }
        .buttonStyle(.v1Outline)
        .runtimeAccessibilityIdentifier("settings.timezone.detect")
      }

      // 本机和正在用的不一样:照实说清楚,不让它成为暗坑。
      if displayTimeZone.machineMismatchNote != nil {
        SettingsFormRow("这台电脑") {
          Text(DisplayTimeZone.displayName(DisplayTimeZone.machineTimeZone()))
            .font(Tokens.V1.Text.body.font)
            .foregroundStyle(Tokens.V1.Color.ink)
          Button("改用它") {
            displayTimeZone.adopt(DisplayTimeZone.machineTimeZone())
            justDetected = nil
          }
          .buttonStyle(.v1Outline)
          .runtimeAccessibilityIdentifier("settings.timezone.adopt")
        }
        .runtimeAccessibilityIdentifier("settings.timezone.mismatch")
        SettingsFormNote(
          "会议时间仍按 \(DisplayTimeZone.displayName(displayTimeZone.pinned)) 显示。"
            + "改用本机时区，已有会议的时间会跟着挪——时刻没变，只是换了个地方的钟看。")
      } else if let justDetected {
        // 检测过且一致:给一句回执,否则点了按钮像没反应。
        SettingsFormNote("本机就是 \(DisplayTimeZone.displayName(justDetected))，一致。")
          .runtimeAccessibilityIdentifier("settings.timezone.match")
      }
    }
    .runtimeAccessibilityIdentifier("settings.timezone")
  }
}

/// 启动时检测到本机时区变了:问一次,不自作主张。
///
/// 选「保留」会记住这个值,同一个变化不再反复问;哪天变成第三个时区会重新问。
struct TimeZoneDriftPrompt: ViewModifier {
  @ObservedObject var displayTimeZone: DisplayTimeZone

  func body(content: Content) -> some View {
    content.alert(
      "这台电脑换时区了",
      isPresented: Binding(
        get: { displayTimeZone.drift != nil },
        set: { if !$0 { displayTimeZone.keepPinned() } }
      ),
      presenting: displayTimeZone.drift
    ) { drift in
      Button("改用 \(DisplayTimeZone.displayName(drift.detected))") {
        displayTimeZone.adopt(drift.detected)
      }
      Button("保留 \(DisplayTimeZone.displayName(drift.pinned))", role: .cancel) {
        displayTimeZone.keepPinned()
      }
    } message: { drift in
      Text(
        "会议时间现在按 \(DisplayTimeZone.displayName(drift.pinned)) 显示。"
          + "改用本机时区，已有会议的时间会跟着挪——时刻没变，只是换了个地方的钟看。"
      )
    }
  }
}

extension View {
  func timeZoneDriftPrompt(_ displayTimeZone: DisplayTimeZone) -> some View {
    modifier(TimeZoneDriftPrompt(displayTimeZone: displayTimeZone))
  }
}
