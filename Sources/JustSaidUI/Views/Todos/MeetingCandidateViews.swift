import JustSaidCore
import SwiftUI

struct MeetingCandidateRailList: View {
  var board: MeetingCandidateBoard
  var onJump: (TimeInterval) -> Void
  var onRefresh: () -> Void
  var onToggle: (UUID) -> Void
  var onPrimary: (UUID) -> Void
  var onEdit: (UUID) -> Void
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
        if line.primaryTitle != "核对" {
          Button("忽略") { onIgnore(line.id) }
            .buttonStyle(.v1Quiet)
            .runtimeAccessibilityIdentifier("meeting.candidates.ignore.\(line.id.uuidString)")
        }
        // 信息齐全的候选一键加入；想改再点「编辑」。缺东西的直接进表单补。
        if line.quickAdd {
          Button("编辑") { onEdit(line.id) }
            .buttonStyle(.v1Quiet)
            .runtimeAccessibilityIdentifier("meeting.candidates.edit.\(line.id.uuidString)")
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
        let line = model.candidateBoard.pending.first(where: { $0.id == id })
        if line?.primaryTitle == "核对" {
          model.beginReconcile(id)
        } else if line?.quickAdd == true {
          model.quickAddCandidate(id)
        } else {
          model.beginCandidateClean([id])
        }
      },
      onEdit: { model.beginCandidateClean([$0]) },
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
      onEdit: { _ in },
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

/// 会议右栏的两种样子：平时是候选列表，点开编辑或核对时同一栏原位换成表单（#146）。
/// 左边的纪要与转写不被盖住，可以边看边填。
struct MeetingCandidateRailSwitch<Normal: View>: View {
  @ObservedObject var page: TodoPageModel
  var meetingID: UUID
  var onJump: (TimeInterval) -> Void
  @ViewBuilder var normal: () -> Normal

  var body: some View {
    if page.candidateSurface != .meeting, page.candidateContext?.meetingID == meetingID {
      MeetingCandidateEditorRail(model: page, onJump: onJump)
    } else {
      normal()
    }
  }
}

extension View {
  /// 加入后的就地回执，浮在阅读列右下角、贴着右栏左沿，不换页。
  @ViewBuilder
  func meetingCandidateReceipt(
    page: TodoPageModel?, meetingID: UUID, trailingInset: CGFloat,
    onShowTodos: @escaping () -> Void
  ) -> some View {
    if let page {
      overlay(alignment: .bottomTrailing) {
        MeetingCandidateReceiptToast(
          page: page, meetingID: meetingID, onShowTodos: onShowTodos
        )
        .padding(.trailing, trailingInset)
      }
    } else {
      self
    }
  }
}

private struct MeetingCandidateReceiptToast: View {
  @ObservedObject var page: TodoPageModel
  var meetingID: UUID
  var onShowTodos: () -> Void

  var body: some View {
    if page.candidateSurface == .meeting, page.candidateContext?.meetingID == meetingID,
      let receipt = page.candidateReceipt
    {
      HStack(spacing: Tokens.V1.Space.sm) {
        Text(receipt.message)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .lineLimit(1)
        if receipt.canUndo {
          Button("撤销") { page.undoCandidateReceipt() }
            .buttonStyle(.v1Quiet)
            .runtimeAccessibilityIdentifier("meeting.candidates.receipt.undo")
        }
        Button("查看待办", action: onShowTodos)
          .buttonStyle(.v1Quiet)
          .runtimeAccessibilityIdentifier("meeting.candidates.receipt.view-todos")
      }
      .padding(.horizontal, Tokens.V1.Space.sm)
      .padding(.vertical, Tokens.V1.Space.s2xs)
      .background(Tokens.V1.Color.raised, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.md).strokeBorder(
          Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
      )
      .padding(Tokens.V1.Space.md)
      .runtimeAccessibilityIdentifier("meeting.candidates.receipt")
    }
  }
}

struct MeetingCandidateEditorRail: View {
  @ObservedObject var model: TodoPageModel
  var onJump: (TimeInterval) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      ScrollView {
        switch model.candidateSurface {
        case .clean: cleanForm
        case .reconcile: reconcileForm
        case .meeting: EmptyView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      if model.candidateSurface == .clean { footer }
    }
    .frame(width: Tokens.V1.Size.meetingEditorWidth)
    .frame(maxHeight: .infinity)
    .background(Tokens.V1.Color.paper2)
    .overlay(alignment: .leading) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(width: Tokens.V1.Size.controlRuleWidth)
    }
    // 表单里 Esc 回到候选列表（取消按钮的快捷键之外再兜一层，焦点在非按钮控件上也生效）。
    .onExitCommand { model.returnToCandidates() }
    .runtimeAccessibilityIdentifier("meeting.candidate-editor")
  }

  private var header: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Button(action: model.returnToCandidates) {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(.v1Quiet)
      .help("返回待办候选 Esc")
      .accessibilityLabel("返回待办候选")
      .runtimeAccessibilityIdentifier("meeting.clean.back")
      Text(title)
        .font(Tokens.V1.Text.barTitle.font)
        .foregroundStyle(Tokens.V1.Color.ink)
      Spacer()
      if model.candidateSurface == .clean,
        model.cleanLines.filter({ !$0.removed }).count > 1
      {
        Text("已核对 \(model.cleanReviewedCount) / \(model.cleanLines.filter { !$0.removed }.count)")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink2)
          .runtimeAccessibilityIdentifier("meeting.clean.reviewed")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.md)
    .frame(height: Tokens.V1.Size.barHeight)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
  }

  /// 确认钉在栏底，填完表单视线和鼠标都不用回到顶上。⌘↩ 提交，Esc 取消。
  private var footer: some View {
    TodoComposeFooter(
      error: model.cleanError, errorIdentifier: "meeting.clean.error",
      saveTitle: model.cleanSaveTitle, saveEnabled: model.cleanSaveEnabled,
      cancelIdentifier: "meeting.clean.cancel", saveIdentifier: "meeting.clean.save",
      disabledSaveIdentifier: "meeting.clean.save.disabled",
      onCancel: model.returnToCandidates, onSave: { model.saveClean() })
  }

  private var title: String {
    switch model.candidateSurface {
    case .reconcile: "核对候选"
    case .clean:
      model.cleanLines.contains(where: { $0.legacyKey != nil && !$0.removed }) ? "带入待办" : "加入待办"
    case .meeting: "待办候选"
    }
  }

  private var cleanForm: some View {
    let active = model.cleanLines.filter { !$0.removed }
    let batch = active.count > 1
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
      ForEach(Array(active.enumerated()), id: \.element.id) { index, line in
        cleanLine(line, batch: batch, focusTitle: index == 0)
      }
    }
    .padding(Tokens.V1.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .runtimeAccessibilityIdentifier(batch ? "meeting.clean.batch" : "meeting.clean.single")
  }

  private var basis: TodoDeadlineBasis? {
    guard let context = model.candidateContext else { return nil }
    return TodoDeadlineBasis(
      referenceDay: context.referenceDay, timeZoneIdentifier: context.timeZoneIdentifier,
      timeZones: Self.zones(current: context.timeZoneIdentifier),
      onSelectTimeZone: { model.setCandidateTimeZone($0) })
  }

  private static func zones(current: String) -> [String] {
    var values = ["Asia/Shanghai", "UTC", "America/Los_Angeles"]
    if !values.contains(current) { values.insert(current, at: 0) }
    return values
  }

  private func cleanLine(_ line: MeetingCandidateCleanLine, batch: Bool, focusTitle: Bool)
    -> some View
  {
    TodoComposeForm(
      draft: Binding(
        get: { model.cleanLines.first { $0.id == line.id }?.draft ?? line.draft },
        // 失焦时输入框会把没变的值再写一遍；只在真有改动时更新，免得把保存失败的原因清掉。
        set: { value in
          guard model.cleanLines.first(where: { $0.id == line.id })?.draft != value else { return }
          model.updateCleanLine(line.id) { $0.draft = value }
        }),
      due: cleanDue(line.id),
      source: TodoComposeSource(
        text: line.sourceText, anchor: line.anchor, missingContext: line.missingContext,
        identifier: "meeting.clean.source.\(line.id.uuidString)"),
      onJump: onJump,
      identifiers: .meeting(line.id),
      assigneeSuggestions: model.assigneeSuggestions(including: line.ownerText),
      clients: model.tagDirectory.clients,
      projects: model.tagDirectory.projects(for: line.draft.client),
      onSelectClient: { model.selectCleanClient($0, lineID: line.id) },
      onSelectProject: { model.selectCleanProject($0, lineID: line.id) },
      now: model.candidateContext?.startedAt ?? model.now,
      dueHint: dueHint(line),
      dueBasis: basis,
      focusTitle: focusTitle,
      spokenAssignee: line.ownerText?.nilIfBlank,
      // 在负责人框里亲手选了或新建了名字，就算确认过，不再追问和会议原话的冲突。
      onAssigneeChosen: { model.confirmCleanAssignee(line.id, useOriginal: false) },
      sourceAccessory: {
        if batch {
          Button("取消加入这一条") { model.removeCleanLine(line.id) }
            .buttonStyle(.v1Quiet.height(Tokens.V1.Size.controlSm))
            // 安静按钮自带横内距；往外让出这一截，字的右沿和下面时间码的右沿对齐。
            .padding(.trailing, -Tokens.V1.Space.sm)
            .runtimeAccessibilityIdentifier("meeting.clean.remove.\(line.id.uuidString)")
        }
      },
      followup: { followup(line) },
      trailing: {
        if line.legacyKey != nil {
          TodoComposeField("完成") {
            V1SegmentedPicker(
              "完成",
              selection: Binding(
                get: { line.markCompleted },
                set: { value in model.updateCleanLine(line.id) { $0.markCompleted = value } }
              ), options: [.init(true, "已完成"), .init(false, "未完成")]
            )
            .runtimeAccessibilityIdentifier("meeting.clean.completed.\(line.id.uuidString)")
          }
        }
      }
    )
    .runtimeAccessibilityIdentifier("meeting.clean.line.\(line.id.uuidString)")
  }

  /// 要你确认负责人、要你选日期时，用「表单里的待确认行」整行放在负责人｜截止下面，答了就消失。
  @ViewBuilder
  private func followup(_ line: MeetingCandidateCleanLine) -> some View {
    if model.cleanNeedsAssigneeConfirmation(line) {
      let spoken = line.ownerText ?? "待确认"
      let selected = TodoText.assignee(model.assignee(from: line.draft))
      TodoComposeNotice(
        level: .warn, text: "会议里说负责人是\(spoken)",
        identifier: "meeting.clean.assignee-conflict.\(line.id.uuidString)"
      ) {
        Button("改用\(spoken)") { model.confirmCleanAssignee(line.id, useOriginal: true) }
          .buttonStyle(.v1Outline.height(Tokens.V1.Size.controlSm))
          .runtimeAccessibilityIdentifier("meeting.clean.assignee-original.\(line.id.uuidString)")
        Button("就用\(selected)") { model.confirmCleanAssignee(line.id, useOriginal: false) }
          .buttonStyle(.v1Quiet.height(Tokens.V1.Size.controlSm))
          .runtimeAccessibilityIdentifier("meeting.clean.assignee-selected.\(line.id.uuidString)")
      }
    }
    if case .choose(let days, let reason) = line.resolution, line.chosenDay == nil {
      TodoComposeNotice(
        level: .neutral,
        text: MeetingCandidateCopy.choicePrompt(line.deadlineText, reason: reason),
        stacked: true,
        identifier: "meeting.clean.choices.\(line.id.uuidString)"
      ) {
        ForEach(days, id: \.day) { day in
          Button {
            model.updateCleanLine(line.id) {
              $0.chosenDay = day.day
              $0.draft.dueKind = .date
              $0.draft.dueDate = TodoClock.pickerDate(day: day.day)
              $0.draft.timeZoneIdentifier = day.timeZoneIdentifier
            }
          } label: {
            // 日期就是这两颗按钮的意义：等分撑满整行，标签不省略。
            Text(MeetingCandidateCopy.choiceLabel(day: day, reason: reason, options: days))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.v1Outline.height(Tokens.V1.Size.controlSm))
          .runtimeAccessibilityIdentifier("meeting.clean.choice.\(line.id.uuidString).\(day.day)")
        }
      }
    }
  }

  /// 截止框下一行：会议原话，日期早于会议当天时接一句「这个日期已经过去」。
  private func dueHint(_ line: MeetingCandidateCleanLine) -> String? {
    var parts: [String] = []
    // 原话和算好的日期写法一样（「9月24日」）时不重复一遍。
    if let spoken = MeetingCandidateCopy.spokenDeadline(line.deadlineText),
      cleanDue(line.id).wrappedValue.monthDayLabel != line.deadlineText?.nilIfBlank
    {
      parts.append(spoken)
    }
    if case .day(let day) = line.resolution,
      TodoDueInterpreter.isBeforeReference(
        day, reference: model.candidateContext?.startedAt ?? model.now,
        timeZone: TimeZone(identifier: day.timeZoneIdentifier) ?? .current)
    {
      parts.append("这个日期已经过去")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func cleanDue(_ id: UUID) -> Binding<TodoDue> {
    Binding(
      get: {
        guard let line = model.cleanLines.first(where: { $0.id == id }) else { return .pending }
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
      },
      set: { value in
        model.updateCleanLine(id) { edited in
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
      })
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
    .padding(Tokens.V1.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .runtimeAccessibilityIdentifier("meeting.reconcile")
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

}
