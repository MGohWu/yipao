import Foundation

/// iOS 1.22.66 的座舱专用协议。认证、GATT 与回包均独立于无感钥匙。
enum CallCarProtocol {
    static let service = "0000EEED-0000-1000-8000-00805F9B34FB"
    static let characteristic = "0000EEE2-0000-1000-8000-00805F9B34FB"

    static func matches(manufacturerData: Data, vin: String) -> Bool {
        let marker = Data(LeapCrypto.md5Hex(Data(vin.utf8)).dropFirst(8).prefix(8).utf8)
        return manufacturerData.count >= 14 && manufacturerData.subdata(in: 6..<14) == marker
    }
}

struct CallCarPacket {
    let type: UInt16
    let payload: Data
}

struct CallCarPacketBuffer {
    private var data = Data()
    mutating func reset() { data.removeAll() }
    mutating func append(_ bytes: Data) throws -> [CallCarPacket] {
        data.append(bytes)
        var packets: [CallCarPacket] = []
        while data.count >= 2 {
            if data.prefix(2) != Data([0xAA, 0xAC]) { data.removeFirst(); data = Data(data); continue }
            guard data.count >= 9 else { break }
            let length = (0..<4).reduce(0) { $0 | (Int(data[5 + $1]) << (8 * $1)) }
            guard length <= 65536 else { data.removeAll(); throw LeapBLEProtocolError.invalidFrame("座舱回包长度异常") }
            guard data.count >= length + 11 else { break }
            guard data[2] == 1 else { throw LeapBLEProtocolError.invalidFrame("座舱业务模块不匹配") }
            packets.append(CallCarPacket(type: UInt16(data[3]) | UInt16(data[4]) << 8,
                                         payload: data.subdata(in: 9..<(9 + length))))
            data = Data(data.dropFirst(length + 11)) // dataProcess + crcData
        }
        return packets
    }
}

enum CallCarStatus: Equatable {
    case waiting, activate, ready, paused(Int), failed(Int), unavailable(Int)

    /// 对应 LMVCallCarService.handleRecieveDataStr:，至少五项，故不能把 2;01;3 当业务就绪。
    static func parse(_ text: String) -> CallCarStatus? {
        let parts = text.components(separatedBy: ";")
        guard parts.count >= 5 else { return nil }
        let values = parts.prefix(5).compactMap(Int.init)
        guard values.count == 5, values.allSatisfy({ $0 >= 0 }) else { return nil }
        guard values.contains(where: { $0 != 0 }) else { return .waiting }
        let status = values[1]
        if status == 5 { return values[2] == 1 ? .activate : .unavailable(values[2]) }
        if values[4] != 0 { return .failed(values[4]) }
        if values[3] != 0 { return .paused(values[3]) }
        if values[2] != 0 { return .unavailable(values[2]) }
        switch status {
        case 1: return .waiting
        case 2, 6: return .ready
        case 4: return .paused(0)
        default: return .failed(status)
        }
    }
}
