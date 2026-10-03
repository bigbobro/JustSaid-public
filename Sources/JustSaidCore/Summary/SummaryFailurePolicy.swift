import Foundation

/// Pure classification policy for live-summary failures. Keeping vendor/network error mapping out of
/// the MainActor feed makes recovery decisions independently reviewable and testable.
enum SummaryFailureCategory: String, Sendable {
  case configuration
  case timeout
  case networkService
  case invalidResponse
  case persistence
  case unknown

  var allowsAutomaticRecovery: Bool {
    self != .configuration
  }
}

enum SummaryFailurePolicy {
  static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }
    if let urlError = error as? URLError {
      return urlError.code == .cancelled
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  static func category(for error: Error) -> SummaryFailureCategory {
    if let liveError = error as? LiveSummaryFeedError {
      switch liveError {
      case .requestTimedOut: return .timeout
      case .invalidStructuredResponse: return .invalidResponse
      case .noTranscriptInRange: return .unknown
      }
    }
    if error is ProviderRuntimeConfigurationError {
      return .configuration
    }
    if let clientError = error as? LLMClientError {
      switch clientError {
      case .invalidEndpoint, .insecureEndpoint:
        return .configuration
      case .malformedResponse, .reasoningOnlyResponse, .emptyResponse:
        return .invalidResponse
      case .streamFailed, .streamTruncated:
        return .networkService
      case .firstFrameTimedOut, .progressTimedOut:
        return .timeout
      }
    }
    if let transportError = error as? HTTPTransportError {
      switch transportError {
      case .nonHTTPResponse:
        return .networkService
      case .unsuccessfulStatus(let code, _):
        if code == 408 || code == 425 || code == 429 || (500..<600).contains(code) {
          return .networkService
        }
        return (400..<500).contains(code) ? .configuration : .networkService
      }
    }
    if let urlError = error as? URLError {
      return urlError.code == .timedOut ? .timeout : .networkService
    }
    // ChatGPT 计划用量:授权、额度与能力问题不提前重试(等用户处理);暂时性问题照常恢复。
    if let unavailable = error as? ChatGPTPlanUnavailable {
      switch unavailable {
      case .credentialsUnavailable: return .networkService
      case .accountChanged: return .unknown
      default: return .configuration
      }
    }
    if let service = error as? ChatGPTPlanServiceError {
      switch service.kind {
      case .usageUnavailable, .userUnavailable, .responseFailed, .other:
        return .networkService
      case .admissionRejected:
        return service.httpStatus == 503 ? .networkService : .configuration
      case .responseIncomplete, .refused:
        return .invalidResponse
      case .usageLimitExceeded, .notEligible, .unsupportedCapability, .routeNotSupported,
        .invalidUser, .notAuthorized:
        return .configuration
      }
    }
    return .unknown
  }

  /// Error summaries are intentionally bounded and sanitized. Response bodies, prompts, transcripts
  /// and credentials are not part of this projection.
  static func errorSummary(_ error: Error) -> String {
    String(DiagnosticSanitizer.summary(error.localizedDescription).prefix(200))
  }
}
