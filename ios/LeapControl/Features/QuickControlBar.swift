import SwiftUI

enum QuickControl: String, CaseIterable, Identifiable {
    /// 上锁。rawValue 沿用原来那个翻转式「车锁」的 `lock`，存过的排序不用迁移这一格。
    case lock
    /// 解锁（2026-11-19 从「车锁」拆出来）。
    case unlock
    case trunk
    case climate
    case horn
    case sentinel
    case sunshade
    case sunroof
    case frunk

    static let orderKey = "homeQuickControlOrder"

    var id: String { rawValue }

    static var savedOrder: [QuickControl] {
        let saved = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        return order(from: saved)
    }

    /// 把存下的排序还原成完整列表。
    ///
    /// 拆分之前存的排序里只有 `lock`（那时它是翻转式的「车锁」）。新出的「解锁」紧跟在它后面，
    /// 不是追加到末尾——车主原来把车锁放在哪儿，上锁 / 解锁这一对就还在哪儿。
    /// 其余没存过的照旧追加到末尾。
    static func order(from saved: [String]) -> [QuickControl] {
        var decoded = saved.compactMap(QuickControl.init(rawValue:))
        if !decoded.contains(.unlock), let index = decoded.firstIndex(of: .lock) {
            decoded.insert(.unlock, at: index + 1)
        }
        return decoded + allCases.filter { !decoded.contains($0) }
    }

    static func save(_ controls: [QuickControl]) {
        UserDefaults.standard.set(controls.map(\.rawValue), forKey: orderKey)
    }
}

/// 车辆舞台下方的横向遥控卡。它是当前车辆的操作面板，不承担页面导航，也不固定在
/// Tab Bar 上方。即时动作收在一张卡内，和底部一级导航形成明确的形态差异。
///
/// 按钮文案一律是名词（车锁 / 空调 / 尾门 / 鸣笛……），不写「关空调」这类动作词——
/// 它们和旁边的名词按钮并排时会被读成状态，看到「解锁」会以为车已经开着。
/// 当前状态由图标和文字的颜色表达，具体的动作在无障碍值里说。
///
/// **唯一的例外是「上锁」「解锁」**（2026-11-19 拆开）：翻转式的「车锁」要先看清
/// 现在是什么状态才知道点下去会发什么，车况一滞后就会发反。拆成两格后方向写在按钮上，
/// 点哪个发哪个；状态改由「解锁」那格在车没锁时亮琥珀色来表达，两格都始终能点
/// （车况可能滞后，重复上锁也无害，置灰反而可能把真正要按的那个灰掉）。
///
/// 只有「反常」的那一档才上色：车没锁、尾门开着、空调开着。锁好了是常态，
/// 天天给它亮一格颜色等于每天报告一件没发生的事。
///
/// 控制项超过一行（4 个）时收起成「前 4 个 + 行尾 chevron」，点 chevron 向下展开其余各行。
/// 哪 4 个在收起时可见不另做编辑界面——就是现有的长按拖拽排序：排在前面的就是常用的。
/// 车不支持的控制（判据见各 `Vehicle.supports*`）整格隐藏，项目不够一行就没有 chevron。
struct QuickControlBar: View {
    /// 一行摆几个。9 项全支持时收起 4 个、展开后再摆两行（4 + 1）。
    private static let rowCapacity = 4
    private static let rowHeight: CGFloat = 70
    private static let rowSpacing: CGFloat = 8
    private static let expandedKey = "homeQuickControlExpanded"

    @Environment(VehicleStore.self) private var store
    @Binding var showTrunk: Bool
    @Binding var showSunshade: Bool
    @Binding var showSunroof: Bool
    @Binding var showFrunk: Bool
    @State private var controls: [QuickControl]
    /// 展开状态记住：常用第二行的人不必每次进首页都点一下。
    @AppStorage(Self.expandedKey) private var expanded = false
    @Namespace private var namespace

    init(
        showTrunk: Binding<Bool>,
        showSunshade: Binding<Bool>,
        showSunroof: Binding<Bool>,
        showFrunk: Binding<Bool>
    ) {
        _showTrunk = showTrunk
        _showSunshade = showSunshade
        _showSunroof = showSunroof
        _showFrunk = showFrunk
        _controls = State(initialValue: QuickControl.savedOrder)
    }

    private var locked: Bool { store.state?.isLocked ?? true }
    /// 两格的无障碍值都报当前状态：按钮名已经是动作，状态得另外说。
    private var lockStateDescription: String {
        switch store.state?.isLocked {
        case true?: "当前已锁车"
        case false?: "当前已解锁"
        case nil: "锁状态未上报"
        }
    }
    /// 尾门读不到就按关着画。开着是要提醒的异常，猜一个「开着」出来天天报警更糟。
    private var trunkOpen: Bool { store.state?.trunkOpen ?? false }
    /// 前备箱同尾门：读不到按关着画。
    private var frunkOpen: Bool { store.state?.frontTrunkOpen ?? false }
    private var isDriving: Bool { store.state?.isDriving == true }

    /// 车不支持的控制整格隐藏（不是置灰：摆一个永远点不了的按钮等于承诺了做不到的事）。
    private func isSupported(_ control: QuickControl) -> Bool {
        switch control {
        case .lock, .unlock, .trunk, .climate, .horn: true
        case .sentinel: store.sentinelSupported
        case .sunshade: store.sunshadeSupported
        case .sunroof: store.sunroofSupported
        case .frunk: store.frunkSupported
        }
    }

    var body: some View {
        let visible = controls.filter(isSupported)
        let overflow = visible.count > Self.rowCapacity
        let firstRow = overflow ? Array(visible.prefix(Self.rowCapacity)) : visible
        // 展开部分按每行 4 个切开。拆出「解锁」之后全支持是 9 项，展开部分有 5 个，
        // 塞进一行会按 4 格的宽度排 5 个、挤出卡片。
        let rest = overflow ? Array(visible.dropFirst(Self.rowCapacity)) : []
        let extraRows = stride(from: 0, to: rest.count, by: Self.rowCapacity).map {
            Array(rest[$0..<min($0 + Self.rowCapacity, rest.count)])
        }
        let showExtraRows = overflow && expanded
        let rowCount = 1 + (showExtraRows ? extraRows.count : 0)

        LeapGlassContainer(spacing: 8) {
            GeometryReader { proxy in
                // chevron 不占一个整格：它是布局开关不是控制项，占格会把四个真按钮挤瘦一号。
                let chevronWidth: CGFloat = overflow ? 24 : 0
                let slotCount = overflow ? Self.rowCapacity : max(firstRow.count, 1)
                let slotWidth = (proxy.size.width - chevronWidth) / CGFloat(slotCount)

                VStack(spacing: Self.rowSpacing) {
                    HStack(spacing: 0) {
                        ForEach(firstRow) { control in
                            slot(control, width: slotWidth)
                        }
                        if overflow { chevron }
                    }
                    if showExtraRows {
                        ForEach(extraRows, id: \.first) { row in
                            HStack(spacing: 0) {
                                ForEach(row) { control in
                                    slot(control, width: slotWidth)
                                }
                                // 不足一行时左对齐补空，列和第一行对齐。
                                Spacer(minLength: 0)
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
            .frame(height: Self.rowHeight * CGFloat(rowCount) + Self.rowSpacing * CGFloat(rowCount - 1))
        }
        .commandBusy(store.isSendingCommand)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
    }

    private func slot(_ control: QuickControl, width: CGFloat) -> some View {
        controlButton(control)
            .frame(width: width)
            .contentShape(
                .dragPreview,
                RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .draggable(control.rawValue) {
                dragPreview(control)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let rawValue = items.first,
                      let dragged = QuickControl(rawValue: rawValue) else {
                    return false
                }
                reorder(dragged, before: control)
                return true
            }
    }

    private var chevron: some View {
        Button {
            withAnimation(.smooth) { expanded.toggle() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .frame(width: 24)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "收起更多控制" : "展开更多控制")
    }

    @ViewBuilder
    private func controlButton(_ control: QuickControl) -> some View {
        switch control {
        case .lock:
            // 上锁是回到常态，永远不上色。
            QuickControlButton(
                title: "上锁",
                systemImage: "car.side.lock.fill",
                tint: .primary,
                accessibilityValue: lockStateDescription,
                action: store.lockCar
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .unlock:
            // 车没锁是要提醒的反常，由这一格亮琥珀色来说。读不到锁状态时按锁着画，不上色。
            QuickControlButton(
                title: "解锁",
                systemImage: "car.side.lock.open.fill",
                tint: locked ? .primary : LeapStyle.caution,
                highlighted: !locked,
                accessibilityValue: lockStateDescription,
                action: store.unlockCar
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .trunk:
            QuickControlButton(
                title: "尾门",
                // 车尾特写的一对：同一段车尾，关着是描边、开着填实并上色。
                systemImage: trunkOpen ? "car.side.rear.open.crop.fill" : "car.side.rear.open.crop",
                tint: trunkOpen ? LeapStyle.caution : .primary,
                highlighted: trunkOpen,
                accessibilityValue: store.state?.trunkOpen == nil
                    ? "状态未上报"
                    : (trunkOpen ? "已打开" : "已关闭"),
                action: { showTrunk = true },
                disabled: isDriving
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .climate:
            QuickControlButton(
                title: "空调",
                systemImage: store.climateOn ? "fan.fill" : "fan",
                tint: store.climateOn ? LeapStyle.cool : .primary,
                highlighted: store.climateOn,
                accessibilityValue: store.climateOn ? "运行中" : "已关闭",
                action: { store.applyClimate(on: !store.climateOn) }
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .horn:
            QuickControlButton(
                title: "鸣笛",
                systemImage: "speaker.wave.2.fill",
                tint: .primary,
                action: store.honk
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .sentinel:
            // 和另外三个新按钮不同，哨兵有状态回读（信号 3636）也没有物理风险，
            // 就地 toggle（原哨兵卡就是这个交互），不弹层。
            QuickControlButton(
                title: "哨兵",
                systemImage: store.sentinelOn ? "shield.fill" : "shield",
                tint: store.sentinelOn ? LeapStyle.cool : .primary,
                highlighted: store.sentinelOn,
                accessibilityValue: store.sentinelOn ? "已开启" : "已关闭",
                action: { store.applySentinel(!store.sentinelOn) }
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .sunshade:
            // 车况里没有遮阳帘状态，图标不做两态、不上色；方向在弹层里由用户明确点。
            QuickControlButton(
                title: "遮阳帘",
                systemImage: "curtains.closed",
                tint: .primary,
                action: { showSunshade = true }
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .sunroof:
            QuickControlButton(
                title: "天窗",
                systemImage: "rectangle.topthird.inset.filled",
                tint: .primary,
                action: { showSunroof = true }
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .frunk:
            // 车头特写的一对，和尾门那对同一个语言：关着是描边、开着填实并上色。
            QuickControlButton(
                title: "前备箱",
                systemImage: frunkOpen ? "car.side.front.open.crop.fill" : "car.side.front.open.crop",
                tint: frunkOpen ? LeapStyle.caution : .primary,
                highlighted: frunkOpen,
                accessibilityValue: store.state?.frontTrunkOpen == nil
                    ? "状态未上报"
                    : (frunkOpen ? "已打开" : "已关闭"),
                action: { showFrunk = true },
                disabled: isDriving
            )
            .leapGlassID(control.rawValue, in: namespace)
        }
    }

    @ViewBuilder
    private func dragPreview(_ control: QuickControl) -> some View {
        controlButton(control)
            .frame(width: 76, height: 64)
            .padding(.horizontal, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(
                .dragPreview,
                RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
    }

    private func reorder(_ dragged: QuickControl, before target: QuickControl) {
        guard let sourceIndex = controls.firstIndex(of: dragged),
              let targetIndex = controls.firstIndex(of: target),
              sourceIndex != targetIndex else { return }

        withAnimation(.smooth) {
            controls.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
        QuickControl.save(controls)
    }
}

/// 控车条里的一个动作。
///
/// 不给底色。这一行长在一张玻璃卡里，谁激活就给谁糊一块彩色圆角底的话，卡上就多出
/// 几块浮着的色块，和底下几张卡的排版对不上。激活状态改由图标和文字一起上色表达——
/// 同一个信息，不额外占一层。
///
/// 图标尺寸也不跟着激活变：原来激活的那一格会从 19 涨到 21，四列的图标行就不齐了。
struct QuickControlButton: View {
    var title: String
    var systemImage: String
    var tint: Color
    var highlighted: Bool = false
    var accessibilityValue: String?
    var action: () -> Void
    var disabled: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 42, height: 34)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(highlighted ? tint : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .disabled(disabled)
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityHint("长按并拖动可调整位置")
    }
}
