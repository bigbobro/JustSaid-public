import CryptoKit
import Darwin
import Foundation
import OSLog

struct LocalModelAssetOperations: Sendable {
  static let receiptFileName = ".justsaid-installations.json"
  static let stagingDirectoryName = ".staging"
  static let transactionDirectoryName = ".transactions"
  static let quarantineDirectoryName = ".quarantine"
  /// 续传分片目录。不在 `.staging` 之下:失败、取消清理与 reconcile 只删 staging,分片留给下一次。
  static let downloadsDirectoryName = ".downloads"
  static let safetyMarginBytes: Int64 = 64 * 1024 * 1024
  static let hashChunkSize = 1024 * 1024
  /// 这么久没写过的分片不再续:本地检查会删掉它。
  static let partialMaxAge: TimeInterval = 7 * 24 * 60 * 60

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

  var downloadsRoot: URL {
    modelsRoot.appendingPathComponent(Self.downloadsDirectoryName, isDirectory: true)
  }

  /// 资产的续传分片 `.downloads/<资产 ID>-<下载 SHA 前 8 位>.partial`。崩溃重启后要按同一个名字
  /// 找回分片,所以名字只由清单决定,不带作业 ID 或时间。
  func partialURL(for asset: LocalModelAsset) -> URL {
    downloadsRoot.appendingPathComponent("\(asset.id)-\(asset.downloadSHA256.prefix(8)).partial")
  }

  /// 分片里能接着用的字节数:普通文件、不是硬链接、不比清单长才算,否则 0
  /// (transport 会删掉它从头下)。只读,不改盘。
  func resumableBytes(for asset: LocalModelAsset) -> Int64 {
    guard downloadsDirectoryIsReal else { return 0 }
    var info = stat()
    guard lstat(partialURL(for: asset).path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1
    else {
      return 0
    }
    let size = Int64(info.st_size)
    return size <= asset.downloadBytes ? size : 0
  }

  /// 删掉这项资产当前清单版本的分片;没有就算了。符号链接只删链接本身。
  func removePartial(for asset: LocalModelAsset) {
    guard downloadsDirectoryIsReal else { return }
    let url = partialURL(for: asset)
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return }
    try? FileManager.default.removeItem(at: url)
  }

  /// 收掉不会再被续上的分片:名字不是当前清单里任何一项资产的分片名(清单换了 SHA、资产已退役、
  /// 来路不明),不是普通文件,或超过 `partialMaxAge` 没写过。只在没有作业在跑时调用。
  func pruneStalePartials(catalog: LocalModelAssetCatalog, now: Date = Date()) {
    guard downloadsDirectoryIsReal else { return }
    let current = Set(catalog.assets.map { partialURL(for: $0).lastPathComponent })
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: downloadsRoot,
        includingPropertiesForKeys: nil
      )) ?? []
    let oldest = now.timeIntervalSince1970 - Self.partialMaxAge
    for entry in entries {
      var info = stat()
      guard lstat(entry.path, &info) == 0 else { continue }
      let keep =
        current.contains(entry.lastPathComponent)
        && (info.st_mode & S_IFMT) == S_IFREG
        && TimeInterval(info.st_mtimespec.tv_sec) >= oldest
      if !keep {
        try? FileManager.default.removeItem(at: entry)
      }
    }
  }

  /// 取消落在最后一字节之后时,把已下满的整文件改名回分片位置(只改名,不复制),下次 prepare 不联网、
  /// 直接重做整文件校验。按顺序看 `candidates`,第一个是普通文件、不是硬链接、与清单一样长的才搬;
  /// 分片位置已有东西就不动。尽力而为:搬不成就随 staging 删掉,下次从 0 下,与没有这一步时一样。
  func salvageDownload(from candidates: [URL], for asset: LocalModelAsset) {
    let partial = partialURL(for: asset)
    var existing = stat()
    guard lstat(partial.path, &existing) != 0, errno == ENOENT else { return }
    for candidate in candidates {
      guard let info = try? LocalModelFileIO.metadataIfExists(at: candidate), info.isRegular,
        info.linkCount == 1, info.fingerprint.size == asset.downloadBytes
      else { continue }
      do {
        // `.downloads` 不在就建;它若是符号链接,这里抛错,整文件不搬到模型根之外。
        try LocalModelFileIO.requireWritableDirectoryChain(
          root: downloadsRoot, fileManager: FileManager.default)
        try FileManager.default.moveItem(at: candidate, to: partial)
      } catch {
        // 搬不成:整文件留在 staging,随它删掉。
      }
      return
    }
  }

  /// `.downloads` 存在且是真目录(不是符号链接)才动里面的东西。
  private var downloadsDirectoryIsReal: Bool {
    (try? LocalModelFileIO.metadataIfExists(at: downloadsRoot))?.isDirectory == true
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
      // 分片里已有的字节已经占着盘,续传只再下剩下的那段。
      total = try adding(total, asset.downloadBytes - resumableBytes(for: asset))
      total = try adding(total, asset.installedBytes)
    }
    return try adding(total, Self.safetyMarginBytes)
  }

  /// 只收尾 journal 记下的 staging、backup 与隔离目录;`.downloads/` 里的分片不归 journal 管,
  /// 崩溃或强退之后原样留给下一次续传。
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
    // 删除已过不可回头点:把删除做完、补删 receipt 条目。backup 此时可能只剩一半,
    // 照下面「未提交就搬回」的老路走,会把残缺目录放回原位,模型变成「校验未通过」。
    // `removing` 不进这里:目录还完整地躺在 backup 里,按未提交处理、原样搬回。
    if journal.phase == LocalModelTransactionJournal.deletingPhase {
      try finishRemoval(journal: journal, journalURL: journalURL)
      return
    }
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

  /// 删除事务过了不可回头点(phase `deleting`)之后的收尾,正常删除与崩溃恢复走同一条路:
  /// 删 `.staging/<op>`(backup 在它里面,或只剩残余)→ receipt 去掉这一项 → 删 journal。
  /// 先删字节再改 receipt:反过来的话,中途崩溃会留下没有条目的残缺目录。
  /// 任何一步失败就抛出、journal 留着,下次本地检查接着做;做过的步骤重做也无害。
  ///
  /// App 写 `deleting` 时不带 backupRelativePath:旧版 App 不认识这个 phase,会按「未提交」处理,
  /// 带着 backup 路径就会把删到一半的目录搬回原位;不带,它只会清掉 `.staging/<op>`,删除照样做完。
  /// 带 backupRelativePath 的 `deleting` journal(本 PR 早先的构建写的)仍照下面那段先删 backup。
  func finishRemoval(journal: LocalModelTransactionJournal, journalURL: URL) throws {
    // journal 是盘上的文件:要删的路径必须落在 .staging 之内,不能被一份坏 journal 带到别处。
    let stagingPrefix = Self.stagingDirectoryName + "/"
    let stagingRelative = try LocalModelPathSecurity.requireRelativeMember(
      journal.stagingRelativePath)
    guard stagingRelative.hasPrefix(stagingPrefix) else {
      throw LocalModelPrepareError.unsafePath("删除事务的 staging 不在 .staging 内")
    }
    if let backup = journal.backupRelativePath {
      let backupRelative = try LocalModelPathSecurity.requireRelativeMember(backup)
      guard backupRelative.hasPrefix(stagingRelative + "/") else {
        throw LocalModelPrepareError.unsafePath("删除事务的 backup 不在 staging 内")
      }
      if let backupURL = try existingUnlinkedItem(relativePath: backupRelative) {
        try FileManager.default.removeItem(at: backupURL)
      }
    }
    if let stagingURL = try existingUnlinkedItem(relativePath: stagingRelative) {
      try FileManager.default.removeItem(at: stagingURL)
    }
    try removeReceiptEntry(assetID: journal.assetID)
    // 删不掉 journal 也不算失败:上面每一步重做都无害,下次本地检查会再收一次尾。
    try? FileManager.default.removeItem(at: journalURL)
  }

  /// `modelsRoot/<relativePath>` 存在就返回它,不存在返回 nil;路径上任何一段是符号链接就抛出,
  /// 免得删除顺着链接删到模型根之外。只逐段 lstat,不依赖对不存在路径做 symlink 解析。
  func existingUnlinkedItem(relativePath: String) throws -> URL? {
    let member = try LocalModelPathSecurity.requireRelativeMember(relativePath)
    var cursor = modelsRoot
    for part in member.split(separator: "/") {
      cursor.appendPathComponent(String(part))
      guard try LocalModelFileIO.metadataIfExists(at: cursor) != nil else { return nil }
    }
    return cursor
  }

  /// receipt 去掉一项资产。没有 receipt 或本来就没有这一项时什么都不写。
  func removeReceiptEntry(assetID: String) throws {
    guard var receipt = try loadReceipt() else { return }
    guard receipt.assets.removeValue(forKey: assetID) != nil else { return }
    try writeReceipt(receipt)
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

  /// - Parameter reconcilingJournals: 有下载或删除作业在跑时传 false:它自己的 journal 正在用,
  ///   这时去「恢复」会把作业做到一半的目录搬回去或删掉;receipt 也归作业写,这时不认领;
  ///   正在写的分片也不去清。
  func refresh(
    cachedFingerprints: [String: LocalModelFileFingerprint],
    reconcilingJournals: Bool = true
  ) throws -> (
    snapshots: [String: LocalModelCapabilitySnapshot],
    fingerprints: [String: LocalModelFileFingerprint]
  ) {
    if reconcilingJournals {
      try operations.reconcileJournals()
      operations.pruneStalePartials(catalog: catalog)
    }
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

    // 只收集要认领的条目,不在读进来的那份 receipt 上改:hash 要几秒,这期间删除作业可能已经
    // 去掉过某一项,写回旧副本会把删掉的条目带回来。
    var adopted: [String: LocalModelReceiptAsset] = [:]

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
          if receipt?.assets[asset.id]?.revision != asset.revision {
            adopted[asset.id] = LocalModelReceiptAsset(
              revision: asset.revision,
              files: asset.installedFiles.map {
                LocalModelReceiptFile(path: $0.path, bytes: $0.bytes, sha256: $0.sha256)
              }
            )
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

    // 有作业在跑(reconcilingJournals == false)时 receipt 归作业写,这里不认领;作业结束后的
    // refresh 会补上。认领时重读一次 receipt,只把认领的条目并进去。
    if reconcilingJournals, !adopted.isEmpty {
      var latest =
        (try? operations.loadReceipt())
        ?? LocalModelReceipt(catalogRevision: catalog.catalogRevision, assets: [:])
      latest.catalogRevision = catalog.catalogRevision
      latest.assets.merge(adopted) { _, new in new }
      try? operations.writeReceipt(latest)
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

    let downloadURL = downloadDir.appendingPathComponent(asset.id)
    do {
      try Task.checkCancellation()
      // 有分片就从它的长度报起:先报 0 会让进度条缩回去再跳上来。
      let resumable = operations.resumableBytes(for: asset)
      if resumable > 0 {
        logger.notice(
          "resume asset=\(asset.id, privacy: .public) bytes=\(resumable, privacy: .public)")
      }
      progress(
        .downloading(assetID: asset.id, received: resumable, total: asset.downloadBytes)
      )
      // 下载先写 `.downloads/` 里的分片,下完才改名进 staging 的 downloadURL;下面的失败与取消清理
      // 只删 staging,分片留给下一次接着下。
      let downloaded = try await transport.download(
        LocalModelDownloadRequest(
          url: asset.url,
          destination: downloadURL,
          expectedBytes: asset.downloadBytes,
          partialURL: operations.partialURL(for: asset)
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
      // 取消可能落在最后一字节之后(还在校验、解压、复验):整文件已改名进 staging,file 类资产还可能
      // 已搬进 final。删 staging 之前把它改名回分片位置,下次不联网、直接重做整文件校验。
      var salvageable = [downloadURL]
      if asset.kind == .file, let mapping = asset.extract.first {
        salvageable.append(finalDir.appendingPathComponent(mapping.installPath))
      }
      operations.salvageDownload(from: salvageable, for: asset)
      try? FileManager.default.removeItem(at: staging)
      try? removeJournal(operationID)
      throw LocalModelPrepareError.cancelled
    } catch let error as LocalModelPrepareError {
      try? rollback(journal: journal, target: target)
      try? FileManager.default.removeItem(at: staging)
      try? removeJournal(operationID)
      if case .verificationFailed = error {
        // 下完时分片已改名进 staging,坏字节随 staging 删掉;这里再按名字删一次是兜底:下完若改成复制,
        // 留下的坏分片会让每次重试都续同一个坏前缀。
        operations.removePartial(for: asset)
      }
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

  /// 删除一项可选能力里由 App 装的、不被任何必需能力引用的资产(SenseVoice 删它自己,共用的
  /// Silero VAD 留下)。必需能力、全是共用资产的能力、盘上有目录却没有 receipt 条目(不是 App 装的)
  /// 一律在动手之前拒绝,盘上与 receipt 原样不动。
  ///
  /// 所有权只看 receipt 有没有这一项、条目里的文件是否都在这个目录下,不再要求字节仍与条目一致:
  /// 「校验未通过」就是字节对不上,它也必须删得掉。
  func remove(
    capabilityID: String,
    cachedFingerprints: [String: LocalModelFileFingerprint]
  ) throws {
    guard let capability = catalog.capabilitiesByID[capabilityID] else {
      throw LocalModelRemoveError.configurationFailed
    }
    guard !capability.required else {
      throw LocalModelRemoveError.requiredCapability
    }
    let assets = catalog.removableAssets(forCapabilityID: capabilityID)
    guard !assets.isEmpty else {
      throw LocalModelRemoveError.requiredCapability
    }
    // 先走一遍本地检查:收尾上次中断的事务,并把校验通过、receipt 却没记的资产重新认领进来
    // (旧版 App 可能重写过 receipt),免得 App 自己装的模型被当成用户自放而拒删。不联网。
    _ = try refresh(cachedFingerprints: cachedFingerprints)
    let receipt = try operations.loadReceipt()

    var plan: [LocalModelAsset] = []
    for asset in assets {
      let entry = receipt?.assets[asset.id]
      let owned: Bool
      if let entry {
        owned =
          !entry.files.isEmpty
          && entry.files.allSatisfy { $0.path.hasPrefix(asset.directoryName + "/") }
      } else {
        owned = false
      }
      let onDisk = try operations.existingUnlinkedItem(relativePath: asset.directoryName) != nil
      if onDisk && !owned {
        throw LocalModelRemoveError.notOwned
      }
      if onDisk || entry != nil {
        plan.append(asset)
      }
    }
    for asset in plan {
      try removeInstalledAsset(asset, capabilityID: capabilityID)
    }
    // 下到一半的分片也是这项能力占的空间,删除要一起腾出来。共用资产不在 assets 里,它的分片不动。
    for asset in assets {
      operations.removePartial(for: asset)
    }
    if !plan.isEmpty {
      logger.notice("removed capability=\(capabilityID, privacy: .public)")
    }
  }

  /// 单个资产的删除事务:写 journal(`removing`,带 backup 路径)→ 目录改名进 backup →
  /// journal 改 `deleting`(不可回头点,去掉 backup 路径)→ 删 staging(连同 backup)
  /// → receipt 去掉这一项 → 删 journal。
  /// 改名在同一卷内,不复制;不可回头点之前失败就把目录搬回原位。
  private func removeInstalledAsset(_ asset: LocalModelAsset, capabilityID: String) throws {
    let existing = try operations.existingUnlinkedItem(relativePath: asset.directoryName)
    guard let target = existing else {
      // 目录已经不在(用户自己删过):只剩 receipt 里的旧条目,去掉它,
      // 免得以后有人在同一路径放东西时被当成 App 装的。
      try operations.removeReceiptEntry(assetID: asset.id)
      return
    }
    guard try LocalModelFileIO.metadata(at: target).isDirectory else {
      throw LocalModelRemoveError.unsafePath
    }

    let operationID = UUID().uuidString
    let stagingRelative = LocalModelAssetOperations.stagingDirectoryName + "/" + operationID
    let backupRelative = stagingRelative + "/backup/" + asset.directoryName
    let backup = modelsRoot.appendingPathComponent(backupRelative, isDirectory: true)
    let staging = modelsRoot.appendingPathComponent(stagingRelative, isDirectory: true)
    var journal = LocalModelTransactionJournal(
      operationID: operationID,
      assetID: asset.id,
      capabilityID: capabilityID,
      phase: LocalModelTransactionJournal.removingPhase,
      targetRelativePath: asset.directoryName,
      stagingRelativePath: stagingRelative,
      backupRelativePath: backupRelative,
      quarantineRelativePath: nil,
      catalogRevision: catalog.catalogRevision,
      assetRevision: asset.revision
    )

    try operations.ensureModelsRoot()
    try writeJournal(journal)
    do {
      try FileManager.default.createDirectory(
        at: backup.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.moveItem(at: target, to: backup)
      // 不可回头点的 journal 不带 backup 路径:旧版 App 读到它只会清掉 staging,
      // 不会把删到一半的目录搬回原位(见 finishRemoval)。backup 仍在 staging 里,一起删。
      journal.backupRelativePath = nil
      journal.phase = LocalModelTransactionJournal.deletingPhase
      try writeJournal(journal)
    } catch {
      // 还没过不可回头点:目录若已搬进 backup 就搬回原位,当作没删。
      if !FileManager.default.fileExists(atPath: target.path),
        FileManager.default.fileExists(atPath: backup.path)
      {
        try? FileManager.default.moveItem(at: backup, to: target)
      }
      if !FileManager.default.fileExists(atPath: backup.path) {
        try? FileManager.default.removeItem(at: staging)
        try? removeJournal(operationID)
      }
      throw LocalModelRemoveError.removeFailed
    }
    // 过了不可回头点:收尾失败就留着 journal(phase deleting),下次本地检查接着删完。
    try operations.finishRemoval(
      journal: journal,
      journalURL: operations.transactionRoot.appendingPathComponent("\(operationID).json")
    )
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
