import Combine
import Foundation

/// 行程记录器。
///
/// 两个数据进同一个列表：
///
/// 1. 挂在 10 秒一次的车况轮询上，把「车动了 / 车停了」串成一趟趟行程（`TripTracker`）。
///    它只在 App 活着时存在，但看得见坐标、电量和地名。
/// 2. 零跑云端的逐趟明细（`LeapClient.fetchCloudTrips`）。App 开没开都有，覆盖过去 30 天，
///    代价是没有经纬度。两者由 `CloudTripMerge` 合成一份，重复的那一趟不会记两次。
///
/// 落盘的只有**已经结束**的行程。进行中的那一趟留在内存里（`active`），App 被杀掉就没了——
/// 这是故意的：进程被系统清掉的那一刻，最后一段路到底开没开、开了多远，我们无从知道，
/// 与其存一个半截的、每次启动都接着往上加时间的怪东西，不如让下次启动时的「断档补记」
/// 用里程表差给它一个诚实的、带标注的交代。这条补记之后大概率会被云端那条官方记录取代
/// （见 `CloudTripMerge.dropCoveredReconstructions`）。
@MainActor
final class TripRecorder: ObservableObject {
    static let shared = TripRecorder()

    /// 云端同步的状态。界面据此显示「同步中 / 已同步 12 趟 / 失败原因」。
    enum CloudSync: Equatable {
        case idle
        case syncing
        case synced(Date, Int)
        case failed(String)
    }

    /// 已结束的行程，最新的在前。
    @Published private(set) var trips: [TripRecord]
    /// 正在跑的这一趟。没有就是 nil。
    @Published private(set) var active: TripRecord?
    @Published private(set) var cloudSync: CloudSync = .idle

    /// 多久重新同步一次。云端记录是「结算」数据，一趟跑完要过一会儿才出现，
    /// 所以没必要每次进页面都拉——6 小时一次，加上下拉手动刷新，够用且不打扰服务端。
    static let syncInterval: TimeInterval = 6 * 3600
    /// 往回拉多少天。30 天足够翻，再长就翻不动了，而且云端按页给，越多越慢。
    static let syncWindowDays = 30

    private var tracker = TripTracker()
    private let defaults = UserDefaults(suiteName: SnapshotStore.appGroup) ?? .standard

    private static let lastSyncKey = "tripCloudSyncAt"
    /// 刚失败过就隔一会儿再试：进页面、切前后台都会触发同步，
    /// 服务端那边不通的话，一分钟能连打七八次——这不是重试，是骚扰。
    static let failureCooldown: TimeInterval = 5 * 60
    /// 连败这么多次就不再自动试了，改成一天一次。
    ///
    /// 这不是偷懒：国区的逐趟明细接口看情况是不给用的（`leapmotor-mate-cn` 的国区版
    /// 文档也写着「官方逐笔行程导入尚未支援」）。每 6 小时打十来个注定失败的请求，
    /// 换来的只有车主每天看到一句红字。
    static let giveUpAfter = 3
    static let giveUpInterval: TimeInterval = 24 * 3600
    private var failedAt: Date?

    private static let failureCountKey = "tripCloudFailureCount"

    var consecutiveFailures: Int { defaults.integer(forKey: Self.failureCountKey) }

    private init() {
        trips = TripLogStore.load()
        if let stamp = defaults.object(forKey: Self.lastSyncKey) as? Date {
            cloudSync = .synced(stamp, 0)
        }
    }

    /// 上次跟云端对齐的时间。
    var lastSyncAt: Date? {
        if case .synced(let date, _) = cloudSync { return date }
        return nil
    }

    /// 该不该现在就同步。没有同步过、或者离上次超过 6 小时；刚失败过则等冷却结束。
    var needsCloudSync: Bool {
        if let failedAt {
            let wait = consecutiveFailures >= Self.giveUpAfter
                ? Self.giveUpInterval : Self.failureCooldown
            if Date().timeIntervalSince(failedAt) < wait { return false }
        }
        guard let lastSyncAt else { return true }
        return Date().timeIntervalSince(lastSyncAt) >= Self.syncInterval
    }

    /// 每轮车况刷新后调一次。
    func observe(_ state: VehicleState, vin: String?, at date: Date = .now) {
        let sample = TripTracker.Sample(
            at: date,
            odometerKm: state.totalMileage,
            soc: state.soc,
            coordinate: state.shareableCoordinate,
            gearDriving: state.isDriving,
            poweredOn: state.powerOn3,
            cableIn: state.chargeGunConnected
        )
        for trip in tracker.ingest(sample, vin: vin) {
            record(trip)
        }
        // 进行中的行程也要让界面看到：位置页那条「行程进行中」靠它。
        if active != tracker.active { active = tracker.active }
    }

    /// 丢掉正在跑的这一趟——退出登录、进入演示模式时用。
    ///
    /// 不把它当一条行程交出去：这时候拿到的是半个行程（距离还没结算），存下来只会是
    /// 一条 0 公里的脏数据。真要结束，让轮询自己判「停稳一分钟」就行。
    func forgetActiveTrip() {
        tracker = TripTracker()
        active = nil
    }

    // MARK: - 云端

    /// 把云端那一批记录合进列表。可在任意线程之外的 MainActor 上调，幂等。
    @discardableResult
    func mergeCloud(_ records: [CloudTripRecord]) -> CloudTripMerge.Result {
        let now = Date()
        let window = now.addingTimeInterval(-Double(Self.syncWindowDays + 1) * 86_400)...now.addingTimeInterval(86_400)
        // 正在跑的这一趟还没结算，云端不会有它；万一有（上一趟刚结束、我们还没收尾），
        // 先跳过——等它真的结束了再合，否则列表里会同时出现「进行中」和「官方那一趟」。
        let filtered = records.filter { record in
            guard let active else { return true }
            return CloudTripMerge.intersection(active.startAt, active.endAt, record.startAt, record.endAt) <= 0
        }
        let result = CloudTripMerge.merge(local: trips, cloud: filtered, window: window)
        trips = result.trips
        TripLogStore.save(trips)
        if result.added > 0 || result.matched > 0 || result.dropped > 0 {
            BLEDiagnostics.record(
                "trip",
                "cloud合并 新增\(result.added) 对齐\(result.matched) 删补记\(result.dropped) 共\(trips.count)条"
            )
        }
        return result
    }

    func markSyncing() { cloudSync = .syncing }

    func markSynced(at date: Date = .now, count: Int) {
        cloudSync = .synced(date, count)
        failedAt = nil
        defaults.set(0, forKey: Self.failureCountKey)
        defaults.set(date, forKey: Self.lastSyncKey)
    }

    /// 失败次数多了就传空串：界面据此换成一句「暂不可用」，不再把服务端原话挂在页面上。
    func markSyncFailed(_ message: String) {
        failedAt = .now
        let count = consecutiveFailures + 1
        defaults.set(count, forKey: Self.failureCountKey)
        cloudSync = .failed(count >= Self.giveUpAfter ? "" : message)
    }

    /// 地名异步补齐之后回写。找不到就保持原样，不写「未知地点」这种占位。
    func applyPlaces(id: UUID, start: String?, end: String?) {
        guard let index = trips.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if let start, !start.isEmpty, trips[index].startPlace != start {
            trips[index].startPlace = start
            changed = true
        }
        if let end, !end.isEmpty, trips[index].endPlace != end {
            trips[index].endPlace = end
            changed = true
        }
        if changed { TripLogStore.save(trips) }
    }

    private func record(_ trip: TripRecord) {
        trips.insert(trip, at: 0)
        if trips.count > TripLogStore.limit {
            trips = Array(trips.prefix(TripLogStore.limit))
        }
        TripLogStore.save(trips)
        BLEDiagnostics.record(
            "trip",
            "\(trip.isReconstructed ? "补记" : "行程") "
                + "\(trip.distanceKm)km/\(Int(trip.duration / 60))min"
                + " \(trip.startSoc.map(String.init) ?? "-")→\(trip.endSoc.map(String.init) ?? "-")%"
        )
    }
}
