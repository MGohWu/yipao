package org.yipao.app.widget

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import org.yipao.app.MainActivity
import org.yipao.app.R
import org.yipao.app.app.WidgetControlRunner
import org.yipao.app.core.LeapDeepLink
import org.yipao.app.core.SnapshotStore
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetControlFeedback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/// 磁贴和通知按钮下发指令时用的进程级作用域。
///
/// **不能挂在 Service 上**：磁贴一按下，系统很快就把 `TileService` 解绑，挂在它身上的
/// 协程会跟着被取消——一条发到一半的控车请求，用户看到的是「按了没反应」。
internal val surfaceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

/// 快捷设置磁贴的共同部分。对齐 iOS 的 ControlWidget：**只读快照，从不自己上网**。
///
/// 下拉一次通知栏就要联网拉车况的话，用户每天会为此付出几十次后台请求，
/// 而他多半只是想看眼时间。车况由 App 刷新时推过来。
abstract class LeapTileService : TileService() {

    protected abstract val action: WidgetAction

    /// 磁贴长什么样。
    protected abstract fun render(tile: Tile, snapshot: VehicleSnapshot?)

    /// 按下去会不会把车**打开**（解锁、开尾门）。
    ///
    /// 关系到要不要先让用户解锁手机：快捷设置面板在锁屏上就能拉下来，
    /// 一个锁屏可达的「解锁车门」按钮等于车门没锁。反过来，闭锁和鸣笛
    /// 落在陌生人手上也做不成什么坏事，不该为它们再拦一道。
    protected open fun opensVehicle(snapshot: VehicleSnapshot?): Boolean = false

    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    protected fun refresh() {
        val tile = qsTile ?: return
        render(tile, SnapshotStore.read())
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        val snapshot = SnapshotStore.read()
        // 没有车况就没有可切换的状态，直接把 App 打开，让人先同步一次。
        if (snapshot == null || !WidgetControlRunner.canDispatchDirectly) {
            openApp()
            return
        }
        if (isSecure && isLocked && opensVehicle(snapshot)) {
            // 系统会弹解锁界面，解开之后才跑我们这段。用户拒绝解锁就什么都不发生。
            unlockAndRun { dispatch() }
            return
        }
        dispatch()
    }

    private fun dispatch() {
        surfaceScope.launch {
            // 失败原因由 `WidgetControlRunner` 记进共享偏好，`refresh` 会把它显示成副标题。
            runCatching { WidgetControlRunner.run(action) }
        }
        // 乐观更新已经写进快照了，先重画一次，别等三秒后的回读。
        refresh()
    }

    /// 打开 App 接着办。带上动作，验证通过后 App 会把它执行掉。
    private fun openApp() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(LeapDeepLink.action(action)))
            .setClass(this, MainActivity::class.java)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        // 安卓 14 起只收 PendingIntent，传 Intent 的那版会直接抛异常。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    /// 副标题：刚失败过就说失败，否则说状态。空间只有一行，失败优先。
    protected fun subtitleOf(fallback: String): String =
        WidgetControlFeedback.recentFailure ?: fallback
}

/// 车锁磁贴。对齐 iOS `VehicleLockControl`。
class LockTileService : LeapTileService() {

    override val action = WidgetAction.ToggleLock

    /// 当前锁着（或状态未知）时按下去就是解锁。未知也算——`WidgetControlRunner`
    /// 在读不到锁状态时默认执行解锁，这里的判断必须和它一致，否则会漏掉那道解锁手机的拦。
    override fun opensVehicle(snapshot: VehicleSnapshot?): Boolean = snapshot?.isLocked != false

    override fun render(tile: Tile, snapshot: VehicleSnapshot?) {
        val locked = snapshot?.isLocked
        tile.label = "壹跑车锁"
        tile.icon = Icon.createWithResource(
            this,
            if (locked == false) R.drawable.ic_widget_lock_open else R.drawable.ic_widget_lock,
        )
        // 状态未知时给 INACTIVE 而不是 ACTIVE：ACTIVE 在面板上是高亮的「已开启」，
        // 那等于替车说了句「锁好了」。没有车况才是真的不可用。
        tile.state = when {
            snapshot == null -> Tile.STATE_UNAVAILABLE
            locked == true -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.subtitle = subtitleOf(snapshot?.lockText ?: "未同步")
    }
}

/// 鸣笛寻车磁贴。对齐 iOS `VehicleHornControl`。
class HornTileService : LeapTileService() {

    override val action = WidgetAction.Horn

    override fun render(tile: Tile, snapshot: VehicleSnapshot?) {
        tile.label = "壹跑鸣笛"
        tile.icon = Icon.createWithResource(this, R.drawable.ic_widget_horn)
        // 鸣笛是个瞬时动作，没有「开着」这种状态，永远画成未激活。
        tile.state = if (snapshot == null) Tile.STATE_UNAVAILABLE else Tile.STATE_INACTIVE
        tile.subtitle = subtitleOf(snapshot?.vehicleName ?: "未同步")
    }
}
