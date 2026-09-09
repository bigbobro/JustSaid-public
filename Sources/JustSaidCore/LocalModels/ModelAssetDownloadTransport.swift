import Foundation

public enum ModelAssetDownloadError: Error, Equatable, Sendable {
  case cancelled
  case interrupted
  case invalidURL
  case insecureRedirect
  case nonHTTPResponse
  case unsuccessfulStatus(Int)
  case destinationExists
  case moveFailed

  public var asPrepareError: LocalModelPrepareError {
    switch self {
    case .cancelled:
      return .cancelled
    case .insecureRedirect, .invalidURL:
      return .unsafePath("下载地址不安全")
    case .interrupted:
      return .downloadFailed("下载中断,请重试")
    case .unsuccessfulStatus(let code):
      // 带上状态码:0 = 连接层中断,4xx/5xx = 上游资源问题,两者的处理完全不同。
      return .downloadFailed("下载失败(HTTP \(code))")
    case .nonHTTPResponse, .destinationExists, .moveFailed:
      return .downloadFailed("下载失败")
    }
  }
}

public final class URLSessionModelAssetDownloadTransport: NSObject, ModelAssetDownloadTransport,
  URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable
{
  private var session: URLSession!
  private let lock = NSLock()
  private var tasks: [Int: InFlight] = [:]

  private struct InFlight {
    var destination: URL
    var progress: @Sendable (Int64, Int64?) -> Void
    var continuation: CheckedContinuation<URL, Error>
  }

  public override init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 6 * 60 * 60
    configuration.urlCache = nil
    super.init()
    self.session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: nil
    )
  }

  deinit {
    session.invalidateAndCancel()
  }

  public func download(
    _ request: LocalModelDownloadRequest,
    progress: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws -> URL {
    guard request.url.scheme?.lowercased() == "https" else {
      throw ModelAssetDownloadError.invalidURL
    }
    if FileManager.default.fileExists(atPath: request.destination.path) {
      try FileManager.default.removeItem(at: request.destination)
    }
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = "GET"
    urlRequest.setValue(nil, forHTTPHeaderField: "Authorization")
    urlRequest.setValue(nil, forHTTPHeaderField: "Cookie")
    urlRequest.httpShouldHandleCookies = false

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = session.downloadTask(with: urlRequest)
        lock.lock()
        tasks[task.taskIdentifier] = InFlight(
          destination: request.destination,
          progress: progress,
          continuation: continuation
        )
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      session.getAllTasks { tasks in
        for task in tasks { task.cancel() }
      }
    }
  }

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    lock.lock()
    let progress = tasks[downloadTask.taskIdentifier]?.progress
    lock.unlock()
    let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
    progress?(totalBytesWritten, total)
  }

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    lock.lock()
    guard let inflight = tasks[downloadTask.taskIdentifier] else {
      lock.unlock()
      return
    }
    lock.unlock()

    let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
    do {
      guard let status else { throw ModelAssetDownloadError.nonHTTPResponse }
      guard (200..<300).contains(status) else {
        throw ModelAssetDownloadError.unsuccessfulStatus(status)
      }
      try FileManager.default.createDirectory(
        at: inflight.destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: inflight.destination.path) {
        try FileManager.default.removeItem(at: inflight.destination)
      }
      // 优先改名:879 MB 的包再整拷一份会让磁盘峰值多出一整份下载体积。
      do {
        try FileManager.default.moveItem(at: location, to: inflight.destination)
      } catch {
        try FileManager.default.copyItem(at: location, to: inflight.destination)
      }
      finish(taskIdentifier: downloadTask.taskIdentifier, result: .success(inflight.destination))
    } catch {
      finish(taskIdentifier: downloadTask.taskIdentifier, result: .failure(error))
    }
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      if (error as? URLError)?.code == .cancelled {
        finish(
          taskIdentifier: task.taskIdentifier,
          result: .failure(ModelAssetDownloadError.cancelled)
        )
      } else if error is URLError {
        // 连接层断掉(超时、连接重置、代理掐流)按"中断可重试"报,不要伪装成 HTTP 状态。
        finish(
          taskIdentifier: task.taskIdentifier,
          result: .failure(ModelAssetDownloadError.interrupted)
        )
      } else {
        finish(
          taskIdentifier: task.taskIdentifier,
          result: .failure(ModelAssetDownloadError.unsuccessfulStatus(0))
        )
      }
    }
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    if request.url?.scheme?.lowercased() == "https" {
      completionHandler(request)
    } else {
      completionHandler(nil)
      finish(
        taskIdentifier: task.taskIdentifier,
        result: .failure(ModelAssetDownloadError.insecureRedirect)
      )
    }
  }

  private func finish(taskIdentifier: Int, result: Result<URL, Error>) {
    lock.lock()
    guard let inflight = tasks.removeValue(forKey: taskIdentifier) else {
      lock.unlock()
      return
    }
    lock.unlock()
    switch result {
    case .success(let url):
      inflight.continuation.resume(returning: url)
    case .failure(let error):
      inflight.continuation.resume(throwing: error)
    }
  }
}

public final class FakeModelAssetDownloadTransport: ModelAssetDownloadTransport, @unchecked Sendable
{
  public struct RecordedRequest: Equatable, Sendable {
    public var url: URL
    public var expectedBytes: Int64
  }

  public var filesByURL: [URL: URL] = [:]
  public var errorsByURL: [URL: Error] = [:]
  public var interruptAfterBytes: Int64?
  public var artificialDelayNanoseconds: UInt64 = 0
  private let lock = NSLock()
  private var recorded: [RecordedRequest] = []

  public init() {}

  public var requests: [RecordedRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  public var requestCount: Int { requests.count }

  public var requestedURLs: [URL] { requests.map(\.url) }

  private func record(_ request: RecordedRequest) {
    lock.lock()
    recorded.append(request)
    lock.unlock()
  }

  public func download(
    _ request: LocalModelDownloadRequest,
    progress: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws -> URL {
    record(RecordedRequest(url: request.url, expectedBytes: request.expectedBytes))
    let source = filesByURL[request.url]
    let injectedError = errorsByURL[request.url]
    let interrupt = interruptAfterBytes

    if let injectedError {
      throw injectedError
    }
    guard let source else {
      throw ModelAssetDownloadError.unsuccessfulStatus(404)
    }
    try Task.checkCancellation()
    if artificialDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: artificialDelayNanoseconds)
      try Task.checkCancellation()
    }

    let data = try Data(contentsOf: source)
    if let interrupt, interrupt < data.count {
      progress(interrupt, Int64(data.count))
      // 网络中断不是用户取消:必须走可重试失败,不能静默回到 idle。
      throw ModelAssetDownloadError.interrupted
    }
    progress(Int64(data.count), Int64(data.count))
    try FileManager.default.createDirectory(
      at: request.destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: request.destination.path) {
      try FileManager.default.removeItem(at: request.destination)
    }
    try data.write(to: request.destination, options: [.atomic])
    return request.destination
  }
}
