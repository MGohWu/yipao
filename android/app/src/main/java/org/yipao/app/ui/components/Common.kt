package org.yipao.app.ui.components

import android.os.Build
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kyant.backdrop.Backdrop
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
import com.kyant.backdrop.drawBackdrop
import com.kyant.backdrop.effects.blur
import com.kyant.backdrop.effects.lens
import com.kyant.backdrop.effects.vibrancy
import com.kyant.backdrop.highlight.Highlight
import org.yipao.app.ui.theme.LeapColors

/// 氛围背景的全部绘制参数，一次取齐，方便在 drawBehind 和 backdrop 取景层里复用。
///
/// 必须是 data class：它被 [LocalAmbientSpec] 下发给整棵树，没有 equals 的话
/// 每次重算出来的新实例都跟旧的不等，切页面那 420ms 的色彩动画里每一帧都会
/// 把下游全部判定为「变了」。
data class AmbientSpec(
    val gradient: List<Color>,
    val topGlow: Color,
    val topAlpha: Float,
    val cornerGlow: Color,
    val cornerAlpha: Float,
    val fillGlow: Color?,
)

/// 光晕透明度按 iOS LeapBackground 的档位：深色收敛、浅色放开。
///
/// [topGlow] 让单个页面把顶部光晕换成自己的主色（iOS 的 `LeapBackground(tint:)`）。
/// 传进来的是算好的光晕色（走 `LeapColors.glowOf`），不是原始品牌色。
/// 只换顶部那团：右下的冷光和浅色左下的绿补光是这套背景的骨架，一起换掉就成了单色页。
@Composable
fun rememberAmbientSpec(topGlow: Color? = null): AmbientSpec {
    val dark = LeapColors.isDark
    val glow = topGlow ?: LeapColors.glowTop
    val gradient = LeapColors.ambient
    val cornerGlow = LeapColors.glowCorner
    val fillGlow = if (dark) null else LeapColors.glowFill
    // 名副其实地 remember：入参没变就返回同一个实例。这个值要下发给整棵树，
    // 每次调用都 new 一个的话，下游拿到的引用帧帧都在变。
    return remember(dark, glow, gradient, cornerGlow, fillGlow) {
        AmbientSpec(
            gradient = gradient,
            topGlow = glow,
            // tint 自己带的透明度要折进光晕强度里。iOS 那边空调关着时给的是
            // `cool.opacity(0.6)`，靠颜色的 alpha 把整团光晕调暗；这边画光晕时
            // alpha 是单独传的、会把颜色自带的 alpha 覆盖掉，所以得在这儿先乘进来。
            topAlpha = (if (dark) 0.45f else 0.68f) * glow.alpha,
            cornerGlow = cornerGlow,
            cornerAlpha = if (dark) 0.24f else 0.5f,
            fillGlow = fillGlow,
        )
    }
}

/// 画完整氛围背景：底层线性渐变 + 顶部车况色光晕 + 右下冷光晕 + 浅色左下补光。
/// 圆心/半径/透明度全部照抄 iOS，椭圆用鸿蒙的做法（正圆按屏幕纵横比拉伸）。
fun DrawScope.drawAmbientBackground(spec: AmbientSpec) {
    drawRect(Brush.verticalGradient(spec.gradient))
    val w = size.width
    val h = size.height
    drawGlow(spec.topGlow, spec.topAlpha, Offset(w * 0.5f, h * 0.06f), w * 0.75f)
    drawGlow(spec.cornerGlow, spec.cornerAlpha, Offset(w * 0.9f, h * 0.8f), w * 0.62f)
    if (spec.fillGlow != null) {
        drawGlow(spec.fillGlow, 0.36f, Offset(w * 0.02f, h * 0.62f), w * 0.5f)
    }
}

/// 单团椭圆光晕。纯线性两段渐隐（alpha → 0）对齐 iOS LeapBackground，
/// 比之前抄鸿蒙的四段衰减更柔、更散，中心不至于结成一块实色。
private fun DrawScope.drawGlow(color: Color, alpha: Float, center: Offset, radius: Float) {
    val yScale = size.height / size.width
    withTransform({ scale(1f, yScale, pivot = center) }) {
        drawRect(
            brush = Brush.radialGradient(
                0f to color.copy(alpha = alpha),
                1f to color.copy(alpha = 0f),
                center = center,
                radius = radius,
            ),
            topLeft = Offset(center.x - radius, center.y - radius),
            size = Size(radius * 2, radius * 2),
        )
    }
}

/// 页面背景的取景层：卡片玻璃只折射它（背景静态，跟 iOS 卡片一个道理），
/// 不含页面内容，所以卡片不会折射到自己。由 LeapBackground 提供。
val LocalBackgroundBackdrop = staticCompositionLocalOf<Backdrop?> { null }

/// 页面内容的取景层：连页面一起录，给浮在所有页面之上的锚点弹层折射。
/// 弹层压着的是内容而不是空背景，只折射背景的话透出来是一片平渐变，
/// 跟一块白板没区别——iOS 弹层底下能隐约看见卡片的色块，靠的就是这一层。
/// 由 AppNav 挂在 NavHost 上；弹层宿主在 NavHost 之外，不会折射到自己。
val LocalContentBackdrop = staticCompositionLocalOf<Backdrop?> { null }

/// 当前页面声明的背景主色。
///
/// iOS 是每个页面自己套一层 `LeapBackground(tint:)`；安卓这边整个 App 只有一层背景
/// （挂在最外面），页面再自己画一层就把底下那层盖住了，转场时能看见两层背景对不上的一闪。
/// 所以反过来做：页面把自己的主色报上来，由最外层那一层统一渲染，顺带把颜色过渡也做了。
@Stable
class PageTintController {
    // 用栈而不是单个值。转场时新旧两个页面会同时挂在树上，注册和注销的先后没有保证：
    // 单值的话，旧页面那次注销会把新页面刚设的色一起抹掉，背景当场弹回默认冷蓝。
    private val entries = mutableStateListOf<Pair<Any, Color>>()

    val current: Color? get() = entries.lastOrNull()?.second

    fun push(key: Any, tint: Color) {
        val index = entries.indexOfFirst { it.first === key }
        // 已经在栈里就只更新颜色，不重新入栈——同一个页面自己变色（空调开关、
        // 充电插枪）不该把它挪到别人前面去。
        if (index >= 0) entries[index] = key to tint else entries += key to tint
    }

    fun pop(key: Any) {
        entries.removeAll { it.first === key }
    }
}

val LocalPageTint = staticCompositionLocalOf { PageTintController() }

/// 当前生效的氛围背景参数（含已过渡到位的页面主色）。
/// 玻璃取景层要照它再画一份背景，否则折射出来的还是默认冷蓝，跟眼前的背景对不上。
///
/// 不能用 staticCompositionLocalOf：那个的语义是「值一变，整个 provider 子树无条件
/// 全量重组」，只适合放几乎不变的量。这里的值在切页面时会跟着 420ms 的色彩动画
/// 逐帧变化，用 static 的话每一帧都会把首页全部卡片、正在滑入的新页面、还有首页
/// 那个 WebGL 车模 WebView 和高德地图整棵重组一遍——正好压在 320ms 的转场上。
val LocalAmbientSpec = compositionLocalOf<AmbientSpec?> { null }

/// 声明本页的背景主色，对应 iOS 的 `LeapBackground(tint:)`。
/// 页面离开组合时自动撤回，背景回到上一层页面的色。
@Composable
fun PageTint(tint: Color) {
    val controller = LocalPageTint.current
    val key = remember { Any() }
    SideEffect { controller.push(key, tint) }
    DisposableEffect(controller, key) {
        onDispose { controller.pop(key) }
    }
}

/// 全局氛围背景：iOS 同款冷蓝灰渐变+光晕，所有页面都套在它里面。
/// 顶部光晕跟着当前页面走，见 [PageTint]。
/// 这里不是 material3 Surface，得自己下发 LocalContentColor，
/// 否则默认内容色停在黑色，深色模式下所有默认色文字全变黑字。
@Composable
fun LeapBackground(
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    val tints = remember { PageTintController() }
    val tint = tints.current
    val target = if (tint != null) LeapColors.glowOf(tint) else LeapColors.glowTop
    val animated by animateColorAsState(
        targetValue = target,
        animationSpec = tween(durationMillis = 420),
        label = "ambientTint",
    )
    val spec = rememberAmbientSpec(animated)
    val backdrop = rememberLayerBackdrop()
    CompositionLocalProvider(
        LocalContentColor provides MaterialTheme.colorScheme.onBackground,
        LocalBackgroundBackdrop provides backdrop,
        LocalPageTint provides tints,
        LocalAmbientSpec provides spec,
    ) {
        Box(modifier = modifier.fillMaxSize()) {
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .layerBackdrop(backdrop)
                    .drawBehind { drawAmbientBackground(spec) },
            )
            content()
        }
    }
}

/// 玻璃高光描边。库默认是白 50% + Plus 加法混合，叠亮背景后刺眼，统一压到 0.35。
val GlassHighlight = Highlight(alpha = 0.35f)

/// 液态玻璃表面（iOS 26 glassEffect 的等价物）：折射背景光晕 + 饱和提亮 + 淡 tint 面罩。
/// lens 要 RuntimeShader（API 33+），低版本回落成 tint + 细描边（iOS 18 的降级路径）。
@Composable
fun Modifier.liquidGlass(
    shape: Shape,
    surface: Color,
    /// 折射哪一层。默认只折射背景；弹层要传内容取景层，才看得见底下压着什么。
    backdrop: Backdrop? = LocalBackgroundBackdrop.current,
    /// 折射前的模糊半径。取景层含内容时要糊得更狠，否则底下的字会透出来晃眼。
    blurRadius: Dp = 4.dp,
): Modifier {
    val edge = LeapColors.glassEdge
    return if (Build.VERSION.SDK_INT >= 33 && backdrop != null) {
        this.drawBackdrop(
            backdrop = backdrop,
            shape = { shape },
            effects = {
                vibrancy()
                blur(blurRadius.toPx())
                lens(12.dp.toPx(), 24.dp.toPx())
            },
            highlight = { GlassHighlight },
            onDrawSurface = { drawRect(surface) },
        )
    } else {
        this
            .border(0.8.dp, edge, shape)
            .clip(shape)
            .background(surface)
    }
}

/// 玻璃卡片，替代 material3 Card。内容布局跟 Card 一样是 Column。
@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    shape: Shape = CardShape,
    surface: Color = LeapColors.card,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        // pressable 必须排在 liquidGlass 前面，否则缩放只作用于卡片内容，底板不动。
        modifier = modifier
            .then(
                if (onClick != null) {
                    Modifier.pressable(onClick = onClick, shape = shape)
                } else {
                    Modifier
                }
            )
            .liquidGlass(shape, surface),
        content = content,
    )
}

/// 大数字 + 单位，基线对齐。等价于 iOS 端的 MetricValue。
@Composable
fun MetricValue(
    value: String,
    unit: String? = null,
    valueSize: Int = 32,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier, verticalAlignment = Alignment.Bottom) {
        Text(
            text = value,
            fontSize = valueSize.sp,
            fontWeight = FontWeight.Medium,
            lineHeight = (valueSize + 2).sp,
            color = MaterialTheme.colorScheme.onSurface,
        )
        if (unit != null) {
            Text(
                text = unit,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 4.dp, bottom = 5.dp),
            )
        }
    }
}

/// 状态胶囊徽章：图标 + 短文案。中性状态用 onSurfaceVariant，异常给 caution 色。
@Composable
fun StatusPill(
    text: String,
    icon: ImageVector,
    tint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    container: Color = LeapColors.card,
) {
    Box(modifier = Modifier.liquidGlass(CircleShape, container)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
            Text(
                text = text,
                style = MaterialTheme.typography.labelMedium,
                color = tint,
            )
        }
    }
}

/// 能量条。limit 是充电上限刻度，读不到就不画；charging 时填充用主色渐变示意。
@Composable
fun EnergyBar(
    percent: Int,
    modifier: Modifier = Modifier,
    fill: Color = MaterialTheme.colorScheme.primary,
    limit: Int? = null,
    height: Int = 6,
) {
    val track = MaterialTheme.colorScheme.surfaceVariant
    val mark = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f)
    Canvas(modifier = modifier.fillMaxWidth().height((height + 4).dp)) {
        val barHeight = height.dp.toPx()
        val top = (size.height - barHeight) / 2
        val radius = androidx.compose.ui.geometry.CornerRadius(barHeight / 2)
        drawRoundRect(track, topLeft = Offset(0f, top), size = Size(size.width, barHeight), cornerRadius = radius)
        val w = size.width * percent.coerceIn(0, 100) / 100f
        drawRoundRect(fill, topLeft = Offset(0f, top), size = Size(w, barHeight), cornerRadius = radius)
        if (limit != null) {
            val x = size.width * limit.coerceIn(0, 100) / 100f
            drawRoundRect(
                mark,
                topLeft = Offset(x - 1.dp.toPx(), 0f),
                size = Size(2.dp.toPx(), size.height),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.dp.toPx()),
            )
        }
    }
}

/// 车辆侧面剪影。官方车图资源接入前的占位主视觉，用曲线画个认得出的车侧影。
@Composable
fun CarSilhouette(modifier: Modifier = Modifier) {
    val body = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
    val glass = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f)
    Canvas(modifier = modifier) {
        val w = size.width
        val h = size.height
        // 车身:从车头保险杠起,引擎盖-A柱-车顶-溜背-车尾一笔画完。
        val path = Path().apply {
            moveTo(w * 0.02f, h * 0.78f)
            cubicTo(w * 0.02f, h * 0.62f, w * 0.05f, h * 0.52f, w * 0.14f, h * 0.48f)
            cubicTo(w * 0.22f, h * 0.45f, w * 0.28f, h * 0.42f, w * 0.34f, h * 0.30f)
            cubicTo(w * 0.40f, h * 0.18f, w * 0.52f, h * 0.14f, w * 0.62f, h * 0.16f)
            cubicTo(w * 0.74f, h * 0.18f, w * 0.82f, h * 0.26f, w * 0.88f, h * 0.40f)
            cubicTo(w * 0.93f, h * 0.44f, w * 0.97f, h * 0.50f, w * 0.98f, h * 0.60f)
            cubicTo(w * 0.99f, h * 0.70f, w * 0.97f, h * 0.78f, w * 0.94f, h * 0.78f)
            lineTo(w * 0.02f, h * 0.78f)
            close()
        }
        drawPath(path, body, style = Fill)
        // 车窗
        val window = Path().apply {
            moveTo(w * 0.38f, h * 0.32f)
            cubicTo(w * 0.43f, h * 0.22f, w * 0.52f, h * 0.19f, w * 0.61f, h * 0.21f)
            cubicTo(w * 0.70f, h * 0.23f, w * 0.77f, h * 0.29f, w * 0.82f, h * 0.40f)
            lineTo(w * 0.60f, h * 0.40f)
            lineTo(w * 0.38f, h * 0.40f)
            close()
        }
        drawPath(window, glass, style = Fill)
        // 轮子
        val wheelRadius = h * 0.14f
        val hub = body.copy(alpha = 0.9f)
        drawCircle(hub, wheelRadius, center = Offset(w * 0.24f, h * 0.78f))
        drawCircle(hub, wheelRadius, center = Offset(w * 0.76f, h * 0.78f))
        drawCircle(glass, wheelRadius * 0.45f, center = Offset(w * 0.24f, h * 0.78f))
        drawCircle(glass, wheelRadius * 0.45f, center = Offset(w * 0.76f, h * 0.78f))
    }
}

/// 分组小标题，对应 iOS 的 Section header。
@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = modifier.padding(top = 8.dp, bottom = 2.dp),
    )
}

/// 圆形淡色底的图标，列表行首常用。
@Composable
fun TintedIconBadge(
    icon: ImageVector,
    tint: Color = MaterialTheme.colorScheme.primary,
    size: Int = 40,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(size.dp)
            .background(tint.copy(alpha = 0.14f), CircleShape),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size((size * 0.5f).dp))
    }
}

/// 卡片统一圆角，对齐 iOS 的 cardRadius 26 / tileRadius 22。首页各卡实际都用 22。
val CardShape = RoundedCornerShape(26.dp)
val TileShape = RoundedCornerShape(22.dp)
