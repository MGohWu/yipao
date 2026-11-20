import Foundation
import OSLog

/// Local, bounded BLE trace. Never record certificates, identifiers, tokens or ciphertext.
enum BLEDiagnostics {
    private static let queue = DispatchQueue(label: "app.leap.ble-diagnostics")
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LeapControl", category: "BLE")
    private static let limit = 512 * 1024
    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BLEDiagnostics", isDirectory: true)
    }
    private static var file: URL { directory.appendingPathComponent("ble-current.log") }
    private static var previous: URL { directory.appendingPathComponent("ble-previous.log") }

    static func record(_ channel: String, _ message: String) {
        let line = "\(Date.now.ISO8601Format()) [\(channel)] \(message.replacingOccurrences(of: "\n", with: " "))\n"
        logger.info("\(line, privacy: .public)")
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size >= limit {
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.moveItem(at: file, to: previous)
                }
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil,
                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch { logger.error("BLE trace write failed") }
        }
    }

    static func error(_ value: Error?) -> String {
        guard let value else { return "none" }
        let error = value as NSError
        return "\(error.domain):\(error.code)"
    }

    /// Preserve actionable error categories and Chinese explanations without logging response bodies.
    static func failureDetail(_ value: Error) -> String {
        guard let error = value as? LeapError else { return self.error(value) }
        switch error {
        case .notLoggedIn: return "notLoggedIn"
        case .sessionExpired: return "sessionExpired"
        case .needsRelogin: return "needsRelogin"
        case .missingVehicle: return "missingVehicle"
        case .http(let status, _): return "http status=\(status)"
        case .server(let message): return "server message=\(safeMessage(message))"
        case .decode(let message): return "decode message=\(safeMessage(message))"
        case .network(let message): return "network message=\(safeMessage(message))"
        case .crypto: return "crypto"
        }
    }

    static func safeMessage(_ message: String) -> String {
        let redacted = message.replacingOccurrences(
            of: #"(?i)https?://\S+|(?:[a-f0-9]{2}:){5}[a-f0-9]{2}|[a-z0-9_+/=.-]{6,}"#,
            with: "[redacted]", options: .regularExpression)
        return String(redacted.prefix(240)).replacingOccurrences(of: "\n", with: " ")
    }

    static func versionTokenSummary(_ token: String?) -> String {
        guard let token else { return "versionToken=missing" }
        if token.isEmpty { return "versionToken=empty" }
        // Only expose version-shaped values. MACs, IDs and arbitrary server strings stay hidden.
        let pattern = #"^[vV]?[0-9]{1,3}(?:\.[0-9]{1,6}){0,7}$"#
        if token.range(of: pattern, options: .regularExpression) != nil {
            return "versionToken=\(token)"
        }
        let shape = token.unicodeScalars.prefix(64).map { character -> String in
            switch character.value {
            case 48...57: return "d"
            case 65...90, 97...122: return "a"
            case 46: return "."
            case 58: return ":"
            case 44: return ","
            case 32, 9, 10, 13: return "_"
            default: return "?"
            }
        }.joined()
        return "versionToken=redacted length=\(token.utf8.count) shape=\(shape)"
    }

    static func versionResponseSummary(_ response: JSONValue) -> String {
        func kind(_ value: JSONValue?) -> String {
            switch value {
            case .object: return "object"
            case .array: return "array"
            case .string: return "string"
            case .number: return "number"
            case .bool: return "bool"
            case .null: return "null"
            case nil: return "missing"
            }
        }
        let list = response["data"]?["list"]?.arrayValue
        let info = list?.first?["bluetoothInfo"]
        let minor = LeapBLEProtocol.cloudProtocolMinor(response: response)
        return "result=\(response["result"]?.intValue.map(String.init) ?? "missing") code=\(response["code"]?.intValue.map(String.init) ?? "missing") data=\(kind(response["data"])) list=\(kind(response["data"]?["list"])) count=\(list?.count ?? -1) bluetoothInfo=\(kind(info)) \(versionTokenSummary(LeapBLEProtocol.cloudVersionToken(response: response))) parsedMinor=\(minor.map(String.init) ?? "unknown") message=\(safeMessage(response.responseMessage))"
    }

    /// Numeric configuration only: never include credentials or encrypted frames.
    static func configurationSummary(_ value: LeapBLEConfiguration, protocolMinor: Int? = nil) -> String {
        var text = "distance=\(value.unlockDistance.label)(\(value.unlockDistance.rawValue)) explicit=\(value.distanceSelection != nil) calibration=\(value.calibrationText) baseline=\(value.defaultUnlockCalibration.map { String($0) } ?? "unset") anchors=\(value.multipleAnchors.map { $0 ? "multiple" : "single" } ?? "unknown") enabled=\(value.isEnabled) autoUnlock=\(value.autoUnlockEnabled) autoLock=\(value.autoLockEnabled) button=\(value.supportsButton)"
        if let protocolMinor {
            text += " profileMinor=\(protocolMinor) wire=\(value.wireBytes(protocolMinor: protocolMinor).hexString)"
        }
        return text
    }

    static func frameSummary(_ frame: LeapBLEFrame) -> String {
        var text = "kind=\(frame.kind.label) bytes=\(frame.bytes.count) declared=\(frame.declaredPayloadLength)"
        if case .errorResponse(let code, _) = frame.event {
            text += " resultCode=\(code) hex=\(String(format: "0x%02X", code)) meaning=\(LeapBLEAuthenticationResult.description(code)) source=payload.last offset=\(frame.bytes.count - 1) errorFrame=\(frame.bytes.prefix(42).hexString)"
        }
        return text
    }

    static func export() throws -> URL {
        try queue.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            var text = "LeapControl BLE diagnostics \(version) (\(build))\nExported \(Date.now.ISO8601Format())\n"
            for source in [previous, file] { text += (try? String(contentsOf: source, encoding: .utf8)) ?? "" }
            let url = directory.appendingPathComponent("ble-export.log")
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        }
    }
}
