import Foundation

/// `HTTPTransport.lines` 的内存预算。
///
/// 默认值故意远高于正常 SSE delta 和长纪要输出，只把“无限”改成明确上限；调用方可在
/// 验证或特殊供应商场景注入更小/更大的预算。三个值按包含关系归一化：response ≥ event ≥ line。
public struct HTTPStreamingLimits: Equatable, Sendable {
  public let maximumLineBytes: Int
  public let maximumEventBytes: Int
  public let maximumResponseBytes: Int

  public init(
    maximumLineBytes: Int = 8 * 1_024 * 1_024,
    maximumEventBytes: Int = 16 * 1_024 * 1_024,
    maximumResponseBytes: Int = 128 * 1_024 * 1_024
  ) {
    let line = max(1, maximumLineBytes)
    let event = max(line, maximumEventBytes)
    self.maximumLineBytes = line
    self.maximumEventBytes = event
    self.maximumResponseBytes = max(event, maximumResponseBytes)
  }
}

/// 流式响应越过本地安全预算。错误只携带预算数值，不携带响应正文、URL、prompt 或凭证。
public enum HTTPStreamingError: LocalizedError, CustomNSError, Equatable, Sendable {
  case lineTooLarge(limit: Int)
  case eventTooLarge(limit: Int)
  case responseTooLarge(limit: Int)

  public var errorDescription: String? {
    switch self {
    case .lineTooLarge(let limit):
      return "服务返回的单行流式数据超过安全上限（\(limit) 字节）"
    case .eventTooLarge(let limit):
      return "服务返回的单个流式事件超过安全上限（\(limit) 字节）"
    case .responseTooLarge(let limit):
      return "服务返回的流式响应超过安全上限（\(limit) 字节）"
    }
  }

  /// 沿用系统“响应数据长度超过上限”的错误域，让既有诊断分类稳定落在 network，
  /// 同时 typed Swift error 仍保留 line/event/response 三种判别性。
  public static var errorDomain: String { NSURLErrorDomain }

  public var errorCode: Int {
    URLError.Code.dataLengthExceedsMaximum.rawValue
  }

  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: errorDescription ?? "流式响应超过安全上限"]
  }
}

/// 保留空行的纯值逐行 framer。`package` 可见让同一 Swift package 的 verification
/// 直接驱动真实生产状态机，而不把低层逐字节 API 暴露给 App 外部调用方。
package struct HTTPLineFramer: Sendable {
  private let limits: HTTPStreamingLimits
  private var lineBuffer: [UInt8] = []
  private var responseBytes = 0
  private var eventBytes = 0
  private var eventLineCount = 0

  package init(limits: HTTPStreamingLimits = HTTPStreamingLimits()) {
    self.limits = limits
  }

  /// 追加一个 wire byte；遇到 LF 时返回一行。空行返回空字符串，不能吞掉。
  package mutating func append(_ byte: UInt8) throws -> String? {
    guard responseBytes < limits.maximumResponseBytes else {
      throw HTTPStreamingError.responseTooLarge(limit: limits.maximumResponseBytes)
    }
    responseBytes += 1

    guard byte == UInt8(ascii: "\n") else {
      lineBuffer.append(byte)
      guard lineBuffer.count <= limits.maximumLineBytes else {
        throw HTTPStreamingError.lineTooLarge(limit: limits.maximumLineBytes)
      }
      return nil
    }

    // CRLF 只剥掉紧贴 LF 的一个 CR；无 LF 的末行保持旧实现逐字语义。
    if lineBuffer.last == UInt8(ascii: "\r") {
      lineBuffer.removeLast()
    }
    let line = String(decoding: lineBuffer, as: UTF8.self)
    lineBuffer.removeAll(keepingCapacity: true)
    try accountForEvent(line)
    return line
  }

  /// 流正常结束时产出没有 LF 的非空末行；与旧 transport 一致，不额外制造尾空行。
  package mutating func finish() throws -> String? {
    guard !lineBuffer.isEmpty else { return nil }
    let line = String(decoding: lineBuffer, as: UTF8.self)
    lineBuffer.removeAll(keepingCapacity: false)
    try accountForEvent(line)
    return line
  }

  /// `lines` 的主要生产消费者是 SSE。以空行为事件边界，对连续非空行的解码后 UTF-8
  /// bytes 设预算；行间拼接的一个 `\n` 也计入，和上层 `joined(separator: "\n")` 一致。
  private mutating func accountForEvent(_ line: String) throws {
    guard !line.isEmpty else {
      eventBytes = 0
      eventLineCount = 0
      return
    }
    let separatorBytes = eventLineCount == 0 ? 0 : 1
    let requiredBytes = separatorBytes + line.utf8.count
    let remainingBytes = limits.maximumEventBytes - eventBytes
    guard requiredBytes <= remainingBytes else {
      throw HTTPStreamingError.eventTooLarge(limit: limits.maximumEventBytes)
    }
    eventBytes += requiredBytes
    eventLineCount += 1
  }
}
