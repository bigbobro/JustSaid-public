import Foundation

/// Core Audio 进程对象的一次读数。只含检测需要的事实，不含声音内容。
public struct AudioProcessSample: Equatable, Sendable {
  public var pid: Int32
  public var parentPID: Int32
  /// 进程自己的 bundle ID；命令行程序等可能为空。
  public var bundleID: String
  /// `proc_name`，bundle ID 为空时用来区分不同的命令行进程。
  public var processName: String
  public var isRunningInput: Bool
  public var isRunningOutput: Bool

  public init(
    pid: Int32,
    parentPID: Int32 = 1,
    bundleID: String = "",
    processName: String = "",
    isRunningInput: Bool,
    isRunningOutput: Bool
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.bundleID = bundleID
    self.processName = processName
    self.isRunningInput = isRunningInput
    self.isRunningOutput = isRunningOutput
  }
}

/// 提供当前正在做输入或输出的音频进程。空闲的进程对象不必返回。
public protocol AudioProcessSnapshotProvider: Sendable {
  func snapshot() -> [AudioProcessSample]
  /// 全部进程对象，含此刻空闲的。按 App 录系统声要把空闲的 helper 也算进家族。
  func allProcesses() -> [AudioProcessSample]
}

extension AudioProcessSnapshotProvider {
  public func allProcesses() -> [AudioProcessSample] { snapshot() }
}

/// 正在运行的 App 的一条记录，由系统查询提供；E2E 用假实现。
public struct RunningAppInfo: Equatable, Sendable {
  public var pid: Int32
  public var bundleID: String?
  public var localizedName: String?
  /// 普通前台 App（有 Dock 图标），不含 helper、后台代理。
  public var isRegular: Bool

  public init(pid: Int32, bundleID: String?, localizedName: String?, isRegular: Bool) {
    self.pid = pid
    self.bundleID = bundleID
    self.localizedName = localizedName
    self.isRegular = isRegular
  }
}

public protocol RunningAppLookup: Sendable {
  func app(pid: Int32) -> RunningAppInfo?
  func app(bundleID: String) -> RunningAppInfo?
  /// 按显示名找普通前台 App。
  func regularApp(named name: String) -> RunningAppInfo?
  func parentPID(of pid: Int32) -> Int32?
}

/// 一个 App 家族的身份。按 App 计，不按 pid：重启、多 helper 都是同一个 key。
public struct AppIdentity: Equatable, Hashable, Sendable {
  /// 主程序 bundle ID；没有 bundle ID 的进程为 `proc:<进程名>`。
  public var key: String
  public var bundleID: String?
  public var displayName: String

  public init(key: String, bundleID: String?, displayName: String) {
    self.key = key
    self.bundleID = bundleID
    self.displayName = displayName
  }
}

public struct MeetingCallInfo: Equatable, Sendable {
  public var app: AppIdentity
  /// 进入「通话中」的时刻：输入与输出首次连续同开的时刻，不是满 5 s 后的检测时刻。
  public var startedAt: Date

  public init(app: AppIdentity, startedAt: Date) {
    self.app = app
    self.startedAt = startedAt
  }
}

public enum AudioActivityKind: String, Equatable, Sendable {
  case input
  case output
}

public struct AudioActivity: Equatable, Sendable {
  public var app: AppIdentity
  public var kind: AudioActivityKind
  public var isActive: Bool
  public var at: Date
  public var isExcluded: Bool
}

public enum MeetingDetectionEvent: Equatable, Sendable {
  /// 输入与输出连续同开满 `startHold`。每次通话只发一次。
  case callStarted(MeetingCallInfo)
  /// 输入输出都停满 `endHold`，或整个家族消失满 `endHold`。`endedAt` 是两路首次同时停的时刻。
  case callEnded(MeetingCallInfo, endedAt: Date)
  /// 正在记录、被跟踪的 App 通话结束：该问用户是否结束记录。
  case stopPromptDue(MeetingCallInfo, endedAt: Date)
  /// 输入、输出的起停，供诊断日志。输出的起停只在该家族出现过输入后才发。
  case activity(AudioActivity)
}

extension RunningAppLookup {
  /// 默认用 libproc 取父进程，实现方（界面层、验证）不必再写一份。
  public func parentPID(of pid: Int32) -> Int32? { SystemProcessInfo.parentPID(of: pid) }
}
