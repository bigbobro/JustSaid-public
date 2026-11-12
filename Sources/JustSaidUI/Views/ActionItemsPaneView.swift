import JustSaidCore
import SwiftUI

/// 「替你记」呈现会中承诺与待办的当前版本、时限和时间痕。
struct ActionItemsPaneView: View {
  let items: [SummaryActionItem]
  let onJumpToTranscript: (TimeInterval) -> Void
  @Environment(\.textScale) private var textScale

  var body: some View {
    // 2026-11-11 设计走查(截图「驾驶舱-细条」):原来是一张带描边的白卡,行首一颗墨青点,
    // 归属写在正文下面。按 `live.html` 平铺:栏头一行,行与行之间一条细线,
    // 每行是「谁 · 事 · 时间」,时间贴右。
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Tokens.V1.Space.sm) {
        Text("替你记")
          .font(Tokens.V1.Text.strong.font)
          .foregroundStyle(Tokens.V1.Color.ink)
        if !items.isEmpty {
          Text("\(items.count)")
            .font(Tokens.V1.Text.meta.font.monospacedDigit())
            .foregroundStyle(Tokens.V1.Color.ink3)
        }
        Spacer()
      }
      .frame(height: Tokens.V1.Size.controlLg)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("替你记，承诺与待办 \(items.count) 条")

      rowRule

      if items.isEmpty {
        Text("听到明确承诺或待办后，会记在这里。")
          .font(.system(size: textScale.size(Tokens.FontSize.uiEmphasis)))
          .foregroundStyle(Tokens.V1.Color.ink3)
          .padding(.top, Tokens.V1.Space.xs)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sortedItems) { item in
              actionRow(item)
              rowRule
            }
          }
        }
      }
    }
  }

  private var rowRule: some View {
    Rectangle()
      .fill(Tokens.V1.Color.rule)
      .frame(height: Tokens.V1.Size.controlRuleWidth)
  }

  private var sortedItems: [SummaryActionItem] {
    SummaryActionItem.mineFirst(items)
  }

  private func actionRow(_ item: SummaryActionItem) -> some View {
    // 行首是「谁」,不再另画一颗点:归属由这两三个字与它的颜色承担(「我」用石青)。
    // 仍然**不做可勾选交互**(2026-08-21 走查 N-8):完成用的方框只出现在待办页。
    HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
      Text(ownerLabel(item))
        .font(
          .system(
            size: Tokens.FontSize.badge, weight: item.ownership == .me ? .semibold : .regular)
        )
        .foregroundStyle(item.ownership == .me ? Tokens.V1.Color.me : Tokens.V1.Color.ink3)
        .lineLimit(1)
        .fixedSize()
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        Text(item.text)
          .font(.system(size: textScale.size(Tokens.FontSize.uiEmphasis)))
          .foregroundStyle(Tokens.V1.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
        if item.evidence == .toVerify {
          SummaryMarkerBadge(kind: .toVerify)
        }
        if let deadline = item.deadline {
          Text("时限：\(deadline)")
            .font(.system(size: textScale.size(Tokens.FontSize.badge)))
            .foregroundStyle(Tokens.V1.Color.ink3)
            .runtimeAccessibilityIdentifier("dashboard.action-deadline")
        }
        ForEach(item.updates) { update in
          HStack(spacing: Tokens.V1.Space.s2xs) {
            if let anchor = update.anchor, !canJump(anchor) {
              Text("更新 \(anchor.timecode)")
                .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
                .foregroundStyle(Tokens.V1.Color.ink3)
            } else if update.anchor != nil {
              Text("更新")
                .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
                .foregroundStyle(Tokens.V1.Color.ink3)
            }
            Text(updateLead(update))
              .font(.system(size: textScale.size(Tokens.FontSize.badge)))
              .foregroundStyle(Tokens.Color.revision)
            TranscriptAnchorButton(anchor: update.anchor, onJump: onJumpToTranscript)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // 记下这条的时刻贴右:能点的锚点替代时间文字,拿不到才退回文字。
      if let recorded = item.recordedAt {
        if canJump(recorded) {
          TranscriptAnchorButton(anchor: recorded, onJump: onJumpToTranscript)
        } else {
          Text(recorded.timecode)
            .font(Tokens.V1.Text.timecode.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
        }
      }
    }
    .padding(.vertical, Tokens.V1.Space.xs)
  }

  private func canJump(_ anchor: TranscriptAnchor?) -> Bool {
    TranscriptAnchorButton.canRender(anchor, onJump: onJumpToTranscript)
  }

  /// 有锚点时「更新」标签已单独画出（文字时间或芯片前），正文只写「· 文」；无锚点才由「更新」领头。
  private func updateLead(_ update: SummaryActionUpdate) -> String {
    if update.anchor != nil { return "· \(update.text)" }
    return "更新 · \(update.text)"
  }

  private func ownerLabel(_ item: SummaryActionItem) -> String {
    if item.ownership == .me {
      return item.kind == .commitment ? "我 · 承诺" : "我"
    }
    return item.displayOwner
  }
}
