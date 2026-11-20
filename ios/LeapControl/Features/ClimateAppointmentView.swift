import SwiftUI

/// 预约空调（cmdid 171）。从空调页右上角进来。
///
/// 预约没有车况信号可确认，**确认靠回读**：页面一进来先读车上已有的预约，
/// 下发之后 store 再自动回读一次（见 `VehicleStore.dispatch` 里 171 那条），
/// 顶上那张「车上当前预约」卡显示的永远是车端回读的结果，不是本机刚填的草稿。
///
/// 风量 / 循环 / 除雾 / 出风位置不在界面上，照官方抓包默认值固定发，见 `ClimateAppointment`。
struct ClimateAppointmentView: View {
    @Environment(VehicleStore.self) private var store

    @State private var draft = ClimateAppointment()
    @State private var enabled = true
    /// 用户动过草稿之后，回读结果就不再覆盖它——不然刚调好的时间会被下一次回读冲掉。
    @State private var edited = false

    private var tint: Color { draft.mode == .hot ? LeapStyle.warm : LeapStyle.cool }

    private var currentOnCar: ClimateAppointment? {
        if case .loaded(let appointment) = store.climateAppointmentReadback { return appointment }
        return nil
    }

    var body: some View {
        ConnectedFeatureScaffold(title: "预约空调", tint: tint) {
            VStack(spacing: 16) {
                readbackCard
                editorCard
                actionButton
                footnote
            }
        }
        .task { await store.refreshClimateAppointment() }
        .onChange(of: store.climateAppointmentReadback) { _, readback in
            seed(from: readback)
        }
    }

    private func seed(from readback: VehicleStore.AppointmentReadback?) {
        guard !edited else { return }
        switch readback {
        case .loaded(let appointment):
            draft = appointment
            enabled = true
        case .empty:
            enabled = true
        default:
            break
        }
    }

    private func edit(_ change: (inout ClimateAppointment) -> Void) {
        change(&draft)
        edited = true
    }

    // MARK: - 车上当前预约（回读）

    private var readbackCard: some View {
        GlassCard(radius: LeapStyle.tileRadius) {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel(text: "车上当前预约")
                switch store.climateAppointmentReadback {
                case .empty?:
                    Text("没有预约空调")
                        .font(.subheadline.weight(.medium))
                case .loaded(let appointment)?:
                    Label(appointment.summary, systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.medium))
                case .failed(let message)?:
                    // 读不到 ≠ 没有预约。说清楚是哪一种，别让用户以为车上是空的。
                    Label("读不到车上的预约", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LeapStyle.caution)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .loading?, nil:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("读取中…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 编辑

    private var editorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("启用预约", isOn: Binding(
                    get: { enabled },
                    set: { enabled = $0; edited = true }
                ))
                .tint(LeapStyle.accent)
                .font(.subheadline.weight(.medium))

                if enabled {
                    DatePicker(
                        "开启时间",
                        selection: Binding(
                            get: { timeDate },
                            set: { newValue in
                                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                                edit {
                                    $0.hour = parts.hour ?? $0.hour
                                    $0.minute = parts.minute ?? $0.minute
                                }
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .font(.subheadline)

                    weekdayPicker
                    temperatureRow
                    modePicker
                }
            }
        }
    }

    private var timeDate: Date {
        Calendar.current.date(from: DateComponents(hour: draft.hour, minute: draft.minute)) ?? .now
    }

    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("重复").font(.subheadline)
                Spacer()
                Text(AppointmentWeekday.summary(draft.days))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(AppointmentWeekday.ordered, id: \.value) { day in
                    let selected = draft.days.contains(day.value)
                    Button(day.label) {
                        edit {
                            if selected { $0.days.remove(day.value) } else { $0.days.insert(day.value) }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(selected ? tint.opacity(0.2) : Color.secondary.opacity(0.1), in: .capsule)
                    .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    .buttonStyle(.plain)
                    .accessibilityLabel("星期\(day.label)")
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            // 一个都不勾就是一次性预约——协议里一次性预约的 `days` 就是空数组（161 实测）。
            if draft.days.isEmpty {
                Text("不选星期即为只执行一次。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var temperatureRow: some View {
        HStack {
            Text("温度").font(.subheadline)
            Spacer()
            Stepper(
                value: Binding(
                    get: { draft.temperature },
                    set: { newValue in edit { $0.temperature = newValue } }
                ),
                in: ClimateAppointment.minTemperature...ClimateAppointment.maxTemperature
            ) {
                EmptyView()
            }
            .labelsHidden()
            Text("\(draft.temperature) °C")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(ClimateAppointment.Mode.allCases, id: \.rawValue) { mode in
                let selected = draft.mode == mode
                Button {
                    edit { $0.mode = mode }
                } label: {
                    Label(mode.label, systemImage: mode == .hot ? "flame.fill" : "snowflake")
                        .font(.subheadline.weight(.medium))
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
        .padding(4)
        .leapGlass(.regular, in: .capsule)
        .animation(.snappy, value: draft.mode)
    }

    // MARK: - 保存 / 取消

    @ViewBuilder
    private var actionButton: some View {
        if enabled {
            Button {
                // 改的是车上已有那条就沿用它的 set_id；新建交给构造器现造。
                var appointment = draft
                appointment.setID = currentOnCar?.setID
                store.saveClimateAppointment(appointment)
                edited = false
            } label: {
                Label("保存预约", systemImage: "calendar.badge.clock")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .leapGlassButton(prominent: true)
            .tint(tint)
            .commandBusy(store.isSendingCommand)
        } else {
            // 开关关掉 = 取消车上的预约。车上本来就没有就没什么可取消的，按钮置灰。
            Button {
                store.cancelClimateAppointment()
                edited = false
            } label: {
                Label("取消车上的预约", systemImage: "calendar.badge.minus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .leapGlassButton()
            .tint(LeapStyle.caution)
            .disabled(currentOnCar == nil)
            .commandBusy(store.isSendingCommand)
        }
    }

    private var footnote: some View {
        Label {
            Text("风量 7 档、内循环、前挡除雾开启，与官方 App 的预约默认值一致。到点是否开启以车辆实际表现为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "info.circle.fill")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
    }
}
