package org.yipao.app.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role

/// 点击区的按压反馈。M3 的涟漪是从触点扩散的一圈水波，在半透明玻璃上会拖出脏色，
/// 而且它的语言跟这套界面里所有别的东西都不一样。iOS 不用涟漪：
/// 一块能按的东西按下去要么整块缩一下，要么整块淡一下。
///
/// 光把涟漪删掉不补反馈是不行的——点下去屏幕上什么都不动，看着像没响应。

/// 按下缩到多小。跟 [LiquidButton] 用同一个值，全 App 一个手感。
private const val PressedScale = 0.97f

/// 按下淡到多透。再低就像整块被禁用了。
private const val PressedAlpha = 0.55f

enum class PressFeedback {
    /// 缩一下。给有自己底的整块：卡片、瓦片、胶囊。
    Scale,

    /// 淡一下。给没有自己底、只是一行内容的：列表行、图标、纯文字。
    /// 这类东西缩放会带着周围的留白一起动，看着像整页在抖。
    Fade,
}

/// 无涟漪的点击区。
///
/// **要放在背景之前**——`Modifier.pressable(...).liquidGlass(...)` 而不是反过来。
/// graphicsLayer 只对它后面的绘制生效，放在背景后面的话缩放的只有内容，
/// 底板一动不动，看着像卡片里的字自己在缩。
@Composable
fun Modifier.pressable(
    onClick: () -> Unit,
    enabled: Boolean = true,
    /// 传了就顺手 clip 一下，省得调用方再写一遍。
    shape: Shape? = null,
    feedback: PressFeedback = PressFeedback.Scale,
    role: Role = Role.Button,
): Modifier {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val active = pressed && enabled
    val scale by animateFloatAsState(
        targetValue = if (active && feedback == PressFeedback.Scale) PressedScale else 1f,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMedium),
        label = "pressScale",
    )
    val dim by animateFloatAsState(
        targetValue = if (active && feedback == PressFeedback.Fade) PressedAlpha else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessHigh),
        label = "pressAlpha",
    )
    return this
        .graphicsLayer {
            scaleX = scale
            scaleY = scale
            alpha = dim
        }
        .let { if (shape != null) it.clip(shape) else it }
        .clickable(
            interactionSource = interaction,
            indication = null,
            enabled = enabled,
            role = role,
            onClick = onClick,
        )
}
