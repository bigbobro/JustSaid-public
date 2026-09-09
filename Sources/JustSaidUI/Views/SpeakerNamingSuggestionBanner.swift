import JustSaidCore
import SwiftUI

/// 认名预填的一行呈现(08-17 #7),由 `MeetingLibraryModel.namingSuggestionRows` 计算:
/// - `prefill`:未命名标签 + 唯一强证据名 + 未被拒绝 → 预填建议(可采纳/拒绝);
/// - `conflict`:同一标签下强证据指向两个不同名字 → 只提示,无动作。
/// 强证据判据(08-20 naming-first R2 升级)见 `MeetingLibraryModel.namingSuggestionRows`
/// 纯函数;public 仅为该纯函数的规则矩阵可被验证程序直接驱动,呈现形态不变。
public enum SpeakerNamingSuggestionRow: Identifiable, Equatable {
  case prefill(SpeakerNameSuggestion)
  case conflict(label: String, evidences: [SpeakerNameSuggestion])

  public var id: String {
    switch self {
    case .prefill(let suggestion):
      return "prefill|\(suggestion.label)|\(suggestion.name)"
    case .conflict(let label, _):
      return "conflict|\(label)"
    }
  }
}

extension [SpeakerNamingSuggestionRow] {
  /// 未决预填条数(08-20 naming-first R4):「生成纪要」弹窗提示与「完整转写」页签
  /// 状态点共用这一口径,与建议横幅同一份规则结算(`MeetingLibraryModel.
  /// namingSuggestionRows`),不另起数据源。只数 `.prefill`——冲突行只提示,
  /// 不占「可认名」条数;弱证据行在规则层就不产出。
  var pendingPrefillCount: Int {
    var count = 0
    for row in self {
      if case .prefill = row {
        count += 1
      }
    }
    return count
  }
}

/// 「生成纪要」确认弹窗里的未决认名提示行(08-20 naming-first R4 拍板②,方案已评审):
/// 有未决预填建议时提示「先认名可让纪要更准」并给〔去认名〕入口(跳完整转写页签)。
/// 显隐收在本视图内(verification 红线 6):0 条时整行不存在,弹窗 message 无条件实例化。
/// headless 弹不出 confirmationDialog,本视图提为 public 由 UIHierarchy 单独摆页做
/// 在场/空态正反断言(章节目录/溯源弹层同一处理),调用点接线另由源码断言钉死。
public struct MinutesDialogNamingHint: View {
  let pendingCount: Int
  let onGoNaming: () -> Void

  public init(pendingCount: Int, onGoNaming: @escaping () -> Void) {
    self.pendingCount = pendingCount
    self.onGoNaming = onGoNaming
  }

  public var body: some View {
    if pendingCount > 0 {
      HStack(spacing: Tokens.Spacing.xs) {
        Text("有 \(pendingCount) 条认名建议未处理，先认名可让纪要更准")
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink2)
        Button("去认名") {
          onGoNaming()
        }
        .buttonStyle(.textAction)
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .help("跳到「完整转写」页签处理认名建议")
      }
      .runtimeAccessibilityIdentifier("library.minutes-dialog.naming-hint")
    }
  }
}

/// 转写页的认名预填横幅。显隐判断收在本视图内(红线 6):没有可显示的行时整条
/// 结构不存在;调用点无条件实例化。改名走既有 speakerNames 通道,本视图只发回调。
struct SpeakerNamingSuggestionBanner: View {
  let rows: [SpeakerNamingSuggestionRow]
  let onAdopt: (SpeakerNameSuggestion) -> Void
  let onDismiss: (SpeakerNameSuggestion) -> Void
  let onJump: (TimeInterval) -> Void

  var body: some View {
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
        ForEach(rows) { row in
          switch row {
          case .prefill(let suggestion):
            prefillRow(suggestion)
          case .conflict(let label, let evidences):
            conflictRow(label: label, evidences: evidences)
          }
        }
      }
      .padding(.horizontal, Tokens.Spacing.lg)
      .padding(.vertical, Tokens.Spacing.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Tokens.Color.pane)
      .overlay(alignment: .bottom) { Divider() }
    }
  }

  private func prefillRow(_ suggestion: SpeakerNameSuggestion) -> some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Text("\(suggestion.label) → \(suggestion.name)？")
        .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink)
        .lineLimit(1)
      evidenceChip(suggestion)
      Spacer(minLength: Tokens.Spacing.xxs)
      Button("采纳") {
        onAdopt(suggestion)
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      .help("把「\(suggestion.label)」命名为「\(suggestion.name)」(与手动改名同一通道)")
      .accessibilityLabel("采纳建议：\(suggestion.label) 是 \(suggestion.name)")
      .runtimeAccessibilityIdentifier("library.transcript.naming-suggestion.adopt")
      Button("不是") {
        onDismiss(suggestion)
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.ui))
      .foregroundStyle(Tokens.Color.ink3)
      .help("拒绝这条建议，本场不再提示")
      .accessibilityLabel("拒绝建议：\(suggestion.label) 不是 \(suggestion.name)")
      .runtimeAccessibilityIdentifier("library.transcript.naming-suggestion.dismiss")
    }
    .runtimeAccessibilityIdentifier("library.transcript.naming-suggestion.row")
  }

  private func conflictRow(
    label: String,
    evidences: [SpeakerNameSuggestion]
  ) -> some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.warn)
        .accessibilityHidden(true)
      Text("「\(label)」可能混了两个人：自我介绍证据指向不同名字")
        .font(.system(size: Tokens.FontSize.uiEmphasis, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink)
        .lineLimit(1)
        .help("「\(label)」可能混了两个人：自我介绍证据指向不同名字")
      ForEach(evidences, id: \.name) { evidence in
        evidenceChip(evidence)
      }
      Spacer(minLength: Tokens.Spacing.xxs)
    }
    .runtimeAccessibilityIdentifier("library.transcript.naming-suggestion.conflict")
  }

  /// 证据 chip:引文截断 + 时间戳,点击回跳原话;拿不到秒数就只展示不跳,不编时间。
  private func evidenceChip(_ suggestion: SpeakerNameSuggestion) -> some View {
    let timecode = suggestion.anchor?.timecode
    let seconds = suggestion.anchor?.seconds
    return Button {
      if let seconds {
        onJump(seconds)
      }
    } label: {
      HStack(spacing: Tokens.Spacing.xxs) {
        if let timecode {
          Text(timecode)
            .font(.system(size: Tokens.FontSize.badge, design: .monospaced))
            .foregroundStyle(Tokens.Color.ink4)
        }
        Text("「\(suggestion.evidenceQuote)」")
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink3)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, Tokens.Spacing.xs)
      .padding(.vertical, Tokens.Spacing.hairline)
      .background(
        RoundedRectangle(cornerRadius: Tokens.Radius.widget).fill(Tokens.Color.cardWash)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.widget)
          .stroke(Tokens.Color.line, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .hoverStrokeOutline(cornerRadius: Tokens.Radius.widget)
    .disabled(seconds == nil)
    // 引文本身单行尾截断,完整原话并进 tooltip(走查 N-9)。
    .help(
      seconds == nil
        ? "「\(suggestion.evidenceQuote)」——这条证据没有可回跳的时间戳"
        : "「\(suggestion.evidenceQuote)」——点击回跳到原话"
    )
    .accessibilityLabel("证据：\(suggestion.evidenceQuote)")
    .frame(maxWidth: 260, alignment: .leading)
  }
}
