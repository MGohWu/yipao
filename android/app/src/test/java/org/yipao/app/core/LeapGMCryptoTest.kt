package org.yipao.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// 国密原语。
///
/// SM3 的两条是 GM/T 0004-2012 的标准向量；SM2 KAP 的共享密钥来自 BabaSSL 8.3.1，
/// 和 iOS `CryptoParityTests` 用的是同一个值。其余期望值由一份独立的
/// Python 参考实现算出（按 GM/T 标准和 `LeapGMCrypto.c` 的算式重写，不引用本工程代码）。
///
/// 注意：车端用的是 GmSSL 的 KAP 变体，`material = x‖y‖Z_self‖Z_peer` 里带了各自的 Z，
/// 所以**两端的 sharedKey 本来就不相等**——不要照 ECDH 的直觉去改成相等断言。
class LeapGMCryptoTest {

    @Test
    fun `SM3 与 GM_T 标准向量一致`() {
        assertEquals(
            "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0",
            LeapGMCrypto.sm3(LeapCrypto.utf8("abc")).hex(),
        )
        assertEquals(
            "debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732",
            LeapGMCrypto.sm3(LeapCrypto.utf8("abcd".repeat(16))).hex(),
        )
    }

    @Test
    fun `SM3 KDF 按计数器串接且长度可截断`() {
        val long = LeapGMCrypto.sm3KDF(LeapCrypto.utf8("abc"), 48)
        assertEquals(
            "fe1ea80dac6f100c33537bd24619ec7c72a1e8b1ffeaefb1eb52a37791fdaf61" +
                "9db16c0ac7bebb47238c6cc925ff66af",
            long.hex(),
        )
        // 短的必须是长的前缀：KDF 是按 32 字节块往后接的，不是每个长度重算一次。
        assertEquals(long.copyOf(32).hex(), LeapGMCrypto.sm3KDF(LeapCrypto.utf8("abc"), 32).hex())
    }

    @Test
    fun `SM4 CBC PKCS7 可往返且密文固定`() {
        val key = "0123456789abcdeffedcba9876543210".hexBytes()
        val iv = "000102030405060708090a0b0c0d0e0f".hexBytes()
        val plain = LeapCrypto.utf8("hello sm4 cbc pkcs7 padding!!")

        val cipher = LeapGMCrypto.sm4Encrypt(plain, key, iv)
        assertEquals("1907379f81737a2d40cf93b2bfb6240036438858455b4f0ddf92f578c15e9880", cipher.hex())
        assertEquals(plain.hex(), LeapGMCrypto.sm4Decrypt(cipher, key, iv).hex())
    }

    @Test
    fun `SM2 KAP 与 BabaSSL 8_3_1 固定向量一致`() {
        val agreement = LeapGMCrypto.sm2KAP(
            certificatePEM = "unused by raw vector",
            privateKey = TestVectors.fixedPrivateKey,
            peerPublicKeyX963 = TestVectors.SM2_PEER_PUBLIC_KEY.hexBytes(),
        )

        assertEquals(TestVectors.SM2_LOCAL_PUBLIC_KEY, agreement.publicKey.hex())
        assertEquals(
            "5f86e6b17708f60dfb5d8e3f3ce2b35d3d29744d51c46fc14cdb7bb95fdaf48b",
            agreement.sharedKey.hex(),
        )
    }

    @Test
    fun `SM2 PEM X_509 证书可提取中控公钥`() {
        val agreement = LeapGMCrypto.sm2KAP(
            certificatePEM = TestVectors.SM2_CERTIFICATE_PEM,
            privateKey = TestVectors.fixedPrivateKey,
        )

        assertEquals(TestVectors.SM2_LOCAL_PUBLIC_KEY, agreement.publicKey.hex())
        assertEquals(32, agreement.sharedKey.size)
        assertTrue(agreement.sharedKey.any { it != 0.toByte() })
    }

    /// 两端各自算：公钥要各是各的，协商点相同但 sharedKey 因为带 Z 而不同。
    /// 这条锁的是「Z 的顺序没写反」——写反了两边会算出同一个值，看着像对了。
    @Test
    fun `SM2 KAP 两端 Z 值不对称`() {
        val dA = "1111111111111111111111111111111111111111111111111111111111111111".hexBytes()
        val dB = "2222222222222222222222222222222222222222222222222222222222222222".hexBytes()
        val pubA = "04852611f744af045689dcfbf4c0437730d2d2de332ab7f0fc02769c5fab8a8943" +
            "7d9384f19ab882ed668a28936db92475aa79aef8690ee36f6fb77c69b9b571f8"
        val pubB = "044467e6043f38645e740050f3d6c9d6a0bf6b13d3b57892842be9b75cca3ce884" +
            "f0b5c27a16795142fa467fe6818cdb393c95f8e17d28f7e0a6557bbea8d65034"

        val a = LeapGMCrypto.sm2KAP("", dA, pubB.hexBytes())
        val b = LeapGMCrypto.sm2KAP("", dB, pubA.hexBytes())

        assertEquals(pubA, a.publicKey.hex())
        assertEquals(pubB, b.publicKey.hex())
        assertEquals("e47303abad8a4553a5b54af1774bd927e42e8b15bd8b896f197463a36e059881", a.sharedKey.hex())
        assertEquals("a5d56c4455e986f67d0c50fc9deb3147be1483744d9cb2e8e4fee8ce306b1179", b.sharedKey.hex())
        assertNotEquals(a.sharedKey.hex(), b.sharedKey.hex())
    }

    /// keyType=0 走的是标准 ECDH，共享密钥取协商点的 X——两端必须相等。
    @Test
    fun `P-256 ECDH 两端共享密钥相等`() {
        val dA = "3333333333333333333333333333333333333333333333333333333333333333".hexBytes()
        val dB = "4444444444444444444444444444444444444444444444444444444444444444".hexBytes()

        // 本端公钥只由私钥决定，与 peer 无关，所以先拿基点当占位算出两边的公钥。
        val pubA = LeapGMCrypto.ecdhP256(TestVectors.P256_BASE_POINT.hexBytes(), dA).publicKey
        val pubB = LeapGMCrypto.ecdhP256(TestVectors.P256_BASE_POINT.hexBytes(), dB).publicKey

        val a = LeapGMCrypto.ecdhP256(pubB, dA)
        val b = LeapGMCrypto.ecdhP256(pubA, dB)

        assertEquals(a.sharedKey.hex(), b.sharedKey.hex())
        assertEquals("5238f9f956812e75918895390fa057a2063aa66d4d5eefbe6ecdcf78342d2922", a.sharedKey.hex())
    }
}
