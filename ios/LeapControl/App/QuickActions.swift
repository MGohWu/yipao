import SwiftUI
import UIKit

/// 长按桌面图标弹出来的那几个快捷操作。
///
/// 条目本身是**静态**的，写在 `Info.plist` 的 `UIApplicationShortcutItems` 里——
/// 系统在 App 没运行时也要能画出这个菜单，所以它只能来自 plist，代码没有插手的机会。
/// 也因此菜单上看不到车况：三条都是固定文字，车锁那条写的是「开关车锁」而不是
/// 「解锁」或「上锁」，方向要等 App 起来、拉到实时车况之后才定得下来。
///
/// **快捷方式发不出后台指令。** 点一下必然把 App 拉到前台，和鸿蒙那边的限制一样。
/// 所以这里不碰控车，只做一件事：把动作寄存进 `SharedSettings.pendingWidgetAction`，
/// 剩下的交给 App 里那条既有链路（`refreshThenConsumePendingAction` → Face ID +
/// 操作密码），和卡片按钮回 App 验证走的是同一条路。
enum QuickAction {
    /// `UIApplicationShortcutItemType` 的前缀。后面接 `WidgetAction` 的 rawValue，
    /// plist 里那三条和这里必须对得上，改一处就要改两处。
    static let typePrefix = "org.yipao.app.action."

    static func action(for item: UIApplicationShortcutItem) -> WidgetAction? {
        guard item.type.hasPrefix(typePrefix) else { return nil }
        return WidgetAction(rawValue: String(item.type.dropFirst(typePrefix.count)))
    }

    /// 寄存这条动作。认不出来就返回 false——系统会据此把菜单项标成没执行成功。
    ///
    /// 寄存而不是当场执行：这会儿会话可能还没恢复（冷启动），控车会因为没登录直接失败。
    /// 寄存的值有一分钟时效（`SharedSettings.pendingWidgetActionWindow`），
    /// 按完就锁屏、几小时后才打开 App 的话，这条动作已经作废了。
    @discardableResult
    static func stash(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = action(for: item) else { return false }
        SharedSettings.pendingWidgetAction = action.rawValue
        return true
    }
}

extension Notification.Name {
    /// 快捷方式刚被按下。App 已经在跑的时候，`scenePhase` 未必会变
    /// （从后台回来那一下顺序也不保证在前），所以要有一条自己的信号。
    static let leapQuickAction = Notification.Name("LeapQuickAction")
}

/// 只为一件事存在：把窗口场景的代理换成我们自己的。
///
/// SwiftUI 的 `App` 生命周期底下仍然是 UIScene，而快捷方式的回调
/// （`windowScene(_:performActionFor:)`）只发给**场景**代理——
/// `UIApplicationDelegate` 上那个同名方法在用了场景的 App 里根本不会被调用。
@MainActor
final class LeapAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = LeapSceneDelegate.self
        return configuration
    }
}

/// 快捷方式的两个入口：冷启动从 `connectionOptions` 带进来，热启动走 `performActionFor`。
@MainActor
final class LeapSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // App 没在跑时按的那一下。寄存下来，`bootstrap()` 拉完车况后会接手；
        // 这条通知多半没人听得见（视图还没挂上），所以不能只靠它。
        guard let item = connectionOptions.shortcutItem else { return }
        QuickAction.stash(item)
        NotificationCenter.default.post(name: .leapQuickAction, object: nil)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let accepted = QuickAction.stash(shortcutItem)
        if accepted {
            NotificationCenter.default.post(name: .leapQuickAction, object: nil)
        }
        completionHandler(accepted)
    }
}
