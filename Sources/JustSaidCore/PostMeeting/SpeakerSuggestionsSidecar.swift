import Foundation

extension MeetingPaths {
  /// 认名建议 sidecar(08-20 naming-first)。刻意独立成文件、不预建/不改写 minutes.json:
  /// minutes.json 的字节指纹是核对队列(CheckQueueBuilder)的版本凭据,碰它会污染判定。
  /// 红线:本文件是建议性产物,**绝不计入完整性(completeness)判定**,缺失≠会议残缺;
  /// 会议包导出按名单挑文件,天然不带它。
  public var speakerSuggestionsSidecar: URL {
    directory.appendingPathComponent("speaker-suggestions.json")
  }
}

/// 精转完成后轻量认名提取的落盘产物(08-20 naming-first R1)。
///
/// `suggestions` 元素与 minutes.json v2 的 `SpeakerNameSuggestion` 完全同构(复用类型);
/// `transcriptFingerprint` 是生成时输入 transcript.md 的字节指纹(SHA-256 hex,与
/// `MinutesFingerprint` 同口径),读取端凭它判定建议是否过期——精转重跑后旧建议作废,
/// 回落 minutes.json。
public struct SpeakerSuggestionsSidecar: Codable, Equatable, Sendable {
  public let version: Int
  public let generatedAt: Date
  /// 生成这批建议的模型名(账目对照用,原样展示口径同 cloudUsage)。
  public let model: String
  public let transcriptFingerprint: String
  public let suggestions: [SpeakerNameSuggestion]

  public init(
    version: Int = 1,
    generatedAt: Date = Date(),
    model: String,
    transcriptFingerprint: String,
    suggestions: [SpeakerNameSuggestion]
  ) {
    self.version = version
    self.generatedAt = generatedAt
    self.model = model
    self.transcriptFingerprint = transcriptFingerprint
    self.suggestions = suggestions
  }

  public static func load(from paths: MeetingPaths) -> SpeakerSuggestionsSidecar? {
    guard let data = try? Data(contentsOf: paths.speakerSuggestionsSidecar) else {
      return nil
    }
    return try? StructuredArtifactCodec.decode(SpeakerSuggestionsSidecar.self, from: data)
  }

  public func write(to paths: MeetingPaths) throws {
    try StructuredArtifactCodec.encode(self)
      .write(to: paths.speakerSuggestionsSidecar, options: .atomic)
  }

  /// 本批建议是否仍对应这份转写字节。
  public func matches(transcriptData: Data) -> Bool {
    transcriptFingerprint == MinutesFingerprint.hex(of: transcriptData)
  }

  /// 读取优先级(08-20 naming-first design 决策 6)的**唯一结算点**:
  /// sidecar 在场且指纹与当前 transcript.md 字节匹配 → 只用 sidecar;
  /// 否则回落 minutes.json 的 speakerSuggestions(老会议/提取失败/精转重跑后过期)。
  /// **两源绝不合并**——合并会产生重复行与来历不明的建议。
  public static func resolvedSuggestions(
    paths: MeetingPaths,
    structuredMinutesFallback: () -> [SpeakerNameSuggestion]?
  ) -> [SpeakerNameSuggestion] {
    if let sidecar = load(from: paths),
      let transcriptData = try? Data(contentsOf: paths.transcript),
      sidecar.matches(transcriptData: transcriptData)
    {
      return sidecar.suggestions
    }
    return structuredMinutesFallback() ?? []
  }

  /// 便捷入口:回落源由本函数自己解码 minutes.json(调用方手头没有已解码文档时用;
  /// `MeetingArtifacts.read` 已解码过的走上面带 fallback 闭包的重载,避免二次解码)。
  public static func resolvedSuggestions(
    paths: MeetingPaths
  ) -> [SpeakerNameSuggestion] {
    resolvedSuggestions(paths: paths) {
      guard let data = try? Data(contentsOf: paths.minutesStructured) else {
        return nil
      }
      return
        (try? StructuredArtifactCodec.decode(MeetingMinutesDocument.self, from: data))?
        .speakerSuggestions
    }
  }
}
