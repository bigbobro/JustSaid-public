import Foundation
import OSLog

// Pro 模式复合识别器(PR-07):1.7B 在 GPU 上解码,0.6B 在 CPU 上作热备。
//
// 契约(PRD §5.3 与「开会不等」,owner 2026-10-17),调度层(`LocalOfflineTranscriptionPipeline`)与 stop 语义不变:
// - 开录不等:0.6B 随引擎 start 同步装好;1.7B 由 `beginLoading()` 放进后台任务加载、建会话,再用 0.1 s 噪声
//   预热一次(把 Metal 首次编译挪到接手之前)。没就绪时每段交热备(cpu-spare-loading),就绪后从下一段起走 GPU。
// - 加载或预热出设备错误(含验证注入)按 GPU 出错处理:当场送出一次 `fellBackToStandard(callIndex: 0)`,
//   整场走热备。不在 App 启动时预载,也不看内存或快慢(owner 2026-10-17:选了 Pro 就照用)。
// - 数字静音(RMS < 5e-5)与不足 1,600 样本(0.1 s)的段直接交热备,GPU 照用。
// - GPU 抛 `.backend`(ERR_BACKEND / ERR_OOM,含验证注入):先摘掉 GPU、记下失效,当场送出一次
//   `LiveEngineEvent.fellBackToStandard`,再 await 热备重解同一段并返回;之后整场走热备。
//   重解期间进来的 decode 直接走热备,不碰已失效的会话。
// - GPU 抛 `.inputRejected`:只这一段交热备,GPU 保留,不置回退、不发事件。
// - 每次请求恰好返回一次,不用空串遮掩。
// - transcribe_run 在 actor 内同步执行,同一模型同一时刻最多一个 run,绝不 detach。预热那一次 run 在加载任务里、
//   会话交给 actor 之前,那时只有加载任务一个持有者。
// - 散会:引擎排空两路之后调 `shutdown()`,先取消加载任务并等它退出,再放掉 GPU 会话;返回时 1.7B 已释放。
// - 每次 decode 读当时的语种(#212 会中切换在 GPU 路径上逐段生效),auto 传 nil、中文 zh、英文 en;
//   交给热备的段(含回退之后)把同一个语种传给热备,会中切换在 CPU 路径上照样生效。
// - GPU 文本同样过 `Qwen3ASRTranscriberEngine.removingProtocolHeaders`。
// 产品路径里 faultPlan 与记录器固定为 nil;只有 @_spi(Verification) 入口收它们,产品代码不读环境变量。

/// Pro 模式的 GPU 主识别一侧。产品里只有 `TranscribeGPUSession`;验证程序可接假的,不需要 GGUF。
/// 约定同 `TranscribeGPUSession.run`:同步阻塞,只由持有者串行调用。
public protocol ProGPUTranscribing: AnyObject, Sendable {
  func run(samples: [Float], language: MeetingLanguage) throws -> TranscribeGPURunResult
}

extension TranscribeGPUSession: ProGPUTranscribing {}

/// 热备一侧(标准识别,0.6B 在 CPU 上)。产品里是会中现用的 Qwen3-ASR 识别器;验证可接假的。
/// `language` 是复合识别器这一次 decode 读到的会中语种,热备按它设 stream 的语种选项。
public protocol ProHotSpareDecoding: Sendable {
  func decode(_ samples: [Float], language: MeetingLanguage) async -> String
}

/// 验证专用的故障注入。
@_spi(Verification) public struct ProFaultPlan: Equatable, Sendable {
  /// 第 N 次 GPU 调用(从 1 起,不含预热)照常算完,再当作 ERR_BACKEND;nil 不注入。
  /// 那次的真实结局是出字还是输入被拒都一样注入;真实的设备错误本来就回退,记为未注入。
  public let failGPUCallAt: Int?
  /// 1.7B 照常加载、预热,交给复合识别器之前当作没装好(开录后大模型没能装上)。
  public let failLoad: Bool

  public init(failGPUCallAt: Int) {
    self.init(failGPUCallAt: failGPUCallAt, failLoad: false)
  }

  /// 后台加载照常做完,结局按加载失败处理:回退事件 callIndex 0,整场走热备。
  public static let failLoading = ProFaultPlan(failGPUCallAt: nil, failLoad: true)

  private init(failGPUCallAt: Int?, failLoad: Bool) {
    self.failGPUCallAt = failGPUCallAt
    self.failLoad = failLoad
  }
}

/// 一次 decode 走的路。
@_spi(Verification) public enum ProDecodePath: String, CaseIterable, Codable, Sendable {
  /// GPU 出字。
  case gpu
  /// GPU 真出错(或注入)的那一段,同一次调用里由热备重解。
  case cpuRedecode = "cpu-redecode"
  /// 本场 GPU 已失效(GPU 出错,或开录后 1.7B 没能装好)之后的每一次 decode(含静音与短段)。
  case cpuAfterFailure = "cpu-after-failure"
  /// 1.7B 还没就绪(开录后在后台加载;散会之后同样),交热备(含静音与短段)。
  case cpuSpareLoading = "cpu-spare-loading"
  /// 不足 1,600 样本,直接交热备。
  case cpuSpareShort = "cpu-spare-short"
  /// 数字静音(RMS < 5e-5),直接交热备。
  case cpuSpareSilence = "cpu-spare-silence"
  /// GPU 拒收这一段(inputRejected),只这一段交热备。
  case cpuInputRejected = "cpu-input-rejected"
}

/// 验证专用的逐次 decode 记录,不含文本。字段与研究 decode.jsonl 同名,另加语种与 GPU 起止。
@_spi(Verification) public struct ProDecodeRecord: Equatable, Sendable {
  /// 本场第几次 decode,从 1 起。
  public let index: Int
  public let path: ProDecodePath
  /// 走过 GPU 时是第几次 GPU 调用(从 1 起,不含预热);没碰 GPU 为 nil。
  public let gpuCall: Int?
  public let samples: Int
  /// 这次 decode 读到的语种。
  public let selectedLanguage: MeetingLanguage
  /// 实际传给 transcribe_run 的语言码(auto 为 nil);没碰 GPU 也为 nil,看 `gpuCall` 区分。
  public let gpuLanguageCode: String?
  /// GPU 原始文本里协议头写的语种(清理前,如 `Chinese`);没有头或没碰 GPU 为 nil。
  public let headerLanguage: String?
  /// decode 进出时刻,`DispatchTime.now().uptimeNanoseconds`。路径在进入时定。
  public let startUptimeNanos: UInt64
  public let endUptimeNanos: UInt64
  /// transcribe_run 进出时刻;没碰 GPU 为 nil。
  public let gpuStartUptimeNanos: UInt64?
  public let gpuEndUptimeNanos: UInt64?
  /// GPU 结局(`TranscribeStatus.description`);没碰 GPU 为 nil。
  public let status: String?
  /// 这次的 BACKEND 是 faultPlan 注入的。
  public let injected: Bool
  /// 返回的文本去首尾空白后为空。
  public let empty: Bool

  public init(
    index: Int,
    path: ProDecodePath,
    gpuCall: Int?,
    samples: Int,
    selectedLanguage: MeetingLanguage,
    gpuLanguageCode: String?,
    headerLanguage: String?,
    startUptimeNanos: UInt64,
    endUptimeNanos: UInt64,
    gpuStartUptimeNanos: UInt64?,
    gpuEndUptimeNanos: UInt64?,
    status: String?,
    injected: Bool,
    empty: Bool
  ) {
    self.index = index
    self.path = path
    self.gpuCall = gpuCall
    self.samples = samples
    self.selectedLanguage = selectedLanguage
    self.gpuLanguageCode = gpuLanguageCode
    self.headerLanguage = headerLanguage
    self.startUptimeNanos = startUptimeNanos
    self.endUptimeNanos = endUptimeNanos
    self.gpuStartUptimeNanos = gpuStartUptimeNanos
    self.gpuEndUptimeNanos = gpuEndUptimeNanos
    self.status = status
    self.injected = injected
    self.empty = empty
  }
}

/// 验证专用:每次 decode 返回前调用一次。
@_spi(Verification) public typealias ProDecodeRecorder = @Sendable (ProDecodeRecord) -> Void

/// 本场走 Pro 时交给 `Qwen3ASRTranscriberEngine(pro:)` 的东西:1.7B 从哪里来。只是描述,不占内存;
/// 1.7B 在开录时由复合识别器在后台加载,散会时释放。
public struct ProRecognizerConfiguration: Sendable {
  /// 同步阻塞:加载 GGUF 并建会话(合计数秒),在加载任务里调。失败就抛错。
  let loadGPU: @Sendable () throws -> any ProGPUTranscribing
  /// 预热之后读回,写进接手时的读回;假的 GPU 全为 nil。
  let readDevice: @Sendable (any ProGPUTranscribing) -> ProGPUDeviceReadback
  let faultPlan: ProFaultPlan?
  let recorder: ProDecodeRecorder?
  /// 验证专用:引擎不建真的 0.6B,改用这个热备;产品为 nil。
  let hotSpareOverride: (any ProHotSpareDecoding)?

  /// 产品入口:faultPlan 与记录器固定为 nil。
  public init(proModelURL: URL) {
    self.init(proModelURL: proModelURL, faultPlan: nil, recorder: nil)
  }

  /// 验证入口:真实 GGUF,另可注入故障、逐次记录。
  @_spi(Verification) public init(
    proModelURL: URL,
    faultPlan: ProFaultPlan?,
    recorder: ProDecodeRecorder?
  ) {
    loadGPU = { try TranscribeGPUSession(modelURL: proModelURL) }
    readDevice = { gpu in
      ProGPUDeviceReadback(
        deviceInfo: (gpu as? TranscribeGPUSession)?.deviceInfo,
        hasTensor: TranscribeRuntimeLog.snapshot().hasTensor,
        requestedThreads: TranscribeGPUSession.requestedThreads
      )
    }
    self.faultPlan = faultPlan
    self.recorder = recorder
    hotSpareOverride = nil
  }

  /// 验证入口:假的 GPU,不需要 GGUF。`loadGPU` 在加载任务里同步调用,可以阻塞、可以抛错,
  /// 用来模拟加载用时与加载失败。给了 `hotSpare` 时,引擎用它代替真的 0.6B(不需要模型文件)。
  @_spi(Verification) public init(
    loadGPU: @escaping @Sendable () throws -> any ProGPUTranscribing,
    hotSpare: (any ProHotSpareDecoding)? = nil,
    faultPlan: ProFaultPlan?,
    recorder: ProDecodeRecorder?
  ) {
    self.loadGPU = loadGPU
    readDevice = { _ in
      ProGPUDeviceReadback(deviceInfo: nil, hasTensor: nil, requestedThreads: nil)
    }
    self.faultPlan = faultPlan
    self.recorder = recorder
    hotSpareOverride = hotSpare
  }
}

/// 1.7B 所在设备的读回。
struct ProGPUDeviceReadback: Sendable {
  let deviceInfo: TranscribeGPUDeviceInfo?
  let hasTensor: Bool?
  let requestedThreads: Int32?
}

/// 1.7B 装好接手时的读回:写进本场的引擎报告(PR-08 记进会议与诊断账本)与回放报告。
public struct ProGPUReadiness: Equatable, Sendable {
  /// 1.7B 实际所在的设备;假的 GPU 或读不到为 nil。
  public let deviceInfo: TranscribeGPUDeviceInfo?
  /// 从 ggml-metal 初始化日志读到的 has_tensor;读不到或假的 GPU 为 nil(未核实)。
  public let hasTensor: Bool?
  /// GPU 会话请求的 CPU 线程数(0 = 库自选);假的 GPU 为 nil。
  public let requestedThreads: Int32?
  /// 加载 GGUF 并建会话的用时(秒)。
  public let loadSeconds: Double
  /// 0.1 s 噪声预热的用时(秒);GPU 没接收那次预热为 nil(会话照用,第一段可能多等一次编译)。
  public let warmupSeconds: Double?
  /// 从开始加载到接手的用时(秒),约等于开录后多久 Pro 接手。
  public let readyAfterSeconds: Double
  /// 接手时刻,`DispatchTime.now().uptimeNanoseconds`(与逐次解码记录同一时钟)。
  public let readyAtUptimeNanos: UInt64
}

/// 复合识别器回报给 Qwen 引擎的事(产品接线);验证直接构造复合识别器时没有。
struct ProRecognizerHooks: Sendable {
  /// 每次 GPU 调用实际所传的语种,进引擎的 `languageObservations`(与 CPU stream 读回同一接口)。
  let gpuLanguage: @Sendable (Qwen3ASRStreamLanguageObservation) -> Void
  /// 一次数字静音的 decode,进引擎的 `digitalSilenceSkippedDecodeCount`。
  let digitalSilence: @Sendable () -> Void
  /// 1.7B 装好接手的那一刻调用一次,进引擎的 `liveEngineReport`。
  let ready: @Sendable (ProGPUReadiness) -> Void
  /// 回退发生在第几次 GPU 调用(0 = 开录后没能装好);失败那一刻调用一次,进引擎的 `liveEngineReport`。
  let fellBack: @Sendable (Int) -> Void
}

/// 复合识别器:GPU 主 + 0.6B 热备,契约见文件头。两路共用一个实例。
///
/// 全部状态在 actor 里。GPU 会话只经 `gpu` 这一个引用调用,run 同步执行、中间没有挂起点,
/// 所以同一时刻至多一个 run。会话只在加载任务做完之后、经 actor 装上;回退时先把 `gpu` 置 nil 再 await 热备:
/// 之后进来的 decode 看到的都是 nil,不会再碰失效的会话;最后一个引用放掉时 1.7B 随之释放。
@_spi(Verification) public actor ProGPUPrimaryRecognizer: OfflineSpeechRecognizer {
  /// transcribe.cpp 不收不足一个 mel 窗的段;不足 0.1 s 的交热备,不当成 GPU 故障。
  static let minimumGPUSamples = 1_600
  /// 预热用的样本数:0.1 s(16 kHz),与 GPU 收的最短段相同。
  static let warmupSampleCount = minimumGPUSamples
  /// 与 `Qwen3ASRRecognizer` 相同的数字静音门槛。
  static let digitalSilenceRMSThreshold: Double = 0.000_05

  private let configuration: ProRecognizerConfiguration
  /// 装好且没失效的 GPU 会话;没就绪、已回退或已散会为 nil。
  private var gpu: (any ProGPUTranscribing)?
  /// 后台加载任务;没开始、已做完或已散会为 nil。
  private var loader: Task<Void, Never>?
  private var loadingRequested = false
  private var stopped = false
  private var readinessValue: ProGPUReadiness?
  private let hotSpare: any ProHotSpareDecoding
  private let language: @Sendable () -> MeetingLanguage
  private let events: AsyncStream<LiveEngineEvent>.Continuation
  private let hooks: ProRecognizerHooks?
  private var decodeCount = 0
  private var gpuCallCount = 0
  private var fallbackCallIndex: Int?

  /// `language` 每次 decode 读一次;`events` 收回退事件,由调用方在 stop 后结束。
  /// 建好时 GPU 还没加载,要调 `beginLoading()`。
  public init(
    hotSpare: any ProHotSpareDecoding,
    configuration: ProRecognizerConfiguration,
    language: @escaping @Sendable () -> MeetingLanguage,
    events: AsyncStream<LiveEngineEvent>.Continuation
  ) {
    self.hotSpare = hotSpare
    self.configuration = configuration
    self.language = language
    self.events = events
    hooks = nil
  }

  /// 引擎用:另把 GPU 所传语种、静音计数、接手读回与回退序号回报给引擎。
  init(
    hotSpare: any ProHotSpareDecoding,
    configuration: ProRecognizerConfiguration,
    language: @escaping @Sendable () -> MeetingLanguage,
    events: AsyncStream<LiveEngineEvent>.Continuation,
    hooks: ProRecognizerHooks
  ) {
    self.hotSpare = hotSpare
    self.configuration = configuration
    self.language = language
    self.events = events
    self.hooks = hooks
  }

  /// 本场已改用标准识别(GPU 出错,或开录后 1.7B 没能装好)。
  public var fellBack: Bool {
    fallbackCallIndex != nil
  }

  /// 1.7B 装好接手时的读回;还没接手、没能装好为 nil。
  public var readiness: ProGPUReadiness? {
    readinessValue
  }

  /// 开录时调一次:把 1.7B 的加载、建会话与预热放进后台任务,立刻返回。之后的 decode 在接手前都交热备。
  /// 第二次调用、已散会时什么都不做。
  public func beginLoading() {
    guard !loadingRequested, !stopped else { return }
    loadingRequested = true
    let configuration = configuration
    let started = Self.uptimeNanos()
    // 加载与预热都是同步阻塞的 C 调用,放进脱离的任务,不占这个 actor(两路的 decode 照常进来交热备)。
    // 做完回到 actor 装上;actor 已被放掉就随任务结束释放。
    loader = Task.detached(priority: .userInitiated) { [weak self] in
      let outcome = Self.load(configuration, startedAt: started)
      await self?.finishLoading(outcome)
    }
  }

  /// 等后台加载结束(装好、失败或被取消),装上或回退之后才返回。没在加载就立刻返回。
  /// 验证与回放用来让检查从 GPU 已接手开始;产品不等。
  public func loadingFinished() async {
    await loader?.value
  }

  /// 散会:引擎排空两路之后调用。先取消加载任务并等它退出(正在建会话或预热时要等这一步做完,C 调用不能
  /// 中途打断;做完的会话直接丢掉,不再装上),再放掉 GPU 会话。返回时本识别器不再持有 1.7B。
  public func shutdown() async {
    stopped = true
    let pending = loader
    pending?.cancel()
    gpu = nil
    await pending?.value
    loader = nil
  }

  public func decode(_ samples: [Float]) async -> String {
    decodeCount += 1
    let index = decodeCount
    let started = Self.uptimeNanos()
    // 每次 decode 只读一次:交给 GPU 或热备、记进观察与记录的都是这一个语种。
    let selectedLanguage = language()
    let silent = Self.isDigitalSilence(samples)
    if silent {
      hooks?.digitalSilence()
    }

    guard let gpu else {
      // 路径在进来时定:回退之后是 cpu-after-failure;1.7B 还没就绪(或已散会)是 cpu-spare-loading。
      let path: ProDecodePath = fallbackCallIndex == nil ? .cpuSpareLoading : .cpuAfterFailure
      let text = await hotSpare.decode(samples, language: selectedLanguage)
      record(index, path, samples, selectedLanguage, nil, text, started)
      return text
    }
    if silent || samples.count < Self.minimumGPUSamples {
      let text = await hotSpare.decode(samples, language: selectedLanguage)
      let path: ProDecodePath = silent ? .cpuSpareSilence : .cpuSpareShort
      record(index, path, samples, selectedLanguage, nil, text, started)
      return text
    }

    gpuCallCount += 1
    let call = gpuCallCount
    let languageCode = TranscribeGPUSession.languageCode(for: selectedLanguage)
    hooks?.gpuLanguage(
      Qwen3ASRStreamLanguageObservation(
        selectedLanguage: selectedLanguage,
        hasLanguageOption: languageCode != nil,
        languageOptionValue: languageCode
      ))
    let gpuStarted = Self.uptimeNanos()
    let outcome = Self.run(gpu, samples: samples, language: selectedLanguage)
    let gpuEnded = Self.uptimeNanos()

    switch outcome {
    case .result(let result):
      let header =
        configuration.recorder == nil ? nil : Self.protocolHeaderLanguage(in: result.text)
      let attempt = GPUAttempt(
        call: call, languageCode: languageCode, started: gpuStarted, ended: gpuEnded,
        status: result.status.description, injected: false, headerLanguage: header)
      if configuration.faultPlan?.failGPUCallAt == call {
        // 注入:这次照常算完,结果作废,按设备错误处理。
        return await fallBack(
          index, samples, selectedLanguage, attempt.injectingBackend(), started)
      }
      let text = Qwen3ASRTranscriberEngine.removingProtocolHeaders(from: result.text)
      record(index, .gpu, samples, selectedLanguage, attempt, text, started)
      return text
    case .backend(let status):
      let attempt = GPUAttempt(
        call: call, languageCode: languageCode, started: gpuStarted, ended: gpuEnded,
        status: status.description, injected: false, headerLanguage: nil)
      return await fallBack(index, samples, selectedLanguage, attempt, started)
    case .rejected(let status):
      let attempt = GPUAttempt(
        call: call, languageCode: languageCode, started: gpuStarted, ended: gpuEnded,
        status: status, injected: false, headerLanguage: nil)
      if configuration.faultPlan?.failGPUCallAt == call {
        // 注入只认第 N 次,不看那次的结局:被拒的第 N 次同样作废、按设备错误处理。
        return await fallBack(
          index, samples, selectedLanguage, attempt.injectingBackend(), started)
      }
      // 只是这一段没解出来,会话照常可用:不置回退、不发事件,下一段照常走 GPU。
      Self.logger.info(
        "Pro 第 \(call, privacy: .public) 次 GPU 调用没有接收这一段(\(status, privacy: .public)),交热备")
      let text = await hotSpare.decode(samples, language: selectedLanguage)
      record(index, .cpuInputRejected, samples, selectedLanguage, attempt, text, started)
      return text
    }
  }

  /// 加载任务做完回到 actor:装好就从下一段起走 GPU;失败就当场回退(事件 callIndex 0);已散会就丢掉,
  /// 会话随加载任务结束释放。
  private func finishLoading(_ outcome: LoadOutcome) {
    loader = nil
    guard !stopped else { return }
    switch outcome {
    case .ready(let session, let readiness):
      gpu = session
      readinessValue = readiness
      hooks?.ready(readiness)
      let load = String(format: "%.2f", readiness.loadSeconds)
      let warmup = readiness.warmupSeconds.map { String(format: "%.2f", $0) } ?? "n/a"
      let after = String(format: "%.2f", readiness.readyAfterSeconds)
      Self.logger.notice(
        "Pro 1.7B 已接手:加载 \(load, privacy: .public) s,预热 \(warmup, privacy: .public) s,开录后 \(after, privacy: .public) s"
      )
    case .failed(let reason, let injected):
      fallbackCallIndex = 0
      let at = Self.uptimeNanos()
      hooks?.fellBack(0)
      events.yield(.fellBackToStandard(callIndex: 0, at: at))
      let note = injected ? "(注入)" : ""
      Self.logger.notice(
        "Pro 1.7B 开录后没能装好\(note, privacy: .public):\(reason);本场改用标准识别")
    case .cancelled:
      break
    }
  }

  /// 后台加载的结局。
  private enum LoadOutcome: Sendable {
    case ready(any ProGPUTranscribing, ProGPUReadiness)
    case failed(String, injected: Bool)
    /// 散会时被取消;建好的会话(如果有)随它释放。
    case cancelled
  }

  /// 在加载任务里同步执行:加载 GGUF 并建会话,用 0.1 s 噪声预热一次,读回设备。每一步之间看取消。
  /// 预热返回设备错误(ERR_BACKEND / ERR_OOM)与加载失败一样回退;输入被拒不是设备错误,会话照用,
  /// 预热用时记 nil(报告写 n/a,不拿一个没预热的用时充数)。
  private static func load(
    _ configuration: ProRecognizerConfiguration,
    startedAt: UInt64
  ) -> LoadOutcome {
    let session: any ProGPUTranscribing
    do {
      session = try configuration.loadGPU()
    } catch {
      return .failed("加载失败:\(error.localizedDescription)", injected: false)
    }
    let loadedAt = uptimeNanos()
    if Task.isCancelled {
      return .cancelled
    }
    let warmupSeconds: Double?
    do {
      warmupSeconds = try warmUp(session)
    } catch {
      return .failed("预热失败:\(String(describing: error))", injected: false)
    }
    if Task.isCancelled {
      return .cancelled
    }
    if configuration.faultPlan?.failLoad == true {
      return .failed("加载照常做完,按注入当作没装好", injected: true)
    }
    let device = configuration.readDevice(session)
    let readyAt = uptimeNanos()
    return .ready(
      session,
      ProGPUReadiness(
        deviceInfo: device.deviceInfo,
        hasTensor: device.hasTensor,
        requestedThreads: device.requestedThreads,
        loadSeconds: seconds(from: startedAt, to: loadedAt),
        warmupSeconds: warmupSeconds,
        readyAfterSeconds: seconds(from: startedAt, to: readyAt),
        readyAtUptimeNanos: readyAt
      ))
  }

  /// 用 0.1 s 噪声跑一次 GPU,把 Metal 管线的首次编译挪到接手之前,返回用时(秒)。
  /// 设备错误(ERR_BACKEND / ERR_OOM)原样抛出;输入被拒返回 nil,会话照用。
  private static func warmUp(_ gpu: any ProGPUTranscribing) throws -> Double? {
    let started = uptimeNanos()
    do {
      _ = try gpu.run(samples: warmupNoise(), language: .auto)
    } catch TranscribeGPUError.inputRejected(let status) {
      logger.notice("Pro 预热没有被 GPU 接收(\(status.description, privacy: .public)),会话照用")
      return nil
    }
    return seconds(from: started, to: uptimeNanos())
  }

  /// 确定性的均匀噪声,幅度 ±0.01(RMS 约 0.006,远高于静音门 5e-5)。每次相同,预热可复现。
  static func warmupNoise() -> [Float] {
    var state: UInt32 = 0x9E37_79B9
    var samples: [Float] = []
    samples.reserveCapacity(warmupSampleCount)
    for _ in 0..<warmupSampleCount {
      state = state &* 1_664_525 &+ 1_013_904_223
      let unit = Float(state >> 8) / Float(1 << 24)
      samples.append((unit - 0.5) * 0.02)
    }
    return samples
  }

  private static func seconds(from start: UInt64, to end: UInt64) -> Double {
    end >= start ? Double(end - start) / 1_000_000_000 : 0
  }

  /// 设备错误(真的或注入的):先摘掉 GPU、记下失效并当场送出事件,再在同一次调用里用热备重解。
  /// 顺序不能反:await 热备期间进来的 decode 必须已经看到 `gpu == nil`。
  private func fallBack(
    _ index: Int,
    _ samples: [Float],
    _ selectedLanguage: MeetingLanguage,
    _ attempt: GPUAttempt,
    _ started: UInt64
  ) async -> String {
    gpu = nil
    fallbackCallIndex = attempt.call
    let at = Self.uptimeNanos()
    hooks?.fellBack(attempt.call)
    events.yield(.fellBackToStandard(callIndex: attempt.call, at: at))
    let note = attempt.injected ? "(注入)" : ""
    Self.logger.notice(
      "Pro 第 \(attempt.call, privacy: .public) 次 GPU 调用返回 \(attempt.status, privacy: .public)\(note, privacy: .public);本场改用标准识别"
    )
    let text = await hotSpare.decode(samples, language: selectedLanguage)
    record(index, .cpuRedecode, samples, selectedLanguage, attempt, text, started)
    return text
  }

  private func record(
    _ index: Int,
    _ path: ProDecodePath,
    _ samples: [Float],
    _ selectedLanguage: MeetingLanguage,
    _ attempt: GPUAttempt?,
    _ text: String,
    _ started: UInt64
  ) {
    guard let recorder = configuration.recorder else { return }
    recorder(
      ProDecodeRecord(
        index: index,
        path: path,
        gpuCall: attempt?.call,
        samples: samples.count,
        selectedLanguage: selectedLanguage,
        gpuLanguageCode: attempt?.languageCode,
        headerLanguage: path == .gpu ? attempt?.headerLanguage : nil,
        startUptimeNanos: started,
        endUptimeNanos: Self.uptimeNanos(),
        gpuStartUptimeNanos: attempt?.started,
        gpuEndUptimeNanos: attempt?.ended,
        status: attempt?.status,
        injected: attempt?.injected ?? false,
        empty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ))
  }

  /// 一次 GPU 调用的结局。只有 `.backend` 置回退;其他错误(含取消时的 ABORTED)都按这一段被拒处理。
  private enum GPUOutcome {
    case result(TranscribeGPURunResult)
    case backend(TranscribeStatus)
    case rejected(String)
  }

  /// 走过 GPU 的那次 decode 要记下的东西。
  private struct GPUAttempt {
    let call: Int
    let languageCode: String?
    let started: UInt64
    let ended: UInt64
    let status: String
    let injected: Bool
    let headerLanguage: String?

    func injectingBackend() -> GPUAttempt {
      GPUAttempt(
        call: call, languageCode: languageCode, started: started, ended: ended, status: status,
        injected: true, headerLanguage: headerLanguage)
    }
  }

  private static func run(
    _ gpu: any ProGPUTranscribing,
    samples: [Float],
    language: MeetingLanguage
  ) -> GPUOutcome {
    do {
      return .result(try gpu.run(samples: samples, language: language))
    } catch TranscribeGPUError.backend(let status) {
      return .backend(status)
    } catch TranscribeGPUError.inputRejected(let status) {
      return .rejected(status.description)
    } catch {
      return .rejected(String(describing: error))
    }
  }

  /// 协议头 `language Chinese<asr_text>` 里的语种名(清理前的原文);没有带 `<asr_text>` 的头为 nil。
  static func protocolHeaderLanguage(in text: String) -> String? {
    guard text.range(of: "<asr_text>", options: .caseInsensitive) != nil,
      let pattern = try? NSRegularExpression(
        pattern: #"language\s*([A-Za-z]+)\s*<asr_text>"#,
        options: [.caseInsensitive]
      ),
      let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[range])
  }

  private static func isDigitalSilence(_ samples: [Float]) -> Bool {
    guard !samples.isEmpty else {
      return true
    }
    let sumOfSquares = samples.reduce(into: 0.0) { partialResult, sample in
      let value = Double(sample)
      partialResult += value * value
    }
    return sqrt(sumOfSquares / Double(samples.count)) < digitalSilenceRMSThreshold
  }

  private static func uptimeNanos() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  private static let logger = Logger(subsystem: "com.justsaid.app", category: "ProRecognizer")
}
