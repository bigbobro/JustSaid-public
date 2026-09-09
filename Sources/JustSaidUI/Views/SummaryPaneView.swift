import JustSaidCore
import SwiftUI

/// 舞台以下的左整理区与定宽右栏。quick 覆盖底沿，pinned 替换左侧话题历史，
/// 收起时只显示最新一行预览；录音与总结生命周期仍由 MainWorkspaceView 持有。
struct SummaryPaneView<Feed: SummaryFeed>: View {
  @ObservedObject var feed: Feed
  @ObservedObject var notesController: NotesController
  @Binding var scrollRequest: UUID?
  let onSaveSourceAsNote: (SummarySourceReference) -> Void
  let onJumpToTranscript: (TimeInterval) -> Void
  /// 排除入口透传(08-14):整理区 bullet/话题块右键;nil = 不出菜单。
  var onExcludeBulletAnchor: ((TimeInterval) -> Void)? = nil
  var onExcludeTopicRange: ((ClosedRange<TimeInterval>) -> Void)? = nil
  /// G4(08-15):会话是否活跃(启动中/录制/停止)。false(idle/completed/failed)时
  /// 整理区空态换「未在录制」语义;true 时保留录制态「正在听…」空态原样。
  /// 默认 true = 既有调用点(验证夹具)行为不变。
  /// 08-19:空态不再自带「开始记录」按钮——驾驶舱唯一入口在顶栏。
  var isSessionLive = true
  /// 由工作台独家持有；正文、轨道、标题共用同一呈现意图。
  @Binding var transcriptPresentation: LiveTranscriptPresentationState
  /// 抽屉正文数据与交互全部透传给 `TranscriptPaneView`,本视图不复制一份呈现逻辑。
  var transcriptSegments: [TranscriptSegment] = []
  var transcriptExcludedRanges: [ExcludedRange] = []
  var onMarkChatFrom: ((TimeInterval) -> Void)? = nil
  var onRemoveExclusion: ((UUID) -> Void)? = nil

  var body: some View {
    LiveTranscriptPresentation(
      presentation: $transcriptPresentation,
      transcriptSegments: transcriptSegments,
      transcriptExcludedRanges: transcriptExcludedRanges,
      onMarkChatFrom: onMarkChatFrom,
      onRemoveExclusion: onRemoveExclusion,
      organizerHeader: { SummaryDegradedBanner(status: feed.engineStatus, onRetry: feed.retry) },
      organizer: { organizer },
      sidebar: { sidebar }
    )
  }

  /// 右栏(定宽 332):替你记 + 补充记录两块吃满舞台以下的高度。
  /// 「当前正在聊」08-19 升格成整宽舞台后从这里撤走,右栏不再三分高度。
  private var sidebar: some View {
    VStack(spacing: Tokens.Spacing.sm) {
      ActionItemsPaneView(
        items: feed.actionItems,
        onJumpToTranscript: onJumpToTranscript
      )
      .frame(minHeight: 128, maxHeight: .infinity)
      .runtimeAccessibilityIdentifier("dashboard.actions")

      NotesPaneView(
        controller: notesController,
        onJumpToTranscript: onJumpToTranscript
      )
      .frame(minHeight: 180, maxHeight: .infinity)
      .runtimeAccessibilityIdentifier("dashboard.notes")
    }
    .padding(Tokens.Spacing.sm)
    .frame(width: Tokens.Layout.dashboardSidebarWidth)
    .background(Tokens.Color.bg)
  }

  @ViewBuilder
  private var organizer: some View {
    VStack(spacing: 0) {
      if feed.topics.isEmpty {
        EmptySummaryState(isSessionLive: isSessionLive)
      } else {
        HistoryPaneView(
          topics: feed.topics,
          engineStatus: feed.engineStatus,
          scrollRequest: $scrollRequest,
          onSaveSourceAsNote: onSaveSourceAsNote,
          onJumpToTranscript: onJumpToTranscript,
          onExcludeBulletAnchor: onExcludeBulletAnchor,
          onExcludeTopicRange: onExcludeTopicRange
        )
      }
    }
  }
}

/// 会中总结的降级细带。**显隐判断收在视图内部**：调用点无条件实例化，健康态整条结构不存在。
///
/// 三件事必须都说清楚（08-10 用户被界面误导约 30 分钟的直接对症）：
/// **是哪一路**挂了（快慢两条 lane 独立，健康的一路不许被连坐）、**为什么**挂（渠道配置
/// 还是网络，用户据此决定是去改设置还是等一等）、**现在是不是在重试**。
/// 那颗「重试」只在按下去真的会发生事情时才画——散会后两条 lane 都已取消，
/// 它此前仍挂在横幅上，按下去可证明毫无作用。
struct SummaryDegradedBanner: View {
  let status: SummaryEngineStatus
  let onRetry: () -> Void

  var body: some View {
    if case .unavailable(let degradation) = status {
      DegradedBanner(
        text: degradation.bannerText,
        retryAction: degradation.canRetry ? onRetry : nil,
        retryIdentifier: "dashboard.summary-degraded.retry",
        trailingNote: degradation.isRetryInFlight ? "重试中…" : nil
      )
      .background(
        ZStack {
          ForEach(Self.probeIdentifiers(for: degradation), id: \.self) { identifier in
            Color.clear.runtimeAccessibilityIdentifier(identifier)
          }
        }
      )
    }
  }

  /// 结构探针:把"横幅到底在说什么"变成可断言的标识,而不是让验证去 grep 文案。
  static func probeIdentifiers(for degradation: SummaryDegradation) -> [String] {
    var identifiers = ["dashboard.summary-degraded"]
    for issue in degradation.issues {
      identifiers.append("dashboard.summary-degraded.\(issue.source.rawValue)")
      identifiers.append("dashboard.summary-degraded.cause.\(issue.cause.rawValue)")
    }
    if degradation.isRetryInFlight {
      identifiers.append("dashboard.summary-degraded.retrying")
    }
    if degradation.isPersistent {
      identifiers.append("dashboard.summary-degraded.escalated")
    }
    return identifiers
  }
}

/// 空态分两态(G4,08-15):
/// - 会话活跃(录制中首话题前):「正在听…」+ shimmer,**原样保留**——它是录制态的正确空态;
/// - 非录制(idle/completed/failed):什么都不在录,界面不许装成「在听但出问题了」,
///   换「未在录制」语义并说明开始后这里会出现什么。
///
/// 08-19 撤掉空态里的「开始记录」按钮:G4 当初给舞台与整理区各摆了一颗,加上顶栏
/// 那颗一共三处;舞台升格到顶栏正下方后前两颗与顶栏贴脸,与 08-10「唯一入口」原则冲突。
/// 现在驾驶舱内「开始记录」只在顶栏 `primaryActionButton` 一处,空态只留文案。
private struct EmptySummaryState: View {
  var isSessionLive = true
  /// 空态文案跟随会议内容缩放(2026-08-20 修):整理区这几行原先写死 12.5,
  /// 而舞台/替你记/补充记录的同类空态都走 `textScale.size` ——同一次 A+ 下去
  /// 别处变大、只有整理区不动,用户实测发现的正是这处不一致。
  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(spacing: Tokens.Spacing.sm) {
      Spacer()
      if isSessionLive {
        Text("正在听…有内容后会出现第一个话题")
          .font(.system(size: textScale.size(Tokens.FontSize.body)))
          .foregroundStyle(Tokens.Color.ink3)
        VStack(spacing: Tokens.Spacing.xs) {
          ShimmerLine(widthFraction: 0.7)
          ShimmerLine(widthFraction: 0.5)
        }
        .frame(maxWidth: 260)
      } else {
        // 08-19 同款撤按钮:驾驶舱内「开始记录」只留顶栏那一颗唯一入口。
        Text("未在录制")
          .font(.system(size: textScale.size(Tokens.FontSize.body), weight: .semibold))
          .foregroundStyle(Tokens.Color.ink2)
        Text("开始后，话题与要点会实时整理在这里")
          .font(.system(size: textScale.size(Tokens.FontSize.body)))
          .foregroundStyle(Tokens.Color.ink3)
          .runtimeAccessibilityIdentifier("dashboard.organizer.empty-copy")
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Tokens.Color.card)
  }
}
