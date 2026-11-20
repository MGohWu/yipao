package org.yipao.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.Crossfade
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.key
import androidx.lifecycle.lifecycleScope
import org.yipao.app.app.VehicleStore
import org.yipao.app.core.LeapDeepLink
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetSettings
import org.yipao.app.ui.AppNav
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.LeapBackground
import org.yipao.app.ui.screens.LoginScreen
import org.yipao.app.ui.theme.LeapTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private val store get() = VehicleStore.shared

    /// 由卡片 / 磁贴 / 通知带进来、要在 App 内走完整验证后才执行的动作，和它到手的时刻。
    private var queuedAction: WidgetAction? = null
    private var queuedAt = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        queue(LeapDeepLink.actionOf(intent?.data))
        setContent { LeapApp(store) }
        // 冷启动只跑一次：恢复会话 → 探活 → 首刷 → 起轮询。
        // 转屏重建 Activity 时 `savedInstanceState` 非空，那时会话早就在了，
        // 再跑一遍等于每转一次屏就打一次老链路探活。
        if (savedInstanceState == null) {
            lifecycleScope.launch {
                store.bootstrap()
            }
        }
    }

    /// App 已经开着的时候又被卡片拉起来。singleTop 保证走的是这里而不是新建一个实例。
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        queue(LeapDeepLink.actionOf(intent.data))
    }

    private fun queue(action: WidgetAction?) {
        if (action == null) return
        queuedAction = action
        queuedAt = System.currentTimeMillis()
    }

    /// 把排着的那个动作执行掉。
    ///
    /// 和共享偏好里那条待办用同一个时限：动作是用户按下那一刻的意图，
    /// 隔了半天再执行，车门会在他毫无预期的时候自己开。停在登录页迟迟不登录，
    /// 或者拉起 App 之后又去干别的，都会走到这条超时上。
    private fun runQueuedAction() {
        val fresh = queuedAction?.takeIf {
            System.currentTimeMillis() - queuedAt <= WidgetSettings.PENDING_ACTION_WINDOW_MS
        }
        queuedAction = null
        // 深链没带动作时再看共享偏好——那是「按了卡片按钮但本机没存操作密码」留下的。
        val action = fresh ?: WidgetSettings.consumePendingAction() ?: return
        when (action) {
            WidgetAction.Lock -> store.setLocked(true)
            WidgetAction.Unlock -> store.setLocked(false)
            WidgetAction.ToggleLock -> store.toggleLock()
            WidgetAction.ToggleClimate -> store.applyClimate(!store.climateOn)
            WidgetAction.Trunk -> store.toggleTrunk()
            WidgetAction.Horn -> store.honk()
        }
    }

    /// 回到前台先探一次登录态——被挤下线只有主动探控车 token 才发现（见 `validateSession`），
    /// 有效再静默刷新并起轮询；失效的话 `validateSession` 已经把人送回登录页了。
    override fun onResume() {
        super.onResume()
        store.ble.setApplicationActive(true)
        lifecycleScope.launch {
            if (!store.isLoggedIn) {
                // 停在登录页也可能是启动那帧 Keystore 没读出来（直接启动加密阶段被拉起），
                // 这会儿设备已解锁，给一次重读自愈的机会。
                store.restoreSessionIfNeeded()
                return@launch
            }
            if (!store.validateSession()) return@launch
            store.refresh()
            store.startPolling()
            // 放在刷新之后：控车要按最新车况判断（比如尾门在行驶中不能开），
            // 拿一份进门那刻的旧车况去发指令，判断依据就是错的。
            runQueuedAction()
        }
    }

    /// 退到后台停轮询——刷新不了界面，只是白白耗电和打服务端。
    override fun onPause() {
        super.onPause()
        store.stopPolling()
    }

    /// 这次前台的身份验证到此作废，下次控车重新过指纹或密码。
    ///
    /// 挂在 `onStop` 而不是 `onPause`：指纹弹窗、下拉通知栏都会走 `onPause`，
    /// 在那儿清掉就成了「刚验完又要验」。
    override fun onStop() {
        super.onStop()
        store.endForegroundVerification()
        // 直进直出到此为止。无感钥匙由前台服务继续守着，但「按住才动」这种
        // 需要人盯着车的操作，界面看不见了就必须停。
        store.ble.setApplicationActive(false)
    }
}

/// 应用根：登录墙 → 三 Tab 主界面。外观与动态取色存在 store 里，设置页改完立即生效，
/// 且重启后还在（iOS 那边同样是 UserDefaults 持久化的）。
@Composable
fun LeapApp(store: VehicleStore) {
    CompositionLocalProvider(LocalStore provides store) {
        LeapTheme(appearance = store.appearance) {
            // 背景主色由各个页面自己声明（`PageTint`），这里只提供那一层背景本身。
            LeapBackground {
                Crossfade(targetState = store.isLoggedIn, label = "root") { isIn ->
                    if (isIn) {
                        // loginEpoch 当 key：退登再登录时强制重建整棵视图树，
                        // 不会把上一段会话推着的页面带回来。
                        key(store.loginEpoch) { AppNav() }
                    } else {
                        LoginScreen()
                    }
                }
            }
        }
    }
}
