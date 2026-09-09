import AppKit
import Carbon
import Combine
import os

/// Carbon EventHotKeyID.signature。放在类型外,C 回调不碰 MainActor 隔离的 static。
private let justSaidHotkeySignature: OSType = 0x4A53_4D4B  // 'JSMK'

/// 会中全局热键三行(B6 标记重点,08-21 扩闲聊/暂停麦克风)。
///
/// 走 Carbon `RegisterEventHotKey`:系统认可的全局热键 API,不需要辅助功能 /
/// Input Monitoring 权限。热键回调只把工作抛到主队列,自己立刻返回。
/// 真正动作走 `AppCoordinator` 既有入口(requestMark / requestToggleChat /
/// requestToggleMicrophonePause),与菜单栏、应用内快捷键同一条链路。
@MainActor
final class GlobalHotkeyManager: ObservableObject {
  static let shared = GlobalHotkeyManager()

  @Published private(set) var configurations: [GlobalHotkeyAction: MarkHotkeyChord]
  @Published private(set) var capturingAction: GlobalHotkeyAction?
  @Published private(set) var statusMessages: [GlobalHotkeyAction: String] = [:]
  @Published private(set) var statusErrors: [GlobalHotkeyAction: Bool] = [:]
  @Published private(set) var captureHint: String?

  var isCapturing: Bool { capturingAction != nil }

  private var onPressed: ((GlobalHotkeyAction) -> Void)?
  private var isInstalled = false
  private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
  private var eventHandler: EventHandlerRef?
  private var captureMonitor: Any?

  private init() {
    var loaded: [GlobalHotkeyAction: MarkHotkeyChord] = [:]
    for action in GlobalHotkeyAction.allCases {
      loaded[action] = MarkHotkeyChord.load(
        from: .standard,
        key: action.defaultsKey,
        fallback: action.defaultChord
      )
    }
    configurations = loaded
  }

  func configuration(for action: GlobalHotkeyAction) -> MarkHotkeyChord {
    configurations[action] ?? action.defaultChord
  }

  func statusMessage(for action: GlobalHotkeyAction) -> String? {
    statusMessages[action]
  }

  func statusIsError(for action: GlobalHotkeyAction) -> Bool {
    statusErrors[action] ?? false
  }

  /// 只在正式 App 启动路径调用。UIHierarchy / Preview 不得走这里,
  /// 避免探测进程抢注册真实全局热键。
  func install(onPressed: @escaping (GlobalHotkeyAction) -> Void) {
    self.onPressed = onPressed
    guard !isInstalled else { return }
    isInstalled = true
    installHandlerIfNeeded()
    reregister()
    let enabled = GlobalHotkeyAction.allCases.map {
      "\($0.rawValue)=\(self.configuration(for: $0).isEnabled)"
    }.joined(separator: ",")
    logger.info("global hotkeys installed, \(enabled, privacy: .public)")
  }

  func apply(_ chord: MarkHotkeyChord, for action: GlobalHotkeyAction) {
    cancelCaptureKeepingRegistration(false)
    if chord.isEnabled,
      let other = GlobalHotkeyCollision.collidingAction(
        applying: chord,
        to: action,
        among: configurations
      )
    {
      setStatus(action, "无法使用该组合：与「\(other.title)」冲突。", error: true)
      if isInstalled {
        reregister()
      }
      return
    }
    var next = configurations
    next[action] = chord
    configurations = next
    chord.persist(to: .standard, key: action.defaultsKey)
    guard isInstalled else {
      setStatus(action, nil, error: false)
      return
    }
    reregister()
  }

  func restoreDefault(_ action: GlobalHotkeyAction) {
    apply(action.defaultChord, for: action)
  }

  func disable(_ action: GlobalHotkeyAction) {
    let current = configuration(for: action)
    apply(
      MarkHotkeyChord(
        isEnabled: false,
        keyCode: current.keyCode,
        carbonModifiers: current.carbonModifiers
      ),
      for: action
    )
  }

  func beginCapture(_ action: GlobalHotkeyAction) {
    if capturingAction != nil {
      cancelCaptureKeepingRegistration(false)
    }
    capturingAction = action
    captureHint = nil
    unregisterAllHotKeys()
    captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      Task { @MainActor in
        self?.handleCaptureKey(event)
      }
      return nil
    }
  }

  func cancelCapture() {
    cancelCaptureKeepingRegistration(true)
  }

  // MARK: - Capture

  private func cancelCaptureKeepingRegistration(_ shouldReregister: Bool) {
    guard capturingAction != nil || captureMonitor != nil else { return }
    capturingAction = nil
    captureHint = nil
    if let captureMonitor {
      NSEvent.removeMonitor(captureMonitor)
    }
    captureMonitor = nil
    if shouldReregister, isInstalled {
      reregister()
    }
  }

  private func handleCaptureKey(_ event: NSEvent) {
    guard let action = capturingAction else { return }
    if event.keyCode == UInt16(kVK_Escape) {
      cancelCapture()
      return
    }
    if Self.isModifierKeyCode(event.keyCode) {
      return
    }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
    else {
      captureHint = "请带上 ⌘ / ⌥ / ⌃ 至少一个修饰键"
      return
    }
    let chord = MarkHotkeyChord(
      isEnabled: true,
      keyCode: UInt32(event.keyCode),
      carbonModifiers: Self.carbonModifiers(from: flags)
    )
    if let other = GlobalHotkeyCollision.collidingAction(
      applying: chord,
      to: action,
      among: configurations
    ) {
      captureHint = "与「\(other.title)」冲突，请换一组"
      return
    }
    apply(chord, for: action)
  }

  // MARK: - Registration

  private func reregister() {
    unregisterAllHotKeys()
    for action in GlobalHotkeyAction.allCases {
      let chord = configuration(for: action)
      guard chord.isEnabled else {
        setStatus(
          action,
          "全局热键已停用。主窗前台仍可用 \(action.defaultLabel)。",
          error: false
        )
        continue
      }
      let status = register(action, chord)
      if status == noErr {
        var message = "已生效：\(chord.displayLabel)"
        if let warning = chord.inAppConflictWarning(for: action) {
          message += "。\(warning)"
        }
        setStatus(action, message, error: false)
        continue
      }
      setStatus(
        action,
        Self.registrationErrorMessage(status, inApp: action.defaultLabel),
        error: true
      )
      logger.error("RegisterEventHotKey failed for \(action.rawValue, privacy: .public): \(status)")
    }
  }

  private func register(_ action: GlobalHotkeyAction, _ chord: MarkHotkeyChord) -> OSStatus {
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: justSaidHotkeySignature, id: action.carbonHotKeyID)
    let status = RegisterEventHotKey(
      chord.keyCode,
      chord.carbonModifiers,
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &ref
    )
    if status == noErr, let ref {
      hotKeyRefs[action.carbonHotKeyID] = ref
    }
    return status
  }

  private func unregisterAllHotKeys() {
    for (_, ref) in hotKeyRefs {
      UnregisterEventHotKey(ref)
    }
    hotKeyRefs.removeAll()
  }

  private func installHandlerIfNeeded() {
    guard eventHandler == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let status = InstallEventHandler(
      GetEventDispatcherTarget(),
      justSaidCarbonHotKeyHandler,
      1,
      &eventType,
      nil,
      &eventHandler
    )
    if status != noErr {
      logger.error("InstallEventHandler failed: \(status)")
    }
  }

  fileprivate func deliverPressed(id: UInt32) {
    guard let action = GlobalHotkeyAction.allCases.first(where: { $0.carbonHotKeyID == id }) else {
      return
    }
    onPressed?(action)
  }

  private func setStatus(_ action: GlobalHotkeyAction, _ message: String?, error: Bool) {
    var messages = statusMessages
    var errors = statusErrors
    if let message {
      messages[action] = message
    } else {
      messages.removeValue(forKey: action)
    }
    errors[action] = error
    statusMessages = messages
    statusErrors = errors
  }

  // MARK: - Mapping

  static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
    return carbon
  }

  static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
    switch Int(keyCode) {
    case kVK_Command, kVK_RightCommand,
      kVK_Shift, kVK_RightShift,
      kVK_Option, kVK_RightOption,
      kVK_Control, kVK_RightControl,
      kVK_Function, kVK_CapsLock:
      return true
    default:
      return false
    }
  }

  static func registrationErrorMessage(_ status: OSStatus, inApp: String) -> String {
    if status == eventHotKeyExistsErr {
      return "无法注册：该组合键已被系统或其他应用占用。全局热键当前未生效，主窗前台仍可用 \(inApp)。"
    }
    return "无法注册全局热键（错误码 \(status)）。主窗前台仍可用 \(inApp)。"
  }
}

/// Carbon 回调必须是不捕获的 C 函数。只负责把事件抛到主队列,不做任何标记/落盘。
private func justSaidCarbonHotKeyHandler(
  _ callRef: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr, hotKeyID.signature == justSaidHotkeySignature else {
    return OSStatus(eventNotHandledErr)
  }
  let pressedHotKeyID = hotKeyID.id
  DispatchQueue.main.async {
    Task { @MainActor in
      GlobalHotkeyManager.shared.deliverPressed(id: pressedHotKeyID)
    }
  }
  return noErr
}

/// 应用内快捷键与全局热键偶发双投时,只让第一记落到动作。按动作分槽,互不抢门。
enum HotkeyTriggerGate {
  @MainActor
  private static var lastAcceptedAt: [GlobalHotkeyAction: Date] = [:]
  private static let interval: TimeInterval = 0.22

  @MainActor
  static func tryBegin(_ action: GlobalHotkeyAction) -> Bool {
    let now = Date()
    if let last = lastAcceptedAt[action], now.timeIntervalSince(last) < interval {
      return false
    }
    lastAcceptedAt[action] = now
    return true
  }
}

/// 应用内 ⌥⌘M 与全局热键偶发双投时,只让第一记落到 `beginMark`。
enum MarkTriggerGate {
  @MainActor
  static func tryBegin() -> Bool {
    HotkeyTriggerGate.tryBegin(.mark)
  }
}

/// 三行全局热键动作。默认值=应用内快捷键;持久化 key 各自独立。
public enum GlobalHotkeyAction: String, CaseIterable, Identifiable, Hashable {
  case mark
  case chat
  case pauseMicrophone

  public var id: String { rawValue }

  public var carbonHotKeyID: UInt32 {
    switch self {
    case .mark: return 1
    case .chat: return 2
    case .pauseMicrophone: return 3
    }
  }

  public var defaultsKey: String {
    switch self {
    case .mark: return MarkHotkeyChord.markDefaultsKey
    case .chat: return MarkHotkeyChord.chatDefaultsKey
    case .pauseMicrophone: return MarkHotkeyChord.pauseDefaultsKey
    }
  }

  public var defaultChord: MarkHotkeyChord {
    switch self {
    case .mark: return .markDefault
    case .chat: return .chatDefault
    case .pauseMicrophone: return .pauseDefault
    }
  }

  public var title: String {
    switch self {
    case .mark: return "标记重点"
    case .chat: return "标记闲聊"
    case .pauseMicrophone: return "暂停麦克风"
    }
  }

  public var defaultLabel: String {
    defaultChord.displayLabel
  }

  public var accessibilityPrefix: String {
    switch self {
    case .mark: return "settings.mark-hotkey"
    case .chat: return "settings.chat-hotkey"
    case .pauseMicrophone: return "settings.pause-hotkey"
    }
  }
}

/// 三行互撞:改键/恢复默认时,与另外两行已启用组合相同则拒绝。
public enum GlobalHotkeyCollision {
  public static func collidingAction(
    applying chord: MarkHotkeyChord,
    to action: GlobalHotkeyAction,
    among configurations: [GlobalHotkeyAction: MarkHotkeyChord]
  ) -> GlobalHotkeyAction? {
    guard chord.isEnabled else { return nil }
    for other in GlobalHotkeyAction.allCases where other != action {
      let occupied = configurations[other] ?? other.defaultChord
      guard occupied.isEnabled else { continue }
      if occupied.keyCode == chord.keyCode,
        occupied.carbonModifiers == chord.carbonModifiers
      {
        return other
      }
    }
    return nil
  }
}

/// 呈现层配置,只进 UserDefaults,不入会议数据、不进 Core。三行共用同一 JSON 形状。
public struct MarkHotkeyChord: Equatable, Codable, Sendable {
  public var isEnabled: Bool
  public var keyCode: UInt32
  public var carbonModifiers: UInt32

  public init(isEnabled: Bool, keyCode: UInt32, carbonModifiers: UInt32) {
    self.isEnabled = isEnabled
    self.keyCode = keyCode
    self.carbonModifiers = carbonModifiers
  }

  public static let markDefaultsKey = "justsaid.hotkey.mark"
  public static let chatDefaultsKey = "justsaid.hotkey.chat"
  public static let pauseDefaultsKey = "justsaid.hotkey.pause"
  public static let defaultsKey = markDefaultsKey

  public static let markDefault = MarkHotkeyChord(
    isEnabled: true,
    keyCode: UInt32(kVK_ANSI_M),
    carbonModifiers: UInt32(cmdKey | optionKey)
  )

  public static let chatDefault = MarkHotkeyChord(
    isEnabled: true,
    keyCode: UInt32(kVK_ANSI_X),
    carbonModifiers: UInt32(cmdKey | optionKey)
  )

  public static let pauseDefault = MarkHotkeyChord(
    isEnabled: true,
    keyCode: UInt32(kVK_ANSI_P),
    carbonModifiers: UInt32(cmdKey | optionKey)
  )

  public static let `default` = markDefault

  public var displayLabel: String {
    guard isEnabled else { return "已停用" }
    return Self.label(keyCode: keyCode, modifiers: carbonModifiers)
  }

  /// 与驾驶舱右栏写死的应用内 ⌥⌘M 撞车时,靠 Carbon 吞键 + `MarkTriggerGate` 去重。
  public var matchesInAppOptionCommandM: Bool {
    isEnabled
      && keyCode == UInt32(kVK_ANSI_M)
      && carbonModifiers == UInt32(cmdKey | optionKey)
  }

  public func inAppConflictWarning(for action: GlobalHotkeyAction) -> String? {
    guard isEnabled else { return nil }
    let optionCommand = UInt32(cmdKey | optionKey)
    if action != .pauseMicrophone,
      keyCode == UInt32(kVK_ANSI_P), carbonModifiers == optionCommand
    {
      return "与应用内「暂停麦克风」⌥⌘P 相同，主窗前台可能两动作一起触发"
    }
    if action != .chat,
      keyCode == UInt32(kVK_ANSI_X), carbonModifiers == optionCommand
    {
      return "与应用内「闲聊」⌥⌘X 相同，主窗前台可能两动作一起触发"
    }
    if action != .mark,
      keyCode == UInt32(kVK_ANSI_M), carbonModifiers == optionCommand
    {
      return "与应用内「标记重点」⌥⌘M 相同，主窗前台可能两动作一起触发"
    }
    if keyCode == UInt32(kVK_ANSI_L), carbonModifiers == UInt32(cmdKey) {
      return "与应用内「会议库」⌘L 相同，主窗前台可能两动作一起触发"
    }
    if keyCode == UInt32(kVK_ANSI_Comma), carbonModifiers == UInt32(cmdKey) {
      return "与应用内「设置」⌘, 相同（app 菜单命令），应用前台可能两动作一起触发"
    }
    return nil
  }

  public static func load(
    from defaults: UserDefaults = .standard,
    key: String = defaultsKey,
    fallback: MarkHotkeyChord = .markDefault
  ) -> MarkHotkeyChord {
    guard let data = defaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode(MarkHotkeyChord.self, from: data)
    else {
      return fallback
    }
    return decoded
  }

  public func persist(to defaults: UserDefaults = .standard, key: String = defaultsKey) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: key)
  }

  public static func label(keyCode: UInt32, modifiers: UInt32) -> String {
    var parts = ""
    if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
    parts += keyName(keyCode)
    return parts
  }

  private static func keyName(_ keyCode: UInt32) -> String {
    if let name = namedKeys[keyCode] {
      return name
    }
    return "Key\(keyCode)"
  }

  private static let namedKeys: [UInt32: String] = [
    UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
    UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
    UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
    UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
    UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
    UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
    UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
    UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
    UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
    UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
    UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
    UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
    UInt32(kVK_ANSI_9): "9",
    UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
    UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
    UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";",
    UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
    UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
    UInt32(kVK_ANSI_Grave): "`",
    UInt32(kVK_Space): "空格",
    UInt32(kVK_Return): "↩",
    UInt32(kVK_ANSI_KeypadEnter): "↩",
    UInt32(kVK_Tab): "⇥",
    UInt32(kVK_Delete): "⌫",
    UInt32(kVK_ForwardDelete): "⌦",
    UInt32(kVK_Escape): "Esc",
    UInt32(kVK_LeftArrow): "←",
    UInt32(kVK_RightArrow): "→",
    UInt32(kVK_DownArrow): "↓",
    UInt32(kVK_UpArrow): "↑",
    UInt32(kVK_Home): "Home",
    UInt32(kVK_End): "End",
    UInt32(kVK_PageUp): "PgUp",
    UInt32(kVK_PageDown): "PgDn",
    UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
    UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
    UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
    UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
  ]
}

private let logger = Logger(subsystem: "com.justsaid.app", category: "hotkey")
