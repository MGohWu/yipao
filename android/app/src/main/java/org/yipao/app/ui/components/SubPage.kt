package org.yipao.app.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.theme.LeapColors

/// 二级页顶栏到状态栏的间距。
///
/// 系统 inset 只到状态栏底就没了，紧接着就是返回钮，看着像贴在刘海上。三个主页面
/// 早就为标题补过这一段（见 `PageTitleTopPadding`），二级页当时漏了，两种页面来回切
/// 会感觉顶部忽紧忽松。这里补齐；主页面的标题字号大一号，所以那边留得更多，
/// 不共用同一个值。
val SubPageTopPadding = 20.dp

/// 二级页脚手架：玻璃返回圆钮 + 居中标题 + 滚动内容列。
/// 对应 iOS NavigationStack 的子页（inline 标题）。背景由外层 LeapBackground 透出。
@Composable
fun SubPageScaffold(
    title: String,
    onBack: () -> Unit,
    labBanner: Boolean = false,
    scrollable: Boolean = true,
    contentPadding: Int = 16,
    /// 顶栏右侧的操作钮（预约、全部关闭这类）。和返回钮同尺寸，摆在右边与之对称。
    actions: (@Composable RowScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
    ) {
        // 顶栏:返回钮占位左右对称,标题绝对居中。
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp)
                .padding(top = SubPageTopPadding, bottom = 8.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .size(40.dp)
                    .pressable(
                        onClick = onBack,
                        shape = CircleShape,
                        feedback = PressFeedback.Fade,
                    )
                    .liquidGlass(CircleShape, LeapColors.card),
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowBack,
                    contentDescription = "返回",
                    modifier = Modifier.size(20.dp),
                )
            }
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.align(Alignment.Center),
            )
            if (actions != null) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.align(Alignment.CenterEnd),
                    content = actions,
                )
            }
        }

        val columnModifier = if (scrollable) {
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
        } else {
            Modifier.fillMaxSize()
        }
        Column(
            modifier = columnModifier.padding(horizontal = contentPadding.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (labBanner) LabBanner()
            content()
            if (scrollable) {
                Spacer(modifier = Modifier.navigationBarsPadding().height(12.dp))
            }
        }
    }
}

/// 顶栏右侧的玻璃圆钮，和返回钮同款。`enabled = false` 时图标转灰、点不动。
@Composable
fun SubPageAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(40.dp)
            .pressable(
                onClick = onClick,
                enabled = enabled,
                shape = CircleShape,
                feedback = PressFeedback.Fade,
            )
            .liquidGlass(CircleShape, LeapColors.card),
    ) {
        Icon(
            icon,
            contentDescription = contentDescription,
            tint = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.outline,
            modifier = Modifier.size(19.dp),
        )
    }
}

/// 「暂未接入」横幅，照抄 iOS LabPreviewScaffold 顶部提示：
/// 只能预览操作页面，不会向车辆发送指令。
@Composable
fun LabBanner() {
    GlassCard(shape = TileShape, modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Icon(
                Icons.Outlined.Build,
                contentDescription = null,
                tint = LeapColors.caution,
                modifier = Modifier.size(20.dp),
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = "暂未接入",
                    style = MaterialTheme.typography.titleSmall,
                )
                Text(
                    text = "只能预览操作页面，不会向车辆发送指令",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(
                Icons.Outlined.Lock,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.outline,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

/// 卡片外的灰色脚注，各二级页通用。
@Composable
fun PageFootnote(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.outline,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
}

/// 同上，正文里需要嵌链接时用这一版。
@Composable
fun PageFootnote(text: AnnotatedString) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.outline,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
}
