package org.yipao.app.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// 老链路连败到什么程度才该提示重新登录。
///
/// 阈值判据是纯函数，正是为了能在这里逐条钉住：控车偶发失败（信号差、车在休眠）
/// 绝不能因为连着按了三下就把人赶去登录页。
class OldAuthEscalationTest {

    @Test
    fun `次数不够时只当作可重试`() {
        assertFalse(LeapClient.shouldEscalateOldAuthFailure(streak = 1, spannedSeconds = 3600))
        assertFalse(LeapClient.shouldEscalateOldAuthFailure(streak = 2, spannedSeconds = 3600))
    }

    @Test
    fun `连按三下挤在几秒内不算`() {
        // 用户连点三次，全在同一分钟里——这更像车没醒，不是授权没了。
        assertFalse(LeapClient.shouldEscalateOldAuthFailure(streak = 3, spannedSeconds = 8))
        assertFalse(LeapClient.shouldEscalateOldAuthFailure(streak = 9, spannedSeconds = 59))
    }

    @Test
    fun `次数够且跨过冷却窗口才提示重登`() {
        assertTrue(LeapClient.shouldEscalateOldAuthFailure(streak = 3, spannedSeconds = 300))
        assertTrue(LeapClient.shouldEscalateOldAuthFailure(streak = 4, spannedSeconds = 900))
    }
}
