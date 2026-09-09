import AppKit
import JustSaidCore
import SwiftUI

// 2026-08-21 批0 拆分:自 MainWorkspaceView.swift 按 MARK 边界机械迁出,零行为变更.
extension MainWorkspaceView {

  /// 非打断类系统横幅。两套 chrome 各挂一份、**都无条件实例化**(红线 6)——
  /// 显隐判断全部收在各自组件内部,调用点不加门。
  ///
  /// 驾驶舱里它们排在舞台之下、整理区之上(R9)。闲聊/暂停在控制轨上另有状态点 +
  /// 悬停卡作为**首要**信号(R2),这里的状态条保留为兜底:忘封口 = 后半场不进纪要,
  /// 是会真丢内容的一类,双通道显眼是 08-14 立的规矩,不在本轮撤销。
  @ViewBuilder
  var systemBanners: some View {
    MicrophoneInputRouteBanner(status: recordingSession.microphoneInputStatus)
    legHealthBanner
    // 无条件实例化(红线 6):未封口区间的显隐判断收在 `ChatExclusionBanner` 内部。
    ChatExclusionBanner(openRangeStart: openChatRange?.start) {
      closeChatExclusion()
    }
    // 同款无条件实例化(红线 6):暂停态显隐收在 `MicrophonePauseBanner` 内部。
    // 与「闲聊中」细带可同时激活、上下相邻不合并——暂停=隐私工具(本侧
    // 什么都不记),闲聊=照录但不进纪要,两者定位不同。
    MicrophonePauseBanner(
      isPaused: recordingSession.isMicrophonePaused,
      pausedAt: microphonePausedAt
    ) {
      recordingSession.resumeMicrophone()
    }
    if let exclusionError {
      DegradedBanner(text: exclusionError)
    }
    languageMismatchBanner
    lowRecognitionBanner
    postMeetingBanner
  }

  /// 会后处理进度条：点完「结束会议」之后必须看得见后续在发生什么，以及从哪里看产物。
  /// 2026-07-29 实测反馈「点击结束之后看不到后续的内容了」——原因是会后状态只在
  /// Core 里有字段、界面从不呈现，且没有任何进入本场会议产物的入口。
  ///
  /// **这道 phase 门是承重的,别把横幅挪出去**:`RecordingSession.start()` 会把
  /// `currentMeetingDirectory` 置 nil,`onChange` 因此必然打出一次 `attach(nil)`,
  /// 而 `LiveSummaryFeed.syncPostMeetingState` 的第一道 guard 要求
  /// `meetingPaths?.directory == identity` —— 失配之后这条 feed 对展示门发出的
  /// `.stateChanged` 就失聪,`postMeetingStage` 会**闩在** `.finished` 上没有回头路。
  /// 今天看不见,靠的是两件事叠加:① 本门只在 `.completed`/`.stopping` 开;
  /// ② `phase = .completed` 全仓唯一写点在 `RecordingSession.stop()` 内、且 `stop()`
  /// guard 死 `phase == .recording`——所以门要重开必先经 `.recording`,
  /// 而 `.recording` 必然触发 `summaryFeed.start()` → 把横幅打回 `.none`。
  @ViewBuilder
  private var postMeetingBanner: some View {
    if recordingSession.phase == .completed || recordingSession.phase == .stopping {
      // 单路失败的"部分完成"横幅(08-05 事故):非模态、不打断,如实说明哪路自何时
      // 起缺失、保住了什么;会后进度行照常显示在下方——纪要仍会基于可用一路生成。
      if let partialNotice = recordingSession.partialCaptureNotice {
        HStack(spacing: Tokens.Spacing.xsm) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(partialNotice)
          Spacer()
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
        .runtimeAccessibilityIdentifier("cockpit.partial-capture")
      }
      // 「查看本场会议」打开的是**渲染这条横幅时**捕获的那场会议:点下去那一刻再读
      // `currentMeetingDirectory`,拿到的可能已经是新开的下一场。
      let noticeDirectory =
        summaryFeed.postMeetingDirectory ?? recordingSession.currentMeetingDirectory
      // 无条件实例化(红线 6):显隐判断全部收在 `PostMeetingStatusBanner` 内部。
      // `.none` 时整条结构不存在——不再退化成一句永不消失的「本场会议已保存」。
      // 会议库详情**不再有**对应横幅(08-10 改判:状态跟着会议行走)。
      PostMeetingStatusBanner(
        stage: summaryFeed.postMeetingStage,
        actionTitle: "查看本场会议",
        onAction: {
          // 先收提示再导航:成功提示的展示门也有手动触发这一支。
          summaryFeed.dismissPostMeetingNotice()
          appCoordinator.openLibrary(focus: noticeDirectory)
        }
      )
    }
  }

  /// 会中路级健康横幅(08-05 自愈单):任一采集路 stalled/recovered/givenUp 时出现,
  /// 非模态、不打断录音;文案与结束后的 partial 结算横幅口径一致(mm:ss 起点、
  /// 保住了什么)。与「30 秒纯零静音」细带是两套信号(那边帧在流但纯零,这边帧停摆),
  /// 触发条件天然互斥,不合并、不叠加。恢复后 Core 侧短暂显示 recovered 再转 healthy,
  /// 横幅随之消失。
  @ViewBuilder
  private var legHealthBanner: some View {
    if recordingSession.phase == .recording,
      let startedAt = recordingSession.startedAt
    {
      let notices = CaptureLeg.allCases.compactMap { leg -> String? in
        guard let health = recordingSession.legHealth[leg] else { return nil }
        return RecordingSession.makeLegHealthNotice(
          leg: leg,
          health: health,
          startedAt: startedAt
        )
      }
      if !notices.isEmpty {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
          ForEach(notices, id: \.self) { notice in
            HStack(spacing: Tokens.Spacing.xsm) {
              Image(systemName: "exclamationmark.triangle.fill")
              Text(notice)
              Spacer()
            }
          }
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
        .runtimeAccessibilityIdentifier("cockpit.leg-health")
      }
    }
  }

  /// 语言错配提示(P2-b):开录约 30 秒后速记检测语言与所选不符时出现。
  /// 只提示不自动改;「改选」记为手选(1883e15 的预填此后不再干预)、下一场生效,
  /// 「本场忽略」当场收起。两种选择本场都不再出现。
  @ViewBuilder
  private var languageMismatchBanner: some View {
    if recordingSession.phase == .recording, let detected = languageMismatch {
      LanguageMismatchBanner(
        selected: language,
        detected: detected,
        onSwitch: {
          hasManuallyPickedLanguage = true
          language = detected
          languageMismatch = nil
          isLanguageMismatchDismissed = true
        },
        onIgnore: {
          languageMismatch = nil
          isLanguageMismatchDismissed = true
        }
      )
    }
  }

  /// 低产出提示:错配横幅的盲区补丁(音译污染场景)。错配横幅优先,两者不叠加。
  @ViewBuilder
  private var lowRecognitionBanner: some View {
    if recordingSession.phase == .recording, isShowingLowRecognition, languageMismatch == nil {
      LowRecognitionBanner(
        selected: language,
        onSwitch: {
          hasManuallyPickedLanguage = true
          language = language == .english ? .chinese : .english
          isShowingLowRecognition = false
          isLowRecognitionDismissed = true
        },
        onIgnore: {
          isShowingLowRecognition = false
          isLowRecognitionDismissed = true
        }
      )
    }
  }

  /// 录音异常是唯一允许打断用户的情况（ui-spec §6）：标题栏红色常驻条，
  /// 文案直说哪一路停了、哪一路仍在录；配合 `issueBinding` 的一次性系统提示对话框。
  @ViewBuilder
  var recordingFailureBanner: some View {
    if recordingSession.phase == .failed, let issue = recordingSession.issue {
      HStack(alignment: .top, spacing: Tokens.Spacing.xsm) {
        Image(systemName: "exclamationmark.triangle.fill")
        VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
          Text(issue.title).fontWeight(.bold)
          Text(issue.message).font(.system(size: Tokens.FontSize.ui))
        }
        Spacer()
      }
      .font(.system(size: Tokens.FontSize.bodyMinimum))
      .foregroundStyle(Tokens.Color.onAccent)
      .padding(.horizontal, Tokens.Spacing.md)
      .padding(.vertical, Tokens.Spacing.xs)
      .background(Tokens.Color.rec)
      .accessibilityElement(children: .combine)
    } else if recordingSession.phase == .recording, let issue = recordingSession.issue {
      DegradedBanner(text: "速记引擎异常 · \(issue.message)")
    }
  }
}

/// Visibility belongs to this wrapper, so both cockpit and library render the same route facts.
public struct MicrophoneInputRouteBanner: View {
  public let status: MicrophoneInputStatus

  public init(status: MicrophoneInputStatus) { self.status = status }

  public var body: some View {
    if let notice = status.notice {
      DegradedBanner(text: notice)
        .runtimeAccessibilityIdentifier("microphone.input.notice")
    }
  }
}
