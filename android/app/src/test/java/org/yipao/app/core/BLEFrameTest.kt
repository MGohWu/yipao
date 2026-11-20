package org.yipao.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// 帧重组、事件解析和分号响应。对齐 iOS `BLEProtocolTests` 的同名用例。
class BLEFrameTest {

    @Test
    fun `AA AB 跨分片后按声明长度重组`() {
        val raw = bytes(0xAA, 0xAB, 0x04, 0, 0, 0, 0x41, 0x42, 0x43, 0x44)
        val reassembler = LeapBLEFrameReassembler()

        assertTrue(reassembler.append(raw.copyOf(3)).isEmpty())
        assertEquals(3, reassembler.bufferedByteCount)

        val frame = reassembler.single(raw.copyOfRange(3, raw.size))
        assertEquals(LeapBLEFrameKind.Encrypted, frame.kind)
        assertEquals(4, frame.declaredPayloadLength)
        assertEquals(raw.hex(), frame.bytes.hex())
        assertEquals(0, reassembler.bufferedByteCount)
    }

    @Test
    fun `噪声和同一分片中的多帧不会破坏同步`() {
        val stream = bytes(0x00, 0xFF, 0xAA, 0x00) +
            bytes(0xAA, 0xAC, 2, 0, 0, 3, 2, 0, 0, 0, 0x07, 0x01) +
            bytes(0xAA, 0xAB, 1, 0, 0, 0, 0x58)

        val frames = LeapBLEFrameReassembler().append(stream)

        assertEquals(listOf(LeapBLEFrameKind.Event, LeapBLEFrameKind.Encrypted), frames.map { it.kind })
        assertEquals(listOf(2, 1), frames.map { it.declaredPayloadLength })
    }

    @Test
    fun `实车 AA AC 无感解闭锁事件可解析`() {
        val frames = LeapBLEFrameReassembler().append(
            bytes(0xAA, 0xAC, 2, 0, 0, 2, 3, 0, 0, 0, 0x2D, 0x02, 0x01) +
                bytes(0xAA, 0xAC, 2, 0, 0, 2, 3, 0, 0, 0, 0x24, 0x02, 0x02),
        )

        assertEquals(2, frames.size)
        assertEquals(
            LeapBLEEvent.LockOperation(0x2D, LeapBLEEvent.Trigger.Passive, LeapBLEEvent.Operation.Unlock),
            frames[0].event,
        )
        assertEquals(
            LeapBLEEvent.LockOperation(0x24, LeapBLEEvent.Trigger.Passive, LeapBLEEvent.Operation.Lock),
            frames[1].event,
        )
    }

    @Test
    fun `实车 AA AC 区域事件可解析`() {
        val frames = LeapBLEFrameReassembler().append(
            bytes(0xAA, 0xAC, 2, 0, 0, 3, 2, 0, 0, 0, 0x07, 0x01) +
                bytes(0xAA, 0xAC, 2, 0, 0, 3, 2, 0, 0, 0, 0x09, 0x03),
        )

        assertEquals(LeapBLEEvent.AreaChange(0x07, LeapBLEEvent.Area.Unlock), frames[0].event)
        assertEquals(LeapBLEEvent.AreaChange(0x09, LeapBLEEvent.Area.TrendLock), frames[1].event)
    }

    @Test
    fun `AA AC 错误应答取最后一字节 resultCode`() {
        val frame = LeapBLEFrameReassembler().single(bytes(0xAA, 0xAC, 2, 0, 0, 1, 2, 0, 0, 0, 0x55, 0x07))
        val event = frame.event as LeapBLEEvent.ErrorResponse

        assertEquals(7, event.resultCode)
        assertEquals("5507", event.payload.hex())
    }

    @Test
    fun `截断帧继续缓存，补齐后才输出`() {
        val raw = bytes(0xAA, 0xEE, 0x03, 0x00, 0x11, 0x22, 0x33)
        val reassembler = LeapBLEFrameReassembler()

        assertTrue(reassembler.append(raw.copyOf(raw.size - 1)).isEmpty())
        assertEquals(6, reassembler.bufferedByteCount)
        assertEquals(raw.hex(), reassembler.single(bytes(0x33)).bytes.hex())
    }

    /// 这条曾经真的崩过：`6 + 0x7FFFFFFF` 用 Int 算会溢出成负数，
    /// 负数既躲过超长闸、又让 `ByteArray(total)` 抛 NegativeArraySize——
    /// 也就是说蓝牙上一段畸形数据就能把 App 干掉。
    @Test
    fun `异常的大长度字段会被丢弃并重新找到下一帧`() {
        val invalid = bytes(0xAA, 0xAB, 0xFF, 0xFF, 0xFF, 0x7F)
        val valid = bytes(0xAA, 0xAB, 0x01, 0, 0, 0, 0x58)
        val reassembler = LeapBLEFrameReassembler()

        val frame = reassembler.single(invalid + valid)

        assertEquals(valid.hex(), frame.bytes.hex())
        assertEquals(0, reassembler.bufferedByteCount)
    }

    @Test
    fun `脱敏帧说明不包含载荷，完整模式保留十六进制`() {
        val raw = bytes(0xAA, 0xAB, 0x04, 0, 0, 0, 0x41, 0x42, 0x43, 0x44)
        val frame = LeapBLEFrame(LeapBLEFrameKind.Encrypted, 4, raw)

        assertFalse(frame.logDetail(includingPayload = false).contains("41424344"))
        assertTrue(frame.logDetail(includingPayload = true).contains("41424344"))
    }

    @Test
    fun `官方分号响应区分认证状态和重连 token`() {
        assertEquals(
            LeapBLEDecryptedResponse.Authentication("1", listOf("extra")),
            LeapBLEDecryptedResponse.from(LeapCrypto.utf8("0;1;extra")),
        )
        assertEquals(
            LeapBLEDecryptedResponse.ReconnectToken("A1B2C3D4"),
            LeapBLEDecryptedResponse.from(LeapCrypto.utf8("1;A1B2C3D4")),
        )
        assertEquals(
            LeapBLEDecryptedResponse.Command("response-id", "0", listOf("extra")),
            LeapBLEDecryptedResponse.from(LeapCrypto.utf8("2;response-id;0;extra")),
        )
        assertNull(LeapBLEDecryptedResponse.from(LeapCrypto.utf8("1;not-hex")))
        assertNull(LeapBLEDecryptedResponse.from(LeapCrypto.utf8("0")))
    }

    @Test
    fun `CRC8 与官方多项式 0x07 一致`() {
        assertEquals(0x88.toByte(), LeapBLECryptoSession.crc8(bytes(0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01)))
    }

    @Test
    fun `官方 1_9 默认蓝牙配置固定为 9 字节`() {
        assertEquals(
            bytes(0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 1, 1).hex(),
            LeapBLEConfiguration.OFFICIAL_DEFAULT.bytes.hex(),
        )
    }

    @Test
    fun `首次绑定默认只开启蓝牙控车`() {
        assertEquals("56;2.00;08;16", LeapBLEConfiguration.MANUAL_CONTROL.calibrationText)
        assertEquals(
            bytes(0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 0, 1).hex(),
            LeapBLEConfiguration.MANUAL_CONTROL.bytes.hex(),
        )
    }
}
