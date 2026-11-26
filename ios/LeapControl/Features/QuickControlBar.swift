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
    /// 圆钮从 44 放大到 52 之后，一行按 80 算才装得下。
    private static let rowHeight: CGFloat = 80
    private static let rowSpacing: CGFloat = 8
    /// 展开状态存哪儿。**换过一次 key**：老 key 下默认值是「收起」，于是不充电时
    /// 第二排也一直藏着，只剩一颗「更多控制」——那本来只是给充电时腾地方用的。
    /// 新 key 默认展开，老用户升级后不充电就能看到整排。
    private static let expandedKey = "homeQuickControlExpandedV2"

    @Environment(VehicleStore.self) private var store
    @Binding var showTrunk: Bool
    @Binding var showSunshade: Bool
    @Binding var showSunroof: Bool
    @Binding var showFrunk: Bool
    /// 正在充电。充电时收起第二排（充电卡占了一大块），不充电时恢复展开——
    /// **双向跟随**，不是只收不回。之前只写了「收」，拔枪后第二排还藏着，
    /// 看起来就像上锁解锁这排被吃掉了。
    var collapseWhileCharging: Bool = false
    @State private var controls: [QuickControl]
    /// 展开状态记住：常用第二行的人不必每次进首页都点一下。默认展开。
    @AppStorage(Self.expandedKey) private var expanded = true
    /// 冷启动时就插着枪的话，`onChange` 不会触发（初值没有「变化」），
    /// 得在第一次出现时补收一次，否则一进 App 就是两排。
    @State private var didSyncInitialCharging = false
    @Namespace private var namespace

    init(
        showTrunk: Binding<Bool>,
        showSunshade: Binding<Bool>,
        showSunroof: Binding<Bool>,
        showFrunk: Binding<Bool>,
        collapseWhileCharging: Bool = false
    ) {
        self.collapseWhileCharging = collapseWhileCharging
        _showTrunk = showTrunk
        _showSunshade = showSunshade
        _showSunroof = showSunroof
        _showFrunk = showFrunk
        _controls = State(initialValue: QuickControl.savedOrder)
    }

    private var isDriving: Bool { store.state?.isDriving == true }

    /// 「上锁」亮不亮：**驻车且锁着**才亮。行驶中不亮——行驶中门锁随挡位走，
    /// 远程上锁没有意义，再亮着只会让人以为车停着没动。
    private var lockLit: Bool { store.state?.isLocked == true && !isDriving }
    /// 「解锁」亮不亮：车没锁，或者正在行驶（行驶中锁态不表达「锁没锁」，按解锁画，
    /// 和车上那颗「行驶中」徽章的说法一致）。读不到锁状态时两格都不亮。
    private var unlockLit: Bool { store.state?.isLocked == false || isDriving }
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
        let rest = overflow ? Array(visible.dropFirst(Self.rowCapacity)) : []
        let extraRows = stride(from: 0, to: rest.count, by: Self.rowCapacity).map {
            Array(rest[$0..<min($0 + Self.rowCapacity, rest.count)])
        }
        let showExtraRows = overflow && expanded
        let rowCount = 1 + (showExtraRows ? extraRows.count : 0)

        LeapGlassContainer(spacing: 10) {
            VStack(spacing: 6) {
                GeometryReader { proxy in
                    let slotWidth = proxy.size.width / CGFloat(Self.rowCapacity)
                    VStack(spacing: Self.rowSpacing) {
                        row(firstRow, slotWidth: slotWidth)
                        if showExtraRows {
                            ForEach(extraRows, id: \.first) { row($0, slotWidth: slotWidth) }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(height: Self.rowHeight * CGFloat(rowCount) + Self.rowSpacing * CGFloat(rowCount - 1))

                // chevron 不再挤在格子行尾：那里本来就只有 24pt，塞进去既不对称、
                // 也让人以为它是第五个控制项。改成一条居中的小胶囊，写清「更多控制」。
                if overflow { expandToggle }
            }
        }
        .commandBusy(store.isSendingCommand)
        // 充电时收起第二排（充电卡占了一大块，圆钮少一排，状态卡才不至于被顶出首屏），
        // 不充电时恢复展开。**两个方向都要走**：只收不放的话，拔了枪第二排还藏着，
        // 上锁解锁这一排看起来就像少了一半。
        //
        // 只在「充电状态翻转」那一下动，用户充电中手动展开、或者平时手动收起，
        // 都不会被反复压回去。
        .onChange(of: collapseWhileCharging) { _, charging in
            withAnimation(.smooth(duration: 0.28)) { expanded = !charging }
        }
        // 冷启动就在充电：上面那个 onChange 等不到，这里补收一次。
        // 只做第一次，之后切 Tab 回来不再干预用户的手动展开。
        .onAppear {
            guard !didSyncInitialCharging else { return }
            didSyncInitialCharging = true
            if collapseWhileCharging, expanded {
                withAnimation(.smooth(duration: 0.28)) { expanded = false }
            }
        }
        // 不再套一层玻璃卡：按钮直接坐在画布上，和车、续航块共用同一个背景。
        // 一页里只允许有两类面——画布、和窄卡片。
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    /// 摆一行控制格。不足一行时补空，格子宽度不变，列才对得齐。
    private func row(_ items: [QuickControl], slotWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(items) { slot($0, width: slotWidth) }
            if items.count < Self.rowCapacity {
                ForEach(0..<(Self.rowCapacity - items.count), id: \.self) { _ in
                    Color.clear.frame(width: slotWidth, height: 1)
                }
            }
        }
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.smooth(duration: 0.28)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? "收起" : "更多控制")
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(LeapStyle.primaryLabel.opacity(0.05), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "收起更多控制" : "展开更多控制")
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

    @ViewBuilder
    private func controlButton(_ control: QuickControl) -> some View {
        switch control {
        case .lock:
            // 驻车且锁着才亮（见 `lockLit`）。读不到锁状态时不亮：猜一个「已锁」亮起来，
            // 等于向车主保证了一件我们并不知道的事。
            QuickControlButton(
                title: "上锁",
                systemImage: "car.side.lock.fill",
                highlighted: lockLit,
                accessibilityValue: lockStateDescription,
                action: store.lockCar
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .unlock:
            // 和「上锁」成对：车没锁、或者行驶中，这一格亮。读不到状态时两格都不亮。
            QuickControlButton(
                title: "解锁",
                systemImage: "car.side.lock.open.fill",
                highlighted: unlockLit,
                accessibilityValue: lockStateDescription,
                action: store.unlockCar
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .trunk:
            QuickControlButton(
                title: "尾门",
                // 车尾特写的一对：同一段车尾，关着是描边、开着填实并上色。
                systemImage: trunkOpen ? "car.side.rear.open.crop.fill" : "car.side.rear.open.crop",
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
                highlighted: store.climateOn,
                accessibilityValue: store.climateOn ? "运行中" : "已关闭",
                action: { store.applyClimate(on: !store.climateOn) }
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .horn:
            QuickControlButton(
                title: "鸣笛",
                systemImage: "speaker.wave.2.fill",
                action: store.honk
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .sentinel:
            // 和另外三个新按钮不同，哨兵有状态回读（信号 3636）也没有物理风险，
            // 就地 toggle（原哨兵卡就是这个交互），不弹层。
            QuickControlButton(
                title: "哨兵",
                systemImage: store.sentinelOn ? "shield.fill" : "shield",
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
                action: { showSunshade = true }
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .sunroof:
            QuickControlButton(
                title: "天窗",
                systemImage: "rectangle.topthird.inset.filled",
                action: { showSunroof = true }
            )
            .leapGlassID(control.rawValue, in: namespace)
        case .frunk:
            // 车头特写的一对，和尾门那对同一个语言：关着是描边、开着填实并上色。
            QuickControlButton(
                title: "前备箱",
                systemImage: frunkOpen ? "car.side.front.open.crop.fill" : "car.side.front.open.crop",
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
/// 形态照官方 App：一枚圆形图标 + 下面一行小字。
/// - 常态：淡灰圆底、深灰图标；
/// - 开启：**实心绿底、白色图标**，小字跟着变绿。
///
/// 之前是「图标直接落在玻璃卡上、只在激活时换文字颜色」，一排看过去分不出谁开着，
/// 而且玻璃卡和图标之间没有边界，整块看着发虚。加了圆底之后每个动作有自己的一块地方，
/// 激活时是实心的，扫一眼就能数出开了几个。
struct QuickControlButton: View {
    var title: String
    var systemImage: String
    var highlighted: Bool = false
    var accessibilityValue: String?
    var action: () -> Void
    var disabled: Bool = false

    /// 每按一次加一，喂给 `.symbolEffect(.bounce)`。用计数而不是 Bool：
    /// Bool 从 false 翻到 true 之后，第二次按就没有「变化」可触发了。
    @State private var taps = 0

    private var glyphColor: Color {
        highlighted ? .white : LeapStyle.ink.opacity(0.78)
    }

    /// 常态是描边、激活是实心——和 `docs/UI-PROPOSAL.md` 里方向 G 的按键一个逻辑：
    /// 平时只有一圈线，按下去被填满，扫一眼就知道哪几个是开着的。
    private var circleFill: Color {
        highlighted ? LeapStyle.accent : LeapStyle.surface
    }

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(circleFill)
                        .frame(width: 52, height: 52)
                        .overlay {
                            Circle().stroke(highlighted ? .clear : LeapStyle.hairline, lineWidth: 1)
                        }
                        .shadow(color: highlighted ? LeapStyle.accent.opacity(0.25) : .clear,
                                radius: 8, y: 2)
                        .shadow(color: highlighted ? LeapStyle.accent.opacity(0.35) : .clear,
                                radius: 8, y: 3)

                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(glyphColor)
                        .symbolEffect(.bounce, value: taps)
                        .contentTransition(.symbolEffect(.replace))
                }
                .animation(.smooth(duration: 0.26), value: highlighted)

                Text(title)
                    .font(.system(size: 11, weight: highlighted ? .semibold : .regular))
                    .tracking(0.3)
                    .foregroundStyle(highlighted ? LeapStyle.accent : LeapStyle.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .animation(.smooth(duration: 0.26), value: highlighted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .disabled(disabled)
        .buttonStyle(QuickControlPressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityHint("长按并拖动可调整位置")
    }
}

/// 按下时的反馈：整格缩一下（弹簧），圆底上再浮一层淡色。
///
/// 首页这些按钮很多是「按一下、等车响应」的，没有即时反馈会让人以为没点到，
/// 于是连按三四下。缩放 + 底色是给手指的确认，不是装饰。
private struct QuickControlPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(LeapStyle.accent.opacity(configuration.isPressed ? 0.14 : 0))
                    .frame(width: 56, height: 56)
                    .offset(y: -8)
            }
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: configuration.isPressed)
    }
}
