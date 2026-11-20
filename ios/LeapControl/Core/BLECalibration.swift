import Foundation

/// iOS 1.22.66 的单/多锚点标定；自定义只替换第 3 项。
struct BLECalibration: Sendable {
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return modelName(for: machine)
    }

    static func modelName(for machine: String) -> String { deviceNames[machine] ?? machine }

    private static let deviceNames: [String: String] = [
        "iPhone7,1": "iPhone 6 Plus",
        "iPhone7,2": "iPhone 6",
        "iPhone8,1": "iPhone 6s",
        "iPhone8,2": "iPhone 6s Plus",
        "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7",
        "iPhone9,2": "iPhone 7 Plus",
        "iPhone9,3": "iPhone 7",
        "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8",
        "iPhone10,4": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus",
        "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X",
        "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE 2",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE 3",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
        "i386": "Simulator",
        "x86_64": "Simulator",
        "arm64": "Simulator",
    ]

    let multipleAnchors: Bool
    let defaultText: String
    let selectedDistance: BLEUnlockDistance

    init(json: JSONValue, multipleAnchors: Bool = false) throws {
        self.multipleAnchors = multipleAnchors
        let node = json["data"] ?? json
        let defaultKey = multipleAnchors ? "multipleAnchorPointParams" : "anchorPointParams"
        let customKey = multipleAnchors ? "multipleAnchorAutonomyParams" : "autonomyParams"
        guard let text = node[defaultKey]?.stringValue, Self.parse(text) != nil else {
            throw LeapError.decode("车辆距离标定数据无效")
        }
        defaultText = text
        let custom = node[customKey]?.stringValue ?? ""
        selectedDistance = Self.parse(custom).flatMap {
            BLEUnlockDistance(rawValue: Int($0.unlockCalibration))
        } ?? .standard
    }

    static func parse(_ text: String) -> LeapBLEConfiguration? {
        let fields = text.components(separatedBy: ";")
        guard fields.count >= 4, let distance = UInt8(fields[0]),
              let coefficient = Double(fields[1]), coefficient.isFinite,
              coefficient > 0, coefficient * 100 <= Double(UInt16.max),
              let unlock = UInt8(fields[2]), let lock = UInt8(fields[3]) else { return nil }
        var result = LeapBLEConfiguration.manualControl
        result.distanceCalibration = distance
        result.coefficientHundredths = UInt16((coefficient * 100).rounded())
        result.unlockCalibration = unlock
        result.lockCalibration = lock
        return result
    }

    func applying(to configuration: LeapBLEConfiguration) -> LeapBLEConfiguration {
        guard let defaults = Self.parse(defaultText) else { return configuration }
        var result = configuration
        result.multipleAnchors = multipleAnchors
        result.distanceCalibration = defaults.distanceCalibration
        result.coefficientHundredths = defaults.coefficientHundredths
        result.lockCalibration = defaults.lockCalibration
        result.defaultUnlockCalibration = defaults.unlockCalibration
        result.setUnlockDistance(configuration.distanceSelection ?? selectedDistance)
        return result
    }
}
