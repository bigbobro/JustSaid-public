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
  @FocusState private var isInputFocused: Bool
  @State private var draft = ""

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
  }

  /// 栏头:名字、条数,右端「标记重点」。2026-11-11 设计走查(截图「驾驶舱-细条」):
  /// 「标记重点」原来是输入框右边一颗墨青渐变、带投影、画着键帽的按钮,是右栏里最重的东西;
  /// 按 `live.html` 改成栏头右端的描边小按钮,快捷键写进悬停提示(README:按钮上不画键帽)。
  private var header: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      HStack(spacing: Tokens.V1.Space.sm) {
        Text("补充记录")
          .font(Tokens.V1.Text.strong.font)
          .foregroundStyle(Tokens.V1.Color.ink)
        if !controller.items.isEmpty {
          Text("\(controller.items.count)")
            .font(Tokens.V1.Text.meta.font.monospacedDigit())
            .foregroundStyle(Tokens.V1.Color.ink3)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("补充记录 \(controller.items.count) 条")
      Spacer()
      Button {
        // 与全局热键共用 220ms 门:Carbon 与 SwiftUI keyboardShortcut 偶发双投时只落一记。
        guard MarkTriggerGate.tryBegin() else { return }
        controller.beginMark()
      } label: {
        Label("标记重点", systemImage: "flag")
      }
      .buttonStyle(.v1Outline.height(Tokens.V1.Size.controlSm))
      // ⌥⌘M 注册就在这颗按钮上（合并重复入口后从当前区搬来）。
      .keyboardShortcut("m", modifiers: [.command, .option])
      .help("把最近约一分钟内容提炼成一条补充记录  ⌥⌘M")
      .runtimeAccessibilityIdentifier("notes.mark")
      .accessibilityLabel("标记重点，快捷键 Option Command M")
      .accessibilityHint("把最近约一分钟内容提炼成一条补充记录")
    }
    .frame(height: Tokens.V1.Size.controlLg)
  }

  private var inputRow: some View {
    TextField(
      "补充需要保留的重点", text: $draft,
      prompt: Text("补充需要保留的重点").foregroundColor(Tokens.V1.Color.ink3),
      axis: .vertical
    )
    .textFieldStyle(.plain)
    .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
    .foregroundStyle(Tokens.V1.Color.ink)
    .padding(.horizontal, Tokens.V1.Space.sm)
    .padding(.vertical, Tokens.V1.Space.s2xs)
    .frame(maxWidth: .infinity, minHeight: Tokens.V1.Size.control, alignment: .leading)
    .focused($isInputFocused)
    .modifier(V1FormSurface(focused: isInputFocused))
    .onSubmit(submitDraft)
    .padding(.bottom, Tokens.V1.Space.xs)
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if controller.items.isEmpty {
          Text("会议中补充的重点会显示在这里")
            .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
            .foregroundStyle(Tokens.V1.Color.ink3)
            .padding(.top, Tokens.V1.Space.s2xs)
        } else {
          rowRule
          ForEach(controller.items) { item in
            NoteRow(
              item: item,
              fontSize: textScale.size(Tokens.FontSize.body),
              onJump: { onJumpToTranscript(item.elapsed) },
              onRetry: { controller.retryMark(item.id) }
            )
            rowRule
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
    // 每行「时间 · 正文 · 来源标签」,行间细线由列表画;原来行首那条 2 点竖线退役。
    Group {
      switch item.kind {
      case .normal:
        HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
          Button(action: onJump) {
            TranscriptAnchorChip(label: ElapsedTime.shortLabel(item.elapsed))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("回跳到补充记录时刻 \(ElapsedTime.shortLabel(item.elapsed))")
          Text(item.text)
            .font(.system(size: fontSize))
            .foregroundStyle(Tokens.V1.Color.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let suffixTag = item.suffixTag {
            Text(suffixTag)
              .font(.system(size: Tokens.FontSize.badge))
              .foregroundStyle(Tokens.V1.Color.ink2)
              .lineLimit(1)
              .fixedSize()
              .padding(.horizontal, Tokens.V1.Space.xs)
              .padding(.vertical, Tokens.V1.Space.s3xs)
              .background(Tokens.V1.Color.paper3, in: Capsule())
          }
        }
        .accessibilityElement(children: .combine)

      case .markPending:
        // 「AI 正在工作」在全应用只有一种说法：三点呼吸。斜体文字自己不会动，
        // 看久了分不清是在提炼还是已经卡死。
        HStack(spacing: Tokens.Spacing.xs) {
          Text("已标记，提炼中…")
            .font(.system(size: Tokens.FontSize.body))
            .foregroundStyle(Tokens.Color.ink3)
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
    .padding(.vertical, Tokens.V1.Space.xs)
  }
}
