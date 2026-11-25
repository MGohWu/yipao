import SwiftUI

/// 充电记录。
///
/// 和行程页同一套做法：先拉零跑云端的充电明细（近 30 天，App 没开过也有），再用本机轮询
/// 的数据补上起止电量与峰值功率——那两项云端不给，只有一帧帧看着车才有。
///
/// 充电时车是静止的、SoC 只往上涨，所以「补记」在这边的可信度明显更高：电量那栏就算
/// 是补记也敢给一个数（区间内误差一两个百分点）。
struct ChargeHistoryView: View {
    @Environment(VehicleStore.self) private var store
    @StateObject private var recorder = ChargeRecorder.shared
    @State private var range: RecordsRange = .week
    /// 地名补齐的进度：正在补哪一条。
    @State private var resolvingID: UUID?

    private var vin: String? { store.session.selectedVin }

    private var allCharges: [ChargeRecord] {
        if store.isDemo { return ReviewDemo.chargeLog }
        // 老记录没有 vin 的一并显示，别让升级用户觉得记录丢了。
        guard let vin else { return recorder.charges }
        return recorder.charges.filter { $0.vin == nil || $0.vin == vin }
    }

    private var charges: [ChargeRecord] {
        allCharges.filter { range.contains($0.startAt) }
    }

    private var days: [(day: Date, charges: [ChargeRecord])] {
        Dictionary(grouping: charges) { $0.dayStart }
            .map { (day: $0.key, charges: $0.value.sorted { $0.startAt > $1.startAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        ZStack {
            LeapBackground(tint: LeapStyle.accent)
            ScrollView {
                VStack(spacing: 14) {
                    if let active = recorder.active {
                        RecordsLiveCard(
                            icon: "bolt.fill",
                            tint: LeapStyle.accent,
                            title: "正在充电",
                            detail: "已充 \(durationText(Date().timeIntervalSince(active.startAt)))"
                                + (store.state?.chargePowerKW.map { String(format: " · 当前 %.1f kW", $0) } ?? ""),
                            trailing: store.state?.soc.map { "\($0)%" }
                        )
                    }

                    RecordsRangePicker(selection: $range)
                        .padding(.horizontal, 2)

                    if charges.isEmpty {
                        RecordsEmptyCard(
                            icon: "bolt.car.fill",
                            title: "这段时间没有充电",
                            message: "App 开着的时候会按电流变化自己切段。零跑云端的充电明细如果能取到，这里还会多出标「官方」的记录（带度数与地点）；取不到就只显示本机记录。"
                        )
                    } else {
                        hero
                        ForEach(days, id: \.day) { group in
                            daySection(group.day, charges: group.charges)
                        }
                        footer
                    }

                    RecordsSyncLine(state: syncState) {
                        Task { await store.syncChargeLog(force: true) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.syncChargeLog(force: true) }
        }
        .navigationTitle("充电记录")
        .navigationBarTitleDisplayMode(.large)
        .task { await store.syncChargeLog() }
        // 地名一个个补，只补最近 8 条：一进页面就打十几个反地理编码请求，既慢又没必要。
        .task(id: allCharges.prefix(8).map(\.id)) { await resolveMissingPlaces() }
    }

    // MARK: - 汇总

    private var hero: some View {
        let energy = charges.compactMap(\.energyKwh).reduce(0, +)
        let duration = charges.reduce(0) { $0 + $1.duration }
        let dcCount = charges.filter { $0.isDC && !$0.isReconstructed }.count
        let peak = charges.compactMap(\.maxPowerKw).max()
        let bars = RecordsBar.daily(
            charges.map { ($0.startAt, $0.energyKwh ?? 0) },
            days: range.chartDays
        )
        return RecordsHero(
            caption: "\(range.title) · \(charges.count) 次",
            value: String(format: "%.1f", energy),
            unit: "kWh",
            bars: bars,
            footnote: charges.contains(where: \.isReconstructed) ? "含补记" : nil,
            metrics: [
                .init(title: "充电时长", value: durationText(duration)),
                .init(title: "快充", value: "\(dcCount)", unit: "次"),
                .init(title: "峰值", value: peak.map { String(format: "%.0f", $0) } ?? "—", unit: "kW")
            ]
        )
    }

    // MARK: - 一天

    private func daySection(_ day: Date, charges: [ChargeRecord]) -> some View {
        let energy = charges.compactMap(\.energyKwh).reduce(0, +)
        return VStack(alignment: .leading, spacing: 8) {
            RecordsDayHeader(
                title: dayTitle(day),
                summary: energy > 0
                    ? "\(charges.count) 次 · \(trimmed(energy)) kWh"
                    : "\(charges.count) 次"
            )
            GlassCard(radius: LeapStyle.cardRadius) {
                VStack(spacing: 0) {
                    ForEach(Array(charges.enumerated()), id: \.element.id) { index, charge in
                        chargeRow(charge)
                        if index < charges.count - 1 {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(height: 1)
                                .padding(.vertical, 11)
                        }
                    }
                }
            }
        }
    }

    private func chargeRow(_ charge: ChargeRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timeText(charge.startAt))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                kindTag(charge)
                if charge.isOfficial, !charge.isReconstructed {
                    RecordsTag(text: "官方", tint: LeapStyle.accent)
                }
                Spacer(minLength: 6)
                Text(charge.energyKwh.map { trimmed($0) } ?? "—")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("kWh")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, -3)
            }

            HStack(spacing: 5) {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 9))
                Text(charge.place ?? "地点未知").lineLimit(1)
                if resolvingID == charge.id {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            RecordsMeta(items: metaItems(charge))
        }
    }

    private func metaItems(_ charge: ChargeRecord) -> [(icon: String, text: String)] {
        var items: [(String, String)] = []
        if let start = charge.startSoc, let end = charge.endSoc, end > start {
            items.append(("battery.75percent", "\(start)% → \(end)%"))
        }
        items.append(("clock", durationText(charge.duration)))
        if let power = charge.maxPowerKw {
            items.append(("bolt.horizontal", String(format: "峰值 %.1f kW", power)))
        }
        return items
    }

    /// 快充 / 慢充 / 补记。补记不区分快慢——那时我们根本没看到车。
    private func kindTag(_ charge: ChargeRecord) -> some View {
        let (text, color): (String, Color) = {
            if charge.isReconstructed { return ("补记", LeapStyle.caution) }
            return charge.isDC ? ("快充", LeapStyle.warm) : ("慢充", LeapStyle.cool)
        }()
        return RecordsTag(text: text, tint: color)
    }

    // MARK: - 同步状态

    private var syncState: RecordsSyncState {
        guard !store.isDemo else { return .hidden }
        switch recorder.cloudSync {
        case .idle: return .hidden
        case .syncing: return .working
        case .synced(let date, let count):
            let text = count > 0
                ? "官方记录已同步：\(count) 次 · \(timeText(date))"
                : "官方记录已同步 · \(timeText(date))"
            return .done(text)
        case .failed(let message):
            return .failure(message)
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("「官方」那几条的度数是车的结算值；本机那几条按电压 × 电流积分，与充电桩显示的度数会有几个百分点差距（车载充电机损耗、电池加热都算在里面）。")
            Text("起止电量与峰值功率云端不给，只有本机看着车时才有。")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
    }

    // MARK: - 地名

    private func resolveMissingPlaces() async {
        guard !store.isDemo else { return }
        let pending = Array(allCharges.prefix(8).filter { $0.place == nil && $0.coordinate != nil })
        for charge in pending {
            guard !Task.isCancelled else { return }
            guard let coordinate = charge.coordinate else { continue }
            resolvingID = charge.id
            let place = await LocationNaming.name(for: coordinate)
            recorder.applyPlace(id: charge.id, place: place)
            // 反地理编码有频率限制，一条一条来。
            try? await Task.sleep(for: .milliseconds(350))
        }
        resolvingID = nil
    }

    // MARK: - 格式化

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.month().day().weekday(.abbreviated))
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
