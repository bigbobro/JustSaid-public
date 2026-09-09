import JustSaidCore
import SwiftUI

public struct LocalModelsSettingsCard: View {
  @ObservedObject var manager: LocalModelAssetManager

  public init(manager: LocalModelAssetManager) {
    self.manager = manager
  }

  public var body: some View {
    RoleCardShell(title: "本机模型", subtitle: "会中速记模型由 App 在你确认后下载，不会随 App 更新自动传输") {
      assetBlock(
        title: "Qwen3-ASR 与 Silero VAD",
        detail: "默认完整能力",
        capabilityID: LocalModelKnownIDs.qwenLive,
        identifier: "settings.models.qwen"
      )
      assetBlock(
        title: "SenseVoice-Small",
        detail: "可选引擎。取消或失败不会改变当前会中速记选择。",
        capabilityID: LocalModelKnownIDs.sensevoiceLive,
        identifier: "settings.models.sensevoice"
      )
      VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
        Text("Apple SpeechAnalyzer")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink)
        Text("语言资源由 macOS 管理，不占用 JustSaid 模型下载。")
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink3)
      }
      .runtimeAccessibilityIdentifier("settings.models.apple")
    }
    .runtimeAccessibilityIdentifier("settings.models")
  }

  @ViewBuilder
  private func assetBlock(
    title: String,
    detail: String,
    capabilityID: String,
    identifier: String
  ) -> some View {
    let snapshot = manager.snapshot(forCapabilityID: capabilityID)
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      Text(title)
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink)
      Text(detail)
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.ink3)
      Text(statusText(snapshot))
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink2)
      if let snapshot {
        Text(
          "下载 \(LocalModelByteDisplay.megabytes(snapshot.downloadBytes)) · 安装后约 \(LocalModelByteDisplay.megabytes(snapshot.installedBytes))"
        )
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.ink3)
      }
      if shouldShowDownload(snapshot) {
        Button(actionTitle(snapshot)) {
          HangSentinel.shared.note("models:settings:prepare:\(capabilityID)")
          Task { await manager.prepare(capabilityID: capabilityID) }
        }
        .buttonStyle(.toolbarPill)
        .disabled(manager.isBusy)
        .runtimeAccessibilityIdentifier("\(identifier).download")
      }
    }
    .runtimeAccessibilityIdentifier(identifier)
  }

  private func statusText(_ snapshot: LocalModelCapabilitySnapshot?) -> String {
    switch snapshot?.status {
    case .checking, nil:
      return "检查中"
    case .ready:
      return "已安装"
    case .missing:
      return "未安装"
    case .updateRequired:
      return "需要更新"
    case .damaged:
      return "校验未通过"
    case .configurationFailed:
      return "配置不可用"
    }
  }

  private func shouldShowDownload(_ snapshot: LocalModelCapabilitySnapshot?) -> Bool {
    switch snapshot?.status {
    case .missing, .updateRequired, .damaged:
      return true
    default:
      return false
    }
  }

  private func actionTitle(_ snapshot: LocalModelCapabilitySnapshot?) -> String {
    switch snapshot?.status {
    case .damaged, .updateRequired:
      return "重新下载并修复"
    default:
      return "下载并安装"
    }
  }
}
