import AppKit
import Combine
import JustSaidCore
import UniformTypeIdentifiers

/// One export owns one immutable failure snapshot. Collection and compression never run on the UI actor.
@MainActor
public final class RecoveryDiagnosticsModel: ObservableObject {
  public struct Result: Sendable {
    public let url: URL
    public let notes: [String]
    public init(url: URL, notes: [String]) {
      self.url = url
      self.notes = notes
    }
  }
  public typealias Export =
    @Sendable (URL, MeetingPaths?, String, LLMRecoveryAdvice?) async throws -> Result
  @Published public private(set) var isExporting = false
  @Published public private(set) var result: Result?
  @Published public private(set) var failure: String?
  @Published public private(set) var canExportGlobal = false
  private let exporter: Export

  public init(
    exporter: @escaping Export = { destination, paths, settings, advice in
      try await RecoveryDiagnosticsModel.collect(
        destination: destination, paths: paths, settings: settings, advice: advice)
    }
  ) {
    self.exporter = exporter
  }

  public func chooseDestination(paths: MeetingPaths?, settings: String, advice: LLMRecoveryAdvice?)
  {
    guard !isExporting else { return }
    if paths != nil {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.prompt = "导出"
      panel.message = "选择本场诊断包的保存文件夹；不包含会议正文和密钥。"
      panel.begin { [weak self] response in
        guard response == .OK, let url = panel.url else { return }
        self?.start(to: url, paths: paths, settings: settings, advice: advice)
      }
    } else {
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.zip]
      panel.nameFieldStringValue = DiagnosticsPackageBuilder.defaultFileName()
      panel.canCreateDirectories = true
      panel.prompt = "导出"
      panel.message = "诊断包不含会议正文与密钥，由你手动发送给 JustSaid 开发者。"
      panel.begin { [weak self] response in
        guard response == .OK, let url = panel.url else { return }
        self?.start(to: url, paths: nil, settings: settings, advice: advice)
      }
    }
  }

  public func start(
    to destination: URL, paths: MeetingPaths?, settings: String, advice: LLMRecoveryAdvice?
  ) {
    guard !isExporting else { return }
    isExporting = true
    result = nil
    failure = nil
    canExportGlobal = false
    let exporter = exporter
    Task {
      defer { isExporting = false }
      do {
        result = try await exporter(destination, paths, settings, advice)
      } catch is CancellationError {
        // Choosing cancel is not another failure and never erases the business failure.
      } catch MeetingDiagnosticsExportError.metadataUnreadable {
        failure = "本场资料无法读取，可改导出全局诊断。"
        canExportGlobal = true
      } catch {
        failure = "诊断包未能导出，请重新选择保存位置；仍失败可复制排查信息。"
      }
    }
  }

  public func reveal() {
    guard let url = result?.url else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  public nonisolated static func collect(
    destination: URL, paths: MeetingPaths?, settings: String, advice: LLMRecoveryAdvice?
  ) async throws -> Result {
    try await Task.detached(priority: .utility) {
      if let paths {
        let archive = try MeetingDiagnosticsPackageExporter().export(
          paths: paths, to: destination, recoveryAdvice: advice)
        // The per-meeting manifest records individual missing sources.
        return Result(url: archive, notes: ["资料缺项见包内 manifest.json；不含会议正文。"])
      }
      let report = try DiagnosticsPackageBuilder(
        settingsSnapshotText: settings, recoveryAdvice: advice
      )
      .export(to: destination)
      return Result(url: destination, notes: report.notes)
    }.value
  }
}
