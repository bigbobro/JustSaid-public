import Foundation

public struct MeetingQAAnswer: Equatable, Sendable {
  /// 去掉来源行之后的正文。
  public let body: String
  /// 校验通过的来源,按出现顺序去重。
  public let sources: [MeetingQASource]

  public init(body: String, sources: [MeetingQASource]) {
    self.body = body
    self.sources = sources
  }
}

/// 把模型的回答拆成正文与来源。
///
/// 写之前列出的出错方式(实测时逐条留意):
/// 1. 没有来源行:正文照常显示,不画来源,不报错。
/// 2. 来源行后面还有空行:先去掉末尾空行再找最后一行。
/// 3. 正文里有方括号(「[本场 03:00] 说过……」):只解析最后一行,正文里的方括号原样保留。
/// 4. 时间越界(模型编了一个转写里没有的时刻):丢弃这一个,其余照用。
/// 5. 编号不存在([会议 M4] 而只给了 3 场):丢弃这一个。
/// 6. 流式中途截断:写作过程中半截的「来源…」行不显示,整段写完再解析一次。
/// 7. 写法漂移:半角冒号「来源:」、全角方括号【】、标记里没有空格「本场12:30」、
///    时间写成区间「12:30–13:10」(取开头)、同一标记重复(去重)。
/// 8. 「来源：无」:合法,表示没有依据。
public enum MeetingQAAnswerParser {
  /// 本场时间允许落在转写范围外的余量:转写行时间取整到秒,模型也可能指向句尾。
  static let timeTolerance: TimeInterval = 2

  public static func parse(_ text: String, context: MeetingQAContext) -> MeetingQAAnswer {
    var lines = text.components(separatedBy: "\n")
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    guard let last = lines.last, let tokens = sourceTokens(in: last) else {
      return MeetingQAAnswer(body: trimmed(lines.joined(separator: "\n")), sources: [])
    }
    lines.removeLast()
    var sources: [MeetingQASource] = []
    for token in tokens {
      guard let source = resolve(token, context: context), !sources.contains(source) else {
        continue
      }
      sources.append(source)
    }
    return MeetingQAAnswer(body: trimmed(lines.joined(separator: "\n")), sources: sources)
  }

  /// 写作过程中可以显示的正文:末尾那行若是(或可能正要写成)来源行,先不显示。
  public static func streamingBody(_ partial: String) -> String {
    var lines = partial.components(separatedBy: "\n")
    if let last = lines.last {
      let line = last.trimmingCharacters(in: .whitespaces)
      if !line.isEmpty, "来源：".hasPrefix(line) || "来源:".hasPrefix(line) || line.hasPrefix("来源") {
        lines.removeLast()
      }
    }
    return trimmed(lines.joined(separator: "\n"))
  }

  /// 最后一行是来源行时返回其中的标记原文(可能为空);不是来源行返回 nil。
  static func sourceTokens(in line: String) -> [String]? {
    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
    guard let prefix = ["来源：", "来源:"].first(where: { trimmedLine.hasPrefix($0) }) else {
      return nil
    }
    let rest = String(trimmedLine.dropFirst(prefix.count))
    var tokens: [String] = []
    var current: String?
    for character in rest {
      switch character {
      case "[", "【":
        current = ""
      case "]", "】":
        if let token = current { tokens.append(token) }
        current = nil
      default:
        current?.append(character)
      }
    }
    return tokens
  }

  static func resolve(_ rawToken: String, context: MeetingQAContext) -> MeetingQASource? {
    let token = rawToken.trimmingCharacters(in: .whitespaces)
    if token == "通用知识" {
      return .generalKnowledge
    }
    if token.hasPrefix("本场") {
      var time = token.dropFirst("本场".count).trimmingCharacters(in: .whitespaces)
      if let end = time.firstIndex(where: { "–—-~～至".contains($0) }) {
        time = String(time[..<end]).trimmingCharacters(in: .whitespaces)
      }
      guard let seconds = MeetingQATimeLabel.parse(time), let range = context.transcriptRange,
        seconds >= range.lowerBound.rounded(.down) - timeTolerance,
        seconds <= range.upperBound + timeTolerance
      else { return nil }
      return .thisMeeting(seconds)
    }
    if token.hasPrefix("会议") {
      let number = token.dropFirst("会议".count).trimmingCharacters(in: .whitespaces)
      guard number.first == "M" || number.first == "m", let index = Int(number.dropFirst()),
        let meeting = context.pastMeetings.first(where: { $0.index == index })
      else { return nil }
      return .pastMeeting(meeting)
    }
    return nil
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
