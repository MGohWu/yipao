package org.yipao.app.core

import org.junit.Assert.*
import org.junit.Test

class CallCarProtocolTest {
    @Test fun dedicatedAuthenticationAndOrders() {
        val session = TestVectors.eccSession()
        val frame = session.callCarAuthenticationFrame(TestVectors.eccCertificate(), "12345678", "device", 1_700_000_000)
        assertArrayEquals(bytes(170, 174, 1, 1, 10), frame.copyOf(5))
        assertEquals(frame.size - 7, (frame[5].toInt() and 255) or ((frame[6].toInt() and 255) shl 8))
        assertArrayEquals(bytes(212, 176, 26, 0), frame.copyOfRange(7, 11))
        val cipher = frame.copyOfRange(76, frame.size)
        val plain = session.decrypt(encrypted(cipher))
        val expected = LeapCrypto.utf8("1700000000;a;12345678;device;d;e;f;")
        assertArrayEquals(expected, plain.copyOfRange(4, 4 + expected.size))
        assertEquals(4 + expected.size + 64, plain.size)
        for (order in 1..6) {
            val parsed = LeapBLEFrameReassembler().append(session.callCarOrderFrame(order)).single()
            assertArrayEquals(bytes(order), session.decrypt(parsed))
        }
    }
    @Test fun statusPriorityAndInvalidPackets() {
        assertNull(CallCarStatus.parse("2;01;3"))
        assertNull(CallCarStatus.parse("0;2;;0;0"))
        assertEquals(CallCarStatus.Kind.Activate, CallCarStatus.parse("0;5;1;0;0")?.kind)
        assertEquals(CallCarStatus.Kind.Ready, CallCarStatus.parse("0;2;0;0;0")?.kind)
        assertEquals(CallCarStatus.Kind.Ready, CallCarStatus.parse("0;6;0;0;0")?.kind)
        assertEquals(CallCarStatus(CallCarStatus.Kind.Paused, 4), CallCarStatus.parse("0;2;0;4;0"))
        assertEquals(CallCarStatus(CallCarStatus.Kind.Failed, 9), CallCarStatus.parse("0;2;0;4;9"))
        assertEquals(CallCarStatus(CallCarStatus.Kind.Unavailable, 3), CallCarStatus.parse("0;2;3;0;0"))
        assertEquals(CallCarStatus.Kind.Paused, CallCarStatus.parse("0;4;0;0;0")?.kind)
        assertEquals(CallCarStatus.Kind.Failed, CallCarStatus.parse("0;99;0;0;0")?.kind)
    }
    @Test fun independentFramingAndBounds() {
        val raw = bytes(170, 172, 1, 1, 0, 3, 0, 0, 0, 65, 66, 67, 0, 0)
        val parser = CallCarPacketBuffer()
        assertTrue(parser.append(bytes(0, 170) + raw.copyOf(7)).isEmpty())
        val frames = parser.append(raw.copyOfRange(7, raw.size) + raw)
        assertEquals(2, frames.size)
        assertArrayEquals(LeapCrypto.utf8("ABC"), frames[0].payload)
        assertThrows(IllegalArgumentException::class.java) { CallCarPacketBuffer().append(raw.copyOf().also { it[2] = 2 }) }
        assertThrows(IllegalArgumentException::class.java) { CallCarPacketBuffer().append(bytes(170, 172, 1, 1, 0, 255, 255, 255, 255)) }
    }
    private fun encrypted(payload: ByteArray): LeapBLEFrame {
        val header = bytes(170, 171) + (0..3).map { (payload.size shr (it * 8)).toByte() }.toByteArray()
        return LeapBLEFrame(LeapBLEFrameKind.Encrypted, payload.size, header + payload)
    }
}
