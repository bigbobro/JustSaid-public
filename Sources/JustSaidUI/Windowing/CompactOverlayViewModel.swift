import Foundation
import JustSaidCore

/// 缩略置顶窗的内容桥接：`CompactPanelController` 是非泛型的 AppKit 控制器，
/// 无法直接持有 `any SummaryFeed`（`@ObservedObject` 需要具体类型）。
/// `MainWorkspaceView`（对 `Feed` 泛型）负责把 `feed.now` 同步进这个具体类型。
@MainActor
public final class CompactOverlayViewModel: ObservableObject {
  @Published var lines: [SummaryNowLine] = []
  @Published var coveredUntilLabel = "--:--"
  /// 麦克风暂停态(08-14 mic-only-pause):由 MainWorkspaceView 从
  /// `RecordingSession.isMicrophonePaused` 同步,暂停小条的显隐收在视图内部。
  /// public 是因为 UIHierarchy 探针在模块外直接构造暂停态(与 update(from:) 同理)。
  @Published public var isMicrophonePaused = false

  var onMark: () -> Void = {}
  var onReturnToMain: () -> Void = {}
  var onClose: () -> Void = {}
  /// 一键恢复麦克风,注册模式同 onMark(MainWorkspaceView onAppear 里接
  /// `{ recordingSession.resumeMicrophone() }`)。
  var onResumeMicrophone: () -> Void = {}
  /// 热键标记成功且悬浮窗在场时的短暂回执;不抢焦点。
  @Published var markConfirmation: String?
  /// 闲聊/暂停全局热键的开/关回执;叠在窗顶,不改窗高。
  @Published public var actionConfirmation: String?
  private var markFlashTask: Task<Void, Never>?
  private var actionFlashTask: Task<Void, Never>?

  public init() {}

  func flashMarkConfirmation() {
    markFlashTask?.cancel()
    markConfirmation = "已标记"
    markFlashTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1_200))
      guard !Task.isCancelled else { return }
      markConfirmation = nil
    }
  }

  func flashActionConfirmation(_ text: String) {
    actionFlashTask?.cancel()
    actionConfirmation = text
    actionFlashTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1_200))
      guard !Task.isCancelled else { return }
      actionConfirmation = nil
    }
  }

  public func update(from state: SummaryNowState) {
    lines = Array(state.lines.suffix(2))
    coveredUntilLabel = state.coveredUntilLabel
  }
}
