import Combine
import Foundation
import OSLog

@MainActor
public final class LocalModelAssetManager: ObservableObject {
  public enum CatalogResult {
    case success(LocalModelAssetCatalog)
    case failure(LocalModelCatalogError)
  }

  enum PreviewMode: Equatable {
    case off
    case allReady
  }

  @Published public private(set) var capabilityStates: [String: LocalModelCapabilitySnapshot] = [:]
  @Published public private(set) var preparation: LocalModelPreparationState = .idle
  @Published public private(set) var isBusy = false
  @Published public private(set) var configurationError: String?

  public let catalog: LocalModelAssetCatalog?
  public let modelsRoot: URL

  private let transport: any ModelAssetDownloadTransport
  private let capacity: any VolumeCapacityProviding
  private let previewMode: PreviewMode
  private let logger = Logger(subsystem: "com.justsaid.app", category: "LocalModelAssets")
  private var fingerprints: [String: LocalModelFileFingerprint] = [:]
  private var generation: UInt64 = 0
  private var runningPrepare: Task<Result<Void, Error>, Never>?

  public init(
    catalogResult: Result<LocalModelAssetCatalog, LocalModelCatalogError>,
    modelsRoot: URL,
    transport: any ModelAssetDownloadTransport,
    capacity: any VolumeCapacityProviding = FileSystemVolumeCapacityProvider()
  ) {
    self.modelsRoot = modelsRoot
    self.transport = transport
    self.capacity = capacity
    self.previewMode = .off
    switch catalogResult {
    case .success(let catalog):
      self.catalog = catalog
      self.configurationError = nil
      self.capabilityStates = Self.checkingStates(for: catalog)
    case .failure(let error):
      self.catalog = nil
      self.configurationError = error.userMessage
      self.capabilityStates = [:]
    }
  }

  init(
    catalog: LocalModelAssetCatalog,
    modelsRoot: URL,
    transport: any ModelAssetDownloadTransport,
    capacity: any VolumeCapacityProviding,
    previewMode: PreviewMode
  ) {
    self.catalog = catalog
    self.modelsRoot = modelsRoot
    self.transport = transport
    self.capacity = capacity
    self.previewMode = previewMode
    self.configurationError = nil
    if previewMode == .allReady {
      self.capabilityStates = Self.readyStates(for: catalog)
    } else {
      self.capabilityStates = Self.checkingStates(for: catalog)
    }
  }

  public nonisolated static func defaultModelsRoot(fileManager: FileManager = .default) -> URL {
    LocalOfflineModelPaths.modelsDirectory(fileManager: fileManager)
  }

  public static func makePreviewReady() -> LocalModelAssetManager {
    let catalog: LocalModelAssetCatalog
    switch LocalModelAssetCatalogLoader.load(from: Data(Self.previewCatalogJSON.utf8)) {
    case .success(let value):
      catalog = value
    case .failure:
      preconditionFailure("preview catalog 必须能解码")
    }
    return LocalModelAssetManager(
      catalog: catalog,
      modelsRoot: URL(fileURLWithPath: "/tmp/JustSaid-Preview-Models"),
      transport: FakeModelAssetDownloadTransport(),
      capacity: FixedVolumeCapacityProvider(available: 1_000_000_000),
      previewMode: .allReady
    )
  }

  public func capability(forProviderID providerID: String) -> String? {
    catalog?.capabilityID(forProviderID: providerID)
  }

  public func snapshot(forCapabilityID capabilityID: String) -> LocalModelCapabilitySnapshot? {
    capabilityStates[capabilityID]
  }

  public func startGate(forProviderID providerID: String) -> LocalModelStartGateDecision {
    // Apple 语音资产由 macOS 管理,不经我们的清单:清单本身有问题也不该连它一起拦死。
    if providerID == LocalModelKnownIDs.appleSpeechAnalyzer {
      return .systemManaged
    }
    if let configurationError {
      return .configurationFailed(reason: configurationError)
    }
    guard let catalog else {
      return .configurationFailed(reason: "应用缺少可用的模型清单，请重装 JustSaid。")
    }
    guard let capabilityID = catalog.capabilityID(forProviderID: providerID) else {
      return .configurationFailed(reason: "未知会中速记引擎")
    }
    guard let snapshot = capabilityStates[capabilityID] else {
      return .waitForLocalCheck
    }
    switch snapshot.status {
    case .checking:
      return .waitForLocalCheck
    case .ready:
      return .ready
    case .missing, .updateRequired, .damaged:
      return .showPreparation(capabilityID: capabilityID)
    case .configurationFailed(let reason):
      return .configurationFailed(reason: reason)
    }
  }

  public func refresh() async {
    if previewMode == .allReady {
      if let catalog {
        capabilityStates = Self.readyStates(for: catalog)
      }
      return
    }
    guard let catalog else {
      return
    }
    let modelsRoot = self.modelsRoot
    let transport = self.transport
    let capacity = self.capacity
    let cached = fingerprints
    let capturedGeneration = generation
    let result = await Task.detached(priority: .utility) {
      () -> Result<
        ([String: LocalModelCapabilitySnapshot], [String: LocalModelFileFingerprint]), Error
      > in
      do {
        let engine = LocalModelInstallEngine(
          catalog: catalog,
          modelsRoot: modelsRoot,
          transport: transport,
          capacity: capacity
        )
        let output = try engine.refresh(cachedFingerprints: cached)
        return .success(output)
      } catch {
        return .failure(error)
      }
    }.value
    guard capturedGeneration == generation else { return }
    switch result {
    case .success(let output):
      capabilityStates = output.0
      fingerprints = output.1
    case .failure:
      for (id, snapshot) in capabilityStates {
        capabilityStates[id] = LocalModelCapabilitySnapshot(
          id: snapshot.id,
          displayName: snapshot.displayName,
          summary: snapshot.summary,
          required: snapshot.required,
          status: .damaged(reason: "本地校验失败"),
          downloadBytes: snapshot.downloadBytes,
          installedBytes: snapshot.installedBytes,
          missingDownloadBytes: snapshot.missingDownloadBytes,
          missingInstalledBytes: snapshot.missingInstalledBytes,
          missingAssetIDs: snapshot.missingAssetIDs
        )
      }
    }
  }

  public func prepare(capabilityID: String) async {
    HangSentinel.shared.note("models:prepare:start")
    guard previewMode == .off else { return }
    guard let catalog else {
      preparation = .failed(
        capabilityID: capabilityID,
        stage: "configuration",
        message: "应用缺少可用的模型清单，请重装 JustSaid。",
        retryable: false
      )
      return
    }
    guard !isBusy else {
      return
    }
    isBusy = true
    generation &+= 1
    let capturedGeneration = generation
    let modelsRoot = self.modelsRoot
    let transport = self.transport
    let capacity = self.capacity
    // 进度必须单调:每个回调各起一个 Task 投递到主线程没有先后保证,
    // 用单一 stream 消费才能保证阶段顺序与字节进度不回跳。
    let (phases, phaseSink) = AsyncStream<LocalModelPreparationPhase>.makeStream()
    let consumer = Task { @MainActor [weak self] in
      for await phase in phases {
        guard let self, capturedGeneration == self.generation else { continue }
        self.preparation = .running(capabilityID: capabilityID, phase: phase)
      }
    }
    let task = Task.detached(priority: .utility) { () -> Result<Void, Error> in
      do {
        let engine = LocalModelInstallEngine(
          catalog: catalog,
          modelsRoot: modelsRoot,
          transport: transport,
          capacity: capacity
        )
        try await engine.prepare(capabilityID: capabilityID) { phase in
          phaseSink.yield(phase)
        }
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    runningPrepare = task
    let result = await task.value
    phaseSink.finish()
    await consumer.value
    runningPrepare = nil
    guard capturedGeneration == generation else { return }
    switch result {
    case .success:
      HangSentinel.shared.note("models:prepare:install-commit")
      preparation = .idle
      isBusy = false
      await refresh()
    case .failure(let error):
      if error is CancellationError
        || (error as? LocalModelPrepareError) == .cancelled
        || (error as? ModelAssetDownloadError) == .cancelled
      {
        HangSentinel.shared.note("models:prepare:cancel")
        preparation = .idle
        isBusy = false
        await refresh()
        return
      }
      HangSentinel.shared.note("models:prepare:failed")
      let mapped: LocalModelPrepareError
      if let prepareError = error as? LocalModelPrepareError {
        mapped = prepareError
      } else if let downloadError = error as? ModelAssetDownloadError {
        mapped = downloadError.asPrepareError
      } else {
        mapped = .installFailed("安装失败")
      }
      preparation = .failed(
        capabilityID: capabilityID,
        stage: mapped.stage,
        message: mapped.userMessage,
        retryable: mapped.retryable
      )
      isBusy = false
      await refresh()
    }
  }

  public func cancelActivePreparation() {
    HangSentinel.shared.note("models:prepare:cancel")
    generation &+= 1
    let cancelled = runningPrepare
    runningPrepare = nil
    preparation = .idle
    cancelled?.cancel()
    // 必须等旧作业真的停下来才放开单作业互斥并重查:提前放行会让"重试"与
    // 尚未收尾的旧作业互相覆盖,旧作业的 rollback 能把新装好的模型删掉。
    Task { @MainActor [weak self] in
      _ = await cancelled?.value
      guard let self else { return }
      self.isBusy = false
      await self.refresh()
    }
  }

  private static func checkingStates(for catalog: LocalModelAssetCatalog)
    -> [String: LocalModelCapabilitySnapshot]
  {
    Dictionary(
      uniqueKeysWithValues: catalog.capabilities.map { capability in
        (
          capability.id,
          LocalModelCapabilitySnapshot(
            id: capability.id,
            displayName: capability.displayName,
            summary: capability.summary,
            required: capability.required,
            status: .checking,
            downloadBytes: catalog.downloadBytes(forCapabilityID: capability.id),
            installedBytes: catalog.installedBytes(forCapabilityID: capability.id),
            missingDownloadBytes: 0,
            missingInstalledBytes: 0,
            missingAssetIDs: []
          )
        )
      }
    )
  }

  private static func readyStates(for catalog: LocalModelAssetCatalog)
    -> [String: LocalModelCapabilitySnapshot]
  {
    Dictionary(
      uniqueKeysWithValues: catalog.capabilities.map { capability in
        let files = catalog.assets(forCapabilityID: capability.id).flatMap {
          $0.installedFiles.map(\.path)
        }
        return (
          capability.id,
          LocalModelCapabilitySnapshot(
            id: capability.id,
            displayName: capability.displayName,
            summary: capability.summary,
            required: capability.required,
            status: .ready(revision: catalog.catalogRevision, validatedFiles: files.sorted()),
            downloadBytes: catalog.downloadBytes(forCapabilityID: capability.id),
            installedBytes: catalog.installedBytes(forCapabilityID: capability.id),
            missingDownloadBytes: 0,
            missingInstalledBytes: 0,
            missingAssetIDs: []
          )
        )
      }
    )
  }

  private static let previewCatalogJSON = """
    {
      "schemaVersion": 1,
      "catalogRevision": "preview",
      "assets": [
        {
          "id": "qwen3-asr-0.6b-int8",
          "revision": "preview",
          "kind": "file",
          "displayName": "Qwen3-ASR-0.6B",
          "url": "https://example.invalid/qwen.bin",
          "downloadBytes": 1,
          "downloadSHA256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "archiveKind": null,
          "archiveRoot": null,
          "allowedMembers": ["qwen.bin"],
          "extract": [{"member": "qwen.bin", "installPath": "Qwen3-ASR-0.6B/qwen.bin"}],
          "installedFiles": [{"path": "Qwen3-ASR-0.6B/qwen.bin", "bytes": 1, "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]
        },
        {
          "id": "silero-vad",
          "revision": "preview",
          "kind": "file",
          "displayName": "Silero VAD",
          "url": "https://example.invalid/silero.bin",
          "downloadBytes": 1,
          "downloadSHA256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "archiveKind": null,
          "archiveRoot": null,
          "allowedMembers": ["silero.bin"],
          "extract": [{"member": "silero.bin", "installPath": "Silero-VAD/silero.bin"}],
          "installedFiles": [{"path": "Silero-VAD/silero.bin", "bytes": 1, "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]
        },
        {
          "id": "sensevoice-small-int8",
          "revision": "preview",
          "kind": "file",
          "displayName": "SenseVoice-Small",
          "url": "https://example.invalid/sensevoice.bin",
          "downloadBytes": 1,
          "downloadSHA256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "archiveKind": null,
          "archiveRoot": null,
          "allowedMembers": ["sensevoice.bin"],
          "extract": [{"member": "sensevoice.bin", "installPath": "SenseVoice-Small/sensevoice.bin"}],
          "installedFiles": [{"path": "SenseVoice-Small/sensevoice.bin", "bytes": 1, "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]
        }
      ],
      "capabilities": [
        {
          "id": "qwen-live",
          "displayName": "Qwen3-ASR 与 Silero VAD",
          "summary": "默认完整会中速记能力",
          "required": true,
          "assetIDs": ["qwen3-asr-0.6b-int8", "silero-vad"]
        },
        {
          "id": "sensevoice-live",
          "displayName": "SenseVoice-Small 与 Silero VAD",
          "summary": "可选会中速记引擎",
          "required": false,
          "assetIDs": ["sensevoice-small-int8", "silero-vad"]
        }
      ],
      "providerMappings": [
        {"providerID": "qwen3-asr-0.6b", "capabilityID": "qwen-live"},
        {"providerID": "sensevoice-small", "capabilityID": "sensevoice-live"}
      ]
    }
    """
}
