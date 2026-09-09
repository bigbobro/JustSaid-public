import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-21 批0 拆分:自 MainWorkspaceView.swift 按 MARK 边界机械迁出,零行为变更.
extension MainWorkspaceView {

  func applyWorkspaceSheets<Content: View>(_ content: Content) -> some View {
    content
      .sheet(isPresented: $isShowingSettings) {
        ProviderSettingsView(
          registry: registry,
          settingsStore: providerSettings,
          modelAssetManager: modelAssetManager
        )
        // 词典页会随词表变长，写死高度就意味着长词表被裁掉；
        // 给下限与理想值、放开上限，让内容说了算。
        .frame(minWidth: 760, minHeight: 620, idealHeight: 680, maxHeight: .infinity)
      }
      // 废弃是不可逆的，删掉的是真录音。必须明说删什么、且默认按钮不是「废弃」。
      .confirmationDialog(
        "废弃这场会议？",
        isPresented: $isConfirmingDiscard,
        titleVisibility: .visible
      ) {
        Button("废弃并删除", role: .destructive) {
          discardMeeting()
        }
        Button("继续录", role: .cancel) {}
      } message: {
        Text(
          "会停止录音，且不做会后精转、不生成纪要（不产生云端费用）。"
            + "本场的录音、速记与补充记录会一并删除，无法恢复。"
        )
      }
      // 散会兜底(PRD 硬要求):开区间忘封口 = start 之后整场不进纪要。
      // 「封口并结束」是默认动作;「撤销」留给误触开关的情况。
      .confirmationDialog(
        "还有一段闲聊没有结束",
        isPresented: $isConfirmingChatClose,
        titleVisibility: .visible
      ) {
        Button("封口并结束会议") {
          closeChatExclusion()
          endMeeting()
        }
        .keyboardShortcut(.defaultAction)
        Button("撤销这段排除并结束", role: .destructive) {
          if let range = openChatRange {
            removeExclusion(id: range.id)
          }
          endMeeting()
        }
        Button("返回继续录", role: .cancel) {}
      } message: {
        Text(
          "不封口的话，从 \(openChatRange.map { TranscriptAnchor(seconds: $0.start).timecode } ?? "标记处") 起到会议结束的内容都不会进纪要。"
        )
      }
      .alert(item: issueBinding) { issue in
        if let destination = issue.settingsDestination {
          Alert(
            title: Text(issue.title),
            message: Text(issue.message),
            primaryButton: .default(Text("打开系统设置")) {
              openSystemSettings(destination)
            },
            secondaryButton: .cancel(Text("知道了"))
          )
        } else {
          Alert(
            title: Text(issue.title),
            message: Text(issue.message),
            dismissButton: .default(Text("知道了"))
          )
        }
      }

  }

  private var issueBinding: Binding<RecordingSessionIssue?> {
    Binding(
      get: {
        // 录音异常是唯一允许打断用户的情况（ui-spec §6）；速记引擎异常改走
        // 转写区的降级细带，不弹出会打断当前操作的对话框。
        recordingSession.phase == .failed ? recordingSession.issue : nil
      },
      set: { issue in
        if issue == nil {
          recordingSession.dismissIssue()
        }
      }
    )
  }

  private func openSystemSettings(
    _ destination: RecordingSettingsDestination
  ) {
    let anchor =
      switch destination {
      case .microphone:
        "Privacy_Microphone"
      case .systemAudio:
        "Privacy_ScreenCapture"
      }
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
