import CoreLocation
import Foundation

/// 一次行程：从「车动了」到「车停下」，中间的红灯、等人都不切段。
///
/// **数据是我们自己看着车况攒出来的**，不是零跑云端给的。官方的「行程能耗」只到「天」
/// （累计里程、周能耗、近 7 日按天统计），没有逐趟明细；云端 `drivingrecord` 命名空间里
/// 那几个接口（`mileage/energy/detail`、`getLastweekEC`…）也都是按天/按周聚合的。
/// 所以逐趟记录只能靠 App 在运行时按 10 秒一次的轮询自己切段（见 `TripTracker`）。
///
/// 由此带来一个必须写在界面上的限制：**App 没运行时看不到车**，那段路只能靠前后两次
/// 里程表的差补一条 `isReconstructed` 的记录，时间和路线都不精确。宁可标出来，也不假装
/// 它是精确的——车主一对账就会发现对不上，那时候再解释就晚了。
struct TripRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// 哪台车。多车账号切车之后，列表不能把两台车的行程混在一起算汇总。
    var vin: String?
    var startAt: Date
    var endAt: Date
    /// 公里。取「里程表差」与「轨迹累加」里大的那个，理由见 `TripTracker.finish`。
    var distanceKm: Double
    var startSoc: Int?
    var endSoc: Int?
    var startLatitude: Double?
    var startLongitude: Double?
    var endLatitude: Double?
    var endLongitude: Double?
    /// 起终点地名。进列表时异步补，补到就回写文件，补不到就一直留空。
    var startPlace: String?
    var endPlace: String?
    /// 补记：App 没在跑的那段路，用前后两次看到的里程表差补出来的一条。
    var isReconstructed: Bool

    init(
        id: UUID = UUID(),
        vin: String? = nil,
        startAt: Date,
        endAt: Date,
        distanceKm: Double,
        startSoc: Int? = nil,
        endSoc: Int? = nil,
        start: CLLocationCoordinate2D? = nil,
        end: CLLocationCoordinate2D? = nil,
        startPlace: String? = nil,
        endPlace: String? = nil,
        isReconstructed: Bool = false
    ) {
        self.id = id
        self.vin = vin
        self.startAt = startAt
        self.endAt = endAt
        self.distanceKm = distanceKm
        self.startSoc = startSoc
        self.endSoc = endSoc
        self.startLatitude = start?.latitude
        self.startLongitude = start?.longitude
        self.endLatitude = end?.latitude
        self.endLongitude = end?.longitude
        self.startPlace = startPlace
        self.endPlace = endPlace
        self.isReconstructed = isReconstructed
    }

    var startCoordinate: CLLocationCoordinate2D? {
        guard let startLatitude, let startLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: startLatitude, longitude: startLongitude)
    }

    var endCoordinate: CLLocationCoordinate2D? {
        guard let endLatitude, let endLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude)
    }

    var duration: TimeInterval { max(0, endAt.timeIntervalSince(startAt)) }

    /// 平均时速（含停车等待），只在这个时间跨度足够长时给——一两分钟的行程算出来的是噪声。
    var averageSpeedKmh: Double? {
        guard duration >= 120, distanceKm > 0 else { return nil }
        return distanceKm / (duration / 3600)
    }

    /// 这一段用了几个百分点的电。充电会让差值为负，那不是「这段路发电了」，直接不给。
    var socDrop: Int? {
        guard let startSoc, let endSoc, startSoc >= endSoc else { return nil }
        return startSoc - endSoc
    }

    /// 百公里电耗（kWh/100km）。电池容量我们没有，只能拿「每 1% 电跑了几公里」反推，
    /// 所以**只在同一台车、同一段电量区间内可比**，不给绝对值就是用不了。
    /// 界面因此不显示这一项——留个公式在这里，是为了说明为什么没有它。
    static func socToDistanceRatio(_ trip: TripRecord) -> Double? {
        guard let drop = trip.socDrop, drop > 0, trip.distanceKm > 0 else { return nil }
        return trip.distanceKm / Double(drop)
    }

    /// 归到哪一天（按本机时区）。列表按这个分组。
    var dayStart: Date {
        Calendar.current.startOfDay(for: startAt)
    }
}

/// 行程记录的落盘位置。
///
/// 放 App Group 容器里，和车况快照同一个目录：以后要在桌面卡片上显示「今天跑了多少」
/// 就不用搬家，也不用再申请一次容器。容器拿不到（比如没配 App Group 的调试构建）
/// 退回 `Application Support`，功能不能因为签名配错就整个消失。
enum TripLogStore {
    /// 保留多少条。10 秒一次采样、一天跑四五趟的话，500 条够看小半年；
    /// 再多列表也没人往下翻，文件还会越来越慢。
    static let limit = 500

    private static var directory: URL? {
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SnapshotStore.appGroup) {
            return container
        }
        return try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
    }

    private static var fileURL: URL? {
        directory?.appendingPathComponent("trip-log.json")
    }

    static func load() -> [TripRecord] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        // 解不出来就当没有：这是一份可以重新攒的记录，为它崩一次不值得。
        return (try? JSONDecoder().decode([TripRecord].self, from: data)) ?? []
    }

    static func save(_ trips: [TripRecord]) {
        guard let fileURL else { return }
        let trimmed = Array(trips.sorted { $0.startAt > $1.startAt }.prefix(limit))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 把一串车况采样切成一段段行程。**纯逻辑，不碰网络、不碰文件、不碰 UI**，
/// 所以能在测试里把「等红灯」「App 被杀」「里程表跳变」这些情形一条条摆出来跑。
///
/// 判定口径（借鉴 `ProtossBlaster/leapmotor-mate` 的 poller 状态机，按手机端的条件改过）：
///
/// - **开始**：挡位报 D/R（`VehicleState.isDriving`）就算开始。读不到挡位的车型用位移兜底：
///   相邻两帧相距 80 米以上、且间隔不超过 3 分钟。
/// - **结束**：连续 3 帧（30 秒）既不是行车、里程表也没动。用「连续」而不是「一帧」，
///   是因为锁车、上电、GPS 抖动都会让某一帧的挡位瞬间读不到，一帧就切会把一趟路切成一堆碎片。
///   mate 那边用的是 P 档连续 6 帧（约 1 分钟）+ READY 熄灭，我们只有 10 秒轮询、且不是常驻，
///   30 秒是能拿到的最稳的折中。
/// - **太短的不算**：不足 0.3 公里且里程表没跳字的，直接丢——挪个车位、洗车挪两米都会触发一次
///   「开始→结束」，全留下的话列表第一天就被这种记录淹了（mate 的阈值是 200 米，同一量级）。
/// - **断档**：两帧间隔超过 10 分钟，说明 App 中途被挂起或杀掉。这时不能把中间那段时间算进
///   进行中的行程（会把停车等待算成行驶），要先把行程结束在**上一帧的时刻**，再用里程表差
///   补一条 `isReconstructed`。补记只在没有进行中行程时做，避免和真实行程重复记账。
struct TripTracker {
    struct Sample {
        var at: Date
        /// 里程表（公里）。整数，短行程可能整段都不跳字。
        var odometerKm: Int?
        var soc: Int?
        /// 车辆坐标，已经是 GCJ-02（`VehicleState.shareableCoordinate`）。
        var coordinate: CLLocationCoordinate2D?
        /// 挡位报的是不是 D/R。读不到挡位的车型传 false，交给位移兜底。
        var gearDriving: Bool
    }

    /// 连续多少帧「停着」才结束行程。10 秒一帧 → 30 秒。
    static let parkedTicksToClose = 3
    /// 这么短的路不算一趟。见类型注释。
    static let minimumDistanceKm = 0.3
    /// 两帧间隔超过这个数，就当中间断过。
    static let gapForReconstruction: TimeInterval = 10 * 60
    /// 位移兜底的阈值：80 米（10 秒一帧的话约 29 km/h，走路挪车不会误触发）。
    static let movedMeters: CLLocationDistance = 80

    private(set) var active: TripRecord?
    /// 上一次采样。开始行程时用它把开始时间往前挪到「车还没动」的那一刻。
    private(set) var last: Sample?

    private var parkedTicks = 0
    private var trackKm: Double = 0
    private var startOdometer: Int?
    private var currentOdometer: Int?

    /// 喂一帧。返回这一帧里**刚结束**的行程，可能 0 条、1 条，断档那一帧可能是 2 条
    /// （旧行程收在断档前，紧接着补一条断档期间的补记——两者首尾相接，不重复记账）。
    mutating func ingest(_ sample: Sample, vin: String?) -> [TripRecord] {
        var completed: [TripRecord] = []

        if var trip = active {
            // 换车了：上一台的行程就地结束，不能把两台车的路拼成一条。
            if trip.vin != vin {
                if let finished = finish(&trip, at: last?.at ?? sample.at) { completed.append(finished) }
                reset()
            } else if let previous = last,
                      sample.at.timeIntervalSince(previous.at) > Self.gapForReconstruction {
                // 中间断过：这一段只能算到「上次看到车」为止，剩下的交给下面的补记。
                if let finished = finish(&trip, at: previous.at) { completed.append(finished) }
                reset()
            } else {
                update(&trip, with: sample)
                if shouldClose(sample) {
                    if let finished = finish(&trip, at: sample.at) { completed.append(finished) }
                    reset()
                } else {
                    active = trip
                }
            }
        }

        // 这一帧还有余力的时候：车还在开就接着记，否则补一条断档。
        if active == nil {
            if isMoving(sample) {
                begin(with: sample, vin: vin)
            } else if shouldReconstruct(sample), let previous = last,
                      let reconstructed = reconstructedTrip(from: previous, to: sample, vin: vin) {
                completed.append(reconstructed)
            }
        }

        last = sample
        return completed
    }

    // MARK: - 判定

    /// 这一帧算不算「车在动」。
    private func isMoving(_ sample: Sample) -> Bool {
        if sample.gearDriving { return true }
        guard let previous = last,
              let a = previous.coordinate, let b = sample.coordinate,
              sample.at.timeIntervalSince(previous.at) <= 180 else { return false }
        return Self.distance(a, b) >= Self.movedMeters
    }

    /// 连续几帧停着、里程表也不动 → 这一趟结束了。
    ///
    /// 里程表必须一起看：有的车型挡位信号在锁车后就断了，读不到被当成「没在开车」；
    /// 只凭挡位会在等一个长红灯时把行程切段。
    private func shouldClose(_ sample: Sample) -> Bool {
        guard parkedTicks >= Self.parkedTicksToClose else { return false }
        let odometerStill = (sample.odometerKm ?? currentOdometer) == currentOdometer
        if isMoving(sample) { return false }
        return odometerStill
    }

    /// 断档之后要不要补一条。
    ///
    /// 三个条件缺一不可：隔得够久（不是正常的 10 秒轮询）、里程表真的涨了、涨幅还在合理范围。
    /// 里程倒退说明换了车机或者表被重置过，不能拿它算距离——负数的行程比没有更糟。
    private func shouldReconstruct(_ sample: Sample) -> Bool {
        guard let previous = last,
              sample.at.timeIntervalSince(previous.at) >= Self.gapForReconstruction,
              let before = previous.odometerKm, let after = sample.odometerKm,
              after > before else { return false }
        let km = after - before
        return km >= 1 && km <= 1000
    }

    // MARK: - 生命周期

    private mutating func begin(with sample: Sample, vin: String?) {
        // 开始时间往前挪到上一次采样：那时候车还停着，比「第一次看到 D 档」更接近真实出发时刻。
        // 但只往前挪 3 分钟以内，否则会把半小时前停车的时刻当成出发时间。
        let origin: Sample = {
            guard let previous = last,
                  sample.at.timeIntervalSince(previous.at) <= 180 else { return sample }
            return previous
        }()
        active = TripRecord(
            vin: vin,
            startAt: origin.at,
            endAt: sample.at,
            distanceKm: 0,
            startSoc: origin.soc,
            endSoc: sample.soc,
            start: origin.coordinate,
            end: sample.coordinate
        )
        startOdometer = origin.odometerKm ?? sample.odometerKm
        currentOdometer = sample.odometerKm ?? startOdometer
        trackKm = 0
        parkedTicks = 0
    }

    private mutating func update(_ trip: inout TripRecord, with sample: Sample) {
        if let previous = last, let a = previous.coordinate, let b = sample.coordinate {
            let meters = Self.distance(a, b)
            // 只累加可信的一步：太小是 GPS 抖，太大是漏了很多帧（那一段用里程表去补）。
            if meters >= 20, meters <= 5_000 { trackKm += meters / 1000 }
        }
        trip.endAt = sample.at
        if let soc = sample.soc { trip.endSoc = soc }
        if let coordinate = sample.coordinate {
            trip.endLatitude = coordinate.latitude
            trip.endLongitude = coordinate.longitude
        }
        if let odometer = sample.odometerKm { currentOdometer = odometer }
        parkedTicks = isMoving(sample) ? 0 : parkedTicks + 1
    }

    /// 收尾：把距离算出来，太短的丢掉。
    ///
    /// 距离取「里程表差」和「轨迹累加」里**大的那个**：
    /// - 里程表是整数公里，3.6 公里的路可能只跳 3 个字，短途甚至一个字都不跳；
    /// - 轨迹靠 10 秒一帧的坐标累加，绕弯会略微偏小（走的是折线），但短途至少有个数。
    /// 两个都不完美，取大的那个在绝大多数情况下更接近车主自己心里的数。
    private mutating func finish(_ trip: inout TripRecord, at date: Date) -> TripRecord? {
        trip.endAt = max(trip.startAt, date)
        let odometerDelta: Double? = {
            guard let startOdometer, let currentOdometer, currentOdometer >= startOdometer else { return nil }
            return Double(currentOdometer - startOdometer)
        }()
        let distance = max(odometerDelta ?? 0, trackKm)
        guard distance >= Self.minimumDistanceKm || (odometerDelta ?? 0) >= 1 else { return nil }
        // 一趟超过 500 公里基本不可能（中途总得停车），多半是里程表跳变或者换了车。
        guard distance <= 500 else { return nil }
        trip.distanceKm = (distance * 10).rounded() / 10
        return trip
    }

    private func reconstructedTrip(from previous: Sample, to sample: Sample, vin: String?) -> TripRecord? {
        guard let before = previous.odometerKm, let after = sample.odometerKm, after > before else { return nil }
        let km = Double(after - before)
        return TripRecord(
            vin: vin,
            startAt: previous.at,
            endAt: sample.at,
            distanceKm: km,
            startSoc: previous.soc,
            endSoc: sample.soc,
            start: previous.coordinate,
            end: sample.coordinate,
            isReconstructed: true
        )
    }

    private mutating func reset() {
        active = nil
        parkedTicks = 0
        trackKm = 0
        startOdometer = nil
        currentOdometer = nil
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
