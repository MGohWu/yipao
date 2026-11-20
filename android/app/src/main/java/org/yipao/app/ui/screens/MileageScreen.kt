package org.yipao.app.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.EmojiEvents
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.yipao.app.core.DrivingStats
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.components.VerticalHairline
import org.yipao.app.ui.components.liquidGlass
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.theme.LeapColors
import kotlinx.coroutines.launch

/// 里程能耗页，对齐 iOS `MileageStatsView`：
/// 累计三列 → 近 6 周百公里电耗（可点柱子）→ 所选周能耗构成环形 → 近 7 天里程折线。
/// 数据来自四个 drivingrecord 接口（见 `VehicleStore.loadDrivingStats`），
/// 任一块缺失就整卡不出——不填 0，也不拿别的区间顶。
///
/// iOS 那边是下拉刷新，安卓这套二级页骨架没有下拉，换成右上角一个刷新钮。
///
/// 自己不画标题栏：外面是「行程」页（`TripsScreen`）。
@Composable
fun ColumnScope.MileageStatsContent() {
    val store = LocalStore.current
    val scope = rememberCoroutineScope()
    var stats by remember { mutableStateOf<DrivingStats?>(null) }
    var loading by remember { mutableStateOf(true) }
    /// 当前选中的周柱子（`WeeklyEC.id`）。默认最后一根「本周」，和官方一致。
    /// 周列表整个没拉到时为 null，构成卡退回「近 7 天」并改口。
    var selectedWeekID by remember { mutableStateOf<String?>(null) }
    /// 按周缓存的能耗构成：点过的周不再重复请求。
    val distributions = remember { mutableStateMapOf<String, DrivingStats.EnergyDistribution>() }
    var loadingWeekID by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        loading = true
        val loaded = store.loadDrivingStats()
        stats = loaded
        // 刷新会把六周的数一起换新，旧缓存不能留着接着用。
        distributions.clear()
        loadingWeekID = null
        selectedWeekID = loaded?.distributionWeekID
        val id = loaded?.distributionWeekID
        val distribution = loaded?.energyDistribution
        if (id != null && distribution != null) distributions[id] = distribution
        loading = false
    }

    /// 点某根周柱子：切选中态，缺数据才发请求，拿过的直接用缓存。
    fun select(week: DrivingStats.WeeklyEC) {
        val range = week.range ?: return
        selectedWeekID = week.id
        if (distributions[week.id] != null) return
        loadingWeekID = week.id
        scope.launch {
            // 拉不到就不写缓存：下次再点还会重试，界面这轮整卡隐藏。
            store.loadEnergyDistribution(range)?.let { distributions[week.id] = it }
            if (loadingWeekID == week.id) loadingWeekID = null
        }
    }

    // 切车要重拉：上一辆的里程留在屏幕上比空着更糟。
    LaunchedEffect(store.session.selectedVin) { load() }

    run {
        Row(modifier = Modifier.fillMaxWidth()) {
            Spacer(modifier = Modifier.weight(1f))
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(36.dp)
                    .pressable(
                        onClick = { scope.launch { load() } },
                        enabled = !loading,
                        shape = CircleShape,
                        feedback = PressFeedback.Fade,
                    )
                    .liquidGlass(CircleShape, LeapColors.card),
            ) {
                Icon(
                    Icons.Outlined.Refresh,
                    contentDescription = "刷新里程能耗",
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        val current = stats
        if (current != null && !current.isEmpty) {
            current.totals?.let { TotalsCard(it) }
            val weekly = current.weekly
            if (weekly != null && weekly.weeks.isNotEmpty()) {
                WeeklyCard(weekly, selectedWeekID, onSelect = ::select)
            }
            DistributionSection(current, selectedWeekID, distributions, loadingWeekID)
            if (current.daily.isNotEmpty()) DailyCard(current.daily)
        } else if (loading) {
            Placeholder("正在加载里程能耗…", spinning = true)
        } else {
            Placeholder("暂时拿不到里程能耗数据", spinning = false)
        }
    }
}

// MARK: - 累计里程 / 累计能耗 / 交付天数

@Composable
private fun TotalsCard(totals: DrivingStats.Totals) {
    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min)
                .padding(vertical = 16.dp),
        ) {
            TotalColumn("累计里程", totals.totalMileageKm?.let(::grouped), "km", Modifier.weight(1f))
            VerticalHairline(height = 34.dp)
            TotalColumn("累计能耗", totals.totalEnergyKwh?.let(::grouped), "kWh", Modifier.weight(1f))
            VerticalHairline(height = 34.dp)
            TotalColumn("交付天数", totals.deliveryDays?.let(::grouped), "天", Modifier.weight(1f))
        }
    }
}

@Composable
private fun TotalColumn(title: String, value: String?, unit: String, modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
        modifier = modifier,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = value ?: "--",
            fontSize = 21.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
        Text(
            text = unit,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.outline,
        )
    }
}

// MARK: - 近 6 周百公里电耗 + 排名 + 柱状

@Composable
private fun WeeklyCard(
    weekly: DrivingStats.Weekly,
    selectedWeekID: String?,
    onSelect: (DrivingStats.WeeklyEC) -> Unit,
) {
    val maxValue = maxOf(weekly.weeks.mapNotNull { it.hundredKmEc }.maxOrNull() ?: 1.0, 0.1)
    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Column(
            verticalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier.padding(16.dp),
        ) {
            Row(modifier = Modifier.fillMaxWidth()) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier.weight(1f),
                ) {
                    Text(
                        text = "近 6 周百公里电耗",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            text = weekly.rankHundredKmEc?.let(::trimmed) ?: "--",
                            fontSize = 26.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = "kWh",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline,
                            modifier = Modifier.padding(start = 4.dp, bottom = 3.dp),
                        )
                    }
                }
                val rank = weekly.rankPercent
                if (rank != null) {
                    Column(
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier.padding(start = 8.dp),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier
                                .background(LeapColors.accent.copy(alpha = 0.14f), CircleShape)
                                .padding(horizontal = 11.dp, vertical = 5.dp),
                        ) {
                            Icon(
                                Icons.Outlined.EmojiEvents,
                                contentDescription = null,
                                tint = LeapColors.accent,
                                modifier = Modifier.size(13.dp),
                            )
                            Text(
                                text = "前 $rank",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.SemiBold,
                                color = LeapColors.accent,
                            )
                        }
                        Text(
                            text = "领先全国同车型",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline,
                            maxLines = 1,
                        )
                    }
                }
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(7.dp),
                verticalAlignment = Alignment.Bottom,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(108.dp),
            ) {
                weekly.weeks.forEachIndexed { index, week ->
                    val isLast = index == weekly.weeks.lastIndex
                    // 主色跟着选中走；一根都没选中（周列表在、但区间解析不出来）时回到「本周高亮」。
                    val highlighted = selectedWeekID?.let { it == week.id } ?: isLast
                    val value = week.hundredKmEc ?: 0.0
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier
                            .weight(1f)
                            .pressable(
                                onClick = { onSelect(week) },
                                enabled = week.range != null,
                                feedback = PressFeedback.Fade,
                            ),
                    ) {
                        Text(
                            text = week.hundredKmEc?.let(::trimmed) ?: "--",
                            fontSize = 10.sp,
                            fontWeight = if (highlighted) FontWeight.SemiBold else FontWeight.Normal,
                            color = if (highlighted) {
                                MaterialTheme.colorScheme.onSurface
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            },
                        )
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(maxOf(6.0, value / maxValue * 74).dp)
                                .background(
                                    if (highlighted) {
                                        LeapColors.accent
                                    } else {
                                        LeapColors.cool.copy(alpha = 0.5f)
                                    },
                                    RoundedCornerShape(4.dp),
                                ),
                        )
                        Text(
                            text = if (isLast) "本周" else weekLabel(week),
                            fontSize = 9.sp,
                            color = MaterialTheme.colorScheme.outline,
                            maxLines = 1,
                        )
                    }
                }
            }
        }
    }
}

// MARK: - 能耗构成环形图（跟着选中的那一周走）

/// 选中周的构成卡。没选中任何周（周列表没拉到）时退回 `stats` 里那份「近 7 天」并改口；
/// 选中周拉不到数据就整卡不出——不填 0，也不拿别的区间顶。
@Composable
private fun DistributionSection(
    stats: DrivingStats,
    selectedWeekID: String?,
    distributions: Map<String, DrivingStats.EnergyDistribution>,
    loadingWeekID: String?,
) {
    if (selectedWeekID != null) {
        val week = stats.weekly?.weeks?.firstOrNull { it.id == selectedWeekID }
        val title = week?.let {
            weekRangeLabel(it, isLast = it.id == stats.weekly?.weeks?.lastOrNull()?.id)
        } ?: "所选周"
        val distribution = distributions[selectedWeekID]
        if (distribution != null) {
            DistributionCard(distribution, "${title}能耗分布")
        } else if (loadingWeekID == selectedWeekID) {
            DistributionLoadingCard("${title}能耗分布")
        }
    } else {
        stats.energyDistribution?.let { DistributionCard(it, "近 7 天能耗分布") }
    }
}

@Composable
private fun DistributionLoadingCard(title: String) {
    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Column(
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(16.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(104.dp),
            ) {
                CircularProgressIndicator(modifier = Modifier.size(26.dp), strokeWidth = 2.5.dp)
            }
        }
    }
}

@Composable
private fun DistributionCard(dist: DrivingStats.EnergyDistribution, title: String) {
    val driverColor = LeapColors.accent
    val acColor = LeapColors.cool
    val otherColor = LeapColors.warm
    // 三块都是 0 时不能拿 0 当分母；此时三段各画 0 度，环是空的。
    val total = maxOf(dist.driverKwh + dist.acKwh + dist.otherKwh, 0.0001)
    val driverFrac = (dist.driverKwh / total).toFloat()
    val acFrac = (dist.acKwh / total).toFloat()
    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Column(
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(16.dp),
        ) {
            Text(
                text = "$title · 总 ${trimmed(dist.totalKwh)} kWh",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Box(contentAlignment = Alignment.Center, modifier = Modifier.size(104.dp)) {
                    Canvas(modifier = Modifier.size(104.dp)) {
                        val pad = 8.dp.toPx()
                        val stroke = 15.dp.toPx()
                        val rect = Size(size.width - pad * 2, size.height - pad * 2)
                        val topLeft = Offset(pad, pad)
                        fun arc(from: Float, to: Float, color: Color) {
                            drawArc(
                                color = color,
                                startAngle = -90f + from * 360f,
                                sweepAngle = (to - from) * 360f,
                                useCenter = false,
                                topLeft = topLeft,
                                size = rect,
                                style = Stroke(stroke, cap = StrokeCap.Butt),
                            )
                        }
                        arc(0f, driverFrac, driverColor)
                        arc(driverFrac, driverFrac + acFrac, acColor)
                        arc(driverFrac + acFrac, 1f, otherColor)
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            text = trimmed(dist.totalKwh),
                            fontSize = 20.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = "kWh",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline,
                        )
                    }
                }
                Column(
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.weight(1f),
                ) {
                    LegendRow("行车能耗", dist.driverPct, driverColor)
                    LegendRow("空调能耗", dist.acPct, acColor)
                    LegendRow("其他能耗", dist.otherPct, otherColor)
                }
            }
        }
    }
}

@Composable
private fun LegendRow(title: String, pct: Double?, color: Color) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(modifier = Modifier.size(10.dp).background(color, RoundedCornerShape(2.dp)))
        Text(
            text = title,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = pct?.let { "${trimmed(it)}%" } ?: "--",
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.Medium,
        )
    }
}

// MARK: - 近 7 天里程折线

@Composable
private fun DailyCard(daily: List<DrivingStats.DailyMileage>) {
    val total = daily.sumOf { it.mileageKm ?: 0 }
    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Column(
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(16.dp),
        ) {
            Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = "近 7 天里程",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Text(text = grouped(total), fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    text = "km",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.padding(start = 3.dp, bottom = 2.dp),
                )
            }
            DailyMileageChart(
                values = daily.map { (it.mileageKm ?: 0).toDouble() },
                labels = daily.map(::dayLabel),
            )
        }
    }
}

/// 折线图：每日里程连成线，点上标数值，底部标日期，末点空心加粗（今天还在累计）。
///
/// 数值/日期两排字是 `drawText` 画进画布的：Compose 的 Canvas 会裁掉画布外的东西，
/// 所以首末两点得往里缩一段，否则贴边的标签会被切掉半个字——iOS 那边 GeometryReader
/// 不裁剪，可以让标签溢出去，这里不行。
@Composable
private fun DailyMileageChart(values: List<Double>, labels: List<String>) {
    if (values.isEmpty()) return
    val measurer = rememberTextMeasurer()
    val accent = LeapColors.accent
    val surface = MaterialTheme.colorScheme.surface
    val primaryColor = MaterialTheme.colorScheme.onSurface
    val secondaryColor = MaterialTheme.colorScheme.onSurfaceVariant
    val tertiaryColor = MaterialTheme.colorScheme.outline

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(104.dp),
    ) {
        val topInset = 20.dp.toPx()      // 给数值标签留头
        val bottomInset = 18.dp.toPx()   // 给日期标签留脚
        val sideInset = 14.dp.toPx()     // 给首末两个标签留边
        val plotHeight = maxOf(size.height - topInset - bottomInset, 1f)
        val plotWidth = maxOf(size.width - sideInset * 2, 1f)
        val maxValue = maxOf(values.max(), 1.0)
        val minValue = minOf(values.min(), maxValue)
        val span = maxOf(maxValue - minValue, 1.0)
        val points = values.mapIndexed { index, value ->
            val x = if (values.size > 1) {
                sideInset + plotWidth * index / (values.size - 1)
            } else {
                size.width / 2
            }
            val y = topInset + plotHeight * (1f - ((value - minValue) / span).toFloat())
            Offset(x, y)
        }

        val path = Path().apply {
            moveTo(points.first().x, points.first().y)
            points.drop(1).forEach { lineTo(it.x, it.y) }
        }
        drawPath(path, accent, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round))

        points.forEachIndexed { index, point ->
            val isLast = index == points.lastIndex
            if (isLast) {
                drawCircle(surface, 4.5.dp.toPx(), point)
                drawCircle(accent, 4.5.dp.toPx(), point, style = Stroke(2.dp.toPx()))
            } else {
                drawCircle(accent, 3.dp.toPx(), point)
            }
            val valueLayout = measurer.measure(
                text = values[index].toInt().toString(),
                style = TextStyle(
                    fontSize = 10.sp,
                    fontWeight = if (isLast) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (isLast) primaryColor else secondaryColor,
                ),
            )
            drawText(
                valueLayout,
                topLeft = Offset(
                    x = point.x - valueLayout.size.width / 2f,
                    y = maxOf(point.y - 13.dp.toPx() - valueLayout.size.height / 2f, 0f),
                ),
            )
            val dayLayout = measurer.measure(
                text = dayText(labels, index),
                style = TextStyle(
                    fontSize = 9.sp,
                    color = if (isLast) secondaryColor else tertiaryColor,
                ),
            )
            drawText(
                dayLayout,
                topLeft = Offset(
                    x = point.x - dayLayout.size.width / 2f,
                    y = size.height - dayLayout.size.height,
                ),
            )
        }
    }
}

// MARK: - 状态占位

@Composable
private fun Placeholder(text: String, spinning: Boolean) {
    GlassCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 28.dp),
        ) {
            if (spinning) {
                CircularProgressIndicator(modifier = Modifier.size(26.dp), strokeWidth = 2.5.dp)
            } else {
                Icon(
                    Icons.Outlined.BarChart,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(26.dp),
                )
            }
            Text(
                text = text,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

// MARK: - 小工具

/// 千分位：87398 → "87,398"。
private fun grouped(value: Int): String = String.format("%,d", value)

/// 去掉多余小数尾巴：15.0 → "15"，15.7 → "15.7"。
private fun trimmed(value: Double): String =
    if (value == Math.rint(value)) value.toInt().toString() else String.format("%.1f", value)

/// "2026-07-06" → "7/6"。
private fun weekLabel(week: DrivingStats.WeeklyEC): String {
    val start = week.weekStart ?: return ""
    val parts = start.split("-")
    if (parts.size != 3) return start
    return "${parts[1].toIntOrNull() ?: 0}/${parts[2].toIntOrNull() ?: 0}"
}

/// 构成卡标题里的周名：最后一根叫「本周」，其余用 "7/6–7/12" 这样的区间。
private fun weekRangeLabel(week: DrivingStats.WeeklyEC, isLast: Boolean): String {
    if (isLast) return "本周"
    val start = weekLabel(week)
    val end = week.weekEnd ?: return start
    val parts = end.split("-")
    if (parts.size != 3) return start
    return "$start–${parts[1].toIntOrNull() ?: 0}/${parts[2].toIntOrNull() ?: 0}"
}

/// day 形如 "2026-08-06" 或 "08-06"，取「日」。
private fun dayLabel(entry: DrivingStats.DailyMileage): String {
    val last = entry.day.split("-").lastOrNull()?.toIntOrNull() ?: return entry.day
    return last.toString()
}

/// 末尾三天改叫今天/昨天/前天——比光秃秃一个日号好认。
private fun dayText(labels: List<String>, index: Int): String = when (index) {
    labels.lastIndex -> "今天"
    labels.lastIndex - 1 -> "昨天"
    labels.lastIndex - 2 -> "前天"
    else -> labels[index]
}
