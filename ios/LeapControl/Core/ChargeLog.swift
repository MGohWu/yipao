import CoreLocation
import Foundation

/// 一次充电：从「电流真的流进电池」到「车说这次充完了 / 拔枪」。
///
/// 数据有两个来源，和行程记录同一套做法：
///
/// 1. 零跑云端的充电明细（`CloudChargeRecord`，`officialKey != nil`）。App 开没开都有，
///    覆盖近 30 天，度数用车的结算值，还带充电地点坐标。
/// 2. 本机轮询自己积分出来的（`ChargeTracker`）。它多出起止电量、峰值功率这两项，
///    云端不给；补记（`isReconstructed`）也是这一支的粗版本。
///
/// 一次充电的物理条件比行车简单——车是静止的，SoC 只往上走——所以补记在充电这边
/// 本来就比行程那边可信；接上云端之后，它只在云端也没有那次记录时才留着。
struct ChargeRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// 哪台车。多车账号切车之后，列表不能把两台车混在一起算电费。
    var vin: String?
    var startAt: Date
    var endAt: Date
    var startSoc: Int?
    var endSoc: Int?
    /// 充进电池的电量（kWh）。按「电压 × 电流」随时间积分算出来的，不是车给的；
    /// 读不到电压电流的车型（S01/T03 那套语义信号里没有），退到 SoC 差 × 学习值。
    var energyKwh: Double?
    /// 这一趟见到的最大充电功率（kW）。判断快慢充、评价充电桩好坏就靠它。
    var maxPowerKw: Double?
    /// 直流快充。真值来自「快充枪已连接」（`1197`）；读不到就按峰值功率反推。
    /// **补记的记录这一项没有意义**——那时我们根本没看到车，界面不显示它。
    var isDC: Bool
    var latitude: Double?
    var longitude: Double?
    /// 地名。进列表时异步补，补到就回写文件。
    var place: String?
    /// 补记：App 没在跑的那段，用前后两次看到的电量差补出来的一条。
    var isReconstructed: Bool
    /// 云端那条记录的主键。有了它，重复同步就是幂等的；`!= nil` 也等于「这次充电有官方数据」。
    var officialKey: String?

    /// 这一段有没有官方结算数据。
    var isOfficial: Bool { officialKey != nil }

    init(
        id: UUID = UUID(),
        vin: String? = nil,
        startAt: Date,
        endAt: Date,
        startSoc: Int? = nil,
        endSoc: Int? = nil,
        energyKwh: Double? = nil,
        maxPowerKw: Double? = nil,
        isDC: Bool = false,
        coordinate: CLLocationCoordinate2D? = nil,
        place: String? = nil,
        isReconstructed: Bool = false,
        officialKey: String? = nil
    ) {
        self.id = id
        self.vin = vin
        self.startAt = startAt
        self.endAt = endAt
        self.startSoc = startSoc
        self.endSoc = endSoc
        self.energyKwh = energyKwh
        self.maxPowerKw = maxPowerKw
        self.isDC = isDC
        self.latitude = coordinate?.latitude
        self.longitude = coordinate?.longitude
        self.place = place
        self.isReconstructed = isReconstructed
        self.officialKey = officialKey
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var duration: TimeInterval { max(0, endAt.timeIntervalSince(startAt)) }

    /// 涨了几个百分点。SoC 掉下去说明这一趟其实不是充电（或者读到了残值），不给。
    var socGain: Int? {
        guard let startSoc, let endSoc, endSoc > startSoc else { return nil }
        return endSoc - startSoc
    }

    /// 平均功率只在这种「全程都在充」的记录上给：补记的时长里混着没充电的时间，
    /// 拿它算平均会把 7 kW 的桩说成 2 kW。
    var averagePowerKw: Double? {
        guard !isReconstructed, let energyKwh, duration >= 300 else { return nil }
        return energyKwh / (duration / 3600)
    }

    var dayStart: Date {
        Calendar.current.startOfDay(for: startAt)
    }
}

/// 充电记录的文件格式。
///
/// 除了记录本身，还存一个**学习值** `kwhPerPercent`：每 1% 电量大约等于多少度电。
/// 补记只能看到电量差，没有这个换算就永远给不出「充了多少度」。这个值不是标称容量，
/// 是从真实会话（有积分能量又有电量差）里反推出来的，含充电损耗，正好就是补记要的口径。
struct ChargeLogFile: Codable {
    var records: [ChargeRecord] = []
    var kwhPerPercent: Double?
}

/// 充电记录的落盘位置。和行程记录同目录（App Group 容器），理由见 `TripLogStore`。
enum ChargeLogStore {
    /// 保留多少条。一年充五十次的话，三百条够看六年；充电比行车稀疏得多。
    static let limit = 300

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
        directory?.appendingPathComponent("charge-log.json")
    }

    static func load() -> ChargeLogFile {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return ChargeLogFile() }
        return (try? JSONDecoder().decode(ChargeLogFile.self, from: data)) ?? ChargeLogFile()
    }

    static func save(_ file: ChargeLogFile) {
        guard let fileURL else { return }
        var trimmed = file
        trimmed.records = Array(file.records.sorted { $0.startAt > $1.startAt }.prefix(limit))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 把一串车况采样切成一段段充电。**纯逻辑，不碰网络、不碰文件、不碰 UI**。
///
/// 判定口径借鉴 `ProtossBlaster/leapmotor-mate` 的 poller 状态机（它是目前唯一成熟的
/// 零跑数据采集实现），再按手机端「10 秒一帧、随时可能被挂起」的条件改过：
///
/// - **开始**：只有**真的在充**才开会话——`chargeState == 1`，或者读不到这个信号时
///   功率 ≥ 0.5 kW。**插枪不算**：预约充电时枪是插着的，车在等自己定的时间，
///   这时候开会话会记出一条 0 度的充电，等真正开始充时又要另开一条。
///   （mate 那边为此专门加了 `charge_deferred` 判据，踩过同一个坑。）
/// - **维持**：在充，或者插着枪但车没在「本次已结束 / 预约等待」状态。墙盒限功率、
///   负载均衡会让电流中断几十秒，车会连枪都报成没插——靠插枪这一项撑住，不然一次
///   充电会被切成五六段（mate 的实测：一次插枪记成六次）。
/// - **结束**：连续 3 帧（30 秒）既不充、也没有插枪；或者车明确报「本次充电已结束」
///   （`chargeState == 2`）满 3 帧；或者单次超过 24 小时（信号卡死，不是真在充）。
/// - **太短的丢弃**：不足 0.5 度电且电量没涨 1% 的，是插枪握手、开关桩，不算一次充电。
/// - **断档**：两帧间隔超过 10 分钟说明 App 被挂起或杀掉。会话结束在**上一帧**的时刻
///   （不把挂起的时间算成充电），再用前后 SoC 差补一条 `isReconstructed`。
///   补记的电量靠 `kwhPerPercent` 换算，没有这个学习值时就不给数，只显示电量变化。
struct ChargeTracker {
    struct Sample {
        var at: Date
        var soc: Int?
        /// `1149`：0 未在充、1 充电中、2 本次已结束、3 故障、4 预约等待、6 暂停。
        /// 读不到传 nil（S01/T03 那套语义信号里没有这一项）。
        var chargeState: Int?
        /// 充电枪是否插上（快充 `1197` 与慢充 `47` 取或）。读不到传 nil。
        var gunConnected: Bool?
        /// 快充枪。只在插着的时候为 true。
        var isDC: Bool
        /// 充电功率（kW），`VehicleState.chargePowerKW`，电压 × 电流算出来的。
        var powerKW: Double?
        /// 车辆坐标，已经是 GCJ-02。
        var coordinate: CLLocationCoordinate2D?
    }

    /// 连续多少帧「没在充也没插枪」才收尾。10 秒一帧 → 30 秒。
    static let idleTicksToClose = 3
    /// 两帧间隔超过这个数，就当中间断过。
    static let gapForReconstruction: TimeInterval = 10 * 60
    /// 不足这么多度电、电量也没涨，就不算一次充电。
    static let minimumEnergyKwh = 0.5
    /// 单次会话最长多久。超过当信号卡死。
    static let maximumSessionDuration: TimeInterval = 24 * 3600
    /// 补记至少要有这么多百分点的涨幅：SoC 自己有 1% 的读数抖动。
    static let reconstructedMinimumSocGain = 2
    /// 能量积分的时间步长上限。正常 10 秒一帧，网络慢到半分钟也不会把功率乘出
    /// 一段凭空多出来的电；更长的断档走补记，不走积分。
    static let maxIntegrationStep: TimeInterval = 60
    /// 峰值功率超过这个数就算直流快充（读不到快充枪信号时的反推）。
    static let dcPowerThresholdKW: Double = 20

    private(set) var active: ChargeRecord?
    private(set) var last: Sample?

    private var idleTicks = 0
    private var energyKwh: Double = 0
    private var maxPowerKw: Double = 0
    /// 有没有真的拿到过功率。没拿到过就别宣称自己积分出了能量。
    private var sawPower = false

    /// 喂一帧。返回这一帧里**刚结束**的充电，可能 0 条，断档那一帧可能是 2 条
    /// （旧会话收在断档前，紧接着补一条断档期间的补记——两者首尾相接，不重复记账）。
    mutating func ingest(
        _ sample: Sample,
        vin: String?,
        kwhPerPercent: Double?
    ) -> [ChargeRecord] {
        var completed: [ChargeRecord] = []

        if var charge = active {
            // 换车了：上一台的会话就地结束，不能把两台车的电记成一次。
            if charge.vin != vin {
                if let finished = finish(&charge, at: last?.at ?? sample.at, kwhPerPercent: kwhPerPercent) {
                    completed.append(finished)
                }
                reset()
            } else if let previous = last,
                      sample.at.timeIntervalSince(previous.at) > Self.gapForReconstruction {
                // 中间断过：这一段只能算到「上次看到车」为止，剩下的交给补记。
                if let finished = finish(&charge, at: previous.at, kwhPerPercent: kwhPerPercent) {
                    completed.append(finished)
                }
                reset()
                if let reconstructed = reconstructedCharge(
                    from: previous, to: sample, vin: vin, kwhPerPercent: kwhPerPercent
                ) {
                    completed.append(reconstructed)
                }
            } else {
                update(&charge, with: sample)
                if shouldClose(sample, charge: charge) {
                    if let finished = finish(&charge, at: sample.at, kwhPerPercent: kwhPerPercent) {
                        completed.append(finished)
                    }
                    reset()
                } else {
                    active = charge
                }
            }
        } else if let previous = last,
                  sample.at.timeIntervalSince(previous.at) > Self.gapForReconstruction,
                  let reconstructed = reconstructedCharge(
                      from: previous, to: sample, vin: vin, kwhPerPercent: kwhPerPercent
                  ) {
            completed.append(reconstructed)
        }

        // 这一帧刚结算掉一条，就先不另开——下一帧（10 秒后）再开，避免补记和
        // 新会话在同一时刻首尾相接时算重。用户看不出这 10 秒的差别。
        //
        // **开会话必须用 `isFlowing`，不能用 `isAlive`**：后者把「插着枪」也算活着，
        // 拿它开会话会把「插枪待充」「预约等待」全记成一次零度电的充电。这个区别
        // 正是 mate 当年加 `charge_deferred` 的原因。
        if active == nil, completed.isEmpty, isFlowing(sample) {
            begin(with: sample, vin: vin)
        }

        last = sample
        return completed
    }

    // MARK: - 判定

    /// 这一帧是不是**真的在充**（有电流进电池）。开会话只认这个。
    private func isFlowing(_ sample: Sample) -> Bool {
        if sample.chargeState == 1 { return true }
        // 读不到 1149 的车型只能看功率。待机时电压电流都在，但乘出来不到 0.5 kW。
        if sample.chargeState == nil, let power = sample.powerKW, power >= 0.5 { return true }
        return false
    }

    /// 这一帧算不算「这次充电还没结束」。比 `isFlowing` 宽：插着枪也算，
    /// 这样墙盒断电几十秒不会把一次充电切成好几段。
    private func isAlive(_ sample: Sample) -> Bool {
        if isFlowing(sample) { return true }
        // 2 = 本次充电已结束。车自己都说结束了，就不能再靠插枪吊着——
        // 否则「充完不拔枪」会让会话一直开着，第二天早上看到一段 14 小时的充电。
        if sample.chargeState == 2 { return false }
        // 4 = 预约等待。枪插着，车在等自己定的时间，这不是在充电。
        if sample.chargeState == 4 { return false }
        guard let gun = sample.gunConnected else { return false }
        return gun
    }

    private func shouldClose(_ sample: Sample, charge: ChargeRecord) -> Bool {
        if sample.at.timeIntervalSince(charge.startAt) > Self.maximumSessionDuration { return true }
        guard !isAlive(sample) else { return false }
        return idleTicks >= Self.idleTicksToClose
    }

    // MARK: - 生命周期

    private mutating func begin(with sample: Sample, vin: String?) {
        // 开始时间往前挪到上一次采样：那时候还没在充，比「第一次看到电流」更接近真实插枪时刻。
        // 只往前挪 3 分钟以内，否则会把半小时前的停车时刻当成开始。
        let origin: Sample = {
            guard let previous = last,
                  sample.at.timeIntervalSince(previous.at) <= 180 else { return sample }
            return previous
        }()
        active = ChargeRecord(
            vin: vin,
            startAt: origin.at,
            endAt: sample.at,
            startSoc: origin.soc,
            endSoc: sample.soc,
            isDC: sample.isDC,
            coordinate: origin.coordinate ?? sample.coordinate
        )
        energyKwh = 0
        maxPowerKw = 0
        sawPower = false
        idleTicks = 0
    }

    private mutating func update(_ charge: inout ChargeRecord, with sample: Sample) {
        if let previous = last {
            let step = min(max(0, sample.at.timeIntervalSince(previous.at)), Self.maxIntegrationStep)
            // 只在「这一帧确实在充」时积分。否则插着枪待机的那几个小时会按上一帧的
            // 功率一直乘下去，凭空多出几十度电。
            if isFlowing(sample), let power = sample.powerKW {
                energyKwh += power * step / 3600
                sawPower = true
            }
        }
        if let power = sample.powerKW, power > maxPowerKw { maxPowerKw = power }
        if sample.isDC { charge.isDC = true }
        charge.endAt = sample.at
        if let soc = sample.soc { charge.endSoc = soc }
        if let coordinate = sample.coordinate {
            charge.latitude = coordinate.latitude
            charge.longitude = coordinate.longitude
        }
        idleTicks = isAlive(sample) ? 0 : idleTicks + 1
    }

    private mutating func finish(
        _ charge: inout ChargeRecord,
        at date: Date,
        kwhPerPercent: Double?
    ) -> ChargeRecord? {
        charge.endAt = max(charge.startAt, date)

        var energy: Double? = sawPower ? energyKwh : nil
        // 积分拿不到（车型不报电压电流）或者只积到一点点时，用 SoC 差换算。
        // 这条退路也是补记用的那条，口径一致。
        if (energy ?? 0) < 0.2,
           let kwhPerPercent,
           let gain = charge.socGain, gain > 0 {
            energy = Double(gain) * kwhPerPercent
        }
        if let energy {
            // 一次充电超过 200 度不可能（乘用车包最大也就 140 度上下），
            // 出现这个数只能是电压电流读错或者时间跨度异常，宁可不给。
            charge.energyKwh = energy > 200 ? nil : (energy * 100).rounded() / 100
        }
        charge.maxPowerKw = maxPowerKw > 0 ? (maxPowerKw * 10).rounded() / 10 : nil
        if (charge.maxPowerKw ?? 0) >= Self.dcPowerThresholdKW { charge.isDC = true }

        // 太短的丢掉：插一下枪又拔掉、开关一次充电桩的握手，不该占一条记录。
        let gain = charge.socGain ?? 0
        guard (charge.energyKwh ?? 0) >= Self.minimumEnergyKwh || gain >= 1 else { return nil }
        return charge
    }

    private func reconstructedCharge(
        from previous: Sample,
        to sample: Sample,
        vin: String?,
        kwhPerPercent: Double?
    ) -> ChargeRecord? {
        guard let before = previous.soc, let after = sample.soc else { return nil }
        let gain = after - before
        // 只认「明显涨了」的。SoC 有 1% 的读数抖动，涨 1% 说明不了什么。
        guard gain >= Self.reconstructedMinimumSocGain else { return nil }
        return ChargeRecord(
            vin: vin,
            startAt: previous.at,
            endAt: sample.at,
            startSoc: before,
            endSoc: after,
            energyKwh: kwhPerPercent.map { (Double(gain) * $0 * 100).rounded() / 100 },
            maxPowerKw: nil,
            isDC: false,
            coordinate: sample.coordinate,
            isReconstructed: true
        )
    }

    private mutating func reset() {
        active = nil
        idleTicks = 0
        energyKwh = 0
        maxPowerKw = 0
        sawPower = false
    }
}
