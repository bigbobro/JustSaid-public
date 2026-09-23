import Combine
import Foundation
import JustSaidCore

public enum TodoPagePhase: Equatable {
  case loading
  case ready
  case failed(TodoStoreError)
}

public enum TodoPageLayer: Equatable {
  case browse
  case editor
  case detail(UUID)
  case removed
}

public enum TodoEmptyKind: Equatable {
  case noneYet
  case noOpen
  case noMatch
  case noItemsInScope
}

public struct TodoEditorDraft: Equatable {
  public enum AssigneeKind: String, Equatable, CaseIterable {
    case me, named, pending
    public var title: String {
      switch self {
      case .me: "我"
      case .named: "指定的人"
      case .pending: "待确认"
      }
    }
  }

  public enum DueKind: String, Equatable, CaseIterable {
    case date, none, pending
    public var title: String {
      switch self {
      case .date: "指定日期"
      case .none: "无期限"
      case .pending: "截止待确认"
      }
    }
  }

  public var itemID: UUID?
  public var title = ""
  public var note = ""
  public var assigneeKind: AssigneeKind = .me
  public var assigneeName = ""
  public var dueKind: DueKind = .pending
  public var dueDate = Date()
  public var timeZoneIdentifier = SystemTimeZone.current.identifier
  public var priority: TodoPriority = .normal
  public var client = ""
  public var project = ""
  public var error: String?
  public var isRetry = false

}

public struct TodoQuadrantMove: Equatable {
  public enum DueMode: String, Equatable {
    case date, none, pending
  }

  public var itemID: UUID
  public var target: TodoQuadrant
  public var changesPriority: Bool
  public var priority: TodoPriority
  public var changesDue: Bool
  public var dueMode: DueMode
  public var day: String
  public var timeZoneIdentifier: String
  public var original: TodoEditable
  public var error: String?
  public var isRetry = false
}

public enum TodoEditorFocus: String, Equatable {
  case title, assignee, due
}

public struct TodoTrashConfirmation: Equatable {
  public var revision: Int
  public var count: Int
  public var error: String?
}

public struct TodoUndoOffer: Equatable {
  public enum Kind: Equatable {
    // nil 表示本动作未改该字段，撤销时保留当前值。
    case fields(due: TodoDue? = nil, priority: TodoPriority? = nil)
    case status(TodoStatus)
    case pinned(Bool)
    case removed(Bool)
  }

  public var message: String
  public var itemID: UUID
  public var kind: Kind
}

public struct TodoSourceChoice: Equatable, Identifiable {
  public var source: TodoSource
  public var directories: [URL]
  public var id: UUID { source.id }
}

/// 待办页的快照和呈现态。待办页与以后的会议右栏读同一份；写成功后替换快照，
/// 多窗口因为共用这一个模型而一起刷新。滚动偏移不发布，避免停手之前整页重算。
@MainActor
public final class TodoPageModel: ObservableObject {
  let tagDirectory = ClientProjectDirectory()
  private var directoryObservation: AnyCancellable?
  public let store: TodoStore
  public var usesDisk: Bool
  public var now: Date
  @Published public private(set) var phase: TodoPagePhase
  @Published public private(set) var snapshot: TodoSnapshot? {
    didSet { tagDirectory.replaceTodos(snapshot?.state.todos ?? []) }
  }
  @Published public var scope: TodoScope
  @Published public var layout: TodoLayout {
    didSet {
      guard oldValue != layout else { return }
      sidebarVisible = savedSidebarVisibility(for: layout)
      inspectorVisible = false
      popoverID = nil
      editor = nil
    }
  }
  @Published public var searchText: String
  @Published public var selectedClient: String?
  @Published public var selectedProject: String?
  @Published public var expandedClients: Set<String> = []
  @Published public var sidebarVisible = true {
    didSet { preferences.set(sidebarVisible, forKey: Self.sidebarVisibilityKey(for: layout)) }
  }
  @Published public private(set) var popoverID: UUID?
  @Published public var inspectorVisible = false
  @Published public var inspectorPinned: Bool {
    didSet { preferences.set(inspectorPinned, forKey: Self.inspectorPinnedKey) }
  }
  @Published public var editorFocus: TodoEditorFocus?
  @Published public private(set) var editorFocusRequest = 0
  @Published public var showingRecycleBin = false
  @Published public var trashConfirmation: TodoTrashConfirmation?
  @Published public var transientMessage: String? {
    didSet { if transientMessage != nil { restartReceiptTimer() } }
  }
  private let preferences: UserDefaults
  public static let inspectorPinnedKey = "justsaid.todos.inspectorPinned"
  private var receiptTask: Task<Void, Never>?
  private var establishedInitialSelection = false
  @Published public var selectedID: UUID?
  public var scrollOffset: CGFloat
  @Published public var layer: TodoPageLayer
  @Published public var editor: TodoEditorDraft?
  @Published public var move: TodoQuadrantMove?
  @Published public private(set) var dragSourceID: UUID?
  @Published public private(set) var activeDraggingID: UUID?
  @Published public private(set) var dragHoverTarget: TodoQuadrant?
  @Published public var undo: TodoUndoOffer? {
    didSet {
      if undo != nil {
        transientMessage = nil
        restartReceiptTimer()
      }
    }
  }
  @Published public var sourceChoice: TodoSourceChoice?
  @Published public var candidateContext: MeetingCandidateContext?
  @Published public var candidateRows: [TodoCandidateRow] = []
  @Published public var candidateItems: [SummaryActionItem] = []
  @Published public var candidateQuestions: [MeetingOpenItem] = []
  @Published public var legacyHits: [TodoLegacyHit] = []
  @Published public var candidateSelection: Set<UUID> = []
  @Published public var expandedFolds: Set<MeetingCandidateFold> = []
  @Published public var roundNotices: [MeetingCandidateNotice] = []
  @Published public var candidateSurface: MeetingCandidateSurface = .meeting
  @Published public var cleanLines: [MeetingCandidateCleanLine] = []
  @Published public var reconcileID: UUID?
  @Published public var cleanError: String?
  @Published public var cleanRetry = false
  @Published public var candidateReceipt: MeetingCandidateReceipt?
  @Published public var candidateActionError: String?
  @Published public var candidateWritable = false
  @Published public private(set) var directories: [URL]
  @Published public private(set) var deletedMeetingIDs: Set<UUID>
  @Published public var actionError: String?

  public init(store: TodoStore, now: Date = .now, preferences: UserDefaults = .standard) {
    self.preferences = preferences
    inspectorPinned = preferences.bool(forKey: Self.inspectorPinnedKey)
    self.store = store
    self.now = now
    usesDisk = true
    phase = .loading
    scope = .open
    layout = .list
    sidebarVisible =
      preferences.object(forKey: Self.sidebarVisibilityKey(for: .list)) as? Bool ?? true
    searchText = ""
    scrollOffset = 0
    layer = .browse
    directories = []
    deletedMeetingIDs = []
    directoryObservation = tagDirectory.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  public var canMutate: Bool { phase == .ready && snapshot != nil }

  public var displayedLayout: TodoLayout {
    scope == .done || isSearching || isShowingRecycleBin ? .list : layout
  }

  public var failure: TodoStoreError? {
    if case .failed(let error) = phase { return error }
    return nil
  }

  public var activeItems: [TodoItem] {
    (snapshot?.state.todos ?? []).filter { $0.removedAt == nil }
  }

  public var removedItems: [TodoItem] {
    (snapshot?.state.todos ?? []).filter { $0.removedAt != nil }
      .sorted { ($0.removedAt ?? .distantPast) > ($1.removedAt ?? .distantPast) }
  }

  public func item(_ id: UUID) -> TodoItem? {
    snapshot?.state.todos.first { $0.id == id }
  }

  public var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
  public var isSearching: Bool { !query.isEmpty }
  public var isShowingRecycleBin: Bool { showingRecycleBin && !isSearching }
  public var filtering: Bool { isSearching || selectedClient != nil || selectedProject != nil }
  public var isCreating: Bool { editor != nil && editor?.itemID == nil }

  public var emptyKind: TodoEmptyKind? {
    guard phase == .ready, !isCreating, !isShowingRecycleBin, visibleItems.isEmpty else {
      return nil
    }
    if isSearching || selectedClient != nil { return .noMatch }
    if activeItems.isEmpty { return .noneYet }
    if scope == .open, !activeItems.contains(where: { $0.status == .open }) { return .noOpen }
    return .noItemsInScope
  }

  public func items(in scope: TodoScope) -> [TodoItem] {
    switch scope {
    case .open: return activeItems.filter { $0.status == .open }
    case .pending: return activeItems.filter(\.needsCompletion)
    case .today: return TodoOrdering.todaySections(activeItems, now: now).flatMap(\.items)
    case .overdue:
      return activeItems.filter { TodoOrdering.openGroup(of: $0, now: now) == .overdue }
    case .pinned: return activeItems.filter { $0.status == .open && $0.pinnedAt != nil }
    case .done: return activeItems.filter { $0.status == .done }
    }
  }

  public func count(in scope: TodoScope) -> Int { items(in: scope).count }

  public var visibleItems: [TodoItem] {
    if isSearching { return activeItems.filter { TodoSearch.match($0, query: query) != nil } }
    if isShowingRecycleBin { return removedItems }
    return items(in: scope).filter { item in
      (selectedClient == nil || item.client == selectedClient)
        && (selectedProject == nil || item.project == selectedProject)
    }
  }

  public var summaryText: String {
    if isSearching { return "搜索「\(query)」· \(visibleItems.count) 条" }
    if isShowingRecycleBin { return "回收箱" }
    return scope.title
  }

  public var openSections: [TodoOpenSection] {
    scope == .today && !isSearching
      ? TodoOrdering.todaySections(visibleItems, now: now)
      : TodoOrdering.openSections(visibleItems, now: now)
  }

  public func searchMatch(for item: TodoItem) -> TodoSearchMatch? {
    TodoSearch.match(item, query: query)
  }

  public func projects(for client: String) -> [String] {
    tagDirectory.projects(for: client)
  }

  public func clientCount(_ client: String, project: String? = nil) -> Int {
    items(in: scope).filter { $0.client == client && (project == nil || $0.project == project) }
      .count
  }

  public func chooseScope(_ scope: TodoScope) {
    guard submitCurrentEditor() else { return }
    self.scope = scope
    showingRecycleBin = false
    layer = .browse
  }

  public func chooseClient(_ client: String?, project: String? = nil) {
    guard submitCurrentEditor() else { return }
    selectedClient = client
    selectedProject = project
    showingRecycleBin = false
  }

  public func chooseLayout(_ layout: TodoLayout) {
    guard scope != .done, !isSearching, submitCurrentEditor() else { return }
    self.layout = layout
  }

  public static func sidebarVisibilityKey(for layout: TodoLayout) -> String {
    "justsaid.todos.sidebarVisible.\(layout.rawValue)"
  }

  private func savedSidebarVisibility(for layout: TodoLayout) -> Bool {
    preferences.object(forKey: Self.sidebarVisibilityKey(for: layout)) as? Bool ?? (layout == .list)
  }

  /// Automatic narrow-window collapse is layout only; it never changes the user's preference.
  public func sidebarIsVisible(contentWidth: CGFloat) -> Bool {
    guard sidebarVisible else { return false }
    let accessoryWidth: CGFloat
    if popoverID != nil {
      accessoryWidth = Tokens.V1.Size.todoPopoverWidth + Tokens.V1.Space.lg
    } else if inspectorVisible && inspectorIsDocked(contentWidth: contentWidth) {
      accessoryWidth = Tokens.V1.Size.todoDetailWidth
    } else {
      return true
    }
    return contentWidth >= Tokens.V1.Size.panelWidth + accessoryWidth
      + Tokens.V1.Size.todoListMinWidth
  }

  public func toggleSidebar(contentWidth: CGFloat) {
    if sidebarVisible && !sidebarIsVisible(contentWidth: contentWidth) {
      closeLayer()
    } else {
      sidebarVisible.toggle()
    }
  }

  public func inspectorIsDocked(contentWidth: CGFloat) -> Bool {
    displayedLayout == .list
      || (inspectorPinned
        && contentWidth >= Tokens.V1.Size.todoDetailWidth + Tokens.V1.Size.todoListMinWidth)
  }

  /// Selection and presentation are separate actions. A click never opens an editing surface.
  public func selectItem(_ id: UUID) {
    guard item(id) != nil, submitCurrentEditor() else { return }
    selectedID = id
    inspectorVisible = false
    popoverID = nil
    editor = nil
    editorFocus = nil
    layer = .browse
  }

  public func showPopover(_ id: UUID) {
    guard let item = item(id), item.removedAt == nil,
      editor?.itemID == id || submitCurrentEditor()
    else { return }
    selectedID = id
    if editor?.itemID != id { editor = draft(from: item) }
    editorFocus = nil
    inspectorVisible = false
    popoverID = id
    layer = .detail(id)
  }

  public func closePopover() {
    guard popoverID != nil, submitCurrentEditor() else { return }
    popoverID = nil
    editor = nil
    editorFocus = nil
    layer = .browse
  }

  public func dismissHiddenPopover() {
    guard let popoverID, !visibleItems.contains(where: { $0.id == popoverID }) else { return }
    dismissPopoverForNavigation()
  }

  private func dismissPopoverForNavigation() {
    closePopover()
    // If saving failed, keep the draft/error visible in a pane after its row anchor disappears.
    if popoverID != nil {
      popoverID = nil
      inspectorVisible = true
    }
  }

  public var completed: TodoCompletedSections {
    TodoOrdering.completedSections(visibleItems)
  }

  public var board: TodoQuadrantBoard {
    TodoOrdering.quadrantBoard(visibleItems, now: now)
  }

  public var pinCensus: (total: Int, overdue: Int) {
    let pins = activeItems.filter { $0.status == .open && $0.pinnedAt != nil }
    let overdue = pins.filter { TodoOrdering.openGroup(of: $0, now: now) == .overdue }.count
    return (pins.count, overdue)
  }

  public var clients: [String] {
    tagDirectory.clients
  }

  public func reloadSynchronously() {
    guard usesDisk else { return }
    do {
      snapshot = try store.load()
      phase = .ready
      establishInitialSelection()
    } catch let error as TodoStoreError {
      snapshot = nil
      phase = .failed(error)
    } catch {
      snapshot = nil
      phase = .failed(.unreadable(url: store.fileURL, reason: error.localizedDescription))
    }
  }

  public func installSnapshot(_ snapshot: TodoSnapshot, now: Date) {
    usesDisk = false
    self.now = now
    self.snapshot = snapshot
    phase = .ready
    establishInitialSelection()
  }

  private func establishInitialSelection() {
    guard !establishedInitialSelection else { return }
    establishedInitialSelection = true
    guard selectedID == nil,
      let first = TodoOrdering.openSections(activeItems, now: now).flatMap(\.items).first
    else { return }
    selectedID = first.id
    inspectorVisible = false
  }

  public func installFailure(_ error: TodoStoreError) {
    usesDisk = false
    snapshot = nil
    phase = .failed(error)
  }

  public func installLoading() {
    usesDisk = false
    snapshot = nil
    phase = .loading
  }

  public func replaceMeetingIndex(directories: [URL], deletedMeetingIDs: Set<UUID>) {
    self.directories = directories
    self.deletedMeetingIDs = deletedMeetingIDs
  }

  public func clearSearch() { searchText = "" }

  public func showCompleted() { chooseScope(.done) }

  public func updateEditor(_ body: (inout TodoEditorDraft) -> Void) {
    guard var editor else { return }
    body(&editor)
    self.editor = editor
  }

  public func selectEditorClient(_ value: String) {
    guard let editor else { return }
    let pair = tagDirectory.selectingClient(value, project: editor.project)
    updateEditor {
      $0.client = pair.client
      $0.project = pair.project
    }
    tagDirectory.remember(client: pair.client, project: pair.project)
    saveExistingEditor()
  }

  public func selectEditorProject(_ value: String) {
    guard let editor else { return }
    let pair = tagDirectory.selectingProject(value, client: editor.client)
    updateEditor {
      $0.client = pair.client
      $0.project = pair.project
    }
    tagDirectory.remember(client: pair.client, project: pair.project)
    saveExistingEditor()
  }

  public func cancelCreate() {
    guard isCreating else { return }
    editor = nil
    editorFocus = nil
    inspectorVisible = false
    layer = .browse
  }

  public func saveExistingEditor() {
    guard editor?.itemID != nil else { return }
    _ = saveEditor()
  }

  @discardableResult
  public func submitCurrentEditor() -> Bool {
    guard let editor else { return true }
    if editor.itemID == nil && editor.title.nilIfBlank == nil { return true }
    return saveEditor()
  }

  public func updateMove(_ body: (inout TodoQuadrantMove) -> Void) {
    guard var move else { return }
    body(&move)
    move.error = nil
    move.isRetry = false
    self.move = move
  }

  public func beginCreate() {
    guard canMutate, submitCurrentEditor() else { return }
    layout = .list
    var draft = TodoEditorDraft()
    draft.dueKind = .pending
    draft.dueDate = TodoClock.pickerDate(
      day: TodoCalendar.dayString(of: now, timeZone: SystemTimeZone.current) ?? "")
    editor = draft
    selectedID = nil
    layer = .editor
    showingRecycleBin = false
    popoverID = nil
    inspectorVisible = true
    requestEditorFocus(.title)
  }

  public func beginEdit(_ id: UUID) {
    guard canMutate, let item = item(id), item.removedAt == nil else { return }
    guard editor?.itemID == id || submitCurrentEditor() else { return }
    if editor?.itemID != id {
      editorFocus = nil
      editor = draft(from: item)
    }
    layer = .editor
    selectedID = id
    popoverID = nil
    inspectorVisible = true
  }

  public func beginCompletion(_ id: UUID) {
    beginEdit(id)
    guard editor?.itemID == id, let item = item(id) else { return }
    requestEditorFocus(item.assignee == .pending ? .assignee : .due)
  }

  public func requestEditorFocus(_ focus: TodoEditorFocus) {
    editorFocus = focus
    editorFocusRequest &+= 1
  }

  public func closeLayer() {
    guard submitCurrentEditor() else { return }
    editor = nil
    editorFocus = nil
    inspectorVisible = false
    popoverID = nil
    layer = .browse
  }

  public func showDetail(_ id: UUID) {
    guard let item = item(id), editor?.itemID == id || submitCurrentEditor() else { return }
    selectedID = id
    if item.removedAt == nil {
      if editor?.itemID != id {
        editorFocus = nil
        editor = draft(from: item)
      }
    } else {
      editor = nil
    }
    popoverID = nil
    inspectorVisible = true
    layer = .detail(id)
  }

  public func showRemoved() {
    guard submitCurrentEditor() else { return }
    showingRecycleBin = true
    layer = .removed
    popoverID = nil
    inspectorVisible = false
    editor = nil
  }

  public func requestEmptyRecycleBin() {
    guard canMutate, !removedItems.isEmpty else { return }
    trashConfirmation = TodoTrashConfirmation(revision: revision, count: removedItems.count)
  }

  @discardableResult
  public func emptyRecycleBin() -> Bool {
    guard canMutate, var confirmation = trashConfirmation else { return false }
    do {
      apply(try store.emptyRecycleBin(expectedRevision: confirmation.revision))
      trashConfirmation = nil
      if let selectedID, item(selectedID) == nil {
        self.selectedID = nil
        inspectorVisible = false
      }
      clearReceipt()
      transientMessage = "已清空回收箱"
      return true
    } catch {
      confirmation.error = TodoText.reason(of: error)
      trashConfirmation = confirmation
      return false
    }
  }

  @discardableResult
  public func saveEditor() -> Bool {
    guard canMutate, var editor else { return false }
    let title = editor.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      editor.error = TodoText.saveFailure("事项不能为空")
      editor.isRetry = true
      self.editor = editor
      return false
    }
    if editor.assigneeKind == .named,
      editor.assigneeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      editor.error = TodoText.saveFailure("还没有填写负责人")
      editor.isRetry = true
      self.editor = editor
      return false
    }
    let assignee = assignee(from: editor)
    let due = due(from: editor)
    let client = editor.client.nilIfBlank
    let project = editor.project.nilIfBlank
    let note = editor.note.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let saved: TodoSnapshot
      let savedID: UUID
      if let id = editor.itemID {
        let desired = TodoEditable(
          title: title, note: note, assignee: assignee, due: due,
          priority: editor.priority, client: client, project: project)
        if let current = item(id), editable(current) == desired {
          editor.error = nil
          editor.isRetry = false
          self.editor = editor
          return true
        }
        saved = try store.updateTodo(id, expectedRevision: revision, now: now) { editable in
          editable.title = title
          editable.note = note
          editable.assignee = assignee
          editable.due = due
          editable.priority = editor.priority
          editable.client = client
          editable.project = project
        }
        savedID = id
      } else {
        let result = try store.add(
          [
            TodoDraft(
              title: title, note: note, assignee: assignee, due: due, priority: editor.priority,
              client: client, project: project)
          ], expectedRevision: revision, now: now)
        saved = result.snapshot
        savedID = result.todoIDs.first ?? result.snapshot.state.todos.last?.id ?? UUID()
      }
      apply(saved)
      editor.itemID = savedID
      editor.error = nil
      editor.isRetry = false
      self.editor = editor
      selectedID = savedID
      return true
    } catch let error as TodoStoreError {
      if case .conflict(let current) = error { snapshot = current }
      editor.error = TodoText.saveFailure(TodoText.reason(of: error))
      editor.isRetry = true
      self.editor = editor
      return false
    } catch {
      editor.error = TodoText.saveFailure(TodoText.reason(of: error))
      editor.isRetry = true
      self.editor = editor
      return false
    }
  }

  public func toggleComplete(_ id: UUID) {
    guard canMutate, submitCurrentEditor(), let item = item(id), item.removedAt == nil else {
      return
    }
    let next: TodoStatus = item.status == .done ? .open : .done
    let previous = item.status
    write("\(next == .done ? "已完成" : "已恢复")「\(item.title)」", itemID: id, kind: .status(previous)) {
      try store.setStatus(id, status: next, expectedRevision: revision, now: now)
    }
  }

  public func togglePin(_ id: UUID) {
    guard canMutate, submitCurrentEditor(), let item = item(id), item.removedAt == nil,
      item.status == .open
    else { return }
    if item.pinnedAt != nil {
      write("已取消钉住「\(item.title)」", itemID: id, kind: .pinned(true)) {
        try store.setPinned(id, pinned: false, expectedRevision: revision, now: now)
      }
      return
    }
    do {
      let saved = try store.setPinned(id, pinned: true, expectedRevision: revision, now: now)
      apply(saved)
      undo = TodoUndoOffer(message: "已钉住「\(item.title)」", itemID: id, kind: .pinned(false))
    } catch let error as TodoStoreError {
      if case .pinLimit = error {
        undo = nil
        transientMessage = TodoText.pinLimit
        return
      }
      if case .conflict(let current) = error { snapshot = current }
      actionError = TodoText.reason(of: error)
    } catch {
      actionError = TodoText.reason(of: error)
    }
  }

  public func remove(_ id: UUID) {
    guard canMutate, submitCurrentEditor(), let item = item(id), item.removedAt == nil else {
      return
    }
    write("已移除「\(item.title)」", itemID: id, kind: .removed(false)) {
      try store.setRemoved(id, removed: true, expectedRevision: revision, now: now)
    }
    if self.item(id)?.removedAt != nil, editor?.itemID == id {
      editor = nil
      inspectorVisible = false
    }
  }

  public func restore(_ id: UUID) {
    guard canMutate, let item = item(id), item.removedAt != nil else { return }
    write("已恢复「\(item.title)」", itemID: id, kind: .removed(true)) {
      try store.setRemoved(id, removed: false, expectedRevision: revision, now: now)
    }
  }

  /// Records the native provider request on every supported macOS version. This is source
  /// identity only; it deliberately does not claim that a cancellable session is still active.
  @discardableResult
  public func recordDragSource(_ id: UUID) -> Bool {
    guard canMutate, let item = item(id), item.status == .open, item.removedAt == nil else {
      return false
    }
    if dragSourceID != id {
      dragSourceID = id
      activeDraggingID = nil
      dragHoverTarget = nil
    }
    return true
  }

  /// Only a macOS 26+ native active-session notification calls this in production.
  public func setActiveDragging(_ id: UUID) {
    guard recordDragSource(id) else { return }
    activeDraggingID = id
  }

  public func endDragging(_ id: UUID) {
    guard dragSourceID == id || activeDraggingID == id else { return }
    dragSourceID = nil
    activeDraggingID = nil
    dragHoverTarget = nil
  }

  public func canTargetDrag(_ target: TodoQuadrant) -> Bool {
    guard target != .duePending, let id = dragSourceID, let item = item(id),
      item.status == .open, item.removedAt == nil, canMutate
    else { return false }
    return TodoOrdering.quadrant(of: item, now: now) != target
  }

  public func updateDragHover(_ target: TodoQuadrant, isTargeted: Bool) {
    if isTargeted, canTargetDrag(target) {
      dragHoverTarget = target
    } else if dragHoverTarget == target {
      dragHoverTarget = nil
    }
  }

  public func cancelMove() { move = nil }

  public var canSaveMove: Bool {
    guard canMutate, let move, let item = item(move.itemID) else { return false }
    return moveRejection(move, item: item) == nil
  }

  public func moveDueRejection(_ due: TodoDue) -> String? {
    guard let move, let item = item(move.itemID) else { return "没有待确认的移动" }
    if case .date(let day) = due, !TodoCalendar.isValid(day) { return "请选择有效日期" }
    let zone = TimeZone(identifier: move.timeZoneIdentifier) ?? TodoClock.zone(of: item)
    return dueRejection(due, target: move.target, zone: zone)
  }

  @discardableResult
  public func beginQuadrantMove(_ id: UUID, to target: TodoQuadrant) -> Bool {
    guard canMutate, submitCurrentEditor(), let item = item(id), item.status == .open,
      item.removedAt == nil
    else { return false }
    guard let source = TodoOrdering.quadrant(of: item, now: now), source != target else {
      return false
    }
    let zone = TodoClock.zone(of: item)
    let toImportant = target == .importantUrgent || target == .importantNotUrgent
    let toUrgent = target == .importantUrgent || target == .urgentNotImportant
    let fromUrgent = TodoOrdering.isUrgent(item, now: now)
    let changesPriority =
      target != .duePending
      && ((toImportant && item.priority != .high) || (!toImportant && item.priority == .high))
    let changesDue = target == .duePending || source == .duePending || toUrgent != fromUrgent
    var priority = item.priority
    if changesPriority { priority = toImportant ? .high : .normal }
    var dueMode: TodoQuadrantMove.DueMode = .date
    var day = ""
    if target == .duePending {
      dueMode = .pending
    } else if !changesDue {
      switch item.due {
      case .none: dueMode = .none
      case .pending: dueMode = .pending
      case .date(let existing):
        dueMode = .date
        day = existing.day
      }
    }

    move = TodoQuadrantMove(
      itemID: id, target: target, changesPriority: changesPriority, priority: priority,
      changesDue: changesDue, dueMode: dueMode, day: day, timeZoneIdentifier: zone.identifier,
      original: editable(item), error: nil)
    return true
  }

  @discardableResult
  public func saveMove() -> Bool {
    guard canMutate, var move, let item = item(move.itemID) else { return false }
    if let reason = moveRejection(move, item: item) {
      move.error = TodoText.saveFailure(reason)
      move.isRetry = true
      self.move = move
      return false
    }
    let due = proposedDue(move, item: item)
    let priority = move.changesPriority ? move.priority : item.priority
    do {
      let saved = try store.updateTodo(move.itemID, expectedRevision: revision, now: now) {
        editable in
        editable.priority = priority
        editable.due = due
      }
      apply(saved)
      self.move = nil
      refreshEditor(move.itemID)
      if due != item.due || priority != item.priority {
        undo = TodoUndoOffer(
          message: "已移到「\(TodoText.quadrantTitle(move.target))」",
          itemID: move.itemID,
          kind: .fields(
            due: due != item.due ? item.due : nil,
            priority: priority != item.priority ? item.priority : nil))
      }
      return true
    } catch let error as TodoStoreError {
      if case .conflict(let current) = error { snapshot = current }
      move.error = TodoText.saveFailure(TodoText.reason(of: error))
      move.isRetry = true
      self.move = move
      return false
    } catch {
      move.error = TodoText.saveFailure(TodoText.reason(of: error))
      move.isRetry = true
      self.move = move
      return false
    }
  }

  public func location(of source: TodoSource) -> TodoMeetingLocation {
    TodoMeetingLocator.locate(
      meetingID: source.meetingID, in: directories, deletedMeetingIDs: deletedMeetingIDs)
  }

  public func openSource(_ source: TodoSource, navigate: (URL, TimeInterval?) -> Void) {
    guard submitCurrentEditor() else { return }
    switch location(of: source) {
    case .present(let url):
      navigate(url, TranscriptAnchor(timecode: source.anchor ?? "").seconds)
    case .ambiguous(let urls):
      sourceChoice = TodoSourceChoice(source: source, directories: urls)
    case .deleted, .unavailable:
      showDetail(itemID(containing: source) ?? selectedID ?? source.id)
    }
  }

  public func chooseSourceDirectory(_ url: URL, navigate: (URL, TimeInterval?) -> Void) {
    let seconds = sourceChoice.flatMap {
      TranscriptAnchor(timecode: $0.source.anchor ?? "").seconds
    }
    sourceChoice = nil
    navigate(url, seconds)
  }

  public func performUndo() {
    guard canMutate, submitCurrentEditor(), let undo else { return }
    do {
      let saved: TodoSnapshot
      switch undo.kind {
      case .fields(let due, let priority):
        saved = try store.updateTodo(undo.itemID, expectedRevision: revision, now: now) {
          editable in
          if let due { editable.due = due }
          if let priority { editable.priority = priority }
        }
      case .status(let status):
        saved = try store.setStatus(
          undo.itemID, status: status, expectedRevision: revision, now: now)
      case .pinned(let pinned):
        saved = try store.setPinned(
          undo.itemID, pinned: pinned, expectedRevision: revision, now: now)
      case .removed(let removed):
        saved = try store.setRemoved(
          undo.itemID, removed: removed, expectedRevision: revision, now: now)
      }
      apply(saved)
      refreshEditor(undo.itemID)
      clearReceipt()
    } catch {
      actionError = TodoText.reason(of: error)
    }
  }

  public func matches(_ item: TodoItem) -> Bool {
    isSearching
      ? TodoSearch.match(item, query: query) != nil
      : (selectedClient == nil || item.client == selectedClient)
        && (selectedProject == nil || item.project == selectedProject)
  }

  public func setDue(_ id: UUID, due: TodoDue) {
    guard canMutate, submitCurrentEditor(), let item = item(id) else { return }
    write("已设置截止「\(item.title)」", itemID: id, kind: .fields(due: item.due)) {
      try store.updateTodo(id, expectedRevision: revision, now: now) { $0.due = due }
    }
    refreshEditor(id)
  }

  public func setPriority(_ id: UUID, priority: TodoPriority) {
    guard canMutate, submitCurrentEditor(), let item = item(id) else { return }
    write("已设置优先级「\(item.title)」", itemID: id, kind: .fields(priority: item.priority)) {
      try store.updateTodo(id, expectedRevision: revision, now: now) { $0.priority = priority }
    }
    refreshEditor(id)
  }

  private func refreshEditor(_ id: UUID) {
    if editor?.itemID == id, let item = item(id), actionError == nil { editor = draft(from: item) }
  }

  public func clearReceipt() {
    receiptTask?.cancel()
    receiptTask = nil
    undo = nil
    transientMessage = nil
  }

  public func pageDidDisappear() {
    if popoverID != nil {
      dismissPopoverForNavigation()
    } else {
      _ = submitCurrentEditor()
    }
    clearReceipt()
    cancelMove()
    dragSourceID = nil
    activeDraggingID = nil
    dragHoverTarget = nil
  }

  private func restartReceiptTimer() {
    receiptTask?.cancel()
    receiptTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(Tokens.V1.Motion.receipt)) } catch { return }
      self?.clearReceipt()
    }
  }

  var revision: Int { snapshot?.state.revision ?? 0 }

  func apply(_ snapshot: TodoSnapshot) {
    self.snapshot = snapshot
    phase = .ready
    actionError = nil
  }

  private func write(
    _ message: String, itemID: UUID, kind: TodoUndoOffer.Kind,
    _ body: () throws -> TodoSnapshot
  ) {
    do {
      let saved = try body()
      apply(saved)
      undo = TodoUndoOffer(message: message, itemID: itemID, kind: kind)
    } catch let error as TodoStoreError {
      if case .conflict(let current) = error { snapshot = current }
      actionError = TodoText.reason(of: error)
    } catch {
      actionError = TodoText.reason(of: error)
    }
  }

  private func draft(from item: TodoItem) -> TodoEditorDraft {
    var draft = TodoEditorDraft()
    draft.itemID = item.id
    draft.title = item.title
    draft.note = item.note
    switch item.assignee {
    case .me: draft.assigneeKind = .me
    case .pending: draft.assigneeKind = .pending
    case .named(let name):
      draft.assigneeKind = .named
      draft.assigneeName = name
    }
    switch item.due {
    case .none: draft.dueKind = .none
    case .pending: draft.dueKind = .pending
    case .date(let day):
      draft.dueKind = .date
      draft.dueDate = TodoClock.pickerDate(day: day.day)
      draft.timeZoneIdentifier = day.timeZoneIdentifier
    }
    draft.priority = item.priority
    draft.client = item.client ?? ""
    draft.project = item.project ?? ""
    return draft
  }

  func assignee(from editor: TodoEditorDraft) -> TodoAssignee {
    switch editor.assigneeKind {
    case .me: return .me
    case .pending: return .pending
    case .named: return .named(editor.assigneeName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private func due(from editor: TodoEditorDraft) -> TodoDue {
    switch editor.dueKind {
    case .none: return TodoDue.none
    case .pending: return TodoDue.pending
    case .date:
      let day = TodoClock.dayString(from: editor.dueDate)
      let zone =
        editor.itemID == nil ? SystemTimeZone.current.identifier : editor.timeZoneIdentifier
      return .date(TodoDay(day: day, timeZoneIdentifier: zone))
    }
  }

  private func editable(_ item: TodoItem) -> TodoEditable {
    TodoEditable(
      title: item.title, note: item.note, assignee: item.assignee, due: item.due,
      priority: item.priority, client: item.client, project: item.project)
  }

  private func proposedDue(_ move: TodoQuadrantMove, item: TodoItem) -> TodoDue {
    guard move.changesDue else { return item.due }
    switch move.dueMode {
    case .none: return .none
    case .pending: return .pending
    case .date:
      return .date(TodoDay(day: move.day, timeZoneIdentifier: move.timeZoneIdentifier))
    }
  }

  private func moveRejection(_ move: TodoQuadrantMove, item: TodoItem) -> String? {
    if item.removedAt != nil { return "该待办已移入回收箱，不能移动" }
    if item.status != .open { return "该待办已完成，不能移动" }
    let due = proposedDue(move, item: item)
    if case .date(let day) = due, !TodoCalendar.isValid(day) {
      return move.day.isEmpty ? "请选择截止日期" : "这个日期不存在"
    }
    let zone = TimeZone(identifier: move.timeZoneIdentifier) ?? TodoClock.zone(of: item)
    if let reason = dueRejection(due, target: move.target, zone: zone) { return reason }
    return priorityRejection(
      move.changesPriority ? move.priority : item.priority, target: move.target)
  }

  private func dueRejection(_ due: TodoDue, target: TodoQuadrant, zone: TimeZone) -> String? {
    if target == .duePending {
      return due == .pending ? nil : "截止待确认只接受还没定的日期"
    }
    let urgentTarget = target == .importantUrgent || target == .urgentNotImportant
    switch due {
    case .pending:
      return "四格里不放截止待确认"
    case .none:
      return urgentTarget ? "要选明天或更早的日期" : nil
    case .date(let day):
      let urgent = TodoClock.isUrgentDay(day.day, now: now, zone: zone)
      if urgentTarget, !urgent { return "要选明天或更早的日期" }
      if !urgentTarget, urgent { return "要选后天或更晚的日期，或无期限" }
      return nil
    }
  }

  private func priorityRejection(_ priority: TodoPriority, target: TodoQuadrant) -> String? {
    guard target != .duePending else { return nil }
    let important = target == .importantUrgent || target == .importantNotUrgent
    if important, priority != .high { return "上排只放高优先级" }
    if !important, priority == .high { return "下排要先把高优先级改成普通或低" }
    return nil
  }

  private func itemID(containing source: TodoSource) -> UUID? {
    snapshot?.state.todos.first { $0.sources.contains { $0.id == source.id } }?.id
  }

}

extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
