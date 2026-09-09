import JustSaidCore
import SwiftUI

/// 「排除时间段」UI 入口的共享逻辑(08-14 单)。数据契约在 Core
/// (`.trellis/spec/core/exclusion-ranges-contract.md`),这里只做覆盖判定、
/// 话题时间标签解析与会中常驻细带——读写一律走 `MeetingStore` 四个 API,
/// 本文件不碰 meeting.json,更不碰 transcript.md。
enum ExclusionUI {
  /// 契约 origin 的四个合法取值。origin 是自由字符串、无编译期约束,
  /// 所有写入入口只允许从这里取,新增取值先改契约 spec。
  enum Origin {
    static let liveToggle = "liveToggle"
    static let liveRetro = "liveRetro"
    static let bulletMark = "bulletMark"
    static let postSelect = "postSelect"
  }

  /// 某时刻落在哪条排除区间里。必须用**原始** excludedRanges 自己判:
  /// `ExclusionPolicy` 把区间归并了,按 id 撤销时拿不到归并前的记录。
  /// 多条同时覆盖(会中开区间压住会前已封口的段)时,优先撤会中标记
  /// (liveRetro/liveToggle),再撤最短区间——误标的通常是更具体的那条。
  static func coveringRange(
    at time: TimeInterval,
    in ranges: [ExcludedRange]
  ) -> ExcludedRange? {
    let covering = ranges.filter { range in
      range.start <= time && time <= (range.end ?? .infinity)
    }
    let live = covering.filter {
      $0.origin == Origin.liveRetro || $0.origin == Origin.liveToggle
    }
    let candidates = live.isEmpty ? covering : live
    return candidates.min { lhs, rhs in
      (lhs.end ?? .infinity) - lhs.start < (rhs.end ?? .infinity) - rhs.start
    }
  }

  /// 最近的未封口区间(start 最大者)。「结束闲聊」与散会兜底封的都是它;
  /// 不限 origin——liveRetro 追标的开区间同样靠这个开关封口。
  static func openRange(in ranges: [ExcludedRange]) -> ExcludedRange? {
    ranges.filter { $0.end == nil }.max { $0.start < $1.start }
  }

  /// 解析话题块的 `timeRangeLabel`(如 "00:12:03–00:18:40")。
  /// 镜像 Core `ExclusionPolicy.topicRange` 的私有逻辑(分隔符集一致);
  /// 它是 private 的,UI 侧只能自写一份。解析失败返回 nil,菜单项据此置灰。
  static func topicRangeSeconds(_ label: String) -> ClosedRange<TimeInterval>? {
    let parts =
      label
      .components(separatedBy: CharacterSet(charactersIn: "–—-~至"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard
      parts.count == 2,
      let start = TranscriptAnchor(timecode: parts[0]).seconds,
      let end = TranscriptAnchor(timecode: parts[1]).seconds,
      start <= end
    else {
      return nil
    }
    return start...end
  }
}

/// 「不进纪要」小标记(08-14):会中实时段与会后转写行共用,灰阶描边款,
/// 只是状态、不需要行动——权重对齐 ✓✎● 那一档。只用灰阶不占色相,
/// 与发言人高亮(并行任务)不冲突。
struct ExcludedMarker: View {
  var body: some View {
    Text("不进纪要")
      .font(.system(size: Tokens.FontSize.micro, weight: .semibold))
      .foregroundStyle(Tokens.Color.ink4)
      .padding(.horizontal, Tokens.Spacing.xxs)
      .padding(.vertical, Tokens.Spacing.hairline)
      .overlay(Capsule().stroke(Tokens.Color.line, lineWidth: 1))
  }
}

/// 「闲聊中」常驻细带(08-14):只要存在未封口的排除区间就必须常驻显眼——
/// 开区间的语义是「start 之后整场不进纪要」,隐蔽状态会悄悄吞掉后半场纪要。
/// 显隐判断收在视图内部(验证红线 6),调用点无条件实例化。
/// 样式对齐 legHealthBanner:amber 底 + warn 字 + 底部细线,chrome 不走 textScale。
public struct ChatExclusionBanner: View {
  /// 未封口区间的起点(会议时间轴秒);nil = 没有闲聊在进行,整条结构不存在。
  public let openRangeStart: TimeInterval?
  public let onClose: () -> Void

  public init(openRangeStart: TimeInterval?, onClose: @escaping () -> Void) {
    self.openRangeStart = openRangeStart
    self.onClose = onClose
  }

  public var body: some View {
    if let openRangeStart {
      HStack(spacing: Tokens.Spacing.xsm) {
        Image(systemName: "exclamationmark.triangle.fill")
        Text("闲聊中：从 \(TranscriptAnchor(seconds: openRangeStart).timecode) 起的内容不进纪要")
        Spacer()
        Button("结束闲聊", action: onClose)
          .buttonStyle(.textAction)
          .fontWeight(.semibold)
          .accessibilityLabel("结束闲聊，之后的会议内容重新进纪要")
          .runtimeAccessibilityIdentifier("toolbar.chat-banner.close")
      }
      .font(.system(size: Tokens.FontSize.uiEmphasis))
      .foregroundStyle(Tokens.Color.warn)
      .padding(.horizontal, Tokens.Spacing.md)
      .padding(.vertical, Tokens.Spacing.xs)
      .background(Tokens.Color.amber)
      .overlay(alignment: .bottom) {
        Rectangle().fill(Tokens.Color.amberLine).frame(height: 1)
      }
      .accessibilityElement(children: .contain)
      .runtimeAccessibilityIdentifier("toolbar.chat-banner")
    }
  }
}
