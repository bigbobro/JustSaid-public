import AVFAudio
import Foundation
import OSLog
import SherpaOnnx

public final class SenseVoiceTranscriberEngine: TranscriberEngine,
  TranscriberASRAnchorGapFramesProviding,
  TranscriberLiveEmissionStatsProviding,
  @unchecked Sendable
{
  public static let maximumSpeechSegmentDuration =
    LocalOfflineTranscriptionPolicy.maximumSpeechSegmentDuration

  public static func defaultModelDirectory(
    fileManager: FileManager = .default
  ) -> URL {
    LocalOfflineModelPaths.modelsDirectory(fileManager: fileManager)
      .appendingPathComponent("SenseVoice-Small", isDirectory: true)
  }

  public static func defaultVADModelURL(
    fileManager: FileManager = .default
  ) -> URL {
    LocalOfflineModelPaths.defaultVADModelURL(fileManager: fileManager)
  }

  private let modelDirectory: URL
  private let vadModelURL: URL
  private let runtime = LocalOfflineTranscriptionRuntime(
    engineDisplayName: "SenseVoice",
    loggerCategory: "SenseVoiceTranscriber"
  )
  private let stateLock = NSLock()
  private var configuredLanguageTokenStorage: String?

  public var results: AsyncStream<TranscriptSegment> { runtime.results }

  /// 本场识别器**实际拿到**的 SenseVoice 语言 token,从交给 C API 的那个配置结构体
  /// 读回(不是入参回显)。`nil` = 还没启动;`""` = `lang_auto`。
  /// 会中语种锁定只能靠这条取证:LID 是模型行为,转写文本证明不了参数有没有传到。
  public var configuredLanguageToken: String? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return configuredLanguageTokenStorage
  }

  public init(
    modelDirectory: URL = SenseVoiceTranscriberEngine.defaultModelDirectory(),
    vadModelURL: URL = SenseVoiceTranscriberEngine.defaultVADModelURL()
  ) {
    self.modelDirectory = modelDirectory
    self.vadModelURL = vadModelURL
  }

  /// sherpa-onnx 只认裸语言码:`auto/zh/en/ja/ko/yue`,空串等价 `auto`
  /// (`offline-sense-voice-model-config.cc` 的 `Validate()`)。
  /// **不能传 `"zh-CN"`**——`Validate()` 会失败、C 侧返回 nullptr、
  /// Swift wrapper 直接 `fatalError`,整场速记当场死。
  public static func languageToken(for language: MeetingLanguage) -> String {
    switch language {
    case .auto:
      // 空串 → `offline-recognizer-sense-voice-impl.h` 取 token 0 = `lang_auto`。
      // 「自动」就是要模型自己判 zh/en/ja/ko/yue,不得钉死。
      return ""
    case .chinese:
      return "zh"
    case .english:
      return "en"
    }
  }

  public func start(language: MeetingLanguage) async throws {
    try runtime.start(vadModelURL: vadModelURL) { [self] in
      let modelFiles = try SenseVoiceModelFiles(directory: modelDirectory)
      let recognizer = SenseVoiceRecognizer(
        modelFiles: modelFiles,
        languageToken: Self.languageToken(for: language)
      )
      storeConfiguredLanguageToken(recognizer.configuredLanguageToken)
      // notice 级才落盘可取证:会中出错语种时,散会后要能证明识别器收到的是哪个 token。
      Logger(
        subsystem: "com.justsaid.app",
        category: "SenseVoiceTranscriber"
      ).notice(
        "SenseVoice 语种锁定 selected=\(language.rawValue, privacy: .public) languageToken=\(recognizer.configuredLanguageToken.isEmpty ? "lang_auto" : recognizer.configuredLanguageToken, privacy: .public)"
      )
      return recognizer
    }
  }

  public func feed(
    _ pcmBuffer: AVAudioPCMBuffer,
    source: AudioSource,
    at captureTime: TimeInterval
  ) throws {
    try runtime.feed(pcmBuffer, source: source, at: captureTime)
  }

  public func asrAnchorGapFrames(for source: AudioSource) -> UInt64 {
    runtime.asrAnchorGapFrames(for: source)
  }

  public func liveEmissionStats(for source: AudioSource) -> LiveEmissionStats {
    runtime.liveEmissionStats(for: source)
  }

  public func stop() async {
    await runtime.stop()
  }

  private func storeConfiguredLanguageToken(_ token: String) {
    stateLock.lock()
    configuredLanguageTokenStorage = token
    stateLock.unlock()
  }
}

private struct SenseVoiceModelFiles: Sendable {
  let model: URL
  let tokens: URL

  init(
    directory: URL,
    fileManager: FileManager = .default
  ) throws {
    model = directory.appendingPathComponent("model.int8.onnx")
    tokens = directory.appendingPathComponent("tokens.txt")
    let missing = [model, tokens].filter {
      !fileManager.isReadableFile(atPath: $0.path)
    }
    guard missing.isEmpty else {
      throw TranscriberEngineError.missingLocalModel(
        engine: "SenseVoice-Small int8",
        directory: directory,
        missingFiles: missing.map(\.lastPathComponent)
      )
    }
  }
}

private actor SenseVoiceRecognizer: OfflineSpeechRecognizer {
  private let recognizer: SherpaOnnxOfflineRecognizer

  /// 从**已构造好的**配置结构体读回的语言 token(`""` = `lang_auto`)。
  /// 读回而不是回显入参:入参回显证明不了参数真的进了 `SherpaOnnxOfflineSenseVoiceModelConfig`,
  /// 而 08-10 的缺陷形态恰恰是「上游算对了、构造时漏传」。
  nonisolated let configuredLanguageToken: String

  /// `languageToken` 故意不给默认值:漏传就编译不过。
  /// (08-10 缺陷形态就是 wrapper 的 `language: String = ""` 默认值把漏传变成静默的
  /// `lang_auto`。)
  init(modelFiles: SenseVoiceModelFiles, languageToken: String) {
    let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
      model: modelFiles.model.path,
      language: languageToken,
      useInverseTextNormalization: true
    )
    // 必须在同一作用域内立刻拷成 String:`toCPointer` 走的是
    // `(s as NSString).utf8String`,指针只在自动释放池排干前有效。
    configuredLanguageToken = String(cString: senseVoice.language)
    let model = sherpaOnnxOfflineModelConfig(
      tokens: modelFiles.tokens.path,
      numThreads: 6,
      provider: "cpu",
      debug: 0,
      senseVoice: senseVoice
    )
    let features = sherpaOnnxFeatureConfig(
      sampleRate: 16_000,
      featureDim: 80
    )
    var config = sherpaOnnxOfflineRecognizerConfig(
      featConfig: features,
      modelConfig: model
    )
    recognizer = SherpaOnnxOfflineRecognizer(config: &config)
  }

  func decode(_ samples: [Float]) -> String {
    recognizer.decode(samples: samples, sampleRate: 16_000).text
  }
}
