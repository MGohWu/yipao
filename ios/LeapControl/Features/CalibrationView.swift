import SwiftUI

/// 「帮我适配车型」的引导流程。
///
/// 车主在车边按提示操作，App 比对操作前后的车况，反推出这台车的信号 ID。
/// 全程不上传任何数据——标定结果先存本机立刻生效，要不要发给开发者由用户自己决定。
@MainActor
@Observable
final class CalibrationModel {
    enum Stage: Equatable {
        case intro
        /// 静止采样，摸清哪些字段自己会变。
        case baseline
        case task(index: Int, isBackward: Bool)
        case summary
    }

    private(set) var stage: Stage = .intro
    private(set) var baseline = CalibrationBaseline()
    private(set) var outcomes: [TaskOutcome] = []
    /// 正在等车上报变化。
    private(set) var isCapturing = false
    /// 上一步有没有捕捉到变化，用来给用户即时反馈。
    private(set) var lastStepCaught: Bool?
    private(set) var progressText = ""

    /// 当前这一步的操作前快照。
    private var before: [String: String] = [:]
    private var forwardChanges: [SignalChange] = []

    private let store: VehicleStore

    init(store: VehicleStore) {
        self.store = store
    }

    var tasks: [CalibrationTask] { CalibrationTask.all }

    var currentTask: CalibrationTask? {
        guard case .task(let index, _) = stage, index < tasks.count else { return nil }
        return tasks[index]
    }

    var isBackwardStep: Bool {
        guard case .task(_, let isBackward) = stage else { return false }
        return isBackward
    }

    /// 当前该让用户做的动作。
    var actionText: String {
        guard let task = currentTask else { return "" }
        return isBackwardStep ? task.backward : task.forward
    }

    var learned: [VehicleSignal: String] { Calibration.learnedKeys(from: outcomes) }

    var report: String {
        Calibration.report(
            carType: store.session.selectedCarType,
            schemaID: store.state?.schema.id ?? "unknown",
            baseline: baseline,
            outcomes: outcomes
        )
    }

    // MARK: - 流程

    func start() async {
        stage = .baseline
        await runBaseline()
    }

    /// 静止采 3 次，两两相比，变过的字段全部拉进排除名单。
    ///
    /// 不做这一步，后面每个任务的 diff 都会混进时间戳、经纬度、电压这些一直在跳的字段。
    private func runBaseline() async {
        var samples: [[String: String]] = []
        for index in 0..<3 {
            progressText = "正在采样 \(index + 1)/3"
            if let map = await store.captureSignalMap() { samples.append(map) }
            if index < 2 { try? await Task.sleep(for: .seconds(10)) }
        }
        baseline = CalibrationBaseline.make(from: samples)
        progressText = ""
        await beginStep(index: 0, isBackward: false)
    }

    /// 进入某一步：先记下操作前的车况，再让用户去动车。
    private func beginStep(index: Int, isBackward: Bool) async {
        guard index < tasks.count else {
            stage = .summary
            return
        }
        lastStepCaught = nil
        stage = .task(index: index, isBackward: isBackward)
        before = await store.captureSignalMap() ?? [:]
    }

    /// 用户点了「我做好了」。车端上报有延迟，实测 5–10 秒，所以要连着刷几次等。
    func confirmStepDone() async {
        guard case .task(let index, let isBackward) = stage, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false; progressText = "" }

        var caught: [SignalChange] = []
        let deadline = Date.now.addingTimeInterval(Self.captureTimeout)
        while Date.now < deadline {
            try? await Task.sleep(for: .seconds(2))
            progressText = "正在等车辆上报…"
            guard let after = await store.captureSignalMap() else { continue }
            let changes = Calibration.changes(from: before, to: after, excluding: baseline.noisyKeys)
            if !changes.isEmpty {
                caught = changes
                break
            }
        }

        lastStepCaught = !caught.isEmpty
        if isBackward {
            outcomes.append(TaskOutcome(
                taskID: tasks[index].id,
                signal: tasks[index].signal.rawValue,
                forward: forwardChanges,
                backward: caught
            ))
            forwardChanges = []
            await beginStep(index: index + 1, isBackward: false)
        } else {
            forwardChanges = caught
            await beginStep(index: index, isBackward: true)
        }
    }

    /// 这一步做不了（比如车没有电动尾门），跳过整个任务。
    ///
    /// 在第 2 步跳过时，第 1 步采到的变化不扔——它按单向规则还有可能立得住。
    func skipTask() async {
        guard case .task(let index, let isBackward) = stage else { return }
        if isBackward {
            outcomes.append(TaskOutcome(
                taskID: tasks[index].id,
                signal: tasks[index].signal.rawValue,
                forward: forwardChanges,
                backward: [],
                didReverse: false
            ))
        }
        forwardChanges = []
        await beginStep(index: index + 1, isBackward: false)
    }

    func apply() async {
        await store.applyCalibration(learned)
    }

    /// 和确认车辆响应用的是同一个窗口：实测车辆 5–10 秒响应，休眠时更久。
    static let captureTimeout: TimeInterval = 20
}

struct CalibrationView: View {
    @Environment(VehicleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model: CalibrationModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            // 撑满再铺背景：不这么写，内容不满屏时下半截会露出 sheet 的纯黑底，
            // 和 App 里其他页面的渐变对不上。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { LeapBackground(tint: LeapStyle.accent) }
            .navigationTitle("适配我的车型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            if model == nil { model = CalibrationModel(store: store) }
            // 标定要自己控制采样节奏，十秒一次的后台轮询会插进来干扰 diff。
            store.stopPolling()
        }
        .onDisappear { store.startPolling() }
    }

    @ViewBuilder
    private func content(_ model: CalibrationModel) -> some View {
        switch model.stage {
        case .intro: intro(model)
        case .baseline: baseline(model)
        case .task: taskStep(model)
        case .summary: summary(model)
        }
    }

    // MARK: - 说明

    private func intro(_ model: CalibrationModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("你的车有些车况这个 App 还认不出来")
                    .font(.title3.bold())

                Text("零跑没有公开车况字段表，不同车型上报的字段名也不一样。跟着提示在车边操作几下，App 比对操作前后的差异，就能认出你这台车的门锁、车门、车窗和空调。")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    bullet("car.fill", "需要你在车边，全程约 10–15 分钟")
                    bullet("lock.shield", "不上传任何数据，结果只存在这台手机上")
                    bullet("checkmark.circle", "做完立刻生效，马上能看到自己车的状态")
                }
                .padding(.vertical, 4)

                Text("要做的事")
                    .font(.headline)
                ForEach(CalibrationTask.all) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.tertiary)
                        Text("\(task.title)：\(task.forward)，然后\(task.backward)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await model.start() }
                } label: {
                    Text("开始")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(LeapStyle.accent)
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: - 静止基线

    private func baseline(_ model: CalibrationModel) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("请先什么都别做")
                .font(.title3.bold())
            Text("车上有些数值自己就一直在变——时间、位置、电压。先记下它们，后面才分得清哪些变化是你操作出来的。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(model.progressText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(30)
    }

    // MARK: - 单步操作

    private func taskStep(_ model: CalibrationModel) -> some View {
        guard let task = model.currentTask else { return AnyView(EmptyView()) }
        let index = model.tasks.firstIndex { $0.id == task.id } ?? 0
        return AnyView(
            VStack(spacing: 0) {
                ProgressView(value: Double(index), total: Double(model.tasks.count))
                    .tint(LeapStyle.accent)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Spacer()

                VStack(spacing: 14) {
                    Text("\(task.title) · \(model.isBackwardStep ? "第 2 步" : "第 1 步")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Text(model.actionText)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    if !task.hint.isEmpty {
                        Text(task.hint)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if let caught = model.lastStepCaught {
                        Label(
                            caught ? "上一步已捕捉到变化" : "上一步没捕捉到变化",
                            systemImage: caught ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(caught ? AnyShapeStyle(LeapStyle.accent) : AnyShapeStyle(LeapStyle.caution))
                    }
                }
                .padding(.horizontal, 30)

                Spacer()

                VStack(spacing: 12) {
                    if model.isCapturing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(model.progressText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 44)
                    } else {
                        Button {
                            Task { await model.confirmStepDone() }
                        } label: {
                            Text("我做好了")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LeapStyle.accent)
                        .controlSize(.large)
                    }

                    Button("这项跳过") {
                        Task { await model.skipTask() }
                    }
                    .font(.subheadline)
                    .disabled(model.isCapturing)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        )
    }

    // MARK: - 汇总

    private func summary(_ model: CalibrationModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let learned = model.learned
                Text(learned.isEmpty ? "这次没能认出新字段" : "认出了 \(learned.count) 项车况")
                    .font(.title3.bold())

                if model.baseline.looksAsleep {
                    Label(
                        "开始那会儿车是睡着的，采样三次一个数都没变。这一轮的结果可靠性打折，车醒着时重做一次会准得多。",
                        systemImage: "zzz"
                    )
                    .font(.caption)
                    .foregroundStyle(LeapStyle.caution)
                }

                if learned.isEmpty {
                    Text("可能是操作和车辆上报之间隔得太久，或者这台车不上报这些状态。可以隔一会儿再试一次。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.outcomes, id: \.taskID) { outcome in
                        let title = CalibrationTask.all.first { $0.id == outcome.taskID }?.title ?? outcome.taskID
                        HStack {
                            Image(systemName: outcome.isConfirmed ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(outcome.isConfirmed
                                                 ? AnyShapeStyle(LeapStyle.accent)
                                                 : AnyShapeStyle(.tertiary))
                            Text(title)
                            Spacer()
                            Text(outcome.confirmedKeys.joined(separator: ", ").isEmpty
                                 ? "未确认"
                                 : outcome.confirmedKeys.joined(separator: ", "))
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !learned.isEmpty {
                    Button {
                        Task {
                            await model.apply()
                            dismiss()
                        }
                    } label: {
                        Text("在这台手机上启用")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LeapStyle.accent)
                    .controlSize(.large)
                }

                ShareLink(item: model.report) {
                    Label("把标定报告发给开发者", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Text("报告里只有信号编号和前后数值，不含车架号、位置和账号信息。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
    }
}
