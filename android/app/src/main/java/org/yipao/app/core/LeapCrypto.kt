package org.yipao.app.core

import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/// 与 demo `src/leapmotor-cn-sdk.js` 中的签名/加密实现一一对应（经 iOS 版对拍固化）。
/// 任何一处偏差都会让服务端返回 result=39（信息校验失败），因此这里的字节级行为不可随意「优化」。
object LeapCrypto {

    private const val HEX_CHARS = "0123456789abcdef"
    private val random = SecureRandom()

    fun utf8(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

    fun utf8(data: ByteArray): String = String(data, Charsets.UTF_8)

    fun toHex(data: ByteArray): String {
        val out = StringBuilder(data.size * 2)
        for (byte in data) {
            val value = byte.toInt() and 0xff
            out.append(HEX_CHARS[value shr 4]).append(HEX_CHARS[value and 0x0f])
        }
        return out.toString()
    }

    // ---- 摘要 ----

    private fun digest(algorithm: String, data: ByteArray): ByteArray =
        MessageDigest.getInstance(algorithm).digest(data)

    fun md5Hex(data: ByteArray): String = toHex(digest("MD5", data))

    /// 老链路签名：md5(hex) 取 [8, 24)，即中间 16 个十六进制字符。
    fun shortMD5(input: String): String = md5Hex(utf8(input)).substring(8, 24)

    fun sha256Hex(input: String): String = toHex(digest("SHA-256", utf8(input)))

    fun hmacSHA256Hex(message: String, key: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return toHex(mac.doFinal(utf8(message)))
    }

    // ---- 签名串拼接 ----

    /// 合并若干字典，按 key 升序排列后把 value 直接首尾相接。
    /// 传入的 value 均为非空字符串，与 JS 侧「丢弃空值」的行为由调用方保证一致。
    fun sortAndConcatValues(vararg maps: Map<String, String>?): String {
        val merged = HashMap<String, String>()
        for (map in maps) {
            if (map == null) continue
            merged.putAll(map)
        }
        return merged.keys.sorted().joinToString("") { merged[it].orEmpty() }
    }

    // ---- Base64 / Base64URL ----

    fun base64Encode(data: ByteArray): String = Base64.getEncoder().encodeToString(data)

    fun base64Decode(text: String): ByteArray = try {
        Base64.getDecoder().decode(text)
    } catch (e: IllegalArgumentException) {
        ByteArray(0)
    }

    fun base64URLNoPadding(data: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(data)

    fun base64URLDecode(input: String): ByteArray {
        // 服务端给的 base64url 有带 padding 的也有不带的，统一补齐再按标准表解。
        var normalized = input.replace('-', '+').replace('_', '/')
        val remainder = normalized.length % 4
        if (remainder > 0) normalized += "====".substring(0, 4 - remainder)
        return base64Decode(normalized)
    }

    // ---- 手机号 RSA ----

    /// 零跑 App 内置的固定公钥（SPKI base64）。
    private const val PUBLIC_KEY_BASE64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB"

    /// App 规则：手机号用固定公钥 RSA/PKCS1 加密后转 base64url（无 padding）。
    /// JCA 的 X509EncodedKeySpec 直接吃 SPKI DER，不用像 iOS 那样手工剥头。
    fun phoneNoCiphertext(phone: String): String {
        val spki = base64Decode(PUBLIC_KEY_BASE64)
        if (spki.isEmpty()) throw LeapError.crypto("内置公钥解析失败")
        try {
            val key = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(spki))
            val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            return base64URLNoPadding(cipher.doFinal(utf8(phone)))
        } catch (e: Exception) {
            throw LeapError.crypto("手机号加密失败: ${LeapError.messageOf(e)}")
        }
    }

    // ---- signKey 推导 ----

    /// signKey = accessToken 第三段(base64url) XOR r2(base64) XOR r3(base64)，长度取三者最小值。
    fun deriveSignKey(accessToken: String, r2: String, r3: String): ByteArray {
        val parts = accessToken.split(".")
        if (parts.size != 3) throw LeapError.crypto("accessToken 不是三段式 token")
        val tail = base64URLDecode(parts[2])
        val r2Bytes = base64Decode(r2)
        val r3Bytes = base64Decode(r3)
        val length = minOf(tail.size, r2Bytes.size, r3Bytes.size)
        if (length <= 0) throw LeapError.crypto("signKey 素材为空")
        return ByteArray(length) { i -> (tail[i].toInt() xor r2Bytes[i].toInt() xor r3Bytes[i].toInt()).toByte() }
    }

    // ---- 操作密码 ----

    /// oppwd = AES-128-CBC(操作密码)，key/iv 由老 token 前后 32 字符各自求短 MD5 得到。
    fun encryptOperationPassword(password: String, oldToken: String): String {
        if (password.isEmpty()) return ""
        if (oldToken.length < 64) throw LeapError.crypto("旧 token 长度不足，无法加密操作密码")
        val key = utf8(shortMD5(oldToken.substring(0, 32)))
        val iv = utf8(shortMD5(oldToken.substring(32, 64)))
        try {
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            return base64Encode(cipher.doFinal(utf8(password)))
        } catch (e: Exception) {
            throw LeapError.crypto("操作密码加密失败 (${LeapError.messageOf(e)})")
        }
    }

    // ---- JWT ----

    /// 读取 JWT 的 exp（毫秒）。解不出来返回 0，调用方按「立即过期」处理。
    fun jwtExpiryMilliseconds(token: String): Long {
        val parts = token.split(".")
        if (parts.size != 3) return 0
        return try {
            val payload = JsonValue.parse(utf8(base64URLDecode(parts[1]))) ?: return 0
            val exp = payload.get("exp")?.doubleValue ?: return 0
            if (exp > 0) (exp * 1000).toLong() else 0
        } catch (e: Exception) {
            0
        }
    }

    fun randomNonce(): String = (10_000 + random.nextInt(10_000_000)).toString()
}
