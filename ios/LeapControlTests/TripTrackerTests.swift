import CoreLocation
import Foundation
import Testing

@testable import LeapControl

/// 行程切分规则的回归测试。
///
/// 这套规则全靠「帧」判定，改一个阈值就可能把车主的一趟通勤切成五段、或者把两天的行程拼成一条，
/// 而在真实轮询里很难复现——所以这里用写死的时间轴把几种典型路况摆出来：
/// 正常一趟、等红灯、挪车位、App 被杀断档、里程表倒退、中途换车。
@Suite("行程切分")
struct TripTrackerTests {
    /// 杭州滨江，和坐标换算那组测试同一个点。
    private let origin = CLLocationCoordinate2D(latitude: 30.18682, longitude: 120.19551)
    /// 固定起点时间，不用 `Date.now`——否则每天早上八点跑测试和晚上跑的结果不一样。
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ minutes: Double) -> Date {
        t0.addingTimeInterval(minutes * 60)
    }

    /// 造一帧。`offset` 是纬度上的位移（度），0.01° ≈ 1.1 公里。
    private func sample(
        _ minutes: Double,
        odo: Int?,
        soc: Int? = 80,
        offset: Double = 0,
        gear: Bool
    ) -> TripTracker.Sample {
        TripTracker.Sample(
            at: at(minutes),
            odometerKm: odo,
            soc: soc,
            coordinate: CLLocationCoordinate2D(
                latitude: origin.latitude + offset,
                longitude: origin.longitude
            ),
            gearDriving: gear
        )
    }

    @Test("车动到车停只记一条，开始时间回到车还没动的那一帧")
    func recordsOneTripFromPullAwayToStop() {
        var tracker = TripTracker()
        var done: [TripRecord] = []
        done += tracker.ingest(sample(0, odo: 100, gear: false), vin: "V")
        done += tracker.ingest(sample(1.0 / 6, odo: 100, gear: true), vin: "V")
        done += tracker.ingest(sample(4.83, odo: 104, offset: 0.02, gear: true), vin: "V")
        done += tracker.ingest(sample(5, odo: 104, offset: 0.02, gear: false), vin: "V")
        done += tracker.ingest(sample(5.17, odo: 104, offset: 0.02, gear: false), vin: "V")
        done += tracker.ingest(sample(5.33, odo: 104, offset: 0.02, gear: false), vin: "V")

        #expect(done.count == 1)
        #expect(done.first?.distanceKm == 4, "里程表 100→104，应记 4 公里")
        // 开始时间取「上一次停车采样」而不是「第一次看到 D 档」，否则每趟都会短 10 秒。
        #expect(done.first?.startAt == t0)
        #expect(done.first?.isReconstructed == false)
        #expect(tracker.active == nil)
    }

    @Test("等红灯时挡位只缺一帧，不能切段")
    func redLightDoesNotSplitTheTrip() {
        var tracker = TripTracker()
        _ = tracker.ingest(sample(0, odo: 100, gear: false), vin: "V")
        _ = tracker.ingest(sample(0.17, odo: 100, gear: true), vin: "V")
        _ = tracker.ingest(sample(2, odo: 101, offset: 0.01, gear: true), vin: "V")

        let out = tracker.ingest(sample(2.17, odo: 101, offset: 0.01, gear: false), vin: "V")
        #expect(out.isEmpty)
        #expect(tracker.active != nil, "只停一帧，行程还在进行")
    }

    @Test("挪车位不到 300 米，不算一趟")
    func shortHopIsDropped() {
        var tracker = TripTracker()
        _ = tracker.ingest(sample(0, odo: 100, gear: false), vin: "V")
        _ = tracker.ingest(sample(0.17, odo: 100, gear: true), vin: "V")
        _ = tracker.ingest(sample(0.34, odo: 100, offset: 0.0005, gear: false), vin: "V")
        _ = tracker.ingest(sample(0.5, odo: 100, offset: 0.0005, gear: false), vin: "V")
        let out = tracker.ingest(sample(0.67, odo: 100, offset: 0.0005, gear: false), vin: "V")

        #expect(out.isEmpty)
        #expect(tracker.active == nil)
    }

    @Test("断档：旧行程收在断档前，里程差再补一条")
    func gapClosesTheTripThenReconstructs() {
        var tracker = TripTracker()
        _ = tracker.ingest(sample(0, odo: 100, gear: false), vin: "V")
        _ = tracker.ingest(sample(0.17, odo: 100, gear: true), vin: "V")
        _ = tracker.ingest(sample(5, odo: 103, offset: 0.02, gear: true), vin: "V")

        // App 被挂起 30 分钟，回来时车已经停好，里程表涨了 12 公里。
        let out = tracker.ingest(sample(35, odo: 115, offset: 0.05, gear: false), vin: "V")

        #expect(out.count == 2)
        #expect(out.first?.isReconstructed == false)
        #expect(out.first?.endAt == at(5), "行程要收在断档前那一帧，不能把中间半小时算成行驶")
        #expect(out.last?.isReconstructed == true)
        #expect(out.last?.distanceKm == 12, "补记的距离就是里程表差")
        #expect(out.last?.startAt == at(5))
    }

    @Test("里程表倒退：不记，也不给负距离")
    func odometerRollbackIsIgnored() {
        var tracker = TripTracker()
        _ = tracker.ingest(sample(0, odo: 500, gear: false), vin: "V")
        _ = tracker.ingest(sample(0.17, odo: 500, gear: true), vin: "V")

        // 换了车机、或者表被清过：回来的读数比出发时还小。
        let out = tracker.ingest(sample(35, odo: 20, offset: 0.02, gear: false), vin: "V")
        #expect(out.isEmpty)
        #expect(tracker.active == nil)
    }

    @Test("中途换车：上一台的行程就地收掉，不拼到一起")
    func vehicleSwitchClosesTheTrip() {
        var tracker = TripTracker()
        _ = tracker.ingest(sample(0, odo: 100, gear: false), vin: "A")
        _ = tracker.ingest(sample(0.17, odo: 100, gear: true), vin: "A")
        _ = tracker.ingest(sample(5, odo: 103, offset: 0.02, gear: true), vin: "A")

        let out = tracker.ingest(sample(5.17, odo: 200, offset: 0.02, gear: false), vin: "B")
        #expect(out.count == 1)
        #expect(out.first?.vin == "A")
        #expect(out.first?.distanceKm == 3)
    }

    /// 充电会让电量上涨，那不是「这段路发了电」。界面据此不显示耗电，别让它变成 `-3%`。
    @Test("充电导致的电量上涨不算耗电")
    func socRiseIsNotAConsumption() {
        let trip = TripRecord(
            startAt: t0, endAt: t0.addingTimeInterval(600), distanceKm: 5,
            startSoc: 40, endSoc: 46
        )
        #expect(trip.socDrop == nil)
    }
}
