import AVFoundation
import CoreAudio
import Foundation

/// 默认输入设备摘要(08-20 失败可自证单):启动轨迹头只认**开工时**采好的这一份,
/// 失败路径绝不再查 HAL——若启动超时的根因正是 HAL 被楔住,失败时再查会把
/// 诊断路径自己挂死。全部字段来自同步 CoreAudio 查询,查询失败以 nil 表示。
public struct AudioInputDeviceSummary: Equatable, Sendable {
  public var name: String?
  public var transport: String?
  public var channelCount: Int?

  public init(
    name: String? = nil,
    transport: String? = nil,
    channelCount: Int? = nil
  ) {
    self.name = name
    self.transport = transport
    self.channelCount = channelCount
  }

  /// start-failures 轨迹头的稳定键值形态;字段缺失写「未知」,不留空引发歧义。
  public var logDescription: String {
    let channels = channelCount.map(String.init) ?? "未知"
    return "device=「\(name ?? "未知")」 transport=\(transport ?? "未知") channels=\(channels)"
  }
}

/// App-lifetime read-only directory. All HAL/discovery work stays on its serial query queue.
@MainActor
public final class AudioInputDeviceMonitor: ObservableObject {
  @Published public private(set) var snapshot: MicrophoneInputDirectorySnapshot
  public var currentDeviceName: String? {
    snapshot.devices.first { $0.uid == snapshot.defaultInputUID }?.name
  }
  private var observation: AudioInputDirectoryObservation?
  private let initialSnapshot: MicrophoneInputDirectorySnapshot?
  private let readSnapshot: (@Sendable () throws -> MicrophoneInputDirectorySnapshot)?
  private let subscribe: (@Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void))?

  public init() {
    snapshot = MicrophoneInputDirectorySnapshot(queryFailure: "正在读取麦克风设备")
    initialSnapshot = nil
    readSnapshot = nil
    subscribe = nil
  }

  /// Synthetic callers supply both inventory and events; this path performs no native query.
  public init(
    initialSnapshot: MicrophoneInputDirectorySnapshot,
    readSnapshot: @escaping @Sendable () throws -> MicrophoneInputDirectorySnapshot,
    subscribe: (@Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void))? = nil
  ) {
    snapshot = initialSnapshot
    self.initialSnapshot = initialSnapshot
    self.readSnapshot = readSnapshot
    self.subscribe = subscribe
  }

  deinit { observation?.stop() }

  public func start() {
    guard observation == nil else { return }
    let token = UUID()
    let observation = AudioInputDirectoryObservation(
      token: token, initialSnapshot: initialSnapshot,
      readSnapshot: readSnapshot, subscribe: subscribe
    ) { [weak self] token, snapshot in
      Task { @MainActor [weak self] in
        guard let self, self.observation?.token == token else { return }
        self.snapshot = snapshot
      }
    }
    self.observation = observation
    observation.start()
  }

  public func stop() {
    observation?.stop()
    observation = nil
  }

  /// Convenience callers resolve Auto once. RecordingSession always supplies its fixed target.
  nonisolated static func automaticTarget() throws -> MicrophoneInputTarget {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
    )
    let snapshot = try readDirectory(devices: discovery.devices)
    guard let device = snapshot.devices.first(where: { $0.uid == snapshot.defaultInputUID }) else {
      throw AudioCaptureError.microphoneUnavailable("没有可用的系统麦克风")
    }
    return MicrophoneInputTarget(device: device)
  }

  nonisolated static func readDirectory(
    devices captureDevices: [AVCaptureDevice]
  ) throws -> MicrophoneInputDirectorySnapshot {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
      throw AudioCaptureError.microphoneUnavailable("无法查询麦克风设备列表")
    }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    let status =
      ids.isEmpty
      ? noErr
      : ids.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
      }
    guard status == noErr else {
      throw AudioCaptureError.microphoneUnavailable("无法读取麦克风设备列表")
    }
    let defaultID = try readDefaultInputID()
    var entries: [MicrophoneInputDevice] = []
    for id in ids {
      guard let channels = inputChannelCount(deviceID: id) else {
        throw AudioCaptureError.microphoneUnavailable("无法查询输入设备声道")
      }
      guard channels > 0 else { continue }
      guard let alive = deviceIsAlive(id) else {
        throw AudioCaptureError.microphoneUnavailable("无法查询输入设备连接状态")
      }
      guard alive else { continue }
      guard let uid = deviceString(id, selector: kAudioDevicePropertyDeviceUID) else {
        throw AudioCaptureError.microphoneUnavailable("无法读取输入设备身份")
      }
      let name = deviceString(id, selector: kAudioDevicePropertyDeviceNameCFString) ?? "未命名麦克风"
      let candidates = captureDevices.filter {
        $0.uniqueID == uid && $0.isConnected && $0.hasMediaType(.audio)
      }
      let captureID =
        candidates.count == 1
        ? MicrophoneCaptureDeviceID(rawValue: candidates[0].uniqueID) : nil
      entries.append(
        MicrophoneInputDevice(
          uid: MicrophoneDeviceUID(rawValue: uid), captureID: captureID, objectID: id, name: name,
          summary: AudioInputDeviceSummary(
            name: name, transport: transportType(deviceID: id).map(transportDescription),
            channelCount: channels
          )
        ))
    }
    let defaultUID = entries.first { $0.objectID == defaultID }?.uid
    return MicrophoneInputDirectorySnapshot(devices: entries, defaultInputUID: defaultUID)
  }

  nonisolated private static func readDefaultInputID() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var value = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value
      ) == noErr
    else {
      throw AudioCaptureError.microphoneUnavailable("无法查询系统默认麦克风")
    }
    return value
  }

  /// Checked HAL UID lookup; noErr with an unknown object is still a missing endpoint.
  nonisolated static func checkedDeviceID(for uid: MicrophoneDeviceUID) throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var value = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var qualifier = uid.rawValue as CFString
    let status = withUnsafePointer(to: &qualifier) {
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<CFString>.size), $0, &size, &value
      )
    }
    guard status == noErr, value != kAudioObjectUnknown,
      deviceString(value, selector: kAudioDevicePropertyDeviceUID) == uid.rawValue,
      deviceIsAlive(value) == true, let channels = inputChannelCount(deviceID: value), channels > 0
    else {
      throw AudioCaptureError.microphoneUnavailable("无法核对所选麦克风的设备身份或连接状态")
    }
    return value
  }

  nonisolated static func deviceString(
    _ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    let string = value.takeRetainedValue() as String
    return string.isEmpty ? nil : string
  }

  nonisolated private static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value != 0
  }

  /// 系统默认输入设备名;无输入设备或查询失败为 nil。Verification 直接调用断言非空。
  public nonisolated static func defaultInputDeviceName() -> String? {
    guard let deviceID = MicrophoneCapture.defaultInputDevice() else {
      return nil
    }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceNameCFString,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &name) { pointer in
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let name else {
      return nil
    }
    let value = name.takeRetainedValue() as String
    return value.isEmpty ? nil : value
  }

  /// 默认输入设备的名字/transport/输入声道数,一次采齐(启动轨迹头用)。
  public nonisolated static func defaultInputDeviceSummary() -> AudioInputDeviceSummary {
    guard let deviceID = MicrophoneCapture.defaultInputDevice() else {
      return AudioInputDeviceSummary()
    }
    return AudioInputDeviceSummary(
      name: defaultInputDeviceName(),
      transport: transportType(deviceID: deviceID).map(transportDescription),
      channelCount: inputChannelCount(deviceID: deviceID)
    )
  }

  private nonisolated static func transportType(deviceID: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr else {
      return nil
    }
    return value
  }

  private nonisolated static func transportDescription(_ raw: UInt32) -> String {
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypePCI: return "PCI"
    case kAudioDeviceTransportTypeFireWire: return "FireWire"
    default:
      // 未知类型按 fourCC 原样呈现,不猜。
      let bytes = [
        UInt8((raw >> 24) & 0xFF),
        UInt8((raw >> 16) & 0xFF),
        UInt8((raw >> 8) & 0xFF),
        UInt8(raw & 0xFF),
      ]
      let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
      if printable, let fourCC = String(bytes: bytes, encoding: .ascii) {
        return "fourCC(\(fourCC))"
      }
      return "raw(\(raw))"
    }
  }

  private nonisolated static func inputChannelCount(deviceID: AudioDeviceID) -> Int? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
      size >= UInt32(MemoryLayout<UInt32>.size)
    else {
      return nil
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
    guard status == noErr else {
      return nil
    }
    let list = UnsafeMutableAudioBufferListPointer(
      raw.assumingMemoryBound(to: AudioBufferList.self)
    )
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }
}

/// Safety invariant: mutable listener/query state belongs exclusively to queue. Only immutable
/// snapshots cross it. stop queues removal on that same queue; the lifetime token rejects
/// already-published callbacks after the MainActor monitor releases this observation.
private final class AudioInputDirectoryObservation: @unchecked Sendable {
  let token: UUID
  private let queue = DispatchQueue(label: "com.justsaid.input-directory")
  private let reader: (@Sendable () throws -> MicrophoneInputDirectorySnapshot)?
  private let subscriber: (@Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void))?
  private let publish: @Sendable (UUID, MicrophoneInputDirectorySnapshot) -> Void
  private var lastSuccessful: MicrophoneInputDirectorySnapshot?
  private var nextIncarnation: UInt64 = 0
  private var discovery: AVCaptureDevice.DiscoverySession?
  private var listeners:
    [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var deviceListeners: Set<AudioObjectID> = []
  private var notifications: [NSObjectProtocol] = []
  private var unsubscribe: (@Sendable () -> Void)?
  private var active = false
  private var refreshScheduled = false
  private var listenerFailed = false

  init(
    token: UUID, initialSnapshot: MicrophoneInputDirectorySnapshot?,
    readSnapshot: (@Sendable () throws -> MicrophoneInputDirectorySnapshot)?,
    subscribe: (@Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void))?,
    publish: @escaping @Sendable (UUID, MicrophoneInputDirectorySnapshot) -> Void
  ) {
    self.token = token
    lastSuccessful = initialSnapshot?.queryFailure == nil ? initialSnapshot : nil
    nextIncarnation = initialSnapshot?.devices.map(\.incarnation).max() ?? 0
    reader = readSnapshot
    subscriber = subscribe
    self.publish = publish
  }

  func start() {
    queue.async { [self] in
      active = true
      if let reader {
        _ = reader
        unsubscribe = subscriber? { [weak self] in self?.requestRefresh() }
      } else {
        addListener(
          AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        for name in [
          AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
        ] {
          notifications.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
              [weak self] _ in self?.requestRefresh()
            })
        }
        discovery = AVCaptureDevice.DiscoverySession(
          deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        )
      }
      refresh()
    }
  }

  func stop() {
    queue.async { [self] in
      active = false
      unsubscribe?()
      unsubscribe = nil
      for (id, var address, block) in listeners {
        AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
      }
      listeners.removeAll()
      for token in notifications { NotificationCenter.default.removeObserver(token) }
      notifications.removeAll()
      discovery = nil
    }
  }

  private func requestRefresh() {
    queue.async { [weak self] in
      guard let self, active else { return }
      guard !refreshScheduled else { return }
      refreshScheduled = true
      queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self else { return }
        refreshScheduled = false
        if active { refresh() }
      }
    }
  }

  private func addListener(
    _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
    )
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.requestRefresh() }
    if AudioObjectAddPropertyListenerBlock(id, &address, queue, block) == noErr {
      listeners.append((id, address, block))
    } else {
      listenerFailed = true
    }
  }

  private func refresh() {
    do {
      var snapshot =
        try reader?() ?? AudioInputDeviceMonitor.readDirectory(devices: discovery?.devices ?? [])
      if snapshot.queryFailure == nil {
        for index in snapshot.devices.indices {
          let entry = snapshot.devices[index]
          if let previous = lastSuccessful?.devices.first(where: {
            $0.uid == entry.uid && $0.objectID == entry.objectID
          }) {
            snapshot.devices[index].incarnation = previous.incarnation
          } else {
            nextIncarnation &+= 1
            snapshot.devices[index].incarnation = nextIncarnation
          }
        }
        lastSuccessful = snapshot
        if reader == nil {
          let current = Set(snapshot.devices.map(\.objectID))
          for index in listeners.indices.reversed() {
            let (id, savedAddress, block) = listeners[index]
            var address = savedAddress
            if deviceListeners.contains(id) && !current.contains(id) {
              AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
              listeners.remove(at: index)
            }
          }
          for id in current.subtracting(deviceListeners) {
            addListener(id, kAudioDevicePropertyDeviceIsAlive)
            addListener(
              id, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
          }
          deviceListeners = current
        }
      }
      if listenerFailed {
        snapshot.queryFailure = "无法监听麦克风变化，实际输入待确认"
      }
      publish(token, snapshot)
    } catch {
      // Unknown is not an observed disconnect, so it cannot manufacture reconnect revisions.
      publish(token, MicrophoneInputDirectorySnapshot(queryFailure: "无法读取麦克风设备，实际输入待确认"))
    }
  }
}
