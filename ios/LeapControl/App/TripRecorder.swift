import Combine
import Foundation

/// 行程记录器。挂在 10 秒一次的车况轮询上，把「车动了 / 车停了」串成一趟趟行程。
///
/// 落盘的只有**已经结束**的行程。进行中的那一趟留在内存里（`active`），App 被杀掉就没了——
/// 这是故意的：进程被系统清掉的那一刻，最后一段路到底开没开、开了多远，我们无从知道，
/// 与其存一个半截的、每次启动都接着往上加时间的怪东西，不如让下次启动时的「断档补记」
/// 用里程表差给它一个诚实的、带标注的交代。
///
/// 什么情况下会记不到：App 完全没运行（被划掉、系统回收、连续几天不开）。iOS 不会让第三方
/// App 在后台长期跑，`UIBackgroundModes` 里只有 `bluetooth-central`，靠蓝牙唤醒的那几秒
/// 也不够跑一轮轮询。所以界面上必须写清楚这一点，别让车主以为漏记是 bug。
@MainActor
final class TripRecorder: ObservableObject {
    static let shared = TripRecorder()

    /// 已结束的行程，最新的在前。
    @Published private(set) var trips: [TripRecord]
    /// 正在跑的这一趟。没有就是 nil。
    @Published private(set) var active: TripRecord?

    private var tracker = TripTracker()

    private init() {
        trips = TripLogStore.load()
    }

    /// 每轮车况刷新后调一次。
    func observe(_ state: VehicleState, vin: String?, at date: Date = .now) {
        let sample = TripTracker.Sample(
            at: date,
            odometerKm: state.totalMileage,
            soc: state.soc,
            coordinate: state.shareableCoordinate,
            gearDriving: state.isDriving
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
    /// 一条 0 公里的脏数据。真要结束，让轮询自己判「连续三帧停着」就行。
    func forgetActiveTrip() {
        tracker = TripTracker()
        active = nil
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
