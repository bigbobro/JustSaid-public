import JustSaidCore
import SwiftUI

/// 设置页读取「已存凭证」的唯一通道。
///
/// 为什么要这一层:设置页每渲染一帧,都会问「这把 key 存了吗、末四位是多少」——
/// 真实实现里这是一次 Keychain 读取,而 Keychain 会向用户弹授权框。
/// `UIHierarchyVerification` 反复构造设置页,于是把用户的屏幕轰成了弹窗雨
/// (2026-07-29 实测)。红线由此定下:**任何验证程序都不许碰真钥匙串**。
///
/// 沿用项目既有的可插拔数据源模式(T8):真实实现读 Keychain,验证与预览注入内存桩。
/// 凭证明文永远不经过这层——只出「存没存」和「末四位」两种非敏感摘要。
@MainActor
public protocol StoredSecretDigest: Sendable {
  func exists(slot: ProviderSecretSlot, for binding: RoleProviderBinding) -> Bool
  /// 已保存密钥的末四位;没存或读不到时返回 nil。
  func suffix(slot: ProviderSecretSlot, for binding: RoleProviderBinding) -> String?
  /// 渠道上下文(渠道管理区):渠道可能尚未被任何角色引用,不能借绑定坐标查询。
  func exists(slot: ProviderSecretSlot, forChannel channel: ProviderChannel) -> Bool
  func suffix(slot: ProviderSecretSlot, forChannel channel: ProviderChannel) -> String?
}

/// 真实实现:转交给 `ProviderSettingsStore`,也就是真读 Keychain。应用运行时用这个。
public struct KeychainSecretDigest: StoredSecretDigest {
  private let settingsStore: ProviderSettingsStore

  public init(settingsStore: ProviderSettingsStore) {
    self.settingsStore = settingsStore
  }

  public func exists(slot: ProviderSecretSlot, for binding: RoleProviderBinding) -> Bool {
    settingsStore.hasSecret(slot: slot, for: binding)
  }

  public func suffix(slot: ProviderSecretSlot, for binding: RoleProviderBinding) -> String? {
    settingsStore.secretSuffix(slot: slot, for: binding)
  }

  public func exists(slot: ProviderSecretSlot, forChannel channel: ProviderChannel) -> Bool {
    settingsStore.hasSecret(slot: slot, forChannel: channel)
  }

  public func suffix(slot: ProviderSecretSlot, forChannel channel: ProviderChannel) -> String? {
    settingsStore.secretSuffix(slot: slot, forChannel: channel)
  }
}

/// 内存桩:验证程序与预览用。构造它不会触发任何钥匙串访问。
///
/// 只需要末四位——这本来就是界面上唯一会显示的部分,桩里不需要、也不该出现完整凭证。
public struct InMemorySecretDigest: StoredSecretDigest {
  private let suffixes: [String: String]

  /// - Parameter suffixes: 槽位 → 末四位。缺席的槽位一律视作「没存」。
  public init(suffixes: [ProviderSecretSlot: String] = [:]) {
    self.suffixes = Dictionary(
      uniqueKeysWithValues: suffixes.map { ($0.key.rawValue, $0.value) }
    )
  }

  public func exists(slot: ProviderSecretSlot, for binding: RoleProviderBinding) -> Bool {
    suffixes[slot.rawValue] != nil
  }

  public func suffix(slot: ProviderSecretSlot, for binding: RoleProviderBinding) -> String? {
    suffixes[slot.rawValue]
  }

  public func exists(slot: ProviderSecretSlot, forChannel channel: ProviderChannel) -> Bool {
    suffixes[slot.rawValue] != nil
  }

  public func suffix(slot: ProviderSecretSlot, forChannel channel: ProviderChannel) -> String? {
    suffixes[slot.rawValue]
  }
}
