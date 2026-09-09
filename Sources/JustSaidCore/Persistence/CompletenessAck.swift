import Foundation

/// 完整性缺口人工放行(08-21 ack 单)。机器修不了、也判不了的缺口,由用户选原因
/// 放行销账;放行只影响完整性**展示与计数**,不改 transcript / 母带 /
/// completeness.json 任何字节(红线)。状态存 sidecar `completeness-ack.json`
/// (scan 每次原子重写 completeness.json,放行必须独立存活;删 sidecar 即回到
/// 纯机器裁决)。
public enum CompletenessAckReason: String, Codable, CaseIterable, Sendable {
  case paused
  case waiting
  case deviceKnown = "device_known"
  case userAnnotated = "user_annotated"
  case other
}

public struct CompletenessAck: Codable, Equatable, Sendable {
  /// 缺口身份三元组 `<start>-<end>-<kind>`(design 拍板):重扫产出同 key 缺口 →
  /// 放行沿用;参数变了 → 本 ack 成为孤儿,合成裁决读取时丢弃(不静默匹配相近缺口)。
  public var gapKey: String
  public var reason: CompletenessAckReason
  public var note: String?
  public var ackedAt: Date

  public init(
    gapKey: String,
    reason: CompletenessAckReason,
    note: String? = nil,
    ackedAt: Date = Date()
  ) {
    self.gapKey = gapKey
    self.reason = reason
    self.note = note
    self.ackedAt = ackedAt
  }
}

extension CompletenessGap {
  /// 放行锚定用的缺口身份(见 `CompletenessAck.gapKey`)。
  public var gapKey: String { "\(startSeconds)-\(endSeconds)-\(kind)" }
}

/// `completeness-ack.json` 的读写。缺失 = 无放行,行为与没有本功能时一致;
/// 解析失败按无放行处理(sidecar 是可再生的用户标记,不值得为它挡启动)。
public enum CompletenessAckStore {
  private struct AckFile: Codable {
    var acks: [CompletenessAck]
  }

  public static func load(from paths: MeetingPaths) -> [CompletenessAck] {
    guard let data = try? Data(contentsOf: paths.completenessAck) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(AckFile.self, from: data))?.acks ?? []
  }

  public static func save(_ acks: [CompletenessAck], to paths: MeetingPaths) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(AckFile(acks: acks))
    try data.write(to: paths.completenessAck, options: .atomic)
  }

  /// 放行一条缺口(同 key 已有放行则覆盖),返回落盘后的全量 ack 列表。
  @discardableResult
  public static func acknowledge(
    gapKey: String,
    reason: CompletenessAckReason,
    note: String? = nil,
    in paths: MeetingPaths,
    at date: Date = Date()
  ) throws -> [CompletenessAck] {
    var acks = load(from: paths).filter { $0.gapKey != gapKey }
    acks.append(CompletenessAck(gapKey: gapKey, reason: reason, note: note, ackedAt: date))
    try save(acks, to: paths)
    return acks
  }

  /// 撤销一条放行,返回落盘后的全量 ack 列表。孤儿 ack 也可被撤销(同一入口)。
  @discardableResult
  public static func revoke(
    gapKey: String,
    in paths: MeetingPaths
  ) throws -> [CompletenessAck] {
    let acks = load(from: paths).filter { $0.gapKey != gapKey }
    try save(acks, to: paths)
    return acks
  }
}

/// 合成裁决:机器 report + 用户放行 → 有效完备度。纯函数,scanner 本体不感知 ack。
public enum EffectiveCompletenessVerdict: String, Sendable, Hashable {
  case green
  /// 机器判红,但全部计红缺口已被用户放行——与真 green 可区分的「已确认」态。
  case acknowledged
  case red
  case undetermined
}

public struct EffectiveCompleteness: Equatable, Sendable {
  public let verdict: EffectiveCompletenessVerdict
  /// 有有效放行的缺口 key(按 start-end-kind 锚定;参数漂移的 ack 是孤儿,不在此列)。
  public let ackedGapKeys: Set<String>
  /// 未放行的 `user_annotated` 缺口 key:它们不判红(v2 判定),但 UI 要展示
  /// 记录原文并提供一键放行,verdict green 时的卡片显隐靠这一份。
  public let openUserAnnotatedGapKeys: Set<String>

  public init(
    verdict: EffectiveCompletenessVerdict,
    ackedGapKeys: Set<String>,
    openUserAnnotatedGapKeys: Set<String>
  ) {
    self.verdict = verdict
    self.ackedGapKeys = ackedGapKeys
    self.openUserAnnotatedGapKeys = openUserAnnotatedGapKeys
  }

  /// - `green` / `undetermined` 不被 ack 改写(放行不洗白输入缺失,也不给 green 加戏);
  /// - `red` 且全部计红缺口(kind != user_annotated,它们本就不判红)都有有效放行
  ///   → `acknowledged`;有任一计红缺口未放行 → 仍 `red`;
  /// - 计红缺口集合为空的 red(防御:理论上 redReasons 总伴随缺口)保持 `red`,
  ///   不允许零放行转「已确认」。
  public static func resolve(
    report: CompletenessReport,
    acks: [CompletenessAck]
  ) -> EffectiveCompleteness {
    let gapKeys = Set(report.gaps.map(\.gapKey))
    let acked = Set(acks.map(\.gapKey)).intersection(gapKeys)
    let openUserAnnotated = Set(
      report.gaps.filter { $0.kind == "user_annotated" }.map(\.gapKey)
    ).subtracting(acked)
    let verdict: EffectiveCompletenessVerdict
    switch report.verdict {
    case .green:
      verdict = .green
    case .undetermined:
      verdict = .undetermined
    case .red:
      let redGapKeys = Set(
        report.gaps.filter { $0.kind != "user_annotated" }.map(\.gapKey))
      verdict =
        (!redGapKeys.isEmpty && redGapKeys.subtracting(acked).isEmpty)
        ? .acknowledged : .red
    }
    return EffectiveCompleteness(
      verdict: verdict,
      ackedGapKeys: acked,
      openUserAnnotatedGapKeys: openUserAnnotated
    )
  }
}
