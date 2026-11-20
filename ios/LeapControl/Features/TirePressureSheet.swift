import SwiftUI

/// 四轮胎压。按车辆俯视图摆位，左右两列夹着车身，位置和实车一一对应，
/// 不用再去读"左前/右后"才知道说的是哪个轮子。
///
/// 只读：胎压没有对应的远控命令，车端也不上报推荐值，所以这里不给"标准范围"，
/// 只如实显示数值和车端自己的告警位。
struct TirePressureSheet: View {
    @Environment(VehicleStore.self) private var store

    private var tires: [(label: String, kPa: Double?, warning: Bool)] {
        store.state?.tirePressures ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if tires.isEmpty || store.state?.hasTireData != true {
                emptyState
            } else {
                diagram
                    .padding(.horizontal, 20)
                footnote
            }
        }
        // 不要在这儿放 Spacer 撑满：外面按内容实际高度定弹窗高度，
        // 撑满的话量出来的就永远是弹窗自己的高度，成了死循环。
        .padding(.top, SheetMetrics.topInset)
        .padding(.bottom, SheetMetrics.bottomInset)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("胎压")
                .font(.headline)
            Text(store.state?.hasTireWarning == true ? "有轮胎胎压异常" : "四轮胎压正常")
                .font(.caption2)
                .foregroundStyle(store.state?.hasTireWarning == true
                                 ? AnyShapeStyle(LeapStyle.caution)
                                 : AnyShapeStyle(.tertiary))
        }
        .padding(.bottom, 20)
    }

    /// 上排是前轮、下排是后轮，车身画在四块中间。
    /// 车身放在 background 里而不是并排的一列，否则它会把整行撑到多高就占多高。
    private var diagram: some View {
        // 中间这道 92 给车身和支出来的轮子留位：太窄的话轮子那截会被两侧胎压块盖住。
        Grid(horizontalSpacing: 92, verticalSpacing: 12) {
            GridRow { tile(0); tile(1) }
            GridRow { tile(2); tile(3) }
        }
        .background { carBody.accessibilityHidden(true) }
    }

    /// 没有现成的俯视车符号（SF Symbols 里 `car.top.*` 全都自带开门、雷达波之类的附件），
    /// 只能自己画：一条车身 + 贴在四角支出去的四个轮子。轮子画出来，俯视图一眼就认得
    /// 出是车、朝向哪（车头那端圆得多，上圆下方就是个车鼻子），四张胎压卡也自然对上
    /// 「哪个轮子」。
    ///
    /// 原来只用两个后视镜标朝向，反被误读成车胎、以为掉了两个轮子——现在直接画四个轮子。
    private var carBody: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 26,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 26
            )
            .fill(.quaternary.opacity(0.7))
            .frame(width: 56)

            // 上排前轮、下排后轮，贴着车身两侧各支出去一截，位置跟着前/后排胎压卡走。
            VStack(spacing: 0) {
                wheelPair.padding(.top, 22)
                Spacer(minLength: 0)
                wheelPair.padding(.bottom, 22)
            }
        }
        .frame(width: 74)
    }

    /// 一根车轴上的左右两个轮子。
    private var wheelPair: some View {
        HStack(spacing: 0) {
            wheel
            Spacer()
            wheel
        }
        .frame(width: 74)
    }

    private var wheel: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.secondary)
            .frame(width: 10, height: 20)
    }

    private func tile(_ index: Int) -> some View {
        let tire = tires[index]
        let warning = tire.warning
        return VStack(spacing: 3) {
            Text(tire.label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(tire.kPa.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 27, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("kPa")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(warning ? AnyShapeStyle(LeapStyle.caution) : AnyShapeStyle(.primary))
            if warning {
                Label("异常", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(LeapStyle.caution)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
        // 一格是「左前 / 252 / kPa」三段文字，VoiceOver 会分三条念。
        // 合成一条，轮位当 label、读数当 value；"kPa" 写成"千帕"，
        // 否则会被逐字母拼读成「K P A」。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tire.label)
        .accessibilityValue(
            tire.kPa.map { "\(Int($0)) 千帕" + (warning ? "，异常" : "") } ?? "暂无数据"
        )
    }

    private var footnote: some View {
        Text(
            store.lastUpdated.map {
                HomeView.freshnessText(reportedAt: store.reportedAt, fetchedAt: $0)
            } ?? "胎压随车况一起更新"
        )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("车辆暂未上报胎压")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 40)
    }
}

/// 所有底部弹窗共用的留白：顶上要给拉动指示器让出位置，标题贴太近会显得挤；
/// 底下留一点，内容不至于压在 Home 指示条上。
enum SheetMetrics {
    static let topInset: CGFloat = 26
    static let bottomInset: CGFloat = 10
}

extension View {
    /// 按内容实际高度定弹窗高度。
    ///
    /// 写死一个数（胎压原来是 330）总会在某个字号、某种车况下失手：
    /// 要么内容撑出滚动条，要么就像原来那样在底下空一截。量出来再定就不会。
    /// 只适用于内容自己撑得起高度的弹窗——里面套了 ScrollView 的（比如车窗）
    /// 会一直填满可用高度，量出来的永远是弹窗自身的高度，用不了。
    /// 加上 `safeAreaInsets.bottom` 是因为 detent 说的是整个弹窗的高度，
    /// 而内容是排在安全区里面的，不加就会被 Home 指示条压住。
    func fittedSheetHeight(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.bottom
        } action: { measured in
            height.wrappedValue = measured
        }
        .presentationDetents([.height(height.wrappedValue)])
    }
}
