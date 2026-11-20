import SwiftUI
import UIKit

/// 全局视觉语言。液态玻璃需要底下有内容才有折射感，
/// 所以背景不是纯色，而是随车辆状态变化的渐变 + 光晕。
enum LeapStyle {
    static let cardRadius: CGFloat = 26
    static let tileRadius: CGFloat = 22

    // MARK: - 配色
    //
    // 这五个色都是明暗两套。原来只有一套（现在的深色版），是照着深色底调的，
    // 放到浅色玻璃上当文字用全部不及格——实测对比度：
    // 除霜 1.5:1、快速降温 2.2:1、快速制热 2.1:1，WCAG AA 要求 4.5:1。
    // 浅色版是把同一个色相压暗、加饱和，重新量过都在 4.7:1 以上。
    //
    // 注意：这些色同时被拿去画背景光晕。光晕是大面积色块，用不了压暗的版本，
    // 所以 LeapBackground 在浅色模式下会先把 tint 往白里调，见那边的说明。

    static let accent = adaptive(
        light: Color(red: 0.03, green: 0.44, blue: 0.24),
        dark: Color(red: 0.30, green: 0.77, blue: 0.49)
    )
    static let cool = adaptive(
        light: Color(red: 0.13, green: 0.36, blue: 0.78),
        dark: Color(red: 0.42, green: 0.66, blue: 1.0)
    )
    static let warm = adaptive(
        light: Color(red: 0.72, green: 0.28, blue: 0.03),
        dark: Color(red: 1.0, green: 0.55, blue: 0.35)
    )
    static let caution = adaptive(
        light: Color(red: 0.62, green: 0.36, blue: 0.0),
        dark: Color(red: 1.0, green: 0.82, blue: 0.54)
    )

    /// 除霜专用。不能用 `.primary`：深色模式下它是纯白，玻璃按钮被白色一染就成了亮底，
    /// 排在快速降温、快速制热旁边活像已经选中。也不能用低饱和的灰蓝——`.glass` 的底色
    /// 是跟着 tint 的饱和度走的，越接近灰就越白，一样会亮出来。
    /// 所以给一个和 cool/warm 饱和度相当、色相又岔开的冰蓝／深青。
    static let frost = adaptive(
        light: Color(red: 0.02, green: 0.42, blue: 0.48),
        dark: Color(red: 0.36, green: 0.86, blue: 0.90)
    )

    /// 「有值但不是当前重点」的填充，比如空调关着时亮起的风量柱。
    /// 原来直接写 `Color.primary.opacity(0.6)`，深色下是柔和的浅灰，
    /// 浅色下 primary 翻成黑，就变成一排很重的深灰块。
    static let mutedFill = adaptive(
        light: Color(white: 0.52),
        dark: Color(white: 1.0).opacity(0.6)
    )

    /// 首页那辆车的填充。同样不能用 `.primary`——浅色下会变成一整块纯黑剪影。
    static let vehicleSilhouette = adaptive(
        light: Color(white: 0.46),
        dark: Color(white: 1.0).opacity(0.88)
    )

    /// `.primary` / `.secondary` 的**具体颜色**版本，专门给 `.tint(...)` 用。
    ///
    /// 这两个语义值本身是 `HierarchicalShapeStyle`，不是 `Color`。把它们喂给 tint，
    /// 在 iOS 26 的液态玻璃上会绕成死循环：玻璃材质要解析 tint → 层次样式要算 fallbackColor
    /// → 又回头问材质要底色 → 再解析 tint……主线程两千多帧后栈溢出，
    /// 崩在弹窗呈现那一刻（TestFlight 1787199222 / 1787295067 两条崩溃就是这个）。
    ///
    /// 走 UIKit 的 label 色拿一个实打实的动态颜色，明暗两套和 `.primary` 一模一样，
    /// 只是不再是层次样式，玻璃拿到它就直接用了，不会反过来求值。
    static let primaryLabel = Color(uiColor: .label)
    static let secondaryLabel = Color(uiColor: .secondaryLabel)

    /// 玻璃降级后的边缘线。iOS 26 的液态玻璃自带边缘高光，低版本的毛玻璃没有，
    /// 卡片和背景会糊成一片，得手动描一道。深色下是白边（高光），浅色下是黑边（阴影）。
    static let glassEdge = adaptive(
        light: Color.black.opacity(0.09),
        dark: Color.white.opacity(0.16)
    )

    /// SwiftUI 没有直接声明明暗两套颜色的写法，绕一下 UIKit。
    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

/// 车辆主视觉背景：充电时偏绿、空调制热时偏暖，其余偏冷蓝。
struct LeapBackground: View {
    var tint: Color
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    /// 光晕用的颜色。浅色模式下先把 tint 往白里调再用：
    /// 那几个主题色的浅色版是压暗过的（为了当文字能读），原样铺成一大片光晕
    /// 会在屏幕顶上糊出一块脏。光晕只要色相，不需要对比度。
    ///
    /// 混白的比例原来是 70%，冲得太狠——整屏基本剩下灰，玻璃卡片浮在灰上
    /// 没有可折射的东西，看着就是「素」。降到 40%：色相回来了，又还没到糊脏的程度。
    private var glow: Color {
        isDark ? tint : tint.mix(with: .white, by: 0.32)
    }

    /// 浅色底色。原来是中性灰（0.99 → 0.88），和玻璃、和光晕都不搭腔，
    /// 而且太白——白底上液态玻璃没有可折射的东西，卡片和背景糊成一片。
    ///
    /// 换成带冷调的灰，并且**从上往下明显压深**：顶部留亮（车模在那儿，深了压车），
    /// 中下部是卡片扎堆的地方，底色够深卡片的边缘和高光才立得起来。
    private static let lightBase = [
        Color(red: 0.95, green: 0.96, blue: 0.98),
        Color(red: 0.88, green: 0.91, blue: 0.95),
        Color(red: 0.78, green: 0.83, blue: 0.90)
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: isDark
                    ? [Color(white: 0.09), Color(white: 0.04), .black]
                    : Self.lightBase,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 顶部光晕给玻璃提供折射源，否则玻璃在纯色背景上几乎看不见。
            EllipticalGradient(
                colors: [glow.opacity(isDark ? 0.45 : 0.68), .clear],
                center: .init(x: 0.5, y: 0.06),
                startRadiusFraction: 0,
                endRadiusFraction: 0.75
            )
            .ignoresSafeArea()

            EllipticalGradient(
                colors: [(isDark ? LeapStyle.cool : LeapStyle.cool.mix(with: .white, by: 0.32)).opacity(isDark ? 0.24 : 0.5), .clear],
                center: .init(x: 0.9, y: 0.8),
                startRadiusFraction: 0,
                endRadiusFraction: 0.62
            )
            .ignoresSafeArea()

            // 左下再补一团，压住那个角。两团光晕分别在右下和顶部，浅色下左下角
            // 是整屏唯一一块什么都没有的地方，卡片落在那儿边缘会消失。
            // 用 tint 的补色方向（accent）而不是再来一团 cool，免得整屏只有一个色相。
            if !isDark {
                EllipticalGradient(
                    colors: [LeapStyle.accent.mix(with: .white, by: 0.45).opacity(0.36), .clear],
                    center: .init(x: 0.02, y: 0.62),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.5
                )
                .ignoresSafeArea()
            }
        }
        .animation(.smooth(duration: 0.9), value: tint)
    }
}

/// 玻璃卡片：内容 + 统一圆角 + 液态玻璃材质。
struct GlassCard<Content: View>: View {
    var radius: CGFloat = LeapStyle.cardRadius
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .leapGlass(
                tint.map { LeapGlass.regular.tint($0.opacity(0.5)) } ?? .regular,
                in: .rect(cornerRadius: radius)
            )
    }
}

/// 可点按的玻璃卡片，按下时有交互式高光。
struct GlassActionCard<Content: View>: View {
    var radius: CGFloat = LeapStyle.cardRadius
    var tint: Color?
    var action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .leapGlass(
            (tint.map { LeapGlass.regular.tint($0.opacity(0.5)) } ?? .regular).interactive(),
            in: .rect(cornerRadius: radius)
        )
    }
}

/// 卡片里的标题小字。
struct CardLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// 数值 + 单位的排版，统一用等宽数字避免刷新时跳动。
struct MetricValue: View {
    var value: String
    var unit: String?
    var size: CGFloat = 30
    var weight: Font.Weight = .medium

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: size, weight: weight, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: max(11, size * 0.38), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 顶部状态胶囊，比如"已锁车""充电中"。
struct StatusPill: View {
    var text: String
    var systemImage: String
    var tint: Color

    /// 高度得定死，不能交给 `Label` 撑。撑出来的是 max(符号占位, 文字行高)，
    /// 而 SF Symbol 在同一字号下高矮并不齐：12pt/medium 实测 `car.side.lock.fill`
    /// 连 padding 一共 30pt、`steeringwheel` 28pt、`car.side.rear.open.crop.fill`
    /// 只有 27pt。几颗并排一行，底边就参差。
    /// 跟着 caption 缩放，动态字号调大时胶囊照样长高。
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 28

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .frame(height: height)
            .leapGlass(.regular.tint(tint.opacity(0.22)), in: .capsule)
    }
}

/// 按行摆放、放不下就换行。
///
/// SwiftUI 到 iOS 18 都没有自带的流式布局：`LazyVGrid` 的列宽是固定的，
/// 五个长短不一的标签排进去会留出大片空当。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    /// 每行水平居中（首页车图下那排徽章用；反馈页的分类签保持默认左对齐）。
    var centersRows = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height + spacing }
        return CGSize(width: width == .infinity ? rows.map(\.width).max() ?? 0 : width,
                      height: max(0, height - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = centersRows ? bounds.minX + (bounds.width - row.width) / 2 : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                // 行内垂直居中。放在行顶的话，同一行里高矮不一的标签会底边错位——
                // 那正是眼睛最先看出来的地方。
                let dy = (row.height - size.height) / 2
                subviews[index].place(at: CGPoint(x: x, y: y + dy), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension View {
    /// `navigationSubtitle` 是 iOS 26 才有的槽位，但首页副标题承载的是「等待车辆响应」
    /// 「有车门未关闭」这类必须看见的状态，不能在低版本上悄悄丢掉。
    /// 低版本改用导航栏中央的自定义视图，把标题和副标题摞成两行。
    ///
    /// 导航栏的高度不跟着动态字号长，所以副标题限一行并允许缩放——
    /// 缩到看不清也没关系，VoiceOver 读的是完整文本。
    @ViewBuilder
    func leapNavigationSubtitle(_ subtitle: String, title: String) -> some View {
        if #available(iOS 26.0, *) {
            navigationSubtitle(subtitle)
        } else {
            toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// 指令下发中时压暗并禁用，避免重复点击。
    func commandBusy(_ busy: Bool) -> some View {
        disabled(busy)
            .opacity(busy ? 0.55 : 1)
            .animation(.easeOut(duration: 0.2), value: busy)
    }
}
