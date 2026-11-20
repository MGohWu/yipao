import CryptoKit
import Foundation
import Testing
@testable import LeapControl

@Suite("蓝牙协议")
struct BLEProtocolTests {
    @Test("后台刷新保留同凭据手动配对，但切车、切账号、失去资格仍生效")
    func pairingSurvivesOnlyMatchingProductionRefresh() {
        let certificate = deterministicCertificate()
        let context = LeapBLECredentialContext(certificate: certificate, accountId: "test", deviceId: "device", vin: certificate.vin)
        let otherCar = LeapBLECredentialContext(certificate: certificate, accountId: "test", deviceId: "device", vin: "other")
        let otherAccount = LeapBLECredentialContext(certificate: certificate, accountId: "other", deviceId: "device", vin: certificate.vin)
        let otherDevice = LeapBLECredentialContext(certificate: certificate, accountId: "test", deviceId: "other", vin: certificate.vin)
        let id = UUID()
        for state: BLEPairingState in [.scanning, .connecting(id), .authenticating(id)] {
            #expect(state.preservesConnection(onRefreshFrom: context, to: context, eligible: true))
            #expect(!state.preservesConnection(onRefreshFrom: context, to: context, eligible: false))
            for incoming in [otherCar, otherAccount, otherDevice] {
                #expect(!state.preservesConnection(onRefreshFrom: context, to: incoming, eligible: true))
            }
            #expect(!state.preservesConnection(onRefreshFrom: context, to: nil, eligible: true))
        }
        for state: BLEPairingState in [.idle, .bound, .failed("rejected"), .preparing] {
            #expect(!state.preservesConnection(onRefreshFrom: context, to: context, eligible: true))
        }
    }

    @MainActor @Test("主动配对即使已有缓存也请求新证书")
    func pairingRefreshesCachedCertificate() async throws {
        let certificate = deterministicCertificate()
        let cached = LeapBLECredentialContext(certificate: certificate, accountId: "test", deviceId: "device", vin: certificate.vin)
        let replacement = LeapBLEKeyCertificate(ecdhPublicKey: certificate.ecdhPublicKey, keyType: certificate.keyType,
            passwordCard: certificate.passwordCard, plainText: certificate.plainText,
            signResult: Data(repeating: 1, count: 64).base64EncodedString(), vin: certificate.vin)
        let fresh = LeapBLECredentialContext(certificate: replacement, accountId: "test", deviceId: "device", vin: certificate.vin)
        var requests = 0
        let result = try await BLEPairingCredentialRefresh.resolve(cached: cached) {
            requests += 1
            return fresh
        }
        #expect(requests == 1)
        #expect(result == fresh)
        #expect(!BLEPairingState.scanning.preservesConnection(onRefreshFrom: cached, to: fresh, eligible: true))
    }

    @MainActor @Test("网络中断保留可用缓存，认证拒绝和取消不降级缓存")
    func pairingCertificateFallbackBoundaries() async throws {
        let certificate = deterministicCertificate()
        let cached = LeapBLECredentialContext(certificate: certificate, accountId: "test", deviceId: "device", vin: certificate.vin)
        let result = try await BLEPairingCredentialRefresh.resolve(cached: cached) { throw URLError(.notConnectedToInternet) }
        #expect(result == cached)
        let errors: [Error] = [LeapError.sessionExpired, LeapError.server("denied"), LeapError.decode("invalid"),
                               CancellationError(), URLError(.cancelled)]
        for error in errors {
            do {
                _ = try await BLEPairingCredentialRefresh.resolve(cached: cached) { throw error }
                Issue.record("拒绝/取消不能复用缓存")
            } catch { }
        }
        do {
            _ = try await BLEPairingCredentialRefresh.resolve(cached: nil) { throw URLError(.notConnectedToInternet) }
            Issue.record("无缓存时离线不能配对")
        } catch { }
    }

    @Test("实车错误帧按官方映射解释，不能误判为证书过期")
    func officialChipFailureResponses() throws {
        let samples: [(UInt8, String, String)] = [
            (18, "AAAC02000001100000004E000000000000000000278C9D38BA12", "加密芯片应答错误"),
            (17, "AAAC0200000110000000E8000000000000000000F898F943BA11", "加密芯片无应答"),
            (16, "AAAC0200000110000000BD00000000000000000000000000BA10", "协议版本号低于1.7"),
        ]
        for (code, hex, meaning) in samples {
            let bytes = stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            var reassembler = LeapBLEFrameReassembler()
            #expect(reassembler.append(Data(bytes.prefix(13))).isEmpty)
            let frame = try #require(reassembler.append(Data(bytes.dropFirst(13))).single)
            guard case .errorResponse(let result, _) = frame.event else {
                Issue.record("未解析为错误应答")
                continue
            }
            #expect(result == code)
            #expect(LeapBLEAuthenticationResult.description(result) == meaning)
            #expect(BLEDiagnostics.frameSummary(frame).contains(meaning))
        }
        #expect(LeapBLEAuthenticationResult.description(255) == "未知错误码")
        #expect(LeapBLEAuthenticationResult.description(2) == "验签不通过")
    }

    @Test("旧绑定缺失版本时由云端补齐，认证后版本可持久化")
    func legacyBindingProtocolRecovery() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let binding = BLEVehicleBinding(accountId: "test", vin: "test", peripheralIdentifier: id,
            certificateFingerprint: "test", configuration: .officialDefault, syncState: .synced,
            removeAfterDisable: false, lastVerifiedAt: nil)
        let data = try JSONEncoder().encode(binding)
        var restored = try JSONDecoder().decode(BLEVehicleBinding.self, from: data)
        #expect(restored.protocolMinor == nil)
        #expect(LeapBLEProtocol.resolvedProtocolMinor(cloud: nil, advertisedServices: ["FFFE", "FCD1"], verified: restored.protocolMinor) == nil)
        let response: JSONValue = .object(["data": .object(["list": .array([
            .object(["bluetoothInfo": .string("2.0")])
        ])])])
        let cloud = try #require(LeapBLEProtocol.cloudProtocolMinor(response: response))
        restored.protocolMinor = LeapBLEProtocol.resolvedProtocolMinor(cloud: cloud, advertisedServices: ["FFFE"], verified: restored.protocolMinor)
        restored = try JSONDecoder().decode(BLEVehicleBinding.self, from: JSONEncoder().encode(restored))
        #expect(LeapBLEProtocol.resolvedProtocolMinor(cloud: nil, advertisedServices: ["FFFE"], verified: restored.protocolMinor) == 9)
    }

    @Test("距离诊断区分档位、默认基准和实际协议字节")
    func distanceDiagnostics() {
        var configuration = LeapBLEConfiguration.officialDefault
        configuration.unlockCalibration = 10
        configuration.multipleAnchors = true
        for distance in [BLEUnlockDistance.near, .far, .standard] {
            configuration.setUnlockDistance(distance)
            let summary = BLEDiagnostics.configurationSummary(configuration, protocolMinor: 9)
            let unlockByte = distance == .standard ? "0A" : (distance == .near ? "04" : "07")
            #expect(summary.contains("distance=\(distance.label)(\(distance.rawValue))"))
            #expect(summary.contains("baseline=10 anchors=multiple"))
            #expect(summary.contains("autoUnlock=true autoLock=false"))
            #expect(summary.lowercased().contains("wire=38c800\(unlockByte.lowercased())1001000101"))
        }
        let legacy = BLEDiagnostics.configurationSummary(configuration, protocolMinor: 8)
        #expect(legacy.lowercased().contains("profileminor=8 wire=38c8000a100100"))
        #expect(!BLEDiagnostics.configurationSummary(configuration).contains("wire="))
    }

    @Test("官方版本比较生成完整 1.9 认证字段", arguments: ["1.9", "1.9.0.0", "01.09.00.00", "2.0", "2", "1.256.0"])
    func cloudVersionDrivesAuthentication(version: String) throws {
        let response: JSONValue = .object(["data": .object(["list": .array([
            .object(["bluetoothInfo": .string("00:11:22:33:44:55,\(version)")])
        ])])])
        let cloud = try #require(LeapBLEProtocol.cloudProtocolMinor(response: response))
        let version = try #require(LeapBLEProtocol.resolvedProtocolMinor(cloud: cloud,
            advertisedServices: ["FFFE"], verified: nil))
        #expect(version == 9)
        let session = try makeDeterministicSession()
        let frame = try session.fullAuthenticationFrame(certificate: deterministicCertificate(),
            accountId: "12345678", deviceId: "device", timestamp: 1700000000,
            configuration: .manualControl, protocolMinor: version)
        let cipher = frame.dropFirst(73).dropLast(2)
        var raw = Data([0xAA, 0xAB]); raw.appendLittleEndian(UInt32(cipher.count)); raw.append(cipher)
        var parser = LeapBLEFrameReassembler()
        let plain = try session.decrypt(#require(parser.append(raw).single))
        let text = String(decoding: plain.dropFirst(4).dropLast(64), as: UTF8.self)
        #expect(text.hasSuffix(";56;2.00;08;16;1;0;0;1;"))
    }

    @Test("官方 lastObject 允许无逗号版本", arguments: ["1.9", "1.9.0", " 1.9 ", "00:11:22:33:44:55,1.9"])
    func cloudVersionWithoutMac(info: String) {
        let row: JSONValue = .object(["bluetoothInfo": .string(info)])
        let response: JSONValue = .object(["data": .object(["list": .array([row])])])
        #expect(LeapBLEProtocol.cloudProtocolMinor(response: response) == 9)
        #expect(LeapBLEProtocol.cloudProtocolMinor(response: .object(["data": .object(["list": .array([row, row])])])) == nil)
    }

    @Test("云端旧版本按数字比较，缺失的小版本视为零")
    func cloudLegacyProfiles() {
        for (token, expected) in [("1", 0), ("1.6.0.0", 6), ("01.07.0.0", 7), ("1.8.99.100", 8)] {
            let response: JSONValue = .object(["data": .object(["list": .array([.object(["bluetoothInfo": .string(token)])])])])
            #expect(LeapBLEProtocol.cloudProtocolMinor(response: response) == expected)
        }
    }

    @Test("版本日志保留版本及空值，未知值脱敏显示格式")
    func versionTokenDiagnostic() {
        #expect(BLEDiagnostics.versionTokenSummary("2.0.0.0") == "versionToken=2.0.0.0")
        #expect(BLEDiagnostics.versionTokenSummary("V1.9") == "versionToken=V1.9")
        #expect(BLEDiagnostics.versionTokenSummary("") == "versionToken=empty")
        #expect(BLEDiagnostics.versionTokenSummary(nil) == "versionToken=missing")
        #expect(BLEDiagnostics.versionTokenSummary("AA:BB:CC:DD:EE:FF").contains("shape=aa:aa:aa:aa:aa:aa"))
        #expect(!BLEDiagnostics.versionTokenSummary("123456789012").contains("123456789012"))
        #expect(!BLEDiagnostics.versionTokenSummary("tokenSecret").contains("tokenSecret"))
    }

    @Test("版本日志区分空返回与业务错误，不输出 MAC、token 或响应体")
    func versionDiagnosticExplainsFailureWithoutSecrets() {
        let response: JSONValue = .object(["result": .number(0), "data": .object(["list": .array([
            .object(["bluetoothInfo": .string("AA:BB:CC:DD:EE:FF,1.9"), "token": .string("secretToken123")])
        ])])])
        let summary = BLEDiagnostics.versionResponseSummary(response)
        #expect(summary.contains("parsedMinor=9"))
        #expect(!summary.contains("AA:BB"))
        #expect(!summary.contains("secretToken"))
        #expect(BLEDiagnostics.versionResponseSummary(.object(["data": .object(["list": .array([])])])).contains("count=0"))
        let error = BLEDiagnostics.failureDetail(LeapError.server("信息校验失败，账号 12345678 token=secretToken123 VIN=LTEST1234567890123"))
        #expect(error.contains("信息校验失败"))
        #expect(!error.contains("12345678"))
        #expect(!error.contains("secretToken"))
        #expect(!error.contains("LTEST"))
        #expect(BLEDiagnostics.failureDetail(LeapError.http(404, "secret response")) == "http status=404")
        #expect(BLEDiagnostics.failureDetail(LeapError.notLoggedIn) == "notLoggedIn")
    }

    @Test("未知版本不降级，明确旧版本仍使用旧格式")
    func versionResolutionDoesNotGuess() {
        #expect(LeapBLEProtocol.resolvedProtocolMinor(cloud: nil, advertisedServices: ["FFFE"], verified: nil) == nil)
        #expect(LeapBLEProtocol.resolvedProtocolMinor(cloud: 8, advertisedServices: ["0109"], verified: 9) == 8)
        #expect(LeapBLEProtocol.resolvedProtocolMinor(cloud: nil, advertisedServices: ["0106"], verified: 9) == 6)
        #expect(LeapBLEProtocol.resolvedProtocolMinor(cloud: nil, advertisedServices: ["FFFE"], verified: 9) == 9)
    }

    @Test("无效云端版本不能被当成旧车", arguments: ["", "MAC,", "MAC,0.9", "MAC,1.-1", "MAC,1.9.bad", "MAC,AA:BB:CC:DD:EE:FF", "123456789012"])
    func invalidCloudVersions(info: String) {
        let response: JSONValue = .object(["data": .object(["list": .array([
            .object(["bluetoothInfo": .string(info)])
        ])])])
        #expect(LeapBLEProtocol.cloudProtocolMinor(response: response) == nil)
    }

    @Test("蓝牙日志不输出认证或加密帧内容")
    func diagnosticFramesExcludeSecrets() {
        let secret = Data("SECRET_TOKEN_CERTIFICATE".utf8)
        for kind in [LeapBLEFrameKind.fullAuthentication, .reconnectAuthentication, .encrypted] {
            let summary = BLEDiagnostics.frameSummary(LeapBLEFrame(kind: kind, declaredPayloadLength: secret.count, bytes: secret))
            #expect(!summary.contains("SECRET"))
            #expect(!summary.contains(secret.hexString))
            #expect(summary.contains("bytes="))
        }
    }

    @Test("蓝牙日志保留错误码及原始取值偏移")
    func diagnosticResultCode() {
        let bytes = Data([0xAA, 0xAC, 0, 0, 0, 1, 2, 0, 0, 0, 0x55, 7])
        let summary = BLEDiagnostics.frameSummary(LeapBLEFrame(kind: .event, declaredPayloadLength: 2, bytes: bytes))
        #expect(summary.contains("resultCode=7 hex=0x07"))
        #expect(summary.contains("offset=11"))
        #expect(summary.contains(bytes.hexString))
    }

    @Test("驻车照片空 data 正常表示暂无图片")
    func parkingPhotoEmptyDataIsUnavailable() {
        let photo = ParkingPhoto(response: .object([
            "result": .number(0),
            "data": .object(["fileUrl": .string("")])
        ]))

        #expect(!photo.available)
        #expect(photo.url == nil)
        #expect(photo.uploadTime == nil)
    }

    @Test("驻车照片保留服务端 URL 和原始上传时间")
    func parkingPhotoParsesLatestImage() {
        let photo = ParkingPhoto(response: .object([
            "result": .number(0),
            "data": .object([
                "fileUrl": .string("https://example.com/parking.jpg"),
                "uploadTime": .string("2026-08-12 16:00:00")
            ])
        ]))

        #expect(photo.available)
        #expect(photo.url?.absoluteString == "https://example.com/parking.jpg")
        #expect(photo.uploadTime == "2026-08-12 16:00:00")
        #expect(photo.displayUploadTime == "2026-08-12 16:00:00")
    }

    @Test("驻车照片毫秒时间戳显示为中文日期")
    func parkingPhotoFormatsTimestampForDisplay() {
        let photo = ParkingPhoto(response: .object([
            "result": .number(0),
            "data": .object([
                "fileUrl": .string("https://example.com/parking.jpg"),
                "uploadTime": .number(1_786_525_416_253)
            ])
        ]))

        #expect(photo.uploadTime == "1786525416253")
        #expect(photo.displayUploadTime?.contains("年") == true)
        #expect(photo.displayUploadTime?.contains("月") == true)
        #expect(photo.displayUploadTime?.contains("日") == true)
        #expect(photo.displayUploadTime != photo.uploadTime)
    }

    @Test("驻车照片 HTTP 地址统一升级为 HTTPS")
    func parkingPhotoUpgradesHTTPToHTTPS() {
        let photo = ParkingPhoto(response: .object([
            "result": .number(0),
            "data": .object([
                "fileUrl": .string("http://example.com/parking.jpg?key=value")
            ])
        ]))

        #expect(photo.available)
        #expect(photo.url?.absoluteString == "https://example.com/parking.jpg?key=value")
    }

    @Test("驻车照片协议相对地址补全 HTTPS")
    func parkingPhotoCompletesProtocolRelativeURL() {
        let photo = ParkingPhoto(response: .object([
            "result": .number(0),
            "data": .object(["fileUrl": .string("//example.com/parking.jpg")])
        ]))

        #expect(photo.url?.absoluteString == "https://example.com/parking.jpg")
    }

    @Test("驻车照片拒绝非 HTTP 图片地址")
    func parkingPhotoRejectsUnsupportedSchemes() {
        let photo = ParkingPhoto(response: .object([
            "result": .number(0),
            "data": .object(["fileUrl": .string("file:///tmp/parking.jpg")])
        ]))

        #expect(!photo.available)
        #expect(photo.url == nil)
    }

    @Test("AA AB 跨分片后按声明长度重组")
    func encryptedFrameReassemblesAcrossChunks() {
        let raw = Data([0xAA, 0xAB, 0x04, 0, 0, 0, 0x41, 0x42, 0x43, 0x44])
        var reassembler = LeapBLEFrameReassembler()

        #expect(reassembler.append(raw.prefix(3)).isEmpty)
        #expect(reassembler.bufferedByteCount == 3)
        let frames = reassembler.append(raw.dropFirst(3))

        #expect(frames == [LeapBLEFrame(kind: .encrypted, declaredPayloadLength: 4, bytes: raw)])
        #expect(reassembler.bufferedByteCount == 0)
    }

    @Test("噪声和同一分片中的多帧不会破坏同步")
    func noiseAndMultipleFrames() {
        let area = Data([0xAA, 0xAC, 2, 0, 0, 3, 2, 0, 0, 0, 0x07, 0x01])
        let encrypted = Data([0xAA, 0xAB, 1, 0, 0, 0, 0x58])
        var stream = Data([0x00, 0xFF, 0xAA, 0x00])
        stream.append(area)
        stream.append(encrypted)

        var reassembler = LeapBLEFrameReassembler()
        let frames = reassembler.append(stream)

        #expect(frames.map(\.kind) == [.event, .encrypted])
        #expect(frames.map(\.declaredPayloadLength) == [2, 1])
    }

    @Test("实车 AA AC 无感解锁和闭锁事件可解析")
    func passiveLockEventsDecode() {
        var reassembler = LeapBLEFrameReassembler()
        let unlock = Data([0xAA, 0xAC, 2, 0, 0, 2, 3, 0, 0, 0, 0x2D, 0x02, 0x01])
        let lock = Data([0xAA, 0xAC, 2, 0, 0, 2, 3, 0, 0, 0, 0x24, 0x02, 0x02])
        let frames = reassembler.append(unlock + lock)

        #expect(frames.count == 2)
        #expect(frames[0].event == .lockOperation(crc8: 0x2D, trigger: .passive, operation: .unlock))
        #expect(frames[1].event == .lockOperation(crc8: 0x24, trigger: .passive, operation: .lock))
    }

    @Test("实车 AA AC 区域事件可解析")
    func areaEventsDecode() {
        var reassembler = LeapBLEFrameReassembler()
        let unlockArea = Data([0xAA, 0xAC, 2, 0, 0, 3, 2, 0, 0, 0, 0x07, 0x01])
        let trendLockArea = Data([0xAA, 0xAC, 2, 0, 0, 3, 2, 0, 0, 0, 0x09, 0x03])
        let frames = reassembler.append(unlockArea + trendLockArea)

        #expect(frames[0].event == .areaChange(crc8: 0x07, area: .unlock))
        #expect(frames[1].event == .areaChange(crc8: 0x09, area: .trendLock))
    }

    @Test("截断帧继续缓存，补齐后才输出")
    func truncatedFrameWaitsForRemainder() {
        let raw = Data([0xAA, 0xEE, 0x03, 0x00, 0x11, 0x22, 0x33])
        var reassembler = LeapBLEFrameReassembler()

        #expect(reassembler.append(raw.dropLast()).isEmpty)
        #expect(reassembler.bufferedByteCount == 6)
        #expect(reassembler.append(raw.suffix(1)).single?.bytes == raw)
    }

    @Test("异常的大长度字段会被丢弃并重新找到下一帧")
    func oversizedFrameResynchronizes() {
        let invalid = Data([0xAA, 0xAB, 0xFF, 0xFF, 0xFF, 0x7F])
        let valid = Data([0xAA, 0xAB, 0x01, 0, 0, 0, 0x58])
        var reassembler = LeapBLEFrameReassembler()

        let frames = reassembler.append(invalid + valid)

        #expect(frames.single?.bytes == valid)
        #expect(reassembler.bufferedByteCount == 0)
    }


    @Test("CRC8 与官方多项式 0x07 一致")
    func crc8Vector() {
        let body = Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01])
        #expect(LeapBLECryptoSession.crc8(body) == 0x88)
    }

    @Test("官方 1.9 默认蓝牙配置固定为 9 字节")
    func defaultBLEConfiguration() {
        #expect(LeapBLEConfiguration.officialDefault.bytes == Data([0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 1, 1]))
    }

    @Test("首次绑定默认只开启蓝牙控车")
    func manualControlConfiguration() {
        #expect(LeapBLEConfiguration.manualControl.calibrationText == "56;2.00;08;16")
        #expect(LeapBLEConfiguration.manualControl.bytes == Data([0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 0, 1]))
    }

    @Test("官方分号响应区分认证状态和重连 token")
    func decryptedAuthenticationResponses() {
        #expect(
            LeapBLEDecryptedResponse(data: Data("0;1;extra".utf8))
                == .authentication(lockState: "1", remainingFields: ["extra"])
        )
        #expect(
            LeapBLEDecryptedResponse(data: Data("1;A1B2C3D4".utf8))
                == .reconnectToken("A1B2C3D4")
        )
        #expect(
            LeapBLEDecryptedResponse(data: Data("2;0;response-id;extra".utf8))
                == .command(identifier: "response-id", result: "0", remainingFields: ["extra"])
        )
        #expect(LeapBLEDecryptedResponse(data: Data("1;not-hex".utf8)) == nil)
        #expect(LeapBLEDecryptedResponse(data: Data("0".utf8)) == nil)
    }

    @Test("证书响应明确选择 bluetoothKey 而不是 mobileControl")
    func certificateSelectsBluetoothKey() throws {
        func node(vin: String) -> JSONValue {
            .object([
                "ecdhPublicKey": .string("public-\(vin)"),
                "keyType": .number(0),
                "passwordCard": .string("card-\(vin)"),
                "plainText": .string("plain-\(vin)"),
                "signResult": .string("sign-\(vin)"),
                "vin": .string(vin)
            ])
        }
        let response = JSONValue.object([
            "result": .number(0),
            "data": .object([
                "mobileControl": node(vin: "MOBILE"),
                "bluetoothKey": node(vin: "BLUETOOTH")
            ])
        ])

        let certificate = try #require(LeapBLEKeyCertificate(json: response))
        #expect(certificate.vin == "BLUETOOTH")
        #expect(certificate.ecdhPublicKey == "public-BLUETOOTH")
    }

    @Test("生产蓝牙路径支持 keyType=0/1，拒绝未知类型")
    func supportedCertificateTypes() {
        #expect(LeapBLEProtocol.supportsKeyType(0))
        #expect(LeapBLEProtocol.supportsKeyType(1))
        #expect(!LeapBLEProtocol.supportsKeyType(2))
        #expect(deterministicCertificate().isSupportedKeyType)
    }

    @Test("passwordCard 必须覆盖 16 个 ASCII 五字节切片")
    func passwordCardValidation() throws {
        let certificate = deterministicCertificate()
        #expect(certificate.hasValidPasswordCard)

        let short = LeapBLEKeyCertificate(
            ecdhPublicKey: certificate.ecdhPublicKey,
            keyType: certificate.keyType,
            passwordCard: String(repeating: "0", count: 79),
            plainText: certificate.plainText,
            signResult: certificate.signResult,
            vin: certificate.vin
        )
        #expect(!short.hasValidPasswordCard)
        #expect(throws: LeapBLEProtocolError.invalidCertificate(
            "passwordCard 必须是至少 80 字节的 ASCII 字符串"
        )) {
            try short.validatePasswordCard()
        }

        let nonASCII = LeapBLEKeyCertificate(
            ecdhPublicKey: certificate.ecdhPublicKey,
            keyType: certificate.keyType,
            passwordCard: String(repeating: "0", count: 79) + "é",
            plainText: certificate.plainText,
            signResult: certificate.signResult,
            vin: certificate.vin
        )
        #expect(!nonASCII.hasValidPasswordCard)
        #expect(throws: LeapBLEProtocolError.invalidCertificate(
            "passwordCard 必须是至少 80 字节的 ASCII 字符串"
        )) {
            try nonASCII.validatePasswordCard()
        }
        #expect(throws: LeapBLEProtocolError.invalidCertificate(
            "passwordCard 必须是至少 80 字节的 ASCII 字符串"
        )) {
            try LeapBLECryptoSession.make(certificate: short, vin: short.vin)
        }
    }

    @Test("旧证书缺少 keyType 时兼容路由到老款")
    func certificateMissingKeyTypeDefaultsToLegacy() throws {
        let response = JSONValue.object([
            "data": .object([
                "bluetoothKey": .object([
                    "ecdhPublicKey": .string("legacy-public"),
                    "passwordCard": .string(String(repeating: "0", count: 80)),
                    "plainText": .string("a;b;c;d;e;f"),
                    "signResult": .string(Data([0x01]).base64EncodedString())
                ])
            ])
        ])

        let certificate = try #require(LeapBLEKeyCertificate(json: response))
        #expect(certificate.keyType == 0)
        #expect(certificate.isSupportedKeyType)
    }

    @Test("固定 ECDH 向量生成官方 AA AB 控车帧")
    func controlFrameMatchesOpenSSLVector() throws {
        let session = try makeDeterministicSession()
        let frame = try session.controlFrame(command: .unlock, timestamp: 0x0102030405060708)

        #expect(frame.hexString.lowercased() == "aaab180000002f54522b62355a533357472b365965427753487079513d3d")

        var reassembler = LeapBLEFrameReassembler()
        let parsed = try #require(reassembler.append(frame).single)
        #expect(try session.decrypt(parsed) == Data([0x88, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01]))
    }

    @Test("直进直出 1/2/3 明文只有单个 order 字节")
    func straightMoveFramesContainOnlyOrder() throws {
        let session = try makeDeterministicSession()

        for order in [StraightMoveOrder.forward, .backward, .stop] {
            let frame = try session.straightMoveFrame(order: order)
            var reassembler = LeapBLEFrameReassembler()
            let parsed = try #require(reassembler.append(frame).single)

            #expect(frame.prefix(2) == Data([0xAA, 0xAB]))
            #expect(parsed.declaredPayloadLength == 24)
            #expect(try session.decrypt(parsed) == Data([order.rawValue]))
        }
    }

    @Test("命令 3 明文携带完整 9 字节配置")
    func configurationCommandPlaintext() throws {
        let session = try makeDeterministicSession()
        let frame = try session.configurationFrame(
            .manualControl,
            timestamp: 0x0102030405060708
        )

        var reassembler = LeapBLEFrameReassembler()
        let parsed = try #require(reassembler.append(frame).single)
        let plain = try session.decrypt(parsed)
        var body = Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x03])
        body.append(LeapBLEConfiguration.manualControl.bytes)

        #expect(plain.count == 19)
        #expect(plain.first == LeapBLECryptoSession.crc8(body))
        #expect(plain.dropFirst() == body)
    }

    @Test("固定 ECDH 向量生成官方 1.9 AA AE 认证帧")
    func authenticationFrameMatchesOpenSSLVector() throws {
        let certificate = deterministicCertificate()
        let session = try makeDeterministicSession()
        let frame = try session.fullAuthenticationFrame(
            certificate: certificate,
            accountId: "12345678",
            deviceId: "0123456789ABCDEF0123456789ABCDEF",
            timestamp: 1_700_000_000
        )

        #expect(frame.count == 291)
        #expect(frame.prefix(8).hexString.lowercased() == "aaae1f01d4b01a00")
        #expect(frame.suffix(2) == Data([0x01, 0x09]))

        let encodedCipher = frame[73..<(frame.count - 2)]
        var encryptedFrame = Data([0xAA, 0xAB])
        encryptedFrame.appendLittleEndian(UInt32(encodedCipher.count))
        encryptedFrame.append(encodedCipher)
        var reassembler = LeapBLEFrameReassembler()
        let parsed = try #require(reassembler.append(encryptedFrame).single)
        let plain = try session.decrypt(parsed)
        let authTextLength = Int(plain.prefix(4).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        let authText = try #require(
            String(data: plain[4..<(4 + authTextLength)], encoding: .utf8)
        )
        #expect(
            authText
                == "1700000000;a;12345678;0123456789ABCDEF0123456789ABCDEF;d;e;f;56;2.00;08;16;1;0;1;1;"
        )

        let digest = SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "e71e332f17e6d305edf2ba359b11b1c4fb9921f83d75fe85ace36ec4ab1d4d98")
    }

    @Test("AA AE 从同一配置模型生成无感开关")
    func authenticationUsesConfigurationFlags() throws {
        let certificate = deterministicCertificate()
        let session = try makeDeterministicSession()
        let frame = try session.fullAuthenticationFrame(
            certificate: certificate,
            accountId: "12345678",
            deviceId: "0123456789ABCDEF0123456789ABCDEF",
            timestamp: 1_700_000_000,
            configuration: .manualControl
        )

        let encodedCipher = frame[73..<(frame.count - 2)]
        var encryptedFrame = Data([0xAA, 0xAB])
        encryptedFrame.appendLittleEndian(UInt32(encodedCipher.count))
        encryptedFrame.append(encodedCipher)
        var reassembler = LeapBLEFrameReassembler()
        let parsed = try #require(reassembler.append(encryptedFrame).single)
        let plain = try session.decrypt(parsed)
        let authTextLength = Int(plain.prefix(4).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        let authText = try #require(String(data: plain[4..<(4 + authTextLength)], encoding: .utf8))

        #expect(authText.hasSuffix(";56;2.00;08;16;1;0;0;1;"))
    }

    @Test("老款 AES AA EE 重连帧使用 SHA-256 摘要")
    func legacyReconnectAuthenticationUsesSHA256() throws {
        let session = try makeDeterministicSession()
        let frame = try session.reconnectAuthenticationFrame(
            token: "DEADBEEF",
            accountId: "1234567890",
            timestamp: 0x0102030405060708
        )

        #expect(frame.prefix(2) == Data([0xAA, 0xEE]))
        #expect(frame.suffix(18).prefix(2) == Data([0x01, 0x09]))
        let digest = Data(SHA256.hash(data: frame.dropLast(16)))
        #expect(frame.suffix(16) == digest.prefix(16))
    }

    @Test("SM2 KAP 与 BabaSSL 8.3.1 固定向量一致")
    func sm2KAPMatchesBabaSSLVector() throws {
        let agreement = try LeapGMCrypto.sm2KAP(
            certificatePEM: "unused by raw vector",
            privateKey: Data(repeating: 0, count: 31) + Data([1]),
            peerPublicKeyX963: try Data(hexString: Self.sm2PeerPublicKey)
        )

        #expect(agreement.publicKey.hexString.lowercased() == Self.sm2LocalPublicKey)
        #expect(
            agreement.sharedKey.hexString.lowercased()
                == "5f86e6b17708f60dfb5d8e3f3ce2b35d3d29744d51c46fc14cdb7bb95fdaf48b"
        )
    }

    @Test("SM2 PEM X.509 证书可提取中控公钥")
    func sm2CertificateParses() throws {
        let agreement = try LeapGMCrypto.sm2KAP(
            certificatePEM: Self.sm2CertificatePEM,
            privateKey: Data(repeating: 0, count: 31) + Data([1])
        )

        #expect(agreement.publicKey.hexString.lowercased() == Self.sm2LocalPublicKey)
        #expect(agreement.sharedKey.count == 32)
        #expect(agreement.sharedKey.contains(where: { $0 != 0 }))
    }

    @Test("国密证书生成官方 SM3/SM4 AA AB 控车帧")
    func smControlFrameMatchesOpenSSLVector() throws {
        let sm = LeapBLEKeyCertificate(
            ecdhPublicKey: "unused by raw vector",
            keyType: 1,
            passwordCard: String(repeating: "0123456789", count: 8),
            plainText: "a;b;c;d;e;f",
            signResult: Data(repeating: 0, count: 64).base64EncodedString(),
            vin: "TESTVIN1234567890"
        )
        let session = try LeapBLECryptoSession.make(
            certificate: sm,
            vin: sm.vin,
            sessionID: 0x001AB0D4,
            privateKeyRawRepresentation: Data(repeating: 0, count: 31) + Data([1]),
            smPeerPublicKeyX963: try Data(hexString: Self.sm2PeerPublicKey)
        )
        let frame = try session.controlFrame(command: .unlock, timestamp: 0x0102030405060708)

        #expect(
            frame.hexString.lowercased()
                == "aaab18000000416943615a4a303431474e644a4561545a70646736413d3d"
        )
        var reassembler = LeapBLEFrameReassembler()
        let parsed = try #require(reassembler.append(frame).single)
        #expect(try session.decrypt(parsed) == Data([0x88, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01]))
    }

    @Test("AA EE 组帧与官方 App 运行时固定向量一致")
    func reconnectFrameMatchesOfficialRuntimeVector() throws {
        let publicKey = Data([0x04] + (1...64).map(UInt8.init))
        let frame = try LeapBLECryptoSession.reconnectFrame(
            sessionID: 0x001AB0D4,
            publicKey: publicKey,
            encodedCipher: Data(repeating: 0x41, count: 64),
            usesSM3: true
        )

        #expect(frame.count == 155)
        #expect(
            frame.hexString.lowercased()
                == "aaee9700d4b01a00040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414101096135e0da096a186bf8d79ced78d22062"
        )
    }

    @Test("国密 AA EE 明文包含 token、9 字节配置和账号长度")
    func smReconnectAuthenticationPlaintext() throws {
        let certificate = LeapBLEKeyCertificate(
            ecdhPublicKey: "unused by raw vector",
            keyType: 1,
            passwordCard: String(repeating: "0123456789", count: 8),
            plainText: "a;b;c;d;e;f",
            signResult: Data(repeating: 0, count: 64).base64EncodedString(),
            vin: "TESTVIN1234567890"
        )
        let session = try LeapBLECryptoSession.make(
            certificate: certificate,
            vin: certificate.vin,
            sessionID: 0x001AB0D4,
            privateKeyRawRepresentation: Data(repeating: 0, count: 31) + Data([1]),
            smPeerPublicKeyX963: try Data(hexString: Self.sm2PeerPublicKey)
        )
        let frame = try session.reconnectAuthenticationFrame(
            token: "DEADBEEF",
            accountId: "1234567890",
            timestamp: 0x0102030405060708
        )

        #expect(frame.count == 155)
        #expect(frame.prefix(8).hexString.lowercased() == "aaee9700d4b01a00")
        #expect(frame[frame.count - 18..<frame.count - 16] == Data([0x01, 0x09]))

        let encodedCipher = frame[73..<(frame.count - 18)]
        var encryptedFrame = Data([0xAA, 0xAB])
        encryptedFrame.appendLittleEndian(UInt32(encodedCipher.count))
        encryptedFrame.append(encodedCipher)
        var reassembler = LeapBLEFrameReassembler()
        let parsed = try #require(reassembler.append(encryptedFrame).single)
        let plain = try session.decrypt(parsed)

        var expected = Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        expected.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        expected.append(contentsOf: [0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 1, 1])
        expected.append(contentsOf: [0x0A, 0])
        expected.append(contentsOf: "1234567890".utf8)
        #expect(plain == expected)
    }

    @Test("未知证书类型仍明确拒绝")
    func unknownCertificateTypeIsRejected() {
        let ecc = deterministicCertificate()
        let unknown = LeapBLEKeyCertificate(
            ecdhPublicKey: ecc.ecdhPublicKey,
            keyType: 2,
            passwordCard: ecc.passwordCard,
            plainText: ecc.plainText,
            signResult: ecc.signResult,
            vin: ecc.vin
        )

        #expect(throws: LeapBLEProtocolError.unsupportedKeyType(2)) {
            try LeapBLECryptoSession.make(certificate: unknown, vin: unknown.vin)
        }
    }

    @Test("AA AC 错误应答取最后一字节 resultCode")
    func errorResponseDecode() {
        let raw = Data([0xAA, 0xAC, 2, 0, 0, 1, 2, 0, 0, 0, 0x55, 0x07])
        var reassembler = LeapBLEFrameReassembler()
        #expect(reassembler.append(raw).single?.event == .errorResponse(resultCode: 7, payload: Data([0x55, 0x07])))
    }

    @Test("只有 BLE 写入前不可用才允许回退 HTTP")
    func bluetoothFallbackBoundary() {
        #expect(BLEControlAttemptResult.unavailableBeforeWrite("offline").shouldFallbackToHTTP)
        #expect(!BLEControlAttemptResult.confirmed.shouldFallbackToHTTP)
        #expect(!BLEControlAttemptResult.sentWithoutConfirmation.shouldFallbackToHTTP)
        #expect(!BLEControlAttemptResult.failedAfterWrite("uncertain").shouldFallbackToHTTP)
    }

    @Test("车辆绑定可按账号和 VIN 完整持久化")
    func vehicleBindingCodableRoundTrip() throws {
        let binding = BLEVehicleBinding(
            accountId: "account-1",
            vin: "TESTVIN1234567890",
            peripheralIdentifier: UUID(uuidString: "E71B30A0-C135-43B4-B1E8-A4E4928A9810")!,
            certificateFingerprint: "A1B2C3D4",
            configuration: .manualControl,
            syncState: .pending,
            removeAfterDisable: false,
            lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoded = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(BLEVehicleBinding.self, from: encoded) == binding)
    }

    @Test("新版距离档位保留云端基准和开关")
    func distanceCalibrationPreservesBaseline() throws {
        var config = LeapBLEConfiguration.manualControl
        config.unlockCalibration = 12
        config.setUnlockDistance(.near)
        #expect(config.calibrationText == "56;2.00;04;16")
        config.setUnlockDistance(.far)
        #expect(config.unlockCalibration == 7)
        config.setUnlockDistance(.standard)
        #expect(config.unlockCalibration == 12)
        #expect(!config.autoUnlockEnabled)
        #expect(try JSONDecoder().decode(LeapBLEConfiguration.self, from: JSONEncoder().encode(config)) == config)
        #expect(config.wireBytes(protocolMinor: 8).count == 7)
        #expect(config.wireBytes(protocolMinor: 9).count == 9)
        let old = Data(#"{"distanceCalibration":56,"coefficientHundredths":200,"unlockCalibration":8,"lockCalibration":16,"isEnabled":true,"autoLockEnabled":false,"autoUnlockEnabled":false,"supportsButton":true}"#.utf8)
        #expect(try JSONDecoder().decode(LeapBLEConfiguration.self, from: old).unlockDistance == .standard)
    }

    @Test("1.22.66 根据能力选择单锚点和多锚点标定")
    func anchorCalibration() throws {
        #expect(BLECalibration.modelName(for: "iPhone18,3") == "iPhone 17")
        #expect(BLECalibration.modelName(for: "iPhone99,9") == "iPhone99,9")
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"data":{"anchorPointParams":"56;2.00;12;16","autonomyParams":"56;2.00;04;16","multipleAnchorPointParams":"60;2.50;14;20","multipleAnchorAutonomyParams":"60;2.50;07;20"}}"#.utf8))
        let single = try BLECalibration(json: json)
        let multi = try BLECalibration(json: json, multipleAnchors: true)
        var applied = single.applying(to: .manualControl)
        #expect(applied.unlockDistance == .near)
        #expect(applied.defaultUnlockCalibration == 12)
        applied.setUnlockDistance(.standard)
        #expect(applied.unlockCalibration == 12)
        let appliedMulti = multi.applying(to: .manualControl)
        #expect(appliedMulti.multipleAnchors == true)
        #expect(appliedMulti.unlockDistance == .far)
        #expect(appliedMulti.coefficientHundredths == 250)
        #expect(appliedMulti.supportsButton)
        #expect(BLECalibration.parse("56;nan;08;16") == nil)
        #expect(BLECalibration.parse("56;2;256;16") == nil)
    }

    @Test("协议版本支持 Bluetooth SIG 的三种 UUID 表示", arguments: [
        "0109", "00000109", "00000109-0000-1000-8000-00805f9b34fb"
    ])
    func protocolVersionUUIDForms(_ uuid: String) throws {
        #expect(LeapBLEProtocol.protocolMinor(serviceUUIDs: ["FFFE", uuid]) == 9)
        let session = try makeDeterministicSession()
        let certificate = deterministicCertificate()
        let expected = try session.fullAuthenticationFrame(certificate: certificate,
            accountId: "12345678", deviceId: "device", timestamp: 1700000000, protocolMinor: 9)
        let actual = try session.fullAuthenticationFrame(certificate: certificate,
            accountId: "12345678", deviceId: "device", timestamp: 1700000000,
            protocolMinor: LeapBLEProtocol.protocolMinor(serviceUUIDs: [uuid]))
        #expect(actual == expected)
    }

    @Test("分段广播不丢失版本，新广播明确给出旧版本时可更新")
    func partialAdvertisementPreservesProtocol() {
        let initial = ["FFFE", "0109"]
        let partial = LeapBLEProtocol.mergingAdvertisedServices(previous: initial, incoming: ["FFFE"])
        #expect(LeapBLEProtocol.protocolMinor(serviceUUIDs: partial) == 9)
        let empty = LeapBLEProtocol.mergingAdvertisedServices(previous: partial, incoming: [])
        #expect(LeapBLEProtocol.protocolMinor(serviceUUIDs: empty) == 9)
        let changed = LeapBLEProtocol.mergingAdvertisedServices(previous: empty,
            incoming: ["00000106-0000-1000-8000-00805F9B34FB"])
        #expect(LeapBLEProtocol.protocolMinor(serviceUUIDs: changed) == 6)
        #expect(LeapBLEProtocol.usesPre17TokenFormat(serviceUUIDs: changed))
    }

    @Test("不把厂商 UUID 或无效版本误认为 1.9")
    func vendorUUIDIsNotProtocolVersion() {
        for uuid in ["00000109-1234-5678-ABCD-00805F9B34FB", "010G", "FFFF", "0209"] {
            #expect(LeapBLEProtocol.advertisedProtocolMinor(serviceUUIDs: [uuid]) == nil)
            #expect(LeapBLEProtocol.protocolMinor(serviceUUIDs: [uuid], fallback: 6) == 6)
        }
    }

    @Test("1.22.66 兼容旧车配置，但认证声明 1.9")
    func advertisedProtocolCompatibility() throws {
        #expect(LeapBLEProtocol.protocolMinor(serviceUUIDs: ["FFFE", "0109"]) == 9)
        #expect(LeapBLEProtocol.protocolMinor(serviceUUIDs: ["FFFE", "0106"]) == 6)
        #expect(LeapBLEProtocol.protocolMinor(serviceUUIDs: []) == 8)
        #expect(LeapBLEProtocol.protocolMinor(serviceUUIDs: [], fallback: 9) == 9)
        let session = try makeDeterministicSession()
        let frame = try session.reconnectAuthenticationFrame(token: "deadbeef", accountId: "1234567890",
            timestamp: 0x0102030405060708, pre17: true, protocolMinor: 6)
        #expect(frame.count == 117)
        #expect(frame.prefix(8) == Data([0xaa, 0xee, 0x71, 0, 0xd4, 0xb0, 0x1a, 0]))
        let full = try session.fullAuthenticationFrame(certificate: deterministicCertificate(),
            accountId: "12345678", deviceId: "0123456789ABCDEF0123456789ABCDEF", timestamp: 1700000000, protocolMinor: 8)
        #expect(full.suffix(2) == Data([1, 9]))
        let cipher = full.dropFirst(73).dropLast(2)
        var framed = Data([0xaa, 0xab]); framed.appendLittleEndian(UInt32(cipher.count)); framed.append(cipher)
        var reassembler = LeapBLEFrameReassembler()
        let plain = try session.decrypt(#require(reassembler.append(framed).single))
        #expect(String(decoding: plain.dropFirst(4).dropLast(64), as: UTF8.self).hasSuffix(";1;0;"))
    }

    @Test("直进直出使用座舱 AA AE 模块头，不带钥匙配置尾部")
    func callCarAuthentication() throws {
        let session = try makeDeterministicSession()
        let frame = try session.callCarAuthenticationFrame(certificate: deterministicCertificate(),
            accountId: "12345678", deviceId: "device", timestamp: 1_700_000_000)
        #expect(Array(frame.prefix(5)) == [0xAA, 0xAE, 1, 1, 10])
        #expect(Int(frame[5]) | Int(frame[6]) << 8 == frame.count - 7)
        #expect(Data(frame[7..<11]) == Data([0xD4, 0xB0, 0x1A, 0]))
        let cipher = Data(frame.dropFirst(76))
        var raw = Data([0xAA, 0xAB]); raw.appendLittleEndian(UInt32(cipher.count)); raw.append(cipher)
        let plain = try session.decrypt(LeapBLEFrame(kind: .encrypted, declaredPayloadLength: cipher.count, bytes: raw))
        let expected = Data("1700000000;a;12345678;device;d;e;f;".utf8)
        #expect(plain.subdata(in: 4..<(4 + expected.count)) == expected)
        #expect(plain.count == 4 + expected.count + 64)
        for order: UInt8 in [1, 2, 3, 4, 5, 6] {
            var parser = LeapBLEFrameReassembler()
            let command = try #require(parser.append(session.callCarOrderFrame(order)).single)
            #expect(try session.decrypt(command) == Data([order]))
        }
    }

    @Test("座舱状态优先处理故障和障碍物；通用三段回包不能放行车辆")
    func callCarStates() {
        #expect(CallCarStatus.parse("2;01;3") == nil)
        #expect(CallCarStatus.parse("0;5;1;0;0") == .activate)
        #expect(CallCarStatus.parse("0;2;0;0;0") == .ready)
        #expect(CallCarStatus.parse("0;6;0;0;0") == .ready)
        #expect(CallCarStatus.parse("0;2;0;4;0") == .paused(4))
        #expect(CallCarStatus.parse("0;2;0;4;9") == .failed(9))
        #expect(CallCarStatus.parse("0;2;3;0;0") == .unavailable(3))
        #expect(CallCarStatus.parse("0;4;0;0;0") == .paused(0))
        #expect(CallCarStatus.parse("0;99;0;0;0") == .failed(99))
        #expect(CallCarStatus.parse("0;2;;0;0") == nil)
    }

    @Test("座舱 AA AC 独立重组，处理分片、粘包、错误模块和异常长度")
    func callCarPackets() throws {
        let raw = Data([0xAA, 0xAC, 1, 1, 0, 3, 0, 0, 0, 65, 66, 67, 0, 0])
        var parser = CallCarPacketBuffer()
        #expect(try parser.append(Data([0, 0xAA]) + raw.prefix(7)).isEmpty)
        let frames = try parser.append(raw.dropFirst(7) + raw)
        #expect(frames.count == 2)
        #expect(frames[0].type == 1)
        #expect(frames[0].payload == Data("ABC".utf8))
        var wrong = raw; wrong[2] = 2
        #expect(throws: (any Error).self) { try parser.append(wrong) }
        parser.reset()
        #expect(throws: (any Error).self) { try parser.append(Data([170, 172, 1, 1, 0, 255, 255, 255, 255])) }
    }

    private func makeDeterministicSession() throws -> LeapBLECryptoSession {
        try LeapBLECryptoSession.make(
            certificate: deterministicCertificate(),
            vin: "TESTVIN1234567890",
            sessionID: 0x001AB0D4,
            privateKeyRawRepresentation: Data(repeating: 0, count: 31) + Data([1])
        )
    }

    private func deterministicCertificate() -> LeapBLEKeyCertificate {
        LeapBLEKeyCertificate(
            ecdhPublicKey: "BHzyexiNA09+ilI4AwS1GsPAiWnid/IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E=",
            keyType: 0,
            passwordCard: String(repeating: "0123456789", count: 8),
            plainText: "a;b;c;d;e;f",
            signResult: Data(repeating: 0, count: 64).base64EncodedString(),
            vin: "TESTVIN1234567890"
        )
    }

    private static let sm2LocalPublicKey =
        "0432c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7"
        + "bc3736a2f4f6779c59bdcee36b692153d0a9877cc62a474002df32e52139f0a0"

    private static let sm2PeerPublicKey =
        "0456cefd60d7c87c000d58ef57fa73ba4d9c0dfa08c08a7331495c2e1da3f2bd52"
        + "31b7e7e6cc8189f668535ce0f8eaf1bd6de84c182f6c8e716f780d3a970a23c3"

    private static let sm2CertificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIIBhjCCASugAwIBAgIUTzck05zW50mkmjvS/cenk1gi1DkwCgYIKoEcz1UBg3Uw
        GDEWMBQGA1UEAwwNTGVhcCBCTEUgVGVzdDAeFw0yNjA4MTExMTI0MjRaFw0zNjA4
        MDgxMTI0MjRaMBgxFjAUBgNVBAMMDUxlYXAgQkxFIFRlc3QwWTATBgcqhkjOPQIB
        BggqgRzPVQGCLQNCAARm0r00h4HiOELHHY28UKYY8lX5SKf4LBHGmvWNa0KHsASd
        U0HR+dehjj+S2Lx09VidadPDi94ZFdcXF4jh9BhCo1MwUTAdBgNVHQ4EFgQUGukz
        fBVOWfRrTrtSw1Ir3aXscdwwHwYDVR0jBBgwFoAUGukzfBVOWfRrTrtSw1Ir3aXs
        cdwwDwYDVR0TAQH/BAUwAwEB/zAKBggqgRzPVQGDdQNJADBGAiEA6uBKX+5wjDkW
        JTdlQ1ELDYJqkYGOq+YnPZ7A7hM8cUMCIQDFAca3P6D583BC8j5q+Q1Udix210pb
        Vr72D+mN0HFPSg==
        -----END CERTIFICATE-----
        """
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}

private extension Data {
    init(hexString: String) throws {
        guard hexString.count.isMultiple(of: 2) else {
            throw LeapBLEProtocolError.invalidFrame("测试向量 Hex 长度不是偶数")
        }
        var result = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                throw LeapBLEProtocolError.invalidFrame("测试向量包含非 Hex 字符")
            }
            result.append(byte)
            index = next
        }
        self = result
    }
}
