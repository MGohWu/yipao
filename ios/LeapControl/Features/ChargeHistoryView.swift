import SwiftUI

/// 充电记录。
///
/// 数据是我们自己按 10 秒一次的轮询攒的，不是零跑云端给的——云端没有充电明细接口，
/// 只有里程能耗的按天聚合。所以这一页的说法和 `TripHistoryView` 保持一致：
/// 从头到尾说清数是怎么来的，页脚也不放「合计电费」这种会被拿去对账的数。
///
/// 和行程不同的一点：充电时车是静止的，SoC 只往上涨，所以补记的可信度明显更高，
/// 电量那栏就算是补记也敢给一个数（区间内误差一两个百分点）。
struct ChargeHistoryView: View {
    @Environment(VehicleStore.self) private var store
    @StateObject private var recorder = ChargeRecorder.shared
    /// 地名补齐的进度：正在补哪一条。补的时候那行显示一个细进度条，不遮内容。
    @State private var resolvingID: UUID?

    private var vin: String? { store.session.selectedVin }

    private var charges: [ChargeRecord] {
        if store.isDemo { return ReviewDemo.chargeLog }
        // 老记录没有 vin 的一并显示，别让升级用户觉得记录丢了。
        guard let vin else { return recorder.charges }
        return recorder.charges.filter { $0.vin == nil || $0.vin == vin }
    }

    /// 按天分组，新的一天在上面。
    private var days: [(day: Date, charges: [ChargeRecord])] {
        Dictionary(grouping: charges) { $0.dayStart }
            .map { (day: $0.key, charges: $0.value.sorted { $0.startAt > $1.startAt }) }
            .sorted { $0.day > $1.day }
    }

    /// 近 7 天（含今天）。用近 7 天而不是本周，理由同行程页：周一早上打开时
    /// 「本周」只有一次，看着像数据丢了。
    private var recentCharges: [ChargeRecord] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return charges }
        return charges.filter { $0.startAt >= start }
    }

    var body: some View {
        ZStack {
            LeapBackground(tint: LeapStyle.accent)
            ScrollView {
                VStack(spacing: 14) {
                    if !store.isDemo, let active = recorder.active {
                        activeCard(active)
                    }
                    if charges.isEmpty {
                        emptyCard
                    } else {
                        summaryCard
                        ForEach(days, id: \.day) { group in
                            dayCard(group.day, charges: group.charges)
                        }
                        footer
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("充电记录")
        .navigationBarTitleDisplayMode(.inline)
        // 地名一个个补，只补最近 8 条：一进页面就打十几个反地理编码请求，既慢又没必要。
        .task(id: charges.prefix(8).map(\.id)) {
            await resolveMissingPlaces()
        }
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        let count = recentCharges.count
        let energy = recentCharges.compactMap(\.energyKwh).reduce(0, +)
        let unknown = recentCharges.contains { $0.energyKwh == nil }
        return GlassCard(radius: LeapStyle.tileRadius) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("近 7 天").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if recentCharges.contains(where: \.isReconstructed) {
                        Text("含补记").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 0) {
                    metric("充电", value: "\(count)", unit: "次")
                    divider
                    metric("充入", value: unknown && energy == 0 ? "—" : trimmed(energy), unit: "kWh")
                    divider
                    metric("快充", value: "\(recentCharges.filter { $0.isDC && !$0.isReconstructed }.count)", unit: "次")
                }
            }
        }
    }

    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 34)
    }

    // MARK: - 进行中

    private func activeCard(_ charge: ChargeRecord) -> some View {
        let power = store.state?.chargePowerKW
        return GlassCard(radius: LeapStyle.tileRadius) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LeapStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(LeapStyle.accent.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在充电").font(.subheadline.weight(.semibold))
                    Text("已充 \(durationText(Date().timeIntervalSince(charge.startAt)))"
                        + (power.map { String(format: " · 当前 %.1f kW", $0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let soc = store.state?.soc {
                    Text("\(soc)%")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(LeapStyle.accent)
                }
            }
        }
    }

    // MARK: - 一天

    private func dayCard(_ day: Date, charges: [ChargeRecord]) -> some View {
        let energy = charges.compactMap(\.energyKwh).reduce(0, +)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayTitle(day)).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(energy > 0
                     ? "\(charges.count) 次 · \(trimmed(energy)) kWh"
                     : "\(charges.count) 次")
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.horizontal, 6)

            GlassCard(radius: LeapStyle.tileRadius) {
                VStack(spacing: 0) {
                    ForEach(Array(charges.enumerated()), id: \.element.id) { index, charge in
                        chargeRow(charge)
                        if index < charges.count - 1 {
                            Rectangle().fill(.quaternary).frame(height: 1).padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    private func chargeRow(_ charge: ChargeRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timeText(charge.startAt))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                kindTag(charge)
                Spacer(minLength: 6)
                Text(charge.energyKwh.map { "\(trimmed($0)) kWh" } ?? "电量未知")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            HStack(spacing: 5) {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 10))
                Text(charge.place ?? "地点未知")
                    .lineLimit(1)
                if resolvingID == charge.id {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if let start = charge.startSoc, let end = charge.endSoc, end > start {
                    Label("\(start)% → \(end)%", systemImage: "battery.75percent")
                }
                Label(durationText(charge.duration), systemImage: "clock")
                if let power = charge.maxPowerKw {
                    Label(String(format: "峰值 %.1f kW", power),
                          systemImage: "bolt.horizontal")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
        }
    }

    private func kindTag(_ charge: ChargeRecord) -> some View {
        let (text, color): (String, Color) = {
            if charge.isReconstructed { return ("补记", LeapStyle.caution) }
            return charge.isDC ? ("快充", LeapStyle.warm) : ("慢充", LeapStyle.cool)
        }()
        return Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: .rect(cornerRadius: 4))
            .foregroundStyle(color)
    }

    // MARK: - 空态与说明

    private var emptyCard: some View {
        GlassCard(radius: LeapStyle.tileRadius) {
            VStack(spacing: 10) {
                Image(systemName: "bolt.car.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("还没有充电记录").font(.subheadline.weight(.medium))
                Text("App 开着的时候每 10 秒看一次车况，插枪后电流真的流进电池才开始记，拔枪或车报「充电完成」收尾。App 没在跑的那段，下次打开时会按电量差补一条「补记」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("电量按电压 × 电流随时间积分，与充电桩显示的度数会有几个百分点差距（车载充电机损耗、电池加热都算在里面）。")
            Text("记录在本机，不上传。")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    // MARK: - 地名

    private func resolveMissingPlaces() async {
        guard !store.isDemo else { return }
        let pending = Array(recorder.charges.prefix(8).filter { $0.place == nil })
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
