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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AcUnit
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Air
import androidx.compose.material.icons.outlined.AutoMode
import androidx.compose.material.icons.outlined.Cyclone
import androidx.compose.material.icons.outlined.EditCalendar
import androidx.compose.material.icons.outlined.LocalFireDepartment
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Remove
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.yipao.app.core.ClimateMode
import org.yipao.app.core.LeapFormat
import org.yipao.app.core.VehicleState
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.LiquidIconButton
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.SubPageAction
import org.yipao.app.ui.components.SubPageScaffold
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.components.readableContent
import org.yipao.app.ui.theme.LeapColors
import kotlinx.coroutines.delay

/// 空调页，对应 iOS ClimateView：温度盘 → 模式分段 → 风量 → 内外循环 → 四个快捷场景。
/// 右上角进预约空调子页。
///
/// 所有设定值都存在 VehicleStore 上（跟车况轮询共用一份，草稿有新鲜期保护），
/// 这里只负责改值 + 触发下发。温度是连点的，每点一下都发一条会把车按死，
/// 所以 ± 只改本地值，800ms 没有新的点击才真的推一次（同 iOS 的 debounce）。
@Composable
fun ClimateScreen(onBack: () -> Unit, onOpenAppointment: () -> Unit = {}) {
    val store = LocalStore.current
    val state = store.state
    val climateOn = store.climateOn

    // 防抖用的计数器。不能盯着温度值本身做防抖——车况轮询也会写这个值，
    // 那样一次后台刷新就能凭空下发一条指令。
    var pushTick by remember { mutableIntStateOf(0) }
    LaunchedEffect(pushTick) {
        if (pushTick == 0) return@LaunchedEffect
        delay(800)
        store.pushClimateIfRunning()
    }

    // 车报的模式。没报模式但报了「是不是自动」的车，至少能确认自动这一档。
    val confirmedMode = state?.climateMode ?: if (state?.acAutoMode == true) ClimateMode.Auto else null
    fun isSelected(mode: ClimateMode): Boolean = when {
        confirmedMode != null -> confirmedMode == mode
        // 车明说了不是自动模式，那自动这一档就不该亮，哪怕本机记的是自动。
        state?.acAutoMode == false && mode == ClimateMode.Auto -> false
        else -> store.climateMode == mode
    }

    // 空调页背景跟着当前模式走，同 iOS ClimateView：关机时冷蓝压到六成、制热转暖橙、其余冷蓝。
    PageTint(
        when {
            !climateOn -> LeapColors.cool.copy(alpha = 0.6f)
            store.climateMode == ClimateMode.Hot -> LeapColors.warm
            else -> LeapColors.cool
        }
    )

    SubPageScaffold(
        title = "空调",
        onBack = onBack,
        // 预约空调（cmdid 171），同 iOS 右上角那个日历钮。演示账号也能进，回读在演示态直接给「没有预约」。
        actions = {
            SubPageAction(icon = Icons.Outlined.EditCalendar, contentDescription = "预约空调", onClick = onOpenAppointment)
        },
    ) {
        // 温度盘卡:电源钮在右上,巨大设定温度在中间,±圆钮两侧。
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = when {
                            !climateOn -> "空调已关闭 · 保留上次设定"
                            confirmedMode == null -> "空调运行中"
                            else -> "空调运行中 · ${confirmedMode.label}"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                    LiquidIconButton(
                        icon = Icons.Outlined.PowerSettingsNew,
                        contentDescription = "空调开关",
                        onClick = {
                            if (store.isSendingCommand) return@LiquidIconButton
                            store.applyClimate(on = !climateOn)
                        },
                        container = if (climateOn) LeapColors.accent else LeapColors.accent.copy(alpha = 0.15f),
                        tint = if (climateOn) LeapColors.accent.readableContent() else LeapColors.accent,
                    )
                }

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(22.dp),
                    modifier = Modifier.padding(vertical = 14.dp),
                ) {
                    TempStepButton(Icons.Outlined.Remove, "调低") {
                        if (store.climateTemperature > 18) {
                            store.updateClimateTemperature(store.climateTemperature - 1)
                            pushTick++
                        }
                    }
                    Row(verticalAlignment = Alignment.Top) {
                        Text(
                            text = "${store.climateTemperature}",
                            fontSize = 78.sp,
                            fontWeight = FontWeight.Light,
                            lineHeight = 80.sp,
                        )
                        Text(
                            text = "°",
                            fontSize = 28.sp,
                            fontWeight = FontWeight.Light,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 8.dp),
                        )
                    }
                    TempStepButton(Icons.Outlined.Add, "调高") {
                        if (store.climateTemperature < 32) {
                            store.updateClimateTemperature(store.climateTemperature + 1)
                            pushTick++
                        }
                    }
                }

                // 车内/车外温度：哪个没报就不写哪个，两个都没有就整行不出现。
                val ambient = ambientLine(state)
                if (ambient != null) {
                    Text(
                        text = ambient,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        // 模式四分段:制冷/制热/通风/自动
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(10.dp),
            ) {
                ClimateMode.entries.forEach { mode ->
                    val selected = isSelected(mode)
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(5.dp),
                        modifier = Modifier
                            .weight(1f)
                            .pressable(
                                onClick = {
                                    store.updateClimateMode(mode)
                                    store.pushClimateIfRunning()
                                },
                                enabled = !store.isSendingCommand,
                                shape = RoundedCornerShape(14.dp),
                                role = Role.RadioButton,
                            )
                            .background(if (selected) LeapColors.cool.copy(alpha = 0.14f) else Color.Transparent)
                            .padding(vertical = 10.dp),
                    ) {
                        Icon(
                            modeIcon(mode),
                            contentDescription = mode.label,
                            tint = if (selected) LeapColors.cool else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp),
                        )
                        Text(
                            text = mode.label,
                            style = MaterialTheme.typography.labelMedium,
                            color = if (selected) LeapColors.cool else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }

        // 车不报模式的时候得说清楚上面那一格亮的是哪来的，否则用户会以为那是车的当前状态。
        val notice = if (climateOn && state?.acModeRaw == null) {
            if (state?.acAutoMode == null) {
                "这台车不上报空调模式，上面选中的是本机记录的上次设定。"
            } else {
                "这台车只上报是不是自动模式，制冷还是制热它不报——那两档高亮的是本机记录。"
            }
        } else {
            null
        }
        if (notice != null) {
            Text(
                text = notice,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }

        // 风量卡:7 根递增柱,≤当前档位上蓝色。
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.padding(16.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = "风量",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = "${store.climateFanLevel} 档",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium,
                    )
                }
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Bottom,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    (1..7).forEach { level ->
                        val active = level <= store.climateFanLevel
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .height((16.5 + (level - 1) * 4.5).dp)
                                .pressable(
                                    onClick = {
                                        store.updateClimateFanLevel(level)
                                        store.pushClimateIfRunning()
                                    },
                                    enabled = !store.isSendingCommand,
                                    shape = RoundedCornerShape(4.dp),
                                    role = Role.RadioButton,
                                )
                                .background(
                                    // 空调关着的时候柱子不上色：那是「上次设定」，不是正在吹的风。
                                    if (active && climateOn) LeapColors.cool
                                    else MaterialTheme.colorScheme.surfaceVariant
                                ),
                        )
                    }
                }
            }
        }

        // 内外循环:整卡可点切换。
        val circleActive = climateOn && store.climateCircleIn
        GlassCard(
            shape = TileShape,
            onClick = if (store.isSendingCommand) {
                null
            } else {
                {
                    store.updateClimateCircleIn(!store.climateCircleIn)
                    store.pushClimateIfRunning()
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                Icon(
                    Icons.Outlined.Sync,
                    contentDescription = null,
                    tint = if (circleActive) LeapColors.accent else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = if (store.climateCircleIn) "内循环" else "外循环",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium,
                    )
                    Text(
                        text = "轻点切换",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        // 四个快捷场景。这几条是整套下发（开机 + 温度 + 风量），不是改设定，所以不走防抖。
        // 快速除味（2026-11-19，同 iOS）：通风 + 外循环 + 7 档 + 不开除雾，判据不比温度。
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
            val busy = store.isSendingCommand
            QuickScene("快速降温", Icons.Outlined.AcUnit, LeapColors.cool, busy, Modifier.weight(1f)) {
                store.quickCool()
            }
            QuickScene("快速制热", Icons.Outlined.LocalFireDepartment, LeapColors.warm, busy, Modifier.weight(1f)) {
                store.quickHeat()
            }
            QuickScene("除霜", Icons.Outlined.Air, LeapColors.frost, busy, Modifier.weight(1f)) {
                store.defrost()
            }
            QuickScene("除味", Icons.Outlined.Cyclone, LeapColors.accent, busy, Modifier.weight(1f)) {
                store.deodorize()
            }
        }
        Spacer(modifier = Modifier.height(2.dp))
    }
}

/// 车内/车外温度那一行。读不到的一侧直接不写，两侧都读不到返回 null 整行不显示。
private fun ambientLine(state: VehicleState?): String? {
    val parts = buildList {
        state?.indoorTemp?.let { add("车内 ${LeapFormat.temperature(it)}°") }
        state?.outdoorTemp?.let { add("车外 ${LeapFormat.temperature(it)}°") }
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

private fun modeIcon(mode: ClimateMode): ImageVector = when (mode) {
    ClimateMode.Cold -> Icons.Outlined.AcUnit
    ClimateMode.Hot -> Icons.Outlined.LocalFireDepartment
    ClimateMode.Vent -> Icons.Outlined.Air
    ClimateMode.Auto -> Icons.Outlined.AutoMode
}

@Composable
private fun TempStepButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    LiquidIconButton(
        icon = icon,
        contentDescription = label,
        onClick = onClick,
        size = 54.dp,
        iconSize = 24.dp,
        container = LeapColors.cool.copy(alpha = 0.12f),
        tint = LeapColors.cool,
    )
}

@Composable
private fun QuickScene(
    label: String,
    icon: ImageVector,
    tint: Color,
    busy: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    GlassCard(shape = TileShape, onClick = if (busy) null else onClick, modifier = modifier) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(7.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 14.dp),
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = if (busy) MaterialTheme.colorScheme.outline else tint,
                modifier = Modifier.size(22.dp),
            )
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                color = if (busy) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.onSurface,
                // 四格等宽之后窄屏上「快速降温」会被挤断成两行，宁可省略也不让四格高低不齐。
                maxLines = 1,
            )
        }
    }
}
