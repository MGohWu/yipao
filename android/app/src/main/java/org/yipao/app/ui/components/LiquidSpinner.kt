package org.yipao.app.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.theme.LeapColors
import kotlin.math.cos
import kotlin.math.sin

/// iOS 的转圈：一圈辐条依次点亮再暗下去，整体不动。
/// M3 那个是一段圆弧绕着转、长度还忽长忽短，动得比 iOS 躁。
///
/// 辐条数取 12——8 条能看出是在一格一格跳，16 条又糊成一个匀速的环。
private const val SpokeCount = 12

@Composable
fun LiquidSpinner(
    modifier: Modifier = Modifier,
    size: Dp = 28.dp,
    color: Color = LeapColors.cool,
) {
    val transition = rememberInfiniteTransition(label = "spinner")
    // 一圈一秒，走整数格：动画值直接就是「最亮的是第几条」，
    // 落在格子中间的话相邻两条会同亮，看着是两个头在转。
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = SpokeCount.toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "spinnerPhase",
    )
    Canvas(modifier = modifier.size(size)) {
        val radius = this.size.minDimension / 2f
        val strokeWidth = radius * 0.24f
        // 辐条从中心 45% 处起，到边上留一点余量，跟 iOS 的比例接近。
        val inner = radius * 0.45f
        val outer = radius - strokeWidth / 2f
        val center = Offset(this.size.width / 2f, this.size.height / 2f)
        val head = phase.toInt()
        repeat(SpokeCount) { index ->
            // 离「头」越远越淡。绕回去要走模运算，否则第 0 条和第 11 条中间会有个断层。
            val distance = ((index - head) + SpokeCount) % SpokeCount
            val alpha = 1f - distance / SpokeCount.toFloat() * 0.85f
            // 12 点方向是第 0 条，所以起始角减 90°。
            val angle = (index.toFloat() / SpokeCount) * 2f * Math.PI.toFloat() - Math.PI.toFloat() / 2f
            val dx = cos(angle)
            val dy = sin(angle)
            drawLine(
                color = color.copy(alpha = alpha),
                start = center + Offset(dx * inner, dy * inner),
                end = center + Offset(dx * outer, dy * outer),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round,
            )
        }
    }
}
