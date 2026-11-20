package org.yipao.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// 卡片上那几句话的派生规则。对齐 iOS `VehicleSnapshotTests`。
///
/// 这些量只在小组件、磁贴和常驻通知上露面——那三处没有界面能验，改坏了不会有任何
/// 报错，只是卡片上悄悄换了句话（比如替一台没报锁状态的车说「已锁车」）。所以钉在这里。
class VehicleSnapshotTest {

    private val now = 1_700_000_000_000L

    /// 一台安静停着的纯电车。每个用例只改自己关心的那几个字段。
    private val calm = VehicleSnapshot(
        vehicleName = "C11",
        soc = 76,
        gasolinePercent = null,
        rangeKm = 312,
        isLocked = true,
        isDriving = false,
        isCharging = false,
        chargeLimit = null,
        chargeRemainMinutes = null,
        chargePowerKW = null,
        indoorTemp = 26.0,
        climateOn = false,
        windowsClosed = true,
        anyDoorOpen = false,
        trunkOpen = false,
        hasTireWarning = false,
        locationName = null,
        latitude = null,
        longitude = null,
        updatedAt = now,
        reportedAt = now,
    )

    private fun rangeState() = VehicleState(
        schema = SignalSchema.numeric,
        isExtendRange = true,
        signalMap = mapOf("100003" to "75", "2188" to "254", "3262" to "1",
            "3257" to "150", "3256" to "433", "3260" to "114", "3259" to "365"),
    )

    private fun rangeSnapshot(state: VehicleState) = VehicleSnapshot.make(state, "测试车", null, now)

    @Test
    fun `中卡忽略滞留254并跟随工况和分项续航变化`() {
        val state = rangeState()
        val first = rangeSnapshot(state)
        assertEquals(254, first.rangeKm)
        assertEquals("电 114 · 油 365 km", first.mediumRangeText)
        val decoded = VehicleSnapshot.fromJson(first.toJson())!!
        assertEquals(true, decoded.isExtendRange)
        assertEquals(first.mediumRangeText, decoded.mediumRangeText)
        assertEquals("电 110 · 油 365 km", rangeSnapshot(state.copy(
            signalMap = state.signalMap + ("3260" to "110"))).mediumRangeText)
        assertEquals("电 150 · 油 433 km", rangeSnapshot(state.copy(
            signalMap = state.signalMap + ("3262" to "0"))).mediumRangeText)
    }

    @Test
    fun `增程缺续航不回退旧值且零续航有效`() {
        val state = rangeState()
        assertEquals("油 365 km", rangeSnapshot(state.copy(signalMap = state.signalMap - "3260")).mediumRangeText)
        assertEquals("油 0 km", rangeSnapshot(state.copy(
            signalMap = state.signalMap - "3260" + ("3259" to "0"))).mediumRangeText)
        val missing = rangeSnapshot(state.copy(signalMap = state.signalMap - "3260" - "3259"))
        assertTrue(missing.hasFuel)
        assertNull(missing.mediumRangeText)
    }

    @Test
    fun `纯电保持单项续航且旧快照兼容分项`() {
        assertEquals("254 km", rangeSnapshot(rangeState().copy(isExtendRange = false)).mediumRangeText)
        val json = org.json.JSONObject(rangeSnapshot(rangeState()).toJson()).apply { remove("isExtendRange") }
        assertEquals("电 114 · 油 365 km", VehicleSnapshot.fromJson(json.toString())!!.mediumRangeText)
    }

    // MARK: - 时效

    @Test
    fun `车端没报采集时刻时动词改口成读取`() {
        // 「更新于 3 分钟前」是在替车担保车况就是那时候的；没有 collectTime 时
        // 我们只能保证 3 分钟前问过服务端，措辞必须弱下来。
        val reported = calm.copy(reportedAt = now - 180_000)
        val unknown = calm.copy(updatedAt = now - 180_000, reportedAt = null)

        assertEquals("更新于 3 分钟前", reported.freshnessText(now))
        assertEquals("读取于 3 分钟前", unknown.freshnessText(now))
    }

    @Test
    fun `时效分档到分钟 小时 天`() {
        assertEquals("刚刚更新", calm.copy(reportedAt = now - 59_000).freshnessText(now))
        assertEquals("更新于 59 分钟前", calm.copy(reportedAt = now - 3_599_000).freshnessText(now))
        assertEquals("更新于 2 小时前", calm.copy(reportedAt = now - 7_200_000).freshnessText(now))
        assertEquals("更新于 3 天前", calm.copy(reportedAt = now - 259_200_000).freshnessText(now))
    }

    @Test
    fun `车端时刻跑到未来时不出现负数`() {
        // 手机和车端时钟差几十秒是常事，「更新于 -1 分钟前」这种话不能出现在卡片上。
        assertEquals("刚刚更新", calm.copy(reportedAt = now + 90_000).freshnessText(now))
    }

    @Test
    fun `休眠车反复拉到同一份旧数据仍然算过期`() {
        // 这是 isStale 按 reportedAt 而不是 updatedAt 算的全部理由：车睡着不上报时，
        // 本机每次都拉得到东西，按拉取时间算的话这份车况永远不会过期。
        val sleeping = calm.copy(updatedAt = now, reportedAt = now - 7_200_000)
        assertTrue(sleeping.isStale(now))
        assertFalse(calm.copy(reportedAt = now - 1_799_000).isStale(now))
    }

    @Test
    fun `车端时刻读不到时退回本机拉取时间判过期`() {
        assertTrue(calm.copy(updatedAt = now - 1_801_000, reportedAt = null).isStale(now))
        assertFalse(calm.copy(updatedAt = now - 60_000, reportedAt = null).isStale(now))
    }

    // MARK: - 那一句话

    @Test
    fun `headline 按危险程度排序`() {
        val everything = calm.copy(
            anyDoorOpen = true,
            trunkOpen = true,
            hasTireWarning = true,
            windowsClosed = false,
            isCharging = true,
            chargeLimit = 90,
            climateOn = true,
            locationName = "杭州市上城区",
        )
        assertEquals("有车门未关闭", everything.headline)
        assertEquals("尾门未关闭", everything.copy(anyDoorOpen = false).headline)
        assertEquals("胎压异常", everything.copy(anyDoorOpen = false, trunkOpen = false).headline)
        assertEquals(
            "车窗未关闭",
            everything.copy(anyDoorOpen = false, trunkOpen = false, hasTireWarning = false).headline,
        )
    }

    @Test
    fun `尾门不在 anyDoorOpen 里 要单独说`() {
        // anyDoorOpen 只看四个车门。尾门当初漏了这一条，卡片上就永远不提尾门。
        assertEquals("尾门未关闭", calm.copy(trunkOpen = true).headline)
    }

    @Test
    fun `充电中带上限 没上限就只说充电中`() {
        val charging = calm.copy(isCharging = true, chargeLimit = 90)
        assertEquals("充电中 · 上限 90%", charging.headline)
        assertEquals("充电中", charging.copy(chargeLimit = null).headline)
    }

    @Test
    fun `没别的可说时用地名 再没有才说锁态`() {
        assertEquals("杭州市上城区", calm.copy(locationName = "杭州市上城区").headline)
        assertEquals("已锁车", calm.headline)
        assertEquals("已解锁", calm.copy(isLocked = false).headline)
        // 锁状态读不到时 headline 只能落到这句，但它是兜底，不是断言——
        // 真正要显示锁态的地方看 lockText。
        assertEquals("已锁车", calm.copy(isLocked = null).headline)
    }

    @Test
    fun `锁状态读不到就说状态未知 不替车说已锁车`() {
        // iOS 上这条判据分叉过一次：状态卡按 `isLocked != false` 画了个绿色闭锁，
        // 同一时刻锁车卡显示的是「状态未知」。同一台车两个说法。
        assertEquals("已锁车", calm.lockText)
        assertEquals("已解锁", calm.copy(isLocked = false).lockText)
        assertEquals("状态未知", calm.copy(isLocked = null).lockText)
    }

    @Test
    fun `needsAttention 覆盖五种要提醒的状态`() {
        assertFalse(calm.needsAttention)
        assertTrue(calm.copy(anyDoorOpen = true).needsAttention)
        assertTrue(calm.copy(trunkOpen = true).needsAttention)
        assertTrue(calm.copy(hasTireWarning = true).needsAttention)
        assertTrue(calm.copy(isLocked = false).needsAttention)
        assertTrue(calm.copy(windowsClosed = false).needsAttention)
        // 三态字段的 null 一律按「不亮」处理：不亮只是中性外观，
        // 不像文字那样会替车编出一个「已关」。
        assertFalse(calm.copy(trunkOpen = null, windowsClosed = null, isLocked = null).needsAttention)
    }

    // MARK: - 充电那一行

    @Test
    fun `充电指标两个都读不到时整行不出现`() {
        // 摆一行「剩余时间 -- 功率 --」等于用两个占位符告诉用户「我不知道」。
        assertFalse(calm.hasChargeMetrics)
        assertTrue(calm.copy(chargePowerKW = 6.6).hasChargeMetrics)
        assertTrue(calm.copy(chargeRemainMinutes = 30).hasChargeMetrics)
    }

    @Test
    fun `剩余时间按分 小时 小时加分三种说法`() {
        assertEquals("还需 45 分", calm.copy(chargeRemainMinutes = 45).chargeRemainingText)
        assertEquals("还需 2 小时", calm.copy(chargeRemainMinutes = 120).chargeRemainingText)
        assertEquals("还需 1 小时 5 分", calm.copy(chargeRemainMinutes = 65).chargeRemainingText)
        // 0 和负数是「没在充」的脏值，不是「还需 0 分」。
        assertNull(calm.copy(chargeRemainMinutes = 0).chargeRemainingText)
        assertNull(calm.copy(chargeRemainMinutes = -1).chargeRemainingText)
    }

    @Test
    fun `充电功率保留一位 脏值不显示`() {
        assertEquals("6.6 kW", calm.copy(chargePowerKW = 6.6).chargePowerText)
        // 小数点必须是点：跟着系统区域走的话，某些地区会渲染成「6,6 kW」。
        assertEquals("0.0 kW", calm.copy(chargePowerKW = 0.0).chargePowerText)
        assertNull(calm.copy(chargePowerKW = -1.0).chargePowerText)
        assertNull(calm.copy(chargePowerKW = Double.NaN).chargePowerText)
        assertNull(calm.copy(chargePowerKW = Double.POSITIVE_INFINITY).chargePowerText)
    }

    // MARK: - 落盘

    @Test
    fun `JSON 往返后三态字段仍然是三态`() {
        // 这是快照落盘最容易坏的地方：null 写成 false 的话，一台没报锁状态的车
        // 重启进程之后会在卡片上变成「已解锁」。
        val unknown = calm.copy(
            soc = null,
            rangeKm = null,
            isLocked = null,
            trunkOpen = null,
            windowsClosed = null,
            indoorTemp = null,
            locationName = null,
            reportedAt = null,
        )
        val back = VehicleSnapshot.fromJson(unknown.toJson())!!
        assertNull(back.soc)
        assertNull(back.rangeKm)
        assertNull(back.isLocked)
        assertNull(back.trunkOpen)
        assertNull(back.windowsClosed)
        assertNull(back.indoorTemp)
        assertNull(back.locationName)
        assertNull(back.reportedAt)
        assertEquals("状态未知", back.lockText)
    }

    @Test
    fun `JSON 往返保住所有有值的字段`() {
        val full = calm.copy(
            gasolinePercent = 42,
            isCharging = true,
            chargeLimit = 90,
            chargeRemainMinutes = 65,
            chargePowerKW = 6.6,
            climateOn = true,
            locationName = "杭州市上城区",
            latitude = 30.24704,
            longitude = 120.21201,
        )
        val back = VehicleSnapshot.fromJson(full.toJson())!!
        assertEquals(full, back)
    }

    @Test
    fun `读到坏数据返回 null 而不是抛`() {
        // 卡片是在系统进程调度下画的，这里抛出去等于小组件直接白屏。
        assertNull(VehicleSnapshot.fromJson(""))
        assertNull(VehicleSnapshot.fromJson("{"))
        assertNull(VehicleSnapshot.fromJson("[1,2,3]"))
    }
}
