import Foundation

/// 把音频进程归到所属 App 家族（design 规则 1 至 5）。
///
/// 只应对正在做输入或输出的进程调用；内部按 pid 缓存，避免每次轮询都查系统。
/// 非线程安全：与检测器一样只在监视器的串行队列使用。
// Safety invariant: single-owner and lock-protected by the caller. The monitor only calls it
// inside its `lock`, so the cache is never touched concurrently.
public final class MeetingAppIdentityResolver: @unchecked Sendable {
  public enum Resolution: Equatable, Sendable {
    /// JustSaid 自身或其子进程。
    case selfProcess
    case app(AppIdentity)
  }

  /// WebKit 类 helper 的名字后缀：宿主 App 名 + 后缀。
  static let webKitNameSuffixes = [
    " Graphics and Media", " Web Content", " Networking", " WebContent",
  ]

  private let lookup: RunningAppLookup
  private let selfPID: Int32
  private var cache: [Int32: (sample: AudioProcessSample, resolution: Resolution)] = [:]

  public init(lookup: RunningAppLookup, selfPID: Int32 = getpid()) {
    self.lookup = lookup
    self.selfPID = selfPID
  }

  /// 丢掉本轮没出现的 pid 的缓存。
  public func prune(keeping pids: Set<Int32>) {
    cache = cache.filter { pids.contains($0.key) }
  }

  public func resolve(_ sample: AudioProcessSample) -> Resolution {
    let signature = AudioProcessSample(
      pid: sample.pid, parentPID: sample.parentPID, bundleID: sample.bundleID,
      processName: sample.processName, isRunningInput: false, isRunningOutput: false)
    if let cached = cache[sample.pid], cached.sample == signature {
      return cached.resolution
    }
    let resolution = compute(sample)
    cache[sample.pid] = (signature, resolution)
    return resolution
  }

  private func compute(_ sample: AudioProcessSample) -> Resolution {
    // 规则 1：自身与后代。
    if isSelfOrDescendant(sample) { return .selfProcess }

    // 规则 2：`<主程序>.helper…` 归到主程序。
    if let range = sample.bundleID.range(of: ".helper"),
      range.lowerBound != sample.bundleID.startIndex
    {
      let main = String(sample.bundleID[..<range.lowerBound])
      let info = lookup.app(bundleID: main)
      return .app(
        AppIdentity(
          key: main, bundleID: main,
          displayName: info?.localizedName ?? Self.fallbackName(bundleID: main)))
    }

    // 规则 3：父进程是正在运行的前台 App，且自己不是前台 App（Xcode 调试启动的 App 不归父）。
    if let parent = lookup.app(pid: sample.parentPID), parent.isRegular,
      lookup.app(pid: sample.pid)?.isRegular != true
    {
      return .app(Self.identity(of: parent, fallbackName: sample.processName))
    }

    // 规则 4：WebKit helper（ppid 为 1）：显示名去掉后缀后匹配宿主 App。
    // 匹配不到时每个 pid 各成一家：所有 WebKit 宿主的 bundle ID 相同，共用一个 key 会把
    // 一个 App 的输入与另一个 App 的输出拼成通话。宁可少报，不跨 App 拼接。
    if sample.bundleID.hasPrefix("com.apple.WebKit.") {
      var name = lookup.app(pid: sample.pid)?.localizedName
      for suffix in Self.webKitNameSuffixes {
        if let current = name, current.hasSuffix(suffix) {
          name = String(current.dropLast(suffix.count))
          break
        }
      }
      if let name, let host = lookup.regularApp(named: name) {
        return .app(Self.identity(of: host, fallbackName: name))
      }
      return .app(
        AppIdentity(
          key: "\(sample.bundleID)#\(sample.pid)", bundleID: sample.bundleID,
          displayName: name ?? Self.fallbackName(bundleID: sample.bundleID)))
    }

    // 规则 5：自己的身份。
    if !sample.bundleID.isEmpty {
      let name =
        lookup.app(pid: sample.pid)?.localizedName
        ?? Self.fallbackName(bundleID: sample.bundleID)
      return .app(
        AppIdentity(key: sample.bundleID, bundleID: sample.bundleID, displayName: name))
    }
    let name = sample.processName.isEmpty ? "pid \(sample.pid)" : sample.processName
    return .app(AppIdentity(key: "proc:\(name)", bundleID: nil, displayName: name))
  }

  private func isSelfOrDescendant(_ sample: AudioProcessSample) -> Bool {
    if sample.pid == selfPID { return true }
    var current = sample.parentPID
    var depth = 0
    while current > 1, depth < 32 {
      if current == selfPID { return true }
      guard let next = lookup.parentPID(of: current), next != current else { return false }
      current = next
      depth += 1
    }
    return false
  }

  private static func identity(of info: RunningAppInfo, fallbackName: String) -> AppIdentity {
    let name = info.localizedName ?? info.bundleID.map(fallbackName(bundleID:)) ?? fallbackName
    return AppIdentity(
      key: info.bundleID ?? "proc:\(name)", bundleID: info.bundleID, displayName: name)
  }

  private static func fallbackName(bundleID: String) -> String {
    bundleID.split(separator: ".").last.map(String.init) ?? bundleID
  }
}
