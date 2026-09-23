import AppKit
import JustSaidCore
import SwiftUI

struct HomeMeetingsView: View {
  @ObservedObject var model: MeetingLibraryModel
  @ObservedObject var coordinator: AppCoordinator
  @State private var filter = HomeMeetingFilter.all
  @State private var renameTarget: MeetingLibraryItem?
  @State private var renamedTitle = ""

  private var meetings: [MeetingLibraryItem] { model.meetings.filter { $0.status != .recording } }

  /// 首页是**待办面板**,回答「我最近在忙什么、有什么没收尾」;
  /// 会议库是**检索面板**,回答「我要找某一场会」。
  /// 2026-09-20 owner:两页原来都显示全部会议,底部那句「在会议库里看全部 N 场」
  /// 因此是假的——点进去看到的是同一批,只是多了筛选与分组。首页截断到最近若干场,
  /// 那句话才成立,两页的职责也才分得开。
  static let recentLimit = 8

  private var matching: [MeetingLibraryItem] {
    let hits = Set(model.librarySearchResults.map(\.meetingID))
    return meetings.filter {
      filter.matches(model.pipelineState(for: $0))
        && (model.librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || hits.contains($0.id))
    }
  }

  /// 只有「近 8 场」这一档截断。待办三档不截断(owner 2026-09-20):
  /// 「没做纪要 1」若那一场在三个月前,截断会把它藏起来——而那正是最需要看见的。
  /// 这样每个页签的数字都等于你能看到的行数。
  private var items: [MeetingLibraryItem] {
    filter == .all ? Array(matching.prefix(Self.recentLimit)) : matching
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      // 标题、页签和去会议库的链接放在同一行(owner 2026-09-21 第二份参考稿:「筛选 tab 直接
      // 放在一行,不要分行」)。标题跟着职责改口:这一块是最近的几场,不是全部会议(全部在会议库)。
      // 页签仍是下划线式(和会议页三个页签同一个画法):选中项 strong + 2pt 墨线,整行底下一条
      // 通栏细线,墨线就落在这条线上。原来是 paper-3 填色块,比「最近的会」还重,标题压不住它
      // (owner 2026-09-21:「这些标题完全不特殊,完全没有层级的感觉」)。计数用 meta 灰字。
      HStack(spacing: Tokens.V1.Space.lg) {
        Text("最近的会").font(Tokens.V1.Text.title.font)
        HStack(spacing: Tokens.V1.Space.lg) {
        ForEach(HomeMeetingFilter.allCases, id: \.self) { candidate in
          let selected = filter == candidate
          Button {
            HangSentinel.shared.note("home:filter:\(candidate.rawValue)")
            filter = candidate
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.s2xs) {
              Text(candidate.title)
              if candidate != .all {
                Text("\(meetings.filter { candidate.matches(model.pipelineState(for: $0)) }.count)")
                  .font(Tokens.V1.Text.meta.font)
                  .foregroundStyle(Tokens.V1.Color.ink3)
              }
            }
            .font(selected ? Tokens.V1.Text.strong.font : Tokens.V1.Text.label.font)
            .foregroundStyle(selected ? Tokens.V1.Color.ink : Tokens.V1.Color.ink3)
            .padding(.vertical, Tokens.V1.Space.xs)
            .overlay(alignment: .bottom) {
              Rectangle().fill(selected ? Tokens.V1.Color.ink : .clear)
                .frame(height: Tokens.V1.Size.focusWidth)
            }
          }
          .buttonStyle(.v1Quiet)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
        }
        Spacer(minLength: 0)
        // 去会议库的链接挪到这一行的右端,底下那句「在会议库里看全部 N 场」随之删掉——同一件事
        // 一处说。一场都没有时不画:空状态已经说了「还没有会议记录」。
        if !meetings.isEmpty {
          Button { coordinator.openLibrary() } label: {
            HStack(spacing: Tokens.V1.Space.s3xs) {
              Text("在会议库里看全部 \(meetings.count) 场")
              Image(systemName: "chevron.right").imageScale(.small)
            }
            .font(Tokens.V1.Text.label.font)
            .foregroundStyle(Tokens.V1.Color.accent)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("首页只列最近 \(Self.recentLimit) 场")
        }
      }
      .overlay(alignment: .bottom) {
        Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
      }
      // 已有列表时后台重扫不打转:列表先照旧显示,扫完就地换成新的。只有冷启动、
      // 手里一场都没有的时候才转圈。
      if (model.isReloading && model.meetings.isEmpty) || model.isLibrarySearching {
        ProgressView().controlSize(.small)
      }
      if let error = model.importError { homeError(error) }
      if let error = model.deletionError ?? model.titleError ?? model.exportError {
        homeError(error)
      }
      if let notice = model.exportNotice { Text(notice).font(Tokens.V1.Text.meta.font) }
      if model.isImporting { Text("正在导入录音…").font(Tokens.V1.Text.meta.font) }
      if items.isEmpty, !model.isReloading, !model.isLibrarySearching {
        Text(meetings.isEmpty ? "还没有会议记录" : "没有符合条件的会议")
          .font(Tokens.V1.Text.body.font).foregroundStyle(Tokens.V1.Color.ink3)
          .padding(.vertical, Tokens.V1.Space.lg)
      }
      // 表头(owner 2026-09-21 第二版参考稿):四列各一个名字,列宽与下面的行同一套。
      if !items.isEmpty {
        HStack(spacing: Tokens.V1.Space.sm) {
          Text("会议名称").frame(maxWidth: .infinity, alignment: .leading)
          Text("时间").frame(width: Tokens.V1.Size.homeColTime, alignment: .trailing)
          Text("状态").frame(width: Tokens.V1.Size.homeColState, alignment: .leading)
          Text("操作").frame(width: Tokens.V1.Size.homeColAction)
        }
        .font(Tokens.V1.Text.micro.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .padding(.horizontal, Tokens.V1.Space.xs)
        .frame(height: Tokens.V1.Size.control)
        .overlay(alignment: .bottom) {
          Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
        }
        .accessibilityHidden(true)
      }
      // 行与行之间 1px 细线,恢复设计稿(`.meet .list > li + li`)。实现一度丢了它,
      // 八行字堆在一起没有边界——owner 说的「不分栏」。
      LazyVStack(spacing: 0) {
        ForEach(items) { item in
          row(item)
            .overlay(alignment: .bottom) {
              if item.id != items.last?.id {
                Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
              }
            }
        }
      }
    }
    // 「最近的会」装进一张卡(owner 2026-09-21 批的首页参考稿):入口卡下面不再是一片
    // 裸列表,两块各成一张,上重下轻。这张是列表卡——raised 白底加 1px rule、不投影;
    // 和入口卡的「背景图 + sh2」拉开一档,主次一眼可分。
    .padding(.horizontal, Tokens.V1.Space.lg)
    .padding(.vertical, Tokens.V1.Space.md)
    .background(Tokens.V1.Color.raised, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg))
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
        .strokeBorder(Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
    )
    .runtimeAccessibilityIdentifier("home.meetings")
    .confirmationDialog(
      "删除会议？",
      isPresented: Binding(
        get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
      titleVisibility: .visible, presenting: model.pendingDeletion
    ) { item in
      Button("删除「\(item.title)」", role: .destructive) {
        Task { await model.confirmDeletion(of: item) {} }
      }
      Button("取消", role: .cancel) {}
    } message: { _ in
      Text("这场会议的录音、转写、补充记录和纪要会一并永久删除，无法恢复。已加入的待办与来源摘录会保留。")
        .runtimeAccessibilityIdentifier("meeting.delete.keeps-todos")
    }
    .confirmationDialog(
      "\(reprocessTitle)？",
      isPresented: Binding(
        get: { model.pendingReprocess != nil }, set: { if !$0 { model.pendingReprocess = nil } }),
      titleVisibility: .visible, presenting: model.pendingReprocess
    ) { item in
      Button("\(reprocessTitle)（按全时长计费）", role: .destructive) { model.retryPostMeeting(for: item) }
      Button("取消", role: .cancel) {}
    } message: { item in
      Text(
        model.pipelineState(for: item).transcription == .notStarted
          ? "将上传「\(item.title)」的录音做精转并按全时长计费。结果替换现有转写时会先备份；新转写的人物标注需要确认。"
          : "将重新上传「\(item.title)」的录音并按全时长计费。新结果替换时会备份旧转写和人物标注；新转写的人物标注需重新确认。")
    }
    .confirmationDialog(
      "生成纪要",
      isPresented: Binding(
        get: { model.pendingMinutesGeneration != nil },
        set: { if !$0 { model.pendingMinutesGeneration = nil } }),
      titleVisibility: .visible, presenting: model.pendingMinutesGeneration
    ) { item in
      Button(MinutesGenerationScope.chineseOnly.actionTitle) {
        model.generateMinutes(for: item, scope: .chineseOnly)
      }
      Button(MinutesGenerationScope.bilingual.actionTitle) {
        model.generateMinutes(for: item, scope: .bilingual)
      }
      Button("取消", role: .cancel) {}
    } message: { _ in
      Text("一种语言一次模型调用。只按盘上的转写生成，不重新精转、不按录音时长计费。")
    }
    .alert(
      "重命名会议",
      isPresented: Binding(
        get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }),
      presenting: renameTarget
    ) { item in
      TextField("会议名称", text: $renamedTitle)
      Button("保存") { _ = model.rename(item, to: renamedTitle) }
      Button("取消", role: .cancel) {}
    }
  }

  private func homeError(_ text: String) -> some View {
    Text(text).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.warn)
  }

  private func row(_ item: MeetingLibraryItem) -> some View {
    let state = model.pipelineState(for: item)
    return HStack(spacing: Tokens.V1.Space.sm) {
      Button {
        open(item)
      } label: {
        // 客户不占列:绝大多数会议没有客户,整列空着只会显得像填错位。
        // 有客户时紧跟会名,没有就什么都不出现。
        HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
          Text(item.title).font(Tokens.V1.Text.body.font).lineLimit(1)
          if let client = item.client, !client.isEmpty {
            // 客户是一枚描边小标签(参考稿):和会名分得开,又不抢会名。不按客户换颜色。
            Text(client)
              .font(.system(size: Tokens.V1.Text.micro.size))
              .foregroundStyle(Tokens.V1.Color.ink2)
              .lineLimit(1)
              .padding(.horizontal, Tokens.V1.Space.s2xs)
              .padding(.vertical, Tokens.V1.Space.s3xs / 2)
              .overlay(
                RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs)
                  .strokeBorder(Tokens.V1.Color.controlRule, lineWidth: Tokens.V1.Size.controlRuleWidth)
              )
              .layoutPriority(-1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain)
      // 时间是这一行第二要紧的信息,用 12 号等宽(会议库更密,仍是 11 号 timecode)。
      Text(ChineseDateText.dayAndTime(item.startedAt))
        .font(.system(size: Tokens.V1.Text.meta.size, design: .monospaced))
        .foregroundStyle(Tokens.V1.Color.ink3).lineLimit(1)
        .frame(width: Tokens.V1.Size.homeColTime, alignment: .trailing)
      // 与会议库共用同一枚结论胶囊,同一件事不再两个页面两套判定。
      MeetingOutcomePill(
        MeetingOutcomePill.outcome(
          for: state, acknowledgedCompleteness: item.effectiveCompleteness?.verdict == .acknowledged)
      )
      .frame(width: Tokens.V1.Size.homeColState, alignment: .leading)
      Group {
        if state.nextAction != .none || state.hasFormalMinutes || state.completeness == .red
          || state.transcription == .inProgress || state.minutes == .inProgress
        {
          Button(nextTitle(state)) { next(item, state: state) }
            .buttonStyle(V1ButtonStyle.v1Outline.height(Tokens.V1.Size.controlSm))
            .disabled(!nextEnabled(item, state: state))
        } else {
          Color.clear
        }
      }
      .frame(width: Tokens.V1.Size.homeColAction)
    }
    .padding(.horizontal, Tokens.V1.Space.xs)
    .frame(height: Tokens.V1.Size.rowHome)
    .background(HomeRowHover())
    // 行尾原来常驻一枚「⋯」(owner 2026-09-21:「这个点有啥用呢?也没啥用啊」)。
    // 里面的重命名 / 删除 / 导出不是没用,是不该占一整列常驻:收进右键菜单——Mac 上
    // 对某一行的次要操作本来就在右键里,需要时在,不需要时不占地方。
    .contextMenu {
      Button("重命名") {
        renamedTitle = item.title
        renameTarget = item
      }
      Button("导出") { export(item) }.disabled(!model.canExport(item))
      Divider()
      Button("删除", role: .destructive) { model.pendingDeletion = item }
        .disabled(!model.isDeletable(item))
    }
    .runtimeAccessibilityIdentifier("home.meeting.\(item.id)")
  }

  /// 确认框标题跟着这场会的状态走:从没精转过叫「精转」,不是「重新精转」。
  private var reprocessTitle: String {
    model.pendingReprocess.map { model.pipelineState(for: $0).transcriptionActionTitle } ?? "精转"
  }

  private func nextEnabled(_ item: MeetingLibraryItem, state: MeetingPipelineState) -> Bool {
    if state.completeness == .red || state.hasFormalMinutes || state.nextAction == .none {
      return true
    }
    return state.nextAction == .retryTranscription
      ? model.canRetryPostMeeting(for: item) : model.canGenerateMinutes(for: item)
  }

  private func nextTitle(_ state: MeetingPipelineState) -> String {
    if state.transcription == .inProgress || state.minutes == .inProgress { return "查看进度" }
    if state.completeness == .red { return "去确认" }
    // 点进去是这场会的详情,里面不止纪要:一页纸、纪要、完整转写、会中记录都在。
    // 所以叫「查看详情」,不叫「查看纪要」。下面 .none 那支走的是同一个 open(item),
    // 原来叫「查看会议」,同一个动作不留两个名字。
    if state.hasFormalMinutes { return "查看详情" }
    switch state.nextAction {
    case .retryTranscription: return state.transcriptionActionTitle
    case .generateMinutes, .regenerateMinutes: return "生成纪要"
    case .confirmCompleteness: return "去确认"
    case .none: return "查看详情"
    }
  }

  private func next(_ item: MeetingLibraryItem, state: MeetingPipelineState) {
    HangSentinel.shared.note("home:next:\(state.nextAction.rawValue)")
    if state.completeness == .red || state.hasFormalMinutes || state.nextAction == .none {
      open(item)
    } else if state.nextAction == .retryTranscription {
      model.pendingReprocess = item
    } else if model.canGenerateMinutes(for: item) {
      model.pendingMinutesGeneration = item
    }
  }

  private func open(_ item: MeetingLibraryItem) {
    coordinator.openLibrary(focus: item.paths.directory)
    coordinator.librarySelectedTab = item.hasFormalMinutes ? .minutes : .onePage
  }

  private func export(_ item: MeetingLibraryItem) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "导出"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.exportMeetingPackage(for: item, to: url)
  }
}

enum HomeMeetingFilter: String, CaseIterable {
  case all, transcription, minutes, confirmation
  var title: String {
    switch self {
    case .all: return "近 \(HomeMeetingsView.recentLimit) 场"
    // 措辞与会议库的 LibraryQueueFilter 对齐。后两档谓词完全相同,直接用同一个词;
    // 第一档在首页是「待精转 + 精转失败」的并集(没做过的也该出现在待办里),
    // 所以叫「精转未完成」,而不是会议库那档只管失败的「精转失败」。
    case .transcription: return "精转未完成"
    case .minutes: return "待纪要"
    case .confirmation: return "完备度缺"
    }
  }
  func matches(_ state: MeetingPipelineState) -> Bool {
    switch self {
    case .all: return true
    case .transcription: return state.transcription == .notStarted || state.transcription == .failed
    case .minutes: return LibraryQueueFilter.awaitingMinutes.matches(state)
    case .confirmation: return state.completeness == .red
    }
  }
}

private struct HomeRowHover: View {
  @State private var hovered = false
  var body: some View {
    RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
      .fill(hovered ? Tokens.V1.Color.paper2 : .clear)
      .onHover { hovered = $0 }
  }
}
