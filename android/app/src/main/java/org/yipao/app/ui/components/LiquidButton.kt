package org.yipao.app.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.theme.LeapColors

/// iOS 26 的按钮。跟 M3 Button 的差别不只是圆角：
/// M3 按下是从触点扩散的涟漪 + 抬起阴影，iOS 是整块按钮轻微缩一下、颜色压暗一点。
/// 涟漪那套在这种半透明玻璃界面上会拖出一圈脏色，所以整套关掉自己做。
///
/// 四种：`LiquidButton` 实心胶囊（主动作）、`LiquidGlassButton` 玻璃胶囊（并列的次要动作）、
/// `LiquidTonalButton` 淡色底（次要动作）、`LiquidTextButton` 纯文字（第三级）。

/// 按下时缩到多小。iOS 大约 0.97，再小就显得按钮在弹跳。
private const val PressedScale = 0.97f

/// 彩色底上的文字/图标色。不能一律白——深色主题的 accent 是亮绿，
/// 白字压上去几乎糊在一起；亮底就得换回近黑的字。勾选框也用它。
internal fun Color.readableContent(): Color =
    if (red * 0.299f + green * 0.587f + blue * 0.114f > 0.62f) Color(0xFF10151C) else Color.White

@Composable
fun LiquidButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = LeapColors.accent,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    height: Dp = 50.dp,
    textStyle: TextStyle = MaterialTheme.typography.titleSmall,
) {
    LiquidButtonSurface(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        height = height,
        container = tint,
        content = tint.readableContent(),
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp))
        }
        Text(text = text, style = textStyle, fontWeight = FontWeight.SemiBold)
    }
}

/// 玻璃胶囊：透背景的玻璃底 + 主题色文字，对应 iOS 的 `.buttonStyle(.glass)`。
/// 跟 [LiquidTonalButton] 的差别是它没有自己的色底——底下透出来的是页面氛围光，
/// 所以摆在实心主按钮旁边不会抢，摆在输入框下面又跟输入框是同一种材质。
@Composable
fun LiquidGlassButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = LeapColors.accent,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    height: Dp = 46.dp,
    textStyle: TextStyle = MaterialTheme.typography.titleSmall,
) {
    LiquidButtonSurface(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        height = height,
        container = LeapColors.card,
        content = tint,
        glass = true,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp))
        }
        Text(text = text, style = textStyle, fontWeight = FontWeight.Medium)
    }
}

/// 次要动作：同色系的淡底 + 彩色文字。iOS 里的 `.borderedProminent` 对应
/// 主动作，这个对应 `.bordered`——存在感低一档，但还是个能看见的按钮。
@Composable
fun LiquidTonalButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = LeapColors.accent,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    height: Dp = 46.dp,
    textStyle: TextStyle = MaterialTheme.typography.titleSmall,
) {
    LiquidButtonSurface(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        height = height,
        container = tint.copy(alpha = 0.14f),
        content = tint,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp))
        }
        Text(text = text, style = textStyle, fontWeight = FontWeight.Medium)
    }
}

/// 纯文字按钮。没有底、没有涟漪，按下只是变淡——iOS 的第三级动作就长这样。
/// 内边距比 M3 的 TextButton 小：那套 12dp 横向内边距是给涟漪留的显示区域，
/// 这里没有涟漪，留着只会让「没有账号？试试演示模式」这类文字莫名离得很远。
@Composable
fun LiquidTextButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    color: Color = LeapColors.accent,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    textStyle: TextStyle = MaterialTheme.typography.labelLarge,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val alpha by animateFloatAsState(
        targetValue = if (!enabled) 0.35f else if (pressed) 0.45f else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessHigh),
        label = "textButtonAlpha",
    )
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier
            .clip(CircleShape)
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            )
            .padding(horizontal = 8.dp, vertical = 6.dp)
            .graphicsLayer { this.alpha = alpha },
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(16.dp))
        }
        Text(text = text, style = textStyle, color = color)
    }
}

/// 圆形图标按钮。M3 的 IconButton 自带涟漪，还会在圆之外留一圈 48dp 的触摸padding，
/// 排版时经常莫名把旁边的东西顶开。这个只画一个圆，触摸区就是它自己。
///
/// 有底色的按下缩一下（像个实体按钮），没底色的按下淡一下（只是个图标）。
@Composable
fun LiquidIconButton(
    icon: ImageVector,
    contentDescription: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 40.dp,
    iconSize: Dp = 18.dp,
    container: Color = Color.Transparent,
    tint: Color = LeapColors.accent,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .pressable(
                onClick = onClick,
                shape = CircleShape,
                feedback = if (container == Color.Transparent) PressFeedback.Fade else PressFeedback.Scale,
            )
            .size(size)
            .background(container, CircleShape),
    ) {
        Icon(icon, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(iconSize))
    }
}

/// 四种按钮共用的底：胶囊、按下缩一下、禁用去色。
@Composable
private fun LiquidButtonSurface(
    onClick: () -> Unit,
    modifier: Modifier,
    enabled: Boolean,
    height: Dp,
    container: Color,
    content: Color,
    /// 底走玻璃（折射背景 + 高光描边）而不是一块纯色。
    glass: Boolean = false,
    label: @Composable RowScope.() -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled) PressedScale else 1f,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMedium),
        label = "buttonScale",
    )
    // 禁用要去色。以前只压透明度保留原色底，在深色背景上一个 38% 的绿胶囊反而比周围
    // 任何东西都亮，看着像「主按钮还等着你按」。iOS 的禁用态是整块退成中性玻璃，
    // 颜色是「能不能按」的信号，不该在禁用时还留着。
    val bg by animateColorAsState(
        targetValue = if (enabled) container else if (glass) container else LeapColors.buttonDisabled,
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "buttonContainer",
    )
    val fg by animateColorAsState(
        targetValue = if (enabled) content else MaterialTheme.colorScheme.outline,
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "buttonContent",
    )
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        modifier = modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .height(height)
            .then(
                if (glass || !enabled) {
                    Modifier.liquidGlass(CircleShape, bg)
                } else {
                    Modifier.clip(CircleShape).background(bg)
                },
            )
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            )
            .padding(horizontal = 20.dp),
    ) {
        CompositionLocalProvider(LocalContentColor provides fg) {
            label()
        }
    }
}
