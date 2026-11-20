package org.yipao.app.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AcUnit
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Air
import androidx.compose.material.icons.outlined.Bedtime
import androidx.compose.material.icons.outlined.Coffee
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Remove
import androidx.compose.material.icons.outlined.SensorWindow
import androidx.compose.material.icons.outlined.SevereCold
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material.icons.outlined.Whatshot
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.yipao.app.app.VehicleStore
import org.yipao.app.core.FridgeMode
import org.yipao.app.core.FridgePreset
import org.yipao.app.core.FridgeSetting
import org.yipao.app.core.FridgeStyle
import org.yipao.app.core.SeatComfortChannel
import org.yipao.app.core.SeatPosition
import org.yipao.app.core.fridgeState
import org.yipao.app.core.mirrorHeatingMismatched
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.AnchoredConfirmation
import org.yipao.app.ui.components.AnchoredOverlayBox
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.LiquidButton
import org.yipao.app.ui.components.LiquidGlassButton
import org.yipao.app.ui.components.LiquidIconButton
import org.yipao.app.ui.components.LiquidSlider
import org.yipao.app.ui.components.LiquidSwitch
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.SubPageAction
import org.yipao.app.ui.components.SubPageScaffold
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.components.liquidGlass
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.theme.LeapColors
import java.util.Calendar

// MARK: - 舒适座舱

/// 舒适座舱：座椅加热 / 通风、方向盘加热、后视镜加热。对应 iOS `ComfortCabinView`。
///
/// 和空调页最大的不同是**这一页的状态是真的**：八个座椅信号、方向盘的 `1816`、
/// 后视镜的 `49`/`50` 全在车主 C16 的真实 signalMap 里，档位能直接回显、指令成败能靠信号确认。
/// 所以这里没有「高亮的是本机记录」那种免责声明——草稿只活在点击到车确认之间。
///
/// 下发 301/370/320/440 都**没有实车样本**。
@Composable
fun ComfortCabinScreen(onBack: () -> Unit) {
    val store = LocalStore.current
    /// 当前看的是加热还是通风。纯视图状态，不下发。
    var channel by rememberSaveable { mutableStateOf(SeatComfortChannel.Heating) }
    var confirmingCloseAll by remember { mutableStateOf(false) }
    val tint = if (channel == SeatComfortChannel.Heating) LeapColors.warm else LeapColors.cool
    PageTint(tint)

    // 调完档位立刻退出去的话，那条还没发的指令就不该再发了。同空调页。
    DisposableEffect(Unit) { onDispose { store.cancelPendingCabinPushes() } }

    val hasAnySeat = SeatComfortChannel.entries.any { c -> SeatPosition.entries.any { store.seatLevel(it, c) != null } }
    val hasSeatInChannel = SeatPosition.entries.any { store.seatLevel(it, channel) != null }
    val hasAnything = hasAnySeat || store.steeringWheelLevel != null || store.mirrorHeatingOn != null
    val hasAnythingOn = SeatComfortChannel.entries.any { c ->
        SeatPosition.entries.any { (store.seatLevel(it, c) ?: 0) > 0 }
    } || (store.steeringWheelLevel ?: 0) > 0 || store.mirrorHeatingOn == true

    SubPageScaffold(
        title = "舒适座舱",
        onBack = onBack,
        actions = {
            // 「全部关闭」是批量指令，不该一下就走，锚一层确认。
            AnchoredOverlayBox(
                expanded = confirmingCloseAll,
                onDismissRequest = { confirmingCloseAll = false },
                anchor = {
                    SubPageAction(
                        icon = Icons.Outlined.PowerSettingsNew,
                        contentDescription = "全部关闭",
                        enabled = hasAnythingOn,
                        onClick = { confirmingCloseAll = true },
                    )
                },
            ) {
                AnchoredConfirmation(
                    title = "关闭所有座舱加热与通风？",
                    message = "会把当前开着的座椅、方向盘和后视镜逐条关掉。",
                    confirmText = "全部关闭",
                    destructive = true,
                    onConfirm = {
                        confirmingCloseAll = false
                        store.closeAllCabinComfort()
                    },
                    onCancel = { confirmingCloseAll = false },
                )
            }
        },
    ) {
        // 两条通道都读不到任何座位时，分段和座位图整块不画——
        // 不然剩一个只有方向盘图标的空框，等于摆了个点不动的格子。
        if (hasAnySeat) {
            SegmentedCapsule(
                options = SeatComfortChannel.entries.map { it.label to channelIcon(it) },
                selectedIndex = channel.ordinal,
                onSelect = { channel = SeatComfortChannel.entries[it] },
            )
            if (hasSeatInChannel) SeatMap(store, channel, tint)
        }
        if (store.steeringWheelLevel != null) SteeringWheelCard(store)
        if (store.mirrorHeatingOn != null) MirrorCard(store)
        if (!hasAnything) {
            // 入口本身已经过了支持门控，走到这儿还全空，最常见的原因是车在休眠、这一轮字段缺了一片。
            NoticeCard(
                icon = Icons.Outlined.Bedtime,
                title = "暂时读不到座舱状态",
                detail = "车辆休眠时这一批字段会整片缺失。等车况刷新后会自动出现。",
            )
        }
    }
}

private fun channelIcon(channel: SeatComfortChannel): ImageVector = when (channel) {
    SeatComfortChannel.Heating -> Icons.Outlined.Whatshot
    SeatComfortChannel.Ventilation -> Icons.Outlined.Air
}

/// 车内俯视座位图：方向盘那一道压在主驾列上，一眼看出车头朝上、主驾在左。
/// 整行都读不到就不画这一行——不摆灰格子、不写「本车不支持」。
@Composable
private fun SeatMap(store: VehicleStore, channel: SeatComfortChannel, tint: Color) {
    Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxWidth()) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
            modifier = Modifier
                .widthIn(max = 300.dp)
                .fillMaxWidth()
                .liquidGlass(RoundedCornerShape(28.dp), LeapColors.card)
                .padding(vertical = 20.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(26.dp)) {
                SteeringWheelGlyph(
                    color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier
                        .width(64.dp)
                        .height(18.dp),
                )
                Spacer(modifier = Modifier.width(64.dp))
            }
            listOf(SeatPosition.front, SeatPosition.rear).forEach { row ->
                if (row.any { store.seatLevel(it, channel) != null }) {
                    Row(horizontalArrangement = Arrangement.spacedBy(26.dp)) {
                        row.forEach { position ->
                            if (store.seatLevel(position, channel) != null) {
                                SeatTile(store, position, channel, tint)
                            } else {
                                // 同一行里个别座位读不到：留一块等大的透明占位，左右两座不会跑到中间去。
                                Spacer(modifier = Modifier.size(64.dp, 93.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SeatTile(store: VehicleStore, position: SeatPosition, channel: SeatComfortChannel, tint: Color) {
    val level = store.seatLevel(position, channel) ?: 0
    val isOn = level > 0
    val fill = if (isOn) tint.copy(alpha = 0.24f + 0.26f * (level - 1)) else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.10f)
    val haptics = LocalHapticFeedback.current
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .size(64.dp, 93.dp)
            .pressable(
                onClick = {
                    haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                    store.cycleSeat(position, channel)
                },
                shape = RoundedCornerShape(12.dp),
            )
            // 四块色块读屏时全念作「按钮」分不出来：合成一个元素，名字带位置和通道，状态报档位。
            .semantics(mergeDescendants = true) {
                contentDescription = "${position.label}座椅${channel.label}"
                stateDescription = if (isOn) "$level 档" else "已关闭"
            },
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
            // 靠背
            Box(
                modifier = Modifier
                    .size(56.dp, 16.dp)
                    .background(fill, RoundedCornerShape(7.dp)),
            )
            // 坐垫 + 档位
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(64.dp, 52.dp)
                    .background(fill, RoundedCornerShape(12.dp))
                    .then(
                        if (!isOn) Modifier.border(1.dp, LeapColors.glassEdge, RoundedCornerShape(12.dp)) else Modifier,
                    ),
            ) {
                if (isOn) {
                    Text(
                        text = "$level",
                        fontSize = 22.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                } else {
                    Icon(
                        channelIcon(channel),
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.outline,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }
        Text(
            text = position.label,
            style = MaterialTheme.typography.labelSmall,
            color = if (isOn) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.outline,
        )
    }
}

/// 方向盘加热卡：关 / 弱 / 强。**只有两档**，和座椅的三档不是一套量程。
@Composable
private fun SteeringWheelCard(store: VehicleStore) {
    val level = store.steeringWheelLevel ?: 0
    GlassCard(
        shape = TileShape,
        surface = if (level > 0) LeapColors.warm.copy(alpha = 0.14f) else LeapColors.card,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SteeringWheelGlyph(
                    color = if (level > 0) LeapColors.warm else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
                Text("方向盘加热", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                // 剩余分钟只在加热确实开着时才给——信号 1624 在关闭时也非 0。
                store.steeringWheelHeatMinutes?.let {
                    Text("约剩 $it 分钟", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
                }
            }
            SegmentedCapsule(
                options = listOf("关" to null, "弱" to null, "强" to null),
                selectedIndex = level,
                onSelect = { store.setSteeringWheelHeat(it) },
                compact = true,
            )
        }
    }
}

/// 后视镜加热卡：整卡轻点切换开 / 关。
@Composable
private fun MirrorCard(store: VehicleStore) {
    val on = store.mirrorHeatingOn ?: false
    GlassCard(
        shape = TileShape,
        surface = if (on) LeapColors.frost.copy(alpha = 0.16f) else LeapColors.card,
        onClick = { store.toggleMirrorHeating() },
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(
                    Icons.Outlined.SensorWindow,
                    contentDescription = null,
                    tint = if (on) LeapColors.frost else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
                Text("后视镜加热", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                Text(
                    if (on) "已开启" else "已关闭",
                    style = MaterialTheme.typography.labelMedium,
                    color = if (on) LeapColors.frost else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            // 五项里唯一官方 App 自己都没做的功能：内部码 440 在官方包里连中文文案都没有。
            // 按下去没反应时，用户该先知道这件事，而不是以为我们坏了。
            Text(
                if (store.state?.mirrorHeatingMismatched == true) "左右状态不一致 · 该指令未经官方 App 验证"
                else "轻点切换 · 该指令未经官方 App 验证",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

// MARK: - 车载冰箱

/// 车载冰箱：电源、三个预设、目标温度、制冷风格、离车保持。对应 iOS `FridgeView`。
///
/// 这一页在**没装冰箱的车上整个不出现**（入口门控见 `VehicleStore.fridgeSupported`）。
/// cmdid `500` 的 state 是**全量**的，所以这页维护的是整份草稿（`VehicleStore.fridgeDraft`）。
@Composable
fun FridgeScreen(onBack: () -> Unit) {
    val store = LocalStore.current
    LaunchedEffect(Unit) { store.seedFridgeDraft() }
    // 车况还没回来时给一份中性默认值：草稿本来就是本机准备要发的东西，必须有个值；
    // 上面那行状态文字读的仍然是车况，读不到就不显示。
    val draft = store.fridgeDraft ?: store.state?.fridgeState?.asSetting ?: FridgeSetting()
    val tint = when {
        !draft.enabled -> LeapColors.frost.copy(alpha = 0.6f)
        draft.mode == FridgeMode.Hot -> LeapColors.warm
        else -> LeapColors.cool
    }
    PageTint(tint)

    fun update(change: (FridgeSetting) -> FridgeSetting) {
        store.fridgeDraft = change(draft)
        store.pushFridgeDraft()
    }

    SubPageScaffold(title = "车载冰箱", onBack = onBack) {
        store.state?.fridgeState?.fault?.takeIf { it != 0 }?.let { code ->
            NoticeCard(
                icon = Icons.Outlined.WarningAmber,
                title = "冰箱自检故障（码 $code）",
                // 不编造排查指引：这个码的含义我们没有任何对照表。
                detail = "车端报了一个非零故障码，具体含义以车机或售后为准。",
                tint = LeapColors.caution,
            )
        }

        // 电源：大圆 + 状态行（读车况）+ 开关按钮
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 8.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(142.dp)
                    .background(
                        (if (draft.enabled) tint else MaterialTheme.colorScheme.onSurfaceVariant).copy(alpha = 0.13f),
                        CircleShape,
                    ),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        if (draft.mode == FridgeMode.Hot) Icons.Outlined.Coffee else Icons.Outlined.AcUnit,
                        contentDescription = null,
                        tint = if (draft.enabled) tint else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(34.dp),
                    )
                    Text(
                        "${draft.wireTemperature} °C",
                        fontSize = 26.sp,
                        fontWeight = FontWeight.Light,
                        color = if (draft.enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.outline,
                    )
                }
            }
            // 这一行读的是**车况**，不是草稿——它要回答的是「车上现在到底什么状态」。读不到整行不显示。
            fridgeStateLine(store)?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (draft.enabled) {
                LiquidGlassButton(
                    text = "关闭冰箱",
                    icon = Icons.Outlined.PowerSettingsNew,
                    onClick = { store.setFridgePower(false) },
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    enabled = !store.isSendingCommand,
                    height = 50.dp,
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                LiquidButton(
                    text = "开启冰箱",
                    icon = Icons.Outlined.PowerSettingsNew,
                    onClick = { store.setFridgePower(true) },
                    tint = LeapColors.cool,
                    enabled = !store.isSendingCommand,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        if (draft.enabled) {
            SegmentedCapsule(
                options = FridgePreset.entries.map { it.label to presetIcon(it) },
                selectedIndex = draft.preset?.ordinal ?: -1,
                onSelect = { index -> update { it.applying(FridgePreset.entries[index]) } },
            )

            // 目标温度。保温模式下协议写死 50 ℃，滑杆置灰而不是藏起来——藏起来卡片会在两个模式间跳高度。
            GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CardCaption("目标温度", Modifier.weight(1f))
                        Text(
                            if (draft.mode == FridgeMode.Hot) "固定 ${FridgeSetting.HOT_TEMP} ℃" else "${draft.temperature} ℃",
                            style = MaterialTheme.typography.labelLarge,
                        )
                    }
                    // 拖动中只改本地显示，松手才写草稿、走防抖下发。
                    var dragging by remember { mutableStateOf<Float?>(null) }
                    Box(modifier = Modifier.alpha(if (draft.mode == FridgeMode.Hot) 0.4f else 1f)) {
                        LiquidSlider(
                            value = dragging ?: draft.temperature.toFloat(),
                            onValueChange = { if (draft.mode != FridgeMode.Hot) dragging = it },
                            onValueChangeFinished = {
                                dragging?.let { value -> update { it.copy(temperature = Math.round(value)) } }
                                dragging = null
                            },
                            valueRange = FridgeSetting.MIN_TEMP.toFloat()..FridgeSetting.MAX_TEMP.toFloat(),
                            step = 1f,
                            tint = LeapColors.cool,
                        )
                    }
                    if (draft.mode == FridgeMode.Hot) {
                        Text(
                            "保温模式恒温 ${FridgeSetting.HOT_TEMP} ℃，温度不可调。",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline,
                        )
                    }
                }
            }

            // 制冷风格
            GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                    CardCaption("制冷风格", Modifier.weight(1f))
                    SegmentedCapsule(
                        options = FridgeStyle.entries.map { it.label to null },
                        selectedIndex = draft.style.ordinal,
                        onSelect = { index -> update { it.copy(style = FridgeStyle.entries[index]) } },
                        compact = true,
                        modifier = Modifier.width(150.dp),
                    )
                }
            }

            // 离车保持
            GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("离车保持", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                        LiquidSwitch(checked = draft.parkEnabled, onCheckedChange = { on -> update { it.copy(parkEnabled = on) } })
                    }
                    if (draft.parkEnabled) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            CardCaption("工作时长", Modifier.weight(1f))
                            StepperButtons(
                                text = "${draft.parkHours} 小时",
                                canDecrease = draft.parkHours > 1,
                                canIncrease = draft.parkHours < 24,
                                onDecrease = { update { it.copy(parkHours = it.parkHours - 1) } },
                                onIncrease = { update { it.copy(parkHours = it.parkHours + 1) } },
                            )
                        }
                        // 截止时刻读车况（信号 11260），车端没给就不显示。
                        store.state?.fridgeState?.parkEndsAt?.let { endsAt ->
                            val c = Calendar.getInstance().apply { timeInMillis = endsAt }
                            Text(
                                "预计 %02d:%02d 结束".format(c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE)),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.outline,
                            )
                        }
                        // 周期这一版不暴露：下发口径（"1"/"2"）和上报口径（0/1）对不上，固定发 "1"。
                        Text(
                            "当前仅对本次离车生效。",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline,
                        )
                    }
                }
            }
        }
    }
}

private fun presetIcon(preset: FridgePreset): ImageVector = when (preset) {
    FridgePreset.Chill -> Icons.Outlined.AcUnit
    FridgePreset.Freeze -> Icons.Outlined.SevereCold
    FridgePreset.KeepWarm -> Icons.Outlined.Coffee
}

private fun fridgeStateLine(store: VehicleStore): String? {
    val fridge = store.state?.fridgeState ?: return null
    if (!fridge.enabled) return "冰箱已关闭 · 保留上次设定"
    val parts = mutableListOf(
        when {
            fridge.mode == FridgeMode.Hot -> "保温 ${FridgeSetting.HOT_TEMP} ℃"
            fridge.targetTemp != null -> "制冷 ${fridge.targetTemp} ℃"
            else -> fridge.mode.label
        },
        fridge.style.label,
    )
    if (fridge.parkEnabled) parts.add("离车保持中")
    return parts.joinToString(" · ")
}

// MARK: - 本组共用的小件

/// 胶囊分段选择（同 iOS 空调页 modePicker 的形态）：玻璃底 + 选中段淡底。
/// `selectedIndex = -1` 表示一个都不亮（冰箱温度落在三个预设之外时）。
@Composable
internal fun SegmentedCapsule(
    options: List<Pair<String, ImageVector?>>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier.fillMaxWidth(),
    compact: Boolean = false,
) {
    val haptics = LocalHapticFeedback.current
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier
            .liquidGlass(CircleShape, LeapColors.card)
            .padding(if (compact) 4.dp else 5.dp),
    ) {
        options.forEachIndexed { index, (label, icon) ->
            val selected = index == selectedIndex
            val color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .weight(1f)
                    .pressable(
                        onClick = {
                            if (!selected) haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                            onSelect(index)
                        },
                        shape = CircleShape,
                        feedback = PressFeedback.Fade,
                        role = Role.RadioButton,
                    )
                    .background(
                        if (selected) MaterialTheme.colorScheme.onSurface.copy(alpha = 0.14f) else Color.Transparent,
                        CircleShape,
                    )
                    .padding(vertical = if (compact) 8.dp else 11.dp),
            ) {
                if (icon != null) Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(16.dp))
                Text(label, style = MaterialTheme.typography.labelLarge, color = color, maxLines = 1)
            }
        }
    }
}

/// 一行「‹ 2 小时 ›」式的加减钮。
@Composable
internal fun StepperButtons(
    text: String,
    canDecrease: Boolean,
    canIncrease: Boolean,
    onDecrease: () -> Unit,
    onIncrease: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        LiquidIconButton(
            icon = Icons.Outlined.Remove,
            contentDescription = "减少",
            onClick = { if (canDecrease) onDecrease() },
            size = 32.dp,
            iconSize = 16.dp,
            container = LeapColors.cool.copy(alpha = if (canDecrease) 0.12f else 0.05f),
            tint = if (canDecrease) LeapColors.cool else MaterialTheme.colorScheme.outline,
        )
        Text(text, style = MaterialTheme.typography.labelLarge, modifier = Modifier.widthIn(min = 52.dp))
        LiquidIconButton(
            icon = Icons.Outlined.Add,
            contentDescription = "增加",
            onClick = { if (canIncrease) onIncrease() },
            size = 32.dp,
            iconSize = 16.dp,
            container = LeapColors.cool.copy(alpha = if (canIncrease) 0.12f else 0.05f),
            tint = if (canIncrease) LeapColors.cool else MaterialTheme.colorScheme.outline,
        )
    }
}

@Composable
internal fun CardCaption(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = modifier)
}

@Composable
private fun NoticeCard(icon: ImageVector, title: String, detail: String, tint: Color? = null) {
    GlassCard(
        shape = TileShape,
        surface = tint?.copy(alpha = 0.14f) ?: LeapColors.card,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(14.dp)) {
            Icon(icon, contentDescription = null, tint = tint ?: MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = MaterialTheme.typography.titleSmall)
                Text(detail, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/// Material 图标库里没有方向盘，手画一个：外圈 + 三根辐条。纯装饰。
@Composable
private fun SteeringWheelGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        val r = minOf(size.width, size.height) / 2 - 1.dp.toPx()
        val c = center
        val stroke = 1.6.dp.toPx()
        drawCircle(color, r, c, style = Stroke(stroke))
        drawCircle(color, r * 0.28f, c, style = Stroke(stroke))
        drawLine(color, Offset(c.x - r, c.y), Offset(c.x - r * 0.28f, c.y), stroke)
        drawLine(color, Offset(c.x + r * 0.28f, c.y), Offset(c.x + r, c.y), stroke)
        drawLine(color, Offset(c.x, c.y + r * 0.28f), Offset(c.x, c.y + r), stroke)
    }
}
