import Combine
import Foundation
import JustSaidCore

/// One in-memory projection of existing meeting/todo records, shared by all entry points.
/// New names are visible immediately during this run; durable ownership stays with their records.
@MainActor
final class ClientProjectDirectory: ObservableObject {
  private struct Entry: Equatable {
    var client: String
    var project: String
    var date: Date
    var key: String
  }
  private var meetings: [Entry] = []
  private var todos: [Entry] = []
  private var additions: [Entry] = []
  @Published private var entries: [Entry] = []

  var clients: [String] { unique(entries.map(\.client)) }

  func projects(for client: String) -> [String] {
    let client = clean(client)
    return unique(entries.filter { client.isEmpty || $0.client == client }.map(\.project))
  }

  func client(for project: String) -> String? {
    let project = clean(project)
    guard !project.isEmpty else { return nil }
    return entries.first { $0.project == project && !$0.client.isEmpty }?.client
  }

  func replaceMeetings(_ items: [MeetingLibraryItem]) {
    meetings = items.map {
      Entry(
        client: clean($0.client ?? ""), project: clean($0.project ?? ""), date: $0.startedAt,
        key: $0.id)
    }
    rebuild()
  }

  func replaceTodos(_ items: [TodoItem]) {
    todos = items.filter { $0.removedAt == nil }.map {
      Entry(
        client: clean($0.client ?? ""), project: clean($0.project ?? ""), date: $0.updatedAt,
        key: $0.id.uuidString)
    }
    rebuild()
  }

  func remember(client: String, project: String, at date: Date = .now) {
    let client = clean(client)
    let project = clean(project)
    guard !client.isEmpty || !project.isEmpty else { return }
    additions.removeAll { $0.client == client && $0.project == project }
    additions.append(
      Entry(client: client, project: project, date: date, key: "\(client)\u{0}\(project)"))
    rebuild()
  }

  func selectingClient(_ client: String, project: String) -> (client: String, project: String) {
    let client = clean(client)
    let project = clean(project)
    return (client, client.isEmpty || projects(for: client).contains(project) ? project : "")
  }

  func selectingProject(_ project: String, client: String) -> (client: String, project: String) {
    let project = clean(project)
    let client = clean(client)
    return (client.isEmpty ? self.client(for: project) ?? "" : client, project)
  }

  private func rebuild() {
    let next = (meetings + todos + additions).sorted {
      $0.date == $1.date ? $0.key < $1.key : $0.date > $1.date
    }
    if next != entries { entries = next }
  }

  private func clean(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private func unique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}
