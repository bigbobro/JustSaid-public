import Foundation

/// 本地 JSON sidecar 的统一文本边界。类型本身保持纯数据模型；真正写盘或从盘读取时，
/// 所有字符串值都经过与 Markdown 相同的清理器，字段名与 JSON 结构不改。
///
/// 公开是为了让 `MeetingStoreVerification` 直接断言非法浮点回环(08-13 D2.5)；
/// 生产代码只在 Persistence/Summary 写读 sidecar 处调用。
public enum StructuredArtifactCodec {
  /// 非法浮点(NaN/±Inf)的字符串词面。`JSONEncoder` 默认对它们抛错——08-13 诊断
  /// 疑因带非法 Double 锚点的行动项让散会最终快照整份未写出。转成字符串占位,
  /// 解码侧以同一组词面还原,一个坏数字不再毁掉整份 sidecar。
  private static let positiveInfinityToken = "Infinity"
  private static let negativeInfinityToken = "-Infinity"
  private static let nanToken = "NaN"

  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: positiveInfinityToken,
      negativeInfinity: negativeInfinityToken,
      nan: nanToken
    )
    let encoded = try encoder.encode(value)
    return try sanitizedJSONData(from: encoded)
  }

  public static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data
  ) throws -> T {
    let sanitized = try sanitizedJSONData(from: data)
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: positiveInfinityToken,
      negativeInfinity: negativeInfinityToken,
      nan: nanToken
    )
    return try decoder.decode(type, from: sanitized)
  }

  private static func sanitizedJSONData(from data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(
      withJSONObject: sanitize(object),
      options: [.sortedKeys]
    )
  }

  private static func sanitize(_ value: Any) -> Any {
    if let text = value as? String {
      return TextAssetSanitizer.sanitize(text)
    }
    if let values = value as? [Any] {
      return values.map(sanitize)
    }
    if let values = value as? [String: Any] {
      return values.mapValues(sanitize)
    }
    return value
  }
}
