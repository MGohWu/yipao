package org.yipao.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.MessageDigest

/// 证书解析与会话组帧。所有 hex 期望值都是 iOS `BLEProtocolTests` 里的原值。
class BLESessionTest {

    // MARK: - 证书

    @Test
    fun `证书响应明确选择 bluetoothKey 而不是 mobileControl`() {
        fun node(vin: String) = JsonValue.of(
            mapOf(
                "ecdhPublicKey" to JsonValue.of("public-$vin"),
                "keyType" to JsonValue.of(0),
                "passwordCard" to JsonValue.of("card-$vin"),
                "plainText" to JsonValue.of("plain-$vin"),
                "signResult" to JsonValue.of("sign-$vin"),
                "vin" to JsonValue.of(vin),
            ),
        )
        val response = JsonValue.of(
            mapOf(
                "result" to JsonValue.of(0),
                "data" to JsonValue.of(
                    mapOf("mobileControl" to node("MOBILE"), "bluetoothKey" to node("BLUETOOTH")),
                ),
            ),
        )

        val certificate = LeapBLEKeyCertificate.from(response)
        assertNotNull(certificate)
        assertEquals("BLUETOOTH", certificate!!.vin)
        assertEquals("public-BLUETOOTH", certificate.ecdhPublicKey)
    }

    @Test
    fun `旧证书缺少 keyType 时兼容路由到老款`() {
        val response = JsonValue.of(
            mapOf(
                "data" to JsonValue.of(
                    mapOf(
                        "bluetoothKey" to JsonValue.of(
                            mapOf(
                                "ecdhPublicKey" to JsonValue.of("legacy-public"),
                                "passwordCard" to JsonValue.of("0".repeat(80)),
                                "plainText" to JsonValue.of("a;b;c;d;e;f"),
                                "signResult" to JsonValue.of(LeapCrypto.base64Encode(bytes(0x01))),
                            ),
                        ),
                    ),
                ),
            ),
        )

        val certificate = LeapBLEKeyCertificate.from(response)
        assertNotNull(certificate)
        assertEquals(0, certificate!!.keyType)
        assertTrue(certificate.isSupportedKeyType)
    }

    @Test
    fun `生产蓝牙路径支持 keyType 0 和 1，拒绝未知类型`() {
        assertTrue(LeapBLEProtocol.supportsKeyType(0))
        assertTrue(LeapBLEProtocol.supportsKeyType(1))
        assertFalse(LeapBLEProtocol.supportsKeyType(2))
        assertTrue(TestVectors.eccCertificate().isSupportedKeyType)
    }

    @Test
    fun `passwordCard 必须覆盖 16 个 ASCII 五字节切片`() {
        val certificate = TestVectors.eccCertificate()
        assertTrue(certificate.hasValidPasswordCard)

        val short = certificate.copy(passwordCard = "0".repeat(79))
        assertFalse(short.hasValidPasswordCard)
        assertMessage("passwordCard 必须是至少 80 字节的 ASCII 字符串") { short.validatePasswordCard() }

        // 79 个 ASCII 加一个非 ASCII：长度够了但切片不再是 80 字节。
        val nonASCII = certificate.copy(passwordCard = "0".repeat(79) + "é")
        assertFalse(nonASCII.hasValidPasswordCard)
        assertMessage("passwordCard 必须是至少 80 字节的 ASCII 字符串") { nonASCII.validatePasswordCard() }

        assertMessage("passwordCard 必须是至少 80 字节的 ASCII 字符串") {
            LeapBLECryptoSession.make(certificate = short, vin = short.vin)
        }
    }

    @Test
    fun `未知证书类型仍明确拒绝`() {
        val unknown = TestVectors.eccCertificate().copy(keyType = 2)
        assertMessage("2") { LeapBLECryptoSession.make(certificate = unknown, vin = unknown.vin) }
    }

    // MARK: - 老款 P-256 会话

    @Test
    fun `固定 ECDH 向量生成官方 AA AB 控车帧`() {
        val session = TestVectors.eccSession()
        val frame = session.controlFrame(LeapBLEControlCommand.Unlock, TestVectors.FIXED_TIMESTAMP)

        assertEquals("aaab180000002f54522b62355a533357472b365965427753487079513d3d", frame.hex())

        val parsed = LeapBLEFrameReassembler().single(frame)
        assertEquals(
            bytes(0x88, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01).hex(),
            session.decrypt(parsed).hex(),
        )
    }

    @Test
    fun `直进直出 1_2_3 明文只有单个 order 字节`() {
        val session = TestVectors.eccSession()

        for (order in StraightMoveOrder.entries) {
            val frame = session.straightMoveFrame(order)
            val parsed = LeapBLEFrameReassembler().single(frame)

            assertEquals("aaab", frame.copyOf(2).hex())
            assertEquals(24, parsed.declaredPayloadLength)
            assertEquals(bytes(order.code).hex(), session.decrypt(parsed).hex())
        }
    }

    @Test
    fun `命令 3 明文携带完整 9 字节配置`() {
        val session = TestVectors.eccSession()
        val frame = session.configurationFrame(LeapBLEConfiguration.MANUAL_CONTROL, TestVectors.FIXED_TIMESTAMP)
        val plain = session.decrypt(LeapBLEFrameReassembler().single(frame))

        val body = bytes(0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x03) +
            LeapBLEConfiguration.MANUAL_CONTROL.bytes

        assertEquals(19, plain.size)
        assertEquals(LeapBLECryptoSession.crc8(body), plain[0])
        assertEquals(body.hex(), plain.copyOfRange(1, plain.size).hex())
    }

    @Test
    fun `固定 ECDH 向量生成官方 1_9 AA AE 认证帧`() {
        val session = TestVectors.eccSession()
        val frame = session.fullAuthenticationFrame(
            certificate = TestVectors.eccCertificate(),
            accountId = "12345678",
            deviceId = "0123456789ABCDEF0123456789ABCDEF",
            timestamp = 1_700_000_000,
        )

        assertEquals(291, frame.size)
        assertEquals("aaae1f01d4b01a00", frame.copyOf(8).hex())
        assertEquals("0109", frame.copyOfRange(frame.size - 2, frame.size).hex())
        assertEquals(
            "e2278d2cb93482b2cb1e8a2ccc5ddd6ef4b9b5ec50f3b3520966c276290b40dd",
            MessageDigest.getInstance("SHA-256").digest(frame).hex(),
        )
        // 时间戳后那个空字段和末尾的 isSupportBtn 是 resultCode=9 的根因，逐字符比对。
        assertEquals(
            "1700000000;;12345678;0123456789ABCDEF0123456789ABCDEF;d;e;f;56;2.00;08;16;1;0;1;1;",
            session.authTextOf(frame, tailSkip = 2),
        )
    }

    @Test
    fun `AA AE 从同一配置模型生成无感开关`() {
        val session = TestVectors.eccSession()
        val frame = session.fullAuthenticationFrame(
            certificate = TestVectors.eccCertificate(),
            accountId = "12345678",
            deviceId = "0123456789ABCDEF0123456789ABCDEF",
            timestamp = 1_700_000_000,
            configuration = LeapBLEConfiguration.MANUAL_CONTROL,
        )

        assertTrue(session.authTextOf(frame, tailSkip = 2).endsWith(";56;2.00;08;16;1;0;0;1;"))
    }

    @Test
    fun `老款 AES AA EE 重连帧使用 SHA-256 摘要`() {
        val session = TestVectors.eccSession()
        val frame = session.reconnectAuthenticationFrame(
            token = "DEADBEEF",
            accountId = "1234567890",
            timestamp = TestVectors.FIXED_TIMESTAMP,
        )

        assertEquals("aaee", frame.copyOf(2).hex())
        assertEquals("0109", frame.copyOfRange(frame.size - 18, frame.size - 16).hex())
        assertEquals(
            MessageDigest.getInstance("SHA-256").digest(frame.copyOf(frame.size - 16)).copyOf(16).hex(),
            frame.copyOfRange(frame.size - 16, frame.size).hex(),
        )
    }

    @Test
    fun `AA EE 组帧与官方 App 运行时固定向量一致`() {
        val publicKey = ByteArray(65) { if (it == 0) 0x04 else it.toByte() }
        val frame = LeapBLECryptoSession.reconnectFrame(
            sessionID = TestVectors.TEST_SESSION_ID,
            publicKey = publicKey,
            encodedCipher = ByteArray(64) { 0x41 },
            usesSM3 = true,
        )

        assertEquals(155, frame.size)
        assertEquals(
            "aaee9700d4b01a0004" +
                "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20" +
                "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40" +
                "4141414141414141414141414141414141414141414141414141414141414141" +
                "4141414141414141414141414141414141414141414141414141414141414141" +
                "01096135e0da096a186bf8d79ced78d22062",
            frame.hex(),
        )
    }

    // MARK: - 国密会话

    @Test
    fun `国密证书生成官方 SM3 SM4 AA AB 控车帧`() {
        val session = TestVectors.smSession()
        val frame = session.controlFrame(LeapBLEControlCommand.Unlock, TestVectors.FIXED_TIMESTAMP)

        assertEquals("aaab18000000416943615a4a303431474e644a4561545a70646736413d3d", frame.hex())
        assertEquals(
            bytes(0x88, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01).hex(),
            session.decrypt(LeapBLEFrameReassembler().single(frame)).hex(),
        )
    }

    @Test
    fun `国密 AA EE 明文包含 token、9 字节配置和账号长度`() {
        val session = TestVectors.smSession()
        val frame = session.reconnectAuthenticationFrame(
            token = "DEADBEEF",
            accountId = "1234567890",
            timestamp = TestVectors.FIXED_TIMESTAMP,
        )

        assertEquals(155, frame.size)
        assertEquals("aaee9700d4b01a00", frame.copyOf(8).hex())
        assertEquals("0109", frame.copyOfRange(frame.size - 18, frame.size - 16).hex())

        val cipher = frame.copyOfRange(73, frame.size - 18)
        val plain = session.decrypt(LeapBLEFrameReassembler().single(encryptedFrameOf(cipher)))

        val expected = bytes(0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01) +
            bytes(0xDE, 0xAD, 0xBE, 0xEF) +
            bytes(0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 1, 1) +
            bytes(0x0A, 0) +
            LeapCrypto.utf8("1234567890")
        assertEquals(expected.hex(), plain.hex())
    }

    // MARK: - 工具

    /// 认证帧里 sessionID(4) + 公钥(65) + 帧头(4) = 73 字节之后才是密文段。
    private fun LeapBLECryptoSession.authTextOf(frame: ByteArray, tailSkip: Int): String {
        val cipher = frame.copyOfRange(73, frame.size - tailSkip)
        val plain = decrypt(LeapBLEFrameReassembler().single(encryptedFrameOf(cipher)))
        val length = (plain[0].toInt() and 0xFF) or
            ((plain[1].toInt() and 0xFF) shl 8) or
            ((plain[2].toInt() and 0xFF) shl 16) or
            ((plain[3].toInt() and 0xFF) shl 24)
        return String(plain, 4, length, Charsets.UTF_8)
    }

    private fun assertMessage(fragment: String, block: () -> Unit) {
        try {
            block()
            fail("期望抛出包含「$fragment」的 LeapBLEProtocolError，实际没有抛")
        } catch (e: LeapBLEProtocolError) {
            assertTrue("错误文案是「${e.message}」，不含「$fragment」", e.message.contains(fragment))
        }
    }
}
