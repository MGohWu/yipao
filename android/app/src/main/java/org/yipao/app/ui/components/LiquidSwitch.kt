package org.yipao.app.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.theme.LeapColors

/// iOS 26 同款开关：51×31 的胶囊轨道 + 27 的白色圆钮，弹簧滑动。
/// M3 那颗开关的选中态图标、外描边和拇指变形跟这套界面的其余部分完全不搭，
/// 这里整体换掉；关闭态轨道压得比 M3 更淡，靠近 iOS 的 systemGray5。
///
/// onCheckedChange 传 null 表示只读展示（对应 M3 的 enabled = false 用法）。
@Composable
fun LiquidSwitch(
    checked: Boolean,
    onCheckedChange: ((Boolean) -> Unit)?,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val trackColor by animateColorAsState(
        targetValue = if (checked) LeapColors.accent else LeapColors.switchTrackOff,
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "switchTrack",
    )
    // 轨道 51 - 圆钮 27 - 左右各 2 的内边距 = 20 的行程。
    val thumbOffset by animateDpAsState(
        targetValue = if (checked) 20.dp else 0.dp,
        animationSpec = spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessMediumLow),
        label = "switchThumb",
    )

    val interactive = enabled && onCheckedChange != null
    Box(
        contentAlignment = Alignment.CenterStart,
        modifier = modifier
            .size(width = 51.dp, height = 31.dp)
            .background(trackColor.copy(alpha = if (interactive) 1f else 0.5f), CircleShape)
            .then(
                if (interactive) {
                    Modifier.toggleable(
                        value = checked,
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        role = Role.Switch,
                        onValueChange = { onCheckedChange?.invoke(it) },
                    )
                } else {
                    Modifier
                }
            )
            .padding(horizontal = 2.dp),
    ) {
        Box(
            modifier = Modifier
                .offset(x = thumbOffset)
                .size(27.dp)
                .shadow(2.dp, CircleShape)
                .background(Color.White, CircleShape),
        )
    }
}
