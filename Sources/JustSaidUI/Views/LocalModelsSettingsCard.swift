import JustSaidCore
import SwiftUI

public struct LocalModelsSettingsCard: View {
  @ObservedObject var manager: LocalModelAssetManager
  /// 录音中(开始中、记录中、结束中)不能下载或删除本机模型。
  let isRecording: Bool
  /// 点了「删除」、正等确认框回话的那项能力。
  @State private var removalCandidate: String?
  /// 删除被拒绝或没做完时,按能力记下要给用户看的原因。
  @State private var removalErrors: [String: String] = [:]
  /// 删除做成之后告诉调用方是哪项能力(删除 Pro 模型要把 Pro 模式关掉)。
  private let onRemoved: (String) -> Void

  public init(
    manager: LocalModelAssetManager, isRecording: Bool = false,
    onRemoved: @escaping (String) -> Void = { _ in }
  ) {
    self.manager = manager
    self.isRecording = isRecording
    self.onRemoved = onRemoved
  }

  /// 下载、修复与删除共用一道门:录音中,或已有下载/修复/删除作业在跑,三个按钮一起置灰。
  private var actionsLocked: Bool {
    isRecording || manager.isBusy
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
      // Pro 模式的模型(PR-10)。在这里下载只装模型,不打开 Pro 模式。清单里没有这项就不画。
      if manager.snapshot(forCapabilityID: LocalModelKnownIDs.qwenLivePro) != nil {
        assetBlock(
          title: "Qwen3-ASR Pro（1.7B）",
          detail: "可选",
          capabilityID: LocalModelKnownIDs.qwenLivePro,
          identifier: "settings.models.pro",
          removalName: "Qwen3-ASR Pro",
          removalLead: "删除后 Pro 模式关闭，"
        )
      }
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
    // 确认框开着时开始了录音或下载:收起它。不收的话再点「删除」只会被下面的门挡掉,什么都不发生。
    .onChange(of: actionsLocked) { _, locked in
      if locked { removalCandidate = nil }
    }
  }

  @ViewBuilder
  private func assetBlock(
    title: String,
    detail: String,
    capabilityID: String,
    identifier: String,
    removalName: String? = nil,
    removalLead: String = ""
  ) -> some View {
    let snapshot = manager.snapshot(forCapabilityID: capabilityID)
    // 删除只删这项能力独占的资产(共用的 Silero 留下),确认框里的体积也只算这几项。
    let removableBytes = removableDownloadBytes(capabilityID)
    let dialogTitle = "删除 \(removalName ?? title)？"
    let dialogMessage =
      "\(removalLead)需要时可重新下载 \(LocalModelByteDisplay.size(removableBytes))。"
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
            removalErrors[capabilityID] = nil
            Task { await manager.prepare(capabilityID: capabilityID) }
          }
          .buttonStyle(.v1Outline)
          .disabled(actionsLocked)
          .runtimeAccessibilityIdentifier(
            actionsLocked ? "\(identifier).download.disabled" : "\(identifier).download")
        }
        // 必需能力(Qwen)永远没有「删除」;可选能力装着(含需要更新、校验未通过)才有。
        if shouldShowRemove(snapshot, removableBytes: removableBytes) {
          Button("删除") {
            HangSentinel.shared.note("models:settings:remove-request:\(capabilityID)")
            removalErrors[capabilityID] = nil
            removalCandidate = capabilityID
          }
          .buttonStyle(.v1DestructiveText)
          .disabled(actionsLocked)
          .runtimeAccessibilityIdentifier(
            actionsLocked ? "\(identifier).delete.disabled" : "\(identifier).delete")
        }
      }
      Text(
        ([detail]
          + (snapshot.map {
            [
              "下载 \(LocalModelByteDisplay.size($0.downloadBytes))",
              "安装后约 \(LocalModelByteDisplay.size($0.installedBytes))",
            ]
          } ?? []))
          .joined(separator: " · ")
      )
      .font(Tokens.V1.Text.meta.font)
      .foregroundStyle(Tokens.V1.Color.ink3)
      .fixedSize(horizontal: false, vertical: true)
      if let removalError = removalErrors[capabilityID] {
        Text(removalError)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier("\(identifier).delete.error")
      }
    }
    .padding(.vertical, Tokens.V1.Space.s2xs)
    .runtimeAccessibilityIdentifier(identifier)
    .confirmationDialog(
      dialogTitle,
      isPresented: Binding(
        get: { removalCandidate == capabilityID },
        set: { presented in
          if !presented, removalCandidate == capabilityID { removalCandidate = nil }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) {
        removalCandidate = nil
        remove(capabilityID)
      }
      // 设计系统 README:默认按钮是「取消」,回车不能删掉模型。
      Button("取消", role: .cancel) { removalCandidate = nil }
        .keyboardShortcut(.defaultAction)
    } message: {
      Text(dialogMessage)
    }
  }

  private func remove(_ capabilityID: String) {
    // 确认框开着的时候也可能开始录音或开始下载:真动手前再看一次门。
    guard !actionsLocked else { return }
    HangSentinel.shared.note("models:settings:remove:\(capabilityID)")
    removalErrors[capabilityID] = nil
    Task { @MainActor in
      do {
        try await manager.remove(capabilityID: capabilityID)
        onRemoved(capabilityID)
      } catch let error as LocalModelRemoveError {
        removalErrors[capabilityID] = error.userMessage
      } catch {
        removalErrors[capabilityID] = LocalModelRemoveError.removeFailed.userMessage
      }
    }
  }

  private func removableDownloadBytes(_ capabilityID: String) -> Int64 {
    (manager.catalog?.removableAssets(forCapabilityID: capabilityID) ?? [])
      .reduce(into: Int64(0)) { $0 += $1.downloadBytes }
  }

  private func shouldShowRemove(
    _ snapshot: LocalModelCapabilitySnapshot?,
    removableBytes: Int64
  ) -> Bool {
    guard let snapshot, !snapshot.required, removableBytes > 0 else { return false }
    switch snapshot.status {
    case .ready, .updateRequired, .damaged:
      return true
    case .checking, .missing, .configurationFailed:
      return false
    }
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
  let isRecording: Bool
  private let onRemoved: (String) -> Void
  @State private var isManaging = false

  public init(
    manager: LocalModelAssetManager, isRecording: Bool = false,
    onRemoved: @escaping (String) -> Void = { _ in }
  ) {
    self.manager = manager
    self.isRecording = isRecording
    self.onRemoved = onRemoved
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
          .runtimeAccessibilityIdentifier("settings.models.needs-attention")
      }
    }
    .runtimeAccessibilityIdentifier("settings.models")
    .sheet(isPresented: $isManaging) {
      SettingsSheetShell(
        "本机模型",
        subtitle: "由 App 在你确认后下载，不会随 App 更新自动传输",
        onDone: { isManaging = false }
      ) {
        LocalModelsSettingsCard(manager: manager, isRecording: isRecording, onRemoved: onRemoved)
      }
    }
  }

  /// 一行说清「现在装了什么」。全装好就报已装的那个,有缺的就点名缺谁——只点必需的:
  /// 可选的 SenseVoice、Pro 没装是常态,不算缺,装好才进名单(Pro 不带「（1.7B）」)。
  private var summary: String {
    let entries: [(String, LocalModelCapabilitySnapshot?)] = [
      ("Qwen3-ASR", manager.snapshot(forCapabilityID: LocalModelKnownIDs.qwenLive)),
      ("Qwen3-ASR Pro", manager.snapshot(forCapabilityID: LocalModelKnownIDs.qwenLivePro)),
      ("SenseVoice-Small", manager.snapshot(forCapabilityID: LocalModelKnownIDs.sensevoiceLive)),
    ]
    let ready = entries.filter { isReady($0.1) }.map(\.0)
    let missing = entries.filter { $0.1?.required == true && !isReady($0.1) }.map(\.0)
    if !missing.isEmpty {
      return "\(missing.joined(separator: "、")) 未安装"
    }
    if ready.isEmpty {
      return "检查中"
    }
    return "\(ready.joined(separator: "、")) 已安装"
  }

  /// 「有模型未安装」只数必需能力(按快照的 `required`):可选的 SenseVoice、Pro 没装或坏了
  /// 不催,它们在「管理…」里各自显示状态。
  private var needsAttention: Bool {
    manager.capabilityStates.values
      .filter(\.required)
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
