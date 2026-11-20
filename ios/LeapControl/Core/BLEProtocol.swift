import CommonCrypto
import CryptoKit
import Foundation

/// 零跑蓝牙钥匙协议中已经由实车抓包确认的常量与帧结构。
enum LeapBLEProtocol {
    static let serviceUUID = "0000FFFE-0000-1000-8000-00805F9B34FB"
    static let characteristicUUID = "0000FFF2-0000-1000-8000-00805F9B34FB"

    /// `passwordCard` 按 16 个 5 字节切片取值，服务端材料必须覆盖完整范围。
    static let minimumPasswordCardByteCount = 80

    /// Bluetooth SIG UUIDs may be represented as 16-bit, 32-bit, or base-UUID strings.
    /// Do not interpret arbitrary vendor UUID prefixes as a protocol version.
    static func advertisedProtocolMinor(serviceUUIDs: [String]) -> Int? {
        for uuid in serviceUUIDs {
            var value = uuid.uppercased()
            if value.count == 36, value.hasSuffix("-0000-1000-8000-00805F9B34FB") {
                value = String(value.prefix(8))
            }
            if value.count == 8, value.hasPrefix("0000") {
                value = String(value.suffix(4))
            }
            if value.count == 4, value.hasPrefix("01"),
               let minor = UInt8(value.suffix(2), radix: 16) {
                return Int(minor)
            }
        }
        return nil
    }

    static func protocolMinor(serviceUUIDs: [String], fallback: Int = 8) -> Int {
        advertisedProtocolMinor(serviceUUIDs: serviceUUIDs)
            ?? ((0...255).contains(fallback) ? fallback : 8)
    }

    /// Official commoninfo/sync reads the last comma-separated component, even without a comma.
    static func cloudVersionToken(response: JSONValue) -> String? {
        guard let list = response["data"]?["list"]?.arrayValue, list.count == 1,
              case .string(let info) = list[0]["bluetoothInfo"] else { return nil }
        return info.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compatibility profile, not the reported minor: official code compares whole versions
    /// to 1.9 / 1.7, so 2.0 must use 1.9 fields rather than being interpreted as minor=0.
    static func cloudProtocolMinor(response: JSONValue) -> Int? {
        guard let token = cloudVersionToken(response: response), !token.isEmpty, token.utf8.count <= 128 else { return nil }
        let fields = token.components(separatedBy: ".")
        guard fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = fields.compactMap(Int.init)
        guard numbers.count == fields.count, let major = numbers.first,
              (1...255).contains(major) else { return nil }
        let minor = numbers.count > 1 ? numbers[1] : 0
        // compareVersion2_lmv:to: compares integer components and pads absent components with zero.
        if major > 1 || minor >= 9 { return 9 }
        return minor
    }

    static func resolvedProtocolMinor(cloud: Int?, advertisedServices: [String], verified: Int?) -> Int? {
        // The official app persists its cloud version. Missing advertisements are not 1.8 evidence.
        if let cloud, (0...255).contains(cloud) { return cloud }
        if let advertised = advertisedProtocolMinor(serviceUUIDs: advertisedServices) { return advertised }
        if let verified, (0...255).contains(verified) { return verified }
        return nil
    }

    /// A scan response can omit services present in an earlier advertisement. Retain
    /// them for this peripheral; only an explicit new version replaces the old version.
    static func mergingAdvertisedServices(previous: [String], incoming: [String]) -> [String] {
        let hasNewVersion = advertisedProtocolMinor(serviceUUIDs: incoming) != nil
        let retained = previous.filter {
            !hasNewVersion || advertisedProtocolMinor(serviceUUIDs: [$0]) == nil
        }
        return Array(Set((retained + incoming).map { $0.uppercased() })).sorted()
    }

    static func usesPre17TokenFormat(serviceUUIDs: [String]) -> Bool {
        advertisedProtocolMinor(serviceUUIDs: serviceUUIDs).map { $0 < 7 } ?? false
    }

    /// 官方 iOS 1.22.66 按证书选择 ECC 或国密链路。
    static func supportsKeyType(_ keyType: Int) -> Bool {
        keyType == 0 || keyType == 1
    }

    /// 防止损坏的长度字段让重组器无限等待或吃掉过多内存。
    static let maximumFrameLength = 1_048_576

    static func decodeReconnectToken(_ token: String) throws -> Data {
        guard !token.isEmpty, token.count.isMultiple(of: 2), token.count <= 1_024 else {
            throw LeapBLEProtocolError.invalidFrame("重连 token 不是有效的偶数长度 Hex")
        }

        var result = Data(capacity: token.count / 2)
        var index = token.startIndex
        while index < token.endIndex {
            let next = token.index(index, offsetBy: 2)
            guard let byte = UInt8(token[index..<next], radix: 16) else {
                throw LeapBLEProtocolError.invalidFrame("重连 token 包含非 Hex 字符")
            }
            result.append(byte)
            index = next
        }
        return result
    }
}

/// `syncBluetoothKeys` 返回的每车蓝牙钥匙证书。字段都属于认证材料，必须放 Keychain。
struct LeapBLEKeyCertificate: Codable, Equatable, Sendable {
    let ecdhPublicKey: String
    let keyType: Int
    let passwordCard: String
    let plainText: String
    let signResult: String
    let vin: String

    init?(json: JSONValue, vin expectedVIN: String? = nil) {
        let isCertificateNode: ([String: JSONValue]) -> Bool = {
            $0["ecdhPublicKey"] != nil
                && $0["passwordCard"] != nil
                && $0["plainText"] != nil
                && $0["signResult"] != nil
                && (expectedVIN == nil || $0["vin"]?.stringValue == expectedVIN)
        }

        let node: [String: JSONValue]?
        if let bluetoothKey = json["data"]?["bluetoothKey"] ?? json["bluetoothKey"] {
            // 官方 DTO 同时返回 bluetoothKey/mobileControl；BLE 认证只能使用前者。
            node = bluetoothKey.firstObject(where: isCertificateNode)
        } else {
            node = json.firstObject(where: isCertificateNode)
        }

        guard let node,
        let ecdhPublicKey = node["ecdhPublicKey"]?.stringValue,
        let passwordCard = node["passwordCard"]?.stringValue,
        let plainText = node["plainText"]?.stringValue,
        let signResult = node["signResult"]?.stringValue
        else { return nil }

        self.ecdhPublicKey = ecdhPublicKey
        // 老接口曾省略该字段；兼容时按官方老款路径处理。显式未知值仍由会话创建拒绝。
        self.keyType = node["keyType"]?.intValue ?? 0
        self.passwordCard = passwordCard
        self.plainText = plainText
        self.signResult = signResult
        self.vin = node["vin"]?.stringValue ?? ""
    }

    init(
        ecdhPublicKey: String,
        keyType: Int,
        passwordCard: String,
        plainText: String,
        signResult: String,
        vin: String
    ) {
        self.ecdhPublicKey = ecdhPublicKey
        self.keyType = keyType
        self.passwordCard = passwordCard
        self.plainText = plainText
        self.signResult = signResult
        self.vin = vin
    }

    var fingerprint: String {
        let digest = SHA256.hash(data: Data(("ios-1.22.66|" + ecdhPublicKey + signResult + passwordCard + plainText).utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    var isSupportedKeyType: Bool {
        LeapBLEProtocol.supportsKeyType(keyType)
    }

    /// 官方 Java 按字符切片，当前协议要求这些字符是一字节 ASCII。
    var hasValidPasswordCard: Bool {
        passwordCard.utf8.count >= LeapBLEProtocol.minimumPasswordCardByteCount
            && passwordCard.unicodeScalars.allSatisfy { $0.value <= 0x7F }
    }

    func validatePasswordCard() throws {
        guard hasValidPasswordCard else {
            throw LeapBLEProtocolError.invalidCertificate(
                "passwordCard 必须是至少 80 字节的 ASCII 字符串"
            )
        }
    }
}

struct LeapBLECredentialContext: Equatable, Sendable {
    let certificate: LeapBLEKeyCertificate
    let accountId: String
    let deviceId: String
    let vin: String
}

enum LeapBLEProtocolError: LocalizedError, Equatable {
    case unsupportedKeyType(Int)
    case invalidCertificate(String)
    case invalidFrame(String)
    case cryptoFailure(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedKeyType(let value): return "暂不支持的蓝牙证书类型（keyType=\(value)）"
        case .invalidCertificate(let reason): return "蓝牙证书无效：\(reason)"
        case .invalidFrame(let reason): return "蓝牙帧无效：\(reason)"
        case .cryptoFailure(let reason): return "蓝牙加解密失败：\(reason)"
        }
    }
}

enum LeapBLEControlCommand: UInt8, Equatable, Identifiable, Sendable {
    case unlock = 1
    case lock = 2

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .unlock: return "解锁"
        case .lock: return "闭锁"
        }
    }
}

enum StraightMoveDirection: UInt8, CaseIterable, Equatable, Identifiable, Sendable {
    case forward = 1
    case backward = 2

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .forward: return "向前"
        case .backward: return "向后"
        }
    }

    var symbol: String {
        switch self {
        case .forward: return "arrow.up"
        case .backward: return "arrow.down"
        }
    }
}

enum StraightMoveOrder: UInt8, Equatable, Sendable {
    case forward = 1
    case backward = 2
    case stop = 3

    init(direction: StraightMoveDirection) {
        self = direction == .forward ? .forward : .backward
    }

    var label: String {
        switch self {
        case .forward: return "直进"
        case .backward: return "直出"
        case .stop: return "停止挪车"
        }
    }
}

/// 官方 1.9 重连明文中的 9 字节蓝牙钥匙配置。
enum BLEUnlockDistance: Int, Codable, CaseIterable, Sendable {
    case standard = 0
    case near = 4
    case far = 7

    var label: String {
        switch self {
        case .standard: return "默认"
        case .near: return "较近"
        case .far: return "较远"
        }
    }
}

struct LeapBLEConfiguration: Codable, Equatable, Sendable {
    var distanceCalibration: UInt8
    var coefficientHundredths: UInt16
    var unlockCalibration: UInt8
    var lockCalibration: UInt8
    var isEnabled: Bool
    var autoLockEnabled: Bool
    var autoUnlockEnabled: Bool
    var supportsButton: Bool
    // Optional 保持旧版持久化记录可解码；默认档恢复云端基准，不覆盖其它标定值。
    var distanceSelection: BLEUnlockDistance? = nil
    var defaultUnlockCalibration: UInt8? = nil
    var multipleAnchors: Bool? = nil

    var unlockDistance: BLEUnlockDistance { distanceSelection ?? .standard }

    mutating func setUnlockDistance(_ value: BLEUnlockDistance) {
        if defaultUnlockCalibration == nil { defaultUnlockCalibration = unlockCalibration }
        distanceSelection = value
        unlockCalibration = value == .standard ? (defaultUnlockCalibration ?? 8) : UInt8(value.rawValue)
    }

    /// 1.8 的总开关表示无感解锁；手动蓝牙控车不需要打开这个车端开关。
    var legacyPassiveEnabled: Bool { isEnabled && autoUnlockEnabled }

    static let officialDefault = LeapBLEConfiguration(
        distanceCalibration: 56,
        coefficientHundredths: 200,
        unlockCalibration: 8,
        lockCalibration: 16,
        isEnabled: true,
        autoLockEnabled: false,
        autoUnlockEnabled: true,
        supportsButton: true
    )

    /// 首次只绑定蓝牙控车时使用。车辆仍接受手动指令，但不会自动解锁或闭锁。
    static let manualControl = LeapBLEConfiguration(
        distanceCalibration: 56,
        coefficientHundredths: 200,
        unlockCalibration: 8,
        lockCalibration: 16,
        isEnabled: true,
        autoLockEnabled: false,
        autoUnlockEnabled: false,
        supportsButton: true
    )

    var calibrationText: String {
        let coefficient = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(coefficientHundredths) / 100
        )
        let unlock = String(format: "%02d", Int(unlockCalibration))
        let lock = String(format: "%02d", Int(lockCalibration))
        return "\(distanceCalibration);\(coefficient);\(unlock);\(lock)"
    }

    var bytes: Data { wireBytes(protocolMinor: 9) }

    func wireBytes(protocolMinor: Int) -> Data {
        var result = Data([distanceCalibration])
        result.appendLittleEndian(coefficientHundredths)
        result.append(unlockCalibration)
        result.append(lockCalibration)
        result.append((protocolMinor >= 9 ? isEnabled : legacyPassiveEnabled) ? 1 : 0)
        result.append(isEnabled && autoLockEnabled ? 1 : 0)
        if protocolMinor >= 9 {
            result.append(isEnabled && autoUnlockEnabled ? 1 : 0)
            result.append(isEnabled && supportsButton ? 1 : 0)
        }
        return result
    }
}

/// `AA AB` 解密后的分号文本。官方解析器至少要求类型和一个数据字段。
enum LeapBLEDecryptedResponse: Equatable, Sendable {
    case authentication(lockState: String, remainingFields: [String])
    case reconnectToken(String)
    case command(identifier: String, result: String?, remainingFields: [String])
    case other(type: String, fields: [String])

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2 else { return nil }

        switch fields[0] {
        case "0":
            guard !fields[1].isEmpty else { return nil }
            self = .authentication(lockState: fields[1], remainingFields: Array(fields.dropFirst(2)))
        case "1":
            guard (try? LeapBLEProtocol.decodeReconnectToken(fields[1])) != nil else { return nil }
            self = .reconnectToken(fields[1])
        case "2":
            self = .command(
                identifier: fields.count > 2 ? fields[2] : "",
                result: fields[1],
                remainingFields: fields.count > 3 ? Array(fields.dropFirst(3)) : []
            )
        default:
            self = .other(type: fields[0], fields: Array(fields.dropFirst()))
        }
    }
}

/// 一次 GATT 连接内使用的会话密钥。临时私钥完成协商后立即丢弃，只保留 key/iv。
struct LeapBLECryptoSession: Sendable {
    private enum Cipher: Sendable {
        case aes
        case sm4
    }

    let sessionID: UInt32
    let publicKey: Data
    private let key: Data
    private let iv: Data
    private let cipher: Cipher

    static func make(
        certificate: LeapBLEKeyCertificate,
        vin: String,
        sessionID requestedSessionID: UInt32? = nil,
        privateKeyRawRepresentation: Data? = nil,
        smPeerPublicKeyX963: Data? = nil
    ) throws -> LeapBLECryptoSession {
        guard certificate.vin.isEmpty || certificate.vin == vin else {
            throw LeapBLEProtocolError.invalidCertificate("证书 VIN 与当前车辆不一致")
        }
        try certificate.validatePasswordCard()
        guard LeapBLEProtocol.supportsKeyType(certificate.keyType) else {
            throw LeapBLEProtocolError.unsupportedKeyType(certificate.keyType)
        }

        let publicKey: Data
        let sharedSecret: Data
        let cipher: Cipher
        switch certificate.keyType {
        case 0:
            guard let peerX963 = Data(
                base64Encoded: certificate.ecdhPublicKey,
                options: .ignoreUnknownCharacters
            ), peerX963.count == 65, peerX963.first == 0x04 else {
                throw LeapBLEProtocolError.invalidCertificate("ECDH 公钥不是 65 字节 P-256 公钥")
            }

            let privateKey: P256.KeyAgreement.PrivateKey
            do {
                if let privateKeyRawRepresentation {
                    privateKey = try P256.KeyAgreement.PrivateKey(
                        rawRepresentation: privateKeyRawRepresentation
                    )
                } else {
                    privateKey = P256.KeyAgreement.PrivateKey()
                }
            } catch {
                throw LeapBLEProtocolError.cryptoFailure("临时 P-256 私钥创建失败")
            }

            do {
                let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: peerX963)
                let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
                sharedSecret = secret.withUnsafeBytes { Data($0) }
            } catch {
                throw LeapBLEProtocolError.cryptoFailure("P-256 ECDH 协商失败")
            }
            publicKey = privateKey.publicKey.x963Representation
            cipher = .aes
        case 1:
            let agreement = try LeapGMCrypto.sm2KAP(
                certificatePEM: certificate.ecdhPublicKey,
                privateKey: privateKeyRawRepresentation,
                peerPublicKeyX963: smPeerPublicKeyX963
            )
            publicKey = agreement.publicKey
            sharedSecret = agreement.sharedKey
            cipher = .sm4
        default:
            throw LeapBLEProtocolError.unsupportedKeyType(certificate.keyType)
        }

        let sessionID = requestedSessionID ?? UInt32.random(in: UInt32.min...UInt32.max)
        var indexMaterial = Data()
        indexMaterial.appendLittleEndian(sessionID)
        indexMaterial.append(contentsOf: String(vin.reversed()).utf8)
        let indexDigest: Data
        if certificate.keyType == 1 {
            indexDigest = try LeapGMCrypto.sm3(indexMaterial)
        } else {
            indexDigest = Data(SHA256.hash(data: indexMaterial))
        }
        let cardIndex = Int(indexDigest[0] >> 4)
        let start = cardIndex * 5
        let passwordBytes = Array(certificate.passwordCard.utf8)

        var keyMaterial = Data(passwordBytes[start..<(start + 5)])
        keyMaterial.append(sharedSecret)
        let digest: Data
        if certificate.keyType == 1 {
            digest = try LeapGMCrypto.sm3(keyMaterial)
        } else {
            digest = Data(SHA256.hash(data: keyMaterial))
        }
        let digestHex = digest
            .map { String(format: "%02x", $0) }
            .joined()
        let key = Data(digestHex.prefix(16).utf8)
        let iv = Data(digestHex.suffix(16).utf8)
        return LeapBLECryptoSession(
            sessionID: sessionID,
            publicKey: publicKey,
            key: key,
            iv: iv,
            cipher: cipher
        )
    }

    /// 官方 1.9 协议的完整认证帧（`AA AE`）。
    func fullAuthenticationFrame(
        certificate: LeapBLEKeyCertificate,
        accountId: String,
        deviceId: String,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970),
        configuration: LeapBLEConfiguration = .officialDefault,
        protocolMinor: Int = 9
    ) throws -> Data {
        var certificateFields = certificate.plainText.components(separatedBy: ";")
        guard certificateFields.count >= 6 else {
            throw LeapBLEProtocolError.invalidCertificate("plainText 字段不足 6 项")
        }
        guard !accountId.isEmpty, !deviceId.isEmpty,
              !accountId.contains(";"), !deviceId.contains(";") else {
            throw LeapBLEProtocolError.invalidCertificate("账号或设备标识为空/含分隔符")
        }
        guard let signature = Data(
            base64Encoded: certificate.signResult,
            options: .ignoreUnknownCharacters
        ), !signature.isEmpty else {
            throw LeapBLEProtocolError.invalidCertificate("signResult 不是有效 Base64")
        }

        // iOS 1.22.66 保留完整 plainText，只替换其中的账号和设备号，不能丢掉第一个字段。
        certificateFields[1] = accountId
        certificateFields[2] = deviceId
        var authFields = [
            String(timestamp), certificateFields.joined(separator: ";"),
            configuration.calibrationText,
            (protocolMinor >= 9 ? configuration.isEnabled : configuration.legacyPassiveEnabled) ? "1" : "0",
            configuration.isEnabled && configuration.autoLockEnabled ? "1" : "0",
        ]
        if protocolMinor >= 9 {
            authFields.append(configuration.isEnabled && configuration.autoUnlockEnabled ? "1" : "0")
            authFields.append(configuration.isEnabled && configuration.supportsButton ? "1" : "0")
        }
        let authText = (authFields + [""]).joined(separator: ";")
        let authTextData = Data(authText.utf8)
        var plain = Data()
        plain.appendLittleEndian(UInt32(authTextData.count))
        plain.append(authTextData)
        plain.append(signature)

        let encodedCipher = try encrypt(plain).base64EncodedData()
        var payload = Data()
        payload.appendLittleEndian(sessionID)
        payload.append(publicKey)
        payload.append(encodedCipher)
        payload.append(contentsOf: [0x01, 0x09])
        guard payload.count <= Int(UInt16.max) else {
            throw LeapBLEProtocolError.invalidFrame("认证载荷过长")
        }

        var frame = Data([0xAA, LeapBLEFrameKind.fullAuthentication.rawValue])
        frame.appendLittleEndian(UInt16(payload.count))
        frame.append(payload)
        return frame
    }

    /// 官方 iOS 1.22.66 token 快速重连帧（`AA EE`）。
    func reconnectAuthenticationFrame(
        token: String,
        accountId: String,
        configuration: LeapBLEConfiguration = .officialDefault,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970),
        pre17: Bool = false,
        protocolMinor: Int = 9
    ) throws -> Data {
        let tokenData = try LeapBLEProtocol.decodeReconnectToken(token)
        let accountData = Data(accountId.utf8)
        guard !accountData.isEmpty, accountData.count <= Int(UInt16.max) else {
            throw LeapBLEProtocolError.invalidCertificate("账号为空或长度超过 UInt16")
        }

        var plain = Data()
        plain.appendLittleEndian(timestamp)
        plain.append(tokenData)
        plain.append(configuration.wireBytes(protocolMinor: protocolMinor))
        plain.appendLittleEndian(UInt16(accountData.count))
        plain.append(accountData)

        return try Self.reconnectFrame(
            sessionID: sessionID,
            publicKey: publicKey,
            encodedCipher: try encrypt(plain).base64EncodedData(),
            usesSM3: usesSM3, pre17: pre17
        )
    }

    /// 独立保留组帧步骤，便于直接对照官方 App 运行时固定向量。
    static func reconnectFrame(
        sessionID: UInt32,
        publicKey: Data,
        encodedCipher: Data,
        usesSM3: Bool,
        pre17: Bool = false
    ) throws -> Data {
        guard publicKey.count == 65, publicKey.first == 0x04 else {
            throw LeapBLEProtocolError.invalidFrame("重连公钥不是 65 字节未压缩公钥")
        }
        guard !encodedCipher.isEmpty else {
            throw LeapBLEProtocolError.invalidFrame("重连密文为空")
        }

        if pre17 {
            guard 4 + publicKey.count + encodedCipher.count <= Int(UInt16.max) else {
                throw LeapBLEProtocolError.invalidFrame("重连载荷过长")
            }
            var frame = Data([0xAA, LeapBLEFrameKind.reconnectAuthentication.rawValue])
            frame.appendLittleEndian(UInt16(4 + publicKey.count + encodedCipher.count))
            frame.appendLittleEndian(sessionID)
            frame.append(publicKey)
            frame.append(encodedCipher)
            return frame
        }

        let payloadLength = 4 + publicKey.count + encodedCipher.count + 2 + 16
        guard payloadLength <= Int(UInt16.max) else {
            throw LeapBLEProtocolError.invalidFrame("重连载荷过长")
        }

        var frame = Data([0xAA, LeapBLEFrameKind.reconnectAuthentication.rawValue])
        frame.appendLittleEndian(UInt16(payloadLength))
        frame.appendLittleEndian(sessionID)
        frame.append(publicKey)
        frame.append(encodedCipher)
        frame.append(contentsOf: [0x01, 0x09])

        let digest = usesSM3
            ? try LeapGMCrypto.sm3(frame)
            : Data(SHA256.hash(data: frame))
        guard digest.count >= 16 else {
            throw LeapBLEProtocolError.cryptoFailure("重连摘要不足 16 字节")
        }
        frame.append(digest.prefix(16))
        return frame
    }

    func controlFrame(
        command: LeapBLEControlCommand,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970)
    ) throws -> Data {
        try encryptedCommandFrame(commandID: command.rawValue, payload: Data(), timestamp: timestamp)
    }

    /// 已认证连接内下发命令 `3`，让车辆更新无感钥匙配置。
    func configurationFrame(
        _ configuration: LeapBLEConfiguration,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970),
        protocolMinor: Int = 9
    ) throws -> Data {
        try encryptedCommandFrame(commandID: 3, payload: configuration.wireBytes(protocolMinor: protocolMinor), timestamp: timestamp)
    }

    /// 官方 LMVBlueToothDataHandler.JuFRkMcmipTPcykn:：座舱业务认证，不是钥匙 AA AE。
    func callCarAuthenticationFrame(certificate: LeapBLEKeyCertificate, accountId: String,
                                    deviceId: String, timestamp: UInt64 = UInt64(Date().timeIntervalSince1970)) throws -> Data {
        var fields = certificate.plainText.components(separatedBy: ";")
        guard fields.count >= 6, !accountId.isEmpty, !deviceId.isEmpty,
              !accountId.contains(";"), !deviceId.contains(";"),
              let signature = Data(base64Encoded: certificate.signResult), !signature.isEmpty else {
            throw LeapBLEProtocolError.invalidCertificate("直进直出证书无效")
        }
        fields[1] = accountId
        fields[2] = deviceId
        let text = Data("\(timestamp);\(fields.joined(separator: ";"));".utf8)
        var plain = Data()
        plain.appendLittleEndian(UInt32(text.count))
        plain.append(text)
        plain.append(signature)
        let cipher = try encrypt(plain).base64EncodedData()
        guard cipher.count + 69 <= Int(UInt16.max) else { throw LeapBLEProtocolError.invalidFrame("认证帧过长") }
        var frame = Data([0xAA, 0xAE, 1, 1, 10]) // module=1, App business protocol=1.10
        frame.appendLittleEndian(UInt16(cipher.count + 69))
        frame.appendLittleEndian(sessionID)
        frame.append(publicKey)
        frame.append(cipher)
        return frame
    }

    func callCarOrderFrame(_ order: UInt8) throws -> Data {
        let cipher = try encrypt(Data([order])).base64EncodedData()
        var frame = Data([0xAA, 0xAB])
        frame.appendLittleEndian(UInt32(cipher.count))
        frame.append(cipher)
        return frame
    }

    /// 直进直出使用独立明文：只有一个 order 字节，没有 RKE 的 CRC、时间戳和 cmdID。
    func straightMoveFrame(order: StraightMoveOrder) throws -> Data {
        let encodedCipher = try encrypt(Data([order.rawValue])).base64EncodedData()
        var frame = Data([0xAA, LeapBLEFrameKind.encrypted.rawValue])
        frame.appendLittleEndian(UInt32(encodedCipher.count))
        frame.append(encodedCipher)
        return frame
    }

    private func encryptedCommandFrame(
        commandID: UInt8,
        payload: Data,
        timestamp: UInt64
    ) throws -> Data {
        var body = Data()
        body.appendLittleEndian(timestamp)
        body.append(commandID)
        body.append(payload)
        let crc = Self.crc8(body)
        body.insert(crc, at: 0)

        let encodedCipher = try encrypt(body).base64EncodedData()
        var frame = Data([0xAA, LeapBLEFrameKind.encrypted.rawValue])
        frame.appendLittleEndian(UInt32(encodedCipher.count))
        frame.append(encodedCipher)
        return frame
    }

    func decrypt(_ frame: LeapBLEFrame) throws -> Data {
        guard frame.kind == .encrypted,
              let cipher = Data(base64Encoded: frame.payload, options: .ignoreUnknownCharacters),
              !cipher.isEmpty else {
            throw LeapBLEProtocolError.invalidFrame("AA AB 载荷不是有效 Base64")
        }
        return try crypt(cipher, operation: CCOperation(kCCDecrypt))
    }

    static func crc8(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    private func encrypt(_ data: Data) throws -> Data {
        switch cipher {
        case .aes:
            return try cryptAES(data, operation: CCOperation(kCCEncrypt))
        case .sm4:
            return try LeapGMCrypto.sm4Encrypt(data, key: key, iv: iv)
        }
    }

    private var usesSM3: Bool {
        switch cipher {
        case .aes: return false
        case .sm4: return true
        }
    }

    private func crypt(_ data: Data, operation: CCOperation) throws -> Data {
        switch cipher {
        case .aes:
            return try cryptAES(data, operation: operation)
        case .sm4 where operation == CCOperation(kCCDecrypt):
            return try LeapGMCrypto.sm4Decrypt(data, key: key, iv: iv)
        case .sm4:
            return try LeapGMCrypto.sm4Encrypt(data, key: key, iv: iv)
        }
    }

    private func cryptAES(_ data: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, key.count,
                            ivBuffer.baseAddress,
                            inputBuffer.baseAddress, data.count,
                            outputBuffer.baseAddress, outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw LeapBLEProtocolError.cryptoFailure("AES-CBC 返回 \(status)")
        }
        return output.prefix(moved)
    }
}

enum LeapBLEFrameKind: UInt8, Equatable, Sendable {
    case encrypted = 0xAB
    case event = 0xAC
    case fullAuthentication = 0xAE
    case reconnectAuthentication = 0xEE

    var label: String {
        switch self {
        case .encrypted: return "AA AB"
        case .event: return "AA AC"
        case .fullAuthentication: return "AA AE"
        case .reconnectAuthentication: return "AA EE"
        }
    }
}

struct LeapBLEFrame: Equatable, Sendable {
    let kind: LeapBLEFrameKind
    let declaredPayloadLength: Int
    let bytes: Data

    var payload: Data {
        let offset: Int
        switch kind {
        case .encrypted: offset = 6
        case .event: offset = 10
        case .fullAuthentication, .reconnectAuthentication: offset = 4
        }
        guard bytes.count >= offset else { return Data() }
        return bytes.subdata(in: offset..<bytes.count)
    }

    var event: LeapBLEEvent? {
        LeapBLEEvent(frame: self)
    }

}

/// 官方 iOS 1.22.66 handleResultCode: 的 0...18 查找表。
/// 错误含义不是根因诊断；例如芯片应答错误不能直接认定为硬件损坏。
enum LeapBLEAuthenticationResult {
    static func description(_ code: UInt8) -> String {
        let descriptions = [
            "认证通过", "时间戳校验不通过", "验签不通过", "Token已失效",
            "Token验证不通过", "超时5秒未收到App数据", "命令码无效", "Token生成失败",
            "数据包格式异常", "参数解析错误", "解析到参数，但是参数无效", "数据解密失败",
            "ECDH密钥协商失败", "AES密钥生成失败", "数据包类型解析错误", "明文长度异常",
            "协议版本号低于1.7", "加密芯片无应答", "加密芯片应答错误",
        ]
        return Int(code) < descriptions.count ? descriptions[Int(code)] : "未知错误码"
    }
}

/// `AA AC` 的明文事件。这里只解释已经由官方字符串表和实车时序交叉确认的值。
enum LeapBLEEvent: Equatable, Sendable {
    case errorResponse(resultCode: UInt8, payload: Data)
    case lockOperation(crc8: UInt8, trigger: Trigger, operation: Operation)
    case areaChange(crc8: UInt8, area: Area)
    case other(messageType: UInt8, payload: Data)

    enum Trigger: Equatable, Sendable {
        case none
        case active
        case passive
        case button
        case unknown(UInt8)

        init(rawValue: UInt8) {
            switch rawValue {
            case 0: self = .none
            case 1: self = .active
            case 2: self = .passive
            case 3: self = .button
            default: self = .unknown(rawValue)
            }
        }

        var label: String {
            switch self {
            case .none: return "无触发"
            case .active: return "有感"
            case .passive: return "无感"
            case .button: return "按钮"
            case .unknown(let value): return "未知触发(\(value))"
            }
        }
    }

    enum Operation: Equatable, Sendable {
        case none
        case unlock
        case lock
        case unknown(UInt8)

        init(rawValue: UInt8) {
            switch rawValue {
            case 0: self = .none
            case 1: self = .unlock
            case 2: self = .lock
            default: self = .unknown(rawValue)
            }
        }

        var label: String {
            switch self {
            case .none: return "无操作"
            case .unlock: return "解锁"
            case .lock: return "闭锁"
            case .unknown(let value): return "未知操作(\(value))"
            }
        }
    }

    enum Area: Equatable, Sendable {
        case unlock
        case trendLock
        case unknown(UInt8)

        init(rawValue: UInt8) {
            switch rawValue {
            case 1: self = .unlock
            case 3: self = .trendLock
            default: self = .unknown(rawValue)
            }
        }

        var label: String {
            switch self {
            case .unlock: return "进入解锁区域"
            case .trendLock: return "进入趋势闭锁区域"
            case .unknown(let value): return "未知区域(\(value))"
            }
        }
    }

    init?(frame: LeapBLEFrame) {
        guard frame.kind == .event, frame.bytes.count >= 10 else { return nil }
        let bytes = [UInt8](frame.bytes)
        let messageType = bytes[5]
        let payload = [UInt8](frame.payload)

        switch messageType {
        case 1 where !payload.isEmpty:
            self = .errorResponse(resultCode: payload.last!, payload: frame.payload)
        case 2 where payload.count >= 3:
            self = .lockOperation(
                crc8: payload[0],
                trigger: Trigger(rawValue: payload[1]),
                operation: Operation(rawValue: payload[2])
            )
        case 3 where payload.count >= 2:
            self = .areaChange(crc8: payload[0], area: Area(rawValue: payload[1]))
        default:
            self = .other(messageType: messageType, payload: frame.payload)
        }
    }

    var summary: String {
        switch self {
        case .errorResponse(let resultCode, _):
            return "错误应答：resultCode=\(resultCode)（\(LeapBLEAuthenticationResult.description(resultCode))）"
        case .lockOperation(let crc8, let trigger, let operation):
            return "解闭锁事件：\(trigger.label) / \(operation.label)，CRC8=\(String(format: "%02X", crc8))"
        case .areaChange(let crc8, let area):
            return "区域事件：\(area.label)，CRC8=\(String(format: "%02X", crc8))"
        case .other(let messageType, let payload):
            return "未解析事件：type=\(messageType)，payload=\(payload.count) bytes"
        }
    }
}

/// CoreBluetooth 一次通知不等于一帧；认证帧也会按 MTU 拆成多个写入分片。
struct LeapBLEFrameReassembler: Sendable {
    private var buffer: [UInt8] = []

    var bufferedByteCount: Int { buffer.count }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func append(_ data: Data) -> [LeapBLEFrame] {
        buffer.append(contentsOf: data)
        var frames: [LeapBLEFrame] = []

        while true {
            guard alignToFrameHeader() else { break }
            guard let description = expectedFrameDescription() else { break }

            if description.totalLength > LeapBLEProtocol.maximumFrameLength {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= description.totalLength else { break }

            let raw = Data(buffer.prefix(description.totalLength))
            frames.append(LeapBLEFrame(
                kind: description.kind,
                declaredPayloadLength: description.declaredLength,
                bytes: raw
            ))
            buffer.removeFirst(description.totalLength)
        }

        return frames
    }

    /// 丢弃帧头前的噪声；末尾单独一个 AA 留给下一分片继续匹配。
    private mutating func alignToFrameHeader() -> Bool {
        guard buffer.count >= 2 else { return false }
        guard let start = buffer.indices.dropLast().first(where: { index in
            buffer[index] == 0xAA && LeapBLEFrameKind(rawValue: buffer[index + 1]) != nil
        }) else {
            buffer = buffer.last == 0xAA ? [0xAA] : []
            return false
        }
        if start > 0 { buffer.removeFirst(start) }
        return true
    }

    private func expectedFrameDescription() -> (kind: LeapBLEFrameKind, declaredLength: Int, totalLength: Int)? {
        guard buffer.count >= 2, let kind = LeapBLEFrameKind(rawValue: buffer[1]) else { return nil }

        switch kind {
        case .encrypted:
            guard buffer.count >= 6 else { return nil }
            let length = littleEndianUInt32(at: 2)
            return (kind, length, 6 + length)
        case .event:
            guard buffer.count >= 10 else { return nil }
            let length = littleEndianUInt32(at: 6)
            return (kind, length, 10 + length)
        case .fullAuthentication, .reconnectAuthentication:
            guard buffer.count >= 4 else { return nil }
            let length = Int(buffer[2]) | (Int(buffer[3]) << 8)
            return (kind, length, 4 + length)
        }
    }

    private func littleEndianUInt32(at offset: Int) -> Int {
        Int(buffer[offset])
            | (Int(buffer[offset + 1]) << 8)
            | (Int(buffer[offset + 2]) << 16)
            | (Int(buffer[offset + 3]) << 24)
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
