package org.yipao.app.core

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// 只覆盖分流判定这一件事：哪些分类该进 logcat、哪些只留在回溯缓冲里。
///
/// 分类名一旦被改错（比如把 `RX-CHUNK` 写成 `RX_CHUNK`），高频日志就会静默地开始
/// 刷 `DiagLog`，把 2000 条环形缓冲冲掉——没有任何报错，只是排查时什么都不剩。
///
/// `replay` 本身测不了：它要读 `AppEnv.context` 判断是不是 debug 构建，单测里没有 Context。
class BLETraceTest {

    @After
    fun tearDown() = BLETrace.reset()

    @Test
    fun `高频分类只进回溯缓冲`() {
        assertFalse(BLETrace.note("TX-CHUNK", "第 1/3 片，197 bytes"))
        assertFalse(BLETrace.note("RX-CHUNK", "收到 20 bytes"))
        assertFalse(BLETrace.note("REASSEMBLY", "帧尚未收全，已缓存 6 bytes"))
        assertFalse(BLETrace.note("RX-FRAME", "AA AB 声明载荷 32 bytes"))
        assertFalse(BLETrace.note("SERVICE-MAP", "0000fffe-… → 0000fff2-…"))
    }

    @Test
    fun `建链与故障分类同时进系统日志`() {
        assertTrue(BLETrace.note("SERVICE", "服务发现完成：12 个服务，FFFE=有，耗时 340 ms"))
        assertTrue(BLETrace.note("MTU", "协商结果 mtu=200，等了 180 ms"))
        assertTrue(BLETrace.note("NOTIFY", "已订阅 FFF2 通知，耗时 90 ms"))
        assertTrue(BLETrace.note("CONNECT", "连接已断开（status=19 车端主动断开）"))
        assertTrue(BLETrace.note("ERROR", "服务表里没有 FFFE"))
    }

    @Test
    fun `没有勾选时导出不带帧原文`() {
        BLETrace.note("RX-FRAME", "AA AB 声明载荷 32 bytes", "hex=AAAB0020DEADBEEF")
        val plain = BLETrace.dump(includingSensitive = false)!!
        assertTrue(plain.contains("AA AB 声明载荷 32 bytes"))
        // 帧原文是能开车门的材料，车主没主动勾就一个字节都不该出现在上传内容里。
        assertFalse(plain.contains("DEADBEEF"))
        assertTrue(BLETrace.dump(includingSensitive = true)!!.contains("DEADBEEF"))
    }

    @Test
    fun `缓冲为空时没有可传的内容`() {
        assertFalse(BLETrace.hasEntries)
        assertNull(BLETrace.dump(includingSensitive = true))
        BLETrace.note("CONNECT", "发起连接")
        assertTrue(BLETrace.hasEntries)
    }
}
