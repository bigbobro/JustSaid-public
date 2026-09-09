import Foundation

public enum LiveTranscriptReadError: LocalizedError, Sendable {
  case invalidRecord(line: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidRecord(let line):
      return "实时速记文件第 \(line) 行无法解析"
    }
  }
}

public actor LiveTranscriptWriter {
  private struct Record: Codable {
    let t0: TimeInterval
    let t1: TimeInterval
    let source: AudioSource
    let text: String
  }

  private let fileURL: URL
  private let encoder: JSONEncoder
  private var finalSegments: [TranscriptSegment] = []

  public init(fileURL: URL) throws {
    self.fileURL = fileURL
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: fileURL, options: .atomic)
  }

  public func append(_ segment: TranscriptSegment) throws {
    guard segment.isFinal else {
      return
    }

    let alreadyStored = finalSegments.contains {
      $0.source == segment.source
        && $0.t0 == segment.t0
        && $0.t1 == segment.t1
        && $0.text == segment.text
    }
    guard !alreadyStored else {
      return
    }

    finalSegments.append(segment)
    finalSegments.sort(by: Self.areInTimelineOrder)
    try writeAllSegments()
  }

  public func finish() throws {
    try writeAllSegments()
  }

  public static func read(from fileURL: URL) throws -> [TranscriptSegment] {
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    return try data.split(separator: 0x0A).enumerated().map { index, line in
      let record: Record
      do {
        record = try decoder.decode(Record.self, from: Data(line))
      } catch {
        throw LiveTranscriptReadError.invalidRecord(line: index + 1)
      }
      return TranscriptSegment(
        t0: record.t0,
        t1: record.t1,
        text: record.text,
        isFinal: true,
        source: record.source
      )
    }
  }

  private func writeAllSegments() throws {
    var data = Data()
    for segment in finalSegments {
      let record = Record(
        t0: segment.t0,
        t1: segment.t1,
        source: segment.source,
        text: segment.text
      )
      data.append(try encoder.encode(record))
      data.append(0x0A)
    }
    try data.write(to: fileURL, options: .atomic)
  }

  private static func areInTimelineOrder(
    _ lhs: TranscriptSegment,
    _ rhs: TranscriptSegment
  ) -> Bool {
    if lhs.t0 != rhs.t0 {
      return lhs.t0 < rhs.t0
    }
    if lhs.t1 != rhs.t1 {
      return lhs.t1 < rhs.t1
    }
    return lhs.source.rawValue < rhs.source.rawValue
  }
}
