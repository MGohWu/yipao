import SwiftUI
import UIKit

struct ParkingPhotosPreviewView: View {
    @Environment(VehicleStore.self) private var store
    @State private var photo: ParkingPhoto?
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ConnectedFeatureScaffold(title: "驻车照片", tint: LeapStyle.frost) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最近驻车").font(.headline)
                        Spacer()
                        Button {
                            Task { await load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 36, height: 36)
                        }
                        .leapGlassButton()
                        .disabled(isLoading)
                        .accessibilityLabel("刷新驻车照片")
                    }
                    photoContent
                }

                Label {
                    Text("照片由车辆驻车时自动记录。这里只读取服务端保存的最近一张，不会远程触发拍照。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .padding(16)
                .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
            }
        }
        .task(id: store.session.selectedVin) { await load() }
    }

    @ViewBuilder
    private var photoContent: some View {
        if isLoading && image == nil {
            ProgressView("正在读取驻车照片")
                .frame(maxWidth: .infinity, minHeight: 260)
                .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
        } else if let image {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                if let uploadTime = photo?.displayUploadTime {
                    Text(uploadTime)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 6))
                        .padding(12)
                }
            }
            .clipShape(.rect(cornerRadius: LeapStyle.tileRadius))
            .overlay {
                RoundedRectangle(cornerRadius: LeapStyle.tileRadius)
                    .stroke(LeapStyle.glassEdge, lineWidth: 0.8)
            }
        } else {
            ContentUnavailableView {
                Label(errorMessage == nil ? "暂无驻车照片" : "读取失败",
                      systemImage: errorMessage == nil ? "camera.slash" : "exclamationmark.triangle")
            } description: {
                Text(errorMessage ?? "车辆可能尚未开启驻车拍照，稍后再试。")
            } actions: {
                Button("重试") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
            .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await store.loadParkingPhoto()
            photo = result.0
            image = result.1.flatMap(UIImage.init(data:))
            if result.1 != nil, image == nil { throw LeapError.decode("驻车照片格式无法显示") }
        } catch {
            photo = nil
            image = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct BatteryPreheatPreviewView: View {
    @Environment(VehicleStore.self) private var store

    // 预约预热（cmdid 161）的 state 结构已真车抓包验证，接入真实下发；
    // set_id 由 store 按「iOS_VIN_毫秒」构造。立即预热（cmdid 160）也是真实下发。
    @State private var scheduleEnabled = true
    @State private var schedule = Calendar.current.date(from: DateComponents(hour: 7, minute: 30)) ?? .now
    @State private var scheduleDays: Set<Int> = [1, 2, 3, 4, 5]

    /// 周日是 **0** 不是 7（2026-11-19 改，和预约空调 171 共用一套编码，见 `AppointmentWeekday`）。
    private let weekdayLabels = AppointmentWeekday.ordered.map { ($0.value, $0.label) }

    var body: some View {
        // 立即预热已接真实下发，横幅那句「不会向车辆发送指令」不再成立，撤掉，
        // 改由每一段自己的说明如实交代下发与否。
        LabPreviewScaffold(title: "电池预热", tint: LeapStyle.warm, showsAvailabilityBanner: false) {
            VStack(spacing: 16) {
                immediateSection
                appointmentSection
            }
        }
    }

    // MARK: - 立即预热（真实下发 cmdid 160）

    @ViewBuilder
    private var immediateSection: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.13))
                    .frame(width: 142, height: 142)
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.secondary)
            }

            // 车端不上报可判定的预热终态（ptcState 枚举未确认），所以不做「开着/关着」
            // 的状态显示——那会是凭空断言。这里只给两个一次性动作，结果交给全局提示：
            // 成功报「已发送」，部分车型/环境不支持时服务端会回错误、由 show(error:) 如实弹出。
            Text("立即预热")
                .font(.title3.weight(.semibold))
            Text("是否生效以车辆实际表现为准")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    store.preheatBattery()
                } label: {
                    Label("开启预热", systemImage: "heat.waves")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .leapGlassButton(prominent: true)
                .tint(LeapStyle.warm)

                Button {
                    store.stopBatteryPreheat()
                } label: {
                    Label("关闭预热", systemImage: "power")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .leapGlassButton()
                .tint(LeapStyle.secondaryLabel)
            }
            .disabled(store.isSendingCommand)
            .commandBusy(store.isSendingCommand)
        }
        .padding(.vertical, 8)
    }

    // MARK: - 预约预热（真实下发 cmdid 161）

    @ViewBuilder
    private var appointmentSection: some View {
        GlassCard {
            VStack(spacing: 14) {
                Toggle("预约预热", isOn: $scheduleEnabled)
                    .tint(LeapStyle.accent)
                if scheduleEnabled {
                    DatePicker("开始时间", selection: $schedule, displayedComponents: .hourAndMinute)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("重复星期").font(.subheadline)
                        HStack(spacing: 6) {
                            ForEach(weekdayLabels, id: \.0) { day, label in
                                Button(label) {
                                    if scheduleDays.contains(day) {
                                        guard scheduleDays.count > 1 else { return }
                                        scheduleDays.remove(day)
                                    } else {
                                        scheduleDays.insert(day)
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(scheduleDays.contains(day) ? LeapStyle.accent.opacity(0.2) : Color.secondary.opacity(0.1), in: .capsule)
                                .foregroundStyle(scheduleDays.contains(day) ? LeapStyle.accent : .secondary)
                                .accessibilityLabel("星期\(label)")
                                .accessibilityAddTraits(scheduleDays.contains(day) ? .isSelected : [])
                            }
                        }
                    }
                }
            }
        }

        Button {
            // 开关关着时保存 = 取消预约（下发 on:0）；开着时下发预约时间与重复日。
            store.scheduleBatteryPreheat(
                at: schedule,
                enabled: scheduleEnabled,
                days: scheduleDays.sorted()
            )
        } label: {
            Label(scheduleEnabled ? "保存预约" : "取消预约", systemImage: "calendar.badge.clock")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .leapGlassButton(prominent: true)
        .tint(LeapStyle.accent)
        .disabled(store.isSendingCommand)
        .commandBusy(store.isSendingCommand)

        Label {
            Text("预约设置会下发到车辆，是否按时生效以车辆实际表现为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "info.circle.fill")
        }
        .padding(16)
        .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
    }
}

struct ChargePlanPreviewView: View {
    @Environment(VehicleStore.self) private var store

    // 初值取真实 config."3"（见 seedFromPlan），拿不到时退到这套默认：23:00–08:00 / 90% / 每天 / 关。
    @State private var scheduleEnabled = false
    @State private var beginTime = Self.time(hour: 23, minute: 0)
    @State private var endTime = Self.time(hour: 8, minute: 0)
    @State private var percent = 90.0
    /// 7 位循环日，index 0=周一 … 6=周日（和 `ChargePlan.cycles` 同一套假设）。
    @State private var cycleDays: [Bool] = Array(repeating: true, count: 7)
    /// `circulation`/`recharge` 含义未确认，原样回填车辆上报的那份（见 `ChargePlan`）。
    @State private var circulation = 1
    @State private var recharge = 0
    /// 健康充电开关。初值取车况信号 48（见 seedFromPlan / `VehicleState.healthyChargeOn`），读不到才默认关。
    @State private var healthyChargeOn = false
    /// 用户这次有没有动过健康充电开关。只有动过才下发 cmdid 480，没动就不必重复写一遍车上已有的设置。
    @State private var healthyTouched = false
    /// 只在首次出现时用真实计划播种一次，之后不覆盖用户在预览里的改动。
    @State private var seeded = false
    @State private var loading = true
    @State private var loadFailed = false

    /// 健康充电开启时充电上限最多 90%（官方页面同款约束）。
    private var maxPercent: Double { healthyChargeOn ? 90 : 100 }

    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        LabPreviewScaffold(title: "充电计划", tint: LeapStyle.accent, showsAvailabilityBanner: false) {
            VStack(spacing: 18) {
                if loading { ProgressView("正在读取充电计划…") }
                if loadFailed {
                    Button("读取失败，点击重试") { Task { await loadPlan() } }
                }
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(percent))")
                            .font(.system(size: 78, weight: .ultraLight, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("%")
                            .font(.title2.weight(.light))
                            .foregroundStyle(.secondary)
                    }
                    Text("目标电量")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 18)

                GlassCard {
                    VStack(spacing: 14) {
                        Slider(value: $percent, in: 50...maxPercent, step: 5)
                            .tint(LeapStyle.accent)
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("80%").foregroundStyle(LeapStyle.accent)
                            Spacer()
                            Text("\(Int(maxPercent))%")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("健康充电", isOn: Binding(
                            get: { healthyChargeOn },
                            set: { on in
                                healthyChargeOn = on
                                healthyTouched = true
                                if on, percent > 90 { percent = 90 }
                            }
                        ))
                        .tint(LeapStyle.accent)
                        Text("开启后充电上限最多 90%。开关状态取自车况，改动后保存才下发。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                GlassCard {
                    VStack(spacing: 14) {
                        Toggle("预约充电", isOn: $scheduleEnabled)
                            .tint(LeapStyle.accent)
                        if scheduleEnabled {
                            DatePicker("开始时间", selection: $beginTime, displayedComponents: .hourAndMinute)
                            DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("循环日").font(.subheadline)
                                HStack(spacing: 6) {
                                    ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { index, label in
                                        Button(label) {
                                            cycleDays[index].toggle()
                                        }
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .background(cycleDays[index] ? LeapStyle.accent.opacity(0.2) : Color.secondary.opacity(0.1), in: .capsule)
                                        .foregroundStyle(cycleDays[index] ? LeapStyle.accent : .secondary)
                                        .accessibilityLabel("星期\(label)")
                                        .accessibilityAddTraits(cycleDays[index] ? .isSelected : [])
                                    }
                                }
                            }
                        }
                    }
                }

                Button(action: save) {
                    Label("保存充电计划", systemImage: "bolt.badge.checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .leapGlassButton(prominent: true)
                .tint(LeapStyle.accent)
                .disabled(store.isSendingCommand || !seeded || loading)
                .commandBusy(store.isSendingCommand)

                Text("改动保存后才下发到车辆，是否生效以车辆实际表现为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(loading)
        }
        .task(id: "\(store.session.oldAuth?.accountId ?? "")/\(store.session.selectedVin)") { await loadPlan() }
    }

    private func loadPlan() async {
        loading = true
        seeded = false
        loadFailed = false
        let success = await store.refreshChargePlan()
        guard !Task.isCancelled else { return }
        if success { seedFromPlan() }
        loadFailed = !success
        loading = false
    }

    /// 把当前设置下发给车：充电上限 + 预约充电走 190；这次动过健康充电才连发 480。
    private func save() {
        store.saveChargePlan(
            limitPercent: Int(percent),
            scheduledEnabled: scheduleEnabled,
            startTime: Self.hhmm(from: beginTime),
            endTime: Self.hhmm(from: endTime),
            cycles: cycleDays,
            circulation: circulation,
            recharge: recharge,
            healthyChargeOn: healthyTouched ? healthyChargeOn : nil
        )
    }

    /// Date → `"HH:mm"`（下发字段 starttime/endtime 的格式）。
    private static func hhmm(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 用当前车真实的充电计划播种一次控件初值。拿不到就保留默认值。
    private func seedFromPlan() {
        guard !seeded else { return }
        seeded = true
        scheduleEnabled = false
        percent = 90
        beginTime = Self.time(hour: 23, minute: 0)
        endTime = Self.time(hour: 8, minute: 0)
        cycleDays = Array(repeating: true, count: 7)
        circulation = 1
        recharge = 0
        healthyChargeOn = false
        healthyTouched = false
        // 健康充电来自车况信号 48，和充电计划（config."3"）不同源，单独播种。
        if let on = store.state?.healthyChargeOn { healthyChargeOn = on }
        guard let plan = store.state?.chargePlan else { return }
        scheduleEnabled = plan.isEnable
        percent = Double(min(100, max(50, plan.percent)))
        if let begin = Self.time(from: plan.beginTime) { beginTime = begin }
        if let end = Self.time(from: plan.endTime) { endTime = end }
        if plan.cycles.count == 7 { cycleDays = plan.cycles }
        // circulation/recharge 含义未确认，原样带回，保存时回填、不擅自改。
        circulation = plan.circulation
        recharge = plan.recharge
    }

    private static func time(hour: Int, minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
    }

    /// `"23:00"` → 当天该时刻的 Date。解析不出返回 nil，交给调用方保留默认。
    private static func time(from text: String) -> Date? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return Calendar.current.date(from: DateComponents(hour: hour, minute: minute))
    }
}

struct LabPreviewScaffold<Content: View>: View {
    var title: String
    var tint: Color
    var showsAvailabilityBanner = true
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            LeapBackground(tint: tint)
            ScrollView {
                VStack(spacing: 18) {
                    if showsAvailabilityBanner {
                        FeatureAvailabilityBanner()
                    }
                    content
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectedFeatureScaffold<Content: View>: View {
    var title: String
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            LeapBackground(tint: tint)
            ScrollView {
                VStack(spacing: 18) {
                    content
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
