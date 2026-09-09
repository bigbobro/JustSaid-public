import Foundation
import JustSaidCore

/// 补充记录区（步骤 5）的界面侧控制器：把真实的 `NotesWriter` 落盘与“标记重点”交互
/// 状态机接到一起。会议生命周期（何时创建/切换 writer、何时清空列表）由 `MainWorkspaceView`
/// 通过 `attachWriter(directory:)` 驱动，控制器本身不直接依赖 `RecordingSession`。
///
/// 类型名、`note` 字段、`notes.md` 文件名与导出 schema **一律不改**（08-10 明写的
/// Out of Scope）：改的只有面向用户的说法。
@MainActor
final class NotesController: ObservableObject {
  struct NoteItem: Identifiable, Equatable {
    enum Kind: Equatable {
      case normal
      case markPending
      case markFailed
    }

    let id: UUID
    var elapsed: TimeInterval
    var text: String
    var kind: Kind
    var suffixTag: String?

    init(
      id: UUID = UUID(),
      elapsed: TimeInterval,
      text: String,
      kind: Kind,
      suffixTag: String? = nil
    ) {
      self.id = id
      self.elapsed = elapsed
      self.text = text
      self.kind = kind
      self.suffixTag = suffixTag
    }
  }

  @Published private(set) var items: [NoteItem] = []
  @Published private(set) var persistenceWarning: String?

  /// 生产路径由会中总结引擎注入“标记”提炼；Preview 未注入时按诚实的失败态收尾。
  var markDistillationHandler:
    (@MainActor @Sendable (UUID, TimeInterval, TimeInterval) async throws -> String)?

  private var writer: NotesWriter?
  private var recordingStartedAt: Date?
  private var markTokens: [UUID: NotesMarkToken] = [:]
  private var meetingGeneration: UInt64 = 0
  private var pendingWorkCounts: [UInt64: Int] = [:]
  private var pendingWorkWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

  func bindRecordingStart(_ date: Date) {
    recordingStartedAt = date
  }

  /// 会议目录变化时（开始新录音 / 结束）重新指向对应的 notes.md，并清空上一场会议的列表。
  func attachWriter(directory: URL?) {
    meetingGeneration &+= 1
    items = []
    persistenceWarning = nil
    markTokens = [:]
    guard let directory else {
      writer = nil
      return
    }
    do {
      writer = try NotesWriter(fileURL: MeetingPaths(directory: directory).notes)
    } catch {
      writer = nil
      persistenceWarning = "补充记录暂时无法写入磁盘：\(error.localizedDescription)"
    }
  }

  func currentElapsed(now: Date = Date()) -> TimeInterval {
    guard let recordingStartedAt else {
      return 0
    }
    return max(0, now.timeIntervalSince(recordingStartedAt))
  }

  @discardableResult
  func addNote(_ text: String, elapsedOverride: TimeInterval? = nil) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return false
    }
    let elapsed = elapsedOverride ?? currentElapsed()
    items.append(NoteItem(elapsed: elapsed, text: trimmed, kind: .normal))
    persist(text: trimmed, elapsed: elapsed, suffix: nil)
    return true
  }

  /// 溯源弹层“存为补充记录”：带原时间戳写入，不额外打标签（仅“标记重点”产出的条目
  /// 才带“来自标记”标签，与 ui-final-v2.html 的列表一致）。
  func addSourceQuote(_ reference: SummarySourceReference) {
    let composed = reference.lines
      .map { "\($0.source == .me ? "我" : "对方")：\($0.text)" }
      .joined(separator: " ")
    addNote(composed, elapsedOverride: reference.transcriptAnchor)
  }

  func beginMark() {
    let id = UUID()
    let elapsed = currentElapsed()
    items.append(NoteItem(id: id, elapsed: elapsed, text: "", kind: .markPending))
    resolveMark(id: id, windowEnd: elapsed)
  }

  func retryMark(_ id: UUID) {
    guard
      let index = items.firstIndex(where: { $0.id == id }),
      items[index].kind == .markFailed
    else {
      return
    }
    let elapsed = items[index].elapsed
    items[index] = NoteItem(id: id, elapsed: elapsed, text: "", kind: .markPending)
    resolveMark(id: id, windowEnd: elapsed)
  }

  func flushPendingWrites() async {
    let generation = meetingGeneration
    guard pendingWorkCounts[generation, default: 0] > 0 else {
      return
    }
    await withCheckedContinuation { continuation in
      pendingWorkWaiters[generation, default: []].append(continuation)
    }
  }

  private func resolveMark(id: UUID, windowEnd: TimeInterval) {
    let windowStart = max(0, windowEnd - 75)
    let requestGeneration = meetingGeneration
    let requestWriter = writer
    let requestHandler = markDistillationHandler
    let existingToken = markTokens[id]
    let distillationTask: Task<String, Error>? = requestHandler.map { handler in
      Task {
        try await handler(id, windowStart, windowEnd)
      }
    }
    beginPendingWork(for: requestGeneration)
    Task {
      defer { finishPendingWork(for: requestGeneration) }
      var token = existingToken
      if let requestWriter {
        do {
          token = try await requestWriter.writeMarkPlaceholder(
            token: token,
            elapsed: windowEnd
          )
          if meetingGeneration == requestGeneration {
            markTokens[id] = token
          }
        } catch {
          if meetingGeneration == requestGeneration {
            persistenceWarning = "标记占位未能保存：\(error.localizedDescription)"
          }
        }
      }

      if let distillationTask {
        do {
          let text = try await distillationTask.value
          if let requestWriter, let token {
            do {
              try await requestWriter.resolveMark(token: token, text: text)
            } catch {
              if meetingGeneration == requestGeneration {
                persistenceWarning = "标记未能保存：\(error.localizedDescription)"
              }
            }
          } else if let requestWriter {
            do {
              try await requestWriter.append(
                elapsed: windowEnd,
                text: text,
                suffix: "来自标记"
              )
            } catch {
              if meetingGeneration == requestGeneration {
                persistenceWarning = "标记未能保存：\(error.localizedDescription)"
              }
            }
          }
          guard meetingGeneration == requestGeneration else {
            return
          }
          completeMark(id: id, text: text)
          markTokens.removeValue(forKey: id)
          return
        } catch {
          if let requestWriter, let token {
            do {
              try await requestWriter.failMark(token: token)
            } catch {
              if meetingGeneration == requestGeneration {
                persistenceWarning = "标记失败状态未能保存：\(error.localizedDescription)"
              }
            }
          }
          guard meetingGeneration == requestGeneration else {
            return
          }
          failMark(id: id)
          return
        }
      }
      // 未接入真实提炼能力：诚实地展示“提炼中”片刻后转入失败态，而不是编造内容。
      try? await Task.sleep(for: .seconds(1.4))
      if let requestWriter, let token {
        do {
          try await requestWriter.failMark(token: token)
        } catch {
          if meetingGeneration == requestGeneration {
            persistenceWarning = "标记失败状态未能保存：\(error.localizedDescription)"
          }
        }
      }
      guard meetingGeneration == requestGeneration else {
        return
      }
      failMark(id: id)
    }
  }

  private func completeMark(id: UUID, text: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return
    }
    items[index].text = text
    items[index].kind = .normal
    items[index].suffixTag = "来自标记"
  }

  private func failMark(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return
    }
    items[index].kind = .markFailed
  }

  private func persist(text: String, elapsed: TimeInterval, suffix: String?) {
    guard let writer else {
      return
    }
    let requestGeneration = meetingGeneration
    beginPendingWork(for: requestGeneration)
    Task {
      defer { finishPendingWork(for: requestGeneration) }
      do {
        try await writer.append(elapsed: elapsed, text: text, suffix: suffix)
      } catch {
        if meetingGeneration == requestGeneration {
          persistenceWarning = "补充记录未能保存：\(error.localizedDescription)"
        }
      }
    }
  }

  private func beginPendingWork(for generation: UInt64) {
    pendingWorkCounts[generation, default: 0] += 1
  }

  private func finishPendingWork(for generation: UInt64) {
    let remaining = max(0, pendingWorkCounts[generation, default: 1] - 1)
    if remaining > 0 {
      pendingWorkCounts[generation] = remaining
      return
    }
    pendingWorkCounts.removeValue(forKey: generation)
    let waiters = pendingWorkWaiters.removeValue(forKey: generation) ?? []
    for waiter in waiters {
      waiter.resume()
    }
  }
}
