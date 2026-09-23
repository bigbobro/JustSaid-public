import JustSaidCore
import SwiftUI

public struct LocalModelsSettingsCard: View {
  @ObservedObject var manager: LocalModelAssetManager

  public init(manager: LocalModelAssetManager) {
    self.manager = manager
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
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
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        Text("苹果系统语音识别")
          .font(Tokens.V1.Text.label.font)
          .foregroundStyle(Tokens.V1.Color.ink)
        Text("语言资源由 macOS 管理，不占用 JustSaid 模型下载。")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
      }
      .padding(.vertical, Tokens.V1.Space.s2xs)
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
    // 原来一个模型堆四行:名称、说明、状态、体积,各占一行,三个模型就是十二行。
    // 收成两行——第一行「名称 + 状态 + 动作」,第二行「说明 · 体积」。
    // 状态贴在名称后面而不是另起一行:你找的是「这个装了没有」,不是一份状态清单。
    VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
      HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
        Text(title)
          .font(Tokens.V1.Text.label.font)
          .foregroundStyle(Tokens.V1.Color.ink)
        Text(statusText(snapshot))
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(
            shouldShowDownload(snapshot) ? Tokens.V1.Color.warn : Tokens.V1.Color.ink3)
        Spacer(minLength: Tokens.V1.Space.xs)
        if shouldShowDownload(snapshot) {
          Button(actionTitle(snapshot)) {
            HangSentinel.shared.note("models:settings:prepare:\(capabilityID)")
            Task { await manager.prepare(capabilityID: capabilityID) }
          }
          .buttonStyle(.v1Outline)
          .disabled(manager.isBusy)
          .runtimeAccessibilityIdentifier("\(identifier).download")
        }
      }
      Text(
        ([detail]
          + (snapshot.map {
            [
              "下载 \(LocalModelByteDisplay.megabytes($0.downloadBytes))",
              "安装后约 \(LocalModelByteDisplay.megabytes($0.installedBytes))",
            ]
          } ?? []))
          .joined(separator: " · ")
      )
      .font(Tokens.V1.Text.meta.font)
      .foregroundStyle(Tokens.V1.Color.ink3)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, Tokens.V1.Space.s2xs)
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


/// 会中速记组里的「本机模型」一行。设计稿(`settings-models.html`)把它并进了这一组:
/// 它就是这个角色要用的东西,不是另一张卡。三个模型的清单收进浮层——
/// 装好之后你不会再看它,只会在没装的时候来一次。
public struct LocalModelsSettingsRow: View {
  @ObservedObject var manager: LocalModelAssetManager
  @State private var isManaging = false

  public init(manager: LocalModelAssetManager) {
    self.manager = manager
  }

  public var body: some View {
    SettingsFormRow("本机模型", labelDetail: summary) {
      Button("管理…") { isManaging = true }
        .buttonStyle(.v1Outline)
        .runtimeAccessibilityIdentifier("settings.models.manage")
      if needsAttention {
        Text("有模型未安装")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.warn)
      }
    }
    .runtimeAccessibilityIdentifier("settings.models")
    .sheet(isPresented: $isManaging) {
      SettingsSheetShell(
        "本机模型",
        subtitle: "由 App 在你确认后下载，不会随 App 更新自动传输",
        onDone: { isManaging = false }
      ) {
        LocalModelsSettingsCard(manager: manager)
      }
    }
  }

  /// 一行说清「现在装了什么」。全装好就报已装的那个,有缺的就点名缺谁。
  private var summary: String {
    let entries: [(String, LocalModelCapabilitySnapshot?)] = [
      ("Qwen3-ASR", manager.snapshot(forCapabilityID: LocalModelKnownIDs.qwenLive)),
      ("SenseVoice-Small", manager.snapshot(forCapabilityID: LocalModelKnownIDs.sensevoiceLive)),
    ]
    let ready = entries.filter { isReady($0.1) }.map(\.0)
    let missing = entries.filter { $0.1 != nil && !isReady($0.1) }.map(\.0)
    if !missing.isEmpty {
      return "\(missing.joined(separator: "、")) 未安装"
    }
    if ready.isEmpty {
      return "检查中"
    }
    return "\(ready.joined(separator: "、")) 已安装"
  }

  private var needsAttention: Bool {
    [LocalModelKnownIDs.qwenLive, LocalModelKnownIDs.sensevoiceLive]
      .compactMap { manager.snapshot(forCapabilityID: $0) }
      .contains { snapshot in
        switch snapshot.status {
        case .ready, .checking: return false
        default: return true
        }
      }
  }

  /// `.ready` 带关联值(revision/validatedFiles),只能模式匹配,不能 `==`。
  private func isReady(_ snapshot: LocalModelCapabilitySnapshot?) -> Bool {
    guard let snapshot else { return false }
    if case .ready = snapshot.status { return true }
    return false
  }
}
