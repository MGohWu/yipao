import Foundation
import Testing

@testable import LeapControl

/// 通知判定的回归测试。
///
/// 这三条规则最容易出的错不是「不发」，而是**一次事件发好几条**：车主在电梯里收到五条
/// 「车还没锁」，第二天就会把通知全关掉。所以每条用例的重点都在「只发一次」和「什么时候复位」。
@Suite("通知判定")
struct VehicleAlertTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ minutes: Double) -> Date {
        t0.addingTimeInterval(minutes * 60)
    }

    private func sample(
        _ minutes: Double,
        locked: Bool? = true,
        driving: Bool = false,
        charging: Bool = false,
        state: Int? = nil,
        gun: Bool? = false,
        power: Double? = nil,
        soc: Int? = 60
    ) -> VehicleAlertSample {
        VehicleAlertSample(
            at: at(minutes),
            isLocked: locked,
            isDriving: driving,
            isCharging: charging,
            chargeState: state,
            gunConnected: gun,
            powerKW: power,
            soc: soc
        )
    }

    // MARK: - 未锁车

    @Test("没锁车未到时限不提醒，到了才提醒，而且只提醒一次")
    func unlockedAlertsOnceAfterGrace() {
        var engine = VehicleAlertEngine()
        var events: [VehicleAlertEvent] = []
        events += engine.ingest(sample(0, locked: false))
        events += engine.ingest(sample(4, locked: false))
        #expect(events.isEmpty, "才 4 分钟，不该吵")

        events += engine.ingest(sample(10, locked: false))
        #expect(events.count == 1)
        #expect(events.first?.kind == .unlocked)
        #expect(events.first?.minutes == 10)

        // 继续停着没锁：不该每帧都发
        events += engine.ingest(sample(11, locked: false))
        events += engine.ingest(sample(25, locked: false))
        #expect(events.count == 1, "一次没锁只提醒一次")
    }

    @Test("锁上就复位，下次再解锁重新计时")
    func lockingResetsTheEpisode() {
        var engine = VehicleAlertEngine()
        _ = engine.ingest(sample(0, locked: false))
        let first = engine.ingest(sample(10, locked: false))
        #expect(first.count == 1)

        _ = engine.ingest(sample(11, locked: true))
        _ = engine.ingest(sample(12, locked: false))
        let second = engine.ingest(sample(23, locked: false))
        #expect(second.count == 1, "新的一次没锁，要再提醒一次")
    }

    @Test("读不到锁状态不提醒——那可能是信号没上报")
    func unknownLockStateStaysQuiet() {
        var engine = VehicleAlertEngine()
        var events: [VehicleAlertEvent] = []
        for minute in stride(from: 0.0, through: 30, by: 5) {
            events += engine.ingest(sample(minute, locked: nil))
        }
        #expect(events.isEmpty)
    }

    @Test("在开的时候不提醒，哪怕锁状态报的是未锁")
    func drivingIsNotReminded() {
        var engine = VehicleAlertEngine()
        var events: [VehicleAlertEvent] = []
        for minute in stride(from: 0.0, through: 30, by: 5) {
            events += engine.ingest(sample(minute, locked: false, driving: true))
        }
        #expect(events.isEmpty)
    }

    // MARK: - 充电

    @Test("连续两帧在充电才算开始，功率抖一下不算")
    func chargeStartNeedsConfirmation() {
        var engine = VehicleAlertEngine()
        // 先来一帧「没在充」，定下起点；否则第一帧会被当成冷启动对齐。
        _ = engine.ingest(sample(0, charging: false, state: 0, gun: false, power: 0, soc: 40))
        let first = engine.ingest(sample(0.17, charging: true, state: 1, gun: true, power: 6.8, soc: 40))
        #expect(first.isEmpty, "第一帧只是看到，还没确认")

        let second = engine.ingest(sample(0.33, charging: true, state: 1, gun: true, power: 6.8, soc: 40))
        #expect(second.count == 1)
        #expect(second.first?.kind == .chargeStarted)
        #expect(second.first?.powerKW == 6.8)
    }

    @Test("冷启动时车已经在充电，不弹「开始充电」")
    func coldStartWhileChargingIsQuiet() {
        var engine = VehicleAlertEngine()
        var events: [VehicleAlertEvent] = []
        for minute in stride(from: 0.0, through: 2, by: 0.17) {
            events += engine.ingest(sample(minute, charging: true, state: 1, gun: true, power: 7, soc: 55))
        }
        #expect(events.isEmpty, "打开 App 时它就在充，这不是「开始」")
    }

    @Test("充电中功率掉到阈值以下，不会误报完成")
    func powerDipDoesNotFinishTheCharge() {
        var engine = VehicleAlertEngine()
        _ = engine.ingest(sample(0, charging: false, state: 0, gun: false, power: 0))
        _ = engine.ingest(sample(0.17, charging: true, state: 1, gun: true, power: 7))
        _ = engine.ingest(sample(0.33, charging: true, state: 1, gun: true, power: 7))
        // 涓流阶段车仍然报 1149 == 1
        let dip = engine.ingest(sample(1, charging: true, state: 1, gun: true, power: 0.2))
        #expect(dip.isEmpty)
    }

    @Test("车说充完了就提醒，并给出这次涨了多少")
    func chargeFinishedWithGain() {
        var engine = VehicleAlertEngine()
        _ = engine.ingest(sample(0, charging: false, state: 0, gun: false, power: 0, soc: 40))
        _ = engine.ingest(sample(0.17, charging: true, state: 1, gun: true, power: 7, soc: 40))
        _ = engine.ingest(sample(0.33, charging: true, state: 1, gun: true, power: 7, soc: 40))
        let done = engine.ingest(sample(180, charging: false, state: 2, gun: true, power: 0, soc: 82))

        #expect(done.count == 1)
        #expect(done.first?.kind == .chargeFinished)
        #expect(done.first?.soc == 82)
        #expect(done.first?.socGain == 42)
    }

    @Test("拔枪走人不算充满——那是车主自己的动作")
    func unpluggingIsNotAFinish() {
        var engine = VehicleAlertEngine()
        _ = engine.ingest(sample(0, charging: false, state: 0, gun: false, power: 0))
        _ = engine.ingest(sample(0.17, charging: true, state: 1, gun: true, power: 7))
        _ = engine.ingest(sample(0.33, charging: true, state: 1, gun: true, power: 7))
        let away = engine.ingest(sample(30, charging: false, state: 0, gun: false, power: 0))
        #expect(away.isEmpty)
    }

    @Test("两次充电是两次提醒，中间不会粘连")
    func twoSessionsTwoAlerts() {
        var engine = VehicleAlertEngine()
        var events: [VehicleAlertEvent] = []
        _ = engine.ingest(sample(0, charging: false, state: 0, gun: false, power: 0))
        _ = engine.ingest(sample(0.17, charging: true, state: 1, gun: true, power: 7))
        events += engine.ingest(sample(0.33, charging: true, state: 1, gun: true, power: 7))
        events += engine.ingest(sample(60, charging: false, state: 2, gun: true, soc: 80))

        _ = engine.ingest(sample(600, charging: true, state: 1, gun: true, power: 7))
        events += engine.ingest(sample(600.17, charging: true, state: 1, gun: true, power: 7))

        #expect(events.map(\.kind) == [.chargeStarted, .chargeFinished, .chargeStarted])
    }

    @Test("改时限立即生效")
    func graceSettingApplies() {
        var engine = VehicleAlertEngine()
        engine.settings.unlockedGrace = 5 * 60
        _ = engine.ingest(sample(0, locked: false))
        let events = engine.ingest(sample(5, locked: false))
        #expect(events.count == 1)
    }
}
