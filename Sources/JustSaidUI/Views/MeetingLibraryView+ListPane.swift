import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

// 2026-08-20 批3 拆分:自 MeetingLibraryView.swift 按 MARK 边界机械迁出,零行为变更。
extension MeetingLibraryView {
  // MARK: - 列表

  /// 指挥台滤镜行(批3-C):库列表按「还欠什么加工」寻路。**寻路器不是第二舞台**——
  /// 视觉压 ink3/ink4 档,不与舞台/详情争第一眼。红线6 模式:调用点无条件实例化,
  /// 显隐全收在这里——空库、或所有欠账 lane 皆 0 时整行收成空;
  /// 搜索态(搜索 > 滤镜,不组合)整行置灰禁点。
  @ViewBuilder
  var libraryQueueRow: some View {
    let lanes = LibraryQueueFilter.allCases.filter { lane in
      lane != .all && model.queueCount(for: lane) > 0
    }
    if !model.meetings.isEmpty && !lanes.isEmpty {
      let isSearchActive = !normalizedLibrarySearchQuery.isEmpty
      HStack(spacing: Tokens.Spacing.xxs) {
        ForEach([LibraryQueueFilter.all] + lanes, id: \.rawValue) { lane in
          queuePill(lane)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Tokens.Spacing.md)
      .padding(.bottom, Tokens.Spacing.xs)
      .opacity(isSearchActive ? 0.4 : 1)
      .disabled(isSearchActive)
      .accessibilityElement(children: .contain)
      .runtimeAccessibilityIdentifier("library.queue")
    }
  }

  private func queuePill(_ lane: LibraryQueueFilter) -> some View {
    let isOn = model.effectiveQueueFilter == lane
    let count = model.queueCount(for: lane)
    return Button {
      model.queueFilter = lane
    } label: {
      HStack(spacing: Tokens.Spacing.hairline) {
        Text(lane.title)
          .foregroundStyle(isOn ? Tokens.Color.acDeep : Tokens.Color.ink3)
        if lane != .all {
          Text("\(count)")
            .foregroundStyle(isOn ? Tokens.Color.acDeep : queueCountColor(lane))
        }
      }
      .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
      .padding(.horizontal, Tokens.Spacing.xxs)
      .frame(height: Tokens.Layout.libraryRowChipHeight)
      .background(
        RoundedRectangle(cornerRadius: Tokens.Radius.chip)
          .fill(isOn ? Tokens.Color.acSoft : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.chip)
          .stroke(isOn ? Tokens.Color.acLine : Tokens.Color.line, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip))
    }
    .buttonStyle(.plain)
    // spec 把滤镜 pill / 页签 / 分组钮 / 搜索说话人 chip 定为同一套选中态词汇,
    // 但四件里只有页签有悬停(2026-08-21 走查 P-7b)。补齐,不新造样式。
    .hoverRowBackground(cornerRadius: Tokens.Radius.chip)
    .help(
      lane == .all
        ? "显示全部会议"
        : "只看「\(lane.title)」的会议"
    )
    .accessibilityLabel("按\(lane.title)过滤")
    .runtimeAccessibilityIdentifier("library.queue.lane.\(lane.rawValue)")
  }

  private func queueCountColor(_ lane: LibraryQueueFilter) -> Color {
    switch lane {
    case .all: return Tokens.Color.ink3
    case .transcriptionFailed: return Tokens.Color.warn
    case .awaitingMinutes: return Tokens.Color.warn
    case .completenessRed: return Tokens.Color.warn
    }
  }

  var meetingList: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let deletionError = model.deletionError {
        DegradedBanner(text: deletionError)
      }
      HStack(spacing: Tokens.Spacing.xsm) {
        Text("历史会议")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink3)
        Spacer()
        Text("\(model.meetings.count) 场")
          .font(.system(size: Tokens.FontSize.caption))
          .foregroundStyle(Tokens.Color.ink4)
        // 「按客户分组」(08-17 R-b):纯呈现开关,只作用于满库列表——
        // 搜索态结果本来就按会议分组,两者互不组合。
        Button {
          model.groupsByClient.toggle()
        } label: {
          Image(systemName: "person.2")
            .font(.system(size: Tokens.FontSize.caption, weight: .semibold))
            .foregroundStyle(model.groupsByClient ? Tokens.Color.acDeep : Tokens.Color.ink3)
            .padding(.horizontal, Tokens.Spacing.xxs)
            .padding(.vertical, Tokens.Spacing.hairline)
            .background(
              Capsule().fill(model.groupsByClient ? Tokens.Color.acSoft : Color.clear)
            )
            .overlay(
              Capsule().stroke(
                model.groupsByClient ? Tokens.Color.acLine : Color.clear,
                lineWidth: 1
              )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverRowBackground(cornerRadius: Tokens.Radius.pill)
        .help(
          model.groupsByClient
            ? "关闭按客户分组，回到时间倒序列表"
            : "按客户分组：按「客户」标签分段显示，无标签会议归「未标注」"
        )
        .accessibilityLabel(model.groupsByClient ? "关闭按客户分组" : "按客户分组")
        .runtimeAccessibilityIdentifier("library.group.toggle")
      }
      .padding(.horizontal, Tokens.Spacing.md)
      .padding(.vertical, Tokens.Spacing.sm)
      if let importError = model.importError {
        DegradedBanner(text: importError)
      }
      if model.isImporting {
        Text("正在导入录音…")
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink3)
          .padding(.horizontal, Tokens.Spacing.md)
      }

      libraryQueueRow

      Divider()

      if !model.meetings.isEmpty {
        librarySearchRow
      }

      if model.meetings.isEmpty {
        if model.isReloading {
          VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            ProgressView()
              .controlSize(.small)
            Text("正在读取会议库…")
              .font(.system(size: textScale.size(Tokens.FontSize.ui)))
              .foregroundStyle(Tokens.Color.ink3)
          }
          .runtimeAccessibilityIdentifier("library.loading-list-content")
          .padding(Tokens.Spacing.md)
          Spacer()
        } else {
          VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("还没有会议记录")
              .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum), weight: .semibold))
              .foregroundStyle(Tokens.Color.ink2)
            Text("开一场会，结束后这里会出现纪要、转写和补充记录。")
              .font(.system(size: textScale.size(Tokens.FontSize.ui)))
              .foregroundStyle(Tokens.Color.ink3)
            Button("开始记录") {
              onStartRecording?()
            }
            .buttonStyle(.toolbarPillAccent)
            .disabled(onStartRecording == nil)
            .runtimeAccessibilityIdentifier("library.empty-start-recording")
          }
          .runtimeAccessibilityIdentifier("library.empty-list-content")
          .padding(Tokens.Spacing.md)
          Spacer()
        }
      } else if !normalizedLibrarySearchQuery.isEmpty {
        // 全库搜索态:结果组代替满库列表;清空 query 即回满库(呈现切换,零落盘)。
        librarySearchResultsList
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            // 分组是纯呈现(08-17 R-b):同一份 rows、同一个容器,开了只是插节头;
            // 方向键遍历走 model.visibleOrderedMeetings,与这里的可视顺序同源。
            if model.groupsByClient {
              ForEach(model.clientSections) { section in
                clientSectionHeader(section)
                ForEach(section.items) { item in
                  meetingRow(item)
                }
              }
            } else {
              ForEach(model.queueFilteredMeetings) { item in
                meetingRow(item)
              }
            }
          }
          .scrollTargetLayout()
        }
        .modifier(RememberedListScrollPositionModifier($retainedListScrollPosition))
        .focusable(true)
        .focused($focusedPane, equals: .list)
        .focusEffectDisabled()
        .onMoveCommand { direction in
          switch direction {
          case .up:
            model.selectAdjacent(offset: -1)
          case .down:
            model.selectAdjacent(offset: 1)
          default:
            break
          }
        }
        .onKeyPress(.return) {
          focusedPane = .detail
          return .handled
        }
        .accessibilityElement(children: .contain)
      }
    }
    .background(Tokens.Color.pane)
    .confirmationDialog(
      "删除「\(model.pendingDeletion?.title ?? "")」?",
      isPresented: Binding(
        get: { model.pendingDeletion != nil },
        set: { if !$0 { model.pendingDeletion = nil } }
      ),
      titleVisibility: .visible,
      // 条目必须经 presenting 按值送进动作闭包:关框会同步清 pendingDeletion,
      // 而按钮动作的 Task 在其后才跑,回读 pendingDeletion 必得 nil → 删除静默空转。
      presenting: model.pendingDeletion
    ) { item in
      Button("删除", role: .destructive) {
        Task {
          await model.confirmDeletion(of: item) {
            suppressNextSelectionScroll = true
          }
        }
      }
      Button("取消", role: .cancel) {}
    } message: { _ in
      Text("这场会议的录音、转写、补充记录和纪要会一并永久删除，无法恢复。")
    }
  }

  /// 点行之后 `↑`/`↓` 不生效、要先按 Tab(#84):上面那句 `focusedPane = .list` 写在按钮
  /// 动作里,新启动后的第一次点击会被静默丢弃,所以这里隔一个 runloop 轮次再请求一次。
  ///
  /// 定位这条 bug 时加过一轮临时诊断日志,真机上钉死三件事(诊断已随本单移除):
  /// 1. 动作里写完当场回读 `focusedPane` 仍是 nil,`onChange` 一次都没触发——写入没落地,
  ///    而且失败是静默的,不回读根本看不出来;
  /// 2. 同一刻 AppKit 的 first responder,与「方向键能用」的那次完全相同(都是列表面板的
  ///    `NSHostingView`)。所以不是响应链缺位——窗口根是 `AppKitWindowHostingView`,
  ///    对它 `makeFirstResponder` 是修错了地方;方向键也不需要 `KeyViewProxy` 在场,
  ///    first responder 停在面板宿主视图时照样走 `onMoveCommand`;
  /// 3. 同一次点击的 +200ms 采样上,first responder 已经被收回窗口根宿主视图——点击这一轮
  ///    事务里 SwiftUI 自己也在动焦点,动作里的焦点请求跟这次收尾撞在一起,无处落地。
  ///
  /// 隔一轮之后再请求就被接住:验收日志里这一句写完时回读仍是 nil(焦点是异步结算的),
  /// 26ms 后 `focus-change` 报 `from=nil` 到 `.list`,方向键随即可用。判据是 `focus-change`
  /// 有没有来,不是回读当场的值。
  ///
  /// 已经是 `.list` 时重复赋同一个值对 SwiftUI 是空操作,不会打断进行中的键盘导航;
  /// 这条只碰焦点,不碰选中与滚动,#82 的邻近选中与滚动抑制不受影响。
  ///
  /// 覆盖面止于行点击这条路:右键→删除→确认/取消 不经过这里,它们靠点击已经建立的焦点。
  private func reassertListKeyboardFocus() {
    DispatchQueue.main.async {
      focusedPane = .list
    }
  }

  /// 一行会议:满库列表与分组态共用同一构造——分组只是插节头,不换行本体。
  /// 焦点/滚动抑制留在这里;选中绘制与 AX 由 `LibraryMeetingRowButton` 直接观察 model。
  private func meetingRow(_ item: MeetingLibraryItem) -> some View {
    LibraryMeetingRowButton(
      model: model,
      item: item,
      onSelect: {
        focusedMeetingTitleID = nil
        focusedPane = .list
        // 点已选中行不会触发 onChange,置 false 防旗标滞留下一次程序性选中。
        suppressNextSelectionScroll = model.selectedID != item.id
        model.select(item.id)
        reassertListKeyboardFocus()
      },
      onRename: {
        model.select(item.id)
        focusedMeetingTitleID = item.id
      }
    )
  }

  /// 分组节头(08-17 R-b):客户名 + 场数;「未标注」段与有名段同一构造。
  private func clientSectionHeader(_ section: MeetingClientSection) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
      Text(section.title)
        .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink2)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(section.title)
      Text("\(section.items.count) 场")
        .font(.system(size: Tokens.FontSize.badge))
        .foregroundStyle(Tokens.Color.ink4)
        .fixedSize(horizontal: true, vertical: false)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Tokens.Spacing.md)
    .padding(.top, Tokens.Spacing.sm)
    .padding(.bottom, Tokens.Spacing.xxs)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("客户「\(section.title)」\(section.items.count) 场会议")
    .runtimeAccessibilityIdentifier("library.group.header")
  }
}

/// 分组嵌套 ForEach 可能复用旧行;行自身观察 model,让高亮与选中 AX 一起更新。
private struct LibraryMeetingRowButton: View {
  @ObservedObject var model: MeetingLibraryModel
  let item: MeetingLibraryItem
  let onSelect: () -> Void
  let onRename: () -> Void

  private var isSelected: Bool { model.selectedID == item.id }

  var body: some View {
    Button(action: onSelect) {
      MeetingRowView(
        item: item,
        isSelected: isSelected,
        transcriptionProgress: model.transcriptionProgress(for: item),
        minutesProgress: model.minutesProgress(for: item),
        effectiveStatus: model.effectiveStatus(for: item)
      )
    }
    .buttonStyle(.plain)
    .id(item.id)
    .focusable(false)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .runtimeAccessibilityIdentifier("library.row")
    .contextMenu {
      Button(action: onRename) {
        Label("重命名", systemImage: "pencil")
      }
      Button(role: .destructive) {
        model.pendingDeletion = item
      } label: {
        Label("删除这场会议…", systemImage: "trash")
      }
      .disabled(!model.isDeletable(item))
    }
  }
}

private struct MeetingRowView: View {
  let item: MeetingLibraryItem
  let isSelected: Bool
  let transcriptionProgress: MeetingArtifactProgress
  let minutesProgress: MeetingArtifactProgress
  /// 状态点用的有效状态(08-13 可观测单 R1):进行中时实时阶段优先于磁盘快照。
  let effectiveStatus: MeetingStatus
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @State private var isHovering = false

  var body: some View {
    // 2026-08-21 批3:双行仍 40pt——上行标题+日期,下行徽章 A 词汇。
    // 信息一项不丢:标题省略号兜底 + hover 全名;日期仍 compact 标签。
    VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
      HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xsm) {
        Text(item.title)
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(item.title)
        Spacer(minLength: Tokens.Spacing.xxs)
        Text("\(item.compactStartedLabel) · \(item.compactDurationLabel)")
          .font(.system(size: Tokens.FontSize.badge).monospacedDigit())
          .foregroundStyle(Tokens.Color.ink4)
          .lineLimit(1)
          .layoutPriority(1)
          .frame(minWidth: Tokens.Layout.libraryRowDateWidth, alignment: .trailing)
      }
      HStack(alignment: .center, spacing: Tokens.Spacing.xxs) {
        MeetingStatusDot(status: effectiveStatus)
        MeetingArtifactProgressMarks(
          transcription: transcriptionProgress,
          minutes: minutesProgress
        )
        CompletenessBadge(verdict: item.effectiveCompleteness?.verdict)
        if item.hasPartialCapture {
          LibraryRowChip(
            label: "部分录音",
            foreground: Tokens.Color.warn,
            fill: Tokens.Color.warnSoft,
            stroke: Tokens.Color.amberLine
          )
          .help("部分录音")
          .accessibilityLabel("部分录音")
          .runtimeAccessibilityIdentifier("library.row.partial-capture")
        }
        Spacer(minLength: 0)
        if let client = item.client {
          LibraryRowChip(
            label: client,
            foreground: Tokens.Color.ink2,
            fill: Tokens.Color.card,
            stroke: Tokens.Color.line,
            weight: .medium
          )
          .frame(maxWidth: Tokens.Layout.libraryRowClientChipMaxWidth)
          .help("客户：\(client)")
          .accessibilityLabel("客户标签：\(client)")
          .runtimeAccessibilityIdentifier("library.row.client-chip")
        }
      }
    }
    .padding(.horizontal, Tokens.Spacing.md)
    .frame(height: Tokens.Layout.libraryRowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isSelected ? Tokens.Color.acSoft : (isHovering ? Tokens.Color.line2 : Color.clear))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(isSelected ? Tokens.Color.ac : Color.clear)
        .frame(width: 3)
    }
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Tokens.Color.line)
        .frame(height: 1)
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
  }
}
