import Foundation

extension Qwen3ASRTranscriberEngine {
  /// Qwen3-ASR 的识别结果里会漏出几类不是话的东西,这里删掉它们,正文一字不动:
  /// 1. `<|endoftext|>` 这类 `<|名字|>` 特殊记号,以及 `<non_speech>`、`<blank12>`、`<think>` 等
  ///    不带竖线的附加标记。sherpa 把它们原样打印出来,1.13.8 截断重复时更常见;说话不会产出这种写法。
  /// 2. 协议头 `language Chinese<asr_text>` 与落单的 `<asr_text>`。sherpa 只在前 16 个生成 ID 里
  ///    认到 marker 时剥一次,头出现在正文中间、重复出现或由普通 token 拼成时会漏进转写(#71)。
  ///    删掉一处可能拼出新的标记或协议头,所以反复删到不再变化。
  /// 3. 整段只剩协议头残片时(`language`、`language Chinese`、截断的 `language Canton`,或连着几个这样
  ///    的头)返回空串,sherpa 1.13.8 截断重复时会留下它。只认由小写 `language` 加至多一个首字母大写的词
  ///    重复组成、别无他物的整段;句中或后面还有话的 `language Chinese` 当正文保留。
  ///
  /// 回放评分 `Scripts/live-replay-score.py` 的 `strip_protocol_headers` 与这里逐条一致,两边读同一张
  /// 用例表 `Verification/QwenProtocolHeaders/cases.json`。
  @_spi(Verification)
  public static func removingProtocolHeaders(from text: String) -> String {
    var cleaned = text
    while true {
      let next =
        cleaned
        .replacingOccurrences(of: specialTokenPattern, with: "", options: .regularExpression)
        .replacingOccurrences(
          of: protocolHeaderPattern, with: "", options: [.regularExpression, .caseInsensitive])
      if next == cleaned { break }
      cleaned = next
    }
    let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: headerOnlyPattern, options: .regularExpression) != nil {
      return ""
    }
    return cleaned
  }

  private static let specialTokenPattern =
    #"<\|[a-z_]{1,32}\|>|<(?:/?tool_call|/?tool_response|/?think|tts_pad|tts_text_bos|tts_text_eod|tts_text_bos_single|non_speech|blank[0-9]{1,2})>"#
  private static let protocolHeaderPattern = #"(?:language\s*[A-Za-z]+\s*)?<asr_text>"#
  // 词里不许含 language:否则一串粘连的 languageChinese 有指数多种切法,整段判断会回溯失控。
  private static let headerOnlyPattern =
    #"^(?:language(?:\s*[A-Z](?:(?!language)[A-Za-z])*)?\s*)+$"#
}
