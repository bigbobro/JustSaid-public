import Foundation

/// 本场系统声的录制范围，写进 meeting.json（2026-09-30 P2）。
/// 解码宽松：旧档案没有这个键；未知的 mode 按 global 读，字段缺失按空读，不让一份档案整体解码失败。
public struct SystemAudioScopeRecord: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Sendable {
    /// 全局 tap（手动开始，或按 App 失败后的回退）。
    case global
    /// 只录被确认 App 家族的进程。
    case perApp
  }

  public var mode: Mode
  /// 按 App 时的显示名与主程序 bundle ID；全局为 nil（回退的场次保留，说明原本想录谁）。
  public var appName: String?
  public var bundleID: String?
  /// 录制中 pid 集合扩大的次数。
  public var pidSetChanges: Int
  /// 回退成全局的原因：`noProcesses`、`tapFailed`、`expandFailed`、`userSwitched`。
  public var fallbackReason: String?

  public init(
    mode: Mode, appName: String? = nil, bundleID: String? = nil,
    pidSetChanges: Int = 0, fallbackReason: String? = nil
  ) {
    self.mode = mode
    self.appName = appName
    self.bundleID = bundleID
    self.pidSetChanges = pidSetChanges
    self.fallbackReason = fallbackReason
  }

  private enum CodingKeys: String, CodingKey {
    case mode, appName, bundleID, pidSetChanges, fallbackReason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawMode = try container.decodeIfPresent(String.self, forKey: .mode)
    mode = rawMode.flatMap(Mode.init(rawValue:)) ?? .global
    appName = try container.decodeIfPresent(String.self, forKey: .appName)
    bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
    pidSetChanges = try container.decodeIfPresent(Int.self, forKey: .pidSetChanges) ?? 0
    fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
  }
}

public enum SystemAudioScopeFallbackReason: String, Sendable {
  case noProcesses
  case tapFailed
  case expandFailed
  case userSwitched
  /// 改录全局的重建连续失败，采集可能已断，交给路级健康看门狗继续恢复。
  case globalRebuildFailed
}

/// 会中界面要展示的录制范围提示。
public enum SystemAudioScopeNotice: Equatable, Sendable {
  /// 按 App 录没成，已改为录制全部系统声音。信息级，不丢内容。
  case fellBackToGlobal
  /// 按 App 的 tap 建好了，但该 App 在出声时 tap 里一直是数字零：声音很可能来自它之外的进程。
  case silentTap(appName: String)
  /// 改录全局也没成功（重试仍失败）：系统声音现在可能没在录。警示级。
  case rebuildFailed(appName: String)
}

/// 按 App 录制中的决策（纯逻辑，输入是带时间的家族读数与 tap 峰值，便于合成验证）。
///
/// - 扩集：家族里出现**不在当前集合里、且正在输出**的进程才重建；只是空闲的新进程不重建
///   （重建会在采集里留一段静音缺口）。重建后的集合取家族当前全集，空闲 helper 一并带上。
/// - 零声：家族有进程在输出，而 tap 这段时间的峰值低于数字静音门限，连续满 `zeroOfferSeconds`
///   提示一次。N 取 30 秒，与麦克风纯静音看门狗一致：通话软件在没人说话时也会输出全零帧，
///   太短会在安静的会里误报；提示只建议、不自动改，误报代价低。
public struct SystemAudioScopePlanner: Sendable {
  public enum Decision: Equatable, Sendable {
    case none
    case expand(pids: [pid_t])
    case offerGlobal
  }

  /// 与麦克风静音看门狗同一门限（RMS < 5e-5 只有数字静音才会出现）。
  public static let silenceThreshold: Float = 0.000_05
  /// 两次读数间隔超过它按它算（机器睡眠、主线程被占），避免一次长停顿直接凑满零声时长。
  static let maximumTickSeconds: TimeInterval = 5

  public private(set) var appliedPIDs: Set<pid_t>
  public let zeroOfferSeconds: TimeInterval
  private var zeroRunSeconds: TimeInterval = 0
  private var lastTickAt: Date?
  private var hasOffered = false

  public init(appliedPIDs: Set<pid_t>, zeroOfferSeconds: TimeInterval = 30) {
    self.appliedPIDs = appliedPIDs
    self.zeroOfferSeconds = zeroOfferSeconds
  }

  /// `tapPeak` 是上次读数以来 tap 收到的最大 RMS；nil = 这段时间一帧都没收到，同样按「没听到」算
  /// （帧停摆另由路级健康看门狗处理）。
  public mutating func evaluate(
    family: [AudioProcessSample], tapPeak: Float?, at now: Date
  ) -> Decision {
    let elapsed = lastTickAt.map { min(max(0, now.timeIntervalSince($0)), Self.maximumTickSeconds) } ?? 0
    lastTickAt = now

    if family.contains(where: { $0.isRunningOutput && !appliedPIDs.contains($0.pid) }) {
      zeroRunSeconds = 0
      return .expand(pids: Set(family.map(\.pid)).sorted())
    }

    let outputRunning = family.contains { $0.isRunningOutput }
    if outputRunning, (tapPeak ?? 0) < Self.silenceThreshold {
      zeroRunSeconds += elapsed
    } else {
      zeroRunSeconds = 0
    }
    if zeroRunSeconds >= zeroOfferSeconds, !hasOffered {
      hasOffered = true
      return .offerGlobal
    }
    return .none
  }

  /// 重建成功后登记新集合；零声计时重来。
  public mutating func didApply(pids: [pid_t]) {
    appliedPIDs = Set(pids)
    zeroRunSeconds = 0
  }
}

/// 记录 tap 收到的最大 RMS，供规划器按间隔读走。音频线程只做一次加锁比较。
// Safety invariant: every access to `peak` is inside `lock`.
public final class SystemTapPeakProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var peak: Float?

  public init() {}

  public func record(rms: Float) {
    lock.withLock { peak = max(peak ?? 0, rms) }
  }

  /// 取走并清空；这段时间没有任何帧返回 nil。
  public func drain() -> Float? {
    lock.withLock {
      defer { peak = nil }
      return peak
    }
  }
}
