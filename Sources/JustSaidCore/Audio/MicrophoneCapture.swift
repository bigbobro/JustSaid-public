import AVFAudio
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import OSLog

/// VPIO 上行 AGC 显式关闭(08-10 回声消除音量修复)。
///
/// 根因:`setVoiceProcessingEnabled(true)` 会启用整套 VPIO 处理,其中
/// `kAUVoiceIOProperty_VoiceProcessingEnableAGC`(AudioUnitProperties.h=2101)
/// **默认开启**(官方头文件注明 "On by default")——近讲或较响输入被上行 AGC 压低,
/// 远端听感显著变小。这里在 tap/engine 启动前显式写 0 并严格读回。
///
/// 纪律:set/get/readback 任一失败都判 VPIO 启动失败,由调用点走既有
/// AVCaptureSession 回落——不带着未知 AGC 状态继续;绝不设
/// `kAUVoiceIOProperty_BypassVoiceProcessing`(AEC 必须保持启用),也不加固定软件增益。
///
/// `Operations` 是属性读写的注入点:生产走 AudioUnitSetProperty/GetProperty;
/// 验证注入脚本化失败矩阵(set/get OSStatus、读回值),不碰真实音频 I/O。
/// 泛型 Unit 让验证拿哨兵对象当"设备",不需要伪造 AudioUnit 指针。
public enum VPIOUpstreamAGC {
  public struct Operations<Unit> {
    public var set:
      (Unit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UInt32) -> OSStatus
    public var get:
      (Unit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement) -> (
        status: OSStatus, value: UInt32
      )

    public init(
      set:
        @escaping (Unit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UInt32) ->
        OSStatus,
      get:
        @escaping (Unit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement) -> (
          status: OSStatus, value: UInt32
        )
    ) {
      self.set = set
      self.get = get
    }
  }

  public struct Report: Equatable, Sendable {
    public var setStatus: OSStatus?
    public var getStatus: OSStatus?
    public var readbackValue: UInt32?
    public var accepted = false
    public var failureDescription: String?

    public init() {}
  }

  public static let propertyID: AudioUnitPropertyID = kAUVoiceIOProperty_VoiceProcessingEnableAGC
  public static let scope = AudioUnitScope(kAudioUnitScope_Global)
  public static let element = AudioUnitElement(0)
  /// bypass 属性只许读、不许写:断言 AEC 真在干活(0=处理激活),而不是被旁路。
  public static let bypassPropertyID: AudioUnitPropertyID = kAUVoiceIOProperty_BypassVoiceProcessing

  public static func liveOperations() -> Operations<AudioUnit> {
    Operations<AudioUnit>(
      set: { unit, property, scope, element, value in
        var data = value
        return AudioUnitSetProperty(
          unit,
          property,
          scope,
          element,
          &data,
          UInt32(MemoryLayout<UInt32>.size)
        )
      },
      get: { unit, property, scope, element in
        // 毒值而非 0:0 正是"读回通过"的值。AU 若返回 noErr 却没写出参(或只写了一半),
        // 用 0 初始化会把"根本没读到"误判成"读回=0 通过";毒值让这种情况必然被拒。
        var value: UInt32 = 0xFFFF_FFFF
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, property, scope, element, &value, &size)
        return (status, value)
      }
    )
  }

  /// 写 0 → 读回 → 必须为 0;任一步失败立即短路返回失败报告(不产生二次写入)。
  public static func disable<Unit>(
    on unit: Unit?,
    operations: Operations<Unit>
  ) -> Report {
    guard let unit else {
      var report = Report()
      report.failureDescription = "inputNode.audioUnit 不可用"
      return report
    }
    var report = Report()
    let setStatus = operations.set(unit, propertyID, scope, element, 0)
    report.setStatus = setStatus
    guard setStatus == noErr else {
      report.failureDescription = "AGC=0 写入失败 OSStatus=\(setStatus)"
      return report
    }
    let readback = operations.get(unit, propertyID, scope, element)
    report.getStatus = readback.status
    report.readbackValue = readback.value
    guard readback.status == noErr else {
      report.failureDescription = "AGC 回读失败 OSStatus=\(readback.status)"
      return report
    }
    guard readback.value == 0 else {
      report.failureDescription = "AGC 读回仍为 \(readback.value)"
      return report
    }
    report.accepted = true
    return report
  }
}

/// 麦克风暂停边界的线程安全时间轴。保留已闭合区间，是为了让处理队列即使晚于
/// 「恢复」才消费旧 buffer，也仍按该 buffer 的 captureTime 写静音。
final class MicrophonePauseGate: @unchecked Sendable {
  private struct Interval {
    let start: TimeInterval
    var end: TimeInterval?
  }

  private let lock = NSLock()
  private var intervals: [Interval] = []

  func reset() {
    lock.lock()
    intervals.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  func setPaused(_ paused: Bool, at captureTime: TimeInterval) {
    guard captureTime.isFinite else { return }
    let boundary = max(0, captureTime)
    lock.lock()
    defer { lock.unlock() }
    if paused {
      guard intervals.last?.end != nil || intervals.isEmpty else { return }
      intervals.append(Interval(start: boundary, end: nil))
      return
    }
    guard let index = intervals.indices.last, intervals[index].end == nil else { return }
    intervals[index].end = max(intervals[index].start, boundary)
  }

  func overlapsBuffer(start: TimeInterval, duration: TimeInterval) -> Bool {
    guard start.isFinite, duration.isFinite, duration > 0 else { return false }
    let end = start + duration
    guard end.isFinite else { return false }
    lock.lock()
    defer { lock.unlock() }
    return intervals.contains { interval in
      start < (interval.end ?? .infinity) && interval.start < end
    }
  }
}

/// Owns the PCM boundary shared by `AVCaptureAudioDataOutput`, the mother-track
/// writer, and live transcription. Unannounced format drift is rejected; rebuild
/// may explicitly adopt one input format and convert the entire new segment back
/// to the original mother-track format before writer/VAD/ASR share it.
public final class AVCaptureMicrophoneSampleProcessor: @unchecked Sendable {
  private final class RebuildInputAdapter: @unchecked Sendable {
    let inputFormat: AVAudioFormat
    let selectedChannels: [UInt32]?

    private let downmixer: PCMStereoDownmixer?
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    /// 整段转换(降混、转换器、结果校验)在这把锁下串行:同一适配器同一时刻只跑一次 convert,
    /// 共享的 downmixer / AVAudioConverter 不会被两次调用同时使用。
    private let conversionLock = NSLock()
    /// 转换器的 Sendable 输入块只捕获 self;本次调用待喂入的缓冲在这把独立的锁下暂存,
    /// 块内恰好取走一次。锁独立是为了让块在外层转换进行中也能取走/清空。
    private let feedLock = NSLock()
    private var pendingConverterInput: AVAudioPCMBuffer?

    init(
      inputFormat: AVAudioFormat,
      preferredChannels: [UInt32]?,
      outputFormat: AVAudioFormat
    ) throws {
      self.inputFormat = inputFormat
      self.outputFormat = outputFormat
      let downmixer = PCMStereoDownmixer(
        inputFormat: inputFormat,
        preferredChannels: preferredChannels
      )
      guard inputFormat.channelCount <= 2 || downmixer != nil else {
        throw IncrementalM4AWriterError.inputFormatMismatch
      }
      self.downmixer = downmixer
      selectedChannels = downmixer?.selectedChannels
      let converterInputFormat = downmixer?.outputFormat ?? inputFormat
      if converterInputFormat == outputFormat {
        converter = nil
      } else {
        guard
          let converter = AVAudioConverter(
            from: converterInputFormat,
            to: outputFormat
          )
        else {
          throw IncrementalM4AWriterError.inputFormatMismatch
        }
        self.converter = converter
      }
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
      guard input.format == inputFormat else {
        throw IncrementalM4AWriterError.inputFormatMismatch
      }
      conversionLock.lock()
      defer { conversionLock.unlock() }
      let converterInput: AVAudioPCMBuffer
      if let downmixer {
        guard let downmixed = downmixer.convert(input) else {
          throw IncrementalM4AWriterError.inputFormatMismatch
        }
        converterInput = downmixed
      } else {
        converterInput = input
      }
      guard let converter else {
        return converterInput
      }

      let rateRatio = outputFormat.sampleRate / converterInput.format.sampleRate
      let frameCapacity = AVAudioFrameCount(
        ceil(Double(converterInput.frameLength) * rateRatio) + 32
      )
      guard
        let output = AVAudioPCMBuffer(
          pcmFormat: outputFormat,
          frameCapacity: max(1, frameCapacity)
        )
      else {
        throw IncrementalM4AWriterError.inputFormatMismatch
      }

      feedLock.withLock { pendingConverterInput = converterInput }
      defer { feedLock.withLock { pendingConverterInput = nil } }
      var conversionError: NSError?
      let status = converter.convert(
        to: output,
        error: &conversionError
      ) { [self] _, inputStatus in
        let buffer = feedLock.withLock {
          defer { pendingConverterInput = nil }
          return pendingConverterInput
        }
        guard let buffer else {
          inputStatus.pointee = .noDataNow
          return nil
        }
        inputStatus.pointee = .haveData
        return buffer
      }
      guard
        status != .error,
        conversionError == nil,
        converterInput.frameLength == 0 || output.frameLength > 0
      else {
        throw IncrementalM4AWriterError.inputFormatMismatch
      }
      return output
    }
  }

  public let inputFormat: AVAudioFormat
  public let outputFormat: AVAudioFormat
  public var selectedChannels: [UInt32]? {
    inputAdapterLock.withLock {
      if let adaptedInput {
        return adaptedInput.selectedChannels
      }
      return initialSelectedChannels
    }
  }

  private let writer: IncrementalM4AWriter
  private let downmixer: PCMStereoDownmixer?
  private let initialSelectedChannels: [UInt32]?
  private let initialPreferredChannels: [UInt32]?
  private let inputAdapterLock = NSLock()
  /// 已接收但尚未处理的缓冲按票据暂存在这里:队列任务只捕获 self 与票据,取走时才拿到缓冲;
  /// 被有界队列拒绝或 cancel 时按票据/整体清掉,不会残留。
  private let pendingIncomingLock = NSLock()
  private var pendingIncoming: [UInt64: AVAudioPCMBuffer] = [:]
  private var nextPendingIncomingTicket: UInt64 = 0
  private var adaptedInput: RebuildInputAdapter?
  private let bufferHandler: AudioPCMBufferHandler?
  private let lossStatsBox: CaptureLossStatsBox
  private let processingQueue: BoundedCaptureProcessingQueue
  private let pauseGate: MicrophonePauseGate
  private let onFailure: @Sendable (Error) -> Void

  public convenience init(
    outputURL: URL,
    inputFormat: AVAudioFormat,
    preferredChannels: [UInt32]?,
    bufferHandler: AudioPCMBufferHandler?
  ) throws {
    try self.init(
      outputURL: outputURL,
      inputFormat: inputFormat,
      preferredChannels: preferredChannels,
      bufferHandler: bufferHandler,
      lossStatsBox: CaptureLossStatsBox(),
      pauseGate: MicrophonePauseGate(),
      onFailure: { _ in }
    )
  }

  init(
    outputURL: URL,
    inputFormat: AVAudioFormat,
    preferredChannels: [UInt32]?,
    bufferHandler: AudioPCMBufferHandler?,
    lossStatsBox: CaptureLossStatsBox,
    pauseGate: MicrophonePauseGate,
    onFailure: @escaping @Sendable (Error) -> Void
  ) throws {
    self.inputFormat = inputFormat
    initialPreferredChannels = preferredChannels
    downmixer = PCMStereoDownmixer(
      inputFormat: inputFormat,
      preferredChannels: preferredChannels
    )
    outputFormat = downmixer?.outputFormat ?? inputFormat
    initialSelectedChannels = downmixer?.selectedChannels
    writer = try IncrementalM4AWriter(
      outputURL: outputURL,
      inputFormat: outputFormat,
      lossStatsBox: lossStatsBox
    )
    self.bufferHandler = bufferHandler
    self.lossStatsBox = lossStatsBox
    self.pauseGate = pauseGate
    processingQueue = BoundedCaptureProcessingQueue(
      label: "com.justsaid.microphone-processing.\(UUID().uuidString)",
      sampleRate: inputFormat.sampleRate
    )
    self.onFailure = onFailure
  }

  public var captureLossStats: CaptureLossStats {
    lossStatsBox.snapshot()
  }

  /// rebuild 复用既有 writer 时采纳新的设备输入格式。转换实现由格式漂移回归驱动；
  /// 同格式仍保持零转换直通。
  @discardableResult
  public func adoptingConverter(
    from inputFormat: AVAudioFormat,
    preferredChannels: [UInt32]? = nil
  ) throws -> AVCaptureMicrophoneSampleProcessor {
    if inputFormat == self.inputFormat, preferredChannels == initialPreferredChannels {
      inputAdapterLock.withLock {
        adaptedInput = nil
      }
      return self
    }
    let adapter = try RebuildInputAdapter(
      inputFormat: inputFormat,
      preferredChannels: preferredChannels,
      outputFormat: outputFormat
    )
    inputAdapterLock.withLock {
      adaptedInput = adapter
    }
    return self
  }

  public func setPaused(_ paused: Bool, at captureTime: TimeInterval) {
    pauseGate.setPaused(paused, at: captureTime)
  }

  @discardableResult
  public func consume(
    _ sampleBuffer: CMSampleBuffer,
    at captureTime: TimeInterval
  ) throws -> AVAudioPCMBuffer {
    let incoming = try Self.makePCMBuffer(from: sampleBuffer)
    let adapter = try inputAdapter(for: incoming.format)
    lossStatsBox.recordCapturedFrames(UInt64(incoming.frameLength))
    return try process(incoming, adapter: adapter, at: captureTime)
  }

  @discardableResult
  public func enqueue(
    _ sampleBuffer: CMSampleBuffer,
    at captureTime: TimeInterval
  ) throws -> Bool {
    let incoming = try Self.makePCMBuffer(from: sampleBuffer)
    return try enqueue(incoming, at: captureTime, alreadyOwned: true)
  }

  /// VPIO tap / 其他已持有 PCM 的入口。默认会复制缓冲，避免回调结束后底层内存失效。
  @discardableResult
  public func enqueue(
    _ buffer: AVAudioPCMBuffer,
    at captureTime: TimeInterval,
    alreadyOwned: Bool = false
  ) throws -> Bool {
    let incoming: AVAudioPCMBuffer
    if alreadyOwned {
      incoming = buffer
    } else {
      incoming = try Self.copyPCMBuffer(buffer)
    }
    let adapter = try inputAdapter(for: incoming.format)
    let frameCount = UInt64(incoming.frameLength)
    lossStatsBox.recordCapturedFrames(frameCount)
    let ticket = stagePendingIncoming(incoming)
    let accepted = processingQueue.submit(frameCount: frameCount) {
      [self, ticket] in
      guard let incoming = takePendingIncoming(ticket) else {
        return
      }
      do {
        _ = try process(incoming, adapter: adapter, at: captureTime)
      } catch {
        onFailure(error)
      }
    }
    if !accepted {
      _ = takePendingIncoming(ticket)
      lossStatsBox.recordOverloadDrop(
        skippedFrames: bufferHandler == nil ? 0 : frameCount
      )
    }
    return accepted
  }

  private func stagePendingIncoming(_ buffer: AVAudioPCMBuffer) -> UInt64 {
    pendingIncomingLock.withLock {
      nextPendingIncomingTicket += 1
      pendingIncoming[nextPendingIncomingTicket] = buffer
      return nextPendingIncomingTicket
    }
  }

  private func takePendingIncoming(_ ticket: UInt64) -> AVAudioPCMBuffer? {
    pendingIncomingLock.withLock {
      pendingIncoming.removeValue(forKey: ticket)
    }
  }

  private func process(
    _ incoming: AVAudioPCMBuffer,
    adapter: RebuildInputAdapter?,
    at captureTime: TimeInterval
  ) throws -> AVAudioPCMBuffer {

    let outgoing: AVAudioPCMBuffer
    if let adapter {
      outgoing = try adapter.convert(incoming)
    } else if let downmixer {
      guard let converted = downmixer.convert(incoming) else {
        throw AudioCaptureError.audioWriteFailed("多声道降混失败")
      }
      outgoing = converted
    } else {
      outgoing = incoming
    }

    let duration = Double(outgoing.frameLength) / max(1, outgoing.format.sampleRate)
    let isPaused = pauseGate.overlapsBuffer(start: captureTime, duration: duration)
    let bufferToWrite = isPaused ? try Self.makeSilentBuffer(like: outgoing) : outgoing

    var writeError: Error?
    do {
      try writer.append(bufferToWrite, at: captureTime)
    } catch {
      writeError = error
    }
    if !isPaused, let bufferHandler {
      bufferHandler(outgoing, captureTime)
      lossStatsBox.recordASRFedFrames(UInt64(outgoing.frameLength))
    }
    if let writeError {
      throw writeError
    }
    return bufferToWrite
  }

  private func inputAdapter(
    for incomingFormat: AVAudioFormat
  ) throws -> RebuildInputAdapter? {
    let adapter = inputAdapterLock.withLock { adaptedInput }
    if let adapter {
      guard incomingFormat == adapter.inputFormat else {
        throw IncrementalM4AWriterError.inputFormatMismatch
      }
      return adapter
    }
    guard incomingFormat == inputFormat else {
      throw IncrementalM4AWriterError.inputFormatMismatch
    }
    return nil
  }

  private static func makeSilentBuffer(
    like buffer: AVAudioPCMBuffer
  ) throws -> AVAudioPCMBuffer {
    guard
      let silence = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: max(1, buffer.frameLength)
      )
    else {
      throw AudioCaptureError.audioWriteFailed("无法创建麦克风暂停静音缓冲")
    }
    silence.frameLength = buffer.frameLength
    for audioBuffer in UnsafeMutableAudioBufferListPointer(
      silence.mutableAudioBufferList
    ) {
      guard audioBuffer.mDataByteSize == 0 || audioBuffer.mData != nil else {
        throw AudioCaptureError.audioWriteFailed("无法清零麦克风暂停缓冲")
      }
      if let data = audioBuffer.mData {
        memset(data, 0, Int(audioBuffer.mDataByteSize))
      }
    }
    return silence
  }

  public func finish() async throws {
    await processingQueue.finishAcceptingAndDrain()
    try await writer.finish()
  }

  public func cancel() {
    processingQueue.cancel()
    pendingIncomingLock.withLock { pendingIncoming.removeAll() }
    writer.cancel()
  }

  static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    guard
      let copy = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: max(1, buffer.frameLength)
      )
    else {
      throw AudioCaptureError.audioWriteFailed("复制麦克风 PCM 缓冲失败")
    }
    copy.frameLength = buffer.frameLength
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else {
      return copy
    }

    if buffer.format.commonFormat == .pcmFormatFloat32,
      let source = buffer.floatChannelData,
      let destination = copy.floatChannelData
    {
      let channelCount = Int(buffer.format.channelCount)
      if buffer.format.isInterleaved {
        let sampleCount = frameCount * channelCount
        destination[0].update(from: source[0], count: sampleCount)
      } else {
        for channel in 0..<channelCount {
          destination[channel].update(from: source[channel], count: frameCount)
        }
      }
      return copy
    }

    let sourceList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destinationList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard sourceList.count == destinationList.count else {
      throw AudioCaptureError.audioWriteFailed("复制麦克风 PCM 声道数不一致")
    }
    for index in 0..<sourceList.count {
      let byteCount = Int(sourceList[index].mDataByteSize)
      guard
        byteCount > 0,
        byteCount <= Int(destinationList[index].mDataByteSize),
        let sourceData = sourceList[index].mData,
        let destinationData = destinationList[index].mData
      else {
        throw AudioCaptureError.audioWriteFailed("复制麦克风 PCM 数据失败")
      }
      memcpy(destinationData, sourceData, byteCount)
    }
    return copy
  }

  fileprivate static func makePCMBuffer(
    from sampleBuffer: CMSampleBuffer
  ) throws -> AVAudioPCMBuffer {
    guard CMSampleBufferDataIsReady(sampleBuffer) else {
      throw IncrementalM4AWriterError.invalidState(
        "AVCaptureSession 样本尚未就绪"
      )
    }
    guard
      let description = CMSampleBufferGetFormatDescription(sampleBuffer),
      CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio
    else {
      throw IncrementalM4AWriterError.invalidInputFormat(
        "AVCaptureSession 未输出音频格式"
      )
    }

    let format = AVAudioFormat(cmAudioFormatDescription: description)
    guard format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
      throw IncrementalM4AWriterError.invalidInputFormat(
        "AVCaptureSession 必须输出线性 PCM"
      )
    }

    let maximumBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
    let audioBufferList = AudioBufferList.allocate(
      maximumBuffers: max(1, maximumBuffers)
    )
    let audioBufferListPointer = audioBufferList.unsafeMutablePointer
    var retainedBlockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: audioBufferListPointer,
      bufferListSize: AudioBufferList.sizeInBytes(
        maximumBuffers: max(1, maximumBuffers)
      ),
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &retainedBlockBuffer
    )
    guard status == noErr, let retainedBlockBuffer else {
      audioBufferListPointer.deallocate()
      throw IncrementalM4AWriterError.coreMedia(
        operation: "读取 AVCaptureSession PCM 样本",
        status: status
      )
    }

    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        bufferListNoCopy: audioBufferList.unsafePointer,
        deallocator: { _ in
          withExtendedLifetime(retainedBlockBuffer) {}
          audioBufferListPointer.deallocate()
        }
      )
    else {
      audioBufferListPointer.deallocate()
      throw IncrementalM4AWriterError.invalidInputFormat(
        "无法读取 AVCaptureSession PCM 缓冲区"
      )
    }

    let frameLength = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frameLength > 0, frameLength <= Int(buffer.frameCapacity) else {
      throw IncrementalM4AWriterError.invalidInputFormat(
        "AVCaptureSession PCM 帧数无效"
      )
    }
    buffer.frameLength = AVAudioFrameCount(frameLength)
    return buffer
  }
}

public enum MicrophoneVPIOBindingStage: String, Sendable {
  case beforeVoiceProcessing
  case afterVoiceProcessing
  case afterStart
}

/// The stopped-engine adapter uses only the existing input unit. Tests inject property failures.
public struct MicrophoneVPIOInputOperations: Sendable {
  public let setDevice: @Sendable (AUAudioUnit?, AudioDeviceID) throws -> Void
  public let readUID: @Sendable (AUAudioUnit?) throws -> MicrophoneDeviceUID

  public init(
    setDevice: @escaping @Sendable (AUAudioUnit?, AudioDeviceID) throws -> Void,
    readUID: @escaping @Sendable (AUAudioUnit?) throws -> MicrophoneDeviceUID
  ) {
    self.setDevice = setDevice
    self.readUID = readUID
  }

  public static var live: MicrophoneVPIOInputOperations {
    MicrophoneVPIOInputOperations(
      setDevice: { unit, id in
        guard let unit else { throw AudioCaptureError.microphoneUnavailable("VPIO 输入单元不可用") }
        try unit.setDeviceID(id)
      },
      readUID: { unit in
        guard let unit,
          let uid = AudioInputDeviceMonitor.deviceString(
            unit.deviceID, selector: kAudioDevicePropertyDeviceUID
          )
        else { throw AudioCaptureError.microphoneUnavailable("无法核对 VPIO 实际输入") }
        let identity = MicrophoneDeviceUID(rawValue: uid)
        guard try AudioInputDeviceMonitor.checkedDeviceID(for: identity) == unit.deviceID else {
          throw AudioCaptureError.microphoneUnavailable("VPIO 实际输入身份不一致")
        }
        return identity
      }
    )
  }

  func apply(
    unit: AUAudioUnit?, target: MicrophoneInputTarget, stage: MicrophoneVPIOBindingStage
  ) throws {
    if stage != .afterStart { try setDevice(unit, target.device.objectID) }
    guard try readUID(unit) == target.device.uid else {
      throw AudioCaptureError.microphoneUnavailable("VPIO 实际输入与所选麦克风不一致")
    }
  }
}

public final class MicrophoneCapture: NSObject, MicrophoneAudioCapturing,
  AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
  private struct StopResources: @unchecked Sendable {
    let processor: AVCaptureMicrophoneSampleProcessor?
    let hadResources: Bool
    let routeDescription: String?
  }

  private let captureQueue = DispatchQueue(
    label: "com.justsaid.microphone-capture"
  )
  private let logger = Logger(
    subsystem: "com.justsaid.app",
    category: "MicrophoneCapture"
  )
  private let failureBox = CaptureFailureBox()
  private let lossStatsBox = CaptureLossStatsBox()
  private let pauseGate = MicrophonePauseGate()
  private let aecEnabledProvider: @Sendable () -> Bool
  /// 验证探针注入：为 true 时强制 VPIO 初始化失败，断言回落原路。
  private let simulateVPIOUnavailable: Bool
  /// VPIO 上行 AGC 属性操作:生产为真实 AudioUnit 读写;验证注入脚本化失败矩阵,
  /// 断言「AGC 配置失败 → 回落 AVCaptureSession」不靠真实设备拒属性。
  private let vpioAGCOperations: VPIOUpstreamAGC.Operations<AudioUnit>
  /// Hardware-free verification replaces only route creation. Notification handling,
  /// captureQueue, processor, start/rebuild/stop and the session sampler stay real.
  private let verificationInputFormat: (@Sendable (Bool) throws -> AVAudioFormat)?
  private let verificationTargetObserver: (@Sendable (MicrophoneInputTarget) throws -> Void)?
  private let verificationVPIOStage:
    (@Sendable (MicrophoneVPIOBindingStage, AVAudioNodeTapBlock?, UInt64) throws -> Void)?
  private let verificationBeforeAdmission:
    (@Sendable (MicrophoneCaptureRoutePlanner.Route) -> Void)?
  private let vpioInputOperations: MicrophoneVPIOInputOperations
  private var verificationTap: AVAudioNodeTapBlock?
  // These fields, including the enqueue cut-off, belong to startGenerationLock.
  private var inputAttemptGeneration: UInt64 = 0
  private var inputAdmission: InputAdmission?
  private var confirmedBinding: MicrophoneInputBinding?

  private struct InputAdmission {
    let generation: UInt64
    let startGeneration: UInt64
    let output: ObjectIdentifier?
    let processor: AVCaptureMicrophoneSampleProcessor
    let epoch: UInt64
    var confirmed: Bool
  }

  private struct ResolvedInput {
    let target: MicrophoneInputTarget
    let device: AVCaptureDevice?
    let format: AVAudioFormat
    let preferredChannels: [UInt32]?
    let isHFP: Bool
  }
  private let routeLock = NSLock()
  private let startGenerationLock = NSLock()
  private var startGeneration: UInt64 = 0
  // Shared with the health sampler under startGenerationLock. The observation identity
  // is minted only on captureQueue; firstCaptureFailure remains a separate history.
  private var latestRuntimeRecovery: MicrophoneRuntimeRecoveryRequest?
  private var runtimeRecoveryProgress:
    (request: MicrophoneRuntimeRecoveryRequest, frames: UInt64, at: Date)?

  // Accessed only on captureQueue.
  private var session: AVCaptureSession?
  private var audioOutput: AVCaptureAudioDataOutput?
  private var engine: AVAudioEngine?
  private var sampleProcessor: AVCaptureMicrophoneSampleProcessor?
  private var statsTimer: DispatchSourceTimer?
  private var sessionNotificationTokens: [NSObjectProtocol] = []
  private var sessionObservationGeneration: UInt = 0
  private var sessionEpochHostTime: UInt64?
  private var activeRoute: MicrophoneCaptureRoutePlanner.Route?
  private var publishedRouteDescription: String?
  private var isRunning = false
  private var tapInstalled = false
  /// rebuild 重走路由决策所需的开录参数;stop 时清空。
  private var startConfiguration: (outputURL: URL, bufferHandler: AudioPCMBufferHandler?)?

  public override convenience init() {
    self.init(
      aecEnabledProvider: { MicrophoneAECSettings.isEnabled() },
      simulateVPIOUnavailable: false
    )
  }

  public init(
    aecEnabledProvider: @escaping @Sendable () -> Bool,
    simulateVPIOUnavailable: Bool = false,
    vpioAGCOperations: VPIOUpstreamAGC.Operations<AudioUnit> = VPIOUpstreamAGC.liveOperations(),
    verificationInputFormat: (@Sendable (Bool) throws -> AVAudioFormat)? = nil,
    verificationTargetObserver: (@Sendable (MicrophoneInputTarget) throws -> Void)? = nil,
    vpioInputOperations: MicrophoneVPIOInputOperations = .live,
    verificationVPIOStage: (
      @Sendable (MicrophoneVPIOBindingStage, AVAudioNodeTapBlock?, UInt64) throws -> Void
    )? = nil,
    verificationBeforeAdmission: (@Sendable (MicrophoneCaptureRoutePlanner.Route) -> Void)? = nil
  ) {
    self.aecEnabledProvider = aecEnabledProvider
    self.simulateVPIOUnavailable = simulateVPIOUnavailable
    self.vpioAGCOperations = vpioAGCOperations
    self.verificationInputFormat = verificationInputFormat
    self.verificationTargetObserver = verificationTargetObserver
    self.vpioInputOperations = vpioInputOperations
    self.verificationVPIOStage = verificationVPIOStage
    self.verificationBeforeAdmission = verificationBeforeAdmission
    super.init()
  }

  public var captureLossStats: CaptureLossStats {
    lossStatsBox.snapshot()
  }

  public var runtimeRecoverySnapshot: MicrophoneRuntimeRecoverySnapshot? {
    startGenerationLock.withLock {
      guard let request = latestRuntimeRecovery else { return nil }
      let progress = runtimeRecoveryProgress?.request == request ? runtimeRecoveryProgress : nil
      return MicrophoneRuntimeRecoverySnapshot(
        request: request, rebuiltAt: progress?.at, framesAtRebuild: progress?.frames,
        capturedFrames: lossStatsBox.snapshot().capturedFrames
      )
    }
  }

  public var firstCaptureFailure: (error: any Error, at: Date)? {
    failureBox.firstFailure
  }

  public var activeCaptureRouteDescription: String? {
    routeLock.lock()
    defer { routeLock.unlock() }
    return publishedRouteDescription
  }

  private func publishRoute(_ route: MicrophoneCaptureRoutePlanner.Route?) {
    activeRoute = route
    routeLock.lock()
    publishedRouteDescription = route?.rawValue
    routeLock.unlock()
  }

  private func beginStartGeneration() -> UInt64 {
    startGenerationLock.withLock {
      startGeneration &+= 1
      return startGeneration
    }
  }

  private func invalidateStartGeneration() {
    startGenerationLock.withLock {
      startGeneration &+= 1
      inputAdmission = nil
      confirmedBinding = nil
    }
  }

  private func isCurrentStartGeneration(_ generation: UInt64) -> Bool {
    startGenerationLock.withLock { startGeneration == generation }
  }

  public func requestPermission() async throws {
    if verificationInputFormat != nil { return }
    try await ensurePermission()
  }

  public func setPaused(_ paused: Bool, at captureTime: TimeInterval) {
    pauseGate.setPaused(paused, at: captureTime)
  }

  public func start(
    target: MicrophoneInputTarget,
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    bufferHandler: AudioPCMBufferHandler? = nil,
    onStartStage: MicrophoneStartStageObserver? = nil
  ) async throws -> MicrophoneInputBinding {
    let generation = beginStartGeneration()
    try await requestPermission()
    guard isCurrentStartGeneration(generation) else {
      throw CancellationError()
    }

    return try await withCheckedThrowingContinuation { continuation in
      captureQueue.async { [self] in
        // 子阶段完成语义:queueEntry 在任何守卫之前上报——
        // 「零子阶段到达」才能区分「队列被上一场卡死的 teardown 楔住」。
        onStartStage?(.queueEntry, nil)
        do {
          guard isCurrentStartGeneration(generation) else {
            throw CancellationError()
          }
          let binding = try startOnCaptureQueue(
            target: target, expectedGeneration: generation,
            outputURL: outputURL,
            sessionEpochHostTime: sessionEpochHostTime,
            bufferHandler: bufferHandler,
            onStartStage: onStartStage
          )
          guard isCurrentStartGeneration(generation) else {
            let resources = stopOnCaptureQueue()
            resources.processor?.cancel()
            throw CancellationError()
          }
          continuation.resume(returning: binding)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func cancelPendingStart() {
    // 同步失效旧世代；teardown 排进串行队列但不阻塞 timeout 返回。
    invalidateStartGeneration()
    captureQueue.async { [self] in
      let resources = stopOnCaptureQueue()
      resources.processor?.cancel()
    }
  }

  public func stop() async throws {
    invalidateStartGeneration()
    let resources = await withCheckedContinuation { continuation in
      captureQueue.async { [self] in
        continuation.resume(returning: stopOnCaptureQueue())
      }
    }
    guard resources.hadResources else {
      return
    }

    var finishError: Error?
    if let processor = resources.processor {
      do {
        try await processor.finish()
      } catch {
        finishError = error
      }
    }
    let firstError = failureBox.take() ?? finishError

    let statsDescription = captureLossStats.logDescription
    let route = resources.routeDescription ?? "unknown"
    logger.info(
      "麦克风采集统计（结束）：\(statsDescription, privacy: .public)"
    )
    logger.info("麦克风录制已停止（\(route, privacy: .public)）")
    if let firstError {
      throw firstError
    }
  }

  /// 自愈原语(08-05 单路故障自愈):拆掉当前采集路径(VPIO 或 AVCaptureSession)后
  /// 重走既有路由决策;**processor(writer/降混/统计)保持不动**,中断段由 writer
  /// 补为等长静音。由会话层健康监测驱动,与 stop() 的互斥由会话层保证。
  public func rebuild(target: MicrophoneInputTarget) async throws -> MicrophoneInputBinding {
    let generation = startGenerationLock.withLock { startGeneration }
    return try await withCheckedThrowingContinuation { continuation in
      captureQueue.async { [self] in
        do {
          continuation.resume(
            returning: try rebuildOnCaptureQueue(target: target, expectedGeneration: generation))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func rebuildOnCaptureQueue(
    target: MicrophoneInputTarget, expectedGeneration: UInt64
  ) throws -> MicrophoneInputBinding {
    guard isCurrentStartGeneration(expectedGeneration) else { throw CancellationError() }
    guard
      let configuration = startConfiguration,
      let epochHostTime = sessionEpochHostTime,
      let processor = sampleProcessor
    else {
      throw AudioCaptureError.microphoneUnavailable("麦克风采集未在运行，无法重建")
    }

    let recoveryRequest = startGenerationLock.withLock { latestRuntimeRecovery }
    // A failed attempt cannot leave an earlier completion eligible to acknowledge it.
    startGenerationLock.withLock { runtimeRecoveryProgress = nil }
    // 拆当前路径:VPIO 引擎与 AVCaptureSession 均可能在场,全部拆净,不碰 processor。
    retireInputAdmission()
    isRunning = false
    if activeRoute == .vpio || engine != nil {
      tearDownVPIOOnCaptureQueue(cancelProcessor: false)
    }
    audioOutput?.setSampleBufferDelegate(nil, queue: nil)
    stopObservingSessionFailures()
    if let session {
      session.stopRunning()
      tearDown(session)
    }
    session = nil
    audioOutput = nil
    publishRoute(nil)

    let binding = try startPreferredRouteOnCaptureQueue(
      target: target, expectedGeneration: expectedGeneration,
      outputURL: configuration.outputURL,
      sessionEpochHostTime: epochHostTime,
      bufferHandler: configuration.bufferHandler,
      reusingProcessor: processor
    )
    confirmRuntimeRecoveryRebuild(recoveryRequest, generation: sessionObservationGeneration)
    logger.notice(
      "麦克风采集管线已重建（路径：\(self.activeRoute?.rawValue ?? "unknown", privacy: .public)）"
    )
    return binding
  }

  public func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let identity = ObjectIdentifier(output)
    guard
      let admission = startGenerationLock.withLock({
        inputAdmission.flatMap { $0.confirmed && $0.output == identity ? $0 : nil }
      })
    else { return }
    do {
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      let presentationSeconds = CMTimeGetSeconds(presentationTime)
      guard presentationTime.isValid, presentationSeconds.isFinite, presentationSeconds >= 0 else {
        throw IncrementalM4AWriterError.invalidState("AVCaptureSession 样本缺少有效 host-time 时间戳")
      }
      let captureTime = AudioCaptureClock.secondsSinceEpoch(
        hostTime: AVAudioTime.hostTime(forSeconds: presentationSeconds),
        epochHostTime: admission.epoch
      )
      let owned = try AVCaptureMicrophoneSampleProcessor.makePCMBuffer(from: sampleBuffer)
      verificationBeforeAdmission?(.avCaptureSession)
      try admit(owned, at: captureTime, admission: admission)
    } catch { recordCallbackFailure(error, admission: admission) }
  }

  private func makeVPIOTapHandler(admission: InputAdmission) -> AVAudioNodeTapBlock {
    { [weak self] buffer, time in
      guard let self, startGenerationLock.withLock({ self.isCurrentAdmission(admission) }) else {
        return
      }
      do {
        guard time.isHostTimeValid else {
          throw IncrementalM4AWriterError.invalidState("VPIO tap 缺少有效 hostTime")
        }
        let owned = try AVCaptureMicrophoneSampleProcessor.copyPCMBuffer(buffer)
        let captureTime = AudioCaptureClock.secondsSinceEpoch(
          hostTime: time.hostTime, epochHostTime: admission.epoch
        )
        verificationBeforeAdmission?(.vpio)
        try admit(owned, at: captureTime, admission: admission)
      } catch { recordCallbackFailure(error, admission: admission) }
    }
  }

  /// Copying has finished before this short cut-off. Adapter capture, counters and queue
  /// admission linearize together; accepted queued content is never filtered on a later generation.
  private func admit(
    _ owned: AVAudioPCMBuffer, at captureTime: TimeInterval, admission: InputAdmission
  ) throws {
    try startGenerationLock.withLock {
      guard isCurrentAdmission(admission) else { return }
      try admission.processor.enqueue(owned, at: captureTime, alreadyOwned: true)
    }
  }

  /// Caller holds startGenerationLock. No HAL, DSP, writer work or captureQueue sync under it.
  private func isCurrentAdmission(_ admission: InputAdmission) -> Bool {
    inputAdmission?.generation == admission.generation
      && inputAdmission?.confirmed == true && startGeneration == admission.startGeneration
  }

  private func recordCallbackFailure(_ error: Error, admission: InputAdmission) {
    let recorded = startGenerationLock.withLock {
      isCurrentAdmission(admission) && failureBox.record(error)
    }
    if recorded { logger.error("麦克风样本处理失败：\(error.localizedDescription, privacy: .public)") }
  }

  private func retireInputAdmission() {
    startGenerationLock.withLock {
      inputAdmission = nil
      confirmedBinding = nil
    }
  }

  private func prepareInputAdmission(
    processor: AVCaptureMicrophoneSampleProcessor, epoch: UInt64,
    expectedGeneration: UInt64, output: AVCaptureOutput? = nil
  ) throws -> InputAdmission {
    try startGenerationLock.withLock {
      guard startGeneration == expectedGeneration else { throw CancellationError() }
      inputAttemptGeneration &+= 1
      let admission = InputAdmission(
        generation: inputAttemptGeneration, startGeneration: expectedGeneration,
        output: output.map(ObjectIdentifier.init), processor: processor, epoch: epoch,
        confirmed: false
      )
      inputAdmission = admission
      confirmedBinding = nil
      return admission
    }
  }

  private func confirmInputAdmission(
    _ admission: InputAdmission, target: MicrophoneInputTarget,
    route: MicrophoneCaptureRoutePlanner.Route, actualName: String,
    processingFallback: String? = nil
  ) throws -> MicrophoneInputBinding {
    var device = target.device
    device = MicrophoneInputDevice(
      uid: device.uid, captureID: device.captureID, objectID: device.objectID,
      name: actualName, summary: device.summary, incarnation: device.incarnation
    )
    let binding = MicrophoneInputBinding(
      device: device, route: route, generation: admission.generation,
      processingFallbackReason: processingFallback
    )
    return try startGenerationLock.withLock {
      guard inputAdmission?.generation == admission.generation,
        startGeneration == admission.startGeneration
      else { throw CancellationError() }
      inputAdmission?.confirmed = true
      confirmedBinding = binding
      return binding
    }
  }

  private func startOnCaptureQueue(
    target: MicrophoneInputTarget, expectedGeneration: UInt64,
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    bufferHandler: AudioPCMBufferHandler?,
    onStartStage: MicrophoneStartStageObserver?
  ) throws -> MicrophoneInputBinding {
    guard !isRunning else {
      throw AudioCaptureError.microphoneUnavailable("麦克风采集已在运行")
    }
    failureBox.reset()
    startGenerationLock.withLock {
      latestRuntimeRecovery = nil
      runtimeRecoveryProgress = nil
    }
    lossStatsBox.reset()
    pauseGate.reset()
    publishRoute(nil)
    // 观测回调不进 startConfiguration:rebuild 是会中自愈,不属于启动轨迹。
    startConfiguration = (outputURL, bufferHandler)

    return try startPreferredRouteOnCaptureQueue(
      target: target, expectedGeneration: expectedGeneration,
      outputURL: outputURL,
      sessionEpochHostTime: sessionEpochHostTime,
      bufferHandler: bufferHandler,
      reusingProcessor: nil,
      onStartStage: onStartStage
    )
  }

  /// 路由决策(AEC 开关/蓝牙 HFP → VPIO 优先,失败回落 AVCaptureSession)。
  /// start 与 rebuild 共用同一条决策路径(自愈红线:rebuild 不得新造路径);
  /// rebuild 传入既有 processor(writer/降混/统计不动),start 传 nil 新建。
  private func startPreferredRouteOnCaptureQueue(
    target: MicrophoneInputTarget, expectedGeneration: UInt64,
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    bufferHandler: AudioPCMBufferHandler?,
    reusingProcessor: AVCaptureMicrophoneSampleProcessor?,
    onStartStage: MicrophoneStartStageObserver? = nil
  ) throws -> MicrophoneInputBinding {
    guard isCurrentStartGeneration(expectedGeneration) else { throw CancellationError() }
    // Identity failures precede the VPIO catch: they cannot silently choose another default.
    let input = try resolveInput(target: target, rebuilding: reusingProcessor != nil)
    onStartStage?(.resolveDevice, input.device?.localizedName ?? target.device.name)
    let aecEnabled = aecEnabledProvider()
    let preferred = MicrophoneCaptureRoutePlanner.preferredRoute(
      aecEnabled: aecEnabled, isBluetoothHFPInput: input.isHFP
    )
    let fallbackReason = MicrophoneCaptureRoutePlanner.fallbackReason(
      aecEnabled: aecEnabled, isBluetoothHFPInput: input.isHFP
    )
    onStartStage?(
      .route, fallbackReason.map { "\(preferred.rawValue)|\($0)" } ?? preferred.rawValue)
    var processingFallback: String?
    var fallbackProcessor = reusingProcessor
    if preferred == .vpio {
      do {
        return try startVPIOOnCaptureQueue(
          input: input, expectedGeneration: expectedGeneration, outputURL: outputURL,
          sessionEpochHostTime: sessionEpochHostTime,
          bufferHandler: bufferHandler, reusingProcessor: reusingProcessor,
          onStartStage: onStartStage
        )
      } catch {
        retireInputAdmission()
        guard isCurrentStartGeneration(expectedGeneration) else {
          tearDownVPIOOnCaptureQueue(cancelProcessor: reusingProcessor == nil)
          throw CancellationError()
        }
        // The pending VPIO attempt may already own the meeting's writer. Keep it for the
        // same-target fallback; asynchronous cancellation would race a new writer at this URL.
        fallbackProcessor = sampleProcessor ?? reusingProcessor
        tearDownVPIOOnCaptureQueue(cancelProcessor: false)
        processingFallback = "回声消除路径未能确认所选输入，已临时使用普通采集；回声消除设置保持不变"
        logger.warning(
          "VPIO 启动失败，同一麦克风回落 AVCaptureSession：\(error.localizedDescription, privacy: .public)")
      }
    }
    do {
      return try startAVCaptureSessionOnCaptureQueue(
        input: input, expectedGeneration: expectedGeneration, outputURL: outputURL,
        sessionEpochHostTime: sessionEpochHostTime,
        bufferHandler: bufferHandler, reusingProcessor: fallbackProcessor,
        onStartStage: onStartStage, processingFallback: processingFallback
      )
    } catch {
      if reusingProcessor == nil {
        let resources = stopOnCaptureQueue()
        resources.processor?.cancel()
      }
      throw error
    }
  }

  private func resolveInput(target: MicrophoneInputTarget, rebuilding: Bool) throws -> ResolvedInput
  {
    guard let captureID = target.device.captureID else {
      throw AudioCaptureError.microphoneUnavailable("无法核对所选麦克风与采集设备的对应关系")
    }
    if let verificationInputFormat {
      try verificationTargetObserver?(target)
      return ResolvedInput(
        target: target, device: nil, format: try verificationInputFormat(rebuilding),
        preferredChannels: nil, isHFP: false
      )
    }
    let id = try AudioInputDeviceMonitor.checkedDeviceID(for: target.device.uid)
    guard id == target.device.objectID, captureID.rawValue == target.device.uid.rawValue,
      let device = AVCaptureDevice(uniqueID: captureID.rawValue), device.isConnected,
      device.hasMediaType(.audio), device.uniqueID == captureID.rawValue
    else { throw AudioCaptureError.microphoneUnavailable("所选麦克风已变化或设备身份无法核对") }
    let format = AVAudioFormat(cmAudioFormatDescription: device.activeFormat.formatDescription)
    return ResolvedInput(
      target: target, device: device, format: format,
      preferredChannels: PCMStereoDownmixer.preferredChannels(
        for: id, scope: kAudioDevicePropertyScopeInput),
      isHFP: MicrophoneCaptureRoutePlanner.isBluetoothHFPInput(
        transportType: UInt32(bitPattern: device.transportType),
        inputChannelCount: format.channelCount
      )
    )
  }

  private func startVPIOOnCaptureQueue(
    input: ResolvedInput, expectedGeneration: UInt64,
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    bufferHandler: AudioPCMBufferHandler?,
    reusingProcessor: AVCaptureMicrophoneSampleProcessor? = nil,
    onStartStage: MicrophoneStartStageObserver? = nil
  ) throws -> MicrophoneInputBinding {
    if simulateVPIOUnavailable {
      throw AudioCaptureError.microphoneUnavailable(
        "模拟 VPIO 不可用（验证探针）"
      )
    }

    let engine = verificationInputFormat == nil ? AVAudioEngine() : nil
    self.engine = engine
    try verificationVPIOStage?(.beforeVoiceProcessing, nil, sessionEpochHostTime)
    try vpioInputOperations.apply(
      unit: engine?.inputNode.auAudioUnit, target: input.target, stage: .beforeVoiceProcessing
    )
    try engine?.inputNode.setVoiceProcessingEnabled(true)
    // Reacquire the input node/unit after the VP mode change on this stopped engine.
    let inputNode = engine?.inputNode
    if let inputNode, !inputNode.isVoiceProcessingEnabled {
      throw AudioCaptureError.microphoneUnavailable("setVoiceProcessingEnabled 后未生效")
    }

    try verificationVPIOStage?(.afterVoiceProcessing, nil, sessionEpochHostTime)
    try vpioInputOperations.apply(
      unit: engine?.inputNode.auAudioUnit, target: input.target, stage: .afterVoiceProcessing
    )

    if let inputNode {
      // 上行 AGC 必须在 tap/engine 启动前显式关闭并读回:VPIO 默认开着它,
      // 近讲/较响输入会被压低(远端听感显著变小的根因)。任一失败都不带病上路——
      // 关掉 voice processing 再走既有 AVCaptureSession 回落,不留半启动状态。
      let agcReport = VPIOUpstreamAGC.disable(
        on: inputNode.audioUnit,
        operations: vpioAGCOperations
      )
      guard agcReport.accepted else {
        try? inputNode.setVoiceProcessingEnabled(false)
        throw AudioCaptureError.microphoneUnavailable(
          "VPIO 上行 AGC 关闭失败：\(agcReport.failureDescription ?? "未知")"
        )
      }

      // advanced-min：2026-08-03 用户听感判决 PASS；baseline（advanced=false）已弃用。
      let ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: ObjCBool(true),
        duckingLevel: .min
      )
      inputNode.voiceProcessingOtherAudioDuckingConfiguration = ducking
      let accepted = inputNode.voiceProcessingOtherAudioDuckingConfiguration
      guard
        accepted.enableAdvancedDucking.boolValue,
        accepted.duckingLevel == .min
      else {
        throw AudioCaptureError.microphoneUnavailable(
          "VPIO advanced-min ducking 配置回读不一致"
        )
      }

    }
    let inputFormat = inputNode?.outputFormat(forBus: 0) ?? input.format
    guard
      inputFormat.sampleRate > 0,
      inputFormat.channelCount > 0,
      inputFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM
    else {
      throw AudioCaptureError.microphoneUnavailable("VPIO 输入格式无效")
    }

    let preferredChannels = input.preferredChannels
    let processor: AVCaptureMicrophoneSampleProcessor
    if let reusingProcessor {
      // rebuild 复用既有 writer；格式漂移时在 processor 单一入口整段转换回
      // 原母带格式，writer/VAD/ASR 不各自分叉。
      do {
        processor = try reusingProcessor.adoptingConverter(
          from: inputFormat,
          preferredChannels: preferredChannels
        )
      } catch {
        try? inputNode?.setVoiceProcessingEnabled(false)
        throw error
      }
    } else {
      do {
        processor = try AVCaptureMicrophoneSampleProcessor(
          outputURL: outputURL,
          inputFormat: inputFormat,
          preferredChannels: preferredChannels,
          bufferHandler: bufferHandler,
          lossStatsBox: lossStatsBox,
          pauseGate: pauseGate,
          onFailure: { [failureBox, logger] error in
            if failureBox.record(error) {
              logger.error(
                "VPIO 麦克风样本处理失败：\(error.localizedDescription, privacy: .public)"
              )
            }
          }
        )
      } catch {
        try? inputNode?.setVoiceProcessingEnabled(false)
        throw AudioCaptureError.audioWriteFailed(error.localizedDescription)
      }
    }

    if inputFormat.channelCount > 2 {
      if let channels = processor.selectedChannels {
        logger.info(
          "VPIO 麦克风输入为 \(inputFormat.channelCount, privacy: .public) 声道，按设备偏好声道 \(channels[0], privacy: .public)/\(channels[1], privacy: .public) 降混为立体声"
        )
      } else {
        logger.warning(
          "VPIO 麦克风输入为 \(inputFormat.channelCount, privacy: .public) 声道，设备未提供可用立体声声道，退回全声道平均降混"
        )
      }
    }

    sampleProcessor = processor
    let admission = try prepareInputAdmission(
      processor: processor, epoch: sessionEpochHostTime, expectedGeneration: expectedGeneration
    )
    let tap = makeVPIOTapHandler(admission: admission)
    inputNode?.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: tap)
    if verificationInputFormat != nil { verificationTap = tap }
    tapInstalled = true
    self.engine = engine
    self.sessionEpochHostTime = sessionEpochHostTime
    publishRoute(.vpio)

    engine?.prepare()
    do {
      try engine?.start()
    } catch {
      throw AudioCaptureError.microphoneUnavailable(
        "AVAudioEngine 启动失败：\(error.localizedDescription)"
      )
    }
    if let engine, !engine.isRunning {
      throw AudioCaptureError.microphoneUnavailable("AVAudioEngine 未能进入运行状态")
    }

    try verificationVPIOStage?(.afterStart, tap, sessionEpochHostTime)
    try vpioInputOperations.apply(
      unit: engine?.inputNode.auAudioUnit, target: input.target, stage: .afterStart
    )
    let binding = try confirmInputAdmission(
      admission, target: input.target, route: .vpio,
      actualName: input.device?.localizedName ?? input.target.device.name
    )
    isRunning = true
    onStartStage?(.startRunning, nil)
    startStatsLogging()
    logger.info(
      "麦克风开始录制（VPIO，\(inputFormat.sampleRate, privacy: .public) Hz / \(inputFormat.channelCount, privacy: .public) 声道，ducking=advanced-min）"
    )
    return binding
  }

  private func startAVCaptureSessionOnCaptureQueue(
    input resolved: ResolvedInput, expectedGeneration: UInt64,
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    bufferHandler: AudioPCMBufferHandler?,
    reusingProcessor: AVCaptureMicrophoneSampleProcessor? = nil,
    onStartStage: MicrophoneStartStageObserver? = nil,
    processingFallback: String? = nil
  ) throws -> MicrophoneInputBinding {
    if verificationInputFormat != nil {
      let processor =
        try reusingProcessor?.adoptingConverter(from: resolved.format)
        ?? AVCaptureMicrophoneSampleProcessor(
          outputURL: outputURL, inputFormat: resolved.format,
          preferredChannels: resolved.preferredChannels,
          bufferHandler: bufferHandler, lossStatsBox: lossStatsBox, pauseGate: pauseGate,
          onFailure: { [failureBox] error in _ = failureBox.record(error) }
        )
      let session = AVCaptureSession()
      let output = AVCaptureAudioDataOutput()
      self.session = session
      audioOutput = output
      sampleProcessor = processor
      self.sessionEpochHostTime = sessionEpochHostTime
      publishRoute(.avCaptureSession)
      observeSessionFailures(session)
      let admission = try prepareInputAdmission(
        processor: processor, epoch: sessionEpochHostTime, expectedGeneration: expectedGeneration,
        output: output
      )
      let binding = try confirmInputAdmission(
        admission, target: resolved.target, route: .avCaptureSession,
        actualName: resolved.target.device.name, processingFallback: processingFallback
      )
      isRunning = true
      return binding
    }
    guard let device = resolved.device else {
      throw AudioCaptureError.microphoneUnavailable("所选采集设备不可用")
    }

    let input: AVCaptureDeviceInput
    do {
      input = try AVCaptureDeviceInput(device: device)
    } catch {
      throw AudioCaptureError.microphoneUnavailable(error.localizedDescription)
    }

    let session = AVCaptureSession()
    let output = AVCaptureAudioDataOutput()

    session.beginConfiguration()
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw AudioCaptureError.microphoneUnavailable("无法添加麦克风输入")
    }
    session.addInput(input)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw AudioCaptureError.microphoneUnavailable("无法添加 PCM 音频输出")
    }
    session.addOutput(output)
    session.commitConfiguration()

    let deviceFormat = resolved.format
    guard
      deviceFormat.sampleRate > 0,
      deviceFormat.channelCount > 0,
      deviceFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM
    else {
      throw AudioCaptureError.microphoneUnavailable("没有可用的麦克风输入格式")
    }
    var captureSettings = deviceFormat.settings
    captureSettings[AVLinearPCMIsFloatKey] = true
    captureSettings[AVLinearPCMBitDepthKey] = 32
    captureSettings[AVLinearPCMIsBigEndianKey] = false
    captureSettings[AVLinearPCMIsNonInterleaved] = false
    guard
      let inputFormat = AVAudioFormat(settings: captureSettings),
      inputFormat.commonFormat == .pcmFormatFloat32
    else {
      throw AudioCaptureError.microphoneUnavailable("无法配置 Float32 PCM 输出")
    }
    // 不显式钉住时，AVCaptureAudioDataOutput 的实际 ASBD 可能与
    // activeFormat 不同，writer 会在首个样本才报格式不匹配(本机实录已复现)。
    // VAD 与纯零看门狗都依赖 Float32，因此保留设备采样率/声道数，
    // 同时固定为交错 Float32 PCM。
    output.audioSettings = inputFormat.settings

    // 微信语音通话等场景会把输入设备切成 >2 声道(2026-07-31 实测开录直接失败)。
    // AVCaptureSession 保留设备原生采样率/声道数，仍须保留官方
    // 偏好声道选择与全平均兜底。
    let preferredChannels = resolved.preferredChannels
    let processor: AVCaptureMicrophoneSampleProcessor
    if let reusingProcessor {
      processor = try reusingProcessor.adoptingConverter(
        from: inputFormat,
        preferredChannels: preferredChannels
      )
    } else {
      do {
        processor = try AVCaptureMicrophoneSampleProcessor(
          outputURL: outputURL,
          inputFormat: inputFormat,
          preferredChannels: preferredChannels,
          bufferHandler: bufferHandler,
          lossStatsBox: lossStatsBox,
          pauseGate: pauseGate,
          onFailure: { [failureBox, logger] error in
            if failureBox.record(error) {
              logger.error(
                "AVCaptureSession 麦克风样本处理失败：\(error.localizedDescription, privacy: .public)"
              )
            }
          }
        )
      } catch {
        throw AudioCaptureError.audioWriteFailed(error.localizedDescription)
      }
    }

    if inputFormat.channelCount > 2 {
      if let channels = processor.selectedChannels {
        logger.info(
          "麦克风输入为 \(inputFormat.channelCount, privacy: .public) 声道，按设备偏好声道 \(channels[0], privacy: .public)/\(channels[1], privacy: .public) 降混为立体声"
        )
      } else {
        logger.warning(
          "麦克风输入为 \(inputFormat.channelCount, privacy: .public) 声道，设备未提供可用立体声声道，退回全声道平均降混"
        )
      }
    }

    output.setSampleBufferDelegate(self, queue: captureQueue)
    self.session = session
    audioOutput = output
    sampleProcessor = processor
    self.sessionEpochHostTime = sessionEpochHostTime
    publishRoute(.avCaptureSession)
    observeSessionFailures(session)

    let admission = try prepareInputAdmission(
      processor: processor, epoch: sessionEpochHostTime, expectedGeneration: expectedGeneration,
      output: output
    )
    session.startRunning()
    guard session.isRunning else {
      output.setSampleBufferDelegate(nil, queue: nil)
      stopObservingSessionFailures()
      tearDown(session)
      self.session = nil
      audioOutput = nil
      publishRoute(nil)
      if reusingProcessor == nil {
        // 新建 processor 才连带取消;rebuild 复用的 writer 要留给下次重试与收尾。
        sampleProcessor = nil
        self.sessionEpochHostTime = nil
        processor.cancel()
      }
      throw AudioCaptureError.microphoneUnavailable(
        "AVCaptureSession 未能进入运行状态"
      )
    }
    let binding: MicrophoneInputBinding
    do {
      guard input.device.isConnected, input.device.hasMediaType(.audio),
        input.device.uniqueID == resolved.target.device.captureID?.rawValue,
        try AudioInputDeviceMonitor.checkedDeviceID(for: resolved.target.device.uid)
          == resolved.target.device.objectID
      else {
        throw AudioCaptureError.microphoneUnavailable("麦克风启动后实际输入与所选设备不一致")
      }
      binding = try confirmInputAdmission(
        admission, target: resolved.target, route: .avCaptureSession,
        actualName: input.device.localizedName, processingFallback: processingFallback
      )
    } catch {
      // Both a false readback and a throwing HAL query retire this same pending session.
      retireInputAdmission()
      output.setSampleBufferDelegate(nil, queue: nil)
      stopObservingSessionFailures()
      session.stopRunning()
      tearDown(session)
      self.session = nil
      audioOutput = nil
      publishRoute(nil)
      throw error
    }
    // startRunning 返回且 session 确认运行才算完成;返回但未运行走上面的失败封闭。
    onStartStage?(.startRunning, nil)

    isRunning = true
    startStatsLogging()
    logger.info(
      "麦克风开始录制（AVCaptureSession，设备 \(device.localizedName, privacy: .public)，\(inputFormat.sampleRate, privacy: .public) Hz / \(inputFormat.channelCount, privacy: .public) 声道）"
    )
    return binding
  }

  private func stopOnCaptureQueue() -> StopResources {
    retireInputAdmission()
    let hadResources =
      isRunning
      || session != nil
      || audioOutput != nil
      || engine != nil
      || sampleProcessor != nil
    guard hadResources else {
      return StopResources(
        processor: nil,
        hadResources: false,
        routeDescription: nil
      )
    }

    let routeDescription = activeRoute?.rawValue
    startGenerationLock.withLock {
      latestRuntimeRecovery = nil
      runtimeRecoveryProgress = nil
    }
    isRunning = false
    stopStatsLogging()

    if activeRoute == .vpio || engine != nil {
      tearDownVPIOOnCaptureQueue(cancelProcessor: false)
    }

    audioOutput?.setSampleBufferDelegate(nil, queue: nil)
    stopObservingSessionFailures()
    if let session {
      session.stopRunning()
      tearDown(session)
    }

    session = nil
    audioOutput = nil
    let processor = sampleProcessor
    sampleProcessor = nil
    sessionEpochHostTime = nil
    startConfiguration = nil
    publishRoute(nil)
    return StopResources(
      processor: processor,
      hadResources: true,
      routeDescription: routeDescription
    )
  }

  private func tearDownVPIOOnCaptureQueue(cancelProcessor: Bool) {
    retireInputAdmission()
    verificationTap = nil
    if let engine {
      if tapInstalled {
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
      }
      if engine.isRunning {
        engine.stop()
      }
      if engine.inputNode.isVoiceProcessingEnabled {
        try? engine.inputNode.setVoiceProcessingEnabled(false)
      }
    }
    engine = nil
    tapInstalled = false
    if cancelProcessor {
      sampleProcessor?.cancel()
      sampleProcessor = nil
      sessionEpochHostTime = nil
      publishRoute(nil)
      isRunning = false
    }
  }

  private func tearDown(_ session: AVCaptureSession) {
    session.beginConfiguration()
    for output in session.outputs {
      session.removeOutput(output)
    }
    for input in session.inputs {
      session.removeInput(input)
    }
    session.commitConfiguration()
  }

  private func startStatsLogging() {
    stopStatsLogging()
    let timer = DispatchSource.makeTimerSource(queue: captureQueue)
    timer.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let description = self.captureLossStats.logDescription
      self.logger.info(
        "麦克风采集统计（60s）：\(description, privacy: .public)"
      )
    }
    statsTimer = timer
    timer.resume()
  }

  private func stopStatsLogging() {
    statsTimer?.cancel()
    statsTimer = nil
  }

  private func observeSessionFailures(_ session: AVCaptureSession) {
    stopObservingSessionFailures()
    let generation = sessionObservationGeneration
    let center = NotificationCenter.default
    sessionNotificationTokens = [
      center.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification,
        object: session,
        queue: nil
      ) { [weak self] notification in
        let detail =
          (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?
          .localizedDescription ?? "未知运行错误"
        self?.enqueueSessionFailure(
          "运行错误：\(detail)",
          generation: generation,
          isRuntimeError: true
        )
      },
      center.addObserver(
        forName: AVCaptureSession.wasInterruptedNotification,
        object: session,
        queue: nil
      ) { [weak self] _ in
        self?.enqueueSessionFailure(
          "采集会话被系统中断",
          generation: generation
        )
      },
      center.addObserver(
        forName: AVCaptureSession.didStopRunningNotification,
        object: session,
        queue: nil
      ) { [weak self] _ in
        self?.enqueueSessionFailure(
          "采集会话意外停止",
          generation: generation
        )
      },
    ]
  }

  private func stopObservingSessionFailures() {
    let center = NotificationCenter.default
    for token in sessionNotificationTokens {
      center.removeObserver(token)
    }
    sessionNotificationTokens.removeAll()
    sessionObservationGeneration &+= 1
  }

  private func enqueueSessionFailure(
    _ detail: String,
    generation: UInt,
    isRuntimeError: Bool = false
  ) {
    captureQueue.async { [weak self] in
      guard
        let self,
        self.sessionObservationGeneration == generation,
        self.session != nil,
        self.startGenerationLock.withLock({
          self.inputAdmission.map { $0.startGeneration == self.startGeneration } ?? false
        })
      else {
        return
      }
      if isRuntimeError {
        self.startGenerationLock.withLock {
          if self.latestRuntimeRecovery?.generation != generation {
            self.latestRuntimeRecovery = MicrophoneRuntimeRecoveryRequest(
              generation: generation, observedAt: Date()
            )
            self.runtimeRecoveryProgress = nil
          }
        }
      }
      self.recordSessionFailure(detail)
    }
  }

  private func confirmRuntimeRecoveryRebuild(
    _ request: MicrophoneRuntimeRecoveryRequest?, generation: UInt
  ) {
    guard let request, generation == sessionObservationGeneration, isRunning,
      generation != request.generation
    else { return }
    startGenerationLock.withLock {
      guard latestRuntimeRecovery == request else { return }
      runtimeRecoveryProgress = (request, lossStatsBox.snapshot().capturedFrames, Date())
    }
  }

  private func recordSessionFailure(_ detail: String) {
    let error = AudioCaptureError.audioWriteFailed("麦克风采集中断：\(detail)")
    if failureBox.record(error) {
      logger.error("AVCaptureSession 麦克风采集中断：\(detail, privacy: .public)")
    }
  }

  /// Runs a synthetic notification/sample operation on the same queue as AVCapture delegates.
  @_spi(Verification) public func withVerificationCapture(
    _ operation:
      @escaping @Sendable (
        AVCaptureSession?, AVCaptureAudioDataOutput?, UInt, UInt64?, ObjectIdentifier?
      ) -> Void
  ) async {
    precondition(verificationInputFormat != nil)
    await withCheckedContinuation { continuation in
      captureQueue.async { [self] in
        operation(
          session, audioOutput, sessionObservationGeneration, sessionEpochHostTime,
          sampleProcessor.map(ObjectIdentifier.init)
        )
        continuation.resume()
      }
    }
  }

  /// Exercises delayed notification/completion identities without touching hardware.
  @_spi(Verification) public func enqueueVerificationRuntimeError(generation: UInt) {
    precondition(verificationInputFormat != nil)
    enqueueSessionFailure("合成运行错误", generation: generation, isRuntimeError: true)
  }

  @_spi(Verification) public func completeVerificationRuntimeRebuild(
    _ request: MicrophoneRuntimeRecoveryRequest, generation: UInt
  ) async {
    precondition(verificationInputFormat != nil)
    await withCheckedContinuation { continuation in
      captureQueue.async { [self] in
        confirmRuntimeRecoveryRebuild(request, generation: generation)
        continuation.resume()
      }
    }
  }

  @_spi(Verification) public func withVerificationTap(
    _ operation: @escaping @Sendable (AVAudioNodeTapBlock?, UInt64?) -> Void
  ) async {
    precondition(verificationInputFormat != nil)
    await withCheckedContinuation { continuation in
      captureQueue.async { [self] in
        operation(verificationTap, sessionEpochHostTime)
        continuation.resume()
      }
    }
  }

  private func ensurePermission() async throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .audio)
      guard granted else {
        throw AudioCaptureError.microphonePermissionDenied
      }
    case .denied:
      throw AudioCaptureError.microphonePermissionDenied
    case .restricted:
      throw AudioCaptureError.microphonePermissionRestricted
    @unknown default:
      throw AudioCaptureError.microphonePermissionRestricted
    }
  }

  static func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else {
      return nil
    }
    return deviceID
  }

  /// 默认输入是否为蓝牙 HFP（戴耳机通话场景，走原路更稳）。
  static func isDefaultInputBluetoothHFP() -> Bool {
    guard let device = AVCaptureDevice.default(for: .audio) else {
      return false
    }
    let format = AVAudioFormat(
      cmAudioFormatDescription: device.activeFormat.formatDescription
    )
    return MicrophoneCaptureRoutePlanner.isBluetoothHFPInput(
      transportType: UInt32(bitPattern: device.transportType),
      inputChannelCount: format.channelCount
    )
  }
}
