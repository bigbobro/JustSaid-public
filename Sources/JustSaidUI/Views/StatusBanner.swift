import JustSaidCore
import SwiftUI

/// 失败原因的来源不统一:`URLError.localizedDescription` 自带句号(「网络连接已中断。」),
/// 仓里的 typed error 多数不带(「会后管线尚未填写模型名称」)。所有要在原因后面再接
/// 一句话的失败文案,拼接前都过这里削掉尾部句号,否则会粘成「…尚未填写模型名称录音已保留」。
/// (issue #27:用户看到的失败提示只有原因、没有下一步。)
func trimmedFailureReason(_ reason: String) -> String {
  var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
  while let last = text.last, last == "。" || last == "." {
    text.removeLast()
  }
  return text
}

/// 会后处理/纪要生成两条状态条的共享核(2026-08-20 批2 收编:两份逐行同构实现合并)。
/// 公开类型 `PostMeetingStatusBanner` / `MinutesGenerationStatusBanner` 保持原名原 init——
/// UIHierarchy 对这两个名字有源码级断言与直接实例化,合并的是实现,不是契约面。
///
/// 探针标识全部由外壳传入,核不自带任何 id:library.post-meeting 整窗反断言的覆盖
/// 依赖各态 id 不漂移。
///
/// 横幅纪律(批2 成文):正文 uiEmphasis 档;底缘 1pt 色线(警示 amberLine/信息 acLine),
/// 弃 Divider(08-18 已证其在行 Button 语境有朝向陷阱)。
struct StatusBannerCore: View {
  struct Action {
    let title: String
    let isEnabled: Bool
    let tint: Color?
    let probeID: String
    let onTap: () -> Void
  }

  let stage: PostMeetingStage
  /// 失败正文,由外壳带各自的前缀口径(「会后处理未完成」/「纪要生成未成功」)。
  let failedText: (String) -> String
  let failedReasonProbeID: String?
  let probeID: (PostMeetingStage) -> String
  let action: Action?
  let horizontalPadding: CGFloat
  let containsChildren: Bool

  @ViewBuilder
  var body: some View {
    if stage != .none {
      HStack(spacing: Tokens.Spacing.xsm) {
        switch stage {
        case .running(let detail):
          BreathingDots()
          // 文案只跟真实进度事件;无事件时用中性「处理中」,不编造阶段名。
          Text(detail ?? "处理中…")
        case .finished(let notice):
          Image(systemName: "checkmark.circle.fill")
          Text(notice)
        case .failed(let reason):
          Image(systemName: "exclamationmark.triangle.fill")
          if let failedReasonProbeID {
            Text(failedText(reason))
              .runtimeAccessibilityIdentifier(failedReasonProbeID)
          } else {
            Text(failedText(reason))
          }
        case .none:
          EmptyView()
        }

        Spacer()

        if let action {
          Button(action.title) {
            action.onTap()
          }
          .buttonStyle(.textAction)
          .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
          .foregroundStyle(action.tint ?? Tokens.Color.acDeep)
          .disabled(!action.isEnabled)
          .runtimeAccessibilityIdentifier(action.probeID)
        }
      }
      .font(.system(size: Tokens.FontSize.uiEmphasis))
      .foregroundStyle(isFailure ? Tokens.Color.warn : Tokens.Color.acDeep)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, Tokens.Spacing.xs)
      .background(isFailure ? Tokens.Color.amber : Tokens.Color.acSoft)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(isFailure ? Tokens.Color.amberLine : Tokens.Color.acLine)
          .frame(height: 1)
      }
      .modifier(ContainChildrenIfNeeded(isEnabled: containsChildren))
      .runtimeAccessibilityIdentifier(probeID(stage))
    }
  }

  private var isFailure: Bool {
    if case .failed = stage { return true }
    return false
  }
}

private struct ContainChildrenIfNeeded: ViewModifier {
  let isEnabled: Bool
  func body(content: Content) -> some View {
    if isEnabled {
      content.accessibilityElement(children: .contain)
    } else {
      content
    }
  }
}

/// 驾驶舱散会后的会后处理状态条。**只有驾驶舱这一处**(08-10 用户改判):
/// 状态本来就属于某一场会议,该跟着会议库那一行走,不该飘在详情页顶部。保留驾驶舱这一条
/// 的理由是散会那一刻用户人在驾驶舱、不在会议库,完全取消会让人不知道后台在跑。
///
/// **是否显示的判断只有这一处**:调用方无条件实例化,`.none` 由本视图自己收成空。
///
/// 成功提示活多久不在这里定:它跟着 `PostMeetingTaskCoordinator` 的快照走,
/// 快照被展示门(约 5 秒)或 ⌘L 边界收掉,这里就自然收成空。视图不持有计时器,
/// 所以关窗/remount 也不会重开一轮倒计时。
public struct PostMeetingStatusBanner: View {
  public let stage: PostMeetingStage
  public let actionTitle: String?
  public let isActionEnabled: Bool
  public let onAction: (() -> Void)?

  public init(
    stage: PostMeetingStage,
    actionTitle: String? = nil,
    isActionEnabled: Bool = true,
    onAction: (() -> Void)? = nil
  ) {
    self.stage = stage
    self.actionTitle = actionTitle
    self.isActionEnabled = isActionEnabled
    self.onAction = onAction
  }

  public var body: some View {
    StatusBannerCore(
      stage: stage,
      // issue #27:光说「未完成 + 原因」,用户既不知道录音还在不在、也不知道下一步去哪。
      // 右侧按钮「查看本场会议」只是导航,真正的修复动作在那一场的详情里,所以这里点名它。
      failedText: { "会后处理未完成 · \(trimmedFailureReason($0))。录音已保留，可在本场会议重新精转。" },
      failedReasonProbeID: "cockpit.post-meeting.reason",
      probeID: { stage in
        let prefix = "cockpit.post-meeting"
        switch stage {
        case .running: return "\(prefix).running"
        case .finished: return "\(prefix).finished"
        case .failed: return "\(prefix).failed"
        case .none: return "\(prefix).none"
        }
      },
      action: bannerAction,
      horizontalPadding: Tokens.Spacing.md,
      containsChildren: true
    )
  }

  private var bannerAction: StatusBannerCore.Action? {
    guard let actionTitle, let onAction else { return nil }
    let isFailure: Bool
    if case .failed = stage { isFailure = true } else { isFailure = false }
    return StatusBannerCore.Action(
      title: actionTitle,
      isEnabled: isActionEnabled,
      tint: isFailure ? Tokens.Color.warn : Tokens.Color.acDeep,
      probeID: "cockpit.post-meeting.action",
      onTap: onAction
    )
  }
}

/// 会议库详情的纪要生成状态条。显隐判断只在这里:`.none` 收成空,调用方无条件实例化。
/// 探针族 library.minutes-generation-* 的后缀不同构(running 态历史命名为 -progress),
/// 保持原样——断言按这些 id 匹配。
public struct MinutesGenerationStatusBanner: View {
  public let stage: PostMeetingStage
  public let onRetry: () -> Void

  public init(stage: PostMeetingStage, onRetry: @escaping () -> Void) {
    self.stage = stage
    self.onRetry = onRetry
  }

  public var body: some View {
    StatusBannerCore(
      stage: stage,
      // issue #27:补上「重试贵不贵」这个用户真正在犹豫的点——重试只读盘上的转写重生成
      // 纪要,不重新上传、不按录音时长计费(口径与「生成纪要」确认弹窗一致)。
      failedText: { "纪要生成未成功 · \(trimmedFailureReason($0))。转写已保留，重试不会重新精转。" },
      failedReasonProbeID: nil,
      probeID: { stage in
        switch stage {
        case .running: return "library.minutes-generation-progress"
        case .finished: return "library.minutes-generation-finished"
        case .failed: return "library.minutes-generation-failed"
        case .none: return "library.minutes-generation-none"
        }
      },
      action: retryAction,
      horizontalPadding: Tokens.Spacing.lg,
      containsChildren: false
    )
  }

  private var retryAction: StatusBannerCore.Action? {
    guard case .failed = stage else { return nil }
    return StatusBannerCore.Action(
      title: "重试",
      isEnabled: true,
      // 重试只在失败态渲染:警示级横幅上按钮随级取 warn(旧实现靠继承外层色,收编后显式传)。
      tint: Tokens.Color.warn,
      probeID: "library.minutes-generation-retry",
      onTap: onRetry
    )
  }
}
