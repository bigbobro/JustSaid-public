import Foundation

/// 生成中纪要缓冲区的板块。`rawValue` 即模型输出 JSON 的键名(与 `MinutesResponseWire` 对齐)。
public enum PartialMinutesSectionKind: String, CaseIterable, Sendable {
  case coreConclusions
  case keyDiscussions
  case decisions
  case actionItems
  case openQuestions

  /// 板块标题是**结构装饰**:文字来自本固定映射,不是模型正文;
  /// 渲染器只在该板块的键已完整出现在缓冲区里时才画它(D2)。
  public func title(for language: MeetingLanguage) -> String {
    switch (self, language) {
    case (.coreConclusions, .chinese): return "核心结论"
    case (.keyDiscussions, .chinese): return "关键讨论"
    case (.decisions, .chinese): return "决定"
    case (.actionItems, .chinese): return "待办"
    case (.openQuestions, .chinese): return "未决"
    case (.coreConclusions, .english): return "Key Outcomes"
    case (.keyDiscussions, .english): return "Key Discussion"
    case (.decisions, .english): return "Decisions"
    case (.actionItems, .english): return "Action Items"
    case (.openQuestions, .english): return "Open Questions"
    case (_, .auto):
      // 板块标题只在纪要流式渲染中按具体输出语言取用,auto 已被入口过滤。
      preconditionFailure("auto 不是纪要输出语言")
    }
  }

  /// 条目对象闭合时,以这个直接键的字符串值作为条目正文;缺了就整条不渲染,绝不补占位。
  var primaryTextKey: String {
    self == .decisions ? "issue" : "text"
  }

  /// 允许作为「正在写」露出的键:只有这些键的值是模型正文。
  /// `kind`/`owner`/`anchor` 等是结构字段,半截也不得当内容显示(D2)。
  static let contentKeys: Set<String> = ["text", "issue", "rationale", "proposal"]
}

/// 一个已在缓冲区里出现的板块。`items` 只收**完整闭合**条目的正文位置;
/// 板块可以先出现、条目数为零(此时界面只画标题,等正文长出来)。
public struct PartialMinutesSection: Sendable, Equatable {
  public let kind: PartialMinutesSectionKind
  /// 正文在源缓冲区中的原样区间(不解转义、不加工)。
  public let items: [Range<String.Index>]

  public init(kind: PartialMinutesSectionKind, items: [Range<String.Index>]) {
    self.kind = kind
    self.items = items
  }
}

/// 「到此为止能确定的东西」的快照。正文一律以 `Range<String.Index>` 指回 `source`,
/// 让"编造内容"在类型层面就写不出来(design §4):要显示,只能切缓冲区。
public struct PartialMinutesSnapshot: Sendable, Equatable {
  public let source: String
  /// 已出现的板块,按其在缓冲区中的出现顺序(即模型书写顺序)。
  public let completedSections: [PartialMinutesSection]
  /// 正在写、尚未闭合的那段字符串值(原样,不补引号不补闭合);nil = 当前没有在写正文。
  public let inFlight: Range<String.Index>?
  public let inFlightSection: PartialMinutesSectionKind?

  public init(
    source: String,
    completedSections: [PartialMinutesSection],
    inFlight: Range<String.Index>?,
    inFlightSection: PartialMinutesSectionKind?
  ) {
    self.source = source
    self.completedSections = completedSections
    self.inFlight = inFlight
    self.inFlightSection = inFlightSection
  }

  public func text(in range: Range<String.Index>) -> String {
    String(source[range])
  }

  public var inFlightText: String? {
    inFlight.map { String(source[$0]) }
  }

  /// D4/AC6:计数只来自真实解析出的完整条目,是事实不是估算;
  /// 绝不输出百分比或预计剩余(既有红线)。全部板块尚无完整条目时返回 nil。
  public func progressSummary(language: MeetingLanguage) -> String? {
    let parts = completedSections.filter { !$0.items.isEmpty }.map { section in
      language == .english
        ? "\(section.kind.title(for: language)) \(section.items.count)"
        : "\(section.kind.title(for: language)) \(section.items.count) 条"
    }
    guard !parts.isEmpty else { return nil }
    return (language == .english ? "Completed: " : "已生成：")
      + parts.joined(separator: " · ")
  }
}

/// 容忍任意截断的增量解析器:纯函数、无状态、**永不抛错**(R5——解析器是观测,不是产物路径)。
///
/// 输入是可能断在任何一个字符上的模型 JSON(含流首 BOM、```json 围栏等前缀噪音);
/// 输出「到此为止」的快照:未闭合条目不算完成、结构字段的半截值不当正文、缺失字段不补占位。
public enum PartialMinutesScanner {
  private struct Frame {
    enum Kind {
      case object
      case array
    }
    enum Phase {
      case expectKey
      case expectColon
      case expectValue
      case afterValue
    }
    var kind: Kind
    var phase: Phase = .expectKey
    var lastKey: String?
    var isRoot = false
    /// 数组帧:若正是根对象某板块的值,记板块(条目直接收在这里)。
    var arraySection: PartialMinutesSectionKind?
    /// 对象帧:若是板块数组的直接元素(一个条目),记板块。
    var elementSection: PartialMinutesSectionKind?
    /// 向内传播的所在板块(options/updates/anchor 等嵌套仍知道自己属于哪个板块)。
    var enclosingSection: PartialMinutesSectionKind?
    /// 条目对象的主正文区间(直接键 text/issue,首见为准)。
    var primaryRun: Range<String.Index>?
  }

  private enum StringRole {
    case key
    case value
    case element
  }

  public static func scan(_ buffer: String) -> PartialMinutesSnapshot {
    // 与 `parseMinutes` 同规则:跳到第一个 `{`;BOM/```json 围栏/客套话前缀天然被跳过。
    guard let rootStart = buffer.firstIndex(of: "{") else {
      return PartialMinutesSnapshot(
        source: buffer,
        completedSections: [],
        inFlight: nil,
        inFlightSection: nil
      )
    }

    var frames: [Frame] = []
    var sectionOrder: [PartialMinutesSectionKind] = []
    var sectionItems: [PartialMinutesSectionKind: [Range<String.Index>]] = [:]

    var inString = false
    var stringRole = StringRole.key
    var stringStart = rootStart
    var escaped = false

    let scalars = buffer.unicodeScalars
    var index = rootStart
    while index < scalars.endIndex {
      let scalar = scalars[index]
      if inString {
        // 只为找到未转义的收尾引号:`\X` 整体跳过(含 `\"`、`\\`;`\uXXXX` 的
        // 十六进制位是普通字符,无需特判)。断在转义中间时 `escaped` 停在 true,
        // 循环自然结束,不会崩、也不会把半个转义当收尾。
        if escaped {
          escaped = false
        } else if scalar == "\\" {
          escaped = true
        } else if scalar == "\"" {
          let content = stringStart..<index
          switch stringRole {
          case .key:
            if !frames.isEmpty, frames[frames.count - 1].kind == .object {
              frames[frames.count - 1].lastKey = String(buffer[content])
              frames[frames.count - 1].phase = .expectColon
            }
          case .value:
            if !frames.isEmpty, frames[frames.count - 1].kind == .object {
              let top = frames[frames.count - 1]
              if let section = top.elementSection,
                top.lastKey == section.primaryTextKey,
                top.primaryRun == nil
              {
                frames[frames.count - 1].primaryRun = content
              }
              frames[frames.count - 1].phase = .afterValue
            }
          case .element:
            // 板块数组的裸字符串条目(keyDiscussions 等允许的简写形态)。
            if let top = frames.last, top.kind == .array,
              let section = top.arraySection
            {
              sectionItems[section, default: []].append(content)
            }
          }
          inString = false
        }
      } else {
        switch scalar {
        case "\"":
          inString = true
          escaped = false
          stringStart = scalars.index(after: index)
          if let top = frames.last {
            switch top.kind {
            case .array:
              stringRole = .element
            case .object:
              // 异常相位(缺逗号等)按 key 容错:宁可少认内容,不错认结构为正文。
              stringRole = top.phase == .expectValue ? .value : .key
            }
          } else {
            stringRole = .key
          }
        case "{":
          var frame = Frame(kind: .object)
          if let top = frames.last {
            frame.enclosingSection = top.arraySection ?? top.enclosingSection
            if top.kind == .array, let section = top.arraySection {
              frame.elementSection = section
            }
          } else {
            frame.isRoot = true
          }
          frames.append(frame)
        case "}":
          if let top = frames.last, top.kind == .object {
            frames.removeLast()
            // 条目对象完整闭合、且主正文在:这一刻才算一条完成(D2:未闭合不算)。
            if let section = top.elementSection, let run = top.primaryRun {
              sectionItems[section, default: []].append(run)
            }
            if !frames.isEmpty, frames[frames.count - 1].kind == .object {
              frames[frames.count - 1].phase = .afterValue
            }
          }
        case "[":
          var frame = Frame(kind: .array)
          if let top = frames.last {
            frame.enclosingSection = top.arraySection ?? top.enclosingSection
            if top.kind == .object, top.isRoot, top.phase == .expectValue,
              let key = top.lastKey,
              let kind = PartialMinutesSectionKind(rawValue: key)
            {
              // 板块从这一刻起才算「出现」——标题装饰的门(D2)。
              frame.arraySection = kind
              if !sectionOrder.contains(kind) {
                sectionOrder.append(kind)
                sectionItems[kind] = sectionItems[kind] ?? []
              }
            }
          }
          frames.append(frame)
        case "]":
          if let top = frames.last, top.kind == .array {
            frames.removeLast()
            if !frames.isEmpty, frames[frames.count - 1].kind == .object {
              frames[frames.count - 1].phase = .afterValue
            }
          }
        case ":":
          if !frames.isEmpty, frames[frames.count - 1].kind == .object,
            frames[frames.count - 1].phase == .expectColon
          {
            frames[frames.count - 1].phase = .expectValue
          }
        case ",":
          if !frames.isEmpty, frames[frames.count - 1].kind == .object {
            frames[frames.count - 1].phase = .expectKey
          }
        default:
          // 数字/true/false/null/空白:对结构追踪无影响,相位由随后的 `,`/`}` 归位。
          break
        }
      }
      index = scalars.index(after: index)
    }

    // 缓冲区在字符串中间断掉:只有「内容键的值」或「板块数组的裸字符串条目」
    // 才作为正在写的正文露出;半截键名、kind/owner/timecode 等结构值一律不露(D2)。
    var inFlight: Range<String.Index>?
    var inFlightSection: PartialMinutesSectionKind?
    if inString {
      switch stringRole {
      case .key:
        break
      case .value:
        if let top = frames.last, top.kind == .object,
          let key = top.lastKey,
          PartialMinutesSectionKind.contentKeys.contains(key),
          let section = top.elementSection ?? top.enclosingSection
        {
          inFlight = stringStart..<buffer.endIndex
          inFlightSection = section
        }
      case .element:
        if let top = frames.last, top.kind == .array,
          let section = top.arraySection
        {
          inFlight = stringStart..<buffer.endIndex
          inFlightSection = section
        }
      }
    }

    return PartialMinutesSnapshot(
      source: buffer,
      completedSections: sectionOrder.map {
        PartialMinutesSection(kind: $0, items: sectionItems[$0] ?? [])
      },
      inFlight: inFlight,
      inFlightSection: inFlightSection
    )
  }
}
