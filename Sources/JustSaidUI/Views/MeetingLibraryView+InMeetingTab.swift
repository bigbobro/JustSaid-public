import JustSaidCore
import SwiftUI

extension MeetingLibraryView {
  /// 会中记录页:会开的时候留下了什么。两样东西——机器边听边总结的「总结留痕」,
  /// 和你自己随手记的「补充记录」。两段功能(版本回看、时间戳回跳)不丢。
  ///
  /// 2026-09-20 只统一设计语言,不碰功能(owner)。三处向另外两个页签看齐:
  /// 一是补上工具行——这一页原来是三个页签里唯一没有工具行的,版本选择器埋在段头里,
  /// 现在挪到和「结构/正式纪要」「认名·搜索·章节目录」同一个位置;
  /// 二是话题块换成和「这场会」同款的积木(细边 + paper-2 + 大圆角、标题在块内),
  /// 原来是「裸标题在块外 + 要点区自己一个底和描边」,同一个会议页里两种盒子;
  /// 三是段头统一走 SectionHeaderRow,间距走 v1。
  func inMeetingPage(_ item: MeetingLibraryItem) -> some View {
    VStack(alignment: .leading, spacing: .zero) {
      inMeetingToolRow()
      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
          SummaryTopicCardsDocumentView(
            topics: model.selectedHistoryTopics,
            emptyHint: model.inMeetingHistoryEmptyHint(),
            onJumpToTranscript: model.jumpToTranscript,
            embedded: true
          )
        }
        .padding(.vertical, Tokens.V1.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .rememberedScrollOffset(tabScrollBinding(for: .inMeeting))
    }
    .runtimeAccessibilityIdentifier("library.in-meeting")
  }

  /// 工具行。另外两个页签都有一条,这一页原来没有,所以它看着不像同一个 app 的页。
  /// 版本选择器从段头挪进来:它管的是整页留痕看哪一版,本来就是工具,不是段落标题的一部分。
  @ViewBuilder
  private func inMeetingToolRow() -> some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Text("总结留痕")
        .font(Tokens.V1.Text.heading.font)
        .foregroundStyle(Tokens.V1.Color.ink)
      if !model.selectedHistoryTopics.isEmpty {
        Text("\(model.selectedHistoryTopics.count) 项")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
          .monospacedDigit()
      }
      Spacer(minLength: Tokens.V1.Space.xs)
      if model.snapshots.count > 1 {
        Picker("看哪一版", selection: $model.snapshotID) {
          Text("全部留痕").tag(nil as String?)
          ForEach(model.snapshots) { snapshot in
            Text(snapshot.label).tag(snapshot.id as String?)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        // 按自己的内容取宽。原来借了会议库客户列的宽度(140),客户列收窄后跟着变形。
        .fixedSize()
        .help("会中每隔一段会总结一次,这里能回看某一次的留痕")
        .runtimeAccessibilityIdentifier("library.in-meeting.history-revision-picker")
      } else if !model.snapshots.isEmpty {
        // 只有一版也说一句。原来这一行整条不画,你分不清是「只有一版」还是「这功能没有」。
        Text("只有一版留痕")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink4)
      }
    }
    .padding(.horizontal, Tokens.V1.Space.lg)
    .padding(.vertical, Tokens.V1.Space.xs)
    .frame(minHeight: Tokens.V1.Size.chipsRowHeight)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .runtimeAccessibilityIdentifier("library.in-meeting.tools")
  }

  /// 补充记录。2026-09-20 从正文搬到右栏:左边是机器边听边记的,右边是你自己写的,
  /// 并排看才对得上号——原来它排在总结留痕**下面**,要一直滚到底才看得见自己写过什么。
  /// `item` 传进来是因为记录按会议读盘,不从当前选中推。
  func inMeetingNotesRail(_ item: MeetingLibraryItem) -> some View {
    VStack(alignment: .leading, spacing: .zero) {
      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
          SectionHeaderRow(title: "补充记录", count: model.noteEntries(for: item).count)
          MeetingNotesDocumentView(
            entries: model.noteEntries(for: item),
            emptyHint: model.inMeetingNotesEmptyHint(),
            onJumpToTranscript: model.jumpToTranscript,
            embedded: true,
            compact: true
          )
        }
        .padding(Tokens.V1.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(width: Tokens.V1.Size.meetingRailWidth, alignment: .leading)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Tokens.V1.Color.paper2)
    .overlay(alignment: .leading) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(width: Tokens.V1.Size.controlRuleWidth)
    }
    .runtimeAccessibilityIdentifier("meeting.notes-rail")
  }
}
