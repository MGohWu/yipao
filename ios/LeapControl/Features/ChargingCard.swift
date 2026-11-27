import SwiftUI

/// 首页的充电模块：插枪在充时出现，回答三个问题——**还要多久、多大功率、充到哪儿了**。
///
/// 参照原厂控车 App 的充电卡：上面一行状态与功率，中间一个大号的「还剩多久」，
/// 下面一条进度（当前电量 → 目标电量），最后一行是已充度数的流水。
///
/// 右上角有一个小三角，点开才露出「结束充电」：停充是**不可撤回**的动作
/// （停完要重新插枪或上车操作才能继续），不摆在明面上，避免手掌擦一下就停掉一晚上的充电。
/// 展开之后再问一次，文案和充电页保持一致。
///
/// 剩余时间的来源有优先级：
/// 1. 车自己报的剩余分钟（`chargeRemainMinutes`）——最准，直接信；
/// 2. 没有就按「还差多少度 ÷ 当前功率」估，度数用 `ChargeRecorder` 学出来的
///    「每 1% 多少度」；充电有损耗，按 92% 折算，否则会比实际乐观一成；
/// 3. 连换算值都还没有（新装、还没充过完整的电）就只显示功率和百分比。
///    **不编一个时间**——一个不准的倒计时比没有更让人焦躁。
struct ChargingCard: View {
    var state: VehicleState
    /// 正在充的这条记录：用来算「已充多少度」。**不给已充时长**——官方没有
    /// 「充电开始时间/已持续时长」的接口（车况只报状态、剩余时间、功率；云端明细
    /// 只覆盖已结算的场次），本机从「第一次观察到在充电」起算，App 重开就归零，
    /// 充了一夜显示「已充 1 分钟」纯粹是误导，宁可不展示。
    var active: ChargeRecord?
    var kwhPerPercent: Double?

    @Environment(VehicleStore.self) private var store
    /// 「结束充电」是否已展开。默认收起——见类型注释。
    @State private var showStopAction = false
    @State private var confirmingStop = false

    /// 目标电量。车没报就按 100% 算。
    private var target: Int { min(100, max(1, state.chargeLimit ?? 100)) }
    private var soc: Int? { state.soc }
    private var power: Double? { state.chargePowerKW }

    private var progress: Double {
        guard let soc else { return 0 }
        return min(1, max(0, Double(soc) / Double(target)))
    }

    /// 本次充电已结束（车报 `chargeState == 2`：充满、手动停充都走这个值）。
    /// 卡片不因此消失，改画收尾状态——「充完了」必须有个交代，整张消失
    /// 会让人以为数据丢了。枪拔没拔由首页决定（拔了整卡隐藏）。
    private var finished: Bool { state.chargeState == 2 }

    /// 结束方式的措辞：充满和停充共用 `chargeState == 2`，用电量到没到目标区分。
    private var finishedLabel: String {
        (soc ?? 0) >= target ? "已充满" : "已结束充电"
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
            if finished {
                finishedHeadline
            } else {
                headline
            }
            progressBar
            footer

            // 展开后才占高度：收起时卡片和原来一模一样，不因为多了个入口变高。
            if showStopAction, !finished {
                stopAction
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LeapStyle.surface, in: .rect(cornerRadius: 18, style: .continuous))
        .animation(.smooth(duration: 0.4), value: finished)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if finished {
                // 收尾状态用一颗实心对勾替换脉冲圆点：圆点是「进行中」的语言，
                // 对勾是「办完了」的语言，一眼区分两个阶段。
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LeapStyle.accent)
                Text("充电完成")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(LeapStyle.accent)
            } else {
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
            }

            Spacer(minLength: 8)

            if !finished, let power, power > 0 {
                Text(String(format: "%.1f kW", power))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LeapStyle.ink)
            }

            // 22pt 的小三角，比整张卡片可点安全：卡片本身还要显示信息，
            // 整块可点会让「想看数据」和「想停充电」撞在同一个手势上。
            // 充完就没有可停的东西了，这个入口整个撤掉。
            if !finished {
                Button {
                    withAnimation(.smooth(duration: 0.24)) { showStopAction.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LeapStyle.secondaryLabel)
                        .rotationEffect(.degrees(showStopAction ? 180 : 0))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多充电操作")
                .accessibilityHint(showStopAction ? "收起结束充电" : "展开结束充电")
            }
        }
    }

    /// 充电结束后的主行：大号当前电量 + 一句话说明结束方式。
    /// 「已充满」上强调绿，「已结束充电」（提前停的）保持中性灰——
    /// 没充满不是错误，不该用告警色。
    private var finishedHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let soc {
                Text("\(soc)%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(-0.8)
                    .foregroundStyle(LeapStyle.ink)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(finishedLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle((soc ?? 0) >= target ? LeapStyle.accent : LeapStyle.secondaryLabel)
                Text("目标 \(target)%")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 「结束充电」。**红色实心文字 + 10% 红底**：这是这张卡里唯一能做破坏性操作的地方，
    /// 不能长得像普通按钮；但也不填满整块红，那段面积太大，看着像页面出错了。
    private var stopAction: some View {
        Button {
            confirmingStop = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(store.isSendingCommand ? "正在结束…" : "结束充电")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(LeapStyle.alert)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                LeapStyle.alert.opacity(0.10),
                in: .rect(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.isSendingCommand)
        // 和充电页同一句：停完不会自己恢复，得重新插枪或上车。
        .confirmationDialog("结束充电？", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("结束充电", role: .destructive) {
                store.setCharging(start: false)
                withAnimation(.smooth(duration: 0.2)) { showStopAction = false }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("停止后需要重新插枪或在车机上操作才能继续充电。")
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
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(LeapStyle.secondaryLabel)
        .monospacedDigit()
    }

    /// 「1 小时 25 分」；不到一小时只给分钟。给「预计还需」用的，不是已充时长。
    private func durationText(_ minutes: Int) -> String {
        let total = max(1, minutes)
        if total < 60 { return "\(total) 分钟" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }
}
