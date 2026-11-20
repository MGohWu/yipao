package org.yipao.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.theme.LeapColors

/// 发丝分隔线。M3 的 HorizontalDivider 用 outlineVariant，在玻璃卡上偏重，
/// 一排下来像是画了格子；iOS 的分隔线只是「两行之间有一点点断开」的暗示。
///
/// 厚度 0.7dp 而不是 0.5dp：0.5dp 在 2x 屏上不足一个物理像素，Skia 会按覆盖率
/// 把它画得忽隐忽现，一条线上深浅不匀。0.7 刚好稳定落在 1~2 像素上。
private val HairlineThickness = 0.7.dp

/// 横向发丝线。startIndent 是左侧缩进——列表行之间的分隔线要跟文字左对齐，
/// 不能顶到卡片边上，那样看着像把卡片切成了两半。
@Composable
fun HairlineDivider(modifier: Modifier = Modifier, startIndent: Dp = 0.dp) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = startIndent)
            .height(HairlineThickness)
            .background(LeapColors.glassEdge),
    )
}

/// 竖向发丝线，用来隔开并排的数据列。
@Composable
fun VerticalHairline(height: Dp, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .width(HairlineThickness)
            .height(height)
            .background(LeapColors.glassEdge),
    )
}
