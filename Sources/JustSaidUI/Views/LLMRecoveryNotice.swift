import AppKit
import JustSaidCore
import SwiftUI

public struct RecoverySettingsRequest: Equatable, Identifiable {
  public let id = UUID()
  public let context: LLMFailureContext
  public let action: LLMRecoveryAdvice.Action
  public init(context: LLMFailureContext, action: LLMRecoveryAdvice.Action) {
    self.context = context
    self.action = action
  }
}

@MainActor
public struct LLMRecoveryServices {
  public let settings: ProviderSettingsStore?
  public let navigate: (RecoverySettingsRequest) -> Void
  private let defaults: UserDefaults
  public init(
    settings: ProviderSettingsStore?, defaults: UserDefaults = .standard,
    navigate: @escaping (RecoverySettingsRequest) -> Void
  ) {
    self.settings = settings
    self.navigate = navigate
    self.defaults = defaults
  }
  public var safeSettings: String {
    guard let settings else { return "设置快照不可用；未读取密钥。" }
    return DiagnosticsSettingsSnapshot.render(store: settings, defaults: defaults)
  }
}
private struct LLMRecoveryServicesKey: EnvironmentKey {
  static let defaultValue: LLMRecoveryServices? = nil
}
extension EnvironmentValues {
  public var llmRecoveryServices: LLMRecoveryServices? {
    get { self[LLMRecoveryServicesKey.self] }
    set { self[LLMRecoveryServicesKey.self] = newValue }
  }
}

/// Identity includes the failure and meeting. An old export can finish in its old model,
/// but can never publish its ZIP next to a new failure or another meeting.
public struct LLMRecoveryNotice: View {
  public let advice: LLMRecoveryAdvice
  public var paths: MeetingPaths?
  public var recovering: String?
  public var affectedArea: String?
  public var retry: (() -> Void)?
  private let diagnostics: RecoveryDiagnosticsModel?

  public init(
    advice: LLMRecoveryAdvice, paths: MeetingPaths? = nil, recovering: String? = nil,
    affectedArea: String? = nil, retry: (() -> Void)? = nil,
    diagnostics: RecoveryDiagnosticsModel? = nil
  ) {
    self.advice = advice
    self.paths = paths
    self.recovering = recovering
    self.affectedArea = affectedArea
    self.retry = retry
    self.diagnostics = diagnostics
  }

  public var body: some View {
    RecoveryNoticeContents(
      advice: advice, paths: paths, recovering: recovering, affectedArea: affectedArea,
      retry: retry, diagnostics: diagnostics
    )
    .id(PresentationIdentity(advice: advice, directory: paths?.directory))
  }

  private struct PresentationIdentity: Hashable {
    let advice: LLMRecoveryAdvice
    let directory: URL?
  }
}

/// Every LLM surface uses this small notice and the same actual export flow.
private struct RecoveryNoticeContents: View {
  public let advice: LLMRecoveryAdvice
  public var paths: MeetingPaths?
  public var recovering: String?
  public var affectedArea: String?
  public var retry: (() -> Void)?
  @Environment(\.llmRecoveryServices) private var services
  @State private var showsDetails = false
  @State private var copied = false
  @StateObject private var diagnostics: RecoveryDiagnosticsModel

  public init(
    advice: LLMRecoveryAdvice, paths: MeetingPaths? = nil, recovering: String? = nil,
    affectedArea: String? = nil, retry: (() -> Void)? = nil,
    diagnostics: RecoveryDiagnosticsModel? = nil
  ) {
    self.advice = advice
    self.paths = paths
    self.recovering = recovering
    self.affectedArea = affectedArea
    self.retry = retry
    _diagnostics = StateObject(wrappedValue: diagnostics ?? RecoveryDiagnosticsModel())
  }

  private var version: String { ProviderSettingsView.buildLabel }
  private var supportText: String {
    advice.supportText(version: version) + (diagnostics.failure.map { "\n导出结果：\($0)" } ?? "")
  }
  private var settings: String { services?.safeSettings ?? "设置快照不可用；未读取密钥。" }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      NoticeShell(
        level: .warn, systemImage: "exclamationmark.triangle",
        text:
          "\(affectedArea ?? advice.context.feature.title) · \(recovering ?? advice.message)"
      ) {
        if recovering == nil {
          Button(advice.actionTitle) { perform(advice.action) }
            .buttonStyle(.v1Outline)
            .disabled(diagnostics.isExporting)
            .runtimeAccessibilityIdentifier("recovery.primary.\(advice.action.rawValue)")
        }
        Button("查看详情") { showsDetails.toggle() }
          .buttonStyle(.v1Quiet)
          .runtimeAccessibilityIdentifier("recovery.details")
      }
      if showsDetails {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
          ForEach(advice.steps, id: \.self) {
            Text($0).fixedSize(horizontal: false, vertical: true)
          }
          if advice.channelIssue, services != nil {
            Button("修改本次使用的渠道配置") { perform(.editKey) }.buttonStyle(.v1Quiet)
          }
          if let retry {
            Button("重试…", action: retry).buttonStyle(.v1Quiet)
              .runtimeAccessibilityIdentifier("recovery.retry")
          }
          Text(supportText).textSelection(.enabled).font(Tokens.V1.Text.meta.font)
          HStack {
            Button(copied ? "已复制" : advice.channelIssue ? "复制渠道排查信息" : "复制排查信息") { copy() }
              .buttonStyle(.v1Outline).runtimeAccessibilityIdentifier("recovery.copy")
            Button("导出诊断包") { perform(.exportDiagnostics) }.buttonStyle(.v1Quiet)
              .disabled(diagnostics.isExporting)
          }
        }
        .padding(Tokens.V1.Space.sm)
        .font(Tokens.V1.Text.body.font)
      }
      if diagnostics.isExporting {
        HStack {
          ProgressView().controlSize(.small)
          Text("正在收集诊断资料")
        }
        .runtimeAccessibilityIdentifier("recovery.export.running")
      }
      if let result = diagnostics.result {
        Text("已导出到 \(result.url.path)。请将此诊断包发送给 JustSaid 开发者。")
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        ForEach(result.notes, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
        Button("在 Finder 中显示") { diagnostics.reveal() }.buttonStyle(.v1Quiet)
          .runtimeAccessibilityIdentifier("recovery.export.reveal")
      }
      if let failure = diagnostics.failure {
        Text(failure).foregroundStyle(Tokens.V1.Color.warn)
        HStack {
          Button(diagnostics.canExportGlobal ? "导出全局诊断" : "重新选择保存位置") {
            diagnostics.chooseDestination(
              paths: diagnostics.canExportGlobal ? nil : paths, settings: settings, advice: advice)
          }.buttonStyle(.v1Outline)
          Button("复制排查信息") { copy() }.buttonStyle(.v1Quiet)
        }
      }
    }
    .font(Tokens.V1.Text.meta.font)
    .foregroundStyle(Tokens.V1.Color.ink)
    .background(Tokens.V1.Color.paper)
    .runtimeAccessibilityIdentifier("recovery.notice.\(advice.cause.rawValue)")
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(supportText, forType: .string)
    copied = true
  }
  private func perform(_ action: LLMRecoveryAdvice.Action) {
    switch action {
    case .steps: showsDetails = true
    case .exportDiagnostics:
      diagnostics.chooseDestination(paths: paths, settings: settings, advice: advice)
    case .editKey, .editModel, .editConfiguration, .chooseChannel:
      services?.navigate(.init(context: advice.context, action: action))
    }
  }
}

public struct RecoverySettingsDestination: Equatable {
  public let channelID: String?
  public let role: ProviderRole?
  public let changed: Bool

  public static func resolve(
    _ request: RecoverySettingsRequest, configuration: ProviderConfiguration
  ) -> Self {
    let context = request.context
    let channel = context.channelID.flatMap { configuration.channel(id: $0) }
    let selection = context.role.flatMap { configuration.selection(for: $0) }
    let roleChanged =
      context.role != nil
      && (selection?.channelID != context.channelID
        || selection.map { LLMFailureContext.fingerprint($0.model) } != context.modelFingerprint)
    let endpointChanged =
      channel.map { LLMFailureContext.fingerprint($0.baseURL) != context.endpointFingerprint }
      ?? true
    let providerChanged =
      channel.map { LLMFailureContext.fingerprint($0.providerID) != context.providerFingerprint }
      ?? true
    let changed = channel == nil || roleChanged || endpointChanged || providerChanged
    return Self(
      channelID: request.action == .chooseChannel
        || (request.action == .editModel && context.role != nil) || changed ? nil : channel?.id,
      role: context.role, changed: changed)
  }
}
