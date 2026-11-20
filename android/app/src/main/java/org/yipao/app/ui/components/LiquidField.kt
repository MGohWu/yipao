package org.yipao.app.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.theme.LeapColors

/// iOS 26 的输入框和勾选框。
///
/// M3 的 TextField 有两样东西在这套界面里格格不入：会往上飘的 label，
/// 和输入框底部那条粗指示线。iOS 的做法是一个圆角填充框，提示文字就待在框里，
/// 一敲字就消失，没有位移动画，也没有下划线。

/// 输入框圆角。跟 iOS 登录页的 `.rect(cornerRadius: 18)` 对齐。
private val FieldShape = RoundedCornerShape(18.dp)

/// 独立输入框：自带圆角填充底，登录页这种直接摆在页面上的用它。
@Composable
fun LiquidTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    /// 永远显示在输入内容左边的固定文字，比如手机号前的「+86」。
    prefix: String? = null,
    singleLine: Boolean = true,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    textStyle: TextStyle = MaterialTheme.typography.bodyLarge,
    minHeight: Dp = 54.dp,
    /// 输入内容左边的图标，比如验证码框的短信图标。跟 [prefix] 一样是常驻的，
    /// 区别只是它画的是图形，所以调用方自己给颜色。
    leading: @Composable (RowScope.() -> Unit)? = null,
    trailing: @Composable (RowScope.() -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .defaultMinSize(minHeight = minHeight)
            .liquidGlass(FieldShape, LeapColors.card)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        if (leading != null) leading()
        if (prefix != null) {
            Text(
                text = prefix,
                style = textStyle,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        LiquidBasicField(
            value = value,
            onValueChange = onValueChange,
            placeholder = placeholder,
            singleLine = singleLine,
            keyboardOptions = keyboardOptions,
            textStyle = textStyle,
            modifier = Modifier.weight(1f),
        )
        if (trailing != null) trailing()
    }
}

/// 嵌在卡片里的输入框：不画自己的底，借卡片的。
/// 卡片本身已经是玻璃，再套一层填充底就是玻璃里嵌了块塑料。
@Composable
fun LiquidInlineField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    singleLine: Boolean = false,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    textStyle: TextStyle = MaterialTheme.typography.bodyMedium,
) {
    LiquidBasicField(
        value = value,
        onValueChange = onValueChange,
        placeholder = placeholder,
        singleLine = singleLine,
        keyboardOptions = keyboardOptions,
        textStyle = textStyle,
        modifier = modifier.padding(horizontal = 12.dp, vertical = 10.dp),
    )
}

/// 光标和占位文字的共用实现。BasicTextField 默认没有占位文字，得自己在底下垫一层。
@Composable
private fun LiquidBasicField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String?,
    singleLine: Boolean,
    keyboardOptions: KeyboardOptions,
    textStyle: TextStyle,
    modifier: Modifier = Modifier,
) {
    val merged = textStyle.merge(color = MaterialTheme.colorScheme.onSurface)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = singleLine,
        keyboardOptions = keyboardOptions,
        textStyle = merged,
        cursorBrush = SolidColor(LeapColors.accent),
        modifier = modifier,
        decorationBox = { inner ->
            // 单行的居中，多行的顶头。多行框还居中的话，写第一行时光标浮在框中间，
            // 敲到第三行又整体往上跳一次。
            Box(contentAlignment = if (singleLine) Alignment.CenterStart else Alignment.TopStart) {
                if (value.isEmpty() && placeholder != null) {
                    Text(
                        text = placeholder,
                        style = merged,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
                inner()
            }
        },
    )
}

/// iOS 的勾选框是个圆，不是 M3 那个方块。未选中只有一圈细线，
/// 选中了整个圆填成主题色、里面一个白勾。勾用弹簧放大出场，
/// 跟开关的圆钮同一个手感。
@Composable
fun LiquidCheck(
    checked: Boolean,
    modifier: Modifier = Modifier,
    tint: Color = LeapColors.accent,
    size: Dp = 20.dp,
) {
    val fill by animateFloatAsState(
        targetValue = if (checked) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.62f, stiffness = Spring.StiffnessMediumLow),
        label = "checkFill",
    )
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .size(size)
            .border(1.4.dp, LeapColors.glassEdge, CircleShape),
    ) {
        Box(
            modifier = Modifier
                .graphicsLayer {
                    scaleX = fill
                    scaleY = fill
                    alpha = fill
                }
                .size(size)
                .background(tint, CircleShape),
        )
        Icon(
            Icons.Rounded.Check,
            contentDescription = null,
            tint = tint.readableContent(),
            modifier = Modifier
                .graphicsLayer {
                    scaleX = fill
                    scaleY = fill
                    alpha = fill
                }
                .size(size * 0.68f),
        )
    }
}
