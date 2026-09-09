import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

/// 放行原因的用户可见说法(08-21 ack 单四选 + user_annotated 预填),全 app 统一。
extension CompletenessAckReason {
  var displayLabel: String {
    switch self {
    case .paused: return "暂停/休息"
    case .waiting: return "等人无发言"
    case .deviceKnown: return "设备中断已知悉"
    case .userAnnotated: return "用户已标注"
    case .other: return "其他"
    }
  }
}

// 2026-08-20 批3 拆分:自 MeetingLibraryView.swift 按 MARK 边界机械迁出,零行为变更。
// 2026-08-21 ack 单:一行 verdict + 缺口文案扩成逐缺口行(放行/撤销/原因/互补轨)。
struct CompletenessDetailCard: View {
  let item: MeetingLibraryItem
  let ackError: String?
  let onAcknowledge: (CompletenessGap, CompletenessAckReason, String?) -> Void
  let onRevoke: (String) -> Void

  /// 「其他」原因的备注编辑现场:非 nil = 该缺口的备注输入行展开。呈现级状态,换场即清。
  @State private var noteDraftGapKey: String?
  @State private var noteDraft = ""

  var body: some View {
    // R0(批5,用户拍板「状态只说一遍」):全覆盖让位状态带 ●完备——真绿整卡不存在。
    // 缺口(red)、已确认(acknowledged,可撤销)、未定(undetermined)与
    // 「绿但有未放行的用户标注缺口」(R4:展示记录原文 + 一键放行)才展开明细。
    // 先看 reload 预载的合成裁决,真绿/无报告路径零 IO;需要明细时才读盘。
    // 显隐收在组件内,调用点无条件实例化不变。
    if let effective = item.effectiveCompleteness,
      effective.verdict != .green || !effective.openUserAnnotatedGapKeys.isEmpty,
      let report = CompletenessReport.load(from: item.paths)
    {
      VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
        Text(title(effective.verdict))
          .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
          .foregroundStyle(color(effective.verdict))
        if effective.verdict == .undetermined {
          ForEach(report.blocking, id: \.self) { line in
            Text(line)
              .font(.system(size: Tokens.FontSize.secondary))
              .foregroundStyle(Tokens.Color.ink3)
          }
        } else {
          ForEach(Array(report.gaps.enumerated()), id: \.offset) { _, gap in
            gapRow(gap, report: report, effective: effective)
          }
        }
        if let ackError {
          Text(ackError)
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.warn)
            .runtimeAccessibilityIdentifier("library.completeness.ack-error")
        }
      }
      .padding(.top, Tokens.Spacing.hairline)
      .runtimeAccessibilityIdentifier("library.completeness-card")
    }
  }

  @ViewBuilder
  private func gapRow(
    _ gap: CompletenessGap,
    report: CompletenessReport,
    effective: EffectiveCompleteness
  ) -> some View {
    let ack = effective.ackedGapKeys.contains(gap.gapKey)
      ? item.completenessAcks.first(where: { $0.gapKey == gap.gapKey })
      : nil
    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
      VStack(alignment: .leading, spacing: 0) {
        Text(gap.detail)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(ack == nil ? Tokens.Color.ink3 : Tokens.Color.ink4)
          .fixedSize(horizontal: false, vertical: true)
        if let otherTrack = otherTrackLine(for: gap, report: report) {
          Text(otherTrack)
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.ink4)
            .fixedSize(horizontal: false, vertical: true)
            .runtimeAccessibilityIdentifier(
              "library.completeness.gap.\(gap.gapKey).other-track")
        }
        if let ack {
          Text(ackedLabel(ack))
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.resolved)
            .fixedSize(horizontal: false, vertical: true)
        }
        if noteDraftGapKey == gap.gapKey {
          noteEditor(for: gap)
        }
      }
      Spacer(minLength: Tokens.Spacing.xs)
      if let ack {
        Button("撤销") {
          onRevoke(ack.gapKey)
        }
        .buttonStyle(.textAction)
        .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink3)
        .help("撤销这条放行，缺口重新计入完备度")
        .runtimeAccessibilityIdentifier("library.completeness.gap.\(gap.gapKey).revoke")
      } else if gap.kind == "user_annotated" {
        // R4:会中已有用户记录的缺口,一键放行,原因预填「用户已标注」。
        Button("确认放行") {
          onAcknowledge(gap, .userAnnotated, nil)
        }
        .buttonStyle(.textAction)
        .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
        .foregroundStyle(Tokens.Color.acDeep)
        .help("会中已有你的记录，放行后不再计入缺口")
        .runtimeAccessibilityIdentifier("library.completeness.gap.\(gap.gapKey).ack")
      } else if noteDraftGapKey != gap.gapKey {
        Menu {
          Button(CompletenessAckReason.paused.displayLabel) {
            onAcknowledge(gap, .paused, nil)
          }
          Button(CompletenessAckReason.waiting.displayLabel) {
            onAcknowledge(gap, .waiting, nil)
          }
          Button(CompletenessAckReason.deviceKnown.displayLabel) {
            onAcknowledge(gap, .deviceKnown, nil)
          }
          Button("其他（填写备注）…") {
            noteDraft = ""
            noteDraftGapKey = gap.gapKey
          }
        } label: {
          Text("确认放行")
            .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
            .foregroundStyle(Tokens.Color.acDeep)
        }
        .menuStyle(.button)
        .buttonStyle(.textAction)
        .fixedSize()
        .help("机器修不了的缺口，由你选原因放行销账；放行不改动任何录音与转写")
        .runtimeAccessibilityIdentifier("library.completeness.gap.\(gap.gapKey).ack")
      }
    }
  }

  private func noteEditor(for gap: CompletenessGap) -> some View {
    HStack(spacing: Tokens.Spacing.xs) {
      TextField("放行原因备注", text: $noteDraft)
        .textFieldStyle(.plain)
        .font(.system(size: Tokens.FontSize.secondary))
        .frame(maxWidth: 220)
        .insetPanel()
        .runtimeAccessibilityIdentifier("library.completeness.gap.\(gap.gapKey).ack-note")
      Button("放行") {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onAcknowledge(gap, .other, trimmed.isEmpty ? nil : trimmed)
        noteDraftGapKey = nil
        noteDraft = ""
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
      .foregroundStyle(Tokens.Color.acDeep)
      .runtimeAccessibilityIdentifier(
        "library.completeness.gap.\(gap.gapKey).ack-note-confirm")
      Button("取消") {
        noteDraftGapKey = nil
        noteDraft = ""
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.secondary))
      .foregroundStyle(Tokens.Color.ink3)
    }
    .padding(.top, Tokens.Spacing.hairline)
  }

  private func ackedLabel(_ ack: CompletenessAck) -> String {
    var label = "已放行 · \(ack.reason.displayLabel)"
    if let note = ack.note, !note.isEmpty {
      label += "：\(note)"
    }
    return label
  }

  /// 互补轨提示(R3):late/track_fail 缺口展示另一轨录音时长,帮助判断实际损失。
  /// 数据来自 scanner 已算出的 `trackCoverage`(v3),旧快照无字段则整行隐藏,
  /// 不在 UI 层再跑 afinfo。
  private func otherTrackLine(
    for gap: CompletenessGap,
    report: CompletenessReport
  ) -> String? {
    guard gap.kind == "late" || gap.kind == "track_fail",
      let coverage = report.trackCoverage
    else { return nil }
    let failedTrack: String
    if gap.rangeLabel.hasPrefix("mic") {
      failedTrack = "mic"
    } else if gap.rangeLabel.hasPrefix("system") {
      failedTrack = "system"
    } else {
      return nil
    }
    let otherName = failedTrack == "mic" ? "system" : "mic"
    guard
      let otherSeconds = failedTrack == "mic" ? coverage.systemSeconds : coverage.micSeconds
    else { return nil }
    guard let endedAt = item.endedAt, endedAt > item.startedAt else {
      return "\(otherName) 轨录到 \(otherSeconds)s"
    }
    let recordingDuration = Int(endedAt.timeIntervalSince(item.startedAt).rounded())
    var line = "\(otherName) 轨录到 \(otherSeconds)s，本次录音共 \(recordingDuration)s"
    // 60 与 lateThreshold 同源:另一轨自身不短欠时,才给出定性判断。
    if Double(recordingDuration - otherSeconds) <= CompletenessScanner.lateThreshold {
      line += otherName == "system" ? "，系统声音内容大概率完整" : "，麦克风内容大概率完整"
    }
    return line
  }

  private func title(_ verdict: EffectiveCompletenessVerdict) -> String {
    switch verdict {
    case .green: return "完整性 · 有用户标注的缺口"
    case .acknowledged: return "完整性 · 已确认（缺口已人工放行）"
    case .red: return "完整性 · 有缺口"
    case .undetermined: return "完整性 · 未知"
    }
  }

  private func color(_ verdict: EffectiveCompletenessVerdict) -> Color {
    switch verdict {
    case .green: return Tokens.Color.ink3
    case .acknowledged: return Tokens.Color.resolved
    case .red: return Tokens.Color.warn
    case .undetermined: return Tokens.Color.ink4
    }
  }
}

/// 行内 A 词汇 chip(2026-08-21 批3):16 高 / Radius.chip / FontSize.badge / 语义软底+同族描边。
struct LibraryRowChip: View {
  let label: String
  let foreground: Color
  let fill: Color
  let stroke: Color
  var weight: Font.Weight = .semibold

  var body: some View {
    Text(label)
      .font(.system(size: Tokens.FontSize.badge, weight: weight))
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, Tokens.Spacing.xxs)
      .frame(height: Tokens.Layout.libraryRowChipHeight)
      .background(
        RoundedRectangle(cornerRadius: Tokens.Radius.chip).fill(fill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.chip)
          .stroke(stroke, lineWidth: 1)
      )
  }
}

struct CompletenessBadge: View {
  /// 合成裁决(08-21 ack 单):`acknowledged` = 机器判红但缺口已全部人工放行,
  /// 「已确认」样式走降档描边款(cardWash + line),与真 green 的软底款可区分。
  let verdict: EffectiveCompletenessVerdict?

  var body: some View {
    if let verdict {
      LibraryRowChip(
        label: label,
        foreground: foreground,
        fill: fill,
        stroke: stroke
      )
      .accessibilityLabel("完整性：\(label)")
      .help(help)
      .runtimeAccessibilityIdentifier("library.row.completeness.\(verdict.rawValue)")
    }
  }

  private var label: String {
    switch verdict {
    case .green: return "整"
    case .acknowledged: return "已确认"
    case .red: return "缺"
    case .undetermined, .none: return "未知"
    }
  }

  private var help: String {
    switch verdict {
    case .acknowledged: return "完整性：缺口已由你确认放行"
    default: return "完整性：\(label)"
    }
  }

  private var foreground: Color {
    switch verdict {
    case .green, .acknowledged: return Tokens.Color.resolved
    case .red: return Tokens.Color.warn
    case .undetermined, .none: return Tokens.Color.ink4
    }
  }

  private var fill: Color {
    switch verdict {
    case .green: return Tokens.Color.resolvedSoft
    case .red: return Tokens.Color.warnSoft
    case .acknowledged, .undetermined, .none: return Tokens.Color.cardWash
    }
  }

  private var stroke: Color {
    switch verdict {
    case .green: return Tokens.Color.resolved
    case .red: return Tokens.Color.amberLine
    case .acknowledged, .undetermined, .none: return Tokens.Color.line
    }
  }
}

struct MeetingArtifactProgressMarks: View {
  let transcription: MeetingArtifactProgress
  let minutes: MeetingArtifactProgress

  var body: some View {
    HStack(spacing: Tokens.Spacing.xxs) {
      mark("精", kind: "transcription", progress: transcription)
      mark("纪", kind: "minutes", progress: minutes)
    }
    .runtimeAccessibilityIdentifier(
      "library.row.progress.transcription-\(transcription.rawValue).minutes-\(minutes.rawValue)"
    )
  }

  private func mark(
    _ label: String,
    kind: String,
    progress: MeetingArtifactProgress
  ) -> some View {
    LibraryRowChip(
      label: label,
      foreground: foreground(for: progress),
      fill: fill(for: progress),
      stroke: stroke(for: progress)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label)·\(stateLabel(for: progress))")
    .help("\(label)·\(stateLabel(for: progress))")
    .runtimeAccessibilityIdentifier("library.row.\(kind).\(progress.rawValue)")
  }

  private func foreground(for progress: MeetingArtifactProgress) -> Color {
    switch progress {
    case .completed: Tokens.Color.resolved
    case .inProgress: Tokens.Color.ac
    case .failed: Tokens.Color.warn
    case .notStarted: Tokens.Color.ink4
    }
  }

  private func fill(for progress: MeetingArtifactProgress) -> Color {
    switch progress {
    case .completed: Tokens.Color.resolvedSoft
    case .inProgress: Tokens.Color.acSoft
    case .failed: Tokens.Color.warnSoft
    case .notStarted: Tokens.Color.cardWash
    }
  }

  private func stroke(for progress: MeetingArtifactProgress) -> Color {
    switch progress {
    case .completed: Tokens.Color.resolved
    case .inProgress: Tokens.Color.acLine
    case .failed: Tokens.Color.amberLine
    case .notStarted: Tokens.Color.line
    }
  }

  private func stateLabel(for progress: MeetingArtifactProgress) -> String {
    switch progress {
    case .completed: "完成"
    case .inProgress: "进行中"
    case .failed: "失败"
    case .notStarted: "未做"
    }
  }
}

struct MeetingStatusDot: View {
  let status: MeetingStatus

  var body: some View {
    Group {
      if status == .recording {
        PulsingDot(color: Tokens.Color.rec, size: 6)
      } else {
        Circle()
          .fill(MeetingStatusBadge.color(for: status))
          .frame(width: 6, height: 6)
      }
    }
    .accessibilityLabel(MeetingStatusBadge.label(for: status, finalized: false))
  }
}

/// 「完整转写」页签的认名待办状态点(08-20 naming-first R4 拍板③,方案已评审):
/// 有未决预填建议时在页签标题旁亮一个与库列表状态点同语言的 6pt 圆点——
/// 取 `Tokens.Color.warn`(与「部分录音」「会后处理未完成」同一支警示色,
/// 不自造第二种提醒色),令牌自带浅/深两档,暗色两态随之自适应。不打扰但可发现:
/// 点开页签,命名行与建议横幅就在顶部。
/// 显隐收在本视图内(verification 红线 6):0 条时整点不存在,调用点无条件实例化。
struct TranscriptTabNamingBadge: View {
  let pendingCount: Int

  var body: some View {
    if pendingCount > 0 {
      Circle()
        .fill(Tokens.Color.warn)
        .frame(width: 6, height: 6)
        .accessibilityLabel("有 \(pendingCount) 条认名建议未处理")
        .help("有 \(pendingCount) 条认名建议未处理，先认名可让纪要更准")
        .runtimeAccessibilityIdentifier("library.tab.transcript.badge")
    }
  }
}

/// "部分录音"徽章(08-05 事故):单路采集失败但整场仍完成的会议,在状态徽章旁
/// 亮出可辨识标识;悬停给出逐路缺失起点(mm:ss)。老 failed 会议不挂它。
struct PartialCaptureBadge: View {
  let summary: String

  var body: some View {
    StatusCapsuleBadge(label: "部分录音", color: Tokens.Color.warn)
      .help(summary)
      .runtimeAccessibilityIdentifier("library.partial-capture")
  }
}

struct MeetingStatusBadge: View {
  let status: MeetingStatus
  let finalized: Bool

  static func color(for status: MeetingStatus) -> Color {
    switch status {
    case .recording: return Tokens.Color.rec
    case .processing: return Tokens.Color.ac
    case .completed: return Tokens.Color.ink4
    case .failed, .interrupted: return Tokens.Color.warn
    }
  }

  static func label(for status: MeetingStatus, finalized: Bool) -> String {
    if finalized {
      return "已定稿"
    }
    switch status {
    case .recording: return "录制中"
    case .processing: return "会后处理中"
    case .completed: return "已完成"
    case .failed: return "会后处理未完成"
    case .interrupted: return "上次未正常结束"
    }
  }

  var body: some View {
    // R0(批5):completed 未定稿的常态不再挂「已完成」徽章——状态带已表达;
    // 异常态(录制中/处理中/失败/中断)与「已定稿」照旧。显隐收在组件内。
    if finalized || status != .completed {
      StatusCapsuleBadge(
        label: Self.label(for: status, finalized: finalized),
        color: Self.color(for: status)
      )
    }
  }
}
