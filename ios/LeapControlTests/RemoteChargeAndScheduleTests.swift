import Foundation
import Testing
@testable import LeapControl

/// 远程启停充电（193）、解锁充电枪（192）、预约空调（171）、遮阳帘 / 天窗开合确认。
///
/// 协议依据全来自 leapauto 记录的官方抓包。
/// 遮阳帘那组用的是一台 C16 真实车况里的 `1724`。
@Suite("充电控制与预约空调")
struct RemoteChargeAndScheduleTests {

    private func state(_ pairs: [String: String]) -> VehicleState {
        var state = VehicleState()
        state.signalMap = pairs
        state.schema = SignalSchema.detect(pairs)
        return state
    }

    private func json(_ raw: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    }

    /// 数字口径的最小底子：只放一个电量，让 detect 认成 numeric。
    private let base: [String: String] = ["1204": "80", "1318": "1000", "sts": "1"]

    private func with(_ extra: [String: String]) -> VehicleState {
        state(base.merging(extra) { _, new in new })
    }

    // MARK: - 遮阳帘 / 天窗

    @Test("1724 是遮阳帘、1718 才是天窗")
    func sunshadeAndSunroofSignals() {
        // 实测 C16：1724 在（=0，遮阳帘关着），1718 不在（没有可开启天窗）
        let c16 = with(["1724": "0"])
        #expect(c16.sunshadeOpen == false)
        #expect(c16.sunroofOpen == nil)

        #expect(with(["1724": "100"]).sunshadeOpen == true)
        #expect(with(["1718": "10"]).sunroofOpen == true)
        #expect(with(["1718": "0"]).sunroofOpen == false)
    }

    @Test("天窗报 15 / 150 这种占位值当读不到，不当开着")
    func sunroofSNAIsUnknown() {
        #expect(with(["1718": "15"]).sunroofOpen == nil)
        #expect(with(["1718": "150"]).sunroofOpen == nil)
    }

    @Test("车报开度才等确认，不报的车照旧只说已发送")
    func sunshadeObservabilityFollowsCar() {
        // 不报的车如果也等信号，就会每次都误报「未收到车辆确认」
        #expect(LeapCommand.sunshade(open: true).expectation == .unobservable)
        #expect(LeapCommand.sunshade(open: true, observable: true).expectation == .sunshadeOpen(true))
        #expect(LeapCommand.sunroof(open: false, observable: true).expectation == .sunroofOpen(false))

        let expectation = ControlExpectation.sunshadeOpen(true)
        #expect(!expectation.isSatisfied(by: with(["1724": "0"])))
        // 下发的是 "10"，车回报 10 还是 100 都算开
        #expect(expectation.isSatisfied(by: with(["1724": "10"])))
        #expect(expectation.isSatisfied(by: with(["1724": "100"])))
    }

    @Test("下发值没变：遮阳帘开 10 关 0、天窗开 1 关 0")
    func sunshadePayloadUnchanged() {
        #expect(json(LeapCommand.sunshade(open: true, observable: true).stateJSON)["value"] as? String == "10")
        #expect(json(LeapCommand.sunshade(open: false).stateJSON)["value"] as? String == "0")
        #expect(json(LeapCommand.sunroof(open: true).stateJSON)["value"] as? String == "1")
    }

    // MARK: - 启停充电 / 解锁

    @Test("停止充电发 finish，不是 stop")
    func chargingPayload() {
        let start = LeapCommand.charging(start: true)
        let stop = LeapCommand.charging(start: false)
        #expect(start.cmdid == "193")
        #expect(stop.cmdid == "193")
        #expect(json(start.stateJSON)["value"] as? String == "start")
        // 车端 OBC 只认 start / finish，发 stop 服务端照收、车不理
        #expect(json(stop.stateJSON)["value"] as? String == "finish")
        #expect(!start.isAppointment)
    }

    @Test("开始充电要等充电状态报 1")
    func startChargingExpectation() {
        let expectation = ControlExpectation.charging(true)
        #expect(!expectation.isSatisfied(by: with(["1149": "0"])))
        #expect(expectation.isSatisfied(by: with(["1149": "1"])))
        // 读不到充电状态不算确认
        #expect(!expectation.isSatisfied(by: with([:])))
    }

    @Test("停止充电接受 0/2/4/6，故障 3 和仍在充 1 都不算")
    func stopChargingExpectation() {
        let expectation = ControlExpectation.charging(false)
        for value in ["0", "2", "4", "6"] {
            #expect(expectation.isSatisfied(by: with(["1149": value])), "1149=\(value)")
        }
        #expect(!expectation.isSatisfied(by: with(["1149": "1"])))
        #expect(!expectation.isSatisfied(by: with(["1149": "3"])))
    }

    @Test("解锁充电枪：key 是 operation，且确认不了")
    func unlockGun() {
        let command = LeapCommand.unlockChargingGun()
        #expect(command.cmdid == "192")
        #expect(json(command.stateJSON)["operation"] as? String == "unlock")
        // 94 在停充未拔枪时已经是 0，拿它判会假确认，所以老实 unobservable
        #expect(command.expectation == .unobservable)
    }

    // MARK: - 预约空调

    @Test("预约空调走预约端点，字段形态照官方抓包")
    func climateAppointmentPayload() throws {
        var appointment = ClimateAppointment()
        appointment.hour = 7
        appointment.minute = 30
        appointment.days = [1, 3, 0]
        appointment.temperature = 26
        appointment.mode = .hot

        // 2026-11-19 06:00（本地时间）：07:30 还没过，start_time 应该就是今天
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 6)))
        let command = LeapCommand.climateAppointment(appointment, vin: "VIN123", now: now)
        #expect(command.cmdid == "171")
        #expect(command.isAppointment)

        let controls = try #require(json(command.stateJSON)["controls"] as? [[String: Any]])
        #expect(controls.count == 1)
        let item = controls[0]
        #expect(item["on"] as? String == "1")
        #expect(item["operate"] as? String == "manual")
        #expect(item["mode"] as? String == "hot")
        #expect(item["temperature"] as? String == "26")
        // 固定默认值：7 档 / 内循环 / 除雾开 / 全车出风（官方抓包 [681]）
        #expect(item["windlevel"] as? String == "7")
        #expect(item["circle"] as? String == "in")
        #expect(item["wshld"] as? String == "1")
        #expect(item["position"] as? String == "all")
        // days 是整数数组，周日是 0
        #expect(item["days"] as? [Int] == [0, 1, 3])
        #expect(item["start_time"] as? String == "2026-11-19 07:30:00")
        #expect((item["set_id"] as? String)?.hasPrefix("iOS_VIN123_") == true)
    }

    @Test("一次性预约的时间已过就推到明天，不发一个过去的时间")
    func oneShotRollsToTomorrow() throws {
        var appointment = ClimateAppointment()
        appointment.hour = 7
        appointment.minute = 30
        appointment.days = []
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9)))
        let item = try #require((json(LeapCommand.climateAppointment(appointment, vin: "V", now: now).stateJSON)["controls"] as? [[String: Any]])?.first)
        #expect(item["start_time"] as? String == "2026-11-20 07:30:00")
        #expect(item["days"] as? [Int] == [])
    }

    @Test("改已有预约时沿用车上那条的 set_id")
    func keepsExistingSetID() throws {
        var appointment = ClimateAppointment()
        appointment.setID = "android_abc123"
        let item = try #require((json(LeapCommand.climateAppointment(appointment, vin: "V").stateJSON)["controls"] as? [[String: Any]])?.first)
        #expect(item["set_id"] as? String == "android_abc123")
    }

    @Test("取消预约发空 controls，不发 on:0 的预约项")
    func cancelSendsEmptyControls() {
        let command = LeapCommand.cancelClimateAppointment()
        #expect(command.cmdid == "171")
        #expect(command.stateJSON == #"{"controls":[]}"#)
    }

    @Test("回读：data 是 JSON 字符串，解出开着的那条")
    func parsesReadback() throws {
        let raw = #"{"controls":[{"circle":"in","days":[1,3,4],"mode":"hot","on":"1","operate":"manual","position":"all","set_id":"android_x","start_time":"2026-10-22 19:54:00","temperature":"32","update_time":"1","windlevel":"7","wshld":"1"}]}"#
        let controls = try #require(ClimateAppointment.controls(fromAppointmentData: .string(raw)))
        let appointment = try #require(ClimateAppointment.parse(controls: controls))
        #expect(appointment.hour == 19)
        #expect(appointment.minute == 54)
        #expect(appointment.days == [1, 3, 4])
        #expect(appointment.temperature == 32)
        #expect(appointment.mode == .hot)
        #expect(appointment.setID == "android_x")
        #expect(appointment.summary == "每周一、三、四 19:54 · 制热 32 ℃")
    }

    @Test("回读到空 controls 是「没有预约」，解析失败才是「读不到」")
    func emptyVersusUnreadable() {
        // 官方取消后回读 [334] 就是这样
        let empty = ClimateAppointment.controls(fromAppointmentData: .string(#"{"controls":[]}"#))
        #expect(empty?.isEmpty == true)
        #expect(ClimateAppointment.parse(controls: empty ?? []) == nil)
        // 乱码 → nil（读不到），调用方据此报错而不是说「没有预约」
        #expect(ClimateAppointment.controls(fromAppointmentData: .string("not json")) == nil)
        #expect(ClimateAppointment.controls(fromAppointmentData: nil) == nil)
    }

    @Test("只有 on:0 的项不算有预约")
    func disabledItemIsNotAnAppointment() {
        let controls = ClimateAppointment.controls(fromAppointmentData: .string(
            #"{"controls":[{"on":"0","start_time":"2026-10-22 07:00:00","days":[]}]}"#
        )) ?? []
        #expect(ClimateAppointment.parse(controls: controls) == nil)
    }

    // MARK: - 星期编码

    @Test("周日编码是 0，界面顺序周一在前")
    func weekdayEncoding() {
        #expect(AppointmentWeekday.ordered.first?.value == 1)
        #expect(AppointmentWeekday.ordered.last?.value == 0)
        #expect(AppointmentWeekday.ordered.last?.label == "日")
        #expect(!AppointmentWeekday.ordered.contains { $0.value == 7 })
    }

    @Test("星期摘要")
    func weekdaySummary() {
        #expect(AppointmentWeekday.summary([]) == "仅一次")
        #expect(AppointmentWeekday.summary([1, 2, 3, 4, 5]) == "工作日")
        #expect(AppointmentWeekday.summary([6, 0]) == "周末")
        #expect(AppointmentWeekday.summary(Set(0...6)) == "每天")
        #expect(AppointmentWeekday.summary([0, 1]) == "每周一、日")
    }

    @Test("预约预热 161 的周日也跟着发 0")
    func batteryPreheatSundayIsZero() throws {
        let command = LeapCommand.batteryPreheatAppointment(on: true, startTime: .now, days: [0, 6], vin: "V")
        let item = try #require((json(command.stateJSON)["controls"] as? [[String: Any]])?.first)
        #expect(item["days"] as? [Int] == [0, 6])
    }
}
