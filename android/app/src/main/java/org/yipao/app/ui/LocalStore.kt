package org.yipao.app.ui

import androidx.compose.runtime.staticCompositionLocalOf
import org.yipao.app.app.VehicleStore

/// 全局唯一的那份车况/控车状态。`VehicleStore` 本身是进程级单例，
/// 走 CompositionLocal 只是为了让页面不必到处 import 单例，
/// 也让预览和测试能塞一份别的进去。
val LocalStore = staticCompositionLocalOf<VehicleStore> {
    error("VehicleStore 没有下发")
}

/// 车况新鲜度文案。
///
/// 优先报车端自己采集这份数据的时刻：本机每 10 秒问一次服务端，但车休眠着不上报时，
/// 服务端会把同一份旧数据一直发回来——按本机拉取时间算，屏幕上就永远写着「刚刚更新」，
/// 而实际数据可能是半小时前的。这正是「刷新不及时」最常见的真身。
///
/// 车端时间拿不到（某些车型不报 `collectTime`）时退回本机拉取时间，同时把措辞从
/// 「更新」换成「读取」——那句话只能保证「几分钟前问过」，保证不了「车况就是那时候的」。
fun freshnessText(reportedAt: Long?, fetchedAt: Long): String {
    val verb = if (reportedAt == null) "读取" else "更新"
    val moment = reportedAt ?: fetchedAt
    if (elapsedSeconds(moment) < 60) return "车况刚刚$verb"
    return "车况${verb}于 ${relativeText(moment)}"
}

/// 「刚刚 / 12 分钟前 / 3 小时前」。不带主语，谁在什么时候发生由调用方自己说。
fun relativeText(moment: Long): String {
    val elapsed = elapsedSeconds(moment)
    return when {
        elapsed < 60 -> "刚刚"
        elapsed < 3600 -> "${elapsed / 60} 分钟前"
        elapsed < 86400 -> "${elapsed / 3600} 小时前"
        else -> "${elapsed / 86400} 天前"
    }
}

/// 时钟回拨或车端时间略微超前时会算出负数，一律当作 0，别说出「-2 分钟前」。
private fun elapsedSeconds(moment: Long): Int =
    maxOf(0, ((System.currentTimeMillis() - moment) / 1000).toInt())
