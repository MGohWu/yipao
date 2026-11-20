package org.yipao.app.widget

import androidx.compose.ui.graphics.Color
import androidx.glance.color.ColorProvider
import org.yipao.app.ui.theme.LeapCautionDark
import org.yipao.app.ui.theme.LeapCautionLight
import org.yipao.app.ui.theme.LeapCoolDark
import org.yipao.app.ui.theme.LeapCoolLight
import org.yipao.app.ui.theme.LeapGreenDark
import org.yipao.app.ui.theme.LeapGreenLight
import org.yipao.app.ui.theme.LeapWarmDark
import org.yipao.app.ui.theme.LeapWarmLight

/// 卡片和磁贴的配色。
///
/// 不能直接用 `LeapColors`：那一套全是 `@Composable` 取值，要从 `MaterialTheme` 里读，
/// 而 Glance 的组合树里没有 MaterialTheme。品牌色本身（`LeapGreenLight` 那几个常量）
/// 是普通 val，可以直接引，所以这里只是把它们重新包成 Glance 的明暗二元色。
///
/// 也没走 `GlanceTheme` 的动态取色：桌面壁纸取出来的色和车况语义（绿=电量、
/// 琥珀=没锁）没有关系，能量条被染成随机色反而看不懂。
object WidgetPalette {

    /// 卡片底。深色比 App 内背景略亮一点——桌面壁纸多半是深的，纯黑卡会糊在一起。
    ///
    /// 锁车卡另有一层随状态变色的渐变卡底，那个画不进 Glance（没有 Brush），
    /// 做成了 `drawable/widget_lock_bg_*.xml`，取色在 `values/colors.xml`——
    /// 那两处和这里同源，改一处记得改另一处。
    val background = ColorProvider(day = Color(0xFFFBFCFF), night = Color(0xFF1B2130))

    val primaryText = ColorProvider(day = Color(0xFF11161F), night = Color(0xFFF2F5FA))
    val secondaryText = ColorProvider(day = Color(0x9911161F), night = Color(0x99F2F5FA))

    /// 能量条前面那两个小图标（闪电 / 油滴）。比次要文字再淡一档——
    /// 它们只是标注哪条是电哪条是油，不该跟数字抢。
    val tertiaryText = ColorProvider(day = Color(0x6111161F), night = Color(0x61F2F5FA))

    val accent = ColorProvider(day = LeapGreenLight, night = LeapGreenDark)
    val cool = ColorProvider(day = LeapCoolLight, night = LeapCoolDark)
    val warm = ColorProvider(day = LeapWarmLight, night = LeapWarmDark)
    val caution = ColorProvider(day = LeapCautionLight, night = LeapCautionDark)

    /// 没在充电时的电量条、以及油量条。
    ///
    /// 对齐 iOS `SnapshotEnergyBars`：两条都是同一族绿，只靠深浅区分「正在充」和
    /// 「就这么多」。油量条曾经是橙的，和「胎压异常」那类警示色撞在一起——
    /// 油还剩多少不是一件需要警示的事。
    val accentSoft = ColorProvider(
        day = LeapGreenLight.copy(alpha = 0.85f),
        night = LeapGreenDark.copy(alpha = 0.85f),
    )

    /// 铺在 accent / caution 实色徽标上的图标色。两种底色都够深，白色在明暗下都读得清。
    val onAccent = ColorProvider(day = Color(0xFFFFFFFF), night = Color(0xFFFFFFFF))

    /// 能量条的槽。
    val track = ColorProvider(day = Color(0x1A11161F), night = Color(0x24FFFFFF))

    /// 刷新键那种没有语义色的底。比 track 再浅一档，免得没按下的按钮看着像进度条。
    val button = ColorProvider(day = Color(0x0F11161F), night = Color(0x1AFFFFFF))

    /// 「我不知道」那一档的中性色。锁状态读不到时用它——
    /// 绿色和琥珀在卡片上都是断言，灰色才是不做断言。
    val neutral = ColorProvider(day = Color(0xFF6B7280), night = Color(0xFF9AA3B2))

    /// 控车按钮的底色。对齐 iOS `ActionTile`：着重的那颗底色深一档（0.20），
    /// 其余淡底（0.10）。深色下各加两个点——同样的透明度铺在深卡底上会淡到看不见边界。
    fun tileFill(tint: WidgetTint, prominent: Boolean) = ColorProvider(
        day = tint.day.copy(alpha = if (prominent) 0.20f else 0.10f),
        night = tint.night.copy(alpha = if (prominent) 0.22f else 0.12f),
    )

    /// 控车按钮的图标和文字色。着重时用语义色本身，其余用次要文字色——
    /// 一颗淡底灰字的按钮才不会去和「空调开着」那种真状态抢注意力。
    fun tileForeground(tint: WidgetTint, prominent: Boolean): androidx.glance.unit.ColorProvider =
        if (prominent) ColorProvider(day = tint.day, night = tint.night) else secondaryText
}

/// 控车按钮的语义色。存的是明暗两个原色，透明度由 [WidgetPalette.tileFill] 现算——
/// 同一个 tint 要出「着重底 / 淡底 / 前景」三种色，预先包成 ColorProvider 就取不出原色了。
enum class WidgetTint(internal val day: Color, internal val night: Color) {
    Accent(LeapGreenLight, LeapGreenDark),
    Cool(LeapCoolLight, LeapCoolDark),
    Warm(LeapWarmLight, LeapWarmDark),
    Caution(LeapCautionLight, LeapCautionDark),
    Neutral(Color(0xFF6B7280), Color(0xFF9AA3B2)),
}
