package org.yipao.app.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.IBinder
import androidx.compose.runtime.snapshotFlow
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.yipao.app.MainActivity
import org.yipao.app.R
import org.yipao.app.core.AppEnv
import org.yipao.app.core.DiagLog
import org.yipao.app.core.LeapDeepLink
import org.yipao.app.core.SnapshotStore
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetControlFeedback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/// 无感钥匙的后台常驻。
///
/// **为什么非要有它**：安卓不会替普通进程守着 GATT 连接。App 一退到后台，进程随时可能被
/// 回收，回收之后那条 `autoConnect=true` 的连接也就没了——走近车辆不再自动解锁，得先把
/// App 打开。iOS 靠 CoreBluetooth 的状态恢复由系统代管，安卓这边等价的做法只有前台服务。
///
/// 代价是一条撤不掉的常驻通知（前台服务的规矩，不是我们想挂）。所以只在**真的绑定了车、
/// 且蓝牙控车开着**的时候才起：没绑车却挂着一条通知，纯属占地方。
///
/// 这个服务自己不碰蓝牙，连接仍然全部由 [BLEVehicleController] 管。它只做两件事：
/// 把进程钉在前台、把当前状态显示出来。
class BLEKeyForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "leap.ble.key"
        private const val NOTIFICATION_ID = 1001

        /// 服务活着的时候这里非空。用它避免对已经在跑的服务重复 `startForegroundService`——
        /// 安卓 12 起后台启动前台服务会抛 `ForegroundServiceStartNotAllowedException`，
        /// 而「已经在跑」本来就不需要再启一次。
        private var instance: BLEKeyForegroundService? = null

        /// 让常驻通知重画一次（车况变了、控车失败了、直接控车开关动了都要调）。
        /// 服务没在跑就什么都不做——那时本来就没有这条通知。
        fun refreshNotification() {
            instance?.updateNotification()
        }

        /// 按控制器当前是否需要常驻来起停。控制器状态一变就会调到这里。
        fun sync() {
            val wanted = BLEVehicleController.shared.wantsBackgroundArming
            val context = AppEnv.context
            val intent = Intent(context, BLEKeyForegroundService::class.java)
            if (wanted) {
                if (instance != null) return
                // 从后台调用会被系统拒（安卓 12 起）。这条路径本身就只在前台发生，
                // 真被拒了也不该崩——下次回到前台还会再同步一次。
                runCatching { ContextCompat.startForegroundService(context, intent) }
                    .onFailure { DiagLog.note("[ble:service] 前台服务启动被系统拒绝：${it.javaClass.simpleName}") }
            } else {
                if (instance == null) return
                runCatching { context.stopService(intent) }
            }
        }
    }

    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureChannel()
        // 必须在 onCreate 里就进前台：`startForegroundService` 之后有 5 秒的硬限期，
        // 超时系统直接 ANR 掉整个 App。
        //
        // 会失败的情形只有一种：connectedDevice 这个类型要求 BLUETOOTH_CONNECT 在手，
        // 而用户可能在系统设置里刚把它撤了（撤权限会杀进程，回来就走这条路）。
        // 那时候没有蓝牙钥匙可言，直接收摊，别把 SecurityException 抛成崩溃。
        val entered = runCatching {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        }.isSuccess
        if (!entered) {
            DiagLog.note("[ble:service] 进入前台失败，多半是蓝牙权限被撤，停止常驻")
            stopSelf()
            return
        }
        scope.launch {
            snapshotFlow { statusText() }
                .distinctUntilChanged()
                .collect { updateNotification() }
        }
        DiagLog.note("[ble:service] 无感钥匙常驻已启动")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // intent 为 null 说明是 START_STICKY 把我们重新拉起来的：进程是全新的，
        // 会话和蓝牙运行时都还没装配。这里只做本机恢复，不联网——无感钥匙要的
        // 证书和绑定全在本地加密存储里，没网也该照常武装。
        if (intent == null) VehicleStore.shared.restoreBluetoothRuntimeInBackground()
        if (!BLEVehicleController.shared.wantsBackgroundArming) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        instance = null
        DiagLog.note("[ble:service] 无感钥匙常驻已停止")
        super.onDestroy()
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        // IMPORTANCE_LOW：不响铃、不浮出来。这条通知是「服务在跑」的凭证，不是提醒。
        val channel = NotificationChannel(CHANNEL_ID, "蓝牙钥匙", NotificationManager.IMPORTANCE_LOW)
        channel.description = "无感解闭锁在后台保持与车辆的蓝牙连接"
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun statusText(): String {
        val controller = BLEVehicleController.shared
        return controller.runtimeState.detail ?: controller.runtimeState.label
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        // 刚失败过就把原因顶到正文上。这条通知是这三处表面里唯一有足够宽度说清楚的，
        // 蓝牙连接状态可以先让位五分钟。
        val body = WidgetControlFeedback.recentFailure ?: statusText()
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_bluetooth)
            .setContentTitle("蓝牙钥匙")
            .setContentText(body)
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            // 不显示时间戳：这条通知会挂上好几天，一个「三天前」的时间只会让人困惑。
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            // 锁屏上整条不显示：状态文案里可能带着跟这台车有关的提示，而且下面这两个
            // 控车按钮一旦出现在锁屏上，就等于把车门交给了任何一个捡到手机的人。
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
        addControlActions(builder)
        return builder.build()
    }

    /// 解锁 / 闭锁两个按钮。
    ///
    /// 挂在这条已有的通知上，而不是另起一条：多一条常驻通知的代价是每天几十次的视觉打扰，
    /// 而这两个按钮的受众——绑了蓝牙钥匙的人——本来就已经在看这条通知了。
    /// 代价是没绑蓝牙钥匙就没有这两个按钮，那些人用桌面小组件或快捷设置磁贴。
    private fun addControlActions(builder: NotificationCompat.Builder) {
        // 没有车况说明还没同步过，两个按钮发出去也是白发，这时不摆按钮。
        if (SnapshotStore.read() == null) return
        builder.addAction(0, "解锁", controlIntent(desiredLock = false))
        builder.addAction(0, "闭锁", controlIntent(desiredLock = true))
    }

    /// 能直发就发广播，不能就退回打开 App——按钮的外观一样，落点不同。
    ///
    /// requestCode 用目标锁态区分：两个 PendingIntent 只有 extra 不同，
    /// 共用一个 requestCode 的话第二个会复用第一个，两个按钮会做同一件事。
    private fun controlIntent(desiredLock: Boolean): PendingIntent {
        val code = if (desiredLock) 2 else 3
        if (!WidgetControlRunner.canDispatchDirectly) {
            val open = Intent(Intent.ACTION_VIEW, Uri.parse(LeapDeepLink.action(WidgetAction.ToggleLock)))
                .setClass(this, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            return PendingIntent.getActivity(this, code, open, PendingIntent.FLAG_IMMUTABLE)
        }
        val intent = Intent(this, ControlNotificationReceiver::class.java)
            .setAction(ControlNotificationReceiver.ACTION_CONTROL)
            .putExtra(ControlNotificationReceiver.EXTRA_ACTION, WidgetAction.ToggleLock.rawValue)
            .putExtra(ControlNotificationReceiver.EXTRA_DESIRED_LOCK, desiredLock)
        return PendingIntent.getBroadcast(this, code, intent, PendingIntent.FLAG_IMMUTABLE)
    }

    private fun updateNotification() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // 没给通知权限时这一发是空转，服务本身照常跑——这正是我们要的优先级。
        runCatching { manager.notify(NOTIFICATION_ID, buildNotification()) }
    }
}
