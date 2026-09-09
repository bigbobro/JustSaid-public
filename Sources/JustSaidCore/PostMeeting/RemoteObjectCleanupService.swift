import Foundation
import os

struct RemoteObjectCleanupResult: Sendable {
  let deletedCount: Int
  let failures: [(StoredObject, String)]
}

/// Owns the remote-object deletion side effect for the post-meeting orchestrator. The policy is
/// deliberately narrow: one retry for the user-visible cleanup stage, and best-effort deletion for
/// failure unwinding. It does not own pipeline state or meeting metadata.
struct RemoteObjectCleanupService: Sendable {
  private static let logger = Logger(
    subsystem: "com.justsaid.app",
    category: "post-meeting-storage"
  )

  let storage: any StorageProvider

  func deleteWithSingleRetry(_ objects: [StoredObject]) async -> RemoteObjectCleanupResult {
    var deletedCount = 0
    var failures: [(StoredObject, String)] = []
    for object in objects {
      let startedAt = Date()
      do {
        try await storage.delete(object)
        deletedCount += 1
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
        Self.logger.notice(
          "delete 完成 key=\(object.identifier, privacy: .public) 耗时=\(elapsed, privacy: .public)"
        )
      } catch {
        do {
          try await storage.delete(object)
          deletedCount += 1
          Self.logger.notice("delete 重试成功 key=\(object.identifier, privacy: .public)")
        } catch {
          Self.logger.error(
            "delete 失败 key=\(object.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
          )
          failures.append((object, error.localizedDescription))
        }
      }
    }
    return RemoteObjectCleanupResult(deletedCount: deletedCount, failures: failures)
  }

  func deleteBestEffort(_ objects: [StoredObject]) async {
    for object in objects {
      try? await storage.delete(object)
    }
  }
}
