import CryptoKit
import Foundation
import Security

/// base64url(无填充)编解码。PKCE、JWT 与 JWK 共用。
enum ChatGPTBase64URL {
  static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decode(_ text: String) -> Data? {
    guard !text.isEmpty,
      text.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
      })
    else { return nil }
    var base64 = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder == 1 { return nil }
    if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base64)
  }

  /// 密码学随机串(state、nonce、PKCE verifier)。
  static func random(byteCount: Int = 32) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
      throw ChatGPTAuthorizationError.randomUnavailable
    }
    return encode(Data(bytes))
  }

  /// PKCE S256:base64url(SHA256(verifier)),无填充。
  static func codeChallenge(for verifier: String) -> String {
    encode(Data(SHA256.hash(data: Data(verifier.utf8))))
  }
}

/// PKCS#1 公钥编码所需的最小 DER:只编 INTEGER 与 SEQUENCE,不解析任意 ASN.1。
enum ChatGPTDER {
  static func length(_ count: Int) -> [UInt8] {
    guard count >= 0x80 else { return [UInt8(count)] }
    var bytes: [UInt8] = []
    var value = count
    while value > 0 {
      bytes.insert(UInt8(value & 0xFF), at: 0)
      value >>= 8
    }
    return [0x80 | UInt8(bytes.count)] + bytes
  }

  static func integer(_ magnitude: [UInt8]) -> [UInt8] {
    var content = Array(magnitude.drop(while: { $0 == 0 }))
    if content.isEmpty { content = [0] }
    if content[0] & 0x80 != 0 { content.insert(0, at: 0) }
    return [0x02] + length(content.count) + content
  }

  static func sequence(_ content: [UInt8]) -> [UInt8] {
    [0x30] + length(content.count) + content
  }
}

/// JWKS 中一把 RS256 签名公钥。只接受 RSA、签名用途、至少 2048 位模数。
/// `SecKey` 公钥创建后不可变,Security 框架允许多线程只读使用;本类型不暴露可变状态。
/// Safety invariant: keyID/key 在构造后不可变,并发调用仅使用 Security 的只读验签操作。
struct ChatGPTSigningKey: @unchecked Sendable {
  let keyID: String
  let key: SecKey

  init?(jwk: [String: Any]) {
    guard jwk["kty"] as? String == "RSA",
      (jwk["use"] as? String).map({ $0 == "sig" }) ?? true,
      (jwk["alg"] as? String).map({ $0 == "RS256" }) ?? true,
      let kid = jwk["kid"] as? String, !kid.isEmpty,
      let modulus = (jwk["n"] as? String).flatMap(ChatGPTBase64URL.decode),
      let exponent = (jwk["e"] as? String).flatMap(ChatGPTBase64URL.decode)
    else { return nil }
    let significant = modulus.drop(while: { $0 == 0 })
    guard significant.count * 8 >= 2048, !exponent.isEmpty else { return nil }
    // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    let der = ChatGPTDER.sequence(
      ChatGPTDER.integer([UInt8](modulus)) + ChatGPTDER.integer([UInt8](exponent)))
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass: kSecAttrKeyClassPublic,
      kSecAttrKeySizeInBits: significant.count * 8,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error)
    else { return nil }
    keyID = kid
    self.key = key
  }

  static func keys(fromJWKS data: Data) -> [ChatGPTSigningKey] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let keys = object["keys"] as? [[String: Any]]
    else { return [] }
    return keys.compactMap(ChatGPTSigningKey.init(jwk:))
  }
}

/// 已验签并核对过 claims 的身份。`email` 只作显示,不作身份键。
public struct ChatGPTVerifiedIdentity: Equatable, Sendable {
  public let issuer: String
  public let subject: String
  public let email: String?
}

enum ChatGPTIDTokenError: Error, Equatable {
  case malformed
  case unsupportedAlgorithm(String)
  case unknownKey
  case badSignature
  case issuerMismatch
  case audienceMismatch
  case expired
  case issuedInFuture
  case nonceMismatch
  case missingSubject
}

/// ID token 校验:先定算法(只认 RS256),再验签,签名通过后才信任 iss/aud/exp/iat/nonce/sub。
enum ChatGPTIDTokenVerifier {
  static func verify(
    _ token: String,
    keys: [ChatGPTSigningKey],
    clientID: String,
    nonce: String,
    now: Date,
    clockSkew: TimeInterval = 30
  ) throws -> ChatGPTVerifiedIdentity {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3,
      let headerData = ChatGPTBase64URL.decode(parts[0]),
      let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
    else { throw ChatGPTIDTokenError.malformed }
    guard let algorithm = header["alg"] as? String, algorithm == "RS256" else {
      throw ChatGPTIDTokenError.unsupportedAlgorithm(header["alg"] as? String ?? "missing")
    }
    guard let payloadData = ChatGPTBase64URL.decode(parts[1]),
      let signature = ChatGPTBase64URL.decode(parts[2]),
      let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
    else { throw ChatGPTIDTokenError.malformed }
    guard let kid = header["kid"] as? String, let key = keys.first(where: { $0.keyID == kid })
    else { throw ChatGPTIDTokenError.unknownKey }
    let signingInput = Data((parts[0] + "." + parts[1]).utf8)
    var error: Unmanaged<CFError>?
    guard
      SecKeyVerifySignature(
        key.key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData,
        signature as CFData, &error)
    else { throw ChatGPTIDTokenError.badSignature }

    guard claims["iss"] as? String == ChatGPTPlanContract.issuer else {
      throw ChatGPTIDTokenError.issuerMismatch
    }
    let audiences: [String] =
      (claims["aud"] as? String).map { [$0] } ?? (claims["aud"] as? [String]) ?? []
    guard audiences.contains(clientID) else { throw ChatGPTIDTokenError.audienceMismatch }
    guard let exp = (claims["exp"] as? NSNumber)?.doubleValue,
      Date(timeIntervalSince1970: exp) > now.addingTimeInterval(-clockSkew)
    else { throw ChatGPTIDTokenError.expired }
    guard let iat = (claims["iat"] as? NSNumber)?.doubleValue,
      Date(timeIntervalSince1970: iat) <= now.addingTimeInterval(clockSkew)
    else { throw ChatGPTIDTokenError.issuedInFuture }
    guard claims["nonce"] as? String == nonce else { throw ChatGPTIDTokenError.nonceMismatch }
    guard let subject = claims["sub"] as? String, !subject.isEmpty else {
      throw ChatGPTIDTokenError.missingSubject
    }
    return ChatGPTVerifiedIdentity(
      issuer: ChatGPTPlanContract.issuer, subject: subject, email: claims["email"] as? String)
  }

  /// 验签前按需取 JWKS:缓存里找不到 token 的 kid 时最多重取一次。
  static func verify(
    _ token: String,
    jwks: ChatGPTJWKSCache,
    clientID: String,
    nonce: String,
    now: Date
  ) async throws -> ChatGPTVerifiedIdentity {
    let cached = try await jwks.keys(refresh: false)
    do {
      return try verify(token, keys: cached, clientID: clientID, nonce: nonce, now: now)
    } catch ChatGPTIDTokenError.unknownKey {
      let refreshed = try await jwks.keys(refresh: true)
      return try verify(token, keys: refreshed, clientID: clientID, nonce: nonce, now: now)
    }
  }
}

/// OpenAI 签名公钥缓存。只走注入的传输,便于离线验证与 Real 账本分账。
actor ChatGPTJWKSCache {
  private let transport: any HTTPTransport
  private var cached: [ChatGPTSigningKey] = []

  init(transport: any HTTPTransport) {
    self.transport = transport
  }

  func keys(refresh: Bool) async throws -> [ChatGPTSigningKey] {
    if !refresh, !cached.isEmpty { return cached }
    var request = URLRequest(url: ChatGPTPlanContract.jwksURL, timeoutInterval: 30)
    request.httpMethod = "GET"
    let (data, response) = try await transport.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw ChatGPTAuthorizationError.jwksUnavailable(status: response.statusCode)
    }
    let keys = ChatGPTSigningKey.keys(fromJWKS: data)
    guard !keys.isEmpty else { throw ChatGPTAuthorizationError.jwksUnavailable(status: nil) }
    cached = keys
    return keys
  }
}
