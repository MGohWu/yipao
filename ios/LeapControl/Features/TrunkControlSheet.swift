import SwiftUI

/// 尾门控制。
///
/// 控车条上原来点一下就直接反转尾门：手机在兜里蹭一下，尾门就在车主看不见的地方掀起来，
/// 而且这个方向是 App 替他判的——车况读不到时判的还可能是反的。
/// 这里把方向交回给用户：开和关都摆出来，点哪个发哪个，不点就什么都不发生。
struct TrunkControlSheet: View {
    @Environment(VehicleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 车报没报尾门状态。没报时一个按钮都不点亮——猜一个「关着」点上去，
    /// 等于替车说了句它没说过的话（和车窗弹窗同一条规矩）。
    private var reportedOpen: Bool? { store.state?.trunkOpen }

    /// S01 / T03 关不了尾门，那个按钮在这些车上就不该出现（依据见 `trunkSupportsClose`）。
    private var supportsClose: Bool {
        LeapCommand.trunkSupportsClose(carType: store.session.selectedCarType)
    }
    private var isDriving: Bool { store.state?.isDriving == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            actions
                .padding(.horizontal, 20)
                // 上一条还在等车确认时 `perform` 会把新指令直接丢掉。挡在这儿，
                // 免得点完是「弹窗关了、车没动、也没人说为什么」。
                .commandBusy(store.isSendingCommand)
            if !supportsClose {
                // 只剩一个按钮的界面不说明白，看着像另一个没加载出来。
                Text("该车型不支持远程关闭尾门。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
        }
        // 别在这儿撑满高度：外面按内容量出来的高度定弹窗高度。
        .padding(.top, SheetMetrics.topInset)
        .padding(.bottom, SheetMetrics.bottomInset)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("尾门")
                .font(.headline)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 20)
    }

    /// 副标题报的是当前状态，不是操作说明——点亮哪个按钮全看这一句，
    /// 车没上报时更要说清楚是「不知道」，否则两个按钮都不亮看着像界面没加载出来。
    private var statusText: String {
        if isDriving { return "行驶中不能操作尾门" }
        guard let reportedOpen else { return "该车型未上报尾门状态" }
        return reportedOpen ? "尾门当前已打开" : "尾门当前已关闭"
    }

    /// 无障碍字号下两个按钮并排会把「打开尾门」压成两行还断字，改成竖排。
    @ViewBuilder
    private var actions: some View {
        let open = action(title: "打开尾门", systemImage: "car.side.rear.open", open: true)
        let close = supportsClose
            ? action(title: "关闭尾门", systemImage: "car.side", open: false)
            : nil
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) { open; close }
        } else {
            HStack(spacing: 8) { open; close }
        }
    }

    private func action(title: String, systemImage: String, open: Bool) -> some View {
        Button {
            store.setTrunk(open: open)
            // 结果提示贴在根视图底部，弹窗开着会把它整个盖住，
            // 关掉才看得到「指令已下发 / 未收到车辆确认」。
            dismiss()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    // 两个字形高矮差着几点，钉死这一行，两个按钮的标题才在同一条线上。
                    .frame(height: 24)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .leapGlassButton()
        // 点亮的是「车现在停在这一侧」，和车窗弹窗的档位按钮一个意思。
        .tint(reportedOpen == open ? LeapStyle.cool : LeapStyle.primaryLabel)
        .accessibilityHint(reportedOpen == open ? "尾门已处于该状态" : "")
        .disabled(isDriving)
    }
}
