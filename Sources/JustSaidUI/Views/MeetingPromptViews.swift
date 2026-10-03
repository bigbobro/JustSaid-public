import AppKit
import JustSaidCore
import SwiftUI

/// 会议提醒胶囊（设计系统「会议提醒胶囊」）：和点名强提醒同一套深色胶囊，
/// 图标 + App 名 + 时间，后面跟按钮。开始提醒与结束提醒两种。
struct MeetingPromptCapsule: View {
  let prompt: MeetingPrompt
  let icon: NSImage?
  let canExclude: Bool
  var onStart: () -> Void = {}
  var onIgnore: () -> Void = {}
  var onNever: () -> Void = {}
  var onEnd: () -> Void = {}
  var onContinue: () -> Void = {}
  var onScopeSwitch: () -> Void = {}
  var onScopeDismiss: () -> Void = {}
  var showsShadow = true

  @ViewBuilder
  var body: some View {
    if showsShadow {
      capsule
        .tokenShadow(Tokens.V1.Shadow.floatNear)
        .tokenShadow(Tokens.V1.Shadow.floatFar)
    } else {
      capsule
    }
  }

  private var capsule: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      appIcon
      label
      Rectangle()
        .fill(Tokens.V1.Color.handleRule2)
        .frame(width: Tokens.V1.Size.controlRuleWidth, height: Tokens.V1.Space.md)
        .accessibilityHidden(true)
      buttons
    }
    .padding(.leading, Tokens.V1.Space.sm)
    .padding(.trailing, Tokens.V1.Space.s2xs)
    .frame(height: MeetingPresenceMetrics.strongPillHeight)
    .background(Tokens.V1.Color.handle, in: Capsule())
    .overlay {
      Capsule().strokeBorder(
        Tokens.V1.Color.handleRule, lineWidth: Tokens.V1.Size.controlRuleWidth)
    }
    .fixedSize()
    .runtimeAccessibilityIdentifier("meeting-prompt.capsule")
  }

  @ViewBuilder
  private var appIcon: some View {
    if let icon {
      Image(nsImage: icon)
        .resizable()
        .frame(width: Tokens.V1.Size.controlSm, height: Tokens.V1.Size.controlSm)
        .accessibilityHidden(true)
    } else {
      Image(systemName: "waveform")
        .font(.system(size: Tokens.V1.Text.micro.size, weight: .semibold))
        .foregroundStyle(Tokens.V1.Color.handleAccent)
        .frame(width: Tokens.V1.Size.controlSm, height: Tokens.V1.Size.controlSm)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var label: some View {
    let name = prompt.info.app.displayName
    switch prompt {
    case .start(let info):
      let time = ChineseDateText.time(info.startedAt)
      HStack(spacing: Tokens.V1.Space.s2xs) {
        Text(name)
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: Tokens.V1.Size.promptNameMaxWidth, alignment: .leading)
          .help(name)
        Text("\(time) 开始通话")
          .lineLimit(1)
        // 浏览器会议只能按整个浏览器录，开始前写明（不写就是录完才发现录了别的标签页）。
        if MeetingBrowsers.isBrowser(appKey: info.app.key) {
          Text("会录整个浏览器的声音")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.handleAccent)
            .lineLimit(1)
            .runtimeAccessibilityIdentifier("meeting-prompt.browser-note")
        }
      }
      .font(Tokens.V1.Text.body.font)
      .foregroundStyle(Tokens.V1.Color.handleInk)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "\(name) 从 \(time) 开始通话"
          + (MeetingBrowsers.isBrowser(appKey: info.app.key) ? "，会录整个浏览器的声音" : ""))
      .runtimeAccessibilityIdentifier("meeting-prompt.start.label")
    case .scopeFallback, .scopeSilent, .scopeFailed:
      let text = prompt.scopeText
      HStack(spacing: Tokens.V1.Space.s2xs) {
        Text(name)
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: Tokens.V1.Size.promptNameMaxWidth, alignment: .leading)
          .help(name)
        Text(text)
          .lineLimit(1)
      }
      .font(Tokens.V1.Text.body.font)
      .foregroundStyle(Tokens.V1.Color.handleInk)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(name) \(text)")
      .runtimeAccessibilityIdentifier(prompt.scopeLabelIdentifier)
    case .stop:
      HStack(spacing: Tokens.V1.Space.s2xs) {
        Text(name)
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: Tokens.V1.Size.promptNameMaxWidth, alignment: .leading)
          .help(name)
        Text("通话已结束，结束记录？")
          .lineLimit(1)
      }
      .font(Tokens.V1.Text.body.font)
      .foregroundStyle(Tokens.V1.Color.handleInk)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(name) 通话已结束，结束记录？")
      .runtimeAccessibilityIdentifier("meeting-prompt.stop.label")
    }
  }

  @ViewBuilder
  private var buttons: some View {
    HStack(spacing: Tokens.V1.Space.s2xs) {
      switch prompt {
      case .start:
        Button("开始记录", action: onStart)
          .buttonStyle(PromptCapsuleButtonStyle(role: .main))
          .runtimeAccessibilityIdentifier("meeting-prompt.start")
        Button("忽略", action: onIgnore)
          .buttonStyle(PromptCapsuleButtonStyle(role: .quiet))
          .runtimeAccessibilityIdentifier("meeting-prompt.ignore")
        if canExclude {
          Button("不再提醒此 App", action: onNever)
            .buttonStyle(PromptCapsuleButtonStyle(role: .quiet))
            .runtimeAccessibilityIdentifier("meeting-prompt.never")
        }
      case .scopeSilent:
        Button("改录全部系统声音", action: onScopeSwitch)
          .buttonStyle(PromptCapsuleButtonStyle(role: .main))
          .runtimeAccessibilityIdentifier("meeting-prompt.scope-switch")
        Button("不用", action: onScopeDismiss)
          .buttonStyle(PromptCapsuleButtonStyle(role: .quiet))
          .runtimeAccessibilityIdentifier("meeting-prompt.scope-dismiss")
      case .scopeFallback, .scopeFailed:
        Button("知道了", action: onScopeDismiss)
          .buttonStyle(PromptCapsuleButtonStyle(role: .quiet))
          .runtimeAccessibilityIdentifier("meeting-prompt.scope-ack")
      case .stop:
        Button("结束记录", action: onEnd)
          .buttonStyle(PromptCapsuleButtonStyle(role: .main))
          .runtimeAccessibilityIdentifier("meeting-prompt.end")
        Button("继续记录", action: onContinue)
          .buttonStyle(PromptCapsuleButtonStyle(role: .quiet))
          .runtimeAccessibilityIdentifier("meeting-prompt.continue")
      }
    }
  }
}

/// 深色胶囊里的按钮：主按钮是亮青实底深字，安静按钮只有浅字，悬停时铺一层细白。文字不换行。
private struct PromptCapsuleButtonStyle: ButtonStyle {
  enum Role { case main, quiet }
  let role: Role

  func makeBody(configuration: Configuration) -> some View {
    PromptButtonBody(configuration: configuration, role: role)
  }

  private struct PromptButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let role: Role
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .font(Tokens.V1.Text.label.font)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(role == .main ? Tokens.V1.Color.handle : Tokens.V1.Color.handleInk)
        .padding(.horizontal, Tokens.V1.Space.sm)
        .frame(height: Tokens.V1.Size.controlSm)
        .background(
          role == .main
            ? Tokens.V1.Color.handleAccent
            : (isHovering ? Tokens.V1.Color.handleRule2 : Color.clear),
          in: Capsule()
        )
        .opacity(configuration.isPressed ? Tokens.V1.Feedback.pressedOpacity : 1)
        .contentShape(Capsule())
        .onHover { isHovering = $0 }
        .animation(
          reduceMotion ? nil : .easeOut(duration: Tokens.V1.Motion.fast), value: isHovering)
    }
  }
}

/// 面板根：带投影的透明边（与强提醒面板一致，无边框面板按内容自适应不会切掉投影）。
struct MeetingPromptPanelRoot: View {
  @ObservedObject var model: MeetingPromptViewModel
  @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue =
    AppAppearance.system.rawValue

  var body: some View {
    ZStack {
      if let prompt = model.prompt {
        MeetingPromptCapsule(
          prompt: prompt, icon: model.icon, canExclude: model.canExclude,
          onStart: model.onStart, onIgnore: model.onIgnore, onNever: model.onNever,
          onEnd: model.onEnd, onContinue: model.onContinue,
          onScopeSwitch: model.onScopeSwitch, onScopeDismiss: model.onScopeDismiss
        )
        .padding(.horizontal, MeetingPresenceMetrics.strongShadowSide)
        .padding(.top, MeetingPresenceMetrics.strongShadowTop)
        .padding(.bottom, MeetingPresenceMetrics.strongShadowBottom)
      }
    }
    .preferredColorScheme(AppAppearance.persisted(appearanceRawValue).preferredColorScheme)
  }
}

@MainActor
final class MeetingPromptViewModel: ObservableObject {
  @Published var prompt: MeetingPrompt?
  @Published var icon: NSImage?
  @Published var canExclude = true
  var onStart: () -> Void = {}
  var onIgnore: () -> Void = {}
  var onNever: () -> Void = {}
  var onEnd: () -> Void = {}
  var onContinue: () -> Void = {}
  var onScopeSwitch: () -> Void = {}
  var onScopeDismiss: () -> Void = {}
}

extension MeetingPrompt {
  fileprivate var scopeText: String {
    switch self {
    case .scopeSilent: return "可能没录到对方的声音"
    case .scopeFailed: return "系统声音可能没有录上"
    default: return "已改为录制全部系统声音"
    }
  }

  fileprivate var scopeLabelIdentifier: String {
    switch self {
    case .scopeSilent: return "meeting-prompt.scope-silent.label"
    case .scopeFailed: return "meeting-prompt.scope-failed.label"
    default: return "meeting-prompt.scope-fallback.label"
    }
  }
}
