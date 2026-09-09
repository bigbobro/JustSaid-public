import CryptoKit
import Darwin
import Foundation
import OSLog

struct LocalModelAssetOperations: Sendable {
  static let receiptFileName = ".justsaid-installations.json"
  static let stagingDirectoryName = ".staging"
  static let transactionDirectoryName = ".transactions"
  static let quarantineDirectoryName = ".quarantine"
  static let safetyMarginBytes: Int64 = 64 * 1024 * 1024
  static let hashChunkSize = 1024 * 1024

  let modelsRoot: URL

  init(modelsRoot: URL, fileManager _: FileManager = .default) {
    self.modelsRoot = modelsRoot.standardizedFileURL
  }

  var receiptURL: URL {
    modelsRoot.appendingPathComponent(Self.receiptFileName)
  }

  var stagingRoot: URL {
    modelsRoot.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
  }

  var transactionRoot: URL {
    modelsRoot.appendingPathComponent(Self.transactionDirectoryName, isDirectory: true)
  }

  var quarantineRoot: URL {
    modelsRoot.appendingPathComponent(Self.quarantineDirectoryName, isDirectory: true)
  }

  func relativePath(for url: URL) -> String {
    LocalModelFileIO.relativePath(from: modelsRoot, to: url) ?? url.lastPathComponent
  }

  func inspect(
    asset: LocalModelAsset,
    receipt: LocalModelReceipt?,
    cachedFingerprints: [String: LocalModelFileFingerprint]
  ) throws -> LocalModelAssetInspection {
    var fingerprints: [String: LocalModelFileFingerprint] = [:]
    var missing: [String] = []
    var mismatched: [String] = []
    var matchedCurrent = true

    for file in asset.installedFiles {
      let url = modelsRoot.appendingPathComponent(file.path)
      do {
        try LocalModelFileIO.requireUnlinkedPath(from: modelsRoot, to: url)
      } catch {
        return LocalModelAssetInspection(
          assetID: asset.id,
          outcome: .damaged("模型路径不安全"),
          fingerprints: fingerprints
        )
      }
      let metadata: LocalModelFileIO.Metadata?
      do {
        metadata = try LocalModelFileIO.metadataIfExists(at: url)
      } catch {
        return LocalModelAssetInspection(
          assetID: asset.id,
          outcome: .damaged("模型路径不安全"),
          fingerprints: fingerprints
        )
      }
      guard let metadata else {
        matchedCurrent = false
        missing.append(file.path)
        continue
      }
      if metadata.fingerprint.size != file.bytes {
        matchedCurrent = false
        mismatched.append(file.path)
        continue
      }
      if let cached = cachedFingerprints[file.path], cached == metadata.fingerprint {
        // 缓存里只放校验通过的指纹,命中即可跳过重复 hash。
        fingerprints[file.path] = metadata.fingerprint
        continue
      }
      let digest: String
      do {
        digest = try LocalModelFileIO.sha256(of: url)
      } catch {
        // 单个文件读不出来只判这个 asset 损坏,不能把整次本地检查打挂。
        return LocalModelAssetInspection(
          assetID: asset.id,
          outcome: .damaged("模型文件无法校验"),
          fingerprints: [:]
        )
      }
      if digest != file.sha256 {
        matchedCurrent = false
        mismatched.append(file.path)
        continue
      }
      fingerprints[file.path] = metadata.fingerprint
    }

    if matchedCurrent && missing.isEmpty && mismatched.isEmpty {
      return LocalModelAssetInspection(
        assetID: asset.id,
        outcome: .ready,
        fingerprints: fingerprints
      )
    }

    if let receiptAsset = receipt?.assets[asset.id] {
      let receiptMatch = receiptStillMatches(receiptAsset)
      if receiptMatch && receiptAsset.revision != asset.revision {
        return LocalModelAssetInspection(
          assetID: asset.id,
          outcome: .updateRequired(installedRevision: receiptAsset.revision),
          fingerprints: fingerprints
        )
      }
    }

    if missing.count == asset.installedFiles.count {
      return LocalModelAssetInspection(
        assetID: asset.id,
        outcome: .missing,
        fingerprints: [:]
      )
    }

    return LocalModelAssetInspection(
      assetID: asset.id,
      outcome: .damaged("模型文件与锁定清单不一致"),
      fingerprints: fingerprints
    )
  }

  /// receipt 条目里列出的每个文件当前是否仍与该条目逐字节一致。
  /// 只有一致才算"这份目录确实是 JustSaid 装的",才允许备份后删除。
  func receiptStillMatches(_ receiptAsset: LocalModelReceiptAsset?) -> Bool {
    guard let receiptAsset else { return false }
    return receiptAsset.files.allSatisfy { listed in
      guard
        let actual = try? LocalModelFileIO.sha256(
          of: modelsRoot.appendingPathComponent(listed.path)
        )
      else {
        return false
      }
      return actual == listed.sha256
    }
  }

  func loadReceipt() throws -> LocalModelReceipt? {
    guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
    try LocalModelFileIO.requireRegularFile(at: receiptURL)
    let data = try Data(contentsOf: receiptURL)
    return try JSONDecoder().decode(LocalModelReceipt.self, from: data)
  }

  func writeReceipt(_ receipt: LocalModelReceipt) throws {
    try ensureModelsRoot()
    let data = try JSONEncoder().encode(receipt)
    let temporary = receiptURL.appendingPathExtension("tmp")
    try data.write(to: temporary, options: [.atomic])
    if FileManager.default.fileExists(atPath: receiptURL.path) {
      _ = try FileManager.default.replaceItemAt(receiptURL, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: receiptURL)
    }
  }

  func ensureModelsRoot() throws {
    try LocalModelFileIO.requireWritableDirectoryChain(
      root: modelsRoot,
      fileManager: FileManager.default
    )
  }

  func requiredBytes(for assets: [LocalModelAsset]) throws -> Int64 {
    var total: Int64 = 0
    for asset in assets {
      total = try adding(total, asset.downloadBytes)
      total = try adding(total, asset.installedBytes)
    }
    return try adding(total, Self.safetyMarginBytes)
  }

  func reconcileJournals() throws {
    guard FileManager.default.fileExists(atPath: transactionRoot.path) else { return }
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: transactionRoot,
        includingPropertiesForKeys: nil
      )) ?? []
    for url in contents where url.pathExtension == "json" {
      // 单份 journal 读不动只跳过它,不让整次本地检查失败(否则所有能力会被误报损坏)。
      try? reconcile(journalURL: url)
    }
  }

  private func reconcile(journalURL: URL) throws {
    let data = try Data(contentsOf: journalURL)
    let journal = try JSONDecoder().decode(LocalModelTransactionJournal.self, from: data)
    let target = modelsRoot.appendingPathComponent(journal.targetRelativePath, isDirectory: true)
    let staging = modelsRoot.appendingPathComponent(
      journal.stagingRelativePath,
      isDirectory: true
    )
    // 已 committed:新目录已经 rename 就位并复验过,只欠清理。这里若照旧恢复 backup,
    // 反而会把刚装好的模型换回旧的那份。
    let committed = journal.phase == "committed"
    if let backup = journal.backupRelativePath {
      let backupURL = modelsRoot.appendingPathComponent(backup, isDirectory: true)
      if FileManager.default.fileExists(atPath: backupURL.path) {
        if committed {
          try? FileManager.default.removeItem(at: backupURL)
        } else {
          if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
          }
          try FileManager.default.moveItem(at: backupURL, to: target)
        }
      }
    } else if !committed, let quarantine = journal.quarantineRelativePath {
      // 未提交就中断:被隔离的原目录必须搬回原位,不能只留在 .quarantine 里。
      let quarantineURL = modelsRoot.appendingPathComponent(quarantine, isDirectory: true)
      if FileManager.default.fileExists(atPath: quarantineURL.path),
        !FileManager.default.fileExists(atPath: target.path)
      {
        try FileManager.default.moveItem(at: quarantineURL, to: target)
      }
    }
    if FileManager.default.fileExists(atPath: staging.path) {
      try? FileManager.default.removeItem(at: staging)
    }
    try? FileManager.default.removeItem(at: journalURL)
  }

  func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    if overflow {
      throw LocalModelPrepareError.installFailed("字节合计溢出")
    }
    return result
  }
}

enum LocalModelFileIO {
  struct Metadata {
    var fingerprint: LocalModelFileFingerprint
    var isDirectory: Bool
    var isRegular: Bool
    var linkCount: UInt16
  }

  static func metadataIfExists(at url: URL) throws -> Metadata? {
    var status = stat()
    if lstat(url.path, &status) != 0 {
      if errno == ENOENT { return nil }
      throw LocalModelPrepareError.unsafePath("无法读取文件状态")
    }
    return try metadata(from: status)
  }

  static func metadata(at url: URL) throws -> Metadata {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
      throw LocalModelPrepareError.unsafePath("无法读取文件状态")
    }
    return try metadata(from: status)
  }

  private static func metadata(from status: stat) throws -> Metadata {
    let type = status.st_mode & S_IFMT
    if type == S_IFLNK {
      throw LocalModelPrepareError.unsafePath("路径是符号链接")
    }
    let fingerprint = LocalModelFileFingerprint(
      resourceID: "\(status.st_dev):\(status.st_ino)",
      size: Int64(status.st_size),
      mtimeSec: Int64(status.st_mtimespec.tv_sec),
      mtimeNsec: Int64(status.st_mtimespec.tv_nsec)
    )
    return Metadata(
      fingerprint: fingerprint,
      isDirectory: type == S_IFDIR,
      isRegular: type == S_IFREG,
      linkCount: status.st_nlink
    )
  }

  static func requireRegularFile(at url: URL) throws {
    let info = try metadata(at: url)
    guard info.isRegular else {
      throw LocalModelPrepareError.unsafePath("不是普通文件")
    }
    if info.linkCount > 1 {
      throw LocalModelPrepareError.unsafePath("拒绝硬链接")
    }
  }

  static func requireDirectory(at url: URL) throws {
    let info = try metadata(at: url)
    guard info.isDirectory else {
      throw LocalModelPrepareError.unsafePath("不是目录")
    }
  }

  static func sha256(of url: URL) throws -> String {
    try requireRegularFile(at: url)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: LocalModelAssetOperations.hashChunkSize)
      guard let chunk, !chunk.isEmpty else { break }
      hasher.update(data: chunk)
    }
    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func verifyFile(_ file: LocalModelInstalledFile, at url: URL) throws {
    try requireRegularFile(at: url)
    let info = try metadata(at: url)
    guard info.fingerprint.size == file.bytes else {
      throw LocalModelPrepareError.verificationFailed("文件大小不一致")
    }
    let digest = try sha256(of: url)
    guard digest == file.sha256 else {
      throw LocalModelPrepareError.verificationFailed("文件摘要不一致")
    }
  }

  static func requireWritableDirectoryChain(root: URL, fileManager: FileManager) throws {
    var missing: [URL] = []
    var cursor = root
    while !fileManager.fileExists(atPath: cursor.path) {
      missing.append(cursor)
      let parent = cursor.deletingLastPathComponent()
      if parent.path == cursor.path {
        throw LocalModelPrepareError.unsafePath("无法创建模型目录")
      }
      cursor = parent
    }
    try requireDirectory(at: cursor)
    for url in missing.reversed() {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
      try requireDirectory(at: url)
    }
  }

  static func ensureParentDirectory(of url: URL, root: URL, fileManager: FileManager) throws {
    let parent = url.deletingLastPathComponent()
    try requireInside(parent, root: root)
    if fileManager.fileExists(atPath: parent.path) {
      try requireDirectory(at: parent)
      return
    }
    try requireWritableDirectoryChain(root: parent, fileManager: fileManager)
  }

  static func requireUnlinkedPath(from root: URL, to url: URL) throws {
    try requireInside(url, root: root)
    var cursor = root.standardizedFileURL
    _ = try metadataIfExists(at: cursor)
    let relative = String(
      url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)
    )
    let parts = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    for part in parts {
      cursor.appendPathComponent(part)
      _ = try metadataIfExists(at: cursor)
    }
  }

  static func resolvedPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
  }

  static func relativePath(from root: URL, to url: URL) -> String? {
    let rootPath = resolvedPath(root)
    let full = resolvedPath(url)
    if full == rootPath { return "" }
    guard full.hasPrefix(rootPath + "/") else { return nil }
    return String(full.dropFirst(rootPath.count + 1))
  }

  static func requireInside(_ url: URL, root: URL) throws {
    guard relativePath(from: root, to: url) != nil else {
      throw LocalModelPrepareError.unsafePath("路径越出模型根目录")
    }
  }
}

enum LocalModelArchive {
  static let tarExecutable = "/usr/bin/tar"

  static func listMembers(archive: URL, archiveRoot: String) throws -> Set<String> {
    let result = try runTar(arguments: ["-tjf", archive.path])
    guard result.status == 0 else {
      throw LocalModelPrepareError.archiveFailed("无法读取压缩包目录")
    }
    let text = String(data: result.stdout, encoding: .utf8) ?? ""
    var members = Set<String>()
    let prefix = archiveRoot + "/"
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty { continue }
      if line.hasPrefix("./") {
        line.removeFirst(2)
      }
      if line.hasSuffix("/") { continue }
      if line.hasPrefix("/") || line.contains("..") {
        throw LocalModelPrepareError.archiveFailed("压缩包包含越界路径")
      }
      guard line == archiveRoot || line.hasPrefix(prefix) else {
        throw LocalModelPrepareError.archiveFailed("压缩包根目录与清单不符")
      }
      if line == archiveRoot { continue }
      let relative = String(line.dropFirst(prefix.count))
      if relative.isEmpty { continue }
      _ = try LocalModelPathSecurity.requireRelativeMember(relative)
      if members.contains(relative) {
        throw LocalModelPrepareError.archiveFailed("压缩包包含重复成员")
      }
      members.insert(relative)
    }
    return members
  }

  static func extract(
    archive: URL,
    archiveRoot: String,
    members: [String],
    to extractRoot: URL
  ) throws {
    try FileManager.default.createDirectory(
      at: extractRoot,
      withIntermediateDirectories: true
    )
    let fullMembers = members.map { archiveRoot + "/" + $0 }
    var arguments = ["-xjf", archive.path, "-C", extractRoot.path]
    arguments.append(contentsOf: fullMembers)
    let result = try runTar(arguments: arguments)
    guard result.status == 0 else {
      throw LocalModelPrepareError.archiveFailed("解包失败")
    }
  }

  private static func runTar(arguments: [String]) throws -> (
    stdout: Data, stderr: Data, status: Int32
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tarExecutable)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["COPYFILE_DISABLE"] = "1"
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      throw LocalModelPrepareError.archiveFailed("无法启动 tar")
    }
    let outHandle = stdout.fileHandleForReading
    let errHandle = stderr.fileHandleForReading
    // 先排空管道再等退出:tar 输出超过管道缓冲时会阻塞在 write,
    // 先 waitUntilExit 就是死等。
    let out = outHandle.readDataToEndOfFile()
    let err = errHandle.readDataToEndOfFile()
    process.waitUntilExit()
    _ = boundedDiagnostic(err)
    return (out, err, process.terminationStatus)
  }

  private static func boundedDiagnostic(_ data: Data) -> String {
    let raw = String(data: data, encoding: .utf8) ?? ""
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let trimmed = raw.replacingOccurrences(of: home, with: "")
    return String(trimmed.prefix(512))
  }
}

struct LocalModelInstallEngine: Sendable {
  let catalog: LocalModelAssetCatalog
  let modelsRoot: URL
  let transport: any ModelAssetDownloadTransport
  let capacity: any VolumeCapacityProviding
  let operations: LocalModelAssetOperations
  private let logger = Logger(subsystem: "com.justsaid.app", category: "LocalModelAssets")

  init(
    catalog: LocalModelAssetCatalog,
    modelsRoot: URL,
    transport: any ModelAssetDownloadTransport,
    capacity: any VolumeCapacityProviding
  ) {
    self.catalog = catalog
    self.modelsRoot = modelsRoot
    self.transport = transport
    self.capacity = capacity
    self.operations = LocalModelAssetOperations(modelsRoot: modelsRoot)
  }

  func refresh(
    cachedFingerprints: [String: LocalModelFileFingerprint]
  ) throws -> (
    snapshots: [String: LocalModelCapabilitySnapshot],
    fingerprints: [String: LocalModelFileFingerprint]
  ) {
    try operations.reconcileJournals()
    let receipt = try? operations.loadReceipt()
    var fingerprints = cachedFingerprints
    var assetOutcomes: [String: LocalModelAssetInspection] = [:]
    for asset in catalog.assets {
      let inspection = try operations.inspect(
        asset: asset,
        receipt: receipt,
        cachedFingerprints: cachedFingerprints
      )
      assetOutcomes[asset.id] = inspection
      fingerprints.merge(inspection.fingerprints) { _, new in new }
    }

    var nextReceipt =
      receipt ?? LocalModelReceipt(catalogRevision: catalog.catalogRevision, assets: [:])
    nextReceipt.catalogRevision = catalog.catalogRevision
    var mutatedReceipt = false

    var snapshots: [String: LocalModelCapabilitySnapshot] = [:]
    for capability in catalog.capabilities {
      let assets = catalog.assets(forCapabilityID: capability.id)
      var missing: [String] = []
      var damaged: String?
      var updateFrom: String?
      var readyFiles: [String] = []
      var missingDownload: Int64 = 0
      var missingInstalled: Int64 = 0

      for asset in assets {
        guard let inspection = assetOutcomes[asset.id] else { continue }
        switch inspection.outcome {
        case .ready:
          readyFiles.append(contentsOf: asset.installedFiles.map(\.path))
          if nextReceipt.assets[asset.id]?.revision != asset.revision {
            nextReceipt.assets[asset.id] = LocalModelReceiptAsset(
              revision: asset.revision,
              files: asset.installedFiles.map {
                LocalModelReceiptFile(path: $0.path, bytes: $0.bytes, sha256: $0.sha256)
              }
            )
            mutatedReceipt = true
          }
        case .missing:
          missing.append(asset.id)
          missingDownload += asset.downloadBytes
          missingInstalled += asset.installedBytes
        case .updateRequired(let installedRevision):
          updateFrom = installedRevision
          // 需要更新/损坏的 asset 同样要重下,必须计进"还需下载"与待修复清单,
          // 否则 UI 显示还需 0 MB,修复又会把整个能力的资产全部重下一遍。
          missing.append(asset.id)
          missingDownload += asset.downloadBytes
          missingInstalled += asset.installedBytes
        case .damaged(let reason):
          damaged = reason
          missing.append(asset.id)
          missingDownload += asset.downloadBytes
          missingInstalled += asset.installedBytes
        }
      }

      let status: LocalModelAssetStatus
      if let damaged {
        status = .damaged(reason: damaged)
      } else if let updateFrom {
        status = .updateRequired(
          installedRevision: updateFrom,
          targetRevision: catalog.catalogRevision
        )
      } else if !missing.isEmpty {
        status = .missing(missingAssetIDs: missing)
      } else {
        status = .ready(
          revision: catalog.catalogRevision,
          validatedFiles: readyFiles.sorted()
        )
      }

      snapshots[capability.id] = LocalModelCapabilitySnapshot(
        id: capability.id,
        displayName: capability.displayName,
        summary: capability.summary,
        required: capability.required,
        status: status,
        downloadBytes: catalog.downloadBytes(forCapabilityID: capability.id),
        installedBytes: catalog.installedBytes(forCapabilityID: capability.id),
        missingDownloadBytes: missingDownload,
        missingInstalledBytes: missingInstalled,
        missingAssetIDs: missing
      )
    }

    if mutatedReceipt {
      try? operations.writeReceipt(nextReceipt)
    }
    return (snapshots, fingerprints)
  }

  func prepare(
    capabilityID: String,
    progress: @escaping @Sendable (LocalModelPreparationPhase) -> Void
  ) async throws {
    try Task.checkCancellation()
    guard let capability = catalog.capabilitiesByID[capabilityID] else {
      throw LocalModelPrepareError.configurationFailed("未知模型能力")
    }
    let (current, _) = try refresh(cachedFingerprints: [:])
    guard let snapshot = current[capabilityID] else {
      throw LocalModelPrepareError.configurationFailed("未知模型能力")
    }
    let missingIDs: [String]
    switch snapshot.status {
    case .ready:
      return
    case .missing(let ids):
      missingIDs = ids
    case .updateRequired, .damaged:
      // 只重装真正不合格的 asset:Silero(643 KB)坏掉不该连带重下 Qwen 的 879 MB。
      missingIDs = snapshot.missingAssetIDs.isEmpty ? capability.assetIDs : snapshot.missingAssetIDs
    case .checking, .configurationFailed:
      throw LocalModelPrepareError.configurationFailed("模型清单不可用")
    }

    let assets = missingIDs.compactMap { catalog.assetsByID[$0] }
    guard !assets.isEmpty else { return }

    progress(.preflightingSpace)
    try operations.ensureModelsRoot()
    let needed = try operations.requiredBytes(for: assets)
    let available = try capacity.availableBytes(at: modelsRoot)
    if available < needed {
      throw LocalModelPrepareError.insufficientSpace(needed: needed, available: available)
    }

    for asset in assets {
      try Task.checkCancellation()
      try await install(asset: asset, capabilityID: capabilityID, progress: progress)
    }
  }

  private func install(
    asset: LocalModelAsset,
    capabilityID: String,
    progress: @escaping @Sendable (LocalModelPreparationPhase) -> Void
  ) async throws {
    let operationID = UUID().uuidString
    let staging = operations.stagingRoot.appendingPathComponent(operationID, isDirectory: true)
    let downloadDir = staging.appendingPathComponent("download", isDirectory: true)
    let extractDir = staging.appendingPathComponent("extract", isDirectory: true)
    let finalDir = staging.appendingPathComponent("final", isDirectory: true)
    let target = modelsRoot.appendingPathComponent(asset.directoryName, isDirectory: true)
    var journal = LocalModelTransactionJournal(
      operationID: operationID,
      assetID: asset.id,
      capabilityID: capabilityID,
      phase: "preparing",
      targetRelativePath: asset.directoryName,
      stagingRelativePath: operations.relativePath(for: staging),
      backupRelativePath: nil,
      quarantineRelativePath: nil,
      catalogRevision: catalog.catalogRevision,
      assetRevision: asset.revision
    )

    try operations.ensureModelsRoot()
    try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
    try writeJournal(journal)

    do {
      try Task.checkCancellation()
      let downloadURL = downloadDir.appendingPathComponent(asset.id)
      progress(
        .downloading(assetID: asset.id, received: 0, total: asset.downloadBytes)
      )
      let downloaded = try await transport.download(
        LocalModelDownloadRequest(
          url: asset.url,
          destination: downloadURL,
          expectedBytes: asset.downloadBytes
        )
      ) { received, total in
        progress(.downloading(assetID: asset.id, received: received, total: total))
      }
      try Task.checkCancellation()
      progress(.verifyingArchive(assetID: asset.id))
      try LocalModelFileIO.requireRegularFile(at: downloaded)
      let downloadInfo = try LocalModelFileIO.metadata(at: downloaded)
      guard downloadInfo.fingerprint.size == asset.downloadBytes else {
        throw LocalModelPrepareError.verificationFailed("下载大小不一致")
      }
      let downloadSHA = try LocalModelFileIO.sha256(of: downloaded)
      guard downloadSHA == asset.downloadSHA256 else {
        throw LocalModelPrepareError.verificationFailed("下载摘要不一致")
      }

      switch asset.kind {
      case .archive:
        progress(.inspectingArchive(assetID: asset.id))
        guard let archiveRoot = asset.archiveRoot else {
          throw LocalModelPrepareError.archiveFailed("缺少 archive 根目录")
        }
        let members = try LocalModelArchive.listMembers(
          archive: downloaded,
          archiveRoot: archiveRoot
        )
        let allowed = Set(asset.allowedMembers)
        guard members == allowed else {
          throw LocalModelPrepareError.archiveFailed(
            "压缩包成员与锁定清单不一致"
          )
        }
        progress(.extracting(assetID: asset.id))
        let extractMembers = asset.extract.map(\.member)
        try Task.checkCancellation()
        try LocalModelArchive.extract(
          archive: downloaded,
          archiveRoot: archiveRoot,
          members: extractMembers,
          to: extractDir
        )
        try Task.checkCancellation()
        try assembleFinalTree(
          asset: asset,
          from: extractDir.appendingPathComponent(archiveRoot, isDirectory: true),
          into: finalDir
        )
      case .file:
        progress(.extracting(assetID: asset.id))
        guard let mapping = asset.extract.first else {
          throw LocalModelPrepareError.archiveFailed("缺少安装映射")
        }
        let destination = finalDir.appendingPathComponent(mapping.installPath)
        try LocalModelFileIO.ensureParentDirectory(
          of: destination,
          root: finalDir,
          fileManager: FileManager.default
        )
        // 已按固定 SHA 校验过的下载件直接改名进 final,不再整文件读进内存重写一遍。
        try FileManager.default.moveItem(at: downloaded, to: destination)
      }

      progress(.verifyingInstalledFiles(assetID: asset.id))
      try Task.checkCancellation()
      try verifyFinalTree(asset: asset, at: finalDir)

      // 最后一个可取消点:进了 commit 就必须把 rename + 复验 + receipt 做完,
      // 中途放手会留下"旧目录已搬走、新目录还没就位"的中间态。
      try Task.checkCancellation()
      progress(.installing(assetID: asset.id))
      try commitInstall(
        asset: asset,
        finalDir: finalDir,
        target: target,
        staging: staging,
        journal: &journal
      )
      try FileManager.default.removeItem(at: staging)
      try removeJournal(operationID)
      logger.notice("installed asset=\(asset.id, privacy: .public)")
    } catch is CancellationError {
      try? rollback(journal: journal, target: target)
      try? FileManager.default.removeItem(at: staging)
      try? removeJournal(operationID)
      throw LocalModelPrepareError.cancelled
    } catch let error as LocalModelPrepareError {
      try? rollback(journal: journal, target: target)
      try? FileManager.default.removeItem(at: staging)
      try? removeJournal(operationID)
      throw error
    } catch let error as ModelAssetDownloadError {
      try? rollback(journal: journal, target: target)
      try? FileManager.default.removeItem(at: staging)
      try? removeJournal(operationID)
      throw error.asPrepareError
    } catch {
      try? rollback(journal: journal, target: target)
      try? FileManager.default.removeItem(at: staging)
      try? removeJournal(operationID)
      throw LocalModelPrepareError.installFailed("安装失败")
    }
  }

  private func assembleFinalTree(asset: LocalModelAsset, from sourceRoot: URL, into finalDir: URL)
    throws
  {
    for mapping in asset.extract {
      let source = sourceRoot.appendingPathComponent(mapping.member)
      let destination = finalDir.appendingPathComponent(mapping.installPath)
      try LocalModelFileIO.requireRegularFile(at: source)
      try LocalModelFileIO.ensureParentDirectory(
        of: destination,
        root: finalDir,
        fileManager: FileManager.default
      )
      // 同一 staging 内改名而不是整文件重拷:decoder 有 755 MB,拷一份既吃内存也吃磁盘,
      // 还会让空间预检算少一整份安装体积。
      try FileManager.default.moveItem(at: source, to: destination)
    }
  }

  private func verifyFinalTree(asset: LocalModelAsset, at finalDir: URL) throws {
    var expected = Set(asset.installedFiles.map(\.path))
    for file in asset.installedFiles {
      let url = finalDir.appendingPathComponent(file.path)
      try LocalModelFileIO.requireInside(url, root: finalDir)
      try LocalModelFileIO.verifyFile(file, at: url)
    }
    try walk(finalDir, root: finalDir) { url in
      let relative = LocalModelFileIO.relativePath(from: finalDir, to: url) ?? ""
      if relative.isEmpty { return }
      let info = try LocalModelFileIO.metadata(at: url)
      if info.isDirectory { return }
      guard info.isRegular else {
        throw LocalModelPrepareError.archiveFailed("解包结果含非普通文件")
      }
      if !expected.contains(relative) {
        throw LocalModelPrepareError.archiveFailed("解包结果含未锁定文件")
      }
      expected.remove(relative)
    }
    if !expected.isEmpty {
      throw LocalModelPrepareError.verificationFailed("解包结果缺少锁定文件")
    }
  }

  private func walk(_ directory: URL, root: URL, visit: (URL) throws -> Void) throws {
    try visit(directory)
    let children = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: []
    )
    for child in children {
      try LocalModelFileIO.requireInside(child, root: root)
      let info = try LocalModelFileIO.metadata(at: child)
      if info.isDirectory {
        try walk(child, root: root, visit: visit)
      } else {
        try visit(child)
      }
    }
  }

  private func commitInstall(
    asset: LocalModelAsset,
    finalDir: URL,
    target: URL,
    staging: URL,
    journal: inout LocalModelTransactionJournal
  ) throws {
    let stagedTarget = finalDir.appendingPathComponent(asset.directoryName, isDirectory: true)
    try LocalModelFileIO.requireDirectory(at: stagedTarget)
    try operations.ensureModelsRoot()

    if FileManager.default.fileExists(atPath: target.path) {
      let info = try LocalModelFileIO.metadata(at: target)
      if info.isDirectory {
        let receipt = try? operations.loadReceipt()
        // 认领旧目录必须"receipt 有条目 + 实际字节仍与该条目一致"。只看条目存在,
        // 会把用户自己放进来的同名内容当成我们装的,安装成功后连备份一起删掉。
        let owned = operations.receiptStillMatches(receipt?.assets[asset.id])
        if owned {
          let backup = staging.appendingPathComponent("backup", isDirectory: true)
            .appendingPathComponent(asset.directoryName, isDirectory: true)
          try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try FileManager.default.moveItem(at: target, to: backup)
          journal.backupRelativePath = operations.relativePath(for: backup)
          journal.phase = "backed-up"
          try writeJournal(journal)
        } else {
          try FileManager.default.createDirectory(
            at: operations.quarantineRoot,
            withIntermediateDirectories: true
          )
          let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
            of: ":",
            with: ""
          )
          let quarantine = operations.quarantineRoot.appendingPathComponent(
            "\(asset.id)-\(stamp)",
            isDirectory: true
          )
          try FileManager.default.moveItem(at: target, to: quarantine)
          journal.quarantineRelativePath = operations.relativePath(for: quarantine)
          journal.phase = "quarantined"
          try writeJournal(journal)
        }
      } else {
        throw LocalModelPrepareError.unsafePath("安装目标不是目录")
      }
    }

    journal.phase = "installing"
    try writeJournal(journal)
    try FileManager.default.moveItem(at: stagedTarget, to: target)
    for file in asset.installedFiles {
      try LocalModelFileIO.verifyFile(
        file,
        at: modelsRoot.appendingPathComponent(file.path)
      )
    }

    var receipt =
      (try? operations.loadReceipt())
      ?? LocalModelReceipt(catalogRevision: catalog.catalogRevision, assets: [:])
    receipt.catalogRevision = catalog.catalogRevision
    receipt.assets[asset.id] = LocalModelReceiptAsset(
      revision: asset.revision,
      files: asset.installedFiles.map {
        LocalModelReceiptFile(path: $0.path, bytes: $0.bytes, sha256: $0.sha256)
      }
    )
    try operations.writeReceipt(receipt)
    journal.phase = "committed"
    try writeJournal(journal)

    if let backup = journal.backupRelativePath {
      let backupURL = modelsRoot.appendingPathComponent(backup, isDirectory: true)
      try? FileManager.default.removeItem(at: backupURL)
    }
  }

  private func rollback(journal: LocalModelTransactionJournal, target: URL) throws {
    if let backup = journal.backupRelativePath {
      let backupURL = modelsRoot.appendingPathComponent(backup, isDirectory: true)
      if FileManager.default.fileExists(atPath: backupURL.path) {
        if FileManager.default.fileExists(atPath: target.path) {
          try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: backupURL, to: target)
      }
      return
    }
    // 隔离过原目录但没装成:必须把它搬回原位,否则用户的目录会凭空消失。
    if let quarantine = journal.quarantineRelativePath {
      let quarantineURL = modelsRoot.appendingPathComponent(quarantine, isDirectory: true)
      if FileManager.default.fileExists(atPath: quarantineURL.path) {
        if FileManager.default.fileExists(atPath: target.path) {
          try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: quarantineURL, to: target)
      }
      return
    }
    // 既没备份也没隔离:失败前若已把未复验的新目录 rename 到位,不能留在最终模型目录。
    if journal.phase == "installing", FileManager.default.fileExists(atPath: target.path) {
      try? FileManager.default.removeItem(at: target)
    }
  }

  private func writeJournal(_ journal: LocalModelTransactionJournal) throws {
    try FileManager.default.createDirectory(
      at: operations.transactionRoot,
      withIntermediateDirectories: true
    )
    let url = operations.transactionRoot.appendingPathComponent("\(journal.operationID).json")
    let data = try JSONEncoder().encode(journal)
    try data.write(to: url, options: [.atomic])
  }

  private func removeJournal(_ operationID: String) throws {
    let url = operations.transactionRoot.appendingPathComponent("\(operationID).json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}
