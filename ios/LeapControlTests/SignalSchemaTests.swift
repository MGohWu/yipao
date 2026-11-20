import Foundation
import Testing
@testable import LeapControl

/// 字段命名体系的识别与映射。
///
/// 这层存在的理由是一次真实故障：C11 登录后整屏空白，抓日志才发现车况 98 个字段全都取到了，
/// 只是 key 是数字信号 ID（`100003`、`1318`…），而取值全按 S01 的语义名（`soc`、`acSwitch`…）写死。
@Suite("字段命名体系")
struct SignalSchemaTests {

    /// C11 实测响应的节选，值取自真车（车停放、上锁、空调关）。
    private let c11: [String: String] = [
        "1": "1785900613638",
        "100003": "79.9",
        "1318": "35347",
        "2188": "454",
        "2646": "253", "2653": "253", "2660": "255", "2667": "247",
        // 告警位 = 胎压 ID − 5：左前2641/右前2648/左后2655/右后2662（全 0=正常）。
        // 2669/2681 是非告警信号，一并放进来验证不会被误当告警。
        "2641": "0", "2648": "0", "2655": "0", "2662": "0",
        "2669": "1", "2681": "2",
        "2": "120.185362",
        "3": "30.259255",
        "sts": "1785900614706"
    ]

    private func state(_ pairs: [String: String], isExtendRange: Bool = false) -> VehicleState {
        var state = VehicleState()
        state.signalMap = pairs
        state.schema = SignalSchema.detect(pairs)
        state.isExtendRange = isExtendRange
        return state
    }

    // MARK: - 识别

    @Test("有 soc 字段就是语义名体系")
    func detectsLegacy() {
        #expect(SignalSchema.detect(["soc": "76", "acSwitch": "false"]) == .legacy)
    }

    @Test("key 多数是纯数字就是数字 ID 体系")
    func detectsNumeric() {
        // C11 的 signalMap 里混着 `sts` 这类非数字 key，不能要求全部是数字。
        #expect(SignalSchema.detect(c11) == .numeric)
    }

    @Test("认不出来的体系不瞎猜，返回空表")
    func detectsUnknown() {
        #expect(SignalSchema.detect([:]) == .unknown)
        #expect(SignalSchema.detect(["foo": "1", "bar": "2"]) == .unknown)
    }

    @Test("识别只看 signalMap 形态，不看 carType")
    func detectionIgnoresCarType() {
        // 口径只有两套，新车型该零改动接入，所以判据不能是车型字符串。
        #expect(SignalSchema.detect(["soc": "80"]) == .legacy)
        // C11 之外的车型也上报数字 ID，自动落进同一张表，不需要往白名单里加车型。
        #expect(SignalSchema.detect(["100003": "80", "1318": "1"]) == .numeric)
    }

    // MARK: - C11 数字体系取值

    @Test("C11 的电量、里程、续航按数字 ID 取到")
    func numericBattery() {
        let state = state(c11)
        #expect(state.soc == 79)
        #expect(state.totalMileage == 35347)
        #expect(state.expectedMileage == 454)
    }

    @Test("C11 四轮胎压按数字 ID 取到；告警位=胎压ID−5，2669/2681 不算告警")
    func numericTires() {
        let pressures = state(c11).tirePressures
        #expect(pressures.map(\.kPa) == [253, 253, 255, 247])
        #expect(pressures.allSatisfy { !$0.warning })
        #expect(state(c11).hasTireData)
        // 回归守卫（2026-08-11 真实误报车）：fixture 里 `2669=1`、`2681=2`，而四个真告警位
        // 2641/2648/2655/2662 全为 0。曾经把 `2669` 当右后告警位 → 误报「右后异常」。
        // 现在 `2669`/`2681` 不映射到任何告警位，四轮必须全部正常。
        #expect(!state(c11).hasTireWarning)

        // 正例：置真告警位。`2662` 是右后（胎压 2667 − 5），置 1 → 只有右后报异常。
        var rrWarn = c11
        rrWarn["2662"] = "1"
        let rr = state(rrWarn)
        #expect(rr.hasTireWarning)
        #expect(rr.tirePressures.map(\.warning) == [false, false, false, true])
    }

    @Test("C11 的车内温度按标定确认的 ID 取到")
    func numericIndoorTemp() {
        // 早上 26.5、午后 31.5，车主对照车机显示的是 31。
        #expect(state(["1349": "31.5"]).indoorTemp == 31.5)
    }

    @Test("充电上限和充电状态读不到就是读不到，不给默认值")
    func numericChargeFieldsStayNil() {
        // 车主车机上设的是 95%，而界面原来会回退到本地草稿的 90% ——
        // 凭空显示一个错数字比显示占位符糟得多。
        let state = state(c11)
        #expect(state.chargeLimit == nil)
        // 读不到充电状态不等于没插枪。
        #expect(state.chargeState == nil)
        #expect(!state.isCharging)
    }

    @Test("充电上限从 config 的充电计划里取，官方 key 是「3」")
    func chargePlanLimitFromConfig() throws {
        // C11 那批车不把充电上限当信号报，官方是从 data.config."3".percent 读的。
        let config = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"2":{"foo":"1"},"3":{"percent":"95","isEnable":"1"}}"#.utf8)
        )
        #expect(VehicleState.chargePlanLimit(fromConfig: config) == 95)
        // 反编译 bean 名 _$3 也认，防某个网关按 bean 名回。
        let beanNamed = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"_$3":{"percent":"80"}}"#.utf8)
        )
        #expect(VehicleState.chargePlanLimit(fromConfig: beanNamed) == 80)
        // percent 空串按官方判据视同没有，不 parse 出 0。
        let empty = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"3":{"percent":""}}"#.utf8)
        )
        #expect(VehicleState.chargePlanLimit(fromConfig: empty) == nil)
        #expect(VehicleState.chargePlanLimit(fromConfig: nil) == nil)
    }

    @Test("信号里没有充电上限时退到充电计划，两头都没有才是 nil")
    func chargeLimitFallsBackToChargePlan() {
        var withPlan = state(c11)
        withPlan.chargePlanLimit = 95
        #expect(withPlan.chargeLimit == 95)
        // 语义口径直接报 chargesocSetting 信号，信号优先——两套来源不该打架。
        var legacy = VehicleState()
        legacy.signalMap = ["chargesocSetting": "90"]
        legacy.chargePlanLimit = 95
        #expect(legacy.chargeLimit == 90)
    }

    @Test("充电计划从 config.3 整份解析：时段、开关、循环日、目标电量")
    func chargePlanParsesFullConfig() throws {
        // 取自真车 commonConfig 的 config."3"（percent/isEnable/circulation/recharge 是数字）。
        let config = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"3":{"cycles":"1,1,1,1,1,1,1","endTime":"08:00","percent":90,"isEnable":1,"recharge":0,"beginTime":"23:00","circulation":2}}"#.utf8)
        )
        let plan = try #require(ChargePlan.fromConfig(config))
        #expect(plan.beginTime == "23:00")
        #expect(plan.endTime == "08:00")
        #expect(plan.percent == 90)
        #expect(plan.isEnable)
        #expect(plan.cycles == Array(repeating: true, count: 7))
        #expect(plan.circulation == 2)
        #expect(plan.recharge == 0)
        // 七位全 1 → 每天。
        #expect(plan.cyclesDescription == "每天")

        // percent 缺失就没有计划（同 chargePlanLimit 的判据）。
        let noPercent = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"3":{"beginTime":"23:00"}}"#.utf8)
        )
        #expect(ChargePlan.fromConfig(noPercent) == nil)
        #expect(ChargePlan.fromConfig(nil) == nil)
    }

    @Test("循环日文案：工作日 / 周末 / 具体几天 / 从不")
    func chargePlanCyclesDescription() {
        func plan(_ cycles: [Bool]) -> ChargePlan {
            ChargePlan(beginTime: "", endTime: "", percent: 90, isEnable: true,
                       cycles: cycles, circulation: 0, recharge: 0)
        }
        // index 0=周一 … 6=周日。
        #expect(plan([true, true, true, true, true, false, false]).cyclesDescription == "工作日")
        #expect(plan([false, false, false, false, false, true, true]).cyclesDescription == "周末")
        #expect(plan([true, false, true, false, true, false, false]).cyclesDescription == "周一 周三 周五")
        #expect(plan([false, false, false, false, false, false, false]).cyclesDescription == "从不")
    }

    @Test("C11 的经纬度按数字 ID 取到")
    func numericLocation() {
        let state = state(c11)
        #expect(state.longitude == 120.185362)
        #expect(state.latitude == 30.259255)
        #expect(state.shareableCoordinate != nil)
    }

    @Test("C11 的空调设定温度和风量按联调确认的 ID 取到")
    func numericClimateSettings() {
        // 车主报「26 度 3 档」读到 2183=26、1941=3；改成 22 度 6 档后两个字段同时跟着变。
        #expect(state(["2183": "26", "1941": "3"]).acSetting == 26)
        #expect(state(["2183": "26", "1941": "3"]).acFanLevel == 3)
        #expect(state(["2183": "22", "1941": "6"]).acSetting == 22)
        #expect(state(["2183": "22", "1941": "6"]).acFanLevel == 6)
    }

    @Test("C11 的电池总电压按 800V 平台的量级取到")
    func numericBatteryVoltage() {
        // 一开始按 400V 车找 350–450 V，把 717 漏了。C11 是 800V 平台。
        #expect(state(["1177": "717.4"]).batteryVoltage == 717.4)
        // 不是剩余能量：SOC 掉 2.1% 时它只掉 1.3，能量该掉近 20（0.1 kWh 为单位）。
        #expect(state(["1177": "717.4"]).dumpEnergyWh == nil)
    }

    @Test("C11 的空调模式按自己那套编码读，3 是制热不是自动")
    func numericClimateMode() {
        // 真车四次采样两次翻转：手动制冷 1 → 自动 0 → 制冷 1 → 制热 3。
        #expect(state(["3713": "1"]).climateMode == .cold)
        #expect(state(["3713": "3"]).climateMode == .hot)
        #expect(state(["3713": "0"]).climateMode == .auto)
        // 同一个 3 在 S01 那套里是 hotcold，当自动读——照着一套读另一套会把制热显示成自动。
        var s01 = VehicleState()
        s01.signalMap = ["acCoolingAndHeating": "3"]
        s01.schema = .legacy
        #expect(s01.climateMode == .auto)
    }

    @Test("C11 的空调自动位单独也读得到")
    func numericClimateAutoFlag() {
        // 1939：手动 0 → 自动 1 → 制冷 0 → 制热 0，和 3713 == 0 说的是同一件事。
        #expect(state(["1939": "1"]).acAutoMode == true)
        #expect(state(["1939": "0"]).acAutoMode == false)
    }

    @Test("C11 的电流按标定确认的 ID 取到")
    func numericBatteryCurrent() {
        // 切到制热那一刻 1348（制热功率）跳到 3500 W，3500 ÷ 716.9 V ≈ 4.9 A，
        // 同一时刻 1178 从 1.0 跳到 5.2——功率、电压、电流三者对得上。
        #expect(state(["1178": "5.2"]).batteryCurrent == 5.2)
    }

    @Test("C11 充电时的电流是负的，充电状态和剩余时间也读得到")
    func numericChargingFields() {
        // 一次真实充电：停车 1178 = 1.0，插枪后 −8.699。
        // 724.4 V × 8.699 A = 6.30 kW，交流慢充的典型功率。
        let charging = state(["1149": "1", "1200": "140", "1178": "-8.699", "1177": "724.4"])
        #expect(charging.isCharging)
        #expect(charging.chargeRemainMinutes == 140)
        #expect(charging.batteryCurrent == -8.699)
        #expect(charging.batteryVoltage == 724.4)
    }

    @Test("充电功率由电压电流算出来，车不上报这一项")
    func numericChargePower() {
        // 724.4 V × 8.699 A = 6.30 kW，交流慢充的典型功率。电流是负的，取绝对值。
        let charging = state(["1177": "724.4", "1178": "-8.699"])
        #expect(charging.chargePowerKW.map { ($0 * 100).rounded() / 100 } == 6.3)
        // 缺一个就算不出来，不拿单边凑。
        #expect(state(["1177": "724.4"]).chargePowerKW == nil)
    }

    @Test("C11 的字段体系里根本没有剩余能量这一项")
    func numericHasNoRemainingEnergy() {
        // 81.9 kWh 的包、SOC 77.5%，该是 63.5 kWh，而 96 个字段里三种量级一个候选都没有。
        #expect(SignalSchema.numeric.candidates(for: .dumpEnergy).isEmpty)
        // S01 那套有，界面按这个决定摆不摆这一格。
        #expect(!SignalSchema.legacy.candidates(for: .dumpEnergy).isEmpty)
    }

    @Test("不充电时剩余时间字段整个缺席，不会显示成 0 分钟")
    func numericChargeRemainAbsentWhenIdle() {
        // 1200 是充电时才出现的字段，停车那几份采样里根本没有它。
        let idle = state(["1149": "0", "1177": "717.3"])
        #expect(!idle.isCharging)
        #expect(idle.chargeRemainMinutes == nil)
    }

    @Test("插枪、充电、停充三件事分得开")
    func numericChargeGunVersusState() {
        // 四种真实情形抓齐了才分得出来（见 SignalSchema 里那张表）：
        //           未插枪  插枪待充  充电中  停充未拔枪
        //   47         0      1        1       1
        //   1149       0      0        1       2
        let unplugged = state(["47": "0", "1149": "0"])
        #expect(unplugged.chargeGunConnected == false)
        #expect(!unplugged.isCharging)

        // 关键一条：插着枪等着充，1149 照样是 0——0 不等于「没插枪」。
        let waiting = state(["47": "1", "1149": "0"])
        #expect(waiting.chargeGunConnected == true)
        #expect(waiting.chargeState == 0)
        #expect(!waiting.isCharging)

        // 停止充电、枪没拔：1149 变 2，剩余时间字段整个消失。
        let stopped = state(["47": "1", "1149": "2", "1178": "0.4"])
        #expect(stopped.chargeGunConnected == true)
        #expect(stopped.chargeState == 2)
        #expect(!stopped.isCharging)
        #expect(stopped.chargeRemainMinutes == nil)
    }

    @Test("S01 那套没有充电枪这一项，读出来是 nil 而不是没插枪")
    func legacyHasNoChargeGunSignal() {
        #expect(SignalSchema.legacy.candidates(for: .chargeGunConnected).isEmpty)
    }

    @Test("数字表里没确认的信号一律取不到，不拿别的字段顶替")
    func numericUnmappedStaysNil() {
        // 这份采样是车停放、空调关那次，空调那一簇字段一个都没有。
        let state = state(c11)
        #expect(state.acModeRaw == nil)
        #expect(state.climateMode == nil)
        #expect(!state.acOn)
        // 表里没有的字段不会因为 signalMap 里恰好存在同名 key 就被取到。
        #expect(state.chargeLimit == nil)
    }

    // MARK: - 真车标定确认的四项

    @Test("C11 的门锁、驾驶门、尾门按标定出来的 ID 取到")
    func numericCalibratedBooleans() {
        // 一次真车标定的结果，每条都是正反两次值完全对调才采信的。
        let parked = state(["1298": "1", "1277": "0", "1281": "0"])
        #expect(parked.isLocked == true)
        #expect(!parked.anyDoorOpen)
        #expect(parked.trunkOpen == false)

        let opened = state(["1298": "0", "1277": "1", "1281": "1"])
        #expect(opened.isLocked == false)
        #expect(opened.anyDoorOpen)
        #expect(opened.trunkOpen == true)
    }

    // MARK: - 车窗刻度方向

    @Test("S01 的 0…10 是倒着的，换算成开度百分比")
    func invertedScaleReadsOpenness() {
        // 车端 0 是全开、10 是关闭——直接当百分比用会把关好的窗显示成全开。
        #expect(WindowScale.invertedTen.openness(raw: 0) == 100)
        #expect(WindowScale.invertedTen.openness(raw: 8) == 20)
        #expect(WindowScale.invertedTen.openness(raw: 10) == 0)
    }

    @Test("C11 的 0…100 本来就是开度，原样透传")
    func percentScaleReadsOpenness() {
        // 标定实测：降一半读到 50，开车门车窗自动微降读到 6。
        #expect(WindowScale.percent.openness(raw: 0) == 0)
        #expect(WindowScale.percent.openness(raw: 6) == 6)
        #expect(WindowScale.percent.openness(raw: 50) == 50)
    }

    @Test("换算能原路返回")
    func scaleRoundTrips() {
        for openness in [0, 20, 50, 100] {
            #expect(WindowScale.invertedTen.openness(raw: WindowScale.invertedTen.raw(openness: openness)) == openness)
            #expect(WindowScale.percent.openness(raw: WindowScale.percent.raw(openness: openness)) == openness)
        }
    }

    @Test("越界的原始值被夹取，不会算出负开度")
    func scaleClampsRawValues() {
        #expect(WindowScale.invertedTen.openness(raw: 99) == 0)
        #expect(WindowScale.invertedTen.openness(raw: -3) == 100)
        #expect(WindowScale.percent.openness(raw: 999) == 100)
        #expect(WindowScale.percent.openness(raw: -3) == 0)
    }

    @Test("同一个车窗原始值 0，两套体系读出来完全相反")
    func sameRawMeansOppositeThings() {
        // 这正是要引入 WindowScale 的原因：C11 车窗关好上报 0，
        // 按 S01 那套读就成了「全开」。
        var s01 = VehicleState()
        s01.signalMap = ["leftFrontWindowPercent": "0"]
        s01.schema = .legacy
        #expect(s01.leftFrontWindow == 100)

        var c11 = VehicleState()
        c11.signalMap = ["644": "0"]
        c11.schema = .numeric
        #expect(c11.leftFrontWindow == 0)
    }

    @Test("纯电车不该被当成增程车")
    func batteryElectricIsNotRangeExtender() {
        // 是不是增程车只看 isExtendRange（来自 vehicle/list 的 abilities 含 "39"），
        // 车况 signalMap 里的汽油信号一概不作数——纯电车也会实报这些字段。

        // 纯电 C11（800V）实测：2956 fuelLevel = 0、2946 fuelHeating = 1 照样上报。
        let bev = state([
            "1204": "48", "2188": "301",
            "3257": "301", "3260": "200", "3262": "0",
            "2956": "0", "2946": "1"
        ], isExtendRange: false)
        #expect(bev.hasFuel == false)
        #expect(bev.isFuelHeating == false)

        // 纯电 C11（400V）实测：3256/3259 汽油续航竟然实报 200/486——旧的「汽油续航读得到」
        // 判据在这台车上直接翻车。现在纯电即 isExtendRange=false，一律不显示油量。
        let bev400 = state([
            "1204": "55", "3256": "200", "3259": "486"
        ], isExtendRange: false)
        #expect(bev400.hasFuel == false)
        #expect(bev400.gasolinePercent == nil)

        // 增程版 C11 实测：abilities 含 "39" → isExtendRange=true，油量和汽油续航都显示。
        let reev = state([
            "1204": "77", "3235": "68.5",
            "3256": "506", "3257": "225", "3258": "731",
            "3259": "541", "3260": "193", "3261": "734", "3262": "0"
        ], isExtendRange: true)
        #expect(reev.hasFuel == true)
        #expect(reev.gasolinePercent == 68)
        #expect(reev.gasolineRange == 506)

        // 纯电 C01 实测：3235 油量报 0——旧的「油量读得到」判据 `0 != nil` 也会误判。
        // 现在同样按 isExtendRange=false 判纯电。
        let c01 = state([
            "1204": "62", "3230": "0", "3235": "0", "3236": "3", "2946": "0"
        ], isExtendRange: false)
        #expect(c01.hasFuel == false)
        #expect(c01.gasolinePercent == nil)
        #expect(c01.isFuelHeating == false)

        // 增程车油箱跑空时油量就是 0，isExtendRange=true 时照样按增程显示，油量透出 0。
        let empty = state([
            "1204": "20", "3235": "0", "3256": "0", "3259": "0"
        ], isExtendRange: true)
        #expect(empty.hasFuel == true)
        #expect(empty.gasolinePercent == 0)
    }

    @Test("PTC 功率大于零才显示电池预热中")
    func batteryPreheatStatus() {
        #expect(state(["1348": "3500"]).isBatteryPreheating == true)
        #expect(state(["1348": "0"]).isBatteryPreheating == false)
        #expect(state([:]).isBatteryPreheating == nil)
        #expect(state(["1186": "0", "1348": "0"]).batteryPreheatStatus == .temperatureGood)
        #expect(state(["1186": "1", "1348": "0"]).batteryPreheatStatus == .inactive)
        #expect(state(["ptcPowerSettingValue": "3500"]).isBatteryPreheating == nil)
    }

    @Test("S01 关好的车窗不被后窗占位值误判成开着")
    func s01ClosedWindowsNotReversedByRearPlaceholder() {
        // S01 是两门轿跑，没有后窗——车端后窗字段恒报占位 0，
        // 而倒序刻度里 0 是「全开」。把后窗算进来，关好的 S01（前窗 raw 10）
        // 会因为后窗那个 0 被读成全开，整车永远显示车窗开着。这是回归，别再犯。
        var closed = VehicleState()
        closed.signalMap = [
            "soc": "80",
            "leftFrontWindowPercent": "10", "rightFrontWindowPercent": "10",
            "leftRearWindowPercent": "0", "rightRearWindowPercent": "0"
        ]
        closed.schema = SignalSchema.detect(closed.signalMap, carType: "S01")
        #expect(closed.anyWindowOpen == false)
        #expect(closed.maxWindowOpenness == 0)

        // 前窗真开着（raw 0 = 全开）才算开。
        var open = VehicleState()
        open.signalMap = [
            "soc": "80",
            "leftFrontWindowPercent": "0", "rightFrontWindowPercent": "10",
            "leftRearWindowPercent": "0", "rightRearWindowPercent": "0"
        ]
        open.schema = SignalSchema.detect(open.signalMap, carType: "S01")
        #expect(open.anyWindowOpen == true)
        #expect(open.maxWindowOpenness == 100)
    }

    @Test("只报开合状态位的车，车窗照样知道开没开")
    func windowStateFallsBackToOpenFlags() {
        // C11 增程版实测（2026-08-07，90 字段）：开度 644/645/865/866 一个都没有，
        // 只有状态位 1693…1696。先前只接开度，这台车首页车窗那格永远是 --。
        var closed = VehicleState()
        closed.signalMap = ["1693": "0", "1694": "0", "1695": "0", "1696": "0"]
        closed.schema = .numeric
        #expect(closed.anyWindowOpen == false)
        // 开度车没报，就不该冒充一个百分比出来。
        #expect(closed.maxWindowOpenness == nil)

        var open = VehicleState()
        open.signalMap = ["1693": "0", "1694": "2", "1695": "0", "1696": "0"]
        open.schema = .numeric
        #expect(open.anyWindowOpen == true)
        #expect(open.rightFrontWindowOpen == true)
        // 判据是「非 0 即开」，不是「== 2」——这组信号不止 0/2 两个取值。
        var other = VehicleState()
        other.signalMap = ["1693": "5"]
        other.schema = .numeric
        #expect(other.anyWindowOpen == true)
    }

    @Test("开度说关、状态位说开，仍然算开着")
    func openFlagAloneIsEnough() {
        // 数字口径这边官方判开合读的就是状态位（开度那组只喂 3D 车模动画），
        // 所以开度报 0 也不能盖过状态位。两组取或，任何一路说开就算开。
        var state = VehicleState()
        state.signalMap = ["644": "0", "1693": "2"]
        state.schema = .numeric
        #expect(state.anyWindowOpen == true)
        #expect(state.leftFrontWindow == 0)
    }

    @Test("车窗信号一个都没有时是 nil，不是「已关」")
    func windowStateUnknownStaysNil() {
        var state = VehicleState()
        state.signalMap = ["1204": "77"]
        state.schema = .numeric
        #expect(state.anyWindowOpen == nil)
    }

    @Test("T03 的 0 是关闭，和 S01 正好相反")
    func t03WindowDirectionIsOpposite() {
        // 官方 Oooo000 里同一个 leftFrontWindowPercent：S01 判开是 != 10，
        // isT03Car() 那支判开是 != 0。两台车共用一张表，方向却相反。
        let map = ["soc": "80", "leftFrontWindowPercent": "0"]
        var t03 = VehicleState()
        t03.signalMap = map
        t03.schema = SignalSchema.detect(map, carType: "T03")
        #expect(t03.anyWindowOpen == false)
        // 量程 2026-08-10 真车验明是 0…100 线性（发 50 车报 51），所以直接就是百分比。
        #expect(t03.leftFrontWindow == 0)

        var s01 = VehicleState()
        s01.signalMap = map
        s01.schema = SignalSchema.detect(map, carType: "S01")
        #expect(s01.anyWindowOpen == true)
        #expect(s01.leftFrontWindow == 100)
    }

    /// T03 实测节选（2026-08-10，55 字段，车停放、上锁、车窗全关、空调关）。
    /// 车窗那四个是这台车真正上报的字段名和取值——**不是** `leftFrontWindowPercent`。
    private let t03: [String: String] = [
        "soc": "33",
        "expectedMileage": "140",
        "acSwitch": "false", "acSetting": "23", "acAirVolume": "1",
        "acCoolingAndHeating": "1", "outdoorTemp": "26",
        "isSupportWindowsRemoteControl": "2",
        "driverWindowStatus": "false", "rightFrontWindowStatus": "false",
        "leftRearWindowStatus": "false", "rightRearWindowStatus": "false"
    ]

    private func t03State(_ overrides: [String: String] = [:]) -> VehicleState {
        var state = VehicleState()
        state.signalMap = t03.merging(overrides) { _, new in new }
        state.schema = SignalSchema.detect(state.signalMap, carType: "T03")
        return state
    }

    @Test("T03 的车窗是另一套布尔状态位，关好的窗不能被读成开着")
    func t03WindowsUseBooleanStatusFields() {
        // 实测这台 T03 一个 `*Percent` 都不报，车窗只有四个 `*Status` 布尔位。
        // 先前表里没有它们，首页车窗那格永远是 --，就是这次的故障。
        let closed = t03State()
        #expect(closed.anyWindowOpen == false)
        // 布尔字面量必须先认：`"false" != "0"` 是成立的，照抄官方那条判据
        // 会把四扇关好的窗全报成开着——比读不到更糟，这条是回归护栏。
        #expect(closed.leftFrontWindowOpen == false)
        // 车没报开度，就别冒充一个百分比。
        #expect(closed.maxWindowOpenness == nil)

        // 左前是主驾那个字段，名字和其余三扇不是一套。
        let open = t03State(["driverWindowStatus": "true"])
        #expect(open.anyWindowOpen == true)
        #expect(open.leftFrontWindowOpen == true)
        #expect(open.maxWindowOpenness == nil)

        // 后窗单独开也认。
        #expect(t03State(["rightRearWindowStatus": "true"]).anyWindowOpen == true)
        // 这台车**控不了**车窗：支持位虽然报 2，但四个开度字段一个都没有。
        // 依据见 `windowRemoteSupportNeedsOpennessFields`。
        #expect(!closed.windowsRemoteSupported)
    }

    @Test("carType 带后缀时，识别和下发不会各判各的")
    func carTypeSuffixKeepsDetectAndCommandInSync() {
        // `detect` 原先用精确相等、下发一律用前缀匹配。carType 一旦是 `T03-2023`
        // 这种带后缀的，同一台车会被判成两个结论：车窗刻度落回 S01 的倒序
        // （关好的窗读成全开），下发却仍按 T03 的三档发。现在两边都走 `CarTypeFamily`。
        let map = ["soc": "80", "driverWindowStatus": "false"]
        var state = VehicleState()
        state.signalMap = map
        state.schema = SignalSchema.detect(map, carType: "T03-2023")
        #expect(state.schema.windowScale == .percent)
        #expect(state.anyWindowOpen == false)

        // 下发侧对同一个 carType 给出一致的答案。
        #expect(LeapCommand.windowValue(openness: 100, carType: "T03-2023") == "100")
        #expect(LeapCommand.windowValue(openness: 50, carType: "T03-2023") == "50")
        #expect(LeapCommand.windowSupportsSlider(carType: "T03-2023"))
        #expect(!LeapCommand.trunkSupportsClose(carType: "T03-2023"))

        // 大小写不该影响任何一边。
        #expect(SignalSchema.detect(map, carType: "t03").windowScale == .percent)
        #expect(CarTypeFamily.isS01("s01-abc"))
        #expect(CarTypeFamily.isLegacyFamily("T03"))
        #expect(!CarTypeFamily.isLegacyFamily("C11"))
    }

    @Test("车图层的车型分组也按前缀走，带后缀不会掉进兜底分支")
    func carLayerGroupingUsesPrefixToo() {
        // 车图层那套分组表原来是精确 switch，`T03-2023` 会静悄悄落进 default，
        // 门窗按 C11 那套画（四门齐全、尾门恒显示）、充电层也换到车身下面。
        // 判据统一后跟着走前缀，和车窗、下发那几处对齐。
        let plain = CarLayerComposer.plan(for: nil, carType: "T03")
        let suffixed = CarLayerComposer.plan(for: nil, carType: "T03-2023")
        #expect(plain == suffixed)

        // 充电中的帧数按车型不同（s01 = 18、t03 = 14、其余 = 15），带后缀也得对上。
        var charging = VehicleState()
        charging.signalMap = ["soc": "80", "chargeState": "1"]
        charging.schema = .legacy
        #expect(CarLayerComposer.plan(for: charging, carType: "T03-2023").chargeFrames.count == 14)
        #expect(CarLayerComposer.plan(for: charging, carType: "S01-2021").chargeFrames.count == 18)
        #expect(CarLayerComposer.plan(for: charging, carType: "C11").chargeFrames.count == 15)
    }

    @Test("车报了开度就以开度为准，状态位不跟随也不会误报「已关」")
    func opennessWinsOverStaleStatusFlags() {
        // 2026-08-10 实测那台能控车窗的 T03：车窗**实际开着**，四扇开度都报 `18`，
        // 而四个 `*WindowStatus` **仍然全报 false**（车况是 34 秒前的，不是没刷新）。
        // 状态位优先的话界面会说「已关」——窗开着该报的时候不报，比不知道更糟。
        var state = VehicleState()
        state.signalMap = [
            "soc": "63",
            "leftFrontWindowPercent": "18", "rightFrontWindowPercent": "18",
            "leftRearWindowPercent": "18", "rightRearWindowPercent": "18",
            "driverWindowStatus": "false", "rightFrontWindowStatus": "false",
            "leftRearWindowStatus": "false", "rightRearWindowStatus": "false"
        ]
        state.schema = SignalSchema.detect(state.signalMap, carType: "T03")
        #expect(state.anyWindowOpen == true)

        // 开度全 0 时才是真关着，这时状态位说什么都一样。
        var closed = state
        for key in ["leftFrontWindowPercent", "rightFrontWindowPercent",
                    "leftRearWindowPercent", "rightRearWindowPercent"] {
            closed.signalMap[key] = "0"
        }
        #expect(closed.anyWindowOpen == false)
    }

    @Test("数字口径的 0/2 状态位不受布尔解析影响")
    func numericWindowFlagsStillUseNonZeroRule() {
        // 布尔分支不能动到 C11 那组：`"0"` 走布尔同样是 false，
        // `"2"` 认不出布尔、落回「非 0 即开」，仍然是开着。
        var state = VehicleState()
        state.signalMap = ["1693": "2", "1694": "0", "1695": "0", "1696": "0"]
        state.schema = .numeric
        #expect(state.leftFrontWindowOpen == true)
        #expect(state.rightFrontWindowOpen == false)
        #expect(state.anyWindowOpen == true)
    }

    @Test("能不能控车窗看开度字段在不在，不是看支持位")
    func windowRemoteSupportNeedsOpennessFields() {
        // 两台 T03 实测（2026-08-10）：支持位都报 2，一台能控一台不能。
        // 能控的那台多且只多四个 *WindowPercent 开度字段（外加无关的 parkOutEnable）。
        let cannotControl = t03State()
        #expect(cannotControl.raw(.windowsRemoteSupported) == "2")
        #expect(!cannotControl.windowsRemoteSupported)

        // 能控的那台：同样报 2，但四个开度字段都在。
        let canControl = t03State([
            "leftFrontWindowPercent": "0", "rightFrontWindowPercent": "0",
            "leftRearWindowPercent": "0", "rightRearWindowPercent": "0"
        ])
        #expect(canControl.windowsRemoteSupported)

        // 支持位报了别的值，直接不支持，不用再看开度。
        var other = VehicleState()
        other.signalMap = ["soc": "80", "isSupportWindowsRemoteControl": "1",
                           "leftFrontWindowPercent": "0"]
        other.schema = .legacy
        #expect(!other.windowsRemoteSupported)
    }

    @Test("数字口径的车不报支持位，车窗一律放行")
    func numericSchemaAlwaysAllowsWindowControl() {
        // C11 增程版实测四个开度字段全缺，但它的车窗是能控的——官方在数字口径那套
        // 解析里直接把车窗开关置 true。拿 T03 那条判据套过来会把它误杀，这是回归护栏。
        var extended = VehicleState()
        extended.signalMap = ["1204": "77", "1693": "0", "1694": "0", "1695": "0", "1696": "0"]
        extended.schema = .numeric
        #expect(extended.raw(.windowsRemoteSupported) == nil)
        #expect(extended.windowsRemoteSupported)
    }

    @Test("T03 不上报车内温度，只有车外温度")
    func t03ReportsOutdoorTempOnly() {
        // 全表 55 个字段里没有 `indoorTemp`——这是车不报，不是没读到。
        // 首页那张卡因此退成车外温度并改口叫「车外温度」，见 `HomeView.temperatureLabel`。
        let state = t03State()
        #expect(state.indoorTemp == nil)
        #expect(state.outdoorTemp == 26)
        // 空调其余各项它都报，空调页不受影响。
        #expect(state.acSetting == 23)
        #expect(state.acFanLevel == 1)
        #expect(state.climateMode == .cold)
    }

    // MARK: - 候选 key

    @Test("首选 key 缺席时退到备选")
    func fallsBackToNextCandidate() {
        // C11 的 100003（带小数的精确电量）车休眠那次整个字段缺席，
        // 只认一个 key 的话电量会整项变空。1204 是它的整数版。
        #expect(state(["100003": "79.9", "1204": "80"]).soc == 79)
        #expect(state(["1204": "80", "1318": "1"]).soc == 80)
    }

    @Test("候选全都缺席才算取不到")
    func nilWhenAllCandidatesMissing() {
        #expect(state(["1318": "35347"]).soc == nil)
    }

    @Test("空字符串不算有值，继续往后找")
    func emptyValueFallsThrough() {
        #expect(state(["100003": "", "1204": "80"]).soc == 80)
    }

    @Test("标定结果排在候选最前，但不挤掉内置的")
    func learnedGoesFirstWithoutDropping() {
        let schema = SignalSchema.numeric.merging([.soc: "9999"])
        #expect(schema.candidates(for: .soc) == ["9999", "100003", "1204"])
        // 标定那次没覆盖到的状态还得靠内置的兜底。
        var state = VehicleState()
        state.signalMap = ["100003": "79.9"]
        state.schema = schema
        #expect(state.soc == 79)
    }

    @Test("叠加标定结果不会把车窗刻度弄丢")
    func mergingKeepsWindowScale() {
        #expect(SignalSchema.numeric.merging([.acSwitch: "9999"]).windowScale == .percent)
        #expect(SignalSchema.legacy.merging([.acSwitch: "9999"]).windowScale == .invertedTen)
    }

    // MARK: - 兼容

    @Test("语义名体系原样工作，老车型不受影响")
    func legacyStillWorks() {
        let state = state(["soc": "76", "driverDoorLockStatus": "true", "leftFrontTirePressure": "255"])
        #expect(state.soc == 76)
        #expect(state.isLocked == true)
        #expect(state.tirePressures.first?.kPa == 255)
    }

    @Test("本地构造的车况默认按语义名解析")
    func defaultsToLegacy() {
        // 演示车况和测试用例写的都是语义名，默认值必须是 legacy，否则演示模式会整屏空白。
        #expect(VehicleState().schema == .legacy)
    }

    @Test("空表体系下取值全部为 nil，不会误报状态")
    func unknownSchemaReadsNothing() {
        var state = VehicleState()
        state.signalMap = ["foo": "1"]
        state.schema = .unknown
        #expect(state.soc == nil)
        #expect(state.isLocked == nil)
        #expect(!state.hasTireData)
    }

    @Test("每个语义信号在语义名体系里都有对应 key")
    func legacyCoversEverySignal() {
        // 这套是从真车实测确认过的，不该有漏项；新增 VehicleSignal 时这条会立刻失败。
        //
        // 例外都是从 C11 那套数字 ID 里挖出来的信号，S01 / T03 的
        // ServerCarInfoBean 字段表里根本没有对应项，不是漏填：
        // - 充电枪连接、快充枪、健康充电、取消本次充电
        // - 前备箱、热管理档位
        // - 增程那一组（油量、CLTC/WLTC 续航、燃油加热）——S01 / T03 没有增程版
        // - 车窗开合状态位：数字口径独有的一组（1693…1696）。语义名那套没有平行字段，
        //   官方在 legacy 路径上是直接拿开度判开合的（S01 `!= 10`、T03 `!= 0`）。
        //
        // `.ptcPower` 是**另一种**例外，不属于上面那类。语义名那套里有个
        // `ptcPowerSettingValue`，但它是设定值/记忆值，不是实际输出功率——拿它判
        // 「正在预热」，空调设过一次温度之后就会一直报预热中。宁可这一路读不到
        // （`batteryPreheatStatus` 会退回 `.unknown`），也不能拿一个语义不对的字段冒充。
        let absentInLegacy: Set<VehicleSignal> = [
            .chargeGunConnected, .healthyCharge, .cancelChargeOnce,
            .frontTrunkOpen, .thermalManageRequest, .ptcPower,
            .leftFrontWindowOpen, .rightFrontWindowOpen,
            .leftRearWindowOpen, .rightRearWindowOpen,
            .gasolinePercent, .fuelLevel, .fuelHeating, .fuelHeatingError,
            .workingCondition,
            .cltcEnergyRange, .cltcGasolineRange, .cltcTotalRange,
            .wltcEnergyRange, .wltcGasolineRange, .wltcTotalRange,
            // 哨兵状态位只有数字口径的车（非 S01/T03）才报，legacy 那套语义名里没有对应字段。
            .sentinel,
            // 2026-11-19 补的一批。全部来自数字口径，
            // S01 / T03 的 ServerCarInfoBean 字段表里一个都没有；舒适座舱和冰箱入口
            // 在这两个车型上本来就被门控挡掉（`Vehicle.supportsCabinComfort` 先排车型）。
            .windshieldDefrost, .rapidCooling, .rapidHeating,
            .driverSeatHeating, .driverSeatVentilation,
            .passengerSeatHeating, .passengerSeatVentilation,
            .leftRearSeatHeating, .leftRearSeatVentilation,
            .rightRearSeatHeating, .rightRearSeatVentilation,
            .steeringWheelHeating, .steeringWheelHeatMinutes,
            .leftMirrorHeating, .rightMirrorHeating, .rearWindowHeating,
            .fridgeSwitch, .fridgeMode, .fridgeTargetTemp, .fridgeStyle, .fridgeFault,
            .fridgeParkSwitch, .fridgeParkDurationHours, .fridgeParkCycles, .fridgeParkEndTime,
            // 遮阳帘 / 天窗开度（1724 / 1718）。T03 样本里倒是有个 `sunShade`，但只见过关闭态、
            // 值域没测过，照「读不到就别显示」不映射；S01 / T03 也压根不给天窗入口。
            .sunshadeOpening, .sunroofOpening,
        ]
        for signal in VehicleSignal.allCases where !absentInLegacy.contains(signal) {
            #expect(SignalSchema.legacy.key(for: signal) != nil, "legacy 缺少 \(signal.rawValue)")
        }
    }

    @Test("哨兵开关状态读信号 3636")
    func sentinelState() {
        // 数字口径的车：3636 == 1 为开、0 为关，读不到即关（不是所有车都报这一位）。
        #expect(state(["3636": "1"]).sentinelOn == true)
        #expect(state(["3636": "0"]).sentinelOn == false)
        #expect(state(c11).sentinelOn == false)
        // 语义名口径（S01/T03）本来就没有这一位，恒当关，不会误读别的字段。
        #expect(state(["soc": "76", "acSwitch": "false"]).sentinelOn == false)
    }
}

/// 哨兵模式的支持判据。反编译已钉死（`apk-analysis/sentinel-mode-interfaces.md` §4）：
/// 车型不是 S01/T03，且 `permission` 能力码清单含 `"400"`。
///
/// 关键坑：走的是 `permission`，**不是**增程那个 `abilities`——两份是 vehicle/list 上并列、
/// 含义不同的清单，`abilities.contains("39")` 判不了哨兵。范式抄增程判据那组测试。
@Suite("哨兵支持判据")
struct SentinelSupportTests {

    @Test("非 S01/T03 且 permission 含 400 才支持")
    func supportPredicate() {
        // 典型支持车：C11 系，permission 里带 "400"。
        #expect(Vehicle.supportsSentinel(carType: "C11", permission: ["400"]) == true)
        #expect(Vehicle.supportsSentinel(carType: "C10", permission: ["130", "400", "110"]) == true)
        // permission 里没有 "400"：不支持，哪怕车型不在排除名单。
        #expect(Vehicle.supportsSentinel(carType: "C11", permission: ["130", "110"]) == false)
        #expect(Vehicle.supportsSentinel(carType: "C11", permission: []) == false)
        // S01 / T03 官方走白名单硬排除：哪怕 permission 里有 "400" 也恒不支持。
        #expect(Vehicle.supportsSentinel(carType: "S01", permission: ["400"]) == false)
        #expect(Vehicle.supportsSentinel(carType: "T03", permission: ["400"]) == false)
        // 车型判据是前缀匹配（统一走 CarTypeFamily），带年款后缀的 S01/T03 照样排除。
        #expect(Vehicle.supportsSentinel(carType: "T03-2023", permission: ["400"]) == false)
    }

    @Test("老会话缺字段解码后标记 sentinelStale 待重拉")
    func legacySessionMarksStale() throws {
        // 新会话：带 permission / isSentinelSupported，解码后不 stale。
        let fresh = Vehicle(vin: "LFZ63AZ50SD000001", carType: "C11", name: "C11",
                            permission: ["400"], isSentinelSupported: true)
        let encoded = try JSONEncoder().encode(fresh)
        let decoded = try JSONDecoder().decode(Vehicle.self, from: encoded)
        #expect(decoded.isSentinelSupported == true)
        #expect(decoded.permission == ["400"])
        #expect(decoded.sentinelStale == false)

        // 老会话：JSON 里压根没有 isSentinelSupported 键，兜底 false 但标记 stale 待重拉，
        // 避免「支持哨兵」被永久误判成不支持且永不自愈（同 abilitiesStale 那套双保险）。
        let legacyJSON = #"{"vin":"OLD00000000000001","carType":"C11","name":"C11"}"#
        let old = try JSONDecoder().decode(Vehicle.self, from: Data(legacyJSON.utf8))
        #expect(old.isSentinelSupported == false)
        #expect(old.sentinelStale == true)
    }
}

/// 遮阳帘 / 天窗 / 前备箱的支持判据（`apk-analysis/permission-codes-map.md`）：
/// 都看 `permission` 能力码，但**车型排除名单不一样**——S01/T03 的前置白名单里
/// 有遮阳帘的 240、没有天窗 300 和前备箱 131，三条不能抄成同一个样子。
@Suite("车身控制支持判据")
struct BodyControlSupportTests {

    @Test("遮阳帘只看 240，不排除任何车型")
    func sunshadePredicate() {
        #expect(Vehicle.supportsSunshade(permission: ["240"]) == true)
        #expect(Vehicle.supportsSunshade(permission: ["130", "240", "110"]) == true)
        #expect(Vehicle.supportsSunshade(permission: ["130", "110"]) == false)
        #expect(Vehicle.supportsSunshade(permission: []) == false)
    }

    @Test("天窗：非 S01/T03 且含 300")
    func sunroofPredicate() {
        #expect(Vehicle.supportsSunroof(carType: "C11", permission: ["300"]) == true)
        #expect(Vehicle.supportsSunroof(carType: "C11", permission: ["240"]) == false)
        #expect(Vehicle.supportsSunroof(carType: "S01", permission: ["300"]) == false)
        #expect(Vehicle.supportsSunroof(carType: "T03", permission: ["300"]) == false)
        // 前缀匹配，带年款后缀照样排除（同哨兵那条的规矩）。
        #expect(Vehicle.supportsSunroof(carType: "T03-2023", permission: ["300"]) == false)
    }

    @Test("前备箱：非 S01/T03 且含 131")
    func frunkPredicate() {
        #expect(Vehicle.supportsFrunk(carType: "C11", permission: ["131"]) == true)
        #expect(Vehicle.supportsFrunk(carType: "C10", permission: ["131", "400"]) == true)
        #expect(Vehicle.supportsFrunk(carType: "C11", permission: ["130"]) == false)
        #expect(Vehicle.supportsFrunk(carType: "S01", permission: ["131"]) == false)
        #expect(Vehicle.supportsFrunk(carType: "T03", permission: ["131"]) == false)
    }
}

/// 演示车换成 C11 数字口径之后的自检：signalMap 换了一整套键，
/// 哪个键写错了界面就是整块空白，靠人眼过一遍太容易漏。
@Suite("演示车况")
struct ReviewDemoStateTests {

    @Test("演示车八个控制全亮")
    func demoVehicleSupportsAll() {
        let vehicle = ReviewDemo.session.vehicles[0]
        #expect(CarTypeFamily.isLegacyFamily(vehicle.carType) == false)
        #expect(vehicle.isSentinelSupported == true)
        #expect(Vehicle.supportsSunshade(permission: vehicle.permission) == true)
        #expect(Vehicle.supportsSunroof(carType: vehicle.carType, permission: vehicle.permission) == true)
        #expect(Vehicle.supportsFrunk(carType: vehicle.carType, permission: vehicle.permission) == true)
    }

    @Test("演示车况按数字口径读得出核心字段")
    func demoStateReadsUnderNumericSchema() {
        let state = ReviewDemo.vehicleState
        #expect(state.schema.id == "numeric")
        #expect(state.soc == 76)
        #expect(state.expectedMileage == 312)
        #expect(state.chargeLimit == 90)
        #expect(state.isLocked == true)
        #expect(state.trunkOpen == false)
        #expect(state.frontTrunkOpen == false)
        #expect(state.sentinelOn == false)
        #expect(state.isDriving == false)
        #expect(state.acOn == false)
        #expect(state.indoorTemp == 33)
        #expect(state.shareableCoordinate != nil)
        // 前两扇窗微开 10%，数字口径是正向刻度。
        #expect(state.leftFrontWindow == 10)
        #expect(state.leftFrontWindowOpen == true)
        #expect(state.leftRearWindowOpen == false)
        #expect(state.anyWindowOpen == true)
        #expect(state.windowsRemoteSupported == true)
    }
}

/// 车端采集时刻的解析。
///
/// 这个值决定首页那句「车况刚刚更新」到底说的是什么：车休眠着不上报时，服务端会把
/// 同一份旧数据一直发回来，只有它能看出车况有多旧。解析错了比读不到更糟——
/// 读不到会退回本机拉取时间并改口说「读取」，解析错了则会拿一个假时刻冒充车端时刻。
@Suite("车端采集时刻")
struct ReportTimeTests {

    private let now = Date(timeIntervalSince1970: 1_785_900_000)

    @Test("字面时间按本机时区解释")
    func literalTime() throws {
        let calendar = Calendar.current
        let expected = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 5, hour: 9, minute: 40, second: 12
        )))
        // 参考时刻跟随本机时区构造，避免 CI 使用 UTC 时把本地字面时间误判成未来。
        let parsed = try #require(VehicleState.parseReportTime(
            "2026-08-05 09:40:12",
            now: expected.addingTimeInterval(60)
        ))
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: parsed
        )
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 5)
        #expect(parts.hour == 9)
        #expect(parts.minute == 40)
        #expect(parts.second == 12)
    }

    @Test("日期和时间之间是 T、秒带小数、秒缺省，都认")
    func literalVariants() {
        let base = VehicleState.parseReportTime("2026-08-05 09:40:12", now: now)
        #expect(VehicleState.parseReportTime("2026-08-05T09:40:12", now: now) == base)
        #expect(VehicleState.parseReportTime("2026-08-05 09:40:12.480", now: now) == base)
        #expect(VehicleState.parseReportTime("2026-08-05 09:40", now: now)
            == VehicleState.parseReportTime("2026-08-05 09:40:00", now: now))
    }

    @Test("十位数当秒、十三位数当毫秒")
    func epochScale() {
        let seconds = VehicleState.parseReportTime("1785899000", now: now)
        let millis = VehicleState.parseReportTime("1785899000000", now: now)
        #expect(seconds == Date(timeIntervalSince1970: 1_785_899_000))
        #expect(seconds == millis)
    }

    @Test("解析不出来的一律当读不到，不返回 1970")
    func rejectsGarbage() {
        #expect(VehicleState.parseReportTime("", now: now) == nil)
        #expect(VehicleState.parseReportTime("   ", now: now) == nil)
        #expect(VehicleState.parseReportTime("0", now: now) == nil)
        #expect(VehicleState.parseReportTime("--", now: now) == nil)
        #expect(VehicleState.parseReportTime("2026-08-05", now: now) == nil)
    }

    @Test("落在三十天前到五分钟后之外的不可信")
    func rejectsOutOfWindow() {
        // 车端时钟比手机快一点很常见，五分钟以内照收。
        #expect(VehicleState.parseReportTime("1785900100", now: now) != nil)
        #expect(VehicleState.parseReportTime("1785900600", now: now) == nil)
        #expect(VehicleState.parseReportTime("1783400000", now: now) != nil)
        #expect(VehicleState.parseReportTime("1780000000", now: now) == nil)
    }
}
