import Foundation
import Testing

@testable import LeapControl

/// 云端逐趟记录：解析与合并。
///
/// 这一层最容易出的两种错都不会报错、只会悄悄歪掉：把云端的碎片（0 公里、没有电量）当成
/// 一趟行程显示出来，或者同一趟既算了本机那条又算了官方那条——车主看到的里程直接翻倍。
/// 所以字段解析、去重、幂等这三件事都钉在测试里。
@Suite("云端行程记录")
struct CloudTripMergeTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func ms(_ date: Date) -> JSONValue {
        .number(date.timeIntervalSince1970 * 1000)
    }

    private func row(
        start: Date, minutes: Double, km: Double, miles: Double? = nil,
        energy: Double? = nil, maxSpeed: Double? = nil, fuel: Double? = nil
    ) -> [String: JSONValue] {
        var row: [String: JSONValue] = [
            "vin": .string("V"),
            "routeStartTs": ms(start),
            "routeEndTs": ms(start.addingTimeInterval(minutes * 60)),
            "totalMileage": .number(km)
        ]
        if let miles { row["totalMileageInMi"] = .number(miles) }
        if let energy { row["totalEnergy"] = .number(energy) }
        if let maxSpeed { row["maxSpeed"] = .number(maxSpeed) }
        if let fuel { row["driveReevOil"] = .number(fuel) }
        return row
    }

    // MARK: - 解析

    @Test("十一个字段里该用的都用上：时间、距离、度数、最高速、油耗")
    func parsesTheOfficialFields() throws {
        // 12 公里 ≈ 7.5 英里。英里字段带一位小数，比整数公里细。
        let parsed = try #require(CloudTripParser.record(
            from: row(start: t0, minutes: 10, km: 12, miles: 7.5,
                      energy: 1.8, maxSpeed: 96, fuel: 0),
            vin: "V"
        ))
        #expect(parsed.startAt == t0)
        #expect(parsed.endAt == t0.addingTimeInterval(600))
        #expect(abs(parsed.distanceKm - 12.1) < 0.06, "7.5 英里 = 12.07 公里，取一位小数")
        #expect(parsed.energyKWh == 1.8)
        #expect(parsed.maxSpeedKmh == 96)
        #expect(parsed.fuelLitres == 0, "纯电车的油耗字段是 0.0，不是缺字段")
        #expect(parsed.vin == "V")
    }

    /// 万一哪天这个字段装的其实是「带小数的公里」，乘 1.609 会差出六成。
    /// 校验把它们拉回来：换算结果和整数字段差得远，就退回整数字段。
    @Test("英里字段和公里字段对不上时，退回整数公里")
    func milesFieldIsCrossChecked() throws {
        let parsed = try #require(CloudTripParser.record(
            from: row(start: t0, minutes: 80, km: 77, miles: 77),
            vin: "V"
        ))
        #expect(parsed.distanceKm == 77, "77 英里是 124 公里，和 77 公里对不上，不能采信")
    }

    @Test("0 公里又没有电量的记录是云端碎片，直接丢")
    func emptyFragmentIsDropped() {
        let junk = row(start: t0, minutes: 3, km: 0)
        #expect(CloudTripParser.record(from: junk, vin: "V") == nil)
    }

    @Test("0 公里但有电量：增程器在停车状态下发电，要留着")
    func standbyGenerationIsKept() throws {
        let parsed = try #require(CloudTripParser.record(
            from: row(start: t0, minutes: 30, km: 0, energy: 2.4, fuel: 0.8),
            vin: "V"
        ))
        #expect(parsed.distanceKm == 0)
        #expect(parsed.energyKWh == 2.4)
    }

    // MARK: - 合并

    @Test("云端有、本机没有的那一趟，补进列表并且标成官方")
    func cloudOnlyTripIsAdded() {
        let cloud = CloudTripParser.records(
            from: [row(start: t0, minutes: 20, km: 9, energy: 1.4)], vin: "V"
        )
        let result = CloudTripMerge.merge(local: [], cloud: cloud, window: window())
        #expect(result.added == 1)
        let trip = result.trips[0]
        #expect(trip.hasOfficialData)
        #expect(trip.source == .official)
        #expect(trip.distanceKm == 9)
        #expect(trip.energyKWh == 1.4)
        #expect(trip.startCoordinate == nil, "官方记录没有经纬度")
    }

    @Test("同一趟认出来：时间用本机的，距离和度数用官方的，地名不能丢")
    func matchedTripTakesOfficialNumbers() throws {
        var local = TripRecord(
            startAt: t0, endAt: t0.addingTimeInterval(19 * 60), distanceKm: 8.4,
            startSoc: 70, endSoc: 66
        )
        local.startPlace = "滨江·江南大道"
        local.endPlace = "西湖·文一路"
        let cloud = CloudTripParser.records(
            from: [row(start: t0, minutes: 20, km: 9, energy: 1.4)], vin: "V"
        )
        let result = CloudTripMerge.merge(local: [local], cloud: cloud, window: window())

        #expect(result.matched == 1)
        #expect(result.added == 0, "认出来了就不能再补一条，否则同一条路算两次")
        let trip = try #require(result.trips.first)
        #expect(trip.distanceKm == 9)
        #expect(trip.energyKWh == 1.4)
        #expect(trip.duration == 19 * 60, "时间仍用本机看到的那段")
        #expect(trip.startPlace == "滨江·江南大道")
        #expect(trip.officialKey != nil)
    }

    @Test("补记被官方记录覆盖了，就该让位，不能两边都算")
    func reconstructionYieldsToOfficialRecords() {
        // 本机只看到「两小时里里程涨了 20 公里」，官方那边是两趟各 10 公里。
        let reconstructed = TripRecord(
            startAt: t0, endAt: t0.addingTimeInterval(2 * 3600), distanceKm: 20,
            isReconstructed: true
        )
        let cloud = CloudTripParser.records(from: [
            row(start: t0, minutes: 50, km: 10, energy: 1.6),
            row(start: t0.addingTimeInterval(3600), minutes: 50, km: 10, energy: 1.7)
        ], vin: "V")

        let result = CloudTripMerge.merge(local: [reconstructed], cloud: cloud, window: window())
        #expect(result.dropped == 1)
        #expect(result.added == 2)
        #expect(result.trips.count == 2, "补记换成两趟官方记录，里程合计不变")
        #expect(result.trips.reduce(0) { $0 + $1.distanceKm } == 20)
    }

    @Test("补记没被完全覆盖时留着——那里面还有官方不知道的路")
    func partialCoverageKeepsReconstruction() {
        let reconstructed = TripRecord(
            startAt: t0, endAt: t0.addingTimeInterval(4 * 3600), distanceKm: 30,
            isReconstructed: true
        )
        let cloud = CloudTripParser.records(
            from: [row(start: t0.addingTimeInterval(3600), minutes: 20, km: 8)], vin: "V"
        )
        let result = CloudTripMerge.merge(local: [reconstructed], cloud: cloud, window: window())
        #expect(result.dropped == 0)
        #expect(result.trips.contains { $0.isReconstructed })
    }

    @Test("同步两次结果一样：不会每打开一次就多出一条")
    func mergeIsIdempotent() {
        let cloud = CloudTripParser.records(
            from: [row(start: t0, minutes: 20, km: 9, energy: 1.4)], vin: "V"
        )
        let first = CloudTripMerge.merge(local: [], cloud: cloud, window: window())
        let second = CloudTripMerge.merge(local: first.trips, cloud: cloud, window: window())
        #expect(second.added == 0)
        #expect(second.trips.count == first.trips.count)
        #expect(second.trips.first?.id == first.trips.first?.id)
    }

    @Test("云端删掉的记录，本机那份也要跟着走")
    func officialRowsDisappearWithTheCloud() {
        let cloud = CloudTripParser.records(
            from: [row(start: t0, minutes: 20, km: 9)], vin: "V"
        )
        let first = CloudTripMerge.merge(local: [], cloud: cloud, window: window())
        let second = CloudTripMerge.merge(local: first.trips, cloud: [], window: window())
        #expect(second.trips.isEmpty)
    }

    @Test("删掉的官方行程，下次同步不会复活")
    func deletedOfficialRowStaysDeleted() throws {
        let cloud = CloudTripParser.records(
            from: [row(start: t0, minutes: 20, km: 9)], vin: "V"
        )
        let first = CloudTripMerge.merge(local: [], cloud: cloud, window: window())
        let key = try #require(first.trips.first?.officialKey)

        // 用户长按删掉了这一条：本机列表空了，但云端那条还在。
        let second = CloudTripMerge.merge(
            local: [], cloud: cloud, window: window(), hiddenKeys: [key]
        )
        #expect(second.trips.isEmpty, "删掉的记录不能被云端合并回来")
        #expect(second.added == 0)
    }

    @Test("窗口之外的官方记录不动——只拉了 30 天，不能把更早的删掉")
    func olderOfficialRowsSurviveANarrowWindow() {
        let old = TripRecord(
            vin: "V",
            startAt: t0.addingTimeInterval(-60 * 86_400),
            endAt: t0.addingTimeInterval(-60 * 86_400 + 1800),
            distanceKm: 12,
            source: .official
        )
        let second = CloudTripMerge.merge(local: [old], cloud: [], window: window())
        #expect(second.trips.count == 1)
    }

    private func window() -> ClosedRange<Date> {
        t0.addingTimeInterval(-31 * 86_400)...t0.addingTimeInterval(86_400)
    }
}
