package org.yipao.app.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// 舒适座舱（座椅加热/通风、方向盘加热、后视镜加热）与车载冰箱。对齐 iOS `CabinComfortTests`。
///
/// 下面那份 `c16` 取自车主本人 C16 的真实车况抓包（采样时座舱功能全关），八个座椅信号、
/// 方向盘的 1816/1624、后视镜的 49/50/1946 逐个在场，而九个冰箱信号一个都没有。
class CabinComfortTest {

    /// C16 signalMap 的节选（经纬度已替换为示例值，其余字段结构照实车）。
    private val c16: Map<String, String> = mapOf(
        "1" to "1786972478598",
        "100003" to "90.6",
        "1204" to "91",
        "2100" to "0", "2101" to "0",
        "2118" to "0", "2119" to "0",
        "1879" to "0", "3727" to "0",
        "1880" to "0", "3728" to "0",
        // 方向盘：加热关着（1816=0），但剩余分钟（1624）是 15——这就是那个坑
        "1816" to "0", "1624" to "15",
        "49" to "0", "50" to "0", "1946" to "0",
        "1938" to "0", "1943" to "1", "2669" to "0", "2681" to "0", "3713" to "1",
        // 经纬度三组同时在场
        "2" to "120.155527", "3" to "30.276109",
        "2190" to "120.150028", "2191" to "30.277968",
        "3724" to "120.150009", "3725" to "30.27797",
        "sts" to "1786972478119",
    )

    /// C16 实测 abilities：含 21/42/43/59，**不含 76**。
    private val c16Abilities = listOf(
        "1", "2", "3", "5", "6", "7", "10", "11", "12", "13", "14", "15", "19", "20", "21",
        "22", "23", "24", "29", "30", "31", "32", "34", "35", "38", "39", "41", "42", "43", "45", "46", "47", "48", "49",
        "50", "51", "52", "53", "55", "56", "57", "58", "59", "60", "61", "65", "66", "67", "68", "71", "72", "73", "74",
        "75", "82", "87", "88", "89",
    )

    private fun state(pairs: Map<String, String>) =
        VehicleState(signalMap = pairs, schema = SignalSchema.detect(pairs))

    private fun json(raw: String) = JSONObject(raw)

    // MARK: - 信号映射

    @Test
    fun readsAllSeatSignals() {
        val s = state(c16 + mapOf("2100" to "3", "2119" to "2", "1879" to "1", "3728" to "3"))
        assertEquals(3, s.seatLevel(SeatPosition.Driver, SeatComfortChannel.Heating))
        assertEquals(2, s.seatLevel(SeatPosition.Passenger, SeatComfortChannel.Ventilation))
        assertEquals(1, s.seatLevel(SeatPosition.LeftRear, SeatComfortChannel.Heating))
        assertEquals(3, s.seatLevel(SeatPosition.RightRear, SeatComfortChannel.Ventilation))
        // 没动过的仍是 0，不是 null——车报了 0 和车没报是两件事
        assertEquals(0, s.seatLevel(SeatPosition.Driver, SeatComfortChannel.Ventilation))
        assertTrue(s.hasSeatComfort)
        assertTrue(s.hasRearSeatComfort)
        assertTrue(s.hasCabinComfort)
    }

    @Test
    fun missingSeatSignalIsNull() {
        val s = state(c16 - setOf("1879", "3727", "1880", "3728"))
        assertNull(s.seatLevel(SeatPosition.LeftRear, SeatComfortChannel.Heating))
        assertNull(s.seatLevel(SeatPosition.RightRear, SeatComfortChannel.Ventilation))
        assertFalse(s.hasRearSeatComfort)
        assertEquals(0, s.seatLevel(SeatPosition.Driver, SeatComfortChannel.Heating))
        assertEquals(SeatPosition.front, s.seats(SeatComfortChannel.Heating))
    }

    @Test
    fun legacySchemaHasNoCabinSignals() {
        val s = state(mapOf("soc" to "76", "acSwitch" to "false", "acCircleMode" to "true"))
        assertEquals("legacy", s.schema.id)
        assertFalse(s.hasCabinComfort)
        assertNull(s.steeringWheelHeatLevel)
        assertNull(s.mirrorHeatingOn)
        assertNull(s.fridgeState)
    }

    @Test
    fun clampsSeatLevel() {
        val s = state(c16 + mapOf("2100" to "9", "2101" to "-2"))
        assertEquals(3, s.seatLevel(SeatPosition.Driver, SeatComfortChannel.Heating))
        assertEquals(0, s.seatLevel(SeatPosition.Driver, SeatComfortChannel.Ventilation))
    }

    // MARK: - 方向盘那个坑

    @Test
    fun steeringMinutesHiddenWhenOff() {
        val s = state(c16)
        assertEquals(0, s.steeringWheelHeatLevel)
        assertNull(s.steeringWheelHeatMinutes)
    }

    @Test
    fun steeringMinutesShownWhenOn() {
        val s = state(c16 + ("1816" to "2"))
        assertEquals(2, s.steeringWheelHeatLevel)
        assertEquals(15, s.steeringWheelHeatMinutes)
    }

    @Test
    fun steeringLevelClampsToTwo() {
        assertEquals(2, state(c16 + ("1816" to "3")).steeringWheelHeatLevel)
    }

    // MARK: - 后视镜

    @Test
    fun mirrorHeatingReadsBothSides() {
        val one = state(c16 + ("49" to "1"))
        assertEquals(true, one.mirrorHeatingOn)
        assertTrue(one.mirrorHeatingMismatched)
        val both = state(c16 + mapOf("49" to "1", "50" to "1"))
        assertEquals(true, both.mirrorHeatingOn)
        assertFalse(both.mirrorHeatingMismatched)
    }

    @Test
    fun mirrorHeatingMissingIsNull() {
        assertNull(state(c16 - setOf("49", "50")).mirrorHeatingOn)
    }

    // MARK: - 冰箱

    @Test
    fun fridgeAbsentOnOwnerCar() {
        assertNull(state(c16).fridgeState)
        assertNull(state(c16 + ("11260" to "0")).fridgeState)
    }

    @Test
    fun fridgeStateParses() {
        val fridge = state(
            c16 + mapOf(
                "10709" to "1", "10708" to "1", "10707" to "50", "10711" to "1", "10712" to "0",
                "11190" to "1", "11189" to "3", "11260" to "1786980000",
            ),
        ).fridgeState!!
        assertTrue(fridge.enabled)
        assertEquals(FridgeMode.Hot, fridge.mode)
        assertEquals(FridgeStyle.Turbo, fridge.style)
        assertFalse(fridge.hasFault)
        assertTrue(fridge.parkEnabled)
        assertEquals(3, fridge.parkHours)
        assertEquals(1786980000_000L, fridge.parkEndsAt)
    }

    @Test
    fun fridgeFaultSurfaces() {
        val fridge = state(c16 + mapOf("10709" to "1", "10712" to "3")).fridgeState!!
        assertTrue(fridge.hasFault)
        assertEquals(3, fridge.fault)
    }

    @Test
    fun fridgeParkEndZeroIsNull() {
        assertNull(state(c16 + mapOf("10709" to "1", "11260" to "0")).fridgeState?.parkEndsAt)
    }

    // MARK: - 指令

    @Test
    fun seatCommands() {
        val heat = CabinCommands.seatComfort(SeatPosition.Driver, SeatComfortChannel.Heating, 3)
        assertEquals("301", heat.cmdid)
        assertEquals("left_front", json(heat.stateJSON).get("position"))
        assertEquals("3", json(heat.stateJSON).get("level"))
        assertEquals("主驾加热 3 档", heat.label)

        val vent = CabinCommands.seatComfort(SeatPosition.RightRear, SeatComfortChannel.Ventilation, 0)
        assertEquals("370", vent.cmdid)
        assertEquals("right_rear", json(vent.stateJSON).get("position"))
        assertEquals("0", json(vent.stateJSON).get("level"))
        assertEquals("二排右通风关闭", vent.label)
    }

    @Test
    fun seatPositionWireValues() {
        assertEquals("left_front", SeatPosition.Driver.wireValue)
        assertEquals("right_front", SeatPosition.Passenger.wireValue)
        assertEquals("left_rear", SeatPosition.LeftRear.wireValue)
        assertEquals("right_rear", SeatPosition.RightRear.wireValue)
    }

    /// level 是 JSON 数字不是字符串（按 leapauto 代码走）。真车不认改成字符串时这里会红，提醒同步文档。
    @Test
    fun steeringCommand() {
        val command = CabinCommands.steeringWheelHeating(2)
        assertEquals("320", command.cmdid)
        assertEquals("""{"level":2}""", command.stateJSON)
        assertEquals(2, json(command.stateJSON).get("level"))
        assertEquals("方向盘加热强档", command.label)
    }

    @Test
    fun mirrorCommand() {
        assertEquals("440", CabinCommands.mirrorHeating(true).cmdid)
        assertEquals("2", json(CabinCommands.mirrorHeating(true).stateJSON).get("value"))
        assertEquals("1", json(CabinCommands.mirrorHeating(false).stateJSON).get("value"))
    }

    @Test
    fun fridgeCommandIsFullState() {
        val command = CabinCommands.fridge(FridgeSetting())
        assertEquals("500", command.cmdid)
        val payload = json(command.stateJSON)
        assertEquals(8, payload.length())
        assertEquals(1, payload.get("enable"))
        assertEquals("cold", payload.get("mode"))
        assertEquals(4, payload.get("temp"))
        assertEquals("normal", payload.get("style"))
        assertEquals(0, payload.get("parkEnable"))
        assertEquals(3600, payload.get("duration"))
        assertEquals("1", payload.get("cycles"))
        assertEquals("false", payload.get("value"))
    }

    @Test
    fun fridgeHotModeSendsFixedTemp() {
        var setting = FridgeSetting(temperature = -6).applying(FridgePreset.KeepWarm)
        assertEquals(FridgeMode.Hot, setting.mode)
        assertEquals(50, setting.wireTemperature)
        setting = setting.applying(FridgePreset.Chill)
        assertEquals(4, setting.temperature)

        val frozen = FridgeSetting().applying(FridgePreset.Freeze).applying(FridgePreset.KeepWarm)
            .copy(mode = FridgeMode.Cold)
        assertEquals(-6, frozen.temperature)
    }

    @Test
    fun fridgeDurationFloor() {
        assertEquals(FridgeSetting.MIN_DURATION_SECONDS, FridgeSetting(parkHours = 0).durationSeconds)
        assertEquals(10800, FridgeSetting(parkHours = 3).durationSeconds)
    }

    @Test
    fun fridgePresetMatching() {
        assertEquals(FridgePreset.Chill, FridgePreset.matching(FridgeMode.Cold, 4))
        assertEquals(FridgePreset.Freeze, FridgePreset.matching(FridgeMode.Cold, -6))
        assertEquals(FridgePreset.KeepWarm, FridgePreset.matching(FridgeMode.Hot, 50))
        assertNull(FridgePreset.matching(FridgeMode.Cold, 8))
    }

    @Test
    fun fridgeTempClamp() {
        assertEquals(15, FridgeSetting(temperature = 40).wireTemperature)
        assertEquals(-6, FridgeSetting(temperature = -40).wireTemperature)
    }

    // MARK: - 车况确认

    @Test
    fun seatExpectation() {
        val expectation = ControlExpectation.seatLevel(SeatPosition.Driver, SeatComfortChannel.Heating, 2)
        assertFalse(expectation.isSatisfied(state(c16)))
        assertTrue(expectation.isSatisfied(state(c16 + ("2100" to "2"))))
        assertFalse(expectation.isSatisfied(state(c16 + ("2100" to "1"))))
        // 读不到这个座位也不算（宁可报「未收到确认」，不凭空判成功）
        assertFalse(expectation.isSatisfied(state(c16 - "2100")))
    }

    @Test
    fun mirrorExpectationAcceptsAnySignal() {
        val expectation = ControlExpectation.mirrorHeating(true)
        assertFalse(expectation.isSatisfied(state(c16)))
        assertTrue(expectation.isSatisfied(state(c16 + ("49" to "1"))))
        assertTrue(expectation.isSatisfied(state(c16 + ("1946" to "1"))))
    }

    @Test
    fun fridgeExpectation() {
        val expectation = ControlExpectation.fridge(FridgeSetting(style = FridgeStyle.Turbo))
        assertFalse(expectation.isSatisfied(state(c16)))
        val ok = c16 + mapOf("10709" to "1", "10708" to "0", "10707" to "4", "10711" to "1")
        assertTrue(expectation.isSatisfied(state(ok)))
        // 目标温度车端没报 → 跳过这一项，不作否决
        assertTrue(expectation.isSatisfied(state(ok - "10707")))
        // 温度报了但对不上 → 不算
        assertFalse(expectation.isSatisfied(state(ok + ("10707" to "9"))))
    }

    @Test
    fun fridgeOffExpectationIgnoresSettings() {
        val expectation = ControlExpectation.fridge(FridgeSetting(enabled = false))
        assertTrue(expectation.isSatisfied(state(c16 + mapOf("10709" to "0", "10708" to "1", "10707" to "50"))))
    }

    // MARK: - 能力码门控

    @Test
    fun abilitiesTranslateCabinCodes() {
        val permission = VehicleUtil.permissionCodes(c16Abilities)
        assertTrue(permission.contains("301"))
        assertTrue(permission.contains("370"))
        assertTrue(permission.contains("440"))
        assertFalse(permission.contains("500"))
        assertTrue(Vehicle.supportsCabinComfort("C16", permission))
        assertFalse(Vehicle.supportsFridge("C16", permission))
    }

    @Test
    fun legacyCarsExcluded() {
        val permission = listOf("301", "370", "440", "500")
        assertFalse(Vehicle.supportsCabinComfort("S01", permission))
        assertFalse(Vehicle.supportsCabinComfort("T03", permission))
        assertFalse(Vehicle.supportsFridge("S01", permission))
        assertFalse(Vehicle.supportsCabinComfort("T03-2023", permission))
    }

    @Test
    fun noCabinCodesNoEntry() {
        assertFalse(Vehicle.supportsCabinComfort("C11", listOf("400", "240")))
    }

    // MARK: - 顺手修掉的三处

    @Test
    fun locationPrefersVerifiedSignals() {
        val s = state(c16)
        assertEquals(120.150009, s.longitude!!, 0.0)
        assertEquals(30.27797, s.latitude!!, 0.0)
        val onlyLegacyPair = state(c16 - setOf("3724", "3725", "2190", "2191"))
        assertEquals(120.155527, onlyLegacyPair.longitude!!, 0.0)
        assertEquals(30.276109, onlyLegacyPair.latitude!!, 0.0)
    }

    @Test
    fun recirculationReadable() {
        assertEquals(true, state(c16).acCircleIn)
        assertEquals(false, state(c16 + ("1943" to "0")).acCircleIn)
    }

    @Test
    fun rapidStatesReadable() {
        val on = state(c16 + mapOf("2669" to "1", "2681" to "0"))
        assertEquals(true, on.rapidCoolingOn)
        assertEquals(false, on.rapidHeatingOn)
    }

    @Test
    fun defrostUsesOutsideAirAndWindshieldVent() {
        val payload = json(LeapCommand.defrost().stateJSON)
        assertEquals("out", payload.get("circle"))
        assertEquals("wshld", payload.get("position"))
        assertEquals("1", payload.get("wshld"))
        // 温度和模式故意不跟第三方那条 24 ℃ 制冷，保留热风
        assertEquals("hot", payload.get("mode"))
        assertEquals("32", payload.get("temperature"))
    }

    @Test
    fun normalClimateStillAllVents() {
        val payload = json(LeapCommand.climate(true, 24, 3, ClimateMode.Cold, circleIn = true, windshield = false).stateJSON)
        assertEquals("all", payload.get("position"))
        assertEquals("in", payload.get("circle"))
        assertEquals("0", payload.get("wshld"))
    }
}
