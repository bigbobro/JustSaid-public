import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

// Core Audio process-tap setup is adapted from AudioCap by Guilherme Rambo:
// https://github.com/insidegui/AudioCap (BSD-2-Clause).
// The complete license is included in Support/ThirdPartyNotices.txt.
public final class SystemAudioCapture: SystemAudioCapturing, @unchecked Sendable {
  private let callbackQueue = DispatchQueue(
    label: "com.justsaid.system-audio-capture",
    qos: .userInitiated
  )
  private let logger = Logger(
    subsystem: "com.justsaid.app",
    category: "SystemAudioCapture"
  )
  private let failureBox = CaptureFailureBox()
  private let lossStatsBox = CaptureLossStatsBox()
  /// IO 与布局监听同跑在 `callbackQueue`，无需加锁。
  private let tapLayoutBox = TapStreamLayoutBox()

  private var processTapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
  private var deviceIOProcID: AudioDeviceIOProcID?
  private var streamConfigListenerBlock: AudioObjectPropertyListenerBlock?
  private var isStreamConfigListening = false
  private var writer: IncrementalM4AWriter?
  private var processingQueue: BoundedCaptureProcessingQueue?
  private var statsTimer: DispatchSourceTimer?
  private var isRunning = false
  /// rebuild 重建管线所需的开录参数(writer 之外的接线材料);stop 时清空。
  private var startConfiguration:
    (
      sessionEpochHostTime: UInt64,
      processIDs: [pid_t]?,
      bufferHandler: AudioPCMBufferHandler?
    )?
  /// 既有 writer 钉住的输入格式;rebuild 后新格式与它不一致按格式漂移失败封闭。
  private var writerInputFormat: AVAudioFormat?

  public init() {}

  public var captureLossStats: CaptureLossStats {
    lossStatsBox.snapshot()
  }

  public var firstCaptureFailure: (error: any Error, at: Date)? {
    failureBox.firstFailure
  }

  public func start(
    outputURL: URL,
    sessionEpochHostTime: UInt64,
    processIDs: [pid_t]? = nil,
    bufferHandler: AudioPCMBufferHandler? = nil
  ) async throws {
    guard !isRunning else {
      return
    }
    failureBox.reset()
    lossStatsBox.reset()
    tapLayoutBox.layout = nil

    do {
      let plan = try createTapAndAggregateDevice(processIDs: processIDs)

      let writer = try IncrementalM4AWriter(
        outputURL: outputURL,
        inputFormat: plan.writeFormat,
        lossStatsBox: lossStatsBox
      )
      self.writer = writer
      let processingQueue = BoundedCaptureProcessingQueue(
        label: "com.justsaid.system-audio-processing.\(UUID().uuidString)",
        sampleRate: plan.format.sampleRate
      )
      self.processingQueue = processingQueue

      try activateCoreAudioPipeline(
        plan: plan,
        sessionEpochHostTime: sessionEpochHostTime,
        writer: writer,
        processingQueue: processingQueue,
        bufferHandler: bufferHandler
      )

      startConfiguration = (sessionEpochHostTime, processIDs, bufferHandler)
      writerInputFormat = plan.writeFormat
      isRunning = true
      startStatsLogging()
      logger.info(
        "系统音频开始录制，模式：\((processIDs ?? []).isEmpty ? "全局" : "按进程", privacy: .public)"
      )
    } catch {
      stopStatsLogging()
      cleanUpCoreAudio()
      try? await tearDownWriter(finishing: false)
      throw error
    }
  }

  /// 自愈原语(08-05 单路故障自愈):拆掉并重建 tap/聚合设备/IO 回调/布局监听,
  /// **writer、processingQueue、lossStats 保持不动**——新样本仍按 session epoch 的
  /// hostTime 锚定,中断段由 writer 依时间轴保真契约补为等长静音。
  /// 重建时重读 tapFormat 与流布局;新写入格式与既有 writer 不一致时按格式漂移
  /// 失败封闭(禁止把不兼容 PCM 静默写入既有时间线)。由会话层健康监测驱动,
  /// 与 stop() 的互斥由会话层保证(先取消监测任务再收尾)。
  public func rebuild() async throws {
    guard
      isRunning,
      let writer,
      let processingQueue,
      let configuration = startConfiguration,
      let writerInputFormat
    else {
      throw AudioCaptureError.audioWriteFailed("系统音频采集未在运行，无法重建")
    }

    if aggregateDeviceID != kAudioObjectUnknown, let deviceIOProcID {
      let status = AudioDeviceStop(aggregateDeviceID, deviceIOProcID)
      if status != noErr {
        logger.warning("重建前停止系统音频设备失败：\(status, privacy: .public)")
      }
    }
    cleanUpCoreAudio()

    do {
      let plan = try createTapAndAggregateDevice(
        processIDs: configuration.processIDs
      )
      guard plan.writeFormat == writerInputFormat else {
        throw IncrementalM4AWriterError.inputFormatMismatch
      }
      try activateCoreAudioPipeline(
        plan: plan,
        sessionEpochHostTime: configuration.sessionEpochHostTime,
        writer: writer,
        processingQueue: processingQueue,
        bufferHandler: configuration.bufferHandler
      )
    } catch {
      cleanUpCoreAudio()
      throw error
    }
    logger.notice("系统音频采集管线已重建（tap/聚合设备/IO 回调）")
  }

  /// tap + 聚合设备 + 降混计划(start 与 rebuild 共用)。每次都重读 tapFormat 与
  /// 设备偏好声道——rebuild 时环境可能已变,不得沿用旧形态。
  private func createTapAndAggregateDevice(
    processIDs: [pid_t]?
  ) throws -> CoreAudioPipelinePlan {
    let processObjectIDs = try (processIDs ?? []).map(Self.processObjectID(for:))
    let tapDescription =
      if processObjectIDs.isEmpty {
        CATapDescription(stereoGlobalTapButExcludeProcesses: [])
      } else {
        CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
      }

    tapDescription.uuid = UUID()
    tapDescription.name = "JustSaid System Audio"
    tapDescription.isPrivate = true
    tapDescription.muteBehavior = .unmuted

    try createTap(using: tapDescription)
    let format = try tapFormat()
    let outputDeviceID = try Self.defaultSystemOutputDevice()
    let outputDeviceUID = try Self.deviceUID(for: outputDeviceID)
    try createAggregateDevice(
      tapDescription: tapDescription,
      outputDeviceUID: outputDeviceUID
    )

    // 通话场景下 tap/聚合设备可能呈 >2 声道。先问 Core Audio 设备该用哪两个
    // 立体声声道;聚合设备未提供时再问它的主输出设备,最终才由降混器平均兜底。
    let preferredChannels =
      PCMStereoDownmixer.preferredChannels(
        for: aggregateDeviceID,
        scope: kAudioDevicePropertyScopeInput
      )
      ?? PCMStereoDownmixer.preferredChannels(
        for: outputDeviceID,
        scope: kAudioDevicePropertyScopeOutput
      )
    let downmixer = PCMStereoDownmixer(
      inputFormat: format,
      preferredChannels: preferredChannels
    )
    if let downmixer {
      if let channels = downmixer.selectedChannels {
        logger.info(
          "系统音频为 \(format.channelCount, privacy: .public) 声道，按设备偏好声道 \(channels[0], privacy: .public)/\(channels[1], privacy: .public) 降混为立体声"
        )
      } else {
        logger.warning(
          "系统音频为 \(format.channelCount, privacy: .public) 声道，设备未提供可用立体声声道，退回全声道平均降混"
        )
      }
    }
    return CoreAudioPipelinePlan(
      format: format,
      downmixer: downmixer,
      writeFormat: downmixer?.outputFormat ?? format
    )
  }

  /// 装 IO 回调并启动聚合设备(start 与 rebuild 共用);writer/processingQueue/
  /// lossStats 由调用方持有,这里只接线,不重置任何统计。
  private func activateCoreAudioPipeline(
    plan: CoreAudioPipelinePlan,
    sessionEpochHostTime: UInt64,
    writer: IncrementalM4AWriter,
    processingQueue: BoundedCaptureProcessingQueue,
    bufferHandler: AudioPCMBufferHandler?
  ) throws {
    let format = plan.format
    let handoff = TapBufferHandoffBox(downmixer: plan.downmixer)
    let tapChannelCount = format.channelCount
    let initialLayout = try AggregateInputStreamQuery.layout(
      deviceID: aggregateDeviceID,
      tapChannelCount: tapChannelCount
    )
    tapLayoutBox.layout = initialLayout
    logger.info(
      "系统音频输入流布局：streams=\(initialLayout.streamChannelCounts, privacy: .public) tapBuffer=\(initialLayout.tapBufferRange.description, privacy: .public)"
    )
    try installStreamConfigurationListener(tapChannelCount: tapChannelCount)

    let layoutBox = tapLayoutBox
    let layoutMismatchLog = OnceFlag()
    let callback: AudioDeviceIOBlock = {
      [failureBox, logger, lossStatsBox, layoutBox, layoutMismatchLog, handoff]
      _, inputData, inputTime, _, _ in
      guard inputTime.pointee.mFlags.contains(.hostTimeValid) else {
        if failureBox.record(
          IncrementalM4AWriterError.invalidState("系统音频样本缺少 hostTime")
        ) {
          logger.error("系统音频样本缺少 hostTime")
        }
        return
      }

      let source = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inputData)
      )
      let bufferCount = source.count
      // 热路径：缓存 buffer 数匹配时零分配直接用区间；失配才扫 ABL 声道形态。
      let range: Range<Int>?
      if let cached = layoutBox.layout, cached.matchesBufferCount(bufferCount) {
        range = cached.tapBufferRange
      } else {
        var bufferChannelCounts: [UInt32] = []
        bufferChannelCounts.reserveCapacity(bufferCount)
        for index in 0..<bufferCount {
          bufferChannelCounts.append(source[index].mNumberChannels)
        }
        if let resolved = AggregateInputStreamMapper.resolveBufferRange(
          bufferChannelCounts: bufferChannelCounts,
          tapChannelCount: tapChannelCount,
          cached: nil
        ) {
          layoutBox.layout = AggregateInputStreamLayout(
            streamChannelCounts: bufferChannelCounts,
            tapStreamIndex: resolved.lowerBound,
            tapBufferRange: resolved,
            expectedBufferCount: bufferCount
          )
          layoutMismatchLog.reset()
          logger.info(
            "系统音频缓冲布局已按 ABL 重选：ch=\(bufferChannelCounts, privacy: .public) tapBuffer=\(resolved.description, privacy: .public)"
          )
          range = resolved
        } else {
          range = nil
          Self.recordDroppedInputFrames(
            source: source,
            format: format,
            lossStatsBox: lossStatsBox
          )
          if layoutMismatchLog.mark() {
            logger.error(
              "系统音频缓冲无法匹配 tap 流（nBuf=\(bufferCount, privacy: .public) ch=\(bufferChannelCounts, privacy: .public)），已计入 gap"
            )
          }
        }
      }

      guard let range else {
        return
      }

      guard
        let rawBuffer = Self.makeOwnedPCMBuffer(
          from: inputData,
          format: format,
          sourceBufferRange: range
        )
      else {
        Self.recordDroppedInputFrames(
          source: source,
          format: format,
          lossStatsBox: lossStatsBox
        )
        if layoutMismatchLog.mark() {
          logger.error("复制系统音频缓冲失败（tap 区间 \(range.description, privacy: .public)），已计入 gap")
        }
        return
      }
      layoutMismatchLog.reset()

      let frameCount = UInt64(rawBuffer.frameLength)
      lossStatsBox.recordCapturedFrames(frameCount)
      let captureTime = AudioCaptureClock.secondsSinceEpoch(
        hostTime: inputTime.pointee.mHostTime,
        epochHostTime: sessionEpochHostTime
      )
      let ticket = handoff.stage(rawBuffer)
      let accepted = processingQueue.submit(frameCount: frameCount) {
        guard let rawBuffer = handoff.take(ticket) else {
          return
        }
        let buffer: AVAudioPCMBuffer
        if let downmixer = handoff.downmixer {
          guard let converted = downmixer.convert(rawBuffer) else {
            if failureBox.record(AudioCaptureError.audioWriteFailed("多声道降混失败")) {
              logger.error("系统音频多声道降混失败")
            }
            return
          }
          buffer = converted
        } else {
          buffer = rawBuffer
        }

        var writeError: Error?
        do {
          try writer.append(buffer, at: captureTime)
        } catch {
          writeError = error
        }
        if let bufferHandler {
          bufferHandler(buffer, captureTime)
          lossStatsBox.recordASRFedFrames(UInt64(buffer.frameLength))
        }
        if let writeError, failureBox.record(writeError) {
          logger.error(
            "系统音频写入失败：\(writeError.localizedDescription, privacy: .public)"
          )
        }
      }
      if !accepted {
        _ = handoff.take(ticket)
        lossStatsBox.recordOverloadDrop(
          skippedFrames: bufferHandler == nil ? 0 : frameCount
        )
      }
    }

    var status = AudioDeviceCreateIOProcIDWithBlock(
      &deviceIOProcID,
      aggregateDeviceID,
      callbackQueue,
      callback
    )
    try Self.requireNoError(status, operation: "安装系统音频回调")

    status = AudioDeviceStart(aggregateDeviceID, deviceIOProcID)
    try Self.requireNoError(status, operation: "启动系统音频设备")
  }

  public func stop() async throws {
    guard isRunning || writer != nil || processTapID != kAudioObjectUnknown else {
      return
    }

    var firstError: Error?
    stopStatsLogging()

    if aggregateDeviceID != kAudioObjectUnknown, let deviceIOProcID {
      let status = AudioDeviceStop(aggregateDeviceID, deviceIOProcID)
      if status != noErr {
        firstError = AudioCaptureError.systemAudioTapFailed(
          operation: "停止系统音频设备",
          status: status
        )
      }
    }

    cleanUpCoreAudio()

    do {
      try await tearDownWriter(finishing: true)
    } catch {
      firstError = firstError ?? error
    }

    if let writeError = failureBox.take() {
      firstError = firstError ?? writeError
    }

    isRunning = false
    startConfiguration = nil
    writerInputFormat = nil
    let statsDescription = captureLossStats.logDescription
    logger.info(
      "系统音频采集统计（结束）：\(statsDescription, privacy: .public)"
    )
    logger.info("系统音频录制已停止")

    if let firstError {
      throw firstError
    }
  }

  private func createTap(using description: CATapDescription) throws {
    processTapID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateProcessTap(description, &processTapID)
    try Self.requireNoError(status, operation: "创建 Core Audio process tap")
    guard processTapID != kAudioObjectUnknown else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "创建 Core Audio process tap",
        status: kAudioHardwareBadObjectError
      )
    }
  }

  private func startStatsLogging() {
    stopStatsLogging()
    let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
    timer.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let description = self.captureLossStats.logDescription
      self.logger.info(
        "系统音频采集统计（60s）：\(description, privacy: .public)"
      )
    }
    statsTimer = timer
    timer.resume()
  }

  private func stopStatsLogging() {
    statsTimer?.cancel()
    statsTimer = nil
  }

  private func tapFormat() throws -> AVAudioFormat {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var streamDescription = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(
      processTapID,
      &address,
      0,
      nil,
      &size,
      &streamDescription
    )
    try Self.requireNoError(status, operation: "读取系统音频格式")

    guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "创建系统音频格式",
        status: kAudioHardwareUnsupportedOperationError
      )
    }
    return format
  }

  private func createAggregateDevice(
    tapDescription: CATapDescription,
    outputDeviceUID: String
  ) throws {
    let description: [String: Any] = [
      kAudioAggregateDeviceNameKey: "JustSaid-\(UUID().uuidString)",
      kAudioAggregateDeviceUIDKey: "com.justsaid.tap.\(UUID().uuidString)",
      kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [
        [
          kAudioSubDeviceUIDKey: outputDeviceUID
        ]
      ],
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
          kAudioSubTapDriftCompensationKey: true,
        ]
      ],
    ]

    aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateAggregateDevice(
      description as CFDictionary,
      &aggregateDeviceID
    )
    try Self.requireNoError(status, operation: "创建系统音频聚合设备")
  }

  private func installStreamConfigurationListener(tapChannelCount: UInt32) throws {
    removeStreamConfigurationListener()
    guard aggregateDeviceID != kAudioObjectUnknown else {
      return
    }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    let deviceID = aggregateDeviceID
    let layoutBox = tapLayoutBox
    let logger = self.logger
    let block: AudioObjectPropertyListenerBlock = { _, _ in
      do {
        let layout = try AggregateInputStreamQuery.layout(
          deviceID: deviceID,
          tapChannelCount: tapChannelCount
        )
        layoutBox.layout = layout
        logger.info(
          "系统音频输入流布局（监听）：streams=\(layout.streamChannelCounts, privacy: .public) tapBuffer=\(layout.tapBufferRange.description, privacy: .public)"
        )
      } catch {
        logger.warning(
          "系统音频输入流布局重算失败：\(error.localizedDescription, privacy: .public)"
        )
      }
    }

    let status = AudioObjectAddPropertyListenerBlock(
      deviceID,
      &address,
      callbackQueue,
      block
    )
    try Self.requireNoError(status, operation: "注册系统音频流布局监听")
    streamConfigListenerBlock = block
    isStreamConfigListening = true
  }

  private func removeStreamConfigurationListener() {
    guard
      isStreamConfigListening,
      aggregateDeviceID != kAudioObjectUnknown,
      let block = streamConfigListenerBlock
    else {
      streamConfigListenerBlock = nil
      isStreamConfigListening = false
      return
    }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectRemovePropertyListenerBlock(
      aggregateDeviceID,
      &address,
      callbackQueue,
      block
    )
    if status != noErr {
      logger.warning("注销系统音频流布局监听失败：\(status, privacy: .public)")
    }
    streamConfigListenerBlock = nil
    isStreamConfigListening = false
  }

  private func cleanUpCoreAudio() {
    // 先停监听再毁设备，与 install 对称。
    removeStreamConfigurationListener()

    if aggregateDeviceID != kAudioObjectUnknown {
      if let deviceIOProcID {
        let status = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceIOProcID)
        if status != noErr {
          logger.warning("销毁系统音频回调失败：\(status, privacy: .public)")
        }
        self.deviceIOProcID = nil
      }

      let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
      if status != noErr {
        logger.warning("销毁系统音频聚合设备失败：\(status, privacy: .public)")
      }
      aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    if processTapID != kAudioObjectUnknown {
      let status = AudioHardwareDestroyProcessTap(processTapID)
      if status != noErr {
        logger.warning("销毁系统音频 tap 失败：\(status, privacy: .public)")
      }
      processTapID = AudioObjectID(kAudioObjectUnknown)
    }

    tapLayoutBox.layout = nil
  }

  private func tearDownWriter(finishing: Bool) async throws {
    guard let writer else {
      return
    }
    self.writer = nil
    let processingQueue = self.processingQueue
    self.processingQueue = nil

    if finishing {
      await processingQueue?.finishAcceptingAndDrain()
      try await writer.finish()
    } else {
      processingQueue?.cancel()
      writer.cancel()
    }
  }

  /// 按流身份区间从 ABL 拷贝 tap PCM；不再要求 destination.count == 全量 source.count。
  private static func makeOwnedPCMBuffer(
    from audioBufferList: UnsafePointer<AudioBufferList>,
    format: AVAudioFormat,
    sourceBufferRange: Range<Int>
  ) -> AVAudioPCMBuffer? {
    guard
      format.streamDescription.pointee.mBytesPerFrame > 0,
      !sourceBufferRange.isEmpty
    else {
      return nil
    }
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
    let frameLength =
      first.mDataByteSize
      / format.streamDescription.pointee.mBytesPerFrame
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
    let destination = UnsafeMutableAudioBufferListPointer(
      copy.mutableAudioBufferList
    )
    guard destination.count == sourceBufferRange.count else {
      return nil
    }
    for (offset, sourceIndex) in sourceBufferRange.enumerated() {
      let byteCount = Int(source[sourceIndex].mDataByteSize)
      guard
        byteCount <= Int(destination[offset].mDataByteSize),
        let sourceData = source[sourceIndex].mData,
        let destinationData = destination[offset].mData
      else {
        return nil
      }
      memcpy(destinationData, sourceData, byteCount)
    }
    return copy
  }

  private static func recordDroppedInputFrames(
    source: UnsafeMutableAudioBufferListPointer,
    format: AVAudioFormat,
    lossStatsBox: CaptureLossStatsBox
  ) {
    let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
    guard bytesPerFrame > 0, let first = source.first, first.mDataByteSize > 0 else {
      return
    }
    let frames = UInt64(first.mDataByteSize / bytesPerFrame)
    if frames > 0 {
      lossStatsBox.recordGapFrames(frames)
    }
  }

  private static func processObjectID(for processID: pid_t) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var qualifier = processID
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        qualifierPointer,
        &size,
        &objectID
      )
    }
    try requireNoError(status, operation: "查找进程 \(processID)")

    guard objectID != kAudioObjectUnknown else {
      throw AudioCaptureError.systemAudioProcessUnavailable(processID)
    }
    return objectID
  }

  private static func defaultSystemOutputDevice() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
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
    try requireNoError(status, operation: "读取默认系统输出设备")
    return deviceID
  }

  private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &value
    )
    try requireNoError(status, operation: "读取默认系统输出设备标识")
    guard let value else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "读取默认系统输出设备标识",
        status: kAudioHardwareBadObjectError
      )
    }
    return value.takeRetainedValue() as String
  }

  private static func requireNoError(
    _ status: OSStatus,
    operation: String
  ) throws {
    guard status == noErr else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: operation,
        status: status
      )
    }
  }
}

/// start/rebuild 共用的管线材料:tap 格式、降混器与最终写入格式。
private struct CoreAudioPipelinePlan {
  let format: AVAudioFormat
  let downmixer: PCMStereoDownmixer?
  let writeFormat: AVAudioFormat
}

// Safety invariant: the ticket map is lock-protected and each ticket is taken exactly
// once; the generation's downmixer is queue-confined to the serial `processingQueue`.
/// 一次 start/rebuild 管线的交接所有权：IO 线程把新建的 rawBuffer 按票据寄存，
/// 由处理队列上唯一取走它的作业消费；该代 plan 的降混器也由本盒持有，只在串行
/// 处理队列上使用。每次 activateCoreAudioPipeline 新建一个，随该代 IO 回调与其
/// 未完成作业一起释放，因此旧代不会与新代共用票据空间。
private final class TapBufferHandoffBox: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [UInt64: AVAudioPCMBuffer] = [:]
  private var nextTicket: UInt64 = 0
  let downmixer: PCMStereoDownmixer?

  init(downmixer: PCMStereoDownmixer?) {
    self.downmixer = downmixer
  }

  func stage(_ buffer: AVAudioPCMBuffer) -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let ticket = nextTicket
    nextTicket &+= 1
    pending[ticket] = buffer
    return ticket
  }

  func take(_ ticket: UInt64) -> AVAudioPCMBuffer? {
    lock.lock()
    defer { lock.unlock() }
    return pending.removeValue(forKey: ticket)
  }
}

/// 仅由 `callbackQueue` 读写的布局缓存（IO 回调与 StreamConfiguration 监听共享）。
private final class TapStreamLayoutBox: @unchecked Sendable {
  var layout: AggregateInputStreamLayout?
}

/// 一次性日志开关，失配恢复后可 reset。
private final class OnceFlag: @unchecked Sendable {
  private var fired = false

  func mark() -> Bool {
    if fired {
      return false
    }
    fired = true
    return true
  }

  func reset() {
    fired = false
  }
}
