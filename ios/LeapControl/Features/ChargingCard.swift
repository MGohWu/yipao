import SwiftUI

/// 首页的充电模块：插枪在充时出现，回答三个问题——**还要多久、多大功率、充到哪儿了**。
///
/// 参照原厂控车 App 的充电卡：上面一行状态与功率，中间一个大号的「还剩多久」，
/// 下面一条进度（当前电量 → 目标电量），最后一行已充度数与时长的流水。
///
/// 剩余时间的来源有优先级：
/// 1. 车自己报的剩余分钟（`chargeRemainMinutes`）——最准，直接信；
/// 2. 没有就按「还差多少度 ÷ 当前功率」估，度数用 `ChargeRecorder` 学出来的
///    「每 1% 多少度」；充电有损耗，按 92% 折算，否则会比实际乐观一成；
/// 3. 连换算值都还没有（新装、还没充过完整的电）就只显示功率和百分比。
///    **不编一个时间**——一个不准的倒计时比没有更让人焦躁。
struct ChargingCard: View {
    var state: VehicleState
    /// 正在充的这条记录：用来算「已充多少度、已经充了多久」。
    var active: ChargeRecord?
    var kwhPerPercent: Double?

    /// 目标电量。车没报就按 100% 算。
    private var target: Int { min(100, max(1, state.chargeLimit ?? 100)) }
    private var soc: Int? { state.soc }
    private var power: Double? { state.chargePowerKW }

    private var progress: Double {
        guard let soc else { return 0 }
        return min(1, max(0, Double(soc) / Double(target)))
    }

    private var remainingMinutes: Int? {
        if let minutes = state.chargeRemainMinutes, minutes > 0, minutes <= 36 * 60 {
            return minutes
        }
        guard let power, power >= 0.5,
              let per = kwhPerPercent, per > 0,
              let soc, soc < target else { return nil }
        let missingKwh = Double(target - soc) * per
        let hours = missingKwh / (power * 0.92)
        let minutes = Int((hours * 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    /// 预计充满的时刻。没有剩余时间就不给。
    private var finishClock: String? {
        guard let remainingMinutes else { return nil }
        let date = Date().addingTimeInterval(TimeInterval(remainingMinutes * 60))
        return date.formatted(.dateTime.hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            headline
            progressBar
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LeapStyle.surface, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(LeapStyle.accent)
                .frame(width: 6, height: 6)
                .overlay {
                    Circle()
                        .stroke(LeapStyle.accent.opacity(0.45), lineWidth: 1)
                        .scaleEffect(1.9)
                }

            Text("充电中")
                .font(.system(size: 12, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(LeapStyle.accent)

            Spacer(minLength: 8)

            if let power, power > 0 {
                Text(String(format: "%.1f kW", power))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LeapStyle.ink)
            }
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let remainingMinutes {
                Text(durationText(remainingMinutes))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(-0.8)
                    .foregroundStyle(LeapStyle.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else if let soc {
                Text("\(soc)%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(-0.8)
                    .foregroundStyle(LeapStyle.ink)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                if let finishClock {
                    Text("预计 \(finishClock) 充满")
                        .font(.system(size: 11))
                        .foregroundStyle(LeapStyle.secondaryLabel)
                } else if remainingMinutes == nil {
                    Text("剩余时间待估算")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text("目标 \(target)%")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(LeapStyle.hairline)
                Capsule()
                    .fill(LeapStyle.accent)
                    .frame(width: max(4, proxy.size.width * progress))
            }
        }
        .frame(height: 5)
        .animation(.smooth(duration: 0.5), value: progress)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let soc {
                Text("\(soc)%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LeapStyle.ink)
            }
            if let energy = active?.energyKwh, energy > 0.05 {
                Text("·").foregroundStyle(.tertiary)
                Text(String(format: "已充 %.1f kWh", energy))
            }
            if let active {
                Text("·").foregroundStyle(.tertiary)
                Text("已充 \(durationText(Int(active.duration / 60)))")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(LeapStyle.secondaryLabel)
        .monospacedDigit()
    }

    /// 「1 小时 25 分」；不到一小时只给分钟。
    private func durationText(_ minutes: Int) -> String {
        let total = max(1, minutes)
        if total < 60 { return "\(total) 分钟" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }
}
