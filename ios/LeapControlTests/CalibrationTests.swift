import Foundation
import Testing
@testable import LeapControl

/// 车型标定：拿操作前后的车况差异反推信号 ID。
///
/// 判据必须严——认错一个 ID，界面就会拿一个无关字段冒充门锁状态，
/// 那比老老实实显示「认不出来」糟糕得多。
@Suite("车型标定")
struct CalibrationTests {

    // MARK: - diff

    @Test("只报变化的字段")
    func diffReportsChangesOnly() {
        let changes = Calibration.changes(
            from: ["1943": "1", "1693": "0", "soc": "79"],
            to: ["1943": "0", "1693": "0", "soc": "79"]
        )
        #expect(changes == [SignalChange(key: "1943", before: "1", after: "0")])
    }

    @Test("字段新增或消失也算变化")
    func diffCoversAppearingKeys() {
        let appeared = Calibration.changes(from: [:], to: ["2100": "50"])
        #expect(appeared == [SignalChange(key: "2100", before: "", after: "50")])
        let vanished = Calibration.changes(from: ["2100": "50"], to: [:])
        #expect(vanished == [SignalChange(key: "2100", before: "50", after: "")])
    }

    @Test("噪声字段被排除")
    func diffExcludesNoise() {
        let changes = Calibration.changes(
            from: ["1": "100", "1943": "1"],
            to: ["1": "200", "1943": "0"],
            excluding: ["1"]
        )
        #expect(changes.map(\.key) == ["1943"])
    }

    // MARK: - 静止基线

    @Test("静止时变过的字段全部进噪声名单")
    func baselineCollectsNoise() {
        // 时间戳每次都跳，电压电流一直在小幅飘，这些必须先摘掉。
        let baseline = CalibrationBaseline.make(from: [
            ["1": "100", "1177": "718.6", "1943": "1"],
            ["1": "200", "1177": "718.2", "1943": "1"],
            ["1": "300", "1177": "718.4", "1943": "1"]
        ])
        #expect(baseline.noisyKeys == ["1", "1177"])
        // 经纬度不在这儿处理——它是无条件排除的，压根进不了 diff。
        #expect(!baseline.noisyKeys.contains("2"))
    }

    @Test("采样不足两次时不敢下结论，噪声名单为空")
    func baselineNeedsTwoSamples() {
        #expect(CalibrationBaseline.make(from: []).noisyKeys.isEmpty)
        #expect(CalibrationBaseline.make(from: [["1": "100"]]).noisyKeys.isEmpty)
        // 采样不足不等于「车睡着了」，别拿这个去吓用户。
        #expect(!CalibrationBaseline.make(from: [["1": "100"]]).looksAsleep)
    }

    @Test("采了好几次一个字段都没变，判定为车睡着了")
    func baselineDetectsSleepingCar() {
        // 真实发生过：车休眠时三次采样一模一样，噪声名单空了，
        // 后面每一步的 diff 都混进十几个无关 ID。
        let asleep = CalibrationBaseline.make(from: [
            ["1": "100", "1943": "1"],
            ["1": "100", "1943": "1"],
            ["1": "100", "1943": "1"]
        ])
        #expect(asleep.noisyKeys.isEmpty)
        #expect(asleep.looksAsleep)
    }

    // MARK: - 位置字段

    @Test("经纬度无条件排除，不靠基线兜")
    func locationNeverEntersDiff() {
        // 车睡着时基线是空的，光靠噪声名单挡不住。
        let changes = Calibration.changes(
            from: ["2": "120.185362", "3": "30.259255", "longitude": "120.19551", "1943": "1"],
            to: ["2": "120.185901", "3": "30.259712", "longitude": "120.19602", "1943": "0"]
        )
        #expect(changes.map(\.key) == ["1943"])
    }

    @Test("映射表里没收录的坐标字段，按值的形状也挡得住")
    func unmappedCoordinatesGetRedacted() {
        // C11 至少还有 2190/2191、3724/3725 两组坐标，其中一个从上一版报告里溜过。
        let changes = Calibration.changes(
            from: ["2191": "120.182100", "1349": "26.5", "1177": "718.6"],
            to: ["2191": "120.183300", "1349": "31.5", "1177": "718.2"]
        )
        #expect(changes.map(\.key) == ["1177", "1349"])
    }

    // MARK: - 双向确认

    private func outcome(
        signal: VehicleSignal = .driverDoorLocked,
        forward: [SignalChange],
        backward: [SignalChange]
    ) -> TaskOutcome {
        TaskOutcome(taskID: "lock", signal: signal.rawValue, forward: forward, backward: backward)
    }

    @Test("正反两次值完全对调才算确认")
    func confirmsOnlyOnExactReversal() {
        let result = outcome(
            forward: [SignalChange(key: "1943", before: "1", after: "0")],
            backward: [SignalChange(key: "1943", before: "0", after: "1")]
        )
        #expect(result.confirmedKeys == ["1943"])
        #expect(result.isConfirmed)
    }

    @Test("只朝一个方向变的不算数")
    func rejectsOneWayChange() {
        // 车自己也在动——空调余温、电压回落都会造成单向变化，不能当成用户操作的结果。
        let result = outcome(
            forward: [SignalChange(key: "1943", before: "1", after: "0")],
            backward: []
        )
        #expect(result.confirmedKeys.isEmpty)
        #expect(result.unconfirmedKeys == ["1943"])
        #expect(!result.isConfirmed)
    }

    @Test("两次都变但没回到原值的不算数")
    func rejectsNonReversal() {
        // 连续量在两步之间一路下滑，两次都会变，但不是对调。
        let result = outcome(
            forward: [SignalChange(key: "1177", before: "718.6", after: "718.2")],
            backward: [SignalChange(key: "1177", before: "718.2", after: "717.9")]
        )
        #expect(result.confirmedKeys.isEmpty)
        #expect(result.unconfirmedKeys == ["1177"])
    }

    // MARK: - 单向任务

    private func oneWay(_ forward: [SignalChange], signal: VehicleSignal = .acSetting) -> TaskOutcome {
        TaskOutcome(taskID: "acTemp", signal: signal.rawValue, forward: forward, backward: [], didReverse: false)
    }

    @Test("跳过复原时，正向只动了一个字段就采信")
    func singleDirectionAcceptsLoneChange() {
        // 有些操作复不了原（空调设定温度调回去车端也不一定回报），
        // 这时候唯一站得住的判据是「没有别的字段陪着一起动」。
        let result = oneWay([SignalChange(key: "2183", before: "26", after: "24")])
        #expect(result.confirmedKeys == ["2183"])
        #expect(result.isConfirmed)
        #expect(Calibration.learnedKeys(from: [result]) == [.acSetting: "2183"])
    }

    @Test("跳过复原时，正向变了两个就整步作废")
    func singleDirectionRejectsAmbiguity() {
        // 没有对调可比，分不出哪个是目标。猜错会把错的 key 写进映射表。
        let result = oneWay([
            SignalChange(key: "2183", before: "26", after: "24"),
            SignalChange(key: "1178", before: "0.4", after: "1.6")
        ])
        #expect(result.confirmedKeys.isEmpty)
        #expect(result.unconfirmedKeys == ["1178", "2183"])
        #expect(Calibration.learnedKeys(from: [result]).isEmpty)
    }

    @Test("跳过复原且什么都没捕捉到，同样不算数")
    func singleDirectionNeedsEvidence() {
        #expect(oneWay([]).confirmedKeys.isEmpty)
    }

    @Test("做了复原的步骤照旧要求对调，宽松规则不外溢")
    func twoWayStillNeedsReversal() {
        // didReverse 默认为真，单个字段的单向变化仍然不算数。
        let result = outcome(
            forward: [SignalChange(key: "1177", before: "718.6", after: "718.2")],
            backward: []
        )
        #expect(result.confirmedKeys.isEmpty)
    }

    @Test("车窗刻度这类非布尔值同样按对调判定")
    func confirmsWindowScale() {
        let result = outcome(
            signal: .leftFrontWindow,
            forward: [SignalChange(key: "2100", before: "0", after: "50")],
            backward: [SignalChange(key: "2100", before: "50", after: "0")]
        )
        #expect(result.confirmedKeys == ["2100"])
    }

    // MARK: - 写入映射

    @Test("一步只变一个字段时才采信")
    func learnsOnlyUnambiguousStep() {
        let clean = outcome(
            forward: [SignalChange(key: "1943", before: "1", after: "0")],
            backward: [SignalChange(key: "1943", before: "0", after: "1")]
        )
        #expect(Calibration.learnedKeys(from: [clean]) == [.driverDoorLocked: "1943"])
    }

    @Test("同一步变了好几个字段就整步放弃，不猜哪个才对")
    func discardsAmbiguousStep() {
        // 开车门会连带解锁，这种没隔离干净的步骤宁可不要。
        let messy = outcome(
            forward: [
                SignalChange(key: "1943", before: "1", after: "0"),
                SignalChange(key: "1693", before: "0", after: "1")
            ],
            backward: [
                SignalChange(key: "1943", before: "0", after: "1"),
                SignalChange(key: "1693", before: "1", after: "0")
            ]
        )
        #expect(Calibration.learnedKeys(from: [messy]).isEmpty)
    }

    @Test("未确认的步骤不写进映射")
    func skipsUnconfirmed() {
        let oneWay = outcome(
            forward: [SignalChange(key: "1943", before: "1", after: "0")],
            backward: []
        )
        #expect(Calibration.learnedKeys(from: [oneWay]).isEmpty)
    }

    // MARK: - 叠加到映射表

    @Test("标定结果盖过内置表")
    func learnedOverridesBuiltIn() {
        let schema = SignalSchema.numeric.merging([.driverDoorLocked: "1943"])
        #expect(schema.key(for: .driverDoorLocked) == "1943")
        // 内置的那些不受影响。
        #expect(schema.key(for: .soc) == "100003")
    }

    @Test("没有标定结果时映射表原样不动")
    func mergingNothingKeepsSchema() {
        #expect(SignalSchema.numeric.merging([:]) == .numeric)
    }

    @Test("标定过的信号能真的取到值")
    func learnedSignalReadsValue() {
        var state = VehicleState()
        state.signalMap = ["1943": "0", "100003": "79.9"]
        state.schema = SignalSchema.numeric.merging([.driverDoorLocked: "1943"])
        #expect(state.isLocked == false)
        #expect(state.soc == 79)
    }

    // MARK: - 任务清单

    @Test("每个任务都有正反两步，且目标信号互不重复")
    func tasksAreWellFormed() {
        let signals = CalibrationTask.all.map(\.signal)
        #expect(Set(signals).count == signals.count)
        for task in CalibrationTask.all {
            #expect(!task.forward.isEmpty)
            #expect(!task.backward.isEmpty)
        }
    }

    @Test("车锁排在车门前面")
    func lockComesBeforeDoor() {
        // 开车门会顺带解锁，先把车锁标定完才不会互相干扰。
        let ids = CalibrationTask.all.map(\.id)
        let lock = ids.firstIndex(of: "lock")
        let door = ids.firstIndex(of: "driverDoor")
        #expect(lock != nil && door != nil && lock! < door!)
    }

    // MARK: - 报告

    @Test("报告不含车架号、位置和账号信息")
    func reportCarriesNoPrivateData() {
        let report = Calibration.report(
            carType: "C11",
            schemaID: "numeric",
            baseline: CalibrationBaseline(noisyKeys: ["1", "2", "3"]),
            outcomes: [outcome(
                forward: [SignalChange(key: "1943", before: "1", after: "0")],
                backward: [SignalChange(key: "1943", before: "0", after: "1")]
            )],
            at: Date(timeIntervalSince1970: 0)
        )
        #expect(report.contains("C11"))
        #expect(report.contains("1943"))
        // 经纬度进了噪声名单，只留编号，数值不会出现在任何 diff 里。
        #expect(!report.contains("120.18"))
        #expect(!report.contains("30.25"))
        #expect(!report.lowercased().contains("vin"))
    }

    @Test("没做的任务在报告里标成未做，不假装有结果")
    func reportMarksSkippedTasks() {
        let report = Calibration.report(
            carType: "C11",
            schemaID: "numeric",
            baseline: CalibrationBaseline(),
            outcomes: [],
            at: Date(timeIntervalSince1970: 0)
        )
        #expect(report.contains("未做"))
        #expect(report.contains("(无)"))
    }

    @Test("基线判定车睡着时，报告里要写清楚结果不可信")
    func reportWarnsAboutSleepingCar() {
        let report = Calibration.report(
            carType: "C11",
            schemaID: "numeric",
            baseline: CalibrationBaseline(noisyKeys: [], sampleCount: 3),
            outcomes: [],
            at: Date(timeIntervalSince1970: 0)
        )
        #expect(report.contains("睡着"))
    }

    @Test("单向确认的步骤在报告里如实标出来")
    func reportMarksSingleDirection() {
        let report = Calibration.report(
            carType: "C11",
            schemaID: "numeric",
            baseline: CalibrationBaseline(),
            outcomes: [oneWay([SignalChange(key: "2183", before: "26", after: "24")])],
            at: Date(timeIntervalSince1970: 0)
        )
        #expect(report.contains("单向唯一变化"))
        #expect(report.contains("(跳过)"))
    }

    @Test("新加的后排车窗和空调调节都在任务清单里")
    func coversRearWindowAndClimateAdjustments() {
        let ids = CalibrationTask.all.map(\.id)
        #expect(ids.contains("rearWindow"))
        #expect(ids.contains("acTemp"))
        #expect(ids.contains("acFan"))
        // 温度和风量得在空调开着的时候调。
        #expect(ids.firstIndex(of: "climate")! < ids.firstIndex(of: "acTemp")!)
        #expect(ids.firstIndex(of: "climate")! < ids.firstIndex(of: "acFan")!)
    }
}
