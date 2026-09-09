import Foundation

public enum TranscriberEngineError: LocalizedError, Sendable {
  case unsupportedProvider(String)
  case unsupportedLocale(String)
  case missingLocalModel(engine: String, directory: URL, missingFiles: [String])
  case audioFormatUnavailable
  case invalidState(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedProvider(let providerID):
      return "未知的会中速记引擎：\(providerID)"
    case .unsupportedLocale(let localeIdentifier):
      return "会中速记引擎不支持语言：\(localeIdentifier)"
    case .missingLocalModel(let engine, _, let missingFiles):
      return
        "\(engine) 模型缺失：\(missingFiles.joined(separator: "、"))。"
        + "请打开 JustSaid 的模型准备页或设置，下载并安装缺失的模型。"
    case .audioFormatUnavailable:
      return "会中速记引擎没有可用的音频格式"
    case .invalidState(let detail):
      return "会中速记引擎状态无效：\(detail)"
    }
  }
}

public struct TranscriberEngineFactory: Sendable {
  public init() {}

  public func make(providerID: String) throws -> any TranscriberEngine {
    switch providerID {
    case "apple-speech-analyzer":
      if #available(macOS 26.0, *) {
        #if canImport(Speech)
          return SpeechAnalyzerTranscriberEngine()
        #else
          throw TranscriberEngineError.unsupportedProvider(providerID)
        #endif
      }
      throw TranscriberEngineError.unsupportedProvider(providerID)
    case "sensevoice-small":
      return SenseVoiceTranscriberEngine()
    case "qwen3-asr-0.6b":
      return Qwen3ASRTranscriberEngine()
    default:
      throw TranscriberEngineError.unsupportedProvider(providerID)
    }
  }
}
