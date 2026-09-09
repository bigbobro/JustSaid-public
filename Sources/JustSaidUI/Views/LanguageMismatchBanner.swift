import JustSaidCore
import SwiftUI

/// 语言错配提示横幅(P2-b):开录约 30 秒后,速记检测到的语言与所选不符时,
/// 挂在工具栏下方的横幅栈里提示「一键切换或本场忽略」。
///
/// 纪律与边界(与 1883e15 的智能默认同一条底线):
/// - **只提示、绝不自动改**——手选永远优先;
/// - 「切换」更新的是语言选择器(下一场开录生效),**不会中途重启本场速记引擎**
///   ——buffer handler 在开录时就闭包捕获了引擎,中途换引擎要动音频链路,不值得冒险;
/// - 提示的真正价值是让用户在 30 秒内发现选错了:此刻废弃重录代价还小,
///   而不是录满一小时才发现速记全是乱码;
/// - 本场的云端精转本就按实际语言自动判定(`MeetingLanguageDetector`),不受所选影响。
public struct LanguageMismatchBanner: View {
  public let selected: MeetingLanguage
  public let detected: MeetingLanguage
  public let onSwitch: () -> Void
  public let onIgnore: () -> Void

  public init(
    selected: MeetingLanguage,
    detected: MeetingLanguage,
    onSwitch: @escaping () -> Void,
    onIgnore: @escaping () -> Void
  ) {
    self.selected = selected
    self.detected = detected
    self.onSwitch = onSwitch
    self.onIgnore = onIgnore
  }

  /// 速记片段已覆盖约 30 秒、检测语言明确且与所选不符时,返回检测到的语言;
  /// 否则返回 nil(覆盖不足、混说、或与所选一致都不提示)。
  /// 30 秒门槛用片段自带的相对时间而不是挂钟:静场没有文本,挂钟到点也没东西可判。
  public static func detectMismatch(
    selected: MeetingLanguage,
    segments: [TranscriptSegment]
  ) -> MeetingLanguage? {
    guard segments.contains(where: { $0.isFinal && $0.t1 >= 30 }) else {
      return nil
    }
    let detected: MeetingLanguage?
    switch MeetingLanguageDetector.detect(segments) {
    case .english:
      detected = .english
    case .chinese:
      detected = .chinese
    case .auto:
      detected = nil
    }
    guard let detected, detected != selected else {
      return nil
    }
    return detected
  }

  /// 低产出判定(语言错配的盲区补丁,2026-07-31 实测事故):说中文时英文引擎会把语音
  /// **音译成英文碎词**("Wait, you know, ma."),文本语种检测因此判"一致"、错配横幅
  /// 永不触发——错误的引擎污染了用来发现错误的证据。这条启发式不看语种只看产出量:
  /// 速记终稿已覆盖 ≥45 秒、可读字符(字母/数字/汉字)总量却不足 30,说明引擎几乎
  /// 听不懂进来的声音(语言选错/麦克风没进声),该提醒用户了。
  /// 静场不误报:没有终稿片段到达 45 秒就不判。
  public static func detectLowOutput(segments: [TranscriptSegment]) -> Bool {
    let finals = segments.filter(\.isFinal)
    guard finals.contains(where: { $0.t1 >= 45 }) else {
      return false
    }
    let readableCount =
      finals
      .reduce(into: 0) { count, segment in
        count +=
          segment.text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
          }.count
      }
    return readableCount < 30
  }

  private static func shortName(_ language: MeetingLanguage) -> String {
    language == .english ? "英语" : "中文"
  }

  public var body: some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Image(systemName: "waveform.badge.exclamationmark")
        .accessibilityHidden(true)
      Text(
        "速记听到的更像\(Self.shortName(detected))，本场语言选的是\(Self.shortName(selected))"
      )

      Spacer()

      Button("改选\(Self.shortName(detected))", action: onSwitch)
        .buttonStyle(.textAction)
        .fontWeight(.semibold)
        .help("更新语言选择，下一场开录生效；本场速记引擎不变，云端精转会按实际语言自动判定")
        .runtimeAccessibilityIdentifier("language-mismatch.switch")

      Button("本场忽略", action: onIgnore)
        .buttonStyle(.textAction)
        .runtimeAccessibilityIdentifier("language-mismatch.ignore")
    }
    .font(.system(size: Tokens.FontSize.ui))
    .foregroundStyle(Tokens.Color.warn)
    .padding(.horizontal, Tokens.Spacing.md)
    .padding(.vertical, Tokens.Spacing.xs)
    .background(Tokens.Color.amber)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.Color.amberLine).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .runtimeAccessibilityIdentifier("banner.language-mismatch")
  }
}

/// 低产出提示横幅:与错配横幅同栈同视觉,但不依赖文本语种判断——音译污染骗不过它。
/// 「下一场改为 X」直接给出当前所选的另一种语言(只有两种,翻转即具体动作);
/// 同样只提示不自动改、不重启本场引擎。
public struct LowRecognitionBanner: View {
  public let selected: MeetingLanguage
  public let onSwitch: () -> Void
  public let onIgnore: () -> Void

  public init(
    selected: MeetingLanguage,
    onSwitch: @escaping () -> Void,
    onIgnore: @escaping () -> Void
  ) {
    self.selected = selected
    self.onSwitch = onSwitch
    self.onIgnore = onIgnore
  }

  private var other: MeetingLanguage {
    selected == .english ? .chinese : .english
  }

  private static func shortName(_ language: MeetingLanguage) -> String {
    language == .english ? "英语" : "中文"
  }

  public var body: some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Image(systemName: "waveform.badge.exclamationmark")
        .accessibilityHidden(true)
      Text(
        "速记几乎没有识别到内容——本场语言选的是\(Self.shortName(selected))，"
          + "可能选错了，或者麦克风没有进声"
      )

      Spacer()

      Button("下一场改为\(Self.shortName(other))", action: onSwitch)
        .buttonStyle(.textAction)
        .fontWeight(.semibold)
        .help("更新语言选择，下一场开录生效；本场速记引擎不变，云端精转会按实际语言自动判定")
        .runtimeAccessibilityIdentifier("low-recognition.switch")

      Button("本场忽略", action: onIgnore)
        .buttonStyle(.textAction)
        .runtimeAccessibilityIdentifier("low-recognition.ignore")
    }
    .font(.system(size: Tokens.FontSize.ui))
    .foregroundStyle(Tokens.Color.warn)
    .padding(.horizontal, Tokens.Spacing.md)
    .padding(.vertical, Tokens.Spacing.xs)
    .background(Tokens.Color.amber)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.Color.amberLine).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .runtimeAccessibilityIdentifier("banner.low-recognition")
  }
}
