import SwiftUI

/// 逐趟行程记录。
///
/// 和隔壁「行程」（`MileageStatsView`，零跑官方的里程能耗统计）是两件事：那边是官方按天/按周
/// 聚合的数，这边是 App 自己按 10 秒一次的轮询切出来的「这一趟从哪到哪、跑了多久、掉了几个电」。
/// 两个数永远对不上——一个按天结算、一个按次切段，中间还隔着「App 有没有在跑」。
/// 所以这里从头到尾都说清数据是哪来的，页面底部也不放「合计」这种会被拿去对账的数。
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
                    } else {
                        summaryCard
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
        }
        .navigationTitle("行程记录")
        .navigationBarTitleDisplayMode(.inline)
        // 地名一个个补，补到就回写文件。只补最近 8 条：更早的那些翻到的概率低，
        // 一进页面就打十几个反地理编码请求，既慢又没必要。
        .task(id: trips.prefix(8).map(\.id)) {
            await resolveMissingPlaces()
        }
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        let count = recentTrips.count
        let distance = recentTrips.reduce(0) { $0 + $1.distanceKm }
        let duration = recentTrips.reduce(0) { $0 + $1.duration }
        return GlassCard(radius: LeapStyle.tileRadius) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("近 7 天").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if recentTrips.contains(where: \.isReconstructed) {
                        Text("含补记").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 0) {
                    metric("行程", value: "\(count)", unit: "次")
                    divider
                    metric("里程", value: trimmed(distance), unit: "km")
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
                if trip.isReconstructed { reconstructedTag }
                Spacer(minLength: 6)
                Text("\(trimmed(trip.distanceKm)) km")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

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

            HStack(spacing: 10) {
                Label(durationText(trip.duration), systemImage: "clock")
                if let drop = trip.socDrop {
                    Label("\(drop)%", systemImage: "battery.75percent")
                }
                if let speed = trip.averageSpeedKmh {
                    Label("\(Int(speed.rounded())) km/h", systemImage: "gauge.with.dots.needle.33percent")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
        }
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
                Text("App 开着的时候每 10 秒看一次车况，车一动就开始记，停稳半分钟后收尾。App 没在跑的那段路，下次打开时会按里程表的差补一条「补记」。")
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
        Text("记录在本机，不上传。里程按里程表与轨迹取大者，与零跑官方「行程」页的按天统计不会完全一致。")
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
            $0.startPlace == nil || $0.endPlace == nil
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
