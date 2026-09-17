import AVFoundation
import Combine
import JustSaidCore

/// Local preview work belongs to this immutable meeting target, not the library selection.
/// Closing it cancels only this copy generation; it never touches recording or paid tasks.
@MainActor
final class EchoReductionModel: ObservableObject {
  enum Preview: String {
    case original = "原始麦克风"
    case processed = "处理副本"
  }

  let directory: URL
  let microphoneURL: URL
  let player = AVPlayer()
  @Published private(set) var report: PostMeetingEchoReductionService.Report?
  @Published private(set) var isEnabled = false
  @Published private(set) var isLoading = false
  @Published private(set) var isGenerating = false
  @Published private(set) var isSaving = false
  @Published private(set) var progress = 0.0
  @Published private(set) var preview: Preview?
  @Published private(set) var errorMessage: String?
  @Published private(set) var notice: String?
  @Published var confirmedSpeech = false

  private let service: PostMeetingEchoReductionService
  private let canChange: @MainActor () -> Bool
  private var operation: Task<Void, Never>?
  private var generation: UInt = 0
  private var playbackID = UUID()
  private var playbackObservation: NSKeyValueObservation?

  init(
    directory: URL,
    microphoneURL: URL,
    service: PostMeetingEchoReductionService = .shared,
    canChange: @escaping @MainActor () -> Bool
  ) {
    self.directory = directory
    self.microphoneURL = microphoneURL
    self.service = service
    self.canChange = canChange
  }

  var isBusy: Bool { isLoading || isGenerating || isSaving }

  static func canChange(_ item: MeetingLibraryItem, in library: MeetingLibraryModel) -> Bool {
    let current = library.meetings.first { $0.id == item.id } ?? item
    guard current.hasAudio, !current.isImportedRecording,
      current.status != .recording, current.status != .processing,
      !library.postMeetingTasks.isRunning(directory: item.paths.directory)
    else { return false }
    if let recording = library.recordingSession,
      recording.phase.isBusy,
      recording.currentMeetingDirectory?.standardizedFileURL
        == item.paths.directory.standardizedFileURL
    {
      return false
    }
    return true
  }

  func load() {
    guard !isBusy else { return }
    generation &+= 1
    let token = generation
    isLoading = true
    errorMessage = nil
    operation = Task { [weak self] in
      guard let self else { return }
      defer {
        if generation == token {
          isLoading = false
          operation = nil
        }
      }
      do {
        let result = try await service.existingResult(at: directory)
        try Task.checkCancellation()
        guard generation == token else { return }
        report = result
        isEnabled = result?.isEnabled == true
      } catch is CancellationError {
      } catch {
        guard generation == token else { return }
        errorMessage = "无法读取处理副本：\(error.localizedDescription)"
      }
    }
  }

  func generate() {
    guard !isBusy, canChange(), !isEnabled else { return }
    stopPlayback()
    generation &+= 1
    let token = generation
    isGenerating = true
    progress = 0
    confirmedSpeech = false
    errorMessage = nil
    notice = nil
    operation = Task { [weak self] in
      guard let self else { return }
      defer {
        if generation == token {
          isGenerating = false
          operation = nil
        }
      }
      do {
        guard canChange() else { throw PostMeetingEchoReductionError.busy }
        let result = try await service.generate(at: directory) { [weak self] value in
          Task { @MainActor [weak self] in
            guard let self, generation == token, value.isFinite else { return }
            progress = min(1, max(0, value))
          }
        }
        try Task.checkCancellation()
        guard generation == token else { return }
        report = result
        isEnabled = result.isEnabled
        notice = "副本已生成。请先试听，特别留意本人短句和双方同时说话的片段。"
      } catch is CancellationError {
        if generation == token { notice = "已取消生成，原录音和已有副本保留。" }
      } catch {
        guard generation == token else { return }
        errorMessage = "生成失败：\(error.localizedDescription)"
      }
    }
  }

  func setEnabled(_ enabled: Bool) {
    guard !isBusy, canChange(), !enabled || (report != nil && confirmedSpeech) else { return }
    generation &+= 1
    let token = generation
    let expectedID = report?.id
    isSaving = true
    errorMessage = nil
    notice = nil
    operation = Task { [weak self] in
      guard let self else { return }
      defer {
        if generation == token {
          isSaving = false
          operation = nil
        }
      }
      do {
        guard canChange() else { throw PostMeetingEchoReductionError.busy }
        try await service.setEnabled(
          enabled, at: directory, expectedResultID: enabled ? expectedID : nil)
        try Task.checkCancellation()
        guard generation == token else { return }
        isEnabled = enabled
        notice =
          enabled
          ? "已选择处理副本。需要时请关闭此面板，再点「重新精转」；精转仍需确认计费。"
          : "已恢复使用原录音；已有转写不变。"
      } catch is CancellationError {
      } catch {
        guard generation == token else { return }
        errorMessage = "未能更改精转输入：\(error.localizedDescription)"
      }
    }
  }

  func play(_ source: Preview) {
    let url: URL
    switch source {
    case .original: url = microphoneURL
    case .processed:
      guard let report else { return }
      url = report.outputURL
    }
    let position = player.currentTime()
    stopPlayback()
    let token = playbackID
    let item = AVPlayerItem(url: url)
    playbackObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      guard item.status == .failed else { return }
      let detail = item.error?.localizedDescription ?? "无法读取音频"
      Task { @MainActor [weak self] in
        guard let self, playbackID == token else { return }
        errorMessage = "试听失败：\(detail)"
      }
    }
    player.replaceCurrentItem(with: item)
    preview = source
    if position.isNumeric, position.seconds > 0 {
      player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    player.play()
  }

  func stopPlayback() {
    playbackID = UUID()
    player.pause()
    player.replaceCurrentItem(with: nil)
    playbackObservation = nil
    preview = nil
  }

  func cancel() {
    let wasGenerating = isGenerating
    generation &+= 1
    operation?.cancel()
    operation = nil
    isLoading = false
    isGenerating = false
    isSaving = false
    stopPlayback()
    if wasGenerating { notice = "已取消生成，原录音和已有副本保留。" }
  }
}
