import Foundation

public struct SecurityCommandResult: Sendable {
  public let output: Data
  public let terminationStatus: Int32

  public init(output: Data, terminationStatus: Int32) {
    self.output = output
    self.terminationStatus = terminationStatus
  }
}

public enum SecurityCommandProviderSecretStoreError: LocalizedError, Sendable {
  case launchFailed(String)
  case commandFailed(service: String, account: String, status: Int32)
  case malformedBundle(service: String, account: String)
  case readOnly

  public var errorDescription: String? {
    switch self {
    case .launchFailed(let detail):
      return "无法启动 /usr/bin/security 读取 JustSaid 凭证：\(detail)"
    case .commandFailed(let service, let account, let status):
      return
        "无法从系统钥匙串读取 JustSaid 凭证总包"
        + "（service「\(service)」、账户「\(account)」、security 退出码 \(status)）。"
        + "请先在 JustSaid 设置页保存凭证，并在系统提示时允许读取。"
    case .malformedBundle(let service, let account):
      return
        "系统钥匙串中的 JustSaid 凭证总包不是有效的字符串键值 JSON"
        + "（service「\(service)」、账户「\(account)」）。"
        + "请在 JustSaid 设置页重新保存凭证。"
    case .readOnly:
      return "Real 系验证通过 /usr/bin/security 读取凭证，只读且不能写回钥匙串"
    }
  }
}

/// Real 系验证专用的只读凭证源。
///
/// 读取委托给 Apple 稳定签名的 `/usr/bin/security`，避免 SwiftPM 临时可执行文件
/// 直接调用 Security.framework 时每次重编译都重新触发钥匙串授权。命令执行器可注入，
/// 桩验证只解析伪造 JSON，不访问用户钥匙串。
public struct SecurityCommandProviderSecretStore: ProviderSecretStore, Sendable {
  public typealias CommandRunner = (URL, [String]) throws -> SecurityCommandResult

  private let secrets: [String: String]

  public init(
    service: String = KeychainStore.defaultService,
    bundleAccount: String = KeychainStore.bundleAccount
  ) throws {
    try self.init(
      service: service,
      bundleAccount: bundleAccount,
      commandRunner: Self.runSecurityCommand
    )
  }

  public init(
    service: String = KeychainStore.defaultService,
    bundleAccount: String = KeychainStore.bundleAccount,
    commandRunner: CommandRunner
  ) throws {
    let executable = URL(fileURLWithPath: "/usr/bin/security")
    let arguments = [
      "find-generic-password",
      "-s",
      service,
      "-a",
      bundleAccount,
      "-w",
    ]
    let result: SecurityCommandResult
    do {
      result = try commandRunner(executable, arguments)
    } catch {
      throw SecurityCommandProviderSecretStoreError.launchFailed(error.localizedDescription)
    }
    guard result.terminationStatus == 0 else {
      throw SecurityCommandProviderSecretStoreError.commandFailed(
        service: service,
        account: bundleAccount,
        status: result.terminationStatus
      )
    }
    do {
      secrets = try JSONDecoder().decode([String: String].self, from: result.output)
    } catch {
      throw SecurityCommandProviderSecretStoreError.malformedBundle(
        service: service,
        account: bundleAccount
      )
    }
  }

  public func save(_ secret: String, account: String) throws {
    throw SecurityCommandProviderSecretStoreError.readOnly
  }

  public func contains(account: String) -> Bool {
    secrets[account] != nil
  }

  public func load(account: String) throws -> String? {
    secrets[account]
  }

  private static func runSecurityCommand(
    executable: URL,
    arguments: [String]
  ) throws -> SecurityCommandResult {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return SecurityCommandResult(
      output: data,
      terminationStatus: process.terminationStatus
    )
  }
}
