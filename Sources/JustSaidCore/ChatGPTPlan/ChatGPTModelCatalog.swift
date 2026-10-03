import Foundation

/// 账户模型目录里的一项。`reasoningLevels` 为 nil 表示无法确认该模型支持的推理档位。
public struct ChatGPTModelEntry: Codable, Equatable, Sendable {
  public enum ReasoningSource: String, Codable, Sendable {
    /// 目录本身给出了档位。
    case catalog
    /// 目录没给,按同名模型的官方模型页(2026-10-01 核对)。
    case officialModelPage
    case unknown
  }

  public let slug: String
  public let displayName: String
  public let reasoningLevels: [ReasoningEffortLevel]?
  public let reasoningSource: ReasoningSource

  public init(
    slug: String, displayName: String, reasoningLevels: [ReasoningEffortLevel]?,
    reasoningSource: ReasoningSource
  ) {
    self.slug = slug
    self.displayName = displayName
    self.reasoningLevels = reasoningLevels
    self.reasoningSource = reasoningSource
  }
}

public struct ChatGPTModelCatalog: Equatable, Sendable {
  public let entries: [ChatGPTModelEntry]
  /// 目录条目里出现过的字段名(不含取值),用于核对真实目录形态;不进日志正文。
  public let fieldNames: [String]
}

enum ChatGPTModelCatalogParser {
  /// 官方模型页声明的 `reasoning.effort`(2026-10-01 抓取,见 research/openai-siwc/model-*.md)。
  /// 只按 slug 精确匹配,不做通配或前缀推断;快照后缀等未列名的模型一律视为未知。
  static let officialReasoningLevels: [String: [ReasoningEffortLevel]] = [
    "gpt-6-luna": [.off, .low, .medium, .high, .xhigh, .max],
    "gpt-6.1-sol": [.low, .medium, .high, .xhigh, .max],
  ]

  /// `GET /v1/models` 的 `models` 数组:只保留 `visibility == "list"`,保持服务端顺序。
  static func parse(_ data: Data) throws -> ChatGPTModelCatalog {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = object["models"] as? [[String: Any]]
    else { throw ChatGPTPlanServiceError(kind: .other, code: "malformed_model_catalog") }
    var fieldNames = Set<String>()
    var entries: [ChatGPTModelEntry] = []
    var seen = Set<String>()
    for model in models {
      fieldNames.formUnion(model.keys)
      guard model["visibility"] as? String == "list",
        let slug = model["slug"] as? String, !slug.isEmpty, seen.insert(slug).inserted
      else { continue }
      let displayName = (model["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
      if let levels = catalogLevels(model), !levels.isEmpty {
        entries.append(
          ChatGPTModelEntry(
            slug: slug, displayName: displayName, reasoningLevels: levels,
            reasoningSource: .catalog))
      } else if let levels = officialReasoningLevels[slug] {
        entries.append(
          ChatGPTModelEntry(
            slug: slug, displayName: displayName, reasoningLevels: levels,
            reasoningSource: .officialModelPage))
      } else {
        entries.append(
          ChatGPTModelEntry(
            slug: slug, displayName: displayName, reasoningLevels: nil, reasoningSource: .unknown))
      }
    }
    return ChatGPTModelCatalog(entries: entries, fieldNames: fieldNames.sorted())
  }

  /// 目录若自带档位字段(形态未在文档中承诺),接受字符串数组或 `{effort: …}` 对象数组。
  /// `none` 对应「关」;`minimal` 等 JustSaid 没有的档位忽略。
  private static func catalogLevels(_ model: [String: Any]) -> [ReasoningEffortLevel]? {
    for key in [
      "supported_reasoning_efforts", "supported_reasoning_levels", "reasoning_efforts",
    ] {
      guard let raw = model[key] as? [Any] else { continue }
      let values = raw.compactMap { item -> String? in
        (item as? String) ?? ((item as? [String: Any])?["effort"] as? String)
      }
      let levels = values.compactMap(level(fromWire:))
      return Array(Set(levels)).sorted()
    }
    return nil
  }

  static func level(fromWire value: String) -> ReasoningEffortLevel? {
    switch value {
    case "none": return .off
    case "low": return .low
    case "medium": return .medium
    case "high": return .high
    case "xhigh": return .xhigh
    case "max": return .max
    default: return nil
    }
  }

  static func wire(_ level: ReasoningEffortLevel) -> String {
    switch level {
    case .off: return "none"
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .xhigh: return "xhigh"
    case .max: return "max"
    }
  }
}
