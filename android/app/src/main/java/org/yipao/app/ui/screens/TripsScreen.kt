package org.yipao.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.SubPageScaffold
import org.yipao.app.ui.theme.LeapColors

/// 行程页，对齐 iOS `TripsView`：零跑官方按天统计的里程能耗（[MileageStatsContent]）。
@Composable
fun TripsScreen(onBack: () -> Unit) {
    PageTint(LeapColors.accent)
    SubPageScaffold(title = "行程", onBack = onBack, scrollable = false) {
        Column(
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
        ) {
            MileageStatsContent()
            Spacer(modifier = Modifier.navigationBarsPadding().height(12.dp))
        }
    }
}
