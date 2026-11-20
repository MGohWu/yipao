package org.yipao.app.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/// iOS 26 的锚点弹层（popover / pull-down menu）基础设施。
///
/// 为什么不用 Compose 的 Popup/Dialog：它们各自开一个独立 window，
/// kyant 的 layerBackdrop 只录得到主 window 的内容，玻璃折射会变成一片空白
/// （ModalBottomSheet 就是这么退化成描边样式的，见 DemoRuntime.sheetTile）。
/// 所以这里把弹层内容「传送」到导航根部的宿主里，跟主界面同一个 window，
/// liquidGlass 照常工作，弹层还能从锚点位置长出来。

/// 弹层贴在哪：跟着锚点长出来（popover / 下拉菜单），还是从屏幕底部滑上来（底部弹层）。
internal enum class OverlayPlacement { Anchored, BottomSheet }

/// 一条弹层记录。content 由锚点处定义、在宿主处调用，捕获的是定义处的闭包，
/// 读到的 CompositionLocal 则是宿主处的（背景取景层在更外层，取得到）。
/// 底部弹层没有锚点，anchorBounds 给 { null } 就行。
internal class OverlayEntry(
    val anchorBounds: () -> Rect?,
    val visible: () -> Boolean,
    val onDismissRequest: () -> Unit,
    val placement: OverlayPlacement = OverlayPlacement.Anchored,
    val content: @Composable () -> Unit,
)

/// 弹层宿主状态。整个 App 只有一份，挂在导航根 Box 上。
class OverlayHostState internal constructor() {
    internal val entries = mutableStateListOf<OverlayEntry>()

    /// 宿主 Box 自己在 window 里的位置，用来把锚点的 window 坐标换算成宿主内坐标。
    internal var hostBounds by mutableStateOf(Rect.Zero)

    /// 当前有没有弹层露在外面。
    ///
    /// 给 AppNav 用来决定要不要录内容取景层：弹层折射的是页面内容，
    /// 没有弹层的时候那一层录了也没人看，白白把整页（含 WebView 和地图）
    /// 每帧拷进离屏层一遍。注意退场动画期间这里已经是 false，
    /// 关取景层要自己再延一段。
    val hasVisibleOverlay: Boolean get() = entries.any { it.visible() }
}

val LocalOverlayHost = staticCompositionLocalOf<OverlayHostState?> { null }

@Composable
fun rememberOverlayHostState(): OverlayHostState = remember { OverlayHostState() }

/// 弹层宿主：铺满全屏，先画点击消隐的暗幕，再把每条弹层按锚点定位画上去。
/// 放在导航根 Box 的最后（DemoToastHost 之后），保证盖在所有页面之上。
@Composable
fun BoxScope.OverlayHost(state: OverlayHostState) {
    val active = state.entries.filter { it.visible() }
    val scrimAlpha by animateFloatAsState(
        targetValue = if (active.isEmpty()) 0f else 1f,
        animationSpec = tween(durationMillis = if (active.isEmpty()) 160 else 220),
        label = "overlayScrim",
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned { state.hostBounds = it.boundsInWindow() },
    ) {
        // 暗幕。alpha 归零后彻底让开，否则退场动画期间还在吃点击。
        if (scrimAlpha > 0.01f) {
            val topmost = active.lastOrNull()
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .drawBehind { drawRect(Color.Black.copy(alpha = 0.32f * scrimAlpha)) }
                    .then(
                        if (topmost != null) {
                            Modifier.clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = { topmost.onDismissRequest() },
                            )
                        } else {
                            Modifier
                        }
                    ),
            )
        }

        state.entries.forEach { entry ->
            when (entry.placement) {
                OverlayPlacement.Anchored ->
                    AnchoredOverlayContent(entry = entry, hostBounds = state.hostBounds)
                OverlayPlacement.BottomSheet ->
                    BottomSheetOverlayContent(entry = entry)
            }
        }
    }

    // 返回键先收弹层，不退页面。
    val topmost = active.lastOrNull()
    BackHandler(enabled = topmost != null) { topmost?.onDismissRequest() }
}

/// 单条弹层的定位 + 出场动画。
@Composable
private fun AnchoredOverlayContent(entry: OverlayEntry, hostBounds: Rect) {
    val visible = entry.visible()
    val anchor = entry.anchorBounds()
    val progress by animateFloatAsState(
        targetValue = if (visible && anchor != null) 1f else 0f,
        animationSpec = if (visible) {
            spring(dampingRatio = 0.78f, stiffness = Spring.StiffnessMediumLow)
        } else {
            tween(durationMillis = 150)
        },
        label = "overlayShow",
    )
    if (progress < 0.001f && !visible) return
    if (anchor == null) return

    // 锚点换算到宿主坐标系。
    val anchorInHost = anchor.translate(-hostBounds.left, -hostBounds.top)
    // 变换原点：从锚点那一侧长出来。measure 时算出，下一帧生效——
    // 动画有 300ms，首帧的原点偏差看不出来。
    var origin by remember { mutableStateOf(TransformOrigin(0.5f, 0f)) }

    Layout(
        content = {
            Box(
                modifier = Modifier
                    .graphicsLayer {
                        transformOrigin = origin
                        // 从 0.86 起跳，跟 iOS 弹层「弹出来」的手感一致。
                        val scale = 0.86f + 0.14f * progress
                        scaleX = scale
                        scaleY = scale
                        alpha = progress
                    }
                    .widthIn(max = 320.dp),
            ) {
                entry.content()
            }
        },
    ) { measurables, constraints ->
        val gap = 8.dp.roundToPx()
        val margin = 12.dp.roundToPx()
        val width = constraints.maxWidth
        val height = constraints.maxHeight
        val placeable = measurables.first().measure(
            constraints.copy(minWidth = 0, minHeight = 0),
        )

        // 竖直：优先贴在锚点下方，下方装不下就翻到上方。
        val below = anchorInHost.bottom.toInt() + gap
        val fitsBelow = below + placeable.height <= height - margin
        val y = if (fitsBelow) {
            below
        } else {
            (anchorInHost.top.toInt() - gap - placeable.height).coerceAtLeast(margin)
        }
        // 水平：跟锚点中心对齐，再夹进屏幕边距内。
        val maxX = (width - margin - placeable.width).coerceAtLeast(margin)
        val x = (anchorInHost.center.x.toInt() - placeable.width / 2).coerceIn(margin, maxX)

        val originX = if (placeable.width > 0) {
            ((anchorInHost.center.x - x) / placeable.width).coerceIn(0f, 1f)
        } else {
            0.5f
        }
        val next = TransformOrigin(originX, if (fitsBelow) 0f else 1f)
        if (next != origin) origin = next

        layout(width, height) { placeable.place(x, y) }
    }
}

/// 底部弹层的定位 + 滑入滑出 + 下滑关闭手势。
///
/// 位移只用 hidden 这一个量（0 = 完全露出，1 = 整个滑到屏幕外），
/// 进出动画和手指拖动写的是同一个 Animatable：手一松如果判定要关，
/// 外面 visible 翻 false，动画从手指停下的位置接着往下走，不会跳一下。
@Composable
private fun BoxScope.BottomSheetOverlayContent(entry: OverlayEntry) {
    val visible = entry.visible()
    val hidden = remember { Animatable(1f) }
    var sheetHeight by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(visible) {
        if (visible) {
            hidden.animateTo(0f, spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMediumLow))
        } else {
            hidden.animateTo(1f, tween(durationMillis = 200))
        }
    }
    // 收完了就别占着位置，否则退场动画跑完还在吃点击。
    if (!visible && hidden.value > 0.999f) return

    // 手势换算要除以弹层高度；还没测量到就先当 1，反正这一帧也在屏幕外。
    val travel = sheetHeight.coerceAtLeast(1).toFloat()
    Box(
        modifier = Modifier
            .align(Alignment.BottomCenter)
            .onSizeChanged { sheetHeight = it.height }
            // size 是这一帧的实测高度，比外面存的 state 早一帧，滑入不会先闪一下。
            .graphicsLayer { translationY = hidden.value * size.height }
            .draggable(
                orientation = Orientation.Vertical,
                state = rememberDraggableState { delta ->
                    scope.launch {
                        hidden.snapTo((hidden.value + delta / travel).coerceIn(0f, 1f))
                    }
                },
                onDragStopped = { velocity ->
                    // 拖过四分之一，或者甩得够快，就算要关；否则弹回去。
                    if (hidden.value > 0.25f || velocity > 1200f) {
                        entry.onDismissRequest()
                    } else {
                        hidden.animateTo(
                            0f,
                            spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMediumLow),
                        )
                    }
                },
            ),
    ) {
        entry.content()
    }
}

/// 锚点弹层。用法跟 DropdownMenu 一样就地声明：
///
///     AnchoredOverlayBox(
///         expanded = show,
///         onDismissRequest = { show = false },
///         anchor = { TextButton(onClick = { show = true }) { Text("退出登录") } },
///     ) { AnchoredConfirmation(...) }
///
/// anchor 原地布局，content 被送到宿主里画，所以不会被滚动容器裁掉。
@Composable
fun AnchoredOverlayBox(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    anchor: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val host = LocalOverlayHost.current
    var anchorBounds by remember { mutableStateOf<Rect?>(null) }
    val currentExpanded by rememberUpdatedState(expanded)
    val currentDismiss by rememberUpdatedState(onDismissRequest)
    val currentContent by rememberUpdatedState(content)

    Box(modifier = modifier.onGloballyPositioned { anchorBounds = it.boundsInWindow() }) {
        anchor()
    }

    if (host == null) return
    DisposableEffect(host) {
        val entry = OverlayEntry(
            anchorBounds = { anchorBounds },
            visible = { currentExpanded },
            onDismissRequest = { currentDismiss() },
            placement = OverlayPlacement.Anchored,
            content = { currentContent() },
        )
        host.entries.add(entry)
        onDispose { host.entries.remove(entry) }
    }
}
