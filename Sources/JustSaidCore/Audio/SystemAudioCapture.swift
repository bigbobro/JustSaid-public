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
  private let callbackQueueKey = DispatchSpecificKey<Void>()
  private let logger = Logger(
    subsystem: "com.justsaid.app",
    category: "SystemAudioCapture"
  )
  private let failureBox = CaptureFailureBox()
  private let lossStatsBox = CaptureLossStatsBox()
  /// Activation ownership and all listener/cache mutation stay on callbackQueue.
  private var inputState: SystemAudioCaptureInputState?

  private var processTapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
  private var deviceIOProcID: AudioDeviceIOProcID?
  private var streamConfigListenerBlocks:
    [(selector: AudioObjectPropertySelector, block: AudioObjectPropertyListenerBlock)] = []
  private var streamFormatListenerBlocks:
    [(streamID: AudioStreamID, block: AudioObjectPropertyListenerBlock)] = []
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

  public init() {
    callbackQueue.setSpecific(key: callbackQueueKey, value: ())
  }

  /// Hardware-free verification activation. The supplied writer and input
  /// state are the same production objects used by the runtime path; no tap,
  /// aggregate device, IO proc, or listener is created by this initializer.
  @_spi(Verification) public convenience init(
    verificationWriter: IncrementalM4AWriter,
    verificationInputState: SystemAudioCaptureInputState
  ) {
    self.init()
    writer = verificationWriter
    inputState = verificationInputState
    isRunning = true
  }

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
      guard
        SystemAudioCaptureFormatPlanFactory.writerFormatMatches(
          candidate: plan.writeFormat,
          existing: writerInputFormat
        )
      else {
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

  /// tap + 聚合设备 + 降混计划(start 与 rebuild 共用)。tap format 只作为
  /// 选择提示；聚合设备建立后立即读取实际 selected stream 的完整 VirtualFormat，
  /// 并让该格式贯穿 plan、PCM 包装、降混与初始 writer。
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
    let tapFormat = try tapFormat()
    let outputDeviceID = try Self.defaultSystemOutputDevice()
    let outputDeviceUID = try Self.deviceUID(for: outputDeviceID)
    try createAggregateDevice(
      tapDescription: tapDescription,
      outputDeviceUID: outputDeviceUID
    )

    // The tap is queried before aggregate creation for a channel-count hint only.
    // The aggregate's selected stream is the authoritative format provenance.
    let capturePlan = try AggregateInputStreamQuery.capturePlan(
      deviceID: aggregateDeviceID,
      tapFormat: AggregateInputStreamFormat(
        tapFormat.streamDescription.pointee
      )
    )
    guard
      let selectedStream = capturePlan.streamLayout.selectedStream,
      let format = capturePlan.inputFormat.makeAVAudioFormat()
    else {
      throw AudioCaptureError.systemAudioTapFailed(
        operation: "创建实际系统音频输入格式",
        status: kAudioHardwareUnsupportedOperationError
      )
    }

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
      tapFormatSnapshot: capturePlan.tapFormat,
      selectedStreamID: selectedStream.streamID,
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
    let inputState = try installStreamConfigurationListener(
      tapFormat: plan.tapFormatSnapshot,
      expectedVirtualFormat: AggregateInputStreamFormat(format.streamDescription.pointee),
      selectedStreamID: plan.selectedStreamID
    )
    performOnCallbackQueue {
      let layout = inputState.layout
      let writerFormat = AggregateInputStreamFormat(plan.writeFormat.streamDescription.pointee)
      logger.notice(
        "系统音频格式计划已确认：tap=\(Self.formatLogDescription(plan.tapFormatSnapshot), privacy: .public) selectedStream=\(layout?.selectedStream?.streamID ?? 0, privacy: .public) range=\(layout?.tapBufferRange.description ?? "invalid", privacy: .public) input=\(Self.formatLogDescription(layout?.selectedStream?.virtualFormat), privacy: .public) writer=\(Self.formatLogDescription(writerFormat), privacy: .public)"
      )
    }
    let layoutMismatchLog = OnceFlag()
    let callback: AudioDeviceIOBlock = {
      [
        failureBox, logger, lossStatsBox, inputState, layoutMismatchLog, handoff
      ]
      _, inputData, inputTime, _, _ in
      guard !inputState.isRetired else { return }
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
      // No Core Audio property query or channel-only fallback in the callback.
      // Admission and PCM copying consume this activation's monitored layout.
      guard let rawBuffer = inputState.makeOwned(from: inputData) else {
        Self.recordDroppedInputFrames(
          source: source,
          format: format,
          lossStatsBox: lossStatsBox
        )
        if layoutMismatchLog.mark() {
          logger.error("系统音频输入格式/布局未确认或缓冲复制失败，已计入 gap")
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
    do {
      try performOnCallbackQueue {
        // A format notification may have retired admission during IO setup.
        // Do not report a known-invalid activation as successfully started.
        guard !inputState.isRetired else {
          throw failureBox.firstFailure?.error ?? IncrementalM4AWriterError.inputFormatMismatch
        }
      }
    } catch {
      let stopStatus = AudioDeviceStop(aggregateDeviceID, deviceIOProcID)
      if stopStatus != noErr {
        logger.warning("失效系统音频启动后停止设备失败：\(stopStatus, privacy: .public)")
      }
      // start/rebuild's existing catch unregisters listeners and destroys IO.
      throw error
    }
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

  private func installStreamConfigurationListener(
    tapFormat: AggregateInputStreamFormat,
    expectedVirtualFormat: AggregateInputStreamFormat,
    selectedStreamID: AudioStreamID
  ) throws -> SystemAudioCaptureInputState {
    try performOnCallbackQueue {
      removeStreamConfigurationListenerOnCallbackQueue()
      guard aggregateDeviceID != kAudioObjectUnknown else {
        throw AudioCaptureError.systemAudioTapFailed(
          operation: "注册系统音频监听时聚合设备无效", status: kAudioHardwareBadObjectError
        )
      }
      let deviceID = aggregateDeviceID
      let state = SystemAudioCaptureInputState(
        expectedFormat: expectedVirtualFormat,
        selectedStreamID: selectedStreamID
      )
      inputState = state
      let refresh: @Sendable () -> Void = { [weak self, state] in
        self?.refreshStreamLayout(deviceID: deviceID, tapFormat: tapFormat, state: state)
      }
      // Stream IDs can change without any channel-shape change. Both topology
      // properties must be observed before reading/registering a selected stream.
      do {
        for selector in [
          kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyStreams,
        ] {
          var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
          )
          let block: AudioObjectPropertyListenerBlock = { _, _ in refresh() }
          let status = AudioObjectAddPropertyListenerBlock(
            deviceID, &address, callbackQueue, block
          )
          try Self.requireNoError(status, operation: "注册系统音频输入流监听")
          streamConfigListenerBlocks.append((selector, block))
        }
        try updateStreamLayout(deviceID: deviceID, tapFormat: tapFormat, state: state)
      } catch {
        removeStreamConfigurationListenerOnCallbackQueue()
        throw error
      }
      return state
    }
  }

  /// Initial installation and notifications share the production read/register/
  /// reread transaction. Registration collections and publication are serialized
  /// with IO by callbackQueue; a retired notification cannot rearm its cache.
  private func updateStreamLayout(
    deviceID: AudioDeviceID,
    tapFormat: AggregateInputStreamFormat,
    state: SystemAudioCaptureInputState
  ) throws {
    try refreshInputState(
      state: state,
      queryWithExpectedSelection: { expectedStreamID, expectedVirtualFormat in
        try AggregateInputStreamQuery.capturePlan(
          deviceID: deviceID,
          tapFormat: tapFormat,
          expectedStreamID: expectedStreamID,
          expectedVirtualFormat: expectedVirtualFormat
        )
      },
      monitor: { streamID in
        try addStreamFormatListener(
          for: streamID,
          refresh: { [weak self, state] in
            self?.refreshStreamLayout(deviceID: deviceID, tapFormat: tapFormat, state: state)
          }
        )
      }
    )
  }

  /// Shared error-recording boundary for initial installation, runtime
  /// notifications, and the hardware-free SPI verification path. A retired
  /// state keeps its first typed format failure for `stop()` to consume;
  /// recoverable query/topology errors are deliberately not recorded.
  private func refreshInputState(
    state: SystemAudioCaptureInputState,
    queryWithExpectedSelection:
      (_ expectedStreamID: AudioStreamID?, _ expectedVirtualFormat: AggregateInputStreamFormat)
      throws -> SystemAudioCaptureFormatPlan,
    monitor: (AudioStreamID) throws -> Void
  ) throws {
    do {
      try state.refresh(
        queryWithExpectedSelection: queryWithExpectedSelection,
        monitor: monitor
      )
    } catch {
      recordRetiredInputFailure(error, state: state)
      throw error
    }
  }

  /// Runs the same state refresh and retired-error recording on the serial
  /// callback queue without touching hardware. Verification uses this to feed
  /// a raw-descriptor mutation through the real production admission path, then
  /// calls `stop()` so the normal writer/failureBox handoff remains exercised.
  @_spi(Verification) public func refreshVerificationInputFormat(
    queryWithExpectedSelection:
      (_ expectedStreamID: AudioStreamID?, _ expectedVirtualFormat: AggregateInputStreamFormat)
      throws -> SystemAudioCaptureFormatPlan,
    monitor: (AudioStreamID) throws -> Void
  ) throws {
    try performOnCallbackQueue {
      guard let state = inputState else {
        throw AudioCaptureError.systemAudioTapFailed(
          operation: "合成系统音频输入状态不存在",
          status: kAudioHardwareBadObjectError
        )
      }
      try refreshInputState(
        state: state,
        queryWithExpectedSelection: queryWithExpectedSelection,
        monitor: monitor
      )
    }
  }

  private func refreshStreamLayout(
    deviceID: AudioDeviceID,
    tapFormat: AggregateInputStreamFormat,
    state: SystemAudioCaptureInputState
  ) {
    guard !state.isRetired else { return }
    do {
      try updateStreamLayout(deviceID: deviceID, tapFormat: tapFormat, state: state)
      let layout = state.layout
      logger.info(
        "系统音频输入流布局（监听）：selectedStream=\(layout?.selectedStream?.streamID ?? 0, privacy: .public) tapBuffer=\(layout?.tapBufferRange.description ?? "invalid", privacy: .public) rate=\(layout?.selectedStream?.virtualFormat.sampleRate ?? 0, privacy: .public)"
      )
    } catch {
      // refreshInputState() already logs the first retired error.
      if !state.isRetired {
        logger.warning("系统音频输入布局暂不可用：\(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func recordRetiredInputFailure(
    _ error: Error,
    state: SystemAudioCaptureInputState
  ) {
    guard state.isRetired else { return }
    if failureBox.record(error) {
      logger.error("系统音频格式或监听失效，旧计划已停用：\(error.localizedDescription, privacy: .public)")
    }
  }

  private func addStreamFormatListener(
    for streamID: AudioStreamID,
    refresh: @escaping @Sendable () -> Void
  ) throws {
    guard !streamFormatListenerBlocks.contains(where: { $0.streamID == streamID }) else {
      return
    }
    var formatAddress = AudioObjectPropertyAddress(
      mSelector: kAudioStreamPropertyVirtualFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let formatBlock: AudioObjectPropertyListenerBlock = { _, _ in
      refresh()
    }
    let formatStatus = AudioObjectAddPropertyListenerBlock(
      streamID,
      &formatAddress,
      callbackQueue,
      formatBlock
    )
    try Self.requireNoError(formatStatus, operation: "注册系统音频 VirtualFormat 监听")
    streamFormatListenerBlocks.append((streamID, formatBlock))
  }

  private func removeStreamConfigurationListener() {
    performOnCallbackQueue {
      removeStreamConfigurationListenerOnCallbackQueue()
    }
  }

  private func removeStreamConfigurationListenerOnCallbackQueue() {
    // Invalidate before unregistering or destroying IO. Already queued old IO
    // and listener closures retain a permanently retired activation.
    inputState?.retire()
    inputState = nil
    for entry in streamConfigListenerBlocks {
      var address = AudioObjectPropertyAddress(
        mSelector: entry.selector,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
      )
      let status = AudioObjectRemovePropertyListenerBlock(
        aggregateDeviceID, &address, callbackQueue, entry.block
      )
      if status != noErr {
        logger.warning("注销系统音频输入流监听失败：\(status, privacy: .public)")
      }
    }
    for entry in streamFormatListenerBlocks {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyVirtualFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      let status = AudioObjectRemovePropertyListenerBlock(
        entry.streamID,
        &address,
        callbackQueue,
        entry.block
      )
      if status != noErr {
        logger.warning("注销系统音频 VirtualFormat 监听失败：\(status, privacy: .public)")
      }
    }
    streamConfigListenerBlocks.removeAll()
    streamFormatListenerBlocks.removeAll()
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
  }

  private func performOnCallbackQueue<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: callbackQueueKey) != nil {
      return try body()
    }
    return try callbackQueue.sync {
      try body()
    }
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

  private static func formatLogDescription(
    _ format: AggregateInputStreamFormat?
  ) -> String {
    guard let format else {
      return "invalid"
    }
    return
      "rate=\(format.sampleRate) id=\(format.formatID) flags=\(format.formatFlags) bytesPerPacket=\(format.bytesPerPacket) framesPerPacket=\(format.framesPerPacket) bytesPerFrame=\(format.bytesPerFrame) channels=\(format.channelsPerFrame) bits=\(format.bitsPerChannel)"
  }
}

/// start/rebuild 共用的管线材料:tap 格式、降混器与最终写入格式。
private struct CoreAudioPipelinePlan {
  let format: AVAudioFormat
  let tapFormatSnapshot: AggregateInputStreamFormat
  let selectedStreamID: AudioStreamID
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
