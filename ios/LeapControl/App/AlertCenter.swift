import Foundation
import UserNotifications

/// 通知的投递端：判定交给 `VehicleAlertEngine`，这里只管「要不要发、发什么、别重复发」。
///
/// **一个必须先说清的限制**：iOS 只有在 App 还在跑的时候才能发本地通知。
/// App 被系统挂起（或者用户划掉）之后，没有任何代码在运行，也就没有通知——
/// 这不是实现取舍，是系统约束。想覆盖锁屏后的场景，只有两条路：
/// 打开设置里的「后台记录」（用低精度定位把进程拖住，60 秒一帧），
/// 或者自己搭一台服务器接 APNs 发远程推送（那需要把车账号交给服务器，代价更大）。
@MainActor
final class AlertCenter: ObservableObject {
    static let shared = AlertCenter()

    private enum Key {
        static let unlocked = "alert.unlocked"
        static let chargeStarted = "alert.chargeStarted"
        static let chargeFinished = "alert.chargeFinished"
        static let graceMinutes = "alert.unlockedGraceMinutes"
        static let lastSentPrefix = "alert.lastSent."
    }

    /// 同一个提醒的最短间隔。状态在边界上抖两下不该弹两次。
    private static let cooldown: TimeInterval = 3 * 60

    @Published var unlockedEnabled: Bool {
        didSet {
            defaults.set(unlockedEnabled, forKey: Key.unlocked)
            if unlockedEnabled { Task { await requestAuthorizationIfNeeded() } }
        }
    }
    @Published var chargeStartedEnabled: Bool {
        didSet {
            defaults.set(chargeStartedEnabled, forKey: Key.chargeStarted)
            if chargeStartedEnabled { Task { await requestAuthorizationIfNeeded() } }
        }
    }
    @Published var chargeFinishedEnabled: Bool {
        didSet {
            defaults.set(chargeFinishedEnabled, forKey: Key.chargeFinished)
            if chargeFinishedEnabled { Task { await requestAuthorizationIfNeeded() } }
        }
    }
    /// 未锁车多久后提醒（分钟）。
    @Published var unlockedGraceMinutes: Int {
        didSet {
            defaults.set(unlockedGraceMinutes, forKey: Key.graceMinutes)
            engine.settings.unlockedGrace = TimeInterval(max(1, unlockedGraceMinutes) * 60)
        }
    }

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private let defaults = UserDefaults(suiteName: SnapshotStore.appGroup) ?? .standard
    private var engine = VehicleAlertEngine()

    private init() {
        unlockedEnabled = defaults.object(forKey: Key.unlocked) as? Bool ?? true
        chargeStartedEnabled = defaults.object(forKey: Key.chargeStarted) as? Bool ?? true
        chargeFinishedEnabled = defaults.object(forKey: Key.chargeFinished) as? Bool ?? true
        let stored = defaults.object(forKey: Key.graceMinutes) as? Int ?? 10
        unlockedGraceMinutes = stored
        engine.settings.unlockedGrace = TimeInterval(max(1, stored) * 60)
    }

    // MARK: - 权限

    /// 读一次当前权限。启动时调，界面据此显示「已关闭」。
    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 第一次打开开关时再问，不在启动时弹——那时候用户还不知道这个 App 要通知他什么。
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        authorization = status
        return status == .authorized || status == .provisional
    }

    var authorizationDenied: Bool {
        authorization == .denied
    }

    // MARK: - 判定入口

    /// 每轮车况刷新后调。`place` 只用于文案，拿不到就少一句。
    func observe(_ state: VehicleState, place: String?) {
        let sample = VehicleAlertSample(
            at: Date(),
            isLocked: state.isLocked,
            isDriving: state.isDriving,
            isCharging: state.isCharging,
            chargeState: state.chargeState,
            gunConnected: state.chargeGunConnected,
            powerKW: state.chargePowerKW,
            soc: state.soc
        )
        for event in engine.ingest(sample) {
            deliver(event, place: place)
        }
    }

    /// 退出登录 / 演示模式时清掉判定状态，免得换账号后带着上一台的计时。
    func reset() {
        engine = VehicleAlertEngine()
        engine.settings.unlockedGrace = TimeInterval(max(1, unlockedGraceMinutes) * 60)
    }

    // MARK: - 投递

    private func deliver(_ event: VehicleAlertEvent, place: String?) {
        guard isEnabled(event.kind) else { return }
        guard !isCoolingDown(event.kind, at: event.at) else { return }

        let content = UNMutableNotificationContent()
        content.title = title(for: event)
        content.body = body(for: event, place: place)
        content.sound = .default
        content.threadIdentifier = "leap.vehicle"
        // 点通知回到 App 的首页。`categoryIdentifier` 先留空：
        // 通知上直接挂控车按钮要过 Face ID，那个流程以后再说，别先给一个点不动的按钮。
        content.userInfo = ["alert": event.kind.rawValue]

        let request = UNNotificationRequest(
            identifier: "leap.\(event.kind.rawValue).\(Int(event.at.timeIntervalSince1970))",
            content: content,
            trigger: nil   // 立即送达
        )
        // `add` 在这个 SDK 上只有 async 版本，扔进 Task 里发；投递本身不需要等结果。
        Task { try? await UNUserNotificationCenter.current().add(request) }
        markSent(event.kind, at: event.at)
        BLEDiagnostics.record("alert", "\(event.kind.rawValue) 已投递")
    }

    private func isEnabled(_ kind: VehicleAlert) -> Bool {
        switch kind {
        case .unlocked: return unlockedEnabled
        case .chargeStarted: return chargeStartedEnabled
        case .chargeFinished: return chargeFinishedEnabled
        }
    }

    private func isCoolingDown(_ kind: VehicleAlert, at date: Date) -> Bool {
        let key = Key.lastSentPrefix + kind.rawValue
        guard let last = defaults.object(forKey: key) as? Date else { return false }
        return date.timeIntervalSince(last) < Self.cooldown
    }

    private func markSent(_ kind: VehicleAlert, at date: Date) {
        defaults.set(date, forKey: Key.lastSentPrefix + kind.rawValue)
    }

    private func title(for event: VehicleAlertEvent) -> String {
        switch event.kind {
        case .unlocked: return "车还没锁"
        case .chargeStarted: return "开始充电"
        case .chargeFinished: return "充电完成"
        }
    }

    private func body(for event: VehicleAlertEvent, place: String?) -> String {
        switch event.kind {
        case .unlocked:
            var text = "已经 \(event.minutes ?? 0) 分钟没锁车了"
            if let soc = event.soc { text += "，电量 \(soc)%" }
            if let place, !place.isEmpty { text += " · \(place)" }
            return text
        case .chargeStarted:
            var parts: [String] = []
            if let soc = event.soc { parts.append("当前 \(soc)%") }
            if let power = event.powerKW, power > 0 { parts.append(String(format: "%.1f kW", power)) }
            return parts.isEmpty ? "已经开始充电" : parts.joined(separator: " · ")
        case .chargeFinished:
            var text = event.soc.map { "已充到 \($0)%" } ?? "充电已结束"
            if let gain = event.socGain, gain > 0 { text += "，本次 +\(gain)%" }
            return text
        }
    }
}

/// 前台也要弹横幅。
///
/// 默认行为是「App 在前台时不显示通知」——那正好把最该看见的一刻吞掉：
/// 用户盯着 App 看充电，充完了却什么都没发生。所以显式要求横幅 + 声音。
final class AlertPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = AlertPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
