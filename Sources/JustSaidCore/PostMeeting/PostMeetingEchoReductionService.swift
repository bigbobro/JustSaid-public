import CryptoKit
import Darwin
import Foundation
import SpeexEchoCanceller

public enum PostMeetingEchoReductionError: LocalizedError {
  case busy, unsafePath, invalidAudio, unavailable, stale, alreadyEnabled

  public var errorDescription: String? {
    switch self {
    case .busy: return "会议正在录制或处理，请完成后再生成或切换副本。"
    case .unsafePath: return "音频副本路径无效，请保留原录音后重试。"
    case .invalidAudio: return "无法读取有效的双路录音，未修改原录音。"
    case .unavailable: return "尚未生成可使用的处理副本。"
    case .stale: return "原录音或处理副本已变化，请重新生成并试听。"
    case .alreadyEnabled: return "请先恢复使用原录音，再生成新的处理副本。"
    }
  }
}

/// Per-meeting, opt-in derived audio. All file/DSP work stays on this actor,
/// never on the main actor. The shared instance serializes generation and selection.
public actor PostMeetingEchoReductionService {
  public static let shared = PostMeetingEchoReductionService()
  public static let engine = "SpeexDSP 1.2.1 · 16 kHz · frame 160 · filter 4000 · lag 0"

  public struct Report: Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let outputURL: URL
    public let isEnabled: Bool
    public let engine: String
    public let microphoneSHA256: String
    public let referenceSHA256: String
    public let outputSHA256: String
    public let microphoneSamples: Int64
    /// Reference samples actually consumed, excluding explicit zero padding.
    public let referenceSamples: Int64
    public let referencePaddingSamples: Int64
    public let sampleRate: Int
    public let clippedSamples: Int64
    public var durationSeconds: Double { Double(microphoneSamples) / Double(sampleRate) }
  }

  private struct Record: Codable {
    let schemaVersion: Int
    let id: UUID
    let meetingID: UUID
    let createdAt: Date
    let engine: String
    let microphoneSHA256: String
    let referenceSHA256: String
    let outputSHA256: String
    let microphoneSamples: Int64
    let referenceSamples: Int64
    let referencePaddingSamples: Int64
    let clippedSamples: Int64
    // Required even when empty: copies made before pause protection cannot be selected.
    let microphonePauseIntervals: [MicrophonePauseInterval]
  }
  private struct Selection: Codable {
    let enabled: Bool
    let id: UUID?
  }
  private struct Latest: Codable { let id: UUID }
  public init() {}

  public func generate(
    at directory: URL,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> Report {
    let paths = MeetingPaths(directory: directory)
    let metadata = try editable(paths)
    let pauses = metadata.microphonePauseIntervals ?? []
    let pauseMask = try PostMeetingEchoPauseMask(pauses)
    let root = try derivedRoot(paths, create: true)
    if try selection(root)?.enabled == true { throw PostMeetingEchoReductionError.alreadyEnabled }
    let micSHA = try hash(paths.microphoneAudio)
    let refSHA = try hash(paths.systemAudio)
    try Task.checkCancellation()
    let id = UUID()
    let destination = root.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: destination, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    var published = false
    defer { if !published { try? FileManager.default.removeItem(at: destination) } }
    let output = destination.appendingPathComponent("microphone.wav")
    let mic = try PostMeetingEchoPCMReader(url: paths.microphoneAudio)
    let reference = try PostMeetingEchoPCMReader(url: paths.systemAudio)
    guard let state = js_speex_create() else { throw PostMeetingEchoReductionError.invalidAudio }
    defer { js_speex_destroy(state) }
    let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw PostMeetingEchoReductionError.unsafePath }
    let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? writer.close() }
    try writer.write(contentsOf: Data(repeating: 0, count: 44))
    var count: Int64 = 0
    var referenceCount: Int64 = 0
    var clipped: Int64 = 0
    var lastProgress = Date.distantPast
    progress?(0)
    while true {
      try Task.checkCancellation()
      let microphone = try mic.read()
      if microphone.isEmpty { break }
      let render = try reference.read(microphone.count)
      referenceCount += Int64(render.count)
      let capturePCM = try quantize(microphone, clipped: &clipped)
      let renderPCM = try quantize(render, clipped: &clipped)
      var cleaned = [Int16](repeating: 0, count: 160)
      capturePCM.withUnsafeBufferPointer { capture in
        renderPCM.withUnsafeBufferPointer { playback in
          cleaned.withUnsafeMutableBufferPointer { result in
            js_speex_process(
              state, capture.baseAddress!, playback.baseAddress!, result.baseAddress!)
          }
        }
      }
      // Preserve the capture privacy gate without changing the adaptive filter state.
      pauseMask.apply(to: &cleaned, firstSample: count, sampleCount: microphone.count)
      let bytes = cleaned.prefix(microphone.count).flatMap { sample -> [UInt8] in
        let value = UInt16(bitPattern: sample)
        return [UInt8(value & 255), UInt8(value >> 8)]
      }
      try writer.write(contentsOf: Data(bytes))
      count += Int64(microphone.count)
      guard count <= Int64((UInt32.max - 36) / 2) else {
        throw PostMeetingEchoReductionError.invalidAudio
      }
      if Date().timeIntervalSince(lastProgress) >= 0.25 {
        _ = try editable(paths)
        lastProgress = Date()
        progress?(min(0.99, Double(count) / Double(max(1, mic.estimatedSamples))))
      }
    }
    guard count > 0, referenceCount > 0 else { throw PostMeetingEchoReductionError.invalidAudio }
    try writer.seek(toOffset: 0)
    try writer.write(contentsOf: wavHeader(samples: count))
    try writer.synchronize()
    try writer.close()
    try Task.checkCancellation()
    let finalMicSHA = try hash(paths.microphoneAudio)
    let finalRefSHA = try hash(paths.systemAudio)
    let finalMetadata = try editable(paths)
    guard finalMicSHA == micSHA, finalRefSHA == refSHA,
      finalMetadata.id == metadata.id,
      (finalMetadata.microphonePauseIntervals ?? []) == pauses
    else { throw PostMeetingEchoReductionError.stale }
    let record = Record(
      schemaVersion: 1, id: id, meetingID: metadata.id, createdAt: Date(),
      engine: Self.engine, microphoneSHA256: micSHA, referenceSHA256: refSHA,
      outputSHA256: try hash(output), microphoneSamples: count, referenceSamples: referenceCount,
      referencePaddingSamples: count - referenceCount, clippedSamples: clipped,
      microphonePauseIntervals: pauses)
    try write(record, to: destination.appendingPathComponent("report.json"))
    try Task.checkCancellation()
    let publicationMetadata = try editable(paths)
    guard publicationMetadata.id == metadata.id,
      (publicationMetadata.microphonePauseIntervals ?? []) == pauses
    else { throw PostMeetingEchoReductionError.stale }
    try write(Latest(id: id), to: root.appendingPathComponent("latest.json"))
    published = true
    progress?(1)
    return report(record, root: root, enabled: false)
  }

  public func existingResult(at directory: URL) async throws -> Report? {
    let paths = MeetingPaths(directory: directory)
    let root = try derivedRoot(paths)
    let selected = try selection(root)
    let id: UUID?
    if selected?.enabled == true { id = selected?.id } else { id = try latest(root)?.id }
    guard let id else { return nil }
    let record = try validate(id: id, paths: paths, root: root)
    return report(record, root: root, enabled: selected?.enabled == true && selected?.id == id)
  }

  public func setEnabled(_ enabled: Bool, at directory: URL, expectedResultID: UUID? = nil)
    async throws
  {
    let paths = MeetingPaths(directory: directory)
    _ = try editable(paths)
    let root = try derivedRoot(paths, create: true)
    var id: UUID?
    if enabled {
      guard let expectedResultID, try latest(root)?.id == expectedResultID else {
        throw PostMeetingEchoReductionError.stale
      }
      _ = try validate(id: expectedResultID, paths: paths, root: root)
      id = expectedResultID
    }
    try Task.checkCancellation()
    _ = try editable(paths)
    try write(
      Selection(enabled: enabled, id: id), to: root.appendingPathComponent("selection.json"))
  }

  /// Used only by the stereo upload path. Invalid selection throws so the caller
  /// can record the failure and compose the original two mother tracks instead.
  public func selectedMicrophone(at directory: URL) async throws -> URL? {
    try Task.checkCancellation()
    let paths = MeetingPaths(directory: directory)
    let root = try derivedRoot(paths)
    guard let selected = try selection(root), selected.enabled else { return nil }
    guard let id = selected.id else { throw PostMeetingEchoReductionError.stale }
    let record = try validate(id: id, paths: paths, root: root)
    return report(record, root: root, enabled: true).outputURL
  }

  private func validate(id: UUID, paths: MeetingPaths, root: URL) throws -> Record {
    let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
    let record: Record = try read(folder.appendingPathComponent("report.json"))
    let current = try metadata(paths)
    let micSHA = try hash(paths.microphoneAudio)
    let referenceSHA = try hash(paths.systemAudio)
    let outputSHA = try hash(folder.appendingPathComponent("microphone.wav"))
    guard record.schemaVersion == 1, record.id == id, record.engine == Self.engine,
      record.meetingID == current.id, record.microphoneSamples > 0,
      record.referenceSamples > 0, record.referenceSamples <= record.microphoneSamples,
      record.referencePaddingSamples == record.microphoneSamples - record.referenceSamples,
      record.microphonePauseIntervals == (current.microphonePauseIntervals ?? []),
      record.microphoneSHA256 == micSHA,
      record.referenceSHA256 == referenceSHA,
      record.outputSHA256 == outputSHA
    else {
      throw PostMeetingEchoReductionError.stale
    }
    return record
  }

  private func report(_ record: Record, root: URL, enabled: Bool) -> Report {
    Report(
      id: record.id, createdAt: record.createdAt,
      outputURL: root.appendingPathComponent(record.id.uuidString).appendingPathComponent(
        "microphone.wav"),
      isEnabled: enabled, engine: record.engine, microphoneSHA256: record.microphoneSHA256,
      referenceSHA256: record.referenceSHA256, outputSHA256: record.outputSHA256,
      microphoneSamples: record.microphoneSamples, referenceSamples: record.referenceSamples,
      referencePaddingSamples: record.referencePaddingSamples, sampleRate: 16_000,
      clippedSamples: record.clippedSamples)
  }

  private func metadata(_ paths: MeetingPaths) throws -> MeetingMetadata {
    try safe(paths.metadata, regular: true)
    return try MeetingStore(rootDirectory: paths.directory.deletingLastPathComponent()).read(
      from: paths)
  }
  private func editable(_ paths: MeetingPaths) throws -> MeetingMetadata {
    try Task.checkCancellation()
    let value = try metadata(paths)
    guard value.status != .recording, value.status != .processing else {
      throw PostMeetingEchoReductionError.busy
    }
    return value
  }
  private func derivedRoot(_ paths: MeetingPaths, create: Bool = false) throws -> URL {
    try safe(paths.directory)
    let root = paths.directory.appendingPathComponent("echo-reduction", isDirectory: true)
    try safe(root)
    if create && !FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    return root
  }
  private func selection(_ root: URL) throws -> Selection? {
    let path = root.appendingPathComponent("selection.json")
    try safe(path)
    return FileManager.default.fileExists(atPath: path.path) ? try read(path) : nil
  }
  private func latest(_ root: URL) throws -> Latest? {
    let path = root.appendingPathComponent("latest.json")
    try safe(path)
    return FileManager.default.fileExists(atPath: path.path) ? try read(path) : nil
  }
  private func safe(_ url: URL, regular: Bool = false) throws {
    guard url.isFileURL else { throw PostMeetingEchoReductionError.unsafePath }
    var part = url.standardizedFileURL
    while true {
      if let attributes = try? FileManager.default.attributesOfItem(atPath: part.path),
        attributes[.type] as? FileAttributeType == .typeSymbolicLink
      {
        // Foundation canonicalizes macOS temporary URLs back through these
        // root-owned aliases. User-created symlinks remain forbidden.
        let systemAliases = ["/var": "private/var", "/tmp": "private/tmp"]
        guard let expected = systemAliases[part.path],
          try FileManager.default.destinationOfSymbolicLink(atPath: part.path) == expected
        else {
          throw PostMeetingEchoReductionError.unsafePath
        }
      }
      if part.path == "/" { break }
      part.deleteLastPathComponent()
    }
    if regular {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        (attributes[.referenceCount] as? NSNumber)?.intValue == 1
      else { throw PostMeetingEchoReductionError.unsafePath }
    }
  }
  private func hash(_ url: URL) throws -> String {
    try safe(url, regular: true)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var value = SHA256()
    while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
      try Task.checkCancellation()
      value.update(data: bytes)
    }
    return value.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private func read<T: Decodable>(_ url: URL) throws -> T {
    try safe(url, regular: true)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(contentsOf: url))
  }
  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try safe(url)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func quantize(_ values: [Float], clipped: inout Int64) throws -> [Int16] {
    var result = [Int16](repeating: 0, count: 160)
    for (index, value) in values.enumerated() {
      guard value.isFinite else { throw PostMeetingEchoReductionError.invalidAudio }
      let scaled = (Double(value) * 32768).rounded(.toNearestOrEven)
      if scaled < -32768 || scaled > 32767 { clipped += 1 }
      result[index] = Int16(max(-32768, min(32767, scaled)))
    }
    return result
  }
  private func wavHeader(samples: Int64) -> Data {
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func u16(_ value: UInt16) {
      data.append(UInt8(value & 255))
      data.append(UInt8(value >> 8))
    }
    func u32(_ value: UInt32) {
      u16(UInt16(value & 65535))
      u16(UInt16(value >> 16))
    }
    text("RIFF")
    u32(UInt32(36 + samples * 2))
    text("WAVEfmt ")
    u32(16)
    u16(1)
    u16(1)
    u32(16_000)
    u32(32_000)
    u16(2)
    u16(16)
    text("data")
    u32(UInt32(samples * 2))
    return data
  }
}
