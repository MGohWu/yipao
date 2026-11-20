import Foundation

/// 卡片刷新时自己去拉一次车况。
///
/// 之所以能在扩展里做：登录态存在共享的 Keychain 组里，`LeapClient` 在这个进程里
/// 一样能重放两条链路的签名，token 续期结果也会写回同一份会话，主 App 下次读得到。
///
/// 拉不到就沿用主 App 留下的那份快照——卡片上宁可显示一份标着"多久前"的旧数据，
/// 也不要突然变成占位值。
enum WidgetVehicleFetcher {
    /// 共享快照新到这个程度，就不再自己拉了，直接用。
    ///
    /// 现在有两条独立的时间线（车辆状态卡、锁车卡），每个 kind 一条，
    /// 系统会分别派发。不加这道复用的话它们各拉一遍「续期 token → 取路由 → 查车况」：
    /// 请求翻倍不说，两条拉取之间车况变了，**同一时刻两个组件显示的锁车状态就不一样**——
    /// 这个真出过，桌面上锁车卡和状态卡对同一台车说了两句话。
    ///
    /// 先跑的那条拉网络并写回共享快照，后跑的几条看到快照够新就直接复用，
    /// 于是它们渲染的是同一个瞬间。刷新间隔是 10 分钟，窗口取 5 分钟：同一轮派发里
    /// 的几条必然复用，下一轮又必然重新拉。
    ///
    /// 用 `updatedAt` 判断是安全的：控车后的乐观更新只改锁/空调那两个字段，
    /// **不动 `updatedAt`**（见 `WidgetControlRunner.applyOptimistically`），
    /// 所以乐观值不会把自己伪装成一份新拉的数据。
    static let reuseWindow: TimeInterval = 300

    /// 时间线用：一定给得出一份能渲染的快照，拉不到就沿用旧的、再不济是占位值。
    static func latest(fallback: VehicleSnapshot?) async -> VehicleSnapshot {
        if let fallback, Date.now.timeIntervalSince(fallback.updatedAt) < reuseWindow {
            return fallback
        }
        return await fetch(reusing: fallback) ?? fallback ?? .placeholder
    }

    /// **真的从车端拉到了**才返回快照；没登录、没选车、请求失败一律是 nil。
    ///
    /// 和 `latest` 分开是有必要的：`latest` 拿不到时会退回 `.placeholder`，
    /// 而占位值里的 `isLocked` 是 `true`——时间线上无所谓（卡片总得画点什么），
    /// 但锁屏控件照着它渲染就是**替一台没读到状态的车说了句「锁好了」**，
    /// 而按下去的方向正是照着这个显示算的。控件那边要能分清"拉到了"和"没拉到"。
    static func fetch(reusing fallback: VehicleSnapshot?) async -> VehicleSnapshot? {
        let client = LeapClient()
        let session = await client.currentSession()
        guard session.isLoggedIn, !session.selectedVin.isEmpty else { return nil }

        guard let state = try? await client.fetchVehicleState() else { return nil }

        var locationName: String?
        if let coordinate = state.shareableCoordinate {
            locationName = await LocationNaming.name(for: coordinate, reusing: fallback)
        }

        let snapshot = VehicleSnapshot.make(
            state: state,
            vehicleName: (await client.currentSession()).displayVehicleName,
            locationName: locationName
        )
        // 写回共享文件：主 App 下次启动前，桌面上这份就是最新的。
        SnapshotStore().write(snapshot)
        return snapshot
    }
}
