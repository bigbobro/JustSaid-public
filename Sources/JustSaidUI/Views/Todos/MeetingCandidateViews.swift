import JustSaidCore
import SwiftUI

struct MeetingCandidateRailList: View {
  var board: MeetingCandidateBoard
  var onJump: (TimeInterval) -> Void
  var onRefresh: () -> Void
  var onToggle: (UUID) -> Void
  var onPrimary: (UUID) -> Void
  var onIgnore: (UUID) -> Void
  var onUndoAdd: (UUID) -> Void
  var onReadd: (UUID) -> Void
  var onRestore: (UUID) -> Void
  var onFold: (MeetingCandidateFold) -> Void
  var onAddSelected: () -> Void
  var onImportLegacy: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      HStack(alignment: .firstTextBaseline) {
        Text("待办候选")
          .font(Tokens.V1.Text.heading.font)
          .foregroundStyle(Tokens.V1.Color.ink)
        Spacer(minLength: Tokens.V1.Space.xs)
        Button(action: onRefresh) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.v1Quiet)
        .accessibilityLabel("查看纪要更新后的候选")
        .runtimeAccessibilityIdentifier("meeting.candidates.refresh")
      }
      .runtimeAccessibilityIdentifier("meeting.candidates")
      ForEach(board.notices) { notice in
        Text(notice.text)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .runtimeAccessibilityIdentifier("meeting.candidates.notice.\(notice.id)")
      }
      if let error = board.error {
        Text(error)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier("meeting.candidates.error")
      }
      if !board.pending.isEmpty {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
          SectionHeaderRow(title: "未处理", count: board.pending.count)
            .runtimeAccessibilityIdentifier("meeting.candidates.pending")
          ForEach(board.pending) { line in
            candidateRow(line, selectable: true)
          }
        }
      }
      if board.selection.count >= 2 {
        HStack(spacing: Tokens.V1.Space.xs) {
          Text("已选择 \(board.selection.count) 条")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink2)
          Spacer(minLength: Tokens.V1.Space.xs)
          Button("加入所选 \(board.selection.count) 条", action: onAddSelected)
            .buttonStyle(.v1Outline)
            .runtimeAccessibilityIdentifier("meeting.candidates.add-selected")
        }
        .runtimeAccessibilityIdentifier("meeting.candidates.selection")
      }
      fold(.added, title: "已加入", rows: board.added) { line in
        handledRow(
          line,
          actionTitle: line.permanentlyDeleted ? "重新加入" : "撤销加入",
          actionID:
            "meeting.candidates.\(line.permanentlyDeleted ? "readd" : "undo-add").\(line.id.uuidString)"
        ) {
          if line.permanentlyDeleted { onReadd(line.id) } else { onUndoAdd(line.id) }
        }
      }
      fold(.ignored, title: "已忽略", rows: board.ignored) { line in
        handledRow(
          line, actionTitle: "恢复", actionID: "meeting.candidates.restore.\(line.id.uuidString)"
        ) {
          onRestore(line.id)
        }
      }
      legacyFold
      if !board.questions.isEmpty {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
          SectionHeaderRow(title: "还没定", count: board.questions.count)
            .runtimeAccessibilityIdentifier("meeting.candidates.questions")
          ForEach(board.questions, id: \.id) { question in
            HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
              Text(question.text)
                .font(Tokens.V1.Text.body.font)
                .foregroundStyle(Tokens.V1.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
              TranscriptAnchorButton(anchor: question.anchor, onJump: onJump)
            }
          }
        }
      }
    }
  }

  private func candidateRow(_ line: MeetingCandidateLineVM, selectable: Bool) -> some View {
    let selected = board.selection.contains(line.id)
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
      HStack(alignment: .top, spacing: Tokens.V1.Space.xs) {
        if selectable {
          Button {
            onToggle(line.id)
          } label: {
            V1CheckboxMark(isOn: selected)
          }
          .buttonStyle(.plain)
          .padding(.top, Tokens.V1.Space.s3xs)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("选择候选：\(line.title)")
          .accessibilityValue(selected ? "已选择" : "未选择")
          .accessibilityAddTraits(.isButton)
          .runtimeAccessibilityIdentifier("meeting.candidates.select.\(line.id.uuidString)")
        }
        VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
          Text(line.title)
            .font(Tokens.V1.Text.body.font)
            .foregroundStyle(Tokens.V1.Color.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
            Text(line.owner)
              .font(Tokens.V1.Text.micro.font)
              .foregroundStyle(Tokens.V1.Color.ink3)
            Text(line.deadline)
              .font(Tokens.V1.Text.meta.font)
              .foregroundStyle(Tokens.V1.Color.ink3)
            Spacer(minLength: Tokens.V1.Space.xs)
            TranscriptAnchorButton(anchor: line.anchor, onJump: onJump)
          }
          if let note = line.note {
            Text(note)
              .font(Tokens.V1.Text.meta.font)
              .foregroundStyle(Tokens.V1.Color.ink2)
          }
        }
      }
      HStack(spacing: Tokens.V1.Space.xs) {
        Spacer(minLength: Tokens.V1.Space.xs)
        if line.primaryTitle == "加入待办" {
          Button("忽略") { onIgnore(line.id) }
            .buttonStyle(.v1Quiet)
            .runtimeAccessibilityIdentifier("meeting.candidates.ignore.\(line.id.uuidString)")
        }
        Button(line.primaryTitle) { onPrimary(line.id) }
          .buttonStyle(.v1Outline)
          .runtimeAccessibilityIdentifier(line.primaryIdentifier)
      }
    }
    .padding(.vertical, Tokens.V1.Space.s2xs)
    .runtimeAccessibilityIdentifier("meeting.candidates.row.\(line.id.uuidString)")
  }

  private func fold<Row: View>(
    _ fold: MeetingCandidateFold,
    title: String,
    rows: [MeetingCandidateLineVM],
    @ViewBuilder row: @escaping (MeetingCandidateLineVM) -> Row
  ) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      Button {
        onFold(fold)
      } label: {
        HStack(spacing: Tokens.V1.Space.xs) {
          Image(systemName: board.expanded.contains(fold) ? "chevron.down" : "chevron.right")
            .font(Tokens.V1.Text.micro.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
          Text(title)
            .font(Tokens.V1.Text.body.font)
            .foregroundStyle(Tokens.V1.Color.ink)
          Text("\(rows.count)")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
        }
        .frame(minHeight: Tokens.V1.Size.control, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .runtimeAccessibilityIdentifier("meeting.candidates.fold.\(fold.rawValue)")
      if board.expanded.contains(fold) {
        ForEach(rows) { line in
          row(line)
            .runtimeAccessibilityIdentifier(
              "meeting.candidates.\(fold.rawValue).\(line.id.uuidString)")
        }
      }
    }
  }

  private func handledRow(
    _ line: MeetingCandidateLineVM,
    actionTitle: String,
    actionID: String,
    action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
      Text(line.title)
        .font(Tokens.V1.Text.body.font)
        .foregroundStyle(Tokens.V1.Color.ink)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: Tokens.V1.Space.xs) {
        Text(line.owner)
        Text(line.deadline)
      }
      .font(Tokens.V1.Text.meta.font)
      .foregroundStyle(Tokens.V1.Color.ink3)
      if let note = line.note {
        Text(note)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink2)
          .runtimeAccessibilityIdentifier("meeting.candidates.absent.\(line.id.uuidString)")
      }
      Button(actionTitle, action: action)
        .buttonStyle(.v1Quiet)
        .runtimeAccessibilityIdentifier(actionID)
    }
  }

  private var legacyFold: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      Button {
        onFold(.legacy)
      } label: {
        HStack(spacing: Tokens.V1.Space.xs) {
          Image(systemName: board.expanded.contains(.legacy) ? "chevron.down" : "chevron.right")
            .font(Tokens.V1.Text.micro.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
          Text("历史已勾选")
            .font(Tokens.V1.Text.body.font)
            .foregroundStyle(Tokens.V1.Color.ink)
          Text("\(board.legacy.count)")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
        }
        .frame(minHeight: Tokens.V1.Size.control, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .runtimeAccessibilityIdentifier("meeting.candidates.fold.legacy")
      if board.expanded.contains(.legacy) {
        ForEach(board.legacy) { line in
          VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
            Text(line.title)
              .font(Tokens.V1.Text.body.font)
              .foregroundStyle(Tokens.V1.Color.ink)
              .fixedSize(horizontal: false, vertical: true)
            Text(line.detail)
              .font(Tokens.V1.Text.meta.font)
              .foregroundStyle(Tokens.V1.Color.ink2)
              .runtimeAccessibilityIdentifier("meeting.candidates.legacy.note.\(line.id)")
            if line.canImport {
              Button(line.permanentlyDeleted ? "重新加入" : "带入待办") { onImportLegacy(line.id) }
                .buttonStyle(.v1Outline)
                .runtimeAccessibilityIdentifier("meeting.candidates.legacy.import.\(line.id)")
            }
          }
          .runtimeAccessibilityIdentifier("meeting.candidates.legacy.\(line.id)")
        }
      }
    }
  }
}

struct MeetingCandidateModelRail: View {
  @ObservedObject var model: TodoPageModel
  var onJump: (TimeInterval) -> Void
  var onRefresh: () -> Void

  var body: some View {
    MeetingCandidateRailList(
      board: model.candidateBoard,
      onJump: onJump,
      onRefresh: onRefresh,
      onToggle: { model.toggleCandidateSelection($0) },
      onPrimary: { id in
        if model.candidateBoard.pending.first(where: { $0.id == id })?.primaryTitle == "核对" {
          model.beginReconcile(id)
        } else {
          model.beginCandidateClean([id])
        }
      },
      onIgnore: { model.ignoreCandidate($0) },
      onUndoAdd: { model.undoAddedCandidate($0) },
      onReadd: { model.beginCandidateReadd($0) },
      onRestore: { model.restoreIgnored($0) },
      onFold: { model.toggleCandidateFold($0) },
      onAddSelected: { model.beginCandidateClean(Array(model.candidateSelection)) },
      onImportLegacy: { model.beginLegacyImport($0) }
    )
  }
}

struct MeetingCandidateFallbackRail: View {
  var document: MeetingMinutesDocument?
  var completed: [String]
  var onJump: (TimeInterval) -> Void
  @State private var selection: Set<UUID> = []
  @State private var expanded: Set<MeetingCandidateFold> = []

  var body: some View {
    let board = Self.board(
      document: document, completed: completed, selection: selection, expanded: expanded)
    MeetingCandidateRailList(
      board: board,
      onJump: onJump,
      onRefresh: {},
      onToggle: { id in
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
      },
      onPrimary: { _ in },
      onIgnore: { _ in },
      onUndoAdd: { _ in },
      onReadd: { _ in },
      onRestore: { _ in },
      onFold: { fold in
        if expanded.contains(fold) { expanded.remove(fold) } else { expanded.insert(fold) }
      },
      onAddSelected: {},
      onImportLegacy: { _ in }
    )
  }

  private static func board(
    document: MeetingMinutesDocument?,
    completed: [String],
    selection: Set<UUID>,
    expanded: Set<MeetingCandidateFold>
  ) -> MeetingCandidateBoard {
    let items = document?.actionItems ?? []
    let hits = TodoLegacyBridge.hits(
      completedActionItems: completed, items: items, ledger: MeetingCandidateLedger())
    let legacyIDs = Set(hits.flatMap { $0.matches.compactMap(\.candidateID) })
    var board = MeetingCandidateBoard()
    board.selection = selection
    board.expanded = expanded
    board.pending = items.enumerated().compactMap { index, item in
      if legacyIDs.contains(item.id) { return nil }
      return MeetingCandidateLineVM(
        id: item.id, title: item.text,
        owner: item.owner?.nilIfBlank ?? (item.ownership == .me ? "我" : "待确认"),
        deadline: item.deadline.map { "原截止：\($0)" } ?? "原截止：待确认",
        anchor: item.recordedAt, primaryTitle: "加入待办",
        primaryIdentifier: "meeting.candidates.add.\(item.id.uuidString)", note: nil)
    }
    board.legacy = hits.enumerated().map { index, hit in
      MeetingLegacyLineVM(
        id: index,
        title: hit.matches.first?.item.text ?? hit.key,
        detail: "此前在会议中勾选过",
        canImport: false
      )
    }
    board.questions = (document?.openQuestions ?? []).map {
      ($0.id, $0.content.text, $0.content.anchor)
    }
    return board
  }
}

extension View {
  @ViewBuilder
  func meetingCandidateCover(
    page: TodoPageModel?, meetingID: UUID, onShowTodos: @escaping () -> Void,
    onJump: @escaping (TimeInterval) -> Void, onRefresh: @escaping () -> Void
  ) -> some View {
    if let page {
      modifier(
        MeetingCandidateCover(
          page: page, meetingID: meetingID,
          onShowTodos: onShowTodos, onJump: onJump, onRefresh: onRefresh))
    } else {
      self
    }
  }
}

private struct MeetingCandidateCover: ViewModifier {
  @ObservedObject var page: TodoPageModel
  var meetingID: UUID
  var onShowTodos: () -> Void
  var onJump: (TimeInterval) -> Void
  var onRefresh: () -> Void

  func body(content: Content) -> some View {
    let showing = page.candidateSurface != .meeting && page.candidateContext?.meetingID == meetingID
    content
      .accessibilityHidden(showing)
      .allowsHitTesting(!showing)
      .overlay {
        if showing {
          MeetingCandidateLayerView(
            model: page, onShowTodos: onShowTodos,
            onJump: onJump, onRefresh: onRefresh)
        }
      }
  }
}

struct MeetingCandidateLayerView: View {
  @ObservedObject var model: TodoPageModel
  @FocusState private var focusedAssignee: UUID?
  var onShowTodos: () -> Void
  var onJump: (TimeInterval) -> Void
  var onRefresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      layerBar
      HStack(alignment: .top, spacing: 0) {
        ScrollView {
          switch model.candidateSurface {
          case .clean: cleanForm
          case .reconcile: reconcileForm
          case .receipt: receipt
          case .meeting: EmptyView()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 原会议右栏仍挂在下面，返回时它的选择与滚动位置保持不变。
        ScrollView {
          MeetingCandidateModelRail(
            model: model,
            onJump: { seconds in
              model.returnToCandidates()
              onJump(seconds)
            }, onRefresh: onRefresh
          )
          .padding(Tokens.V1.Space.md)
        }
        .frame(width: Tokens.V1.Size.meetingRailWidth)
        .frame(maxHeight: .infinity)
        .background(Tokens.V1.Color.paper2)
        .overlay(alignment: .leading) {
          Rectangle().fill(Tokens.V1.Color.rule).frame(width: Tokens.V1.Size.controlRuleWidth)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Tokens.V1.Color.paper)
  }

  private var layerBar: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Button(action: model.returnToCandidates) {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(.v1Quiet)
      .accessibilityLabel("返回会议右栏")
      .runtimeAccessibilityIdentifier("meeting.clean.back")
      Text(title)
        .font(Tokens.V1.Text.barTitle.font)
        .foregroundStyle(Tokens.V1.Color.ink)
      Spacer()
      if model.candidateSurface == .clean {
        if model.cleanLines.filter({ !$0.removed }).count > 1 {
          Text("已核对 \(model.cleanReviewedCount) / \(model.cleanLines.filter { !$0.removed }.count)")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink2)
            .runtimeAccessibilityIdentifier("meeting.clean.reviewed")
        }
        Button("取消", action: model.returnToCandidates).buttonStyle(.v1Quiet)
        Button(model.cleanSaveTitle) { model.saveClean() }
          .buttonStyle(.v1Primary)
          .disabled(!model.cleanSaveEnabled)
          .runtimeAccessibilityIdentifier(
            model.cleanSaveEnabled ? "meeting.clean.save" : "meeting.clean.save.disabled")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.md)
    .frame(height: Tokens.V1.Size.barHeight)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
  }

  private var title: String {
    switch model.candidateSurface {
    case .reconcile: "核对候选"
    case .receipt: "加入待办"
    case .clean:
      model.cleanLines.contains(where: { $0.legacyKey != nil && !$0.removed }) ? "带入待办" : "加入待办"
    case .meeting: "待办候选"
    }
  }

  private var cleanForm: some View {
    let active = model.cleanLines.filter { !$0.removed }
    let batch = active.count > 1
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      Text("待办事项确认")
        .font(Tokens.V1.Text.heading.font)
        .foregroundStyle(Tokens.V1.Color.ink)
      if let context = model.candidateContext {
        Text("按会议日期 \(context.referenceDay) 计算")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink2)
          .runtimeAccessibilityIdentifier("meeting.clean.basis")
        timeZoneControl(context)
      }
      ForEach(model.cleanLines) { line in
        if !line.removed {
          cleanLine(line, batch: batch)
        }
      }
      if let error = model.cleanError {
        Text(error)
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .runtimeAccessibilityIdentifier("meeting.clean.error")
      }

    }
    .padding(Tokens.V1.Space.lg)
    .frame(maxWidth: batch ? Tokens.V1.Size.reading : Tokens.V1.Size.settingsForm)
    .runtimeAccessibilityIdentifier(batch ? "meeting.clean.batch" : "meeting.clean.single")
    .frame(maxWidth: .infinity)
  }

  private func timeZoneControl(_ context: MeetingCandidateContext) -> some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Text(context.timeZoneIdentifier)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink2)
      Menu("改这次的计算时区") {
        ForEach(Self.zones(current: context.timeZoneIdentifier), id: \.self) { zone in
          Button(zone) { model.setCandidateTimeZone(zone) }
        }
      }
      .font(Tokens.V1.Text.meta.font)
    }
    .runtimeAccessibilityIdentifier("meeting.clean.timezone")
  }

  private static func zones(current: String) -> [String] {
    var values = ["Asia/Shanghai", "UTC", "America/Los_Angeles"]
    if !values.contains(current) { values.insert(current, at: 0) }
    return values
  }

  private func cleanLine(_ line: MeetingCandidateCleanLine, batch: Bool) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
        HStack {
          Text("来源候选").font(Tokens.V1.Text.meta.font)
          Spacer()
          if let anchor = line.anchor {
            Text(TodoClock.sourceTime(anchor))
              .font(Tokens.V1.Text.timecode.font)
          }
        }
        .foregroundStyle(Tokens.V1.Color.ink3)
        Text("「\(line.sourceText)」")
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier("meeting.clean.source.\(line.id.uuidString)")
        if line.missingContext {
          Text("原负责人、截止和位置无法恢复")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink2)
        }
      }
      .padding(Tokens.V1.Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Tokens.V1.Color.paper2, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md))
      field("事项") {
        TextField(
          "要跟进的事", text: cleanText(line.id, \.title) { $0.draft.title = $1 }, axis: .vertical
        )
        .lineLimit(2...5)
        .textFieldStyle(.plain)
        .font(Tokens.V1.Text.body.font)
        .padding(Tokens.V1.Space.sm)
        .background(fieldBackground)
        .runtimeAccessibilityIdentifier("meeting.clean.title.\(line.id.uuidString)")
      }
      HStack(alignment: .top, spacing: Tokens.V1.Space.md) {
        field("负责人") { assigneeField(line) }
        field("截止日期") { deadlineField(line) }
      }
      HStack(alignment: .top, spacing: Tokens.V1.Space.md) {
        field("优先级") {
          Menu {
            ForEach([TodoPriority.high, .normal, .low], id: \.rawValue) { value in
              Button {
                model.updateCleanLine(line.id) { $0.draft.priority = value }
              } label: {
                if value == line.draft.priority {
                  Label(TodoText.priority(value), systemImage: "checkmark")
                } else {
                  Text(TodoText.priority(value))
                }
              }
            }
          } label: {
            Text(TodoText.priorityPhrase(line.draft.priority))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden)
          .frame(maxWidth: .infinity, minHeight: Tokens.V1.Size.control)
          .modifier(TodoFieldSurface())
          .overlay(alignment: .trailing) { cleanMenuIndicator }
          .accessibilityLabel("优先级")
          .runtimeAccessibilityIdentifier("meeting.clean.priority.\(line.id.uuidString)")
        }
        VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
          field("客户 / 项目") {
            V1ComboBox(
              label: "客户", value: line.draft.client, suggestions: model.tagDirectory.clients,
              identifier: "meeting.clean.client.\(line.id.uuidString)"
            ) { value in
              model.selectCleanClient(value, lineID: line.id)
            }
            V1ComboBox(
              label: "项目", value: line.draft.project,
              suggestions: model.tagDirectory.projects(for: line.draft.client),
              identifier: "meeting.clean.project.\(line.id.uuidString)"
            ) { value in
              model.selectCleanProject(value, lineID: line.id)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      field("备注") {
        TextField("补充说明", text: cleanText(line.id, \.note) { $0.draft.note = $1 }, axis: .vertical)
          .lineLimit(3...6)
          .textFieldStyle(.plain)
          .font(Tokens.V1.Text.body.font)
          .padding(Tokens.V1.Space.sm)
          .background(fieldBackground)
          .runtimeAccessibilityIdentifier("meeting.clean.note.\(line.id.uuidString)")
      }
      if line.legacyKey != nil {
        V1SegmentedPicker(
          "完成",
          selection: Binding(
            get: { line.markCompleted },
            set: { value in model.updateCleanLine(line.id) { $0.markCompleted = value } }
          ), options: [.init(true, "已完成"), .init(false, "未完成")]
        )
        .runtimeAccessibilityIdentifier("meeting.clean.completed.\(line.id.uuidString)")
      }
      if batch {
        Button("取消加入这一条") { model.removeCleanLine(line.id) }
          .buttonStyle(.v1Quiet)
          .runtimeAccessibilityIdentifier("meeting.clean.remove.\(line.id.uuidString)")
        Divider()
      }
    }
    .runtimeAccessibilityIdentifier("meeting.clean.line.\(line.id.uuidString)")
  }

  private func assigneeField(_ line: MeetingCandidateCleanLine) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      Menu {
        ForEach(TodoEditorDraft.AssigneeKind.allCases, id: \.self) { kind in
          Button {
            model.updateCleanLine(line.id) { $0.draft.assigneeKind = kind }
            focusedAssignee = kind == .named ? line.id : nil
          } label: {
            let title =
              kind == .named && !line.draft.assigneeName.isEmpty
              ? line.draft.assigneeName : kind.title
            if kind == line.draft.assigneeKind {
              Label(title, systemImage: "checkmark")
            } else {
              Text(title)
            }
          }
        }
      } label: {
        Text(TodoText.assignee(model.assignee(from: line.draft)))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden)
      .frame(maxWidth: .infinity, minHeight: Tokens.V1.Size.control)
      .modifier(TodoFieldSurface())
      .overlay(alignment: .trailing) { cleanMenuIndicator }
      .accessibilityLabel("负责人")
      .runtimeAccessibilityIdentifier("meeting.clean.assignee.\(line.id.uuidString)")
      if line.draft.assigneeKind == .named {
        TextField("姓名", text: cleanText(line.id, \.assigneeName) { $0.draft.assigneeName = $1 })
          .textFieldStyle(.plain)
          .focused($focusedAssignee, equals: line.id)
          .font(Tokens.V1.Text.body.font)
          .padding(Tokens.V1.Space.sm)
          .background(fieldBackground)
          .runtimeAccessibilityIdentifier("meeting.clean.assignee-name.\(line.id.uuidString)")
      }
      if model.cleanNeedsAssigneeConfirmation(line) {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
          Text(
            "会议里说的负责人是\(line.ownerText ?? "待确认")，你选的是\(TodoText.assignee(model.assignee(from: line.draft)))，请确认用哪个"
          )
          .font(Tokens.V1.Text.meta.font)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(Tokens.V1.Color.warn)
          Button("用\(line.ownerText ?? "原负责人")") {
            model.confirmCleanAssignee(line.id, useOriginal: true)
          }
          .buttonStyle(.v1Outline)
          .runtimeAccessibilityIdentifier("meeting.clean.assignee-original.\(line.id.uuidString)")
          Button("用\(TodoText.assignee(model.assignee(from: line.draft)))") {
            model.confirmCleanAssignee(line.id, useOriginal: false)
          }
          .buttonStyle(.v1Outline)
          .runtimeAccessibilityIdentifier("meeting.clean.assignee-selected.\(line.id.uuidString)")
        }
        .padding(Tokens.V1.Space.sm)
        .background(
          Tokens.V1.Color.warnSoft, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
        )
        .runtimeAccessibilityIdentifier("meeting.clean.assignee-conflict.\(line.id.uuidString)")
      }
    }
  }

  private var cleanMenuIndicator: some View {
    Image(systemName: "chevron.down")
      .font(Tokens.V1.Text.meta.font)
      .foregroundStyle(Tokens.V1.Color.ink3)
      .padding(.trailing, Tokens.V1.Space.sm)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func deadlineField(_ line: MeetingCandidateCleanLine) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      if let deadline = line.deadlineText?.nilIfBlank {
        Text("原截止：\(deadline)")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink2)
      }
      if case .choose(let days, let reason) = line.resolution {
        Text(reason.detail)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink2)
        ForEach(days, id: \.day) { day in
          Button {
            model.updateCleanLine(line.id) {
              $0.chosenDay = day.day
              $0.draft.dueKind = .date
              $0.draft.dueDate = TodoClock.pickerDate(day: day.day)
              $0.draft.timeZoneIdentifier = day.timeZoneIdentifier
            }
          } label: {
            HStack(alignment: .top, spacing: Tokens.V1.Space.xs) {
              Image(systemName: line.chosenDay == day.day ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(
                  line.chosenDay == day.day ? Tokens.V1.Color.accent : Tokens.V1.Color.ink3)
              Text(MeetingCandidateCopy.choiceLabel(day: day, reason: reason, options: days))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .buttonStyle(.v1Outline)
          .runtimeAccessibilityIdentifier("meeting.clean.choice.\(line.id.uuidString).\(day.day)")
        }
      }
      TodoDeadlinePicker(
        due: Binding(
          get: { cleanDue(line) },
          set: { value in
            model.updateCleanLine(line.id) { edited in
              switch value {
              case .date(let day):
                edited.draft.dueKind = .date
                edited.draft.dueDate = TodoClock.pickerDate(day: day.day)
                edited.draft.timeZoneIdentifier = day.timeZoneIdentifier
                edited.chosenDay = day.day
              case .none:
                edited.draft.dueKind = .none
                edited.chosenDay = nil
              case .pending:
                edited.draft.dueKind = .pending
                edited.chosenDay = nil
              }
            }
          }),
        now: model.candidateContext?.startedAt ?? model.now,
        timeZoneIdentifier: line.draft.timeZoneIdentifier,
        identifier: "meeting.clean.due.\(line.id.uuidString)"
      )
      if case .day(let day) = line.resolution,
        TodoDueInterpreter.isBeforeReference(
          day, reference: model.candidateContext?.startedAt ?? model.now,
          timeZone: TimeZone(identifier: day.timeZoneIdentifier) ?? .current)
      {
        Text("这个日期已经过去")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink)
      }
    }
  }

  private func cleanDue(_ line: MeetingCandidateCleanLine) -> TodoDue {
    switch line.draft.dueKind {
    case .none: return .none
    case .pending: return .pending
    case .date:
      if case .choose = line.resolution, line.chosenDay == nil { return .pending }
      return .date(
        TodoDay(
          day: line.chosenDay ?? TodoClock.dayString(from: line.draft.dueDate),
          timeZoneIdentifier: line.draft.timeZoneIdentifier))
    }
  }

  private var reconcileForm: some View {
    let comparison = model.reconcileComparison()
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
      Text("待核对")
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink2)
      if let comparison {
        Text(comparison.meetingTitle)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
        ForEach(comparison.cards) { card in
          HStack(alignment: .top, spacing: Tokens.V1.Space.md) {
            compareColumn(
              "旧说法", rows: MeetingCandidateCopy.fieldRows(card.old), current: comparison.current,
              side: .old)
            compareColumn(
              "新说法", rows: MeetingCandidateCopy.fieldRows(comparison.current), current: card.old,
              side: .new)
          }
          if card.todos.isEmpty {
            Text("没有可关联的待办")
              .font(Tokens.V1.Text.meta.font)
              .foregroundStyle(Tokens.V1.Color.ink2)
          }
          ForEach(card.todos) { todo in
            VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
              Text("已有待办")
                .font(Tokens.V1.Text.body.font)
                .fontWeight(Tokens.V1.Text.strong.weight)
              Text(todo.title)
                .font(Tokens.V1.Text.body.font)
              Text(currentMeta(todo))
                .font(Tokens.V1.Text.meta.font)
                .foregroundStyle(Tokens.V1.Color.ink2)
                .runtimeAccessibilityIdentifier("meeting.reconcile.current.\(todo.id.uuidString)")
              choice(
                "关联已有", detail: "追加本次来源，保留已有待办的字段。",
                identifier: "meeting.reconcile.link.\(todo.id.uuidString)"
              ) {
                model.linkExisting(candidateID: comparison.candidateID, todoID: todo.id)
              }
            }
          }
        }
        choice("另建一条", detail: "打开清洗表单，确认后才新增。", identifier: "meeting.reconcile.create") {
          model.beginSeparateClean(comparison.candidateID)
        }
        choice("忽略这个候选", detail: "保留这次忽略决定，可在已忽略中恢复。", identifier: "meeting.reconcile.ignore") {
          model.ignoreCandidate(comparison.candidateID)
        }
      }
      if let error = model.cleanError {
        Text(error)
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .runtimeAccessibilityIdentifier("meeting.clean.error")
      }
      Button("暂不处理", action: model.deferReconcile)
        .buttonStyle(.v1Quiet)
        .runtimeAccessibilityIdentifier("meeting.reconcile.defer")
    }
    .padding(Tokens.V1.Space.lg)
    .frame(maxWidth: Tokens.V1.Size.reading, alignment: .leading)
    .runtimeAccessibilityIdentifier("meeting.reconcile")
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private enum CompareSide { case old, new }

  private func compareColumn(
    _ heading: String,
    rows: [(key: String, label: String, value: String)],
    current: CandidateVariant,
    side: CompareSide
  ) -> some View {
    let other = Dictionary(
      uniqueKeysWithValues: MeetingCandidateCopy.fieldRows(current).map { ($0.key, $0.value) })
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      Text(heading)
        .font(Tokens.V1.Text.body.font)
        .fontWeight(Tokens.V1.Text.strong.weight)
      ForEach(rows, id: \.key) { row in
        let changed = other[row.key] != row.value
        VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
          Text(changed ? "\(row.label) · 已变化" : row.label)
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
          Text(row.value)
            .font(Tokens.V1.Text.body.font)
            .fontWeight(changed ? Tokens.V1.Text.strong.weight : Tokens.V1.Text.body.weight)
            .foregroundStyle(Tokens.V1.Color.ink)
            .runtimeAccessibilityIdentifier(
              "meeting.reconcile.\(side == .old ? "old" : "new").\(row.key)\(changed ? ".changed" : "")"
            )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func choice(
    _ title: String, detail: String, identifier: String, action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        Text(title).font(Tokens.V1.Text.body.font)
        Text(detail).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink2)
      }
      Spacer(minLength: Tokens.V1.Space.md)
      Button(title, action: action)
        .buttonStyle(.v1Outline)
        .runtimeAccessibilityIdentifier(identifier)
    }
  }

  private func currentMeta(_ todo: TodoItem) -> String {
    let status = todo.status == .done ? "已完成" : "未完成"
    return
      "\(TodoText.assignee(todo.assignee)) · \(TodoText.duePhrase(todo.due, now: model.now, item: todo)) · \(TodoText.priorityPhrase(todo.priority)) · \(status)"
  }

  private var receipt: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      Text(model.candidateReceipt?.message ?? "已加入")
        .font(Tokens.V1.Text.heading.font)
        .foregroundStyle(Tokens.V1.Color.ink)
      if let error = model.cleanError {
        Text(error)
          .font(Tokens.V1.Text.body.font)
          .runtimeAccessibilityIdentifier("meeting.clean.error")
      }
      HStack(spacing: Tokens.V1.Space.sm) {
        Button("查看待办", action: onShowTodos)
          .buttonStyle(.v1Primary)
          .runtimeAccessibilityIdentifier("meeting.clean.view-todos")
        if model.candidateReceipt?.canUndo == true {
          Button("撤销") { model.undoCandidateReceipt() }
            .buttonStyle(.v1Outline)
            .runtimeAccessibilityIdentifier("meeting.clean.undo")
        }
      }
    }
    .padding(Tokens.V1.Space.lg)
    .frame(maxWidth: Tokens.V1.Size.settingsForm, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .runtimeAccessibilityIdentifier("meeting.clean.receipt")
  }

  private var fieldBackground: some View {
    RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
      .fill(Tokens.V1.Color.raised)
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
          .strokeBorder(Tokens.V1.Color.controlRule, lineWidth: Tokens.V1.Size.controlRuleWidth)
      )
  }

  private func field<Control: View>(_ label: String, @ViewBuilder control: () -> Control)
    -> some View
  {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      Text(label)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink2)
      control().frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func cleanText(
    _ id: UUID,
    _ keyPath: WritableKeyPath<TodoEditorDraft, String>,
    assign: @escaping (inout MeetingCandidateCleanLine, String) -> Void
  ) -> Binding<String> {
    Binding(
      get: { model.cleanLines.first { $0.id == id }?.draft[keyPath: keyPath] ?? "" },
      set: { value in model.updateCleanLine(id) { assign(&$0, value) } }
    )
  }
}
