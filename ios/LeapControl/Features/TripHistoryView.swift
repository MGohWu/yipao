import SwiftUI

/// 逐趟行程记录。
///
/// 和隔壁「行程」（`MileageStatsView`，零跑官方的里程能耗统计）是两件事：那边是按天/按周
/// 聚合的数，这边是「这一趟从哪到哪、跑了多久、用了多少电」。
///
/// 数据来自两处，页面上分别标出来：
/// - **官方**：零跑云端自己的逐趟明细（`CloudTripRecord`），App 开没开都有，覆盖近 30 天；
/// - **本机**：轮询切出来的那些，能补上起终点地名和电量变化；
/// - **补记**：官方和本机都没有、只能拿里程表差估算的那一段。
struct TripHistoryView: View {
    @Environment(VehicleStore.self) private var store
    @StateObject private var recorder = TripRecorder.shared
    /// 地名补齐的进度：正在补哪一条。补的时候那行显示一个细进度条，不遮内容。
    @State private var resolvingID: UUID?

    private var vin: String? { store.session.selectedVin }

    private var trips: [TripRecord] {
        if store.isDemo { return ReviewDemo.tripLog }
        // 老记录没有 vin（这份数据刚上线时写的），一并显示，别让升级用户觉得记录丢了。
        guard let vin else { return recorder.trips }
        return recorder.trips.filter { $0.vin == nil || $0.vin == vin }
    }

    /// 按天分组，新的一天在上面。
    private var days: [(day: Date, trips: [TripRecord])] {
        Dictionary(grouping: trips) { $0.dayStart }
            .map { (day: $0.key, trips: $0.value.sorted { $0.startAt > $1.startAt }) }
            .sorted { $0.day > $1.day }
    }

    /// 近 7 天（含今天）的汇总。用「近 7 天」而不是「本周」：周一早上打开时「本周」只有一趟，
    /// 看着像数据丢了。
    private var recentTrips: [TripRecord] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return trips }
        return trips.filter { $0.startAt >= start }
    }

    var body: some View {
        ZStack {
            LeapBackground(tint: LeapStyle.accent)
            ScrollView {
                VStack(spacing: 14) {
                    if !store.isDemo, let active = recorder.active {
                        activeCard(active)
                    }
                    if trips.isEmpty {
                        emptyCard
                        syncRow
                    } else {
                        summaryCard
                        syncRow
                        ForEach(days, id: \.day) { group in
                            dayCard(group.day, trips: group.trips)
                        }
                        footer
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            // 官方记录是「按趟结算」的数据，下拉就重新拉一次——不用等 6 小时。
            .refreshable { await store.syncTripLog(force: true) }
        }
        .navigationTitle("行程记录")
        .navigationBarTitleDisplayMode(.inline)
        // 进页面顺手对一次官方记录：没有同步过、或者已经过了 6 小时才会真的发请求。
        .task {
            await store.syncTripLog()
        }
        // 地名一个个补，补到就回写文件。只补最近 8 条：更早的那些翻到的概率低，
        // 一进页面就打十几个反地理编码请求，既慢又没必要。
        .task(id: trips.prefix(8).map(\.id)) {
            await resolveMissingPlaces()
        }
    }

    // MARK: - 同步状态

    /// 官方记录同步得怎么样。失败时点一下重试——比让用户去猜「为什么只有本机记录」好。
    @ViewBuilder
    private var syncRow: some View {
        if !store.isDemo {
            switch recorder.cloudSync {
            case .syncing:
                statusLine(icon: "arrow.triangle.2.circlepath", text: "正在同步零跑官方记录…", tint: .secondary)
            case .synced(let date, let count):
                statusLine(
                    icon: "checkmark.icloud",
                    text: count > 0
                        ? "官方记录已同步：\(count) 趟 · \(timeText(date))"
                        : "官方记录已同步 · \(timeText(date))",
                    tint: .secondary
                )
            case .failed(let message):
                Button {
                    Task { await store.syncTripLog(force: true) }
                } label: {
                    statusLine(icon: "exclamationmark.icloud", text: "官方记录暂不可用：\(message)", tint: LeapStyle.caution)
                }
                .buttonStyle(.plain)
            case .idle:
                EmptyView()
            }
        }
    }

    private func statusLine(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        let count = recentTrips.count
        let distance = recentTrips.reduce(0) { $0 + $1.distanceKm }
        let duration = recentTrips.reduce(0) { $0 + $1.duration }
        let energies = recentTrips.compactMap(\.energyKWh)
        let energy = energies.reduce(0, +)
        return GlassCard(radius: LeapStyle.tileRadius) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("近 7 天 · \(count) 趟").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if recentTrips.contains(where: \.isReconstructed) {
                        Text("含补记").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 0) {
                    metric("里程", value: trimmed(distance), unit: "km")
                    divider
                    // 官方没给度数的那些（今天刚跑的、或者接口没回来）不计入，所以这一格
                    // 只在至少有一趟带官方度数时才有意义。
                    metric("耗电", value: energies.isEmpty ? "—" : String(format: "%.1f", energy), unit: "kWh")
                    divider
                    metric("在车上", value: durationText(duration), unit: "")
                }
            }
        }
    }

    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 34)
    }

    // MARK: - 进行中

    private func activeCard(_ trip: TripRecord) -> some View {
        GlassCard(radius: LeapStyle.tileRadius) {
            HStack(spacing: 12) {
                Image(systemName: "location.north.line.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LeapStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(LeapStyle.accent.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("行程进行中").font(.subheadline.weight(.semibold))
                    Text("已过去 \(durationText(Date().timeIntervalSince(trip.startAt)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 一天

    private func dayCard(_ day: Date, trips: [TripRecord]) -> some View {
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayTitle(day)).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(trips.count) 趟 · \(trimmed(distance)) km")
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.horizontal, 6)

            GlassCard(radius: LeapStyle.tileRadius) {
                VStack(spacing: 0) {
                    ForEach(Array(trips.enumerated()), id: \.element.id) { index, trip in
                        tripRow(trip)
                        if index < trips.count - 1 {
                            Rectangle().fill(.quaternary).frame(height: 1).padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    private func tripRow(_ trip: TripRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timeText(trip.startAt))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if trip.isReconstructed {
                    reconstructedTag
                } else if trip.hasOfficialData {
                    officialTag
                }
                Spacer(minLength: 6)
                Text("\(trimmed(trip.distanceKm)) km")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            if trip.startCoordinate == nil, trip.endCoordinate == nil {
                // 云端那批记录只有结算数据，没有经纬度。与其写两行「起点未知」，不如说清原因。
                Label("官方记录，无起终点位置", systemImage: "cloud")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "circle.fill").font(.system(size: 4))
                    Text(trip.startPlace ?? "起点未知")
                        .lineLimit(1)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                    Text(trip.endPlace ?? "终点未知")
                        .lineLimit(1)
                    if resolvingID == trip.id {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label(durationText(trip.duration), systemImage: "clock")
                if let energy = trip.energyKWh, energy > 0 {
                    Label(String(format: "%.1f kWh", energy), systemImage: "bolt.fill")
                }
                if let drop = trip.socDrop {
                    Label("\(drop)%", systemImage: "battery.75percent")
                }
                if let speed = trip.maxSpeedKmh {
                    Label("最高 \(speed)", systemImage: "gauge.with.dots.needle.67percent")
                } else if let speed = trip.averageSpeedKmh {
                    Label("\(Int(speed.rounded())) km/h", systemImage: "gauge.with.dots.needle.33percent")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
        }
    }

    /// 官方记录标。和「补记」不同色：一个是可信的，一个是估算的。
    private var officialTag: some View {
        Text("官方")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(LeapStyle.accent.opacity(0.14), in: .rect(cornerRadius: 4))
            .foregroundStyle(LeapStyle.accent)
    }

    private var reconstructedTag: some View {
        Text("补记")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(LeapStyle.caution.opacity(0.16), in: .rect(cornerRadius: 4))
            .foregroundStyle(LeapStyle.caution)
    }

    // MARK: - 空态与说明

    private var emptyCard: some View {
        GlassCard(radius: LeapStyle.tileRadius) {
            VStack(spacing: 10) {
                Image(systemName: "road.lanes")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("还没有行程记录").font(.subheadline.weight(.medium))
                Text("零跑云端会存每一趟的结算数据，打开这一页就会拉下来（最近 30 天），App 没开过也不影响。本机同时按 10 秒一次的车况自己切段，补上起终点和电量；两边都没有的那段路，才会按里程表差补一条「补记」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        }
    }

    private var footer: some View {
        Text("标「官方」的是零跑云端的逐趟结算（距离与度数对得上官方 App）；没标的来自本机轮询，多出起终点地名与电量变化。「补记」是按里程表差估算的，只出现在官方也没有记录的那段。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.top, 2)
    }

    // MARK: - 地名

    /// 起点/终点地名是后补的：行程刚结束时只知道坐标，反地理编码要走网络，不能卡着记录。
    private func resolveMissingPlaces() async {
        guard !store.isDemo else { return }
        let pending = Array(recorder.trips.prefix(8).filter {
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
