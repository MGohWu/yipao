package org.yipao.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.VolumeUp
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.outlined.AcUnit
import androidx.compose.material.icons.outlined.Blinds
import androidx.compose.material.icons.outlined.BlindsClosed
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.LocalGasStation
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Roofing
import androidx.compose.material.icons.outlined.Route
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.outlined.WbSunny
import androidx.compose.material.icons.outlined.Window
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.yipao.app.R
import org.yipao.app.app.VehicleStore
import org.yipao.app.core.CarLayerComposer
import org.yipao.app.core.ClimateMode
import org.yipao.app.core.LeapFormat
import org.yipao.app.core.VehicleState
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.Routes
import org.yipao.app.ui.components.AMapView
import org.yipao.app.ui.components.CarModel3DView
import org.yipao.app.ui.components.CarSilhouette
import org.yipao.app.ui.components.EnergyBar
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.HairlineDivider
import org.yipao.app.ui.components.LiquidIconButton
import org.yipao.app.ui.components.MetricValue
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.StatusPill
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.components.VerticalHairline
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.freshnessText
import org.yipao.app.ui.theme.LeapColors
import kotlinx.coroutines.delay

/// 车辆首页：标题 → 车辆主视觉 + 状态徽章 → 快控条 → 电量/空调卡 → 状态条 → 位置卡。
/// 结构与文案判据全部对齐 iOS HomeView，视觉按 Material 3 Expressive 重排。
///
/// 全页遵守「读不到就别显示」：车况没到手就是 `--` 或整行不画，绝不拿默认值顶上去。
/// 首页的六个控车弹窗。
private enum class HomeSheet { Window, Trunk, Tire, Sunshade, Sunroof, Frunk }

@Composable
fun HomeScreen(
    contentPadding: PaddingValues,
    onOpen: (String) -> Unit,
    active: Boolean = true,
) {
    val store = LocalStore.current
    val state = store.state

    // 车辆页：充电时转绿；否则空调开着就跟制冷/制热走；其余冷蓝（同 iOS HomeView）。
    if (active) PageTint(
        when {
            state?.isCharging == true -> LeapColors.accent
            store.climateOn -> if (store.climateMode == ClimateMode.Hot) LeapColors.warm else LeapColors.cool
            else -> LeapColors.cool
        }
    )

    var sheet by remember { mutableStateOf<HomeSheet?>(null) }
    // 弹窗常驻声明，靠 visible 控制显隐：写成 if (sheet == ...) 的话
    // 一收起组件就没了，退场动画来不及播。
    WindowSheet(visible = sheet == HomeSheet.Window, onDismiss = { sheet = null })
    TrunkSheet(visible = sheet == HomeSheet.Trunk, onDismiss = { sheet = null })
    TireSheet(visible = sheet == HomeSheet.Tire, onDismiss = { sheet = null })
    TwoStateControlSheet(TwoStateControl.Sunshade, visible = sheet == HomeSheet.Sunshade) { sheet = null }
    TwoStateControlSheet(TwoStateControl.Sunroof, visible = sheet == HomeSheet.Sunroof) { sheet = null }
    TwoStateControlSheet(TwoStateControl.Frunk, visible = sheet == HomeSheet.Frunk) { sheet = null }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(contentPadding)
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // 标题：车名 + 车况新鲜度/异常播报
        Column(modifier = Modifier.padding(top = PageTitleTopPadding)) {
            Text(
                text = store.vehicleName,
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = homeSubtitle(store),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // 车辆主视觉 + 徽章。锁好了是常态不上色，只有「反常」的那几档才上色。
        // 车这块自己要留出呼吸：不留的话车顶贴着副标题、车尾贴着徽章和快控条，
        // 整屏挤成一坨。比 iOS 的 VehicleHero（10 / 6 / 4）再宽一档——
        // 安卓的标题字号更大，同样的数值在这边显得更紧。
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 16.dp, bottom = 4.dp),
        ) {
            VehicleHero(active)
            StatusBadges(state)
        }

        QuickControlRow(
            onTrunk = { sheet = HomeSheet.Trunk },
            onSunshade = { sheet = HomeSheet.Sunshade },
            onSunroof = { sheet = HomeSheet.Sunroof },
            onFrunk = { sheet = HomeSheet.Frunk },
        )

        // 电量卡 + 空调卡
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Max),
        ) {
            BatteryCard(modifier = Modifier.weight(1f), onClick = { onOpen(Routes.Charge) })
            ClimateCard(modifier = Modifier.weight(1f), onClick = { onOpen(Routes.Climate) })
        }

        StatusStrip(
            onWindow = { sheet = HomeSheet.Window },
            onTire = { sheet = HomeSheet.Tire },
            onMileage = { onOpen(Routes.Mileage) },
        )
        LocationCard(onClick = { onOpen(Routes.Location) })

        // 隐私说明
        Row(
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 2.dp, bottom = 8.dp),
        ) {
            Icon(
                Icons.Filled.Shield,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.outline,
                modifier = Modifier.size(12.dp),
            )
            Text(
                text = " 我们不会记录和上传零跑官方服务的会话信息，控车信息等其他信息。",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.outline,
            )
        }
    }
}

/// 车名底下那句话。优先级同 iOS：正在等车响应 > 没车况 > 车门没关 > 胎压异常 > 新鲜度。
///
/// 异常排在新鲜度前面：一句「车况刚刚更新」再准，也不该盖过「有车门未关闭」。
private fun homeSubtitle(store: VehicleStore): String {
    store.confirmingLabel?.let { return "$it · 等待车辆响应…" }
    val state = store.state ?: return if (store.isRefreshing) "正在读取车况…" else "等待车况"
    if (state.anyDoorOpen) return "有车门未关闭"
    if (state.hasTireWarning) return "胎压异常，请尽快检查"
    val fetchedAt = store.lastUpdated ?: return chargeLabel(state)
    return freshnessText(state.reportedAt, fetchedAt)
}

/// 电量卡的标题，也是没有拉取时间时首页副标题的兜底。
private fun chargeLabel(state: VehicleState?): String = when (state?.chargeState) {
    1 -> if (state.isFastCharging) "充电中 · 直流快充" else "充电中"
    2 -> "充电完成"
    3 -> "充电故障"
    4 -> "预约充电等待"
    6 -> "充电暂停"
    else -> "电量"
}

/// 车辆主视觉。三层回退：3D → 按车况叠出来的官方 2D 车图 → 手绘剪影。
///
/// 静态那层一直垫在底下：3D 渲不出来时（车型没适配、WebGL 挂了）它就是最终画面，
/// 而不是留一块空白；3D 出来了再淡入盖上去。
@Composable
private fun VehicleHero(active: Boolean) {
    val store = LocalStore.current
    val root = store.carModelRoot
    val revision = store.carModelRevision
    val param = store.carModel?.modelParam
    var is3DReady by remember { mutableStateOf(false) }
    var is3DFailed by remember { mutableStateOf(false) }
    // 资源被撤走或换成另一台车的目录时必须把就绪/失败位清掉：撤走后 is3DReady 还是
    // true 的话，静态那层会一直全透明——剪影明明在层里却什么都看不见；换目录后
    // WebView 已经按 key(root) 重建，旧的就绪位不清则新模型加载期间盖着一块空画布。
    LaunchedEffect(root, revision) {
        is3DReady = false
        is3DFailed = false
    }
    val staticAlpha by animateFloatAsState(
        targetValue = if (is3DReady) 0f else 1f,
        animationSpec = tween(350),
        label = "carStaticAlpha",
    )
    Box(
        modifier = Modifier.fillMaxWidth(),
        contentAlignment = Alignment.Center,
    ) {
        if (root != null && param != null && !is3DFailed) {
            // 资源目录一换就整个重建 WebView：拦截器的 root 只在创建时捕获一次，
            // 不重建的话它会一直从上一台车的目录里取文件。
            key(root, revision) {
                CarModel3DView(
                    root = root,
                    param = param,
                    assetAlias = store.carAssetAlias,
                    state = store.state,
                    active = active,
                    onReady = { is3DReady = true },
                    onFailure = {
                        is3DFailed = true
                        is3DReady = false
                    },
                    // 3D 车的桌面小组件车图只能从这里来，包里没有 2D 图层可叠。
                    onSnapshot = { png -> store.adoptRenderedCarImage(png) },
                    // 画布比 2D 图那套高一点，给 3D 的取景余量留位置：模型转到某些角度
                    // （车头朝下那侧）下沿会顶出画布被切掉。车本身的大小靠 serverJSON 里
                    // 的 radius（相机距离）调，不靠撑画布。
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp),
                )
            }
        }
        // WebGL WebView 不能套 Compose alpha：它会生成 HWUI 离屏层，部分 Android 15
        // 设备会在 GLFunctorDrawable 绘制时拿到空 SkSurface 并 native 崩溃。3D 的淡入
        // 在页面内部对 canvas 做（见 CarModel3DView），这里只淡出盖在上面的静态车图。
        StaticVehicle(modifier = Modifier.alpha(staticAlpha))
    }
}

/// 按车况叠出来的官方车图，没有就退回剪影。也充当 3D 加载期间的占位。
@Composable
private fun StaticVehicle(modifier: Modifier = Modifier) {
    val store = LocalStore.current
    val composition = store.carComposition
    val cached = store.carImage
    Box(
        modifier = modifier.fillMaxWidth(),
        contentAlignment = Alignment.Center,
    ) {
        when {
            composition != null -> {
                // 三段是分开画的：充电层夹在车身和充电口盖中间，充电中要逐帧换。
                // 每段都是同一张 1125×525 的画布，用同一套约束就自动对齐。
                CarLayer(composition.base)
                ChargeLayer(composition)
                composition.top?.let { CarLayer(it) }
            }
            // 冷启动缓存的那张，图层还没叠好时先顶上。
            cached != null -> CarLayer(cached)
            else -> CarSilhouette(
                modifier = Modifier
                    .fillMaxWidth(0.82f)
                    .height(150.dp),
            )
        }
    }
}

/// 官方图层是透明背景的宽幅图（1125×525），车本身只占中间一条。
/// 按高度约束会缩得很小，所以让它按宽度铺开，和官方 App 一样占满整行。
///
/// 上限存在的理由：同一个包里也有 1125×1200 这种更方的画布，不设限会长到
/// 把下面的卡片顶下去。图层里自带渲染好的接地阴影，外面不能再叠阴影——
/// 那会沿着不透明像素糊出一块灰白方块。
@Composable
private fun CarLayer(bitmap: android.graphics.Bitmap) {
    Image(
        bitmap = bitmap.asImageBitmap(),
        // 纯装饰。锁车状态由下面那排徽章负责播报，这里再念一遍「汽车」是噪音。
        contentDescription = null,
        contentScale = ContentScale.Fit,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 200.dp),
    )
}

/// 充电层。充电中是 14–18 帧的循环动画（充电线一段段亮起来），
/// 其余状态是一张静态图（插枪待机 / 已充满）。
@Composable
private fun ChargeLayer(composition: CarLayerComposer.ComposedCar) {
    val frames = composition.chargeFrames
    if (frames.isEmpty()) return
    if (!composition.isAnimated) {
        CarLayer(frames.first())
        return
    }
    val interval = CarLayerComposer.FRAME_INTERVAL_MS
    // 用绝对时间取帧：车况刷新会换掉整个 composition，按帧计数的话每刷新一次
    // 动画就跳回第一帧。`remember` 不带 key，重组时这个计时器也不重来。
    var tick by remember { mutableLongStateOf(System.currentTimeMillis() / interval) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(interval)
            tick = System.currentTimeMillis() / interval
        }
    }
    CarLayer(frames[(tick % frames.size).toInt()])
}

/// 车模型底下那排徽章。只报「反常」和「行驶中」，一切正常时只剩一个不上色的「已锁车」。
///
/// 行驶中顶掉锁车徽章：车在动的时候「已锁车」是句废话，位置留给更要紧的那条。
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StatusBadges(state: VehicleState?) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        if (state?.isDriving == true) {
            Badge("行驶中", Icons.Outlined.Route, LeapColors.cool)
        } else if (state?.isLocked ?: true) {
            // 常态不上色：天天亮一格颜色等于每天报告一件没发生的事。
            StatusPill(text = "已锁车", icon = ImageVector.vectorResource(R.drawable.ic_car_door_lock))
        } else {
            Badge("已解锁", ImageVector.vectorResource(R.drawable.ic_car_door_lock_open), LeapColors.caution)
        }
        if (state?.trunkOpen == true) {
            Badge("尾门开启", ImageVector.vectorResource(R.drawable.ic_car_side_rear_open), LeapColors.caution)
        }
        if (state?.frontTrunkOpen == true) {
            Badge("前备箱开启", ImageVector.vectorResource(R.drawable.ic_car_side_front_open), LeapColors.caution)
        }
        if (state?.anyWindowOpen == true) Badge("车窗开启", Icons.Outlined.Window, LeapColors.caution)
        // 天窗和遮阳帘（2026-11-19 起，信号 `1718` / `1724`）只在车报了、且确实开着时出现。
        // 天窗开着跟车窗没关是一类事——下雨会进水——所以用告警色；遮阳帘开着不是隐患，
        // 跟哨兵一样用冷静色，只告诉你它开着。不报这两个信号的车（多数车型）照旧没有这两颗。
        if (state?.sunroofOpen == true) Badge("天窗开启", Icons.Outlined.WbSunny, LeapColors.caution)
        if (state?.sunshadeOpen == true) Badge("遮阳帘开启", Icons.Outlined.Blinds, LeapColors.cool)
        if (state?.sentinelOn == true) Badge("哨兵开启", Icons.Filled.Shield, LeapColors.cool)
    }
}

@Composable
private fun Badge(text: String, icon: ImageVector, tint: Color) {
    StatusPill(text = text, icon = icon, tint = tint, container = tint.copy(alpha = 0.16f))
}

/// 高频控车条：上锁 / 解锁 / 尾门 / 空调 / 鸣笛 + 车支持才出现的哨兵 / 遮阳帘 / 天窗 / 前备箱。
///
/// 对齐 iOS QuickControlBar：不给底色（激活靠图标+文字一起上色，不额外占一层色块），
/// 只有「反常」的那一档才上色。车不支持的控制整格隐藏，不是置灰——
/// 摆一个永远点不了的按钮等于承诺了做不到的事。
///
/// **「上锁」「解锁」是 2026-11-19 从翻转式「车锁」拆出来的**（同 iOS）：翻转式要先看清现在
/// 是什么状态才知道点下去会发什么，车况一滞后就会发反。拆开后方向写在按钮上，点哪个发哪个；
/// 状态改由「解锁」那格在车没锁时亮琥珀色来表达，两格都始终能点（车况可能滞后，重复上锁也无害）。
///
/// 超过一行（4 个）时收起成「前 4 个 + 行尾 chevron」，点 chevron 向下展开其余各行，每行 4 个。
/// iOS 那边还能长按拖拽排序并记住顺序（旧排序会在 `lock` 后补 `unlock`）；安卓这版没有拖拽、
/// 也没有存过排序，顺序固定，上锁 / 解锁这一对就排在原来「车锁」的位置。
@Composable
private fun QuickControlRow(
    onTrunk: () -> Unit,
    onSunshade: () -> Unit,
    onSunroof: () -> Unit,
    onFrunk: () -> Unit,
) {
    val store = LocalStore.current
    val state = store.state
    // 锁读不到按锁着画；尾门/前备箱读不到按关着画——开着是要提醒的异常，
    // 猜一个「开着」出来天天报警更糟。
    val locked = state?.isLocked ?: true
    val trunkOpen = state?.trunkOpen ?: false
    val frunkOpen = state?.frontTrunkOpen ?: false
    val isDriving = state?.isDriving == true
    val busy = store.isSendingCommand
    // buildList 的 lambda 不是 @Composable，drawable 得先在这儿取好再往里塞。
    val lockIcon = ImageVector.vectorResource(R.drawable.ic_car_door_lock)
    val unlockIcon = ImageVector.vectorResource(R.drawable.ic_car_door_lock_open)
    val trunkOpenIcon = ImageVector.vectorResource(R.drawable.ic_car_side_rear_open)
    val frunkOpenIcon = ImageVector.vectorResource(R.drawable.ic_car_side_front_open)

    val controls = buildList {
        // 上锁是回到常态，永远不上色。
        add(QuickControlSpec(label = "上锁", icon = lockIcon, onClick = store::lockCar))
        // 车没锁是要提醒的反常，由这一格亮琥珀色来说。读不到锁状态时按锁着画，不上色。
        add(
            QuickControlSpec(
                label = "解锁",
                icon = unlockIcon,
                tint = if (locked) null else LeapColors.caution,
                onClick = store::unlockCar,
            )
        )
        add(
            QuickControlSpec(
                label = "尾门",
                icon = trunkOpenIcon,
                tint = if (trunkOpen) LeapColors.caution else null,
                enabled = !isDriving,
                onClick = onTrunk,
            )
        )
        add(
            QuickControlSpec(
                label = "空调",
                icon = Icons.Outlined.AcUnit,
                tint = if (store.climateOn) LeapColors.cool else null,
                onClick = { store.applyClimate(on = !store.climateOn) },
            )
        )
        add(
            QuickControlSpec(
                label = "鸣笛",
                icon = Icons.AutoMirrored.Outlined.VolumeUp,
                onClick = store::honk,
            )
        )
        if (store.sentinelSupported) {
            // 哨兵有状态回读（信号 3636）也没有物理风险，就地 toggle，不弹层。
            add(
                QuickControlSpec(
                    label = "哨兵",
                    icon = if (store.sentinelOn) Icons.Filled.Shield else Icons.Outlined.Shield,
                    tint = if (store.sentinelOn) LeapColors.cool else null,
                    onClick = { store.applySentinel(!store.sentinelOn) },
                )
            )
        }
        // 遮阳帘和天窗多数车不报状态，图标不做两态、不上色；方向在弹层里由用户明确点。
        // 报了的车（1724 / 1718）状态在弹层副标题和首页徽章里说。
        if (store.sunshadeSupported) {
            add(QuickControlSpec("遮阳帘", Icons.Outlined.BlindsClosed, onClick = onSunshade))
        }
        if (store.sunroofSupported) {
            add(QuickControlSpec("天窗", Icons.Outlined.Roofing, onClick = onSunroof))
        }
        if (store.frunkSupported) {
            add(
                QuickControlSpec(
                    label = "前备箱",
                    icon = frunkOpenIcon,
                    tint = if (frunkOpen) LeapColors.caution else null,
                    enabled = !isDriving,
                    onClick = onFrunk,
                )
            )
        }
    }

    val rowCapacity = 4
    val overflow = controls.size > rowCapacity
    var expanded by rememberSaveable { mutableStateOf(false) }
    val firstRow = if (overflow) controls.take(rowCapacity) else controls
    // 展开部分按每行 4 个切开。拆出「解锁」之后全支持是 9 项，展开部分有 5 个，
    // 塞进一行会把 5 个挤进 4 格的宽度。
    val extraRows = if (overflow) controls.drop(rowCapacity).chunked(rowCapacity) else emptyList()

    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .fillMaxWidth()
                // iOS / 鸿蒙两端都在控制格外留 14 的左右边距。这里只留纵向边距时，
                // 行尾展开键会直接贴到卡片右缘，视觉上像被挤出去了。
                .padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Row(modifier = Modifier.fillMaxWidth()) {
                firstRow.forEach { QuickControl(it, busy, Modifier.weight(1f)) }
                // chevron 不占一个整格：它是布局开关不是控制项，占格会把四个真按钮挤瘦一号。
                if (overflow) ExpandChevron(expanded) { expanded = !expanded }
            }
            AnimatedVisibility(
                visible = overflow && expanded,
                enter = fadeIn(),
                exit = fadeOut(),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    extraRows.forEach { row ->
                        Row(modifier = Modifier.fillMaxWidth()) {
                            row.forEach { QuickControl(it, busy, Modifier.weight(1f)) }
                            // 不足一行时补空位，列和第一行对齐。
                            repeat(rowCapacity - row.size) { Spacer(modifier = Modifier.weight(1f)) }
                            Spacer(modifier = Modifier.width(24.dp))
                        }
                    }
                }
            }
        }
    }
}

/// 控车条上的一格。文案一律名词，当前状态靠图标和颜色表达。
private data class QuickControlSpec(
    val label: String,
    val icon: ImageVector,
    /// null = 常态，用中性主色。
    val tint: Color? = null,
    val enabled: Boolean = true,
    val onClick: () -> Unit,
)

/// 单个控车动作。iOS 同款：竖排图标+文字、无底色。
/// 图标尺寸不跟着激活变——涨一号那一列就和别的列不齐了。
@Composable
private fun QuickControl(spec: QuickControlSpec, busy: Boolean, modifier: Modifier = Modifier) {
    // 上一条还在等车确认时 `perform` 会把新指令直接丢掉，这里先挡住，
    // 免得点完是「什么都没发生、也没人说为什么」。
    val enabled = spec.enabled && !busy
    val tint = spec.tint ?: MaterialTheme.colorScheme.onSurface
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(7.dp),
        modifier = modifier
            .pressable(onClick = spec.onClick, enabled = enabled, shape = TileShape)
            .padding(vertical = 6.dp),
    ) {
        Icon(
            spec.icon,
            contentDescription = spec.label,
            tint = if (enabled) tint else MaterialTheme.colorScheme.outline,
            modifier = Modifier.size(24.dp),
        )
        Text(
            text = spec.label,
            style = MaterialTheme.typography.labelMedium,
            color = if (!enabled) {
                MaterialTheme.colorScheme.outline
            } else {
                spec.tint ?: MaterialTheme.colorScheme.onSurfaceVariant
            },
            maxLines = 1,
        )
    }
}

@Composable
private fun ExpandChevron(expanded: Boolean, onClick: () -> Unit) {
    val angle by animateFloatAsState(if (expanded) 180f else 0f, label = "chevron")
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .width(24.dp)
            .height(52.dp)
            .pressable(onClick = onClick, feedback = PressFeedback.Fade),
    ) {
        Icon(
            Icons.Outlined.ExpandMore,
            contentDescription = if (expanded) "收起更多控制" else "展开更多控制",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .size(18.dp)
                .rotate(angle),
        )
    }
}

/// 电量卡。增程车电/油分开报，两条细能量条并排叠放；纯电车没有油那条。
@Composable
private fun BatteryCard(modifier: Modifier = Modifier, onClick: () -> Unit) {
    val state = LocalStore.current.state
    GlassCard(
        shape = TileShape,
        onClick = onClick,
        modifier = modifier,
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .padding(16.dp)
                .fillMaxSize(),
        ) {
            Text(
                text = chargeLabel(state),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            MetricValue(value = state?.soc?.toString() ?: "--", unit = "%")
            // 续航读不到就整行不画，不写「-- km」占位。
            rangeText(state)?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(modifier = Modifier.weight(1f))
            LabeledBar(Icons.Outlined.Bolt) {
                // 充电上限没上报就不画那道刻度，别拿 100 顶上去。
                EnergyBar(percent = state?.soc ?: 0, limit = state?.chargeLimit, height = 7)
            }
            state?.gasolinePercent?.let { fuel ->
                LabeledBar(Icons.Outlined.LocalGasStation) {
                    EnergyBar(
                        percent = fuel,
                        fill = MaterialTheme.colorScheme.primary,
                        height = 7,
                    )
                }
            }
        }
    }
}

/// 续航那一行。增程车电油分开报才拆两段，其余就一个综合续航；都没有就不画。
private fun rangeText(state: VehicleState?): String? {
    if (state == null) return null
    val energy = state.energyRange
    val gasoline = state.gasolineRange
    if (state.hasFuel && energy != null && gasoline != null) return "电 $energy · 油 $gasoline km"
    return state.expectedMileage?.let { "$it km" }
}

@Composable
private fun LabeledBar(icon: ImageVector, bar: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(
            icon,
            contentDescription = null,
            tint = LeapColors.accent,
            modifier = Modifier.size(13.dp),
        )
        Box(modifier = Modifier.weight(1f)) { bar() }
    }
}

/// 空调卡。大数字是车内实测温度，设定值在下一行，右上角是开关。
///
/// 车内温度读不到时退到车外温度，并把标题一起改成「车外温度」——
/// 换的是另一个真实值、也改了口，不是拿车外温度冒充车内。
@Composable
private fun ClimateCard(modifier: Modifier = Modifier, onClick: () -> Unit) {
    val store = LocalStore.current
    val state = store.state
    val indoor = state?.indoorTemp
    val outdoor = state?.outdoorTemp
    val displayed = indoor ?: outdoor
    val title = when {
        indoor == null && outdoor != null -> "车外温度"
        store.climateOn -> "空调运行中"
        else -> "车内温度"
    }
    GlassCard(
        shape = TileShape,
        onClick = onClick,
        modifier = modifier,
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .padding(16.dp)
                .fillMaxSize(),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                LiquidIconButton(
                    icon = Icons.Outlined.PowerSettingsNew,
                    contentDescription = if (store.climateOn) "关闭空调" else "开启空调",
                    onClick = {
                        if (!store.isSendingCommand) store.applyClimate(on = !store.climateOn)
                    },
                    size = 34.dp,
                    iconSize = 16.dp,
                    container = if (store.climateOn) {
                        LeapColors.cool.copy(alpha = 0.18f)
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.12f)
                    },
                    tint = if (store.climateOn) {
                        LeapColors.cool
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
            MetricValue(
                value = displayed?.let { LeapFormat.temperature(it) } ?: "--",
                unit = "°C",
            )
            Spacer(modifier = Modifier.weight(1f))
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = if (store.climateOn) climateDetail(state) else "空调设置",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (store.climateOn) LeapColors.cool else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    Icons.Outlined.ChevronRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

/// 空调开着时那一行：设定温度 + 风量。两个都没报就直说「设定值未上报」。
private fun climateDetail(state: VehicleState?): String {
    val parts = buildList {
        state?.acSetting?.let { add("设定 $it °C") }
        state?.acFanLevel?.takeIf { it > 0 }?.let { add("$it 档") }
    }
    return if (parts.isEmpty()) "设定值未上报" else parts.joinToString(" · ")
}

/// 车门 / 车窗 / 胎压 / 里程一行四列。
@Composable
private fun StatusStrip(
    onWindow: () -> Unit,
    onTire: () -> Unit,
    onMileage: () -> Unit,
) {
    val store = LocalStore.current
    val state = store.state
    GlassCard(
        shape = TileShape,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min)
                .padding(vertical = 14.dp),
        ) {
            val doorOpen = state?.anyDoorOpen == true
            StatusColumn(
                icon = ImageVector.vectorResource(R.drawable.ic_car_door),
                value = if (state == null) "--" else if (doorOpen) "未关" else "已关",
                title = "车门",
                alert = doorOpen,
                modifier = Modifier.weight(1f),
            )
            StripDivider()
            StatusColumn(
                icon = Icons.Outlined.Window,
                value = windowSummary(state),
                title = "车窗",
                modifier = Modifier.weight(1f),
                // 车不支持远程控窗时这一格只读：点开一个发不出去的弹层没有意义。
                onClick = if (store.windowsControllable) onWindow else null,
            )
            StripDivider()
            StatusColumn(
                icon = Icons.Outlined.Speed,
                value = tireSummary(state),
                title = "胎压",
                alert = state?.hasTireWarning == true,
                modifier = Modifier.weight(1f),
                onClick = onTire,
            )
            StripDivider()
            val totalMileage = state?.totalMileage
            StatusColumn(
                icon = Icons.Outlined.Route,
                value = totalMileage?.toString() ?: "--",
                unit = if (totalMileage != null) "km" else null,
                title = "行程",
                // 另外三格永远是两个字，里程却可能有六位数字、单位和箭头。
                // 对齐鸿蒙的 1.3 倍列宽，避免窄屏上标题和值一起溢出。
                modifier = Modifier.weight(1.3f),
                onClick = onMileage,
            )
        }
    }
}

/// 车窗那一格。报开度的车说开度，只报开合的车说开合，都没报就是 `--`。
private fun windowSummary(state: VehicleState?): String {
    if (state == null) return "--"
    val open = state.anyWindowOpen ?: return "--"
    val openness = state.maxWindowOpenness
    if (openness != null && openness > 0) return describeWindowOpenness(openness)
    return if (open) "已开" else "已关"
}

/// 胎压那一格。一条读数都没有时不写「正常」——那是在替车说它没说过的话。
private fun tireSummary(state: VehicleState?): String {
    if (state == null || !state.hasTireData) return "--"
    return if (state.hasTireWarning) "异常" else "正常"
}

@Composable
private fun StripDivider() {
    VerticalHairline(height = 30.dp)
}

@Composable
private fun StatusColumn(
    icon: ImageVector,
    value: String,
    title: String,
    modifier: Modifier = Modifier,
    unit: String? = null,
    alert: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
        modifier = if (onClick != null) {
            modifier.pressable(onClick = onClick, feedback = PressFeedback.Fade)
        } else {
            modifier
        },
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (alert) LeapColors.caution else LeapColors.accent,
            modifier = Modifier.size(18.dp),
        )
        // 四格里只有部分点得进去，可它们和纯展示的那几格长得一模一样，等于没有标记。
        // 对齐 iOS：能点的格子给值套一层胶囊底，右边再缀一个箭头，一眼看得出哪几格是门。
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(1.dp),
            modifier = Modifier
                .then(
                    if (onClick != null) {
                        Modifier.background(
                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.10f),
                            CircleShape,
                        )
                    } else {
                        Modifier
                    },
                )
                // 纵向留白四格一律给。只给带胶囊的那几格，它们会比另外几格高出一截，
                // 底下那行标题就横不成一条线了。
                .padding(horizontal = if (onClick != null) 7.dp else 0.dp, vertical = 3.dp),
        ) {
            Text(
                text = value,
                style = MaterialTheme.typography.labelMedium,
                color = if (alert) LeapColors.caution else MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            if (unit != null) {
                Text(
                    text = unit,
                    style = MaterialTheme.typography.labelSmall.copy(fontSize = 9.sp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
            if (onClick != null) {
                Icon(
                    Icons.Outlined.ChevronRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(12.dp),
                )
            }
        }
        Text(
            text = title,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.outline,
        )
    }
}

/// 位置卡：上半是高德地图，下半是位置名。地图不收手势，整张卡点进详情页。
/// 坐标拿不到（隐私模式 / 车没报）时不画地图，只留那一行说明。
@Composable
private fun LocationCard(onClick: () -> Unit) {
    val store = LocalStore.current
    val coordinate = store.coordinate
    GlassCard(
        shape = TileShape,
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick,
    ) {
        Column {
            if (coordinate != null) {
                // 地图 + 居中的车辆标记。地图是张扎扎实实的不透明位图，不裁的话
                // 两个上角会盖住卡片的圆角，露出直角硬边。
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp)
                        .clip(RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)),
                ) {
                    AMapView(
                        latitude = coordinate.latitude,
                        longitude = coordinate.longitude,
                        // 卡片这么小，拉太近看不出在哪，退一档到街区级。
                        zoom = 15f,
                        interactive = false,
                        modifier = Modifier.fillMaxSize(),
                    )
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(34.dp)
                            .background(MaterialTheme.colorScheme.secondary, CircleShape),
                    ) {
                        Icon(
                            Icons.Filled.DirectionsCar,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSecondary,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
                HairlineDivider()
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = "车辆位置",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(
                            Icons.Filled.Place,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.secondary,
                            modifier = Modifier.size(14.dp),
                        )
                        Text(
                            text = locationSummary(store),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
                Icon(
                    Icons.Outlined.ChevronRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.outline,
                )
            }
        }
    }
}

/// 位置那一行。隐私模式、没定位、还没解析出名字，三种「没有地名」得分开说清楚，
/// 都写成「暂无定位」的话用户会以为是 App 坏了。
private fun locationSummary(store: VehicleStore): String {
    val state = store.state ?: return "读取中"
    if (!state.privacyGPSAllowed) return "隐私模式已开启"
    store.coordinate ?: return "暂无定位"
    return store.locationName
        ?: if (store.locationResolveFailed) "位置解析暂不可用" else "正在解析位置"
}
