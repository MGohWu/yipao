import Foundation

/// 零跑云端的一次充电——**原厂自己的充电明细**。
///
/// 端点是 `POST {appCenter}/carownerservice/charge/daily/detail/page`，和行程那套一样是
/// 「7 个固定头 + 业务参数」签名。字段来自 mate-cn 的导入实现：
/// `chargeGunStartTs` / `chargeGunEndTs`（毫秒，早/晚分别是 `chargeEarliestTs` /
/// `chargeLatestTs`）、`chargeInEnergy`（度，充进电池的电）、`chargeType`（SLOW / FAST / QUICK）、
/// `chargeStartLatitude` / `chargeStartLongitude`（**GCJ-02**，和中控屏的定位同一套）。
///
/// 它比我们自己积分的强在两点：一是 App 没开也有，二是「度数」是车的结算值，
/// 不用拿电压电流去猜。它没有的是：起止电量、峰值功率——那两项仍然只有本机看得见。
struct CloudChargeRecord: Codable, Hashable, Sendable {
    var key: String
    var vin: String?
    var startAt: Date
    var endAt: Date
    /// 充进电池的电量（kWh）。云端的口径与充电桩计费口径不同，通常小一点（有损耗）。
    var energyKwh: Double?
    var isDC: Bool
    var latitude: Double?
    var longitude: Double?

    var duration: TimeInterval { max(0, endAt.timeIntervalSince(startAt)) }
}

enum CloudChargeParser {

    static func records(from rows: [[String: JSONValue]], vin: String?) -> [CloudChargeRecord] {
        rows.compactMap { record(from: $0, vin: vin) }
    }

    static func record(from row: [String: JSONValue], vin: String?) -> CloudChargeRecord? {
        let start = CloudTripParser.date(row["chargeGunStartTs"] ?? row["chargeEarliestTs"])
        let end = CloudTripParser.date(row["chargeGunEndTs"] ?? row["chargeLatestTs"])
        guard let start, let end, end > start else { return nil }
        // 太快的不像充电：插枪握手、补一小会儿电都会产生几十秒的记录。
        guard end.timeIntervalSince(start) >= 60 else { return nil }

        let energy = CloudTripParser.positive(row["chargeInEnergy"])
        let latitude = CloudTripParser.positive(row["chargeStartLatitude"])
        let longitude = CloudTripParser.positive(row["chargeStartLongitude"])
        let hasCoordinate = (latitude ?? 0) != 0 && (longitude ?? 0) != 0
        let type = (row["chargeType"]?.stringValue ?? "").uppercased()

        let key = "\(Int(start.timeIntervalSince1970 * 1000))-\(Int(end.timeIntervalSince1970 * 1000))"
        return CloudChargeRecord(
            key: key,
            vin: row["vin"]?.stringValue ?? vin,
            startAt: start,
            endAt: end,
            energyKwh: energy,
            // 1 / 2 是老接口的写法，SLOW / FAST / QUICK 是新的。认不出来时按「不是快充」处理，
            // 界面上宁可少标一个「快充」，也不要给交流桩贴上直流标签。
            isDC: type == "FAST" || type == "QUICK" || type == "2",
            latitude: hasCoordinate ? latitude : nil,
            longitude: hasCoordinate ? longitude : nil
        )
    }
}

/// 把云端充电记录合进本机记录。规则与 `CloudTripMerge` 一一对应，只是比较的量从
/// 距离换成了度数：行程看「跑的路是不是同一段」，充电看「充的电是不是同一次」。
enum CloudChargeMerge {

    struct Result: Equatable {
        var charges: [ChargeRecord]
        var added: Int
        var matched: Int
        var dropped: Int
    }

    static let overlapFraction = 0.5
    /// 度数差得远，就不是同一次充电（相邻两次补电可能连着，但不会是同一条记录）。
    static let energyFloorKwh = 1.0
    static let energyRatio = 0.5
    static let coveredFraction = 0.8

    static func merge(
        local: [ChargeRecord],
        cloud: [CloudChargeRecord],
        window: ClosedRange<Date>,
        limit: Int = ChargeLogStore.limit
    ) -> Result {
        var charges = local
        var added = 0
        var matched = 0

        let keys = Set(cloud.map(\.key))
        charges.removeAll { charge in
            guard charge.officialKey != nil, window.contains(charge.startAt) else { return false }
            guard let key = charge.officialKey else { return true }
            return !keys.contains(key)
        }

        for record in cloud.sorted(by: { $0.startAt < $1.startAt }) {
            if let index = charges.firstIndex(where: { $0.officialKey == record.key }) {
                apply(record, to: &charges[index])
                continue
            }
            switch bestMatch(in: charges, for: record) {
            case .one(let index):
                apply(record, to: &charges[index])
                matched += 1
            case .none:
                charges.append(ChargeRecord(cloud: record))
                added += 1
            case .ambiguous:
                break
            }
        }

        let dropped = dropCoveredReconstructions(&charges, cloud: cloud)
        charges.sort { $0.startAt > $1.startAt }
        if charges.count > limit { charges = Array(charges.prefix(limit)) }
        return Result(charges: charges, added: added, matched: matched, dropped: dropped)
    }

    private enum Match {
        case one(Int)
        case none
        case ambiguous
    }

    private static func bestMatch(in charges: [ChargeRecord], for record: CloudChargeRecord) -> Match {
        var best: (index: Int, overlap: TimeInterval)?
        var tied = false
        // 只和本机真实看到的充电对齐；补记走覆盖检查那条路（理由同行程）。
        for (index, charge) in charges.enumerated() where !charge.isReconstructed {
            guard isSameSession(charge, record) else { continue }
            let overlap = CloudTripMerge.intersection(
                charge.startAt, charge.endAt, record.startAt, record.endAt
            )
            if let current = best {
                if overlap > current.overlap + 120 {
                    best = (index, overlap)
                    tied = false
                } else if abs(overlap - current.overlap) <= 120 {
                    tied = true
                }
            } else {
                best = (index, overlap)
            }
        }
        guard let best else { return .none }
        return tied ? .ambiguous : .one(best.index)
    }

    static func isSameSession(_ charge: ChargeRecord, _ record: CloudChargeRecord) -> Bool {
        let overlap = CloudTripMerge.intersection(charge.startAt, charge.endAt, record.startAt, record.endAt)
        guard overlap > 0 else { return false }
        let shorter = min(charge.duration, record.duration)
        // 充电比行车更容易连着来（一次没充满、换个桩接着充），比例门槛放宽一点。
        guard overlap >= 120 || (shorter > 0 && overlap / shorter >= overlapFraction) else {
            return false
        }
        if let a = charge.energyKwh, let b = record.energyKwh, a >= energyFloorKwh, b >= energyFloorKwh {
            let ratio = a / b
            return ratio >= energyRatio && ratio <= 1 / energyRatio
        }
        return true
    }

    /// 官方的度数覆盖本机的积分值，其余（起止电量、峰值功率、地名）留着——
    /// 那些云端没有，只有一帧帧看着车才有。
    private static func apply(_ record: CloudChargeRecord, to charge: inout ChargeRecord) {
        charge.officialKey = record.key
        if let energy = record.energyKwh, energy > 0 { charge.energyKwh = energy }
        // 只往「快充」方向纠正：云端明确说 FAST/QUICK 时以它为准；它说 SLOW 时不动本机的判断——
        // 认不出来的 `chargeType` 也会落成 false，拿它去覆盖会把本机按功率猜对的快充抹掉。
        if record.isDC { charge.isDC = true }
        if charge.latitude == nil { charge.latitude = record.latitude }
        if charge.longitude == nil { charge.longitude = record.longitude }
    }

    private static func dropCoveredReconstructions(
        _ charges: inout [ChargeRecord], cloud: [CloudChargeRecord]
    ) -> Int {
        guard !cloud.isEmpty else { return 0 }
        var dropped = 0
        charges.removeAll { charge in
            guard charge.isReconstructed, charge.duration > 60 else { return false }
            let covered = cloud.reduce(0.0) { sum, record in
                sum + CloudTripMerge.intersection(charge.startAt, charge.endAt, record.startAt, record.endAt)
            }
            guard covered / charge.duration >= coveredFraction else { return false }
            dropped += 1
            return true
        }
        return dropped
    }
}

extension ChargeRecord {
    /// 从云端记录造一条。起止电量、峰值功率留空——那两项云端不给。
    init(cloud record: CloudChargeRecord) {
        self.init(
            vin: record.vin,
            startAt: record.startAt,
            endAt: record.endAt,
            energyKwh: record.energyKwh,
            isDC: record.isDC,
            coordinate: {
                guard let latitude = record.latitude, let longitude = record.longitude else { return nil }
                return .init(latitude: latitude, longitude: longitude)
            }()
        )
        officialKey = record.key
    }
}
