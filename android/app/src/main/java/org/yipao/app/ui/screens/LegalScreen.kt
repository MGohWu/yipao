package org.yipao.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.SubPageScaffold

/// 用户协议 / 隐私政策页。源文档与 iOS 同一份 markdown（assets/legal/），
/// 极简渲染：一级/二级标题、圆点列表、表格行合并成一行、正文，行内加粗。
@Composable
fun LegalScreen(onBack: () -> Unit, privacy: Boolean) {
    val context = LocalContext.current
    val fileName = if (privacy) "legal/privacy-policy.md" else "legal/user-agreement.md"
    val lines = remember(fileName) {
        context.assets.open(fileName).bufferedReader().readLines()
    }

    SubPageScaffold(title = if (privacy) "隐私政策" else "用户协议", onBack = onBack) {
        GlassCard(modifier = Modifier.fillMaxWidth()) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.padding(18.dp),
            ) {
                lines.forEach { raw ->
                    val line = raw.trim()
                    when {
                        line.isEmpty() -> {}
                        line.startsWith("## ") -> Text(
                            text = line.removePrefix("## "),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(top = 8.dp),
                        )
                        line.startsWith("# ") -> Text(
                            text = line.removePrefix("# "),
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.SemiBold,
                        )
                        line.startsWith("|") -> {
                            // 表格行:分隔行丢弃,数据行合并成「a · b · c」。
                            if (!line.contains("---")) {
                                val cells = line.trim('|').split("|").map { it.trim() }.filter { it.isNotEmpty() }
                                Text(
                                    text = inlineBold(cells.joinToString(" · ")),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        line.startsWith("- ") -> Row(modifier = Modifier.fillMaxWidth()) {
                            Text(
                                text = "•  ",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Text(
                                text = inlineBold(line.removePrefix("- ")),
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.weight(1f),
                            )
                        }
                        else -> Text(
                            text = inlineBold(line),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            }
        }
        Spacer(modifier = Modifier.height(2.dp))
    }
}

/// 行内 **加粗** 解析。只处理成对的双星号，别的 markdown 语法这份文档没用到。
private fun inlineBold(text: String): AnnotatedString = buildAnnotatedString {
    val parts = text.split("**")
    parts.forEachIndexed { index, part ->
        if (index % 2 == 1 && parts.size > index) {
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(part) }
        } else {
            append(part)
        }
    }
}
