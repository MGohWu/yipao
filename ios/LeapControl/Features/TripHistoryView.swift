import SwiftUI

/// 逐趟行程记录。
///
/// 数据来自两处，页面上分别标出来：
/// - **官方**：零跑云端自己的逐趟明细（`CloudTripRecord`），App 开没开都有，覆盖近 30 天；
/// - **本机**：轮询切出来的那些，能补上起终点地名和电量变化；
/// - **补记**：官方和本机都没有、只能拿里程表差估算的那一段。
struct TripHistoryView: View {
    @Environment(VehicleStore.self) private var store
    @StateObject private var recorder = TripRecorder.shared
    /// 默认落在哪个时间档由入口决定：首页「今日行程」卡进来直接看今天，
    /// 行程 Tab 里还是「近 7 天」。选档之后用户自己切，页面不替他锁死。
    @State private var range: RecordsRange
    /// 地名补齐的进度：正在补哪一条。补的时候那行显示一个细进度条，不遮内容。
    @State private var resolvingID: UUID?
    /// 长按后待确认删除的那一条。
    @State private var pendingDelete: TripRecord?

    init(defaultRange: RecordsRange = .week) {
        _range = State(initialValue: defaultRange)
    }

    private var vin: String? { store.session.selectedVin }

    private var allTrips: [TripRecord] {
        if store.isDemo { return ReviewDemo.tripLog }
        // 老记录没有 vin（这份数据刚上线时写的），一并显示，别让升级用户觉得记录丢了。
        guard let vin else { return recorder.trips }
        return recorder.trips.filter { $0.vin == nil || $0.vin == vin }
    }

    private var trips: [TripRecord] {
        allTrips.filter { range.contains($0.startAt) }
    }

    private var days: [(day: Date, trips: [TripRecord])] {
        Dictionary(grouping: trips) { $0.dayStart }
            .map { (day: $0.key, trips: $0.value.sorted { $0.startAt > $1.startAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        ZStack {
            LeapBackground(tint: LeapStyle.accent)
            ScrollView {
                VStack(spacing: 14) {
                    if !store.isDemo, let active = recorder.active {
                        RecordsLiveCard(
                            icon: "location.north.line.fill",
                            tint: LeapStyle.accent,
                            title: "行程进行中",
                            detail: "已过去 \(durationText(Date().timeIntervalSince(active.startAt)))",
                            trailing: nil
                        )
                    }

                    RecordsRangePicker(selection: $range)
                        .padding(.horizontal, 2)

                    if trips.isEmpty {
                        RecordsEmptyCard(
                            icon: "road.lanes",
                            title: "这段时间没有行程",
                            message: "App 开着的时候会自己切段记录。零跑云端的逐趟明细如果能取到，这里还会多出标「官方」的记录；部分账号（尤其国区）这个接口不给数据，那就只有本机这几条。"
                        )
                    } else {
                        hero
                        ForEach(days, id: \.day) { group in
                            daySection(group.day, trips: group.trips)
                        }
                        footer
                    }

                    RecordsSyncLine(state: syncState) {
                        Task { await store.syncTripLog(force: true) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            // 官方记录是「按趟结算」的数据，下拉就重新拉一次——不用等 6 小时。
            .refreshable { await store.syncTripLog(force: true) }
        }
        .navigationTitle("行程记录")
        .navigationBarTitleDisplayMode(.large)
        // 进页面顺手对一次云端：没有同步过、或者已经过了 6 小时才会真的发请求。
        .task { await store.syncTripLog() }
        // 地名一个个补，补到就回写文件。只补最近 8 条：更早的那些翻到的概率低，
        // 一进页面就打十几个反地理编码请求，既慢又没必要。
        .task(id: allTrips.prefix(8).map(\.id)) { await resolveMissingPlaces() }
        .confirmationDialog(
            "删除这条行程？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { trip in
            Button("删除", role: .destructive) {
                recorder.delete(trip)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { trip in
            Text("\(timeText(trip.startAt)) → \(timeText(trip.endAt))，\(trimmed(trip.distanceKm)) km。")
        }
    }

    // MARK: - 汇总

    private var hero: some View {
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        let duration = trips.reduce(0) { $0 + $1.duration }
        let energies = trips.compactMap(\.energyKWh)
        let bars = RecordsBar.daily(
            trips.map { ($0.startAt, $0.distanceKm) },
            days: range.chartDays
        )
        return RecordsHero(
            caption: "\(range.title) · \(trips.count) 趟",
            value: trimmed(distance),
            unit: "km",
            bars: bars,
            footnote: trips.contains(where: \.isReconstructed) ? "含补记" : nil,
            metrics: [
                .init(title: "在车上", value: durationText(duration)),
                .init(title: "耗电", value: energies.isEmpty ? "—" : String(format: "%.1f", energies.reduce(0, +)), unit: "kWh"),
                .init(title: "最长一趟", value: trimmed(trips.map(\.distanceKm).max() ?? 0), unit: "km")
            ]
        )
    }

    // MARK: - 一天

    private func daySection(_ day: Date, trips: [TripRecord]) -> some View {
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        return VStack(alignment: .leading, spacing: 8) {
            RecordsDayHeader(
                title: dayTitle(day),
                summary: "\(trips.count) 趟 · \(trimmed(distance)) km"
            )
            GlassCard(radius: LeapStyle.cardRadius) {
                VStack(spacing: 0) {
                    ForEach(Array(trips.enumerated()), id: \.element.id) { index, trip in
                        tripRow(trip)
                        if index < trips.count - 1 {
                            Rectangle()
                                .fill(LeapStyle.hairline)
                                .frame(height: 1)
                                .padding(.vertical, 11)
                        }
                    }
                }
            }
        }
    }

    private func tripRow(_ trip: TripRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // 出发 → 到达。以前只给出发时间，得自己拿时长去加，
                // 而且和「补记」那种跨小时的记录对不上号。
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(timeText(trip.startAt))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(timeText(trip.endAt))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if crossesMidnight(trip) {
                        Text("+1")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                if trip.isReconstructed {
                    RecordsTag(text: "补记", tint: LeapStyle.caution)
                } else if trip.hasOfficialData {
                    RecordsTag(text: "官方", tint: LeapStyle.accent)
                }
                Spacer(minLength: 6)
                Text(trimmed(trip.distanceKm))
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("km")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, -3)
            }

            if trip.startCoordinate == nil, trip.endCoordinate == nil {
                // 云端那批记录只有结算数据，没有经纬度。与其写两行「起点未知」，不如说清原因。
                Label("官方结算记录，无起终点位置", systemImage: "cloud")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 5) {
                    Circle().fill(LeapStyle.accent).frame(width: 5, height: 5)
                    Text(trip.startPlace ?? "起点未知").lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(trip.endPlace ?? "终点未知").lineLimit(1)
                    if resolvingID == trip.id {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            RecordsMeta(items: metaItems(trip))
        }
        // 隐藏功能：长按弹出删除。不放可见的删除按钮——这一页是拿来看的，
        // 每行挂一个删除图标会把版面弄脏，还容易被误触。
        .contentShape(.rect)
        .contextMenu {
            Button(role: .destructive) {
                pendingDelete = trip
            } label: {
                Label("删除这条记录", systemImage: "trash")
            }
        }
    }

    private func metaItems(_ trip: TripRecord) -> [(icon: String, text: String)] {
        var items: [(String, String)] = [("clock", durationText(trip.duration))]
        if let energy = trip.energyKWh, energy > 0 {
            items.append(("bolt.fill", String(format: "%.1f kWh", energy)))
        }
        if let drop = trip.socDrop {
            items.append(("battery.75percent", "\(drop)%"))
        }
        if let speed = trip.maxSpeedKmh {
            items.append(("gauge.with.dots.needle.67percent", "最高 \(speed)"))
        } else if let speed = trip.averageSpeedKmh {
            items.append(("gauge.with.dots.needle.33percent", "\(Int(speed.rounded())) km/h"))
        }
        return items
    }

    // MARK: - 同步状态

    private var syncState: RecordsSyncState {
        guard !store.isDemo else { return .hidden }
        switch recorder.cloudSync {
        case .idle: return .hidden
        case .syncing: return .working
        case .synced(let date, let count):
            let text = count > 0
                ? "官方记录已同步：\(count) 趟 · \(timeText(date))"
                : "官方记录已同步 · \(timeText(date))"
            return .done(text)
        case .failed(let message):
            return .failure(message)
        }
    }

    private var footer: some View {
        Text("标「官方」的是零跑云端的逐趟结算（距离与度数对得上官方 App）；没标的来自本机轮询，多出起终点地名与电量变化。「补记」是按里程表差估算的，只出现在两边都没有记录的那段。国区部分账号取不到云端明细，那时全页都只有本机记录——这是接口限制，不是漏记。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }

    // MARK: - 地名

    /// 起点/终点地名是后补的：行程刚结束时只知道坐标，反地理编码要走网络，不能卡着记录。
    private func resolveMissingPlaces() async {
        guard !store.isDemo else { return }
        let pending = Array(allTrips.prefix(8).filter {
            // 官方那批没有经纬度，问了也没得补，直接跳过——否则每条都要白等 350 毫秒。
            ($0.startPlace == nil || $0.endPlace == nil)
                && ($0.startCoordinate != nil || $0.endCoordinate != nil)
        })
        for trip in pending {
            guard !Task.isCancelled else { return }
            resolvingID = trip.id
            var start = trip.startPlace
            var end = trip.endPlace
            if start == nil, let coordinate = trip.startCoordinate {
                start = await LocationNaming.name(for: coordinate)
            }
            if end == nil, let coordinate = trip.endCoordinate {
                // 起终点几乎重合（车库进出、绕一圈回来）就别再问一次，省一个请求。
                if let origin = trip.startCoordinate, TripTracker.distance(origin, coordinate) < 60 {
                    end = start
                } else {
                    end = await LocationNaming.name(for: coordinate)
                }
            }
            recorder.applyPlaces(id: trip.id, start: start, end: end)
            // 反地理编码有频率限制，一条一条来。
            try? await Task.sleep(for: .milliseconds(350))
        }
        resolvingID = nil
    }

    // MARK: - 格式化

    /// 跨零点的行程：到达时间后面补一个「+1」，不然「23:40 → 00:10」看着像往回走。
    private func crossesMidnight(_ trip: TripRecord) -> Bool {
        !Calendar.current.isDate(trip.startAt, inSameDayAs: trip.endAt)
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.month().day().weekday(.abbreviated))
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
