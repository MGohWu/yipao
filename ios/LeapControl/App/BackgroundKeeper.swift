import CoreLocation
import Observation
import UIKit

/// 后台记录用的「保活」定位。
///
/// iOS 不会让一个普通 App 在后台一直跑：退到后台几秒后进程被挂起，`Task.sleep`
/// 停住，10 秒一次的轮询随之断掉，行程和充电只能等下次唤醒时补一条粗记录
/// （见 `TripTracker.shouldReconstruct`）。唯一正当的常驻理由是**持续定位**——
/// `UIBackgroundModes` 里的 `location`（见 Info.plist）。
///
/// 所以这里开一个精度极低的定位更新。目的**不是画轨迹**（轨迹来自车机 GPS，
/// 比手机准得多），只是让进程活着，好让轮询继续跑。
///
/// 三件事必须同时成立，缺一样都会在后台被停掉：
///
/// 1. Info.plist 里 `UIBackgroundModes` 含 `location`；
/// 2. `allowsBackgroundLocationUpdates = true`——**只能在 App 处于前台时设置**，
///    在后台设会直接抛异常；
/// 3. 定位权限是「始终允许」。只有「使用期间」时，退到后台立刻失效，
///    表现是「开关开着但什么都没记」。
///
/// 第 3 条是最容易踩的，所以 `Status` 把「只有使用期间」单独分了一档，
/// 设置页据此给出**能照做**的提示，而不是笼统说一句「权限不足」。
///
/// 代价写在明处：状态栏会出现定位图标，耗电比不记录时高。因此做成设置里的开关、
/// 默认关闭——不记录行程的人不该被迫付这份电。
@MainActor
@Observable
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {

    static let shared = BackgroundKeeper()

    enum Status: Equatable {
        /// 用户关掉了。这是默认状态。
        case off
        /// 开了，但权限只有「使用期间」，或者还没问过。
        case needsAlways
        /// 权限被拒。
        case denied
        /// 系统层面不允许（家长控制、MDM 之类）。
        case unavailable
        /// 正在跑。
        case running
    }

    private(set) var status: Status = .off

    /// 最近一次收到定位更新的时刻。
    ///
    /// 判断保活到底有没有在转，看它比看开关可靠：开关只代表用户意愿，
    /// 这个代表系统真的在给位置。设置页把它显示出来，
    /// 「开了但一晚上没动」和「开着且还在更新」就能一眼分开。
    private(set) var lastFixAt: Date?

    private let manager = CLLocationManager()
    /// 用户的开关值。在声明处就从 `SharedSettings` 取：`super.init()` 之前不能碰
    /// `self` 的属性（`@Observable` 的 setter 会访问观察注册器），写在 `init` 里赋值
    /// 反而要额外绕一圈。
    private var enabled = SharedSettings.backgroundRecordingEnabled

    override init() {
        super.init()
        manager.delegate = self
        // 3 公里精度走基站和 Wi-Fi，基本不点亮 GPS 芯片。我们要的只是「进程别睡」。
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        // 500 米才报一次。停在家里一整天可以一次都不报，系统照样让我们活着。
        manager.distanceFilter = 500
        // 默认行为是「用户不再移动就自动停掉定位更新」，那等于把保活自己关掉。
        manager.pausesLocationUpdatesAutomatically = false
        // `allowsBackgroundLocationUpdates` 只能在 App 处于前台时写。init 基本都发生在
        // 前台（启动、或用户打开设置页），先在这儿设一次；`start()` 里再按状态补。
        // 属性一旦是 false，后台定位会**静默**失效——不报错，只是进后台就断，最难查。
        if UIApplication.shared.applicationState == .active {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
    }

    /// 用户的开关。存在 `SharedSettings` 里，与 App Group 一致，将来卡片要读也读得到。
    ///
    /// 写成可读可写是为了能直接 `$keeper.isEnabled` 绑到 `Toggle` 上：
    /// setter 转手交给 `setEnabled`，不绕开那套权限重算。
    var isEnabled: Bool {
        get { enabled }
        set { setEnabled(newValue) }
    }

    /// 保活有没有真的在跑。`VehicleStore` 靠它决定进后台后要不要继续轮询。
    var isRunning: Bool { status == .running }

    /// 给设置页的一行解释。`nil` 表示没有要提醒的。
    var statusHint: String? {
        switch status {
        case .running, .off:
            return nil
        case .needsAlways:
            return "定位权限要选「始终允许」。只有「使用期间」时，锁屏后系统会立刻停掉记录。"
        case .denied:
            return "定位权限被拒绝。去「设置 → 壹跑 → 位置」改成「始终允许」再回来。"
        case .unavailable:
            return "系统不允许这台设备做后台定位。"
        }
    }

    /// 用户在设置里拨开关。
    func setEnabled(_ on: Bool) {
        enabled = on
        SharedSettings.backgroundRecordingEnabled = on
        BLEDiagnostics.record("bg", "switch=\(on)")
        if on {
            reconcile(requestAuthorization: true)
        } else {
            stop()
            status = .off
        }
    }

    /// 按当前权限重算一次。
    ///
    /// 启动时、回到前台时都要调：用户可能刚在系统设置里把权限从「使用期间」
    /// 改成「始终」，也可能反过来改掉了。不在每次回前台重算的话，
    /// 状态会一直停在进程启动那一刻的判断上。
    func refresh() {
        guard enabled else {
            status = .off
            return
        }
        reconcile(requestAuthorization: false)
    }

    private func reconcile(requestAuthorization: Bool) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            start()
        case .notDetermined, .authorizedWhenInUse:
            // 只有 whenInUse 时**不能**假装在跑：进后台就是死的，UI 必须说出来。
            stop()
            status = .needsAlways
            if requestAuthorization, UIApplication.shared.applicationState == .active {
                // 已有 whenInUse 时系统会直接弹「是否允许后台使用位置」；
                // 从没问过时给的是含「始终」那一档的完整选项。
                manager.requestAlwaysAuthorization()
                BLEDiagnostics.record("bg", "auth.request")
            }
        case .denied, .restricted:
            stop()
            status = .denied
        @unknown default:
            stop()
            status = .unavailable
        }
    }

    private func start() {
        // `allowsBackgroundLocationUpdates` **只能在 App 处于前台时改**，在后台赋值
        // 会直接抛 `NSInternalInconsistencyException`。而 `refresh()` 在退后台那一刻
        // 也会被调到（`VehicleStore.enterBackground`），所以这里必须守住状态，
        // 不能无条件写。真正设置它的是「用户在前台拨开关」和「冷启动时在前台重算」两条路，
        // 到进后台时它已经是 true 了。
        if UIApplication.shared.applicationState == .active {
            manager.allowsBackgroundLocationUpdates = true
            // 后台定位要让用户看得见，这是硬要求，也是诚实的做法。
            manager.showsBackgroundLocationIndicator = true
        }
        status = .running
        manager.startUpdatingLocation()
        BLEDiagnostics.record("bg", "start state=\(UIApplication.shared.applicationState.rawValue)")
    }

    private func stop() {
        manager.stopUpdatingLocation()
        lastFixAt = nil
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        BLEDiagnostics.record("bg", "auth=\(manager.authorizationStatus.rawValue)")
        guard enabled else { return }
        reconcile(requestAuthorization: false)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 这些坐标一概不用：手机位置有 `UserLocationProvider` 专门管，而且那边要转 GCJ-02。
        // 这里只留时间戳，给设置页显示「刚才还在更新」。
        lastFixAt = locations.last?.timestamp
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 室内收不到定位很常见。失败**不代表**保活失效，不要因为一条 error 就停掉整个记录。
        BLEDiagnostics.record("bg", "error=\(BLEDiagnostics.error(error))")
    }
}
