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
  /// 正在删除的能力(连同那次作业的 generation)。删完的盘面刷新进快照之前,快照仍是「已安装」,
  /// 开会门不能据此放行:引擎会去加载正被改名进 `.staging`、随后删掉的模型文件。
  private var removal: (capabilityID: String, generation: UInt64)?

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

  /// 开会时定本场要不要走 Pro(PR-08):不等、不检查,只看开关、本场会中引擎与 Pro 模型的本机快照。
  /// `liveProviderID` 是绑定里会中速记的 providerID(「自动」已解析)。
  public func liveProPlan(proModeEnabled: Bool, liveProviderID: String?) -> LiveProPlan {
    let capabilityID = LocalModelKnownIDs.qwenLivePro
    var busy = removal?.capabilityID == capabilityID
    if case .running(let running, _) = preparation, running == capabilityID {
      busy = true
    }
    let modelURL = catalog?.assets(forCapabilityID: capabilityID).first?.installedFiles.first
      .map { modelsRoot.appendingPathComponent($0.path, isDirectory: false) }
    return LiveProPlan.resolve(
      proModeEnabled: proModeEnabled,
      liveProviderID: liveProviderID,
      proStatus: capabilityStates[capabilityID]?.status,
      proModelBusy: busy,
      proModelURL: modelURL
    )
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
    // 删除进行中:这项能力马上就不在了,先等本地检查(删完 refresh 后是「未安装」,走准备页)。
    if removal?.capabilityID == capabilityID {
      return .waitForLocalCheck
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
    // 下载或删除作业在跑时,它的 journal 与 receipt 归它自己写;这里只看盘,不去「恢复」也不认领。
    let reconciling = !isBusy
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
        let output = try engine.refresh(
          cachedFingerprints: cached, reconcilingJournals: reconciling)
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
    // 作业槽一占上就显示为这项能力的下载中:第一次进度回调要隔一跳才到主线程,
    // 中间这段若还是 idle,界面会把「有作业在跑」当成别的模型在下载。
    preparation = .running(capabilityID: capabilityID, phase: .preflightingSpace)
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
      // 先让快照读到新装好的模型再放开作业槽:反过来的那一两秒里,界面会看到「没在下载、
      // 模型却还不是已安装」,开关会闪成「已开启 · 模型需要修复」。
      await refresh()
      guard capturedGeneration == generation else { return }
      preparation = .idle
      isBusy = false
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

  /// 删除一项可选能力里由 App 安装、且不被任何必需能力引用的资产,删完回到「未安装」。
  /// 必需能力、被必需能力共用的资产、receipt 里没有条目的路径一律拒绝并原样保留。
  /// 与下载共用唯一的作业槽(`isBusy` / `generation`):下载或修复进行中不能删,删除中也不能下载。
  /// 不联网。失败抛 `LocalModelRemoveError`。
  public func remove(capabilityID: String) async throws {
    guard previewMode == .off else { return }
    guard let catalog else {
      throw LocalModelRemoveError.configurationFailed
    }
    guard let capability = catalog.capabilitiesByID[capabilityID] else {
      throw LocalModelRemoveError.configurationFailed
    }
    guard !capability.required else {
      throw LocalModelRemoveError.requiredCapability
    }
    guard !isBusy else {
      throw LocalModelRemoveError.busy
    }
    HangSentinel.shared.note("models:remove:start")
    isBusy = true
    generation &+= 1
    let capturedGeneration = generation
    removal = (capabilityID: capabilityID, generation: capturedGeneration)
    let modelsRoot = self.modelsRoot
    let transport = self.transport
    let capacity = self.capacity
    let cached = fingerprints
    let task = Task.detached(priority: .utility) { () -> Result<Void, Error> in
      do {
        let engine = LocalModelInstallEngine(
          catalog: catalog,
          modelsRoot: modelsRoot,
          transport: transport,
          capacity: capacity
        )
        try engine.remove(capabilityID: capabilityID, cachedFingerprints: cached)
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    // 删除也挂在作业槽上:取消入口会等它真的结束才放开 isBusy,不会让下载与删除叠在一起。
    runningPrepare = task
    let result = await task.value
    if capturedGeneration == generation {
      runningPrepare = nil
      // 删掉的文件不留指纹缓存,免得同一路径以后的新文件凑巧撞上旧指纹而跳过 SHA 校验。
      for asset in catalog.removableAssets(forCapabilityID: capabilityID) {
        for file in asset.installedFiles {
          fingerprints[file.path] = nil
        }
      }
      isBusy = false
      await refresh()
    }
    // 删完的盘面已刷新进快照(被取消时由取消入口收尾),开会门回到按快照判。
    // 只清自己这次的:refresh 等待期间可能已经开始了另一次删除。
    if removal?.generation == capturedGeneration {
      removal = nil
    }
    switch result {
    case .success:
      HangSentinel.shared.note("models:remove:done")
    case .failure(let error):
      HangSentinel.shared.note("models:remove:failed")
      throw LocalModelRemoveError.mapping(error)
    }
  }

  /// 收起某项能力上一次准备失败的说明,回到空闲。设置里「Pro 模式」一行在下一次切换开关或离开页面时调用
  /// (设计系统 README「Pro 模式」:失败说明在下一次切换或离开页面时消失)。别的能力的失败与进行中的作业不动。
  public func dismissPreparationFailure(capabilityID: String) {
    if case .failed(let failed, _, _, _) = preparation, failed == capabilityID {
      preparation = .idle
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
        },
        {
          "id": "qwen3-asr-1.7b-q8-gguf",
          "revision": "preview",
          "kind": "file",
          "displayName": "Qwen3-ASR-1.7B",
          "url": "https://example.invalid/pro.gguf",
          "downloadBytes": 1,
          "downloadSHA256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "archiveKind": null,
          "archiveRoot": null,
          "allowedMembers": ["pro.gguf"],
          "extract": [{"member": "pro.gguf", "installPath": "Qwen3-ASR-1.7B/pro.gguf"}],
          "installedFiles": [{"path": "Qwen3-ASR-1.7B/pro.gguf", "bytes": 1, "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]
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
        },
        {
          "id": "qwen-live-pro",
          "displayName": "Qwen3-ASR Pro（1.7B）",
          "summary": "可选",
          "required": false,
          "assetIDs": ["qwen3-asr-1.7b-q8-gguf"]
        }
      ],
      "providerMappings": [
        {"providerID": "qwen3-asr-0.6b", "capabilityID": "qwen-live"},
        {"providerID": "sensevoice-small", "capabilityID": "sensevoice-live"}
      ]
    }
    """
}
