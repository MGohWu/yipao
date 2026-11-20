package org.yipao.app.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

/// 远程启停充电（193）、解锁充电枪（192）、预约空调（171）、遮阳帘 / 天窗开合确认。
/// 对齐 iOS `RemoteChargeAndScheduleTests`。
class RemoteChargeAndScheduleTest {

    private fun state(pairs: Map<String, String>) =
        VehicleState(signalMap = pairs, schema = SignalSchema.detect(pairs))

    /// 数字口径的最小底子：只放一个电量，让 detect 认成 numeric。
    private val base = mapOf("1204" to "80", "1318" to "1000", "sts" to "1")

    private fun with(extra: Map<String, String>) = state(base + extra)

    private fun at(hour: Int): Long = Calendar.getInstance().apply {
        clear()
        set(2026, Calendar.NOVEMBER, 19, hour, 0, 0)
    }.timeInMillis

    private fun firstControl(command: LeapCommand): JSONObject =
        JSONObject(command.stateJSON).getJSONArray("controls").getJSONObject(0)

    private fun ints(array: JSONArray): List<Int> = (0 until array.length()).map { array.getInt(it) }

    // MARK: - 遮阳帘 / 天窗

    @Test
    fun sunshadeAndSunroofSignals() {
        val c16 = with(mapOf("1724" to "0"))
        assertEquals(false, c16.sunshadeOpen)
        assertNull(c16.sunroofOpen)
        assertEquals(true, with(mapOf("1724" to "100")).sunshadeOpen)
        assertEquals(true, with(mapOf("1718" to "10")).sunroofOpen)
        assertEquals(false, with(mapOf("1718" to "0")).sunroofOpen)
    }

    @Test
    fun sunroofSNAIsUnknown() {
        assertNull(with(mapOf("1718" to "15")).sunroofOpen)
        assertNull(with(mapOf("1718" to "150")).sunroofOpen)
    }

    @Test
    fun sunshadeObservabilityFollowsCar() {
        // 不报的车如果也等信号，就会每次都误报「未收到车辆确认」
        assertEquals(ExpectationKind.Unobservable, LeapCommand.sunshade(true).expectation.kind)
        LeapCommand.sunshade(true, observable = true).expectation.let {
            assertEquals(ExpectationKind.SunshadeOpen, it.kind)
            assertTrue(it.boolValue)
        }
        LeapCommand.sunroof(false, observable = true).expectation.let {
            assertEquals(ExpectationKind.SunroofOpen, it.kind)
            assertFalse(it.boolValue)
        }
        val expectation = ControlExpectation.sunshadeOpen(true)
        assertFalse(expectation.isSatisfied(with(mapOf("1724" to "0"))))
        // 下发的是 "10"，车回报 10 还是 100 都算开
        assertTrue(expectation.isSatisfied(with(mapOf("1724" to "10"))))
        assertTrue(expectation.isSatisfied(with(mapOf("1724" to "100"))))
    }

    @Test
    fun sunshadePayloadUnchanged() {
        assertEquals("10", JSONObject(LeapCommand.sunshade(true, observable = true).stateJSON).get("value"))
        assertEquals("0", JSONObject(LeapCommand.sunshade(false).stateJSON).get("value"))
        assertEquals("1", JSONObject(LeapCommand.sunroof(true).stateJSON).get("value"))
    }

    // MARK: - 启停充电 / 解锁

    @Test
    fun chargingPayload() {
        val start = LeapCommand.charging(true)
        val stop = LeapCommand.charging(false)
        assertEquals("193", start.cmdid)
        assertEquals("193", stop.cmdid)
        assertEquals("start", JSONObject(start.stateJSON).get("value"))
        // 车端 OBC 只认 start / finish，发 stop 服务端照收、车不理
        assertEquals("finish", JSONObject(stop.stateJSON).get("value"))
        assertFalse(start.isAppointment)
    }

    @Test
    fun startChargingExpectation() {
        val expectation = ControlExpectation.charging(true)
        assertFalse(expectation.isSatisfied(with(mapOf("1149" to "0"))))
        assertTrue(expectation.isSatisfied(with(mapOf("1149" to "1"))))
        assertFalse(expectation.isSatisfied(with(emptyMap())))
    }

    @Test
    fun stopChargingExpectation() {
        val expectation = ControlExpectation.charging(false)
        for (value in listOf("0", "2", "4", "6")) {
            assertTrue("1149=$value", expectation.isSatisfied(with(mapOf("1149" to value))))
        }
        assertFalse(expectation.isSatisfied(with(mapOf("1149" to "1"))))
        assertFalse(expectation.isSatisfied(with(mapOf("1149" to "3"))))
    }

    @Test
    fun unlockGun() {
        val command = LeapCommand.unlockChargingGun()
        assertEquals("192", command.cmdid)
        assertEquals("unlock", JSONObject(command.stateJSON).get("operation"))
        // 94 在停充未拔枪时已经是 0，拿它判会假确认，所以老实 unobservable
        assertFalse(command.expectation.isObservable)
    }

    // MARK: - 预约空调

    @Test
    fun climateAppointmentPayload() {
        val appointment = ClimateAppointment(hour = 7, minute = 30, days = setOf(1, 3, 0), temperature = 26, mode = ClimateAppointment.Mode.Hot)
        // 2026-11-19 06:00（本地时间）：07:30 还没过，start_time 应该就是今天
        val command = ClimateAppointment.command(appointment, "VIN123", now = at(6))
        assertEquals("171", command.cmdid)
        assertTrue(command.isAppointment)
        val controls = JSONObject(command.stateJSON).getJSONArray("controls")
        assertEquals(1, controls.length())
        val item = controls.getJSONObject(0)
        assertEquals("1", item.get("on"))
        assertEquals("manual", item.get("operate"))
        assertEquals("hot", item.get("mode"))
        assertEquals("26", item.get("temperature"))
        // 固定默认值：7 档 / 内循环 / 除雾开 / 全车出风（官方抓包 [681]）
        assertEquals("7", item.get("windlevel"))
        assertEquals("in", item.get("circle"))
        assertEquals("1", item.get("wshld"))
        assertEquals("all", item.get("position"))
        // days 是整数数组，周日是 0
        assertEquals(listOf(0, 1, 3), ints(item.getJSONArray("days")))
        assertEquals("2026-11-19 07:30:00", item.get("start_time"))
        assertTrue(item.getString("set_id").startsWith("Android_VIN123_"))
    }

    @Test
    fun oneShotRollsToTomorrow() {
        val appointment = ClimateAppointment(hour = 7, minute = 30, days = emptySet())
        val item = firstControl(ClimateAppointment.command(appointment, "V", now = at(9)))
        assertEquals("2026-11-20 07:30:00", item.get("start_time"))
        assertEquals(0, item.getJSONArray("days").length())
    }

    @Test
    fun keepsExistingSetID() {
        val item = firstControl(ClimateAppointment.command(ClimateAppointment(setID = "android_abc123"), "V"))
        assertEquals("android_abc123", item.get("set_id"))
    }

    @Test
    fun cancelSendsEmptyControls() {
        val command = ClimateAppointment.cancelCommand()
        assertEquals("171", command.cmdid)
        assertEquals("""{"controls":[]}""", command.stateJSON)
    }

    @Test
    fun parsesReadback() {
        val raw = """{"controls":[{"circle":"in","days":[1,3,4],"mode":"hot","on":"1","operate":"manual","position":"all","set_id":"android_x","start_time":"2026-10-22 19:54:00","temperature":"32","update_time":"1","windlevel":"7","wshld":"1"}]}"""
        val controls = ClimateAppointment.controlsFromAppointmentData(JsonValue.of(raw))!!
        val appointment = ClimateAppointment.parse(controls)!!
        assertEquals(19, appointment.hour)
        assertEquals(54, appointment.minute)
        assertEquals(setOf(1, 3, 4), appointment.days)
        assertEquals(32, appointment.temperature)
        assertEquals(ClimateAppointment.Mode.Hot, appointment.mode)
        assertEquals("android_x", appointment.setID)
        assertEquals("每周一、三、四 19:54 · 制热 32 ℃", appointment.summary)
    }

    @Test
    fun emptyVersusUnreadable() {
        val empty = ClimateAppointment.controlsFromAppointmentData(JsonValue.of("""{"controls":[]}"""))
        assertNotNull(empty)
        assertTrue(empty!!.isEmpty())
        assertNull(ClimateAppointment.parse(empty))
        // 乱码 → null（读不到），调用方据此报错而不是说「没有预约」
        assertNull(ClimateAppointment.controlsFromAppointmentData(JsonValue.of("not json")))
        assertNull(ClimateAppointment.controlsFromAppointmentData(null))
    }

    @Test
    fun disabledItemIsNotAnAppointment() {
        val controls = ClimateAppointment.controlsFromAppointmentData(
            JsonValue.of("""{"controls":[{"on":"0","start_time":"2026-10-22 07:00:00","days":[]}]}"""),
        ).orEmpty()
        assertNull(ClimateAppointment.parse(controls))
    }

    // MARK: - 星期编码

    @Test
    fun weekdayEncoding() {
        assertEquals(1, AppointmentWeekday.ordered.first().first)
        assertEquals(0, AppointmentWeekday.ordered.last().first)
        assertEquals("日", AppointmentWeekday.ordered.last().second)
        assertFalse(AppointmentWeekday.ordered.any { it.first == 7 })
        // 界面七格：周日那格（下标 6）发 0
        assertEquals(0, AppointmentWeekday.wireValue(6))
        assertEquals(1, AppointmentWeekday.wireValue(0))
    }

    @Test
    fun weekdaySummary() {
        assertEquals("仅一次", AppointmentWeekday.summary(emptySet()))
        assertEquals("工作日", AppointmentWeekday.summary(setOf(1, 2, 3, 4, 5)))
        assertEquals("周末", AppointmentWeekday.summary(setOf(6, 0)))
        assertEquals("每天", AppointmentWeekday.summary((0..6).toSet()))
        assertEquals("每周一、日", AppointmentWeekday.summary(setOf(0, 1)))
    }

    @Test
    fun batteryPreheatSundayIsZero() {
        val command = LeapCommand.batteryPreheatAppointment(true, System.currentTimeMillis(), listOf(0, 6), "V")
        assertEquals(listOf(0, 6), ints(firstControl(command).getJSONArray("days")))
    }
}
