import SwiftUI

/// 车载冰箱：电源、三个预设、目标温度、制冷风格、离车保持。
///
/// 这一页在**没装冰箱的车上整个不出现**（入口门控见 `VehicleStore.fridgeSupported`）。
/// 车主那台 C16 就是这种情况：`abilities` 不含 `76`，signalMap 里九个冰箱信号一个都不报。
///
/// cmdid `500` 的 state 是**全量**的——改一项也要把八个字段一起发出去，
/// 所以这页维护的是整份草稿（`VehicleStore.fridgeDraft`），不是增量。
struct FridgeView: View {
    @Environment(VehicleStore.self) private var store


    var body: some View {
        ConnectedFeatureScaffold(title: "车载冰箱", tint: tint) {
            VStack(spacing: 16) {
                if let fault = store.state?.fridgeState?.fault, fault != 0 {
                    faultBanner(code: fault)
                }
                powerSection
                if draft.enabled {
                    presetPicker
                    temperatureCard
                    styleCard
                    parkCard
                }
            }
        }
        .onAppear { store.seedFridgeDraft() }
    }

    /// 界面读的那份草稿。车况还没回来时给一份中性默认值，
    /// 这不是「伪造车况」——草稿本来就是本机准备要发的东西，必须有个值；
    /// 上面那行状态文字读的仍然是车况，读不到就不显示。
    private var draft: FridgeSetting {
        store.fridgeDraft ?? store.state?.fridgeState?.asSetting ?? FridgeSetting()
    }

    private var tint: Color {
        guard draft.enabled else { return LeapStyle.frost.opacity(0.6) }
        return draft.mode == .hot ? LeapStyle.warm : LeapStyle.cool
    }

    private func update(_ change: (inout FridgeSetting) -> Void) {
        var next = draft
        change(&next)
        store.fridgeDraft = next
        store.pushFridgeDraft()
    }

    // MARK: - 故障

    private func faultBanner(code: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LeapStyle.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text("冰箱自检故障（码 \(code)）")
                    .font(.subheadline.weight(.semibold))
                // 不编造排查指引：这个码的含义我们没有任何对照表。
                Text("车端报了一个非零故障码，具体含义以车机或售后为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .leapGlass(.regular.tint(LeapStyle.caution.opacity(0.14)),
                   in: .rect(cornerRadius: LeapStyle.tileRadius))
    }

    // MARK: - 电源

    private var powerSection: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill((draft.enabled ? tint : Color.secondary).opacity(0.13))
                    .frame(width: 142, height: 142)
                VStack(spacing: 2) {
                    Image(systemName: draft.mode == .hot ? "cup.and.saucer.fill" : "snowflake")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(draft.enabled ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    Text("\(draft.wireTemperature) °C")
                        .font(.system(size: 26, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(draft.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
            }
            .animation(.snappy, value: draft.wireTemperature)

            // 这一行读的是**车况**，不是草稿——它要回答的是「车上现在到底什么状态」。
            // 读不到就整行不显示，不写 `--` 占位。
            if let line = stateLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                store.setFridgePower(on: !draft.enabled)
            } label: {
                Label(draft.enabled ? "关闭冰箱" : "开启冰箱",
                      systemImage: draft.enabled ? "power" : "power.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .leapGlassButton(prominent: !draft.enabled)
            .tint(draft.enabled ? LeapStyle.secondaryLabel : tint)
            .commandBusy(store.isSendingCommand)
        }
        .padding(.vertical, 8)
    }

    private var stateLine: String? {
        guard let fridge = store.state?.fridgeState else { return nil }
        guard fridge.enabled else { return "冰箱已关闭 · 保留上次设定" }
        var parts = [fridge.mode.label]
        if fridge.mode == .hot {
            parts[0] = "保温 \(FridgeSetting.hotTemp) ℃"
        } else if let temp = fridge.targetTemp {
            parts[0] = "制冷 \(temp) ℃"
        }
        parts.append(fridge.style.label)
        if fridge.parkEnabled { parts.append("离车保持中") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 预设

    private var presetPicker: some View {
        LeapGlassContainer(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(FridgePreset.allCases) { preset in
                    let selected = draft.preset == preset
                    Button {
                        update { $0.apply(preset) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: preset.symbol)
                                .font(.system(size: 15, weight: .medium))
                            Text(preset.label)
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .background {
                        if selected { Capsule().fill(.primary.opacity(0.14)) }
                    }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(5)
            .leapGlass(.regular, in: .capsule)
        }
        .animation(.snappy, value: draft.preset)
    }

    // MARK: - 目标温度

    private var temperatureCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardLabel(text: "目标温度")
                    Spacer()
                    Text(draft.mode == .hot ? "固定 \(FridgeSetting.hotTemp) ℃" : "\(draft.temperature) ℃")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(draft.temperature) },
                        set: { newValue in update { $0.temperature = Int(newValue.rounded()) } }
                    ),
                    in: Double(FridgeSetting.minTemp)...Double(FridgeSetting.maxTemp),
                    step: 1
                )
                .tint(LeapStyle.cool)
                // 保温模式下协议写死 50 ℃，滑杆无从施力，置灰而不是藏起来——
                // 藏起来会让卡片在两个模式之间跳高度。
                .disabled(draft.mode == .hot)
                .opacity(draft.mode == .hot ? 0.4 : 1)
                .accessibilityLabel("制冷目标温度")
                .accessibilityValue("\(draft.temperature) 摄氏度")

                if draft.mode == .hot {
                    Text("保温模式恒温 \(FridgeSetting.hotTemp) ℃，温度不可调。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 制冷风格

    private var styleCard: some View {
        GlassCard(radius: LeapStyle.tileRadius) {
            HStack {
                CardLabel(text: "制冷风格")
                Spacer()
                HStack(spacing: 6) {
                    ForEach(FridgeStyle.allCases, id: \.rawValue) { style in
                        let selected = draft.style == style
                        Button {
                            update { $0.style = style }
                        } label: {
                            Text(style.label)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .background {
                            if selected { Capsule().fill(.primary.opacity(0.14)) }
                        }
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(4)
                .leapGlass(.regular, in: .capsule)
            }
            .animation(.snappy, value: draft.style)
        }
    }

    // MARK: - 离车保持

    private var parkCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("离车保持", isOn: Binding(
                    get: { draft.parkEnabled },
                    set: { newValue in update { $0.parkEnabled = newValue } }
                ))
                .tint(LeapStyle.accent)
                .font(.subheadline.weight(.medium))

                if draft.parkEnabled {
                    HStack {
                        CardLabel(text: "工作时长")
                        Spacer()
                        Stepper(
                            "\(draft.parkHours) 小时",
                            value: Binding(
                                get: { draft.parkHours },
                                set: { newValue in update { $0.parkHours = newValue } }
                            ),
                            in: 1...24
                        )
                        .labelsHidden()
                        Text("\(draft.parkHours) 小时")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                    }

                    // 截止时刻读车况（信号 11260），车端没给就不显示。
                    if let endsAt = store.state?.fridgeState?.parkEndsAt {
                        Text("预计 \(endsAt.formatted(date: .omitted, time: .shortened)) 结束")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // 周期这一版不暴露：下发口径（"1"/"2"）和上报口径（0/1）对不上，
                    // 哪个值是「仅本次」哪个是「每次离车」没有依据，固定发 "1"。
                    Text("当前仅对本次离车生效。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
