package org.yipao.app.core

import org.bouncycastle.asn1.gm.GMNamedCurves
import org.bouncycastle.asn1.sec.SECNamedCurves
import org.bouncycastle.asn1.x509.Certificate
import org.bouncycastle.crypto.digests.SM3Digest
import org.bouncycastle.crypto.engines.SM4Engine
import org.bouncycastle.crypto.modes.CBCBlockCipher
import org.bouncycastle.crypto.paddings.PKCS7Padding
import org.bouncycastle.crypto.paddings.PaddedBufferedBlockCipher
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV
import org.bouncycastle.math.ec.ECPoint
import org.bouncycastle.util.BigIntegers
import java.math.BigInteger
import java.security.SecureRandom

/// 国密与 P-256 的原语层，对应 iOS 的 `LeapGMCrypto`（那边是 GmSSL 的 C 封装）。
///
/// 安卓没有 GmSSL，这里用 BouncyCastle 的低层 API 逐行重写 `LeapGMCrypto.c`。
/// **不能改用 BC 现成的 `SM2KeyExchange`**：标准 SM2 KAP 分发起方/响应方、静态密钥和
/// 临时密钥是两把，而车端这套把同一把密钥同时当静态和临时用，KDF 的输入也只有
/// `x‖y‖Z_self‖Z_peer` 四段。用标准实现算出来的共享密钥和车端对不上，
/// 表现是认证帧发出去石沉大海——所以这里照抄 C 的算式，一步不省。
object LeapGMCrypto {

    class Agreement(val publicKey: ByteArray, val sharedKey: ByteArray)

    /// GmSSL 的 `SM2_DEFAULT_ID`，Z 值计算用。ENTL 是它的**比特**长度。
    private val DEFAULT_ID = LeapCrypto.utf8("1234567812345678")

    private val sm2 = GMNamedCurves.getByName("sm2p256v1")
    private val p256 = SECNamedCurves.getByName("secp256r1")
    private val random = SecureRandom()

    // ---- SM3 ----

    fun sm3(data: ByteArray): ByteArray {
        if (data.isEmpty()) throw LeapBLEProtocolError.cryptoFailure("SM3 输入为空")
        val digest = SM3Digest()
        digest.update(data, 0, data.size)
        val out = ByteArray(digest.digestSize)
        digest.doFinal(out, 0)
        return out
    }

    /// GB/T 32918 的 KDF：ct 从 1 开始，逐块 SM3(Z ‖ ct) 拼到够长。
    fun sm3KDF(material: ByteArray, length: Int): ByteArray {
        val out = ByteArray(length)
        val digest = SM3Digest()
        val block = ByteArray(digest.digestSize)
        var counter = 1
        var offset = 0
        while (offset < length) {
            digest.reset()
            digest.update(material, 0, material.size)
            digest.update((counter ushr 24).toByte())
            digest.update((counter ushr 16).toByte())
            digest.update((counter ushr 8).toByte())
            digest.update(counter.toByte())
            digest.doFinal(block, 0)
            val take = minOf(block.size, length - offset)
            System.arraycopy(block, 0, out, offset, take)
            offset += take
            counter += 1
        }
        return out
    }

    // ---- SM4-CBC/PKCS7 ----

    fun sm4Encrypt(data: ByteArray, key: ByteArray, iv: ByteArray): ByteArray =
        sm4(data, key, iv, encrypting = true)

    fun sm4Decrypt(data: ByteArray, key: ByteArray, iv: ByteArray): ByteArray =
        sm4(data, key, iv, encrypting = false)

    private fun sm4(data: ByteArray, key: ByteArray, iv: ByteArray, encrypting: Boolean): ByteArray {
        if (data.isEmpty() || key.size != 16 || iv.size != 16) {
            throw LeapBLEProtocolError.cryptoFailure("SM4 输入或 key/iv 长度无效")
        }
        val cipher = PaddedBufferedBlockCipher(CBCBlockCipher.newInstance(SM4Engine()), PKCS7Padding())
        cipher.init(encrypting, ParametersWithIV(KeyParameter(key), iv))
        val buffer = ByteArray(cipher.getOutputSize(data.size))
        return try {
            var moved = cipher.processBytes(data, 0, data.size, buffer, 0)
            moved += cipher.doFinal(buffer, moved)
            buffer.copyOf(moved)
        } catch (e: Exception) {
            throw LeapBLEProtocolError.cryptoFailure("SM4-CBC 失败：${LeapError.messageOf(e)}")
        }
    }

    // ---- SM2 密钥协商 ----

    /// [certificatePEM] 是车端证书（PEM 或裸 base64 的 X.509 DER）。
    /// [privateKey] / [peerPublicKeyX963] 只给测试用来固定随机量，正常调用传 null。
    fun sm2KAP(
        certificatePEM: String,
        privateKey: ByteArray? = null,
        peerPublicKeyX963: ByteArray? = null,
    ): Agreement {
        if (privateKey != null && privateKey.size != 32) {
            throw LeapBLEProtocolError.cryptoFailure("SM2 临时私钥不是 32 字节")
        }
        val peerPoint = if (peerPublicKeyX963 != null) {
            if (peerPublicKeyX963.size != 65 || peerPublicKeyX963[0] != 0x04.toByte()) {
                throw LeapBLEProtocolError.invalidCertificate("SM2 公钥不是 65 字节未压缩公钥")
            }
            decodePoint(peerPublicKeyX963)
        } else {
            certificatePublicKey(certificatePEM)
        }
        return kap(peerPoint, privateKey)
    }

    /// X.509 里的 SM2 公钥。不走 `CertificateFactory`：系统的 X.509 解析器不认 SM2 的曲线
    /// OID，会直接抛；而我们要的只是 subjectPublicKey 那段裸点，ASN.1 层拿得到。
    private fun certificatePublicKey(value: String): ECPoint {
        val encoded = if (value.contains("BEGIN CERTIFICATE")) {
            value.lineSequence().filterNot { it.startsWith("-----") }.joinToString("")
        } else {
            value
        }
        val der = LeapCrypto.base64Decode(encoded.filterNot { it.isWhitespace() })
        if (der.isEmpty()) {
            throw LeapBLEProtocolError.invalidCertificate("SM2 X.509 证书不是有效 PEM/Base64")
        }
        val bits = try {
            Certificate.getInstance(der).subjectPublicKeyInfo.publicKeyData.bytes
        } catch (e: Exception) {
            throw LeapBLEProtocolError.invalidCertificate("SM2 X.509 证书解析失败：${LeapError.messageOf(e)}")
        }
        return decodePoint(bits)
    }

    private fun decodePoint(encoded: ByteArray): ECPoint = try {
        sm2.curve.decodePoint(encoded).normalize().also {
            if (it.isInfinity || !it.isValid) {
                throw LeapBLEProtocolError.invalidCertificate("SM2 公钥不在曲线上")
            }
        }
    } catch (e: LeapBLEProtocolError) {
        throw e
    } catch (e: Exception) {
        throw LeapBLEProtocolError.invalidCertificate("SM2 公钥解析失败：${LeapError.messageOf(e)}")
    }

    private fun kap(peerPoint: ECPoint, privateKeyBytes: ByteArray?): Agreement {
        val n = sm2.n
        val d = if (privateKeyBytes != null) {
            BigInteger(1, privateKeyBytes).also {
                if (it.signum() <= 0 || it >= n) {
                    throw LeapBLEProtocolError.cryptoFailure("SM2 私钥不在 [1, n-1] 内")
                }
            }
        } else {
            randomScalar(n)
        }
        val selfPoint = sm2.g.multiply(d).normalize()

        // x̄ = 2^127 + (x mod 2^127)，C 里是「高 16 字节清零、低 16 字节保留、再置最高位」。
        val selfFactor = xBar(selfPoint).multiply(d).add(d).mod(n)
        val peerFactor = xBar(peerPoint).add(BigInteger.ONE).mod(n)

        val agreementPoint = peerPoint.multiply(peerFactor).normalize().multiply(selfFactor).normalize()
        if (agreementPoint.isInfinity) {
            throw LeapBLEProtocolError.cryptoFailure("SM2 协商结果为无穷远点")
        }

        val material = coordinate(agreementPoint.affineXCoord.toBigInteger()) +
            coordinate(agreementPoint.affineYCoord.toBigInteger()) +
            computeZ(selfPoint) +
            computeZ(peerPoint)

        val publicKey = ByteArray(65)
        publicKey[0] = 0x04
        System.arraycopy(coordinate(selfPoint.affineXCoord.toBigInteger()), 0, publicKey, 1, 32)
        System.arraycopy(coordinate(selfPoint.affineYCoord.toBigInteger()), 0, publicKey, 33, 32)
        return Agreement(publicKey, sm3KDF(material, 32))
    }

    private fun xBar(point: ECPoint): BigInteger {
        val x = coordinate(point.affineXCoord.toBigInteger())
        val bar = ByteArray(32)
        System.arraycopy(x, 16, bar, 16, 16)
        bar[16] = (bar[16].toInt() or 0x80).toByte()
        return BigInteger(1, bar)
    }

    /// Z = SM3(ENTL ‖ ID ‖ a ‖ b ‖ xG ‖ yG ‖ xA ‖ yA)
    private fun computeZ(point: ECPoint): ByteArray {
        val entlBits = DEFAULT_ID.size * 8
        val head = byteArrayOf((entlBits ushr 8).toByte(), entlBits.toByte())
        val g = sm2.g.normalize()
        return sm3(
            head + DEFAULT_ID +
                coordinate(sm2.curve.a.toBigInteger()) +
                coordinate(sm2.curve.b.toBigInteger()) +
                coordinate(g.affineXCoord.toBigInteger()) +
                coordinate(g.affineYCoord.toBigInteger()) +
                coordinate(point.affineXCoord.toBigInteger()) +
                coordinate(point.affineYCoord.toBigInteger()),
        )
    }

    // ---- P-256（keyType=0 的老款路径）----

    /// 生成一次性 P-256 密钥并与车端公钥做 ECDH。返回 (未压缩公钥, 共享密钥)。
    /// 共享密钥取协商点的 X 坐标——和 CryptoKit `sharedSecretFromKeyAgreement` 一致。
    fun ecdhP256(peerX963: ByteArray, privateKeyBytes: ByteArray? = null): Agreement {
        if (peerX963.size != 65 || peerX963[0] != 0x04.toByte()) {
            throw LeapBLEProtocolError.invalidCertificate("ECDH 公钥不是 65 字节 P-256 公钥")
        }
        val n = p256.n
        val d = if (privateKeyBytes != null) {
            if (privateKeyBytes.size != 32) {
                throw LeapBLEProtocolError.cryptoFailure("P-256 临时私钥不是 32 字节")
            }
            BigInteger(1, privateKeyBytes).also {
                if (it.signum() <= 0 || it >= n) {
                    throw LeapBLEProtocolError.cryptoFailure("P-256 私钥不在 [1, n-1] 内")
                }
            }
        } else {
            randomScalar(n)
        }
        val peerPoint = try {
            p256.curve.decodePoint(peerX963).normalize()
        } catch (e: Exception) {
            throw LeapBLEProtocolError.invalidCertificate("P-256 公钥解析失败：${LeapError.messageOf(e)}")
        }
        if (peerPoint.isInfinity || !peerPoint.isValid) {
            throw LeapBLEProtocolError.invalidCertificate("P-256 公钥不在曲线上")
        }
        val shared = peerPoint.multiply(d).normalize()
        if (shared.isInfinity) throw LeapBLEProtocolError.cryptoFailure("P-256 协商结果为无穷远点")

        val selfPoint = p256.g.multiply(d).normalize()
        val publicKey = ByteArray(65)
        publicKey[0] = 0x04
        System.arraycopy(coordinate(selfPoint.affineXCoord.toBigInteger()), 0, publicKey, 1, 32)
        System.arraycopy(coordinate(selfPoint.affineYCoord.toBigInteger()), 0, publicKey, 33, 32)
        return Agreement(publicKey, coordinate(shared.affineXCoord.toBigInteger()))
    }

    // ---- 小工具 ----

    private fun randomScalar(n: BigInteger): BigInteger {
        while (true) {
            val candidate = BigIntegers.createRandomBigInteger(n.bitLength(), random)
            if (candidate.signum() > 0 && candidate < n) return candidate
        }
    }

    /// 定长 32 字节大端。`BigInteger.toByteArray()` 会带符号位前缀或省略前导零，不能直接用。
    private fun coordinate(value: BigInteger): ByteArray =
        BigIntegers.asUnsignedByteArray(32, value)
}
