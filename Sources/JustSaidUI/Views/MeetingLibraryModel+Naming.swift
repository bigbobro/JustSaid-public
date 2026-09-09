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
      speakerNames: item.speakerNames,
      dismissedSuggestions: item.dismissedSpeakerSuggestions,
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

  /// 采纳 = 与手动改名完全同一条通道(setSpeakerName);真名随之在转写呈现生效。
  func adoptNamingSuggestion(
    _ suggestion: SpeakerNameSuggestion,
    of item: MeetingLibraryItem
  ) {
    setSpeakerName(suggestion.name, for: suggestion.label, of: item)
  }

  /// 「不是」:拒绝写入 meeting.json,本场该建议不再预填;只作用于这一场会议。
  func dismissNamingSuggestion(
    _ suggestion: SpeakerNameSuggestion,
    of item: MeetingLibraryItem
  ) {
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else { return }
    do {
      let metadata = try meetingStore.dismissSpeakerSuggestion(
        label: suggestion.label,
        name: suggestion.name,
        at: item.paths
      )
      meetings[index].dismissedSpeakerSuggestions =
        metadata.dismissedSpeakerSuggestions ?? []
      speakerNameError = nil
    } catch {
      speakerNameError = "这次拒绝没能存进 meeting.json:\(error.localizedDescription)"
    }
  }
}
