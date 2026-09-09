import JustSaidCore
import SwiftUI

/// 「替你记」呈现会中承诺与待办的当前版本、时限和时间痕。
struct ActionItemsPaneView: View {
  let items: [SummaryActionItem]
  let onJumpToTranscript: (TimeInterval) -> Void
  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Tokens.Spacing.xs) {
        Text("替你记 · 承诺与待办")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink3)
        if !items.isEmpty {
          SectionCountBadge(value: items.count)
        }
        Spacer()
      }
      .padding(.horizontal, Tokens.Spacing.md)
      .padding(.vertical, Tokens.Spacing.xsm)

      Divider()

      if items.isEmpty {
        Text("听到明确承诺或待办后，会记在这里。")
          .font(.system(size: textScale.size(Tokens.FontSize.uiEmphasis)))
          .foregroundStyle(Tokens.Color.ink4)
          .padding(Tokens.Spacing.md)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sortedItems) { item in
              actionRow(item)
              Divider()
            }
          }
        }
      }
    }
    .background(Tokens.Color.card)
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.card)
        .stroke(Tokens.Color.line, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
  }

  private var sortedItems: [SummaryActionItem] {
    SummaryActionItem.mineFirst(items)
  }

  private func actionRow(_ item: SummaryActionItem) -> some View {
    HStack(alignment: .top, spacing: Tokens.Spacing.xsm) {
      // 记号不是 checkbox(2026-08-21 走查 N-8,用户拍板)。原先是 14×14 描边方框,
      // 画得像待办勾选框却没有 Button 包裹——视觉承诺了一个不存在的交互
      // (08-15 F-C8 提出,一直没闭)。换成本 app 列表项通用的实心圆点
      // (NowLineRow / 话题卡要点同一套词汇),不新造标注:
      // 归属由「我 · 承诺」那行的文字与色彩承担,待核由 [待核] 徽章承担,
      // 这颗点只负责「这是一条」。**不做可勾选交互**——那是新语义 + 新数据。
      Circle()
        .fill(Tokens.Color.acLine)
        .frame(width: 5, height: 5)
        .padding(.top, Tokens.Spacing.xs)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
        Text(item.text)
          .font(.system(size: textScale.size(Tokens.FontSize.uiEmphasis), weight: .medium))
          .foregroundStyle(Tokens.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Tokens.Spacing.xxs) {
          Text(ownerLabel(item))
            .font(.system(size: Tokens.FontSize.badge, weight: item.ownership == .me ? .semibold : .regular))
            .foregroundStyle(item.ownership == .me ? Tokens.Color.me : Tokens.Color.ink3)
          if item.evidence == .toVerify {
            SummaryMarkerBadge(kind: .toVerify)
          }
        }
        if let deadline = item.deadline {
          Text("时限：\(deadline)")
            .font(.system(size: textScale.size(Tokens.FontSize.badge)))
            .foregroundStyle(Tokens.Color.ink3)
            .runtimeAccessibilityIdentifier("dashboard.action-deadline")
        }
        if let recorded = item.recordedAt {
          HStack(spacing: Tokens.Spacing.xxs) {
            Text("记录 \(recorded.timecode)")
            TranscriptAnchorButton(anchor: recorded, onJump: onJumpToTranscript)
          }
          .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
          .foregroundStyle(Tokens.Color.ink4)
        }
        ForEach(item.updates) { update in
          HStack(spacing: Tokens.Spacing.xxs) {
            if let anchor = update.anchor {
              Text("更新 \(anchor.timecode)")
                .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
                .foregroundStyle(Tokens.Color.ink4)
            }
            Text(update.anchor == nil ? "更新 · \(update.text)" : "· \(update.text)")
              .font(.system(size: textScale.size(Tokens.FontSize.badge)))
              .foregroundStyle(Tokens.Color.revision)
            TranscriptAnchorButton(anchor: update.anchor, onJump: onJumpToTranscript)
          }
        }
      }
    }
    .padding(.horizontal, Tokens.Spacing.md)
    .padding(.vertical, Tokens.Spacing.xsm)
  }

  private func ownerLabel(_ item: SummaryActionItem) -> String {
    if item.ownership == .me {
      return item.kind == .commitment ? "我 · 承诺" : "我"
    }
    return item.displayOwner
  }
}
