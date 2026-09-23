import JustSaidCore

/// 准备页可见性判定。抽成非泛型纯函数是为了能被探针逐格断言:
/// 「用户主动进库后不再被准备页顶回来」这条靠 headless 渲染探针点不到,
/// 而它正是"缺模型时整个 App 只剩一个下载页"的那条 bug。
public enum ModelPreparationVisibility {
  public static func shouldShow(
    gate: LocalModelStartGateDecision,
    isRecordingOrStarting: Bool,
    sessionActive: Bool,
    dismissed: Bool
  ) -> Bool {
    if isRecordingOrStarting { return false }
    if sessionActive { return true }
    if dismissed { return false }
    switch gate {
    case .ready, .systemManaged:
      return false
    case .waitForLocalCheck, .showPreparation, .configurationFailed:
      return true
    }
  }
}
