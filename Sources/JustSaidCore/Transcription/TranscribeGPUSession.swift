import Foundation
import JustSaidTranscribe
import Synchronization

/// transcribe.cpp 返回的状态码和库给的说明,打印成 `17:input too long` 这样。
public struct TranscribeStatus: Equatable, Sendable, CustomStringConvertible {
  public let code: Int32
  public let name: String

  init(_ status: transcribe_status) {
    code = Int32(truncatingIfNeeded: status.rawValue)
    name = transcribe_status_string(code).map { String(cString: $0) } ?? "?"
  }

  /// 验证专用:假的 GPU 主识别器造结局用,码与名字由调用方给,不经 C 库。
  @_spi(Verification) public init(code: Int32, name: String) {
    self.code = code
    self.name = name
  }

  public var description: String { "\(code):\(name)" }

  /// `requestAbort()` 打断的 run(ABORTED)。按约定归在 `.inputRejected` 里,调用方用它区分取消。
  public var isAborted: Bool {
    code == Int32(truncatingIfNeeded: TRANSCRIBE_ERR_ABORTED.rawValue)
  }
}

public enum TranscribeGPUError: LocalizedError, Equatable, Sendable {
  /// 模型加载或会话初始化失败;已经建好的部分已释放。
  case loadFailed(TranscribeStatus)
  /// 设备类错误(ERR_BACKEND / ERR_OOM):这个会话不再可靠,持有方弃用并释放它。
  case backend(TranscribeStatus)
  /// 其他非 OK(含 INPUT_TOO_SHORT=21、INPUT_TOO_LONG=17、取消时的 ABORTED=13):
  /// 只是这一段没解出来,会话照常可用。
  case inputRejected(TranscribeStatus)

  public var errorDescription: String? {
    switch self {
    case .loadFailed(let status):
      return "Pro 识别模型加载失败(\(status))"
    case .backend(let status):
      return "GPU 识别遇到设备错误(\(status))"
    case .inputRejected(let status):
      return "GPU 识别没有接收这段音频(\(status))"
    }
  }
}

public struct TranscribeGPURunResult: Equatable, Sendable {
  /// `transcribe_full_text` 的拷贝。
  public let text: String
  /// OK,或带部分结果的 OUTPUT_TRUNCATED / OUTPUT_REPETITION。
  public let status: TranscribeStatus

  /// 产品里只由 `run` 造;验证专用的假 GPU 主识别器(`ProGPUTranscribing`)也用它。
  @_spi(Verification) public init(text: String, status: TranscribeStatus) {
    self.text = text
    self.status = status
  }
}

public struct TranscribeGPUDeviceInfo: Codable, Equatable, Sendable {
  /// ggml 设备名,例如 `MTL0`。
  public let name: String
  /// 人读的设备描述,例如芯片型号。
  public let description: String
  /// 厂商类别:metal / cpu / accel 等。
  public let kind: String
  /// cpu / gpu / igpu / accel。
  public let deviceType: String
  /// 设备自报容量(字节)。Apple 统一内存上是建议的最大工作集,不是物理内存;0 表示没报。
  public let memoryTotalBytes: UInt64
}

/// transcribe.cpp 在 Metal 上的一个模型加一个会话(Pro 模式的 1.7B)。
///
/// 加载与 `run` 都是同步的阻塞 C 调用,由持有者放在自己的后台任务或 actor 里执行。
/// 句柄在 deinit 释放:先会话、后模型(模型必须比由它派生的会话活得久)。
///
/// Safety invariant: single-owner。C 会话不是线程安全的,同一模型同一时刻最多一个
/// `transcribe_run`(transcribe.h 线程约定),所以 `run` 只由持有者串行调用;跨线程只调
/// `requestAbort()`,它只写加锁的取消标志。其余属性在 init 后不再改。
public final class TranscribeGPUSession: @unchecked Sendable {
  /// 会话的 CPU 线程数请求:0 = 库自选。实际线程数 API 不读回,见 `TranscribeRuntimeDiagnostics`。
  public static let requestedThreads: Int32 = 0

  /// 模型实际所在的设备;读不到为 nil。
  public let deviceInfo: TranscribeGPUDeviceInfo?
  /// 实际绑定的后端(`transcribe_model_backend`),用来识别「要了 GPU 却落在 CPU」。
  public let backend: String
  public let architecture: String
  public let variant: String
  /// 这个会话收得下的最长音频(毫秒),超过就是 INPUT_TOO_LONG;没有上限或读不到为 nil。
  public let effectiveMaxAudioMilliseconds: Int64?

  private let model: OpaquePointer
  private let session: OpaquePointer
  private let abortFlag: TranscribeAbortFlag

  /// 链接的 transcribe.cpp 版本与构建提交,例如 `0.4.0 (f1dcd15)`。
  public static var libraryVersion: String {
    "\(cString(transcribe_version())) (\(cString(transcribe_version_commit())))"
  }

  /// 第一次调用会注册后端:建 Metal 设备、编内嵌着色器库,可能要几秒;之后很快。
  public static func registeredDevices() -> [TranscribeGPUDeviceInfo] {
    TranscribeRuntimeLog.install()
    let count = Int(transcribe_device_count())
    return (0..<max(count, 0)).compactMap { index in
      guard let device = transcribe_device_get(Int32(index)) else { return nil }
      return readDeviceInfo(device)
    }
  }

  /// 与会中语种一致:自动 = nil(由模型自判),中文 zh,英文 en。
  public static func languageCode(for language: MeetingLanguage) -> String? {
    switch language {
    case .auto:
      return nil
    case .chinese:
      return "zh"
    case .english:
      return "en"
    }
  }

  /// 以 Metal 后端加载模型并建会话(n_threads 0)。任一步失败就释放已建的部分并抛 `.loadFailed`。
  public init(modelURL: URL) throws {
    // 正常路径在进程启动时已经装好;这里只兜底,保证设备初始化的日志进诊断。
    TranscribeRuntimeLog.install()

    var loadParams = transcribe_model_load_params()
    transcribe_model_load_params_init(&loadParams)
    loadParams.backend = TRANSCRIBE_BACKEND_METAL
    var loadedModel: OpaquePointer?
    let loaded = transcribe_model_load_file(modelURL.path, &loadParams, &loadedModel)
    guard loaded == TRANSCRIBE_OK, let model = loadedModel else {
      transcribe_model_free(loadedModel)
      throw TranscribeGPUError.loadFailed(TranscribeStatus(loaded))
    }

    var sessionParams = transcribe_session_params()
    transcribe_session_params_init(&sessionParams)
    sessionParams.n_threads = TranscribeGPUSession.requestedThreads
    var openedSession: OpaquePointer?
    let opened = transcribe_session_init(model, &sessionParams, &openedSession)
    guard opened == TRANSCRIBE_OK, let session = openedSession else {
      transcribe_session_free(openedSession)
      transcribe_model_free(model)
      throw TranscribeGPUError.loadFailed(TranscribeStatus(opened))
    }

    var limits = transcribe_session_limits()
    transcribe_session_limits_init(&limits)
    if transcribe_session_get_limits(session, &limits) == TRANSCRIBE_OK,
      limits.effective_max_audio_ms > 0
    {
      effectiveMaxAudioMilliseconds = limits.effective_max_audio_ms
    } else {
      effectiveMaxAudioMilliseconds = nil
    }
    if let device = transcribe_model_device(model) {
      deviceInfo = TranscribeGPUSession.readDeviceInfo(device)
    } else {
      deviceInfo = nil
    }
    backend = cString(transcribe_model_backend(model))
    architecture = cString(transcribe_model_arch_string(model))
    variant = cString(transcribe_model_variant_string(model))

    // 回调在 run 线程、两个解码步之间读标志。标志对象由本实例持有,deinit 先释放会话,
    // 所以回调里的裸指针始终有效。
    let flag = TranscribeAbortFlag()
    transcribe_set_abort_callback(
      session,
      { userData in
        guard let userData else { return false }
        return Unmanaged<TranscribeAbortFlag>.fromOpaque(userData).takeUnretainedValue()
          .isRequested
      },
      Unmanaged.passUnretained(flag).toOpaque()
    )
    self.model = model
    self.session = session
    abortFlag = flag
  }

  deinit {
    transcribe_session_free(session)
    transcribe_model_free(model)
  }

  /// 解一段 16 kHz 单声道 PCM。OK、OUTPUT_TRUNCATED、OUTPUT_REPETITION 算有结果;
  /// ERR_BACKEND / ERR_OOM 抛 `.backend`;其他非 OK 抛 `.inputRejected`。
  public func run(samples: [Float], language: MeetingLanguage) throws -> TranscribeGPURunResult {
    guard !abortFlag.isRequested else {
      throw TranscribeGPUError.inputRejected(TranscribeStatus(TRANSCRIBE_ERR_ABORTED))
    }
    guard !samples.isEmpty, samples.count <= Int(Int32.max) else {
      throw TranscribeGPUError.inputRejected(TranscribeStatus(TRANSCRIBE_ERR_INVALID_ARG))
    }
    var params = transcribe_run_params()
    transcribe_run_params_init(&params)
    let languageCode = TranscribeGPUSession.languageCode(for: language)
    let status: transcribe_status = withOptionalCString(languageCode) { code in
      params.language = code
      return samples.withUnsafeBufferPointer { buffer in
        transcribe_run(session, buffer.baseAddress, Int32(buffer.count), &params)
      }
    }
    if status == TRANSCRIBE_OK || status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED
      || status == TRANSCRIBE_ERR_OUTPUT_REPETITION
    {
      // 文本指针归会话所有,下一次 run 就失效,当场拷贝。
      return TranscribeGPURunResult(
        text: cString(transcribe_full_text(session)),
        status: TranscribeStatus(status)
      )
    }
    if status == TRANSCRIBE_ERR_BACKEND || status == TRANSCRIBE_ERR_OOM {
      throw TranscribeGPUError.backend(TranscribeStatus(status))
    }
    throw TranscribeGPUError.inputRejected(TranscribeStatus(status))
  }

  /// 任意线程可调。正在跑的 run 在下一个解码步返回 ABORTED(编码器中途打断不了);
  /// 之后的 run 直接拒收。取消后的会话只等释放。
  public func requestAbort() {
    abortFlag.request()
  }

  private static func readDeviceInfo(_ device: OpaquePointer) -> TranscribeGPUDeviceInfo? {
    var info = transcribe_device_info()
    transcribe_device_info_init(&info)
    guard transcribe_device_get_info(device, &info) == TRANSCRIBE_OK else { return nil }
    return TranscribeGPUDeviceInfo(
      name: cString(info.name),
      description: cString(info.description),
      kind: cString(info.kind),
      deviceType: deviceTypeName(info.device_type),
      memoryTotalBytes: info.memory_total
    )
  }
}

/// 取消标志:`requestAbort()` 在任意线程置位,C 回调在 run 线程读。
private final class TranscribeAbortFlag: Sendable {
  private let requested = Mutex(false)

  var isRequested: Bool {
    requested.withLock { $0 }
  }

  func request() {
    requested.withLock { $0 = true }
  }
}

private func cString(_ pointer: UnsafePointer<CChar>?) -> String {
  pointer.map { String(cString: $0) } ?? ""
}

private func deviceTypeName(_ type: transcribe_device_type) -> String {
  switch type {
  case TRANSCRIBE_DEVICE_TYPE_CPU:
    return "cpu"
  case TRANSCRIBE_DEVICE_TYPE_GPU:
    return "gpu"
  case TRANSCRIBE_DEVICE_TYPE_IGPU:
    return "igpu"
  case TRANSCRIBE_DEVICE_TYPE_ACCEL:
    return "accel"
  default:
    return "unknown(\(type.rawValue))"
  }
}

private func withOptionalCString<Result>(
  _ value: String?,
  _ body: (UnsafePointer<CChar>?) throws -> Result
) rethrows -> Result {
  guard let value else { return try body(nil) }
  return try value.withCString { try body($0) }
}
