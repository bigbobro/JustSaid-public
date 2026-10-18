import Foundation
import JustSaidCore

/// 设置 › 模型与服务 › 会中速记里「Pro 模式」一行此刻长什么样、点开关做什么(PR-10)。
///
/// 纯函数:六态与文案以设计系统 README「Pro 模式」那张表为准。开关记的是你的选择
/// (`ProviderSettingsStore.liveProModeEnabled`);隐藏、记录中、模型需要修复都不改它,
/// 只有你自己关、取消下载、下载失败与删除 Pro 模型会把它关掉。
public struct ProModeSwitchState: Equatable, Sendable {
  public enum Phase: String, Equatable, Sendable {
    case off
    case downloading
    case failed
    case on
    case needsRepair
    case recording
  }

  /// 点开关时要做的事。
  public enum ToggleAction: Equatable, Sendable {
    /// 打开,模型已在(或需要修复,不下载)。
    case enable
    /// 打开并开始下载 Pro 模型。
    case enableAndDownload
    /// 打开,接上「管理…」里已经在跑的那次下载,不重下。
    case enableJoiningDownload
    /// 关掉,模型保留。
    case disable
  }

  /// 本行关心的 Pro 模型作业(由 `LocalModelAssetManager.preparation` 投影)。
  public enum Job: Equatable, Sendable {
    case none
    case downloading(fraction: Double?)
    case failed(message: String)
    /// 别的模型正在下载(「管理…」里起的 SenseVoice 等)。同一时间只下载一项,Pro 要下载得等它完。
    case otherDownloading
  }

  public struct Inputs: Equatable, Sendable {
    public var intent: Bool
    /// Pro 能力的本机状态;清单里没有这项能力或还没核对完为 nil。
    public var proStatus: LocalModelAssetStatus?
    public var job: Job
    /// 有别的模型作业在跑(另一项下载、删除,或取消后旧作业还没停下)。
    public var otherJobRunning: Bool
    /// 开始中、记录中、结束中。
    public var isRecording: Bool
    /// 本机物理内存,按 1024³ 四舍五入取整。
    public var memoryGB: Int

    public init(
      intent: Bool,
      proStatus: LocalModelAssetStatus?,
      job: Job = .none,
      otherJobRunning: Bool = false,
      isRecording: Bool = false,
      memoryGB: Int
    ) {
      self.intent = intent
      self.proStatus = proStatus
      self.job = job
      self.otherJobRunning = otherJobRunning
      self.isRecording = isRecording
      self.memoryGB = memoryGB
    }
  }

  public let phase: Phase
  public let isOn: Bool
  public let isEnabled: Bool
  /// 标签下那行小字。
  public let labelDetail: String
  /// 开关左侧安静的「取消」。
  public let showsCancel: Bool
  /// 行下通栏细进度条;`progress` 为 nil 时画不定进度。
  public let showsProgress: Bool
  public let progress: Double?
  /// 开关左侧 `color-warn` 小字「模型需要修复」。
  public let showsNeedsRepair: Bool
  /// 行下警示说明(下载失败的原因)。
  public let failureNote: String?
  /// 开关可点时点下去做什么;不可点为 nil。
  public let toggleAction: ToggleAction?

  public static let enabledDetail = "已开启"
  public static let downloadingDetail = "正在准备 Pro 模式"
  public static let recordingDetail = "记录中不能更改"
  public static let needsRepairText = "模型需要修复"
  /// 开关因外部状态禁用时,小字写原因(设计系统 README「开关」)。
  public static let checkingDetail = "正在检查本机模型"
  public static let otherDownloadDetail = "其他模型下载完成后可开启"

  public static func memoryDetail(memoryGB: Int) -> String {
    "建议 24 GB 内存以上开启 · 这台 Mac \(memoryGB) GB"
  }

  /// 物理内存字节数 → 整 GB,按 1024³ 四舍五入(与 Apple 标称一致)。
  public static func memoryGB(physicalMemory: UInt64) -> Int {
    Int((Double(physicalMemory) / 1_073_741_824).rounded())
  }

  /// 把模型管理器的作业状态投影成本行关心的那一份;别的能力的作业不算。
  public static func job(
    from preparation: LocalModelPreparationState, proCapabilityID: String
  ) -> Job {
    switch preparation {
    case .running(let capabilityID, let phase) where capabilityID == proCapabilityID:
      if case .downloading(_, let received, let total) = phase, let total, total > 0 {
        return .downloading(fraction: min(1, Double(received) / Double(total)))
      }
      return .downloading(fraction: nil)
    case .running:
      return .otherDownloading
    case .failed(let capabilityID, _, let message, _) where capabilityID == proCapabilityID:
      return .failed(message: message)
    default:
      return .none
    }
  }

  public init(_ inputs: Inputs) {
    let memory = Self.memoryDetail(memoryGB: inputs.memoryGB)
    var cancel = false
    var progressBar = false
    var fraction: Double?
    var repair = false
    var note: String?
    var action: ToggleAction?

    if inputs.isRecording {
      // 记录中禁用、保持原值;下载没完成也照这一态显示,不给「取消」。
      phase = .recording
      isOn = inputs.intent
      labelDetail = Self.recordingDetail
    } else if case .downloading(let value) = inputs.job {
      phase = .downloading
      isOn = inputs.intent
      labelDetail = Self.downloadingDetail
      cancel = true
      progressBar = true
      fraction = value
      // 从「管理…」起的下载开关保持关、仍可点:点开就接上这次下载。
      action = inputs.intent ? nil : .enableJoiningDownload
    } else if inputs.intent {
      isOn = true
      labelDetail = Self.enabledDetail
      // 关掉不动模型,别的作业在跑也可以关。
      action = .disable
      switch inputs.proStatus {
      case .missing, .updateRequired, .damaged, .configurationFailed:
        phase = .needsRepair
        repair = true
      case .ready, .checking, nil:
        phase = .on
      }
    } else {
      isOn = false
      if case .failed(let message) = inputs.job {
        phase = .failed
        note = message
      } else {
        phase = .off
      }
      switch inputs.proStatus {
      case .ready, .updateRequired, .damaged, .configurationFailed:
        // 模型已在(需要修复也不在这里下载),别的作业在跑也照样可以开。
        labelDetail = memory
        action = .enable
      case .missing where inputs.job == .otherDownloading:
        // 同一时间只下载一项:等「管理…」里那一项下完。
        labelDetail = Self.otherDownloadDetail
      case .missing:
        labelDetail = memory
        // 作业槽在收尾(取消后旧作业还没停下、刚删完)的那一瞬不让点,免得两次作业互相覆盖。
        if !inputs.otherJobRunning { action = .enableAndDownload }
      case .checking, nil:
        // 还不知道要不要下载;核对很快,这时先不让点。
        labelDetail = Self.checkingDetail
      }
    }

    isEnabled = action != nil
    showsCancel = cancel
    showsProgress = progressBar
    progress = fraction
    showsNeedsRepair = repair
    failureNote = note
    toggleAction = action
  }
}
