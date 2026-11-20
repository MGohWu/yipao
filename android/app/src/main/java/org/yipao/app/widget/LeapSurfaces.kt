package org.yipao.app.widget

import android.content.ComponentName
import android.service.quicksettings.TileService
import androidx.compose.runtime.Composable
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.glance.currentState
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.updateAppWidgetState
import org.yipao.app.app.BLEKeyForegroundService
import org.yipao.app.core.WidgetTrace
import org.yipao.app.core.AppEnv
import org.yipao.app.core.SnapshotStore
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetButtonLayout
import org.yipao.app.core.WidgetSettings
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

private val VehicleSnapshotKey = stringPreferencesKey("vehicle.snapshot")
private val WidgetRevisionKey = longPreferencesKey("vehicle.revision")
private val WidgetButtonsKey = stringPreferencesKey("widgetButtons")
private val SmallWidgetButtonsKey = stringPreferencesKey("smallWidgetButtons")

@Composable
internal fun currentWidgetButtons(small: Boolean): List<WidgetAction> {
    val raw = currentState<Preferences>()[if (small) SmallWidgetButtonsKey else WidgetButtonsKey]
        ?: return WidgetSettings.buttons(small)
    return WidgetButtonLayout.normalize(raw.split(','), small)
}

/// 卡片组合只从 Glance 自己的可观察状态取车况。第一次升级、Glance 状态尚未迁入时，
/// 才退回原来的共享快照顶住首帧；下一次 [LeapSurfaces.reloadAll] 会把它正式写进来。
@Composable
internal fun currentVehicleSnapshot(): VehicleSnapshot? {
    val state = currentState<Preferences>()
    // 修订号专门覆盖“车图文件变了、车况 JSON 没变”。读一下让这个依赖明确可见。
    state[WidgetRevisionKey]
    return state[VehicleSnapshotKey]
        ?.let(VehicleSnapshot::fromJson)
        ?: SnapshotStore.read()
}

/// App 界面之外那几处「表面」的统一刷新口。
///
/// 桌面小组件、快捷设置磁贴、常驻通知这三处各有各的刷新方式，谁也不会自动跟着
/// `VehicleStore` 变。散着写的话，每加一处表面就得回去把所有写快照的地方补一遍——
/// 漏掉哪处，那处就永远停在上一份车况上。写快照的地方只调这一个函数。
object LeapSurfaces {

    /// Glance 的四个 provider 更新是挂起操作。车况轮询、车图落盘和手动刷新可能同时进来；
    /// 串行后每一轮都在锁内读取磁盘上的最新快照，旧任务无法在新任务之后落回桌面。
    private val reloadMutex = Mutex()

    /// 全部重画。任何一处失败都不许影响其余几处：小组件宿主可能不存在、
    /// 磁贴可能没被添加、通知权限可能没给，这些都是常态而不是异常。
    suspend fun reloadAll() = reloadAll(null)

    internal suspend fun reloadAll(trace: WidgetTrace?) {
        trace?.note("surfaces.lock.wait")
        reloadMutex.withLock {
            trace?.note("surfaces.lock.acquired")
            if (!AppEnv.isInstalled) return
            val context = AppEnv.context
            NativeWidgets.updateAll(context, trace)
            requestTileUpdate(LockTileService::class.java)
            requestTileUpdate(HornTileService::class.java)
            BLEKeyForegroundService.refreshNotification()
            trace?.note("surfaces.complete")
        }
    }

    /// `updateAll()` 只会要求现有 Glance 会话再出一帧；普通 SharedPreferences 不是
    /// Compose 状态，会话仍会把首次读到的锁态原样发给桌面。先写 provider 自己的
    /// PreferencesGlanceStateDefinition，再按实例 update，组合才会真正收到新状态。
    private suspend fun <T : GlanceAppWidget> syncWidget(
        context: android.content.Context,
        manager: GlanceAppWidgetManager,
        widget: T,
        widgetClass: Class<T>,
        snapshotJson: String?,
        trace: WidgetTrace?,
    ) {
        trace?.note("provider.${widgetClass.simpleName}.begin")
        runCatching { manager.getGlanceIds(widgetClass) }
            .onFailure { trace?.note("provider.${widgetClass.simpleName}.ids.error ${it.javaClass.simpleName}") }
            .getOrDefault(emptyList())
            .forEach { id ->
                runCatching {
                    updateAppWidgetState(context, id) { state ->
                        state[WidgetButtonsKey] = WidgetSettings.buttons(false).joinToString(",") { it.rawValue }
                        state[SmallWidgetButtonsKey] = WidgetSettings.buttons(true).joinToString(",") { it.rawValue }
                        if (snapshotJson == null) {
                            state.remove(VehicleSnapshotKey)
                        } else {
                            state[VehicleSnapshotKey] = snapshotJson
                        }
                        state[WidgetRevisionKey] = (state[WidgetRevisionKey] ?: 0L) + 1L
                    }
                    trace?.note("widget.$id.update.begin")
                    widget.update(context, id)
                    trace?.note("widget.$id.update.ok")
                }.onFailure { trace?.note("widget.$id.error ${it.javaClass.simpleName}") }
            }
        trace?.note("provider.${widgetClass.simpleName}.end")
    }

    /// 让磁贴重走一次 `onStartListening`。
    ///
    /// 系统只对「已经被用户添加到快捷设置面板里」的磁贴响应，没添加的直接忽略——
    /// 这正是我们要的：不需要在这里判断用户加没加。
    private fun requestTileUpdate(service: Class<out TileService>) {
        val context = AppEnv.context
        runCatching {
            TileService.requestListeningState(context, ComponentName(context, service))
        }
    }
}
