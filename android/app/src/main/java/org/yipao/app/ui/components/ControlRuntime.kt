package org.yipao.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Backspace
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.yipao.app.app.AuthChallenge
import org.yipao.app.app.BiometricGate
import org.yipao.app.app.VehicleStore
import org.yipao.app.ui.theme.LeapColors
import kotlinx.coroutines.delay

/// 全局轻提示。控车的全部意义就是「指令发出去了，车到底动没动」，
/// 结果只写在这一条里，所以它盖在导航之上，所有页面共用。
///
/// 两种形态：普通提示是底部浮起的玻璃胶囊；超时要重试的那种做成整行宽的卡片——
/// 「重试」是用户此刻最可能按的一个键，别让人眯着眼在小胶囊里找。
@Composable
fun BoxScope.ToastHost(store: VehicleStore) {
    val toast = store.toast
    var visible by remember { mutableStateOf(false) }
    // 记住最后一条：收起动画还在跑的时候 toast 已经清空了，
    // 内容得留住，否则文字会在滑下去的半路变成空的。
    var shown by remember { mutableStateOf(toast) }
    LaunchedEffect(toast?.id) {
        val current = toast ?: return@LaunchedEffect
        shown = current
        visible = true
        delay((current.seconds * 1000).toLong())
        visible = false
        // 动画播完再真的清掉，别让下一条提示插进收起动画里。
        delay(220)
        if (store.toast?.id == current.id) store.toast = null
    }

    AnimatedVisibility(
        visible = visible,
        enter = slideInVertically(tween(260)) { it / 2 } + fadeIn(tween(260)),
        exit = slideOutVertically(tween(200)) { it / 2 } + fadeOut(tween(200)),
        modifier = Modifier
            .align(Alignment.BottomCenter)
            .padding(bottom = 110.dp),
    ) {
        val current = shown
        if (current != null) {
            if (current.showsRetry) {
                RetryCard(current.text, current.detail) { store.retryLastCommand() }
            } else {
                ToastCapsule(current.text, current.detail, current.isError)
            }
        }
    }
}

@Composable
private fun ToastCapsule(text: String, detail: String?, isError: Boolean) {
    Box(modifier = Modifier.liquidGlass(CircleShape, LeapColors.card)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
        ) {
            Icon(
                if (isError) Icons.Outlined.WarningAmber else Icons.Outlined.CheckCircle,
                contentDescription = null,
                tint = if (isError) LeapColors.caution else LeapColors.accent,
                modifier = Modifier.size(16.dp),
            )
            Column {
                Text(text = text, style = MaterialTheme.typography.labelLarge)
                if (detail != null) {
                    Text(
                        text = detail,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun RetryCard(text: String, detail: String?, onRetry: () -> Unit) {
    Box(modifier = Modifier.padding(horizontal = 16.dp)) {
        Box(modifier = Modifier.liquidGlass(TileShape, LeapColors.card)) {
            Column(
                verticalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier.padding(18.dp),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(
                        Icons.Outlined.WarningAmber,
                        contentDescription = null,
                        tint = LeapColors.caution,
                        modifier = Modifier.size(22.dp),
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(
                            text = text,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                        )
                        if (detail != null) {
                            Text(
                                text = detail,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                LiquidButton(text = "重试", onClick = onRetry, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

/// 弹层面板内的瓦片底色：描边 + 半透明底，刻意不做玻璃。
/// 弹层底板已经是玻璃了，再套一层会显脏；而且瓦片折射的是底下的页面、
/// 不是它压着的底板，透出来比底板还通，看着是脱节的。
@Composable
fun Modifier.sheetTile(shape: androidx.compose.ui.graphics.Shape): Modifier = this
    .border(0.8.dp, LeapColors.glassEdge, shape)
    .clip(shape)
    .background(LeapColors.card)

/// 操作密码弹窗，照抄 iOS OperationPasswordSheet：
/// 标题 → 4 圆点 → 数字九宫格 → 记住密码开关 → 取消。输满 4 位自动提交。
///
/// 用自绘键盘而不是系统键盘：密码是定长数字，自绘做得到「输满即发」，
/// 也避免键盘弹出把玻璃层顶飞。
@Composable
fun PasswordSheetHost(store: VehicleStore) {
    val challenge = store.challenge as? AuthChallenge.OperationPassword
    val visible = challenge != null
    // 收起动画还在跑的时候 challenge 已经清空了，文案得留住最后一次的，
    // 否则「用于验证「解锁」操作」那行会在滑下去的半路变成空的。
    var prompt by remember { mutableStateOf("") }
    LaunchedEffect(challenge) {
        challenge?.let { prompt = it.prompt }
    }
    var input by remember { mutableStateOf("") }
    var rememberPwd by remember { mutableStateOf(true) }
    // 弹窗常驻，输入不会自己清掉，每次打开重新来过。
    LaunchedEffect(visible) {
        if (visible) {
            input = ""
            rememberPwd = true
        }
    }

    LaunchedEffect(input) {
        if (input.length == PASSWORD_LENGTH) {
            val password = input
            delay(180)
            store.submitOperationPassword(password, rememberPwd)
        }
    }

    GlassBottomSheet(
        visible = visible,
        // 侧滑关掉要把待发指令一起丢弃，否则下次输密码会发出上一条。
        onDismissRequest = { store.cancelChallenge() },
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 16.dp),
        ) {
            Text(
                text = "输入操作密码",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "用于验证「$prompt」操作",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )

            // 4 位圆点
            Row(
                horizontalArrangement = Arrangement.spacedBy(18.dp),
                modifier = Modifier.padding(vertical = 22.dp),
            ) {
                repeat(PASSWORD_LENGTH) { index ->
                    val filled = index < input.length
                    Box(
                        modifier = Modifier
                            .size(14.dp)
                            .clip(CircleShape)
                            .background(
                                if (filled) MaterialTheme.colorScheme.onSurface
                                else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.18f)
                            ),
                    )
                }
            }

            // 数字九宫格:1-9 / 空 / 0 / 退格
            val keyShape = RoundedCornerShape(18.dp)
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                (0 until 3).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        (1..3).forEach { col ->
                            val digit = row * 3 + col
                            PasswordKey(
                                shape = keyShape,
                                modifier = Modifier.weight(1f),
                                onClick = { if (input.length < PASSWORD_LENGTH) input += digit },
                            ) {
                                Text("$digit", fontSize = 22.sp, fontWeight = FontWeight.Medium)
                            }
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(modifier = Modifier.weight(1f))
                    PasswordKey(
                        shape = keyShape,
                        modifier = Modifier.weight(1f),
                        onClick = { if (input.length < PASSWORD_LENGTH) input += "0" },
                    ) {
                        Text("0", fontSize = 22.sp, fontWeight = FontWeight.Medium)
                    }
                    PasswordKey(
                        shape = keyShape,
                        modifier = Modifier.weight(1f),
                        onClick = { input = input.dropLast(1) },
                    ) {
                        Icon(
                            Icons.AutoMirrored.Outlined.Backspace,
                            contentDescription = "退格",
                            modifier = Modifier.size(22.dp),
                        )
                    }
                }
            }

            // 记住密码开关。文案跟着这台机器实际有的那种生物识别走，
            // 没有任何可用的识别方式时就只说「在本机记住」，别承诺一个用不了的指纹。
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 18.dp),
            ) {
                val kind = store.biometricKind
                Text(
                    text = if (kind == BiometricGate.Kind.None) {
                        "在本机记住操作密码"
                    } else {
                        "记住密码，之后用${kind.label}验证"
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f),
                )
                LiquidSwitch(checked = rememberPwd, onCheckedChange = { rememberPwd = it })
            }

            LiquidTextButton(
                text = "取消",
                onClick = { store.cancelChallenge() },
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

/// 零跑的操作密码是 4 位。输满即发，不用再点确认。
private const val PASSWORD_LENGTH = 4

@Composable
private fun PasswordKey(
    shape: androidx.compose.ui.graphics.Shape,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(54.dp)
            .pressable(onClick = onClick, shape = shape)
            .sheetTile(shape),
    ) {
        content()
    }
}
