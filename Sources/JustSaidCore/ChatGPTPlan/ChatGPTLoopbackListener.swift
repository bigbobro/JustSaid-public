import Foundation
import Network

enum ChatGPTLoopbackError: Error, Equatable {
  case listenerFailed
  case timedOut
  case cancelled
}

/// 授权回调的一次性回环监听。
///
/// 只绑 `127.0.0.1`(不接 `::1`/外网),端口由系统分配;只认 `GET /auth/callback`,
/// 请求头超过上限回 431;第一个命中路径的请求即交付并关闭监听——state 不符同样消费本次
/// 尝试(失败即关,由调用方报错),不在同一监听上等下一个回调。其它路径(如 favicon)回 404,
/// 不消耗本次授权。授权尝试有存活期限,取消即关。
/// Safety invariant: listener/continuation/终态由 lock 保护;网络连接收包在私有串行 queue 上推进。
final class ChatGPTLoopbackListener: @unchecked Sendable {
  // 可变状态(listener/continuation/终态)全在 `lock` 内读写;网络回调跑在私有串行队列。
  private let maximumRequestBytes: Int
  private let queue = DispatchQueue(label: "com.justsaid.chatgpt-plan.loopback")
  private let lock = NSLock()
  private var listener: NWListener?
  private var continuation: CheckedContinuation<[URLQueryItem], Error>?
  private var delivered: [URLQueryItem]?
  private var failure: Error?

  init(maximumRequestBytes: Int = 16_384) {
    self.maximumRequestBytes = maximumRequestBytes
  }

  /// 开始监听并返回完整回调地址 `http://127.0.0.1:<port>/auth/callback`。
  func start() async throws -> URL {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    lock.withLock { self.listener = listener }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    let ready = OnceFlag()
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          if ready.fire() {
            if let port = listener.port?.rawValue {
              continuation.resume(returning: port)
            } else {
              continuation.resume(throwing: ChatGPTLoopbackError.listenerFailed)
            }
          }
        case .failed, .cancelled:
          if ready.fire() { continuation.resume(throwing: ChatGPTLoopbackError.listenerFailed) }
          self?.finish(with: .failure(ChatGPTLoopbackError.listenerFailed))
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
    guard let url = URL(string: "http://127.0.0.1:\(port)\(ChatGPTPlanContract.callbackPath)")
    else { throw ChatGPTLoopbackError.listenerFailed }
    return url
  }

  /// 等第一个命中路径的回调;超时或取消即关闭监听。
  func waitForCallback(timeout: TimeInterval) async throws -> [URLQueryItem] {
    try await withThrowingTaskGroup(of: [URLQueryItem].self) { group in
      group.addTask {
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            self.register(continuation)
          }
        } onCancel: {
          self.finish(with: .failure(ChatGPTLoopbackError.cancelled))
        }
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
        self.finish(with: .failure(ChatGPTLoopbackError.timedOut))
        throw ChatGPTLoopbackError.timedOut
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw ChatGPTLoopbackError.cancelled }
      return result
    }
  }

  func cancel() { finish(with: .failure(ChatGPTLoopbackError.cancelled)) }

  private func register(_ continuation: CheckedContinuation<[URLQueryItem], Error>) {
    lock.lock()
    if let delivered {
      lock.unlock()
      continuation.resume(returning: delivered)
      return
    }
    if let failure {
      lock.unlock()
      continuation.resume(throwing: failure)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  private func finish(with result: Result<[URLQueryItem], Error>) {
    lock.lock()
    guard delivered == nil, failure == nil else {
      lock.unlock()
      return
    }
    switch result {
    case .success(let items): delivered = items
    case .failure(let error): failure = error
    }
    let continuation = self.continuation
    self.continuation = nil
    let listener = self.listener
    self.listener = nil
    lock.unlock()
    listener?.cancel()
    continuation?.resume(with: result)
  }

  private var isFinished: Bool {
    lock.withLock { delivered != nil || failure != nil }
  }

  private func accept(_ connection: NWConnection) {
    guard !isFinished else { return connection.cancel() }
    connection.start(queue: queue)
    receive(on: connection, buffer: Data())
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
      [weak self] data, _, isComplete, error in
      guard let self else { return connection.cancel() }
      var buffer = buffer
      if let data { buffer.append(data) }
      if buffer.count > self.maximumRequestBytes {
        return self.respond(connection, status: "431 Request Header Fields Too Large", body: "")
      }
      guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        if isComplete || error != nil { return connection.cancel() }
        return self.receive(on: connection, buffer: buffer)
      }
      let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
      let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
      let fields = requestLine.split(separator: " ")
      guard fields.count == 3, fields[0] == "GET",
        let components = URLComponents(string: "http://127.0.0.1" + fields[1]),
        components.path == ChatGPTPlanContract.callbackPath
      else {
        return self.respond(connection, status: "404 Not Found", body: "")
      }
      guard !self.isFinished else {
        return self.respond(connection, status: "410 Gone", body: "")
      }
      self.respond(
        connection, status: "200 OK",
        body:
          "<!doctype html><meta charset=utf-8><title>JustSaid</title>"
          + "<p>已返回 JustSaid，可以关闭此页。</p>")
      self.finish(with: .success(components.queryItems ?? []))
    }
  }

  private func respond(_ connection: NWConnection, status: String, body: String) {
    let payload = Data(body.utf8)
    let head =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(head.utf8) + payload,
      completion: .contentProcessed { _ in connection.cancel() })
  }
}

/// 一次性开关:监听就绪回调可能来多次,只放行第一次。
/// Safety invariant: fired 的每次读写都持有 lock,锁不跨异步等待。
private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false

  func fire() -> Bool {
    lock.withLock {
      guard !fired else { return false }
      fired = true
      return true
    }
  }
}
