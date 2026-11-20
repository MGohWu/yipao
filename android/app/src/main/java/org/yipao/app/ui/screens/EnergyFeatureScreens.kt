package org.yipao.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DeviceThermostat
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import org.yipao.app.core.AppointmentWeekday
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.HairlineDivider
import org.yipao.app.ui.components.LiquidButton
import org.yipao.app.ui.components.LiquidGlassButton
import org.yipao.app.ui.components.LiquidSlider
import org.yipao.app.ui.components.LiquidSwitch
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.SubPageScaffold
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.components.liquidGlass
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.theme.LeapColors
import java.util.Calendar

// 能源组两页。指令链路都是真的（电池预热 cmdid 160/161、充电计划 190 + 健康充电 480，
// 2026-08-18 真车抓包验证）。

/// 电池预热：大圆状态 + 立即预热（160）+ 预约预热（161）。对齐 iOS `BatteryPreheatPreviewView`。
@Composable
fun BatteryHeatScreen(onBack: () -> Unit) {
    PageTint(LeapColors.warm)
    val store = LocalStore.current
    // 车端不上报可判定的预热终态（ptcState 枚举未确认），这里不做「开着/关着」的显示
    // ——那会是凭空断言。
    var scheduleEnabled by rememberSaveable { mutableStateOf(true) }
    var hour by rememberSaveable { mutableIntStateOf(7) }
    var minute by rememberSaveable { mutableIntStateOf(30) }
    val days = rememberDayFlags(listOf(true, true, true, true, true, false, false))
    var picking by remember { mutableStateOf(false) }
    val busy = store.isSendingCommand

    SubPageScaffold(title = "电池预热", onBack = onBack) {
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
                        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.13f),
                        CircleShape,
                    ),
            ) {
                Icon(
                    Icons.Outlined.DeviceThermostat,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(52.dp),
                )
            }

            Text("立即预热", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "是否生效以车辆实际表现为准",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        run {
            // 两个一次性动作，结果交给全局提示：成功报「已发送」，
            // 车型/环境不支持时服务端回错误、由 store 如实弹出。
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                LiquidButton(
                    text = "开启预热",
                    onClick = { store.preheatBattery() },
                    tint = LeapColors.warm,
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                )
                LiquidGlassButton(
                    text = "关闭预热",
                    onClick = { store.stopBatteryPreheat() },
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    enabled = !busy,
                    height = 50.dp,
                    modifier = Modifier.weight(1f),
                )
            }
        }

        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(vertical = 6.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                ) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text("预约预热", style = MaterialTheme.typography.bodyMedium)
                        Text(
                            "按计划在出发前自动完成",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    LiquidSwitch(checked = scheduleEnabled, onCheckedChange = { scheduleEnabled = it })
                }
                if (scheduleEnabled) {
                    HairlineDivider(startIndent = 16.dp)
                    TimeRow(
                        label = "开始时间",
                        hour = hour,
                        minute = minute,
                        onClick = { picking = true },
                    )
                    Text(
                        "重复星期",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 16.dp, top = 4.dp),
                    )
                    DayPills(
                        selected = days,
                        // 一天都不选的预约没有意义，最后一天不给取消。
                        onToggle = { index ->
                            if (days[index] && days.count { it } == 1) return@DayPills
                            days[index] = !days[index]
                        },
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }
        }

        run {
            LiquidButton(
                // 开关关着时保存 = 取消预约（下发 on:0）。
                text = if (scheduleEnabled) "保存预约" else "取消预约",
                onClick = {
                    store.scheduleBatteryPreheat(
                        startTime = todayAt(hour, minute),
                        enabled = scheduleEnabled,
                        // 周日是 **0** 不是 7（2026-11-19 改，和预约空调 171 共用一套编码，
                        // 见 `AppointmentWeekday`）。界面七格仍是周一在前、周日在末。
                        days = days.indices.filter { days[it] }.map { AppointmentWeekday.wireValue(it) },
                    )
                },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            )
            InfoNote("预约设置会下发到车辆，是否按时生效以车辆实际表现为准。")
        }
    }

    if (picking) {
        TimePickerDialog(
            initialHour = hour,
            initialMinute = minute,
            onDismiss = { picking = false },
            onConfirm = { h, m ->
                hour = h
                minute = m
                picking = false
            },
        )
    }
}

/// 充电计划：目标电量（充电上限）+ 健康充电 + 预约时段与循环日。
/// 对齐 iOS `ChargePlanPreviewView`：控件初值用车上真实的 `config."3"` 播种一次。
@Composable
fun ChargePlanScreen(onBack: () -> Unit) {
    PageTint(LeapColors.accent)
    val store = LocalStore.current
    // 拿不到真实计划时退到这套默认：23:00–08:00 / 90% / 每天 / 关。
    var percent by rememberSaveable { mutableFloatStateOf(90f) }
    var scheduleEnabled by rememberSaveable { mutableStateOf(false) }
    var beginHour by rememberSaveable { mutableIntStateOf(23) }
    var beginMinute by rememberSaveable { mutableIntStateOf(0) }
    var endHour by rememberSaveable { mutableIntStateOf(8) }
    var endMinute by rememberSaveable { mutableIntStateOf(0) }
    val cycles = rememberDayFlags(List(7) { true })
    /// `circulation`/`recharge` 含义未确认，原样回填车辆上报的那份（见 `ChargePlan`）。
    var circulation by rememberSaveable { mutableIntStateOf(1) }
    var recharge by rememberSaveable { mutableIntStateOf(0) }
    /// 健康充电开关。初值取车况信号 48，读不到才默认关。
    var healthyCharge by rememberSaveable { mutableStateOf(false) }
    /// 这次动过健康充电才下发 480——没动就不必重复写一遍车上已有的设置。
    var healthyTouched by rememberSaveable { mutableStateOf(false) }
    /// 只播种一次，之后不覆盖用户在这一页上的改动。
    var loaded by remember(store.session.selectedVin) { mutableStateOf(false) }
    var loading by remember(store.session.selectedVin) { mutableStateOf(true) }
    var retry by remember { mutableIntStateOf(0) }
    /// null = 不选时间，true = 选开始，false = 选结束。
    var picking by remember { mutableStateOf<Boolean?>(null) }

    LaunchedEffect(store.session.selectedVin, store.session.oldAuth?.accountId, retry) {
        loading = true
        loaded = false
        val success = store.refreshChargePlan()
        if (success) {
            // 只在本次读取完成后填入，不监听轮询，避免覆盖正在编辑的草稿。
            val plan = store.state?.chargePlan
            healthyCharge = store.state?.healthyChargeOn ?: false
            healthyTouched = false
            scheduleEnabled = plan?.isEnable ?: false
            percent = (plan?.percent ?: 90).coerceIn(50, 100).toFloat()
            val begin = plan?.beginTime?.let(::parseHhmm) ?: (23 to 0)
            val end = plan?.endTime?.let(::parseHhmm) ?: (8 to 0)
            beginHour = begin.first
            beginMinute = begin.second
            endHour = end.first
            endMinute = end.second
            cycles.indices.forEach { cycles[it] = plan?.cycles?.getOrNull(it) ?: true }
            circulation = plan?.circulation ?: 1
            recharge = plan?.recharge ?: 0
            loaded = true
        }
        loading = false
    }

    // 健康充电开启时充电上限最多 90%（官方页面同款约束）。
    val maxPercent = if (healthyCharge) 90f else 100f
    val busy = store.isSendingCommand

    SubPageScaffold(title = "充电计划", onBack = onBack) {
        if (loading) {
            Text("正在读取充电计划…")
            return@SubPageScaffold
        }
        if (!loaded) {
            LiquidButton(text = "读取失败，点击重试", onClick = { retry++ })
            return@SubPageScaffold
        }
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 18.dp),
            ) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(
                        "${percent.toInt()}",
                        fontSize = 78.sp,
                        fontWeight = FontWeight.ExtraLight,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        "%",
                        fontSize = 26.sp,
                        fontWeight = FontWeight.Light,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 14.dp),
                    )
                }
                Text(
                    "目标电量",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                LiquidSlider(
                    value = percent.coerceAtMost(maxPercent),
                    onValueChange = { percent = it },
                    valueRange = 50f..maxPercent,
                    step = 5f,
                    modifier = Modifier.padding(top = 10.dp),
                )
                Row(modifier = Modifier.fillMaxWidth()) {
                    Text("50%", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
                    Spacer(modifier = Modifier.weight(1f))
                    Text("80%", style = MaterialTheme.typography.labelSmall, color = LeapColors.accent)
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        "${maxPercent.toInt()}%",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
            }
        }

        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(
                verticalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text("健康充电", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                    LiquidSwitch(
                        checked = healthyCharge,
                        onCheckedChange = { on ->
                            healthyCharge = on
                            healthyTouched = true
                            // 开启健康充电后上限最多 90%，超了就回拉。
                            if (on && percent > 90f) percent = 90f
                        },
                    )
                }
                Text(
                    "开启后充电上限最多 90%。开关状态取自车况，改动后保存才下发。",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(vertical = 6.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                ) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text("预约充电", style = MaterialTheme.typography.bodyMedium)
                        Text(
                            "只在谷电时段充，插枪不马上充",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    LiquidSwitch(checked = scheduleEnabled, onCheckedChange = { scheduleEnabled = it })
                }
                if (scheduleEnabled) {
                    HairlineDivider(startIndent = 16.dp)
                    TimeRow("开始时间", beginHour, beginMinute, onClick = { picking = true })
                    TimeRow("结束时间", endHour, endMinute, onClick = { picking = false })
                    Text(
                        "循环日",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 16.dp, top = 4.dp),
                    )
                    DayPills(
                        selected = cycles,
                        onToggle = { index -> cycles[index] = !cycles[index] },
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }
        }

        run {
            LiquidButton(
                text = "保存充电计划",
                onClick = {
                    store.saveChargePlan(
                        limitPercent = percent.toInt(),
                        scheduledEnabled = scheduleEnabled,
                        startTime = hhmm(beginHour, beginMinute),
                        endTime = hhmm(endHour, endMinute),
                        cycles = cycles.toList(),
                        circulation = circulation,
                        recharge = recharge,
                        healthyChargeOn = if (healthyTouched) healthyCharge else null,
                    )
                },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            )
            InfoNote("改动保存后才下发到车辆，是否生效以车辆实际表现为准。")
        }
    }

    val target = picking
    if (target != null) {
        TimePickerDialog(
            initialHour = if (target) beginHour else endHour,
            initialMinute = if (target) beginMinute else endMinute,
            onDismiss = { picking = null },
            onConfirm = { h, m ->
                if (target) {
                    beginHour = h
                    beginMinute = m
                } else {
                    endHour = h
                    endMinute = m
                }
                picking = null
            },
        )
    }
}

// —— 本组共用的小件 ——

/// 七位星期开关。`rememberSaveable` 存不了 SnapshotStateList，转屏靠 listSaver 还原。
@Composable
private fun rememberDayFlags(initial: List<Boolean>) = rememberSaveable(
    saver = androidx.compose.runtime.saveable.listSaver(
        save = { it.toList() },
        restore = { mutableStateListOf(*it.toTypedArray()) },
    ),
) { mutableStateListOf(*initial.toTypedArray()) }

/// 一行「标签 —— 07:30」，整行可点，点开时间选择器。
@Composable
internal fun TimeRow(label: String, hour: Int, minute: Int, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .pressable(onClick = onClick, feedback = PressFeedback.Fade)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Text(
            hhmm(hour, minute),
            fontSize = 28.sp,
            fontWeight = FontWeight.Light,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

/// 一到日七个可点小胶囊，选中绿底。状态由调用方持有——预约预热和充电计划各有各的规则
/// （前者不许全不选，后者可以）。
@Composable
internal fun DayPills(selected: List<Boolean>, onToggle: (Int) -> Unit, modifier: Modifier = Modifier) {
    val labels = listOf("一", "二", "三", "四", "五", "六", "日")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = modifier.fillMaxWidth()) {
        labels.forEachIndexed { index, label ->
            val on = selected[index]
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .height(36.dp)
                    .pressable(
                        onClick = { onToggle(index) },
                        shape = CircleShape,
                        role = Role.Checkbox,
                    )
                    .background(
                        if (on) {
                            LeapColors.accent.copy(alpha = 0.18f)
                        } else {
                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f)
                        },
                        CircleShape,
                    ),
            ) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelMedium,
                    color = if (on) LeapColors.accent else MaterialTheme.colorScheme.outline,
                    fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                )
            }
        }
    }
}

@Composable
internal fun InfoNote(text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .liquidGlass(TileShape, LeapColors.card)
            .padding(16.dp),
    ) {
        Icon(
            Icons.Outlined.Info,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/// 时间选择器。这套界面自己没有滚轮控件，直接用 Material3 的 `TimePicker`——
/// 一个只在弹层里出现一次的输入控件，为它手搓一套玻璃滚轮不划算。
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TimePickerDialog(
    initialHour: Int,
    initialMinute: Int,
    onDismiss: () -> Unit,
    onConfirm: (Int, Int) -> Unit,
) {
    val state = rememberTimePickerState(initialHour, initialMinute, is24Hour = true)
    Dialog(onDismissRequest = onDismiss) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            // 弹窗是另一个 window，取不到页面那层取景图，玻璃在这儿折射不出东西，
            // 直接用实底，不装。
            modifier = Modifier
                .background(MaterialTheme.colorScheme.surface, TileShape)
                .padding(20.dp),
        ) {
            TimePicker(state = state)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                LiquidGlassButton(
                    text = "取消",
                    onClick = onDismiss,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                LiquidButton(
                    text = "确定",
                    onClick = { onConfirm(state.hour, state.minute) },
                    height = 46.dp,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/// 今天的 hh:mm 对应的毫秒时间戳（预约接口收的是本机时区的绝对时刻）。
private fun todayAt(hour: Int, minute: Int): Long = Calendar.getInstance().apply {
    set(Calendar.HOUR_OF_DAY, hour)
    set(Calendar.MINUTE, minute)
    set(Calendar.SECOND, 0)
    set(Calendar.MILLISECOND, 0)
}.timeInMillis

private fun hhmm(hour: Int, minute: Int): String =
    "${if (hour < 10) "0$hour" else "$hour"}:${if (minute < 10) "0$minute" else "$minute"}"

/// `"23:00"` → (23, 0)。解析不出返回 null，交给调用方保留默认值。
private fun parseHhmm(text: String): Pair<Int, Int>? {
    val parts = text.split(":")
    if (parts.size != 2) return null
    val hour = parts[0].toIntOrNull() ?: return null
    val minute = parts[1].toIntOrNull() ?: return null
    if (hour !in 0..23 || minute !in 0..59) return null
    return hour to minute
}
