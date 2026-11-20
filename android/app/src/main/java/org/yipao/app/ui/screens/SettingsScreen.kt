package org.yipao.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyOff
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PrivacyTip
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.yipao.app.app.BiometricGate
import org.yipao.app.core.AppEnv
import org.yipao.app.core.VehicleUtil
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.Routes
import org.yipao.app.ui.components.AnchoredConfirmation
import org.yipao.app.ui.components.AnchoredMenu
import org.yipao.app.ui.components.AnchoredOverlayBox
import org.yipao.app.ui.components.CardShape
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.HairlineDivider
import org.yipao.app.ui.components.LiquidSwitch
import org.yipao.app.ui.components.LiquidTextButton
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.SectionTitle
import org.yipao.app.ui.components.TintedIconBadge
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.theme.AppearanceMode
import org.yipao.app.ui.theme.LeapColors

/// 设置页:账号与车辆 → 安全 → 外观 → 支持 → 关于 → 退出登录。对齐 iOS SettingsView。
@Composable
fun SettingsScreen(
    contentPadding: androidx.compose.foundation.layout.PaddingValues,
    onOpen: (String) -> Unit,
) {
    // 同 iOS SettingsView。
    PageTint(LeapColors.cool)
    val store = LocalStore.current
    val scope = rememberCoroutineScope()
    var appearanceMenu by remember { mutableStateOf(false) }
    var logoutConfirm by remember { mutableStateOf(false) }
    var forgetConfirm by remember { mutableStateOf(false) }
    val session = store.session
    val kind = store.biometricKind

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(contentPadding)
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            text = "设置",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(top = PageTitleTopPadding),
        )

        // 账号和车辆是一件事：这个账号下有哪些车。
        SectionTitle("账号")
        SectionCard {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                TintedIconBadge(icon = Icons.Filled.Person, size = 46)
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        text = maskedPhone(session.phone),
                        style = MaterialTheme.typography.titleMedium,
                        fontFamily = FontFamily.Monospace,
                    )
                    Text(
                        text = if (session.isLoggedIn) "已登录" else "未登录",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            // 多车时可点着换，单车时只是一行只读信息。
            if (session.vehicles.size > 1) {
                session.vehicles.forEach { vehicle ->
                    RowDivider()
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .pressable(
                                onClick = { scope.launch { store.selectVehicle(vehicle) } },
                                feedback = PressFeedback.Fade,
                            )
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    ) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Text(text = vehicle.name, style = MaterialTheme.typography.bodyMedium)
                            Text(
                                text = VehicleUtil.maskedVin(vehicle.vin),
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        if (vehicle.vin == session.selectedVin) {
                            Icon(
                                Icons.Filled.Check,
                                contentDescription = "当前车辆",
                                tint = LeapColors.accent,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            } else {
                session.selectedVehicle?.let { vehicle ->
                    RowDivider()
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    ) {
                        Text(
                            text = vehicle.name,
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            text = VehicleUtil.maskedVin(vehicle.vin),
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }

        SectionTitle("安全")
        SectionCard {
            if (kind == BiometricGate.Kind.None) {
                InfoRow(
                    icon = Icons.Filled.Lock,
                    title = "生物识别不可用",
                    subtitle = "此设备未启用指纹或人脸，控车时需要输入操作密码",
                )
            } else {
                ToggleRow(
                    icon = if (kind == BiometricGate.Kind.Face) Icons.Filled.Face else Icons.Filled.Fingerprint,
                    title = "${kind.label}快捷验证",
                    subtitle = "控车时用${kind.label}解锁已保存的操作密码",
                    checked = store.biometricEnabled,
                    onChecked = { store.updateBiometricEnabled(it) },
                )
            }
            RowDivider()
            if (store.hasSavedPassword) {
                // 忘记密码同样不可逆，锚一层确认再删。
                AnchoredOverlayBox(
                    expanded = forgetConfirm,
                    onDismissRequest = { forgetConfirm = false },
                    modifier = Modifier.fillMaxWidth(),
                    anchor = {
                        NavRow(
                            icon = Icons.Filled.KeyOff,
                            title = "忘记已保存的操作密码",
                            subtitle = "删除后下次控车重新输入",
                            destructive = true,
                            onClick = { forgetConfirm = true },
                        )
                    },
                ) {
                    AnchoredConfirmation(
                        title = "忘记操作密码",
                        message = "本机保存的操作密码会被删掉，下次控车需要重新输入。",
                        confirmText = "删除",
                        destructive = true,
                        onConfirm = {
                            forgetConfirm = false
                            store.forgetPassword()
                        },
                        onCancel = { forgetConfirm = false },
                    )
                }
            } else {
                InfoRow(
                    icon = Icons.Filled.Key,
                    title = "操作密码未保存",
                    subtitle = "下次控车输入后可选择记住",
                )
            }
        }
        Footnote("操作密码只加密保存在本机，不会同步到别处。")

        SectionTitle("外观")
        SectionCard {
            // iOS 26 的做法：行尾一个「跟随系统 ⌄」小按钮，点开从它下面弹玻璃菜单。
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                Icon(
                    Icons.Filled.Contrast,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
                Text(
                    text = "深浅外观",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 14.dp),
                )
                AnchoredOverlayBox(
                    expanded = appearanceMenu,
                    onDismissRequest = { appearanceMenu = false },
                    anchor = {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .pressable(
                                    onClick = { appearanceMenu = true },
                                    shape = CircleShape,
                                    feedback = PressFeedback.Fade,
                                )
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                        ) {
                            Text(
                                text = store.appearance.label,
                                style = MaterialTheme.typography.bodyMedium,
                                color = LeapColors.accent,
                            )
                            Icon(
                                Icons.Filled.UnfoldMore,
                                contentDescription = "切换深浅外观",
                                tint = LeapColors.accent,
                                modifier = Modifier
                                    .padding(start = 2.dp)
                                    .size(16.dp),
                            )
                        }
                    },
                ) {
                    AnchoredMenu(
                        options = AppearanceMode.entries,
                        selected = store.appearance,
                        label = { it.label },
                        onSelect = {
                            appearanceMenu = false
                            store.updateAppearance(it)
                        },
                    )
                }
            }
            RowDivider()
            ToggleRow(
                icon = Icons.Filled.DirectionsCar,
                title = "显示车模型",
                subtitle = "关闭后首页显示轮廓剪影",
                checked = store.showCarModel,
                onChecked = { store.updateShowCarModel(it) },
            )
            if (store.showCarModel) {
                RowDivider()
                NavRow(
                    icon = Icons.Filled.Refresh,
                    title = if (store.isCarModelRefreshing) "正在下载车模型" else "刷新车模型",
                    subtitle = "重新下载零跑官方车模型资源",
                    onClick = if (store.isCarModelRefreshing) null else {
                        { scope.launch { store.refreshCarModel() } }
                    },
                )
            }
        }
        Footnote("车模型资源来自零跑官方；车况刷新不会改动车模型。")

        SectionTitle("关于")
        SectionCard {
            NavRow(icon = Icons.Outlined.Description, title = "用户协议", onClick = { onOpen(Routes.Agreement) })
            RowDivider()
            NavRow(icon = Icons.Filled.PrivacyTip, title = "隐私政策", onClick = { onOpen(Routes.Privacy) })
        }
        Footnote("我们不会记录和上传零跑官方服务的会话信息，控车信息等其他信息。")

        SectionCard {
            // 退出登录是不可逆操作，先从按钮上弹一层确认。
            AnchoredOverlayBox(
                expanded = logoutConfirm,
                onDismissRequest = { logoutConfirm = false },
                modifier = Modifier.fillMaxWidth(),
                anchor = {
                    LiquidTextButton(
                        text = "退出登录",
                        onClick = { logoutConfirm = true },
                        icon = Icons.AutoMirrored.Filled.Logout,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 4.dp, vertical = 6.dp),
                    )
                },
            ) {
                AnchoredConfirmation(
                    title = "退出登录",
                    message = "会清除本机的登录状态和操作密码，需要重新用验证码登录。",
                    confirmText = "退出登录",
                    destructive = true,
                    onConfirm = {
                        logoutConfirm = false
                        scope.launch { store.logout() }
                    },
                    onCancel = { logoutConfirm = false },
                )
            }
        }
        Footnote("壹跑 Android ${AppEnv.versionName}")
        Spacer(modifier = Modifier.height(8.dp))
    }
}

/// 手机号打码：11 位才打，其余原样（拿不到就写「未知账号」）。
private fun maskedPhone(phone: String): String {
    if (phone.length != 11) return phone.ifEmpty { "未知账号" }
    return "${phone.take(3)} **** ${phone.takeLast(4)}"
}

@Composable
private fun SectionCard(content: @Composable () -> Unit) {
    GlassCard(
        shape = CardShape,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column { content() }
    }
}

@Composable
private fun RowDivider() {
    HairlineDivider(startIndent = 16.dp)
}

@Composable
private fun Footnote(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.outline,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
}

@Composable
private fun ToggleRow(
    icon: ImageVector,
    title: String,
    subtitle: String?,
    checked: Boolean,
    onChecked: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(text = title, style = MaterialTheme.typography.bodyMedium)
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        LiquidSwitch(checked = checked, onCheckedChange = onChecked)
    }
}

@Composable
private fun InfoRow(icon: ImageVector, title: String, subtitle: String?) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(text = title, style = MaterialTheme.typography.bodyMedium)
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun NavRow(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    destructive: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val tint = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (onClick != null) {
                    Modifier.pressable(onClick = onClick, feedback = PressFeedback.Fade)
                } else {
                    Modifier
                }
            )
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(text = title, style = MaterialTheme.typography.bodyMedium, color = tint)
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Icon(
            Icons.Outlined.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.outline,
            modifier = Modifier.size(18.dp),
        )
    }
}
