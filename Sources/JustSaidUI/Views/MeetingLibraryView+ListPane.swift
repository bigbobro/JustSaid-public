import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

// 2026-08-20 批3 拆分:自 MeetingLibraryView.swift 按 MARK 边界机械迁出,零行为变更。
extension MeetingLibraryView {
  // MARK: - 列表

  var meetingList: some View {
    VStack(alignment: .leading, spacing: .zero) {
      if let deletionError = model.deletionError {
        DegradedBanner(text: deletionError)
      }
      HStack(spacing: Tokens.V1.Space.xs) {
        Text("分组").font(Tokens.V1.Text.meta.font)
        // 四档:不分 / 按天 / 按客户 / 按项目(owner 2026-09-20)。
        V1SegmentedPicker(
          "会议分组", selection: $model.grouping,
          options: LibraryGrouping.allCases.map { .init($0, $0.title) }
        )
        .runtimeAccessibilityIdentifier("library.group.toggle")
        // 搜索提到这一行:原来它独占一行,分组一行、胶囊一行、搜索一行,三行里两行是空的。
        librarySearchRow
          .frame(maxWidth: Tokens.V1.Size.sideWidth)
        Spacer(minLength: Tokens.V1.Space.xs)
      }
      .padding(.horizontal, Tokens.V1.Space.lg)
      .frame(height: Tokens.V1.Size.barHeight)
      .overlay(alignment: .bottom) {
        Rectangle().fill(Tokens.V1.Color.rule)
          .frame(height: Tokens.V1.Size.controlRuleWidth)
      }
      if let importError = model.importError {
        DegradedBanner(text: importError)
      }
      if model.isImporting {
        Text("正在导入录音…")
          .font(.system(size: Tokens.V1.Text.body.size))
          .foregroundStyle(Tokens.V1.Color.ink3)
          .padding(.horizontal, Tokens.V1.Space.md)
      }

      // 搜索已并进上面的分组行;胶囊行只在有条件时出现,不再独占一行空位。
      libraryFilterChips

      if model.meetings.isEmpty {
        if model.isReloading {
          VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
            ProgressView()
              .controlSize(.small)
            Text("正在读取会议库…")
              .font(.system(size: textScale.size(Tokens.V1.Text.body.size)))
              .foregroundStyle(Tokens.V1.Color.ink3)
          }
          .runtimeAccessibilityIdentifier("library.loading-list-content")
          .padding(Tokens.V1.Space.md)
          Spacer()
        } else {
          VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
            Text("还没有会议记录")
              .font(.system(size: textScale.size(Tokens.V1.Text.body.size), weight: .semibold))
              .foregroundStyle(Tokens.V1.Color.ink2)
            // 空态不再自带按钮:顶栏已有「开始记录」,同屏两颗会违反 MW-R8c。
            // 这句话把人指向那一颗,位置在满库与空库下都不变。
            Text("用上面的「开始记录」开一场会，结束后这里会出现纪要、转写和补充记录。")
              .font(.system(size: textScale.size(Tokens.V1.Text.body.size)))
              .foregroundStyle(Tokens.V1.Color.ink3)
              .runtimeAccessibilityIdentifier("library.empty-start-hint")
          }
          .runtimeAccessibilityIdentifier("library.empty-list-content")
          .padding(Tokens.V1.Space.md)
          Spacer()
        }
      } else if !normalizedLibrarySearchQuery.isEmpty {
        // 全库搜索态:结果组代替满库列表;清空 query 即回满库(呈现切换,零落盘)。
        librarySearchResultsList
      } else {
        libraryColumnHeader
        // 容器用 List 而不是 ScrollView + LazyVStack(2026-09-20 实测)。
        // LazyVStack 的 lazy 只是延迟创建,创建过的行一直挂在视图图里不销毁——
        // 从头滚到尾,45 行全变成活的。List 背后是 NSTableView,做真复用,
        // 只有可视区那十几行活着(无障碍树元素数 200 → 53)。
        List {
          // 分组是纯呈现(08-17 R-b):同一份 rows、同一个容器,开了只是插节头;
          // 方向键遍历走 model.visibleOrderedMeetings,与这里的可视顺序同源。
          if model.grouping.isSectioned {
            ForEach(model.clientSections) { section in
              clientSectionHeader(section).v1LibraryListRow()
              ForEach(section.items) { item in
                meetingRow(item).v1LibraryListRow()
              }
            }
          } else if model.grouping == .none {
            // 不分组:一条流水,没有任何节头。
            ForEach(model.queueFilteredMeetings) { item in
              meetingRow(item).v1LibraryListRow()
            }
          } else {
            ForEach(meetingDaySections) { section in
              // 日期分隔要一眼认出来:原来用 meta + ink3,和正文同一个重量,扫过去分不清。
              // `.formatted(date: .abbreviated)` 跟系统区域走,英文机器上会画成
              // 「Jul 28, 2026」——整个 app 是中文,这一行忽然变英文(2026-09-20
              // 从截图装置拍出的会议库列表里看出来的)。照设计稿写死中文:
              // 今天/昨天优先,其余「9月16日 周三」。
              Text(Self.dayHeaderLabel(section.day))
                .font(Tokens.V1.Text.micro.font)
                .foregroundStyle(Tokens.V1.Color.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.V1.Space.md)
                .padding(.vertical, Tokens.V1.Space.xs)
                .v1LibraryListRow()
              ForEach(section.items) { item in
                meetingRow(item).v1LibraryListRow()
              }
            }
          }
        }
        .modifier(
          RememberedListScrollPositionModifier(
            $retainedListScrollPosition, rowIDs: listScrollRowIDs)
        )
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Tokens.V1.Size.libraryRow)
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
          if let item = model.selectedItem { openMeetingPage(item) }
          return .handled
        }
        .accessibilityElement(children: .contain)
      }
    }
    .background(Tokens.V1.Color.paper)
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
      Text("这场会议的录音、转写、补充记录和纪要会一并永久删除，无法恢复。已加入的待办与来源摘录会保留。")
        .runtimeAccessibilityIdentifier("meeting.delete.keeps-todos")
    }
  }

  /// 与 List 的原生行顺序一致；nil 是分组头，不参与会议选择。
  private var listScrollRowIDs: [String?] {
    if model.grouping.isSectioned {
      return model.clientSections.flatMap { [nil] + $0.items.map { Optional($0.id) } }
    }
    if model.grouping == .none {
      return model.queueFilteredMeetings.map { Optional($0.id) }
    }
    return meetingDaySections.flatMap { [nil] + $0.items.map { Optional($0.id) } }
  }

  /// 按天分组走一遍列表就够。原来是「先求出所有日子,再为每一天把整份列表 filter 一遍」,
  /// 天数 × 会议数次 `Calendar.current` + `isDate`,每次 body 求值都重来一遍。
  private var meetingDaySections: [MeetingDaySection] {
    let calendar = Calendar.current
    var buckets: [Date: [MeetingLibraryItem]] = [:]
    for item in model.queueFilteredMeetings {
      buckets[calendar.startOfDay(for: item.startedAt), default: []].append(item)
    }
    return buckets.keys.sorted(by: >).map { MeetingDaySection(day: $0, items: buckets[$0] ?? []) }
  }

  /// 日期分组头。措辞、时区与缓存都在 `ChineseDateText` 一处收口——
  /// 这里原来自己建两个 DateFormatter(实测每次 156 µs),一屏几十个分组头就是几毫秒。
  static func dayHeaderLabel(_ day: Date) -> String {
    ChineseDateText.dayHeader(day)
  }

  private var libraryColumnHeader: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Text("时间").frame(width: Tokens.V1.Size.libraryColTime, alignment: .leading)
      Text("时长").frame(width: Tokens.V1.Size.libraryColDuration, alignment: .trailing)
      Text("会议").frame(maxWidth: .infinity, alignment: .leading)
      Text("客户").frame(width: Tokens.V1.Size.libraryColClient, alignment: .leading)
      Text("项目").frame(width: Tokens.V1.Size.libraryColProject, alignment: .leading)
      Text("状态").frame(width: Tokens.V1.Size.libraryColOutcome, alignment: .trailing)
    }
    // 表头按设计系统 .thead:11 半粗 + ink3 + 一条下边线。
    // 原来用 meta(12 常规)且没有分隔线,和下面的数据行同一个视觉重量,读者看不出这是表头。
    .font(Tokens.V1.Text.micro.font)
    .foregroundStyle(Tokens.V1.Color.ink3)
    // macOS plain List retains an 8pt native row inset even with zero listRowInsets.
    // Match that inset in the header; screenshot checks pin both column edges.
    .padding(.horizontal, Tokens.V1.Space.md + Tokens.V1.Space.xs)
    .padding(.vertical, Tokens.V1.Space.xs)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule)
        .frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .runtimeAccessibilityIdentifier("library.columns")
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
      // 单击只选中(owner 2026-09-20):原来一点就换页,想挑一行看看都做不到。
      // 打开走双击或回车,和 Finder 一致。选中不动滚动位置——点哪一行,列表就待在原处。
      onSelect: {
        focusedMeetingTitleID = nil
        focusedPane = .list
        // 点已选中行不会触发 onChange,置 false 防旗标滞留下一次程序性选中。
        suppressNextSelectionScroll = model.selectedID != item.id
        model.select(item.id)
      },
      onOpen: {
        focusedMeetingTitleID = nil
        suppressNextSelectionScroll = model.selectedID != item.id
        model.select(item.id)
        openMeetingPage(item)
      },
      onRename: {
        suppressNextSelectionScroll = model.selectedID != item.id
        model.select(item.id)
        openMeetingPage(item)
        focusedMeetingTitleID = item.id
      },
      onExport: { chooseExportDestination(for: item) },
      onCompleteness: { openMeetingPage(item) }
    )
  }

  /// 分组节头(08-17 R-b):客户名 + 场数;「未标注」段与有名段同一构造。
  private func clientSectionHeader(_ section: MeetingClientSection) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
      Text(section.title)
        .font(.system(size: Tokens.V1.Text.meta.size, weight: .semibold))
        .foregroundStyle(Tokens.V1.Color.ink2)
        .lineLimit(1)
        .truncationMode(.tail)
      Text("\(section.items.count) 场")
        .font(.system(size: Tokens.V1.Text.micro.size))
        .foregroundStyle(Tokens.V1.Color.ink4)
        .fixedSize(horizontal: true, vertical: false)
      Spacer(minLength: .zero)
    }
    .padding(.horizontal, Tokens.V1.Space.md)
    .padding(.top, Tokens.V1.Space.sm)
    .padding(.bottom, Tokens.V1.Space.s2xs)
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
  let onOpen: () -> Void
  let onRename: () -> Void
  let onExport: () -> Void
  let onCompleteness: () -> Void
  @State private var isHovering = false
  @State private var activeStatus: String?
  @State private var statusHover: String?
  @State private var lastTapAt: Date?

  private var isSelected: Bool { model.selectedID == item.id }

  var body: some View {
    ZStack {
      // 单击立刻选中,第二下才打开。不用 onTapGesture(count: 2):那样 SwiftUI 必须
      // 等满系统双击间隔确认没有第二下,单击才生效,换选中要等半秒(owner 实测)。
      // 自己按时间戳判断:第一下当场选中,间隔内再来一下就打开。
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture {
          let now = Date()
          if let last = lastTapAt, now.timeIntervalSince(last) <= NSEvent.doubleClickInterval {
            lastTapAt = nil
            onOpen()
          } else {
            lastTapAt = now
            onSelect()
          }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("选择「\(item.title)」")
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: "打开") { onOpen() }
        .runtimeAccessibilityIdentifier("library.row.select")
      HStack(spacing: Tokens.V1.Space.xs) {
        Text(ChineseDateText.time(item.startedAt))
          .font(Tokens.V1.Text.timecode.font)
          .frame(width: Tokens.V1.Size.libraryColTime, alignment: .leading)
          .allowsHitTesting(false)
        // 时长单独成列(owner 2026-09-20 选的 B 案):原来它吊在会名底下的副行里,
        // 和左边的开始时间同为「x:xx」,读者分不出哪个是时间点哪个是时长。
        Text(item.compactDurationLabel)
          .font(Tokens.V1.Text.meta.font)
          .monospacedDigit()
          .foregroundStyle(Tokens.V1.Color.ink3)
          .lineLimit(1)
          // 右对齐:「1 小时 30 分钟」与「33 分钟」左对齐时右边缘参差,数字列按右缘对齐更好扫。
          .frame(width: Tokens.V1.Size.libraryColDuration, alignment: .trailing)
          .allowsHitTesting(false)
          .runtimeAccessibilityIdentifier("library.row.duration")
        VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
          Text(item.title)
            .font(isSelected ? Tokens.V1.Text.strong.font : Tokens.V1.Text.body.font)
            .foregroundStyle(Tokens.V1.Color.ink)
            .lineLimit(1)
          // 时长已移到独立列;这里只留真正的例外标记,没有例外时整行只有一行会名。
          if item.isImportedRecording || item.hasPartialCapture {
            HStack(spacing: Tokens.V1.Space.xs) {
              if item.isImportedRecording { Text("导入录音") }
              if item.hasPartialCapture {
                Text("部分录音")
                  .foregroundStyle(Tokens.V1.Color.warn)
                  .runtimeAccessibilityIdentifier("library.row.partial-capture")
              }
            }
            .font(Tokens.V1.Text.meta.font)
            .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        // 客户列只写短记号(owner 2026-09-21):同一家客户在这一列上下对齐,扫一眼就认得出;
        // 跟在会名后面的标签做不到这一点。规则见 `ClientMonogram`。全名在右键菜单「客户：…」、
        // 筛选面板和会议页头部。这里不挂悬停提示:每行一个常驻 tooltip 是滚动卡顿的来源之一。
        Group {
          if let client = item.client {
            Text(ClientMonogram.make(client))
              .font(Tokens.V1.Text.micro.font)
              .foregroundStyle(Tokens.V1.Color.ink2)
              .padding(.horizontal, Tokens.V1.Space.s2xs)
              .padding(.vertical, Tokens.V1.Space.s3xs)
              .background(
                Tokens.V1.Color.paper3, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs))
              .accessibilityLabel("客户：\(client)")
              .runtimeAccessibilityIdentifier("library.row.client-chip")
          } else { Text("") }
        }
        .lineLimit(1)
        .frame(width: Tokens.V1.Size.libraryColClient, alignment: .leading)
        .allowsHitTesting(false)
        // 项目列:与客户并列的第二个标签维度。筛选面板与分组都已经按它分,
        // 列表里却没有它,槽位空着(owner 2026-09-20 框出)。
        // 列宽只够五个汉字,更长的截成前四个字加省略号(owner 2026-09-21「前 4 个字或前 5 个字」)。
        Group {
          if let project = item.project {
            Text(project).runtimeAccessibilityIdentifier("library.row.project-chip")
          } else { Text("") }
        }
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: Tokens.V1.Size.libraryColProject, alignment: .leading)
        .allowsHitTesting(false)
        // 三列过程收敛成一列结论(owner 2026-09-20)。点它仍然弹补做浮层,
        // 哪一步缺、要做什么在浮层里说;列表只回答「这场会好了没有」。
        outcomeButton
      }
      .foregroundStyle(Tokens.V1.Color.ink3)
      .padding(.horizontal, Tokens.V1.Space.md)
    }
    .frame(height: Tokens.V1.Size.libraryRow)
    .background(isSelected ? Tokens.V1.Color.paper2 : (isHovering ? Tokens.V1.Color.scrim : .clear))
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .onHover { isHovering = $0 }
    // 行尾原来挂一颗「更多」按钮,每个可视行都要桥接一套 NSMenu,滚动时每帧都过一遍
    // (owner 2026-09-20 实测:摘掉它滑动明显变顺)。改成整行右键——右键菜单的内容
    // SwiftUI 按需构建,平时一个都不建,而且右键的命中区是整行,比那颗小按钮还好点。
    .contextMenu {
      // 客户与项目原来只能在会议详情头部贴,入口太深:45 场里 43 场没客户、40 场没项目,
      // 「按客户/按项目」两档分组因此几乎没用(owner 2026-09-20)。
      tagMenu("客户", kind: .client, current: item.client, item: item)
      tagMenu("项目", kind: .project, current: item.project, item: item)
      Divider()
      Button("打开会议", action: onOpen)
      Button("重命名", action: onRename)
      Button("导出会议包…", action: onExport)
        .disabled(model.isExporting || !item.hasAuthoritativeTranscript || !item.hasChineseMinutes)
      Button("删除这场会议…", role: .destructive) { model.pendingDeletion = item }
        .disabled(!model.isDeletable(item))
    }
    .id(item.id)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .runtimeAccessibilityIdentifier("library.row")
  }

  /// 行尾菜单里的贴标签子菜单:列出库里已有的取值直接点,外加「清除」。
  /// 新值仍然去会议详情里输入(那里有输入框),这里只解决「已有的标签贴不上」这件事。
  @ViewBuilder
  private func tagMenu(
    _ title: String, kind: MeetingTagKind, current: String?, item: MeetingLibraryItem
  ) -> some View {
    let values: [String] = {
      let all = model.meetings.compactMap { kind == .client ? $0.client : $0.project }
      return Array(Set(all)).sorted()
    }()
    Menu(current.map { "\(title)：\($0)" } ?? "设置\(title)…") {
      ForEach(values, id: \.self) { value in
        Button {
          model.updateTag(kind, to: value, of: item)
        } label: {
          if value == current {
            Label(value, systemImage: "checkmark")
          } else {
            Text(value)
          }
        }
      }
      if current != nil {
        Divider()
        Button("清除\(title)") { model.updateTag(kind, to: "", of: item) }
      }
    }
    .disabled(values.isEmpty && current == nil)
  }

  /// 一列结论。点开的浮层里才是三步明细与补做动作——列表只回答「这场会好了没有」。
  /// 浮层只挂在真打开的那一行。每行常驻一个 .popover,等于每行都搭一套 AppKit 桥接,
  /// 滚动时每帧都要过一遍(owner 2026-09-20 实测:摘掉浮层与菜单,滑动从「阻滞」变成
  /// 「能接受」)。按需挂载之后平时零成本,锚点与外观和以前一样。
  private var outcomeButton: some View {
    Group {
      if activeStatus == "outcome" {
        outcomePill.popover(isPresented: Binding(
          get: { activeStatus == "outcome" }, set: { if !$0 { activeStatus = nil } }
        )) {
          outcomePopover
        }
      } else {
        outcomePill
      }
    }
    // 右对齐(owner 2026-09-21):胶囊宽窄不一,左对齐时右边空出一大块。列宽仍按最宽的
    // 「正在生成纪要」留,短胶囊的余量落在左边。frame 挂在浮层外面,浮层箭头对准胶囊本身。
    .frame(width: Tokens.V1.Size.libraryColOutcome, alignment: .trailing)
  }

  private var outcomePill: some View {
    let state = model.pipelineState(for: item)
    let acknowledged = item.effectiveCompleteness?.verdict == .acknowledged
    return Button {
      HangSentinel.shared.note("library:outcome")
      activeStatus = activeStatus == nil ? "outcome" : nil
    } label: {
      MeetingOutcomePill(
        MeetingOutcomePill.outcome(for: state, acknowledgedCompleteness: acknowledged))
    }
    .buttonStyle(.plain)
    .runtimeAccessibilityIdentifier("library.row.outcome")
  }

  @ViewBuilder
  private var outcomePopover: some View {
    Group {
      // 浮层回答「还差什么」,不是把三步档案念一遍。
      // 原来三步一视同仁地堆成三段,每段都是字形、标题、按钮、说明四样,
      // 按钮还被挤成「重新…」「生成…」,一眼全是省略号(owner 2026-09-20「太丑了」)。
      // 现在:做完的只用一行带勾的文字带过;要你动手的那一步才给说明和按钮。
      let steps: [(String, String, StatusGlyph.State)] = [
        ("精转", "transcription", glyph(model.transcriptionProgress(for: item))),
        ("纪要", "minutes", glyph(model.minutesProgress(for: item))),
        ("完备度", "completeness", completenessGlyph),
      ]
      let pending = steps.filter { $0.2 != .done && $0.2 != .confirmed }
      VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
        if pending.isEmpty {
          Label("三步都齐了", systemImage: "checkmark")
            .font(Tokens.V1.Text.strong.font)
            .foregroundStyle(Tokens.V1.Color.ok)
          Text("精转、纪要、完备度都已完成。需要重跑时从下面进入。")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
          Divider()
          outcomeAction("重新精转", key: "transcription")
        } else {
          // 做完的步骤压成一行,不占篇幅
          ForEach(steps.filter { $0.2 == .done || $0.2 == .confirmed }, id: \.1) { step in
            Label("\(step.0)：\(stateLabel(step.2))", systemImage: "checkmark")
              .font(Tokens.V1.Text.meta.font)
              .foregroundStyle(Tokens.V1.Color.ink3)
          }
          ForEach(pending, id: \.1) { step in
            VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
              Text("\(step.0)：\(stateLabel(step.2))").font(Tokens.V1.Text.strong.font)
              Text(statusExplanation(step.1))
                .font(Tokens.V1.Text.meta.font)
                .foregroundStyle(Tokens.V1.Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
              outcomeAction(
                step.1 == "transcription" ? model.pipelineState(for: item).transcriptionActionTitle
                  : step.1 == "minutes" ? "生成纪要" : "去确认",
                key: step.1)
            }
          }
        }
      }
      .padding(Tokens.V1.Space.md)
      .frame(width: Tokens.V1.Size.panelWidth)
    }
  }

  /// 浮层里的补做按钮。文案写全不截断——按钮位置够宽,原来「重新…」是我把槽位压太窄。
  private func outcomeAction(_ title: String, key: String) -> some View {
    Button(title) {
      activeStatus = nil
      model.select(item.id)
      if key == "transcription" { model.pendingReprocess = item } else if key == "minutes" {
        model.pendingMinutesGeneration = item
      } else {
        onCompleteness()
      }
    }
    .buttonStyle(V1ButtonStyle.v1Outline.height(Tokens.V1.Size.controlSm))
    .fixedSize()
    .disabled(
      key == "transcription"
        ? !model.canRetryPostMeeting(for: item)
        : key == "minutes" ? !model.canGenerateMinutes(for: item) : false)
    .runtimeAccessibilityIdentifier("library.row.status.\(key)")
  }

  private func statusExplanation(_ key: String) -> String {
    switch key {
    case "transcription":
      return model.postMeetingFailureReason(for: item)
        ?? "\(model.transcriptionStatusLabel(for: item))。重新精转将按全长计费，下一步会再次确认。"
    case "minutes":
      return item.hasFormalMinutes ? "已有纪要，可重新生成；下一步选择语言与计费份数。"
        : "这场会还没有纪要。需要先完成精转，再选择语言与计费份数。"
    default:
      return item.effectiveCompleteness?.verdict == .red
        ? "录音、转写或纪要存在缺口，请进入会议页查看并逐项确认。"
        : "进入会议页查看完备度依据与已有确认。"
    }
  }

  private func stateLabel(_ state: StatusGlyph.State) -> String {
    switch state {
    case .done: return "完成"
    case .running: return "处理中"
    case .attention: return "待处理"
    case .confirmed: return "已确认"
    case .none: return "未做"
    }
  }

  private func glyph(_ progress: MeetingArtifactProgress) -> StatusGlyph.State {
    switch progress {
    case .completed: return .done
    case .inProgress: return .running
    case .failed: return .attention
    case .notStarted: return .none
    }
  }

  private var completenessGlyph: StatusGlyph.State {
    switch item.effectiveCompleteness?.verdict {
    case .green: return .done
    case .acknowledged: return .confirmed
    case .red: return .attention
    case .undetermined, nil: return .none
    }
  }
}

/// 按天分组的一段:一天加这天的会。
private struct MeetingDaySection: Identifiable {
  let day: Date
  let items: [MeetingLibraryItem]
  var id: Date { day }
}


extension View {
  /// List 的行:内边距、分隔线、底色全部交还给行自己画,和 LazyVStack 时代一致。
  fileprivate func v1LibraryListRow() -> some View {
    listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }
}


/// 会议库客户列的短记号(owner 2026-09-21:「按拼音首字母或者首字」)。最多 4 个字符。
/// - 含汉字:每个汉字取拼音首字母,夹着的英文词取词首字母,大写。「三一重工」→ SYZG。
/// - 纯英文、多个词:取每个词的首字母,大写。「Trishul Engineering」→ TE。
/// - 纯英文、单个词:原样取前 4 个字母。「BEM」「ME」「Putz」不变,「Putzmeister」→ Putz。
/// 多音字按系统转写取一个读音,偶尔不准;全名始终在右键菜单与会议页里。
enum ClientMonogram {
  static let maxLength = 4

  static func make(_ name: String) -> String {
    var pieces: [String] = []
    var run = ""
    var hasHan = false
    for character in name {
      if character.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
        if !run.isEmpty { pieces.append(run); run = "" }
        pieces.append(String(character))
        hasHan = true
      } else if character.isLetter || character.isNumber {
        run.append(character)
      } else if !run.isEmpty {
        pieces.append(run)
        run = ""
      }
    }
    if !run.isEmpty { pieces.append(run) }
    guard let first = pieces.first else { return String(name.prefix(1)) }
    if !hasHan, pieces.count == 1 { return String(first.prefix(maxLength)) }
    let initials = pieces.compactMap { piece -> Character? in
      let latin = piece.applyingTransform(.toLatin, reverse: false)?
        .applyingTransform(.stripDiacritics, reverse: false) ?? piece
      return latin.first
    }
    return String(initials.prefix(maxLength)).uppercased()
  }
}
