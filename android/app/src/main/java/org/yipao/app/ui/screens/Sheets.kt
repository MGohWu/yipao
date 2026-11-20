package org.yipao.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Blinds
import androidx.compose.material.icons.outlined.BlindsClosed
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.yipao.app.R
import org.yipao.app.app.VehicleStore
import org.yipao.app.core.CarTypeFamily
import org.yipao.app.core.LeapCommand
import org.yipao.app.core.VehicleState
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.GlassBottomSheet
import org.yipao.app.ui.components.LiquidSlider
import org.yipao.app.ui.components.MetricValue
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.components.sheetTile
import org.yipao.app.ui.freshnessText
import org.yipao.app.ui.theme.LeapColors

/// 首页的控车弹窗（车窗 / 尾门 / 胎压 / 遮阳帘 / 天窗 / 前备箱）。弹窗不走导航，
/// 由 HomeScreen 的状态触发；都是常驻声明 + visible 控制显隐，见 GlassBottomSheet 的注释。
///
/// 全部弹窗共用一条规矩：车没上报状态就一个按钮都不点亮。猜一个「关着」点上去，
/// 等于替车说了句它没说过的话。

@Composable
private fun SheetHeader(title: String, subtitle: String, alert: Boolean = false) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = subtitle,
            style = MaterialTheme.typography.bodySmall,
            color = if (alert) LeapColors.caution else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

@Composable
private fun SheetFootnote(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.outline,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 14.dp),
        textAlign = TextAlign.Center,
    )
}

/// 车窗开度的说法。0 是关、100 是全开，中间报百分比。
internal fun describeWindowOpenness(value: Int): String = when {
    value <= 0 -> "已关"
    value >= 100 -> "全开"
    else -> "开 $value%"
}

/// 车窗弹窗：滑杆调开度（松手下发）+ 档位快捷钮。
///
/// 零跑远控只接受一个开度值、两侧前窗一起动，所以是一个统一的位置滑杆，
/// 而不是左右各一个——双滑杆能摆出发不出去的组合。
///
/// 滑杆只给刻度连续、且下发和上报是同一套刻度的车型（S01 / T03）。C11 那组下发 0…10、
/// 上报 0…100，两边不是一套，拖到哪儿都不会有对得上的回音，所以只给档位钮。
@Composable
fun WindowSheet(visible: Boolean, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val state = store.state
    val carType = store.session.selectedCarType
    val showsSlider = LeapCommand.windowSupportsSlider(carType)
    val presets = LeapCommand.windowPresets(carType)
    val tileShape = RoundedCornerShape(18.dp)

    var openness by remember { mutableFloatStateOf(0f) }
    /// 打开弹窗时车上的开度，也就是「已经下发过的那个值」。手指按上滑杆再原地松开
    /// 也会走一次结束回调，拿它挡掉那种「没挪动」的下发。
    var committed by remember { mutableIntStateOf(-1) }
    /// 车到底停在哪个开度，是不是知道。有的车只报「开没开」不报开度（C11 增程版实测），
    /// 那时一个档位都不点亮，等用户自己按了才算数。
    var knowsPosition by remember { mutableStateOf(false) }

    // 弹窗常驻，滑杆位置不会自己清掉，每次打开按当前车况重新起。
    LaunchedEffect(visible) {
        if (!visible) return@LaunchedEffect
        val reported = state?.maxWindowOpenness
        // 车不报开度但报了「关着」，那位置就是 0，这一条是知道的。
        val closedByFlag = state?.anyWindowOpen == false
        val current = reported ?: if (closedByFlag) 0 else null
        knowsPosition = current != null
        openness = (current ?: 0).toFloat()
        // 位置不知道时给个不可能相等的值，免得第一次下发被「没挪动」那条挡掉。
        committed = current ?: -1
    }

    val subtitle = when {
        !knowsPosition && state?.anyWindowOpen == true -> "两侧前窗同时调节 · 车窗当前已开"
        showsSlider -> "两侧前窗同时调节 · 松手即下发"
        else -> "两侧前窗同时调节"
    }

    // 下发完就收起弹窗：结果提示贴在根视图底部，弹窗开着会把它整个盖住。
    fun send(value: Int) {
        knowsPosition = true
        committed = value
        store.applyWindows(value)
        onDismiss()
    }

    GlassBottomSheet(visible = visible, onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            SheetHeader("车窗", subtitle)

            if (showsSlider) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .sheetTile(tileShape)
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = describeWindowOpenness(openness.toInt()),
                        fontSize = 30.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    LiquidSlider(
                        value = openness,
                        onValueChange = { openness = it },
                        // 拖动途中一条都不发：十个刻度一路划过去就是十条控车指令，
                        // 车根本跟不上，用户也说不清最后停在哪一格。
                        onValueChangeFinished = {
                            val value = openness.toInt()
                            if (value != committed && !store.isSendingCommand) send(value)
                        },
                        valueRange = 0f..100f,
                        step = 10f,
                        tint = LeapColors.cool,
                    )
                }
            }

            // 按车型能力渲染，从开到关排——和滑杆「往右越开」的方向一致。
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                presets.reversed().forEach { preset ->
                    val selected = knowsPosition && openness.toInt() == preset.openness
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .weight(1f)
                            .height(44.dp)
                            .pressable(
                                onClick = {
                                    openness = preset.openness.toFloat()
                                    send(preset.openness)
                                },
                                enabled = !store.isSendingCommand,
                                shape = tileShape,
                                role = Role.RadioButton,
                            )
                            .sheetTile(tileShape)
                            .then(
                                if (selected) Modifier.background(LeapColors.cool.copy(alpha = 0.16f))
                                else Modifier
                            ),
                    ) {
                        Text(
                            text = preset.label,
                            style = MaterialTheme.typography.labelLarge,
                            color = if (selected) LeapColors.cool else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }

            // 这句只对 S01 说过，别因为别的车型也有了滑杆就跟着冒出来——
            // 后窗能不能远控是单车型的实测结论，和接口口径分组是两回事。
            if (CarTypeFamily.isS01(carType)) {
                SheetFootnote("该车型的后窗不支持远程控制。")
            }
        }
    }
}

/// 尾门弹窗。
///
/// 不做「点一下就反转」：手机在兜里蹭一下，尾门就在车主看不见的地方掀起来，
/// 而且那个方向是 App 替他判的——车况读不到时判的还可能是反的。
/// 这里把方向交回给用户：开和关都摆出来，点哪个发哪个。
@Composable
fun TrunkSheet(visible: Boolean, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val state = store.state
    val reportedOpen = state?.trunkOpen
    val isDriving = state?.isDriving == true
    // S01 / T03 关不了尾门，那个按钮在这些车上就不该出现。
    val supportsClose = LeapCommand.trunkSupportsClose(store.session.selectedCarType)

    val subtitle = when {
        isDriving -> "行驶中不能操作尾门"
        reportedOpen == null -> "该车型未上报尾门状态"
        reportedOpen -> "尾门当前已打开"
        else -> "尾门当前已关闭"
    }

    GlassBottomSheet(visible = visible, onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            SheetHeader("尾门", subtitle)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                SheetActionButton(
                    title = "打开尾门",
                    icon = ImageVector.vectorResource(R.drawable.ic_car_side_rear_open),
                    // 点亮的是「车现在停在这一侧」，和车窗弹窗的档位钮一个意思。
                    selected = reportedOpen == true,
                    enabled = !isDriving && !store.isSendingCommand,
                    modifier = Modifier.weight(1f),
                ) {
                    store.setTrunk(open = true)
                    onDismiss()
                }
                if (supportsClose) {
                    SheetActionButton(
                        title = "关闭尾门",
                        // 开/关两个动作共用同一张尾门图：CBI 这套是动作图标，没有配套的关闭态，
                        // 靠标题和点亮态区分足够，硬凑一张「车身完整」缩到 28dp 就认不出是车了。
                        icon = ImageVector.vectorResource(R.drawable.ic_car_side_rear_open),
                        selected = reportedOpen == false,
                        enabled = !isDriving && !store.isSendingCommand,
                        modifier = Modifier.weight(1f),
                    ) {
                        store.setTrunk(open = false)
                        onDismiss()
                    }
                }
            }
            // 只剩一个按钮的界面不说明白，看着像另一个没加载出来。
            if (!supportsClose) SheetFootnote("该车型不支持远程关闭尾门。")
        }
    }
}

/// 遮阳帘 / 天窗 / 前备箱这三个「开或关」的控制。三个界面完全同构，只有文案、
/// 图标、状态来源和行驶中拦不拦不一样，抽成一个。
enum class TwoStateControl {
    Sunshade,
    Sunroof,
    Frunk;

    val title: String
        get() = when (this) {
            Sunshade -> "遮阳帘"
            Sunroof -> "天窗"
            Frunk -> "前备箱"
        }

    val openTitle: String get() = "打开$title"
    val closeTitle: String get() = "关闭$title"

    // 前备箱那两态取的是 drawable，getter 只能是 @Composable 的。
    val openIcon: ImageVector
        @Composable get() = when (this) {
            Sunshade -> Icons.Outlined.Blinds
            // Material 里没有天窗图形，开 / 关各用一个到顶 / 到底的箭头示意方向。
            Sunroof -> Icons.Outlined.ArrowUpward
            Frunk -> ImageVector.vectorResource(R.drawable.ic_car_side_front_open)
        }

    val closeIcon: ImageVector
        @Composable get() = when (this) {
            Sunshade -> Icons.Outlined.BlindsClosed
            Sunroof -> Icons.Outlined.ArrowDownward
            // 同尾门：前备箱开 / 关共用一张前盖图，靠标题和点亮态区分。
            Frunk -> ImageVector.vectorResource(R.drawable.ic_car_side_front_open)
        }

    /// 车报没报当前状态。读不到（null）时副标题用 [noStatusText] 交代。
    /// 遮阳帘开度信号 `1724`、天窗开度信号 `1718`（2026-11-19 起，同 iOS）；天窗报 15 / 150
    /// 这类占位值时 `sunroofOpen` 已经当读不到处理。不报的车仍是 null。
    fun reportedOpen(state: VehicleState?): Boolean? = when (this) {
        Sunshade -> state?.sunshadeOpen
        Sunroof -> state?.sunroofOpen
        Frunk -> state?.frontTrunkOpen
    }

    val noStatusText: String
        get() = when (this) {
            Sunshade -> "车辆不上报遮阳帘状态"
            Sunroof -> "车辆不上报天窗状态"
            Frunk -> "该车型未上报前备箱状态"
        }

    /// 行驶中要不要禁用。`perform` 里按 cmdid 还有一道拦截，这里是界面上先说清楚。
    val blocksWhileDriving: Boolean get() = this == Frunk

    fun send(store: VehicleStore, open: Boolean) = when (this) {
        Sunshade -> store.setSunshade(open)
        Sunroof -> store.setSunroof(open)
        Frunk -> store.setFrunk(open)
    }
}

@Composable
fun TwoStateControlSheet(kind: TwoStateControl, visible: Boolean, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val state = store.state
    val reportedOpen = kind.reportedOpen(state)
    val isDriving = kind.blocksWhileDriving && state?.isDriving == true

    val subtitle = when {
        isDriving -> "行驶中不能操作${kind.title}"
        reportedOpen == null -> kind.noStatusText
        reportedOpen -> "${kind.title}当前已打开"
        else -> "${kind.title}当前已关闭"
    }

    GlassBottomSheet(visible = visible, onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            SheetHeader(kind.title, subtitle)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                SheetActionButton(
                    title = kind.openTitle,
                    icon = kind.openIcon,
                    selected = reportedOpen == true,
                    enabled = !isDriving && !store.isSendingCommand,
                    modifier = Modifier.weight(1f),
                ) {
                    kind.send(store, true)
                    onDismiss()
                }
                SheetActionButton(
                    title = kind.closeTitle,
                    icon = kind.closeIcon,
                    selected = reportedOpen == false,
                    enabled = !isDriving && !store.isSendingCommand,
                    modifier = Modifier.weight(1f),
                ) {
                    kind.send(store, false)
                    onDismiss()
                }
            }
        }
    }
}

/// 弹窗里的一个方向按钮。竖排图标+文字，选中态代表「车现在停在这一侧」。
@Composable
private fun SheetActionButton(
    title: String,
    icon: ImageVector,
    selected: Boolean,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(18.dp)
    val tint = when {
        !enabled -> MaterialTheme.colorScheme.outline
        selected -> LeapColors.cool
        else -> MaterialTheme.colorScheme.onSurface
    }
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier
            .pressable(onClick = onClick, enabled = enabled, shape = shape, role = Role.Button)
            .sheetTile(shape)
            .then(if (selected) Modifier.background(LeapColors.cool.copy(alpha = 0.16f)) else Modifier)
            .padding(vertical = 14.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.labelLarge,
            color = tint,
            maxLines = 1,
        )
    }
}

/// 胎压弹窗：2×2 四轮俯视布局，中间是车身俯视示意。
///
/// 只读：胎压没有对应的远控命令，车端也不上报推荐值，所以不给「标准范围」，
/// 只如实显示数值和车端自己的告警位。
@Composable
fun TireSheet(visible: Boolean, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val state = store.state
    val tires = state?.tirePressures.orEmpty()
    val hasData = state?.hasTireData == true

    GlassBottomSheet(visible = visible, onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            val warning = state?.hasTireWarning == true
            SheetHeader("胎压", if (warning) "有轮胎胎压异常" else "四轮胎压正常", alert = warning)

            if (!hasData || tires.size < 4) {
                // 一条读数都没有时不摆四个「--」——那看着像界面加载失败。
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 40.dp),
                ) {
                    Icon(
                        Icons.Outlined.Speed,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.outline,
                        modifier = Modifier.size(30.dp),
                    )
                    Text(
                        text = "车辆暂未上报胎压",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 8.dp),
                ) {
                    Column(
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.spacedBy(40.dp),
                    ) {
                        TireReading(tires[0], alignEnd = true)
                        TireReading(tires[2], alignEnd = true)
                    }
                    CarTopView(modifier = Modifier.padding(horizontal = 24.dp))
                    Column(
                        horizontalAlignment = Alignment.Start,
                        verticalArrangement = Arrangement.spacedBy(40.dp),
                    ) {
                        TireReading(tires[1], alignEnd = false)
                        TireReading(tires[3], alignEnd = false)
                    }
                }
                SheetFootnote(
                    store.lastUpdated?.let { freshnessText(state.reportedAt, it) }
                        ?: "胎压随车况一起更新"
                )
            }
        }
    }
}

@Composable
private fun TireReading(tire: org.yipao.app.core.TirePressure, alignEnd: Boolean) {
    val align = if (alignEnd) Alignment.End else Alignment.Start
    val color = if (tire.warning) LeapColors.caution else MaterialTheme.colorScheme.onSurface
    Column(horizontalAlignment = align) {
        // 读不到就写 `--`，不拿 0 kPa 冒充读数。
        MetricValue(
            value = tire.kPa?.let { it.toInt().toString() } ?: "--",
            unit = "kPa",
            valueSize = 24,
        )
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            if (tire.warning) {
                Icon(
                    Icons.Outlined.WarningAmber,
                    contentDescription = null,
                    tint = LeapColors.caution,
                    modifier = Modifier.size(12.dp),
                )
            }
            Text(
                text = tire.label,
                style = MaterialTheme.typography.labelSmall,
                color = if (tire.warning) color else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/// 车身俯视示意：一条车身 + 贴在四角支出去的四个轮子。头部圆角大、尾部圆角小指明朝向，
/// 四个轮子画出来俯视图一眼就认得出是车，也跟四张胎压卡一一对上。
/// 原来只用两个后视镜标朝向，反被误读成车胎、以为掉了两个轮子——现在直接画四个轮子。
@Composable
private fun CarTopView(modifier: Modifier = Modifier) {
    val body = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.28f)
    val wheel = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .width(56.dp)
                .height(150.dp)
                .clip(
                    RoundedCornerShape(
                        topStart = 28.dp, topEnd = 28.dp,
                        bottomStart = 14.dp, bottomEnd = 14.dp,
                    )
                )
                .background(body),
        )
        // 四个轮子：上排前轮、下排后轮，贴着车身两侧各支出去一截，跟前/后排胎压卡对齐。
        // 三元组是(对齐角, 横偏移, 纵偏移)：正的横偏移往右、正的纵偏移往下。
        for ((align, dx, dy) in listOf(
            Triple(Alignment.TopStart, -5, 26),
            Triple(Alignment.TopEnd, 5, 26),
            Triple(Alignment.BottomStart, -5, -26),
            Triple(Alignment.BottomEnd, 5, -26),
        )) {
            Box(
                modifier = Modifier
                    .align(align)
                    .offset(x = dx.dp, y = dy.dp)
                    .size(10.dp, 22.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(wheel),
            )
        }
    }
}
