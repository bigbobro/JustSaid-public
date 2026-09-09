import Darwin
import Foundation

public enum LocalModelKnownIDs {
  public static let qwenLive = "qwen-live"
  public static let sensevoiceLive = "sensevoice-live"
  public static let appleSpeechAnalyzer = "apple-speech-analyzer"
  public static let qwenProvider = "qwen3-asr-0.6b"
  public static let sensevoiceProvider = "sensevoice-small"
}

public enum LocalModelAssetKind: String, Codable, Equatable, Sendable {
  case archive
  case file
}

public struct LocalModelExtractMapping: Equatable, Sendable {
  public let member: String
  public let installPath: String
}

public struct LocalModelInstalledFile: Equatable, Sendable {
  public let path: String
  public let bytes: Int64
  public let sha256: String
}

public struct LocalModelAsset: Equatable, Sendable, Identifiable {
  public let id: String
  public let revision: String
  public let kind: LocalModelAssetKind
  public let displayName: String
  public let url: URL
  public let downloadBytes: Int64
  public let downloadSHA256: String
  public let archiveKind: String?
  public let archiveRoot: String?
  public let allowedMembers: [String]
  public let extract: [LocalModelExtractMapping]
  public let installedFiles: [LocalModelInstalledFile]
  public let directoryName: String

  public var installedBytes: Int64 {
    installedFiles.reduce(into: Int64(0)) { $0 += $1.bytes }
  }
}

public struct LocalModelCapability: Equatable, Sendable, Identifiable {
  public let id: String
  public let displayName: String
  public let summary: String
  public let required: Bool
  public let assetIDs: [String]
}

public struct LocalModelProviderMapping: Equatable, Sendable {
  public let providerID: String
  public let capabilityID: String
}

public struct LocalModelAssetCatalog: Equatable, Sendable {
  public let schemaVersion: Int
  public let catalogRevision: String
  public let assets: [LocalModelAsset]
  public let capabilities: [LocalModelCapability]
  public let providerMappings: [LocalModelProviderMapping]

  public var assetsByID: [String: LocalModelAsset] {
    Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
  }

  public var capabilitiesByID: [String: LocalModelCapability] {
    Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })
  }

  public func capabilityID(forProviderID providerID: String) -> String? {
    providerMappings.first(where: { $0.providerID == providerID })?.capabilityID
  }

  public func assets(forCapabilityID capabilityID: String) -> [LocalModelAsset] {
    guard let capability = capabilitiesByID[capabilityID] else { return [] }
    return capability.assetIDs.compactMap { assetsByID[$0] }
  }

  public func downloadBytes(forCapabilityID capabilityID: String) -> Int64 {
    assets(forCapabilityID: capabilityID).reduce(into: Int64(0)) { $0 += $1.downloadBytes }
  }

  public func installedBytes(forCapabilityID capabilityID: String) -> Int64 {
    assets(forCapabilityID: capabilityID).reduce(into: Int64(0)) { $0 += $1.installedBytes }
  }
}

public enum LocalModelCatalogError: Error, Equatable, Sendable {
  case missingResource
  case resourceNotRegularFile
  case invalidJSON
  case invalid(String)

  public var userMessage: String {
    switch self {
    case .missingResource, .resourceNotRegularFile, .invalidJSON, .invalid:
      return "应用缺少可用的模型清单，请重装 JustSaid。"
    }
  }
}

public enum LocalModelAssetCatalogLoader {
  public static func load(from data: Data) -> Result<LocalModelAssetCatalog, LocalModelCatalogError>
  {
    let decoder = JSONDecoder()
    let raw: RawCatalog
    do {
      raw = try decoder.decode(RawCatalog.self, from: data)
    } catch {
      return .failure(.invalidJSON)
    }
    do {
      return .success(try LocalModelAssetCatalog(validating: raw))
    } catch let error as LocalModelCatalogError {
      return .failure(error)
    } catch {
      return .failure(.invalid("模型清单无法校验"))
    }
  }

  public static func loadFromBundle(_ bundle: Bundle) -> Result<
    LocalModelAssetCatalog, LocalModelCatalogError
  > {
    guard
      let url = bundle.url(forResource: "LocalModelAssets", withExtension: "json")
    else {
      return .failure(.missingResource)
    }
    do {
      try LocalModelPathSecurity.requireRegularFile(at: url)
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      return load(from: data)
    } catch let error as LocalModelCatalogError {
      return .failure(error)
    } catch {
      return .failure(.resourceNotRegularFile)
    }
  }
}

private struct RawCatalog: Decodable {
  var schemaVersion: Int
  var catalogRevision: String
  var assets: [RawAsset]
  var capabilities: [RawCapability]
  var providerMappings: [RawProviderMapping]
}

private struct RawAsset: Decodable {
  var id: String
  var revision: String
  var kind: String
  var displayName: String
  var url: String
  var downloadBytes: Int64
  var downloadSHA256: String
  var archiveKind: String?
  var archiveRoot: String?
  var allowedMembers: [String]
  var extract: [RawExtract]
  var installedFiles: [RawInstalledFile]
}

private struct RawExtract: Decodable {
  var member: String
  var installPath: String
}

private struct RawInstalledFile: Decodable {
  var path: String
  var bytes: Int64
  var sha256: String
}

private struct RawCapability: Decodable {
  var id: String
  var displayName: String
  var summary: String
  var required: Bool
  var assetIDs: [String]
}

private struct RawProviderMapping: Decodable {
  var providerID: String
  var capabilityID: String
}

extension LocalModelAssetCatalog {
  fileprivate init(validating raw: RawCatalog) throws {
    guard raw.schemaVersion == 1 else {
      throw LocalModelCatalogError.invalid("不支持的 schemaVersion")
    }
    let revision = try Self.requireToken(raw.catalogRevision, label: "catalogRevision")
    guard !raw.assets.isEmpty else {
      throw LocalModelCatalogError.invalid("assets 不能为空")
    }

    var assets: [LocalModelAsset] = []
    var assetIDs = Set<String>()
    var allInstallPaths = Set<String>()
    var downloadTotal: Int64 = 0
    var installedTotal: Int64 = 0

    for rawAsset in raw.assets {
      let asset = try LocalModelAsset(validating: rawAsset)
      if assetIDs.contains(asset.id) {
        throw LocalModelCatalogError.invalid("重复的资产 ID")
      }
      assetIDs.insert(asset.id)
      for file in asset.installedFiles {
        if allInstallPaths.contains(file.path) {
          throw LocalModelCatalogError.invalid("重复的安装路径")
        }
        allInstallPaths.insert(file.path)
        installedTotal = try Self.adding(installedTotal, file.bytes)
      }
      downloadTotal = try Self.adding(downloadTotal, asset.downloadBytes)
      assets.append(asset)
    }

    var capabilities: [LocalModelCapability] = []
    var capabilityIDs = Set<String>()
    for rawCapability in raw.capabilities {
      let capability = try LocalModelCapability(validating: rawCapability, knownAssets: assetIDs)
      if capabilityIDs.contains(capability.id) {
        throw LocalModelCatalogError.invalid("重复的能力 ID")
      }
      capabilityIDs.insert(capability.id)
      capabilities.append(capability)
    }
    guard !capabilities.isEmpty else {
      throw LocalModelCatalogError.invalid("capabilities 不能为空")
    }

    var mappings: [LocalModelProviderMapping] = []
    var providerIDs = Set<String>()
    for rawMapping in raw.providerMappings {
      let providerID = try Self.requireToken(rawMapping.providerID, label: "providerID")
      let capabilityID = try Self.requireToken(rawMapping.capabilityID, label: "capabilityID")
      if providerIDs.contains(providerID) {
        throw LocalModelCatalogError.invalid("重复的 provider 映射")
      }
      if providerID == LocalModelKnownIDs.appleSpeechAnalyzer {
        throw LocalModelCatalogError.invalid("Apple 引擎不得映射到 JustSaid 资产")
      }
      guard capabilityIDs.contains(capabilityID) else {
        throw LocalModelCatalogError.invalid("provider 映射引用了不存在的能力")
      }
      providerIDs.insert(providerID)
      mappings.append(
        LocalModelProviderMapping(providerID: providerID, capabilityID: capabilityID)
      )
    }

    self.schemaVersion = raw.schemaVersion
    self.catalogRevision = revision
    self.assets = assets
    self.capabilities = capabilities
    self.providerMappings = mappings
  }

  fileprivate static func requireToken(_ raw: String, label: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw LocalModelCatalogError.invalid("\(label) 不能为空")
    }
    return value
  }

  fileprivate static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    if overflow {
      throw LocalModelCatalogError.invalid("字节合计溢出")
    }
    return result
  }
}

extension LocalModelAsset {
  fileprivate init(validating raw: RawAsset) throws {
    let id = try LocalModelAssetCatalog.requireToken(raw.id, label: "asset.id")
    let revision = try LocalModelAssetCatalog.requireToken(raw.revision, label: "asset.revision")
    let displayName = try LocalModelAssetCatalog.requireToken(
      raw.displayName,
      label: "asset.displayName"
    )
    guard let kind = LocalModelAssetKind(rawValue: raw.kind) else {
      throw LocalModelCatalogError.invalid("未知资产类型")
    }
    guard raw.downloadBytes > 0 else {
      throw LocalModelCatalogError.invalid("下载大小必须为正")
    }
    let sha = try LocalModelPathSecurity.requireSHA256(raw.downloadSHA256)
    let url = try LocalModelPathSecurity.requirePinnedHTTPSURL(raw.url)
    let allowed = try raw.allowedMembers.map(LocalModelPathSecurity.requireRelativeMember)
    if Set(allowed).count != allowed.count {
      throw LocalModelCatalogError.invalid("archive 成员重复")
    }
    guard !allowed.isEmpty else {
      throw LocalModelCatalogError.invalid("allowedMembers 不能为空")
    }

    let extract = try raw.extract.map { item -> LocalModelExtractMapping in
      let member = try LocalModelPathSecurity.requireRelativeMember(item.member)
      let installPath = try LocalModelPathSecurity.requireRelativeMember(item.installPath)
      guard allowed.contains(member) else {
        throw LocalModelCatalogError.invalid("提取成员不在允许列表中")
      }
      return LocalModelExtractMapping(member: member, installPath: installPath)
    }
    guard !extract.isEmpty else {
      throw LocalModelCatalogError.invalid("extract 不能为空")
    }
    if Set(extract.map(\.installPath)).count != extract.count {
      throw LocalModelCatalogError.invalid("提取安装路径重复")
    }

    let installed = try raw.installedFiles.map { item -> LocalModelInstalledFile in
      let path = try LocalModelPathSecurity.requireRelativeMember(item.path)
      guard item.bytes > 0 else {
        throw LocalModelCatalogError.invalid("安装文件大小必须为正")
      }
      let fileSHA = try LocalModelPathSecurity.requireSHA256(item.sha256)
      return LocalModelInstalledFile(path: path, bytes: item.bytes, sha256: fileSHA)
    }
    guard !installed.isEmpty else {
      throw LocalModelCatalogError.invalid("installedFiles 不能为空")
    }
    if Set(installed.map(\.path)).count != installed.count {
      throw LocalModelCatalogError.invalid("安装文件路径重复")
    }
    let extractPaths = Set(extract.map(\.installPath))
    let installedPaths = Set(installed.map(\.path))
    guard extractPaths == installedPaths else {
      throw LocalModelCatalogError.invalid("提取路径与安装文件不一致")
    }

    let directoryNames = Set(
      installed.compactMap { file -> String? in
        file.path.split(separator: "/").first.map(String.init)
      }
    )
    guard directoryNames.count == 1, let directoryName = directoryNames.first else {
      throw LocalModelCatalogError.invalid("同一资产必须安装到单一目录")
    }

    switch kind {
    case .archive:
      let archiveKind = try LocalModelAssetCatalog.requireToken(
        raw.archiveKind ?? "",
        label: "archiveKind"
      )
      guard archiveKind == "tar.bz2" else {
        throw LocalModelCatalogError.invalid("只支持 tar.bz2 archive")
      }
      let archiveRoot = try LocalModelPathSecurity.requireRelativeMember(raw.archiveRoot ?? "")
      if archiveRoot.contains("/") {
        throw LocalModelCatalogError.invalid("archiveRoot 必须是单层目录名")
      }
      self.archiveKind = archiveKind
      self.archiveRoot = archiveRoot
    case .file:
      if raw.archiveKind != nil || raw.archiveRoot != nil {
        throw LocalModelCatalogError.invalid("直接文件资产不得声明 archive")
      }
      guard allowed.count == 1, extract.count == 1, installed.count == 1 else {
        throw LocalModelCatalogError.invalid("直接文件资产只能有一个成员")
      }
      self.archiveKind = nil
      self.archiveRoot = nil
    }

    self.id = id
    self.revision = revision
    self.kind = kind
    self.displayName = displayName
    self.url = url
    self.downloadBytes = raw.downloadBytes
    self.downloadSHA256 = sha
    self.allowedMembers = allowed
    self.extract = extract
    self.installedFiles = installed
    self.directoryName = directoryName
  }
}

extension LocalModelCapability {
  fileprivate init(validating raw: RawCapability, knownAssets: Set<String>) throws {
    let id = try LocalModelAssetCatalog.requireToken(raw.id, label: "capability.id")
    let displayName = try LocalModelAssetCatalog.requireToken(
      raw.displayName,
      label: "capability.displayName"
    )
    let summary = try LocalModelAssetCatalog.requireToken(
      raw.summary,
      label: "capability.summary"
    )
    guard !raw.assetIDs.isEmpty else {
      throw LocalModelCatalogError.invalid("能力必须引用至少一个资产")
    }
    if Set(raw.assetIDs).count != raw.assetIDs.count {
      throw LocalModelCatalogError.invalid("能力引用了重复资产")
    }
    for assetID in raw.assetIDs {
      let token = try LocalModelAssetCatalog.requireToken(assetID, label: "capability.assetID")
      guard knownAssets.contains(token) else {
        throw LocalModelCatalogError.invalid("能力引用了不存在的资产")
      }
    }
    self.id = id
    self.displayName = displayName
    self.summary = summary
    self.required = raw.required
    self.assetIDs = raw.assetIDs
  }
}

enum LocalModelPathSecurity {
  static func requireSHA256(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
    guard value.count == 64, value.unicodeScalars.allSatisfy({ hexDigits.contains($0) })
    else {
      throw LocalModelCatalogError.invalid("SHA-256 必须是 64 位小写十六进制")
    }
    return value
  }

  static func requirePinnedHTTPSURL(_ raw: String) throws -> URL {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
      throw LocalModelCatalogError.invalid("URL 无效")
    }
    guard scheme == "https" else {
      throw LocalModelCatalogError.invalid("只允许 HTTPS URL")
    }
    guard url.user == nil, url.password == nil else {
      throw LocalModelCatalogError.invalid("URL 不得包含用户信息")
    }
    guard let host = url.host, !host.isEmpty else {
      throw LocalModelCatalogError.invalid("URL 缺少主机名")
    }
    let path = url.path.lowercased()
    if path == "/latest" || path.hasSuffix("/latest") || path.contains("/latest/") {
      throw LocalModelCatalogError.invalid("不得使用 latest URL")
    }
    return url
  }

  static func requireRelativeMember(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw LocalModelCatalogError.invalid("路径不能为空")
    }
    if value.hasPrefix("/") || value.hasPrefix("~") {
      throw LocalModelCatalogError.invalid("路径不得为绝对路径")
    }
    if value.contains("\\") {
      throw LocalModelCatalogError.invalid("路径不得包含反斜杠")
    }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    if parts.contains("") {
      throw LocalModelCatalogError.invalid("路径不得包含空段")
    }
    if parts.contains(".") || parts.contains("..") {
      throw LocalModelCatalogError.invalid("路径不得包含 . 或 ..")
    }
    return value
  }

  static func requireRegularFile(at url: URL) throws {
    var status = stat()
    let result = lstat(url.path, &status)
    guard result == 0 else {
      throw LocalModelCatalogError.resourceNotRegularFile
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw LocalModelCatalogError.resourceNotRegularFile
    }
  }
}

public enum LocalModelByteDisplay {
  public static func megabytes(_ bytes: Int64) -> String {
    let mb = (bytes + 500_000) / 1_000_000
    return "\(mb) MB"
  }
}
