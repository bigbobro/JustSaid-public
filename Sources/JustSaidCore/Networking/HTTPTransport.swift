import Foundation

public protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
  func upload(
    for request: URLRequest,
    fromFile fileURL: URL
  ) async throws -> (Data, HTTPURLResponse)
  /// 逐行读响应体,**空行必须原样产出**——SSE 用空行分隔事件,吞掉空行等于在解析之前
  /// 就丢掉了事件边界(多行 `data:` 再也拼不回一个负载)。实测取证见 task
  /// `08-06-llm-streaming-sse/research/sse-lines-probe.md`。
  func lines(
    for request: URLRequest
  ) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

public enum HTTPTransportError: LocalizedError, Sendable {
  case nonHTTPResponse
  case unsuccessfulStatus(code: Int, body: String)

  public var errorDescription: String? {
    switch self {
    case .nonHTTPResponse:
      return "服务返回了无法识别的响应"
    case .unsuccessfulStatus(let code, _):
      // body 保留在 typed error 内供调用方做本机调试；LocalizedError 是 UI 与
      // `.public` OSLog 的共享出口，绝不能把 provider body 带进去。
      return "服务请求失败（HTTP \(code)）"
    }
  }

  public var statusCode: Int? {
    guard case .unsuccessfulStatus(let code, _) = self else { return nil }
    return code
  }

  public var diagnosticCategory: String {
    switch self {
    case .nonHTTPResponse:
      return "network"
    case .unsuccessfulStatus(let code, _):
      if (400..<500).contains(code) { return "http4xx" }
      if (500..<600).contains(code) { return "http5xx" }
      return "network"
    }
  }

  /// Provider body 只允许贡献一个稳定短码；其余正文永远不出 typed error 的投影。
  public var providerErrorCode: String? {
    guard case .unsuccessfulStatus(_, let body) = self,
      let data = body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let candidates: [Any?] = [
      object["code"],
      (object["error"] as? [String: Any])?["code"],
      (object["error"] as? [String: Any])?["type"],
    ]
    for candidate in candidates {
      guard let value = candidate as? String else { continue }
      let code = DiagnosticSanitizer.token(value, fallback: "")
      if !code.isEmpty { return String(code.prefix(64)) }
    }
    return nil
  }
}

public struct URLSessionHTTPTransport: HTTPTransport {
  private let session: URLSession
  private let streamingLimits: HTTPStreamingLimits

  /// 保留原构造签名：既有调用与 `URLSessionHTTPTransport.init` 函数引用都不需要迁移。
  public init(session: URLSession = .shared) {
    self.session = session
    self.streamingLimits = HTTPStreamingLimits()
  }

  /// 显式预算注入只用于特殊供应商配置与 verification；生产默认继续走上面的构造器。
  public init(
    session: URLSession,
    streamingLimits: HTTPStreamingLimits
  ) {
    self.session = session
    self.streamingLimits = streamingLimits
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw HTTPTransportError.nonHTTPResponse
    }
    return (data, httpResponse)
  }

  public func upload(
    for request: URLRequest,
    fromFile fileURL: URL
  ) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.upload(
      for: request,
      fromFile: fileURL
    )
    guard let httpResponse = response as? HTTPURLResponse else {
      throw HTTPTransportError.nonHTTPResponse
    }
    return (data, httpResponse)
  }

  /// 基于原始字节序列自行切行。**不用 `bytes.lines`(`AsyncLineSequence`)**:实测它会
  /// 静默丢弃全部空行,SSE 事件边界随之消失(2026-08-06 探针取证)。
  /// framing 同时执行 line/event/response 三层预算，异常服务端不能靠不换行或不发空行
  /// 让进程内存随连接寿命无界增长。
  public func lines(
    for request: URLRequest
  ) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
    let (bytes, response) = try await session.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw HTTPTransportError.nonHTTPResponse
    }
    let limits = streamingLimits
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        var framer = HTTPLineFramer(limits: limits)
        do {
          for try await byte in bytes {
            try Task.checkCancellation()
            if let line = try framer.append(byte) {
              continuation.yield(line)
            }
          }
          if let finalLine = try framer.finish() {
            continuation.yield(finalLine)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    return (stream, httpResponse)
  }
}

extension HTTPTransport {
  func validatedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await self.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data.prefix(2_048), encoding: .utf8) ?? ""
      throw HTTPTransportError.unsuccessfulStatus(
        code: response.statusCode,
        body: body
      )
    }
    return (data, response)
  }

  func validatedUpload(
    for request: URLRequest,
    fromFile fileURL: URL
  ) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await upload(
      for: request,
      fromFile: fileURL
    )
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: data.prefix(2_048), encoding: .utf8) ?? ""
      throw HTTPTransportError.unsuccessfulStatus(
        code: response.statusCode,
        body: body
      )
    }
    return (data, response)
  }

  /// 流式版的状态码校验:非 2xx 时先读有限长度的错误体,再抛与缓冲式一致的错误,
  /// 保证"服务端直接报错"这条路径的错误信息不因改流式而变差。
  func validatedLines(
    for request: URLRequest
  ) async throws -> AsyncThrowingStream<String, Error> {
    let (stream, response) = try await lines(for: request)
    guard (200..<300).contains(response.statusCode) else {
      var body = ""
      for try await line in stream {
        body += line + "\n"
        if body.count >= 2_048 {
          break
        }
      }
      throw HTTPTransportError.unsuccessfulStatus(
        code: response.statusCode,
        body: String(body.prefix(2_048)).trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
    return stream
  }

  func validatedDeletion(for request: URLRequest) async throws {
    let (data, response) = try await self.data(for: request)
    guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
      let body = String(data: data.prefix(2_048), encoding: .utf8) ?? ""
      throw HTTPTransportError.unsuccessfulStatus(
        code: response.statusCode,
        body: body
      )
    }
  }
}
