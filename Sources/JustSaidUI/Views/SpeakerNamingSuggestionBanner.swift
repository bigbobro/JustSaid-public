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

/// 转写页的认名预填建议。显隐判断收在本视图内(红线 6):没有可显示的行时整条
/// 结构不存在;调用点无条件实例化。改名走既有 speakerNames 通道,本视图只发回调。
///
/// 2026-09-20 重排:原来是一条横跨正文顶部的全宽横幅,一行里塞「发言人 2 → 张三？」
/// + 证据 chip + 采纳 + 不是。认名收进 300 宽的右栏之后,这一行每一段都被挤成省略号,
/// 采纳/不是几乎点不中(owner「采纳意见完全缩住、看不清楚」)。
/// 现在按竖排三层:问句一层(可折行)、证据一层、动作一层。横幅自己的底色与横向留白
/// 一并去掉——它现在长在右栏里,再画一层底就是卡中卡。
struct SpeakerNamingSuggestionBanner: View {
  let rows: [SpeakerNamingSuggestionRow]
  let onAdopt: (SpeakerNameSuggestion) -> Void
  let onDismiss: (SpeakerNameSuggestion) -> Void
  let onJump: (TimeInterval) -> Void
  /// 把建议配上锚点处的真实原话与真实说话人。见 `MeetingLibraryModel.namingEvidence`。
  var resolve: (([SpeakerNameSuggestion]) -> [MeetingLibraryModel.NamingEvidence])? = nil

  var body: some View {
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
        ForEach(rows) { row in
          switch row {
          case .prefill(let suggestion):
            prefillRow(suggestion)
          case .conflict(let label, let evidences):
            conflictRow(label: label, evidences: evidences)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func prefillRow(_ suggestion: SpeakerNameSuggestion) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
      // 问句本身要看得全。栏只有 300 宽,长名字必须能折行,不能截成「发言人 2 →…」。
      Text("\(suggestion.label) → \(suggestion.name)？")
        .font(Tokens.V1.Text.label.font)
        .foregroundStyle(Tokens.V1.Color.ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      evidenceChip(suggestion)
      HStack(spacing: Tokens.V1.Space.xs) {
        Button("采纳") {
          onAdopt(suggestion)
        }
        .buttonStyle(.v1Outline)
        .help("把「\(suggestion.label)」命名为「\(suggestion.name)」(与手动改名同一通道)")
        .accessibilityLabel("采纳建议：\(suggestion.label) 是 \(suggestion.name)")
        .runtimeAccessibilityIdentifier("library.transcript.naming-suggestion.adopt")
        Button("不是") {
          onDismiss(suggestion)
        }
        .buttonStyle(.v1Quiet)
        .help("拒绝这条建议，本场不再提示")
        .accessibilityLabel("拒绝建议：\(suggestion.label) 不是 \(suggestion.name)")
        .runtimeAccessibilityIdentifier("library.transcript.naming-suggestion.dismiss")
        Spacer(minLength: .zero)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .runtimeAccessibilityIdentifier("library.transcript.naming-suggestion.row")
  }

  /// 冲突行。
  ///
  /// 原来这里写「「X」可能混了两个人:自我介绍证据指向不同名字」。两处都不对:
  /// 一,「混」说不清是什么混(owner 2026-09-20「还是让人有点看不懂」);
  /// 二,「自我介绍证据」是写死的——2026-09-20 这场会 13 条建议里**一条自我介绍都没有**,
  /// 全是「别人这么叫他」,这句话在画面上直接是假话。
  /// 现在按事实说:几个人分别管他叫不同的名字,列出每个候选名和它凭什么。
  private func conflictRow(
    label: String,
    evidences: [SpeakerNameSuggestion]
  ) -> some View {
    let names = Array(NSOrderedSet(array: evidences.map(\.name)).compactMap { $0 as? String })
    let resolved = resolve?(evidences) ?? []
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
      HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.s2xs) {
        Image(systemName: "questionmark.circle")
          .font(.system(size: Tokens.V1.Text.meta.size))
          .foregroundStyle(Tokens.V1.Color.warn)
          .accessibilityHidden(true)
        Text("「\(label)」有 \(names.count) 个候选名字，对不上")
          .font(Tokens.V1.Text.label.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Text("会上有人这么叫过他：\(names.joined(separator: "、"))。自己挑一个填进下面的名字框。")
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      if resolved.isEmpty {
        ForEach(evidences, id: \.name) { evidence in
          evidenceChip(evidence)
        }
      } else {
        ForEach(resolved) { evidence in
          evidenceCard(evidence)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .runtimeAccessibilityIdentifier("library.transcript.naming-suggestion.conflict")
  }

  /// 一条证据:主张谁叫什么、凭什么、原文怎么说的、那句话是谁说的。
  ///
  /// 「谁说的」必须画出来:`addressed` 级证据本来就是**别人**在叫他,点过去当然落到
  /// 别人那一段。不写这一句,用户会以为跳错了(owner 2026-09-20:「我点这 2 个证据,
  /// 一个是发言人 1,一个是发言人 4,不知道这个提示是怎么给的」)。
  private func evidenceCard(_ evidence: MeetingLibraryModel.NamingEvidence) -> some View {
    let suggestion = evidence.suggestion
    let seconds = suggestion.anchor?.seconds
    return Button {
      if let seconds { onJump(seconds) }
    } label: {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.s2xs) {
          Text(suggestion.name)
            .font(Tokens.V1.Text.label.font)
            .foregroundStyle(Tokens.V1.Color.ink)
          Text(evidence.howLabel)
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink4)
          Spacer(minLength: .zero)
          if let timecode = suggestion.anchor?.timecode {
            Text(timecode)
              .font(Tokens.V1.Text.timecode.font)
              .foregroundStyle(Tokens.V1.Color.ink4)
          }
        }
        Text("「\(evidence.quote)」")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let spokenBy = evidence.spokenBy, spokenBy != suggestion.label {
          Text("这句是「\(spokenBy)」说的")
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink4)
        }
        // 拿转写核对这条归属的结论。只报告,不替它改数据——归属是推理那一层的事。
        if let note = evidence.verdictNote {
          Text(note)
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(
              evidence.verdictIsBad ? Tokens.V1.Color.warn : Tokens.V1.Color.ink4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if evidence.nameMissingFromQuote {
          Text(
            evidence.fromTranscript
              ? "原话里没有「\(suggestion.name)」，这条不一定靠谱"
              : "在原文里没找到这一句，下面是模型写的引文"
          )
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Tokens.V1.Space.xs)
      .padding(.vertical, Tokens.V1.Space.s2xs)
      .background(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm).fill(Tokens.V1.Color.paper2)
      )
    }
    .buttonStyle(.plain)
    .hoverStrokeOutline(cornerRadius: Tokens.V1.Radius.sm)
    .disabled(seconds == nil)
    .help(seconds == nil ? "这条证据没有可回跳的时间戳" : "点击回跳到这一句")
    .accessibilityLabel("证据：\(suggestion.name)，\(evidence.howLabel)")
  }

  /// 证据 chip:时间戳 + 引文,点击回跳原话;拿不到秒数就只展示不跳,不编时间。
  /// 窄栏里引文给两行,截成一行看不出这条证据凭什么成立。
  private func evidenceChip(_ suggestion: SpeakerNameSuggestion) -> some View {
    let timecode = suggestion.anchor?.timecode
    let seconds = suggestion.anchor?.seconds
    return Button {
      if let seconds {
        onJump(seconds)
      }
    } label: {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        if let timecode {
          Text(timecode)
            .font(Tokens.V1.Text.timecode.font)
            .foregroundStyle(Tokens.V1.Color.ink4)
        }
        Text("「\(suggestion.evidenceQuote)」")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Tokens.V1.Space.xs)
      .padding(.vertical, Tokens.V1.Space.s2xs)
      .background(
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm).fill(Tokens.V1.Color.paper2)
      )
    }
    .buttonStyle(.plain)
    .hoverStrokeOutline(cornerRadius: Tokens.V1.Radius.sm)
    .disabled(seconds == nil)
    .help(
      seconds == nil
        ? "「\(suggestion.evidenceQuote)」——这条证据没有可回跳的时间戳"
        : "「\(suggestion.evidenceQuote)」——点击回跳到原话"
    )
    .accessibilityLabel("证据：\(suggestion.evidenceQuote)")
  }
}
