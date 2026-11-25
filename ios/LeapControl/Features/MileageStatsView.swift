import SwiftUI

/// 里程能耗统计页。数据来自四个 drivingrecord 接口（见 LeapClient.fetchDrivingStats）。
/// 图表用原生 SwiftUI 形状手绘，避免额外依赖，也好精确对齐设计稿。
struct MileageStatsView: View {
    @Environment(VehicleStore.self) private var store
    @State private var stats: DrivingStats?
    @State private var isLoading = true
    /// 当前选中的周柱子（`WeeklyEC.id`）。默认是最后一根「本周」，和官方一致。
    /// 周列表整个没拉到时为 nil，构成卡退回「近 7 天」并改口。
    @State private var selectedWeekID: String?
    /// 按周缓存的能耗构成：点过的周不再重复请求。
    @State private var distributions: [String: DrivingStats.EnergyDistribution] = [:]
    @State private var loadingWeekID: String?

    // 行车/空调/其他三块的固定配色，和图例、环形图共用。
    private let driverColor = LeapStyle.accent
    private let acColor = LeapStyle.cool
    private let otherColor = LeapStyle.warm

    var body: some View {
        ZStack {
            LeapBackground(tint: LeapStyle.accent)
            ScrollView {
                VStack(spacing: 14) {
                    if let stats, !stats.isEmpty {
                        content(stats)
                    } else if isLoading {
                        placeholder(text: "正在加载里程能耗…", spinning: true)
                    } else {
                        placeholder(text: "暂时拿不到里程能耗数据", spinning: false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
        .navigationTitle("行程")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        let loaded = await store.loadDrivingStats()
        stats = loaded
        // 下拉刷新会把六周的数一起换新，旧缓存不能留着接着用。
        distributions = [:]
        loadingWeekID = nil
        selectedWeekID = loaded?.distributionWeekID
        if let id = loaded?.distributionWeekID, let distribution = loaded?.energyDistribution {
            distributions[id] = distribution
        }
        isLoading = false
    }

    /// 点某根周柱子：切选中态，缺数据才发请求，拿过的直接用缓存。
    private func select(_ week: DrivingStats.WeeklyEC) {
        guard let range = week.range else { return }
        selectedWeekID = week.id
        guard distributions[week.id] == nil else { return }
        loadingWeekID = week.id
        Task {
            let distribution = await store.loadEnergyDistribution(range: range)
            // 拉不到就不写缓存：下次再点还会重试，界面这轮整卡隐藏。
            if let distribution { distributions[week.id] = distribution }
            if loadingWeekID == week.id { loadingWeekID = nil }
        }
    }

    @ViewBuilder
    private func content(_ stats: DrivingStats) -> some View {
        if let totals = stats.totals { totalsCard(totals) }
        if let weekly = stats.weekly, !weekly.weeks.isEmpty { weeklyCard(weekly) }
        distributionSection(stats)
        if !stats.daily.isEmpty { dailyCard(stats.daily) }
        // 说清这一栏的数据是谁给的。隔壁「行车轨迹」那栏的里程来自车机 GPS，
        // 两个数永远对不上，各自标明来源比事后解释省事。
        Text("数据来自零跑官方，按天统计，不含逐趟行程。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
    }

    // MARK: - 累计里程 / 累计能耗 / 交付天数

    private func totalsCard(_ totals: DrivingStats.Totals) -> some View {
        GlassCard(radius: LeapStyle.tileRadius) {
            HStack(spacing: 0) {
                totalColumn("累计里程", value: totals.totalMileageKm.map(grouped), unit: "km")
                columnDivider
                totalColumn("累计能耗", value: totals.totalEnergyKwh.map(grouped), unit: "kWh")
                columnDivider
                totalColumn("交付天数", value: totals.deliveryDays.map(grouped), unit: "天")
            }
        }
    }

    private func totalColumn(_ title: String, value: String?, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "--")
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 近 6 周百公里电耗 + 排名 + 柱状

    private func weeklyCard(_ weekly: DrivingStats.Weekly) -> some View {
        let values = weekly.weeks.map { $0.hundredKmEc ?? 0 }
        let maxValue = max(values.max() ?? 1, 0.1)
        return GlassCard(radius: LeapStyle.tileRadius) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("近 6 周百公里电耗").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(weekly.rankHundredKmEc.map { trimmed($0) } ?? "--")
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("kWh").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let rank = weekly.rankPercent {
                        VStack(alignment: .trailing, spacing: 4) {
                            Label("前 \(rank)", systemImage: "trophy")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LeapStyle.accent)
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(Capsule().fill(LeapStyle.accent.opacity(0.14)))
                                .fixedSize()
                            Text("领先全国同车型").font(.caption2).foregroundStyle(.tertiary).fixedSize()
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 7) {
                    ForEach(Array(weekly.weeks.enumerated()), id: \.element.id) { index, week in
                        let isLast = index == weekly.weeks.count - 1
                        // 主色跟着选中走；一根都没选中（周列表在、但区间解析不出来）时回到「本周高亮」。
                        let highlighted = selectedWeekID.map { $0 == week.id } ?? isLast
                        Button { select(week) } label: {
                            VStack(spacing: 4) {
                                Text(week.hundredKmEc.map { trimmed($0) } ?? "--")
                                    .font(.system(size: 10, weight: highlighted ? .semibold : .regular))
                                    .foregroundStyle(highlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(highlighted ? AnyShapeStyle(LeapStyle.accent) : AnyShapeStyle(LeapStyle.cool.opacity(0.5)))
                                    .frame(height: barHeight(week.hundredKmEc ?? 0, maxValue: maxValue))
                                Text(isLast ? "本周" : weekLabel(week))
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(week.range == nil)
                        .accessibilityLabel("\(weekRangeLabel(week, isLast: isLast))能耗构成")
                        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .frame(height: 108)
                .animation(.easeInOut(duration: 0.18), value: selectedWeekID)
            }
        }
    }

    private func barHeight(_ value: Double, maxValue: Double) -> CGFloat {
        let usable: CGFloat = 74
        return max(6, CGFloat(value / maxValue) * usable)
    }

    // MARK: - 能耗构成环形图（跟着选中的那一周走）

    /// 选中周的构成卡。没选中任何周（周列表没拉到）时退回 `stats` 里那份「近 7 天」并改口；
    /// 选中周拉不到数据就整卡不出——不填 0，也不拿别的区间顶。
    @ViewBuilder
    private func distributionSection(_ stats: DrivingStats) -> some View {
        if let selectedWeekID {
            let week = stats.weekly?.weeks.first { $0.id == selectedWeekID }
            let title = week.map { weekRangeLabel($0, isLast: $0.id == stats.weekly?.weeks.last?.id) } ?? "所选周"
            if let distribution = distributions[selectedWeekID] {
                distributionCard(distribution, title: "\(title)能耗分布")
            } else if loadingWeekID == selectedWeekID {
                distributionLoadingCard(title: "\(title)能耗分布")
            }
        } else if let distribution = stats.energyDistribution {
            distributionCard(distribution, title: "近 7 天能耗分布")
        }
    }

    private func distributionLoadingCard(title: String) -> some View {
        GlassCard(radius: LeapStyle.tileRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 104)
            }
        }
    }

    private func distributionCard(_ dist: DrivingStats.EnergyDistribution, title: String) -> some View {
        let driver = dist.driverKwh, ac = dist.acKwh, other = dist.otherKwh
        let total = max(driver + ac + other, 0.0001)
        let driverFrac = driver / total
        let acFrac = ac / total
        return GlassCard(radius: LeapStyle.tileRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(title) · 总 \(trimmed(dist.totalKwh)) kWh")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    ZStack {
                        ring(from: 0, to: driverFrac, color: driverColor)
                        ring(from: driverFrac, to: driverFrac + acFrac, color: acColor)
                        ring(from: driverFrac + acFrac, to: 1, color: otherColor)
                        VStack(spacing: 0) {
                            Text(trimmed(dist.totalKwh))
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("kWh").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 10) {
                        legendRow("行车能耗", pct: dist.driverPct, color: driverColor)
                        legendRow("空调能耗", pct: dist.acPct, color: acColor)
                        legendRow("其他能耗", pct: dist.otherPct, color: otherColor)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func ring(from: Double, to: Double, color: Color) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: 15, lineCap: .butt))
            .rotationEffect(.degrees(-90))
            .padding(8)
    }

    private func legendRow(_ title: String, pct: Double?, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(pct.map { "\(trimmed($0))%" } ?? "--")
                .font(.footnote.weight(.medium)).monospacedDigit()
        }
    }

    // MARK: - 近 7 天里程折线

    private func dailyCard(_ daily: [DrivingStats.DailyMileage]) -> some View {
        let values = daily.map { Double($0.mileageKm ?? 0) }
        let total = daily.reduce(0) { $0 + ($1.mileageKm ?? 0) }
        return GlassCard(radius: LeapStyle.tileRadius) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("近 7 天里程").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(grouped(total))
                            .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("km").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                DailyMileageChart(values: values, labels: daily.map(dayLabel), accent: LeapStyle.accent)
                    .frame(height: 104)
            }
        }
    }

    // MARK: - 状态占位

    private func placeholder(text: String, spinning: Bool) -> some View {
        GlassCard {
            VStack(spacing: 12) {
                if spinning { ProgressView() }
                else { Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.secondary) }
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    // MARK: - 小工具

    private var columnDivider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 34)
    }

    private func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 去掉多余小数尾巴：15.0 → "15"，15.7 → "15.7"。
    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func weekLabel(_ week: DrivingStats.WeeklyEC) -> String {
        guard let start = week.weekStart else { return "" }
        // "2026-07-06" → "7/6"
        let parts = start.split(separator: "-")
        guard parts.count == 3 else { return start }
        return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }

    /// 构成卡标题里的周名：最后一根叫「本周」，其余用 "7/6–7/12" 这样的区间。
    private func weekRangeLabel(_ week: DrivingStats.WeeklyEC, isLast: Bool) -> String {
        if isLast { return "本周" }
        let start = weekLabel(week)
        guard let end = week.weekEnd else { return start }
        let parts = end.split(separator: "-")
        guard parts.count == 3 else { return start }
        return "\(start)–\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }

    private func dayLabel(_ entry: DrivingStats.DailyMileage) -> String {
        // day 形如 "2026-08-06" 或 "08-06"，取月/日。
        let parts = entry.day.split(separator: "-")
        guard let dayComponent = parts.last, let dayNum = Int(dayComponent) else { return entry.day }
        return String(dayNum)
    }
}

/// 折线图：把每日里程点连成线，点上标数值，底部标日期。末点空心加粗。
private struct DailyMileageChart: View {
    let values: [Double]
    let labels: [String]
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let topInset: CGFloat = 20      // 给数值标签留头
            let bottomInset: CGFloat = 18   // 给日期标签留脚
            let plotHeight = max(height - topInset - bottomInset, 1)
            let maxValue = max(values.max() ?? 1, 1)
            let minValue = min(values.min() ?? 0, maxValue)
            let span = max(maxValue - minValue, 1)
            let points = values.enumerated().map { index, value -> CGPoint in
                let x = values.count > 1 ? width * CGFloat(index) / CGFloat(values.count - 1) : width / 2
                let y = topInset + plotHeight * (1 - CGFloat((value - minValue) / span))
                return CGPoint(x: x, y: y)
            }

            ZStack {
                // 折线
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    let isLast = index == points.count - 1
                    // 数据点
                    Circle()
                        .fill(isLast ? Color(.systemBackground) : accent)
                        .frame(width: isLast ? 9 : 6, height: isLast ? 9 : 6)
                        .overlay(isLast ? Circle().stroke(accent, lineWidth: 2) : nil)
                        .position(point)
                    // 数值标签
                    Text(String(Int(values[index])))
                        .font(.system(size: 10, weight: isLast ? .semibold : .regular))
                        .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .position(x: point.x, y: max(point.y - 13, 8))
                    // 日期标签
                    Text(dayText(index))
                        .font(.system(size: 9))
                        .foregroundStyle(isLast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .position(x: point.x, y: height - 7)
                }
            }
        }
    }

    private func dayText(_ index: Int) -> String {
        let count = labels.count
        if index == count - 1 { return "今天" }
        if index == count - 2 { return "昨天" }
        if index == count - 3 { return "前天" }
        return labels[index]
    }
}
