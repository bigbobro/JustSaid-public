import Foundation
import os

/// 诊断目录里按日期命名的 `<前缀>yyyyMMdd….log`(如 `hang-20261008-101500.log`、
/// `retention-20261008.log`)过了保留期就删。每个写者写完只清自己的前缀,不顺手扫别人的文件。
enum DiagnosticLogRetention {
  static let retentionDays = 14

  private static let logger = Logger(subsystem: "com.justsaid.app", category: "DiagnosticLogRetention")

  /// 文件名里前缀后紧跟的 8 位日期早于 `now - retentionDays` 才删;对不上格式的文件一律不碰。
  /// 清理失败只记统一日志,不影响调用方写诊断。
  static func prune(
    prefix: String,
    in directory: URL,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) {
    guard
      let names = try? fileManager.contentsOfDirectory(atPath: directory.path),
      let cutoff = Calendar(identifier: .gregorian).date(
        byAdding: .day, value: -retentionDays, to: now)
    else { return }
    let cutoffStamp = dayStamp(cutoff)
    for name in names where name.hasPrefix(prefix) && name.hasSuffix(".log") {
      let stamp = String(name.dropFirst(prefix.count).prefix(8))
      guard stamp.count == 8, stamp.allSatisfy(\.isASCII), stamp.allSatisfy(\.isNumber),
        stamp < cutoffStamp
      else { continue }
      do {
        try fileManager.removeItem(at: directory.appendingPathComponent(name))
      } catch {
        logger.error(
          "\(prefix, privacy: .public)过期诊断文件清理失败:\(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  static func dayStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: date)
  }
}
