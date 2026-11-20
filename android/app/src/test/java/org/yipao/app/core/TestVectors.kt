package org.yipao.app.core

/// 蓝牙相关单测共用的固定向量和小工具。
///
/// 这些向量全部来自 iOS `LeapControlTests/BLEProtocolTests.swift`，一字未改。
/// **双端必须逐字节一致**，所以不要「顺手」在这边重新算一遍期望值——
/// 对不上就是安卓这边有问题，不是向量该改。
object TestVectors {

    /// 固定临时私钥：31 个 0 后跟一个 1，也就是标量 1。
    /// 私钥固定，公钥就是 G，整条链路才有可复现的期望值。
    val fixedPrivateKey: ByteArray = ByteArray(32).also { it[31] = 1 }

    const val SM2_PEER_PUBLIC_KEY =
        "0456cefd60d7c87c000d58ef57fa73ba4d9c0dfa08c08a7331495c2e1da3f2bd52" +
            "31b7e7e6cc8189f668535ce0f8eaf1bd6de84c182f6c8e716f780d3a970a23c3"

    /// 标量 1 的公钥就是 SM2 的基点 G。
    const val SM2_LOCAL_PUBLIC_KEY =
        "0432c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7" +
            "bc3736a2f4f6779c59bdcee36b692153d0a9877cc62a474002df32e52139f0a0"

    val SM2_CERTIFICATE_PEM = """
        -----BEGIN CERTIFICATE-----
        MIIBhjCCASugAwIBAgIUTzck05zW50mkmjvS/cenk1gi1DkwCgYIKoEcz1UBg3Uw
        GDEWMBQGA1UEAwwNTGVhcCBCTEUgVGVzdDAeFw0yNjA4MTExMTI0MjRaFw0zNjA4
        MDgxMTI0MjRaMBgxFjAUBgNVBAMMDUxlYXAgQkxFIFRlc3QwWTATBgcqhkjOPQIB
        BggqgRzPVQGCLQNCAARm0r00h4HiOELHHY28UKYY8lX5SKf4LBHGmvWNa0KHsASd
        U0HR+dehjj+S2Lx09VidadPDi94ZFdcXF4jh9BhCo1MwUTAdBgNVHQ4EFgQUGukz
        fBVOWfRrTrtSw1Ir3aXscdwwHwYDVR0jBBgwFoAUGukzfBVOWfRrTrtSw1Ir3aXs
        cdwwDwYDVR0TAQH/BAUwAwEB/zAKBggqgRzPVQGDdQNJADBGAiEA6uBKX+5wjDkW
        JTdlQ1ELDYJqkYGOq+YnPZ7A7hM8cUMCIQDFAca3P6D583BC8j5q+Q1Udix210pb
        Vr72D+mN0HFPSg==
        -----END CERTIFICATE-----
    """.trimIndent()

    /// P-256 的基点 G（未压缩）。ECDH 用例拿它当合法 peer 占位。
    const val P256_BASE_POINT =
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
            "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"

    const val TEST_VIN = "TESTVIN1234567890"
    const val TEST_SESSION_ID = 0x001AB0D4L

    /// 官方 1.9 里 RKE 明文用的固定时间戳，小端展开正好是 08 07 06 05 04 03 02 01。
    const val FIXED_TIMESTAMP = 0x0102030405060708L

    /// keyType=0 的老款 P-256 证书。
    fun eccCertificate(): LeapBLEKeyCertificate = LeapBLEKeyCertificate(
        ecdhPublicKey =
            "BHzyexiNA09+ilI4AwS1GsPAiWnid/IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E=",
        keyType = 0,
        passwordCard = "0123456789".repeat(8),
        plainText = "a;b;c;d;e;f",
        signResult = LeapCrypto.base64Encode(ByteArray(64)),
        vin = TEST_VIN,
    )

    /// keyType=1 的国密证书。ecdhPublicKey 用不上——国密路径直接喂裸公钥向量。
    fun smCertificate(): LeapBLEKeyCertificate = LeapBLEKeyCertificate(
        ecdhPublicKey = "unused by raw vector",
        keyType = 1,
        passwordCard = "0123456789".repeat(8),
        plainText = "a;b;c;d;e;f",
        signResult = LeapCrypto.base64Encode(ByteArray(64)),
        vin = TEST_VIN,
    )

    fun eccSession(): LeapBLECryptoSession = LeapBLECryptoSession.make(
        certificate = eccCertificate(),
        vin = TEST_VIN,
        requestedSessionID = TEST_SESSION_ID,
        privateKeyRaw = fixedPrivateKey,
    )

    fun smSession(): LeapBLECryptoSession = LeapBLECryptoSession.make(
        certificate = smCertificate(),
        vin = TEST_VIN,
        requestedSessionID = TEST_SESSION_ID,
        privateKeyRaw = fixedPrivateKey,
        smPeerPublicKeyX963 = SM2_PEER_PUBLIC_KEY.hexBytes(),
    )
}

fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

fun String.hexBytes(): ByteArray {
    require(length % 2 == 0) { "Hex 长度不是偶数" }
    return ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

/// 把一段密文重新包成 `AA AB` 帧，好让 `decrypt` 能吃。
/// 认证帧里的密文段是嵌在 `AA AE` / `AA EE` 里的，直接解密不了。
fun encryptedFrameOf(cipher: ByteArray): ByteArray = buildBytes {
    write(0xAA)
    write(LeapBLEFrameKind.Encrypted.code)
    leU32(cipher.size.toLong())
    write(cipher)
}

/// 断言只重组出一帧，并把它取出来。
fun LeapBLEFrameReassembler.single(data: ByteArray): LeapBLEFrame {
    val frames = append(data)
    check(frames.size == 1) { "期望重组出 1 帧，实际 ${frames.size} 帧" }
    return frames[0]
}
