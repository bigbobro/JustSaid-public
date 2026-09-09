import Foundation

/// 渐进渲染结果:一串可按行画出的投影。
///
/// **子串纪律的类型层落地(D2/AC2)**:正文行只携带 `Range<String.Index>`,
/// 显示文字必须经 `text(for:)` 从 `source` 切出——渲染层没有任何自由文本出口,
/// 「编一段缓冲区里没有的话」在这里写不出来。允许的装饰仅限:
/// 板块标题(`PartialMinutesSectionKind.title(for:)` 固定映射)、列表符号、未完成光标,
/// 全部由 UI 按 `Line` 的 case 添加,不携带正文。
public struct PartialMinutesRendering: Sendable, Equatable {
  public enum Line: Sendable, Equatable {
    /// 板块标题:只在该板块已出现在缓冲区里时存在;标题文字走固定映射,不是正文。
    case sectionHeading(PartialMinutesSectionKind)
    /// 一条完整条目的正文(缓冲区区间)。
    case item(Range<String.Index>)
    /// 正在写的半截正文(缓冲区区间,原样,不补全);UI 以光标标记未完成。
    case inFlight(Range<String.Index>)
  }

  public let source: String
  public let lines: [Line]

  public init(source: String, lines: [Line]) {
    self.source = source
    self.lines = lines
  }

  /// 正文行 → 从源缓冲区切出的原样文字;标题行返回 nil(标题是装饰,不走这里)。
  public func text(for line: Line) -> String? {
    switch line {
    case .sectionHeading:
      return nil
    case .item(let range), .inFlight(let range):
      return String(source[range])
    }
  }
}

/// 纯函数投影:快照 → 行序列。不新增内容、不重排(板块顺序 = 模型书写顺序)、
/// 不把未完成的画成完成的。
public enum PartialMinutesRenderer {
  public static func render(_ snapshot: PartialMinutesSnapshot) -> PartialMinutesRendering {
    var lines: [PartialMinutesRendering.Line] = []
    for section in snapshot.completedSections {
      lines.append(.sectionHeading(section.kind))
      for item in section.items {
        lines.append(.item(item))
      }
      if snapshot.inFlightSection == section.kind, let inFlight = snapshot.inFlight {
        lines.append(.inFlight(inFlight))
      }
    }
    return PartialMinutesRendering(source: snapshot.source, lines: lines)
  }
}
