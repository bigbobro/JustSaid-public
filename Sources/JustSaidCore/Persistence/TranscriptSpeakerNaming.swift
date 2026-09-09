import Foundation

/// 转写里的一段发言,说话人已按「全局映射 + 单段覆盖」结算成最终显示名。
public struct TranscriptSpeechLine: Equatable, Sendable {
  /// 在 `transcript.md` 里的行序(从 0 起),同时是单段覆盖键的一半。
  public let index: Int
  public let timestamp: String
  /// 转写原文里的说话人字段(`我` / `发言人 2` / `其他人（…）`),永远是原始值。
  public let originalSpeaker: String
  /// 结算后的显示名:单段覆盖 > 全局映射 > 原始标签。
  public let speaker: String
  public let text: String

  public var isMe: Bool { speaker == TranscriptSpeakerNaming.selfSpeakerLabel }

  public var overrideKey: String {
    TranscriptSpeakerNaming.overrideKey(timestamp: timestamp, index: index)
  }
}

/// 详情页要渲染的一行:能解析成发言的走 `speech`,空行与非标准行原样走 `plain`。
public enum TranscriptDisplayRow: Equatable, Sendable {
  case speech(TranscriptSpeechLine)
  case plain(String)
}

/// 说话人命名的**纯呈现层**改写(F2 + N2)。
///
/// 权威转写 `transcript.md` 落盘内容永不改写——它由母带重生成,是证据。真名只在
/// 会议库详情页的转写呈现(以及由它复制出去的全文、重新生成纪要时喂给模型的那一份)里
/// 生效,映射存在 `meeting.json.speakerNames` / `speakerOverrides`。
///
/// 两条路必须分开、不可互相喂食:
/// - **抽标签**永远读原始转写。若从改过名的文本里再抽一次,`发言人 2` 会变成 `张三`,
///   下一次编辑就会往 `meeting.json` 里写一个新键,原键成孤儿、映射再也对不上。
/// - **渲染**才套映射。
public enum TranscriptSpeakerNaming {
  /// 「我」不参与**全局**命名:会后精转只有在供应商没给 speaker 时才按麦克风来源降级到
  /// 这个标签,有 speaker 的麦克风片段会保留为「发言人 N」并允许用户命名。单段覆盖仍能
  /// 修正「我」——不戴耳机或同麦多人时,来源本身不能证明真人身份。
  public static let selfSpeakerLabel = "我"

  /// 单段覆盖的键:时间戳 + 行序。
  ///
  /// 时间戳进键是刻意的**自失效**设计:重新精转后同一行序的时间戳多半变了,键对不上,
  /// 这一条覆盖就自动作废。宁可让用户重填,也不能把「这段是张三」按错到别人头上。
  public static func overrideKey(timestamp: String, index: Int) -> String {
    "\(timestamp)#\(index)"
  }

  /// 转写里出现过的说话人标签,按首次出现顺序去重;不含「我」。
  ///
  /// 标签形态由 `PostMeetingPipeline.normalizedOtherSpeaker` 决定:通常是「发言人 N」,
  /// 供应商给不出编号时会退化成「其他人」/「其他人(原始标签)」——这些同样值得命名,
  /// 所以判据是「不是我」,而不是「以发言人开头」。
  public static func speakerLabels(in transcript: String) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    for line in transcript.components(separatedBy: "\n") {
      guard let range = speakerRange(in: line) else { continue }
      let speaker = String(line[range])
      guard speaker != selfSpeakerLabel, seen.insert(speaker).inserted else { continue }
      ordered.append(speaker)
    }
    return ordered
  }

  /// 结算后的逐行结构:详情页渲染、筛选与配色都从这里取,不再各自去拆字符串。
  public static func rows(
    in transcript: String,
    names: [String: String] = [:],
    overrides: [String: String] = [:]
  ) -> [TranscriptDisplayRow] {
    transcript.components(separatedBy: "\n").enumerated().map { index, line in
      guard let parsed = parse(line, index: index) else {
        return .plain(line)
      }
      return .speech(
        TranscriptSpeechLine(
          index: index,
          timestamp: parsed.timestamp,
          originalSpeaker: parsed.speaker,
          speaker: effectiveSpeaker(
            original: parsed.speaker,
            key: overrideKey(timestamp: parsed.timestamp, index: index),
            names: names,
            overrides: overrides
          ),
          text: parsed.text
        )
      )
    }
  }

  /// 这份转写里出现过的**最终显示名**,按首次出场顺序去重(含「我」)。
  /// 配色与筛选都按它建桶:两个原始标签被更正成同一个真名,就该是同一个人。
  public static func displaySpeakers(
    in transcript: String,
    names: [String: String] = [:],
    overrides: [String: String] = [:]
  ) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    for case .speech(let line) in rows(in: transcript, names: names, overrides: overrides)
    where seen.insert(line.speaker).inserted {
      ordered.append(line.speaker)
    }
    return ordered
  }

  /// 按映射改写转写正文的说话人字段。
  ///
  /// 只替换行首 `[时间戳] 说话人：` 里的那一段,不做全文字符串替换——否则正文里
  /// 提到「发言人 2」的那句话也会被一起改掉。映射里没有的标签原样保留。
  public static func applyingNames(
    _ names: [String: String],
    overrides: [String: String] = [:],
    to transcript: String
  ) -> String {
    guard !names.isEmpty || !overrides.isEmpty else { return transcript }
    return
      rows(in: transcript, names: names, overrides: overrides)
      .map { row in
        switch row {
        case .plain(let line):
          return line
        case .speech(let line):
          return "[\(line.timestamp)] \(line.speaker)：\(line.text)"
        }
      }
      .joined(separator: "\n")
  }

  private static func effectiveSpeaker(
    original: String,
    key: String,
    names: [String: String],
    overrides: [String: String]
  ) -> String {
    if let override = overrides[key], !override.isEmpty {
      return override
    }
    guard original != selfSpeakerLabel, let name = names[original], !name.isEmpty else {
      return original
    }
    return name
  }

  private struct ParsedLine {
    let timestamp: String
    let speaker: String
    let text: String
  }

  /// `[00:03:25] 发言人 2：……`;格式不符返回 nil,由调用方按普通文本处理。
  private static func parse(_ line: String, index: Int) -> ParsedLine? {
    guard
      line.hasPrefix("["),
      let close = line.firstIndex(of: "]"),
      let range = speakerRange(in: line)
    else {
      return nil
    }
    let separator = line[range.upperBound...].firstIndex(of: "：")
    guard let separator else { return nil }
    return ParsedLine(
      timestamp: String(line[line.index(after: line.startIndex)..<close]),
      speaker: String(line[range]),
      text: String(line[line.index(after: separator)...])
    )
  }

  /// `[00:03:25] 发言人 2：……` 里 `发言人 2` 所在的区间(已去掉两侧空白);格式不符返回 nil。
  private static func speakerRange(in line: String) -> Range<String.Index>? {
    guard
      line.hasPrefix("["),
      let close = line.firstIndex(of: "]")
    else {
      return nil
    }
    let afterClose = line.index(after: close)
    guard let separator = line[afterClose...].firstIndex(of: "：") else { return nil }
    var start = afterClose
    while start < separator, line[start].isWhitespace {
      start = line.index(after: start)
    }
    var end = separator
    while end > start, line[line.index(before: end)].isWhitespace {
      end = line.index(before: end)
    }
    return start < end ? start..<end : nil
  }
}
