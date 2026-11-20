package org.yipao.app.core

import android.os.Process
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicLong

/** 小组件诊断写入本机诊断日志；只收阶段名、布尔状态与错误类型，不记录请求或凭据。 */
internal class WidgetTrace(label: String) {
    private val start = SystemClock.elapsedRealtime()
    private val id = "${Process.myPid()}-${sequence.incrementAndGet()}"

    init { note("begin $label") }

    fun note(stage: String) {
        AuthAuditLog.note("[widget:$id +${SystemClock.elapsedRealtime() - start}ms] $stage")
    }

    suspend fun <T> step(stage: String, block: suspend () -> T): T {
        note("$stage.begin")
        try {
            return block().also { note("$stage.ok") }
        } catch (error: Throwable) {
            note("$stage.error ${error.javaClass.simpleName} kind=${(error as? LeapError)?.kind} http=${(error as? LeapError)?.httpStatus}")
            throw error
        }
    }

    companion object { private val sequence = AtomicLong() }
}
