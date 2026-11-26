import CoreLocation
import Foundation

/// 一条记录的来源。三种，界面上的标签和可信度都由它决定。
enum TripSource: String, Codable, Hashable, Sendable {
    /// 本机轮询看着车况切出来的。时间准，距离可能差一点。
    case recorded
    /// 补记：App 没在跑的那段路，用前后两次看到的里程表差估算的。时间和距离都粗。
    case reconstructed
    /// 零跑云端的逐趟记录（`CloudTripRecord`）。App 开没开都有，官方 App 显示的就是这些数。
    case official
}

/// 一次行程：从「车动了」到「车停下」，中间的红灯、等人都不切段。
///
/// 数据有**两个来源**，合并成一份列表：
///
/// 1. 本机轮询切出来的（`TripTracker`，`source == .recorded`）。它看得见坐标、起终点地名、
///    电量变化，但只在 App 活着的时候存在。
/// 2. 零跑云端自己的逐趟明细（`CloudTripRecord`，`source == .official`）。它覆盖 App 没开
///    的那段时间，距离和耗电是官方的口径，只是没有经纬度。
///
/// 两者重叠的那一趟由 `CloudTripMerge` 认出来并合成一条：时间用本机的，数字用官方的。
/// 剩下的补记（`source == .reconstructed`）只在官方也没有那段数据时才留着。
///
/// 因此界面不能再写「记录在本机、App 没开就记不到」——那句话在接上云端之后是错的。
struct TripRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// 哪台车。多车账号切车之后，列表不能把两台车的行程混在一起算汇总。
    var vin: String?
    var startAt: Date
    var endAt: Date
    /// 公里。本机记录取「里程表差」与「轨迹累加」里大的那个（见 `TripTracker.finish`）；
    /// 认出来的官方记录用云端的数。
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
    var source: TripSource
    /// 云端那条记录的主键。有了它，重复同步就是幂等的。
    var officialKey: String?
    /// 官方口径的这一趟用了多少度电。
    var energyKWh: Double?
    /// 官方口径的最高车速（本机拿不到车速信号）。
    var maxSpeedKmh: Int?
    /// 增程车这一趟烧的油（升）。
    var fuelLitres: Double?

    /// 补记。老代码和界面都用这个名字，别改成 `source == .reconstructed` 到处散开。
    var isReconstructed: Bool { source == .reconstructed }

    /// 这一趟有没有官方数据。界面据此打「官方」标、显示度数。
    var hasOfficialData: Bool { officialKey != nil }

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
        isReconstructed: Bool = false,
        source: TripSource? = nil
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
        self.source = source ?? (isReconstructed ? .reconstructed : .recorded)
    }

    // MARK: - 落盘兼容
    //
    // 1.8 之前写下的 `trip-log.json` 里没有 `source` / `officialKey` / 度数这些键。
    // 用合成的 Codable 会因为缺键整份解不出来——那等于用户升级一次就丢光历史记录。
    // 所以解码全部走 `decodeIfPresent`，缺什么补什么：
    // 缺 `source` 就看老字段 `isReconstructed`。

    private enum CodingKeys: String, CodingKey {
        case id, vin, startAt, endAt, distanceKm, startSoc, endSoc
        case startLatitude, startLongitude, endLatitude, endLongitude
        case startPlace, endPlace, source, officialKey
        case energyKWh, maxSpeedKmh, fuelLitres
        case isReconstructed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        vin = try container.decodeIfPresent(String.self, forKey: .vin)
        startAt = try container.decode(Date.self, forKey: .startAt)
        endAt = try container.decode(Date.self, forKey: .endAt)
        distanceKm = try container.decodeIfPresent(Double.self, forKey: .distanceKm) ?? 0
        startSoc = try container.decodeIfPresent(Int.self, forKey: .startSoc)
        endSoc = try container.decodeIfPresent(Int.self, forKey: .endSoc)
        startLatitude = try container.decodeIfPresent(Double.self, forKey: .startLatitude)
        startLongitude = try container.decodeIfPresent(Double.self, forKey: .startLongitude)
        endLatitude = try container.decodeIfPresent(Double.self, forKey: .endLatitude)
        endLongitude = try container.decodeIfPresent(Double.self, forKey: .endLongitude)
        startPlace = try container.decodeIfPresent(String.self, forKey: .startPlace)
        endPlace = try container.decodeIfPresent(String.self, forKey: .endPlace)
        if let stored = try container.decodeIfPresent(TripSource.self, forKey: .source) {
            source = stored
        } else {
            let legacy = try container.decodeIfPresent(Bool.self, forKey: .isReconstructed) ?? false
            source = legacy ? .reconstructed : .recorded
        }
        officialKey = try container.decodeIfPresent(String.self, forKey: .officialKey)
        energyKWh = try container.decodeIfPresent(Double.self, forKey: .energyKWh)
        maxSpeedKmh = try container.decodeIfPresent(Int.self, forKey: .maxSpeedKmh)
        fuelLitres = try container.decodeIfPresent(Double.self, forKey: .fuelLitres)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(vin, forKey: .vin)
        try container.encode(startAt, forKey: .startAt)
        try container.encode(endAt, forKey: .endAt)
        try container.encode(distanceKm, forKey: .distanceKm)
        try container.encodeIfPresent(startSoc, forKey: .startSoc)
        try container.encodeIfPresent(endSoc, forKey: .endSoc)
        try container.encodeIfPresent(startLatitude, forKey: .startLatitude)
        try container.encodeIfPresent(startLongitude, forKey: .startLongitude)
        try container.encodeIfPresent(endLatitude, forKey: .endLatitude)
        try container.encodeIfPresent(endLongitude, forKey: .endLongitude)
        try container.encodeIfPresent(startPlace, forKey: .startPlace)
        try container.encodeIfPresent(endPlace, forKey: .endPlace)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(officialKey, forKey: .officialKey)
        try container.encodeIfPresent(energyKWh, forKey: .energyKWh)
        try container.encodeIfPresent(maxSpeedKmh, forKey: .maxSpeedKmh)
        try container.encodeIfPresent(fuelLitres, forKey: .fuelLitres)
        // 老字段照写：万一有人回滚到 1.8，那份代码还看得懂「这是补记」。
        try container.encode(isReconstructed, forKey: .isReconstructed)
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

    /// 被用户删掉的记录。
    ///
    /// 只删列表里那一条是不够的：云端那批记录每次同步都会重新合并回来，
    /// 用户删掉的官方行程下一次刷新就会「复活」。所以删除要记进这份清单，
    /// 合并时把对应的 `officialKey` 直接跳过。键里同时存本机的 `id`，
    /// 这样删一条纯本机记录也能记住。
    private static var deletedURL: URL? {
        directory?.appendingPathComponent("trip-deleted.json")
    }

    static func loadDeleted() -> Set<String> {
        guard let deletedURL, let data = try? Data(contentsOf: deletedURL) else { return [] }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    static func saveDeleted(_ keys: Set<String>) {
        guard let deletedURL, let data = try? JSONEncoder().encode(Array(keys)) else { return }
        try? data.write(to: deletedURL, options: .atomic)
    }

    static func save(_ trips: [TripRecord]) {
        guard let fileURL else { return }
        let trimmed = Array(trips.sorted { $0.startAt > $1.startAt }.prefix(limit))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 把一串车况采样切成一段段行程。**纯逻辑，不碰网络、不碰文件、不碰 UI**，
/// 所以能在测试里把「等红灯」「在路边等人」「App 被杀」「里程表跳变」这些情形一条条摆出来跑。
///
/// 判定口径来自 `pipipiper/leapmotor-mate-cn` 的 poller 状态机（一个跑了很久、被上百条
/// 实车测试钉住的开源项目），按手机端拿得到的信号改过：
///
/// - **开始**：挡位报 D/R（`VehicleState.isDriving`）就算开始。读不到挡位的车型用位移兜底：
///   相邻两帧相距 80 米以上、且间隔不超过 3 分钟。插着充电枪时不开始——那是在充电，不是出发。
/// - **结束**要过三道关，缺一不可：
///   1. **停够时间**：连续停着（不动、里程表也不动）满 60 秒。
///   2. **车要么熄火、要么一直没熄**：如果车还报「上电/READY」（信号 1258），说明人是
///      停在路边等人、取快递、接孩子——这一趟还没结束，只是中间停了一下。这时候收尾会把
///      一次出门拆成两趟，而云端是按「上电到断电」算一趟的，拆开之后两边都对不上账。
///      只有在 READY 一直亮着超过 4 小时（谁也不至于在车上等这么久）才强制收尾。
///   3. **没在充电**：枪一插进来就收尾，一次充电不该算在行驶时间里。
/// - **收入时刻**取「最后一次看到车在动」的那一帧，不是收尾的那一帧：中间停在路边等的那
///   十分钟不该算成行驶时间。
/// - **太短的不算**：不足 0.2 公里且里程表没跳字的，直接丢——挪个车位、洗车挪两米都会触发
///   一次「开始→结束」（mate 的阈值也是 200 米）。
/// - **断档**：两帧间隔超过 10 分钟，说明 App 中途被挂起或杀掉。这时不能把中间那段时间算进
///   进行中的行程（会把停车等待算成行驶），要先把行程结束在**上一帧的时刻**，再用里程表差
///   补一条 `isReconstructed`。不过现在有云端那 30 天的逐趟明细兜底（`CloudTripMerge`），
///   这段补记只在云端也没有对应记录时才留在列表里。
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
        /// 车是不是还上着电（信号 1258「READY」）。读不到就是 nil，退回纯时间判定。
        var poweredOn: Bool? = nil
        /// 充电枪插上了没有。插枪意味着这一趟结束了。
        var cableIn: Bool? = nil
    }

    /// 停稳多久算这一趟结束。**按秒不按帧**：前台 10 秒一帧是 6 帧，后台 60 秒一帧就是 1 帧，
    /// 两种节奏给出同一个判定。按帧数算的话，后台一开，收尾要拖到三分钟。
    static let parkedSecondsToClose: TimeInterval = 60
    /// 车还上着电时，最多容忍它停多久。超过就按停车那一刻收尾。
    ///
    /// mate-cn 用的是半天，因为它的服务端 24 小时常驻，不会漏掉「READY 由 1 变 0」那一帧。
    /// 我们不一样：手机可能整夜在后台按 60 秒一帧看着车，而某几个车型的 1258 偶尔会一直
    /// 报 1——真让它等 12 小时，昨晚回家和今早出门就会被粘成同一趟。4 小时足够覆盖任何
    /// 真人「在车上等人」的场景，又不至于把两天连起来。
    static let parkedLimitWhilePoweredOn: TimeInterval = 4 * 3600
    /// 这么短的路不算一趟。
    static let minimumDistanceKm = 0.2
    /// 两帧间隔超过这个数，就当中间断过。
    static let gapForReconstruction: TimeInterval = 10 * 60
    /// 位移兜底的阈值：80 米（10 秒一帧的话约 29 km/h，走路挪车不会误触发）。
    static let movedMeters: CLLocationDistance = 80

    private(set) var active: TripRecord?
    /// 上一次采样。开始行程时用它把开始时间往前挪到「车还没动」的那一刻。
    private(set) var last: Sample?

    /// 从哪一刻开始停着的。一直停着就是第一次停下的时刻，一动就清空。
    private var parkedSince: Date?
    /// 最后一次看到车在动的时刻。收尾时用它的时间。
    private var lastMovingAt: Date?
    /// 就这一趟而言，枪是什么时候插进来的。
    private var cableInAt: Date?
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
                if let endedAt = closeTime(sample) {
                    if let finished = finish(&trip, at: endedAt) { completed.append(finished) }
                    reset()
                } else {
                    active = trip
                }
            }
        }

        // 这一帧还有余力的时候：车还在开就接着记，否则补一条断档。
        if active == nil {
            // 插着枪不动就开始记，会记出一条「在充电桩上开了 0 公里」的行程。
            if isMoving(sample), sample.cableIn != true {
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

    /// 这一帧该不该收尾。返回「收尾时刻」，nil 表示还没结束。
    ///
    /// 三道关的顺序是有讲究的：先看枪（插枪就是结束，一秒都不用等），再看停够没停够，
    /// 最后才看车还上不上电——因为「还上着电」只在停够时间之后才有意义。
    ///
    /// 里程表必须一起看：有的车型挡位信号在锁车后就断了，读不到被当成「没在开车」；
    /// 只凭挡位会在等一个长红灯时把行程切段。
    private func closeTime(_ sample: Sample) -> Date? {
        if cableInAt != nil { return sample.at }
        guard let parkedSince else { return nil }
        let parked = sample.at.timeIntervalSince(parkedSince)
        guard parked >= Self.parkedSecondsToClose else { return nil }
        if sample.poweredOn == true, parked < Self.parkedLimitWhilePoweredOn {
            // 人还在车上等着。这一趟没结束。
            return nil
        }
        // 收入时刻取最后一次在动的时刻：停在路边等的那段时间不算行驶。
        return lastMovingAt ?? sample.at
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
        parkedSince = nil
        lastMovingAt = sample.at
        cableInAt = sample.cableIn == true ? sample.at : nil
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
        let odometerMoved = (sample.odometerKm ?? currentOdometer) != currentOdometer
        if let odometer = sample.odometerKm { currentOdometer = odometer }

        // 「停着」= 既没在动、里程表也没跳。只看挡位的话，锁车后挡位信号断掉的车型
        // 会被当成一直停着；只看位移的话，GPS 漂移又会把停着的车算成在开。
        if isMoving(sample) || odometerMoved {
            parkedSince = nil
            lastMovingAt = sample.at
        } else if parkedSince == nil {
            // 从**上一帧**算起：我们看到的第一个「停着」其实更早就停了，按这一帧算会少等几秒。
            parkedSince = last?.at ?? sample.at
        }

        if sample.cableIn == true, cableInAt == nil {
            cableInAt = sample.at
            if lastMovingAt == nil { lastMovingAt = sample.at }
        }
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
        parkedSince = nil
        lastMovingAt = nil
        cableInAt = nil
        trackKm = 0
        startOdometer = nil
        currentOdometer = nil
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
