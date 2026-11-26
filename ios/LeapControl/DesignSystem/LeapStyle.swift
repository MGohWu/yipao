import SwiftUI
import UIKit

/// 全局视觉语言。
///
/// 这一版改成**中性画布 + 状态色**：界面本身只有灰阶，颜色只用来表达车在干什么
/// （在充电 = 绿、异常 = 红、加热 = 橙）。这和 `stephenwang1011/leapauto` 的做法一致——
/// 玻璃是承载车辆状态的容器，花花绿绿的背景会把车本身盖过去。
///
/// 画布是接近中性的暖灰（浅）/ 曜石黑（深），带一层很淡的光；卡片靠折射和边缘高光立起来，
/// 不再靠彩色光晕。
enum LeapStyle {
    static let cardRadius: CGFloat = 28
    static let tileRadius: CGFloat = 24

    // MARK: - 配色
    //
    // 五组色都是明暗两套。浅色版是压暗过的——同一套颜色铺在浅色玻璃上当文字，
    // 对比度不够（WCAG AA 要 4.5:1）；深色版则是提亮过的，放在深底上才立得起来。
    //
    // 注意：这些色同时被拿去画背景的极光。极光是大面积色块，用不了压暗的版本，
    // 所以 `LeapBackground` 会按明暗各自混色，见那边的说明。

    /// 强调色：深绿。**只表示「有电在流动」**——充电中、刚充满、电量健康。
    /// 色相压得比常见的「新能源绿」更暗、更灰，配暖白纸感底色才不刺眼。
    static let accent = adaptive(
        light: Color(red: 0.18, green: 0.42, blue: 0.31),
        dark: Color(red: 0.19, green: 0.82, blue: 0.35)
    )

    /// 卡片底色。暗色下比纯黑亮一档，卡片才浮得起来；浅色下就是白。
    static let surface = adaptive(
        light: Color.white,
        dark: Color(red: 0.086, green: 0.086, blue: 0.094)
    )

    /// 链接色：只给「能点进去」的那几处（位置、充电上限）。
    static let link = adaptive(
        light: Color(red: 0.18, green: 0.36, blue: 0.82),
        dark: Color(red: 0.24, green: 0.42, blue: 0.88)
    )

    /// 界面主色：墨。选中态、主按钮、Tab 用它。
    static let ink = adaptive(
        light: Color(red: 0.12, green: 0.11, blue: 0.09),
        dark: Color(red: 0.96, green: 0.96, blue: 0.97)
    )

    /// 警示：砖红。胎压异常、门没关、没锁车。
    static let alert = adaptive(
        light: Color(red: 0.70, green: 0.15, blue: 0.12),
        dark: Color(red: 1.0, green: 0.27, blue: 0.23)
    )

    /// 冷色：石灰。位置、导航这类中性信息。
    static let cool = adaptive(
        light: Color(red: 0.43, green: 0.41, blue: 0.38),
        dark: Color(red: 0.72, green: 0.70, blue: 0.66)
    )
    /// 暖色：赭石。座椅/方向盘加热。
    static let warm = adaptive(
        light: Color(red: 0.55, green: 0.35, blue: 0.11),
        dark: Color(red: 0.90, green: 0.72, blue: 0.45)
    )
    /// 提醒：和告警同色系但轻一档——补记、暂不可用这类「知道就好」的状态。
    static let caution = adaptive(
        light: Color(red: 0.52, green: 0.38, blue: 0.12),
        dark: Color(red: 1.0, green: 0.82, blue: 0.58)
    )

    /// 除霜专用。不能用 `.primary`：深色模式下它是纯白，玻璃按钮被白色一染就成了亮底。
    static let frost = adaptive(
        light: Color(red: 0.10, green: 0.40, blue: 0.42),
        dark: Color(red: 0.42, green: 0.82, blue: 0.84)
    )

    /// 「有值但不是当前重点」的填充。
    static let mutedFill = adaptive(
        light: Color(white: 0.55),
        dark: Color(white: 1.0).opacity(0.6)
    )

    /// 首页那辆车的填充。不能用 `.primary`——浅色下会变成一整块纯黑剪影。
    static let vehicleSilhouette = adaptive(
        light: Color(red: 0.30, green: 0.28, blue: 0.25),
        dark: Color(red: 0.95, green: 0.94, blue: 0.91)
    )

    /// `.primary` / `.secondary` 的**具体颜色**版本，专门给 `.tint(...)` 用。
    ///
    /// 这两个语义值本身是 `HierarchicalShapeStyle`，不是 `Color`。把它们喂给 tint，
    /// 在 iOS 26 的液态玻璃上会绕成死循环（要解析 tint → 要算 fallbackColor → 又回头问材质），
    /// 主线程两千多帧后栈溢出。走 UIKit 的 label 色拿一个实打实的动态颜色，明暗两套和
    /// `.primary` 一模一样，只是不再是层次样式。
    static let primaryLabel = Color(uiColor: .label)
    static let secondaryLabel = Color(uiColor: .secondaryLabel)

    /// 玻璃降级后的边缘线。iOS 26 的液态玻璃自带边缘高光，低版本的毛玻璃没有，
    /// 卡片和背景会糊成一片，得手动描一道。
    static let glassEdge = adaptive(
        light: Color(red: 0.85, green: 0.83, blue: 0.79),
        dark: Color.white.opacity(0.10)
    )

    /// 卡片里那条分隔线。比 `.quaternary` 更淡一点，成排卡片看着才不吵。
    static let hairline = adaptive(
        light: Color(red: 0.855, green: 0.835, blue: 0.796),
        dark: Color(red: 0.14, green: 0.14, blue: 0.15)
    )

    /// SwiftUI 没有直接声明明暗两套颜色的写法，绕一下 UIKit。
    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

/// 车辆主视觉背景：充电时偏薄荷、空调制热时偏暖，其余偏靛蓝。
///
/// 上一版是叠几个椭圆光晕，再往前是 MeshGradient 极光；这一版全部收掉，
/// 只留「中性底色 + 一片顶光 + 一圈暗角」。理由和配色一致：底色越安静，
/// 车模和卡片越立得住。
struct LeapBackground: View {
    var tint: Color
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            if isDark { darkLayers } else { lightLayers }
            vignette
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 1.1), value: tint)
    }

    // MARK: - 深色：曜石黑 + 一片很淡的顶光

    private var darkLayers: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color.black,
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 只留一片中性顶光。彩色极光会把车模盖住——车才是这一页的主角。
            RadialGradient(
                colors: [Color.white.opacity(0.05), .clear],
                center: .init(x: 0.5, y: 0.06),
                startRadius: 10,
                endRadius: 380
            )
        }
    }

    // MARK: - 浅色：暖浅灰 + 顶部反射

    private var lightLayers: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.972, green: 0.962, blue: 0.942),
                    Color(red: 0.955, green: 0.944, blue: 0.922),
                    Color(red: 0.925, green: 0.914, blue: 0.888)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 顶部一层极淡的白，模拟屏幕边缘的反射，避免整片灰到底。
            RadialGradient(
                colors: [Color.white.opacity(0.85), .clear],
                center: .init(x: 0.5, y: -0.05),
                startRadius: 10,
                endRadius: 480
            )
        }
    }

    /// 暗角。四周压一点点，视觉重心收到中间。
    private var vignette: some View {
        RadialGradient(
            colors: [.clear, .clear, Color.black.opacity(isDark ? 0.0 : 0.08)],
            center: .init(x: 0.5, y: 0.38),
            startRadius: 80,
            endRadius: 640
        )
    }
}

/// 玻璃卡片：内容 + 统一圆角 + 液态玻璃材质。
struct GlassCard<Content: View>: View {
    var radius: CGFloat = LeapStyle.cardRadius
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
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
                .padding(18)
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
            .font(.caption.weight(.medium))
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
                .tracking(-0.5)
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
    /// 而 SF Symbol 在同一字号下高矮并不齐：几颗并排一行，底边就参差。
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
