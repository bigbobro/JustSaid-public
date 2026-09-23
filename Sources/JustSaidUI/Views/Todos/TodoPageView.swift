import JustSaidCore
import SwiftUI

public struct TodoPageView: View {
  @ObservedObject var model: TodoPageModel
  var meetingStore: MeetingStore
  var deletedMeetings: TodoDeletedMeetingLedger
  var onOpenLibrary: () -> Void
  var onOpenSource: (URL, TimeInterval?) -> Void

  public init(
    model: TodoPageModel, meetingStore: MeetingStore, deletedMeetings: TodoDeletedMeetingLedger,
    onOpenLibrary: @escaping () -> Void = {},
    onOpenSource: @escaping (URL, TimeInterval?) -> Void = { _, _ in }
  ) {
    self.model = model
    self.meetingStore = meetingStore
    self.deletedMeetings = deletedMeetings
    self.onOpenLibrary = onOpenLibrary
    self.onOpenSource = onOpenSource
  }

  public var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        bar
        if model.failure != nil { failureBanner }
        ZStack(alignment: .bottomTrailing) {
          if model.phase == .ready {
            workspace(width: geometry.size.width)
          } else {
            browse
          }
          if let undo = model.undo, model.phase == .ready {
            receipt(undo.message, undoable: true)
          } else if let message = model.transientMessage {
            receipt(message, undoable: false)
          }
          panels
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .background(Tokens.V1.Color.paper)
    .background(alignment: .topLeading) { marker("todos.live.scope.\(model.scope.rawValue)") }
    .background(alignment: .topTrailing) { marker("todos.live.layout.\(model.layout.rawValue)") }
    .background(alignment: .bottomLeading) {
      marker("todos.live.selected.\(model.selectedID?.uuidString ?? "none")")
    }
    .onAppear {
      model.reloadSynchronously()
      refreshMeetingIndex()
    }
    .onDisappear { model.pageDidDisappear() }
    .onChange(of: model.visibleItems.map(\.id)) { _, _ in model.dismissHiddenPopover() }
    .onExitCommand {
      if model.popoverID != nil {
        model.closePopover()
      } else if model.isSearching {
        model.clearSearch()
      } else {
        model.closeLayer()
      }
    }
    .runtimeAccessibilityIdentifier("todos.page")
  }

  private func marker(_ identifier: String) -> some View {
    Color.clear.frame(
      width: Tokens.V1.Size.controlRuleWidth, height: Tokens.V1.Size.controlRuleWidth
    )
    .accessibilityHidden(true).runtimeAccessibilityIdentifier(identifier)
  }

  private var bar: some View {
    WorkspaceTopBar("我的待办") {
      HStack(spacing: Tokens.V1.Space.sm) {
        searchField
        Button {
          model.beginCreate()
        } label: {
          Label("新增待办", systemImage: "plus")
        }
        .buttonStyle(.v1Primary).disabled(!model.canMutate)
        .runtimeAccessibilityIdentifier(model.canMutate ? "todos.add" : "todos.add.disabled")
      }
    }
    .runtimeAccessibilityIdentifier("todos.top-bar")
  }

  private var searchField: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Image(systemName: "magnifyingglass").foregroundStyle(Tokens.V1.Color.ink3)
      TextField("搜索待办", text: $model.searchText)
        .textFieldStyle(.plain).font(Tokens.V1.Text.body.font)
        .runtimeAccessibilityIdentifier("todos.search.field")
      if !model.searchText.isEmpty {
        Button {
          model.clearSearch()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
        .help("清除搜索").accessibilityLabel("清除搜索")
        .runtimeAccessibilityIdentifier("todos.search.clear")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.xs)
    .frame(width: Tokens.V1.Size.panelWidth, height: Tokens.V1.Size.control)
    .modifier(TodoFieldSurface())
    .runtimeAccessibilityIdentifier("todos.search")
  }

  private var hasInspector: Bool {
    model.inspectorVisible && (model.editor != nil || model.selectedID.flatMap(model.item) != nil)
  }

  private func workspace(width: CGFloat) -> some View {
    let docked = model.inspectorIsDocked(contentWidth: width)
    let sidebarVisible = model.sidebarIsVisible(contentWidth: width)
    return HStack(spacing: 0) {
      if sidebarVisible { TodoSidebarView(model: model) }
      ZStack(alignment: .trailing) {
        HStack(spacing: 0) {
          VStack(spacing: 0) {
            middleHeader(sidebarVisible: sidebarVisible, width: width)
            if let actionError = model.actionError {
              NoticeShell(level: .warn, systemImage: "exclamationmark.triangle", text: actionError)
              {
                Button("关闭") { model.actionError = nil }.buttonStyle(.v1Quiet)
              }
              .padding(Tokens.V1.Space.sm)
              .runtimeAccessibilityIdentifier("todos.action-error")
            }
            browse
              .padding(
                .trailing,
                model.popoverID == nil ? 0 : Tokens.V1.Size.todoPopoverWidth + Tokens.V1.Space.lg)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          if hasInspector && docked {
            inspector.runtimeAccessibilityIdentifier("todos.inspector.docked")
          }
        }
        if hasInspector && !docked {
          inspector.runtimeAccessibilityIdentifier("todos.inspector.overlay")
        }
      }
    }
  }

  private func middleHeader(sidebarVisible: Bool, width: CGFloat) -> some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      if !sidebarVisible {
        Button {
          model.toggleSidebar(contentWidth: width)
        } label: {
          Image(systemName: "sidebar.left")
        }
        .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
        .help("展开侧栏").accessibilityLabel("展开侧栏")
        .runtimeAccessibilityIdentifier("todos.sidebar.toggle")
      }
      Text(model.summaryText).font(Tokens.V1.Text.heading.font).foregroundStyle(Tokens.V1.Color.ink)
        .lineLimit(1).runtimeAccessibilityIdentifier("todos.heading")
      if !model.isSearching {
        Text("\(model.visibleItems.count)")
          .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
          .runtimeAccessibilityIdentifier("todos.count")
      }
      Spacer(minLength: Tokens.V1.Space.xs)
      if model.isShowingRecycleBin {
        Button("清空回收箱…") { model.requestEmptyRecycleBin() }
          .buttonStyle(.v1DestructiveText).disabled(model.removedItems.isEmpty)
          .runtimeAccessibilityIdentifier("todos.trash.empty")
      } else {
        layoutPicker
      }
    }
    .padding(.horizontal, Tokens.V1.Space.md)
    .frame(height: Tokens.V1.Size.barHeight)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .runtimeAccessibilityIdentifier("todos.middle-header")
  }

  private var layoutPicker: some View {
    HStack(spacing: 0) {
      ForEach(TodoLayout.allCases) { layout in
        Button {
          model.chooseLayout(layout)
        } label: {
          Image(systemName: layout == .list ? "line.3.horizontal" : "square.grid.2x2")
            .foregroundStyle(
              model.displayedLayout == layout ? Tokens.V1.Color.accent : Tokens.V1.Color.ink3
            )
            .frame(width: Tokens.V1.Size.control, height: Tokens.V1.Size.controlSm)
            .background(
              model.displayedLayout == layout ? Tokens.V1.Color.raised : .clear,
              in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs))
        }
        .buttonStyle(V1ButtonStyle.v1Icon.height(Tokens.V1.Size.controlSm))
        .disabled(layout == .matrix && (model.scope == .done || model.isSearching))
        .help(
          layout == .matrix && model.scope == .done
            ? TodoText.matrixDisabledReason
            : (model.isSearching ? "搜索结果按未完成、已完成分组" : layout.title)
        )
        .accessibilityLabel(layout.title)
        .runtimeAccessibilityIdentifier("todos.layout.\(layout.rawValue)")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.s3xs)
    .background(Tokens.V1.Color.paper2, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
  }

  private var inspector: some View {
    VStack(spacing: 0) {
      if model.editor != nil {
        TodoEditorView(
          model: model, onOpenSource: onOpenSource,
          usesInspectorPin: model.displayedLayout == .matrix)
      } else if let id = model.selectedID {
        TodoDetailView(model: model, itemID: id, onOpenSource: onOpenSource)
      }
    }
    .frame(width: Tokens.V1.Size.todoDetailWidth)
    .frame(maxHeight: .infinity)
    .background(Tokens.V1.Color.raised)
    .overlay(alignment: .leading) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(width: Tokens.V1.Size.controlRuleWidth)
    }
    .runtimeAccessibilityIdentifier("todos.inspector")
  }

  @ViewBuilder private var browse: some View {
    switch model.phase {
    case .loading:
      centered(TodoText.loading, detail: nil, action: nil, identifier: "todos.state.loading")
    case .failed(let error): failureContent(error)
    case .ready:
      if model.isShowingRecycleBin {
        removedList
      } else if let kind = model.emptyKind {
        empty(kind)
      } else if model.displayedLayout == .matrix {
        TodoMatrixView(model: model, onOpenSource: onOpenSource)
      } else {
        TodoListView(model: model, onOpenSource: onOpenSource)
      }
    }
  }

  @ViewBuilder private func empty(_ kind: TodoEmptyKind) -> some View {
    switch kind {
    case .noneYet:
      centered(
        TodoText.emptyTitle, detail: TodoText.emptyDetail,
        action: (TodoText.emptyAction, onOpenLibrary), identifier: "todos.state.none")
    case .noOpen:
      centered(
        TodoText.noOpenTitle, detail: TodoText.noOpenDetail,
        action: (TodoText.noOpenAction, { model.showCompleted() }),
        identifier: "todos.state.no-open")
    case .noMatch:
      centered(
        TodoText.noMatchTitle, detail: TodoText.noMatchDetail,
        action: (
          model.isSearching ? "清除搜索" : "查看全部客户",
          {
            if model.isSearching { model.clearSearch() } else { model.chooseClient(nil) }
          }
        ), identifier: "todos.state.no-match")
    case .noItemsInScope:
      centered(
        model.scope == .today ? "今天没有要做的事" : "这里还没有待办",
        detail: model.scope == .today ? "逾期和钉住的事也会出现在这里" : nil,
        action: ("查看全部未完成", { model.chooseScope(.open) }), identifier: "todos.state.scope-empty")
    }
  }

  private func centered(
    _ title: String, detail: String?, action: (String, () -> Void)?, identifier: String
  ) -> some View {
    VStack(spacing: Tokens.V1.Space.sm) {
      Image(systemName: "checkmark.circle").font(.system(size: Tokens.V1.Size.railIcon))
        .foregroundStyle(Tokens.V1.Color.ink3)
      Text(title).font(Tokens.V1.Text.heading.font).foregroundStyle(Tokens.V1.Color.ink)
      if let detail {
        Text(detail).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
      }
      if let action {
        Button(action.0, action: action.1).buttonStyle(.v1Outline)
          .runtimeAccessibilityIdentifier("\(identifier).action")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .runtimeAccessibilityIdentifier(identifier)
  }

  private var failureBanner: some View {
    NoticeShell(
      level: .warn, systemImage: "exclamationmark.triangle", text: TodoText.readFailureBanner
    ) {
      Button("重试") {
        model.usesDisk = true
        model.reloadSynchronously()
        refreshMeetingIndex()
      }
      .buttonStyle(.v1Outline).runtimeAccessibilityIdentifier("todos.failure.retry")
    }
    .padding(Tokens.V1.Space.sm).runtimeAccessibilityIdentifier("todos.failure.banner")
  }

  private func failureContent(_ error: TodoStoreError) -> some View {
    VStack(spacing: Tokens.V1.Space.sm) {
      Text(TodoText.readFailureTitle).font(Tokens.V1.Text.heading.font)
      Text(TodoText.readFailureDetail).font(Tokens.V1.Text.meta.font).foregroundStyle(
        Tokens.V1.Color.ink3)
      TextField("待办文件", text: .constant(model.store.fileURL.path))
        .textFieldStyle(.plain).font(Tokens.V1.Text.meta.font).disabled(true)
        .runtimeAccessibilityIdentifier("todos.failure.path")
    }
    .padding(Tokens.V1.Space.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .runtimeAccessibilityIdentifier("todos.state.failed")
  }

  private func receipt(_ text: String, undoable: Bool) -> some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Text(text).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink).lineLimit(1)
      if undoable {
        Button("撤销") { model.performUndo() }.buttonStyle(.v1Quiet)
          .runtimeAccessibilityIdentifier("todos.undo.action")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.sm).padding(.vertical, Tokens.V1.Space.s2xs)
    .background(Tokens.V1.Color.raised, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md))
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.V1.Radius.md).strokeBorder(
        Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
    )
    .padding(Tokens.V1.Space.md)
    .runtimeAccessibilityIdentifier(undoable ? "todos.undo" : "todos.receipt")
  }

  private var removedList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
        Text("只保留已移除的事项，清空后无法撤销。会议原文和候选记录会保留。")
          .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
        if model.removedItems.isEmpty {
          Text("回收箱是空的").font(Tokens.V1.Text.body.font).foregroundStyle(Tokens.V1.Color.ink3)
        }
        ForEach(model.removedItems) { item in
          HStack(alignment: .top, spacing: Tokens.V1.Space.sm) {
            Button {
              model.showDetail(item.id)
            } label: {
              VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
                Text(item.title).font(Tokens.V1.Text.body.font).foregroundStyle(Tokens.V1.Color.ink)
                Text(
                  "\(TodoText.assignee(item.assignee)) · \(TodoText.priorityPhrase(item.priority))"
                )
                .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button("恢复") { model.restore(item.id) }.buttonStyle(.v1Outline)
              .runtimeAccessibilityIdentifier("todos.restore.\(item.id.uuidString)")
          }
          .padding(Tokens.V1.Space.sm)
          .background(
            model.selectedID == item.id ? Tokens.V1.Color.paper2 : .clear,
            in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm))
        }
      }.padding(Tokens.V1.Space.lg)
    }.runtimeAccessibilityIdentifier("todos.removed.list")
  }

  @ViewBuilder private var panels: some View {
    if model.sourceChoice != nil { sourceChoicePanel }
    if let confirmation = model.trashConfirmation {
      panel("永久删除回收箱中的 \(confirmation.count) 条待办？", identifier: "todos.trash.confirm") {
        Text("只删除回收箱里的待办，无法撤销。会议原文和候选记录会保留。")
          .font(Tokens.V1.Text.body.font).foregroundStyle(Tokens.V1.Color.ink3)
        if let error = confirmation.error {
          Text(error).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.warn)
            .runtimeAccessibilityIdentifier("todos.trash.confirm.error")
        }
        HStack {
          Button("取消") { model.trashConfirmation = nil }.buttonStyle(.v1Outline)
            .runtimeAccessibilityIdentifier("todos.trash.confirm.cancel")
          Spacer()
          Button("永久删除 \(confirmation.count) 条") { _ = model.emptyRecycleBin() }
            .buttonStyle(.v1DestructiveText).runtimeAccessibilityIdentifier(
              "todos.trash.confirm.delete")
        }
      }
    }
  }

  private var sourceChoicePanel: some View {
    panel("同一场会议出现在多个目录，选择要打开的那一个", identifier: "todos.source.choose") {
      if let choice = model.sourceChoice {
        ForEach(choice.directories, id: \.path) { url in
          Button(url.lastPathComponent) {
            model.chooseSourceDirectory(url, navigate: onOpenSource)
          }
          .buttonStyle(.v1Outline)
          .runtimeAccessibilityIdentifier("todos.source.choose.\(url.lastPathComponent)")
        }
        Button("取消") { model.sourceChoice = nil }
          .buttonStyle(.v1Quiet)
      }
    }
  }

  private func panel<Content: View>(
    _ title: String, identifier: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack {
      Spacer()
      VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
        Text(title)
          .font(Tokens.V1.Text.heading.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
        content()
      }
      .padding(Tokens.V1.Space.lg)
      .frame(maxWidth: Tokens.V1.Size.overlayWidth)
      .background(Tokens.V1.Color.raised, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
          .strokeBorder(Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
      )
      .padding(Tokens.V1.Space.lg)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Tokens.V1.Color.scrim)
    .runtimeAccessibilityIdentifier(identifier)
  }

  private func refreshMeetingIndex() {
    let directories = meetingStore.listMeetings().map(\.paths.directory)
    model.replaceMeetingIndex(directories: directories, deletedMeetingIDs: deletedMeetings.load())
  }
}

/// 待办页，或从待办打开的来源会议。轨仍由外层停在「待办」。
public struct TodoDestinationView: View {
  @ObservedObject var coordinator: AppCoordinator
  var recordingSession: RecordingSession?
  var dictionaryStore: DictionaryStore

  public init(
    coordinator: AppCoordinator,
    recordingSession: RecordingSession? = nil,
    dictionaryStore: DictionaryStore = DictionaryStore()
  ) {
    self.coordinator = coordinator
    self.recordingSession = recordingSession
    self.dictionaryStore = dictionaryStore
  }

  public var body: some View {
    if let session = coordinator.todoSourceSession {
      MeetingLibraryView(
        meetingStore: coordinator.meetingStore,
        focus: session.directory,
        recordingSession: recordingSession,
        postMeetingPipelineResolver: coordinator.postMeetingPipelineResolver,
        postMeetingTasks: coordinator.postMeetingTasks,
        dictionaryStore: dictionaryStore,
        transcriptJumpSeconds: session.seconds,
        returnsToTodos: true,
        onReturnToTodos: { coordinator.closeTodoSource() },
        deletedMeetingLedger: coordinator.deletedMeetings,
        todoPage: coordinator.todoPage,
        onShowTodos: { coordinator.showTodos() }
      )
      .id(session.directory.path)
    } else {
      TodoPageView(
        model: coordinator.todoPage,
        meetingStore: coordinator.meetingStore,
        deletedMeetings: coordinator.deletedMeetings,
        onOpenLibrary: { coordinator.openLibrary() },
        onOpenSource: { directory, seconds in
          coordinator.openTodoSource(directory: directory, seconds: seconds)
        }
      )
    }
  }
}
