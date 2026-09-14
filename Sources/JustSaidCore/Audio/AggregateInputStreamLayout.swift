import AVFAudio
import CoreAudio
import Foundation

/// The complete, immutable snapshot of a stream's VirtualFormat.
///
/// `AudioStreamBasicDescription` is a C value type, but keeping the snapshot in a
/// Swift value gives the capture plan an explicit provenance boundary.  In
/// particular, the sample rate and byte layout cannot be lost while selecting a
/// stream by channel count.
public struct AggregateInputStreamFormat: Equatable, Sendable {
  public let sampleRate: Double
  public let formatID: UInt32
  public let formatFlags: UInt32
  public let bytesPerPacket: UInt32
  public let framesPerPacket: UInt32
  public let bytesPerFrame: UInt32
  public let channelsPerFrame: UInt32
  public let bitsPerChannel: UInt32
  public let reserved: UInt32

  public init(_ description: AudioStreamBasicDescription) {
    sampleRate = description.mSampleRate
    formatID = description.mFormatID
    formatFlags = description.mFormatFlags
    bytesPerPacket = description.mBytesPerPacket
    framesPerPacket = description.mFramesPerPacket
    bytesPerFrame = description.mBytesPerFrame
    channelsPerFrame = description.mChannelsPerFrame
    bitsPerChannel = description.mBitsPerChannel
    reserved = description.mReserved
  }

  public var audioStreamBasicDescription: AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: formatID,
      mFormatFlags: AudioFormatFlags(formatFlags),
      mBytesPerPacket: bytesPerPacket,
      mFramesPerPacket: framesPerPacket,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: channelsPerFrame,
      mBitsPerChannel: bitsPerChannel,
      mReserved: reserved
    )
  }

  public var isInterleaved: Bool {
    (formatFlags & kAudioFormatFlagIsNonInterleaved) == 0
  }

  public var bufferCount: Int {
    isInterleaved ? 1 : Int(channelsPerFrame)
  }

  public func makeAVAudioFormat() -> AVAudioFormat? {
    var description = audioStreamBasicDescription
    return AVAudioFormat(streamDescription: &description)
  }
}

/// A stream descriptor and the ABL range that belongs to it.
///
/// The selected stream ID, full VirtualFormat and ABL range travel together in
/// this value.  This prevents a later callback from pairing one stream's bytes
/// with another stream's format when VPIO inserts or removes its reference
/// stream.
public struct AggregateInputStreamSelection: Equatable, Sendable {
  public let streamID: AudioStreamID
  public let virtualFormat: AggregateInputStreamFormat
  public let bufferRange: Range<Int>

  public init(
    streamID: AudioStreamID,
    virtualFormat: AggregateInputStreamFormat,
    bufferRange: Range<Int>
  ) {
    self.streamID = streamID
    self.virtualFormat = virtualFormat
    self.bufferRange = bufferRange
  }
}

/// One immutable system-capture format plan. The tap snapshot is retained only
/// as the selection hint; `inputFormat` always comes from the selected aggregate
/// stream VirtualFormat and its matching ABL range.
public struct SystemAudioCaptureFormatPlan: Equatable, Sendable {
  public let tapFormat: AggregateInputStreamFormat
  public let streamLayout: AggregateInputStreamLayout

  public var inputFormat: AggregateInputStreamFormat {
    // Factory construction guarantees this is present.
    streamLayout.selectedStream!.virtualFormat
  }

  fileprivate init(
    tapFormat: AggregateInputStreamFormat,
    streamLayout: AggregateInputStreamLayout
  ) {
    self.tapFormat = tapFormat
    self.streamLayout = streamLayout
  }
}

/// Shared production plan factory. `SystemAudioCapture` and synthetic timing
/// verification both call this seam so a regression that falls back to the
/// pre-aggregate tap ASBD cannot hide behind a channel-only mapper test.
public enum SystemAudioCaptureFormatPlanFactory {
  public static func make(
    tapFormat: AggregateInputStreamFormat,
    streams: [AggregateInputStreamMapper.StreamDescriptor],
    bufferChannelCounts: [UInt32]
  ) -> SystemAudioCaptureFormatPlan? {
    guard
      let layout = AggregateInputStreamMapper.validatedLayout(
        streams: streams,
        bufferChannelCounts: bufferChannelCounts,
        tapChannelCount: tapFormat.channelsPerFrame
      ),
      layout.selectedStream != nil
    else {
      return nil
    }
    return SystemAudioCaptureFormatPlan(
      tapFormat: tapFormat,
      streamLayout: layout
    )
  }

  /// Production throwing plan seam. It owns the complete raw-descriptor
  /// validation and expected-identity classification before channel-based
  /// selection, so Core Audio queries and synthetic verification cannot drift
  /// into separate implementations of the F1 failure boundary.
  public static func makeValidated(
    tapFormat: AggregateInputStreamFormat,
    streams: [AggregateInputStreamMapper.StreamDescriptor],
    bufferChannelCounts: [UInt32],
    expectedStreamID: AudioStreamID? = nil,
    expectedVirtualFormat: AggregateInputStreamFormat? = nil
  ) throws -> SystemAudioCaptureFormatPlan {
    try validateExpectedStreamFormat(
      streams: streams,
      bufferChannelCounts: bufferChannelCounts,
      expectedStreamID: expectedStreamID,
      expectedVirtualFormat: expectedVirtualFormat
    )
    guard
      let plan = make(
        tapFormat: tapFormat,
        streams: streams,
        bufferChannelCounts: bufferChannelCounts
      )
    else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "校验聚合设备输入流 VirtualFormat 与 AudioBufferList 范围",
        status: kAudioHardwareUnsupportedOperationError
      )
    }
    return plan
  }

  /// Classify a change to the stream that was published for the current
  /// activation before channel-based selection runs. A missing stream is a
  /// recoverable topology transition; a still-present stream with a different
  /// complete ASBD is an incompatible input-format change and must retire the
  /// activation.
  private static func validateExpectedStreamFormat(
    streams: [AggregateInputStreamMapper.StreamDescriptor],
    bufferChannelCounts: [UInt32],
    expectedStreamID: AudioStreamID?,
    expectedVirtualFormat: AggregateInputStreamFormat?
  ) throws {
    // Only classify a format change after the descriptor/ABL snapshot is
    // coherent. A zero/unsupported ASBD or an ABL mismatch is a transient
    // topology read and must stay recoverable through the generic factory path.
    guard
      AggregateInputStreamMapper.validatedBufferRanges(
        streams: streams,
        bufferChannelCounts: bufferChannelCounts
      ) != nil
    else {
      return
    }
    guard let expectedStreamID, let expectedVirtualFormat,
      let current = streams.first(where: { $0.streamID == expectedStreamID })
    else {
      return
    }
    guard current.virtualFormat == expectedVirtualFormat else {
      throw IncrementalM4AWriterError.inputFormatMismatch
    }
  }

  /// The fixed writer format is the rebuild compatibility boundary. Keep this
  /// comparison in the production seam so verification can exercise the exact
  /// guard used by `SystemAudioCapture`, rather than comparing two sample-rate
  /// labels in isolation.
  public static func writerFormatMatches(
    candidate: AVAudioFormat,
    existing: AVAudioFormat
  ) -> Bool {
    candidate == existing
  }
}

/// Safety invariant: mutable layout/retirement state is queue-confined to the
/// existing system callbackQueue, including setup/teardown. Retired IO/listener
/// closures retain this same object, never a replacement activation's layout.
/// Public only for verification to exercise the production admission path.
public final class SystemAudioCaptureInputState: @unchecked Sendable {
  private let expectedFormat: AggregateInputStreamFormat
  /// The stream identity confirmed by the previous successful publication.
  /// Keeping this alongside the expected ASBD lets the next query classify a
  /// same-ID format change before channel-based selection can discard it.
  public private(set) var selectedStreamID: AudioStreamID?
  public private(set) var layout: AggregateInputStreamLayout?
  public private(set) var isRetired = false

  public init(
    expectedFormat: AggregateInputStreamFormat,
    selectedStreamID: AudioStreamID? = nil
  ) {
    self.expectedFormat = expectedFormat
    self.selectedStreamID = selectedStreamID
  }

  public func retire() {
    isRetired = true
    layout = nil
  }

  /// Invalidate before querying. Publish only the exact selection whose format
  /// listener was installed, after a second coherent read. Query/topology races
  /// leave a recoverable empty cache; incompatible formats or failed monitoring
  /// retire this activation until the existing rebuild path creates a new one.
  public func refresh(
    query: () throws -> SystemAudioCaptureFormatPlan,
    monitor: (AudioStreamID) throws -> Void
  ) throws {
    try refresh(
      queryWithExpectedSelection: { _, _ in try query() },
      monitor: monitor
    )
  }

  /// Refresh using the identity expected for each read. The second read gets
  /// the candidate's selected ID without mutating the committed activation
  /// identity; this catches a replacement stream that changes format during
  /// the monitor-registration window while keeping the old ID on failure.
  public func refresh(
    queryWithExpectedSelection:
      (_ expectedStreamID: AudioStreamID?, _ expectedVirtualFormat: AggregateInputStreamFormat)
      throws -> SystemAudioCaptureFormatPlan,
    monitor: (AudioStreamID) throws -> Void
  ) throws {
    guard !isRetired else { return }
    layout = nil
    do {
      let candidate = try queryWithExpectedSelection(selectedStreamID, expectedFormat)
      try requireExpectedFormat(candidate)
      guard let selection = candidate.streamLayout.selectedStream else { return }
      do {
        try monitor(selection.streamID)
      } catch {
        retire()
        throw error
      }
      let verified = try queryWithExpectedSelection(selection.streamID, expectedFormat)
      try requireExpectedFormat(verified)
      guard candidate.streamLayout == verified.streamLayout else {
        throw AudioCaptureError.systemAudioTapFailed(
          operation: "监听注册期间系统音频输入流选择发生变化",
          status: kAudioHardwareIllegalOperationError
        )
      }
      // A synchronous injected registrar may retire this activation. The real
      // callbacks are serialized, but neither path may revive retired admission.
      guard !isRetired else { return }
      // The ID is committed only with the same publication transaction as the
      // verified layout. A transient query/range race therefore keeps the old
      // identity and can recover on the next notification.
      selectedStreamID = verified.streamLayout.selectedStream?.streamID
      layout = verified.streamLayout
    } catch let error as IncrementalM4AWriterError {
      if case .inputFormatMismatch = error {
        retire()
      }
      throw error
    }
  }

  public func makeOwned(
    from audioBufferList: UnsafePointer<AudioBufferList>
  ) -> AVAudioPCMBuffer? {
    guard !isRetired, let layout else { return nil }
    return AggregateInputStreamPCMBuffer.makeOwned(from: audioBufferList, layout: layout)
  }

  private func requireExpectedFormat(_ plan: SystemAudioCaptureFormatPlan) throws {
    guard plan.inputFormat == expectedFormat else {
      throw IncrementalM4AWriterError.inputFormatMismatch
    }
  }
}

/// 聚合设备输入侧「流 → AudioBufferList 缓冲区间」映射。
///
/// VPIO 启动后，聚合设备输入常变为 `[4ch 参考流, 2ch tap 流]`；回调必须按流身份
/// 取 tap 区间，不能假定 first / 单缓冲恒定（见 task 08-05 探针结论）。
public struct AggregateInputStreamLayout: Equatable, Sendable {
  /// 每个输入流的声道数（与 `kAudioDevicePropertyStreams` 顺序一致）。
  public let streamChannelCounts: [UInt32]
  /// tap 流在 stream 列表中的下标。
  public let tapStreamIndex: Int
  /// 该流在 interleaved 假设下占据的 buffer 下标区间（每流 1 个 buffer）。
  public let tapBufferRange: Range<Int>
  /// 期望的总 buffer 数（interleaved 时 = 流数）。
  public let expectedBufferCount: Int
  /// The selected stream's complete identity/format/range. Legacy synthetic
  /// layouts made from channel counts have no stream identity and leave this nil.
  public let selectedStream: AggregateInputStreamSelection?

  public init(
    streamChannelCounts: [UInt32],
    tapStreamIndex: Int,
    tapBufferRange: Range<Int>,
    expectedBufferCount: Int,
    selectedStream: AggregateInputStreamSelection? = nil
  ) {
    self.streamChannelCounts = streamChannelCounts
    self.tapStreamIndex = tapStreamIndex
    self.tapBufferRange = tapBufferRange
    self.expectedBufferCount = expectedBufferCount
    self.selectedStream = selectedStream
  }

  /// 本帧 ABL 的 buffer 数量是否与缓存布局一致。
  public func matchesBufferCount(_ count: Int) -> Bool {
    count == expectedBufferCount
  }

  /// Validate the ABL shape against the cached selected stream. This is safe in
  /// the realtime callback because it only reads the already supplied ABL; it
  /// never performs a Core Audio property query.
  func matchesBufferShape(_ source: UnsafeMutableAudioBufferListPointer) -> Bool {
    guard source.count == expectedBufferCount else {
      return false
    }
    guard let selectedStream else {
      return tapBufferRange.lowerBound >= 0 && tapBufferRange.upperBound <= source.count
    }
    let range = selectedStream.bufferRange
    guard range.lowerBound >= 0, range.upperBound <= source.count else {
      return false
    }
    let format = selectedStream.virtualFormat
    if format.isInterleaved {
      guard range.count == 1 else { return false }
      return source[range.lowerBound].mNumberChannels == format.channelsPerFrame
    }
    guard range.count == Int(format.channelsPerFrame) else {
      return false
    }
    return range.allSatisfy { source[$0].mNumberChannels == 1 }
  }
}

/// Copy a selected ABL range into an owned PCM buffer. The system callback's
/// ABL is only valid for the callback duration; this helper is the production
/// copy boundary and is also used by the synthetic plan verification.
public enum AggregateInputStreamPCMBuffer {
  /// Copy the selected stream range using the format carried by the same
  /// validated layout. A layout without stream provenance is intentionally
  /// rejected; production code must never pair a legacy channel-only layout
  /// with a PCM format.
  public static func makeOwned(
    from audioBufferList: UnsafePointer<AudioBufferList>,
    layout: AggregateInputStreamLayout
  ) -> AVAudioPCMBuffer? {
    guard
      let selected = layout.selectedStream,
      let format = selected.virtualFormat.makeAVAudioFormat()
    else {
      return nil
    }
    guard
      format.streamDescription.pointee.mBytesPerFrame > 0,
      layout.matchesBufferShape(
        UnsafeMutableAudioBufferListPointer(
          UnsafeMutablePointer(mutating: audioBufferList)
        )
      )
    else {
      return nil
    }
    let sourceBufferRange = selected.bufferRange
    let source = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: audioBufferList)
    )
    guard
      sourceBufferRange.lowerBound >= 0,
      sourceBufferRange.upperBound <= source.count
    else {
      return nil
    }

    let first = source[sourceBufferRange.lowerBound]
    let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
    guard bytesPerFrame > 0, first.mDataByteSize % bytesPerFrame == 0 else {
      return nil
    }
    let frameLength = first.mDataByteSize / bytesPerFrame
    guard
      frameLength > 0,
      let copy = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameLength)
      )
    else {
      return nil
    }
    copy.frameLength = AVAudioFrameCount(frameLength)
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard destination.count == sourceBufferRange.count else {
      return nil
    }
    for (offset, sourceIndex) in sourceBufferRange.enumerated() {
      let sourceBuffer = source[sourceIndex]
      let destinationBuffer = destination[offset]
      guard
        sourceBuffer.mDataByteSize == destinationBuffer.mDataByteSize,
        let sourceData = sourceBuffer.mData,
        let destinationData = destinationBuffer.mData
      else {
        return nil
      }
      memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
    }
    return copy
  }
}

/// 纯函数：从各输入流声道数 + 期望 tap 声道数，算出 tap 缓冲区间。
///
/// 识别规则（可单测）：
/// 1. 仅一流入选 → 该流即 tap（AEC 关 / VPIO 前的稳态）。
/// 2. 多流时优先选声道数 == `tapChannelCount` 的流；多个匹配时取**最后一个**
///    （探针观测：VPIO 参考流在前、tap 在后）。
/// 3. 没有任何流匹配声道数 → 回退最后一个流（仍可能对，调用方再用 ABL 形状校验）。
public enum AggregateInputStreamMapper {
  /// Full stream information read from an aggregate device after creation.
  public struct StreamDescriptor: Equatable, Sendable {
    public let streamID: AudioStreamID
    public let virtualFormat: AggregateInputStreamFormat

    public init(
      streamID: AudioStreamID,
      virtualFormat: AggregateInputStreamFormat
    ) {
      self.streamID = streamID
      self.virtualFormat = virtualFormat
    }
  }

  /// Build a capture layout from one coherent stream query and one coherent ABL
  /// shape query. The selected stream's ID, full ASBD and range are committed as
  /// one `AggregateInputStreamSelection`.
  ///
  /// An incompatible topology is rejected; the existing last channel-match
  /// selection policy is retained. The legacy channel-count helper
  /// below remains available for old verification fixtures, but production capture
  /// uses this validating entry point.
  public static func validatedLayout(
    streams: [StreamDescriptor],
    bufferChannelCounts: [UInt32],
    tapChannelCount: UInt32
  ) -> AggregateInputStreamLayout? {
    guard
      let ranges = validatedBufferRanges(
        streams: streams,
        bufferChannelCounts: bufferChannelCounts
      )
    else {
      return nil
    }

    let matching = streams.indices.filter {
      streams[$0].virtualFormat.channelsPerFrame == tapChannelCount
    }
    guard let selectedIndex = matching.last else {
      return nil
    }
    let selected = AggregateInputStreamSelection(
      streamID: streams[selectedIndex].streamID,
      virtualFormat: streams[selectedIndex].virtualFormat,
      bufferRange: ranges[selectedIndex]
    )
    return AggregateInputStreamLayout(
      streamChannelCounts: streams.map { $0.virtualFormat.channelsPerFrame },
      tapStreamIndex: selectedIndex,
      tapBufferRange: ranges[selectedIndex],
      expectedBufferCount: bufferChannelCounts.count,
      selectedStream: selected
    )
  }

  /// Validate descriptor ASBDs and their complete ABL shape without applying
  /// the tap channel hint. This lets the production query distinguish a
  /// coherent known-stream format change from a transient/invalid snapshot
  /// before the channel-based factory selection can return nil.
  static func validatedBufferRanges(
    streams: [StreamDescriptor],
    bufferChannelCounts: [UInt32]
  ) -> [Range<Int>]? {
    guard !streams.isEmpty, !bufferChannelCounts.isEmpty else {
      return nil
    }

    var ranges: [Range<Int>] = []
    ranges.reserveCapacity(streams.count)
    var bufferIndex = 0
    for stream in streams {
      let format = stream.virtualFormat
      guard
        format.sampleRate.isFinite,
        format.sampleRate > 0,
        format.channelsPerFrame > 0,
        format.bytesPerFrame > 0,
        format.bitsPerChannel > 0,
        format.framesPerPacket == 1,
        format.bytesPerPacket == format.bytesPerFrame,
        format.formatID == kAudioFormatLinearPCM
      else {
        return nil
      }
      // CoreAudioBaseTypes.h: LPCM packets contain one frame; per-frame
      // byte fields cover all interleaved channels or one planar channel.
      // Each equal-width sample must fit its valid bits. Unpacked PCM may
      // retain padding, so do not restrict this to native Float32 formats.
      let storedChannels = format.isInterleaved ? format.channelsPerFrame : 1
      guard format.bytesPerFrame % storedChannels == 0 else { return nil }
      let storageBits = UInt64(format.bytesPerFrame / storedChannels) * 8
      guard UInt64(format.bitsPerChannel) <= storageBits else { return nil }
      if (format.formatFlags & kAudioFormatFlagIsPacked) != 0,
        UInt64(format.bitsPerChannel) != storageBits
      {
        return nil
      }
      let count = format.bufferCount
      guard count > 0, bufferIndex <= bufferChannelCounts.count - count else {
        return nil
      }
      let range = bufferIndex..<(bufferIndex + count)
      if format.isInterleaved {
        guard bufferChannelCounts[bufferIndex] == format.channelsPerFrame else {
          return nil
        }
      } else {
        guard range.allSatisfy({ bufferChannelCounts[$0] == 1 }) else {
          return nil
        }
      }
      ranges.append(range)
      bufferIndex += count
    }
    guard bufferIndex == bufferChannelCounts.count else {
      return nil
    }
    return ranges
  }

  public static func layout(
    streamChannelCounts: [UInt32],
    tapChannelCount: UInt32
  ) -> AggregateInputStreamLayout? {
    guard !streamChannelCounts.isEmpty else {
      return nil
    }

    let tapStreamIndex: Int
    if streamChannelCounts.count == 1 {
      tapStreamIndex = 0
    } else {
      let matching = streamChannelCounts.enumerated().compactMap { index, channels -> Int? in
        channels == tapChannelCount ? index : nil
      }
      if let lastMatch = matching.last {
        tapStreamIndex = lastMatch
      } else {
        tapStreamIndex = streamChannelCounts.count - 1
      }
    }

    // interleaved：每流一个 AudioBuffer，区间即 [streamIndex, streamIndex+1)。
    let range = tapStreamIndex..<(tapStreamIndex + 1)
    return AggregateInputStreamLayout(
      streamChannelCounts: streamChannelCounts,
      tapStreamIndex: tapStreamIndex,
      tapBufferRange: range,
      expectedBufferCount: streamChannelCounts.count
    )
  }

  /// 仅凭本帧 ABL 各 buffer 的 `mNumberChannels` 解析 tap 下标（IO 回调内失配兜底，
  /// 不做 Core Audio 属性查询）。
  ///
  /// - 单缓冲：恒为 0（与启动时立体声 tap 一致）。
  /// - 多缓冲：选 `mNumberChannels == tapChannelCount` 的最后一个；无匹配则 nil。
  public static func tapBufferIndex(
    bufferChannelCounts: [UInt32],
    tapChannelCount: UInt32
  ) -> Int? {
    guard !bufferChannelCounts.isEmpty else {
      return nil
    }
    if bufferChannelCounts.count == 1 {
      return 0
    }
    let matching = bufferChannelCounts.enumerated().compactMap { index, channels -> Int? in
      channels == tapChannelCount ? index : nil
    }
    return matching.last
  }

  /// 用缓存布局或 ABL 形状解析本帧应拷贝的 buffer 区间。
  ///
  /// 1. 缓存布局 buffer 数匹配 → 用缓存区间；
  /// 2. 否则按 ABL 声道形态即时重选；
  /// 3. 仍失败 → nil。
  public static func resolveBufferRange(
    bufferChannelCounts: [UInt32],
    tapChannelCount: UInt32,
    cached: AggregateInputStreamLayout?
  ) -> Range<Int>? {
    if let cached, cached.matchesBufferCount(bufferChannelCounts.count) {
      let range = cached.tapBufferRange
      guard range.lowerBound >= 0, range.upperBound <= bufferChannelCounts.count else {
        return nil
      }
      return range
    }
    guard
      let index = tapBufferIndex(
        bufferChannelCounts: bufferChannelCounts,
        tapChannelCount: tapChannelCount
      )
    else {
      return nil
    }
    return index..<(index + 1)
  }
}

// MARK: - Core Audio 查询（仅启动 / 布局监听路径调用，禁止进 IO 热路径常态）

enum AggregateInputStreamQuery {
  static func capturePlan(
    deviceID: AudioDeviceID,
    tapFormat: AggregateInputStreamFormat,
    expectedStreamID: AudioStreamID? = nil,
    expectedVirtualFormat: AggregateInputStreamFormat? = nil
  ) throws -> SystemAudioCaptureFormatPlan {
    let streams = try readStreamDescriptors(deviceID: deviceID)
    let bufferChannelCounts = try inputBufferChannelCounts(deviceID: deviceID)
    // Check the previously published identity before channel-based factory
    // selection. If that stream still exists but its complete ASBD changed,
    // returning the factory's generic "no match" error would leave the old
    // activation recoverable and could revive stale PCM on a later callback.
    return try SystemAudioCaptureFormatPlanFactory.makeValidated(
      tapFormat: tapFormat,
      streams: streams,
      bufferChannelCounts: bufferChannelCounts,
      expectedStreamID: expectedStreamID,
      expectedVirtualFormat: expectedVirtualFormat
    )
  }

  private static func readStreamDescriptors(
    deviceID: AudioDeviceID
  ) throws -> [AggregateInputStreamMapper.StreamDescriptor] {
    try inputStreamIDs(deviceID: deviceID).map { id in
      AggregateInputStreamMapper.StreamDescriptor(
        streamID: id,
        virtualFormat: try streamVirtualFormat(streamID: id)
      )
    }
  }

  private static func inputStreamIDs(deviceID: AudioDeviceID) throws -> [AudioStreamID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    try requireNoError(status, operation: "读取聚合设备输入流列表大小")
    guard size % UInt32(MemoryLayout<AudioStreamID>.size) == 0 else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "解析聚合设备输入流列表大小",
        status: kAudioHardwareBadPropertySizeError
      )
    }
    let count = Int(size) / MemoryLayout<AudioStreamID>.size
    guard count > 0 else {
      return []
    }
    var streamIDs = [AudioStreamID](repeating: 0, count: count)
    var returnedSize = size
    status = streamIDs.withUnsafeMutableBufferPointer { buffer in
      return AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &returnedSize,
        buffer.baseAddress!
      )
    }
    try requireNoError(status, operation: "读取聚合设备输入流列表")
    guard returnedSize <= size, returnedSize % UInt32(MemoryLayout<AudioStreamID>.size) == 0 else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "输入流列表读回大小无效", status: kAudioHardwareBadPropertySizeError
      )
    }
    return Array(streamIDs.prefix(Int(returnedSize) / MemoryLayout<AudioStreamID>.size))
  }

  private static func streamVirtualFormat(
    streamID: AudioStreamID
  ) throws -> AggregateInputStreamFormat {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioStreamPropertyVirtualFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(
      streamID,
      &address,
      0,
      nil,
      &size,
      &asbd
    )
    try requireNoError(status, operation: "读取输入流 VirtualFormat")
    guard size >= UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "读取输入流 VirtualFormat 大小不足",
        status: kAudioHardwareBadPropertySizeError
      )
    }
    return AggregateInputStreamFormat(asbd)
  }

  private static func inputBufferChannelCounts(
    deviceID: AudioDeviceID
  ) throws -> [UInt32] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    try requireNoError(status, operation: "读取聚合设备输入缓冲布局大小")
    guard size >= UInt32(MemoryLayout<UInt32>.size) else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "读取聚合设备输入缓冲布局大小不足",
        status: kAudioHardwareBadPropertySizeError
      )
    }
    let capacity = Int(size)
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: capacity,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      raw
    )
    try requireNoError(status, operation: "读取聚合设备输入缓冲布局")
    let bufferOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
    guard Int(size) <= capacity, Int(size) >= bufferOffset else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "输入缓冲布局读回大小无效", status: kAudioHardwareBadPropertySizeError
      )
    }
    let pointer = raw.assumingMemoryBound(to: AudioBufferList.self)
    guard
      Int(pointer.pointee.mNumberBuffers) <= (Int(size) - bufferOffset)
        / MemoryLayout<AudioBuffer>.size
    else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "输入缓冲布局数量超出返回字节", status: kAudioHardwareBadPropertySizeError
      )
    }
    let list = UnsafeMutableAudioBufferListPointer(pointer)
    return list.map(\.mNumberChannels)
  }

  private static func requireNoError(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
      throw AudioCaptureError.systemAudioTapFailed(operation: operation, status: status)
    }
  }
}
