import SwiftUI

/// 一场会的**结论**:这场会好了没有。首页与会议库共用同一个判定与同一种呈现。
///
/// 2026-09-20 owner:会议库原来是精转、纪要、完备度三列对勾,要人三列扫过去自己心算
/// 「都齐了吗」,而且完备度的两种勾(自动判齐 vs 手工确认过)只差一个圈,读不出来。
/// 三列是过程,结论只有一个,所以收敛成这一枚胶囊;细节留给悬停与点开的浮层。
public struct MeetingOutcomePill: View {
  public enum Outcome {
    case processing(String)
    case attention(String)
    case done(String)
    case pending(String)

    var label: String {
      switch self {
      case .processing(let text), .attention(let text), .done(let text), .pending(let text):
        return text
      }
    }

    var symbol: String {
      switch self {
      case .processing: return "clock"
      case .attention: return "exclamationmark.triangle"
      case .done: return "checkmark"
      case .pending: return "minus"
      }
    }

    var foreground: Color {
      switch self {
      case .processing: return Tokens.V1.Color.accent
      case .attention: return Tokens.V1.Color.warn
      case .done: return Tokens.V1.Color.ok
      case .pending: return Tokens.V1.Color.ink3
      }
    }

    var background: Color {
      switch self {
      case .processing: return Tokens.V1.Color.accentSoft
      case .attention: return Tokens.V1.Color.warnSoft
      case .done: return Tokens.V1.Color.okSoft
      case .pending: return Tokens.V1.Color.paper3
      }
    }
  }

  private let outcome: Outcome

  public init(_ outcome: Outcome) {
    self.outcome = outcome
  }

  /// 从流水线状态与完备度判定推出结论。顺序即优先级:
  /// 处理中 > 要你处理 > 已完成 / 已确认 > 还差哪一步。
  public static func outcome(
    for state: MeetingPipelineState, acknowledgedCompleteness: Bool
  ) -> Outcome {
    if state.transcription == .inProgress { return .processing("正在精转") }
    if state.minutes == .inProgress { return .processing("正在生成纪要") }
    if state.completeness == .red { return .attention("要确认") }
    if state.transcription == .failed { return .attention("精转失败") }
    if state.minutes == .failed { return .attention("纪要失败") }
    if state.hasFormalMinutes {
      // 自动判齐与「你当初确认过」是两件事,用文字说清楚,不靠一个圈。
      return .done(acknowledgedCompleteness ? "已确认" : "已完成")
    }
    return .pending(state.transcription == .completed ? "待纪要" : "待精转")
  }

  public var body: some View {
    Label(outcome.label, systemImage: outcome.symbol)
      .font(Tokens.V1.Text.meta.font)
      .lineLimit(1)
      .foregroundStyle(outcome.foreground)
      .padding(.horizontal, Tokens.V1.Space.xs)
      .padding(.vertical, Tokens.V1.Space.s2xs)
      .background(outcome.background, in: Capsule())
      .accessibilityLabel(outcome.label)
      .runtimeAccessibilityIdentifier("meeting.outcome.\(outcome.label)")
  }
}
