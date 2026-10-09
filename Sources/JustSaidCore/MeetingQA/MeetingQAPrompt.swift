import Foundation

/// 会中问答的提示词。system 固定不变,走各家现有的 system 前缀缓存;会议材料与问题都在 user 里。
public enum MeetingQAPrompt {
  public static let system = """
    你是会议进行中的速查助手。用户正在开会，抽空打字问你一个问题，需要几秒内看懂的答案。

    依据只有三样：
    1. 【本场转写】这场会到现在为止的语音转写。「我」是提问的用户本人，「其他人」是会上的其他人（转写只分这两路，分不出具体是谁）。转写有识别错字，按上下文理解。
    2. 【历史会议纪要】同一客户、同一项目之前几场会的纪要（可能没有）。
    3. 你自己的通用知识：只用来回答通用的技术或常识问题。

    规则：
    - 关于这场会、这个客户、这个项目、我们的产品或交付细节的问题，只根据转写和纪要回答。两者都没有提到时，直接说「会里没提到」，可以再补一句最接近的相关内容；不要用通用知识去猜项目细节。
    - 本场前后说法不一致时，以后说的为准，并点明前面说过不同的。
    - 本场和历史纪要不一致时，以本场为准。
    - 只回答事实和会上已经说过的内容，不给建议，不替用户做决定。
    - 【之前的问答】只用来理解「那个」「它」这类指代，不是事实来源；事实每次都重新从转写和纪要里找。
    - 用中文，简短。一两句能说完就不分点；需要列举时用「- 」开头的短列表，不超过 5 条。不用标题，不加粗。
    - 最后单独一行写来源，格式：来源：[本场 12:30] [会议 M1] [通用知识]
      - [本场 时间]：时间照抄转写行开头的时间，指向最能支持答案的原话，最多 3 个。
      - [会议 Mn]：n 是历史纪要的编号。
      - [通用知识]：答案用到了你自己的知识。
      - 没有任何依据（例如只回答了「会里没提到」）时写：来源：无
    """

  public static func user(
    context: MeetingQAContext,
    history: [MeetingQAExchange],
    question: String
  ) -> String {
    var sections: [String] = []
    if !context.pastMeetingsSection.isEmpty { sections.append(context.pastMeetingsSection) }
    if !context.topicsSection.isEmpty { sections.append(context.topicsSection) }
    sections.append(context.transcriptSection)
    if !history.isEmpty {
      let turns = history.map { "问：\($0.question)\n答：\($0.answer)" }
      sections.append(
        (["【之前的问答】只用于理解指代，不是事实来源"] + turns).joined(separator: "\n"))
    }
    sections.append("【现在的问题】\n\(question)")
    return sections.joined(separator: "\n\n")
  }
}
