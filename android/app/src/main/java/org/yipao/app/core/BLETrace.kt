package org.yipao.app.core

import android.content.pm.ApplicationInfo
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/// 蓝牙链路的时序缓冲。对齐鸿蒙 `BLEVehicleController` 里那份导出缓冲。
///
/// 存在的理由：建链出问题时，真正说明问题的是**出事之前**那几十条——服务发现拿到了什么、
/// MTU 等了多久、分片发到第几片断的。但这些都是高频记录，逐条写进 logcat 会把
/// `DiagLog` 那 2000 条环形缓冲刷爆，有用的反而被挤掉。
///
/// 所以分两层：
/// - [QUIET_CATEGORIES] 里的高频分类只落这份缓冲，平时一声不吭；
/// - 其余分类照旧同时进 `DiagLog`，也就进 `adb logcat -s leap-diag`。
///
/// 一旦建链失败、非预期断连、写入超时或解密失败，[replay] 把缓冲里最近一段一次性
/// 倒进 logcat（标 `[ble:REPLAY]`）。平时不刷屏，出事时拿到完整时序。
///
/// 帧的十六进制内容**一直存在缓冲里**，带不带出去由出口各自决定：
/// - [replay] 往 logcat 里倒，只有 debug 构建带 hex——正式包的 logcat 谁都读得到；
/// - [dump] 整份导出，调用方显式要求才带 hex。
object BLETrace {

    /// 缓冲上限，对齐鸿蒙的 `maximumExportLogEntries`。一次完整建链（含分片收发）
    /// 大约 200 条，4000 条够覆盖十几轮重连。
    private const val CAPACITY = 4000

    /// 一次回溯往 logcat 里倒多少条。再多也读不完，而且会把回溯本身变成刷屏。
    private const val REPLAY_LIMIT = 400

    /// 只进缓冲、不进 logcat 的高频分类。
    private val QUIET_CATEGORIES = setOf(
        "TX-CHUNK", "RX-CHUNK", "REASSEMBLY", "RX-FRAME", "SERVICE-MAP",
        "COCKPIT-TX", "COCKPIT-RX",
    )

    /// 导出体积上限。
    private const val DUMP_LIMIT_BYTES = 256 * 1024

    /// 往 logcat 倒的时候带不带 hex。正式包的 logcat 装了 App 的人都读得到，
    /// 所以这一路只对 debug 构建放行——取 `FLAG_DEBUGGABLE`。
    private val logcatIncludesSensitiveDetail: Boolean by lazy {
        (AppEnv.context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    /// 缓冲里有没有东西。
    val hasEntries: Boolean get() = synchronized(buffer) { buffer.isNotEmpty() }

    private class Entry(
        val time: String,
        val category: String,
        val message: String,
        val detail: String,
    ) {
        fun render(includingSensitive: Boolean): String {
            val suffix = if (includingSensitive && detail.isNotEmpty()) " $detail" else ""
            return "$time [$category] $message$suffix"
        }
    }

    private val buffer = ArrayDeque<Entry>()
    private val timeFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    /// 一条链路只回溯一次。连环失败（断开 → 重连失败 → 再断开）会连着触发好几次，
    /// 每次都倒 400 条的话，第一次那份——也就是真正记录了起因的那份——就被顶没了。
    private var replayed = false

    /// 记一条。返回 true 表示调用方还该把它写进 `DiagLog`（高频分类返回 false）。
    fun note(category: String, message: String, detail: String = ""): Boolean {
        val entry = Entry(timeFormat.format(Date()), category, message, detail)
        synchronized(buffer) {
            if (buffer.size >= CAPACITY) buffer.removeFirst()
            buffer.addLast(entry)
        }
        return category !in QUIET_CATEGORIES
    }

    /// 新一轮连接开始时调，让下一次出事还能再回溯一次。缓冲本身不清——
    /// 跨连接的上下文（上一次是怎么断的）恰恰是重连问题的关键。
    fun armReplay() {
        replayed = false
    }

    /// 把最近一段时序倒进 logcat。`reason` 说明是被什么触发的。
    fun replay(reason: String) {
        if (replayed) return
        replayed = true
        val recent = synchronized(buffer) { buffer.toList() }.takeLast(REPLAY_LIMIT)
        if (recent.isEmpty()) return
        val body = recent.joinToString("\n") { it.render(logcatIncludesSensitiveDetail) }
        DiagLog.emit("ble:REPLAY", "触发：$reason（最近 ${recent.size} 条）\n$body")
    }

    /// 导出整份缓冲。`includingSensitive` 决定带不带帧的十六进制内容。
    ///
    /// 导出的是全量而不是 [replay] 那 400 条：那一份是给 logcat 控量的，
    /// 多出来的前情反而常常是关键。超过 [DUMP_LIMIT_BYTES]
    /// 从头部裁——最近发生的才是要看的。
    fun dump(includingSensitive: Boolean): String? {
        val entries = synchronized(buffer) { buffer.toList() }
        if (entries.isEmpty()) return null
        val body = entries.joinToString("\n") { it.render(includingSensitive) }
        val bytes = body.toByteArray()
        if (bytes.size <= DUMP_LIMIT_BYTES) return body
        // 从行边界起裁，别把一条日志劈成两半。
        val tail = String(bytes, bytes.size - DUMP_LIMIT_BYTES, DUMP_LIMIT_BYTES)
        return "(更早的蓝牙日志已裁剪)\n" + tail.substringAfter('\n')
    }

    /// 诊断会话之间清场，只在测试里用得上。
    fun reset() {
        synchronized(buffer) { buffer.clear() }
        replayed = false
    }
}
