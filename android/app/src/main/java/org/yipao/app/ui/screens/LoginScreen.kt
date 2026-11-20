package org.yipao.app.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Sms
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.yipao.app.app.ReviewDemo
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.LiquidButton
import org.yipao.app.ui.components.LiquidCheck
import org.yipao.app.ui.components.LiquidGlassButton
import org.yipao.app.ui.components.LiquidTextButton
import org.yipao.app.ui.components.LiquidTextField
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.theme.LeapColors

/// 登录页:问候语 → 手机号 → 验证码 → 获取验证码 → 协议勾选 → 登录。对齐 iOS LoginView。
///
/// 协议没勾不禁用登录按钮,而是提示并把勾选框滚到眼前——禁用的按钮不会告诉用户
/// 「差在哪」,用户只能自己找。
@Composable
fun LoginScreen() {
    val store = LocalStore.current
    val scope = rememberCoroutineScope()
    var phone by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var agreed by rememberSaveable { mutableStateOf(false) }
    // null = 不看协议,true = 隐私政策,false = 用户协议。
    var legal by rememberSaveable { mutableStateOf<Boolean?>(null) }
    var nudge by remember { mutableIntStateOf(0) }
    var working by remember { mutableStateOf(false) }
    // 重发倒计时。转屏要保住，否则转一下就能立刻再点一次「获取验证码」。
    var countdown by rememberSaveable { mutableIntStateOf(0) }
    val agreementRequester = remember { BringIntoViewRequester() }

    // 登录页背景走绿光晕，同 iOS `LeapBackground(tint: accent)`。
    PageTint(LeapColors.accent)

    val phoneValid = phone.length == 11 && phone.all { it.isDigit() }
    val codeValid = code.length == 6 && code.all { it.isDigit() }
    val requireAgreement = {
        if (agreed) {
            true
        } else {
            store.show(
                text = "请先同意协议",
                detail = "请阅读并勾选同意《用户协议》和《隐私政策》",
                isError = true,
            )
            nudge++
            scope.launch { agreementRequester.bringIntoView() }
            false
        }
    }

    LaunchedEffect(countdown) {
        if (countdown <= 0) return@LaunchedEffect
        delay(1000)
        countdown -= 1
    }

    // 勾选框的抖动。左右各两下、每下 60ms,幅度 5dp——再大就成了「出错了」而不是「看这里」。
    val shake = remember { Animatable(0f) }
    LaunchedEffect(nudge) {
        if (nudge == 0) return@LaunchedEffect
        shake.snapTo(0f)
        repeat(2) {
            shake.animateTo(1f, tween(durationMillis = 60))
            shake.animateTo(-1f, tween(durationMillis = 60))
        }
        shake.animateTo(0f, tween(durationMillis = 60))
    }

    // 登录页不在 NavHost 里(它是登录墙,在导航之外),协议正文只能就地盖上来。
    val showing = legal
    if (showing != null) {
        // 登录页在导航之外，系统返回键没人接——不自己接的话按一下直接退出整个 App。
        BackHandler { legal = null }
        LegalScreen(onBack = { legal = null }, privacy = showing)
        return
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 28.dp),
    ) {
        // 顶部留白。iOS 是安全区之后再 90pt，安卓的状态栏比 iOS 的刘海区矮一大截，
        // 照抄 90 会让整块问候语顶在屏幕上沿，得自己补回这个差。
        Spacer(modifier = Modifier.height(125.dp))

        // 问候区
        Text(
            text = "壹 跑",
            style = MaterialTheme.typography.labelMedium,
            letterSpacing = 6.sp,
            color = MaterialTheme.colorScheme.outline,
        )
        Text(
            text = "你好，\n欢迎回来",
            style = MaterialTheme.typography.headlineMedium,
            fontSize = 32.sp,
            lineHeight = 40.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(top = 10.dp),
        )
        Text(
            text = "使用手机验证码登录",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 10.dp),
        )

        Spacer(modifier = Modifier.height(34.dp))

        LiquidTextField(
            value = phone,
            onValueChange = { new -> phone = new.filter { it.isDigit() }.take(11) },
            placeholder = "手机号",
            prefix = "+86",
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(modifier = Modifier.height(12.dp))
        LiquidTextField(
            value = code,
            onValueChange = { new -> code = new.filter { it.isDigit() }.take(6) },
            placeholder = "6 位验证码",
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            leading = {
                Icon(
                    Icons.Rounded.Sms,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            },
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(modifier = Modifier.height(12.dp))
        // 「获取验证码」占一整行。塞在输入框右边的话,它得跟着输入框的高度走,
        // 又不能有自己的底,最后只是一行彩色小字,点击区小得像个误触。
        LiquidGlassButton(
            text = if (countdown > 0) "重新发送 (${countdown}s)" else "获取验证码",
            onClick = {
                if (!requireAgreement()) return@LiquidGlassButton
                scope.launch {
                    working = true
                    if (store.sendSMS(phone)) countdown = 60
                    working = false
                }
            },
            enabled = phoneValid && countdown == 0 && !working,
            height = 46.dp,
            modifier = Modifier.fillMaxWidth(),
        )

        // 协议紧跟表单，键盘弹起时仍可滚到眼前。
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .bringIntoViewRequester(agreementRequester)
                .pressable(
                    onClick = { agreed = !agreed },
                    feedback = PressFeedback.Fade,
                    role = Role.Checkbox,
                )
                .padding(top = 14.dp),
            horizontalArrangement = Arrangement.Center,
        ) {
            LiquidCheck(
                checked = agreed,
                modifier = Modifier
                    .graphicsLayer { translationX = shake.value * 5.dp.toPx() }
                    .padding(end = 8.dp),
            )
            Text(
                text = agreementText(onOpen = { legal = it }),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        Spacer(modifier = Modifier.weight(1f))
        Spacer(modifier = Modifier.height(34.dp))

        // 演示模式入口:次要路径,一行小字。点了直接填好演示账号。
        LiquidTextButton(
            text = "没有账号？试试演示模式",
            onClick = {
                phone = ReviewDemo.PHONE
                code = ReviewDemo.CODE
            },
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textStyle = MaterialTheme.typography.labelMedium,
            modifier = Modifier
                .align(Alignment.CenterHorizontally)
                .padding(bottom = 14.dp),
        )

        LiquidButton(
            text = if (working) "登录中…" else "登录",
            onClick = {
                if (!requireAgreement()) return@LiquidButton
                scope.launch {
                    working = true
                    store.login(phone, code)
                    working = false
                }
            },
            enabled = phoneValid && codeValid && !working,
            height = 54.dp,
            textStyle = MaterialTheme.typography.titleMedium,
            modifier = Modifier.fillMaxWidth(),
        )

        Text(
            text = "手机号加密后发送，登录状态只保存在本机。",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.outline,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 10.dp, bottom = 24.dp),
        )
    }
}

/// 协议行的文案。两个书名号是真链接,不是一句「点整行代表你都同意了」。
/// [onOpen] 的参数是「要不要开隐私政策」,false 就是用户协议。
@Composable
private fun agreementText(onOpen: (Boolean) -> Unit) = buildAnnotatedString {
    val accent = LeapColors.accent
    val linkStyle = TextLinkStyles(style = SpanStyle(color = accent))
    fun link(tag: String) = LinkAnnotation.Clickable(
        tag = tag,
        styles = linkStyle,
        linkInteractionListener = { onOpen(tag == "privacy") },
    )
    append("我已阅读并同意")
    withLink(link("user-agreement")) { append("《用户协议》") }
    append("和")
    withLink(link("privacy")) { append("《隐私政策》") }
}
