package org.yipao.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AcUnit
import androidx.compose.material.icons.outlined.EditCalendar
import androidx.compose.material.icons.outlined.EventBusy
import androidx.compose.material.icons.outlined.LocalFireDepartment
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.yipao.app.app.VehicleStore.AppointmentReadback
import org.yipao.app.core.AppointmentWeekday
import org.yipao.app.core.ClimateAppointment
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.HairlineDivider
import org.yipao.app.ui.components.LiquidButton
import org.yipao.app.ui.components.LiquidSpinner
import org.yipao.app.ui.components.LiquidSwitch
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.SubPageScaffold
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.theme.LeapColors

/// 预约空调（cmdid 171）。从空调页右上角进来。对应 iOS `ClimateAppointmentView`。
///
/// 预约没有车况信号可确认，**确认靠回读**：页面一进来先读车上已有的预约，
/// 下发之后 store 再自动回读一次（见 `VehicleStore.confirm` 里 171 那条），
/// 顶上那张「车上当前预约」卡显示的永远是车端回读的结果，不是本机刚填的草稿。
///
/// 风量 / 循环 / 除雾 / 出风位置不在界面上，照官方抓包默认值固定发，见 `ClimateAppointment`。
/// 171 的设置与回读都**没有我们自己的实车样本**。
@Composable
fun ClimateAppointmentScreen(onBack: () -> Unit) {
    val store = LocalStore.current
    var draft by remember { mutableStateOf(ClimateAppointment()) }
    var enabled by remember { mutableStateOf(true) }
    /// 用户动过草稿之后，回读结果就不再覆盖它——不然刚调好的时间会被下一次回读冲掉。
    var edited by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf(false) }
    val readback = store.climateAppointmentReadback
    val currentOnCar = (readback as? AppointmentReadback.Loaded)?.appointment
    val tint = if (draft.mode == ClimateAppointment.Mode.Hot) LeapColors.warm else LeapColors.cool
    PageTint(tint)

    LaunchedEffect(Unit) { store.refreshClimateAppointment() }
    LaunchedEffect(readback) {
        if (edited) return@LaunchedEffect
        when (readback) {
            is AppointmentReadback.Loaded -> {
                draft = readback.appointment
                enabled = true
            }
            AppointmentReadback.Empty -> enabled = true
            else -> Unit
        }
    }

    fun edit(change: (ClimateAppointment) -> ClimateAppointment) {
        draft = change(draft)
        edited = true
    }

    SubPageScaffold(title = "预约空调", onBack = onBack) {
        // 车上当前预约（回读）
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(16.dp)) {
                CardCaption("车上当前预约")
                when (readback) {
                    AppointmentReadback.Empty ->
                        Text("没有预约空调", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                    is AppointmentReadback.Loaded -> Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(Icons.Outlined.EditCalendar, contentDescription = null, modifier = Modifier.size(16.dp))
                        Text(readback.appointment.summary, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                    }
                    // 读不到 ≠ 没有预约。说清楚是哪一种，别让用户以为车上是空的。
                    is AppointmentReadback.Failed -> {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(Icons.Outlined.WarningAmber, contentDescription = null, tint = LeapColors.caution, modifier = Modifier.size(16.dp))
                            Text("读不到车上的预约", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, color = LeapColors.caution)
                        }
                        Text(readback.message, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    AppointmentReadback.Loading, null -> Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        LiquidSpinner(modifier = Modifier.size(16.dp))
                        Text("读取中…", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }

        // 编辑
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(vertical = 6.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                ) {
                    Text("启用预约", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                    LiquidSwitch(checked = enabled, onCheckedChange = {
                        enabled = it
                        edited = true
                    })
                }
                if (enabled) {
                    HairlineDivider(startIndent = 16.dp)
                    TimeRow(label = "开启时间", hour = draft.hour, minute = draft.minute, onClick = { picking = true })
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp),
                    ) {
                        CardCaption("重复", Modifier.weight(1f))
                        Text(
                            AppointmentWeekday.summary(draft.days),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    // 七格周一在前、周日在末；值是协议编码（周日 = 0）。一个都不勾 = 只执行一次。
                    DayPills(
                        selected = AppointmentWeekday.ordered.map { it.first in draft.days },
                        onToggle = { index ->
                            val value = AppointmentWeekday.wireValue(index)
                            edit { it.copy(days = if (value in it.days) it.days - value else it.days + value) }
                        },
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                    if (draft.days.isEmpty()) {
                        Text(
                            "不选星期即为只执行一次。",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline,
                            modifier = Modifier.padding(horizontal = 16.dp),
                        )
                    }
                    HairlineDivider(startIndent = 16.dp, modifier = Modifier.padding(top = 6.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                    ) {
                        Text("温度", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                        StepperButtons(
                            text = "${draft.temperature} °C",
                            canDecrease = draft.temperature > ClimateAppointment.MIN_TEMPERATURE,
                            canIncrease = draft.temperature < ClimateAppointment.MAX_TEMPERATURE,
                            onDecrease = { edit { it.copy(temperature = it.temperature - 1) } },
                            onIncrease = { edit { it.copy(temperature = it.temperature + 1) } },
                        )
                    }
                    SegmentedCapsule(
                        options = ClimateAppointment.Mode.entries.map {
                            it.label to if (it == ClimateAppointment.Mode.Hot) Icons.Outlined.LocalFireDepartment else Icons.Outlined.AcUnit
                        },
                        selectedIndex = draft.mode.ordinal,
                        onSelect = { index -> edit { it.copy(mode = ClimateAppointment.Mode.entries[index]) } },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }
        }

        if (enabled) {
            LiquidButton(
                text = "保存预约",
                icon = Icons.Outlined.EditCalendar,
                onClick = {
                    // 改的是车上已有那条就沿用它的 set_id；新建交给构造器现造。
                    store.saveClimateAppointment(draft.copy(setID = currentOnCar?.setID))
                    edited = false
                },
                tint = tint,
                enabled = !store.isSendingCommand,
                modifier = Modifier.fillMaxWidth(),
            )
        } else {
            // 开关关掉 = 取消车上的预约。车上本来就没有就没什么可取消的，按钮置灰。
            LiquidButton(
                text = "取消车上的预约",
                icon = Icons.Outlined.EventBusy,
                onClick = {
                    store.cancelClimateAppointment()
                    edited = false
                },
                tint = LeapColors.caution,
                enabled = currentOnCar != null && !store.isSendingCommand,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        InfoNote("风量 7 档、内循环、前挡除雾开启，与官方 App 的预约默认值一致。到点是否开启以车辆实际表现为准。")
    }

    if (picking) {
        TimePickerDialog(
            initialHour = draft.hour,
            initialMinute = draft.minute,
            onDismiss = { picking = false },
            onConfirm = { h, m ->
                edit { it.copy(hour = h, minute = m) }
                picking = false
            },
        )
    }
}
