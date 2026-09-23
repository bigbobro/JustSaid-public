import JustSaidCore
import SwiftUI

extension MeetingLibraryView {
  var libraryFilterPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        V1SecondaryPanelHeader(title: "筛选") { EmptyView() }
        filterSectionTitle("状态")
        ForEach(LibraryQueueFilter.allCases.filter { $0 != .all }, id: \.rawValue) { lane in
          filterCheckRow(
            lane.title,
            count: model.queueCount(for: lane),
            isOn: Binding(
              get: { model.queueFilter == lane },
              set: { model.queueFilter = $0 ? lane : .all })
          )
          .runtimeAccessibilityIdentifier("library.queue.lane.\(lane.rawValue)")
        }
        // 客户与项目是两个维度(owner 2026-09-20),分成两组,不再挤在一个标题下。
        filterSectionTitle("客户")
        ForEach(Array(Set(model.meetings.map { $0.client ?? "未标注" })).sorted(), id: \.self) { client in
          filterCheckRow(
            client,
            count: model.meetings.filter { ($0.client ?? "未标注") == client }.count,
            isOn: Binding(
              get: { model.filterSelection.clients.contains(client) },
              set: { selected in
                if selected { model.filterSelection.clients.insert(client) } else {
                  model.filterSelection.clients.remove(client)
                }
              })
          )
          .help(client)
        }
        filterSectionTitle("项目")
        ForEach(Array(Set(model.meetings.map { $0.project ?? "未标注" })).sorted(), id: \.self) { project in
          filterCheckRow(
            project,
            count: model.meetings.filter { ($0.project ?? "未标注") == project }.count,
            isOn: Binding(
              get: { model.filterSelection.projects.contains(project) },
              set: { selected in
                if selected { model.filterSelection.projects.insert(project) } else {
                  model.filterSelection.projects.remove(project)
                }
              })
          )
          .help(project)
        }
        filterSectionTitle("时间")
        // 设计稿这里是**四格分段**(今天 / 本周 / 本月 / 全部),不是下拉。
        // 下拉把四个选项藏起来,还得点开才知道有什么。
        V1SegmentedPicker(
          "时间", selection: $model.filterSelection.period,
          options: [.init("今天", "今天"), .init("本周", "本周"),
                    .init("本月", "本月"), .init("全部", "全部")],
          fills: true
        )
        .padding(.horizontal, Tokens.V1.Space.s2xs)
        .runtimeAccessibilityIdentifier("library.filters.period")
        filterSectionTitle("来源")
        filterCheckRow(
          "本机录制",
          count: model.meetings.filter { !$0.isImportedRecording }.count,
          isOn: Binding(
            get: { model.filterSelection.source == false },
            set: { model.filterSelection.source = $0 ? false : nil })
        )
        filterCheckRow(
          "导入录音",
          count: model.meetings.filter { $0.isImportedRecording }.count,
          isOn: Binding(
            get: { model.filterSelection.source == true },
            set: { model.filterSelection.source = $0 ? true : nil })
        )
      }
      .padding(.horizontal, Tokens.V1.Space.sm)
      .padding(.bottom, Tokens.V1.Space.md)
    }
    .modifier(V1SecondaryPanelSurface())
    .runtimeAccessibilityIdentifier("library.filters.panel")
  }

  /// 分区标题,对应设计系统 `.gh`:11 半粗 + ink-3,上方留 16。
  private func filterSectionTitle(_ text: String) -> some View {
    Text(text)
      .font(Tokens.V1.Text.micro.font)
      .foregroundStyle(Tokens.V1.Color.ink3)
      .padding(.top, Tokens.V1.Space.md)
      .padding(.bottom, Tokens.V1.Space.s2xs)
      .padding(.horizontal, Tokens.V1.Space.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 筛选行,对应设计系统 `.fl` + `.check`:14 见方的方框,选中时填 accent 墨绿并出对勾,
  /// 计数右对齐等宽。系统的 `.checkbox` 样式用的是系统强调色(本机是蓝),与 V1 不符。
  private func filterCheckRow(_ title: String, count: Int, isOn: Binding<Bool>) -> some View {
    // 零计数的条件选了也没结果:灰掉并禁用,不让人白点一次(owner 2026-09-20)。
    // 不直接隐藏,因为「现在是 0」本身是有用的信息(比如「精转失败 0」= 没有失败的)。
    let isEmpty = count == 0 && !isOn.wrappedValue
    return Button {
      isOn.wrappedValue.toggle()
    } label: {
      HStack(spacing: Tokens.V1.Space.xs) {
        V1CheckboxMark(isOn: isOn.wrappedValue)
        Text(title)
          .font(Tokens.V1.Text.meta.font)
          .lineLimit(1)
        Spacer(minLength: Tokens.V1.Space.xs)
        Text("\(count)")
          .font(Tokens.V1.Text.micro.font)
          .monospacedDigit()
      }
    }
    .buttonStyle(V1SecondaryPanelRowStyle(selected: isOn.wrappedValue))
    .disabled(isEmpty)
    .opacity(isEmpty ? Tokens.V1.Feedback.disabledOpacity : 1)
    .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
  }

  /// 有没有生效的条件。没有时整行收起,不留空行。
  private var hasActiveFilters: Bool {
    model.filterSelection != LibraryFilterSelection() || model.queueFilter != .all
      || searchMeetingFilter != nil
  }

  var libraryFilterChips: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      if model.effectiveQueueFilter != .all {
        filterChip(model.effectiveQueueFilter.title) { model.queueFilter = .all }
      }
      ForEach(model.filterSelection.clients.sorted(), id: \.self) { client in
        filterChip("客户：\(client)") { model.filterSelection.clients.remove(client) }
      }
      ForEach(model.filterSelection.projects.sorted(), id: \.self) { project in
        filterChip("项目：\(project)") { model.filterSelection.projects.remove(project) }
      }
      if model.filterSelection.period != "全部" {
        filterChip("时间：\(model.filterSelection.period)") { model.filterSelection.period = "全部" }
      }
      if let imported = model.filterSelection.source {
        filterChip(imported ? "导入录音" : "本机录制") { model.filterSelection.source = nil }
      }
      if searchMeetingFilter != nil {
        filterChip("只看这场") { searchMeetingFilter = nil }
      }
      if model.filterSelection != LibraryFilterSelection() || model.queueFilter != .all || searchMeetingFilter != nil {
        Button("清除筛选") {
          model.filterSelection = .init()
          model.queueFilter = .all
          searchMeetingFilter = nil
        }
        .buttonStyle(.v1Quiet)
        .runtimeAccessibilityIdentifier("library.filters.clear")
      }
      Spacer(minLength: .zero)
    }
    // 设计稿 .chips:固定高 40、左右 24、下边线。原来只有左右内距,
    // 结果和上面的分组行贴在一起(owner 2026-09-20 指出)。
    .padding(.horizontal, Tokens.V1.Space.lg)
    .frame(height: hasActiveFilters ? Tokens.V1.Size.chipsRowHeight : 0)
    .opacity(hasActiveFilters ? 1 : 0)
    .clipped()
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule)
        .frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .runtimeAccessibilityIdentifier("library.filters.chips")
  }

  private func filterChip(_ title: String, clear: @escaping () -> Void) -> some View {
    Button(action: clear) {
      HStack(spacing: Tokens.V1.Space.s2xs) {
        Text(title).lineLimit(1)
        Image(systemName: "xmark")
      }
    }
    .buttonStyle(.v1Quiet)
    .background(Tokens.V1.Color.accentSoft, in: Capsule())
  }
}
