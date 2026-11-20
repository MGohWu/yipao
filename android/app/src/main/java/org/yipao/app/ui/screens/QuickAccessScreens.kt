package org.yipao.app.ui.screens

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.outlined.Bluetooth
import androidx.compose.material.icons.outlined.Campaign
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.yipao.app.R
import org.yipao.app.app.BLEVehicleController
import org.yipao.app.core.OperationPasswordStore
import org.yipao.app.core.WidgetSettings
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.LiquidButton
import org.yipao.app.ui.components.LiquidSwitch
import org.yipao.app.ui.components.PageFootnote
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.SubPageScaffold
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.theme.LeapColors
import org.yipao.app.widget.HornTileService
import org.yipao.app.widget.LeapSurfaces
import org.yipao.app.widget.LockTileService
import kotlinx.coroutines.launch

// 「App 界面之外」的三处表面各自的说明页:快捷磁贴 / 桌面小组件 / 通知控车。
// 对应 iOS 的侧边按钮 / 桌面卡片 / 锁屏控件,但落点按安卓的系统能力换过:
// iOS 的锁屏控件安卓没有对等物,那一格改成了常驻通知上的两个控车按钮。
//
// 三页共用同一个「直接控车」开关(`WidgetSettings.directControlEnabled`),
// 所以每页都摆一张同样的开关卡,并在卡上写明它是三处通用的——
// 只在其中一页放的话,从另外两页进来的人会以为这一处不受它管。

/// 快捷磁贴:下拉快捷开关面板里的一键控车。
@Composable
fun QuickTileScreen(onBack: () -> Unit) {
    PageTint(LeapColors.cool)
    val context = LocalContext.current
    // 系统弹窗的回执。加没加成只有系统知道(用户可能在弹窗上点了「取消」),
    // 不把回执显示出来的话,按钮按下去屏幕上什么都不发生。
    var addResult by remember { mutableStateOf<String?>(null) }
    // 预览里当前「点亮」的磁贴,由下方胶囊点击切换,联动轮廓内的高亮格。
    // 网格前两格摆的就是壹跑这两个磁贴,其余是占位的系统磁贴(灰空块)。
    var selectedTile by remember { mutableStateOf(0) }
    // 主色是 @Composable 取的(随深浅色变),得在 composable 上下文里建,不能塞进 remember。
    val leapTiles = listOf(
        TilePreview("车锁", R.drawable.ic_widget_lock, ImageVector.vectorResource(R.drawable.ic_car_door_lock), LeapColors.accent),
        TilePreview("鸣笛寻车", R.drawable.ic_widget_horn, Icons.Outlined.Campaign, LeapColors.cool),
    )

    SubPageScaffold(title = "快捷磁贴", onBack = onBack) {
        // 手机轮廓 + 下拉面板示意:前两格是壹跑的两个磁贴,点亮的那个跟着下方胶囊走。
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 22.dp),
            ) {
                PhoneOutline {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.padding(16.dp),
                    ) {
                        repeat(2) { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                repeat(3) { col ->
                                    val index = row * 3 + col
                                    TileCell(
                                        tile = leapTiles.getOrNull(index),
                                        lit = index == selectedTile,
                                    )
                                }
                            }
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    leapTiles.forEachIndexed { index, tile ->
                        ActionChip(
                            text = tile.label,
                            icon = tile.chipIcon,
                            tint = tile.tint,
                            selected = index == selectedTile,
                            onClick = { selectedTile = index },
                        )
                    }
                }
            }
        }

        // Android 13 起系统提供了「把这个磁贴加进去吗」的官方弹窗,一步到位。
        // 12 上没有这个 API,只能照下面三步手动拖——所以步骤卡两种情况都留着。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                ) {
                    Text("一键添加", style = MaterialTheme.typography.bodyMedium)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        LiquidButton(
                            text = "车锁磁贴",
                            onClick = {
                                requestAddTile(
                                    context = context,
                                    service = LockTileService::class.java,
                                    label = "壹跑车锁",
                                    iconRes = R.drawable.ic_widget_lock,
                                ) { addResult = it }
                            },
                            modifier = Modifier.weight(1f),
                            icon = ImageVector.vectorResource(R.drawable.ic_car_door_lock),
                            height = 44.dp,
                        )
                        LiquidButton(
                            text = "鸣笛磁贴",
                            onClick = {
                                requestAddTile(
                                    context = context,
                                    service = HornTileService::class.java,
                                    label = "壹跑鸣笛",
                                    iconRes = R.drawable.ic_widget_horn,
                                ) { addResult = it }
                            },
                            modifier = Modifier.weight(1f),
                            tint = LeapColors.cool,
                            icon = Icons.Outlined.Campaign,
                            height = 44.dp,
                        )
                    }
                    addResult?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }

        DirectControlToggleCard()

        StepsCard(
            listOf(
                "下拉通知栏" to "从屏幕顶部向下滑两次，展开快捷开关面板",
                "进入编辑模式" to "点击铅笔图标，查看全部可用磁贴",
                "拖入壹跑磁贴" to "把「壹跑车锁」「壹跑鸣笛」拖到常用位置",
            ),
        )

        PageFootnote("锁屏下拉也能按到这两个磁贴。开车门那一下会先要求解锁手机，闭锁和鸣笛不会。")
    }
}

/// 桌面小组件:主屏一块常驻的控车小卡。
@Composable
fun WidgetScreen(onBack: () -> Unit) {
    // 对应 iOS 的「桌面卡片」页。
    PageTint(LeapColors.accent)
    SubPageScaffold(title = "桌面小组件", onBack = onBack) {
        WidgetPreviewConfiguration()

        DirectControlToggleCard()

        StepsCard(
            listOf(
                "长按主屏空白处" to "在弹出的菜单里选择「小部件」",
                "搜索「壹跑」" to "车况卡、车锁开关、上锁车辆、解锁车辆",
                "拖到主屏" to "车况会跟着 App 每次刷新一起更新",
            ),
        )
    }
}

/// 通知控车:蓝牙钥匙那条常驻通知上的解锁 / 闭锁按钮。
@Composable
fun NotificationControlScreen(onBack: () -> Unit) {
    // 这一格原本照抄 iOS 叫「锁屏控车」。安卓没有 iOS 那种锁屏控件,
    // 也不该有——锁屏上摆一个开车门的按钮,等于把车门交给捡到手机的人。
    // 换成常驻通知上的两个按钮:通知本身设了 VISIBILITY_SECRET,锁屏上整条不显示。
    PageTint(LeapColors.frost)
    val armed = BLEVehicleController.shared.wantsBackgroundArming

    SubPageScaffold(title = "通知控车", onBack = onBack) {
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 26.dp, horizontal = 16.dp),
            ) {
                NotificationPreview()
            }
        }

        // 这两个按钮挂在蓝牙钥匙那条通知上,没有那条通知就没有按钮。
        // 不说清楚的话,没绑蓝牙钥匙的人会在通知栏里找一条永远不出现的通知。
        StatusLineCard(
            active = armed,
            text = if (armed) "蓝牙钥匙常驻中，通知栏里能看到这两个按钮" else "蓝牙钥匙还没常驻，通知栏里暂时没有这条通知",
        )

        DirectControlToggleCard()

        StepsCard(
            listOf(
                "开启蓝牙钥匙" to "绑定车辆并保持蓝牙控车开着，常驻通知才会出现",
                "允许通知" to "系统若拦下了通知，去设置里把壹跑的通知打开",
                "下拉通知栏" to "在「蓝牙钥匙」那条通知上直接点解锁或闭锁",
            ),
        )
        PageFootnote("这条通知在锁屏上整条不显示——状态文字和这两个按钮都不会露出来。锁屏下想控车用快捷磁贴。")
    }
}

// —— 本组共用的小件 ——

/// 三处表面通用的「直接控车」开关。
///
/// 开关本身是真的（写进 `WidgetSettings`），但有一道现实约束要如实说:
/// 开了却没存操作密码的话，按钮仍旧只会打开 App。
/// 这种情况不禁止拨动——用户可能是打算等会儿去存密码，先把开关打开。
@Composable
private fun DirectControlToggleCard() {
    val scope = rememberCoroutineScope()
    var enabled by remember { mutableStateOf(WidgetSettings.directControlEnabled) }
    var hasPassword by remember { mutableStateOf(OperationPasswordStore().hasPassword) }
    // 从别的页面（比如刚去存了操作密码）回来时重新读一次。
    LaunchedEffect(Unit) {
        enabled = WidgetSettings.directControlEnabled
        hasPassword = OperationPasswordStore().hasPassword
    }

    val detail = when {
        !enabled -> "关闭时，按钮只是打开壹跑，由 App 走完整流程"
        !hasPassword -> "本机还没保存操作密码，按钮仍然只会打开壹跑"
        else -> "按下即下发，不再打开壹跑——手机解锁就等于能控车"
    }

    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("直接控车", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        detail,
                        style = MaterialTheme.typography.labelSmall,
                        color = if (enabled && !hasPassword) LeapColors.caution else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                LiquidSwitch(
                    checked = enabled,
                    onCheckedChange = { next ->
                        WidgetSettings.directControlEnabled = next
                        enabled = WidgetSettings.directControlEnabled
                        // 按钮的落点跟着变（直发广播 ↔ 打开 App 的深链），
                        // 三处表面都得重画一遍，否则要等下一次车况刷新才生效。
                        scope.launch { LeapSurfaces.reloadAll() }
                    },
                )
            }
            Text(
                "小组件、快捷磁贴、通知按钮三处共用这一个开关。",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/// 弹一次系统的「添加磁贴」窗口。Android 13 起才有。
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
private fun requestAddTile(
    context: Context,
    service: Class<*>,
    label: String,
    iconRes: Int,
    onResult: (String) -> Unit,
) {
    val manager = context.getSystemService(StatusBarManager::class.java) ?: run {
        onResult("系统没能弹出添加窗口，按下面三步手动加")
        return
    }
    manager.requestAddTileService(
        ComponentName(context, service),
        label,
        Icon.createWithResource(context, iconRes),
        context.mainExecutor,
    ) { result ->
        onResult(
            when (result) {
                StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "「$label」已加到快捷设置"
                StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "「$label」已经在快捷设置里了"
                StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "没有添加「$label」"
                else -> "系统没能弹出添加窗口，按下面三步手动加"
            },
        )
    }
}

/// 手机轮廓,内容画在「屏幕」顶部(下拉面板出现的位置)。
@Composable
private fun PhoneOutline(content: @Composable () -> Unit) {
    Box(
        modifier = Modifier
            .size(width = 184.dp, height = 306.dp)
            .border(2.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(46.dp))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.04f), RoundedCornerShape(46.dp)),
    ) {
        content()
    }
}

/// 一个壹跑磁贴在这页里的三个身份:网格里的真磁贴图标、胶囊上的图标、主色。
private data class TilePreview(
    val label: String,
    val iconRes: Int,
    val chipIcon: ImageVector,
    val tint: Color,
)

/// 预览下拉面板里的一格。`tile` 非空是壹跑磁贴,能被点亮;为空是占位的系统磁贴(灰空块)。
@Composable
private fun TileCell(tile: TilePreview?, lit: Boolean) {
    // 点亮的那格轻轻放大回弹,切换时有个「亮起来」的手感。
    val scale by animateFloatAsState(
        targetValue = if (lit) 1.08f else 1f,
        animationSpec = spring(dampingRatio = 0.45f, stiffness = 520f),
        label = "tileScale",
    )
    val background by animateColorAsState(
        targetValue = when {
            tile == null -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
            lit -> tile.tint
            else -> tile.tint.copy(alpha = 0.16f)
        },
        label = "tileBackground",
    )
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(44.dp)
            .scale(scale)
            .background(background, RoundedCornerShape(14.dp)),
    ) {
        if (tile != null) {
            Icon(
                painter = painterResource(tile.iconRes),
                contentDescription = tile.label,
                tint = if (lit) Color.White else tile.tint,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

/// 「可选磁贴动作」小胶囊。点一下把预览里点亮的磁贴切到它,选中态自身也高亮。
@Composable
private fun ActionChip(
    text: String,
    icon: ImageVector,
    tint: Color,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val background by animateColorAsState(
        targetValue = tint.copy(alpha = if (selected) 0.20f else 0.06f),
        label = "chipBackground",
    )
    val contentColor = if (selected) tint else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .clip(CircleShape)
            .clickable(onClick = onClick)
            .background(background, CircleShape)
            .border(
                width = 1.dp,
                color = if (selected) tint.copy(alpha = 0.5f) else Color.Transparent,
                shape = CircleShape,
            )
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = contentColor, modifier = Modifier.size(15.dp))
        Text(text, style = MaterialTheme.typography.labelMedium, color = contentColor)
    }
}

/// 一行状态:左边一颗点,右边一句话。
@Composable
private fun StatusLineCard(active: Boolean, text: String) {
    val tint = if (active) LeapColors.accent else MaterialTheme.colorScheme.onSurfaceVariant
    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 14.dp),
        ) {
            Box(modifier = Modifier.size(8.dp).background(tint, CircleShape))
            Text(text, style = MaterialTheme.typography.labelMedium, color = tint)
        }
    }
}

/// 常驻通知预览:蓝牙钥匙那条通知 + 底下两个控车按钮。
@Composable
private fun NotificationPreview() {
    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(24.dp))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f), RoundedCornerShape(24.dp))
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(26.dp).background(LeapColors.cool.copy(alpha = 0.16f), CircleShape),
            ) {
                Icon(
                    Icons.Outlined.Bluetooth,
                    contentDescription = null,
                    tint = LeapColors.cool,
                    modifier = Modifier.size(15.dp),
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("蓝牙钥匙", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                Text(
                    "已连接 · 走近自动解锁",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp), modifier = Modifier.padding(start = 36.dp)) {
            Text("解锁", style = MaterialTheme.typography.labelLarge, color = LeapColors.cool)
            Text("闭锁", style = MaterialTheme.typography.labelLarge, color = LeapColors.cool)
        }
    }
}

/// 圆序号时间线卡,快捷入口三页的教程都用它。
@Composable
private fun StepsCard(steps: List<Pair<String, String>>) {
    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Column(
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
        ) {
            steps.forEachIndexed { index, (title, detail) ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(28.dp)
                            .background(LeapColors.cool.copy(alpha = 0.14f), CircleShape),
                    ) {
                        Text(
                            "${index + 1}",
                            style = MaterialTheme.typography.labelMedium,
                            color = LeapColors.cool,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(title, style = MaterialTheme.typography.bodyMedium)
                        Text(
                            detail,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}
