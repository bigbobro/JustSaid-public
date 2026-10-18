import AVFoundation
import CoreMedia
import Foundation

/// Restores system tracks recorded before capture measured its delivery rate.
///
/// Core Audio could deliver 44.1 kHz frames under a 48 kHz label (WeChat calls on
/// speakers; see `SystemAudioDeliveryRateMonitor`). The writer stored those frames as
/// 48 kHz and kept the file on real time by inserting zeros: after a padded block the
/// lag grows by δ = block × (48/44.1 − 1) per block, the second consecutive block past
/// the alignment tolerance is padded by the whole lag, so every `k` blocks of sound are
/// followed by `k × δ` zero frames (23 blocks and about 21 ms with 512-frame blocks).
/// The far side then plays about 8.8% fast in 0.27 s steps, and the post-meeting AEC
/// cannot match it to its echo in the microphone.
///
/// Restoration fits that pad grid to the zero runs the AAC file still shows, cuts the
/// pads, relabels what remains with the delivered rate and writes a 16 kHz mono copy
/// for the AEC reference and the upload. Stretches the grid cannot see (long silence, a
/// phase change) are fitted to real time by trimming or adding silence. Only recordings
/// mislabeled from start to end are restored; the original file is never modified.
enum PostMeetingSystemAudioRestoration {
  static let outputSampleRate = 16_000.0

  /// The writer's behaviour, reconstructed from the capture counters in meeting.json.
  struct Plan: Equatable, Sendable {
    let fileSampleRate: Double
    let deliveredSampleRate: Double
    let blockFrames: Int
    let blocksPerPad: Int
    /// Zero frames per pad, in file frames.
    let padFrames: Double
    /// File frames from one pad to the next.
    let periodFrames: Double
  }

  struct Report: Equatable, Sendable {
    let plan: Plan
    var zeroRuns = 0
    var anchoredRuns = 0
    var regimes = 0
    var modelledPads = 0
    var fittedSegments = 0
    var removedFrames = 0
    var insertedFrames = 0
    var outputSeconds = 0.0
    var elapsedSeconds = 0.0

    /// Numbers only; stored in the stage history.
    var detail: String {
      [
        "status=restored",
        "fileRate=\(Int(plan.fileSampleRate))",
        "deliveredRate=\(Int(plan.deliveredSampleRate))",
        "blockFrames=\(plan.blockFrames)",
        "blocksPerPad=\(plan.blocksPerPad)",
        String(format: "padFrames=%.1f", plan.padFrames),
        "zeroRuns=\(zeroRuns)",
        "anchoredRuns=\(anchoredRuns)",
        "regimes=\(regimes)",
        "modelledPads=\(modelledPads)",
        "fittedSegments=\(fittedSegments)",
        "removedFrames=\(removedFrames)",
        "insertedFrames=\(insertedFrames)",
        String(format: "outputSeconds=%.3f", outputSeconds),
        String(format: "elapsedSeconds=%.3f", elapsedSeconds),
      ].joined(separator: "; ")
    }
  }

  enum RestorationError: LocalizedError {
    case readerFailed
    case invalidPCM
    case noGrid
    case writeFailed(String)

    var errorDescription: String? {
      switch self {
      case .readerFailed: return "无法读取系统声录音"
      case .invalidPCM: return "系统声录音解码结果无效"
      case .noGrid: return "系统声录音里找不到补零的规律"
      case .writeFailed(let detail): return "还原后的系统声写入失败：\(detail)"
      }
    }
  }

  /// IO block sizes seen from Core Audio aggregate devices.
  private static let blockSizes = [64, 128, 256, 441, 480, 512, 960, 1024, 2048, 4096]
  /// Fewer pads than this is ordinary alignment, not a mislabeled rate.
  private static let minimumPadCount: UInt64 = 50
  private static let rateTolerance = 0.002
  private static let periodTolerance = 0.003
  /// AAC keeps inserted digital silence below this amplitude; speech does not stay there.
  private static let silenceAmplitude: Float = 3e-5
  /// A zero run whose centre lies this close to the grid belongs to it.
  private static let anchorToleranceSeconds = 0.005
  private static let envelopeCellSeconds = 0.01

  /// Nil unless the counters show the mislabeled-rate pad pattern over the whole file.
  static func plan(for stats: CaptureLossStats?, fileSampleRate: Double) -> Plan? {
    guard
      let stats, stats.deliveredSampleRate == nil,
      let padCount = stats.alignmentPadCount, padCount >= minimumPadCount,
      let padTotal = stats.alignmentPadFrames, padTotal > 0,
      stats.writtenFrames > 0, fileSampleRate > 0
    else {
      return nil
    }
    // Pads restore real time, so written frames over that span give the delivered rate.
    // A recording that changed rate halfway lands between standard rates and is left
    // alone: relabeling its correct part would slow that part down.
    let written = Double(stats.writtenFrames)
    let timeline = written + Double(padTotal)
    let implied = fileSampleRate * written / timeline
    guard
      let delivered = SystemAudioDeliveryRateMonitor.standardSampleRates.first(where: {
        abs($0 - implied) / $0 <= rateTolerance
      }),
      delivered < fileSampleRate * 0.99
    else {
      return nil
    }
    let observedPeriod = timeline / Double(padCount)
    let tolerance = (IncrementalM4AWriter.alignmentToleranceSeconds * fileSampleRate).rounded()
    var best: (plan: Plan, error: Double, divides: Bool)?
    for block in blockSizes {
      let delta = Double(block) * (fileSampleRate / delivered - 1)
      // The first late block only arms the writer; the next one is padded.
      let blocksPerPad = Int((tolerance / delta).rounded(.down)) + 2
      let period = Double(blocksPerPad * block) * fileSampleRate / delivered
      let error = abs(period - observedPeriod) / observedPeriod
      guard error <= periodTolerance else { continue }
      let divides = stats.writtenFrames % UInt64(block) == 0
      let candidate = Plan(
        fileSampleRate: fileSampleRate,
        deliveredSampleRate: delivered,
        blockFrames: block,
        blocksPerPad: blocksPerPad,
        padFrames: Double(blocksPerPad) * delta,
        periodFrames: period
      )
      if let current = best {
        let better =
          (divides && !current.divides) || (divides == current.divides && error < current.error)
        if better { best = (candidate, error, divides) }
      } else {
        best = (candidate, error, divides)
      }
    }
    return best?.plan
  }

  /// A fresh path beside the other post-meeting upload copies.
  static func makeDestinationURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JustSaid-PostMeeting-Uploads", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
  }

  /// The rate the file is labeled with, which is the rate the writer kept time in.
  static func fileSampleRate(of url: URL) async -> Double? {
    let asset = AVURLAsset(url: url)
    guard
      let track = try? await PostMeetingAudioCompressor.firstAudioTrack(of: asset),
      let description = try? await track.load(.formatDescriptions).first,
      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
      basic.pointee.mSampleRate > 0
    else {
      return nil
    }
    return basic.pointee.mSampleRate
  }

  /// Writes the restored track to `destination` (16 kHz mono float, CAF).
  static func restore(_ source: URL, plan: Plan, to destination: URL) async throws -> Report {
    let started = Date()
    var report = Report(plan: plan)
    let scanned = try await scan(source, plan: plan)
    report.zeroRuns = scanned.centres.count
    let regimes = fitRegimes(scanned.centres, plan: plan)
    guard !regimes.isEmpty else { throw RestorationError.noGrid }
    report.regimes = regimes.count
    report.anchoredRuns = regimes.reduce(0) { $0 + $1.count }
    let edits = makeEdits(regimes, scan: scanned, plan: plan, report: &report)
    try await write(source, edits: edits, plan: plan, to: destination, report: &report)
    report.elapsedSeconds = Date().timeIntervalSince(started)
    return report
  }

  // MARK: - Pass 1: zero runs and energy

  struct Scan {
    var centres: [Double] = []
    /// Mean square per envelope cell, for choosing where silence is trimmed or added.
    var envelope: [Float] = []
    var cellFrames = 1
    var totalFrames = 0
  }

  private static func scan(_ source: URL, plan: Plan) async throws -> Scan {
    let reader = try await MonoReader(url: source, sampleRate: plan.fileSampleRate)
    var scan = Scan()
    scan.cellFrames = max(1, Int(plan.fileSampleRate * envelopeCellSeconds))
    let shortest = Int(plan.padFrames * 0.3)
    let longest = Int(plan.padFrames * 1.3)
    var runStart: Int?
    var position = 0
    var cellSum: Double = 0
    var cellCount = 0
    func closeRun(at end: Int) {
      guard let start = runStart else { return }
      let length = end - start
      if length >= shortest, length <= longest {
        scan.centres.append(Double(start + end) / 2)
      }
      runStart = nil
    }
    while let chunk = try reader.next() {
      try Task.checkCancellation()
      for sample in chunk {
        if abs(sample) < silenceAmplitude {
          if runStart == nil { runStart = position }
        } else {
          closeRun(at: position)
        }
        cellSum += Double(sample) * Double(sample)
        cellCount += 1
        if cellCount == scan.cellFrames {
          scan.envelope.append(Float(cellSum / Double(cellCount)))
          cellSum = 0
          cellCount = 0
        }
        position += 1
      }
    }
    closeRun(at: position)
    if cellCount > 0 { scan.envelope.append(Float(cellSum / Double(cellCount))) }
    scan.totalFrames = position
    return scan
  }

  // MARK: - Grid

  /// One stretch of pads with a constant phase: centre = first + intercept + slope × index.
  struct Regime {
    let firstCentre: Double
    private(set) var indices: [Int] = [0]
    /// Relative to `firstCentre`, which keeps the sums well conditioned.
    private(set) var centres: [Double] = [0]
    private(set) var intercept = 0.0
    private(set) var slope: Double
    private var sums = (x: 0.0, y: 0.0, xx: 0.0, xy: 0.0)

    init(firstCentre: Double, period: Double) {
      self.firstCentre = firstCentre
      slope = period
    }

    var count: Int { indices.count }
    var lastIndex: Int { indices[indices.count - 1] }
    var lastCentre: Double { centres[centres.count - 1] }

    func centre(at index: Int) -> Double { firstCentre + intercept + slope * Double(index) }

    /// The grid index a run at `relative` belongs to, or nil when it is off the grid.
    /// Three anchored runs make the fitted line the prediction; before that, the last
    /// run plus whole periods.
    func index(matching relative: Double, period: Double, tolerance: Double) -> Int? {
      let steps = Int(((relative - lastCentre) / slope).rounded())
      let predicted =
        count >= 3
        ? intercept + slope * Double(lastIndex + steps)
        : lastCentre + Double(steps) * period
      guard steps >= 1, abs(relative - predicted) <= tolerance else { return nil }
      return lastIndex + steps
    }

    mutating func append(index: Int, relativeCentre: Double) {
      indices.append(index)
      centres.append(relativeCentre)
      let x = Double(index)
      sums.x += x
      sums.y += relativeCentre
      sums.xx += x * x
      sums.xy += x * relativeCentre
      guard count >= 3 else { return }
      let n = Double(count)
      let denominator = n * sums.xx - sums.x * sums.x
      guard denominator > 0 else { return }
      slope = (n * sums.xy - sums.x * sums.y) / denominator
      intercept = (sums.y - slope * sums.x) / n
    }

    /// Three rounds of 3σ trimming and a final fit; nil when fewer than three runs stay.
    /// σ has a floor so a clean grid keeps every run.
    func trimmed() -> Regime? {
      var keptIndices = indices
      var keptCentres = centres
      var fit = Self.fit(keptIndices, keptCentres)
      for _ in 0..<3 {
        let residuals = zip(keptIndices, keptCentres).map {
          $1 - (fit.intercept + fit.slope * Double($0))
        }
        let mean = residuals.reduce(0, +) / Double(residuals.count)
        let variance =
          residuals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(residuals.count)
        let limit = 3 * max(variance.squareRoot(), 5)
        let keep = residuals.map { abs($0) <= limit }
        guard keep.contains(false) else { break }
        keptIndices = zip(keptIndices, keep).filter { $0.1 }.map { $0.0 }
        keptCentres = zip(keptCentres, keep).filter { $0.1 }.map { $0.0 }
        guard keptIndices.count >= 3 else { return nil }
        fit = Self.fit(keptIndices, keptCentres)
      }
      guard keptIndices.count >= 3 else { return nil }
      // Re-base so index 0 is the first kept run.
      let first = keptIndices[0]
      var result = self
      result.indices = keptIndices.map { $0 - first }
      result.centres = keptCentres
      result.slope = fit.slope
      result.intercept = fit.intercept + fit.slope * Double(first)
      return result
    }

    private static func fit(_ indices: [Int], _ centres: [Double]) -> (
      intercept: Double, slope: Double
    ) {
      let n = Double(indices.count)
      let meanX = indices.reduce(0.0) { $0 + Double($1) } / n
      let meanY = centres.reduce(0, +) / n
      var sxx = 0.0
      var sxy = 0.0
      for (index, centre) in zip(indices, centres) {
        let dx = Double(index) - meanX
        sxx += dx * dx
        sxy += dx * (centre - meanY)
      }
      let slope = sxx > 0 ? sxy / sxx : 0
      return (meanY - slope * meanX, slope)
    }
  }

  /// Splits the zero-run centres into stretches with one constant pad phase and fits
  /// each with a straight line. Runs off every grid (natural pauses) are ignored.
  static func fitRegimes(_ centres: [Double], plan: Plan) -> [Regime] {
    let tolerance = anchorToleranceSeconds * plan.fileSampleRate
    let period = plan.periodFrames
    var regimes: [Regime] = []
    var current: Regime?
    var index = 0
    func close() {
      if let regime = current?.trimmed() { regimes.append(regime) }
      current = nil
    }
    while index < centres.count {
      let centre = centres[index]
      guard let firstCentre = current?.firstCentre else {
        current = Regime(firstCentre: centre, period: period)
        index += 1
        continue
      }
      // No copy of the regime stays alive here, so appending does not copy its arrays.
      let relative = centre - firstCentre
      if let next = current?.index(matching: relative, period: period, tolerance: tolerance) {
        current?.append(index: next, relativeCentre: relative)
        index += 1
        continue
      }
      // A new phase needs a second run that agrees with it; a lone run is a pause.
      if index + 1 < centres.count {
        let gap = centres[index + 1] - centre
        let nextSteps = Int((gap / period).rounded())
        if nextSteps >= 1, abs(gap - Double(nextSteps) * period) <= tolerance {
          close()
          continue
        }
      }
      index += 1
    }
    close()
    return regimes
  }

  // MARK: - Edits

  enum Edit: Equatable {
    case drop(at: Int, count: Int)
    case insert(at: Int, count: Int)

    var position: Int {
      switch self {
      case .drop(let at, _), .insert(let at, _): return at
      }
    }
  }

  static func makeEdits(
    _ regimes: [Regime], scan: Scan, plan: Plan, report: inout Report
  ) -> [Edit] {
    let ratio = plan.deliveredSampleRate / plan.fileSampleRate
    let chunkFrames = plan.blocksPerPad * plan.blockFrames
    let half = plan.padFrames / 2
    var edits: [Edit] = []
    // File position 0 is real time 0: the writer anchors the first block to the epoch,
    // and every pad ends where real time says the next block belongs.
    var previousEnd = 0.0
    var afterPad = false

    func realFrames(from start: Double, to end: Double) -> Int {
      Int((end * ratio).rounded()) - Int((start * ratio).rounded())
    }

    for regime in regimes {
      for index in 0...regime.lastIndex {
        let centre = regime.centre(at: index)
        let padStart = centre - half
        let padEnd = centre + half
        guard padStart > previousEnd else { continue }
        let start = Int(previousEnd.rounded())
        if afterPad, abs(padStart - previousEnd - Double(chunkFrames)) < Double(plan.blockFrames) / 2
        {
          // Between two pads the writer stored exactly one group of whole blocks.
          let keepEnd = start + chunkFrames
          let next = Int(padEnd.rounded())
          if next > keepEnd {
            edits.append(.drop(at: keepEnd, count: next - keepEnd))
            report.modelledPads += 1
          }
        } else {
          let end = Int(padStart.rounded())
          fitSegment(
            start: start, end: end, target: realFrames(from: previousEnd, to: padEnd),
            scan: scan, edits: &edits, report: &report)
          let next = Int(padEnd.rounded())
          if next > end { edits.append(.drop(at: end, count: next - end)) }
        }
        previousEnd = padEnd
        afterPad = true
      }
    }
    // After the last pad the file holds fewer than one group of blocks unless the grid
    // was lost earlier; only a longer tail can hide pads that need fitting.
    let tail = Double(scan.totalFrames) - previousEnd
    if tail >= plan.periodFrames {
      fitSegment(
        start: Int(previousEnd.rounded()), end: scan.totalFrames,
        target: realFrames(from: previousEnd, to: Double(scan.totalFrames)),
        scan: scan, edits: &edits, report: &report)
    }
    return edits.sorted { $0.position < $1.position }
  }

  /// Makes `[start, end)` hold `target` frames by trimming or adding silence where the
  /// envelope is quietest; the grid cannot see the pads that fall in silence.
  private static func fitSegment(
    start: Int, end: Int, target: Int, scan: Scan, edits: inout [Edit], report: inout Report
  ) {
    let length = max(0, end - start)
    let excess = length - max(0, target)
    guard excess != 0 else { return }
    report.fittedSegments += 1
    if excess >= length {
      if length > 0 { edits.append(.drop(at: start, count: length)) }
      report.removedFrames += length
      return
    }
    if length == 0 {
      edits.append(.insert(at: start, count: -excess))
      report.insertedFrames += -excess
      return
    }
    let middle = quietestPosition(start: start, end: end, width: max(1, excess), scan: scan)
    if excess > 0 {
      let dropStart = min(max(start, middle - excess / 2), end - excess)
      edits.append(.drop(at: dropStart, count: excess))
      report.removedFrames += excess
    } else {
      edits.append(.insert(at: middle, count: -excess))
      report.insertedFrames += -excess
    }
  }

  private static func quietestPosition(start: Int, end: Int, width: Int, scan: Scan) -> Int {
    let cell = scan.cellFrames
    let firstCell = start / cell
    let lastCell = min(scan.envelope.count, (end + cell - 1) / cell)
    let span = max(1, (width + cell - 1) / cell)
    guard lastCell - firstCell > span else { return (start + end) / 2 }
    var sum = scan.envelope[firstCell..<(firstCell + span)].reduce(0, +)
    var bestSum = sum
    var bestCell = firstCell
    for cellIndex in (firstCell + 1)...(lastCell - span) {
      sum += scan.envelope[cellIndex + span - 1] - scan.envelope[cellIndex - 1]
      if sum < bestSum {
        bestSum = sum
        bestCell = cellIndex
      }
    }
    let middle = bestCell * cell + span * cell / 2
    return min(max(start, middle), end)
  }

  // MARK: - Pass 2: apply, relabel, resample, write

  private static func write(
    _ source: URL, edits: [Edit], plan: Plan, to destination: URL, report: inout Report
  ) async throws {
    let reader = try await MonoReader(url: source, sampleRate: plan.fileSampleRate)
    guard
      let delivered = AVAudioFormat(
        standardFormatWithSampleRate: plan.deliveredSampleRate, channels: 1),
      let output = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: 1)
    else {
      throw RestorationError.writeFailed("无法创建音频格式")
    }
    let file: AVAudioFile
    do {
      file = try AVAudioFile(forWriting: destination, settings: output.settings)
    } catch {
      throw RestorationError.writeFailed(error.localizedDescription)
    }
    let converter = PCMBufferConverter(outputFormat: output)
    let flushFrames = 16_384
    var pending: [Float] = []
    pending.reserveCapacity(flushFrames * 2)
    var writtenFrames = 0

    func flush() throws {
      guard !pending.isEmpty else { return }
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: delivered, frameCapacity: AVAudioFrameCount(pending.count))
      else {
        throw RestorationError.writeFailed("无法分配缓冲区")
      }
      buffer.frameLength = AVAudioFrameCount(pending.count)
      pending.withUnsafeBufferPointer {
        buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count)
      }
      pending.removeAll(keepingCapacity: true)
      let converted = try converter.convert(buffer)
      guard converted.frameLength > 0 else { return }
      do {
        try file.write(from: converted)
      } catch {
        throw RestorationError.writeFailed(error.localizedDescription)
      }
      writtenFrames += Int(converted.frameLength)
    }

    var editIndex = 0
    var dropUntil = 0
    var chunkStart = 0
    while let chunk = try reader.next() {
      try Task.checkCancellation()
      let chunkEnd = chunkStart + chunk.count
      var cursor = chunkStart
      while cursor < chunkEnd {
        if cursor < dropUntil {
          cursor = min(dropUntil, chunkEnd)
          continue
        }
        if editIndex < edits.count, edits[editIndex].position <= cursor {
          switch edits[editIndex] {
          case .drop(let at, let count):
            dropUntil = max(dropUntil, at + count)
          case .insert(_, let count):
            pending.append(contentsOf: repeatElement(0, count: count))
          }
          editIndex += 1
          continue
        }
        let stop = min(chunkEnd, editIndex < edits.count ? edits[editIndex].position : chunkEnd)
        pending.append(contentsOf: chunk[(cursor - chunkStart)..<(stop - chunkStart)])
        cursor = stop
        if pending.count >= flushFrames { try flush() }
      }
      chunkStart = chunkEnd
    }
    // Inserts at the very end, then a little silence so the converter releases its tail.
    for edit in edits[editIndex...] {
      if case .insert(_, let count) = edit {
        pending.append(contentsOf: repeatElement(0, count: count))
      }
    }
    pending.append(contentsOf: repeatElement(0, count: Int(plan.deliveredSampleRate / 100)))
    try flush()
    report.outputSeconds = Double(writtenFrames) / outputSampleRate
  }

  /// Mono float at a chosen rate; downmixing and any resampling happen in the decoder.
  private final class MonoReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(url: URL, sampleRate: Double) async throws {
      let asset = AVURLAsset(url: url)
      guard let track = try await PostMeetingAudioCompressor.firstAudioTrack(of: asset) else {
        throw RestorationError.readerFailed
      }
      reader = try AVAssetReader(asset: asset)
      output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ])
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { throw RestorationError.readerFailed }
      reader.add(output)
      guard reader.startReading() else { throw RestorationError.readerFailed }
    }

    deinit { if reader.status == .reading { reader.cancelReading() } }

    /// Next decoded chunk, or nil at the end of the track.
    func next() throws -> [Float]? {
      while true {
        guard let sample = output.copyNextSampleBuffer() else {
          guard reader.status == .completed else { throw RestorationError.readerFailed }
          return nil
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
          throw RestorationError.invalidPCM
        }
        let bytes = CMBlockBufferGetDataLength(block)
        guard bytes == CMSampleBufferGetNumSamples(sample) * MemoryLayout<Float>.size else {
          throw RestorationError.invalidPCM
        }
        guard bytes > 0 else { continue }
        var samples = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes {
          CMBlockBufferCopyDataBytes(
            block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { throw RestorationError.invalidPCM }
        return samples
      }
    }
  }
}
