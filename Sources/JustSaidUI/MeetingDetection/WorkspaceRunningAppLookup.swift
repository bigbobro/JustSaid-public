import AppKit
import Foundation
import JustSaidCore

/// `RunningAppLookup` 的系统实现，给会议检测的 App 身份规则 3、4 用。
/// 放在界面层是因为 `NSRunningApplication` / `NSWorkspace` 的列表要靠主 run loop 刷新，
/// 这是宿主 App 才有的前提；Core 不导入 AppKit。图标由提醒界面另取。
public struct WorkspaceRunningAppLookup: RunningAppLookup {
  public init() {}

  public func app(pid: Int32) -> RunningAppInfo? {
    NSRunningApplication(processIdentifier: pid).map(Self.info)
  }

  public func app(bundleID: String) -> RunningAppInfo? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
      .map(Self.info)
  }

  public func regularApp(named name: String) -> RunningAppInfo? {
    NSWorkspace.shared.runningApplications
      .first { $0.activationPolicy == .regular && $0.localizedName == name }
      .map(Self.info)
  }

  private static func info(_ app: NSRunningApplication) -> RunningAppInfo {
    RunningAppInfo(
      pid: app.processIdentifier,
      bundleID: app.bundleIdentifier,
      localizedName: app.localizedName,
      isRegular: app.activationPolicy == .regular
    )
  }
}
