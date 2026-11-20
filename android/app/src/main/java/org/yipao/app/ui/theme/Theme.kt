package org.yipao.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/// 深浅外观三态，对应设置页里的分段选择。
enum class AppearanceMode(val label: String) {
    System("跟随系统"),
    Light("浅色"),
    Dark("深色"),
}

private val LightScheme = lightColorScheme(
    primary = LeapGreenLight,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFA5F2C4),
    onPrimaryContainer = Color(0xFF00210F),
    secondary = LeapCoolLight,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFD9E2FF),
    onSecondaryContainer = Color(0xFF001947),
    tertiary = LeapWarmLight,
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFDBCB),
    onTertiaryContainer = Color(0xFF380D00),
    background = Color(0xFFF5FAF3),
    onBackground = Color(0xFF171D18),
    surface = Color(0xFFF5FAF3),
    onSurface = Color(0xFF171D18),
    surfaceVariant = Color(0xFFDCE5DB),
    onSurfaceVariant = Color(0xFF404943),
    outline = Color(0xFF707973),
    outlineVariant = Color(0xFFC0C9C0),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFEFF5EE),
    surfaceContainer = Color(0xFFE9EFE8),
    surfaceContainerHigh = Color(0xFFE3EAE2),
    surfaceContainerHighest = Color(0xFFDEE4DC),
)

private val DarkScheme = darkColorScheme(
    primary = LeapGreenDark,
    onPrimary = Color(0xFF00391C),
    primaryContainer = Color(0xFF00522B),
    onPrimaryContainer = Color(0xFFA5F2C4),
    secondary = LeapCoolDark,
    onSecondary = Color(0xFF002C72),
    secondaryContainer = Color(0xFF00419E),
    onSecondaryContainer = Color(0xFFD9E2FF),
    tertiary = LeapWarmDark,
    onTertiary = Color(0xFF571F00),
    tertiaryContainer = Color(0xFF7B2F00),
    onTertiaryContainer = Color(0xFFFFDBCB),
    background = Color(0xFF0F1511),
    onBackground = Color(0xFFDEE4DC),
    surface = Color(0xFF0F1511),
    onSurface = Color(0xFFDEE4DC),
    surfaceVariant = Color(0xFF404943),
    onSurfaceVariant = Color(0xFFC0C9C0),
    outline = Color(0xFF8A938B),
    outlineVariant = Color(0xFF404943),
    surfaceContainerLowest = Color(0xFF0A0F0B),
    surfaceContainerLow = Color(0xFF171D18),
    surfaceContainer = Color(0xFF1B211C),
    surfaceContainerHigh = Color(0xFF252B26),
    surfaceContainerHighest = Color(0xFF303631),
)

/// Material 3 Expressive 主题。固定走品牌配色。
///
/// **不提供动态取色（Material You）**：这套界面拿配色槽位当语义色用——`LeapColors.cool`
/// 就是 `secondary`，空调开启、哨兵开启、空调页档位选中全靠它「亮起来」。跟壁纸取色之后
/// `secondary` 会被换成一个低饱和的灰调，开启态比关闭态还暗，等于把状态反馈整个抹掉。
/// 换句话说这里的颜色不只是好不好看的问题，它得承担「开着还是关着」这句话。
@Composable
fun LeapTheme(
    appearance: AppearanceMode = AppearanceMode.System,
    content: @Composable () -> Unit,
) {
    val dark = when (appearance) {
        AppearanceMode.System -> isSystemInDarkTheme()
        AppearanceMode.Light -> false
        AppearanceMode.Dark -> true
    }
    val colorScheme = if (dark) DarkScheme else LightScheme

    // material3 1.4.0 正式版把 MaterialExpressiveTheme/MotionScheme 收回成 internal，
    // 这里走公开的 MaterialTheme；Expressive 观感由页面层的大圆角与 tonal 配色承担。
    MaterialTheme(
        colorScheme = colorScheme,
        content = content,
    )
}
