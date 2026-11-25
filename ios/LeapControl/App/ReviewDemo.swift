import CoreLocation
import Foundation

/// 演示账号。
///
/// TestFlight 外部测试要过 Beta App Review，审核指南 2.1 要求提供可用的测试账号。
/// 但这个 App 控的是真车——把真实零跑账号交给审核员，等于让陌生人能解锁、鸣笛、
/// 开尾门。所以提供一个固定的演示账号：用它登录后走一份写死的车况，
/// 不发任何网络请求，也不会有任何指令到达车辆。
///
/// 这不是后门：演示态下所有控车操作都只回一条提示，`VehicleStore.perform`
/// 在 `isDemo` 时直接返回，根本走不到签名和下发。
///
/// 与 `DemoData` 的分工：数据在这里（Release 也要能用），
/// `-demo` / `-screen` 那套启动参数留在 `DemoData` 里，仅 Debug 构建。
enum ReviewDemo {
    static let phone = "13800138000"
    static let code = "000000"

    private static let activeKey = "review.demo.active"

    static func matches(phone: String, code: String) -> Bool {
        phone == Self.phone && code == Self.code
    }

    /// 审核员可能会杀掉 App 重进，所以这个状态要落盘。
    static var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    static var session: LeapSession {
        var session = LeapSession.fresh()
        session.phone = phone
        session.oldAuth = OldAuth(
            accountId: "demo",
            token: String(repeating: "d", count: 96),
            refreshToken: "demo-refresh",
            nickname: "演示",
            tokenExpired: "21600",
            tokenObtainedAt: Date().timeIntervalSince1970 * 1000,
            tokenExpiresAt: (Date().timeIntervalSince1970 + 21600) * 1000
        )
        session.newAuth = NewAuth(
            accountId: "demo",
            gatewayAccountId: "demo",
            accessToken: "demo.access.token",
            refreshToken: "demo-refresh",
            accessTokenExpiresAt: (Date().timeIntervalSince1970 + 6 * 3600) * 1000,
            nickname: "演示",
            signKeyBase64: Data(repeating: 7, count: 32).base64EncodedString()
        )
        // 演示车按 C11 纯电立人设：控制栏八个按钮（含哨兵/遮阳帘/天窗/前备箱）审核员
        // 才全都点得到。能力码就是 vehicle/list 会下发的那份 permission 清单——
        // 400 哨兵、240 遮阳帘、300 天窗、131 前备箱，支持位用正式判据算出来，不手填。
        let permission = ["400", "240", "300", "131"]
        let vehicle = Vehicle(
            vin: "LP0DEMO0000012086",
            carType: "C11",
            name: "C11",
            permission: permission,
            isSentinelSupported: Vehicle.supportsSentinel(carType: "C11", permission: permission)
        )
        session.vehicles = [vehicle]
        session.selectedVin = vehicle.vin
        session.selectedCarType = vehicle.carType
        // 指向一个不存在的域名：万一哪条路径漏了 isDemo 判断，请求也发不出去。
        session.route = VehicleRoute(appRegion: "https://demo.invalid", appCenter: "https://demo.invalid")
        return session
    }

    /// 车况写的是**数字口径**（C11 那套信号 ID，见 `SignalSchema.numeric`）：车型既然立成 C11，
    /// signalMap 的形态也得跟着换，legacy 字段名在这套 schema 下一个都读不出来。
    /// 数字口径没有的字段（剩余能量、车外温度、数据时间…）不硬造——真 C11 也不报，
    /// 界面本来就按「读不到就隐藏」处理。
    static var vehicleState: VehicleState {
        var state = VehicleState()
        state.signalMap = [
            "1204": "76",       // 电量 %
            "2188": "312",      // 续航 km
            "1318": "86339",    // 总里程 km
            "1177": "715.9",    // 电池电压：C11 纯电是 800V 平台，静置 708–718 才像话
            "1178": "1.0",      // 电池电流（静置底噪）
            "1182": "27",       // 电池最低单体温度
            "1149": "0",        // 充电状态：未充电
            "47": "0",          // 慢充枪未连接
            "1197": "0",        // 快充枪未连接

            "1298": "1",        // 已锁车（1 = 已锁）
            "1277": "0", "1278": "0", "1279": "0", "1280": "0",  // 四门已关
            "1281": "0",        // 尾门已关
            "1282": "0",        // 前备箱已关

            // 前两扇窗开 10%：数字口径 percent 是正向刻度（0 = 关），legacy 演示数据里
            // 那两个 10 在 S01 的倒置刻度下其实是「全关」，这里按本意写成微开。
            "644": "10", "865": "10", "645": "0", "866": "0",
            "1693": "1", "1694": "1", "1695": "0", "1696": "0",

            "1938": "0",        // 空调关
            "2183": "24",       // 设定温度
            "1941": "3",        // 风量
            "3713": "1",        // 模式：制冷
            "1939": "0",        // 手动
            "1349": "33",       // 车内温度

            "1010": "0",        // 挡位 P，非行驶
            "1258": "0",        // ON3 电源位：下电

            "3636": "0",        // 哨兵未开启

            // 杭州市民中心，公开地标，不是任何人的真实位置。
            "2": "120.21201",   // 经度
            "3": "30.24704",    // 纬度

            "2646": "252", "2653": "249", "2660": "261", "2667": "255",  // 胎压 kPa
            "2641": "0", "2648": "0", "2655": "0", "2662": "0"           // 胎压告警：四轮正常
        ]
        // 正常链路里 schema 是 `fetchVehicleState` 检测后赋的，演示态不走那条路，这里补上；
        // 走同一个 detect 而不是硬编码 .numeric，免得两处口径各判各的。
        state.schema = SignalSchema.detect(state.signalMap, carType: "C11")
        // 充电上限在数字口径下不是信号，正常链路来自 commonConfig，演示态直接放到同一个落点。
        state.chargePlanLimit = 90
        return state
    }

    /// 演示用里程能耗统计，数值取自公开演示车，用来在审核/截图时把统计页填满。
    static var drivingStats: DrivingStats {
        let days = ["07-31", "08-01", "08-02", "08-03", "08-04", "08-05", "08-06"]
        let mileages = [24, 28, 24, 26, 16, 31, 29]
        let energies = [3768, 5406, 3492, 4206, 2753, 4728, 4205]
        let weeks: [(String, String, Double)] = [
            ("2026-06-22", "2026-06-28", 13.9),
            ("2026-06-29", "2026-07-05", 14.1),
            ("2026-07-06", "2026-07-12", 16.4),
            ("2026-07-13", "2026-07-19", 15.5),
            ("2026-07-20", "2026-07-26", 16.4),
            ("2026-07-27", "2026-08-02", 15.7)
        ]
        let weekList = weeks.map {
            DrivingStats.WeeklyEC(weekStart: $0.0, weekEnd: $0.1, hundredKmEc: $0.2)
        }
        return DrivingStats(
            totals: .init(totalMileageKm: 87398, totalEnergyKwh: 12292, deliveryDays: 2093, rangeMileageKm: 178),
            daily: zip(days, zip(mileages, energies)).map { day, pair in
                .init(day: day, mileageKm: pair.0, energyWh: pair.1)
            },
            // 默认选中最后一周，构成图得跟那根柱子对上。
            energyDistribution: weekList.last?.range.map(energyDistribution(for:))
                ?? .init(driverKwh: 22.5, acKwh: 3.7, otherKwh: 2.2),
            weekly: .init(rankPercent: "31%", rankHundredKmEc: 15.7, weeks: weekList),
            range: .lastSevenDays(),
            distributionWeekID: weekList.last?.id
        )
    }

    /// 演示用的能耗构成。按区间起点派生，所以同一周反复点开是同一组数，
    /// 换一周又确实变——正好验「点了跟不跟着变」。
    static func energyDistribution(for range: DrivingStatsRange) -> DrivingStats.EnergyDistribution {
        let seed = Int(range.begintime / 86_400_000)
        func step(_ modulus: Int) -> Double { Double(((seed % modulus) + modulus) % modulus) }
        func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        // 模数不能取 7：相邻周的 seed 正好差 7 天，模 7 恒等，六根柱子会给出同一个数。
        return .init(
            driverKwh: round1(19.8 + step(11) * 0.45),
            acKwh: round1(2.6 + step(3) * 0.55),
            otherKwh: round1(1.8 + step(2) * 0.6)
        )
    }

    /// 演示用的逐趟行程。地名用杭州的公开地标，坐标也是市民中心一带的公开坐标，
    /// 不是任何人的真实住址——审核和截图都会看到这一页。
    ///
    /// 时间按「今天 / 昨天 / 前天」相对生成，所以不管哪天打开演示账号，列表里都有
    /// 今天那两趟，不会出现「今天 0 趟」这种看起来像坏了的状态。
    static var tripLog: [TripRecord] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// (往前几天, 出发时分, 到达时分, 公里, 起电, 终电, 起点, 终点, 是否补记)
        let seeds: [(Int, Int, Int, Double, Int, Int, String, String, Bool)] = [
            (0, 8 * 60 + 42, 9 * 60 + 9, 11.6, 82, 79, "滨江区江陵路", "钱江新城市民中心", false),
            (0, 18 * 60 + 6, 18 * 60 + 34, 13.2, 79, 76, "钱江新城市民中心", "滨江区江陵路", false),
            (1, 7 * 60 + 55, 8 * 60 + 26, 17.4, 90, 86, "滨江区江陵路", "西湖区黄龙体育中心", false),
            (1, 17 * 60 + 20, 17 * 60 + 51, 17.9, 86, 82, "西湖区黄龙体育中心", "滨江区江陵路", false),
            (2, 10 * 60 + 12, 10 * 60 + 40, 14.8, 74, 71, "滨江区江陵路", "萧山区万象汇", false),
            (3, 9 * 60 + 3, 16 * 60 + 48, 42.3, 88, 79, "滨江区江陵路", "临安区青山湖", true)
        ]

        return seeds.enumerated().map { index, seed in
            let day = calendar.date(byAdding: .day, value: -seed.0, to: today) ?? today
            let start = calendar.date(byAdding: .minute, value: seed.1, to: day) ?? day
            let end = calendar.date(byAdding: .minute, value: seed.2, to: day) ?? start
            // 坐标沿起点往西北方向散开一点，够让地图/距离有东西可用，不重要。
            let latitude = 30.24704 - Double(index) * 0.004
            let longitude = 120.21201 + Double(index) * 0.004
            return TripRecord(
                vin: nil,
                startAt: start,
                endAt: end,
                distanceKm: seed.3,
                startSoc: seed.4,
                endSoc: seed.5,
                start: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                end: CLLocationCoordinate2D(latitude: latitude + 0.012, longitude: longitude + 0.01),
                startPlace: seed.6,
                endPlace: seed.7,
                isReconstructed: seed.8
            )
        }
    }

    /// 演示用的充电记录。和行程同理：地名用杭州的公开地标，时间相对生成，
    /// 所以不管哪天打开演示账号，列表里都有「今天」那一次。
    ///
    /// 三条覆盖三种形态：夜间慢充（正常记录）、商场快充（高功率 + 直流）、
    /// 以及一条补记（App 没在跑、靠电量差补出来的），审核一眼能看全。
    static var chargeLog: [ChargeRecord] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// (往前几天, 开始时分, 持续分钟, 起电, 终电, 度数, 峰值kW, 是否快充, 地点, 是否补记)
        let seeds: [(Int, Int, Int, Int, Int, Double, Double, Bool, String, Bool)] = [
            (0, 22 * 60 + 10, 320, 42, 88, 38.4, 6.6, false, "滨江区江陵路 充电站", false),
            (2, 12 * 60 + 35, 46, 28, 76, 33.1, 62.0, true, "萧山区万象汇 快充站", false),
            (4, 21 * 60 + 5, 420, 35, 90, 43.2, 7.0, false, "滨江区江陵路 充电站", true)
        ]

        return seeds.enumerated().map { index, seed in
            let day = calendar.date(byAdding: .day, value: -seed.0, to: today) ?? today
            let start = calendar.date(byAdding: .minute, value: seed.1, to: day) ?? day
            let end = calendar.date(byAdding: .minute, value: seed.1 + seed.2, to: day) ?? start
            let latitude = 30.20835 + Double(index) * 0.006
            let longitude = 120.21105 - Double(index) * 0.005
            return ChargeRecord(
                vin: nil,
                startAt: start,
                endAt: end,
                startSoc: seed.3,
                endSoc: seed.4,
                energyKwh: seed.5,
                maxPowerKw: seed.6,
                isDC: seed.7,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                place: seed.8,
                isReconstructed: seed.9
            )
        }
    }
}
