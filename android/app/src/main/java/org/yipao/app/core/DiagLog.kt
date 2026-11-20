package org.yipao.app.core

import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/// 标定新车型用的诊断日志。
///
/// 存在的理由：零跑没有公开信号表，`SignalSchema` 里每一条映射都得靠真实响应反推。
/// 接入下一个车型时，把 App 装到真机跑一遍，signalMap 全量就在日志里：
///
///     adb logcat -s leap-diag
///
/// 与 iOS/鸿蒙不同的一点：安卓应用读不到自己的 logcat（JB 之后就禁了），
/// 所以这里额外留一份内存环形缓冲。
///
/// 脱敏：VIN 只留后 4 位，token / 手机号 / 账号 ID 一类的键整体遮蔽。
/// 车况字段原样输出——包括经纬度，判断隐私模式开没开要用到。
object DiagLog {

    private const val TAG = "leap-diag"

    /// 环形缓冲上限。一次冷启动到首页大约 40 条，2000 条够覆盖一整轮排查会话。
    private const val CAPACITY = 2000

    private val buffer = ArrayDeque<String>(CAPACITY)
    private val timeFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    /// 值需要整体遮蔽的键，小写包含匹配。
    private val secretKeyFragments = listOf(
        "token", "password", "oppwd", "sign", "phone", "mobile",
        "accountid", "userid", "idcard", "openid", "unionid", "email",
    )

    fun note(text: String) {
        Log.i(TAG, text)
        synchronized(buffer) {
            val line = "${timeFormat.format(Date())} $text"
            if (buffer.size >= CAPACITY) buffer.removeFirst()
            buffer.addLast(line)
        }
    }

    /// 内存缓冲的快照，最新的在最后。
    fun snapshot(): List<String> = synchronized(buffer) { buffer.toList() }

    fun clear() {
        synchronized(buffer) { buffer.clear() }
    }

    fun maskVin(vin: String): String {
        if (vin.length <= 4) return if (vin.isEmpty()) "(空)" else vin
        return "…" + vin.takeLast(4)
    }

    /// 递归遮蔽敏感值，其余结构原样保留。
    fun redacted(value: JsonValue): JsonValue = when (value) {
        is JsonValue.Obj -> {
            val out = LinkedHashMap<String, JsonValue>(value.value.size)
            for ((key, child) in value.value) {
                val lower = key.lowercase()
                out[key] = when {
                    lower.contains("vin") ->
                        JsonValue.of(child.stringValue?.let { maskVin(it) } ?: "***")

                    secretKeyFragments.any { lower.contains(it) } -> JsonValue.of("***")
                    else -> redacted(child)
                }
            }
            JsonValue.of(out)
        }

        is JsonValue.Arr -> JsonValue.of(value.value.map { redacted(it) })
        else -> value
    }

    /// logcat 单条会在 4KB 附近被截断，长文本按行切块发，带序号方便拼回。
    fun emit(tag: String, text: String, limit: Int = 700) {
        val chunks = mutableListOf<String>()
        var current = StringBuilder()
        for (line in text.split("\n")) {
            if (current.isNotEmpty() && current.length + line.length + 1 > limit) {
                chunks.add(current.toString())
                current = StringBuilder()
            }
            if (current.isEmpty()) current.append(line) else current.append('\n').append(line)
        }
        if (current.isNotEmpty()) chunks.add(current.toString())
        val total = maxOf(1, chunks.size)
        chunks.forEachIndexed { index, chunk -> note("[$tag] ${index + 1}/$total\n$chunk") }
    }
}
