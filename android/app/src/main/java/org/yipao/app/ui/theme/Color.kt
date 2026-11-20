package org.yipao.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp

// 品牌色和 iOS 端 LeapStyle 同源：accent 绿、cool 蓝、warm 橙、caution 琥珀。
// 明暗各一套，浅色版压暗保对比度，深色版提亮，数值直接从 LeapStyle.swift 换算。

val LeapGreenLight = Color(0xFF08703D)
val LeapGreenDark = Color(0xFF4DC47D)
val LeapCoolLight = Color(0xFF215CC7)
val LeapCoolDark = Color(0xFF6BA8FF)
val LeapWarmLight = Color(0xFFB84708)
val LeapWarmDark = Color(0xFFFF8C59)
val LeapCautionLight = Color(0xFF9E5C00)
val LeapCautionDark = Color(0xFFFFD18A)
// frost 是除霜专用的冰蓝/深青，也是功能中心、锁屏控车、驻车照片这几页的背景色。
// 色相跟 cool 岔开但饱和度相当，混在一堆蓝里不会被当成「同一页」。
val LeapFrostLight = Color(0xFF056B7A)
val LeapFrostDark = Color(0xFF5CDBE6)

// 氛围背景底层渐变，色标照抄 iOS LeapBackground：浅色冷蓝灰、深色近黑。
// 光晕层（顶部/右下/左下）画在 Common.kt 的 drawAmbientBackground 里。
private val AmbientLight = listOf(Color(0xFFF2F5FA), Color(0xFFE0E8F2), Color(0xFFC7D4E6))
private val AmbientDark = listOf(Color(0xFF171717), Color(0xFF0A0A0A), Color(0xFF000000))

/// 当前主题下的语义色，屏幕代码统一从这里取，不直接写死。
object LeapColors {
    val accent: Color @Composable get() = MaterialTheme.colorScheme.primary
    val cool: Color @Composable get() = MaterialTheme.colorScheme.secondary
    val warm: Color @Composable get() = MaterialTheme.colorScheme.tertiary

    val isDark: Boolean
        @Composable get() = MaterialTheme.colorScheme.surface.perceivedLuminance() < 0.5f

    /// 「反常但不到报错」的琥珀色：车没锁、尾门开着。M3 配色方案没有这个槽位，单独给。
    val caution: Color
        @Composable get() = if (isDark) LeapCautionDark else LeapCautionLight

    /// 除霜和「跟车辆本体无关的设置类页面」用的冰蓝。M3 配色方案同样没有这个槽位。
    val frost: Color
        @Composable get() = if (isDark) LeapFrostDark else LeapFrostLight

    /// 氛围渐变背景的色标，从页面顶到底。
    val ambient: List<Color> @Composable get() = if (isDark) AmbientDark else AmbientLight

    /// 把任意品牌色换算成光晕色，规则同 iOS：深色直接用原色，浅色往白里掺 32% 提亮。
    /// 页面想让背景跟着自己的主色走时（比如登录页给绿），就走这里。
    @Composable
    fun glowOf(tint: Color): Color = if (isDark) tint else lerp(tint, Color.White, 0.32f)

    /// 顶部光晕色。iOS 随车况变色，演示态固定 cool；浅色往白里掺 32% 提亮。
    val glowTop: Color
        @Composable get() = glowOf(if (isDark) LeapCoolDark else LeapCoolLight)

    /// 右下角冷色光晕，同 iOS。
    val glowCorner: Color
        @Composable get() = if (isDark) LeapCoolDark else lerp(LeapCoolLight, Color.White, 0.32f)

    /// 浅色专属的左下绿色补光（iOS accent mix white 0.45）。
    val glowFill: Color
        @Composable get() = lerp(LeapGreenLight, Color.White, 0.45f)

    /// 卡片玻璃的面罩色，也是低版本的回落底色。方向抄鸿蒙（已过对比度校验）：
    /// 浅色比背景亮（白 60%），深色比背景暗，别再往深色里叠白。
    /// 深色从 50% 放到 35%：50% 的黑几乎不透背景，输入框和卡片都成了实心黑块，
    /// 跟 iOS 那层能看见底下光晕的材质差得远。35% 是「透得出光晕、又还看得见边界」的落点。
    val card: Color @Composable get() = if (isDark) Color(0x59000000) else Color(0x99FFFFFF)

    /// 禁用按钮退掉颜色后的底。不能直接用 [card]：深色的 card 是半黑，
    /// 压在近黑背景上等于按钮整个消失，用户不知道那里还有个按钮。
    val buttonDisabled: Color @Composable get() = if (isDark) Color(0x1FFFFFFF) else Color(0x99FFFFFF)

    /// 玻璃卡回落路径的细描边，数值 iOS/鸿蒙一致：浅色黑 9%、深色白 16%。
    val glassEdge: Color @Composable get() = if (isDark) Color(0x29FFFFFF) else Color(0x17000000)

    /// 悬浮导航胶囊的基色，交给 haze 的毛玻璃材质当 tint 用（材质自己控制透明度）。
    val bar: Color @Composable get() = if (isDark) Color(0xFF1B2130) else Color(0xFFFBFCFF)

    /// 锚点弹层的材质基色。不能拿 bar：那是给 haze 材质当 tint 的不透明色，
    /// 直接盖在玻璃上等于把折射和高光全糊死，弹层就成了一块白板。
    /// 这里留出透明度让背景透上来，又实到文字读得清。两端都是 60%——
    /// 试过 84%，肉眼跟纯白板没区别，得压到 60% 折射才看得出来。
    val overlay: Color @Composable get() = if (isDark) Color(0x991B2130) else Color(0x99FFFFFF)

    /// iOS 开关关闭态的轨道色（systemGray5 的深浅两档）。
    val switchTrackOff: Color @Composable get() = if (isDark) Color(0xFF3A3A3C) else Color(0xFFE5E5EA)
}

private fun Color.perceivedLuminance(): Float = (red * 0.299f + green * 0.587f + blue * 0.114f)
