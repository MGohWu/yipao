package org.yipao.app.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.theme.LeapColors
import kotlin.math.roundToInt

/// iOS 26 的滑杆。M3 新版滑杆是粗轨道 + 一排刻度点 + 方头 thumb，
/// 跟这套界面里所有别的控件（圆钮开关、胶囊按钮）都不是一个语言。
/// 这里换成 iOS 的做法：细轨道、圆白钮、没有刻度点。
///
/// 刻度点砍掉不等于砍掉吸附——`step` 照样把值对齐到整档，
/// 只是不把档位画出来。iOS 的逻辑是「手感上能感觉到咯噔一下」就够了。

/// 轨道高度和圆钮直径，照 iOS 的比例。
private val TrackHeight = 4.dp
private val ThumbSize = 24.dp

@Composable
fun LiquidSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
    /// 手指抬起时回调一次。拖动过程中每帧都发指令没意义，落定了再发。
    onValueChangeFinished: (() -> Unit)? = null,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
    /// 吸附粒度。0 表示连续，不吸附。
    step: Float = 0f,
    tint: Color = LeapColors.accent,
) {
    val currentChange by rememberUpdatedState(onValueChange)
    val currentFinished by rememberUpdatedState(onValueChangeFinished)
    var pressed by remember { mutableStateOf(false) }
    // 按下时圆钮放大一点。iOS 靠这个告诉人「抓住了」——没有它，手指压着的地方
    // 完全被指头挡住，看不出控件有没有响应。
    val thumbScale by animateFloatAsState(
        targetValue = if (pressed) 1.15f else 1f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow),
        label = "thumbScale",
    )

    val span = (valueRange.endInclusive - valueRange.start).takeIf { it > 0f } ?: 1f
    val fraction = ((value - valueRange.start) / span).coerceIn(0f, 1f)

    BoxWithConstraints(modifier = modifier.fillMaxWidth().height(ThumbSize)) {
        val density = LocalDensity.current
        val thumbPx = with(density) { ThumbSize.toPx() }
        val widthPx = with(density) { maxWidth.toPx() }
        // 圆钮中心的可走范围：两端各让出半个钮，否则钮会探出轨道外。
        val travel = (widthPx - thumbPx).coerceAtLeast(1f)

        val report: (Float) -> Unit = { x ->
            val raw = ((x - thumbPx / 2f) / travel).coerceIn(0f, 1f)
            var next = valueRange.start + raw * span
            if (step > 0f) {
                // 对齐要以 start 为基准，不是以 0——量程 50..100、步长 5 的时候
                // 从 0 起算会把 52 吸到 50 没错，但量程 3..7 就会吸到 5 之外去。
                next = valueRange.start + ((next - valueRange.start) / step).roundToInt() * step
            }
            currentChange(next.coerceIn(valueRange.start, valueRange.endInclusive))
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(ThumbSize)
                .pointerInput(valueRange, step, travel) {
                    awaitEachGesture {
                        // 按下就跳过去，跟 iOS 一致：轨道上任意位置点一下即定位。
                        val down = awaitFirstDown(requireUnconsumed = false)
                        pressed = true
                        report(down.position.x)
                        drag(down.id) { change ->
                            report(change.position.x)
                            change.consume()
                        }
                        pressed = false
                        currentFinished?.invoke()
                    }
                },
        ) {
            // 轨道底：已走过的那段上色，剩下的用开关关闭态那个灰，全 App 一套灰。
            Box(
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .fillMaxWidth()
                    .height(TrackHeight)
                    .clip(CircleShape)
                    .background(LeapColors.switchTrackOff),
            )
            if (fraction > 0f) {
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .fillMaxWidth(fraction)
                        .height(TrackHeight)
                        .clip(CircleShape)
                        .background(tint),
                )
            }
            // 圆钮。白色 + 轻阴影，深浅两个主题都一样——iOS 的 slider 钮不跟着主题变色。
            Box(
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .offset { IntOffset((fraction * travel).roundToInt(), 0) }
                    .graphicsLayer {
                        scaleX = thumbScale
                        scaleY = thumbScale
                    }
                    .size(ThumbSize)
                    .shadow(3.dp, CircleShape)
                    .background(Color.White, CircleShape),
            )
        }
    }
}
