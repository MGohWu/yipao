import Foundation

/// 零跑云端的一趟行程——**原厂自己的逐趟明细**。
///
/// 这个接口是 `POST {appCenter}/carownerservice/mileage/daily/detail/page`，官方 App 的
/// 「行程」里那一趟趟记录就是从它画出来的（路径与字段来自 `pipipiper/leapmotor-mate-cn`
/// 与 `MiRaToo/LeapMore` 两个项目的实测，前者还留了 183 条记录的比对）。
///
/// 为什么这件事重要：在此之前我们只能靠手机前台轮询自己切段，App 不在跑就记不到，为了
/// 补上这段又得开后台定位常驻——费电，而且车主未必愿意。有了这个接口，**过去 30 天的每一趟
/// 都能在打开页面时一次性拉下来**，手机在不在线、App 有没有开过，都不影响。
///
/// 它给的是「一段路的结算」而不是轨迹：起止时间、距离、耗电、最高车速、增程车的耗油。
/// 没有经纬度，所以起终点地名仍然只能来自我们自己采到的坐标——两边的数据合起来用，
/// 见 `CloudTripMerge`。
struct CloudTripRecord: Codable, Hashable, Sendable {
    /// 稳定的主键，用云端那对毫秒时间戳拼出来。重复同步时靠它认出「已经合并过的那一条」。
    var key: String
    var vin: String?
    var startAt: Date
    var endAt: Date
    /// 公里，已经归一到一位小数。
    var distanceKm: Double
    var energyKWh: Double?
    var maxSpeedKmh: Int?
    /// 增程车这一趟烧的油（升）。纯电车云端会给 `0.0`，不是缺字段。
    var fuelLitres: Double?

    var duration: TimeInterval { max(0, endAt.timeIntervalSince(startAt)) }
}

/// 把云端返回的一页行解析成 `CloudTripRecord`。
///
/// 字段名照抄 mate-cn 的导出清单（那份清单是**唯一**来源，注释里写明「两份清单会漂移」）：
/// `routeStartTs` / `routeEndTs` / `totalMileage` / `totalMileageInMi` / `totalEnergy` /
/// `maxSpeed` / `driveReevOil`。时间戳是**毫秒**。
enum CloudTripParser {

    /// 英里 → 公里。`totalMileageInMi` 是带一位小数的英里数，是这套接口里唯一有小数位的距离。
    static let kmPerMile = 1.609_344

    static func records(from rows: [[String: JSONValue]], vin: String?) -> [CloudTripRecord] {
        rows.compactMap { record(from: $0, vin: vin) }
    }

    static func record(from row: [String: JSONValue], vin: String?) -> CloudTripRecord? {
        guard let start = date(row["routeStartTs"]), let end = date(row["routeEndTs"]),
              end > start else { return nil }

        let distance = distanceKm(row)
        let energy = positive(row["totalEnergy"])
        // 既没有距离也没有电量的记录是云端自己产生的碎片（mate-cn 在一台车的 98 条记录里
        // 见过 41 条 0 公里的），留着只会让列表多出一堆「0 km」。有电量没距离的除外——
        // 那是增程器在停车状态下发电，油和电都是真的。
        guard distance > 0 || energy != nil || positive(row["driveReevOil"]) != nil else { return nil }

        let maxSpeed = positive(row["maxSpeed"]).map { Int($0.rounded()) }
        let key = "\(Int(start.timeIntervalSince1970 * 1000))-\(Int(end.timeIntervalSince1970 * 1000))"
        return CloudTripRecord(
            key: key,
            vin: row["vin"]?.stringValue ?? vin,
            startAt: start,
            endAt: end,
            distanceKm: (distance * 10).rounded() / 10,
            energyKWh: energy,
            // 云端最高车速偶尔给 0（没采到），0 在这里没有意义，当没有。
            maxSpeedKmh: (maxSpeed ?? 0) > 0 ? maxSpeed : nil,
            fuelLitres: positive(row["driveReevOil"])
        )
    }

    /// 距离：公里字段是整数（短途常常是 0），英里字段带一位小数。
    ///
    /// **两者互相校验**，不盲信英里字段：换算成公里后要跟整数字段对得上（差 1.5 公里以内）
    /// 才采用它的精度。万一哪天这个字段其实装的是「带小数的公里」，换算会差出 60%，
    /// 这条校验就会把它挡回去，退化成整数字段——宁可少一位小数，不能整段距离错掉。
    static func distanceKm(_ row: [String: JSONValue]) -> Double {
        let km = max(0, positive(row["totalMileage"]) ?? 0)
        guard let miles = positive(row["totalMileageInMi"]), miles > 0 else { return km }
        let fromMiles = miles * kmPerMile
        guard abs(fromMiles - km) <= 1.5 else { return km }
        return fromMiles
    }

    /// 毫秒时间戳。云端有的车型给字符串，有的给数字，都认。
    static func date(_ value: JSONValue?) -> Date? {
        guard let raw = value?.doubleValue, raw.isFinite, raw > 0 else { return nil }
        // 兼容秒级的万一：小于 1e11 的当秒。
        let seconds = raw < 100_000_000_000 ? raw : raw / 1000
        guard seconds > 946_684_800, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 非负数才要。负数、NaN、读不出来一律当没有。
    static func positive(_ value: JSONValue?) -> Double? {
        guard let number = value?.doubleValue, number.isFinite, number >= 0 else { return nil }
        return number
    }
}

/// 把云端记录合进本机记录。
///
/// **纯函数**，不碰网络和文件，所以「同一趟被记了两遍」「补记和官方记录重叠」这些最容易
/// 出错的情形都能在测试里摆出来跑。
///
/// 三条规则，按顺序：
///
/// 1. **同一趟认出来**：本机记录和云端记录时间上重叠≥较短那段的一半，且距离对得上，
///    就认为是同一趟。本机留着（它的时间是我们一帧帧看着车得到的，比云端那对整分时间戳细），
///    但距离、耗电、最高速、油耗换成官方的——车主拿去跟零跑 App 对账，对的就是这个数。
/// 2. **认不出来的云端记录直接补进来**：这就是 App 没在跑的那些路。它们没有坐标，
///    所以起终点地名空着，界面按「官方记录」显示。
/// 3. **补记被覆盖就删掉**：`reconstructed` 是拿里程表差估算的粗记录，一段可能盖住好几趟。
///    当它的时间有八成以上落在官方记录里，就该由官方那几条取代它，否则同一条路算两次账。
enum CloudTripMerge {

    struct Result: Equatable {
        var trips: [TripRecord]
        var added: Int
        var matched: Int
        var dropped: Int
    }

    /// 一段本机记录和一段云端记录「是同一趟」的判据：重叠达到较短那段的多少。
    static let overlapFraction = 0.5
    /// 距离对不上的，就不是同一趟——两条不同的路可能时间重叠，里程差得远。
    static let distanceFloorKm = 1.0
    static let distanceRatio = 0.5
    /// 补记被官方记录覆盖到这个比例，就可以删了。
    static let coveredFraction = 0.8

    static func merge(
        local: [TripRecord],
        cloud: [CloudTripRecord],
        window: ClosedRange<Date>,
        limit: Int = TripLogStore.limit,
        hiddenKeys: Set<String> = []
    ) -> Result {
        var trips = local
        var added = 0
        var matched = 0

        // 云端那一批里已经没有的官方行，从这次拉取的窗口里清掉：
        // 换了账号、换了车、或者云端删了记录，本机不该继续留着。
        let keys = Set(cloud.map(\.key))
        trips.removeAll { trip in
            guard trip.source == .official, window.contains(trip.startAt) else { return false }
            guard let key = trip.officialKey else { return true }
            return !keys.contains(key)
        }

        for record in cloud.sorted(by: { $0.startAt < $1.startAt }) {
            // 用户长按删掉的那一条：云端再出现也不合并回来。
            if hiddenKeys.contains(record.key) { continue }
            if let index = trips.firstIndex(where: { $0.officialKey == record.key }) {
                apply(record, to: &trips[index])
                continue
            }
            switch bestMatch(in: trips, for: record) {
            case .one(let index):
                apply(record, to: &trips[index])
                matched += 1
            case .none:
                trips.append(TripRecord(cloud: record))
                added += 1
            case .ambiguous:
                // 两段本机记录都像是一趟——不猜。宁可这条官方数据不落地，
                // 也不能把它贴到错误的那一趟上，更不能新造一条出来重复记账。
                break
            }
        }

        let dropped = dropCoveredReconstructions(&trips, cloud: cloud)
        trips.sort { $0.startAt > $1.startAt }
        if trips.count > limit { trips = Array(trips.prefix(limit)) }
        return Result(trips: trips, added: added, matched: matched, dropped: dropped)
    }

    private enum Match {
        case one(Int)
        case none
        case ambiguous
    }

    private static func bestMatch(in trips: [TripRecord], for record: CloudTripRecord) -> Match {
        var best: (index: Int, overlap: TimeInterval)?
        var tied = false
        // 只和**本机真实记录**对齐。补记是按里程表差估算的一段，可能盖住好几趟，
        // 拿它去贴一条官方记录等于把两趟的路算成一趟——让它走「覆盖检查」那条路，
        // 该被取代就被取代，取代不了就老实留着当补记。
        for (index, trip) in trips.enumerated() where trip.source == .recorded {
            guard isSameDrive(trip, record) else { continue }
            let overlap = intersection(trip.startAt, trip.endAt, record.startAt, record.endAt)
            if let current = best {
                if overlap > current.overlap + 60 {
                    best = (index, overlap)
                    tied = false
                } else if abs(overlap - current.overlap) <= 60 {
                    tied = true
                }
            } else {
                best = (index, overlap)
            }
        }
        guard let best else { return .none }
        return tied ? .ambiguous : .one(best.index)
    }

    static func isSameDrive(_ trip: TripRecord, _ record: CloudTripRecord) -> Bool {
        let overlap = intersection(trip.startAt, trip.endAt, record.startAt, record.endAt)
        let shorter = min(trip.duration, record.duration)
        guard overlap > 0 else { return false }
        // 很短的一趟（挪车、进地库）用比例判会太严，给一条 60 秒的绝对线。
        guard overlap >= 60 || (shorter > 0 && overlap / shorter >= overlapFraction) else { return false }
        guard record.distanceKm >= distanceFloorKm, trip.distanceKm >= distanceFloorKm else {
            return true
        }
        let ratio = trip.distanceKm / record.distanceKm
        return ratio >= distanceRatio && ratio <= 1 / distanceRatio
    }

    /// 官方数据贴到本机记录上。距离用官方的（对得上账），时间仍用本机的。
    private static func apply(_ record: CloudTripRecord, to trip: inout TripRecord) {
        trip.officialKey = record.key
        trip.energyKWh = record.energyKWh
        trip.maxSpeedKmh = record.maxSpeedKmh
        trip.fuelLitres = record.fuelLitres
        if record.distanceKm > 0 { trip.distanceKm = record.distanceKm }
    }

    /// 删掉已经被官方记录覆盖的补记，返回删了几条。
    private static func dropCoveredReconstructions(
        _ trips: inout [TripRecord], cloud: [CloudTripRecord]
    ) -> Int {
        guard !cloud.isEmpty else { return 0 }
        var dropped = 0
        trips.removeAll { trip in
            guard trip.source == .reconstructed, trip.duration > 60 else { return false }
            let covered = cloud.reduce(0.0) { sum, record in
                sum + intersection(trip.startAt, trip.endAt, record.startAt, record.endAt)
            }
            guard covered / trip.duration >= coveredFraction else { return false }
            dropped += 1
            return true
        }
        return dropped
    }

    static func intersection(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> TimeInterval {
        max(0, min(aEnd, bEnd).timeIntervalSince(max(aStart, bStart)))
    }
}

extension TripRecord {
    /// 从云端记录造一条。没有坐标、没有电量——那些只有本机看得见。
    init(cloud record: CloudTripRecord) {
        self.init(
            vin: record.vin,
            startAt: record.startAt,
            endAt: record.endAt,
            distanceKm: record.distanceKm
        )
        officialKey = record.key
        source = .official
        energyKWh = record.energyKWh
        maxSpeedKmh = record.maxSpeedKmh
        fuelLitres = record.fuelLitres
    }
}
