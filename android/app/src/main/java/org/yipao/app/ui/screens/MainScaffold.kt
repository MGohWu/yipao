package org.yipao.app.ui.screens

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.DirectionsCar
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.components.LocalAmbientSpec
import org.yipao.app.ui.components.drawAmbientBackground
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.components.rememberAmbientSpec
import org.yipao.app.ui.theme.LeapColors
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.materials.CupertinoMaterials
import dev.chrisbanes.haze.rememberHazeState

/// 三个主页面标题到状态栏的间距。
///
/// 系统 inset 只到状态栏底就没了，标题紧接着开始，读起来贴着刘海。iOS 那边隐藏了
/// 系统导航栏之后另外补了一段（见 HomeView.headerTopInset），这里对齐同一个观感；
/// 安卓的标题字号（headlineMedium）比 iOS 的 title2 大一号，还要再多留一点。
val PageTitleTopPadding = 28.dp

private enum class MainTab(
    val label: String,
    val icon: ImageVector,
    val iconOutlined: ImageVector,
) {
    Vehicle("车辆", Icons.Filled.DirectionsCar, Icons.Outlined.DirectionsCar),
    Features("功能", Icons.Filled.GridView, Icons.Outlined.GridView),
    Settings("设置", Icons.Filled.Settings, Icons.Outlined.Settings),
}

/// 三 Tab 主骨架,对应 iOS MainTabView。
@Composable
fun MainScaffold(onOpen: (String) -> Unit) {
    var tab by rememberSaveable { mutableStateOf(MainTab.Vehicle) }
    // 页面内容标记为模糊源，悬浮胶囊透过它取毛玻璃背景。
    val hazeState = rememberHazeState()
    // 取样源要不透明，见下面 hazeSource 那处的注释。取外层那份算好的（含当前页面的
    // tint），自己重算一份的话切到功能页时背景变了色、胶囊里透出来的还是冷蓝。
    val fallbackAmbient = rememberAmbientSpec()
    val ambient = rememberUpdatedState(LocalAmbientSpec.current ?: fallbackAmbient)

    // 背景渐变由外层 LeapBackground 画,这里全透明让它透出来。
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = Color.Transparent,
        bottomBar = {
            FloatingTabBar(
                current = tab,
                onSelect = { tapped -> tab = tapped },
                hazeState = hazeState,
                liveHaze = tab != MainTab.Vehicle,
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                // hazeSource 会把整棵子树录进离屏层。车辆页包含 WebGL WebView，部分
                // Android 15 ROM 在这条 GLFunctor + 离屏层路径会崩；其他页照常取样。
                .then(if (tab != MainTab.Vehicle) Modifier.hazeSource(hazeState) else Modifier)
                // 氛围背景本来只画在外层 LeapBackground 里,这一层是透明的。
                // 毛玻璃取样的正是这一层:取到半透明像素,模糊图再叠回原位,
                // 就等于把内容画了两遍,胶囊边界会浮出一条明显的硬线。
                // 把背景补进来让取样源不透明,模糊图才是覆盖而不是叠加。
                .drawBehind { drawAmbientBackground(ambient.value) },
        ) {
            // 不放置隐藏页，但保留组合和原生 View，返回时沿用 WebGL 场景和滚动位置。
            Layout(
                content = {
                    HomeScreen(contentPadding = padding, onOpen = onOpen, active = tab == MainTab.Vehicle)
                },
                modifier = Modifier.fillMaxSize(),
            ) { measurables, constraints ->
                val children = measurables.map { it.measure(constraints) }
                layout(constraints.maxWidth, constraints.maxHeight) {
                    if (tab == MainTab.Vehicle) children.forEach { it.placeRelative(0, 0) }
                }
            }
            when (tab) {
                MainTab.Vehicle -> Unit
                MainTab.Features -> FeatureCenterScreen(contentPadding = padding, onOpen = onOpen)
                MainTab.Settings -> SettingsScreen(contentPadding = padding, onOpen = onOpen)
            }
        }
    }
}

/// 悬浮毛玻璃导航条：选中项展开成图标+文字的胶囊。
///
/// 原先 API 33+ 走的是 kyant 的液态玻璃版（LiquidBottomTabs，可拖动磁吸的折射胶囊），
/// 那一套要给整页内容单独录一层取景层、tab 自己还有三处 drawBackdrop，
/// 首页挂着 WebGL 车模的 WebView 和高德地图，每帧都要被拷进离屏层，切页面时代价太大。
/// 现在统一走这条毛玻璃路径；LiquidBottomTabs 的实现留在仓库里没删。
@Composable
private fun FloatingTabBar(
    current: MainTab,
    onSelect: (MainTab) -> Unit,
    hazeState: HazeState,
    liveHaze: Boolean,
) {
    val supportsTransparentHaze = liveHaze && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
    val barSurface = LeapColors.bar
    val isDark = LeapColors.isDark
    // Cupertino 的默认浅色材质会用灰色 ColorDodge 叠底，地图页下面有绿地时最终会
    // 合成灰绿色。浅色单独用中性白 SrcOver：保留模糊内容，但不再吸成地图色。
    val glassStyle = if (isDark) {
        CupertinoMaterials.thin(barSurface)
    } else {
        HazeStyle(
            backgroundColor = Color.White,
            tints = listOf(HazeTint(Color.White.copy(alpha = 0.56f))),
            blurRadius = 24.dp,
            noiseFactor = 0.04f,
        )
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(bottom = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .shadow(6.dp, CircleShape)
                .clip(CircleShape)
                .then(
                    if (supportsTransparentHaze) {
                        // Android 13+ 保留完整的透明毛玻璃效果。
                        Modifier.hazeEffect(
                            state = hazeState,
                            style = glassStyle,
                        )
                            .border(
                                1.dp,
                                if (isDark) LeapColors.glassEdge else Color.White.copy(alpha = 0.72f),
                                CircleShape,
                            )
                    } else if (!liveHaze) {
                        // 车辆页不能录制含 WebGL 的页面；用半透明材质保留玻璃观感。
                        Modifier
                            .background(barSurface.copy(alpha = 0.78f))
                            .border(1.dp, LeapColors.glassEdge, CircleShape)
                    } else {
                        // Android 12 的模糊降级会把浅色导航染成灰色，改用稳定的主题表面。
                        Modifier
                            .background(barSurface)
                            .border(1.dp, LeapColors.glassEdge, CircleShape)
                    }
                ),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
            ) {
                MainTab.entries.forEach { item ->
                    val selected = current == item
                    val tint = if (selected) LeapColors.accent else MaterialTheme.colorScheme.onSurfaceVariant
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier
                            .pressable(
                                onClick = { onSelect(item) },
                                shape = CircleShape,
                                role = Role.Tab,
                            )
                            .background(if (selected) LeapColors.accent.copy(alpha = 0.15f) else Color.Transparent)
                            .padding(horizontal = 18.dp, vertical = 12.dp),
                    ) {
                        Icon(
                            if (selected) item.icon else item.iconOutlined,
                            contentDescription = item.label,
                            tint = tint,
                            modifier = Modifier.size(22.dp),
                        )
                        if (selected) {
                            Text(item.label, color = tint, style = MaterialTheme.typography.labelLarge)
                        }
                    }
                }
            }
        }
    }
}
