package org.yipao.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.AirlineSeatReclineNormal
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.EvStation
import androidx.compose.material.icons.filled.Kitchen
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.ToggleOn
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.yipao.app.app.DemoData
import org.yipao.app.app.VehicleStore
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.Routes
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.theme.LeapColors

/// 功能中心的一项能力。
private data class Feature(
    val title: String,
    val detail: String,
    val icon: ImageVector,
    val route: String,
    /// 这台车摆不摆得出来。座舱两项按车走，其余恒为真。
    val visible: (VehicleStore) -> Boolean = { true },
)

/// 分组结构沿用 iOS ControlFeature.Group（2026-11-19 改版：快捷控车 / 座舱 / 能源）。
/// iOS 独有的入口换成安卓对应物：侧边按钮 → 快捷磁贴，桌面卡片 → 桌面小组件，
/// 锁屏控件 → 蓝牙钥匙常驻通知上的解锁 / 闭锁按钮。
///
/// 「车辆」组整个撤掉（同 iOS）：「直进直出」下线（只删入口和页面，蓝牙底层
/// `CallCarController` 留着）；「驻车照片」地图页位置卡上已经有，不再重复一个入口。
private val featureGroups: List<Pair<String, List<Feature>>> = listOf(
    "快捷控车" to listOf(
        Feature("快捷磁贴", "下拉快捷开关控车", Icons.Filled.ToggleOn, Routes.QuickTile),
        Feature("通知控车", "常驻通知上一键解闭锁", Icons.Filled.Notifications, Routes.NotificationControl),
        Feature("桌面小组件", "主屏快速控车", Icons.Filled.Widgets, Routes.Widget),
        Feature("蓝牙钥匙", "近车直连与无感解锁", Icons.Filled.Bluetooth, Routes.BleKey),
    ),
    // 舒适座舱和车载冰箱按车走：车况信号在场、或能力码有，才给入口（判据见
    // `VehicleStore.cabinComfortSupported` / `fridgeSupported`）。车主那台 C16 没装冰箱，
    // 这个格子在他车上整个不出现——照「读不到就别显示」，而不是摆一个点进去一片空白的入口。
    "座舱" to listOf(
        Feature(
            "舒适座舱", "座椅加热通风、方向盘与后视镜", Icons.Filled.AirlineSeatReclineNormal,
            Routes.ComfortCabin, visible = { it.cabinComfortSupported },
        ),
        Feature(
            "车载冰箱", "制冷保温与离车保持", Icons.Filled.Kitchen,
            Routes.Fridge, visible = { it.fridgeSupported },
        ),
    ),
    "能源" to listOf(
        Feature("电池预热", "立即或预约加热", Icons.Filled.LocalFireDepartment, Routes.BatteryHeat),
        Feature("充电计划", "预约时段、目标电量与循环日", Icons.Filled.EvStation, Routes.ChargePlan),
    ),
)

/// 演示账号看到的那三项。审核演示账号不展示未发布能力，功能页退成纯控车入口。
private val reviewSafeControls: List<Feature> = listOf(
    Feature("空调", "温度、模式与风量", Icons.Filled.Air, Routes.Climate),
    Feature("能源", "电量、续航与充电状态", Icons.Filled.EvStation, Routes.Charge),
    Feature("车辆位置", "位置与导航", Icons.Filled.LocationOn, Routes.Location),
)

/// 功能页（2026-11-19 同 iOS 改版）。
///
/// 原先是一个功能一张 150dp 高的大玻璃瓦片，图标外再套圆框，滑好几屏。改成
/// **一组一张卡，卡里两列，每格是「图标 + 名字 + 一行说明」**，图标不套圆框，框里不再套框。
/// 顶部只留一个「功能」大标题，原来叠着的「控车中心」和车名那行去掉了——车名首页已经有。
@Composable
fun FeatureCenterScreen(
    contentPadding: androidx.compose.foundation.layout.PaddingValues,
    onOpen: (String) -> Unit,
) {
    // 功能中心走冰蓝，同 iOS FeatureCenterView。
    PageTint(LeapColors.frost)
    val store = LocalStore.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(contentPadding)
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
    ) {
        Text(
            text = "功能",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(top = PageTitleTopPadding),
        )

        if (store.isDemo && !DemoData.showsLabCatalog) {
            FeatureGroupCard("常用功能", reviewSafeControls, onOpen)
        } else {
            featureGroups.forEach { (group, features) ->
                val visible = features.filter { it.visible(store) }
                // 整组都被挡掉时连标题一起不出现，否则会剩一个底下什么都没有的小标题。
                if (visible.isNotEmpty()) FeatureGroupCard(group, visible, onOpen)
            }
        }
        Spacer(modifier = Modifier.height(8.dp))
    }
}

/// 一组功能：小标题 + 一张玻璃卡，卡里两列。
@Composable
private fun FeatureGroupCard(title: String, features: List<Feature>, onOpen: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .padding(start = 6.dp)
                .semantics { heading() },
        )
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(4.dp)) {
                features.chunked(2).forEach { rowItems ->
                    // IntrinsicSize.Min：两格各自按内容算高，行取高的那个，字号调大时还是一样高。
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(IntrinsicSize.Min),
                    ) {
                        rowItems.forEach { feature ->
                            FeatureGridCell(
                                feature,
                                onClick = { onOpen(feature.route) },
                                modifier = Modifier.weight(1f),
                            )
                        }
                        if (rowItems.size == 1) Spacer(modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

/// 卡里的一格：图标在左，名字和一行说明在右。
@Composable
private fun FeatureGridCell(feature: Feature, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .fillMaxHeight()
            .defaultMinSize(minHeight = 72.dp)
            .pressable(onClick = onClick, shape = TileShape, feedback = PressFeedback.Fade)
            .padding(horizontal = 12.dp, vertical = 14.dp),
    ) {
        Icon(
            feature.icon,
            contentDescription = null,
            tint = LeapColors.accent,
            modifier = Modifier
                .width(26.dp)
                .size(22.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
            Text(text = feature.title, style = MaterialTheme.typography.titleSmall)
            Text(
                text = feature.detail,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
