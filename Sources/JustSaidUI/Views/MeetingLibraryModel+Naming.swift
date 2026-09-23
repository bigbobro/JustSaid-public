import AppKit
import Foundation
import JustSaidCore
import SwiftUI

// 2026-08-20 批3 拆分:自 MeetingLibraryModel.swift 按 MARK 边界机械迁出,零行为变更;
// 存储属性依 Swift 约束全部留在主文件(恰好锁死零行为)。
extension MeetingLibraryModel {
  // MARK: - 认名预填(08-17 #7;规则升级 08-20 naming-first R2)

  /// 转写页认名横幅的行集。数据源(08-20 起):`speaker-suggestions.json`(指纹匹配)
  /// 优先,否则回落 minutes.json——结算在 `MeetingArtifacts.speakerNamingSuggestions`,
  /// 老会议行为不变。规则结算委托给下面的纯函数,本方法只负责取数。
  func namingSuggestionRows(for item: MeetingLibraryItem) -> [SpeakerNamingSuggestionRow] {
    let suggestions = artifacts(for: item).speakerNamingSuggestions
    guard !suggestions.isEmpty else { return [] }
    return Self.namingSuggestionRows(
      suggestions: suggestions,
      speakerNames: artifactCache[item.id]?.transcript.metadata.speakerNames ?? [:],
      dismissedSuggestions: artifactCache[item.id]?.transcript.metadata.dismissedSpeakerSuggestions
        ?? [],
      rosterForms: rosterForms(neededFor: suggestions)
    )
  }

  /// 名册懒加载:只有存在 addressed 级建议时才需要名册(selfIntro 判定用不到),
  /// 无建议/纯 selfIntro 场景不碰词典文件。读失败按空名册处理(预填退化为不认名册命中)。
  private func rosterForms(neededFor suggestions: [SpeakerNameSuggestion]) -> [String] {
    guard suggestions.contains(where: { $0.level == .addressed }) else { return [] }
    if let cachedRosterForms {
      return cachedRosterForms
    }
    let forms = ((try? dictionaryStore.loadEntries()) ?? []).flatMap(\.allSpokenForms)
    cachedRosterForms = forms
    return forms
  }

  /// 预填规则(纯函数,验证程序直接驱动矩阵;08-20 naming-first design 决策 5):
  /// - 只看**未命名**标签(`speakerNames[label]` 空);已命名 = 用户已拍板,整组不再出;
  /// - 被拒绝的建议(`dismissedSuggestions` 含 `"<label>|<name>"`)不再出;
  /// - 参与预填的强证据:selfIntro 照旧;addressed 须有佐证——
  ///   a. 互称对:另一标签也有 addressed 建议,label 不同、name 不同,
  ///      两条锚点都在且相差 ≤60s(互称对检索用**全集**:证据是否成立看转写事实,
  ///      不随对家已命名/已拒绝而消失);
  ///   b. 名册命中:name 精确等于名册 canonical 或在册称呼(不做模糊——模糊命中
  ///      交给提取模型,它拿着名册);
  /// - 孤立 addressed / thirdParty 是弱证据:不预填也不展示(08-20 UI 方案拍板①);
  /// - 冲突门:同一标签的**强证据**指向 ≥2 个不同名字 → 不预填,只出提示行;
  /// - 「本侧为主」通道不参与判定(app 不知道用户叫什么,证不出名字)。
  nonisolated public static func namingSuggestionRows(
    suggestions: [SpeakerNameSuggestion],
    speakerNames: [String: String],
    dismissedSuggestions: [String],
    rosterForms: [String]
  ) -> [SpeakerNamingSuggestionRow] {
    let dismissed = Set(dismissedSuggestions)
    let roster = Set(rosterForms)
    var labelOrder: [String] = []
    var byLabel: [String: [SpeakerNameSuggestion]] = [:]
    for suggestion in suggestions {
      guard
        isPrefillGradeEvidence(suggestion, in: suggestions, roster: roster),
        (speakerNames[suggestion.label] ?? "").isEmpty,
        !dismissed.contains("\(suggestion.label)|\(suggestion.name)")
      else {
        continue
      }
      if byLabel[suggestion.label] == nil {
        labelOrder.append(suggestion.label)
      }
      byLabel[suggestion.label, default: []].append(suggestion)
    }
    return labelOrder.compactMap { label in
      guard let evidences = byLabel[label], let first = evidences.first else {
        return nil
      }
      let distinctNames = Set(evidences.map(\.name))
      if distinctNames.count >= 2 {
        return .conflict(label: label, evidences: evidences)
      }
      return .prefill(first)
    }
  }

  /// 互称对锚点窗口(design 拍板 ≤60s;今日样本 00:00:10/00:00:11)。
  nonisolated private static let mutualAddressWindow: TimeInterval = 60

  /// 一条建议是否够格参与预填/冲突结算(强证据判定)。
  nonisolated private static func isPrefillGradeEvidence(
    _ suggestion: SpeakerNameSuggestion,
    in allSuggestions: [SpeakerNameSuggestion],
    roster: Set<String>
  ) -> Bool {
    switch suggestion.level {
    case .selfIntro:
      return true
    case .thirdParty:
      return false
    case .addressed:
      if roster.contains(suggestion.name) {
        return true
      }
      guard let seconds = suggestion.anchor?.seconds else { return false }
      return allSuggestions.contains { other in
        other.level == .addressed
          && other.label != suggestion.label
          && other.name != suggestion.name
          && other.anchor?.seconds.map { abs($0 - seconds) <= mutualAddressWindow }
            == true
      }
    }
  }

  /// 一条认名证据在画面上要说清的三件事:它主张谁叫什么、这个主张是怎么来的、
  /// 以及**原文到底怎么说的**。
  ///
  /// 为什么不直接用 `evidenceQuote`:那是提取模型自己写的引文,不保证等于锚点处的原话。
  /// 2026-09-20 实测这场会 13 条建议里 7 条的引文根本不含被建议的名字,还有一条
  /// (发言人 1 → 袁建嵩 @00:39:13)的引文与该时刻的转写对不上。锚点是可信的,引文不是。
  /// 所以按锚点回原文取真话;取不到才退回引文,并如实标出。
  struct NamingEvidence: Identifiable {
    let suggestion: SpeakerNameSuggestion
    /// 锚点处那一段的真实说话人。`addressed` 证据天然是**别人**在叫他,
    /// 所以这里经常不是 `suggestion.label`——画面必须说出来,否则点过去像跳错了。
    let spokenBy: String?
    let quote: String
    /// 引文取自原文(true)还是退回模型写的那句(false)。
    let fromTranscript: Bool
    /// 原话里根本没有这个名字。这条证据支撑不了它的主张,排最后并标出来。
    let nameMissingFromQuote: Bool
    /// 锚点之后第一个换人说话的段落。`addressed` 证据里,被叫的人通常就是接话的那个。
    let answeredBy: String?
    /// 拿转写核对这条归属的结论。**只报告,不改数据**——修归属是推理机制的事,
    /// 不是这一批前端重构的事(owner 2026-09-20)。
    let verdict: Verdict

    enum Verdict {
      /// 说这句的不是他、接话的是他——方向对。
      case consistent
      /// 锚点那句就是他自己说的。没人用第三人称叫自己,所以这条归属反了:
      /// 他是**叫别人**的那个,名字应该归接话的人。
      case inverted
      /// 说这句的不是他,但接话的也不是他。看不出来。
      case unclear
      /// 不是称呼级证据,或者锚点在原文里找不到,核不了。
      case notChecked
    }
    var id: String { "\(suggestion.label)|\(suggestion.name)|\(suggestion.anchor?.timecode ?? "-")" }

    var howLabel: String {
      switch suggestion.level {
      case .selfIntro: return "他自己说的"
      case .addressed: return "别人这么叫他"
      case .thirdParty: return "别人提到他"
      }
    }

    /// 核对结论的一句话说明;nil = 不用说。
    var verdictNote: String? {
      switch verdict {
      case .consistent:
        return answeredBy.map { "接话的是「\($0)」——对得上" }
      case .inverted:
        let who = answeredBy.map { "「\($0)」" } ?? "接话的那个人"
        return "这句是「\(suggestion.label)」自己说的——他在叫别人。这个名字八成是 \(who) 的"
      case .unclear:
        return "接话的不是他，看不出来"
      case .notChecked:
        return nil
      }
    }

    var verdictIsBad: Bool { verdict == .inverted }
  }

  /// 把建议配上锚点处的真实原话与真实说话人,按可信度排序(原话里有名字的在前)。
  func namingEvidence(
    _ suggestions: [SpeakerNameSuggestion],
    of item: MeetingLibraryItem
  ) -> [NamingEvidence] {
    let rows = transcriptPresentation(for: item).rows
    var speech: [TranscriptSpeechLine] = []
    for row in rows {
      if case .speech(let line) = row { speech.append(line) }
    }
    var indexByTimecode: [String: Int] = [:]
    for (index, line) in speech.enumerated() where indexByTimecode[line.timestamp] == nil {
      indexByTimecode[line.timestamp] = index
    }
    return suggestions.map { suggestion in
      // 只认时间戳精确相等。取到隔壁那一段比退回引文更糟——它会挂上一个错的说话人。
      let index = suggestion.anchor.flatMap { indexByTimecode[$0.timecode] }
      let line = index.map { speech[$0] }
      let quote =
        line?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? suggestion.evidenceQuote
      let needle = suggestion.name.count > 2 ? String(suggestion.name.suffix(2)) : suggestion.name
      let answeredBy = index.flatMap { Self.nextDifferentSpeaker(after: $0, in: speech) }
      let verdict: NamingEvidence.Verdict
      if suggestion.level != .addressed || line == nil {
        verdict = .notChecked
      } else if line?.speaker == suggestion.label {
        verdict = .inverted
      } else if answeredBy == suggestion.label {
        verdict = .consistent
      } else {
        verdict = .unclear
      }
      return NamingEvidence(
        suggestion: suggestion,
        spokenBy: line?.speaker,
        quote: quote,
        fromTranscript: line != nil,
        nameMissingFromQuote: !quote.contains(suggestion.name) && !quote.contains(needle),
        answeredBy: answeredBy,
        verdict: verdict
      )
    }
    // 站得住的排前面:先按核对结论,再按原话里有没有这个名字。
    .sorted { lhs, rhs in
      if lhs.verdictIsBad != rhs.verdictIsBad { return !lhs.verdictIsBad }
      return !lhs.nameMissingFromQuote && rhs.nameMissingFromQuote
    }
  }

  /// 锚点之后第一个换人说的那一段。只往后看几段——隔太远就不是在回应这句称呼了。
  nonisolated private static func nextDifferentSpeaker(
    after index: Int,
    in speech: [TranscriptSpeechLine]
  ) -> String? {
    let speaker = speech[index].speaker
    for offset in 1...5 {
      let next = index + offset
      guard next < speech.count else { return nil }
      if speech[next].speaker != speaker { return speech[next].speaker }
    }
    return nil
  }

  /// 采纳 = 与手动改名完全同一条通道(setSpeakerName);真名随之在转写呈现生效。
  public func adoptNamingSuggestion(
    _ suggestion: SpeakerNameSuggestion,
    of item: MeetingLibraryItem
  ) {
    setSpeakerName(suggestion.name, for: suggestion.label, of: item)
  }

  /// 「不是」:拒绝写入 meeting.json,本场该建议不再预填;只作用于这一场会议。
  public func dismissNamingSuggestion(
    _ suggestion: SpeakerNameSuggestion,
    of item: MeetingLibraryItem
  ) {
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else { return }
    do {
      let fingerprint = try requireTranscriptEditContext(for: item)
      let metadata = try meetingStore.dismissSpeakerSuggestion(
        label: suggestion.label,
        name: suggestion.name,
        at: item.paths,
        expectedTranscriptFingerprint: fingerprint
      )
      meetings[index].dismissedSpeakerSuggestions =
        metadata.dismissedSpeakerSuggestions ?? []
      updateTranscriptMetadata(metadata, for: item)
      speakerNameError = nil
    } catch {
      speakerNameError = "这次拒绝没能存进 meeting.json:\(error.localizedDescription)"
    }
  }
}
