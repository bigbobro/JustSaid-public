import Foundation
import JustSaidCore

/// 会中悬浮内容的呈现桥接:摘要、麦克风暂停、点名未确认事件与动作回调。
/// 由应用级 `MeetingPresenceController` 同步,主窗关闭或重建都不影响它;
/// 视图只读这里,不持有检测、确认或声音状态。
@MainActor
public final class CompactOverlayViewModel: ObservableObject {
  /// 当前内容载体:Dock 展开的内容与悬浮小窗共用同一视图,只差「保持展开 / 收起到侧边」入口。
  enum Carrier: Equatable {
    case dock
    case window
  }

  @Published var lines: [SummaryNowLine] = []
  @Published var topicTitle: String?
  @Published var startedAt: Date?
  @Published var coveredUntilLabel = "--:--"
  /// 麦克风暂停态(08-14 mic-only-pause):由应用级呈现控制器从
  /// `RecordingSession.isMicrophonePaused` 同步,暂停小条的显隐收在视图内部。
  /// public 是因为 UIHierarchy 探针在模块外直接构造暂停态(与 update(from:) 同理)。
  @Published public var isMicrophonePaused = false
  /// 正在展示的未确认点名;「知道了」绑定渲染时的事件 id。
  @Published public var pendingEvent: NameAlertEvent?
  @Published var carrier: Carrier = .window
  /// 只在鼠标按住、面板几何冻结时允许摘要与非交互头部受压收缩。
  @Published var isContentGeometryHeld = false

  var onMark: () -> Void = {}
  var onReturnToMain: () -> Void = {}
  /// ×:只把显示模式设为关闭,不暂停提醒、不清未确认事件。
  var onClose: () -> Void = {}
  var onResumeMicrophone: () -> Void = {}
  var onAcknowledge: (NameAlertEvent.ID) -> Void = { _ in }
  /// Dock 内容里的「保持展开」= 切到小窗;小窗里的「收起到侧边」= 切回 Dock。
  var onKeepOpen: () -> Void = {}
  var onCollapseToSide: () -> Void = {}
  /// 热键标记成功且悬浮窗在场时的短暂回执;不抢焦点。
  @Published var markConfirmation: String?
  /// 闲聊/暂停全局热键的开/关回执;显示于顶部中性带,沿用面板高度过渡。
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

  /// 总结 feed 的任何发布都会走到这里;内容没变不重新发布,避免悬浮面板无谓重排。
  public func update(from state: SummaryNowState) {
    let nextLines = Array(state.lines.suffix(2))
    if topicTitle != state.context?.topicTitle { topicTitle = state.context?.topicTitle }
    if lines != nextLines {
      lines = nextLines
    }
    if coveredUntilLabel != state.coveredUntilLabel {
      coveredUntilLabel = state.coveredUntilLabel
    }
  }
}
