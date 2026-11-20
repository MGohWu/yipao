import Foundation
import Testing
@testable import LeapControl

/// 对照 leapauto 第三轮补的三件事：快速除味、首页天窗 / 遮阳帘徽章用到的读数、锁车后顺带检查。
@Suite("对照 leapauto 第三轮")
struct LeapautoGapRound3Tests {

    private let base: [String: String] = ["1204": "80", "1318": "1000", "sts": "1"]

    private func with(_ extra: [String: String]) -> VehicleState {
        var state = VehicleState()
        state.signalMap = base.merging(extra) { _, new in new }
        state.schema = SignalSchema.detect(state.signalMap)
        return state
    }

    private func json(_ raw: String) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: String] ?? [:]
    }

    /// 四扇窗、四扇门、尾门、前备箱全关的底子（数字口径）。
    private let allClosed: [String: String] = [
        "1693": "0", "1694": "0", "1695": "0", "1696": "0",
        "644": "0", "645": "0", "865": "0", "866": "0",
        "1277": "0", "1278": "0", "1279": "0", "1280": "0",
        "1281": "0", "1282": "0"
    ]

    private func closed(_ extra: [String: String]) -> VehicleState {
        with(allClosed.merging(extra) { _, new in new })
    }

    // MARK: - 快速除味

    @Test("快速除味照 leapauto 发：通风 + 外循环 + 7 档 + 不开除雾")
    func deodorizePayload() {
        let command = LeapCommand.deodorize()
        #expect(command.cmdid == "170")
        #expect(command.label == "快速除味")
        let state = json(command.stateJSON)
        #expect(state["operate"] == "manual")
        #expect(state["mode"] == "nohotcold")
        #expect(state["circle"] == "out")
        #expect(state["windlevel"] == "7")
        #expect(state["wshld"] == "0")
        #expect(state["position"] == "all")
    }

    @Test("快速除味的判据不比温度——车保留原设定温度时不能误报未确认")
    func deodorizeIgnoresTemperature() {
        #expect(LeapCommand.deodorize().expectation == .climate(on: true, temperature: nil, fanLevel: 7, mode: .vent))
    }

    // MARK: - 锁车后顺带检查

    @Test("全关好时没有提醒")
    func nothingOpen() {
        #expect(closed([:]).openItemsAfterLock.isEmpty)
    }

    @Test("车况读不到车窗车门时不提醒——不知道不等于开着")
    func unreadableIsNotOpen() {
        #expect(with([:]).openItemsAfterLock.isEmpty)
    }

    @Test("单扇窗开着点名是哪一扇：状态位或开度任一说开就算")
    func singleWindowNamed() {
        #expect(closed(["1696": "2"]).openItemsAfterLock == ["右后车窗"])
        // 状态位说关、开度说开（T03 那次的真实情形）也要报
        #expect(closed(["866": "30"]).openItemsAfterLock == ["右后车窗"])
        #expect(closed(["1693": "2", "1694": "2"]).openItemsAfterLock == ["主驾车窗", "副驾车窗"])
    }

    @Test("四扇都开合成一个「车窗」")
    func allWindowsMerged() {
        let open = closed(["1693": "2", "1694": "2", "1695": "2", "1696": "2"])
        #expect(open.openItemsAfterLock == ["车窗"])
    }

    @Test("天窗、尾门、前备箱、车门都在检查范围内，遮阳帘不在")
    func otherItems() {
        #expect(closed(["1718": "10", "1281": "1"]).openItemsAfterLock == ["天窗", "尾门"])
        #expect(closed(["1282": "1"]).openItemsAfterLock == ["前备箱"])
        #expect(closed(["1277": "1"]).openItemsAfterLock == ["车门"])
        // 遮阳帘开着不是隐患
        #expect(closed(["1724": "100"]).openItemsAfterLock.isEmpty)
        // 天窗占位值当读不到
        #expect(closed(["1718": "150"]).openItemsAfterLock.isEmpty)
    }
}
