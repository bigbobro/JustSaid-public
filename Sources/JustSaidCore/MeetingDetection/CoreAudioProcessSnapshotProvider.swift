import CoreAudio
import Darwin
import Foundation

/// 读 Core Audio 进程对象（`kAudioHardwarePropertyProcessObjectList`）。
///
/// 只读进程列表、bundle ID、输入输出运行状态，不建 tap、不读音频，也不需要权限提示
/// （2026-09-30 在未签名命令行里实测）。`IsRunningInput` 的属性监听实测不触发，所以轮询。
public struct CoreAudioProcessSnapshotProvider: AudioProcessSnapshotProvider {
  public init() {}

  public func snapshot() -> [AudioProcessSample] { read(includeIdle: false) }

  /// 含空闲对象：按 App 录音时要知道家族里所有能被 tap 的进程。
  public func allProcesses() -> [AudioProcessSample] { read(includeIdle: true) }

  private func read(includeIdle: Bool) -> [AudioProcessSample] {
    var samples: [AudioProcessSample] = []
    for object in Self.processObjects() {
      let input: UInt32 = Self.read(object, kAudioProcessPropertyIsRunningInput) ?? 0
      let output: UInt32 = Self.read(object, kAudioProcessPropertyIsRunningOutput) ?? 0
      // 空闲对象占大多数（本机 36 个里通常只有 0 到 3 个在跑）：检测用的快照不读身份。
      guard includeIdle || input != 0 || output != 0 else { continue }
      guard let pid: pid_t = Self.read(object, kAudioProcessPropertyPID), pid > 0 else {
        continue
      }
      samples.append(
        AudioProcessSample(
          pid: pid,
          parentPID: SystemProcessInfo.parentPID(of: pid) ?? 1,
          bundleID: Self.readBundleID(object) ?? "",
          processName: SystemProcessInfo.name(of: pid) ?? "",
          isRunningInput: input != 0,
          isRunningOutput: output != 0
        ))
    }
    return samples
  }

  private static func processObjects() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
      size > 0
    else { return [] }
    var objects = [AudioObjectID](
      repeating: AudioObjectID(kAudioObjectUnknown),
      count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
    else { return [] }
    return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).map { $0 }
  }

  private static func read<T: FixedWidthInteger>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> T? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: T = 0
    var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  private static func readBundleID(_ object: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    return value.takeRetainedValue() as String
  }
}

enum SystemProcessInfo {
  static func parentPID(of pid: Int32) -> Int32? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Int32(bitPattern: info.pbi_ppid)
  }

  static func name(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }
}
