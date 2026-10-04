import Foundation

/// 某个 App 家族在 Core Audio 里的全部进程对象（含此刻空闲的 helper）。
/// 按 App 录系统声用它决定 tap 要哪些 pid，录制中再用它发现新出现的 helper。
public protocol AppFamilyProcessSource: Sendable {
  func familyProcesses(appKey: String) -> [AudioProcessSample]
}

/// 系统实现：读全部进程对象，逐个用与检测相同的身份规则（design 规则 1 至 5）归家，留下属于 `appKey` 的。
///
/// 家族按身份 key 计，不按 bundle ID 字面：
/// - 浏览器：主程序与 `.helper…` 都归到主程序 bundle，整个浏览器是一家（提醒上已写明）。
/// - 找不到宿主的 WebKit helper：按 pid 各成一家，家族只有它自己，不会吸进别的 App。
/// - 飞书、Lark、企业定制版 Lark 共用 `com.electron.lark`：身份无法区分，同 key 的进程全部算进来。
///   宁可多录一个同时在跑的同类 App 的声音，也不漏掉会议那一侧；漏录不可补，多录只是范围比预期宽。
/// - 无 bundle ID 的命令行进程按进程名成家（真机验证用的测试进程靠这条）。
/// 每次调用用全新的解析器：解析器带缓存且非线程安全，这里不和检测监视器共用。
public struct SystemAppFamilyProcessSource: AppFamilyProcessSource {
  private let provider: AudioProcessSnapshotProvider
  private let lookup: RunningAppLookup
  private let selfPID: Int32

  public init(
    lookup: RunningAppLookup,
    provider: AudioProcessSnapshotProvider = CoreAudioProcessSnapshotProvider(),
    selfPID: Int32 = getpid()
  ) {
    self.lookup = lookup
    self.provider = provider
    self.selfPID = selfPID
  }

  public func familyProcesses(appKey: String) -> [AudioProcessSample] {
    let resolver = MeetingAppIdentityResolver(lookup: lookup, selfPID: selfPID)
    return provider.allProcesses().filter { sample in
      if case .app(let identity) = resolver.resolve(sample) { return identity.key == appKey }
      return false
    }
  }
}

/// 常见浏览器的主程序 bundle ID。浏览器会议只能按整个浏览器录，提醒与 meeting.json 用它判断。
/// 来源：`research/prototype-research.md` §4（Homebrew cask 与本机 Safari）。
/// 其他 Chromium/Gecko 衍生浏览器未验证，不在表里，会被当普通 App 处理。
public enum MeetingBrowsers {
  public static let bundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.apple.Safari",
    "com.microsoft.edgemac",
    "company.thebrowser.Browser",
    "org.mozilla.firefox",
  ]

  public static func isBrowser(appKey: String) -> Bool { bundleIDs.contains(appKey) }
}
