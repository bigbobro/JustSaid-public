import Foundation

/// 附和:「嗯」「对对」「好的」「没问题」「OK」这类只表示在听、在同意的应声。
///
/// 会中总结用它给「我」侧的短附和打 `[附和]` 标(`LiveSummaryFeed.isBackchannel`);
/// 精转用它认出一整簇只在应声的「人」(`PostMeetingPipeline.foldSpeakerTails`)。
enum Backchannel {
  /// 去掉标点空白、转小写后,整句能否完全由附和词拼成(「嗯嗯对对对是的是的」)。空句算。
  static func consistsOfTokens(_ text: String) -> Bool {
    let normalized = String(
      text.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0)
      }
    )
    var rest = Substring(normalized)
    while !rest.isEmpty {
      guard let token = tokens.first(where: { rest.hasPrefix($0) }) else {
        return false
      }
      rest = rest.dropFirst(token.count)
    }
    return true
  }

  /// 长度按「先长后短」排，逐位取最长匹配。
  static let tokens: [String] = [
    "嗯", "嗯嗯", "啊", "哦", "噢", "呃", "唉", "诶",
    "对", "对对", "对呀", "对的", "对吧",
    "是", "是的", "是啊", "是吧",
    "好", "好的", "好呀", "好吧",
    "行", "行吧", "可以", "认可", "明白", "了解", "收到", "没错", "没问题",
    "ok", "okay", "yeah", "yep", "yes", "right", "sure", "mm", "mhm", "uhhuh",
  ].sorted { $0.count > $1.count }
}
