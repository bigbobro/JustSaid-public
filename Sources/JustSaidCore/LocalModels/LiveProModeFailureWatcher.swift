import Combine
import Foundation

/// Pro 模型下载失败就把 Pro 模式关掉(PR-10,设计系统 README「Pro 模式」:除了你自己关掉,
/// 只有取消下载、下载失败和删除 Pro 模型会把它关掉)。
///
/// 不放在设置那一行里:离开设置页不打断下载,失败时那一行可能已经不在了;开关还开着的话,
/// 下一场会被当成「模型需要修复」并在开录时提示一句。所以由 App 启动时装一份、跟进程同寿。
/// 取消下载在那一行的「取消」里关,删除在「管理…」的确认里关,都不经过这里。
@MainActor
public final class LiveProModeFailureWatcher {
  private var subscription: AnyCancellable?

  public init(modelAssets: LocalModelAssetManager, settings: ProviderSettingsStore) {
    subscription = modelAssets.$preparation.sink { [weak settings] state in
      guard case .failed(let capabilityID, _, _, _) = state,
        capabilityID == LocalModelKnownIDs.qwenLivePro,
        let settings, settings.liveProModeEnabled
      else { return }
      settings.setLiveProMode(false)
    }
  }
}
