import SwiftUI

/// 舒适座舱：座椅加热 / 通风、方向盘加热、后视镜加热。
///
/// 和空调页最大的不同是**这一页的状态是真的**：八个座椅信号、方向盘的 `1816`、
/// 后视镜的 `49`/`50` 全在一台 C16 的真实 signalMap 里，档位能直接回显、指令成败能靠信号确认。
/// 所以这里没有「高亮的是本机记录」那种免责声明——草稿只活在点击到车确认之间。
struct ComfortCabinView: View {
    @Environment(VehicleStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize


    /// 当前看的是加热还是通风。纯视图状态，不下发。
    @State private var channel: SeatComfortChannel = .heating
    @State private var confirmingCloseAll = false

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private var tint: Color {
        channel == .heating ? LeapStyle.warm : LeapStyle.cool
    }

    var body: some View {
        ConnectedFeatureScaffold(title: "舒适座舱", tint: tint) {
            VStack(spacing: 16) {
                // 两条通道都读不到任何座位时，分段和座位图整块不画——
                // 不然剩一个只有方向盘图标的空框，等于摆了个点不动的格子。
                if hasAnySeat {
                    channelPicker
                    if hasSeatInChannel { seatMap }
                }
                if store.steeringWheelLevel != nil { steeringWheelCard }
                if store.mirrorHeatingOn != nil { mirrorCard }
                if !hasAnything { emptyNotice }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmingCloseAll = true
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .disabled(!hasAnythingOn)
                .accessibilityLabel("全部关闭")
            }
        }
        .confirmationDialog(
            "关闭所有座舱加热与通风？",
            isPresented: $confirmingCloseAll,
            titleVisibility: .visible
        ) {
            Button("全部关闭", role: .destructive) { store.closeAllCabinComfort() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会把当前开着的座椅、方向盘和后视镜逐条关掉。")
        }
        // 调完档位立刻退出去的话，那条还没发的指令就不该再发了。同空调页。
        .onDisappear { store.cancelPendingCabinPushes() }
    }

    // MARK: - 有没有东西可显示

    /// 任一通道、任一座位读得到。决定要不要画「加热 / 通风」分段。
    private var hasAnySeat: Bool {
        SeatComfortChannel.allCases.contains { channel in
            SeatPosition.allCases.contains { store.seatLevel($0, channel) != nil }
        }
    }

    /// 当前通道下有座位可画。
    private var hasSeatInChannel: Bool {
        SeatPosition.allCases.contains { store.seatLevel($0, channel) != nil }
    }

    private var hasAnything: Bool {
        hasAnySeat || store.steeringWheelLevel != nil || store.mirrorHeatingOn != nil
    }

    private var hasAnythingOn: Bool {
        let seatOn = SeatComfortChannel.allCases.contains { channel in
            SeatPosition.allCases.contains { (store.seatLevel($0, channel) ?? 0) > 0 }
        }
        return seatOn || (store.steeringWheelLevel ?? 0) > 0 || store.mirrorHeatingOn == true
    }

    /// 车况一项都没报回来时给一句话，而不是留一整屏空白。
    /// 注意这不是「本车不支持」——入口本身已经过了支持门控（`VehicleStore.cabinComfortSupported`），
    /// 走到这儿还全空，最常见的原因是车在休眠、这一轮车况字段缺了一片。
    private var emptyNotice: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("暂时读不到座舱状态", systemImage: "moon.zzz.fill")
                    .font(.subheadline.weight(.medium))
                Text("车辆休眠时这一批字段会整片缺失。等车况刷新后会自动出现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - ① 加热 / 通风

    private var channelPicker: some View {
        LeapGlassContainer(spacing: 10) {
            Group {
                if isAccessibilitySize {
                    VStack(spacing: 4) { channelButtons }
                } else {
                    HStack(spacing: 6) { channelButtons }
                }
            }
            .padding(5)
            // 竖排时胶囊会鼓成大椭圆，换圆角矩形。两个分支形状类型不同，用 AnyShape 抹平。
            // 同 `ClimateView.modePicker` 的处理。
            .leapGlass(.regular, in: isAccessibilitySize
                         ? AnyShape(.rect(cornerRadius: LeapStyle.cardRadius))
                         : AnyShape(.capsule))
        }
        .animation(.snappy, value: channel)
    }

    @ViewBuilder
    private var channelButtons: some View {
        ForEach(SeatComfortChannel.allCases) { item in
            Button {
                channel = item
            } label: {
                Label(item.label, systemImage: item.symbol)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(channel == item ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background {
                if channel == item {
                    if isAccessibilitySize {
                        RoundedRectangle(cornerRadius: 18).fill(.primary.opacity(0.14))
                    } else {
                        Capsule().fill(.primary.opacity(0.14))
                    }
                }
            }
            .accessibilityAddTraits(channel == item ? [.isButton, .isSelected] : .isButton)
        }
    }

    // MARK: - ② 车内俯视座位图

    /// 这一行里真能读到档位的座位。整行都读不到就不画这一行——
    /// 不摆灰格子、不写「本车不支持」，照「读不到就别显示」。
    private func visibleSeats(_ row: [SeatPosition]) -> [SeatPosition] {
        row.filter { store.seatLevel($0, channel) != nil }
    }

    private var seatMap: some View {
        VStack(spacing: 18) {
            // 仪表台那一道：方向盘正对主驾座位，一眼看出车头朝上、主驾在左。
            // 用和座位行同宽同间距的两格来摆，图标才会正好压在主驾那一列上。
            HStack(spacing: 26) {
                Image(systemName: "steeringwheel")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.tertiary)
                    .frame(width: 64)
                Color.clear.frame(width: 64, height: 1)
            }
            .accessibilityHidden(true)

            if !visibleSeats(SeatPosition.front).isEmpty {
                seatRow(SeatPosition.front)
            }
            if !visibleSeats(SeatPosition.rear).isEmpty {
                seatRow(SeatPosition.rear)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)
        .leapGlass(.regular, in: .rect(cornerRadius: 28))
        .animation(.snappy, value: channel)
    }

    private func seatRow(_ row: [SeatPosition]) -> some View {
        HStack(spacing: 26) {
            ForEach(row) { position in
                if store.seatLevel(position, channel) != nil {
                    seatTile(position)
                } else {
                    // 同一行里个别座位读不到：留一块等大的透明占位，
                    // 这样左右两座不会因为少一个而跑到中间去。
                    Color.clear.frame(width: 64, height: 93)
                }
            }
        }
    }

    private func seatTile(_ position: SeatPosition) -> some View {
        let level = store.seatLevel(position, channel) ?? 0
        let isOn = level > 0
        let fill: Color = isOn ? tint.opacity(0.24 + 0.26 * Double(level - 1)) : Color.primary.opacity(0.10)

        return Button {
            store.cycleSeat(position, channel)
        } label: {
            VStack(spacing: 6) {
                VStack(spacing: 3) {
                    // 靠背
                    RoundedRectangle(cornerRadius: 7)
                        .fill(fill)
                        .frame(width: 56, height: 16)
                    // 坐垫 + 档位
                    RoundedRectangle(cornerRadius: 12)
                        .fill(fill)
                        .frame(width: 64, height: 52)
                        .overlay {
                            if isOn {
                                Text("\(level)")
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .foregroundStyle(.primary)
                            } else {
                                Image(systemName: channel.symbol)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .overlay {
                            if !isOn {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(LeapStyle.glassEdge, lineWidth: 1)
                            }
                        }
                }
                Text(position.label)
                    .font(.caption2)
                    .foregroundStyle(isOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .frame(width: 64, height: 93)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: level)
        .sensoryFeedback(.selection, trigger: level)
        // 四块色块在 VoiceOver 里全念作「按钮」，分不出来，而且点击循环对它很不友好。
        // 合成一个可调元素：上下轻扫加减档位，跟系统音量条一个用法。同空调页风量柱。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(position.label)座椅\(channel.label)")
        .accessibilityValue(isOn ? "\(level) 档" : "已关闭")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: store.setSeat(position, channel, level: min(channel.maxLevel, level + 1))
            case .decrement: store.setSeat(position, channel, level: max(0, level - 1))
            @unknown default: return
            }
        }
    }

    // MARK: - ③ 方向盘加热

    private var steeringWheelCard: some View {
        let level = store.steeringWheelLevel ?? 0
        return GlassCard(radius: LeapStyle.tileRadius, tint: level > 0 ? LeapStyle.warm : nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("方向盘加热", systemImage: "steeringwheel")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    // 剩余分钟只在加热确实开着时才给——信号 1624 在关闭时也非 0，
                    // 取值判据收在 `VehicleState.steeringWheelHeatMinutes` 里。
                    if let minutes = store.steeringWheelHeatMinutes {
                        Text("约剩 \(minutes) 分钟")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                steeringWheelLevels(current: level)
            }
        }
    }

    /// 方向盘只有两档（弱 / 强），和座椅的三档不是一套量程。
    private func steeringWheelLevels(current: Int) -> some View {
        let options: [(level: Int, label: String)] = [(0, "关"), (1, "弱"), (2, "强")]
        return HStack(spacing: 6) {
            ForEach(options, id: \.level) { option in
                Button {
                    store.setSteeringWheelHeat(level: option.level)
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(current == option.level ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background {
                    if current == option.level {
                        Capsule().fill(.primary.opacity(0.14))
                    }
                }
                .accessibilityAddTraits(current == option.level ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .leapGlass(.regular, in: .capsule)
        .animation(.snappy, value: current)
        .sensoryFeedback(.selection, trigger: current)
    }

    // MARK: - ④ 后视镜加热

    private var mirrorCard: some View {
        let on = store.mirrorHeatingOn ?? false
        return GlassActionCard(radius: LeapStyle.tileRadius, tint: on ? LeapStyle.frost : nil) {
            store.toggleMirrorHeating()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    // 车端那个信号（1946）本来就是「后风挡**及外后视镜**电加热除雾」，
                    // 用后风挡加热这个字形比任何后视镜字形都贴。
                    Label("后视镜加热", systemImage: "windshield.rear.and.heat.waves")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(on ? "已开启" : "已关闭")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(on ? AnyShapeStyle(LeapStyle.frost) : AnyShapeStyle(.secondary))
                }
                // 这是五项里唯一官方 App 自己都没做的功能：内部码 440 在官方包里连中文文案都没有。
                // 按下去没反应时，用户该先知道这件事，而不是以为我们坏了。
                Text(store.state?.mirrorHeatingMismatched == true
                     ? "左右状态不一致 · 该指令未经官方 App 验证"
                     : "轻点切换 · 该指令未经官方 App 验证")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .commandBusy(store.isSendingCommand)
    }
}
