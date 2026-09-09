import SwiftUI

/// 补充记录区：自由文本 + 自动会议时间戳（B6），回车即记、零选择零格式；
/// 「标记重点」一键提炼（E1），请求期间展示提炼中，失败后可原位重试。
/// **本区是全驾驶舱唯一的标记入口**（08-10）：当前区曾有一颗同名同动作的按钮，
/// 同屏两个「标记」是重复入口，已删；⌥⌘M 随之落到这里注册。
/// 用户可见语义一律是「补充记录」（内部类型/落盘字段/文件名仍叫 note，不迁移）。
/// **宽度由驾驶舱右栏(332)独家决定**(2026-08-19 A+C 混搭契约):本视图只填满给到的宽,
/// 曾自带的 min/ideal/max 宽度约束与列宽打架,已撤。
struct NotesPaneView: View {
  @ObservedObject var controller: NotesController
  var onJumpToTranscript: (TimeInterval) -> Void = { _ in }
  @Environment(\.textScale) private var textScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isInputFocused: Bool
  @State private var draft = ""
  @State private var isMarkHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      inputRow
      if let warning = controller.persistenceWarning {
        DegradedBanner(text: warning)
      }
      list
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tokens.Color.card)
  }

  private var header: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      Text("补充记录")
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink3)
      if !controller.items.isEmpty {
        SectionCountBadge(value: controller.items.count)
      }
      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("补充记录 \(controller.items.count) 条")
    .padding(.horizontal, Tokens.Spacing.md)
    .padding(.top, Tokens.Spacing.sm)
    .padding(.bottom, Tokens.Spacing.xs)
  }

  private var inputRow: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      TextField("补充需要保留的重点", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, Tokens.Spacing.xs)
        .background(
          RoundedRectangle(cornerRadius: Tokens.Radius.widget)
            .fill(Tokens.Color.pane)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.Radius.widget)
            .stroke(Tokens.Color.line, lineWidth: 1)
        )
        .focused($isInputFocused)
        .onSubmit(submitDraft)

      Button {
        // 与全局热键共用 220ms 门:Carbon 与 SwiftUI keyboardShortcut 偶发双投时只落一记。
        guard MarkTriggerGate.tryBegin() else { return }
        controller.beginMark()
      } label: {
        // ⌥⌘M 注册就在这颗按钮上（合并重复入口后从当前区搬来），
        // 键帽提示与实际注册第一次落在同一个控件上。
        HStack(spacing: Tokens.Spacing.xxs) {
          Image(systemName: "flag.fill")
            .accessibilityHidden(true)
          Text("标记重点")
          KeycapView(label: "⌥⌘M")
        }
        .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .bold))
        .foregroundStyle(Tokens.Color.acDeep)
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, Tokens.Spacing.xs)
        .background(
          LinearGradient(
            colors: [Tokens.Color.acSoft, Tokens.Color.washMark],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.Radius.widget)
            .stroke(isMarkHovering ? Tokens.Color.acDeep : Tokens.Color.acLine, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.widget))
        .tokenShadow(isMarkHovering ? Tokens.Shadow.sh2 : Tokens.Shadow.sh1)
        .onHover { isMarkHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isMarkHovering)
      }
      .buttonStyle(.plain)
      .keyboardShortcut("m", modifiers: [.command, .option])
      .runtimeAccessibilityIdentifier("notes.mark")
      .accessibilityLabel("标记重点，快捷键 Option Command M")
      .accessibilityHint("把最近约一分钟内容提炼成一条补充记录")
    }
    .padding(.horizontal, Tokens.Spacing.smd)
    .padding(.bottom, Tokens.Spacing.sm)
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: Tokens.Spacing.smd) {
        if controller.items.isEmpty {
          Text("会议中补充的重点会显示在这里")
            .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
            .foregroundStyle(Tokens.Color.ink4)
        } else {
          ForEach(controller.items) { item in
            NoteRow(
              item: item,
              fontSize: textScale.size(Tokens.FontSize.body),
              onJump: { onJumpToTranscript(item.elapsed) },
              onRetry: { controller.retryMark(item.id) }
            )
          }
        }
      }
      .padding(.horizontal, Tokens.Spacing.md)
      .padding(.bottom, Tokens.Spacing.md)
    }
  }

  private func submitDraft() {
    guard controller.addNote(draft) else {
      return
    }
    draft = ""
    isInputFocused = true
  }
}

private struct NoteRow: View {
  let item: NotesController.NoteItem
  let fontSize: CGFloat
  let onJump: () -> Void
  let onRetry: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      Rectangle()
        .fill(Tokens.Color.line2)
        .frame(width: 2)
        .padding(.trailing, Tokens.Spacing.xsm)

      switch item.kind {
      case .normal:
        VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
          HStack(spacing: Tokens.Spacing.xxs) {
            Button(action: onJump) {
              TranscriptAnchorChip(
                label: ElapsedTime.shortLabel(item.elapsed),
                fontSize: 10.5,
                weight: .semibold
              )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回跳到补充记录时刻 \(ElapsedTime.shortLabel(item.elapsed))")
            if let suffixTag = item.suffixTag {
              Text(suffixTag)
                .font(.system(size: Tokens.FontSize.micro, weight: .semibold))
                .foregroundStyle(Tokens.Color.ac)
                .padding(.horizontal, Tokens.Spacing.xxs)
                .background(Tokens.Color.acSoft)
                .overlay(
                  RoundedRectangle(cornerRadius: 3).stroke(Tokens.Color.acLine, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
          }
          Text(item.text)
            .font(.system(size: fontSize))
            .foregroundStyle(Tokens.Color.ink2)
        }
        .accessibilityElement(children: .combine)

      case .markPending:
        // 「AI 正在工作」在全应用只有一种说法：三点呼吸。斜体文字自己不会动，
        // 看久了分不清是在提炼还是已经卡死。
        HStack(spacing: Tokens.Spacing.xs) {
          Text("已标记，提炼中…")
            .font(.system(size: Tokens.FontSize.body))
            .italic()
            .foregroundStyle(Tokens.Color.ink4)
          BreathingDots()
        }
        .accessibilityElement(children: .combine)
        .runtimeAccessibilityIdentifier("notes.mark-pending")

      case .markFailed:
        Button(action: onRetry) {
          Text("标记于 \(ElapsedTime.shortLabel(item.elapsed))（提炼失败，可重试）")
            .font(.system(size: Tokens.FontSize.body))
            .foregroundStyle(Tokens.Color.warn)
        }
        .buttonStyle(.textAction)
        .runtimeAccessibilityIdentifier("notes.mark-retry")
        .accessibilityHint("点击重试提炼")
      }
    }
  }
}
