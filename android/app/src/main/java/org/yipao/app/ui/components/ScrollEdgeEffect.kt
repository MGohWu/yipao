package org.yipao.app.ui.components

import android.os.Build
import androidx.compose.animation.core.EaseIn
import androidx.compose.animation.core.EaseOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.HazeProgressive
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeEffect

/// iOS 26 的 scroll edge effect：屏幕上下边缘各铺一条渐变模糊带，
/// 内容滚进去时先渐渐糊掉再被状态栏/悬浮 tab 条盖住，而不是硬生生穿帮。
///
/// kyant backdrop 的 blur() 是均匀模糊，做不出「越靠边越糊」的梯度；
/// 这里用 haze 的 HazeProgressive.verticalGradient，它在 API 33+ 走 RuntimeShader，
/// 逐像素算可变半径高斯，不是「清晰图和模糊图按 alpha 对混」。
/// API < 33 没有 RuntimeShader，回落成整条均匀模糊反而更难看，索性整条不画。
///
/// 想让带子看不出边，两件事都得做到：
/// 1. 取样源必须不透明（见 MainScaffold 里补背景那段），否则模糊图叠回去等于内容画两遍；
/// 2. 强度曲线在「清晰」那一端斜率要收到 0——线性曲线是匀速降到 0 后戛然而止，
///    半径的一阶不连续在眼里就是一条线。顶部走 EaseOut、底部走 EaseIn 才是软着陆。
private val EdgeEffectAvailable = Build.VERSION.SDK_INT >= 33

/// 顶部渐变模糊带：状态栏区最糊，往下渐隐到完全清晰。
@Composable
fun BoxScope.TopScrollEdgeEffect(
    hazeState: HazeState,
    extra: Dp = 28.dp,
    blurRadius: Dp = 24.dp,
) {
    if (!EdgeEffectAvailable) return
    val statusBars = WindowInsets.statusBars.asPaddingValues()
    Box(
        modifier = Modifier
            .align(Alignment.TopCenter)
            .fillMaxWidth()
            .height(statusBars.calculateTopPadding() + extra)
            .hazeEffect(state = hazeState) {
                this.blurRadius = blurRadius
                noiseFactor = 0f
                tints = emptyList()
                backgroundColor = Color.Transparent
                // 上边缘满强度 → 下边缘归零，末端斜率收到 0，接清晰内容那一刀看不出来。
                progressive = HazeProgressive.verticalGradient(
                    easing = EaseOut,
                    startIntensity = 1f,
                    endIntensity = 0f,
                )
            },
    )
}

/// 底部渐变模糊带：盖住悬浮 tab 条那一片，往上渐隐到完全清晰。
/// 高度要把 tab 条（64dp）连同它的 14dp 悬浮间距和导航栏安全区一起罩住，
/// 否则内容会在带子上沿被切一刀。
///
/// 只罩住胶囊那一片就够了。原来带高 102dp、半径 24dp，静止时糊掉的面积
/// 差不多是胶囊的两倍高，最下面那排卡片整个读不出字来——滚动时的柔和过渡
/// 是次要的，页面停着时看到的一大片脏才是用户真正在看的东西。
///
/// 半径后来又从 12dp 收到 8dp：这条带子的活儿只是让内容滚到胶囊底下时别硬穿帮，
/// 不是真要把下面那片内容糊掉。顶部那条不动——状态栏那边本来就该看不清。
@Composable
fun BoxScope.BottomScrollEdgeEffect(
    hazeState: HazeState,
    extra: Dp = 78.dp,
    blurRadius: Dp = 8.dp,
) {
    if (!EdgeEffectAvailable) return
    val navigationBars = WindowInsets.navigationBars.asPaddingValues()
    Box(
        modifier = Modifier
            .align(Alignment.BottomCenter)
            .fillMaxWidth()
            .height(navigationBars.calculateBottomPadding() + extra)
            .hazeEffect(state = hazeState) {
                this.blurRadius = blurRadius
                noiseFactor = 0f
                tints = emptyList()
                backgroundColor = Color.Transparent
                // 起点斜率为 0，从清晰内容里慢慢长出来，不在带子上沿切一刀。
                progressive = HazeProgressive.verticalGradient(
                    easing = EaseIn,
                    startIntensity = 0f,
                    endIntensity = 1f,
                )
            },
    )
}
