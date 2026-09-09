import JustSaidCore

/// 会后加工流水线的统一投影(2026-08-20 批3-B):三步(精转→纪要→完备度)+ 下一步动作。
///
/// **不是第三套事实源**:精/纪四态仍由 `MeetingLibraryModel.transcriptionProgress/minutesProgress`
/// 派生(协调者实时快照压过磁盘事实、英文附加产物只贡献进行中不贡献失败——08-07 契约),
/// 完备度直接取 `effectiveCompleteness`(08-21 ack 单:机器 report + 用户放行的合成裁决,
/// 「完备度缺」lane 与徽章计数因此把已确认场次移出缺档)。本类型只做纯聚合,验证矩阵直接驱动。
///
/// `nextAction` 决定详情头主按钮槽由谁坐(批3-D):它只排序既有动作,不新造动作、
/// 不代替思考(动作的弹窗/确认/禁用原因全部沿用既有链路)。
public struct MeetingPipelineState: Equatable {
  public enum NextAction: String, Equatable {
    /// 精转失败或还没有权威转写(含导入待精转):下一步是(重新)精转。
    case retryTranscription
    /// 有权威转写、还没有正式纪要:下一步是生成纪要。
    case generateMinutes
    /// 纪要已在(或纪要失败可重生成):主动作仍是「生成纪要」语义(重生成/重试同一入口)。
    case regenerateMinutes
    /// 在跑或无可用音频:不推任何主动作(按钮禁用态由既有链路决定)。
    case none
  }

  public let transcription: MeetingArtifactProgress
  public let minutes: MeetingArtifactProgress
  public let completeness: EffectiveCompletenessVerdict?

  /// 三步之外的输入:无可用音频(两路都空)的会议连「重新精转」都无从谈起。
  public let hasUsableAudioChannel: Bool
  /// 盘上是否已有正式纪要(欠账 lane 需要它区分「失败但盘上还有旧纪要」与「真欠着」)。
  public let hasFormalMinutes: Bool

  public init(
    transcription: MeetingArtifactProgress,
    minutes: MeetingArtifactProgress,
    completeness: EffectiveCompletenessVerdict?,
    hasUsableAudioChannel: Bool,
    hasFormalMinutes: Bool = false
  ) {
    self.transcription = transcription
    self.minutes = minutes
    self.completeness = completeness
    self.hasUsableAudioChannel = hasUsableAudioChannel
    self.hasFormalMinutes = hasFormalMinutes
  }

  public var nextAction: NextAction {
    if transcription == .inProgress || minutes == .inProgress {
      return .none
    }
    switch transcription {
    case .failed, .notStarted:
      return hasUsableAudioChannel ? .retryTranscription : .none
    case .inProgress:
      return .none
    case .completed:
      switch minutes {
      case .notStarted:
        return .generateMinutes
      case .failed, .completed:
        return .regenerateMinutes
      case .inProgress:
        return .none
      }
    }
  }
}

extension MeetingLibraryModel {
  /// 单一入口:行内 compact(精/纪记号+完备度徽章)与详情 expanded(stepper/next-action)
  /// 共用同一份派生,消灭「同一语义多套推导」。
  func pipelineState(for item: MeetingLibraryItem) -> MeetingPipelineState {
    MeetingPipelineState(
      transcription: transcriptionProgress(for: item),
      minutes: minutesProgress(for: item),
      completeness: item.effectiveCompleteness?.verdict,
      hasUsableAudioChannel: item.hasUsableAudioChannel,
      hasFormalMinutes: item.hasFormalMinutes
    )
  }
}
