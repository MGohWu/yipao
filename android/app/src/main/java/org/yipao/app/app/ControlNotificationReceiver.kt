package org.yipao.app.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.yipao.app.core.WidgetAction
import org.yipao.app.widget.surfaceScope
import kotlinx.coroutines.launch

/// 常驻通知上那两个按钮按下之后的落点。
///
/// 走广播而不是 `startActivity`：按钮的全部意义就是**不用打开 App**。跳一次 App
/// 还得等冷启动、等生物识别，那还不如直接点通知本体。
class ControlNotificationReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_CONTROL = "org.yipao.app.action.NOTIFICATION_CONTROL"
        const val EXTRA_ACTION = "action"

        /// 明确的目标锁态，不是 toggle。
        ///
        /// 通知上是「解锁」和「闭锁」两个独立按钮，用户按下时表达的是「我要它变成开/关」。
        /// 按快照 toggle 的话，快照要是旧的（车休眠着不上报很常见），按「闭锁」反而会把车打开。
        const val EXTRA_DESIRED_LOCK = "desiredLock"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CONTROL) return
        val action = WidgetAction.of(intent.getStringExtra(EXTRA_ACTION)) ?: return
        val desiredLock = if (intent.hasExtra(EXTRA_DESIRED_LOCK)) {
            intent.getBooleanExtra(EXTRA_DESIRED_LOCK, true)
        } else {
            null
        }
        // 不能挂在 `onReceive` 里同步等：广播接收器超过十秒就是 ANR，而控车要等回读。
        // 失败原因由 `WidgetControlRunner` 记进共享偏好并刷新通知，用户抬眼就能看见。
        surfaceScope.launch {
            runCatching { WidgetControlRunner.run(action, desiredLock) }
        }
    }
}
