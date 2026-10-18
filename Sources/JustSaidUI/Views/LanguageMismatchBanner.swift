import JustSaidCore
import SwiftUI

/// 语言错配提示横幅(P2-b):开录约 30 秒后,速记检测到的语言与所选不符时,
/// 挂在工具栏下方的横幅栈里提示「一键切换或本场忽略」。
///
/// 纪律与边界:
/// - **只提示、绝不自动改**——手选永远优先;
/// - 「切换」在本场生效(owner 2026-10-16 定,推翻 2026-10-15「本场不切」):
///   速记引擎支持 `LiveLanguageSwitching` 时(Qwen3-ASR,language 是每段 stream 的 option),
///   从下一段起改用新语种,已出的片段不重写。实测事故:开录英文、说中文,点了改选后
///   本场仍被转成英文句子(issue #211)。
///   引擎不支持时(设置里手选的 SenseVoice / Apple)退回旧行为:只写下一场的偏好,文案也照实说。
/// - 这条横幅发现不了「被翻译成目标语言」的错配——读起来通顺,没有乱码可看。
/// - 会后精转语言来自 `MeetingLanguageDetector.detect(速记文本)`。切换前那段被错的语言
///   污染的速记仍在,检测结果可能因此判成混说。
public struct LanguageMismatchBanner: View {
  public let selected: MeetingLanguage
  public let detected: MeetingLanguage
  /// true:点「切换」本场就改用检测到的语种;false:引擎不支持,只改下一场。
  public let switchesThisMeeting: Bool
  public let onSwitch: () -> Void
  public let onIgnore: () -> Void

  public init(
    selected: MeetingLanguage,
    detected: MeetingLanguage,
    switchesThisMeeting: Bool,
    onSwitch: @escaping () -> Void,
    onIgnore: @escaping () -> Void
  ) {
    self.selected = selected
    self.detected = detected
    self.switchesThisMeeting = switchesThisMeeting
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

  private var switchTitle: String {
    LiveLanguageSwitchCopy.actionTitle(to: detected, switchesThisMeeting: switchesThisMeeting)
  }

  public var body: some View {
    HintBanner(
      systemImage: "waveform.badge.exclamationmark",
      text: "速记听到的更像\(Self.shortName(detected))，本场语言选的是\(Self.shortName(selected))"
    ) {
      // 中性底上 `.textAction` 不自带颜色(原来靠父级的警示色染),不显式上色就看不出可点。
      Button(switchTitle, action: onSwitch)
        .buttonStyle(.textAction)
        .fontWeight(.semibold)
        .foregroundStyle(Tokens.V1.Color.accent)
        .help(LiveLanguageSwitchCopy.help(switchesThisMeeting: switchesThisMeeting))
        .runtimeAccessibilityIdentifier("language-mismatch.switch")

      Button("本场忽略", action: onIgnore)
        .buttonStyle(.textAction)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .runtimeAccessibilityIdentifier("language-mismatch.ignore")
    }
    .runtimeAccessibilityIdentifier("banner.language-mismatch")
  }
}

/// 低产出提示横幅:与错配横幅同栈同视觉,但不依赖文本语种判断——音译污染骗不过它。
/// 「本场改用 X」直接给出当前所选的另一种语言(只有两种,翻转即具体动作);
/// 同样只提示不自动改;切换口径与错配横幅相同(`switchesThisMeeting`)。
public struct LowRecognitionBanner: View {
  public let selected: MeetingLanguage
  public let switchesThisMeeting: Bool
  public let onSwitch: () -> Void
  public let onIgnore: () -> Void

  public init(
    selected: MeetingLanguage,
    switchesThisMeeting: Bool,
    onSwitch: @escaping () -> Void,
    onIgnore: @escaping () -> Void
  ) {
    self.selected = selected
    self.switchesThisMeeting = switchesThisMeeting
    self.onSwitch = onSwitch
    self.onIgnore = onIgnore
  }

  private var other: MeetingLanguage {
    selected == .english ? .chinese : .english
  }

  private static func shortName(_ language: MeetingLanguage) -> String {
    language == .english ? "英语" : "中文"
  }

  private var switchTitle: String {
    LiveLanguageSwitchCopy.actionTitle(to: other, switchesThisMeeting: switchesThisMeeting)
  }

  /// 这条**不跟语言错配一起降中性**。文案自己写着「可能选错了,或者麦克风没有进声」——
  /// 后半句是采集问题:`legHealthBanner` 只管帧停摆,静音但有帧的数据在它眼里是 healthy,
  /// 所以低产出是「麦克风没进声」这个场景的唯一信号。一条横幅背着两种严重度,
  /// 按最重的那种归级(Fable 评审 2026-09-20)。
  /// 真正的修是按电平拆成两条,那要电平历史,是功能,不在本批。
  public var body: some View {
    NoticeShell(
      level: .warn,
      systemImage: "waveform.badge.exclamationmark",
      text: "速记几乎没有识别到内容——本场语言选的是\(Self.shortName(selected))，"
        + "可能选错了，或者麦克风没有进声"
    ) {
      Button(switchTitle, action: onSwitch)
        .buttonStyle(.textAction)
        .fontWeight(.semibold)
        .foregroundStyle(Tokens.V1.Color.warn)
        .help(LiveLanguageSwitchCopy.help(switchesThisMeeting: switchesThisMeeting))
        .runtimeAccessibilityIdentifier("low-recognition.switch")

      Button("本场忽略", action: onIgnore)
        .buttonStyle(.textAction)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .runtimeAccessibilityIdentifier("low-recognition.ignore")
    }
    .runtimeAccessibilityIdentifier("banner.low-recognition")
  }
}

/// 两条横幅共用的切换文案。按钮必须说清是「本场」还是「下一场」:
/// 旧文案「改选中文」不带时间,用户自然以为本场已切(issue #211)。
enum LiveLanguageSwitchCopy {
  static func actionTitle(to language: MeetingLanguage, switchesThisMeeting: Bool) -> String {
    let name = language == .english ? "英语" : "中文"
    return switchesThisMeeting ? "本场改用\(name)" : "下一场改为\(name)"
  }

  static func help(switchesThisMeeting: Bool) -> String {
    switchesThisMeeting
      ? "从现在起本场速记改用这个语言识别；已经出来的转写不变"
      : "当前速记引擎不支持会中切换：更新语言选择，下一场开录生效"
  }
}
