import CommonCrypto
import CryptoKit
import Foundation
import Security

/// 与 `src/leapmotor-cn-sdk.js` 中的签名/加密实现一一对应。
/// 任何一处偏差都会让服务端返回 result=39（信息校验失败），因此这里的字节级行为不可随意“优化”。
enum LeapCrypto {

    // MARK: - 摘要

    /// 老链路签名：md5(hex) 取 [8, 24)，即中间 16 个十六进制字符。
    static func shortMD5(_ input: String) -> String {
        let hex = md5Hex(Data(input.utf8))
        let start = hex.index(hex.startIndex, offsetBy: 8)
        let end = hex.index(hex.startIndex, offsetBy: 24)
        return String(hex[start..<end])
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256Hex(message: String, key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 签名串拼接

    /// 合并若干字典，按 key 升序排列后把 value 直接首尾相接。
    /// 空值被丢弃（与 JS 侧 `value !== null && value !== undefined` 一致）。
    static func sortAndConcatValues(_ maps: [String: String]?...) -> String {
        var merged: [String: String] = [:]
        for map in maps {
            guard let map else { continue }
            for (key, value) in map { merged[key] = value }
        }
        return merged.keys.sorted().map { merged[$0] ?? "" }.joined()
    }

    // MARK: - Base64URL

    static func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ input: String) -> Data {
        var normalized = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized) ?? Data()
    }

    // MARK: - 手机号 RSA

    // 零跑官方 App 内置的手机号加密公钥（SPKI base64）。公钥本身不是秘密。
    private static let publicKeyBase64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB"

    /// App 规则：手机号用固定公钥 RSA/PKCS1 加密后转 base64url（无 padding）。
    static func phoneNoCiphertext(_ phone: String) throws -> String {
        guard let spki = Data(base64Encoded: publicKeyBase64) else {
            throw LeapError.crypto("内置公钥解析失败")
        }
        // SecKeyCreateWithData 需要裸 RSA 公钥（PKCS#1），这里从 SPKI 中剥掉算法标识头。
        let pkcs1 = try stripSPKIHeader(spki)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw LeapError.crypto("公钥导入失败: \(error?.takeRetainedValue().localizedDescription ?? "未知")")
        }
        guard let encrypted = SecKeyCreateEncryptedData(
            key, .rsaEncryptionPKCS1, Data(phone.utf8) as CFData, &error
        ) as Data? else {
            throw LeapError.crypto("手机号加密失败: \(error?.takeRetainedValue().localizedDescription ?? "未知")")
        }
        return base64URLNoPadding(encrypted)
    }

    /// 从 SubjectPublicKeyInfo 中取出 BIT STRING 里的 PKCS#1 公钥。
    private static func stripSPKIHeader(_ spki: Data) throws -> Data {
        var index = 0
        let bytes = [UInt8](spki)

        func readLength() throws -> Int {
            guard index < bytes.count else { throw LeapError.crypto("公钥结构越界") }
            let first = bytes[index]
            index += 1
            if first & 0x80 == 0 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, index + count <= bytes.count else { throw LeapError.crypto("公钥长度域异常") }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[index])
                index += 1
            }
            return value
        }

        guard bytes.first == 0x30 else { throw LeapError.crypto("公钥不是 SEQUENCE") }
        index = 1
        _ = try readLength()

        // AlgorithmIdentifier
        guard index < bytes.count, bytes[index] == 0x30 else { throw LeapError.crypto("缺少 AlgorithmIdentifier") }
        index += 1
        let algLength = try readLength()
        index += algLength

        // BIT STRING
        guard index < bytes.count, bytes[index] == 0x03 else { throw LeapError.crypto("缺少 BIT STRING") }
        index += 1
        let bitLength = try readLength()
        guard index < bytes.count, bytes[index] == 0x00 else { throw LeapError.crypto("BIT STRING 未对齐") }
        index += 1
        let payloadLength = bitLength - 1
        guard index + payloadLength <= bytes.count else { throw LeapError.crypto("公钥内容越界") }
        return Data(bytes[index..<(index + payloadLength)])
    }

    // MARK: - signKey 推导

    /// signKey = accessToken 第三段(base64url) XOR r2(base64) XOR r3(base64)，长度取三者最小值。
    static func deriveSignKey(accessToken: String, r2: String, r3: String) throws -> Data {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw LeapError.crypto("accessToken 不是三段式 token") }
        let tail = [UInt8](base64URLDecode(String(parts[2])))
        let r2Bytes = [UInt8](Data(base64Encoded: r2) ?? Data())
        let r3Bytes = [UInt8](Data(base64Encoded: r3) ?? Data())
        let length = min(tail.count, r2Bytes.count, r3Bytes.count)
        guard length > 0 else { throw LeapError.crypto("signKey 素材为空") }
        var out = [UInt8](repeating: 0, count: length)
        for i in 0..<length { out[i] = tail[i] ^ r2Bytes[i] ^ r3Bytes[i] }
        return Data(out)
    }

    // MARK: - 操作密码

    /// oppwd = AES-128-CBC(操作密码)，key/iv 由老 token 前后 32 字节各自求短 MD5 得到。
    static func encryptOperationPassword(_ password: String, oldToken: String) throws -> String {
        guard !password.isEmpty else { return "" }
        guard oldToken.count >= 64 else { throw LeapError.crypto("旧 token 长度不足，无法加密操作密码") }
        let chars = Array(oldToken)
        let keySource = String(chars[0..<32])
        let ivSource = String(chars[32..<64])
        let key = Data(shortMD5(keySource).utf8)
        let iv = Data(shortMD5(ivSource).utf8)
        let plain = Data(password.utf8)

        var outLength = plain.count + kCCBlockSizeAES128
        var out = Data(count: outLength)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuffer in
            plain.withUnsafeBytes { plainBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, key.count,
                            ivBuffer.baseAddress,
                            plainBuffer.baseAddress, plain.count,
                            outBuffer.baseAddress, outLength,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw LeapError.crypto("操作密码加密失败 (\(status))") }
        outLength = moved
        return out.prefix(outLength).base64EncodedString()
    }

    // MARK: - JWT

    /// 读取 JWT 的 exp（毫秒）。
    static func jwtExpiryMilliseconds(_ token: String) -> Double {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return 0 }
        guard
            let json = try? JSONSerialization.jsonObject(with: base64URLDecode(String(parts[1]))) as? [String: Any],
            let exp = json["exp"] as? Double, exp > 0
        else { return 0 }
        return exp * 1000
    }

    static func randomNonce() -> String {
        String(Int.random(in: 10_000...10_009_999))
    }
}
