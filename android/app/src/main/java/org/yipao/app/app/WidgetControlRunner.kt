package org.yipao.app.app

import org.yipao.app.core.WidgetTrace
import org.yipao.app.core.ClimateMode
import org.yipao.app.core.LeapClient
import org.yipao.app.core.LeapCommand
import org.yipao.app.core.LeapError
import org.yipao.app.core.OperationPasswordStore
import org.yipao.app.core.SnapshotStore
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.VehicleState
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetSettings
import org.yipao.app.widget.LeapSurfaces
import kotlinx.coroutines.delay

/// 桌面小组件、快捷磁贴和常驻通知按钮共用的那条「不开界面直接下发」实现。
///
/// 对齐 iOS `WidgetControlRunner`。抽出来只为一件事：这段逻辑有三个调用方，
/// 复制三份的话乐观更新、回读车况、刷新哪几个表面这些细节会各自跑偏。
///
/// **和 iOS 的一处实质差异**：iOS 不敢在这里读钥匙串，因为操作密码那条是
/// `WhenUnlockedThisDeviceOnly`，锁屏时读不到，于是它只能靠 UserDefaults 里一个
/// 「存过密码」的布尔标记来决定按钮长什么样。安卓的 `SecureVault` 密钥明确声明了
/// `setUserAuthenticationRequired(false)`，锁屏下照样解得开，所以这里直接读真值，
/// 不需要那个影子标记，也就没有「标记和钥匙串对不上」这种分叉。
object WidgetControlRunner {

    /// 这一侧能不能自己把指令发出去。
    ///
    /// 两个条件缺一不可：用户开了「直接控车」，且本机确实存过操作密码。
    /// 开着开关却没存密码是能出现的（换了手机、或点过「忘记已保存的操作密码」），
    /// 这时按钮必须退回「打开 App」那条路，而不是发一条注定被拒的请求。
    val canDispatchDirectly: Boolean
        get() = WidgetSettings.directControlEnabled && OperationPasswordStore().hasPassword

    /// 跑一个动作：能直接下发就下发，不能就把它留给 App 并把原因写到卡片上。
    ///
    /// `desiredLock` 只有磁贴那个开关会传——用户在开关上表达的是「我要它变成锁着/开着」，
    /// 比照着可能已经过期的快照去 toggle 准确。卡片和通知上的按钮没有这个信息，传 null。
    ///
    /// 失败一律记进 [WidgetSettings.recordControlError] 再抛出去。这三处表面没有别的出口
    /// 能告诉用户「刚才那下没成」，记完立刻刷新，用户抬眼就能看见，
    /// 而不是对着一张没有任何变化的卡片发呆。
    suspend fun run(action: WidgetAction, desiredLock: Boolean? = null) {
        val trace = WidgetTrace("control.run action=${action.rawValue}")
        try {
            trace.step("dispatch") { dispatch(action, desiredLock, trace) }
            WidgetSettings.recordControlError(null)
        } catch (e: Exception) {
            WidgetSettings.recordControlError(LeapError.messageOf(e))
            trace.step("error.refresh-surfaces") { LeapSurfaces.reloadAll(trace) }
            throw e
        }
    }

    private suspend fun dispatch(action: WidgetAction, desiredLock: Boolean?, trace: WidgetTrace) {
        val store = trace.step("store") { VehicleStore.shared }
        trace.note("demo=${store.isDemo}")
        if (store.isDemo) throw LeapError.server("演示模式不会向车辆发送指令")

        if (action == WidgetAction.Trunk && SnapshotStore.read()?.isDriving == true) {
            throw LeapError.server("行驶中不能操作尾门")
        }

        val password = trace.step("password.read") { OperationPasswordStore().read() }
        trace.note("direct=${WidgetSettings.directControlEnabled} passwordPresent=${password != null}")
        if (!WidgetSettings.directControlEnabled || password == null) {
            // 走到这里说明渲染之后条件又没了（比如刚点过「忘记已保存的操作密码」）。
            // 动作先留给 App——下次打开 App 时 `consumePendingAction` 会接手。
            WidgetSettings.setPendingAction(action)
            throw LeapError.server("本机没存操作密码，打开 App 控车")
        }

        // 系统可能只为了这一下按键把进程拉起来，那时 `VehicleStore` 还是空的。
        // 先把会话从加密存储接回来，接不回来就如实说「请先登录」。
        trace.step("session.restore") { store.restoreSessionInBackground() }
        trace.note("loggedIn=${store.isLoggedIn}")
        if (!store.isLoggedIn) throw LeapError.notLoggedIn()

        val client = LeapClient()
        val snapshot = SnapshotStore.read()
        val command = command(action, snapshot, desiredLock)

        // 先下发指令，不等待 Glance 刷新或写入尚未经车辆确认的状态。
        // 部分桌面宿主的刷新可能阻塞，不能让它挡住控车请求。
        trace.step("send-control") { client.sendControl(command, password) }

        // 指令是异步执行的，等一下再拉车况，拿到的才是动作之后的状态。
        trace.step("ack.delay") { delay(3_000) }
        runCatching { trace.step("state.fetch") { client.fetchVehicleState() } }.getOrNull()?.let { state ->
            SnapshotStore.write(merge(state, snapshot ?: VehicleSnapshot.placeholder))
        }
        trace.step("success.refresh-surfaces") { LeapSurfaces.reloadAll(trace) }
    }

    internal fun command(
        action: WidgetAction,
        snapshot: VehicleSnapshot?,
        desiredLock: Boolean?,
    ): LeapCommand = when (action) {
        WidgetAction.Lock -> LeapCommand.lock()
        WidgetAction.Unlock -> LeapCommand.unlock()
        WidgetAction.ToggleLock -> {
            val lock = desiredLock ?: !(snapshot?.isLocked ?: true)
            if (lock) LeapCommand.lock() else LeapCommand.unlock()
        }
        WidgetAction.ToggleClimate -> LeapCommand.climate(
            on = !(snapshot?.climateOn ?: false),
            temperature = 24,
            fanLevel = 3,
            mode = ClimateMode.Cold,
            circleIn = true,
            windshield = false,
        )
        WidgetAction.Trunk -> LeapCommand.trunk()
        WidgetAction.Horn -> LeapCommand.horn()
    }

    /// 回读到的车况并进快照。位置和车名不动——这条路上没重新反查地名，
    /// 拿旧的比清空强。
    private fun merge(state: VehicleState, snapshot: VehicleSnapshot): VehicleSnapshot =
        snapshot.copy(
            soc = state.soc,
            gasolinePercent = state.gasolinePercent,
            isExtendRange = state.hasFuel,
            rangeKm = state.expectedMileage,
            energyRangeKm = if (state.hasFuel) state.energyRange else null,
            fuelRangeKm = if (state.hasFuel) state.gasolineRange else null,
            isLocked = state.isLocked,
            isDriving = state.isDriving,
            isCharging = state.isCharging,
            chargeLimit = state.chargeLimit,
            chargeRemainMinutes = state.chargeRemainMinutes,
            chargePowerKW = state.chargePowerKW,
            indoorTemp = state.indoorTemp,
            climateOn = state.acOn,
            windowsClosed = state.anyWindowOpen?.not() ?: snapshot.windowsClosed,
            anyDoorOpen = state.anyDoorOpen,
            trunkOpen = state.trunkOpen,
            hasTireWarning = state.hasTireWarning,
            updatedAt = System.currentTimeMillis(),
            reportedAt = state.reportedAt,
        )
}
