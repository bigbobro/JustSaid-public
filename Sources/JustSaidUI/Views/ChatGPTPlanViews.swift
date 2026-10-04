import AppKit
import JustSaidCore
import SwiftUI

/// OpenAI 原版 ChatGPT 标识(白/黑两版 SVG,`Support/Assets/`,打包时拷进 app 资源)。
/// 截图装置跑在 `.build/` 下没有 app 包,由装置自己注入。
public enum ChatGPTPlanArtwork {
  public static var whiteLogo: NSImage? = Bundle.main.url(
    forResource: "ChatGPTLogoWhite", withExtension: "svg"
  ).flatMap(NSImage.init(contentsOf:))
  public static var blackLogo: NSImage? = Bundle.main.url(
    forResource: "ChatGPTLogoBlack", withExtension: "svg"
  ).flatMap(NSImage.init(contentsOf:))
}

/// 「Continue with ChatGPT」:按 OpenAI 批准格式(浅色黑底白标、深色白底黑标),
/// 设计系统里登记为第三方品牌例外,不当作这一屏的主按钮。
struct ChatGPTContinueButton: View {
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: action) {
      HStack(spacing: Tokens.V1.Space.sm) {
        if let logo = colorScheme == .dark
          ? ChatGPTPlanArtwork.blackLogo : ChatGPTPlanArtwork.whiteLogo
        {
          Image(nsImage: logo)
            .resizable()
            .frame(width: Tokens.V1.Size.chatGPTLogo, height: Tokens.V1.Size.chatGPTLogo)
            .accessibilityHidden(true)
        }
        Text("Continue with ChatGPT")
          .font(Tokens.V1.Text.label.font)
          .lineLimit(1)
      }
      .padding(.horizontal, Tokens.V1.Space.md)
      .frame(height: Tokens.V1.Size.control)
      .foregroundStyle(Tokens.V1.Color.chatGPTButtonInk)
      .background(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm).fill(Tokens.V1.Color.chatGPTButton)
      )
      .contentShape(RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
    }
    .buttonStyle(.plain)
    .runtimeAccessibilityIdentifier("settings.chatgpt.continue")
  }
}

/// 渠道编辑器里 ChatGPT 渠道的账户区:状态、登录/退出、模型目录与用量入口。
/// 只读服务发布的快照,拿不到令牌;登录与退出都在服务里进行。
struct ChatGPTAccountSection: View {
  let channel: ProviderChannel
  @ObservedObject var settingsStore: ProviderSettingsStore
  @ObservedObject var service: ChatGPTPlanService

  @State private var message: String?
  @State private var isRefreshingCatalog = false
  @State private var isSigningOut = false
  @State private var showsPlanConfirmation = false
  @AppStorage("chatgpt-plan.plan-use-confirmed") private var planUseConfirmed = false

  private var snapshot: ChatGPTAccountSnapshot? { service.snapshots[channel.id] }
  private var isSigningIn: Bool { service.signingIn.contains(channel.id) }
  private var isExiting: Bool { isSigningOut || service.signingOut.contains(channel.id) }
  private var currentChannel: ProviderChannel {
    settingsStore.configuration.channel(id: channel.id) ?? channel
  }

  private var statusText: String {
    let email = snapshot?.email.map { "\($0) · " } ?? ""
    if isExiting { return email + "正在退出…" }
    switch snapshot?.state {
    case .ready?: return email + "已开启计划用量"
    case .signedInWithoutPlan?: return email + "已登录，未开启计划用量"
    case .reauthRequired?: return email + "授权已失效，需要重新登录"
    case .cleanupPending?: return email + "本机授权待清理，请重试退出"
    case .signedOut?: return snapshot?.hasRegistration == true ? email + "已退出" : "未登录"
    case nil: return "尚未读取账户状态"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      Text("ChatGPT 账户")
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink3)
      Text(statusText)
        .font(.system(size: Tokens.FontSize.uiEmphasis))
        .foregroundStyle(Tokens.Color.ink2)
        .runtimeAccessibilityIdentifier("settings.chatgpt.status")
      HStack(spacing: Tokens.Spacing.sm) {
        if isSigningIn {
          Text("请在浏览器里完成授权…")
            .font(.system(size: Tokens.FontSize.ui))
            .foregroundStyle(Tokens.Color.ink3)
          Button("取消") { service.cancelSignIn(account: channel.id) }
            .buttonStyle(.textAction)
        } else {
          if snapshot?.state == .ready {
            Button(isRefreshingCatalog ? "刷新中…" : "刷新模型目录") { refreshCatalog() }
              .buttonStyle(.textAction)
              .disabled(isRefreshingCatalog || isExiting)
              .runtimeAccessibilityIdentifier("settings.chatgpt.refresh-catalog")
          } else if snapshot?.state != .cleanupPending {
            ChatGPTContinueButton { signIn() }
              .disabled(isExiting)
          }
          if snapshot?.state == .ready || snapshot?.state == .signedInWithoutPlan
            || snapshot?.state == .cleanupPending
          {
            Button(isExiting ? "正在退出…" : (snapshot?.state == .cleanupPending ? "重试退出" : "退出")) {
              signOut()
            }
            .buttonStyle(.textAction)
            .disabled(isExiting)
            .runtimeAccessibilityIdentifier("settings.chatgpt.sign-out")
          }
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
        Text("选用这个渠道的总结与纪要会使用你的 ChatGPT 计划用量，计入计划或额度。")
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
        Button("管理用量") { NSWorkspace.shared.open(ChatGPTPlanContract.usageSettingsURL) }
          .buttonStyle(.textAction)
          .font(.system(size: Tokens.FontSize.secondary))
          .runtimeAccessibilityIdentifier("settings.chatgpt.manage-usage")
      }
      let models = currentChannel.availableModels
      if !models.isEmpty {
        Text(
          "模型目录："
            + models.map { currentChannel.modelDisplayNames?[$0] ?? $0 }
            .joined(separator: "、")
        )
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
      }
      if let message {
        HintText(text: message)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .runtimeAccessibilityIdentifier("settings.chatgpt.account")
    .task(id: channel.id) { await service.loadSnapshots(accounts: [channel.id]) }
    .onDisappear { service.cancelSignIn(account: channel.id) }
    .alert("你正在使用 ChatGPT 计划用量", isPresented: $showsPlanConfirmation) {
      Button("知道了") { planUseConfirmed = true }
    } message: {
      Text("在 JustSaid 里选用这个渠道的总结与纪要会使用你的 ChatGPT 计划用量，可以在 ChatGPT 设置里管理。")
    }
  }

  private func signIn() {
    message = nil
    // 已登录但没开计划用量:用户再次点击就是主动开启,授权页要求重新同意。
    let requestConsent = snapshot?.state == .signedInWithoutPlan
    Task { @MainActor in
      do {
        let result = try await service.signIn(
          account: channel.id, requestConsent: requestConsent)
        switch result.state {
        case .ready:
          await loadCatalog()
          if !planUseConfirmed { showsPlanConfirmation = true }
        case .signedInWithoutPlan:
          message = "已登录，但授权里没有开启计划用量；需要时再点一次登录，在授权页允许使用计划用量。"
        default:
          break
        }
      } catch ChatGPTAuthorizationError.cancelled {
        message = nil
      } catch {
        message = error.localizedDescription
      }
    }
  }

  private func refreshCatalog() {
    Task { @MainActor in await loadCatalog() }
  }

  private func loadCatalog() async {
    isRefreshingCatalog = true
    defer { isRefreshingCatalog = false }
    do {
      let catalog = try await service.fetchCatalog(account: channel.id)
      try settingsStore.applyChatGPTCatalog(catalog, channelID: channel.id)
      message = catalog.entries.isEmpty ? "当前账户的模型目录是空的" : nil
    } catch {
      message = error.localizedDescription
    }
  }

  private func signOut() {
    isSigningOut = true
    Task { @MainActor in
      defer { isSigningOut = false }
      let result = await service.signOut(account: channel.id)
      if !result.localTokensCleared {
        message = "本机授权未清除。请解锁登录钥匙串，点「重试退出」并在系统弹窗中允许访问。"
      } else if !result.remoteRevocationConfirmed {
        message = "已退出。远端撤销未确认，可以在 ChatGPT 设置里断开本应用。"
      } else {
        message = "已退出。"
      }
    }
  }
}

/// 纪要这一路是否走 ChatGPT 计划用量:「生成纪要」菜单据此改说调用次数,不说「计费」。
private struct MinutesUsesChatGPTPlanKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var minutesUsesChatGPTPlan: Bool {
    get { self[MinutesUsesChatGPTPlanKey.self] }
    set { self[MinutesUsesChatGPTPlanKey.self] = newValue }
  }
}

/// 角色卡里选了 ChatGPT 渠道时的一行:说明用量来源并给「管理用量」入口。不写金额或余额。
struct ChatGPTUsageRow: View {
  var body: some View {
    SettingsFormRow("用量") {
      Text("使用 ChatGPT 计划用量")
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
      Button("管理用量") { NSWorkspace.shared.open(ChatGPTPlanContract.usageSettingsURL) }
        .buttonStyle(.v1Quiet)
        .runtimeAccessibilityIdentifier("settings.role.chatgpt.manage-usage")
    }
  }
}
