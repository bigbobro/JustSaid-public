import Foundation

public enum ActionItemsRenderer {
  public static func renderMarkdown(
    title: String,
    document: MeetingMinutesDocument,
    hasStructuredMinutes: Bool
  ) -> String {
    var lines = ["# \(title) · 行动清单", ""]
    guard hasStructuredMinutes else {
      lines.append("> 此旧会议没有结构化权威行动项，请查看 minutes.md。")
      return lines.joined(separator: "\n") + "\n"
    }

    let actions = SummaryActionItem.mineFirst(document.actionItems)
    guard !actions.isEmpty else {
      lines.append("- 本场没有明确行动项。")
      return lines.joined(separator: "\n") + "\n"
    }

    for action in actions {
      lines.append("- [ ] **\(action.displayOwner)**：\(action.text)")
      if let deadline = action.deadline {
        lines.append("  - 时限：\(deadline)")
      }
      if let timecode = validTimecode(action.recordedAt) {
        lines.append("  - 回跳：⏱ \(timecode)")
      }
      for update in action.updates {
        let anchor = validTimecode(update.anchor).map { "（⏱ \($0)）" } ?? ""
        lines.append("  - 更新：\(update.text)\(anchor)")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func renderPlainText(
    title: String,
    document: MeetingMinutesDocument
  ) -> String? {
    let actions = SummaryActionItem.mineFirst(document.actionItems)
    guard !actions.isEmpty else { return nil }

    var lines = ["行动清单｜\(title)"]
    for (index, action) in actions.enumerated() {
      let deadline = action.deadline.map { "（时限：\($0)）" } ?? ""
      let anchor = validTimecode(action.recordedAt).map { "〔回看 \($0)〕" } ?? ""
      lines.append(
        "\(index + 1). [ ] \(action.displayOwner)：\(action.text)\(deadline)\(anchor)"
      )
      for update in action.updates {
        let updateAnchor = validTimecode(update.anchor).map { "〔回看 \($0)〕" } ?? ""
        lines.append("   更新：\(update.text)\(updateAnchor)")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func validTimecode(_ anchor: TranscriptAnchor?) -> String? {
    guard let anchor, anchor.seconds != nil else { return nil }
    return anchor.timecode
  }
}
