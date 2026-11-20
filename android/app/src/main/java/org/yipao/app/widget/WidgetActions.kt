package org.yipao.app.widget

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.glance.GlanceId
import androidx.glance.action.Action
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionSendBroadcast
import androidx.glance.appwidget.action.actionStartActivity
import org.yipao.app.MainActivity
import org.yipao.app.app.VehicleStore
import org.yipao.app.app.WidgetControlRunner
import org.yipao.app.core.AppEnv
import org.yipao.app.core.LeapDeepLink
import org.yipao.app.core.LeapError
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetTrace
import org.yipao.app.core.WidgetSettings

/// 卡片按钮按下之后发生什么。
///
/// 每个按钮在**渲染时**就决定走哪条路：能直接下发就挂 [WidgetActionReceiver]，
/// 不能就挂「打开 App」。不在回调里再判一次的原因是外观必须跟着走——
/// 一个看起来会直接锁车、按下去却跳进 App 的按钮，比一个老老实实写着「打开 App」
/// 的按钮更让人恼火。

private const val ACTION_KEY_NAME = "leap.widget.action"
private const val LOCK_KEY_NAME = "leap.widget.desiredLock"
private val ActionKey = ActionParameters.Key<String>(ACTION_KEY_NAME)
private val DesiredLockKey = ActionParameters.Key<Boolean>(LOCK_KEY_NAME)

/// 按下即发。失败已经由 [WidgetControlRunner] 记进卡片，这里只负责不让它崩。
class ControlCallback : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: ActionParameters,
    ) {
        val trace = WidgetTrace("control.callback widget=$glanceId")
        val action = WidgetAction.of(parameters[ActionKey])
        if (action == null) {
            trace.note("invalid-action")
            return
        }
        trace.note("action=${action.rawValue} desiredLock=${parameters[DesiredLockKey]}")
        // 方向是**渲染那一刻**按当时的快照定的，不在这里重算：卡片上写着什么，
        // 按下去就该发生什么。回调里再读一次快照的话，正好赶上后台刷新写入就会发反。
        runCatching {
            trace.step("runner") {
                WidgetControlRunner.run(action, desiredLock = parameters[DesiredLockKey])
            }
        }
        trace.note("callback.end")
    }
}

/// 卡片上那个刷新按钮。
///
/// 这是**唯一**一条卡片主动联网的路径，而且必须由用户按下才会走——
/// 系统那个半小时的心跳只让卡片拿本地快照重画（把「12 分钟前」这句刷新掉），不联网。
class RefreshCallback : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: ActionParameters,
    ) {
        val trace = WidgetTrace("refresh.callback widget=$glanceId")
        try {
            trace.step("refresh-state") { VehicleStore.shared.refreshForSurfaces() }
            WidgetSettings.recordControlError(null)
        } catch (e: Exception) {
            WidgetSettings.recordControlError(LeapError.messageOf(e))
        }
        trace.step("refresh-surfaces") { LeapSurfaces.reloadAll() }
    }
}

/// 直接下发。
internal fun dispatchAction(action: WidgetAction, desiredLock: Boolean? = null): Action {
    val intent = Intent(AppEnv.context, WidgetActionReceiver::class.java)
        .setAction(WidgetActionReceiver.ACTION_CONTROL)
        // PendingIntent 的相等性不比较 extras。把动作放进 data，避免几个按钮复用同一个广播。
        .setData(Uri.parse("leapcontrol://widget/control/${action.rawValue}?lock=$desiredLock"))
        .putExtra(WidgetActionReceiver.EXTRA_ACTION, action.rawValue)
    if (desiredLock != null) {
        intent.putExtra(WidgetActionReceiver.EXTRA_DESIRED_LOCK, desiredLock)
    }
    return actionSendBroadcast(intent)
}

internal fun refreshAction(): Action = actionSendBroadcast(
    Intent(AppEnv.context, WidgetActionReceiver::class.java)
        .setAction(WidgetActionReceiver.ACTION_REFRESH)
        .setData(Uri.parse("leapcontrol://widget/refresh")),
)

/** Native RemoteViews buttons use this directly so their fixed resource IDs own the click. */
internal fun actionPendingIntent(
    context: Context,
    action: WidgetAction,
    desiredLock: Boolean?,
    slot: Int,
    appWidgetId: Int,
): PendingIntent {
    val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    if (!WidgetControlRunner.canDispatchDirectly) {
        val target = Intent(Intent.ACTION_VIEW, Uri.parse("${LeapDeepLink.action(action)}&widget=$appWidgetId&slot=$slot"))
            .setClass(context, MainActivity::class.java)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(context, 20_000 + appWidgetId * 10 + slot, target, flags)
    }

    val target = Intent(context, WidgetActionReceiver::class.java)
        .setAction(WidgetActionReceiver.ACTION_CONTROL)
        .setData(Uri.parse("leapcontrol://widget/control/${action.rawValue}?lock=$desiredLock&slot=$slot&widget=$appWidgetId"))
        .putExtra(WidgetActionReceiver.EXTRA_ACTION, action.rawValue)
    if (desiredLock != null) {
        target.putExtra(WidgetActionReceiver.EXTRA_DESIRED_LOCK, desiredLock)
    }
    return PendingIntent.getBroadcast(context, 30_000 + appWidgetId * 10 + slot, target, flags)
}

internal fun openAppPendingIntent(context: Context, appWidgetId: Int): PendingIntent {
    val target = Intent(Intent.ACTION_VIEW, Uri.parse("${LeapDeepLink.HOME}?widget=$appWidgetId"))
        .setClass(context, MainActivity::class.java)
        .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    return PendingIntent.getActivity(
        context,
        10_000 + appWidgetId,
        target,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

/// 打开 App。带上动作时 App 会在验证通过后接着把它执行掉（见 `MainActivity`）。
internal fun openAppAction(action: WidgetAction? = null): Action {
    val target = action?.let { LeapDeepLink.action(it) } ?: LeapDeepLink.HOME
    return actionStartActivity(
        Intent(Intent.ACTION_VIEW, Uri.parse(target))
            // 显式指到 MainActivity：隐式 VIEW 有可能被别的应用接走。
            .setClass(org.yipao.app.core.AppEnv.context, MainActivity::class.java)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
    )
}

/// 一个动作该挂哪条路：能直发就直发，否则打开 App 接着办。
///
/// [desiredLock] 只有车锁键会传，值来自 `VehicleSnapshot.lockActionTarget`——
/// 不传的话下游会照着快照 toggle，而快照旧了显示「已锁车」，toggle 出来的就是解锁。
/// 打开 App 那条路不带方向：App 拿得到实时车况，用不着卡片替它猜。
internal fun actionFor(action: WidgetAction, desiredLock: Boolean? = null): Action =
    if (WidgetControlRunner.canDispatchDirectly) {
        dispatchAction(action, desiredLock)
    } else {
        openAppAction(action)
    }
