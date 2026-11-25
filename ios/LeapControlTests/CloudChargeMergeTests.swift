import Foundation
import Testing

@testable import LeapControl

/// 云端充电记录的解析与合并。
///
/// 最要紧的一条：**别把同一次充电记两遍**。云端那条和本机那条时间几乎完全重叠，
/// 合并时认不出来就会在列表里出现两次，电量合计直接翻倍。
@Suite("云端充电记录")
struct CloudChargeMergeTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func ms(_ date: Date) -> JSONValue {
        .number(date.timeIntervalSince1970 * 1000)
    }

    private func row(
        start: Date, minutes: Double, energy: Double? = 20,
        type: String = "SLOW", lat: Double? = nil, lon: Double? = nil
    ) -> [String: JSONValue] {
        var row: [String: JSONValue] = [
            "vin": .string("V"),
            "chargeGunStartTs": ms(start),
            "chargeGunEndTs": ms(start.addingTimeInterval(minutes * 60))
        ]
        if let energy { row["chargeInEnergy"] = .number(energy) }
        row["chargeType"] = .string(type)
        if let lat { row["chargeStartLatitude"] = .number(lat) }
        if let lon { row["chargeStartLongitude"] = .number(lon) }
        return row
    }

    // MARK: - 解析

    @Test("度数、快慢充、地点都解析出来")
    func parsesTheOfficialFields() throws {
        let parsed = try #require(CloudChargeParser.record(
            from: row(start: t0, minutes: 55, energy: 32.4, type: "FAST",
                      lat: 30.18682, lon: 120.19551),
            vin: "V"
        ))
        #expect(parsed.startAt == t0)
        #expect(parsed.duration == 55 * 60)
        #expect(parsed.energyKwh == 32.4)
        #expect(parsed.isDC, "FAST 是直流快充")
        #expect(parsed.latitude == 30.18682)
    }

    @Test("SLOW 是慢充；1 / 2 那套老写法也认")
    func understandsChargeType() throws {
        let slow = try #require(CloudChargeParser.record(
            from: row(start: t0, minutes: 120, type: "SLOW"), vin: "V"))
        #expect(slow.isDC == false)
        let old = try #require(CloudChargeParser.record(
            from: row(start: t0, minutes: 30, type: "2"), vin: "V"))
        #expect(old.isDC)
    }

    @Test("几十秒的记录是插枪握手，不算一次充电")
    func handshakeIsDropped() {
        #expect(CloudChargeParser.record(from: row(start: t0, minutes: 0.5), vin: "V") == nil)
    }

    @Test("缺起止时间的记录直接丢，不猜")
    func missingTimestampsAreDropped() {
        let broken: [String: JSONValue] = ["vin": .string("V"), "chargeInEnergy": .number(20)]
        #expect(CloudChargeParser.record(from: broken, vin: "V") == nil)
    }

    // MARK: - 合并

    @Test("云端有、本机没有的那一次，补进列表")
    func cloudOnlyChargeIsAdded() {
        let cloud = CloudChargeParser.records(
            from: [row(start: t0, minutes: 40, energy: 18, lat: 30.1, lon: 120.2)], vin: "V"
        )
        let result = CloudChargeMerge.merge(local: [], cloud: cloud, window: window())
        #expect(result.added == 1)
        let charge = result.charges[0]
        #expect(charge.isOfficial)
        #expect(charge.energyKwh == 18)
        #expect(charge.coordinate != nil, "云端带充电地点")
        #expect(charge.startSoc == nil, "起止电量云端不给")
    }

    @Test("同一次充电认出来：度数用官方的，起止电量和地名不能丢")
    func matchedChargeKeepsLocalDetail() throws {
        let local = ChargeRecord(
            vin: "V", startAt: t0, endAt: t0.addingTimeInterval(40 * 60),
            startSoc: 32, endSoc: 71, energyKwh: 17.2, maxPowerKw: 6.8,
            isDC: false, place: "杭州·滨江"
        )
        let cloud = CloudChargeParser.records(
            from: [row(start: t0, minutes: 41, energy: 18)], vin: "V"
        )
        let result = CloudChargeMerge.merge(local: [local], cloud: cloud, window: window())

        #expect(result.matched == 1)
        #expect(result.added == 0, "认出来了就不能再补一条")
        let charge = try #require(result.charges.first)
        #expect(charge.energyKwh == 18)
        #expect(charge.socGain == 39, "本机看到的电量差要留着")
        #expect(charge.maxPowerKw == 6.8)
        #expect(charge.place == "杭州·滨江")
        #expect(charge.officialKey != nil)
    }

    @Test("补记被官方那次覆盖了就让位，不能两次都算")
    func reconstructionYieldsToOfficial() {
        let reconstructed = ChargeRecord(
            startAt: t0, endAt: t0.addingTimeInterval(2 * 3600),
            energyKwh: 40, isReconstructed: true
        )
        let cloud = CloudChargeParser.records(
            from: [row(start: t0, minutes: 110, energy: 38)], vin: "V"
        )
        let result = CloudChargeMerge.merge(local: [reconstructed], cloud: cloud, window: window())
        #expect(result.dropped == 1)
        #expect(result.charges.count == 1)
        #expect(result.charges[0].isOfficial)
    }

    @Test("补记只被覆盖了一小部分时留着")
    func partialCoverageKeepsReconstruction() {
        let reconstructed = ChargeRecord(
            startAt: t0, endAt: t0.addingTimeInterval(4 * 3600),
            energyKwh: 45, isReconstructed: true
        )
        let cloud = CloudChargeParser.records(
            from: [row(start: t0.addingTimeInterval(3600), minutes: 30, energy: 10)], vin: "V"
        )
        let result = CloudChargeMerge.merge(local: [reconstructed], cloud: cloud, window: window())
        #expect(result.dropped == 0)
        #expect(result.charges.contains { $0.isReconstructed })
    }

    @Test("同步两次结果一样")
    func mergeIsIdempotent() {
        let cloud = CloudChargeParser.records(
            from: [row(start: t0, minutes: 40, energy: 18)], vin: "V"
        )
        let first = CloudChargeMerge.merge(local: [], cloud: cloud, window: window())
        let second = CloudChargeMerge.merge(local: first.charges, cloud: cloud, window: window())
        #expect(second.added == 0)
        #expect(second.charges.count == first.charges.count)
        #expect(second.charges.first?.id == first.charges.first?.id)
    }

    private func window() -> ClosedRange<Date> {
        t0.addingTimeInterval(-31 * 86_400)...t0.addingTimeInterval(86_400)
    }
}
