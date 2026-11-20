import SwiftUI

/// 遮阳帘 / 天窗 / 前备箱共用的「开 / 关」弹层。
///
/// 交互规矩照抄尾门（`TrunkControlSheet`）：方向不由 App 替用户猜，开和关都摆出来，
/// 点哪个发哪个，不点就什么都不发生。差别收在 `Kind` 里：前备箱有车况位（信号 1282）
/// 能点亮当前侧、且行驶中禁用；遮阳帘 / 天窗车况里没有对应字段，两个按钮都不点亮，
/// 副标题直说「不上报状态」——不猜一个状态点上去（和尾门、车窗弹窗同一条规矩）。
struct TwoStateControlSheet: View {
    /// 一种控制的静态描述。当前状态走闭包，弹层每次 body 时现读 store，不在这里存快照。
    struct Kind {
        var title: String
        var openTitle: String
        var closeTitle: String
        var openSymbol: String
        var closeSymbol: String
        /// 车报没报当前状态。读不到（`nil`）时副标题用 `noStatusText` 交代。
        var reportedOpen: (VehicleStore) -> Bool?
        var noStatusText: String
        /// 行驶中要不要禁用。`perform` 里按 cmdid 还有一道拦截，这里是界面上先说清楚、按钮先变灰。
        var blocksWhileDriving: Bool
        var send: (VehicleStore, Bool) -> Void

        // 三个静态描述钉在 MainActor 上：闭包里碰的是 MainActor 的 `VehicleStore`，
        // 非隔离的 static 在 Swift 6 并发检查下过不去；调用方全在 View.body，本来就在主线程。
        @MainActor static let sunshade = Kind(
            title: "遮阳帘",
            openTitle: "打开遮阳帘",
            closeTitle: "关闭遮阳帘",
            openSymbol: "curtains.open",
            closeSymbol: "curtains.closed",
            // 遮阳帘开度信号 `1724`。实测 C16 在报；不报的车仍是 nil，副标题照旧交代。
            reportedOpen: { $0.state?.sunshadeOpen },
            noStatusText: "车辆不上报遮阳帘状态",
            blocksWhileDriving: false,
            send: { $0.setSunshade(open: $1) }
        )

        // SF Symbols 没有天窗图形，开 / 关各用一个到顶 / 到底的箭头示意方向。
        @MainActor static let sunroof = Kind(
            title: "天窗",
            openTitle: "打开天窗",
            closeTitle: "关闭天窗",
            openSymbol: "arrow.up.to.line",
            closeSymbol: "arrow.down.to.line",
            // 天窗开度信号 `1718`，报 15 / 150 这类占位值时 `sunroofOpen` 已经当读不到处理。
            reportedOpen: { $0.state?.sunroofOpen },
            noStatusText: "车辆不上报天窗状态",
            blocksWhileDriving: false,
            send: { $0.setSunroof(open: $1) }
        )

        @MainActor static let frunk = Kind(
            title: "前备箱",
            openTitle: "打开前备箱",
            closeTitle: "关闭前备箱",
            openSymbol: "car.side.front.open",
            closeSymbol: "car.side",
            reportedOpen: { $0.state?.frontTrunkOpen },
            noStatusText: "该车型未上报前备箱状态",
            blocksWhileDriving: true,
            send: { $0.setFrunk(open: $1) }
        )
    }

    var kind: Kind

    @Environment(VehicleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var reportedOpen: Bool? { kind.reportedOpen(store) }
    private var isDriving: Bool { kind.blocksWhileDriving && store.state?.isDriving == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            actions
                .padding(.horizontal, 20)
                // 上一条还在等车确认时 `perform` 会把新指令直接丢掉。挡在这儿，
                // 免得点完是「弹窗关了、车没动、也没人说为什么」。
                .commandBusy(store.isSendingCommand)
        }
        // 别在这儿撑满高度：外面按内容量出来的高度定弹窗高度。
        .padding(.top, SheetMetrics.topInset)
        .padding(.bottom, SheetMetrics.bottomInset)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(kind.title)
                .font(.headline)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 20)
    }

    /// 副标题报的是当前状态，不是操作说明——点亮哪个按钮全看这一句，
    /// 车没上报（或压根不上报）时更要说清楚是「不知道」。
    private var statusText: String {
        if isDriving { return "行驶中不能操作\(kind.title)" }
        guard let reportedOpen else { return kind.noStatusText }
        return reportedOpen ? "\(kind.title)当前已打开" : "\(kind.title)当前已关闭"
    }

    /// 无障碍字号下两个按钮并排会把标题压成两行还断字，改成竖排（同尾门弹层）。
    @ViewBuilder
    private var actions: some View {
        let open = action(title: kind.openTitle, systemImage: kind.openSymbol, open: true)
        let close = action(title: kind.closeTitle, systemImage: kind.closeSymbol, open: false)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) { open; close }
        } else {
            HStack(spacing: 8) { open; close }
        }
    }

    private func action(title: String, systemImage: String, open: Bool) -> some View {
        Button {
            kind.send(store, open)
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
        // 点亮的是「车现在停在这一侧」，和尾门 / 车窗弹窗一个意思；不上报状态的控制两边都不亮。
        .tint(reportedOpen == open ? LeapStyle.cool : LeapStyle.primaryLabel)
        .accessibilityHint(reportedOpen == open ? "\(kind.title)已处于该状态" : "")
        .disabled(isDriving)
    }
}
