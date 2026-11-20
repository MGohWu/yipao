package org.yipao.app.ui.screens

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.material.icons.outlined.Autorenew
import androidx.compose.material.icons.outlined.Bluetooth
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.DirectionsCar
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.KeyOff
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Sensors
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Warning
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import org.yipao.app.app.BLEPairingState
import org.yipao.app.app.BLERuntimeState
import org.yipao.app.core.BLEConfigurationSyncState
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.AnchoredConfirmation
import org.yipao.app.ui.components.AnchoredOverlayBox
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.HairlineDivider
import org.yipao.app.ui.components.LiquidButton
import org.yipao.app.ui.components.LiquidSpinner
import org.yipao.app.ui.components.LiquidSwitch
import org.yipao.app.ui.components.PageFootnote
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.SectionTitle
import org.yipao.app.ui.components.StatusPill
import org.yipao.app.ui.components.SubPageScaffold
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.components.liquidGlass
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.relativeText
import org.yipao.app.ui.theme.LeapColors

// 蓝牙钥匙三级链路：概览 → 钥匙设置 → 配对搜索。
// 状态全部来自 `store.ble`（BLEVehicleController），没有一处是写死的展示值。

/// 概览页：大钥匙图标 + 当前运行时状态 + 进入设置。同 iOS `BluetoothFeatureOverview`。
@Composable
fun BleKeyScreen(onBack: () -> Unit, onOpenSettings: () -> Unit) {
    PageTint(LeapColors.cool)
    val store = LocalStore.current
    val eligible = store.bluetoothKeyEligible

    // 进页面先把运行时按当前账号/车辆装配一次，否则状态文案会停在上次离开时的值。
    LaunchedEffect(store.session.selectedVin, eligible) { store.refreshBluetoothRuntime() }

    SubPageScaffold(title = "蓝牙钥匙", onBack = onBack) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 30.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(110.dp)
                    .liquidGlass(CircleShape, LeapColors.card),
            ) {
                Icon(
                    Icons.Outlined.Key,
                    contentDescription = null,
                    tint = LeapColors.cool,
                    modifier = Modifier.size(48.dp),
                )
            }
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(store.ble.runtimeState.label, style = MaterialTheme.typography.titleLarge)
                Text(
                    store.ble.runtimeState.detail ?: "可信车辆绑定 · 近车直连 · 无感解闭锁",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (!eligible) {
                StatusPill(
                    text = "当前模式不能绑定车辆",
                    icon = Icons.Outlined.Info,
                )
            }
        }

        Spacer(modifier = Modifier.height(18.dp))

        if (eligible) {
            LiquidButton(
                text = "进入蓝牙钥匙设置",
                onClick = onOpenSettings,
                tint = LeapColors.cool,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        PageFootnote("蓝牙钥匙直接与车辆通信，不依赖手机网络，地库和信号盲区也能用。")
    }
}

/// 钥匙设置页：运行时状态 + 钥匙行为开关 + 绑定信息。同 iOS `BluetoothKeySettingsView`。
@Composable
fun BleKeySettingsScreen(onBack: () -> Unit, onOpenPairing: () -> Unit) {
    PageTint(LeapColors.cool)
    val store = LocalStore.current
    val ble = store.ble
    val binding = ble.binding
    var removeConfirm by remember { mutableStateOf(false) }

    // 常驻通知要通知权限（安卓 13 起）。不给也不影响无感钥匙——前台服务照跑，只是那条
    // 状态通知不显示，所以只在用户主动打开蓝牙控车时问一次，拒了就不再问。
    val notificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { }

    LaunchedEffect(Unit) { store.refreshBluetoothRuntime() }

    SubPageScaffold(title = "钥匙设置", onBack = onBack) {
        SectionTitle("状态")
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column {
                RuntimeRow(ble.runtimeState)
                if (binding == null) {
                    HairlineDivider(startIndent = 16.dp)
                    ActionRow(
                        icon = Icons.Outlined.Sensors,
                        title = "搜索并绑定车辆",
                        onClick = onOpenPairing,
                    )
                }
            }
        }
        // 前台服务顶得住系统回收，但顶不住用户上滑强杀（那是明确的「停」）和系统蓝牙关闭。
        // 这两种情况照实说，别让用户以为「装了就一定一直在」。
        PageFootnote(
            "绑定后会有一条「蓝牙钥匙」常驻通知，那是无感钥匙在后台保持连接的凭证，" +
                "关掉蓝牙控车就会消失。上滑强杀 App 或关闭系统蓝牙后，需要重新打开 App 才能恢复。",
        )

        if (binding != null) {
            val enabled = binding.isBluetoothControlEnabled
            SectionTitle("车辆钥匙")
            GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
                Column {
                    ToggleRow(
                        title = "蓝牙控车",
                        detail = "首页解闭锁优先走蓝牙直连",
                        checked = enabled,
                        onChecked = {
                            store.setBluetoothControlEnabled(it)
                            if (it) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        },
                    )
                    HairlineDivider(startIndent = 16.dp)
                    ToggleRow(
                        title = "无感解锁",
                        detail = "带着手机走近车辆时解锁",
                        checked = binding.configuration.autoUnlockEnabled,
                        onChecked = { store.setPassiveAutoUnlock(it) },
                        enabled = enabled,
                    )
                    HairlineDivider(startIndent = 16.dp)
                    ToggleRow(
                        title = "离车自动闭锁",
                        detail = "离开车辆一段距离后落锁",
                        checked = binding.configuration.autoLockEnabled,
                        onChecked = { store.setPassiveAutoLock(it) },
                        enabled = enabled,
                    )
                    HairlineDivider(startIndent = 16.dp)
                    InfoRow("设置同步", syncStateText(binding.syncState))
                    HairlineDivider(startIndent = 16.dp)
                    InfoRow("快速重连", if (ble.reconnectTokenAvailable) "已就绪" else "等待首次认证")
                }
            }
            PageFootnote("无感动作由车辆根据距离区域执行，App 不读取信号强度主动解锁。")

            SectionTitle("绑定")
            GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
                Column {
                    InfoRow("车辆", maskedAddress(binding.deviceAddress), monospaced = true)
                    HairlineDivider(startIndent = 16.dp)
                    InfoRow("证书", binding.certificateFingerprint, monospaced = true)
                    binding.lastVerifiedAt?.let {
                        HairlineDivider(startIndent = 16.dp)
                        InfoRow("最近验证", relativeText(it))
                    }
                    HairlineDivider(startIndent = 16.dp)
                    ActionRow(
                        icon = Icons.Outlined.Autorenew,
                        title = "重新绑定",
                        onClick = onOpenPairing,
                    )
                    HairlineDivider(startIndent = 16.dp)
                    // 移除要先把关闭配置同步到车上，不可逆，锚一层确认。
                    AnchoredOverlayBox(
                        expanded = removeConfirm,
                        onDismissRequest = { removeConfirm = false },
                        modifier = Modifier.fillMaxWidth(),
                        anchor = {
                            ActionRow(
                                icon = Icons.Outlined.KeyOff,
                                title = "移除蓝牙钥匙",
                                destructive = true,
                                onClick = { removeConfirm = true },
                            )
                        },
                    ) {
                        AnchoredConfirmation(
                            title = "移除蓝牙钥匙？",
                            message = "App 会先同步关闭车辆端的无感设置；车辆不在附近时会保留为待同步。",
                            confirmText = "移除",
                            destructive = true,
                            onConfirm = {
                                removeConfirm = false
                                store.removeBluetoothBinding()
                            },
                            onCancel = { removeConfirm = false },
                        )
                    }
                }
            }
        }
    }
}

/// 配对页：权限 → 系统蓝牙 → 扫描 → 选车 → 认证。
@Composable
fun BleKeyPairingScreen(onBack: () -> Unit) {
    PageTint(LeapColors.cool)
    val store = LocalStore.current
    val ble = store.ble
    val context = LocalContext.current

    var permitted by remember { mutableStateOf(ble.hasBluetoothPermission) }
    // 被永久拒绝之后系统弹窗不会再出现，只能引到应用详情页去开。
    var asked by rememberSaveable { mutableStateOf(false) }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { permitted = ble.hasBluetoothPermission }
    // 系统蓝牙开关不给回调，用户从系统弹窗回来时重新读一次。
    val enableLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { permitted = ble.hasBluetoothPermission }

    LaunchedEffect(permitted) {
        if (permitted && ble.bluetoothEnabled) store.prepareBLEPairing()
    }
    // 绑成了就别再取消——取消会把刚建立的连接放掉。
    DisposableEffect(Unit) {
        onDispose { if (ble.pairingState != BLEPairingState.Bound) ble.cancelPairing() }
    }

    val pairingState = ble.pairingState

    SubPageScaffold(title = "绑定车辆", onBack = onBack) {
        SectionTitle("当前车辆")
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column {
                when {
                    !ble.bluetoothSupported ->
                        StateRow(Icons.Outlined.Warning, "这台设备不支持低功耗蓝牙", LeapColors.caution)

                    !permitted -> {
                        StateRow(Icons.Outlined.Bluetooth, "需要「附近的设备」权限才能搜索车辆", LeapColors.cool)
                        HairlineDivider(startIndent = 16.dp)
                        ActionRow(
                            icon = Icons.Outlined.Settings,
                            title = if (asked) "去系统设置开启蓝牙权限" else "允许使用附近的蓝牙设备",
                            onClick = {
                                if (asked) {
                                    context.startActivity(
                                        Intent(
                                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                            Uri.fromParts("package", context.packageName, null),
                                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                    )
                                } else {
                                    asked = true
                                    permissionLauncher.launch(
                                        arrayOf(
                                            Manifest.permission.BLUETOOTH_SCAN,
                                            Manifest.permission.BLUETOOTH_CONNECT,
                                        ),
                                    )
                                }
                            },
                        )
                    }

                    !ble.bluetoothEnabled -> {
                        StateRow(Icons.Outlined.PowerSettingsNew, "系统蓝牙未打开", LeapColors.caution)
                        HairlineDivider(startIndent = 16.dp)
                        ActionRow(
                            icon = Icons.Outlined.Bluetooth,
                            title = "打开蓝牙",
                            onClick = {
                                enableLauncher.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
                            },
                        )
                    }

                    else -> PairingStatusRow(pairingState)
                }
            }
        }

        if (permitted && ble.bluetoothEnabled && ble.bluetoothSupported) {
            SectionTitle("附近车辆")
            GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
                Column {
                    val candidates = ble.devices.sortedByDescending { it.rssi }
                    if (candidates.isEmpty()) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 14.dp),
                        ) {
                            if (ble.isScanning) LiquidSpinner(color = LeapColors.cool, size = 18.dp)
                            Text(
                                if (ble.isScanning) "正在搜索附近车辆" else "没有发现车辆",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    } else {
                        val busy = pairingState is BLEPairingState.Connecting ||
                            pairingState is BLEPairingState.Authenticating ||
                            pairingState == BLEPairingState.Bound
                        candidates.forEachIndexed { index, device ->
                            if (index > 0) HairlineDivider(startIndent = 16.dp)
                            DeviceRow(
                                name = device.displayName,
                                detail = "${maskedAddress(device.address)}  ·  ${device.rssi} dBm",
                                enabled = !busy,
                                onClick = { ble.pair(device.address) },
                            )
                        }
                    }

                    if (pairingState is BLEPairingState.Failed) {
                        HairlineDivider(startIndent = 16.dp)
                        ActionRow(
                            icon = Icons.Outlined.Refresh,
                            title = "重新搜索",
                            onClick = { ble.beginPairing() },
                        )
                    }
                }
            }
            PageFootnote("只有通过当前 VIN 完整认证的车辆才会保存为绑定。")
        }
    }
}

// —— 本组共用的小件 ——

private fun syncStateText(state: BLEConfigurationSyncState) = when (state) {
    BLEConfigurationSyncState.Synced -> "已同步"
    BLEConfigurationSyncState.Pending -> "等待车辆"
    BLEConfigurationSyncState.PendingDisable -> "等待同步关闭"
}

/// MAC 只留厂商段和尾段。这一页可能被截图分享，整串 MAC 是能定位到这台车的。
private fun maskedAddress(address: String): String {
    val parts = address.split(":")
    if (parts.size != 6) return "**"
    return "${parts[0]}:${parts[1]}:**:**:**:${parts[5]}"
}

@Composable
private fun RuntimeRow(state: BLERuntimeState) {
    val icon: ImageVector
    val tint: Color
    when (state) {
        BLERuntimeState.Ready -> {
            icon = Icons.Outlined.CheckCircle
            tint = LeapColors.accent
        }
        BLERuntimeState.WaitingForBluetooth, is BLERuntimeState.NeedsAttention -> {
            icon = Icons.Outlined.Warning
            tint = LeapColors.caution
        }
        BLERuntimeState.Disabled -> {
            icon = Icons.Outlined.PowerSettingsNew
            tint = LeapColors.cool
        }
        BLERuntimeState.Unbound -> {
            icon = Icons.Outlined.Sensors
            tint = LeapColors.cool
        }
        else -> {
            icon = Icons.Outlined.Autorenew
            tint = LeapColors.cool
        }
    }
    StateRow(icon, state.label, tint, detail = state.detail)
}

@Composable
private fun PairingStatusRow(state: BLEPairingState) = when (state) {
    BLEPairingState.Idle -> StateRow(Icons.Outlined.Autorenew, "正在准备蓝牙", LeapColors.cool)
    BLEPairingState.Scanning -> StateRow(Icons.Outlined.Sensors, "请选择车辆", LeapColors.cool)
    is BLEPairingState.Connecting -> StateRow(Icons.Outlined.Bluetooth, "正在连接", LeapColors.cool)
    is BLEPairingState.Authenticating ->
        StateRow(Icons.Outlined.Lock, "正在验证车辆身份", LeapColors.cool)
    BLEPairingState.Bound -> StateRow(Icons.Outlined.CheckCircle, "绑定成功", LeapColors.accent)
    is BLEPairingState.Failed -> StateRow(Icons.Outlined.Warning, state.message, LeapColors.caution)
}

@Composable
private fun StateRow(icon: ImageVector, title: String, tint: Color, detail: String? = null) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Column(
            verticalArrangement = Arrangement.spacedBy(3.dp),
            modifier = Modifier
                .weight(1f)
                .padding(start = 12.dp),
        ) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            if (detail != null) {
                Text(
                    detail,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun InfoRow(title: String, value: String, monospaced: Boolean = false) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Text(title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = if (monospaced) FontFamily.Monospace else null,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ToggleRow(
    title: String,
    detail: String,
    checked: Boolean,
    onChecked: (Boolean) -> Unit,
    enabled: Boolean = true,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(
                detail,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        LiquidSwitch(checked = checked, onCheckedChange = onChecked, enabled = enabled)
    }
}

@Composable
private fun ActionRow(
    icon: ImageVector,
    title: String,
    onClick: () -> Unit,
    destructive: Boolean = false,
) {
    val tint = if (destructive) MaterialTheme.colorScheme.error else LeapColors.cool
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .pressable(onClick = onClick, feedback = PressFeedback.Fade)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Text(
            title,
            style = MaterialTheme.typography.bodyMedium,
            color = if (destructive) MaterialTheme.colorScheme.error else Color.Unspecified,
            modifier = Modifier
                .weight(1f)
                .padding(start = 12.dp),
        )
        Icon(
            Icons.Outlined.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.outline,
        )
    }
}

@Composable
private fun DeviceRow(name: String, detail: String, enabled: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (enabled) Modifier.pressable(onClick = onClick, feedback = PressFeedback.Fade)
                else Modifier,
            )
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(
            Icons.Outlined.DirectionsCar,
            contentDescription = null,
            tint = LeapColors.cool,
            modifier = Modifier.size(20.dp),
        )
        Column(
            verticalArrangement = Arrangement.spacedBy(3.dp),
            modifier = Modifier
                .weight(1f)
                .padding(start = 12.dp),
        ) {
            Text(name, style = MaterialTheme.typography.bodyMedium)
            Text(
                detail,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            Icons.Outlined.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.outline,
        )
    }
}
