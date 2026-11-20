package org.yipao.app.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import org.yipao.app.app.VehicleStore
import org.yipao.app.core.AppEnv
import org.yipao.app.core.LeapError
import org.yipao.app.core.LeapErrorKind
import java.util.concurrent.TimeUnit

/// 后台每 15 分钟拉一次车况，让桌面上那张卡不必等用户打开 App 就能是新的。
///
/// **为什么非得有这个 Worker**：`updatePeriodMillis` 那个心跳只是让系统把卡片重画一遍，
/// 拿的还是磁盘上那份旧快照（重画唯一的效果是把「12 分钟前」这句话刷新掉）；
/// 而卡片的渲染回调里也不该发网络请求——那是有超时的，超时的后果是整张卡画不出来。
/// 对齐 iOS：那边卡片有时间线，系统会按 600 秒替它拉。
///
/// 15 分钟是系统给周期任务的**下限**，不是我们挑的：填更小的值 WorkManager 会直接
/// 按 15 分钟排。真正的执行时刻还要看 Doze 和待机分桶，说好的 15 分钟可能变成半小时，
/// 所以卡片上那句时效必须照实写（见 `VehicleSnapshot.freshnessText`）。
class VehicleRefreshWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        return try {
            VehicleStore.shared.refreshForSurfaces()
            // `refreshForSurfaces` 内部已经落盘并让各表面重画了，这里再来一次是为了
            // **等它画完**：那边是 `scope.launch` 出去的，worker 一返回进程随时可能被回收。
            LeapSurfaces.reloadAll()
            Result.success()
        } catch (e: Exception) {
            // 后台这一趟失败**不写** `recordControlError`。那条通道是「你刚按的那下没成」，
            // 会在卡片上顶五分钟；用户根本没按过任何东西，不该收到这句话。
            val kind = (e as? LeapError)?.kind
            when (kind) {
                // 没登录、演示模式、没选车——重试多少次都是同一个结果，等下个周期。
                LeapErrorKind.NotLoggedIn,
                LeapErrorKind.SessionExpired,
                LeapErrorKind.NeedsRelogin,
                LeapErrorKind.MissingVehicle,
                LeapErrorKind.Server,
                -> Result.success()
                // 断网、超时这类是真的「这次没赶上」，交给 WorkManager 退避重试。
                else -> Result.retry()
            }
        }
    }
}

/// 排这个周期任务，以及在最后一张卡被删掉时把它撤掉。
///
/// 没给用户开关：桌面上摆着卡片本身就是「我要看到最新车况」的意思，
/// 而没摆卡片的人不该为一个看不见的东西付电量。所以判据就是**有没有卡片实例**。
object VehicleRefreshScheduler {

    private const val WORK_NAME = "leap.widget.refresh"

    /// 按当前有没有卡片实例，排上或撤掉。
    ///
    /// 幂等，可以随便多调：排的时候用 `KEEP`，已经排着的任务不会被顶掉重排——
    /// 用 `REPLACE` 的话每次系统心跳都会把周期从头算起，等于永远等不到第一次执行。
    fun sync(context: Context) {
        val manager = runCatching { WorkManager.getInstance(context) }.getOrNull() ?: return
        if (hasAnyWidget(context)) {
            val request = PeriodicWorkRequestBuilder<VehicleRefreshWorker>(15, TimeUnit.MINUTES)
                .setConstraints(
                    Constraints.Builder()
                        // 只要有网就拉，不区分 WiFi 和流量：一次车况请求几 KB，
                        // 而「只在 WiFi 下更新」会让人在路上看到一张过时的卡。
                        // 也不看电量——省电模式下系统自己会把周期任务往后推，不用再加一道。
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build(),
                )
                .build()
            runCatching {
                manager.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
            }
        } else {
            runCatching { manager.cancelUniqueWork(WORK_NAME) }
        }
    }

    /// 四个 provider 里任意一个还有实例在桌面上，就得继续拉。
    ///
    /// 必须全都数：三种尺寸的车况卡是三个独立 provider，锁车卡上那句时效同样会过期。
    /// 少数哪个，桌面上只摆了那一张的人拿到的就是一张永远不动的卡。
    private fun hasAnyWidget(context: Context): Boolean {
        val manager = runCatching { AppWidgetManager.getInstance(context) }.getOrNull() ?: return false
        return listOf(
            VehicleSmallWidgetReceiver::class.java,
            VehicleMediumWidgetReceiver::class.java,
            VehicleWidgetReceiver::class.java,
            LockWidgetReceiver::class.java,
            LockOnlyWidgetReceiver::class.java,
            UnlockWidgetReceiver::class.java,
        ).any { receiver ->
            val ids = runCatching {
                manager.getAppWidgetIds(ComponentName(context, receiver))
            }.getOrNull()
            // `IntArray` 没有 `isNullOrEmpty`，那个扩展只给 `Array<T>` 和集合。
            (ids?.size ?: 0) > 0
        }
    }

    /// App 启动时对一次账。
    ///
    /// 光靠 `onEnabled` 不够：那个回调只在**第一个**实例被添加时来一次，
    /// 而升级安装的用户桌面上早就摆着卡片了，这辈子都不会再收到它。
    fun syncOnLaunch() {
        if (!AppEnv.isInstalled) return
        sync(AppEnv.context)
    }
}
