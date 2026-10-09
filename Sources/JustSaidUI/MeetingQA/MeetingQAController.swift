import Foundation
import JustSaidCore

/// 线程里的一问。
struct MeetingQATurn: Identifiable, Equatable {
  enum State: Equatable {
    /// 正在答;`partial` 是已写出的正文(来源行不在内)。
    case answering(partial: String)
    case answered(MeetingQAAnswer)
    case failed(advice: LLMRecoveryAdvice?, message: String)
  }

  let id: UUID
  let question: String
  /// 提问时的会议计时(秒)。
  let askedAt: TimeInterval
  var state: State
}

/// 线程里的一项:一问,或「新问题」分隔线。
enum MeetingQAThreadItem: Identifiable, Equatable {
  case turn(MeetingQATurn)
  case divider(UUID)

  var id: UUID {
    switch self {
    case .turn(let turn): return turn.id
    case .divider(let id): return id
    }
  }
}

/// 提问那一刻从驾驶舱取的材料。
struct MeetingQASnapshot {
  let segments: [TranscriptSegment]
  let topics: [SummaryTopic]
  let meetingDirectory: URL?
  let startedAt: Date?
}

/// 一场会一个控制器(会中问答,10-09 实验性)。由 `MeetingQAControllerRegistry` 按会议目录持有,
/// 切页签、切到会议库、主窗重建都不丢;换场时整个换掉。
@MainActor
final class MeetingQAController: ObservableObject {
  @Published private(set) var items: [MeetingQAThreadItem] = []
  @Published var draft = ""
  /// ⌘J 每按一次加一,问答页据此把光标放进输入框。
  @Published private(set) var focusToken = 0

  let meetingDirectory: URL?
  private var session = MeetingQASession()
  private var task: Task<Void, Never>?
  private let store = MeetingStore()

  init(meetingDirectory: URL?) {
    self.meetingDirectory = meetingDirectory
  }

  var isAnswering: Bool {
    items.contains {
      if case .turn(let turn) = $0, case .answering = turn.state { return true }
      return false
    }
  }

  var hasTurns: Bool {
    items.contains { if case .turn = $0 { return true } else { return false } }
  }

  func requestFocus() {
    focusToken += 1
  }

  /// 送出输入框里的问题。正在答时不送(输入框照常可打字)。
  func submitDraft(snapshot: MeetingQASnapshot, settings: ProviderSettingsStore) {
    let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !isAnswering else { return }
    draft = ""
    let turn = MeetingQATurn(
      id: UUID(), question: question, askedAt: elapsed(snapshot), state: .answering(partial: ""))
    items.append(.turn(turn))
    run(turn: turn, snapshot: snapshot, settings: settings)
  }

  /// 重试 = 同一个问题重发,上下文按此刻重新组装。
  func retry(turnID: UUID, snapshot: MeetingQASnapshot, settings: ProviderSettingsStore) {
    guard !isAnswering, let index = position(of: turnID), case .turn(var turn) = items[index] else {
      return
    }
    turn.state = .answering(partial: "")
    items[index] = .turn(turn)
    run(turn: turn, snapshot: snapshot, settings: settings)
  }

  /// 「新问题」:线程里画一道分隔,之后的提问不带之前的问答。
  func reset(snapshot: MeetingQASnapshot) {
    guard hasTurns, !isAnswering else { return }
    if case .divider = items.last { return }
    session.reset()
    items.append(.divider(UUID()))
    if let directory = meetingDirectory {
      try? MeetingQALog.append(
        .reset(at: elapsed(snapshot)), to: MeetingPaths(directory: directory))
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  private func run(turn: MeetingQATurn, snapshot: MeetingQASnapshot, settings: ProviderSettingsStore)
  {
    let input = MeetingQAQuestion(
      question: turn.question, askedAt: turn.askedAt, history: session.recentHistory,
      segments: snapshot.segments, topics: snapshot.topics,
      meetingPaths: (snapshot.meetingDirectory ?? meetingDirectory).map(MeetingPaths.init(directory:)))
    let client: any LLMClient
    do {
      // 每一问解析一次当时的选择,问到一半改设置不影响这一问。
      client = try settings.makeLLMClient(for: .meetingQA)
    } catch {
      finish(
        turnID: turn.id, question: turn.question, error: error,
        context: settings.failureContext(feature: .meetingQA, lane: .meetingQA))
      return
    }
    let store = store
    let turnID = turn.id
    // 一问最长几分钟;期间控制器由这个任务持有,答完即释放。
    task = Task {
      do {
        let answer = try await MeetingQAService.ask(input, client: client, store: store) {
          partial in
          Task { @MainActor in self.updatePartial(turnID: turnID, partial: partial) }
        }
        finish(turnID: turnID, question: input.question, answer: answer)
      } catch {
        finish(
          turnID: turnID, question: input.question, error: error,
          context: LLMFailureContext(feature: .meetingQA, configuration: client.configuration))
      }
    }
  }

  private func updatePartial(turnID: UUID, partial: String) {
    guard let index = position(of: turnID), case .turn(var turn) = items[index],
      case .answering(let current) = turn.state,
      // 增量回调经各自的 Task 回到主线程,先后不保证;累计正文只会变长。
      partial.count > current.count
    else { return }
    turn.state = .answering(partial: partial)
    items[index] = .turn(turn)
  }

  private func finish(turnID: UUID, question: String, answer: MeetingQAAnswer) {
    guard let index = position(of: turnID), case .turn(var turn) = items[index] else { return }
    turn.state = .answered(answer)
    items[index] = .turn(turn)
    session.record(MeetingQAExchange(question: question, answer: answer.body))
    task = nil
  }

  private func finish(
    turnID: UUID, question: String, error: Error, context: LLMFailureContext
  ) {
    task = nil
    guard let index = position(of: turnID), case .turn(var turn) = items[index] else { return }
    if error is CancellationError { return }
    let advice = LLMRecoveryAdvice.project(error, context: context)
    turn.state = .failed(
      advice: advice, message: advice?.message ?? error.localizedDescription)
    items[index] = .turn(turn)
  }

  private func position(of turnID: UUID) -> Int? {
    items.firstIndex { $0.id == turnID }
  }

  private func elapsed(_ snapshot: MeetingQASnapshot) -> TimeInterval {
    snapshot.startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
  }
}

/// 按会议目录持有当前这一场的控制器。只留一场:换场即取消上一场还在跑的一问并丢弃。
@MainActor
final class MeetingQAControllerRegistry {
  static let shared = MeetingQAControllerRegistry()

  private var current: MeetingQAController?
  /// ⌘J 在问答页还没出现时按下(主窗刚打开):等控制器建好再补一次取焦。
  private var pendingFocus = false

  func controller(for directory: URL?) -> MeetingQAController {
    let key = directory?.standardizedFileURL
    if let current, current.meetingDirectory == key {
      return current
    }
    current?.cancel()
    let created = MeetingQAController(meetingDirectory: key)
    current = created
    return created
  }

  /// ⌘J:切到「问答」页并取焦。
  func requestFocus() {
    UserDefaults.standard.set(
      MeetingQASidebarTab.qa.rawValue, forKey: MeetingQASettings.sidebarTabDefaultsKey)
    if let current {
      current.requestFocus()
    } else {
      pendingFocus = true
    }
  }

  func consumePendingFocus(into controller: MeetingQAController) {
    guard pendingFocus else { return }
    pendingFocus = false
    controller.requestFocus()
  }
}
