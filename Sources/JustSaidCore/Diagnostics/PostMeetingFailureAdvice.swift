import Foundation
import Synchronization

/// 会后精转失败时出错的那一步。同一个 HTTP 403,上传录音时是对象存储的密钥,
/// 提交或查询任务时是精转服务的密钥,只看错误类型分不出来。
public enum PostMeetingFailureStep: String, Sendable {
  case storage, transcription
}

/// 会后精转失败的闭合原因(B2,2026-10-08)。落进 meeting.json,
/// 只用于给处理建议,不参与重试、计费或任务结局。
public enum PostMeetingFailureCause: String, Codable, Sendable, CaseIterable {
  case offline, network
  case configuration
  case storageCredentials, storageMalformedRequest, storageBucketMissing, storageUnavailable
  case storageConfiguration, localAudioUnreadable
  case transcriptionCredentials, transcriptionRateLimited, transcriptionBusy
  case transcriptionServiceError, transcriptionRejected, transcriptionTimedOut
  case transcriptionMalformedResponse
  case audioEmpty, audioFormat
  case remoteCleanup
  case unknown
}

/// 会后处理失败的呈现投影:一句原因加几步处理办法。
/// 原因只从类型化错误加失败步骤得出;供应商的自由文本(X-Api-Message、响应正文)不解析。
public struct PostMeetingFailureAdvice: Hashable, Sendable {
  /// nil = 历史失败,当时没有记下原因,只能原样展示失败文字。
  public let cause: PostMeetingFailureCause?
  /// 落盘的原始失败文字(可能带火山 logid),放在详情里供复制。
  public let reason: String

  public init(cause: PostMeetingFailureCause?, reason: String) {
    self.cause = cause
    self.reason = reason
  }

  public var message: String {
    guard let cause else { return reason }
    switch cause {
    case .offline: return "这台 Mac 没有连上网络，录音没能交给云端"
    case .network: return "网络连接中途失败，原因还不确定"
    case .configuration: return "会后处理用到的服务还没配置完整"
    case .storageCredentials: return "对象存储拒绝了上传，密钥或写入权限不对"
    case .storageMalformedRequest: return "对象存储拒绝了请求本身，通常是密钥里混进了空格或换行"
    case .storageBucketMissing: return "对象存储里找不到这个存储桶"
    case .storageUnavailable: return "对象存储服务暂时出错"
    case .storageConfiguration: return "对象存储配置不完整，录音没能上传"
    case .localAudioUnreadable: return "读不到这场会的本机录音文件"
    case .transcriptionCredentials: return "精转服务拒绝了请求，密钥或权限不对"
    case .transcriptionRateLimited: return "精转服务提示请求太多"
    case .transcriptionBusy: return "精转服务繁忙"
    case .transcriptionServiceError: return "精转服务端处理出错"
    case .transcriptionRejected: return "精转服务拒绝了这次任务"
    case .transcriptionTimedOut: return "等精转结果超过了本机等待时限"
    case .transcriptionMalformedResponse: return "精转服务的返回无法解析"
    case .audioEmpty: return "精转服务收到的录音是空的"
    case .audioFormat: return "精转服务认不出这份录音的格式"
    case .remoteCleanup: return "转写已经完成，但云端临时录音没删掉"
    case .unknown: return "暂时判断不出失败原因"
    }
  }

  public var steps: [String] {
    let retry = "处理好之后点「重新精转…」。"
    let diagnostics = "仍然失败时，导出本场诊断包发给 JustSaid 开发者。"
    guard let cause else {
      return ["这场会失败时还没有记录原因。可以直接点「重新精转…」。", diagnostics]
    }
    switch cause {
    case .offline:
      return ["连上网络后点「重新精转…」。"]
    case .network:
      return ["检查网络和代理，再点「重新精转…」。", diagnostics]
    case .configuration:
      return ["到「设置 › 模型与服务」检查会后精转、对象存储和纪要用的配置，各点一次「测试连接」。", retry]
    case .storageCredentials:
      return [
        "到对象存储控制台核对 Access Key 是否有效、对这个存储桶有没有写入权限。",
        "需要换密钥时，在「设置 › 模型与服务 › 对象存储」重新填写，再点「测试连接」。", retry,
      ]
    case .storageMalformedRequest:
      return [
        "在「设置 › 模型与服务 › 对象存储」重新复制粘贴 Access Key ID 和 Secret Access Key，不要带首尾空白。",
        "点「测试连接」确认通过。", retry,
      ]
    case .storageBucketMissing:
      return ["在「设置 › 模型与服务 › 对象存储」核对存储桶名称和区域，再点「测试连接」。", retry]
    case .storageUnavailable:
      return ["到对象存储控制台查看服务状态，稍后点「重新精转…」。", diagnostics]
    case .storageConfiguration:
      return ["在「设置 › 模型与服务 › 对象存储」补全配置，点「测试连接」确认通过。", retry]
    case .localAudioUnreadable:
      return [
        "录音可能已被移走，或超过音频保留期被清理。在 Finder 里打开这场会的目录，看录音文件还在不在。",
        "录音还在却仍然失败时，导出本场诊断包发给 JustSaid 开发者。",
      ]
    case .transcriptionCredentials:
      return [
        "到火山引擎控制台核对语音识别的 API Key 是否有效、录音文件识别有没有开通。",
        "需要换密钥时，在「设置 › 模型与服务」的会后精转里重新填写。", retry,
      ]
    case .transcriptionRateLimited:
      return ["到火山引擎控制台看并发和调用频率的限制，稍后点「重新精转…」。"]
    case .transcriptionBusy:
      return ["这是服务端繁忙，稍后点「重新精转…」即可。"]
    case .transcriptionServiceError:
      return [
        "失败的任务火山已经计费，再点「重新精转…」会按全长再计一次。",
        "对象存储在海外区域时，火山下载大录音容易超时；反复失败可以考虑换成国内区域的存储（如火山 TOS）。",
        "带上详情里的 logid 可以到火山引擎控制台提工单。",
      ]
    case .transcriptionRejected:
      return ["带上详情里的状态码和 logid 到火山引擎控制台查原因。", diagnostics]
    case .transcriptionTimedOut:
      return [
        "火山那边可能还在排队或处理。稍后点「重新精转…」。",
        "长会议在高峰期排队更久，这一步不代表录音有问题。",
      ]
    case .transcriptionMalformedResponse:
      return ["稍后点「重新精转…」。", diagnostics]
    case .audioEmpty:
      return [
        "打开这场会的录音听一下，确认确实录到了声音。",
        "录音有声音却仍然失败时，导出本场诊断包发给 JustSaid 开发者。",
      ]
    case .audioFormat:
      return [
        "导入的录音请先转成 m4a、mp3 或 wav 再重新导入。",
        "本机录制的会议出现这条时，导出本场诊断包发给 JustSaid 开发者。",
      ]
    case .remoteCleanup:
      return [
        "到对象存储控制台删掉这场会留下的临时录音（对象名以会议编号开头），免得一直占用空间。",
        "点「重新精转…」会重新上传并按全长计费，只为删文件不必重转。",
      ]
    case .unknown:
      return ["可以先点「重新精转…」再试一次。", diagnostics]
    }
  }

  /// 投影入口。取消不算失败,返回 nil;`step` 为 nil 时 HTTP 状态不确诊归属。
  public static func classify(
    _ error: Error, step: PostMeetingFailureStep?
  ) -> PostMeetingFailureCause? {
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
    if let url = error as? URLError {
      return url.code == .notConnectedToInternet ? .offline : .network
    }
    if let pipeline = error as? PostMeetingPipelineError {
      switch pipeline {
      case .transcriptionNotConfigured: return .configuration
      case .batchFailed(let detail): return volcengine(code: volcengineCode(in: detail))
      case .pollingTimedOut: return .transcriptionTimedOut
      case .remoteCleanupFailed: return .remoteCleanup
      case .finalized, .minutesGenerationFailed: return .unknown
      }
    }
    if let storage = error as? StorageProviderError {
      switch storage {
      case .invalidConfiguration, .invalidObjectURL: return .storageConfiguration
      case .unreadableFile: return .localAudioUnreadable
      }
    }
    if let volcengine = error as? VolcengineBatchTranscriptionError {
      switch volcengine {
      case .serviceFailed(let code, _, _): return Self.volcengine(code: code)
      case .insecureEndpoint: return .configuration
      case .insecureAudioURL: return .storageConfiguration
      case .exactlyOneAudioURLRequired, .missingTaskID, .malformedResponse:
        return .transcriptionMalformedResponse
      }
    }
    if error is ProviderRuntimeConfigurationError || error is ProviderChannelError {
      return .configuration
    }
    if let http = error as? HTTPTransportError {
      guard let status = http.statusCode else {
        return step == .transcription ? .transcriptionMalformedResponse : .unknown
      }
      switch (step, status) {
      case (.storage?, 400): return .storageMalformedRequest
      case (.storage?, 401), (.storage?, 403): return .storageCredentials
      case (.storage?, 404): return .storageBucketMissing
      case (.storage?, 500..<600): return .storageUnavailable
      case (.transcription?, 401), (.transcription?, 403): return .transcriptionCredentials
      case (.transcription?, 429): return .transcriptionRateLimited
      case (.transcription?, 500..<600): return .transcriptionServiceError
      case (.transcription?, 400..<500): return .transcriptionRejected
      default: return .unknown
      }
    }
    return .unknown
  }

  /// 火山录音文件识别的业务状态码(官方错误码表):45000002 空音频,45000151 音频格式不正确,
  /// 55000031 服务器繁忙,其余 550 开头为服务内部处理错误;别的 4 开头按请求被拒处理。
  static func volcengine(code: String?) -> PostMeetingFailureCause {
    guard let code else { return .unknown }
    switch code {
    case "45000002": return .audioEmpty
    case "45000151": return .audioFormat
    case "55000031": return .transcriptionBusy
    default:
      if code.hasPrefix("550") { return .transcriptionServiceError }
      if code.hasPrefix("4") { return .transcriptionRejected }
      return .unknown
    }
  }

  /// `batchFailed` 的 detail 是 Volcengine provider 自己拼的「火山状态码 <code>(…」,
  /// 这里只取本应用固定格式里的数字码,不碰括号里的供应商原文。
  static func volcengineCode(in detail: String) -> String? {
    let prefix = "火山状态码 "
    guard detail.hasPrefix(prefix) else { return nil }
    let code = detail.dropFirst(prefix.count).prefix { $0.isASCII && $0.isNumber }
    return code.isEmpty ? nil : String(code)
  }
}

/// 一轮精转里第一个带步骤的失败原因。双声道并发上传/提交时,先失败的那一路说了算。
final class PostMeetingFailureCauseRecorder: Sendable {
  private let recorded = Mutex<PostMeetingFailureCause?>(nil)

  func record(_ error: Error, step: PostMeetingFailureStep) {
    guard let cause = PostMeetingFailureAdvice.classify(error, step: step) else { return }
    recorded.withLock { if $0 == nil { $0 = cause } }
  }

  var cause: PostMeetingFailureCause? { recorded.withLock { $0 } }
}
