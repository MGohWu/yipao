package org.yipao.app.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import org.yipao.app.R
import org.yipao.app.core.CarImageCache
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetControlFeedback
import androidx.glance.state.PreferencesGlanceStateDefinition

/// 桌面车况卡。三种版式和 iOS `VehicleWidgetView` 一一对应：
///
/// - **小**（`SmallVehicleView`）：车名 + 大号电量 + 能量条 + 两颗最常用的按钮。
/// - **中**（`MediumVehicleView`）：左信息栏 + 右 2×2 按钮网格。
/// - **大**（`LargeVehicleView`）：头部 + 主视觉 + 四颗按钮横排。iOS 那块主视觉是预渲染
///   的地图，安卓这边换成车模——高德静态图要另走一次联网出图，而车模本来就躺在
///   `filesDir` 里（锁车卡用的同一张）。
///
/// **一种版式一个 provider，各自钉死尺寸、都不可拉伸。** iOS 是一张卡片横滑挑
/// 小/中/大，安卓没有这个机制——桌面选择器里因此是三个独立条目。
/// 三档尺寸是 2×2 / 4×2 / 4×4，理由见 `res/xml/widget_vehicle_small_info.xml`。
///
/// 之前是一个 provider 配 `SizeMode.Responsive`，版式跟着尺寸走。那样更「安卓」，
/// 但安卓的卡片是能被用户随手拉伸的：往窄里一拖，四按钮的横卡就变成两按钮的竖卡，
/// 同一张卡长出四种样子。车主要的是「选哪张就是哪张」，和 iOS 一样。
///
/// 车况由 App 刷新时推过来，卡片自己不联网；`VehicleRefreshWorker` 每 15 分钟在后台
/// 拉一次（对齐 iOS 卡片那条时间线）。点击非按钮区域打开 App。
abstract class VehicleWidgetBase : GlanceAppWidget() {

    override val stateDefinition = PreferencesGlanceStateDefinition

    /// 按桌面**实际给的**尺寸排版，不是按 provider 里声明的那个。
    ///
    /// 三张卡各自钉死一种版式、都不可拉伸，本来 `SizeMode.Single` 就够了。但「2×2」
    /// 在各家桌面上根本不是同一个尺寸——栅格是启动器定的，同一张卡在这台 AOSP
    /// 模拟器上落地二百六十来 dp 高，换一家国产桌面可能只有一百八。而 Glance 的溢出是
    /// **静默裁掉**：多出来的部分不会挤压别人，是直接不画，矮的那一头会少半排按钮。
    ///
    /// `Exact` 让每张卡拿到自己的真实尺寸（各 `Layout` 里读 `LocalSize` 的那几处）。
    /// 版式还是同一套，只有按钮高度、右栏宽度、要不要摆充电详情这类数跟着收放——
    /// 和「一张卡长出四种样子」的 `Responsive` 不是一回事。
    /// 桌面不报尺寸时 Glance 退回 provider 里的 `minWidth/minHeight`，而那两个值
    /// 就是各自的目标尺寸，退回去也不会错。
    override val sizeMode = SizeMode.Exact

    /// 卡片四周留白。照 iOS 的 15/15/17 各收一两档：安卓同格数的卡比 iOS 窄十几 dp，
    /// 留白照搬会把小卡那两颗按钮挤成条。
    protected open val cardPadding: Dp = MEDIUM_PADDING

    @Composable
    protected abstract fun Layout(snapshot: VehicleSnapshot)

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val snapshot = currentVehicleSnapshot()
            WidgetCard(
                onClick = openAppAction(),
                padding = cardPadding,
            ) {
                if (snapshot == null) EmptyState() else Layout(snapshot)
            }
        }
    }
}

/// 2×2，对齐 iOS 小尺寸。国产桌面上的「小卡」标准档。
class VehicleSmallWidget : VehicleWidgetBase() {
    override val cardPadding = SMALL_PADDING

    @Composable
    override fun Layout(snapshot: VehicleSnapshot) = SmallLayout(snapshot)
}

/// 4×2，对齐 iOS 中尺寸那张横条。
class VehicleMediumWidget : VehicleWidgetBase() {
    @Composable
    override fun Layout(snapshot: VehicleSnapshot) = MediumLayout(snapshot)
}

/// 4×4，对齐 iOS 大尺寸。
///
/// 类名保留 `VehicleWidget`（以及下面的 `VehicleWidgetReceiver`）不是随手起的：
/// 老版本装出去的那个 provider 就叫这个名字，改名的话桌面上已经摆着的卡
/// 会在升级后直接消失。
class VehicleWidget : VehicleWidgetBase() {
    override val cardPadding = LARGE_PADDING

    @Composable
    override fun Layout(snapshot: VehicleSnapshot) = LargeLayout(snapshot)
}

/// 三张卡的四周留白，照 iOS 的 15/15/17 各收一两档。
/// 版式里还要拿它反算净高净宽，所以摆在外面而不是各自写死在类里。
internal val SMALL_PADDING = 12.dp
internal val MEDIUM_PADDING = 14.dp
internal val LARGE_PADDING = 16.dp

/// 三张车况卡的 receiver 共同部分：出现和消失时都去对一次后台任务的账。
abstract class VehicleWidgetReceiverBase : GlanceAppWidgetReceiver() {

    /// 桌面上第一次出现这张卡时，把后台那趟 15 分钟的刷新排上。
    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        VehicleRefreshScheduler.sync(context)
    }

    /// 最后一张被删掉时撤掉——但只有所有卡都没了才真撤，判据在 `VehicleRefreshScheduler`。
    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        VehicleRefreshScheduler.sync(context)
    }

    /// 系统那个半小时的心跳。顺手对一次账：覆盖安装的用户桌面上早就摆着卡片，
    /// `onEnabled` 不会再来第二次，光靠它的话这些人永远排不上任务。
    override fun onUpdate(
        context: Context,
        appWidgetManager: android.appwidget.AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        VehicleRefreshScheduler.sync(context)
    }
}

class VehicleSmallWidgetReceiver : NativeWidgetReceiver() {
    override val nativeKind = NativeWidgetKind.SMALL
}

class VehicleMediumWidgetReceiver : NativeWidgetReceiver() {
    override val nativeKind = NativeWidgetKind.MEDIUM
}

class VehicleWidgetReceiver : NativeWidgetReceiver() {
    override val nativeKind = NativeWidgetKind.LARGE
}

// MARK: - 外壳

/// 两张卡共用的外壳：底色、圆角、整卡可点。
///
/// [background] 是锁车卡那层随状态变色的渐变——Glance 画不了渐变（没有 Brush），
/// 只能把它做成 drawable 铺进来；车况卡不传，走纯色卡底。
@Composable
internal fun WidgetCard(
    onClick: Action?,
    padding: Dp = 12.dp,
    background: Int? = null,
    clickOverlay: Boolean = false,
    content: @Composable () -> Unit,
) {
    val base = GlanceModifier.fillMaxSize().cornerRadius(20.dp)
    val painted = if (background != null) {
        base.background(ImageProvider(background), contentScale = ContentScale.FillBounds)
    } else {
        base.background(WidgetPalette.background)
    }
    Box(modifier = painted) {
        // 打开 App 的点击面在内容下方，与控车按钮不构成可点击父子关系。
        // ColorOS 会把嵌套点击交给最外层 RemoteViews，不能给根节点挂 clickable。
        if (onClick != null && !clickOverlay) {
            Box(modifier = GlanceModifier.fillMaxSize().clickable(onClick)) {}
        }
        Box(
            modifier = GlanceModifier.fillMaxSize().padding(padding),
            contentAlignment = Alignment.Center,
        ) { content() }
        if (onClick != null && clickOverlay) {
            Box(modifier = GlanceModifier.fillMaxSize().clickable(onClick)) {}
        }
    }
}

@Composable
private fun EmptyState() {
    Column(
        modifier = GlanceModifier.fillMaxSize(),
        verticalAlignment = Alignment.Vertical.CenterVertically,
        horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
    ) {
        Text("还没有车况", style = TextStyle(color = WidgetPalette.primaryText, fontSize = 14.sp, fontWeight = FontWeight.Medium))
        Spacer(GlanceModifier.height(4.dp))
        // 不编一个「0%」出来占位。什么都没有的时候，说清楚下一步该干什么就够了。
        Text("打开 App 同步一次", style = TextStyle(color = WidgetPalette.secondaryText, fontSize = 12.sp))
    }
}

// MARK: - 小

/// 小版式（2×2）。对齐 iOS `SmallVehicleView`：车名一行、大号电量、能量条、两颗键。
///
/// 上一版是 2×1，净高只有一百来 dp，刷新键、按钮上的文字、剩余充电时间全是被高度
/// 逼掉的，主数字也从 36 收到了 28。回到 2×2 之后这些一并摆回来，尺寸照 iOS。
///
/// 充电功率摆右上角、剩余时间摆能量条下面——这个拆法是 iOS 定的，而且是被**宽度**
/// 逼出来的，不会因为卡片变高就不成立：这张卡只有 2 格宽（净宽一百二十来 dp），
/// 「剩余 1 小时 35 分 · 7.0 kW」两项并排一定被切掉后半截。
@Composable
private fun SmallLayout(snapshot: VehicleSnapshot) {
    // 各家桌面对「2×2」的理解差得很远，按实际净高收放，别让底下那排按钮被裁掉。
    val available = LocalSize.current.height - SMALL_PADDING * 2
    val compact = available < 180.dp
    val tileHeight = when {
        available >= 200.dp -> 50.dp
        available >= 160.dp -> 44.dp
        else -> 40.dp
    }
    val socSize = if (compact) 30.sp else 34.sp
    val percentSize = if (compact) 13.sp else 14.sp
    Column(modifier = GlanceModifier.fillMaxSize()) {
        HeaderRow(snapshot, chargePowerInHeader = true)
        // 顶部只留一条固定的小缝，把弹性余量全部放到按钮之前。原先上下各一条
        // defaultWeight，部分桌面算出的净高偏小时会先把底部两颗按钮挤出卡片。
        Spacer(GlanceModifier.height(if (compact) 2.dp else 4.dp))
        SocRow(snapshot, socSize = socSize, percentSize = percentSize, showBolt = false)
        EnergyBars(snapshot, topPadding = if (compact) 3.dp else 4.dp)
        // 功率已经在右上角，这一行就只剩剩余时间；读不到就整行不摆。
        // 卡片矮的时候也不摆——它是这张卡上最可省的一行，中卡和大卡上都有。
        if (available >= 200.dp && snapshot.isCharging && snapshot.chargeRemainingText != null) {
            ChargeMetricsLine(snapshot, showsPower = false)
        }
        Spacer(GlanceModifier.defaultWeight())
        Spacer(GlanceModifier.height(if (compact) 4.dp else 7.dp))
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            currentWidgetButtons(small = true).forEachIndexed { index, action ->
                if (index > 0) Spacer(GlanceModifier.width(7.dp))
                ConfiguredActionTile(action, snapshot, tileHeight, GlanceModifier.defaultWeight())
            }
        }
    }
}

// MARK: - 中

/// 中版式（4×2）。对齐 iOS `MediumVehicleView`：左边一栏信息，右边 2×2 等大网格。
///
/// 右栏宽度按比例算，不写死 iOS 的 146：那是 iOS 中卡内容宽（299pt）的一半，
/// 而安卓这张卡在不同机器上净宽能差七八十 dp，写死的话窄机器上左栏只剩一百 dp 出头，
/// 大号电量和续航挤在一起。均分（`defaultWeight`）也不行——宽机器上四颗按钮会摊成扁条。
///
/// 按钮高度让两行吃满右栏，上限还是 iOS 的 62：再高就成了两块竖条，
/// 和大卡那排横按钮不像一家人了。
@Composable
private fun MediumLayout(snapshot: VehicleSnapshot) {
    val size = LocalSize.current
    val contentWidth = size.width - MEDIUM_PADDING * 2
    val contentHeight = size.height - MEDIUM_PADDING * 2
    val gridWidth = (contentWidth * 0.49f).coerceIn(118.dp, 146.dp)
    val tileHeight = ((contentHeight - 7.dp) / 2).coerceIn(46.dp, 62.dp)
    // 左栏窄到摆不下 40sp 的大数字加续航时收一档——先被切掉的是「312 km」。
    val socSize = if (contentWidth - gridWidth - 14.dp >= 130.dp) 40.sp else 34.sp
    Row(modifier = GlanceModifier.fillMaxSize()) {
        Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight()) {
            // 头部只摆一颗闪电，功率跟着剩余时间去下面那一行——照 iOS。
            // 上一版是把功率摆在头部、整行充电详情不摆，那是 4×1 的净高（一百一十来 dp）
            // 逼出来的：五行要一百三十多，摆下去最后两行会被 Glance 静默裁掉。
            HeaderRow(snapshot, chargePowerInHeader = false, showBolt = true)
            Spacer(GlanceModifier.defaultWeight())
            Column {
                SocRow(
                    snapshot,
                    socSize = socSize,
                    // 「%」照 iOS 取主数字的 0.425（40/17），跟着字号一起收。
                    percentSize = (socSize.value * 0.425f).sp,
                    showBolt = false,
                    showRange = !snapshot.hasFuel,
                )
                if (snapshot.hasFuel) {
                    snapshot.mediumRangeText?.let { range ->
                        Text(range, maxLines = 1,
                            style = TextStyle(color = WidgetPalette.secondaryText, fontSize = 10.sp))
                    }
                }
                EnergyBars(snapshot, topPadding = 7.dp)
                if (snapshot.isCharging && snapshot.hasChargeMetrics) ChargeMetricsLine(snapshot)
            }
            Spacer(GlanceModifier.defaultWeight())
            // 状态行是这里必须留的：「车窗未关闭」比任何一个读数都重要。
            Column { StatusLine(snapshot, fontSize = 10.sp, compactFreshness = true) }
        }
        Spacer(GlanceModifier.width(14.dp))
        Column(
            modifier = GlanceModifier.width(gridWidth).fillMaxHeight(),
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            currentWidgetButtons(small = false).chunked(2).forEachIndexed { row, actions ->
                if (row > 0) Spacer(GlanceModifier.height(7.dp))
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    actions.forEachIndexed { index, action ->
                        if (index > 0) Spacer(GlanceModifier.width(7.dp))
                        ConfiguredActionTile(action, snapshot, tileHeight, GlanceModifier.defaultWeight())
                    }
                }
            }
        }
    }
}

// MARK: - 大

/// 对齐 iOS `LargeVehicleView`：车名一行 + 车模主视觉 + 读数 + 四颗按钮横排。
///
/// 车模在中间吃掉所有余量当主角，电量和状态沉到车下面——大数字压在顶上会把车挤扁，
/// 而这张卡最该一眼认出来的就是「这是我那台车」。
@Composable
private fun LargeLayout(snapshot: VehicleSnapshot) {
    val size = LocalSize.current
    val contentWidth = size.width - LARGE_PADDING * 2
    val contentHeight = size.height - LARGE_PADDING * 2
    // 车图最宽只占内容宽的七成（iOS `carWidthRatio`）：3D 渲染器截来的车图比图层叠出来的
    // 大不少，让它顶到卡片两边整张卡就散了。Glance 没有按比例取宽度的写法
    // （`fillMaxWidth` 不收 fraction），只能折算成左右各 15% 的边距——但要按**这台机器**
    // 的实际净宽折算，上一版写死的 44dp 是按一种栅格量出来的，换台机器就不是七成了。
    val carInset = contentWidth * 0.15f
    // 缺图时那个剪影跟着卡片一起缩放。写死一个数的话，高卡上它浮在中间一小块，
    // 看着像图没加载出来（上一版 76dp 就是这么来的）。
    val silhouette = (contentHeight * 0.22f).coerceIn(56.dp, 132.dp)
    Column(modifier = GlanceModifier.fillMaxSize()) {
        // 车名和那句状态挤在同一行。只有状态那段带 `defaultWeight`：车名先按内容量宽度，
        // 剩下的全给状态，长车名时被压的是状态而不是车名。反过来（车名吃 weight）
        // 会让状态直接被挤成一个字。
        //
        // 续航不在这一行——它跟着各自的能量条走（见 [LargeEnergySection]）。
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Vertical.CenterVertically) {
            Text(
                text = snapshot.vehicleName,
                maxLines = 1,
                // 20sp 对齐 iOS 的 `.title3`。上一版收到 17 是给 4×2 那点高度让路的。
                style = TextStyle(color = WidgetPalette.primaryText, fontSize = 20.sp, fontWeight = FontWeight.Bold),
            )
            Spacer(GlanceModifier.width(8.dp))
            Box(modifier = GlanceModifier.defaultWeight(), contentAlignment = Alignment.CenterEnd) {
                StatusLine(snapshot, fontSize = 12.sp, textAlign = TextAlign.End, alwaysFreshness = true)
            }
        }
        CarArtwork(
            silhouetteSize = silhouette,
            onClick = openAppAction(),
            modifier = GlanceModifier
                .fillMaxWidth()
                .defaultWeight()
                .padding(vertical = 8.dp, horizontal = carInset),
        )
        LargeEnergySection(snapshot)
        if (snapshot.isCharging && snapshot.hasChargeMetrics) ChargeMetricsLine(snapshot)
        Spacer(GlanceModifier.height(14.dp))
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            currentWidgetButtons(small = false).forEachIndexed { index, action ->
                if (index > 0) Spacer(GlanceModifier.width(8.dp))
                ConfiguredActionTile(action, snapshot, 64.dp, GlanceModifier.defaultWeight())
            }
        }
    }
}

/// 车图下面那块读数。增程车切成左右对称的两段，电一段油一段，各自带一个续航数。
///
/// 官方和车端都不给综合续航——电和油本来就是两个数，用一条总条子把它们并起来，
/// 等于替车主编了一个车上根本没有的读数。纯电车没有第二段，那一段整个不摆，
/// 剩下的一段铺满整行（不是留半边空着）。和 iOS 大卡同一套版式。
@Composable
private fun LargeEnergySection(snapshot: VehicleSnapshot) {
    val fuel = snapshot.gasolinePercent
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Vertical.Top) {
        EnergySegment(
            icon = R.drawable.ic_widget_bolt,
            iconTint = if (snapshot.isCharging) WidgetPalette.accent else WidgetPalette.tertiaryText,
            percent = snapshot.soc,
            // 纯电车的续航就是快照里那个总数；增程车才有单独的纯电续航。
            km = snapshot.energyRangeKm ?: snapshot.rangeKm.takeIf { fuel == null },
            barColor = if (snapshot.isCharging) WidgetPalette.accent else WidgetPalette.accentSoft,
            modifier = GlanceModifier.defaultWeight(),
        )
        if (fuel != null) {
            // 两边各 14，照 iOS `energySection` 那个 `HStack(spacing: 14)`。
            Spacer(GlanceModifier.width(14.dp))
            // Glance 没有分隔线控件，一条 1dp 宽的实心方块就是那道竖线。
            Box(modifier = GlanceModifier.width(1.dp).height(34.dp).background(WidgetPalette.track)) {}
            Spacer(GlanceModifier.width(14.dp))
            EnergySegment(
                icon = R.drawable.ic_widget_fuel,
                iconTint = WidgetPalette.tertiaryText,
                percent = fuel,
                km = snapshot.fuelRangeKm,
                barColor = WidgetPalette.accentSoft,
                modifier = GlanceModifier.defaultWeight(),
            )
        }
    }
}

/// 一段读数：图标 + 百分比 + 续航，底下压一条进度条。
/// 续航读不到就整个不摆那个数——空着比写个 `--` 老实，也比编一个数强。
///
/// 基线补偿的道理和 [SocRow] 里那段一样：Glance 没有基线对齐，只能底对齐之后
/// 给矮的元素垫一层下边距。
@Composable
private fun EnergySegment(
    icon: Int,
    iconTint: androidx.glance.unit.ColorProvider,
    percent: Int?,
    km: Int?,
    barColor: androidx.glance.unit.ColorProvider,
    modifier: GlanceModifier,
) {
    val socSize = 28.sp
    val percentSize = 13.sp
    val kmSize = 12.sp
    val descent = socSize.value * 0.22f
    Column(modifier = modifier) {
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Vertical.Bottom) {
            Image(
                provider = ImageProvider(icon),
                contentDescription = null,
                modifier = GlanceModifier
                    .width(10.dp)
                    .height(10.dp + descent.dp)
                    .padding(bottom = descent.dp),
                colorFilter = ColorFilter.tint(iconTint),
            )
            Spacer(GlanceModifier.width(3.dp))
            Text(
                text = percent?.toString() ?: "--",
                style = TextStyle(color = WidgetPalette.primaryText, fontSize = socSize, fontWeight = FontWeight.Normal),
            )
            Text(
                text = "%",
                modifier = GlanceModifier.padding(
                    bottom = (descent - percentSize.value * 0.22f).coerceAtLeast(0f).dp,
                ),
                style = TextStyle(color = WidgetPalette.secondaryText, fontSize = percentSize),
            )
            if (km != null) {
                Box(
                    modifier = GlanceModifier
                        .defaultWeight()
                        .padding(bottom = (descent - kmSize.value * 0.22f).coerceAtLeast(0f).dp),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    Text(
                        text = "$km km",
                        maxLines = 1,
                        style = TextStyle(color = WidgetPalette.secondaryText, fontSize = kmSize, textAlign = TextAlign.End),
                    )
                }
            }
        }
        Spacer(GlanceModifier.height(5.dp))
        EnergyBar(progress = percent, color = barColor, modifier = GlanceModifier.fillMaxWidth())
    }
}

/// 大卡中间那块主视觉。主 App 叠好写进 `filesDir` 的那张车图，
/// 取不到——关了「显示车模型」、图还没叠好、演示态——就退回剪影，
/// 和 iOS `LockWidgetView` 缺图时是同一个处理。
@Composable
private fun CarArtwork(
    modifier: GlanceModifier,
    silhouetteSize: Dp,
    onClick: Action? = null,
) {
    val car = CarImageCache.shared()
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        Box(modifier = GlanceModifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            if (car != null) {
                Image(
                    provider = ImageProvider(car),
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = GlanceModifier.fillMaxSize(),
                )
            } else {
                Image(
                    provider = ImageProvider(R.drawable.ic_widget_car),
                    contentDescription = null,
                    // 尺寸由调用方按卡片净高折算（见 [LargeLayout] 里的 `silhouette`）。
                    modifier = GlanceModifier.size(silhouetteSize),
                    colorFilter = ColorFilter.tint(WidgetPalette.tertiaryText),
                )
            }
        }
        if (onClick != null) {
            // ColorOS 16 会在桌面切前后台后丢掉“可点击容器”里的图片子节点，直到用户
            // 再触摸一次才重绘。图片层保持普通 RemoteViews，最后叠一层透明点击面，
            // 既能点车图区打开 App，也不会让宿主拿点击占位替换车图。
            Box(modifier = GlanceModifier.fillMaxSize().clickable(onClick)) {}
        }
    }
}

// MARK: - 版式零件

/// 车名那一行。车名是配角（次要色小字），主角是下面那个大数字——和 iOS 一致。
///
/// 充电这件事在这一行说，分两种说法：小版式摆功率（[chargePowerInHeader]），
/// 中版式只摆一颗闪电（[showBolt]），都照 iOS 来。大版式不用这个零件——
/// 它那颗闪电在 SOC 行里，头部右侧让给了状态。
@Composable
private fun HeaderRow(
    snapshot: VehicleSnapshot,
    chargePowerInHeader: Boolean,
    showBolt: Boolean = false,
) {
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Vertical.CenterVertically) {
        Text(
            text = snapshot.vehicleName,
            maxLines = 1,
            modifier = GlanceModifier.defaultWeight(),
            style = TextStyle(color = WidgetPalette.secondaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium),
        )
        if (snapshot.isCharging && chargePowerInHeader) {
            val power = snapshot.chargePowerText
            Image(
                provider = ImageProvider(R.drawable.ic_widget_bolt),
                contentDescription = if (power == null) "充电中" else null,
                modifier = GlanceModifier.size(11.dp),
                colorFilter = ColorFilter.tint(WidgetPalette.accent),
            )
            // 功率本身就意味着车在充电，所以它替掉那个孤零零的闪电；读不到才退回图标——
            // 总得有个东西说明车在充电。
            if (power != null) {
                Spacer(GlanceModifier.width(3.dp))
                Text(
                    text = power,
                    maxLines = 1,
                    style = TextStyle(color = WidgetPalette.accent, fontSize = 11.sp, fontWeight = FontWeight.Medium),
                )
            }
            Spacer(GlanceModifier.width(6.dp))
        } else if (snapshot.isCharging && showBolt) {
            Image(
                provider = ImageProvider(R.drawable.ic_widget_bolt),
                contentDescription = "充电中",
                modifier = GlanceModifier.size(10.dp),
                colorFilter = ColorFilter.tint(WidgetPalette.accent),
            )
            Spacer(GlanceModifier.width(6.dp))
        }
    }
}

/// 大号电量。对齐 iOS：细体大数字 + 小一号的「%」，续航靠右。
@Composable
private fun SocRow(
    snapshot: VehicleSnapshot,
    socSize: androidx.compose.ui.unit.TextUnit,
    percentSize: androidx.compose.ui.unit.TextUnit,
    showBolt: Boolean,
    showRange: Boolean = true,
    rangePrefix: String = "",
    rangeSize: androidx.compose.ui.unit.TextUnit = 11.sp,
) {
    // iOS 那行是 `firstTextBaseline` 对齐：`%`、闪电、续航全都坐在大数字的基线上。
    // Glance 只有 Top/Center/Bottom，底对齐的话每个元素是各自的**行底**对齐，
    // 而字号越大下伸区越深——44sp 的「76」底下空着近 10dp，11sp 的续航只空 2dp，
    // 于是续航看起来整整低了一截（真机上确认过）。
    //
    // 所以底对齐之后再给矮的元素各垫一层下边距，把它们顶回基线。0.22 是常见西文
    // 字体的下伸比例，中文数字用它误差在 1dp 以内，比写死一个常数跟着字号变。
    val descent = socSize.value * 0.22f
    fun baselinePad(size: androidx.compose.ui.unit.TextUnit) =
        (descent - size.value * 0.22f).coerceAtLeast(0f).dp

    Row(
        modifier = GlanceModifier.fillMaxWidth(),
        verticalAlignment = Alignment.Vertical.Bottom,
    ) {
        // 读不到就写 `--`：主数字不占位的话卡片会空掉一大块，但绝不编一个数出来。
        Text(
            text = snapshot.soc?.toString() ?: "--",
            style = TextStyle(color = WidgetPalette.primaryText, fontSize = socSize, fontWeight = FontWeight.Normal),
        )
        Text(
            text = "%",
            modifier = GlanceModifier.padding(bottom = baselinePad(percentSize)),
            style = TextStyle(color = WidgetPalette.secondaryText, fontSize = percentSize, fontWeight = FontWeight.Normal),
        )
        if (showBolt && snapshot.isCharging) {
            Spacer(GlanceModifier.width(3.dp))
            // 图标没有下伸区，整个 descent 都要垫。高度给足再用 padding 顶——
            // 只写 `size(13.dp).padding(bottom = …)` 的话内边距是往里啃的，
            // 图标会被压成一个小点（真机上就是这个样子）。
            Image(
                provider = ImageProvider(R.drawable.ic_widget_bolt),
                contentDescription = "充电中",
                modifier = GlanceModifier
                    .width(13.dp)
                    .height(13.dp + descent.dp)
                    .padding(bottom = descent.dp),
                colorFilter = ColorFilter.tint(WidgetPalette.accent),
            )
        }
        Spacer(GlanceModifier.defaultWeight())
        snapshot.rangeKm?.takeIf { showRange }?.let {
            Text(
                text = "$rangePrefix$it km",
                maxLines = 1,
                modifier = GlanceModifier.padding(bottom = baselinePad(rangeSize)),
                style = TextStyle(color = WidgetPalette.secondaryText, fontSize = rangeSize),
            )
        }
    }
}

/// 电量条；增程车再叠一条同款油量条，各带一个小图标区分（和 iOS `SnapshotEnergyBars` 一致）。
/// 纯电车没有油量数据，只画电量一条，也不加图标——一条条的时候没什么要区分的。
@Composable
private fun EnergyBars(snapshot: VehicleSnapshot, topPadding: Dp) {
    val fuel = snapshot.gasolinePercent
    Column(modifier = GlanceModifier.fillMaxWidth().padding(top = topPadding)) {
        if (fuel == null) {
            EnergyBar(
                progress = snapshot.soc,
                color = if (snapshot.isCharging) WidgetPalette.accent else WidgetPalette.accentSoft,
                modifier = GlanceModifier.fillMaxWidth(),
            )
        } else {
            LabeledEnergyBar(
                icon = R.drawable.ic_widget_bolt,
                progress = snapshot.soc,
                color = if (snapshot.isCharging) WidgetPalette.accent else WidgetPalette.accentSoft,
            )
            Spacer(GlanceModifier.height(3.dp))
            LabeledEnergyBar(
                icon = R.drawable.ic_widget_fuel,
                progress = fuel,
                color = WidgetPalette.accentSoft,
            )
        }
    }
}

@Composable
private fun LabeledEnergyBar(icon: Int, progress: Int?, color: androidx.glance.unit.ColorProvider) {
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Vertical.CenterVertically) {
        Image(
            provider = ImageProvider(icon),
            contentDescription = null,
            modifier = GlanceModifier.size(9.dp),
            colorFilter = ColorFilter.tint(WidgetPalette.tertiaryText),
        )
        Spacer(GlanceModifier.width(5.dp))
        EnergyBar(progress = progress, color = color, modifier = GlanceModifier.defaultWeight())
    }
}

@Composable
private fun EnergyBar(progress: Int?, color: androidx.glance.unit.ColorProvider, modifier: GlanceModifier) {
    LinearProgressIndicator(
        progress = ((progress ?: 0) / 100f).coerceIn(0f, 1f),
        modifier = modifier.height(5.dp).cornerRadius(3.dp),
        color = color,
        backgroundColor = WidgetPalette.track,
    )
}

/// 充电时的剩余时间和功率。只画读得到的那一项，两项都读不到时调用方就不该摆这一行
/// （见 `VehicleSnapshot.hasChargeMetrics`）。
@Composable
private fun ChargeMetricsLine(snapshot: VehicleSnapshot, showsPower: Boolean = true) {
    Row(
        modifier = GlanceModifier.fillMaxWidth().padding(top = 6.dp),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        snapshot.chargeRemainingText?.let { remaining ->
            Image(
                provider = ImageProvider(R.drawable.ic_widget_clock),
                contentDescription = null,
                modifier = GlanceModifier.size(10.dp),
                colorFilter = ColorFilter.tint(WidgetPalette.accent),
            )
            Spacer(GlanceModifier.width(3.dp))
            Text(remaining, maxLines = 1, style = TextStyle(color = WidgetPalette.accent, fontSize = 11.sp))
        }
        if (showsPower) {
            snapshot.chargePowerText?.let { power ->
                Spacer(GlanceModifier.width(8.dp))
                Image(
                    provider = ImageProvider(R.drawable.ic_widget_bolt),
                    contentDescription = null,
                    modifier = GlanceModifier.size(10.dp),
                    colorFilter = ColorFilter.tint(WidgetPalette.accent),
                )
                Spacer(GlanceModifier.width(3.dp))
                Text(power, maxLines = 1, style = TextStyle(color = WidgetPalette.accent, fontSize = 11.sp))
            }
        }
    }
}

/// 那句最该被看到的话。刚失败过的话，失败原因优先——五分钟内它比车况重要。
///
/// 时效只在数据**旧过半小时**时才跟在后面（琥珀色）；大卡例外，它一直写
/// （[alwaysFreshness]）——那张卡上有一颗刷新键，按下去要看得见「刚刚」才知道按生效了。
/// 这边后台那趟是 15 分钟一次，车休眠时更是拉回同一份旧数据，真旧了必须说出来，
/// 不能让人以为卡上写的是此刻的车。
@Composable
private fun StatusLine(
    snapshot: VehicleSnapshot,
    fontSize: androidx.compose.ui.unit.TextUnit = 11.sp,
    textAlign: TextAlign = TextAlign.Start,
    compactFreshness: Boolean = false,
    alwaysFreshness: Boolean = false,
) {
    val failure = WidgetControlFeedback.recentFailure
    val stale = snapshot.isStale
    // 中卡只有半张卡的宽度可用，「车窗未关闭 · 更新于 1 小时前」放不下，
    // 而被切掉的正好是句尾的时效。丢掉「更新于」三个字换整句读得完（锁车卡上
    // 同一个取舍，见 `LockWidget.StatusLine`）。
    val freshness = if (compactFreshness) {
        snapshot.freshnessText.removePrefix("更新于 ").removePrefix("读取于 ")
    } else {
        snapshot.freshnessText
    }
    val text = when {
        // 失败时不拼时效：那一刻要说的是「刚才那下没成」，几分钟前的车况不相干。
        failure != null -> failure
        stale -> "${snapshot.headline} · $freshness"
        alwaysFreshness -> "${snapshot.headline} · ${snapshot.freshnessCompact}"
        else -> snapshot.headline
    }
    Text(
        text = text,
        maxLines = 1,
        style = TextStyle(
            color = when {
                failure != null -> WidgetPalette.warm
                stale || snapshot.needsAttention -> WidgetPalette.caution
                else -> WidgetPalette.secondaryText
            },
            fontSize = fontSize,
            fontWeight = FontWeight.Medium,
            textAlign = textAlign,
        ),
    )
}

// MARK: - 控车按钮

/// 卡片上唯一的按钮样式：圆角方块，**图标在上、文字在下**。
/// 三种版式共用它，看起来才是一家人——对齐 iOS `ActionTile`。
@Composable
internal fun ActionTile(
    icon: Int,
    title: String,
    tint: WidgetTint,
    prominent: Boolean,
    action: Action,
    height: Dp,
    modifier: GlanceModifier,
) {
    val foreground = WidgetPalette.tileForeground(tint, prominent)
    Box(
        modifier = modifier
            .height(height)
            .cornerRadius(14.dp)
            .background(WidgetPalette.tileFill(tint, prominent))
            .clickable(action),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            Image(
                provider = ImageProvider(icon),
                contentDescription = title,
                modifier = GlanceModifier.size(17.dp),
                colorFilter = ColorFilter.tint(foreground),
            )
            Spacer(GlanceModifier.height(4.dp))
            Text(
                text = title,
                maxLines = 1,
                style = TextStyle(
                    color = foreground,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                ),
            )
        }
    }
}

@Composable
internal fun ConfiguredActionTile(action: WidgetAction, snapshot: VehicleSnapshot, height: Dp, modifier: GlanceModifier) {
    val appearance = WidgetActionAppearance.of(action, snapshot)
    ActionTile(
        icon = appearance.icon,
        title = appearance.title,
        tint = appearance.tint,
        prominent = appearance.prominent,
        action = actionFor(action, desiredLock = if (action == WidgetAction.ToggleLock) snapshot.lockActionTarget else null),
        height = height,
        modifier = modifier,
    )
}

/// 锁状态的字形和配色。两张卡共用一份，免得同一台车在两处显示成两个样子。
///
/// 读不到时既不画闭锁也不画开锁，改画一个警示号：一把闭锁就是在断言「锁好了」，
/// 而这时候并不知道。
internal fun lockIcon(locked: Boolean?): Int = when (locked) {
    true -> R.drawable.ic_widget_lock
    false -> R.drawable.ic_widget_lock_open
    null -> R.drawable.ic_widget_warning
}

internal fun lockTint(locked: Boolean?): WidgetTint = when (locked) {
    true -> WidgetTint.Accent
    false -> WidgetTint.Caution
    null -> WidgetTint.Neutral
}
