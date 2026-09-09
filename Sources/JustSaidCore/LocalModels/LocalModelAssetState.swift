import Foundation

public enum LocalModelAssetStatus: Equatable, Sendable {
  case checking
  case ready(revision: String, validatedFiles: [String])
  case missing(missingAssetIDs: [String])
  case updateRequired(installedRevision: String, targetRevision: String)
  case damaged(reason: String)
  case configurationFailed(reason: String)
}

public enum LocalModelPreparationPhase: Equatable, Sendable {
  case preflightingSpace
  case downloading(assetID: String, received: Int64, total: Int64?)
  case verifyingArchive(assetID: String)
  case inspectingArchive(assetID: String)
  case extracting(assetID: String)
  case verifyingInstalledFiles(assetID: String)
  case installing(assetID: String)
}

public enum LocalModelPreparationState: Equatable, Sendable {
  case idle
  case running(capabilityID: String, phase: LocalModelPreparationPhase)
  case failed(capabilityID: String, stage: String, message: String, retryable: Bool)
}

public struct LocalModelCapabilitySnapshot: Equatable, Sendable, Identifiable {
  public let id: String
  public let displayName: String
  public let summary: String
  public let required: Bool
  public let status: LocalModelAssetStatus
  public let downloadBytes: Int64
  public let installedBytes: Int64
  public let missingDownloadBytes: Int64
  public let missingInstalledBytes: Int64
  public let missingAssetIDs: [String]

  public var isReady: Bool {
    if case .ready = status { return true }
    return false
  }
}

public enum LocalModelStartGateDecision: Equatable, Sendable {
  case ready
  case systemManaged
  case waitForLocalCheck
  case showPreparation(capabilityID: String)
  case configurationFailed(reason: String)
}

public struct LocalModelDownloadRequest: Sendable {
  public let url: URL
  public let destination: URL
  public let expectedBytes: Int64
}

public protocol ModelAssetDownloadTransport: Sendable {
  func download(
    _ request: LocalModelDownloadRequest,
    progress: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws -> URL
}

public protocol VolumeCapacityProviding: Sendable {
  func availableBytes(at url: URL) throws -> Int64
}

public enum LocalModelPrepareError: Error, Equatable, Sendable {
  case configurationFailed(String)
  case insufficientSpace(needed: Int64, available: Int64)
  case busy
  case cancelled
  case downloadFailed(String)
  case verificationFailed(String)
  case archiveFailed(String)
  case installFailed(String)
  case unsafePath(String)

  public var stage: String {
    switch self {
    case .configurationFailed: return "configuration"
    case .insufficientSpace: return "preflight"
    case .busy: return "busy"
    case .cancelled: return "cancelled"
    case .downloadFailed: return "download"
    case .verificationFailed: return "verify"
    case .archiveFailed: return "archive"
    case .installFailed: return "install"
    case .unsafePath: return "safety"
    }
  }

  public var retryable: Bool {
    switch self {
    case .configurationFailed, .unsafePath:
      return false
    case .insufficientSpace, .busy, .cancelled, .downloadFailed, .verificationFailed,
      .archiveFailed, .installFailed:
      return true
    }
  }

  public var userMessage: String {
    switch self {
    case .configurationFailed:
      return "应用缺少可用的模型清单，请重装 JustSaid。"
    case .insufficientSpace(let needed, let available):
      return
        "磁盘空间不足：还需要约 \(LocalModelByteDisplay.megabytes(needed))，当前可用约 \(LocalModelByteDisplay.megabytes(available))。"
    case .busy:
      return "已有模型安装作业正在进行，请等待完成后再试。"
    case .cancelled:
      return "已取消本次下载，现有模型未被改动。"
    case .downloadFailed:
      return "模型下载失败，请检查网络后重试。现有模型未被改动。"
    case .verificationFailed:
      return "下载的文件与锁定清单不一致，现有模型未被改动。"
    case .archiveFailed:
      return "压缩包内容不安全或与清单不符，现有模型未被改动。"
    case .installFailed:
      return "无法完成安装，已保留原来的模型。"
    case .unsafePath:
      return "安装路径不安全，已停止写入。"
    }
  }
}

struct LocalModelFileFingerprint: Equatable, Sendable {
  var resourceID: String
  var size: Int64
  var mtimeSec: Int64
  var mtimeNsec: Int64
}

struct LocalModelReceiptAsset: Codable, Equatable, Sendable {
  var revision: String
  var files: [LocalModelReceiptFile]
}

struct LocalModelReceiptFile: Codable, Equatable, Sendable {
  var path: String
  var bytes: Int64
  var sha256: String
}

struct LocalModelReceipt: Codable, Equatable, Sendable {
  var catalogRevision: String
  var assets: [String: LocalModelReceiptAsset]
}

struct LocalModelTransactionJournal: Codable, Equatable, Sendable {
  var operationID: String
  var assetID: String
  var capabilityID: String
  var phase: String
  var targetRelativePath: String
  var stagingRelativePath: String
  var backupRelativePath: String?
  var quarantineRelativePath: String?
  var catalogRevision: String
  var assetRevision: String
}

struct LocalModelAssetInspection: Equatable, Sendable {
  enum Outcome: Equatable, Sendable {
    case missing
    case ready
    case updateRequired(installedRevision: String)
    case damaged(String)
  }

  var assetID: String
  var outcome: Outcome
  var fingerprints: [String: LocalModelFileFingerprint]
}

public struct FileSystemVolumeCapacityProvider: VolumeCapacityProviding, Sendable {
  public init() {}

  public func availableBytes(at url: URL) throws -> Int64 {
    var probe = url
    let fileManager = FileManager.default
    while !fileManager.fileExists(atPath: probe.path) {
      let parent = probe.deletingLastPathComponent()
      if parent.path == probe.path { break }
      probe = parent
    }
    let values = try probe.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
    ])
    if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
      return important
    }
    if let available = values.volumeAvailableCapacity {
      return Int64(available)
    }
    throw LocalModelPrepareError.installFailed("无法读取磁盘剩余空间")
  }
}

public struct FixedVolumeCapacityProvider: VolumeCapacityProviding, Sendable {
  public var available: Int64

  public init(available: Int64) {
    self.available = available
  }

  public func availableBytes(at url: URL) throws -> Int64 {
    _ = url
    return available
  }
}
