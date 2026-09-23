import JustSaidCore
import SwiftUI

/// Compact projection of the existing preparation state machine, without a second task owner.
public struct HomeModelPreparationView: View {
  @ObservedObject var manager: LocalModelAssetManager
  let capabilityID: String?
  let onStart: () -> Void

  private var snapshot: LocalModelCapabilitySnapshot? {
    capabilityID.flatMap { manager.snapshot(forCapabilityID: $0) }
  }

  public init(manager: LocalModelAssetManager, capabilityID: String?, onStart: @escaping () -> Void)
  {
    self.manager = manager
    self.capabilityID = capabilityID
    self.onStart = onStart
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
      if let error = manager.configurationError {
        Text(error).foregroundStyle(Tokens.V1.Color.warn)
      } else {
        switch manager.preparation {
        case .running(_, let phase):
          HStack(spacing: Tokens.V1.Space.s2xs) {
            Text("正在准备本机模型").lineLimit(1)
            Spacer(minLength: 0)
            Button("取消") { manager.cancelActivePreparation() }
              .buttonStyle(.v1Quiet)
              .runtimeAccessibilityIdentifier("home.models.cancel")
          }
          if case .downloading(_, let received, let total) = phase, let total, total > 0 {
            ProgressView(value: min(1, Double(received) / Double(total)))
              .runtimeAccessibilityIdentifier("home.models.progress")
          } else {
            ProgressView().controlSize(.small)
              .runtimeAccessibilityIdentifier("home.models.progress")
          }
        case .failed(_, _, let reason, let retryable):
          Text(reason).foregroundStyle(Tokens.V1.Color.warn).lineLimit(2).help(reason)
          if retryable {
            Button("重试", action: prepare).buttonStyle(.v1Outline)
              .runtimeAccessibilityIdentifier("home.models.retry")
          }
        case .idle:
          if snapshot?.isReady == true {
            // 和首页那颗「开始记录」同一个槽位、同一个规格(主入口档:墨青实底、44 高、撑满卡宽)。
            // 同一个位置出现过 48 / 36 / 28 三种高度,这里不再自己定。
            Button(action: onStart) {
              Label("开始记录", systemImage: "waveform")
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(V1ButtonStyle.v1Entry)
            .help("开始记录  ⌘R")
            .runtimeAccessibilityIdentifier("home.start-recording")
          } else if snapshot == nil || snapshot?.status == .checking {
            HStack(spacing: Tokens.V1.Space.xs) {
              ProgressView().controlSize(.small)
              Text("正在检查本机模型")
            }
          } else {
            Button(repairNeeded ? "重新下载并修复" : "下载并安装", action: prepare)
              .buttonStyle(.v1Outline)
              .runtimeAccessibilityIdentifier("home.models.download")
          }
        }
      }
    }
    .font(Tokens.V1.Text.meta.font)
    .runtimeAccessibilityIdentifier("home.models")
  }

  private var repairNeeded: Bool {
    switch snapshot?.status {
    case .damaged, .updateRequired: return true
    default: return false
    }
  }

  private func prepare() {
    guard let capabilityID else { return }
    HangSentinel.shared.note("home:models:prepare")
    Task { await manager.prepare(capabilityID: capabilityID) }
  }
}
