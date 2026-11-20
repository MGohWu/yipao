package org.yipao.app.ui.screens

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.NoPhotography
import androidx.compose.material.icons.outlined.PrivacyTip
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.yipao.app.core.LeapError
import org.yipao.app.core.ParkingPhoto
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.CarSilhouette
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.LiquidButton
import org.yipao.app.ui.components.LiquidTextButton
import org.yipao.app.ui.components.PageFootnote
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.SubPageScaffold
import org.yipao.app.ui.components.TileShape
import org.yipao.app.ui.components.liquidGlass
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.theme.LeapColors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

// 车辆功能：驻车照片、座舱 BLE 直进直出与车模预览。

/// 驻车照片：挂 P 挡后车机自动拍的最近一张。这一页只读服务端存的那张，不发拍照指令。
///
/// 与 iOS `ParkingPhotosPreviewView` 同一套状态机：加载中 / 有图 / 没图或读失败。
/// 「没图」和「读失败」文案是分开的——前者是车没拍，后者是我们没拿到，
/// 混成一句会让用户以为车坏了。
@Composable
fun ParkPhotoScreen(onBack: () -> Unit) {
    PageTint(LeapColors.frost)
    val store = LocalStore.current
    val scope = rememberCoroutineScope()
    var photo by remember { mutableStateOf<ParkingPhoto?>(null) }
    var image by remember { mutableStateOf<ImageBitmap?>(null) }
    var loading by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        if (loading) return
        loading = true
        failure = null
        try {
            val (result, bytes) = store.loadParkingPhoto()
            photo = result
            image = bytes?.let {
                BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap()
            }
            // 下到了字节却解不出位图，说明拿到的不是这台机器认得的格式。
            // 这时候显示「暂无驻车照片」是撒谎——照片是有的。
            if (bytes != null && image == null) failure = "驻车照片格式无法显示"
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            photo = null
            image = null
            failure = LeapError.messageOf(e)
        } finally {
            loading = false
        }
    }

    // 切车要重拉：上一辆的照片留在屏幕上比空着更糟。
    LaunchedEffect(store.session.selectedVin) { load() }

    SubPageScaffold(title = "驻车照片", onBack = onBack) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 4.dp),
        ) {
            Text(
                "最近驻车",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
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
                    contentDescription = "刷新驻车照片",
                    tint = if (loading) MaterialTheme.colorScheme.outline else LocalContentColor.current,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        val shot = image
        if (shot != null) {
            GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
                Box(modifier = Modifier.fillMaxWidth()) {
                    Image(
                        bitmap = shot,
                        contentDescription = "驻车照片",
                        contentScale = ContentScale.FillWidth,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    photo?.displayUploadTime?.let { time ->
                        Text(
                            text = time,
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier
                                .align(Alignment.BottomStart)
                                .padding(12.dp)
                                .clip(RoundedCornerShape(6.dp))
                                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.72f))
                                .padding(horizontal = 12.dp, vertical = 8.dp),
                        )
                    }
                }
            }
        } else {
            GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(260.dp)
                        .padding(16.dp),
                ) {
                    Spacer(modifier = Modifier.weight(1f))
                    if (loading) {
                        CircularProgressIndicator(
                            color = LeapColors.cool,
                            modifier = Modifier.size(28.dp),
                        )
                        Text("正在读取驻车照片", style = MaterialTheme.typography.labelMedium)
                    } else {
                        val problem = failure
                        Icon(
                            if (problem == null) Icons.Outlined.NoPhotography else Icons.Outlined.WarningAmber,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.outline,
                            modifier = Modifier.size(44.dp),
                        )
                        Text(
                            if (problem == null) "暂无驻车照片" else "读取失败",
                            style = MaterialTheme.typography.titleSmall,
                        )
                        Text(
                            problem ?: "车辆可能尚未开启驻车拍照，稍后再试。",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        LiquidTextButton(
                            text = "重试",
                            onClick = { scope.launch { load() } },
                            color = LeapColors.cool,
                        )
                    }
                    Spacer(modifier = Modifier.weight(1f))
                }
            }
        }

        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                Icon(
                    Icons.Outlined.PrivacyTip,
                    contentDescription = null,
                    tint = LeapColors.cool,
                    modifier = Modifier.size(20.dp),
                )
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("照片如何拍摄与存储", style = MaterialTheme.typography.titleSmall)
                    Text(
                        "挂入 P 挡后由车机自动拍摄，加密传输到手机，云端只保留最近一张。",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/// 年款车模。
@Composable
fun CarModelScreen(onBack: () -> Unit) {
    PageTint(LeapColors.frost)
    var year by rememberSaveable { mutableIntStateOf(2026) }

    SubPageScaffold(
        title = "年款车模",
        onBack = onBack,
        labBanner = true,
    ) {
        GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 20.dp, horizontal = 16.dp),
            ) {
                CarSilhouette(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(150.dp),
                )
                Text(
                    "C11 · $year 款",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .fillMaxWidth()
                .liquidGlass(TileShape, LeapColors.card)
                .padding(6.dp),
        ) {
            listOf(2024, 2025, 2026).forEach { y ->
                DirectionSegment("$y 款", year == y, modifier = Modifier.weight(1f)) { year = y }
            }
        }

        PageFootnote("车模仅用于 App 内展示，与真实车辆的配置无关。")
    }
}

// —— 本组共用的小件 ——

/// 分段选择的一段,选中蓝底。车模年款在用（直进直出页 2026-11-19 已下线）。
@Composable
internal fun DirectionSegment(
    text: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(40.dp)
            .pressable(
                onClick = onClick,
                shape = RoundedCornerShape(16.dp),
                role = Role.RadioButton,
                enabled = enabled,
            )
            .background(
                if (selected) LeapColors.cool.copy(alpha = 0.16f) else Color.Transparent,
                RoundedCornerShape(16.dp),
            ),
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelLarge,
            color = if (selected) LeapColors.cool else MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}
