package org.yipao.app.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.widget.RemoteViews
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.core.content.ContextCompat
import org.yipao.app.R
import org.yipao.app.app.WidgetControlRunner
import org.yipao.app.core.CarImageCache
import org.yipao.app.core.SnapshotStore
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetControlFeedback
import org.yipao.app.core.WidgetSettings
import org.yipao.app.core.WidgetTrace

enum class NativeWidgetKind { SMALL, MEDIUM, LARGE, LOCK_TOGGLE, LOCK_ONLY, UNLOCK }

abstract class NativeWidgetReceiver : AppWidgetProvider() {
    protected abstract val nativeKind: NativeWidgetKind

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        VehicleRefreshScheduler.sync(context)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        VehicleRefreshScheduler.sync(context)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        NativeWidgets.update(context, manager, nativeKind, ids)
        VehicleRefreshScheduler.sync(context)
    }
}

/** Root-level RemoteViews for launchers that lose PendingIntents in nested Glance views. */
internal object NativeWidgets {
    private data class Provider(val kind: NativeWidgetKind, val receiver: Class<out AppWidgetProvider>)
    private val providers = listOf(
        Provider(NativeWidgetKind.SMALL, VehicleSmallWidgetReceiver::class.java),
        Provider(NativeWidgetKind.MEDIUM, VehicleMediumWidgetReceiver::class.java),
        Provider(NativeWidgetKind.LARGE, VehicleWidgetReceiver::class.java),
        Provider(NativeWidgetKind.LOCK_TOGGLE, LockWidgetReceiver::class.java),
        Provider(NativeWidgetKind.LOCK_ONLY, LockOnlyWidgetReceiver::class.java),
        Provider(NativeWidgetKind.UNLOCK, UnlockWidgetReceiver::class.java),
    )

    fun updateAll(context: Context, trace: WidgetTrace? = null) {
        val manager = AppWidgetManager.getInstance(context)
        providers.forEach { provider ->
            val ids = manager.getAppWidgetIds(ComponentName(context, provider.receiver))
            update(context, manager, provider.kind, ids, trace)
        }
    }

    fun update(
        context: Context,
        manager: AppWidgetManager,
        kind: NativeWidgetKind,
        ids: IntArray,
        trace: WidgetTrace? = null,
    ) {
        trace?.note("provider.Native${kind.name}.begin count=${ids.size}")
        val snapshot = SnapshotStore.read()
        ids.forEach { id ->
            runCatching { manager.updateAppWidget(id, createViews(context, kind, snapshot, id)) }
                .onSuccess { trace?.note("widget.$id.native.update.ok") }
                .onFailure { trace?.note("widget.$id.native.error ${it.javaClass.simpleName}") }
        }
        trace?.note("provider.Native${kind.name}.end")
    }

    internal fun createViews(
        context: Context,
        kind: NativeWidgetKind,
        snapshot: VehicleSnapshot?,
        appWidgetId: Int,
    ): RemoteViews = when (kind) {
        NativeWidgetKind.SMALL -> vehicleViews(context, snapshot, appWidgetId, small = true)
        NativeWidgetKind.MEDIUM -> mediumViews(context, snapshot, appWidgetId)
        NativeWidgetKind.LARGE -> vehicleViews(context, snapshot, appWidgetId, small = false)
        NativeWidgetKind.LOCK_TOGGLE,
        NativeWidgetKind.LOCK_ONLY,
        NativeWidgetKind.UNLOCK,
        -> lockViews(context, kind, snapshot, appWidgetId)
    }.also {
        WidgetTrace("native.render widget=$appWidgetId").note(
            "kind=${kind.name} direct=${WidgetControlRunner.canDispatchDirectly}",
        )
    }

    private fun mediumViews(context: Context, snapshot: VehicleSnapshot?, id: Int) =
        RemoteViews(context.packageName, R.layout.widget_vehicle_medium).apply {
            bindRoot(context, R.id.widget_medium_root, id)
            bindVehicleInfo(
                snapshot,
                R.id.widget_medium_vehicle_name,
                R.id.widget_medium_soc,
                R.id.widget_medium_percent,
                R.id.widget_medium_range,
                R.id.widget_medium_energy,
                R.id.widget_medium_status,
            )
            bindActions(
                context, snapshot, id, WidgetSettings.buttons(false),
                intArrayOf(R.id.widget_medium_action_0, R.id.widget_medium_action_1, R.id.widget_medium_action_2, R.id.widget_medium_action_3),
                intArrayOf(R.id.widget_medium_action_icon_0, R.id.widget_medium_action_icon_1, R.id.widget_medium_action_icon_2, R.id.widget_medium_action_icon_3),
                intArrayOf(R.id.widget_medium_action_title_0, R.id.widget_medium_action_title_1, R.id.widget_medium_action_title_2, R.id.widget_medium_action_title_3),
            )
        }

    private fun vehicleViews(context: Context, snapshot: VehicleSnapshot?, id: Int, small: Boolean) =
        RemoteViews(context.packageName, if (small) R.layout.widget_vehicle_small else R.layout.widget_vehicle_large).apply {
            if (small) {
                bindRoot(context, R.id.widget_small_root, id)
                bindVehicleInfo(snapshot, R.id.widget_small_vehicle_name, R.id.widget_small_soc,
                    R.id.widget_small_percent, R.id.widget_small_range, R.id.widget_small_energy, null)
                bindActions(
                    context, snapshot, id, WidgetSettings.buttons(true),
                    intArrayOf(R.id.widget_small_action_0, R.id.widget_small_action_1),
                    intArrayOf(R.id.widget_small_action_icon_0, R.id.widget_small_action_icon_1),
                    intArrayOf(R.id.widget_small_action_title_0, R.id.widget_small_action_title_1),
                )
            } else {
                bindRoot(context, R.id.widget_large_root, id)
                bindVehicleInfo(snapshot, R.id.widget_large_vehicle_name, R.id.widget_large_soc,
                    R.id.widget_large_percent, R.id.widget_large_range, R.id.widget_large_energy, R.id.widget_large_status)
                setVehicleArtwork(context, R.id.widget_large_car)
                bindActions(
                    context, snapshot, id, WidgetSettings.buttons(false),
                    intArrayOf(R.id.widget_large_action_0, R.id.widget_large_action_1, R.id.widget_large_action_2, R.id.widget_large_action_3),
                    intArrayOf(R.id.widget_large_action_icon_0, R.id.widget_large_action_icon_1, R.id.widget_large_action_icon_2, R.id.widget_large_action_icon_3),
                    intArrayOf(R.id.widget_large_action_title_0, R.id.widget_large_action_title_1, R.id.widget_large_action_title_2, R.id.widget_large_action_title_3),
                )
            }
        }

    private fun lockViews(
        context: Context,
        kind: NativeWidgetKind,
        snapshot: VehicleSnapshot?,
        id: Int,
    ) = RemoteViews(context.packageName, R.layout.widget_lock_native).apply {
        val action = when (kind) {
            NativeWidgetKind.LOCK_ONLY -> WidgetAction.Lock
            NativeWidgetKind.UNLOCK -> WidgetAction.Unlock
            else -> if (snapshot?.lockActionTarget == false) WidgetAction.Unlock else WidgetAction.Lock
        }
        setTextViewText(R.id.widget_lock_title, action.label)
        setTextViewText(R.id.widget_lock_vehicle_name, snapshot?.vehicleName ?: "我的车")
        setTextViewText(R.id.widget_lock_status, lockStatus(snapshot))
        val badgeColor = if (action == WidgetAction.Unlock) WidgetTint.Caution else WidgetTint.Accent
        setImageViewBitmap(R.id.widget_lock_badge, iconBitmap(context,
            if (action == WidgetAction.Unlock) R.drawable.ic_widget_lock_open else R.drawable.ic_widget_lock,
            currentColor(context, badgeColor), 18))
        setVehicleArtwork(context, R.id.widget_lock_car)
        setOnClickPendingIntent(
            R.id.widget_lock_root,
            actionPendingIntent(context, action, snapshot?.takeIf { kind == NativeWidgetKind.LOCK_TOGGLE }?.lockActionTarget, 8, id),
        )
    }

    private fun RemoteViews.bindRoot(context: Context, rootId: Int, appWidgetId: Int) {
        setOnClickPendingIntent(rootId, openAppPendingIntent(context, appWidgetId))
    }

    private fun RemoteViews.bindVehicleInfo(
        snapshot: VehicleSnapshot?,
        nameId: Int,
        socId: Int,
        percentId: Int,
        rangeId: Int,
        progressId: Int,
        statusId: Int?,
    ) {
        setTextViewText(nameId, snapshot?.vehicleName ?: "还没有车况")
        setTextViewText(socId, snapshot?.soc?.toString() ?: "--")
        setTextViewText(percentId, "%")
        setTextViewText(rangeId, snapshot?.mediumRangeText.orEmpty())
        setViewVisibility(rangeId, if (snapshot?.mediumRangeText == null) View.GONE else View.VISIBLE)
        setProgressBar(progressId, 100, snapshot?.soc?.coerceIn(0, 100) ?: 0, false)
        statusId?.let {
            setTextViewText(it, snapshot?.let { value -> "${value.headline} · ${value.freshnessCompact}" }
                ?: "打开 App 同步一次")
        }
    }

    private fun RemoteViews.bindActions(
        context: Context,
        snapshot: VehicleSnapshot?,
        appWidgetId: Int,
        actions: List<WidgetAction>,
        tileIds: IntArray,
        iconIds: IntArray,
        titleIds: IntArray,
    ) {
        tileIds.indices.forEach { slot ->
            val action = actions.getOrNull(slot)
            if (action == null) {
                setViewVisibility(tileIds[slot], View.INVISIBLE)
                return@forEach
            }
            val appearance = WidgetActionAppearance.of(action, snapshot)
            val desiredLock = if (action == WidgetAction.ToggleLock) snapshot?.lockActionTarget else null
            val foreground = if (appearance.prominent) currentColor(context, appearance.tint)
                else ContextCompat.getColor(context, R.color.widget_native_secondary)
            setViewVisibility(tileIds[slot], View.VISIBLE)
            setTextViewText(titleIds[slot], appearance.title)
            setTextColor(titleIds[slot], foreground)
            setImageViewBitmap(iconIds[slot], iconBitmap(context, appearance.icon, foreground, 24))
            setCharSequence(tileIds[slot], "setContentDescription", appearance.title)
            setOnClickPendingIntent(tileIds[slot], actionPendingIntent(context, action, desiredLock, slot, appWidgetId))
            val fill = Color(foreground).copy(alpha = if (appearance.prominent) 0.20f else 0.10f).toArgb()
            setColorStateList(tileIds[slot], "setBackgroundTintList", ColorStateList.valueOf(fill))
        }
    }

    private fun RemoteViews.setVehicleArtwork(context: Context, viewId: Int) {
        val car = CarImageCache.shared()
        if (car != null) setImageViewBitmap(viewId, car)
        else setImageViewBitmap(viewId, iconBitmap(context, R.drawable.ic_widget_car,
            ContextCompat.getColor(context, R.color.widget_native_secondary), 96))
    }

    private fun lockStatus(snapshot: VehicleSnapshot?): String {
        if (snapshot == null) return "打开 App 同步一次"
        val warning = WidgetControlFeedback.recentFailure ?: when {
            snapshot.anyDoorOpen -> "有车门未关闭"
            snapshot.trunkOpen == true -> "尾门未关闭"
            snapshot.windowsClosed == false -> "车窗未关闭"
            else -> null
        }
        return "${warning ?: snapshot.lockText} · ${snapshot.freshnessCompact}"
    }

    private fun currentColor(context: Context, tint: WidgetTint): Int {
        val night = context.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK ==
            android.content.res.Configuration.UI_MODE_NIGHT_YES
        return (if (night) tint.night else tint.day).toArgb()
    }

    private fun iconBitmap(context: Context, resource: Int, color: Int, sizeDp: Int): Bitmap {
        val px = (sizeDp * context.resources.displayMetrics.density).toInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val drawable = requireNotNull(ContextCompat.getDrawable(context, resource)).mutate()
        drawable.setTint(color)
        drawable.setBounds(0, 0, px, px)
        drawable.draw(Canvas(bitmap))
        return bitmap
    }
}
