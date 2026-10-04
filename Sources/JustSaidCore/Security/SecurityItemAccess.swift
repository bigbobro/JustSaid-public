import Foundation
import Security

/// 验证接缝只替换 Security.framework 的返回状态/结果，不替换凭证存储逻辑。
@_spi(KeychainVerification)
public protocol SecurityItemAccess: Sendable {
  func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
  func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemSecurityItemAccess: SecurityItemAccess {
  func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  {
    SecItemCopyMatching(query, result)
  }

  func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    SecItemUpdate(query, attributes)
  }

  func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    SecItemAdd(attributes, result)
  }

  func delete(_ query: CFDictionary) -> OSStatus {
    SecItemDelete(query)
  }
}
