package org.yipao.app.widget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.yipao.app.app.VehicleStore
import org.yipao.app.app.WidgetControlRunner
import org.yipao.app.core.LeapError
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetSettings
import org.yipao.app.core.WidgetTrace
import kotlinx.coroutines.launch

/**
 * Desktop-widget button entry point owned by the app.
 *
 * HyperOS 4 can mount Glance callback RemoteViews without retaining the callback session. An
 * explicit broadcast PendingIntent avoids that session and reaches this receiver directly.
 */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val request = parseWidgetBroadcast(
            intent.action,
            intent.getStringExtra(EXTRA_ACTION),
            intent.takeIf { it.hasExtra(EXTRA_DESIRED_LOCK) }
                ?.getBooleanExtra(EXTRA_DESIRED_LOCK, true),
        ) ?: return
        val trace = WidgetTrace("broadcast.received request=$request")
        val pendingResult = goAsync()
        surfaceScope.launch {
            try {
                when (request) {
                    is WidgetBroadcastRequest.Control -> trace.step("broadcast.control") {
                        WidgetControlRunner.run(request.action, request.desiredLock)
                    }
                    WidgetBroadcastRequest.Refresh -> refresh(trace)
                }
            } catch (_: Exception) {
                // The runner and refresh path persist their user-facing error and trace details.
            } finally {
                trace.note("broadcast.finished")
                pendingResult.finish()
            }
        }
    }

    private suspend fun refresh(trace: WidgetTrace) {
        try {
            trace.step("broadcast.refresh-state") { VehicleStore.shared.refreshForSurfaces() }
            WidgetSettings.recordControlError(null)
        } catch (error: Exception) {
            WidgetSettings.recordControlError(LeapError.messageOf(error))
        }
        trace.step("broadcast.refresh-surfaces") { LeapSurfaces.reloadAll(trace) }
    }

    companion object {
        internal const val ACTION_CONTROL = "org.yipao.app.action.WIDGET_CONTROL"
        internal const val ACTION_REFRESH = "org.yipao.app.action.WIDGET_REFRESH"
        internal const val EXTRA_ACTION = "action"
        internal const val EXTRA_DESIRED_LOCK = "desiredLock"
    }
}

internal sealed interface WidgetBroadcastRequest {
    data class Control(val action: WidgetAction, val desiredLock: Boolean?) : WidgetBroadcastRequest
    data object Refresh : WidgetBroadcastRequest
}

internal fun parseWidgetBroadcast(
    intentAction: String?,
    rawAction: String?,
    desiredLock: Boolean?,
): WidgetBroadcastRequest? = when (intentAction) {
    WidgetActionReceiver.ACTION_CONTROL -> WidgetAction.of(rawAction)?.let {
        WidgetBroadcastRequest.Control(it, desiredLock)
    }
    WidgetActionReceiver.ACTION_REFRESH -> WidgetBroadcastRequest.Refresh
    else -> null
}
