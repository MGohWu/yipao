package org.yipao.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.theme.LeapColors

/// iOS 26 的底部弹层。
///
/// 为什么不是 ModalBottomSheet：它自己开一个 window，kyant 的 layerBackdrop
/// 只录得到主 window，玻璃折射出来是一片空白，底板只能退化成描边样式。
/// 这里跟锚点弹层走同一条路——内容传送到 OverlayHost，跟页面同一个 window，
/// liquidGlass 照常工作。暗幕、点空白收起、返回键收起都是宿主给的，这边不用管。
///
/// 用法跟 AnchoredOverlayBox 一样是常驻声明、拿 visible 控制显隐，
/// 不能写成 `if (show) GlassBottomSheet {}`——那样一收起组件就没了，退场动画来不及播。

/// 弹层圆角。四角都圆，因为它是悬浮卡不是贴底面板。
private val SheetShape = RoundedCornerShape(28.dp)

@Composable
fun GlassBottomSheet(
    visible: Boolean,
    onDismissRequest: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val host = LocalOverlayHost.current ?: return
    val currentVisible by rememberUpdatedState(visible)
    val currentDismiss by rememberUpdatedState(onDismissRequest)
    val currentContent by rememberUpdatedState(content)

    DisposableEffect(host) {
        val entry = OverlayEntry(
            anchorBounds = { null },
            visible = { currentVisible },
            onDismissRequest = { currentDismiss() },
            placement = OverlayPlacement.BottomSheet,
            content = { GlassSheetSurface { currentContent() } },
        )
        host.entries.add(entry)
        onDispose { host.entries.remove(entry) }
    }
}

/// 弹层的玻璃底板：左右留边、离屏幕底边也留一截，跟悬浮 tab 条同一套语言。
/// 折射内容取景层而不是背景层，底下压着什么才看得见——跟锚点弹层同一个道理。
@Composable
private fun GlassSheetSurface(content: @Composable ColumnScope.() -> Unit) {
    val backdrop = LocalContentBackdrop.current ?: LocalBackgroundBackdrop.current
    val navigationBars = WindowInsets.navigationBars.asPaddingValues()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .padding(bottom = navigationBars.calculateBottomPadding() + 12.dp)
            .shadow(28.dp, SheetShape, clip = false)
            .liquidGlass(
                shape = SheetShape,
                surface = LeapColors.overlay,
                backdrop = backdrop,
                blurRadius = 20.dp,
            )
            .clip(SheetShape),
    ) {
        // 抓手。手势本身整片弹层都能拖，这条只是告诉人「可以往下拽」。
        Box(
            modifier = Modifier
                .align(Alignment.CenterHorizontally)
                .padding(top = 10.dp, bottom = 4.dp)
                .size(width = 36.dp, height = 4.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.3f)),
        )
        content()
    }
}
