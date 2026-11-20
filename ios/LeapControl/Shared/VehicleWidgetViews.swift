import SwiftUI
import WidgetKit

struct WidgetPreviewEditor {
    var actions: [WidgetAction]
    var select: (WidgetAction) -> Void
    var selected: WidgetAction? = nil
    var move: (WidgetAction, WidgetAction) -> Void = { _, _ in }
}

extension EnvironmentValues {
    @Entry var widgetPreviewEditor: WidgetPreviewEditor? = nil
}

/// 桌面卡片的各尺寸视图。放在共享层是为了 App 内也能预览核对，
/// 卡片扩展只保留 WidgetKit 的时间线装配。

struct VehicleWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    var snapshot: VehicleSnapshot
    /// 官方图层叠出来的车图，主 App 每次叠完写进 App Group。大尺寸的主视觉用。
    var carImage: Image?
    /// App 内的画廊没有真实的 widgetFamily 环境值（这个键只读，注入不进去），
    /// 所以显式传一个。画廊必须走这里，否则预览验不到内边距那一层。
    var familyOverride: WidgetFamily?

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    /// 桌面卡片的内边距由这里说了算，不再依赖系统默认边距。
    ///
    /// 实测桌面上的默认边距只有 3pt 左右，而添加卡片时的预览又是另一个值——
    /// 同一份视图两处长得不一样。所以配置里关掉系统边距（`contentMarginsDisabled`），
    /// 三种尺寸各自写死，两边才一致。锁屏样式本来就该贴边，不加。
    /// 卡片扩展在时间线阶段（非主线程）也要读它，所以标 nonisolated。
    nonisolated static func contentPadding(for family: WidgetFamily) -> CGFloat? {
        switch family {
        case .systemSmall, .systemMedium: return 15
        case .systemLarge: return 17
        default: return nil
        }
    }

    private var contentPadding: CGFloat? { Self.contentPadding(for: family) }

    var body: some View {
        // nil 表示不加内边距（锁屏样式），所以用接受可选值的这个 padding 重载。
        content.padding(.all, contentPadding)
            .widgetURL(LeapDeepLink.home)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall: SmallVehicleView(snapshot: snapshot)
        case .systemMedium: MediumVehicleView(snapshot: snapshot)
        case .systemLarge: LargeVehicleView(snapshot: snapshot, carImage: carImage)
        case .accessoryCircular: CircularVehicleView(snapshot: snapshot)
        case .accessoryRectangular: RectangularVehicleView(snapshot: snapshot)
        case .accessoryInline: InlineVehicleView(snapshot: snapshot)
        default: SmallVehicleView(snapshot: snapshot)
        }
    }
}

// MARK: - 小尺寸

private struct SmallVehicleView: View {
    @Environment(\.widgetPreviewEditor) private var editor
    var snapshot: VehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(snapshot.vehicleName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if snapshot.isCharging {
                    // 功率占住右上角这一格。小卡下面那行摆不下「剩余时间 + 功率」两项，
                    // 剩余时间一长功率就被挤成省略号；挪上来这行就只剩剩余时间，摆得开。
                    // 功率本身就意味着在充电，所以它替掉原来那个孤零零的闪电图标，
                    // 只有读不到功率时才退回图标——总得有个东西说明车在充电。
                    if let power = snapshot.chargePowerText {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                            Text(power)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LeapPalette.accent)
                        .lineLimit(1)
                        // 三位数功率（快充 120.5 kW）加上长一点的车名会顶到一起，
                        // 宁可整体缩一点也不截断。
                        .minimumScaleFactor(0.75)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LeapPalette.accent)
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(snapshot.soc.map(String.init) ?? "--")
                    .font(.system(size: 36, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let range = snapshot.rangeKm {
                    Text("\(range) km")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            SnapshotEnergyBars(snapshot: snapshot)
                .padding(.top, 5)

            // 功率已经在右上角，这里只剩剩余时间——读不到就整行不摆。
            if snapshot.isCharging, snapshot.chargeRemainingText != nil {
                ChargeMetricsLine(snapshot: snapshot, showsPower: false)
                    .padding(.top, 5)
            }

            Spacer(minLength: 8)

            // 小卡只放两个最常用的动作，再多就挤到看不清图标了。
            HStack(spacing: 7) {
                ForEach(editor?.actions ?? SharedSettings.widgetButtons(small: true), id: \.rawValue) { action in
                    ConfiguredActionTile(action: action, snapshot: snapshot, height: 54)
                }
            }
        }
    }
}

struct ConfiguredActionTile: View {
    var action: WidgetAction
    var snapshot: VehicleSnapshot
    var height: CGFloat = 60

    var body: some View {
        switch action {
        case .toggleLock:
            LockActionTile(snapshot: snapshot, height: height)
        case .trunk:
            TrunkActionTile(snapshot: snapshot, height: height)
        default:
            ActionTile(
                action: action,
                systemImage: action == .toggleClimate && snapshot.climateOn ? "fan.fill" : action.symbol,
                title: action == .horn ? "鸣笛" : action.title,
                prominent: action == .lock || action == .unlock || (action == .toggleClimate && snapshot.climateOn),
                tint: action == .lock ? LeapPalette.accent : (action == .unlock ? LeapPalette.caution : LeapPalette.cool),
                height: height
            )
        }
    }
}

/// 卡片上唯一的按钮样式：圆角方块，图标在上文字在下。
/// 小尺寸用它单独做锁车键，中/大尺寸用它拼网格——三种规格因此看起来是一家人。
struct ActionTile: View {
    @Environment(\.widgetPreviewEditor) private var editor
    @State private var isDropTarget = false
    var action: WidgetAction
    var systemImage: String
    var title: String
    /// 主要动作（锁车）用实心底色，次要动作用淡底。
    var prominent: Bool = false
    var tint: Color = LeapPalette.cool
    var height: CGFloat = 60

    /// 直控须同时开启开关并保存操作密码；否则打开 App 完成验证。
    var body: some View {
        if let editor {
            if editor.selected != nil {
                editingButton(editor)
                    .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 14))
                    .draggable(action.rawValue) {
                        label.frame(width: 72)
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard items.count == 1, let raw = items.first,
                              let source = WidgetAction(rawValue: raw),
                              editor.actions.contains(source), source != action else { return false }
                        editor.move(source, action)
                        return true
                    } isTargeted: { isDropTarget = $0 }
            } else {
                editingButton(editor)
            }
        } else if WidgetControlRunner.canDispatchDirectly {
            Button(intent: VehicleControlIntent(action: action)) { label }
                .buttonStyle(.plain)
        } else {
            Button(intent: OpenVehicleActionIntent(action: action)) { label }
                .buttonStyle(.plain)
        }
    }

    private func editingButton(_ editor: WidgetPreviewEditor) -> some View {
        Button { editor.select(action) } label: {
            label
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(LeapPalette.accent, lineWidth: isDropTarget || editor.selected == action ? 2 : 0)
                }
                .overlay(alignment: .topTrailing) {
                    if editor.selected != nil {
                        Image(systemName: "circle.grid.2x3.fill")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更换\(action.title)按钮")
        .accessibilityAddTraits(editor.selected == action ? .isSelected : [])
        .onChange(of: editor.selected) { _, selected in
            if selected == nil { isDropTarget = false }
        }
    }

    private var label: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(action == .unlock ? AnyShapeStyle(Color.primary) :
            prominent ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            tint.opacity(prominent ? 0.20 : 0.10),
            in: .rect(cornerRadius: 14)
        )
    }
}

/// 车锁键。文案固定是名词，和旁边的空调/尾门并排时才不会被读成状态；
/// 当前是锁着还是开着由图标和配色表达（绿色闭锁 = 已锁）。
struct LockActionTile: View {
    var snapshot: VehicleSnapshot
    var height: CGFloat = 60

    var body: some View {
        ActionTile(
            action: .toggleLock,
            systemImage: snapshot.lockSymbol,
            title: "车锁",
            // 读不到锁状态时不着重：着重色是在说「我知道车现在什么样」，
            // 而这时候并不知道。淡底 + 中性前景，和锁车卡的「状态未知」一个意思。
            prominent: snapshot.isLocked != nil,
            tint: tint,
            height: height
        )
    }

    private var tint: Color {
        switch snapshot.isLocked {
        case true: LeapPalette.accent
        case false: LeapPalette.caution
        case nil: .gray
        }
    }
}

/// 尾门键。判据和 App 内快控条那颗键保持一致（`QuickControlBar`）。
///
/// 尾门开着是个该被看见的状态——车停在那儿后备箱敞着，卡片上只显示一个灰键
/// 等于没说。读不到（nil）按关着画：不亮只是中性外观，不会替车编出「已关」。
struct TrunkActionTile: View {
    var snapshot: VehicleSnapshot
    var height: CGFloat = 60

    private var open: Bool { snapshot.trunkOpen == true }

    var body: some View {
        ActionTile(
            action: .trunk,
            systemImage: open ? "car.side.rear.open" : "car.side.rear.crop.trunk.partition",
            title: "尾门",
            prominent: open,
            tint: open ? LeapPalette.caution : LeapPalette.cool,
            height: height
        )
    }
}

// MARK: - 中尺寸

private struct MediumVehicleView: View {
    @Environment(\.widgetPreviewEditor) private var editor
    var snapshot: VehicleSnapshot

    var body: some View {
        HStack(spacing: 14) {
            infoColumn
            actionGrid.frame(width: 146)
        }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(snapshot.vehicleName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if snapshot.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LeapPalette.accent)
                }
            }

            Spacer(minLength: 2)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(snapshot.soc.map(String.init) ?? "--")
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !snapshot.hasFuel, let range = snapshot.rangeKm {
                    Text("\(range) km")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if snapshot.hasFuel, let range = snapshot.mediumRangeText {
                Text(range)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            SnapshotEnergyBars(snapshot: snapshot)
                .padding(.top, 7)

            if snapshot.isCharging, snapshot.hasChargeMetrics {
                ChargeMetricsLine(snapshot: snapshot)
                    .padding(.top, 6)
            }

            Spacer(minLength: 2)

            let failure = WidgetControlFeedback.recentFailure
            Text(failure ?? snapshot.headline)
                .font(.system(size: 10))
                .foregroundStyle(
                    failure != nil || snapshot.needsAttention
                        ? AnyShapeStyle(LeapPalette.caution)
                        : AnyShapeStyle(.tertiary)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// 2×2 等大网格。四个动作块尺寸一致，和大尺寸卡片用的是同一个组件。
    private var actionGrid: some View {
        VStack(spacing: 7) {
            ForEach(0..<2) { row in
                HStack(spacing: 7) {
                    ForEach(Array((editor?.actions ?? SharedSettings.widgetButtons(small: false))[(row * 2)..<(row * 2 + 2)]), id: \.rawValue) { action in
                        ConfiguredActionTile(action: action, snapshot: snapshot, height: 62)
                    }
                }
            }
        }
    }
}

// MARK: - 大尺寸

private struct LargeVehicleView: View {
    @Environment(\.widgetPreviewEditor) private var editor
    var snapshot: VehicleSnapshot
    /// 官方图层叠出来的那张车图。取不到（3D 资源没下完、关了「显示车模型」、
    /// 演示态）就退回剪影，和 `LockWidgetView` 缺图时是同一个处理。
    var carImage: Image?

    /// 车图最宽只占卡片内容宽度的七成，两侧留白。3D 渲染器截来的图比图层叠出来的
    /// 那张大不少，摆满会把整张卡压垮。
    private let carWidthRatio: CGFloat = 0.7

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            carSection
            energySection
            if snapshot.isCharging, snapshot.hasChargeMetrics {
                ChargeMetricsLine(snapshot: snapshot)
                    .padding(.top, 6)
            }
            actionRow
                .padding(.top, 14)
        }
    }

    // MARK: 标题行

    /// 车名摆左边，车停在哪、车况多旧摆右边。
    ///
    /// 续航不在这一行——它跟着各自的能量条走（见 `energySection`）：增程车电和油
    /// 各有一个续航数，摆在标题行只能拼成「电 312 · 油 380 km」那样一长串，
    /// 而摆到条子旁边，哪个数属于哪一格是自明的。
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(snapshot.vehicleName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            // 状态和「多久前」拼成一句：这一行右边只剩这么点地方，两句话分不开摆。
            // 失败时不拼时间——那一刻要说的是「刚才那下没成」，几分钟前的车况不相干。
            let failure = WidgetControlFeedback.recentFailure
            Text(failure ?? "\(snapshot.headline) · \(snapshot.freshnessCompact)")
                .font(.caption)
                .foregroundStyle(
                    failure != nil || snapshot.needsAttention
                        ? AnyShapeStyle(LeapPalette.caution)
                        : AnyShapeStyle(.secondary)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: 主视觉

    /// 中间这块摆车，不摆地图。
    ///
    /// 车停在哪已经由上面那句地名说了，而一张没有比例尺也没法缩放的静态地图截图并不比
    /// 那句话多说什么——它只在「车不在你以为的地方」时才有用，而那种时候人本来就会点进
    /// App 看实时地图。换成车图之后这张卡一眼能认出是哪台车，三端的大卡也终于长成同一个样子。
    ///
    /// 高度不写死：车吃掉标题行和读数行之间的所有余量，增程车那格更高时自己让出来。
    private var carSection: some View {
        GeometryReader { proxy in
            ZStack {
                if let carImage {
                    // 写进 App Group 时已经裁掉了四周透明边，这里只管压宽度。
                    carImage
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: proxy.size.width * carWidthRatio)
                } else {
                    // 缺图时和锁车卡共用同一档剪影色，两张卡不该一个深一个浅。
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(LockWidgetPalette.silhouette)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 读数区

    /// 车图下面这块读数。增程车切成左右对称的两段，电一段油一段，各自带一个续航数。
    ///
    /// 官方和车端都不给综合续航——电和油本来就是两个数，用一条总条子把它们并起来，
    /// 等于替车主编了一个车上根本没有的读数。纯电车没有第二段，那一段整个不摆，
    /// 剩下的一段铺满整行（不是留半边空着）。
    private var energySection: some View {
        HStack(alignment: .top, spacing: 14) {
            energySegment(
                icon: "bolt.fill",
                iconTint: snapshot.isCharging ? AnyShapeStyle(LeapPalette.accent) : AnyShapeStyle(.tertiary),
                percent: snapshot.soc,
                // 纯电车的续航就是快照里那个总数；增程车才有单独的纯电续航。
                km: snapshot.energyRangeKm ?? (snapshot.gasolinePercent == nil ? snapshot.rangeKm : nil)
            )
            if let fuel = snapshot.gasolinePercent {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 34)
                energySegment(
                    icon: "fuelpump.fill",
                    iconTint: AnyShapeStyle(.tertiary),
                    percent: fuel,
                    km: snapshot.fuelRangeKm
                )
            }
        }
    }

    /// 一段读数：图标 + 百分比 + 续航，底下压一条进度条。
    /// 续航读不到就整个不摆那个数——空着比写个 `--` 老实，也比编一个数强。
    private func energySegment(
        icon: String,
        iconTint: AnyShapeStyle,
        percent: Int?,
        km: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(iconTint)
                Text(percent.map(String.init) ?? "--")
                    .font(.system(size: 28, weight: .regular, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let km {
                    Text("\(km) km")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            SnapshotEnergyBar(percent: percent ?? 0, highlighted: snapshot.isCharging && icon == "bolt.fill")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 动作区

    /// 四个等宽动作块，和中尺寸网格用的是同一个组件。
    private var actionRow: some View {
        HStack(spacing: 8) {
            ForEach(editor?.actions ?? SharedSettings.widgetButtons(small: false), id: \.rawValue) { action in
                ConfiguredActionTile(action: action, snapshot: snapshot, height: 64)
            }
        }
    }
}

/// 充电时的剩余时间和功率。只画读得到的那一项，两项都读不到时调用方就不该摆这一行
/// （见 `VehicleSnapshot.hasChargeMetrics`）。
private struct ChargeMetricsLine: View {
    let snapshot: VehicleSnapshot
    /// 小尺寸把功率挪到了右上角（见 `SmallVehicleView`），这一行就只留剩余时间。
    var showsPower = true

    var body: some View {
        HStack(spacing: 8) {
            if let remaining = snapshot.chargeRemainingText {
                Label(remaining, systemImage: "clock")
            }
            if showsPower, let power = snapshot.chargePowerText {
                Label(power, systemImage: "bolt.fill")
            }
        }
        .font(.caption2)
        .foregroundStyle(LeapPalette.accent)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
}

// MARK: - 锁屏

private struct CircularVehicleView: View {
    var snapshot: VehicleSnapshot

    var body: some View {
        Gauge(value: Double(snapshot.soc ?? 0), in: 0...100) {
            Image(systemName: snapshot.isCharging ? "bolt.fill" : "car.fill")
        } currentValueLabel: {
            Text(snapshot.soc.map(String.init) ?? "--")
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(LeapDeepLink.charge)
    }
}

private struct RectangularVehicleView: View {
    var snapshot: VehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: snapshot.lockSymbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(snapshot.vehicleName)
                    .font(.headline)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text("\(snapshot.soc.map(String.init) ?? "--")%")
                    .monospacedDigit()
                if let range = snapshot.rangeKm {
                    Text("· \(range) km")
                }
                if snapshot.isCharging {
                    Image(systemName: "bolt.fill")
                }
            }
            .font(.caption)
            let failure = WidgetControlFeedback.recentFailure
            Text(failure ?? snapshot.headline)
                .font(.caption2)
                .foregroundStyle(failure != nil ? AnyShapeStyle(LeapPalette.caution) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .widgetURL(LeapDeepLink.home)
    }
}

private struct InlineVehicleView: View {
    var snapshot: VehicleSnapshot

    var body: some View {
        Label {
            Text("\(snapshot.soc.map(String.init) ?? "--")% · \(snapshot.lockText)")
        } icon: {
            Image(systemName: snapshot.isCharging ? "bolt.fill" : "car.fill")
        }
        .widgetURL(LeapDeepLink.home)
    }
}

// MARK: - 能量条

/// 电量条；增程车再叠一条同款油量条，各带一个小图标区分（和首页那张卡一致）。
/// 纯电车没有油量数据，只画电量一条，跟以前一样。
private struct SnapshotEnergyBars: View {
    var snapshot: VehicleSnapshot

    var body: some View {
        if let fuel = snapshot.gasolinePercent {
            VStack(spacing: 3) {
                labeledBar(
                    "bolt.fill",
                    value: snapshot.soc ?? 0,
                    fill: snapshot.isCharging ? LeapPalette.accent : LeapPalette.accent.opacity(0.85)
                )
                labeledBar("fuelpump.fill", value: fuel, fill: LeapPalette.accent.opacity(0.85))
            }
        } else {
            SnapshotBatteryBar(snapshot: snapshot)
        }
    }

    private func labeledBar(_ icon: String, value: Int, fill: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(width: 9)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fill)
                        .frame(width: proxy.size.width * CGFloat(min(100, max(0, value))) / 100)
                }
            }
            .frame(height: 5)
        }
    }
}

/// 大卡分段读数里的那条进度条。和 `SnapshotEnergyBars` 画的是同一根条子，
/// 只是标签由外面自己摆——分段布局里图标要和百分比同行，不能再挤在条子左边。
private struct SnapshotEnergyBar: View {
    var percent: Int
    var highlighted: Bool = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(highlighted ? LeapPalette.accent : LeapPalette.accent.opacity(0.85))
                    .frame(width: proxy.size.width * CGFloat(min(100, max(0, percent))) / 100)
            }
        }
        .frame(height: 5)
    }
}

private struct SnapshotBatteryBar: View {
    var snapshot: VehicleSnapshot

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(snapshot.isCharging ? LeapPalette.accent : LeapPalette.accent.opacity(0.85))
                    .frame(width: proxy.size.width * CGFloat(min(100, max(0, snapshot.soc ?? 0))) / 100)
            }
        }
        .frame(height: 5)
    }
}


// MARK: - 预览包装

/// 各尺寸视图本身是文件私有的，这几个包装只是把它们暴露给 App 内的预览屏，
/// 让排版核对和桌面上真正渲染的是同一套代码。
struct SmallVehicleWidgetPreview: View {
    var snapshot: VehicleSnapshot
    var body: some View {
        VehicleWidgetView(snapshot: snapshot, familyOverride: .systemSmall)
    }
}

struct MediumVehicleWidgetPreview: View {
    var snapshot: VehicleSnapshot
    var body: some View {
        VehicleWidgetView(snapshot: snapshot, familyOverride: .systemMedium)
    }
}

struct LargeVehicleWidgetPreview: View {
    var snapshot: VehicleSnapshot
    var carImage: Image?
    var body: some View {
        VehicleWidgetView(snapshot: snapshot, carImage: carImage, familyOverride: .systemLarge)
    }
}
