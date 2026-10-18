import Foundation
import JustSaidTranscribe
import OSLog
import Synchronization

/// transcribe.cpp 运行时日志里的读回(Pro 模式)。设备结构里没有 has_tensor,
/// ggml-metal 只在初始化日志里报它,所以从日志读;没见到的项保持 nil,上层报「未核实」,不硬造。
public struct TranscribeRuntimeDiagnostics: Codable, Equatable, Sendable {
  /// `ggml_metal_device_init: has tensor = true|false` 的值。
  public internal(set) var hasTensor: Bool?
  /// has_tensor 的来源行原文。
  public internal(set) var hasTensorLine: String?
  public internal(set) var gpuName: String?
  /// 每行 `GPU family:` 的值,例如 `MTLGPUFamilyApple9  (1009)`。
  public internal(set) var gpuFamilies: [String] = []
  /// 着色器内嵌时 ggml-metal 打的 `using embedded metal library` 原文。
  public internal(set) var embeddedLibraryLine: String?
  /// `loaded N libraries from embedded data in X sec` 里的 X:内嵌着色器库的编译耗时。
  public internal(set) var libraryLoadSeconds: Double?
  /// 第一行含 offload 的日志;没有就是 nil(层是否卸到 GPU 未核实)。
  public internal(set) var offloadLine: String?
  /// 第一行含 n_threads 的日志;没有就是 nil(实际线程数未核实)。
  public internal(set) var threadsLine: String?
  /// ggml-metal 的 info / warn / error 行,最多 64 行。
  public internal(set) var metalLines: [String] = []
  /// ERROR 级的行,只留前 32 行;`errorCount` 是总数。
  public internal(set) var errorLines: [String] = []
  public internal(set) var errorCount = 0
}

/// transcribe.cpp 与 ggml 的日志出口。进程启动时装一次钩子,之后日志不再写 stderr,
/// 转到 OSLog(category TranscribeRuntime),并把 Metal 初始化几行和 GPU 错误收进诊断。
public enum TranscribeRuntimeLog {
  /// 进程启动时调用(App 启动、验证程序 main 开头),必须早于任何设备查询或模型加载
  /// (transcribe.h 线程约定)。重复调用无副作用。
  public static func install() {
    _ = installation
  }

  /// 目前收到的读回。任意线程可调。
  public static func snapshot() -> TranscribeRuntimeDiagnostics {
    collector.snapshot()
  }

  private static let logger = Logger(subsystem: "com.justsaid.app", category: "TranscribeRuntime")
  private static let collector = TranscribeLogCollector()

  /// static let 由运行时保证只初始化一次且线程安全,所以 transcribe_log_set 只会调一次。
  /// 回调是 C 函数指针,不能捕获上下文,只经静态成员转发。
  private static let installation: Void = {
    transcribe_log_set(
      { level, message, _ in
        guard let message else { return }
        TranscribeRuntimeLog.receive(level, String(cString: message))
      },
      nil
    )
  }()

  /// 回调可能来自任何线程(含 ggml 工作线程)。拼行与记录在锁内,写 OSLog 在锁外。
  private static func receive(_ level: transcribe_log_level, _ text: String) {
    for line in collector.append(text, level: TranscribeLogLine.Level(level)) {
      forward(line)
    }
  }

  /// ggml-metal 行只有设备名、GPU family、开关与耗时,公开记录并用 notice 落盘,供诊断包取证;
  /// 其他行可能带模型路径,保持默认隐私。
  private static func forward(_ line: TranscribeLogLine) {
    let text = line.text
    if line.isMetal {
      switch line.level {
      case .error:
        logger.error("\(text, privacy: .public)")
      case .warn, .info:
        logger.notice("\(text, privacy: .public)")
      case .debug:
        logger.debug("\(text, privacy: .public)")
      }
    } else {
      switch line.level {
      case .error:
        logger.error("\(text)")
      case .warn:
        logger.notice("\(text)")
      case .info:
        logger.info("\(text)")
      case .debug:
        logger.debug("\(text)")
      }
    }
  }
}

private struct TranscribeLogLine: Sendable {
  enum Level: Sendable {
    case error
    case warn
    case info
    case debug

    /// CONT 是上一条消息的续片,返回 nil。
    init?(_ level: transcribe_log_level) {
      switch level {
      case TRANSCRIBE_LOG_LEVEL_ERROR:
        self = .error
      case TRANSCRIBE_LOG_LEVEL_WARN:
        self = .warn
      case TRANSCRIBE_LOG_LEVEL_DEBUG:
        self = .debug
      case TRANSCRIBE_LOG_LEVEL_CONT:
        return nil
      default:
        self = .info
      }
    }
  }

  let level: Level
  let text: String

  /// 去掉首尾空白;空行返回 nil。
  init?(level: Level, raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    self.level = level
    text = trimmed
  }

  var isMetal: Bool {
    text.hasPrefix("ggml_metal") || text.hasPrefix("ggml_backend_metal")
  }
}

/// Safety: 全部可变状态在 `state` 这把 Mutex 里,类本身只有 let。
private final class TranscribeLogCollector: Sendable {
  private struct State {
    var pending = ""
    var pendingLevel = TranscribeLogLine.Level.info
    var diagnostics = TranscribeRuntimeDiagnostics()
  }

  /// 一直不换行的片段攒到这么长就当一行处理,免得无限增长。
  private static let pendingLimit = 4_096
  private let state = Mutex(State())

  /// ggml 的消息以换行结尾,也可能拆成 CONT 续片;按换行切成整行再记录。
  func append(_ text: String, level: TranscribeLogLine.Level?) -> [TranscribeLogLine] {
    state.withLock { current in
      var raw: [(TranscribeLogLine.Level, String)] = []
      if let level {
        if !current.pending.isEmpty {
          raw.append((current.pendingLevel, current.pending))
          current.pending = ""
        }
        current.pendingLevel = level
      }
      current.pending += text
      while let newline = current.pending.firstIndex(of: "\n") {
        raw.append((current.pendingLevel, String(current.pending[..<newline])))
        current.pending.removeSubrange(...newline)
      }
      if current.pending.utf8.count > Self.pendingLimit {
        raw.append((current.pendingLevel, current.pending))
        current.pending = ""
      }
      let lines = raw.compactMap { TranscribeLogLine(level: $0.0, raw: $0.1) }
      for line in lines {
        current.diagnostics.record(line)
      }
      return lines
    }
  }

  /// 还没等到换行的最后一段也算进读回,但不从缓冲里取走。
  func snapshot() -> TranscribeRuntimeDiagnostics {
    state.withLock { current in
      var diagnostics = current.diagnostics
      if let line = TranscribeLogLine(level: current.pendingLevel, raw: current.pending) {
        diagnostics.record(line)
      }
      return diagnostics
    }
  }
}

extension TranscribeRuntimeDiagnostics {
  fileprivate mutating func record(_ line: TranscribeLogLine) {
    let text = line.text
    if line.level == .error {
      errorCount += 1
      if errorLines.count < 32 {
        errorLines.append(text)
      }
    }
    if line.isMetal, line.level != .debug, metalLines.count < 64 {
      metalLines.append(text)
    }
    if let value = Self.value(after: "has tensor", in: text, separator: "=") {
      hasTensorLine = text
      switch value {
      case "true":
        hasTensor = true
      case "false":
        hasTensor = false
      default:
        hasTensor = nil
      }
    }
    if let family = Self.value(after: "GPU family:", in: text), !gpuFamilies.contains(family) {
      gpuFamilies.append(family)
    }
    if gpuName == nil, let name = Self.value(after: "GPU name:", in: text) {
      gpuName = name
    }
    if text.contains("embedded metal library") {
      embeddedLibraryLine = text
    }
    if let range = text.range(of: "from embedded data in ") {
      let number = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
      libraryLoadSeconds = Double(String(number))
    }
    if offloadLine == nil, text.range(of: "offload", options: .caseInsensitive) != nil {
      offloadLine = text
    }
    if threadsLine == nil, text.contains("n_threads") {
      threadsLine = text
    }
  }

  /// `marker` 之后的值;给了 `separator` 就取它之后的部分。去首尾空白,空值返回 nil。
  private static func value(
    after marker: String,
    in text: String,
    separator: String? = nil
  ) -> String? {
    guard let markerRange = text.range(of: marker) else { return nil }
    var rest = text[markerRange.upperBound...]
    if let separator {
      guard let separatorRange = rest.range(of: separator) else { return nil }
      rest = rest[separatorRange.upperBound...]
    }
    let value = rest.trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : value
  }
}
