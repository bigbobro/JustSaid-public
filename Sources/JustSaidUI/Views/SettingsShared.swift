import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-20 批4 拆分:自 ProviderSettingsView.swift 机械迁出,零行为变更。
// MARK: - 卡片外壳

struct RoleCardShell<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.smd) {
      VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
        Text(title)
          .font(.system(size: Tokens.FontSize.cardTitle, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink)
        Text(subtitle)
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink3)
      }
      content()
    }
    .padding(Tokens.Spacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardShell()
    .tokenShadow(Tokens.Shadow.sh1)
  }
}

struct LabeledField<Content: View>: View {
  let label: String
  /// 传入被编辑的值:它一变就说明已经落盘了,旁边闪一下「已保存」。
  var savedTrigger: String?
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      HStack(spacing: Tokens.Spacing.xs) {
        Text(label)
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink3)
        if let savedTrigger {
          SavedFlashLabel(trigger: savedTrigger)
        }
      }
      content()
        .textFieldStyle(.plain)
        .font(.system(size: Tokens.FontSize.body))
        .padding(.horizontal, Tokens.Spacing.xsm)
        .padding(.vertical, Tokens.Spacing.xs)
        .insetPanel()
        .accessibilityLabel(label)
    }
  }
}

struct HintText: View {
  let text: String

  var body: some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.system(size: Tokens.FontSize.secondary))
      .foregroundStyle(Tokens.Color.warn)
  }
}

// MARK: - 自动保存的两层回执

/// 字段级回执:值一变就淡入「已保存」,停手 1.5 秒后淡出。
///
/// 设置页没有保存键,所有非密钥字段随打随存(`ProviderSettingsStore.update` 每次都落盘)。
/// 但「静默地存了」和「没存」在屏幕上长得一模一样——用户 2026-07-29 实测就卡在这:
/// 失焦之后无从判断到底存没存。这一闪就是那句缺失的回答。
struct SavedFlashLabel: View {
  /// 保存回执统一时长(批4):字段级「已保存」与词典卡青闪共用一个常量。
  static let flashDuration: TimeInterval = 1.5

  let trigger: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isVisible = false
  @State private var hideTask: Task<Void, Never>?

  var body: some View {
    Label("已保存", systemImage: "checkmark.circle.fill")
      .font(.system(size: Tokens.FontSize.caption))
      .foregroundStyle(Tokens.Color.ac)
      // 用 opacity 而不是条件插入:提示出现/消失不会把这一行的高度顶来顶去。
      .opacity(isVisible ? 1 : 0)
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.revealIn), value: isVisible)
      .accessibilityHidden(!isVisible)
      .onChange(of: trigger) { _, _ in
        isVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
          try? await Task.sleep(for: .seconds(Self.flashDuration))
          guard !Task.isCancelled else { return }
          isVisible = false
        }
      }
  }
}

/// 区块级回执的文案拼装。
///
/// 纯函数,不碰视图:`UIHierarchyVerification` 直接断言它拼出来的句子,
/// 这样「回执行有没有、写没写对」是被真的验过,而不是只验了"这块布局没崩"。
public enum ProviderEffectiveSummary {
  /// `当前生效:api.siliconflow.cn · deepseek-ai/DeepSeek-V3 · key ····ddqe · 保存于 14:32`
  /// 空段自动省略;`savedAt` 只在本次会话里真发生过保存时才有值,不知道就不写。
  public static func text(segments: [String?], savedAt: Date? = nil) -> String {
    var parts = segments.compactMap { segment -> String? in
      guard let segment, !segment.isEmpty else { return nil }
      return segment
    }
    if parts.isEmpty {
      return "当前生效：还没有配置"
    }
    if let savedAt {
      parts.append("保存于 \(timeLabel(savedAt))")
    }
    return "当前生效：" + parts.joined(separator: " · ")
  }

  /// 回执里只显示主机名:完整 URL 太长,一行装不下反而看不清是哪一家。
  public static func host(from baseURL: String) -> String {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return URL(string: trimmed)?.host ?? trimmed
  }

  public static func keySegment(label: String, suffix: String?) -> String {
    guard let suffix, !suffix.isEmpty else {
      return "\(label) 未填"
    }
    return "\(label) ····\(suffix)"
  }

  private static func timeLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}

/// 角色卡片底部常驻的一行「当前生效」。
///
/// 刻意读**已存值**渲染(设置存档 + Keychain 末四位),而不是表单里正在敲的东西:
/// 用户要的是「到底什么在生效」,不是「我刚打了什么」。
struct EffectiveConfigurationRow: View {
  let summary: String
  var pendingWarning: String?

  var body: some View {
    HStack(alignment: .top, spacing: Tokens.Spacing.xxs) {
      Image(systemName: pendingWarning == nil ? "checkmark.seal" : "exclamationmark.triangle.fill")
        .font(.system(size: Tokens.FontSize.caption))
      Text(pendingWarning ?? summary)
        .font(.system(size: Tokens.FontSize.secondary))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .foregroundStyle(pendingWarning == nil ? Tokens.Color.ink3 : Tokens.Color.warn)
    .padding(.horizontal, Tokens.Spacing.xsm)
    .padding(.vertical, Tokens.Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Tokens.Radius.control)
        .fill(pendingWarning == nil ? Tokens.Color.surface2 : Tokens.Color.amber)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.control)
        .stroke(
          pendingWarning == nil ? Tokens.Color.surface2Line : Tokens.Color.amberLine,
          lineWidth: 1
        )
    )
    .accessibilityElement(children: .combine)
  }
}

/// 密钥行：已保存时只显示徽章 + 末四位；点“更改”才重新露出输入框（密钥永不回显全文）。
/// 保存失败保留草稿与输入框，并就地给出钥匙串失败原因；成功才清草稿收起。
struct SecretRow: View {
  let label: String
  let isSaved: Bool
  let suffix: String?
  @Binding var draft: String
  let onSave: () throws -> Void

  @State private var isEditing = false
  @State private var saveError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      Text(label)
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink3)

      if isSaved && !isEditing {
        HStack(spacing: Tokens.Spacing.sm) {
          Label("已保存 ····\(suffix ?? "")", systemImage: "checkmark.shield.fill")
            .font(.system(size: Tokens.FontSize.uiEmphasis))
            .foregroundStyle(Tokens.Color.ac)
          Button("更改") {
            saveError = nil
            isEditing = true
          }
          .buttonStyle(.textAction)
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink3)
        }
      } else {
        HStack(spacing: Tokens.Spacing.xs) {
          SecureField("粘贴密钥", text: $draft)
            .textFieldStyle(.plain)
            .padding(.horizontal, Tokens.Spacing.xsm)
            .padding(.vertical, Tokens.Spacing.xs)
            .insetPanel()
            .accessibilityLabel(label)
          Button("保存") {
            do {
              try onSave()
              draft = ""
              isEditing = false
              saveError = nil
            } catch {
              saveError = Self.saveFailureText(error)
            }
          }
          .buttonStyle(.textAction)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if isSaved && isEditing {
            Button("取消") {
              draft = ""
              isEditing = false
              saveError = nil
            }
            .buttonStyle(.textAction)
            .font(.system(size: Tokens.FontSize.ui))
            .foregroundStyle(Tokens.Color.ink3)
            .runtimeAccessibilityIdentifier("settings.secret.cancel")
          }
        }
        if let saveError {
          HintText(text: saveError)
            .fixedSize(horizontal: false, vertical: true)
            .runtimeAccessibilityIdentifier("settings.secret.save-error")
        }
      }
    }
  }

  private static func saveFailureText(_ error: Error) -> String {
    "密钥未能写入钥匙串：\(error.localizedDescription)"
  }
}

// MARK: - LLM 测试连接（真实请求）

/// 一次「测试连接」的四种呈现状态。
public enum ConnectionTestState: Equatable, Sendable {
  case idle
  case running
  /// 拿到了非空回复:记下往返耗时与回复开头,让用户一眼确认「答话的确实是我选的那个模型」。
  case succeeded(latencyMilliseconds: Int, replyPreview: String)
  /// 失败原样呈现服务端说法(含 402/403 的响应体)——用户要靠它分辨是没积分还是没权限。
  case failed(message: String)

  var isRunning: Bool { self == .running }
}

/// 测试连接文案:LLM 探针与对象存储 HEAD 自检共用四态行,措辞不同。
public enum ConnectionTestKind: Equatable, Sendable {
  case llm
  case storage
}

/// 渠道编辑器里的「测试连接」一行:按钮 + 结果。
///
/// 公开是为了让 `UIHierarchyVerification` 能把成功/失败/进行中三态直接摆出来布局,
/// 而不必真的发一次网络请求(红线:验证不做真实云端调用)。
public struct ConnectionTestRow: View {
  private let state: ConnectionTestState
  private let kind: ConnectionTestKind
  private let action: (() -> Void)?

  public init(
    state: ConnectionTestState = .idle,
    kind: ConnectionTestKind = .llm,
    action: (() -> Void)? = nil
  ) {
    self.state = state
    self.kind = kind
    self.action = action
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      HStack(spacing: Tokens.Spacing.xsm) {
        Button(state.isRunning ? "测试中…" : "测试连接") {
          action?()
        }
        .buttonStyle(.toolbarPill)
        .disabled(state.isRunning || action == nil)
        if state.isRunning {
          BreathingDots()
        }
      }
      resultView
    }
  }

  @ViewBuilder
  private var resultView: some View {
    switch state {
    case .idle:
      EmptyView()
    case .running:
      Text(
        kind == .storage
          ? "正在检查对象存储连接…最多等 15 秒。"
          : "正在发一条最短的英文问句，等模型回话…最多等 30 秒。"
      )
      .font(.system(size: Tokens.FontSize.ui))
      .foregroundStyle(Tokens.Color.ink3)
    case .succeeded(let latency, let preview):
      HStack(alignment: .top, spacing: Tokens.Spacing.xxs) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ac)
        VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
          Text(kind == .storage ? "连接成功" : "连接成功 · \(latency) ms")
            .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
            .foregroundStyle(Tokens.Color.acDeep)
          Text(kind == .storage ? preview : "模型回话：\(preview)")
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityElement(children: .combine)
    case .failed(let message):
      HStack(alignment: .top, spacing: Tokens.Spacing.xxs) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: Tokens.FontSize.ui))
        // 服务端原文照登、可选中复制:吞掉它等于让用户去猜自己是欠费还是没开权限。
        Text(message)
          .font(.system(size: Tokens.FontSize.secondary))
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      .foregroundStyle(Tokens.Color.warn)
      .accessibilityElement(children: .combine)
    }
  }
}

/// 「测试连接」实际发出的那一次调用。
///
/// 刻意不复用 `makeLLMClient` 自带的超时:会后纪要角色的超时是 600 秒(长文纪要要那么久),
/// 但配置页面等十分钟毫无意义。这里统一在外面卡 30 秒。
enum ConnectionProbe {
  struct TimedOut: LocalizedError {
    var errorDescription: String? { "测试连接超时：30 秒内没有收到回复" }
  }

  /// 用户拍板的探针内容:system 留空,user 是一句最短的英文自我介绍请求。
  static let request = LLMRequest(
    systemPrompt: "",
    userPrompt: "Hello, please reply with one short sentence: which model are you?"
  )

  static func run(
    _ client: any LLMClient,
    timeout: TimeInterval = 30
  ) async throws -> LLMResponse {
    try await withThrowingTaskGroup(of: LLMResponse.self) { group in
      group.addTask {
        try await client.complete(request)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(timeout))
        throw TimedOut()
      }
      guard let first = try await group.next() else {
        throw TimedOut()
      }
      group.cancelAll()
      return first
    }
  }

  /// 回复只取前 60 字符、并把换行压成空格,免得一段长回答把卡片撑开。
  static func preview(of text: String, limit: Int = 60) -> String {
    let flattened =
      text
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return flattened.count <= limit ? flattened : String(flattened.prefix(limit)) + "…"
  }
}
