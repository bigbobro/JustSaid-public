import JustSaidCore
import SwiftUI

/// 准备页可见性判定。抽成非泛型纯函数是为了能被探针逐格断言:
/// 「用户主动进库后不再被准备页顶回来」这条靠 headless 渲染探针点不到,
/// 而它正是"缺模型时整个 App 只剩一个下载页"的那条 bug。
public enum ModelPreparationVisibility {
  public static func shouldShow(
    gate: LocalModelStartGateDecision,
    isRecordingOrStarting: Bool,
    sessionActive: Bool,
    dismissed: Bool
  ) -> Bool {
    if isRecordingOrStarting { return false }
    if sessionActive { return true }
    if dismissed { return false }
    switch gate {
    case .ready, .systemManaged:
      return false
    case .waitForLocalCheck, .showPreparation, .configurationFailed:
      return true
    }
  }
}

public struct ModelPreparationView: View {
  @ObservedObject var manager: LocalModelAssetManager
  let capabilityID: String
  let onDownload: () -> Void
  let onCancel: () -> Void
  let onRetry: () -> Void
  let onOpenLibrary: () -> Void
  let onOpenSettings: () -> Void
  let onStartMeeting: () -> Void

  public init(
    manager: LocalModelAssetManager,
    capabilityID: String,
    onDownload: @escaping () -> Void,
    onCancel: @escaping () -> Void,
    onRetry: @escaping () -> Void,
    onOpenLibrary: @escaping () -> Void,
    onOpenSettings: @escaping () -> Void,
    onStartMeeting: @escaping () -> Void
  ) {
    self.manager = manager
    self.capabilityID = capabilityID
    self.onDownload = onDownload
    self.onCancel = onCancel
    self.onRetry = onRetry
    self.onOpenLibrary = onOpenLibrary
    self.onOpenSettings = onOpenSettings
    self.onStartMeeting = onStartMeeting
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
      Text(title)
        .font(.system(size: Tokens.FontSize.pageTitle, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink)
      Text(subtitle)
        .font(.system(size: Tokens.FontSize.body))
        .foregroundStyle(Tokens.Color.ink2)
        .fixedSize(horizontal: false, vertical: true)

      sizeBlock
      stageBlock
      actionRow
      navigationRow
    }
    .padding(Tokens.Spacing.xxl)
    .frame(maxWidth: 720, alignment: .leading)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Tokens.Color.bg)
    .runtimeAccessibilityIdentifier("models.preparation")
  }

  private var snapshot: LocalModelCapabilitySnapshot? {
    manager.snapshot(forCapabilityID: capabilityID)
  }

  private var title: String {
    snapshot?.displayName ?? "会中速记模型"
  }

  private var subtitle: String {
    if manager.configurationError != nil {
      return manager.configurationError ?? "应用缺少可用的模型清单，请重装 JustSaid。"
    }
    switch snapshot?.status {
    case .checking, nil:
      return "正在检查本机已有模型，不会联网。"
    case .ready:
      return "模型已就绪。开始会议仍走同一道检查，不会自动开录。"
    case .updateRequired:
      return "本机模型需要更新。只有你明确下载后才会联网。"
    case .damaged:
      return "本机模型校验未通过。重新下载并修复前不会改动现有文件。"
    case .missing:
      return "需要联网下载锁定的公开模型。下载与安装前可进入会议库或设置。"
    case .configurationFailed(let reason):
      return reason
    }
  }

  @ViewBuilder
  private var sizeBlock: some View {
    if let snapshot {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
        Text(
          "预计下载 \(LocalModelByteDisplay.megabytes(snapshot.missingDownloadBytes == 0 ? snapshot.downloadBytes : snapshot.missingDownloadBytes))，安装后约 \(LocalModelByteDisplay.megabytes(snapshot.missingInstalledBytes == 0 ? snapshot.installedBytes : snapshot.missingInstalledBytes))。"
        )
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink2)
        Text("需要联网。不会请求 GitHub API、latest 或任何带认证的地址。")
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink3)
      }
    }
  }

  @ViewBuilder
  private var stageBlock: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
      Text(stageText)
        .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink)
        .runtimeAccessibilityIdentifier("models.preparation.progress")
      if case .running(_, .downloading(_, let received, let total)) = manager.preparation {
        ProgressView(value: progressValue(received: received, total: total))
          .progressViewStyle(.linear)
        Text(progressLabel(received: received, total: total))
          .font(.system(size: Tokens.FontSize.secondary, design: .monospaced))
          .foregroundStyle(Tokens.Color.ink3)
      }
      if case .failed(_, _, let message, _) = manager.preparation {
        Text(message)
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var stageText: String {
    if manager.configurationError != nil {
      return "配置不可用"
    }
    switch manager.preparation {
    case .idle:
      switch snapshot?.status {
      case .checking, nil: return "正在检查本机模型"
      case .ready: return "已就绪"
      case .missing: return "等待下载"
      case .updateRequired: return "需要更新"
      case .damaged: return "需要修复"
      case .configurationFailed: return "配置不可用"
      }
    case .running(_, let phase):
      return phaseLabel(phase)
    case .failed:
      return "失败，可重试"
    }
  }

  private func phaseLabel(_ phase: LocalModelPreparationPhase) -> String {
    switch phase {
    case .preflightingSpace:
      return "正在检查磁盘空间"
    case .downloading(let assetID, _, _):
      return "正在下载 \(assetID)"
    case .verifyingArchive:
      return "正在校验压缩包"
    case .inspectingArchive:
      return "正在检查压缩包内容"
    case .extracting:
      return "正在解包"
    case .verifyingInstalledFiles:
      return "正在校验安装文件"
    case .installing:
      return "正在安装"
    }
  }

  private func progressValue(received: Int64, total: Int64?) -> Double {
    guard let total, total > 0 else { return 0 }
    return min(1, Double(received) / Double(total))
  }

  private func progressLabel(received: Int64, total: Int64?) -> String {
    if let total {
      return
        "\(LocalModelByteDisplay.megabytes(received)) / \(LocalModelByteDisplay.megabytes(total))"
    }
    return LocalModelByteDisplay.megabytes(received)
  }

  @ViewBuilder
  private var actionRow: some View {
    HStack(spacing: Tokens.Spacing.sm) {
      switch manager.preparation {
      case .running:
        Button("取消") { onCancel() }
          .buttonStyle(.toolbarPill)
          .runtimeAccessibilityIdentifier("models.preparation.cancel")
      case .failed(_, _, _, let retryable):
        if retryable {
          Button("重试") { onRetry() }
            .buttonStyle(.toolbarPillAccent)
            .runtimeAccessibilityIdentifier("models.preparation.retry")
        }
      case .idle:
        if snapshot?.isReady == true {
          Button("开始会议") { onStartMeeting() }
            .buttonStyle(.toolbarPillAccent)
            .runtimeAccessibilityIdentifier("models.preparation.start-meeting")
        } else if manager.configurationError == nil {
          Button(primaryActionTitle) { onDownload() }
            .buttonStyle(.toolbarPillAccent)
            .runtimeAccessibilityIdentifier("models.preparation.download")
        }
      }
    }
  }

  private var primaryActionTitle: String {
    switch snapshot?.status {
    case .damaged, .updateRequired:
      return "重新下载并修复"
    default:
      return "下载并安装"
    }
  }

  private var navigationRow: some View {
    HStack(spacing: Tokens.Spacing.sm) {
      Button("进入会议库") { onOpenLibrary() }
        .buttonStyle(.toolbarPill)
        .runtimeAccessibilityIdentifier("models.preparation.open-library")
      Button("打开设置") { onOpenSettings() }
        .buttonStyle(.toolbarPill)
        .runtimeAccessibilityIdentifier("models.preparation.open-settings")
    }
  }
}
