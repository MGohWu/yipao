import CoreLocation
import Foundation
import Testing

@testable import LeapControl

/// 充电切分规则的回归测试。
///
/// 和行程那套一样，判定全靠「帧」，改一个阈值就可能把一次充电记成六次、或者把
/// 「插着枪等预约时间」记成一次零度电的充电。这些情形在真实轮询里很难复现，
/// 所以用写死的时间轴摆出来：正常慢充、预约等待、墙盒断电、充完不拔枪、太短的丢弃、
/// App 被挂起后的补记、中途换车、读不到电流的车型。
@Suite("充电切分")
struct ChargeTrackerTests {
    private let origin = CLLocationCoordinate2D(latitude: 30.18682, longitude: 120.19551)
    /// 固定起点时间，不用 `Date.now`，否则测试结果跟着运行时刻变。
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ minutes: Double) -> Date {
        t0.addingTimeInterval(minutes * 60)
    }

    /// 造一帧。默认「插着枪但没在充」——那正是插枪待充/预约等待的样子。
    private func sample(
        _ minutes: Double,
        soc: Int? = 40,
        state: Int? = 0,
        gun: Bool? = true,
        power: Double? = nil,
        dc: Bool = false
    ) -> ChargeTracker.Sample {
        ChargeTracker.Sample(
            at: at(minutes),
            soc: soc,
            chargeState: state,
            gunConnected: gun,
            isDC: dc,
            powerKW: power,
            coordinate: origin
        )
    }

    @Test("插枪到拔枪只记一条，能量按功率积分")
    func recordsOneSessionAndIntegratesEnergy() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []

        // 插枪待充：不开会话。
        done += tracker.ingest(sample(0, soc: 40), vin: "V", kwhPerPercent: nil)
        #expect(tracker.active == nil, "插着枪但没电流，不能开始记")

        // 电流真的来了。
        done += tracker.ingest(sample(1, soc: 40, state: 1, power: 6.5), vin: "V", kwhPerPercent: nil)
        #expect(tracker.active != nil)

        for minute in 2...61 {
            done += tracker.ingest(
                sample(Double(minute), soc: 40 + minute / 10, state: 1, power: 6.5),
                vin: "V",
                kwhPerPercent: nil
            )
        }
        // 拔枪，连续三帧。
        for minute in 62...64 {
            done += tracker.ingest(sample(Double(minute), soc: 48, gun: false), vin: "V", kwhPerPercent: nil)
        }

        #expect(done.count == 1)
        // 60 帧 × 6.5 kW × 1 分钟 = 6.5 kWh。
        #expect(abs((done.first?.energyKwh ?? 0) - 6.5) < 0.2)
        #expect(done.first?.maxPowerKw == 6.5)
        #expect(done.first?.isReconstructed == false)
        #expect(done.first?.socGain == 8)
        // 开始时间回到「还没开始充」的那一帧，否则每次充电都会短一分钟。
        #expect(done.first?.startAt == t0)
        #expect(tracker.active == nil)
    }

    @Test("预约等待时插着枪也不能开始记")
    func deferredChargeDoesNotOpenSession() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []
        // 1149 == 4：车在等自己定的时间，枪是插着的、电流是零。
        for minute in 0...5 {
            done += tracker.ingest(
                sample(Double(minute), state: 4, power: nil),
                vin: "V",
                kwhPerPercent: nil
            )
        }
        #expect(done.isEmpty)
        #expect(tracker.active == nil, "插枪等预约不算充电，否则会记出一条 0 度的记录")
    }

    @Test("墙盒断电几十秒时靠插枪撑住，不能切成两段")
    func currentDipDoesNotSplitSession() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []
        done += tracker.ingest(sample(0), vin: "V", kwhPerPercent: nil)
        done += tracker.ingest(sample(1, state: 1, power: 7), vin: "V", kwhPerPercent: nil)
        // 负载均衡让电流停了半分钟，车把枪也报成「没在充」，但仍算插着。
        for minute in 2...4 {
            done += tracker.ingest(sample(Double(minute), state: 0, gun: true), vin: "V", kwhPerPercent: nil)
        }
        #expect(done.isEmpty, "插着枪的断电是暂停，不是结束")
        #expect(tracker.active != nil)

        done += tracker.ingest(sample(5, state: 1, power: 7), vin: "V", kwhPerPercent: nil)
        #expect(done.isEmpty)
        #expect(tracker.active != nil)
    }

    @Test("车报「本次充电已结束」三帧就收尾，哪怕枪还插着")
    func completedChargeClosesEvenIfPlugged() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []
        done += tracker.ingest(sample(0), vin: "V", kwhPerPercent: nil)
        done += tracker.ingest(sample(1, soc: 40, state: 1, power: 60, dc: true), vin: "V", kwhPerPercent: nil)
        done += tracker.ingest(sample(2, soc: 60, state: 1, power: 60, dc: true), vin: "V", kwhPerPercent: nil)

        // 1149 == 2，枪没拔。
        done += tracker.ingest(sample(3, soc: 61, state: 2), vin: "V", kwhPerPercent: nil)
        done += tracker.ingest(sample(4, soc: 61, state: 2), vin: "V", kwhPerPercent: nil)
        #expect(done.isEmpty)
        done += tracker.ingest(sample(5, soc: 61, state: 2), vin: "V", kwhPerPercent: nil)

        #expect(done.count == 1, "充完不拔枪不该让会话挂一整晚")
        #expect(done.first?.isDC == true)
        #expect(tracker.active == nil)
    }

    @Test("不足半度电、电量也没涨的，不算一次充电")
    func tooShortChargeIsDropped() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []
        done += tracker.ingest(sample(0), vin: "V", kwhPerPercent: nil)
        done += tracker.ingest(sample(1, state: 1, power: 6), vin: "V", kwhPerPercent: nil)
        for minute in 2...4 {
            done += tracker.ingest(sample(Double(minute), gun: false), vin: "V", kwhPerPercent: nil)
        }
        #expect(done.isEmpty, "插一下枪又拔掉是握手，不该占一条记录")
        #expect(tracker.active == nil)
    }

    @Test("App 被挂起后按电量差补一条，有学习值时给出度数")
    func reconstructionUsesSocGainAndLearnedRatio() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []
        done += tracker.ingest(sample(0, soc: 40), vin: "V", kwhPerPercent: 0.8)
        done += tracker.ingest(sample(1, soc: 40, state: 1, power: 7), vin: "V", kwhPerPercent: 0.8)
        done += tracker.ingest(sample(2, soc: 41, state: 1, power: 7), vin: "V", kwhPerPercent: 0.8)

        // 两个小时后才再看到车：中间 App 不在。
        done += tracker.ingest(sample(122, soc: 70, state: 1, power: 7), vin: "V", kwhPerPercent: 0.8)

        let reconstructed = done.first { $0.isReconstructed }
        #expect(reconstructed != nil, "断档期间电量涨了 29 个点，必须补一条")
        #expect(reconstructed?.startSoc == 41)
        #expect(reconstructed?.endSoc == 70)
        // 29 × 0.8 = 23.2 kWh。
        #expect(abs((reconstructed?.energyKwh ?? 0) - 23.2) < 0.2)
        // 断档前那一段只算到「上次看到车」为止，不把挂起的两小时算进去。
        #expect(done.first { !$0.isReconstructed }?.endAt == at(2))
    }

    @Test("没有学习值时补记只给电量变化，不编度数")
    func reconstructionWithoutRatioOmitsEnergy() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []
        done += tracker.ingest(sample(0, soc: 30), vin: "V", kwhPerPercent: nil)
        done += tracker.ingest(sample(90, soc: 60), vin: "V", kwhPerPercent: nil)

        #expect(done.count == 1)
        #expect(done.first?.isReconstructed == true)
        #expect(done.first?.energyKwh == nil, "没有换算口径就不该给一个编出来的度数")
        #expect(done.first?.socGain == 30)
    }

    @Test("电量只涨 1% 不补记：那是读数抖动")
    func socNoiseDoesNotReconstruct() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []
        done += tracker.ingest(sample(0, soc: 55), vin: "V", kwhPerPercent: 0.8)
        done += tracker.ingest(sample(60, soc: 56), vin: "V", kwhPerPercent: 0.8)
        #expect(done.isEmpty)
    }

    @Test("中途换车：上一台的会话就地结束，不把两台车的电记成一次")
    func switchingVehicleClosesSession() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []
        done += tracker.ingest(sample(0, soc: 40), vin: "A", kwhPerPercent: nil)
        done += tracker.ingest(sample(1, soc: 40, state: 1, power: 7), vin: "A", kwhPerPercent: nil)
        done += tracker.ingest(sample(2, soc: 42, state: 1, power: 7), vin: "A", kwhPerPercent: nil)
        done += tracker.ingest(sample(3, soc: 42, state: 1, power: 7), vin: "B", kwhPerPercent: nil)

        #expect(done.count == 1)
        #expect(done.first?.vin == "A")
        #expect(tracker.active == nil || tracker.active?.vin == "B")
    }

    @Test("读不到电压电流的车型，用 SoC 差乘学习值")
    func fallsBackToSocGainWhenPowerIsMissing() {
        var tracker = ChargeTracker()
        var done: [ChargeRecord] = []
        done += tracker.ingest(sample(0, soc: 40), vin: "V", kwhPerPercent: 0.82)
        done += tracker.ingest(sample(1, soc: 40, state: 1, power: nil), vin: "V", kwhPerPercent: 0.82)
        for minute in 2...6 {
            done += tracker.ingest(sample(Double(minute), soc: 42, state: 1, power: nil), vin: "V", kwhPerPercent: 0.82)
        }
        for minute in 7...9 {
            done += tracker.ingest(sample(Double(minute), soc: 42, state: 2), vin: "V", kwhPerPercent: 0.82)
        }

        #expect(done.count == 1)
        // 2 个百分点 × 0.82 = 1.64 kWh。
        #expect(abs((done.first?.energyKwh ?? 0) - 1.64) < 0.05)
        #expect(done.first?.maxPowerKw == nil, "没读到功率就不该编一个峰值出来")
    }
}
