package org.yipao.app.core

import java.util.Calendar

/// 预约类指令（cmdid 161 预约电池预热、171 预约空调）共用的星期编码。和 iOS 同名类型一一对应。
///
/// **0 = 周日、1 = 周一 … 6 = 周六。** 2026-11-19 按 leapauto 的协议文档定下，171 和 161 一起改。
/// 在此之前 161 发的是 1…7（周日 = 7，出自静态分析），两边都没有勾周日的实车样本，
/// 车主拍板按 0 走。如果哪天读回来的预约里出现 `7`，就说明这条定错了。
object AppointmentWeekday {
    /// 界面上的排列顺序：周一在前、周日在末，和国内日历习惯一致；值仍是协议编码。
    val ordered: List<Pair<Int, String>> = listOf(
        1 to "一", 2 to "二", 3 to "三", 4 to "四", 5 to "五", 6 to "六", 0 to "日",
    )

    val workdays: Set<Int> = setOf(1, 2, 3, 4, 5)

    /// 界面那七个格子（周一…周日的下标 0…6）→ 协议编码。周日那格是 0，不是 7。
    fun wireValue(displayIndex: Int): Int = ordered[displayIndex].first

    /// 「每周一、三、五」这种人话。空集合是一次性预约。
    fun summary(days: Set<Int>): String {
        if (days.isEmpty()) return "仅一次"
        if (days.size == 7) return "每天"
        if (days == workdays) return "工作日"
        if (days == setOf(6, 0)) return "周末"
        return "每周" + ordered.filter { it.first in days }.joinToString("、") { it.second }
    }
}

/// 一条预约空调（cmdid 171）。
///
/// 协议出处：leapauto 的官方抓包 `[681]`（设置）、`cancel/[332]`（取消）、`[334]`（取消后回读）。
/// 设置 payload 里除了时间、星期、温度、模式之外，风量 / 循环 / 除雾 / 出风位置都是固定值——
/// 车主选的方案是照官方抓包的默认值发（7 档 / 内循环 / 前挡除雾开 / 全车出风），不在界面上暴露。
data class ClimateAppointment(
    val hour: Int = 7,
    val minute: Int = 30,
    /// 协议编码（0 = 周日），见 [AppointmentWeekday]。空集合 = 仅一次。
    val days: Set<Int> = AppointmentWeekday.workdays,
    val temperature: Int = 24,
    val mode: Mode = Mode.Hot,
    /// 车上已有那条预约的 id。改已有预约时沿用，新建时为 null、下发时现造。
    val setID: String? = null,
) {
    /// 预约只开放制冷 / 制热两档：自动模式在 171 上没有任何样本
    /// （预约这条的 `operate` 抓包里只见过 `manual`）。
    enum class Mode(val wireValue: String, val label: String) {
        Cold("cold", "制冷"),
        Hot("hot", "制热"),
    }

    val timeText: String get() = "${pad(hour)}:${pad(minute)}"

    val summary: String
        get() = "${AppointmentWeekday.summary(days)} $timeText · ${mode.label} $temperature ℃"

    /// 下一次到点的时刻（毫秒）。`start_time` 带日期，一次性预约必须落在将来——
    /// 今天这个钟点已经过了就往后推一天，不然下发的是一个已经过去的时间。
    fun nextStart(now: Long): Long {
        val calendar = Calendar.getInstance().apply {
            timeInMillis = now
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (calendar.timeInMillis <= now) calendar.add(Calendar.DAY_OF_MONTH, 1)
        return calendar.timeInMillis
    }

    companion object {
        const val MIN_TEMPERATURE = 18
        const val MAX_TEMPERATURE = 32

        private fun pad(value: Int): String = if (value < 10) "0$value" else "$value"

        /// 从 `getappointment` 回读的 `controls[]` 里取第一条开着的预约。
        ///
        /// `controls` 为空（官方取消之后回读就是这样）或者里面没有 `on == "1"` 的项，返回 null——
        /// 那是「车上没有预约」，不是「读不到」，调用方要分清。
        fun parse(controls: List<JsonValue>): ClimateAppointment? {
            for (item in controls) {
                if (item.objectValue == null) continue
                if (item.get("on")?.stringValue != "1") continue
                val start = item.get("start_time")?.stringValue ?: continue
                val (hour, minute) = clock(start) ?: continue
                val days = item.get("days")?.arrayValue.orEmpty().mapNotNull { it.intValue }.toSet()
                val temperature = item.get("temperature")?.intValue ?: 24
                return ClimateAppointment(
                    hour = hour,
                    minute = minute,
                    days = days,
                    temperature = temperature.coerceIn(MIN_TEMPERATURE, MAX_TEMPERATURE),
                    mode = Mode.entries.firstOrNull { it.wireValue == item.get("mode")?.stringValue } ?: Mode.Hot,
                    setID = item.get("set_id")?.stringValue,
                )
            }
            return null
        }

        /// `"2026-10-22 19:54:00"` → (19, 54)。
        fun clock(startTime: String): Pair<Int, Int>? {
            val time = startTime.trim().split(" ").lastOrNull() ?: return null
            val hm = time.split(":")
            if (hm.size < 2) return null
            val hour = hm[0].toIntOrNull() ?: return null
            val minute = hm[1].toIntOrNull() ?: return null
            if (hour !in 0..23 || minute !in 0..59) return null
            return hour to minute
        }

        /// `getappointment` 的 `data` 是一段 **JSON 字符串**，里面才是 `{"controls":[...]}`。
        /// 也兼容网关哪天直接回对象。解析不出返回 null（= 读不到，不是「没有预约」）。
        fun controlsFromAppointmentData(data: JsonValue?): List<JsonValue>? {
            if (data == null) return null
            if (data.objectValue != null) return data.get("controls")?.arrayValue ?: emptyList()
            val text = (data as? JsonValue.Str)?.value?.takeIf { it.isNotEmpty() } ?: return null
            val decoded = JsonValue.parse(text) ?: return null
            if (decoded.objectValue == null) return null
            return decoded.get("controls")?.arrayValue ?: emptyList()
        }

        /// 预约空调。cmdid 171，走预约端点（`appointmentCmdIds` 里本来就有 171）。
        ///
        /// 字段值全用字符串（`on` / `temperature` / `windlevel` 等），`days` 是整数数组——
        /// 照官方抓包 `[681]` 的形态，不自作主张统一类型。字段按 key 排序，和 iOS 输出一致。
        fun command(appointment: ClimateAppointment, vin: String, now: Long = System.currentTimeMillis()): LeapCommand {
            val setID = appointment.setID?.takeIf { it.isNotEmpty() }
                ?: "${LeapConstants.PLATFORM_TAG}_${vin}_$now"
            val temperature = appointment.temperature.coerceIn(MIN_TEMPERATURE, MAX_TEMPERATURE)
            val control = "{\"circle\":\"in\",\"days\":[${appointment.days.sorted().joinToString(",")}]" +
                ",\"mode\":\"${appointment.mode.wireValue}\",\"on\":\"1\",\"operate\":\"manual\"" +
                ",\"position\":\"all\",\"set_id\":\"$setID\"" +
                ",\"start_time\":\"${formatTime(appointment.nextStart(now))}\"" +
                ",\"temperature\":\"$temperature\",\"update_time\":\"$now\"" +
                ",\"windlevel\":\"7\",\"wshld\":\"1\"}"
            return LeapCommand("171", "{\"controls\":[$control]}", "预约空调")
        }

        /// 取消预约空调：**发空的 `controls`**，不是发一条 `on: "0"` 的预约项。
        /// 官方取消抓包 `cancel/[332]` 就是这样，随后回读 `[334]` 拿到的也是空 `controls`。
        fun cancelCommand(): LeapCommand = LeapCommand("171", "{\"controls\":[]}", "取消预约空调")

        /// 预约接口要的时刻格式：`yyyy-MM-dd HH:mm:ss`，本机时区。
        private fun formatTime(millis: Long): String {
            val c = Calendar.getInstance().apply { timeInMillis = millis }
            return "${c.get(Calendar.YEAR)}-${pad(c.get(Calendar.MONTH) + 1)}-${pad(c.get(Calendar.DAY_OF_MONTH))} " +
                "${pad(c.get(Calendar.HOUR_OF_DAY))}:${pad(c.get(Calendar.MINUTE))}:${pad(c.get(Calendar.SECOND))}"
        }
    }
}
