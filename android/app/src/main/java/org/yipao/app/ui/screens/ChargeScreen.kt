package org.yipao.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.LockOpen
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import org.yipao.app.core.CarTypeFamily
import org.yipao.app.ui.components.AnchoredConfirmation
import org.yipao.app.ui.components.AnchoredOverlayBox
import org.yipao.app.ui.components.LiquidButton
import org.yipao.app.ui.components.LiquidGlassButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.yipao.app.core.ChargePlan
import org.yipao.app.core.LeapFormat
import org.yipao.app.core.VehicleSignal
import org.yipao.app.core.VehicleState
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.EnergyBar
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.MetricValue
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.SubPageScaffold
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.theme.LeapColors

/// 能源页，对应 iOS `ChargeView`：超大 SOC → 充电状态 → 启停充电 / 解锁充电枪（插着枪才有）→ 电量条 → 充电上限 →
/// 充电计划（车端有才出现）→ 指标网格。
///
/// 叫「能源」而不是「电池与充电」：增程车这页还要放油量和汽油续航，原来那个名字容不下油。
///
/// 预约充电和电池预热两块 iOS 已经撤下（实测在真车上不生效），这里也不做。
@Composable
fun ChargeScreen(onBack: () -> Unit) {
    val store = LocalStore.current
    val state = store.state

    // 充电中转绿，同 iOS。
    PageTint(if (state?.isCharging == true) LeapColors.accent else LeapColors.cool)

    SubPageScaffold(title = "能源", onBack = onBack) {
        // 超大 SOC。iOS 用 ultraLight 100pt 档，这里对应 ExtraLight。
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 12.dp),
        ) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    // 车端没报 SOC 就写横杠。这页的主角读不到，也不许拿 0 顶上。
                    text = state?.soc?.toString() ?: "--",
                    fontSize = 96.sp,
                    fontWeight = FontWeight.ExtraLight,
                    lineHeight = 98.sp,
                )
                Text(
                    text = "%",
                    fontSize = 30.sp,
                    fontWeight = FontWeight.Light,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 14.dp, start = 2.dp),
                )
            }
            Text(
                text = chargeStateLine(state),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp),
            )
        }

        ChargingControls()

        // 电量条 + 充电上限
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.padding(16.dp),
            ) {
                EnergyBar(
                    percent = state?.soc ?: 0,
                    limit = state?.chargeLimit,
                    height = 10,
                    fill = if (state?.isCharging == true) LeapColors.accent else MaterialTheme.colorScheme.primary,
                )
                // 车端没报就整行不出现。回退到本地草稿的默认值 90% 是错的——车主实际设的
                // 可能是 95%，凭空显示一个错数字比不显示糟得多；而写一个「充电上限 --」
                // 摆在那儿，也只是把一件读不到的事天天摆到眼前。
                state?.chargeLimit?.let { limit ->
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Icon(
                            Icons.Outlined.Bolt,
                            contentDescription = null,
                            tint = LeapColors.accent,
                            modifier = Modifier.size(15.dp),
                        )
                        Text(
                            text = " 充电上限",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            text = "$limit%",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
            }
        }

        // 充电计划：真实来自 commonConfig 的 config."3"。车端没这张表（S01/T03 那套，
        // 或没设过预约）就整卡不出现。这里只读不写——下发预约走的是另一个端点，没样本。
        state?.chargePlan?.let { ChargePlanCard(it) }

        MetricsGrid(state)

        Spacer(modifier = Modifier.height(2.dp))
    }
}

/// 启停充电 / 解锁充电枪（同 iOS `ChargeView.chargingControls`）。
///
/// 按车况只摆当下用得上的按钮：充电中给「停止」；插着枪没在充给「开始」+「解锁」；
/// 没插枪整行不出现。S01 / T03 不给：cmdid 193 / 192 的依据全来自数字口径的车
/// （leapauto 的 C16 抓包），老车型那套没有任何样本，摆出来大概率是点了等不到确认。
@Composable
private fun ChargingControls() {
    val store = LocalStore.current
    val state = store.state ?: return
    if (CarTypeFamily.isLegacyFamily(store.session.selectedCarType)) return
    val busy = store.isSendingCommand
    var confirmingStop by remember { mutableStateOf(false) }
    var confirmingUnlock by remember { mutableStateOf(false) }

    if (state.isCharging) {
        // 确认弹层锚在它自己的按钮上：锚在整行上箭头会指着别处，看不出是哪个按钮在问。
        // 停充之后要重新插枪或回车机才能再充，不好撤回，所以先问一句。
        AnchoredOverlayBox(
            expanded = confirmingStop,
            onDismissRequest = { confirmingStop = false },
            modifier = Modifier.fillMaxWidth(),
            anchor = {
                LiquidButton(
                    text = "停止充电",
                    icon = Icons.Outlined.Stop,
                    onClick = { confirmingStop = true },
                    tint = LeapColors.caution,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
        ) {
            AnchoredConfirmation(
                title = "停止充电？",
                message = "停止后需要重新插枪或在车机上操作才能继续充电。",
                confirmText = "停止充电",
                destructive = true,
                onConfirm = {
                    confirmingStop = false
                    store.setCharging(start = false)
                },
                onCancel = { confirmingStop = false },
            )
        }
    } else if (state.chargeGunConnected == true) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
            // 开始充电不问——发错了再停就是。
            LiquidButton(
                text = "开始充电",
                icon = Icons.Outlined.Bolt,
                onClick = { store.setCharging(start = true) },
                enabled = !busy,
                modifier = Modifier.weight(1f),
            )
            // 解锁之后线缆可以被直接拔走，同样先问。
            AnchoredOverlayBox(
                expanded = confirmingUnlock,
                onDismissRequest = { confirmingUnlock = false },
                modifier = Modifier.weight(1f),
                anchor = {
                    LiquidGlassButton(
                        text = "解锁充电枪",
                        icon = Icons.Outlined.LockOpen,
                        onClick = { confirmingUnlock = true },
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        enabled = !busy,
                        height = 50.dp,
                        modifier = Modifier.fillMaxWidth(),
                    )
                },
            ) {
                AnchoredConfirmation(
                    title = "解锁充电枪？",
                    message = "解锁后充电线可以被直接拔下。车辆不上报解锁结果，发出后无法确认是否生效。",
                    confirmText = "解锁",
                    destructive = true,
                    onConfirm = {
                        confirmingUnlock = false
                        store.unlockChargingGun()
                    },
                    onCancel = { confirmingUnlock = false },
                )
            }
        }
    }
}

/// 充电计划卡。iOS 那边点一下能跳到功能中心的只读预览页，安卓的那页目前还是本地状态，
/// 跳过去会看到一组和这张卡对不上的数字，所以这里先不做跳转。
@Composable
private fun ChargePlanCard(plan: ChargePlan) {
    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Column(
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "充电计划",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = if (plan.isEnable) "预约开" else "预约关",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Medium,
                    color = if (plan.isEnable) LeapColors.accent else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    text = if (plan.beginTime.isEmpty() || plan.endTime.isEmpty()) {
                        "--"
                    } else {
                        "${plan.beginTime} - ${plan.endTime}"
                    },
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = "充至 ${plan.percent}%",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            // cyclesDescription 读不到（空串）就不摆这一行，别留个空图标。
            if (plan.cyclesDescription.isNotEmpty()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Icon(
                        Icons.Outlined.Repeat,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(13.dp),
                    )
                    Text(
                        text = plan.cyclesDescription,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/// 指标网格，两列。读不到的写 `--`。
///
/// 格子该在的位置就得在——某项这次读不到就把卡片抽走，下次读到了又冒出来，整页会跟着
/// 重排，比留个横杠更让人摸不着头脑。但「这辈子都读不到」的格子（这台车压根没这个字段）
/// 摆着就只是占地方，那种整格不摆。
@Composable
private fun MetricsGrid(state: VehicleState?) {
    // 三元组：标签、数值、单位。单位为 null 表示数值自带单位或本来就没有。
    val tiles = buildList {
        // 充电时把「还要多久」和「多快」顶到最前——这时候它俩就是最该被看到的数。
        if (state?.isCharging == true) {
            state.chargeRemainMinutes?.takeIf { it > 0 }?.let {
                add(Triple("充电剩余时间", durationText(it), null))
            }
            state.chargePowerKW?.let {
                add(Triple("充电功率", String.format(java.util.Locale.US, "%.1f", it), "kW"))
            }
        }
        // 这台车压根没有剩余能量这个字段时，格子整个不摆。C11 那套数字 ID 里就没有。
        val reportsRemainingEnergy =
            state == null || state.schema.candidates(VehicleSignal.DumpEnergy).isNotEmpty()
        if (reportsRemainingEnergy) {
            add(
                Triple(
                    "剩余能量",
                    state?.dumpEnergyWh?.let { String.format(java.util.Locale.US, "%.1f", it / 1000) } ?: "--",
                    "kWh",
                ),
            )
        }
        // 增程车的续航是电、油两个数，官方也是分开列的。纯电车照旧一个「估算续航」。
        if (state != null && state.hasFuel) {
            add(Triple("纯电续航", state.energyRange?.toString() ?: "--", "km"))
            add(Triple("汽油续航", state.gasolineRange?.toString() ?: "--", "km"))
            add(Triple("综合续航", state.totalRange?.toString() ?: "--", "km"))
            add(Triple("油量", state.gasolinePercent?.toString() ?: "--", "%"))
            // 燃油加热是间歇性的，加热时才摆——常驻一格「未加热」是每天报告一件没发生的事。
            if (state.isFuelHeating) add(Triple("燃油加热", "加热中", null))
        } else {
            add(Triple("估算续航", state?.expectedMileage?.toString() ?: "--", "km"))
        }
        add(Triple("电压 · 电流", voltageText(state), null))
        add(Triple("最低单体温度", state?.minSingleTemp?.toString() ?: "--", "°C"))
        add(Triple("总里程", state?.totalMileage?.toString() ?: "--", "km"))
        // 和首页空调卡同一套：车内读不到就退车外，标签跟着改口。车外是另一个真实的值，
        // 但绝不许它冒充车内。T03 实测整张表没有 indoorTemp，只有 outdoorTemp。
        add(
            Triple(
                if (state?.indoorTemp == null && state?.outdoorTemp != null) "车外温度" else "车内温度",
                (state?.indoorTemp ?: state?.outdoorTemp)?.let { LeapFormat.temperature(it) } ?: "--",
                "°C",
            ),
        )
    }

    tiles.chunked(2).forEach { rowItems ->
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            rowItems.forEach { (label, value, unit) ->
                GlassCard(shape = TileShape, modifier = Modifier.weight(1f)) {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier
                            .heightIn(min = 62.dp)
                            .padding(14.dp),
                    ) {
                        Text(
                            text = label,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (unit != null) {
                            MetricValue(value = value, unit = unit, valueSize = 20)
                        } else {
                            Text(
                                text = value,
                                fontSize = 20.sp,
                                fontWeight = FontWeight.Medium,
                                modifier = Modifier.padding(vertical = 3.dp),
                            )
                        }
                    }
                }
            }
            // 奇数格补一个空位，否则最后那格会撑满整行，看着像另起一块。
            if (rowItems.size == 1) Spacer(modifier = Modifier.weight(1f))
        }
    }
}

/// SOC 下面那行状态字。
private fun chargeStateLine(state: VehicleState?): String {
    if (state == null) return "读取车况中"
    // 车端没报充电状态，不等于没插枪。说成「未连接充电枪」在车正在充电时就是凭空断言。
    val charging = state.chargeState ?: return "充电状态未上报"
    return when (charging) {
        1 -> {
            val kind = if (state.isFastCharging) "直流快充" else "交流慢充"
            val remain = state.chargeRemainMinutes?.takeIf { it > 0 } ?: return "${kind}中"
            // 充电上限读不到就别说「充至几%」。写死 100% 而车主实际设的是 95，
            // 凭空多出来的那 5% 会让预计时间显得对不上。
            val limit = state.chargeLimit ?: return "$kind · 预计还需 ${durationText(remain)}"
            "$kind · 预计 ${durationText(remain)}充至 $limit%"
        }
        2 -> "充电完成"
        3 -> "充电故障，请检查充电枪"
        4 -> "预约充电等待中"
        6 -> "充电已暂停"
        // 充电状态的 0 只说明「没在充」，插没插枪是另一个字段。报了枪已连接就照说，
        // 没报（S01 / T03 没有这一项）才回到原来那句。
        else -> if (state.chargeGunConnected == true) "充电枪已连接 · 等待充电" else "未连接充电枪"
    }
}

/// 分钟数写成「2 小时 20 分」。不满一小时就只写分钟，别写「0 小时 40 分」。
private fun durationText(minutes: Int): String {
    val hours = minutes / 60
    val rest = minutes % 60
    if (hours == 0) return "$rest 分"
    return if (rest == 0) "$hours 小时" else "$hours 小时 $rest 分"
}

/// 电压电流是两个数各带一个单位，塞不进 MetricValue 那种「数值 + 尾单位」的排版，
/// 只好拼成一个字符串走无单位那条分支。
private fun voltageText(state: VehicleState?): String {
    fun part(number: Double?, unit: String): String =
        (number?.let { String.format(java.util.Locale.US, "%.0f", it) } ?: "--") + unit
    return part(state?.batteryVoltage, "V") + " · " + part(state?.batteryCurrent, "A")
}
