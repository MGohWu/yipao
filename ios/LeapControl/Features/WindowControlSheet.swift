import SwiftUI

/// 车窗控制。零跑远控只接受一个开度值，两侧前窗一起动，
/// 所以这里是一个统一的位置滑杆，而不是左右各一个（原型里的双滑杆会给出无法下发的组合）。
struct WindowControlSheet: View {
    @Environment(VehicleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// 开度百分比：0 关闭、100 全开。车端原始刻度各车型不同，换算在 `WindowScale` 里做完了。
    @State private var openness: Double = 0

    /// 打开弹窗时车上的开度，也就是「已经下发过的那个值」。
    /// 手指按上滑杆再原地松开也会走一次结束回调，拿它挡掉那种「没挪动」的下发——
    /// 否则用户只是碰了一下滑杆，就凭空发出一条控车指令并被关掉弹窗。
    @State private var committedOpenness: Int = 0

    /// 车到底停在哪个开度，是不是知道。
    ///
    /// 有的车只报「开没开」不报开度（C11 增程版实测），这时 ``openness`` 里的 0
    /// 是没得选的占位、不是车的真实位置——照着它把「关闭」点亮，等于替车说了句
    /// 它没说过的话。所以那种情况下一个档位都不点亮，等用户自己按了才算数。
    @State private var knowsPosition = false

    /// 弹窗高度。档位车型只剩一行按钮，还按 450 开就是大半屏空白。
    /// 滑杆车型的底部发送按钮也去掉了，那一截（按钮 + 上下留白约 75）跟着收。
    /// 这里只能写死：内容套在 ScrollView 里，量出来的永远是弹窗自身的高度
    /// （`fittedSheetHeight` 的注释里说的就是这一条）。字号放大到撑不下时由 ScrollView 接着。
    static func sheetHeight(carType: String) -> CGFloat {
        LeapCommand.windowSupportsSlider(carType: carType) ? 300 : 230
    }

    private var carType: String { store.session.selectedCarType }
    private var presets: [WindowPreset] { LeapCommand.windowPresets(carType: carType) }
    private var showsSlider: Bool { LeapCommand.windowSupportsSlider(carType: carType) }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 16) {
                    if showsSlider {
                        positionSlider
                    }
                    presetRow
                    // 这句只对 S01 说过，别因为别的车型也有了滑杆就跟着冒出来——
                    // 后窗能不能远控是单车型的实测结论，和接口口径分组是两回事，
                    // C11 那组至今没验过，不能替它下结论。
                    if CarTypeFamily.isS01(carType) {
                        Text("该车型的后窗不支持远程控制。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                // 上一条还在等车确认时 `perform` 会把新指令直接丢掉。
                // 原来挡在发送按钮上的这层保护，现在要挡在滑杆和档位按钮上——
                // 不然点了就是「弹窗关了、车没动、也没人说为什么」。
                .commandBusy(store.isSendingCommand)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, SheetMetrics.topInset)
        .onAppear {
            // 四扇里开得最大的那扇代表当前位置，两侧前窗通常同步。
            let reported = store.state?.maxWindowOpenness
            // 车不报开度，但报了「关着」，那位置就是 0，这一条是知道的。
            let closedByFlag = store.state?.anyWindowOpen == false
            let current = reported ?? (closedByFlag ? 0 : nil)
            knowsPosition = current != nil
            openness = Double(current ?? 0)
            // 位置不知道时给个不可能相等的值，免得第一次下发被「没挪动」那条挡掉。
            committedOpenness = current ?? -1
        }
    }

    /// 下发并关掉弹窗。结果提示是贴在根视图底部的，弹窗开着会把它整个盖住，
    /// 关掉才看得到「指令已下发 / 未收到车辆确认」。
    private func send(openness value: Int) {
        store.applyWindows(openness: value)
        dismiss()
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("车窗控制")
                .font(.headline)
            // 发送按钮没了，下发那一刻就没有可见的落点了。滑杆车型在这儿说清楚
            // 「松手就发」，否则用户会拖完站在那儿等，或者反复拖找那个按钮。
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 18)
    }

    /// 车报了开合、没报开度时，把「现在是开着的」说在这儿——
    /// 一个档位都没点亮的界面，不说清楚就像是没读到车况。
    private var subtitle: String {
        if !knowsPosition, store.state?.anyWindowOpen == true {
            return "两侧前窗同时调节 · 车窗当前已开"
        }
        return showsSlider ? "两侧前窗同时调节 · 松手即下发" : "两侧前窗同时调节"
    }

    private var positionSlider: some View {
        VStack(spacing: 10) {
            HStack {
                Text(WindowPosition.describe(Int(openness)))
                    .font(.title2.weight(.medium))
                    .contentTransition(.numericText())
                Spacer()
            }

            // 只有验证过任意刻度都能下发的车型才给滑杆。给不出的开度不该摆在这里。
            if showsSlider {
                // 值本身就是开度，往右 = 开得更大，不用再取反。
                Slider(value: $openness, in: 0...100, step: 10) {
                    Text("车窗开度")
                } minimumValueLabel: {
                    Image(systemName: "rectangle.fill")
                } maximumValueLabel: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                } onEditingChanged: { editing in
                    // 拖动途中一条都不发：十个刻度一路划过去就是十条控车指令，
                    // 车根本跟不上，用户也说不清最后停在哪一格。
                    // 手指离开才算「他停下了」，这时把最终开度发出去。
                    guard !editing else { return }
                    let value = Int(openness)
                    guard value != committedOpenness else { return }
                    knowsPosition = true
                    committedOpenness = value
                    send(openness: value)
                }
                .tint(LeapStyle.cool)
                .sensoryFeedback(.selection, trigger: openness)
            }
        }
        .padding(16)
        .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
    }

    /// 按车型能力渲染，从开到关排——和滑杆「往右越开」的方向一致。
    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(presets.reversed()) { item in
                preset(title: item.label, value: Double(item.openness))
            }
        }
    }

    private func preset(title: String, value: Double) -> some View {
        Button {
            withAnimation(.snappy) { openness = value }
            // 点档位就是下发，有没有滑杆都一样——按钮按下去就该有事发生，
            // 不能只是把滑杆挪过去然后等用户再找一个发送按钮。
            knowsPosition = true
            committedOpenness = Int(value)
            send(openness: Int(value))
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .leapGlassButton()
        .tint(knowsPosition && openness == value ? LeapStyle.cool : LeapStyle.primaryLabel)
    }
}
