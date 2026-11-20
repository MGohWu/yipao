package org.yipao.app.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.state.PreferencesGlanceStateDefinition
import org.yipao.app.R
import org.yipao.app.core.CarImageCache
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetControlFeedback

/// 整张卡执行标题所示的上锁或解锁操作，右上角图标标识操作方向。
open class LockWidget(private val action: WidgetAction = WidgetAction.ToggleLock) : GlanceAppWidget() {

    override val stateDefinition = PreferencesGlanceStateDefinition

    /// 只有一种尺寸（2×2），而且不可拉伸：这张卡上只有一个字加一个图标，放大了
    /// 也不会多出信息，反而会变成一大片可点区域——误触代价是车门开了。
    ///
    /// 尺寸钉死了还要 `Exact`，是因为「2×2」在各家桌面上不是同一个尺寸（道理和
    /// `VehicleWidgetBase.sizeMode` 那段一样）。这里只用它算中间剪影该多大。
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val snapshot = currentVehicleSnapshot()
            val cardAction = if (action == WidgetAction.ToggleLock) {
                if (snapshot?.lockActionTarget != false) WidgetAction.Lock else WidgetAction.Unlock
            } else action
            // Glance 修订号变化会重组这段；车图只换文件、不改车况时也能读到新图。
            val car = CarImageCache.shared()
            // 缺图时那个剪影跟着卡片一起缩放：写死一个数的话，卡片一高它就浮在
            // 中间一小块，看着像图没加载出来。
            val silhouette = ((LocalSize.current.height - CARD_PADDING * 2) * 0.34f)
                .coerceIn(34.dp, 72.dp)
            WidgetCard(
                onClick = if (snapshot == null) openAppAction(cardAction) else actionFor(cardAction),
                padding = CARD_PADDING,
                background = lockBackground(snapshot?.isLocked),
                clickOverlay = true,
            ) {
                Column(
                    modifier = GlanceModifier.fillMaxSize(),
                    horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
                ) {
                    Row(modifier = GlanceModifier.fillMaxWidth()) {
                        Column(modifier = GlanceModifier.defaultWeight()) {
                            Text(
                                text = cardAction.label,
                                maxLines = 1,
                                style = TextStyle(color = WidgetPalette.primaryText, fontSize = 14.sp, fontWeight = FontWeight.Bold),
                            )
                            Text(
                                text = snapshot?.vehicleName ?: "我的车",
                                maxLines = 1,
                                style = TextStyle(color = WidgetPalette.secondaryText, fontSize = 11.sp),
                            )
                        }
                        LockBadge(cardAction)
                    }
                    Box(
                        modifier = GlanceModifier.fillMaxWidth().defaultWeight().padding(vertical = 4.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (car != null) {
                            Image(
                                provider = ImageProvider(car),
                                contentDescription = null,
                                contentScale = ContentScale.Fit,
                                // 写进共享目录时四周透明边已经裁掉了，这里铺满就行。
                                modifier = GlanceModifier.fillMaxSize(),
                            )
                        } else {
                            Image(
                                provider = ImageProvider(R.drawable.ic_widget_car),
                                contentDescription = null,
                                modifier = GlanceModifier.size(silhouette),
                                colorFilter = ColorFilter.tint(WidgetPalette.tertiaryText),
                            )
                        }
                    }
                    StatusLine(snapshot)
                }
            }
        }
    }
}

/// 卡片四周留白，照 iOS `LockWidgetView` 的 14。
/// 版式里要拿它反算净高，所以摆在外面。
private val CARD_PADDING = 14.dp

class LockOnlyWidget : LockWidget(WidgetAction.Lock)
class UnlockWidget : LockWidget(WidgetAction.Unlock)

class LockOnlyWidgetReceiver : NativeWidgetReceiver() {
    override val nativeKind = NativeWidgetKind.LOCK_ONLY
}

class UnlockWidgetReceiver : NativeWidgetReceiver() {
    override val nativeKind = NativeWidgetKind.UNLOCK
}

class LockWidgetReceiver : NativeWidgetReceiver() {
    override val nativeKind = NativeWidgetKind.LOCK_TOGGLE
}

/// 徽标表达点击后的操作方向，当前车况由底部文字表达。
@Composable
private fun LockBadge(action: WidgetAction) {
    Box(
        modifier = GlanceModifier
            .size(26.dp)
            .cornerRadius(13.dp)
            .background(WidgetPalette.tileForeground(
                if (action == WidgetAction.Unlock) WidgetTint.Caution else WidgetTint.Accent,
                prominent = true,
            )),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            provider = ImageProvider(if (action == WidgetAction.Unlock) R.drawable.ic_widget_lock_open else R.drawable.ic_widget_lock),
            contentDescription = action.label,
            modifier = GlanceModifier.size(13.dp),
            colorFilter = ColorFilter.tint(WidgetPalette.onAccent),
        )
    }
}

/// 底部那一行。
///
/// 门窗未关比「锁没锁」更该被看到：锁着但窗开着，车其实是敞的。有这类异常时整行
/// 让给它，前面加一个警示图标。
///
/// **颜色只交给图标，文字保持常规色**——卡底本来就是一层淡琥珀，同色系的字叠上去
/// 几乎看不见，最该被看到的一行反而成了最不显眼的。这条是 iOS 那边试出来的。
@Composable
private fun StatusLine(snapshot: VehicleSnapshot?) {
    if (snapshot == null) {
        Text(
            text = "打开 App 同步一次",
            maxLines = 1,
            style = TextStyle(color = WidgetPalette.secondaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium),
        )
        return
    }
    val warning = lockWarning(snapshot)
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Vertical.CenterVertically) {
        if (warning != null) {
            Image(
                provider = ImageProvider(R.drawable.ic_widget_warning),
                contentDescription = null,
                modifier = GlanceModifier.size(10.dp),
                colorFilter = ColorFilter.tint(WidgetPalette.warm),
            )
            Spacer(GlanceModifier.width(3.dp))
        }
        // 有警告时把时效缩成「1 小时前」。这张卡只有 2 格宽，一百二十来 dp 的可用宽度
        // 装不下「车窗未关闭 · 更新于 1 小时前」，多出来的部分会被直接切掉——
        // 而被切掉的正好是时效。丢掉「更新于」三个字换整句话读得完，划算。
        val freshness = if (warning == null) {
            snapshot.freshnessText
        } else {
            snapshot.freshnessText.removePrefix("更新于 ").removePrefix("读取于 ")
        }
        Text(
            text = "${warning ?: snapshot.lockText} · $freshness",
            maxLines = 1,
            style = TextStyle(color = WidgetPalette.primaryText, fontSize = 10.sp, fontWeight = FontWeight.Medium),
        )
    }
}

/// 这张卡只说门窗类异常，充电、位置那些是车况卡的事。没有就返回 null。
private fun lockWarning(snapshot: VehicleSnapshot): String? {
    // 刚按过一下却没成，这件事比任何车况都该先说。
    WidgetControlFeedback.recentFailure?.let { return it }
    if (snapshot.anyDoorOpen) return "有车门未关闭"
    if (snapshot.trunkOpen == true) return "尾门未关闭"
    if (snapshot.windowsClosed == false) return "车窗未关闭"
    return null
}

/// 随状态变色的卡片底。
///
/// 刻意压得很淡（照抄 iOS 那两档 0.18 / 0.05 的透明度）：状态该由右上角的徽标说，
/// 底色只是让人余光扫过桌面时能感觉到不对劲。铺一层饱和色块会把车图整个染掉。
///
/// 做成 drawable 而不是在这里画，是因为 Glance 没有 Brush——它的画面最终是
/// `RemoteViews`，只认得 drawable 资源，画不了运行时生成的渐变。
private fun lockBackground(locked: Boolean?): Int = when (locked) {
    true -> R.drawable.widget_lock_bg_locked
    false -> R.drawable.widget_lock_bg_unlocked
    null -> R.drawable.widget_lock_bg_unknown
}
