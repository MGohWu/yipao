package org.yipao.app.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// 对照 leapauto 第三轮补的三件事：快速除味、首页天窗 / 遮阳帘徽章用到的读数、锁车后顺带检查。
/// 对齐 iOS `LeapautoGapRound3Tests`。
class LeapautoGapRound3Test {

    private val base = mapOf("1204" to "80", "1318" to "1000", "sts" to "1")

    private fun with(extra: Map<String, String>): VehicleState {
        val pairs = base + extra
        return VehicleState(signalMap = pairs, schema = SignalSchema.detect(pairs))
    }

    /// 四扇窗、四扇门、尾门、前备箱全关的底子（数字口径）。
    private val allClosed = mapOf(
        "1693" to "0", "1694" to "0", "1695" to "0", "1696" to "0",
        "644" to "0", "645" to "0", "865" to "0", "866" to "0",
        "1277" to "0", "1278" to "0", "1279" to "0", "1280" to "0",
        "1281" to "0", "1282" to "0",
    )

    private fun closed(extra: Map<String, String> = emptyMap()) = with(allClosed + extra)

    // MARK: - 快速除味

    @Test
    fun deodorizePayload() {
        val command = LeapCommand.deodorize()
        assertEquals("170", command.cmdid)
        assertEquals("快速除味", command.label)
        val state = JSONObject(command.stateJSON)
        assertEquals("manual", state.get("operate"))
        assertEquals("nohotcold", state.get("mode"))
        assertEquals("out", state.get("circle"))
        assertEquals("7", state.get("windlevel"))
        assertEquals("0", state.get("wshld"))
        assertEquals("all", state.get("position"))
    }

    /// 判据不比温度——车保留原设定温度时不能误报未确认。
    @Test
    fun deodorizeIgnoresTemperature() {
        val expectation = LeapCommand.deodorize().expectation
        assertEquals(ExpectationKind.Climate, expectation.kind)
        assertTrue(expectation.climateOn)
        assertNull(expectation.temperature)
        assertEquals(7, expectation.fanLevel)
        assertEquals(ClimateMode.Vent, expectation.mode)
        // 车开着通风 7 档、设定温度还是 20：照样算确认
        assertTrue(expectation.isSatisfied(with(mapOf("1938" to "1", "1941" to "7", "3713" to "4", "2183" to "20"))))
    }

    // MARK: - 锁车后顺带检查

    @Test
    fun nothingOpen() {
        assertTrue(closed().openItemsAfterLock.isEmpty())
    }

    /// 车况读不到车窗车门时不提醒——不知道不等于开着。
    @Test
    fun unreadableIsNotOpen() {
        assertTrue(with(emptyMap()).openItemsAfterLock.isEmpty())
    }

    @Test
    fun singleWindowNamed() {
        assertEquals(listOf("右后车窗"), closed(mapOf("1696" to "2")).openItemsAfterLock)
        // 状态位说关、开度说开（T03 那次的真实情形）也要报
        assertEquals(listOf("右后车窗"), closed(mapOf("866" to "30")).openItemsAfterLock)
        assertEquals(listOf("主驾车窗", "副驾车窗"), closed(mapOf("1693" to "2", "1694" to "2")).openItemsAfterLock)
    }

    @Test
    fun allWindowsMerged() {
        val open = closed(mapOf("1693" to "2", "1694" to "2", "1695" to "2", "1696" to "2"))
        assertEquals(listOf("车窗"), open.openItemsAfterLock)
    }

    @Test
    fun otherItems() {
        assertEquals(listOf("天窗", "尾门"), closed(mapOf("1718" to "10", "1281" to "1")).openItemsAfterLock)
        assertEquals(listOf("前备箱"), closed(mapOf("1282" to "1")).openItemsAfterLock)
        assertEquals(listOf("车门"), closed(mapOf("1277" to "1")).openItemsAfterLock)
        // 遮阳帘开着不是隐患
        assertTrue(closed(mapOf("1724" to "100")).openItemsAfterLock.isEmpty())
        // 天窗占位值当读不到
        assertTrue(closed(mapOf("1718" to "150")).openItemsAfterLock.isEmpty())
    }

    /// 新加的这批信号全来自数字口径，legacy（S01 / T03）一条都不映射。
    @Test
    fun legacySchemaHasNoNewSignals() {
        val added = listOf(
            VehicleSignal.WindshieldDefrost, VehicleSignal.RapidCooling, VehicleSignal.RapidHeating,
            VehicleSignal.DriverSeatHeating, VehicleSignal.DriverSeatVentilation,
            VehicleSignal.PassengerSeatHeating, VehicleSignal.PassengerSeatVentilation,
            VehicleSignal.LeftRearSeatHeating, VehicleSignal.LeftRearSeatVentilation,
            VehicleSignal.RightRearSeatHeating, VehicleSignal.RightRearSeatVentilation,
            VehicleSignal.SteeringWheelHeating, VehicleSignal.SteeringWheelHeatMinutes,
            VehicleSignal.LeftMirrorHeating, VehicleSignal.RightMirrorHeating, VehicleSignal.RearWindowHeating,
            VehicleSignal.FridgeSwitch, VehicleSignal.FridgeMode, VehicleSignal.FridgeTargetTemp,
            VehicleSignal.FridgeStyle, VehicleSignal.FridgeFault, VehicleSignal.FridgeParkSwitch,
            VehicleSignal.FridgeParkDurationHours, VehicleSignal.FridgeParkCycles, VehicleSignal.FridgeParkEndTime,
            VehicleSignal.SunshadeOpening, VehicleSignal.SunroofOpening,
        )
        for (signal in added) {
            assertTrue("$signal 不该映射到 legacy", SignalSchema.legacy.candidates(signal).isEmpty())
            assertTrue("$signal 应有数字口径映射", SignalSchema.numeric.candidates(signal).isNotEmpty())
        }
    }
}
