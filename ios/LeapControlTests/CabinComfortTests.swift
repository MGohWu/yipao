import Foundation
import Testing
@testable import LeapControl

/// 舒适座舱（座椅加热/通风、方向盘加热、后视镜加热）与车载冰箱。
///
/// 这一层的信号断言不是纸面推断：下面那份 `c16` 取自一台 C16 的真实车况抓包
/// （采样时座舱功能全关），
/// 八个座椅信号、方向盘的 1816/1624、后视镜的 49/50/1946 在那份响应里逐个在场，
/// 而九个冰箱信号一个都没有——「这台车没装冰箱」就是这么判出来的。
@Suite("舒适座舱")
struct CabinComfortTests {

    /// 一台 C16 真实 signalMap 的节选（经纬度已替换成示例值，其余原样）。
    private let c16: [String: String] = [
        "1": "1786972478598",
        "100003": "90.6",
        "1204": "91",
        // 座椅八项，采样时全关
        "2100": "0", "2101": "0",
        "2118": "0", "2119": "0",
        "1879": "0", "3727": "0",
        "1880": "0", "3728": "0",
        // 方向盘：加热关着（1816=0），但剩余分钟（1624）是 15——这就是那个坑
        "1816": "0", "1624": "15",
        // 后视镜 + 后风挡
        "49": "0", "50": "0", "1946": "0",
        // 空调那几项，顺带验 1943 / 2669 / 2681
        "1938": "0", "1943": "1", "2669": "0", "2681": "0", "3713": "1",
        // 经纬度三组同时在场
        "2": "120.215527", "3": "30.246109",
        "2190": "120.210028", "2191": "30.247968",
        "3724": "120.210009", "3725": "30.24797",
        "sts": "1786972478119"
    ]

    /// C16「小灰灰」实测 abilities（同 `VehicleCapabilityTests`）：含 21/42/43/59，**不含 76**。
    private let c16Abilities = ["1","2","3","5","6","7","10","11","12","13","14","15","19","20","21",
        "22","23","24","29","30","31","32","34","35","38","39","41","42","43","45","46","47","48","49",
        "50","51","52","53","55","56","57","58","59","60","61","65","66","67","68","71","72","73","74",
        "75","82","87","88","89"]

    private func state(_ pairs: [String: String]) -> VehicleState {
        var state = VehicleState()
        state.signalMap = pairs
        state.schema = SignalSchema.detect(pairs)
        return state
    }

    private func json(_ raw: String) -> [String: Any] {
        let data = Data(raw.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - 信号映射

    @Test("八个座椅档位都能从真实车况里读出来")
    func readsAllSeatSignals() {
        var pairs = c16
        pairs["2100"] = "3"   // 主驾加热 3 档
        pairs["2119"] = "2"   // 副驾通风 2 档
        pairs["1879"] = "1"   // 二排左加热 1 档
        pairs["3728"] = "3"   // 二排右通风 3 档
        let s = state(pairs)

        #expect(s.seatLevel(.driver, .heating) == 3)
        #expect(s.seatLevel(.passenger, .ventilation) == 2)
        #expect(s.seatLevel(.leftRear, .heating) == 1)
        #expect(s.seatLevel(.rightRear, .ventilation) == 3)
        // 没动过的仍是 0，不是 nil——车报了 0 和车没报是两件事
        #expect(s.seatLevel(.driver, .ventilation) == 0)
        #expect(s.hasSeatComfort)
        #expect(s.hasRearSeatComfort)
        #expect(s.hasCabinComfort)
    }

    @Test("车况没报这个座位就返回 nil，不退 0")
    func missingSeatSignalIsNil() {
        // 只有前排的车（C11 那类 5 座）：二排四个信号整片缺席
        var pairs = c16
        for key in ["1879", "3727", "1880", "3728"] { pairs[key] = nil }
        let s = state(pairs)

        #expect(s.seatLevel(.leftRear, .heating) == nil)
        #expect(s.seatLevel(.rightRear, .ventilation) == nil)
        #expect(!s.hasRearSeatComfort)
        // 前排照常
        #expect(s.seatLevel(.driver, .heating) == 0)
        #expect(s.seats(with: .heating) == SeatPosition.front)
    }

    @Test("老口径（S01/T03）一项都读不到，整页该被门控挡掉")
    func legacySchemaHasNoCabinSignals() {
        let s = state(["soc": "76", "acSwitch": "false", "acCircleMode": "true"])
        #expect(s.schema == .legacy)
        #expect(!s.hasCabinComfort)
        #expect(s.steeringWheelHeatLevel == nil)
        #expect(s.mirrorHeatingOn == nil)
        #expect(s.fridgeState == nil)
    }

    @Test("档位超出值域时夹取，不把脏值透出去")
    func clampsSeatLevel() {
        var pairs = c16
        pairs["2100"] = "9"
        pairs["2101"] = "-2"
        let s = state(pairs)
        #expect(s.seatLevel(.driver, .heating) == 3)
        #expect(s.seatLevel(.driver, .ventilation) == 0)
    }

    // MARK: - 方向盘那个坑

    @Test("方向盘加热关着时不给剩余分钟")
    func steeringMinutesHiddenWhenOff() {
        // 这就是真车那一帧：1816=0（没开）而 1624=15。
        // 拿 1624 当「正在加热」的佐证会在界面上凭空报出一个加热中。
        let s = state(c16)
        #expect(s.steeringWheelHeatLevel == 0)
        #expect(s.steeringWheelHeatMinutes == nil)
    }

    @Test("方向盘加热开着才给剩余分钟")
    func steeringMinutesShownWhenOn() {
        var pairs = c16
        pairs["1816"] = "2"
        let s = state(pairs)
        #expect(s.steeringWheelHeatLevel == 2)
        #expect(s.steeringWheelHeatMinutes == 15)
    }

    @Test("方向盘档位只到 2，不按座椅的三档读")
    func steeringLevelClampsToTwo() {
        var pairs = c16
        pairs["1816"] = "3"
        #expect(state(pairs).steeringWheelHeatLevel == 2)
    }

    // MARK: - 后视镜

    @Test("两侧任一为开即算开，且能看出左右不一致")
    func mirrorHeatingReadsBothSides() {
        var pairs = c16
        pairs["49"] = "1"
        let s = state(pairs)
        #expect(s.mirrorHeatingOn == true)
        #expect(s.mirrorHeatingMismatched)

        pairs["50"] = "1"
        let both = state(pairs)
        #expect(both.mirrorHeatingOn == true)
        #expect(!both.mirrorHeatingMismatched)
    }

    @Test("两侧都读不到就是 nil")
    func mirrorHeatingMissingIsNil() {
        var pairs = c16
        pairs["49"] = nil
        pairs["50"] = nil
        #expect(state(pairs).mirrorHeatingOn == nil)
    }

    // MARK: - 冰箱

    @Test("车主那台 C16 读不到冰箱，整块该隐藏")
    func fridgeAbsentOnOwnerCar() {
        // 真实抓包里九个冰箱信号一个都没有，只有 11260（离车保温截止时间）在、值为 0。
        #expect(state(c16).fridgeState == nil)
        #expect(state(c16.merging(["11260": "0"]) { _, new in new }).fridgeState == nil)
    }

    @Test("装了冰箱的车能完整解析状态")
    func fridgeStateParses() {
        let pairs = c16.merging([
            "10709": "1",       // 开机
            "10708": "1",       // 保温
            "10707": "50",
            "10711": "1",       // 急速
            "10712": "0",
            "11190": "1",       // 离车保持开
            "11189": "3",
            "11260": "1786980000"
        ]) { _, new in new }

        let fridge = state(pairs).fridgeState
        #expect(fridge?.enabled == true)
        #expect(fridge?.mode == .hot)
        #expect(fridge?.style == .turbo)
        #expect(fridge?.hasFault == false)
        #expect(fridge?.parkEnabled == true)
        #expect(fridge?.parkHours == 3)
        #expect(fridge?.parkEndsAt == Date(timeIntervalSince1970: 1786980000))
    }

    @Test("故障码非 0 要能看出来")
    func fridgeFaultSurfaces() {
        let pairs = c16.merging(["10709": "1", "10712": "3"]) { _, new in new }
        #expect(state(pairs).fridgeState?.hasFault == true)
        #expect(state(pairs).fridgeState?.fault == 3)
    }

    @Test("截止时间为 0 当没有，不显示一个 1970 年")
    func fridgeParkEndZeroIsNil() {
        let pairs = c16.merging(["10709": "1", "11260": "0"]) { _, new in new }
        #expect(state(pairs).fridgeState?.parkEndsAt == nil)
    }

    // MARK: - 指令

    @Test("座椅加热走 301、通风走 370，position 和 level 都是字符串")
    func seatCommands() {
        let heat = LeapCommand.seatComfort(position: .driver, channel: .heating, level: 3)
        #expect(heat.cmdid == "301")
        #expect(json(heat.stateJSON)["position"] as? String == "left_front")
        #expect(json(heat.stateJSON)["level"] as? String == "3")
        #expect(heat.label == "主驾加热 3 档")

        let vent = LeapCommand.seatComfort(position: .rightRear, channel: .ventilation, level: 0)
        #expect(vent.cmdid == "370")
        #expect(json(vent.stateJSON)["position"] as? String == "right_rear")
        #expect(json(vent.stateJSON)["level"] as? String == "0")
        #expect(vent.label == "二排右通风关闭")
    }

    @Test("四个 position 字面量和协议一致")
    func seatPositionWireValues() {
        #expect(SeatPosition.driver.wireValue == "left_front")
        #expect(SeatPosition.passenger.wireValue == "right_front")
        #expect(SeatPosition.leftRear.wireValue == "left_rear")
        #expect(SeatPosition.rightRear.wireValue == "right_rear")
    }

    @Test("方向盘走 320，level 是 JSON 数字不是字符串")
    func steeringCommand() {
        let command = LeapCommand.steeringWheelHeating(level: 2)
        #expect(command.cmdid == "320")
        // leapauto 的代码发数字、它自己的文档写字符串，按代码走（见构造器注释）。
        // 这条断言的作用是：真车不认时改成字符串，这里会立刻红掉，提醒同步文档。
        #expect(command.stateJSON == #"{"level":2}"#)
        #expect(json(command.stateJSON)["level"] as? Int == 2)
        #expect(command.label == "方向盘加热强档")
    }

    @Test("后视镜走 440，开 2 关 1——不是 1/0")
    func mirrorCommand() {
        #expect(LeapCommand.mirrorHeating(on: true).cmdid == "440")
        #expect(json(LeapCommand.mirrorHeating(on: true).stateJSON)["value"] as? String == "2")
        #expect(json(LeapCommand.mirrorHeating(on: false).stateJSON)["value"] as? String == "1")
    }

    @Test("冰箱走 500，八个字段一次发全")
    func fridgeCommandIsFullState() {
        let command = LeapCommand.fridge(FridgeSetting())
        #expect(command.cmdid == "500")
        let payload = json(command.stateJSON)
        #expect(payload.count == 8)
        #expect(payload["enable"] as? Int == 1)
        #expect(payload["mode"] as? String == "cold")
        #expect(payload["temp"] as? Int == 4)
        #expect(payload["style"] as? String == "normal")
        #expect(payload["parkEnable"] as? Int == 0)
        #expect(payload["duration"] as? Int == 3600)
        #expect(payload["cycles"] as? String == "1")
        #expect(payload["value"] as? String == "false")
    }

    @Test("保温模式下发 50 ℃，但不弄丢用户调过的制冷温度")
    func fridgeHotModeSendsFixedTemp() {
        var setting = FridgeSetting()
        setting.temperature = -6
        setting.apply(.keepWarm)
        #expect(setting.mode == .hot)
        #expect(setting.wireTemperature == 50)
        // 切回制冷时还是 −6，不是被 50 盖掉
        setting.apply(.chill)
        #expect(setting.temperature == 4)
        var frozen = FridgeSetting()
        frozen.apply(.freeze)
        frozen.apply(.keepWarm)
        frozen.mode = .cold
        #expect(frozen.temperature == -6)
    }

    @Test("离车时长低于半小时被抬到 1800 秒")
    func fridgeDurationFloor() {
        var setting = FridgeSetting()
        setting.parkHours = 0
        #expect(setting.durationSeconds == FridgeSetting.minDurationSeconds)
        setting.parkHours = 3
        #expect(setting.durationSeconds == 10800)
    }

    @Test("三个预设按模式 + 温度回落")
    func fridgePresetMatching() {
        #expect(FridgePreset.matching(mode: .cold, temperature: 4) == .chill)
        #expect(FridgePreset.matching(mode: .cold, temperature: -6) == .freeze)
        #expect(FridgePreset.matching(mode: .hot, temperature: 50) == .keepWarm)
        // 手动拖到中间温度：三个预设都不该高亮
        #expect(FridgePreset.matching(mode: .cold, temperature: 8) == nil)
    }

    @Test("制冷温度夹到协议量程 −6…15")
    func fridgeTempClamp() {
        var setting = FridgeSetting()
        setting.temperature = 40
        #expect(setting.wireTemperature == 15)
        setting.temperature = -40
        #expect(setting.wireTemperature == -6)
    }

    // MARK: - 车况确认

    @Test("座椅档位翻到位才算确认")
    func seatExpectation() {
        let expectation = ControlExpectation.seatLevel(position: .driver, channel: .heating, level: 2)
        #expect(!expectation.isSatisfied(by: state(c16)))
        #expect(expectation.isSatisfied(by: state(c16.merging(["2100": "2"]) { _, new in new })))
        // 只到 1 档不算
        #expect(!expectation.isSatisfied(by: state(c16.merging(["2100": "1"]) { _, new in new })))
        // 读不到这个座位也不算（宁可报「未收到确认」，不凭空判成功）
        var missing = c16
        missing["2100"] = nil
        #expect(!expectation.isSatisfied(by: state(missing)))
    }

    @Test("后视镜三个候选位任一翻到位就算确认")
    func mirrorExpectationAcceptsAnySignal() {
        let expectation = ControlExpectation.mirrorHeating(true)
        #expect(!expectation.isSatisfied(by: state(c16)))
        // 只有 49 翻了
        #expect(expectation.isSatisfied(by: state(c16.merging(["49": "1"]) { _, new in new })))
        // 只有 1946 翻了——cmdid 440 到底动哪个没验过，所以这个也接受
        #expect(expectation.isSatisfied(by: state(c16.merging(["1946": "1"]) { _, new in new })))
    }

    @Test("冰箱确认：开关必比，车端没报的项跳过")
    func fridgeExpectation() {
        var setting = FridgeSetting()
        setting.style = .turbo
        let expectation = ControlExpectation.fridge(setting)

        // 冰箱整个读不到 → 不算确认
        #expect(!expectation.isSatisfied(by: state(c16)))

        // 开关对上、模式温度风格也对上
        let ok = c16.merging([
            "10709": "1", "10708": "0", "10707": "4", "10711": "1"
        ]) { _, new in new }
        #expect(expectation.isSatisfied(by: state(ok)))

        // 目标温度车端没报 → 跳过这一项，不作否决（同空调那条宽松判法）
        var noTemp = ok
        noTemp["10707"] = nil
        #expect(expectation.isSatisfied(by: state(noTemp)))

        // 温度报了但对不上 → 不算
        let wrongTemp = ok.merging(["10707": "9"]) { _, new in new }
        #expect(!expectation.isSatisfied(by: state(wrongTemp)))
    }

    @Test("关机只比开关，不比模式温度")
    func fridgeOffExpectationIgnoresSettings() {
        var setting = FridgeSetting()
        setting.enabled = false
        let expectation = ControlExpectation.fridge(setting)
        let off = c16.merging(["10709": "0", "10708": "1", "10707": "50"]) { _, new in new }
        #expect(expectation.isSatisfied(by: state(off)))
    }

    // MARK: - 能力码门控

    @Test("C16 的 abilities 翻出座舱三项，翻不出冰箱")
    func abilitiesTranslateCabinCodes() {
        let permission = Vehicle.permissionCodes(fromAbilities: c16Abilities)
        #expect(permission.contains("301"))   // 21 → 座椅加热
        #expect(permission.contains("370"))   // 42/43 → 座椅通风
        #expect(permission.contains("440"))   // 59 → 后视镜加热
        #expect(!permission.contains("500"))  // 不含 76 → 没装冰箱

        #expect(Vehicle.supportsCabinComfort(carType: "C16", permission: permission))
        #expect(!Vehicle.supportsFridge(carType: "C16", permission: permission))
    }

    @Test("S01 / T03 一律排除，哪怕服务端下发了能力码")
    func legacyCarsExcluded() {
        let permission = ["301", "370", "440", "500"]
        #expect(!Vehicle.supportsCabinComfort(carType: "S01", permission: permission))
        #expect(!Vehicle.supportsCabinComfort(carType: "T03", permission: permission))
        #expect(!Vehicle.supportsFridge(carType: "S01", permission: permission))
        // 带年款后缀也要挡住（前缀匹配，和下发那边口径一致）
        #expect(!Vehicle.supportsCabinComfort(carType: "T03-2023", permission: permission))
    }

    @Test("能力码里一条都没有就不给入口")
    func noCabinCodesNoEntry() {
        #expect(!Vehicle.supportsCabinComfort(carType: "C11", permission: ["400", "240"]))
    }

    // MARK: - 顺手修掉的三处

    @Test("经纬度优先读 3724/3725，不再读偏 500 米的 2/3")
    func locationPrefersVerifiedSignals() {
        let s = state(c16)
        // 三组同时在场时取官方那一路
        #expect(s.longitude == 120.210009)
        #expect(s.latitude == 30.24797)

        // 只报老那组的车仍然显示位置，不至于整块空掉
        var onlyLegacyPair = c16
        for key in ["3724", "3725", "2190", "2191"] { onlyLegacyPair[key] = nil }
        #expect(state(onlyLegacyPair).longitude == 120.215527)
        #expect(state(onlyLegacyPair).latitude == 30.246109)
    }

    @Test("内外循环在数字口径上终于能读到（信号 1943）")
    func recirculationReadable() {
        #expect(state(c16).acCircleIn == true)
        #expect(state(c16.merging(["1943": "0"]) { _, new in new }).acCircleIn == false)
    }

    @Test("快速降温 / 快速制热状态位可读（2669 / 2681）")
    func rapidStatesReadable() {
        let on = c16.merging(["2669": "1", "2681": "0"]) { _, new in new }
        #expect(state(on).rapidCoolingOn == true)
        #expect(state(on).rapidHeatingOn == false)
    }

    @Test("前挡除雾改走外循环、只吹前挡")
    func defrostUsesOutsideAirAndWindshieldVent() {
        let state = LeapCommand.defrost().stateJSON
        let payload = json(state)
        // 内循环是反的：除雾要把干燥外气引进来
        #expect(payload["circle"] as? String == "out")
        // 出风位置不再是全车
        #expect(payload["position"] as? String == "wshld")
        #expect(payload["wshld"] as? String == "1")
        // 温度和模式故意不跟第三方那条 24 ℃ 制冷，保留热风（见构造器注释）
        #expect(payload["mode"] as? String == "hot")
        #expect(payload["temperature"] as? String == "32")
    }

    @Test("普通开空调仍然是全车出风，没被除雾那条带歪")
    func normalClimateStillAllVents() {
        let command = LeapCommand.climate(
            on: true, temperature: 24, fanLevel: 3, mode: .cold, circleIn: true, windshield: false
        )
        let payload = json(command.stateJSON)
        #expect(payload["position"] as? String == "all")
        #expect(payload["circle"] as? String == "in")
        #expect(payload["wshld"] as? String == "0")
    }
}
