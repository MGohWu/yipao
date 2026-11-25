import Combine
import Foundation

/// 充电记录器。挂在 10 秒一次的车况轮询上，把「开始充电 / 充完拔枪」串成一段段记录。
///
/// 落盘的只有**已经结束**的充电。进行中的那一段只留在内存（`active`），App 被杀掉就没了——
/// 理由和 `TripRecorder` 一样，但代价小得多：充电时车不动，下次打开时用前后 SoC 差补一条
/// 补记，电量误差通常在一两个百分点以内。行车那边补记只能靠里程表，粗糙得多。
///
/// 能量不是车给的。车只报电压和电流，我们按「功率 × 时间」积分（`ChargeTracker`），
/// 再拿 SoC 差交叉验证；两者对不上时以积分为准，因为电量读数只有整数个百分点。
@MainActor
final class ChargeRecorder: ObservableObject {
    static let shared = ChargeRecorder()

    /// 已结束的充电，最新的在前。
    @Published private(set) var charges: [ChargeRecord]
    /// 正在充的这一段。没有就是 nil。
    @Published private(set) var active: ChargeRecord?
    /// 每 1% 电量约等于多少度电（含充电损耗）。补记只靠它换算出「充了多少度」。
    @Published private(set) var kwhPerPercent: Double?

    private var tracker = ChargeTracker()

    private init() {
        let file = ChargeLogStore.load()
        charges = file.records
        kwhPerPercent = file.kwhPerPercent
    }

    /// 每轮车况刷新后调一次。
    func observe(_ state: VehicleState, vin: String?, at date: Date = .now) {
        let sample = ChargeTracker.Sample(
            at: date,
            soc: state.soc,
            chargeState: state.chargeState,
            gunConnected: state.chargeGunConnected,
            isDC: state.isFastChargingConnected,
            powerKW: state.chargePowerKW,
            coordinate: state.shareableCoordinate
        )
        for charge in tracker.ingest(sample, vin: vin, kwhPerPercent: kwhPerPercent) {
            record(charge)
        }
        if active != tracker.active { active = tracker.active }
    }

    /// 丢掉正在充的这一段——退出登录、进入演示模式时用。理由同 `TripRecorder.forgetActiveTrip`。
    func forgetActiveCharge() {
        tracker = ChargeTracker()
        active = nil
    }

    /// 地名异步补齐之后回写。
    func applyPlace(id: UUID, place: String?) {
        guard let place, !place.isEmpty,
              let index = charges.firstIndex(where: { $0.id == id }),
              charges[index].place != place else { return }
        charges[index].place = place
        persist()
    }

    private func record(_ charge: ChargeRecord) {
        charges.insert(charge, at: 0)
        if charges.count > ChargeLogStore.limit {
            charges = Array(charges.prefix(ChargeLogStore.limit))
        }
        learn(from: charge)
        persist()
        BLEDiagnostics.record(
            "charge",
            "\(charge.isReconstructed ? "补记" : "充电") "
                + "\(charge.startSoc.map(String.init) ?? "-")→\(charge.endSoc.map(String.init) ?? "-")%"
                + " \(charge.energyKwh.map { String(format: "%.1fkWh", $0) } ?? "电量未知")"
                + " \(charge.maxPowerKw.map { String(format: "%.1fkW", $0) } ?? "")"
                + " /\(Int(charge.duration / 60))min"
        )
    }

    /// 从一次**精确的**充电里学「每 1% 是多少度」。
    ///
    /// 只认同时有积分能量和电量差的记录：补记没有能量，短途充电的电量差又只有一两个点，
    /// 拿它算出来的是噪声。`0.3~2.5 度/百分点` 这个区间对应 30~250 度的电池包，
    /// 超出的说明积分或 SoC 读错了，不进学习值。
    ///
    /// 用 0.7/0.3 的指数平滑而不是取平均：这份数据要跨会话积累，没必要把历史上
    /// 每一个样本都存下来，而新旧样本本来就该有不同的权重（换季节、换桩，效率会变）。
    private func learn(from charge: ChargeRecord) {
        guard !charge.isReconstructed,
              let energy = charge.energyKwh, energy >= 3,
              let gain = charge.socGain, gain >= 5 else { return }
        let ratio = energy / Double(gain)
        guard ratio >= 0.3, ratio <= 2.5 else { return }
        if let current = kwhPerPercent {
            kwhPerPercent = current * 0.7 + ratio * 0.3
        } else {
            kwhPerPercent = ratio
        }
    }

    private func persist() {
        var file = ChargeLogFile()
        file.records = charges
        file.kwhPerPercent = kwhPerPercent
        ChargeLogStore.save(file)
    }
}
