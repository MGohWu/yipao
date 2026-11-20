package org.yipao.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.theme.LeapColors

/// 锚点弹层的圆角。iOS 26 弹层比卡片更圆一档。
private val OverlayShape = RoundedCornerShape(22.dp)

/// 弹层的玻璃底板。所有锚点弹层内容都套在它里面。
/// 三件事缺一不可，否则就是一块白板：面罩色留透明度（不能拿不透明的 bar）、
/// 折射内容取景层（只折射背景等于透出一片平渐变）、模糊拉大到看不清底下的字。
@Composable
private fun OverlaySurface(content: @Composable ColumnScope.() -> Unit) {
    val contentBackdrop = LocalContentBackdrop.current ?: LocalBackgroundBackdrop.current
    Box(
        modifier = Modifier
            .shadow(24.dp, OverlayShape, clip = false)
            .liquidGlass(
                shape = OverlayShape,
                surface = LeapColors.overlay,
                backdrop = contentBackdrop,
                blurRadius = 20.dp,
            )
            .clip(OverlayShape),
    ) {
        Column(modifier = Modifier.width(260.dp)) { content() }
    }
}

/// iOS 26 的确认弹层：标题 + 说明 + 竖排按钮，按钮之间发丝分隔线。
/// 危险操作（退出登录、清除数据）用 destructive = true 标红。
@Composable
fun AnchoredConfirmation(
    title: String,
    message: String? = null,
    confirmText: String,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
    destructive: Boolean = false,
) {
    OverlaySurface {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp)
                .padding(top = 18.dp, bottom = 14.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
            )
            if (message != null) {
                Text(
                    text = message,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
        }
        HairlineDivider()
        OverlayAction(
            text = confirmText,
            color = if (destructive) MaterialTheme.colorScheme.error else LeapColors.accent,
            bold = true,
            onClick = onConfirm,
        )
        HairlineDivider()
        OverlayAction(
            text = "取消",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            onClick = onCancel,
        )
    }
}

/// iOS 26 的下拉菜单：竖排选项，当前项右侧打勾。
/// 每项可带一个前置图标（跟 iOS 的 Menu label 一样）。
@Composable
fun <T> AnchoredMenu(
    options: List<T>,
    selected: T?,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    icon: (T) -> ImageVector? = { null },
) {
    OverlaySurface {
        options.forEachIndexed { index, option ->
            if (index > 0) HairlineDivider()
            val isSelected = option == selected
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .pressable(
                        onClick = { onSelect(option) },
                        feedback = PressFeedback.Fade,
                        role = Role.RadioButton,
                    )
                    .padding(horizontal = 18.dp, vertical = 14.dp),
            ) {
                val leading = icon(option)
                if (leading != null) {
                    Icon(
                        leading,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Text(
                    text = label(option),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = if (isSelected) FontWeight.Medium else FontWeight.Normal,
                    modifier = Modifier.weight(1f),
                )
                if (isSelected) {
                    Icon(
                        Icons.Outlined.Check,
                        contentDescription = "已选中",
                        tint = LeapColors.accent,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

/// 弹层里的单个动作行。整行可点，跟 iOS 的 confirmationDialog 一样。
@Composable
private fun OverlayAction(
    text: String,
    color: Color,
    bold: Boolean = false,
    onClick: () -> Unit,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .pressable(onClick = onClick, feedback = PressFeedback.Fade)
            .padding(vertical = 14.dp),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
            color = color,
        )
    }
}
