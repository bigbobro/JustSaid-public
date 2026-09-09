import AVFAudio
import CoreAudio
import Foundation

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

  public init(
    streamChannelCounts: [UInt32],
    tapStreamIndex: Int,
    tapBufferRange: Range<Int>,
    expectedBufferCount: Int
  ) {
    self.streamChannelCounts = streamChannelCounts
    self.tapStreamIndex = tapStreamIndex
    self.tapBufferRange = tapBufferRange
    self.expectedBufferCount = expectedBufferCount
  }

  /// 本帧 ABL 的 buffer 数量是否与缓存布局一致。
  public func matchesBufferCount(_ count: Int) -> Bool {
    count == expectedBufferCount
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
  /// 读取聚合设备 input scope 各流声道数，并按 `tapChannelCount` 解析布局。
  static func layout(
    deviceID: AudioDeviceID,
    tapChannelCount: UInt32
  ) throws -> AggregateInputStreamLayout {
    let counts = try inputStreamChannelCounts(deviceID: deviceID)
    guard
      let layout = AggregateInputStreamMapper.layout(
        streamChannelCounts: counts,
        tapChannelCount: tapChannelCount
      )
    else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "解析聚合设备输入流布局（无输入流）",
        status: kAudioHardwareUnsupportedOperationError
      )
    }
    return layout
  }

  static func inputStreamChannelCounts(deviceID: AudioDeviceID) throws -> [UInt32] {
    let streamIDs = try inputStreamIDs(deviceID: deviceID)
    return try streamIDs.map { try streamChannelCount(streamID: $0) }
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
    let count = Int(size) / MemoryLayout<AudioStreamID>.size
    guard count > 0 else {
      return []
    }
    var streamIDs = [AudioStreamID](repeating: 0, count: count)
    status = streamIDs.withUnsafeMutableBufferPointer { buffer in
      var mutableSize = size
      return AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &mutableSize,
        buffer.baseAddress!
      )
    }
    try requireNoError(status, operation: "读取聚合设备输入流列表")
    return streamIDs
  }

  private static func streamChannelCount(streamID: AudioStreamID) throws -> UInt32 {
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
    return asbd.mChannelsPerFrame
  }

  private static func requireNoError(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
      throw AudioCaptureError.systemAudioTapFailed(operation: operation, status: status)
    }
  }
}
