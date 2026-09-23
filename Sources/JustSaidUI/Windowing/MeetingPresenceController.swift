import AppKit
import Combine
import JustSaidCore

/// 点名提示音。只由新事件信号驱动一次;暂停提醒、结束或失败时停止。
@MainActor
protocol NameAlertSoundPlaying: AnyObject {
  func play()
  func stop()
}

@MainActor
final class SystemNameAlertSound: NameAlertSoundPlaying {
  private var sound: NSSound?

  func play() {
    sound?.stop()
    let next = NSSound(named: "Glass")
    next?.play()
    sound = next
  }

  func stop() {
    sound?.stop()
    sound = nil
  }
}

/// 会中呈现的应用级唯一宿主(生命周期高于主窗与会议库视图)。
///
/// - 点名:唯一的 `NameAlertSession` 订阅同一个 `RecordingSession` 的解码观察;
///   pending、确认、暂停提醒语义全在会话里,这里只转成呈现与一次性提示音。
/// - 摘要桥接:会议目录 attach、进入录制时 start+ingest、转写更新 ingest、`now` 同步小窗、
///   麦克风暂停同步——从主窗视图迁来,主窗关闭或重建时不中断、也不产生第二份。
/// - 呈现:按 `MeetingPresencePolicy` 选一个悬浮载体,由 `CompactPanelController` 显示。
@MainActor
public final class MeetingPresenceController: ObservableObject {
  /// 主窗失焦后多久才算后台(沿用小窗既有 1.5 秒防抖,短暂切窗不弹)。
  let backgroundDelay: Duration

  public let preferences: NameAlertPreferencesStore
  public let nameAlerts: NameAlertSession
  @Published public private(set) var surface: MeetingPresenceSurface = .none
  @Published public private(set) var isMainForeground = true

  let overlayModel: CompactOverlayViewModel
  let panels: CompactPanelController
  private(set) weak var recordingSession: RecordingSession?
  private weak var mainWindow: NSWindow?
  private let sound: NameAlertSoundPlaying
  private var cancellables: Set<AnyCancellable> = []
  private var windowTokens: [NSObjectProtocol] = []
  private var backgroundTask: Task<Void, Never>?
  private var isRecording = false
  private var hasPending = false
  private var displayMode: NameAlertPreferences.DisplayMode
  private var reminderStyle: NameAlertPreferences.ReminderStyle

  struct Actions {
    var mark: () -> Void
    var returnToMain: () -> Void
  }

  init<Feed: SummaryFeed>(
    recordingSession: RecordingSession,
    summaryFeed: Feed,
    preferences: NameAlertPreferencesStore,
    defaults: UserDefaults = .standard,
    sound: NameAlertSoundPlaying? = nil,
    backgroundDelay: Duration = .seconds(1.5),
    actions: Actions
  ) {
    self.backgroundDelay = backgroundDelay
    self.recordingSession = recordingSession
    self.preferences = preferences
    self.sound = sound ?? SystemNameAlertSound()
    let overlayModel = CompactOverlayViewModel()
    self.overlayModel = overlayModel
    panels = CompactPanelController(overlayModel: overlayModel, defaults: defaults)
    nameAlerts = NameAlertSession(preferences: preferences)
    displayMode = preferences.preferences.displayMode
    reminderStyle = preferences.preferences.reminderStyle
    isRecording = recordingSession.phase == .recording

    wireOverlayActions(actions: actions)
    wireSummaryBridge(recordingSession: recordingSession, summaryFeed: summaryFeed)
    wireNameAlerts(recordingSession: recordingSession)
    panels.preferredScreen = { [weak self] in self?.mainWindow?.screen ?? NSScreen.main }
    recompute()
  }

  isolated deinit {
    windowTokens.forEach(NotificationCenter.default.removeObserver)
  }

  /// 被替换(验证程序换录制会话)时收掉订阅与面板。
  func invalidate() {
    cancellables.removeAll()
    stopObservingWindow()
    backgroundTask?.cancel()
    sound.stop()
    panels.apply(surface: .none, isPending: false, isRecording: false)
  }

  // MARK: - 主窗前后台

  /// 主窗解析或重建时登记;窗口关闭即视为后台,重开的新窗获得焦点后回到前台。
  func observe(mainWindow window: NSWindow?) {
    guard mainWindow !== window else { return }
    stopObservingWindow()
    mainWindow = window
    guard let window else { return }
    if window.isKeyWindow {
      setForeground(true)
    }
    let center = NotificationCenter.default
    windowTokens = [
      center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleBackground() }
      },
      center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.setForeground(true) }
      },
      center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          // 同一个 NSWindow 之后可能被重新前置:清掉身份,下次登记时重新观察。
          self?.stopObservingWindow()
          self?.mainWindow = nil
          self?.setForeground(false)
        }
      },
    ]
  }

  private func stopObservingWindow() {
    windowTokens.forEach(NotificationCenter.default.removeObserver)
    windowTokens.removeAll()
  }

  private func scheduleBackground() {
    backgroundTask?.cancel()
    backgroundTask = Task { [weak self] in
      guard let delay = self?.backgroundDelay else { return }
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.setForeground(false)
    }
  }

  private func setForeground(_ foreground: Bool) {
    backgroundTask?.cancel()
    backgroundTask = nil
    guard isMainForeground != foreground else { return }
    isMainForeground = foreground
    recompute()
  }

  // MARK: - 接线

  private func wireOverlayActions(actions: Actions) {
    overlayModel.onMark = actions.mark
    overlayModel.onReturnToMain = actions.returnToMain
    overlayModel.onResumeMicrophone = { [weak self] in
      self?.recordingSession?.resumeMicrophone()
    }
    overlayModel.onAcknowledge = { [weak self] eventID in
      self?.nameAlerts.acknowledge(eventID: eventID)
    }
    overlayModel.onClose = { [weak self] in
      self?.preferences.setDisplayMode(.off)
    }
    overlayModel.onKeepOpen = { [weak self] in
      self?.preferences.setDisplayMode(.window)
    }
    overlayModel.onCollapseToSide = { [weak self] in
      self?.preferences.setDisplayMode(.dock)
    }
  }

  private func wireSummaryBridge<Feed: SummaryFeed>(
    recordingSession: RecordingSession,
    summaryFeed: Feed
  ) {
    if let directory = recordingSession.currentMeetingDirectory {
      summaryFeed.attach(meetingDirectory: directory)
    }
    overlayModel.update(from: summaryFeed.now)
    overlayModel.isMicrophonePaused = recordingSession.isMicrophonePaused
    recordingSession.$startedAt
      .removeDuplicates()
      .sink { [weak self] in self?.overlayModel.startedAt = $0 }
      .store(in: &cancellables)

    recordingSession.$currentMeetingDirectory
      .dropFirst()
      .sink { [weak summaryFeed] directory in
        summaryFeed?.attach(meetingDirectory: directory)
      }
      .store(in: &cancellables)
    recordingSession.$phase
      .dropFirst()
      .removeDuplicates()
      .sink { [weak summaryFeed, weak recordingSession] phase in
        guard phase == .recording, let summaryFeed, let recordingSession else { return }
        summaryFeed.start()
        summaryFeed.ingest(recordingSession.liveSegments)
      }
      .store(in: &cancellables)
    // 结果任务一次追加会连发 removeAll/append/sort 几次发布;合并到本轮末尾只 ingest 一次,
    // 与原先主窗 onChange 每次视图更新一次的节奏一致(ingest 会读 meeting.json)。
    recordingSession.$liveSegments
      .dropFirst()
      .debounce(for: .zero, scheduler: DispatchQueue.main)
      .sink { [weak summaryFeed] segments in
        summaryFeed?.ingest(segments)
      }
      .store(in: &cancellables)
    summaryFeed.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak summaryFeed] _ in
        guard let self, let summaryFeed else { return }
        self.overlayModel.update(from: summaryFeed.now)
      }
      .store(in: &cancellables)
    recordingSession.$isMicrophonePaused
      .removeDuplicates()
      .sink { [weak self] paused in
        self?.overlayModel.isMicrophonePaused = paused
      }
      .store(in: &cancellables)
  }

  private func wireNameAlerts(recordingSession: RecordingSession) {
    nameAlerts.attach(to: recordingSession)

    recordingSession.$phase
      .removeDuplicates()
      .sink { [weak self] phase in
        guard let self else { return }
        let recording = phase == .recording
        if recording, !self.isRecording {
          self.panels.resetForNewMeeting()
        }
        if !recording {
          self.sound.stop()
        }
        self.isRecording = recording
        self.recompute()
      }
      .store(in: &cancellables)
    nameAlerts.$pendingEvent
      .sink { [weak self] event in
        guard let self else { return }
        if self.overlayModel.pendingEvent != event {
          self.overlayModel.pendingEvent = event
        }
        self.hasPending = event != nil
        self.recompute()
      }
      .store(in: &cancellables)
    nameAlerts.newEvents
      .sink { [weak self] _ in
        guard let self, self.preferences.preferences.soundEnabled else { return }
        self.sound.play()
      }
      .store(in: &cancellables)
    preferences.$preferences
      .sink { [weak self] value in
        guard let self else { return }
        if !value.remindersEnabled || !value.soundEnabled {
          self.sound.stop()
        }
        self.displayMode = value.displayMode
        self.reminderStyle = value.reminderStyle
        self.recompute()
      }
      .store(in: &cancellables)
  }

  private func recompute() {
    let next = MeetingPresencePolicy.surface(
      isRecording: isRecording,
      isMainForeground: isMainForeground,
      hasPending: hasPending,
      displayMode: displayMode,
      reminderStyle: reminderStyle
    )
    if surface != next {
      surface = next
    }
    panels.apply(surface: next, isPending: hasPending, isRecording: isRecording)
  }
}
