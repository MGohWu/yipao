import Foundation
import Testing
@testable import LeapControl

@Suite("中卡片续航")
struct WidgetRangeTests {
    // iPhone 真机节选：2188 停在 254，WLTC 电 114 / 油 365，CLTC 电 150 / 油 433。
    private func state() -> VehicleState {
        var state = VehicleState()
        state.schema = .numeric
        state.isExtendRange = true
        state.signalMap = ["100003": "75", "2188": "254", "3262": "1",
                           "3257": "150", "3256": "433", "3260": "114", "3259": "365"]
        return state
    }

    private func snapshot(_ state: VehicleState) -> VehicleSnapshot {
        VehicleSnapshot.make(state: state, vehicleName: "测试车", locationName: nil)
    }

    @Test("旧主续航不变时中卡仍跟随当前工况的电油续航")
    func followsCurrentRanges() throws {
        var state = state()
        let first = snapshot(state)
        #expect(first.rangeKm == 254)
        #expect(first.mediumRangeText == "电 114 · 油 365 km")
        let decoded = try JSONDecoder().decode(VehicleSnapshot.self, from: JSONEncoder().encode(first))
        #expect(decoded.isExtendRange == true)
        #expect(decoded.mediumRangeText == first.mediumRangeText)
        state.signalMap["3260"] = "110"
        #expect(snapshot(state).mediumRangeText == "电 110 · 油 365 km")
        state.signalMap["3262"] = "0"
        #expect(snapshot(state).mediumRangeText == "电 150 · 油 433 km")
    }

    @Test("增程缺项只显示已知值，零续航有效，两项都缺失不显示旧主续航")
    func missingRanges() {
        var state = state()
        state.signalMap.removeValue(forKey: "3260")
        #expect(snapshot(state).mediumRangeText == "油 365 km")
        state.signalMap["3259"] = "0"
        #expect(snapshot(state).mediumRangeText == "油 0 km")
        state.signalMap.removeValue(forKey: "3259")
        #expect(snapshot(state).hasFuel)
        #expect(snapshot(state).mediumRangeText == nil)
    }

    @Test("纯电忽略冗余油信号，旧快照兼容分项续航")
    func batteryAndLegacySnapshots() throws {
        var state = state()
        state.isExtendRange = false
        #expect(snapshot(state).mediumRangeText == "254 km")
        state.isExtendRange = true
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(state))) as? [String: Any])
        old.removeValue(forKey: "isExtendRange")
        let decoded = try JSONDecoder().decode(VehicleSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.mediumRangeText == "电 114 · 油 365 km")
    }
}
