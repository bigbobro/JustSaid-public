import Foundation

extension TodoItem {
  /// 明确无期限已经补全；已完成或回收箱条目不进入待补全。
  public var needsCompletion: Bool {
    status == .open && removedAt == nil && (assignee == .pending || due == .pending)
  }
}

public enum TodoAssigneeConflict {
  /// 不猜姓名是否代表本人。没有具体负责人原文时不制造冲突。
  public static func requiresConfirmation(sourceOwnerText: String?, assignee: TodoAssignee) -> Bool
  {
    guard let sourceOwnerText else { return false }
    let original = normalized(sourceOwnerText)
    guard !original.isEmpty, original != "待确认" else { return false }
    switch assignee {
    case .me: return original != "我" && original != "本人"
    case .named(let name): return original != normalized(name)
    case .pending: return true
    }
  }

  private static func normalized(_ text: String) -> String {
    TodoCandidateSignature.normalizedText(text)
  }
}

public enum TodoSearchField: String, Hashable, Sendable {
  case title, note, assignee, sourceMeeting
}

public struct TodoSearchMatch: Equatable, Sendable {
  public var fields: Set<TodoSearchField>
  /// 只包含确实命中的来源会名，供结果行展示并高亮。
  public var sourceMeetingTitles: [String]
}

public enum TodoSearch {
  /// 不受智能视图或完成状态约束；回收箱永远不参与。
  public static func match(_ item: TodoItem, query: String) -> TodoSearchMatch? {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, item.removedAt == nil else { return nil }
    var fields: Set<TodoSearchField> = []
    if contains(item.title, query: query) { fields.insert(.title) }
    if contains(item.note, query: query) { fields.insert(.note) }
    let assignee: String
    switch item.assignee {
    case .me: assignee = "我"
    case .named(let name): assignee = name
    case .pending: assignee = "待确认"
    }
    if contains(assignee, query: query) { fields.insert(.assignee) }
    var titles: [String] = []
    for title in item.sources.compactMap(\.meetingTitle)
    where contains(title, query: query) && !titles.contains(title) {
      titles.append(title)
    }
    if !titles.isEmpty { fields.insert(.sourceMeeting) }
    return fields.isEmpty ? nil : TodoSearchMatch(fields: fields, sourceMeetingTitles: titles)
  }

  public static func contains(_ text: String, query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return !query.isEmpty
      && text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }
}
