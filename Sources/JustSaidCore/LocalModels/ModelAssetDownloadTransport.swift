import Darwin
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
  /// 续传分片打不开或写不进去。盘满等写入失败时已写下的前缀仍有效、分片留着;上游给的字节比清单多时
  /// 多出的那块不写,分片也留着;打开后发现分片被换成别的东西(类型、链接数、长度对不上)就删掉它。
  case writeFailed

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
    case .writeFailed:
      return .downloadFailed("下载分片写入失败")
    case .nonHTTPResponse, .destinationExists, .moveFailed:
      return .downloadFailed("下载失败")
    }
  }
}

/// 一次 HTTP 往返的可核对记录:只有锁定地址、Range、状态码、字节数与耗时,不含任何用户数据。
/// 续传是否真的从分片接着下(206),还是悄悄从头又下了一遍(200),只有它看得出来。
/// 一次 `download` 里可能有两次往返:416 之后丢掉分片、不带 Range 重下。
public struct ModelAssetDownloadExchange: Equatable, Sendable {
  public enum Outcome: String, Equatable, Sendable {
    case completed
    case cancelled
    case interrupted
    /// 416,或 206 的 Content-Range 不是从分片末尾开始:分片已丢掉,紧接着不带 Range 重下。
    case rangeNotSatisfiable
    case failed
  }

  /// 清单锁定的地址(跟跳转之前)。
  public let url: URL
  /// 跟完跳转后实际回应的主机名(HF 先 302 到 CDN);只留主机,不留带签名的完整地址。
  public let finalHost: String?
  public let redirectCount: Int
  /// 这次往返开始时分片里已有、准备接着下的字节数;0 = 从头下。
  public let resumeOffset: Int64
  /// 实际发往最后一跳(跟完跳转之后)的 Range 头;nil = 没带。
  public let rangeHeader: String?
  /// 最后一跳的 HTTP 状态;nil = 没收到响应。
  public let status: Int?
  /// 这次往返写进分片的字节数。
  public let bytesReceived: Int64
  public let seconds: Double
  public let outcome: Outcome
}

/// 续传分片在盘上的全部规则。URLSession transport 与 fake transport 共用这一份,fake 只扮服务器,
/// 所以孤立检查打到的就是生产逻辑:
/// - 分片在 `LocalModelDownloadRequest.partialURL`(`<模型根>/.downloads/`);目录不在就建,
///   是符号链接就拒绝。分片不是普通文件、是硬链接、或比清单还长:删掉从头下。
/// - 与清单一样长:不联网,直接交给整文件校验(上次下满了、没来得及改名就退出)。
/// - 比清单短:带 `Range: bytes=<分片长度>-`。206 且 Content-Range 从分片末尾开始才接上去;
///   其余 2xx 是服务器无视了 Range,截掉分片从头写,不能把整个文件接在旧前缀后面;
///   416 或 Content-Range 起点对不上:丢掉分片,不带 Range 再问一次(只会有一次:丢掉之后就不带
///   Range 了)。
/// - 回应与清单对不上的不碰分片:200 的 Content-Length 不是清单大小(代理、中间盒的拦截页)、
///   206 的 Content-Range 总长不是清单大小(另一份上游),都按失败报、分片原样留着;正文写之前按清单
///   大小封顶,分片不会比清单长。
/// - 非 2xx、取消、断网,以及正文干净地结束却没到清单大小(有上限的 206、提前收尾):分片原样留着,
///   下次接着下。到清单大小才把分片改名成 `destination`,之后由引擎做 size + SHA-256 整文件校验;
///   校验是唯一的安装门。
///
/// 不是 Sendable:一次 `download` 独占一个实例,同一时刻只有一处在用它
/// (URLSession transport 里是串行的委托队列)。
final class ModelAssetPartialFile {
  enum Disposition: Equatable {
    /// 收下这次回应的正文(206 接在分片后面,其余 2xx 从头写)。
    case receive
    /// 分片已丢掉,不带 Range 重下一次。
    case restartWithoutRange
  }

  let partialURL: URL
  let destination: URL
  let expectedBytes: Int64
  /// 分片现在有多少字节。
  private(set) var length: Int64 = 0
  /// 这次往返开始时分片的长度;大于 0 就是带了 `Range: bytes=<它>-`。
  private(set) var resumeOffset: Int64 = 0
  /// 这次往返写进分片的字节数。
  private(set) var received: Int64 = 0
  /// 整个文件的字节数,做进度的分母:206 取 Content-Range 的总长,200 取 Content-Length,
  /// 都没有就用清单值。
  private(set) var total: Int64?
  /// 这次往返的回应已收下、正文正在写进分片。
  private(set) var receivingBody = false
  private var handle: FileHandle?

  init(_ request: LocalModelDownloadRequest) throws {
    partialURL = request.partialURL
    destination = request.destination
    expectedBytes = request.expectedBytes
    // `.downloads` 不在就建;它若是符号链接,这里抛 unsafePath,分片不会写到模型根之外。
    try LocalModelFileIO.requireWritableDirectoryChain(
      root: request.partialURL.deletingLastPathComponent(),
      fileManager: FileManager.default
    )
    var info = stat()
    if lstat(request.partialURL.path, &info) == 0 {
      let size = Int64(info.st_size)
      if (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 && size <= request.expectedBytes {
        length = size
      } else {
        // 符号链接、目录、硬链接都不拿来续写;比清单还长的(例如 200 被接在旧前缀后面留下的)
        // 不可能是这份文件的前缀。删掉(符号链接只删链接本身),从头下。
        do {
          try FileManager.default.removeItem(at: request.partialURL)
        } catch {
          throw ModelAssetDownloadError.writeFailed
        }
      }
    } else if errno != ENOENT {
      throw ModelAssetDownloadError.writeFailed
    }
  }

  /// 分片已经与清单一样长:不必再联网。
  var isComplete: Bool {
    length > 0 && length == expectedBytes
  }

  /// 开始一次往返:起点记为分片当前长度,返回要带的 Range 头;nil = 不带,从头下。
  func beginExchange() -> String? {
    close()
    resumeOffset = length
    received = 0
    total = nil
    receivingBody = false
    return length > 0 ? "bytes=\(length)-" : nil
  }

  /// 服务器的回应(状态码与头)决定正文怎么写,见类型注释。非 2xx(带 Range 时的 416 除外)抛
  /// `ModelAssetDownloadError.unsuccessfulStatus`,分片不动。
  func respond(status: Int, contentRange: String?, contentLength: Int64?) throws -> Disposition {
    let askedForRange = resumeOffset > 0
    if askedForRange && status == 416 {
      discard()
      return .restartWithoutRange
    }
    if askedForRange && status == 206 {
      // 总长不是清单大小:这段字节来自另一份上游,接上去只会拼出一个怪文件。分片与清单一致,
      // 错的是上游,所以分片留着,按失败报。
      if let total = Self.contentRange(contentRange)?.total, total != expectedBytes {
        throw ModelAssetDownloadError.unsuccessfulStatus(status)
      }
      guard let range = Self.contentRange(contentRange), range.start == resumeOffset else {
        // 给的不是分片末尾之后的那段:接上去就错位,不如丢掉重下。
        discard()
        return .restartWithoutRange
      }
      try openForWriting(truncating: false)
      total = range.total ?? contentLength.map { resumeOffset + $0 } ?? expectedBytes
      return .receive
    }
    guard (200..<300).contains(status), status != 206 else {
      throw ModelAssetDownloadError.unsuccessfulStatus(status)
    }
    // 长度不是清单大小的 200 不可能是这份文件(代理、中间盒的拦截页最常见):截掉之前就拒绝,
    // 好分片不能换成一页 HTML。
    if let contentLength, contentLength != expectedBytes {
      throw ModelAssetDownloadError.unsuccessfulStatus(status)
    }
    try openForWriting(truncating: true)
    total = contentLength ?? expectedBytes
    return .receive
  }

  /// 把正文接到分片末尾。先写盘、再报进度:报出去的字节一定已经在分片里。写之前按清单大小封顶:
  /// 上游多给的那块不写,分片不会长过清单、占满盘。
  func append(_ data: Data) throws {
    guard let handle, Int64(data.count) <= expectedBytes - length else {
      throw ModelAssetDownloadError.writeFailed
    }
    do {
      try handle.write(contentsOf: data)
    } catch {
      throw ModelAssetDownloadError.writeFailed
    }
    length += Int64(data.count)
    received += Int64(data.count)
  }

  /// 关掉句柄,分片留在盘上。可以重复调用。
  func close() {
    try? handle?.close()
    handle = nil
  }

  /// 丢掉分片:下一次往返从 0 开始。
  func discard() {
    close()
    try? FileManager.default.removeItem(at: partialURL)
    length = 0
    received = 0
    receivingBody = false
  }

  /// 下完:分片改名成 `destination`(同在模型根下,只改名不复制)。改名失败分片留着。
  /// 没到清单大小(有上限的 206、正文提前干净地结束)按中断报:分片留着,下次从它的长度接着下;
  /// 交出去只会被整文件校验判成大小不一致,连已下的前缀一起丢掉。
  func finish() throws -> URL {
    close()
    guard length == expectedBytes else { throw ModelAssetDownloadError.interrupted }
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.moveItem(at: partialURL, to: destination)
    } catch {
      throw ModelAssetDownloadError.moveFailed
    }
    length = 0
    receivingBody = false
    return destination
  }

  /// 206 接在分片末尾(`O_APPEND`),其余从头写(`O_TRUNC`)。`O_NOFOLLOW` 加打开后的 fstat:
  /// 分片在检查之后被换成符号链接、硬链接或长度变了,都不往里写。
  private func openForWriting(truncating: Bool) throws {
    close()
    let start = truncating ? 0 : resumeOffset
    let mode = truncating ? O_TRUNC : O_APPEND
    let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | mode
    let descriptor = open(partialURL.path, flags, 0o644)
    guard descriptor >= 0 else { throw ModelAssetDownloadError.writeFailed }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1, Int64(info.st_size) == start
    else {
      Darwin.close(descriptor)
      discard()
      throw ModelAssetDownloadError.writeFailed
    }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    length = start
    received = 0
    receivingBody = true
  }

  /// `Content-Range: bytes <起点>-<终点>/<总长或 *>`;解析不了返回 nil。
  static func contentRange(_ value: String?) -> (start: Int64, total: Int64?)? {
    guard let value else { return nil }
    let text = value.trimmingCharacters(in: .whitespaces)
    let unit = "bytes "
    guard text.lowercased().hasPrefix(unit) else { return nil }
    let parts = text.dropFirst(unit.count).split(
      separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let bounds = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2,
      let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
      let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
      start >= 0, end >= start
    else { return nil }
    return (start, Int64(parts[1].trimmingCharacters(in: .whitespaces)))
  }
}

public final class URLSessionModelAssetDownloadTransport: NSObject, ModelAssetDownloadTransport,
  URLSessionDataDelegate, @unchecked Sendable
{
  private var session: URLSession!
  /// 保护 `jobs`、`jobIDsByTask`、`nextJobID`,以及每个 `Job` 的 `continuation`、`task`、`cancelled`。
  private let lock = NSLock()
  private var jobs: [Int: Job] = [:]
  private var jobIDsByTask: [Int: Int] = [:]
  private var nextJobID = 0
  /// 每次 HTTP 往返结束时回报一次;只有真实下载验收传,App 不传。
  private let exchangeObserver: (@Sendable (ModelAssetDownloadExchange) -> Void)?

  /// 一次 `download` 调用。416 之后不带 Range 重下时,同一个 Job 换一个 URLSession 任务。
  /// `continuation`、`task`、`cancelled` 由 transport 的 `lock` 保护;`file` 与 `exchange` 只在
  /// URLSession 的委托队列(串行)上读写,第一个任务开始之前由 `download` 设好。
  private final class Job {
    let id: Int
    let request: LocalModelDownloadRequest
    let file: ModelAssetPartialFile
    let progress: @Sendable (Int64, Int64?) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    var task: URLSessionDataTask?
    var cancelled = false
    var exchange: Exchange?

    init(
      id: Int,
      request: LocalModelDownloadRequest,
      file: ModelAssetPartialFile,
      progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) {
      self.id = id
      self.request = request
      self.file = file
      self.progress = progress
    }
  }

  /// 正在进行的那次 HTTP 往返;结束时变成一条 `ModelAssetDownloadExchange`。
  private struct Exchange {
    let startedAt = Date()
    let resumeOffset: Int64
    let requestedRange: String?
    var sentRange: String?
    var redirectCount = 0
    var finalHost: String?
    var status: Int?
  }

  public override convenience init() {
    self.init(exchangeObserver: nil)
  }

  /// 真实下载验收用:每次 HTTP 往返结束时把 `ModelAssetDownloadExchange` 交给 `exchangeObserver`
  /// (在 URLSession 的回调线程上调用)。
  @_spi(Verification)
  public init(exchangeObserver: (@Sendable (ModelAssetDownloadExchange) -> Void)?) {
    self.exchangeObserver = exchangeObserver
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 60
    // 整次下载的上限。到点是 URLError.timedOut,与断网一样按「中断」报、分片留着,重试接着下。
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
    try Task.checkCancellation()
    let file = try ModelAssetPartialFile(request)
    if file.isComplete {
      progress(file.length, file.length)
      return try file.finish()
    }
    let job = register(request: request, file: file, progress: progress)
    let jobID = job.id
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        job.continuation = continuation
        lock.unlock()
        start(job)
      }
    } onCancel: {
      cancel(jobID: jobID)
    }
  }

  private func register(
    request: LocalModelDownloadRequest,
    file: ModelAssetPartialFile,
    progress: @escaping @Sendable (Int64, Int64?) -> Void
  ) -> Job {
    lock.lock()
    defer { lock.unlock() }
    nextJobID += 1
    let job = Job(id: nextJobID, request: request, file: file, progress: progress)
    jobs[job.id] = job
    return job
  }

  /// 发起一次往返:分片里有字节就带 `Range: bytes=<分片长度>-`。已被取消就按取消收尾,不再发请求。
  private func start(_ job: Job) {
    let offset = job.file.length
    let range = job.file.beginExchange()
    var request = URLRequest(url: job.request.url)
    request.httpMethod = "GET"
    Self.applyHeaders(to: &request, range: range)
    let task = session.dataTask(with: request)
    lock.lock()
    if job.cancelled {
      lock.unlock()
      // 没登记的任务:它的回调都会被忽略,取消只是让它不占着 session。
      task.cancel()
      complete(job, outcome: .cancelled, result: .failure(ModelAssetDownloadError.cancelled))
      return
    }
    job.task = task
    job.exchange = Exchange(resumeOffset: offset, requestedRange: range)
    jobIDsByTask[task.taskIdentifier] = job.id
    lock.unlock()
    task.resume()
  }

  /// 每一跳(包括 HF 302 之后的 CDN)都用这一组头:不带凭证与 Cookie;要原始字节(identity),
  /// Range 的偏移才是文件里的偏移;续传时带同一个 Range,跳转后的请求丢了它,CDN 就会回 200 从头下。
  private static func applyHeaders(to request: inout URLRequest, range: String?) {
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue(nil, forHTTPHeaderField: "Cookie")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(range, forHTTPHeaderField: "Range")
    request.httpShouldHandleCookies = false
  }

  private func cancel(jobID: Int) {
    lock.lock()
    let job = jobs[jobID]
    job?.cancelled = true
    let task = job?.task
    lock.unlock()
    task?.cancel()
  }

  private func job(forTask taskIdentifier: Int) -> Job? {
    lock.lock()
    defer { lock.unlock() }
    return jobIDsByTask[taskIdentifier].flatMap { jobs[$0] }
  }

  /// 这个任务的回调不再归 Job 管(416 之后换了新任务):之后它的回调都忽略。
  private func detach(taskIdentifier: Int) {
    lock.lock()
    jobIDsByTask[taskIdentifier] = nil
    lock.unlock()
  }

  /// 一次 download 只收尾一次:先从表里摘掉,关掉分片句柄,再回报往返、恢复 continuation。
  /// 句柄先关、引擎才往下走:取消后马上续传时,新任务打开分片之前旧句柄已经关了。
  private func complete(
    _ job: Job,
    outcome: ModelAssetDownloadExchange.Outcome,
    result: Result<URL, Error>
  ) {
    lock.lock()
    guard jobs.removeValue(forKey: job.id) != nil else {
      lock.unlock()
      return
    }
    if let task = job.task {
      jobIDsByTask[task.taskIdentifier] = nil
    }
    let continuation = job.continuation
    job.continuation = nil
    lock.unlock()
    job.file.close()
    report(job, outcome: outcome)
    continuation?.resume(with: result)
  }

  private func report(_ job: Job, outcome: ModelAssetDownloadExchange.Outcome) {
    guard let exchange = job.exchange else { return }
    job.exchange = nil
    exchangeObserver?(
      ModelAssetDownloadExchange(
        url: job.request.url,
        finalHost: exchange.finalHost,
        redirectCount: exchange.redirectCount,
        resumeOffset: exchange.resumeOffset,
        rangeHeader: exchange.sentRange,
        status: exchange.status,
        bytesReceived: job.file.received,
        seconds: Date().timeIntervalSince(exchange.startedAt),
        outcome: outcome
      ))
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let job = job(forTask: task.taskIdentifier) else {
      completionHandler(nil)
      return
    }
    guard request.url?.scheme?.lowercased() == "https" else {
      completionHandler(nil)
      task.cancel()
      job.exchange?.status = response.statusCode
      job.exchange?.finalHost = response.url?.host
      complete(job, outcome: .failed, result: .failure(ModelAssetDownloadError.insecureRedirect))
      return
    }
    job.exchange?.redirectCount += 1
    var redirected = request
    Self.applyHeaders(to: &redirected, range: job.exchange?.requestedRange)
    completionHandler(redirected)
  }

  public func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let job = job(forTask: dataTask.taskIdentifier) else {
      completionHandler(.cancel)
      return
    }
    job.exchange?.finalHost = response.url?.host
    // 最后一跳(跟完跳转之后)实际带出去的 Range:续传有没有真的接上,看的是它。
    job.exchange?.sentRange = dataTask.currentRequest?.value(forHTTPHeaderField: "Range")
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      complete(job, outcome: .failed, result: .failure(ModelAssetDownloadError.nonHTTPResponse))
      return
    }
    job.exchange?.status = http.statusCode
    let disposition: ModelAssetPartialFile.Disposition
    do {
      disposition = try job.file.respond(
        status: http.statusCode,
        contentRange: http.value(forHTTPHeaderField: "Content-Range"),
        contentLength: http.expectedContentLength > 0 ? http.expectedContentLength : nil
      )
    } catch {
      completionHandler(.cancel)
      complete(job, outcome: .failed, result: .failure(error))
      return
    }
    switch disposition {
    case .receive:
      completionHandler(.allow)
      job.progress(job.file.length, job.file.total)
    case .restartWithoutRange:
      completionHandler(.cancel)
      report(job, outcome: .rangeNotSatisfiable)
      detach(taskIdentifier: dataTask.taskIdentifier)
      start(job)
    }
  }

  public func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard let job = job(forTask: dataTask.taskIdentifier) else { return }
    do {
      try job.file.append(data)
    } catch {
      dataTask.cancel()
      complete(job, outcome: .failed, result: .failure(error))
      return
    }
    job.progress(job.file.length, job.file.total)
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let job = job(forTask: task.taskIdentifier) else { return }
    if job.exchange?.sentRange == nil {
      job.exchange?.sentRange = task.currentRequest?.value(forHTTPHeaderField: "Range")
    }
    if let error {
      if (error as? URLError)?.code == .cancelled {
        complete(job, outcome: .cancelled, result: .failure(ModelAssetDownloadError.cancelled))
      } else if error is URLError {
        // 连接层断掉(超时、连接重置、代理掐流、6 h 资源上限)按「中断可重试」报,不伪装成 HTTP 状态;
        // 分片留着,重试从它的长度接着下。
        complete(job, outcome: .interrupted, result: .failure(ModelAssetDownloadError.interrupted))
      } else {
        complete(
          job, outcome: .failed, result: .failure(ModelAssetDownloadError.unsuccessfulStatus(0)))
      }
      return
    }
    guard job.file.receivingBody else {
      complete(job, outcome: .failed, result: .failure(ModelAssetDownloadError.nonHTTPResponse))
      return
    }
    // 正文干净地结束却没到清单大小(有上限的 206、提前收尾):与断网一样按中断报,分片留着接着下。
    guard job.file.length == job.file.expectedBytes else {
      complete(job, outcome: .interrupted, result: .failure(ModelAssetDownloadError.interrupted))
      return
    }
    do {
      let downloaded = try job.file.finish()
      complete(job, outcome: .completed, result: .success(downloaded))
    } catch {
      complete(job, outcome: .failed, result: .failure(error))
    }
  }
}

public final class FakeModelAssetDownloadTransport: ModelAssetDownloadTransport, @unchecked Sendable
{
  public struct RecordedRequest: Equatable, Sendable {
    public var url: URL
    public var expectedBytes: Int64
    public var partialURL: URL
  }

  /// 模拟的服务器怎么对待 `Range: bytes=N-`。
  public enum RangeBehavior: Equatable, Sendable {
    /// 照 HTTP 规矩:带 Range 回 206 与 N 之后的字节,N 不在文件内回 416;不带 Range 回 200 整个文件。
    case honorsRange
    /// 无视 Range,一律回 200 整个文件(有的 CDN 与代理就这样)。
    case ignoresRange
    /// 下一次带 Range 的请求回 416,之后照 `honorsRange`。
    case rangeNotSatisfiableOnce
    /// 下一次带 Range 的请求回 200 和一页短 HTML(代理或中间盒的拦截页),之后照 `honorsRange`。
    case blockPageOnce
  }

  public var filesByURL: [URL: URL] = [:]
  public var errorsByURL: [URL: Error] = [:]
  /// 这次往返收到这么多字节后断开,抛 `.interrupted`(网络中断,不是用户取消)。
  public var interruptAfterBytes: Int64?
  /// 从网络交出整文件之后取消调用方所在的任务:模拟最后一字节刚到、用户就点了「取消」,
  /// 引擎下一个取消点(校验之前)抛 CancellationError。
  public var cancelsAfterDelivery = false
  public var artificialDelayNanoseconds: UInt64 = 0
  public var rangeBehavior: RangeBehavior {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedRangeBehavior
    }
    set {
      lock.lock()
      storedRangeBehavior = newValue
      lock.unlock()
    }
  }
  private let lock = NSLock()
  private var storedRangeBehavior: RangeBehavior = .honorsRange
  private var recorded: [RecordedRequest] = []
  private var recordedExchanges: [ModelAssetDownloadExchange] = []

  public init() {}

  public var requests: [RecordedRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  public var requestCount: Int { requests.count }

  public var requestedURLs: [URL] { requests.map(\.url) }

  /// 模拟服务器的每一次 HTTP 往返,按发生顺序。
  public var exchanges: [ModelAssetDownloadExchange] {
    lock.lock()
    defer { lock.unlock() }
    return recordedExchanges
  }

  private func record(_ request: RecordedRequest) {
    lock.lock()
    recorded.append(request)
    lock.unlock()
  }

  private func record(_ exchange: ModelAssetDownloadExchange) {
    lock.lock()
    recordedExchanges.append(exchange)
    lock.unlock()
  }

  /// 带 Range 的请求要按哪种行为回;`rangeNotSatisfiableOnce`、`blockPageOnce` 用过一次就回到
  /// `honorsRange`。
  private func takeRangeBehavior() -> RangeBehavior {
    lock.lock()
    defer { lock.unlock() }
    let current = storedRangeBehavior
    if current == .rangeNotSatisfiableOnce || current == .blockPageOnce {
      storedRangeBehavior = .honorsRange
    }
    return current
  }

  public func download(
    _ request: LocalModelDownloadRequest,
    progress: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws -> URL {
    record(
      RecordedRequest(
        url: request.url,
        expectedBytes: request.expectedBytes,
        partialURL: request.partialURL
      ))
    let source = filesByURL[request.url]
    let injectedError = errorsByURL[request.url]
    let interrupt = interruptAfterBytes
    let cancelAfterDelivery = cancelsAfterDelivery

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

    let whole = try Data(contentsOf: source)
    // 分片怎么续、遇到 206 / 200 / 416 怎么办,与 URLSession transport 走同一个 ModelAssetPartialFile;
    // 这里只扮服务器。
    let file = try ModelAssetPartialFile(request)
    if file.isComplete {
      progress(file.length, file.length)
      return try file.finish()
    }
    // 最多两次往返:416 之后分片已丢,第二次不带 Range,不会再 416。
    for _ in 0..<2 {
      let offset = file.length
      let range = file.beginExchange()
      let reply = serve(whole, offset: offset, rangeRequested: range != nil)
      func exchange(_ outcome: ModelAssetDownloadExchange.Outcome, bytes: Int64)
        -> ModelAssetDownloadExchange
      {
        ModelAssetDownloadExchange(
          url: request.url,
          finalHost: request.url.host,
          redirectCount: 0,
          resumeOffset: offset,
          rangeHeader: range,
          status: reply.status,
          bytesReceived: bytes,
          seconds: 0,
          outcome: outcome
        )
      }
      let disposition: ModelAssetPartialFile.Disposition
      do {
        disposition = try file.respond(
          status: reply.status,
          contentRange: reply.contentRange,
          contentLength: Int64(reply.body.count)
        )
      } catch {
        record(exchange(.failed, bytes: 0))
        throw error
      }
      if disposition == .restartWithoutRange {
        record(exchange(.rangeNotSatisfiable, bytes: 0))
        continue
      }
      progress(file.length, file.total)
      if let interrupt, interrupt < Int64(reply.body.count) {
        try file.append(reply.body.prefix(Int(interrupt)))
        progress(file.length, file.total)
        file.close()
        record(exchange(.interrupted, bytes: interrupt))
        // 网络中断不是用户取消:必须走可重试失败,不能静默回到 idle;已收到的字节留在分片里。
        throw ModelAssetDownloadError.interrupted
      }
      let downloaded: URL
      do {
        try file.append(reply.body)
        progress(file.length, file.total)
        downloaded = try file.finish()
      } catch {
        // 写不进分片、或没写到清单大小:这次往返也留下记录,检查才看得出停在了哪一步。
        let outcome: ModelAssetDownloadExchange.Outcome =
          (error as? ModelAssetDownloadError) == .interrupted ? .interrupted : .failed
        record(exchange(outcome, bytes: file.received))
        throw error
      }
      record(exchange(.completed, bytes: Int64(reply.body.count)))
      if cancelAfterDelivery {
        withUnsafeCurrentTask { task in
          if let task { task.cancel() }
        }
      }
      return downloaded
    }
    throw ModelAssetDownloadError.unsuccessfulStatus(416)
  }

  /// 扮服务器:按 `rangeBehavior` 回状态码、Content-Range 与正文。
  private func serve(_ whole: Data, offset: Int64, rangeRequested: Bool) -> (
    status: Int, contentRange: String?, body: Data
  ) {
    let size = Int64(whole.count)
    guard rangeRequested else { return (200, nil, whole) }
    switch takeRangeBehavior() {
    case .ignoresRange:
      return (200, nil, whole)
    case .rangeNotSatisfiableOnce:
      return (416, "bytes */\(size)", Data())
    case .blockPageOnce:
      return (200, nil, Data("<html><body>blocked</body></html>".utf8))
    case .honorsRange:
      guard offset < size else { return (416, "bytes */\(size)", Data()) }
      let rest = whole.subdata(in: Int(offset)..<whole.count)
      return (206, "bytes \(offset)-\(size - 1)/\(size)", rest)
    }
  }
}
