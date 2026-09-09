import JustSaidCore
import SwiftUI

/// 「此刻舞台」（2026-08-19 A+C 混搭，由原右栏「当前区」升格）：顶栏之下的整宽定高带，
/// 只做一眼——话题、谁正就什么发言、最近两三句。完整内容留在下方整理区。
///
/// **为什么升格**：它是「开会回来第一眼」要落的地方，塞在右栏第三分之一里与替你记、
/// 补充记录抢高度，层级和它承担的任务不匹配（08-19 用户诊断 L1/V1）。升格后**不含
/// 控制轨宽度**、不带卡片外壳（整宽带 + 底部细线），高度由 `Tokens.Layout.nowStageHeight` 定。
///
/// **点名高亮画整行**（V10 / R3）：`.callout` 片段原先只给行内文字上琥珀底，一屏里
/// 是个几毫米的色块；被点到名字是这一屏唯一需要抢注意力的事，整行琥珀底+描边才够。
///
/// **本区不放「标记」入口**（08-10）：它和右栏补充记录区的按钮调的是同一个
/// `NotesController.beginMark()`，同一屏两颗同名按钮属于重复入口。唯一入口连同
/// ⌥⌘M 一起收在 `NotesPaneView` 的「标记重点」上。
struct NowPaneView: View {
  let state: SummaryNowState
  /// G4(08-15):会话是否活跃(启动中/录制/停止)。false 时空态换「未在录制」语义,
  /// 新鲜度指示器只报时不告警;默认 true = 既有调用点行为不变。
  /// 08-19:空态不再自带「开始记录」按钮——驾驶舱唯一入口在顶栏。
  var isSessionLive = true
  @Environment(\.textScale) private var textScale
  var onJumpToTranscript: (TimeInterval) -> Void = { _ in }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if let context = state.context {
        contextContent(context)
      } else if state.lines.isEmpty {
        emptyState
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            ForEach(state.lines) { line in
              NowLineRow(line: line, fontSize: textScale.size(Tokens.FontSize.bodyMinimum))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, Tokens.Spacing.xsm)
        }
      }
      actions
    }
    .padding(.horizontal, Tokens.Spacing.xxl)
    .padding(.vertical, Tokens.Spacing.smd)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(NowPaneBackground())
    .accessibilityElement(children: .contain)
  }

  private func contextContent(_ context: SummaryNowContext) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
        // 舞台标题按整宽带的层级放大(原右栏 12.5 在整宽下读起来像小标签)。
        Text(context.topicTitle)
          .font(.system(size: textScale.size(Tokens.FontSize.stageTitle), weight: .semibold))
          .foregroundStyle(Tokens.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
        if let speaker = context.speaker, !speaker.isEmpty {
          HStack(spacing: Tokens.Spacing.xxs) {
            BreathingDots()
            Text(
              context.speakingAbout.map { "\(speaker) 正在就\($0)发言" }
                ?? "\(speaker) 正在发言"
            )
            .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
            .foregroundStyle(Tokens.Color.ink2)
          }
        }
        // 2026-07-31 用户拍板:当前区不放转写原文(原文自有转写栏,这里要的是轻加工)。
        // recentLines 仍在数据里,只用作「看这段原文」的回跳锚点,不再逐行渲染。
        ForEach(state.lines) { line in
          NowLineRow(line: line, fontSize: textScale.size(Tokens.FontSize.bodyMinimum))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, Tokens.Spacing.xsm)
    }
  }

  private var header: some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      PulsingDot(
        color: Tokens.Color.ac,
        size: 7,
        haloColor: Tokens.Color.ac.opacity(0.14),
        isPulsing: isSessionLive
      )
      Text("当前正在聊")
        .font(.system(size: Tokens.FontSize.bodyMinimum, weight: .bold))
        .foregroundStyle(Tokens.Color.acDeep)
      Spacer()
      // G4:告警(琥珀点+「更新较慢」)只在会话活跃时进入;空闲态没有「总结覆盖进度」
      // 这回事,指示器照常报时但永不转告警语气。
      FreshnessIndicator(
        coveredUntilLabel: state.coveredUntilLabel,
        updatedAt: state.updatedAt,
        allowsStaleAlert: isSessionLive
      )
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "当前正在聊，\(state.coveredUntilLabel.isEmpty ? "" : "覆盖至 \(state.coveredUntilLabel)")")
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xsm) {
      HStack {
        Spacer(minLength: 0)
        if isSessionLive {
          VStack(spacing: Tokens.Spacing.xs) {
            Text("正在听…有内容后会出现第一个话题")
              .font(.system(size: textScale.size(Tokens.FontSize.body)))
              .foregroundStyle(Tokens.Color.ink3)
            ShimmerLine(widthFraction: 0.7)
              .frame(maxWidth: 220)
          }
        } else {
          // G4(08-15):非录制态不装「在听」——直说未在录制。
          // 08-19 撤掉这里的「开始记录」按钮:舞台升格到顶栏正下方后,它与顶栏那颗
          // 只隔 40pt,同屏两颗同名按钮正是 08-10「唯一入口」要消灭的重复。
          // 空态只说明现状与将会发生什么,动作交给顶栏那颗唯一入口。
          VStack(spacing: Tokens.Spacing.xs) {
            Text("未在录制")
              .font(.system(size: textScale.size(Tokens.FontSize.body), weight: .semibold))
              .foregroundStyle(Tokens.Color.ink2)
            Text("开始后，这里显示当前在聊什么")
              .font(.system(size: textScale.size(Tokens.FontSize.body)))
              .foregroundStyle(Tokens.Color.ink3)
          }
        }
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// 「按不动又占着位」的空钮才不渲染(红线 6 的同一口径:结构不存在,不退化成占位)。
  /// 判据是两条的或:**会话活跃**——录制中锚点会反复有无,按显隐会让舞台底部一直跳,
  /// 那种情况下禁用态才是对的;**或已经有锚点**——散会后人还留在舱里时,内容与锚点
  /// 都还在,这颗钮照样点得动,不能连它一起收掉。
  /// 只有「没在录 + 没锚点」这一种组合下它是纯死钮,那时整条不存在。
  @ViewBuilder
  private var actions: some View {
    if isSessionLive || state.sourceAnchorSeconds != nil {
      liveActions
    }
  }

  private var liveActions: some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Button {
        guard let seconds = state.sourceAnchorSeconds else { return }
        onJumpToTranscript(seconds)
      } label: {
        HStack(spacing: Tokens.Spacing.xxs) {
          Text("看这段原文")
          Image(systemName: "arrow.up.right")
            .accessibilityHidden(true)
        }
      }
      .buttonStyle(.toolbarPill)
      .disabled(state.sourceAnchorSeconds == nil)
      .accessibilityLabel("展开转写区并查看最新原文")
    }
    .padding(.top, Tokens.Spacing.xs)
  }
}

private struct NowLineRow: View {
  let line: SummaryNowLine
  let fontSize: CGFloat

  /// 点名高亮的载体是 `.callout` 片段（V10 语义），行级判定就读它——
  /// 不在 UI 层另发明一个「这行重要吗」的第二事实源。
  private var isCallout: Bool {
    line.text.runs.contains { $0.style == .callout }
  }

  var body: some View {
    HStack(alignment: isCallout ? .center : .top, spacing: Tokens.Spacing.xsm) {
      Circle()
        .fill(isCallout ? Tokens.Color.warn : Tokens.Color.acLine)
        .frame(width: 5, height: 5)
        .padding(.top, isCallout ? 0 : Tokens.Spacing.xs)
      RichText(line.text)
        .font(.system(size: fontSize, weight: isCallout ? .medium : .regular))
        .foregroundStyle(Tokens.Color.nowBody)
        .fixedSize(horizontal: false, vertical: true)
      if isCallout {
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, isCallout ? Tokens.Spacing.smd : 0)
    .padding(.vertical, isCallout ? Tokens.Spacing.xsm : 0)
    .background {
      if isCallout {
        RoundedRectangle(cornerRadius: Tokens.Radius.widget)
          .fill(Tokens.Color.amber)
          .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.widget)
              .stroke(Tokens.Color.amberLine, lineWidth: 1)
          )
      }
    }
    .runtimeAccessibilityIdentifier(
      isCallout ? "dashboard.current.callout-row" : "dashboard.current.line"
    )
  }
}

/// 新鲜度文案（纯函数，验证程序直接断言）。
///
/// 原先每秒跳一次「落后 N 秒」：开会时余光扫过来看到的是一只秒表在走，而不是「总结覆盖到哪了」
/// ——那是注意力噪声，不是信息。改成 5 秒粒度、15 秒内不报数字，
/// 只有真的开始落后（>90s）时才换成告警语气抢一次注意力。
/// 2026-07-31 文案改判:「落后 N 秒」被读成"总结比现场慢 N 秒",实义是"距上次刷新 N 秒"
/// (安静期没有新内容也会涨),改说「更新于 N 秒前」——数字没变,话说对了。
public enum SummaryFreshness {
  /// 报数粒度：滞后秒数向下取整到 5 的倍数，同时也是刷新节拍。
  public static let granularity = 5
  /// 低于这个滞后不报数字，直接说「刚刚更新」。
  private static let freshThreshold = 15
  /// 超过这个滞后转入告警语气。
  private static let staleThreshold = 90

  public static func isStale(lag: Int) -> Bool {
    lag > staleThreshold
  }

  /// 既有两参口径 = 永远允许告警(UIHierarchy 逐条断言,行为一字不动)。
  public static func label(coveredUntil: String, lag: Int) -> String {
    label(coveredUntil: coveredUntil, lag: lag, allowsStaleAlert: true)
  }

  /// G4(08-15):`allowsStaleAlert = false` 时只报时不告警——非录制态没有
  /// 「总结覆盖进度」,stale>90s 也不许换成告警语气抢注意力。
  public static func label(coveredUntil: String, lag: Int, allowsStaleAlert: Bool) -> String {
    let prefix = "覆盖至 \(coveredUntil) · "
    if allowsStaleAlert && isStale(lag: lag) {
      return prefix + "更新较慢"
    }
    if lag < freshThreshold {
      return prefix + "刚刚更新"
    }
    return prefix + "更新于 \(lag / granularity * granularity) 秒前"
  }
}

private struct FreshnessIndicator: View {
  let coveredUntilLabel: String
  let updatedAt: Date
  /// G4:仅会话活跃时为 true;false 时点不转琥珀、文案不转「更新较慢」。
  var allowsStaleAlert = true

  var body: some View {
    TimelineView(.periodic(from: updatedAt, by: TimeInterval(SummaryFreshness.granularity))) {
      context in
      let lag = max(0, Int(context.date.timeIntervalSince(updatedAt)))
      let stale = allowsStaleAlert && SummaryFreshness.isStale(lag: lag)
      HStack(spacing: Tokens.Spacing.xs) {
        Circle()
          .fill(stale ? Tokens.Color.warn : Tokens.Color.ac)
          .frame(width: 5, height: 5)
        Text(
          SummaryFreshness.label(
            coveredUntil: coveredUntilLabel,
            lag: lag,
            allowsStaleAlert: allowsStaleAlert
          )
        )
        .font(.system(size: Tokens.FontSize.secondary, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink3)
      }
    }
  }
}

/// 径向渐变（左上最亮）：GeometryReader 撑满宽高后取一个足够覆盖对角线的半径近似
/// CSS 的 `120% 140%` 扩散比例。
private struct NowPaneBackground: View {
  var body: some View {
    GeometryReader { geometry in
      let radius = max(geometry.size.width, geometry.size.height) * 1.3
      RadialGradient(
        colors: [Tokens.Color.acSoft, Tokens.Color.washMint, Tokens.Color.card],
        center: .topLeading,
        startRadius: 0,
        endRadius: max(radius, 1)
      )
    }
  }
}
