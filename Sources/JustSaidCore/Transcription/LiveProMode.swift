import Foundation

// Pro 模式在开会与散会两头的约定(PR-08,owner 2026-10-17 定稿,见 docs/design-system/README.md「Pro 模式」):
// - 开会不等、不检查:点开始时按 Pro 开关、本场实际的会中引擎与 Pro 模型的本机状态定一次 `LiveProPlan`。
// - 只对 Qwen3-ASR 生效(「自动」会解析到它);需要修复时用标准识别并在开录时提示一句,还没下载完时用标准识别、不提示。
// - 会中只在 GPU 出错(含开录后没能装好)时改用标准识别,提示「已改用标准识别继续」;同一场最多一句。
// - 散会时把本场实际用的引擎写进 meeting.json(`LiveTranscriberRecord`),「处理信息」只读这份记录。

/// 本场会中速记要不要走 Pro。只有 `.pro` 把 1.7B 交给引擎,其余都是标准识别。
public enum LiveProPlan: Equatable, Sendable {
  /// Pro 关,或本场引擎不是 Qwen3-ASR:与没有 Pro 时完全相同。
  case off
  /// 走 Pro:1.7B 由引擎在开录时于后台加载,装好之前由 0.6B 出字。
  case pro(modelURL: URL)
  /// Pro 开、引擎是 Qwen3-ASR,但 Pro 模型缺失、需要更新、校验未通过或清单不可用:本场用标准识别,
  /// 开录时提示一句。
  case standardNeedsRepair
  /// Pro 开、引擎是 Qwen3-ASR,Pro 模型正在下载、删除或核对中:本场用标准识别,不提示。
  case standardNotReady

  /// 写进诊断账本的名字(不含路径)。
  public var diagnosticName: String {
    switch self {
    case .off: return "off"
    case .pro: return "pro"
    case .standardNeedsRepair: return "standardNeedsRepair"
    case .standardNotReady: return "standardNotReady"
    }
  }

  /// `liveProviderID` 是本场绑定里会中速记的 providerID(「自动」已解析);`proStatus` 是 Pro 能力的本机状态,
  /// 清单里没有这项能力时为 nil;`proModelBusy` 为真表示 Pro 模型正在下载、修复或删除。
  public static func resolve(
    proModeEnabled: Bool,
    liveProviderID: String?,
    proStatus: LocalModelAssetStatus?,
    proModelBusy: Bool,
    proModelURL: URL?
  ) -> LiveProPlan {
    guard proModeEnabled, liveProviderID == LocalModelKnownIDs.qwenProvider else {
      return .off
    }
    if proModelBusy {
      return .standardNotReady
    }
    guard let proStatus, let proModelURL else {
      return .standardNeedsRepair
    }
    switch proStatus {
    case .ready:
      return .pro(modelURL: proModelURL)
    case .checking:
      return .standardNotReady
    case .missing, .updateRequired, .damaged, .configurationFailed:
      return .standardNeedsRepair
    }
  }
}

/// 会中 Pro 相关的那一句中性提示(界面在 PR-10 画,文案以设计系统 README 为准)。同一场最多一句,散会消失。
public enum LiveEngineNotice: Equatable, Sendable {
  /// 开录时:「本场使用标准识别：Pro 模型需要修复」。
  case standardNeedsRepair
  /// 会中改用标准识别时:「已改用标准识别继续」。
  case fellBackToStandard
}

/// 本场会中速记实际用了什么,散会时写进 meeting.json 的 `liveTranscriber`。不复用用量记录
/// (那会算进用量与费用)。只记事实,「处理信息」里的显示名由 `displayName` 推出。
public struct LiveTranscriberRecord: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Sendable {
    /// Qwen3-ASR 走 Pro(1.7B 主解,0.6B 热备)。
    case pro
    /// Qwen3-ASR 标准识别(0.6B)。
    case standard
    /// 其他会中引擎(SenseVoice、Apple 等)。
    case other
  }

  /// 本场绑定的会中速记 providerID。
  public let providerID: String
  /// Qwen3-ASR:清单资产 ID(`qwen3-asr-1.7b-q8-gguf` / `qwen3-asr-0.6b-int8`);其他引擎:该渠道的显示名。
  public let model: String
  public let mode: Mode
  /// Pro 场会中改用了标准识别(GPU 出错,或开录后没能装好)。
  public let fellBack: Bool

  public init(providerID: String, model: String, mode: Mode, fellBack: Bool) {
    self.providerID = providerID
    self.model = model
    self.mode = mode
    self.fellBack = fellBack
  }

  /// Qwen3-ASR 引擎按它停止后的报告记;其他引擎记渠道显示名(找不到时记 providerID)。
  /// 开着 Pro 但散会前 1.7B 还没接手、也没改用的一场,字全是 0.6B 出的,如实记标准。
  public init(
    providerID: String,
    report: TranscriberLiveEngineReport?,
    registry: ProviderRegistry = ProviderRegistry()
  ) {
    if let report {
      let pro = report.modelAssetID == Qwen3ASRTranscriberEngine.proModelAssetID
      if pro, !report.fellBack, report.proReadyAfterSeconds == nil {
        self.init(
          providerID: providerID, model: Qwen3ASRTranscriberEngine.standardModelAssetID,
          mode: .standard, fellBack: false)
        return
      }
      self.init(
        providerID: providerID, model: report.modelAssetID, mode: pro ? .pro : .standard,
        fellBack: pro && report.fellBack)
    } else {
      let name = registry.provider(id: providerID, for: .liveTranscriber)?.displayName
      self.init(providerID: providerID, model: name ?? providerID, mode: .other, fellBack: false)
    }
  }

  /// 「处理信息」里「会中速记」那一行。1.7B 接手过就写 Pro(开录头几秒由 0.6B 出字也一样)。
  public var displayName: String {
    switch mode {
    case .pro:
      return fellBack ? "\(Self.standardName)（标准）· 会中改用" : "Qwen3-ASR 1.7B Q8_0（Pro）"
    case .standard:
      return "\(Self.standardName)（标准）"
    case .other:
      return model
    }
  }

  private static let standardName = "Qwen3-ASR 0.6B INT8"
}
