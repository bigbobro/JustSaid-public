import Foundation

/// 不解码音轨、只读 MP4/M4A 容器头里的 `mvhd` 时长。
///
/// 背景(2026-08-07 B4):Opus-in-MP4 让 AVFoundation 整文件罢工(时长报 0),
/// 但 `mvhd` 里的 duration/timescale 一直在——`ffprobe` 正是这么读到真实秒数的。
/// **拿不到返回 nil,绝不当 0**(账本纪律:「没查到」与「没花钱」必须可区分)。
public enum MP4ContainerDuration {
  /// 从文件路径探测;非 MP4 家族或解析失败 → nil。
  public static func durationSeconds(at url: URL) -> TimeInterval? {
    guard
      let handle = try? FileHandle(forReadingFrom: url)
    else {
      return nil
    }
    defer { try? handle.close() }
    // 只读前 2MB:moov/mvhd 通常靠前;大文件尾部 moov 再扫一遍。
    let head = (try? handle.read(upToCount: 2_000_000)) ?? Data()
    if let seconds = durationSeconds(in: head) {
      return seconds
    }
    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard fileSize > 2_000_000 else { return nil }
    let tailSize = min(2_000_000, fileSize)
    try? handle.seek(toOffset: UInt64(fileSize - tailSize))
    let tail = (try? handle.read(upToCount: tailSize)) ?? Data()
    return durationSeconds(in: tail)
  }

  public static func durationSeconds(in data: Data) -> TimeInterval? {
    guard data.count >= 8 else { return nil }
    // 非 MP4 家族(无 ftyp 四字符类型位)直接放弃,避免把 AAC 帧当 box 乱扫。
    let typeHint = String(bytes: data[4..<8], encoding: .ascii) ?? ""
    guard typeHint == "ftyp" || typeHint == "moov" || typeHint == "mdat" || typeHint == "free"
    else {
      return nil
    }
    return findMVHD(in: data, range: 0..<data.count)
  }

  private static func findMVHD(in data: Data, range: Range<Int>) -> TimeInterval? {
    var offset = range.lowerBound
    var guardSteps = 0
    while offset + 8 <= range.upperBound {
      guardSteps += 1
      // 异常 size 或损坏文件时硬停,避免解析自旋。
      guard guardSteps < 10_000 else { return nil }
      let size32 = readUInt32(data, at: offset)
      let typeStart = offset + 4
      let typeEnd = offset + 8
      guard typeEnd <= data.count else { break }
      let type = String(bytes: data[typeStart..<typeEnd], encoding: .ascii) ?? ""
      var boxSize = Int(size32)
      var header = 8
      if size32 == 1 {
        guard offset + 16 <= range.upperBound else { break }
        let size64 = readUInt64(data, at: offset + 8)
        guard size64 <= UInt64(Int.max) else { break }
        boxSize = Int(size64)
        header = 16
      } else if size32 == 0 {
        boxSize = range.upperBound - offset
      }
      // 必须前进,否则损坏的 0 尺寸会自旋。
      guard boxSize > header, offset + boxSize <= range.upperBound else {
        offset += 1
        continue
      }

      let contentStart = offset + header
      let contentEnd = offset + boxSize

      if type == "mvhd" {
        return parseMVHD(data, start: contentStart, end: contentEnd)
      }
      if type == "moov" || type == "trak" || type == "mdia" {
        if let found = findMVHD(in: data, range: contentStart..<contentEnd) {
          return found
        }
      }
      offset += boxSize
    }
    return nil
  }

  private static func parseMVHD(_ data: Data, start: Int, end: Int) -> TimeInterval? {
    // version(1) + flags(3)
    guard start + 4 <= end else { return nil }
    let version = data[start]
    if version == 1 {
      // creation(8)+modification(8)+timescale(4)+duration(8)
      guard start + 4 + 8 + 8 + 4 + 8 <= end else { return nil }
      let timescale = readUInt32(data, at: start + 4 + 16)
      let duration = readUInt64(data, at: start + 4 + 20)
      guard timescale > 0, duration > 0 else { return nil }
      return TimeInterval(duration) / TimeInterval(timescale)
    }
    // version 0: creation(4)+modification(4)+timescale(4)+duration(4)
    guard start + 4 + 4 + 4 + 4 + 4 <= end else { return nil }
    let timescale = readUInt32(data, at: start + 4 + 8)
    let duration = readUInt32(data, at: start + 4 + 12)
    guard timescale > 0, duration > 0 else { return nil }
    return TimeInterval(duration) / TimeInterval(timescale)
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
      UInt32(bigEndian: $0.load(as: UInt32.self))
    }
  }

  private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    guard offset + 8 <= data.count else { return 0 }
    return data.subdata(in: offset..<(offset + 8)).withUnsafeBytes {
      UInt64(bigEndian: $0.load(as: UInt64.self))
    }
  }
}
