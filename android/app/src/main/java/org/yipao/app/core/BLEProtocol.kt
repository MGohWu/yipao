package org.yipao.app.core

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Locale
import kotlin.random.Random

/// 零跑蓝牙钥匙协议中已经由实车抓包确认的常量与帧结构。逐行对齐 iOS `BLEProtocol.swift`。
object LeapBLEProtocol {
    const val SERVICE_UUID = "0000FFFE-0000-1000-8000-00805F9B34FB"
    const val CHARACTERISTIC_UUID = "0000FFF2-0000-1000-8000-00805F9B34FB"

    /// `passwordCard` 按 16 个 5 字节切片取值，服务端材料必须覆盖完整范围。
    const val MINIMUM_PASSWORD_CARD_BYTE_COUNT = 80

    /// 防止损坏的长度字段让重组器无限等待或吃掉过多内存。
    const val MAXIMUM_FRAME_LENGTH = 1_048_576

    /// 官方目前有两条可用的蓝牙证书密码路径；其它值必须在认证前拒绝。
    fun supportsKeyType(keyType: Int): Boolean = keyType == 0 || keyType == 1

    fun decodeReconnectToken(token: String): ByteArray {
        if (token.isEmpty() || token.length % 2 != 0 || token.length > 1_024) {
            throw LeapBLEProtocolError.invalidFrame("重连 token 不是有效的偶数长度 Hex")
        }
        val result = ByteArray(token.length / 2)
        for (index in result.indices) {
            val value = token.substring(index * 2, index * 2 + 2).toIntOrNull(16)
                ?: throw LeapBLEProtocolError.invalidFrame("重连 token 包含非 Hex 字符")
            result[index] = value.toByte()
        }
        return result
    }
}

class LeapBLEProtocolError(override val message: String) : Exception(message) {
    companion object {
        fun unsupportedKeyType(value: Int) =
            LeapBLEProtocolError("暂不支持的蓝牙证书类型（keyType=$value）")

        fun invalidCertificate(reason: String) = LeapBLEProtocolError("蓝牙证书无效：$reason")

        fun invalidFrame(reason: String) = LeapBLEProtocolError("蓝牙帧无效：$reason")

        fun cryptoFailure(reason: String) = LeapBLEProtocolError("蓝牙加解密失败：$reason")
    }
}

/// `syncBluetoothKeys` 返回的每车蓝牙钥匙证书。字段都属于认证材料，必须进加密存储。
data class LeapBLEKeyCertificate(
    val ecdhPublicKey: String,
    val keyType: Int,
    val passwordCard: String,
    val plainText: String,
    val signResult: String,
    val vin: String,
) {
    /// 只取指纹进日志。证书本体任何一段都不许出现在诊断日志里。
    val fingerprint: String
        get() = LeapCrypto.toHex(
            MessageDigest.getInstance("SHA-256")
                .digest(LeapCrypto.utf8(ecdhPublicKey + signResult))
                .copyOf(6),
        )

    val isSupportedKeyType: Boolean get() = LeapBLEProtocol.supportsKeyType(keyType)

    /// 官方 Java 按字符切片，当前协议要求这些字符是一字节 ASCII。
    val hasValidPasswordCard: Boolean
        get() = passwordCard.length >= LeapBLEProtocol.MINIMUM_PASSWORD_CARD_BYTE_COUNT &&
            passwordCard.all { it.code <= 0x7F }

    fun validatePasswordCard() {
        if (!hasValidPasswordCard) {
            throw LeapBLEProtocolError.invalidCertificate("passwordCard 必须是至少 80 字节的 ASCII 字符串")
        }
    }

    fun toJson(): String = JSONObject()
        .put("ecdhPublicKey", ecdhPublicKey)
        .put("keyType", keyType)
        .put("passwordCard", passwordCard)
        .put("plainText", plainText)
        .put("signResult", signResult)
        .put("vin", vin)
        .toString()

    companion object {
        private fun isCertificateNode(node: Map<String, JsonValue>): Boolean =
            node["ecdhPublicKey"] != null &&
                node["passwordCard"] != null &&
                node["plainText"] != null &&
                node["signResult"] != null

        fun from(json: JsonValue): LeapBLEKeyCertificate? {
            // 官方 DTO 同时返回 bluetoothKey/mobileControl；BLE 认证只能使用前者。
            val bluetoothKey = json.path("data", "bluetoothKey") ?: json.get("bluetoothKey")
            val node = (bluetoothKey ?: json).firstObject(::isCertificateNode) ?: return null
            return LeapBLEKeyCertificate(
                ecdhPublicKey = node["ecdhPublicKey"]?.stringValue ?: return null,
                // 老接口曾省略该字段；兼容时按官方老款路径处理。显式未知值仍由会话创建拒绝。
                keyType = node["keyType"]?.intValue ?: 0,
                passwordCard = node["passwordCard"]?.stringValue ?: return null,
                plainText = node["plainText"]?.stringValue ?: return null,
                signResult = node["signResult"]?.stringValue ?: return null,
                vin = node["vin"]?.stringValue.orEmpty(),
            )
        }

        fun fromStorage(text: String): LeapBLEKeyCertificate? {
            val node = JsonValue.parse(text)?.objectValue ?: return null
            return LeapBLEKeyCertificate(
                ecdhPublicKey = node["ecdhPublicKey"]?.stringValue ?: return null,
                keyType = node["keyType"]?.intValue ?: 0,
                passwordCard = node["passwordCard"]?.stringValue ?: return null,
                plainText = node["plainText"]?.stringValue ?: return null,
                signResult = node["signResult"]?.stringValue ?: return null,
                vin = node["vin"]?.stringValue.orEmpty(),
            )
        }
    }
}

enum class LeapBLEControlCommand(val code: Int) {
    Unlock(1),
    Lock(2);

    val label: String get() = if (this == Unlock) "解锁" else "闭锁"
}

enum class StraightMoveDirection(val code: Int) {
    Forward(1),
    Backward(2);

    val label: String get() = if (this == Forward) "向前" else "向后"
}

enum class StraightMoveOrder(val code: Int) {
    Forward(1),
    Backward(2),
    Stop(3);

    val label: String
        get() = when (this) {
            Forward -> "直进"
            Backward -> "直出"
            Stop -> "停止挪车"
        }

    companion object {
        fun of(direction: StraightMoveDirection): StraightMoveOrder =
            if (direction == StraightMoveDirection.Forward) Forward else Backward
    }
}

/// 官方 1.9 重连明文中的 9 字节蓝牙钥匙配置。
data class LeapBLEConfiguration(
    val distanceCalibration: Int,
    val coefficientHundredths: Int,
    val unlockCalibration: Int,
    val lockCalibration: Int,
    val isEnabled: Boolean,
    val autoLockEnabled: Boolean,
    val autoUnlockEnabled: Boolean,
    val supportsButton: Boolean,
) {
    val calibrationText: String
        get() = "%d;%s;%02d;%02d".format(
            Locale.US,
            distanceCalibration,
            String.format(Locale.US, "%.2f", coefficientHundredths / 100.0),
            unlockCalibration,
            lockCalibration,
        )

    val bytes: ByteArray
        get() = buildBytes {
            write(distanceCalibration)
            leU16(coefficientHundredths)
            write(unlockCalibration)
            write(lockCalibration)
            write(if (isEnabled) 1 else 0)
            write(if (isEnabled && autoLockEnabled) 1 else 0)
            write(if (isEnabled && autoUnlockEnabled) 1 else 0)
            write(if (supportsButton) 1 else 0)
        }

    fun toJson(): JSONObject = JSONObject()
        .put("distanceCalibration", distanceCalibration)
        .put("coefficientHundredths", coefficientHundredths)
        .put("unlockCalibration", unlockCalibration)
        .put("lockCalibration", lockCalibration)
        .put("isEnabled", isEnabled)
        .put("autoLockEnabled", autoLockEnabled)
        .put("autoUnlockEnabled", autoUnlockEnabled)
        .put("supportsButton", supportsButton)

    companion object {
        val OFFICIAL_DEFAULT = LeapBLEConfiguration(
            distanceCalibration = 56,
            coefficientHundredths = 200,
            unlockCalibration = 8,
            lockCalibration = 16,
            isEnabled = true,
            autoLockEnabled = false,
            autoUnlockEnabled = true,
            supportsButton = true,
        )

        /// 首次只绑定蓝牙控车时使用。车辆仍接受手动指令，但不会自动解锁或闭锁。
        val MANUAL_CONTROL = OFFICIAL_DEFAULT.copy(autoUnlockEnabled = false)

        fun fromJson(node: Map<String, JsonValue>?): LeapBLEConfiguration? {
            if (node == null) return null
            fun flag(key: String) = node[key]?.boolValue
            return LeapBLEConfiguration(
                distanceCalibration = node["distanceCalibration"]?.intValue ?: return null,
                coefficientHundredths = node["coefficientHundredths"]?.intValue ?: return null,
                unlockCalibration = node["unlockCalibration"]?.intValue ?: return null,
                lockCalibration = node["lockCalibration"]?.intValue ?: return null,
                isEnabled = flag("isEnabled") ?: return null,
                autoLockEnabled = flag("autoLockEnabled") ?: return null,
                autoUnlockEnabled = flag("autoUnlockEnabled") ?: return null,
                supportsButton = flag("supportsButton") ?: return null,
            )
        }
    }
}

/// `AA AB` 解密后的分号文本。官方解析器至少要求类型和一个数据字段。
sealed class LeapBLEDecryptedResponse {
    data class Authentication(val lockState: String, val remainingFields: List<String>) :
        LeapBLEDecryptedResponse()

    data class ReconnectToken(val token: String) : LeapBLEDecryptedResponse()

    data class Command(
        val identifier: String,
        val result: String?,
        val remainingFields: List<String>,
    ) : LeapBLEDecryptedResponse()

    data class Other(val type: String, val fields: List<String>) : LeapBLEDecryptedResponse()

    companion object {
        fun from(data: ByteArray): LeapBLEDecryptedResponse? {
            if (data.isEmpty()) return null
            val text = LeapCrypto.utf8(data)
            if (text.isEmpty()) return null
            val fields = text.split(";")
            if (fields.size < 2) return null
            return when (fields[0]) {
                "0" -> if (fields[1].isEmpty()) null else {
                    Authentication(fields[1], fields.drop(2))
                }
                "1" -> {
                    runCatching { LeapBLEProtocol.decodeReconnectToken(fields[1]) }.getOrNull()
                        ?: return null
                    ReconnectToken(fields[1])
                }
                "2" -> Command(
                    identifier = fields[1],
                    result = fields.getOrNull(2),
                    remainingFields = if (fields.size > 3) fields.drop(3) else emptyList(),
                )
                else -> Other(fields[0], fields.drop(1))
            }
        }
    }
}

/// 一次 GATT 连接内使用的会话密钥。临时私钥完成协商后立即丢弃，只保留 key/iv。
class LeapBLECryptoSession private constructor(
    val sessionID: Long,
    val publicKey: ByteArray,
    private val key: ByteArray,
    private val iv: ByteArray,
    private val usesSM: Boolean,
) {

    /// 官方 1.9 协议的完整认证帧（`AA AE`）。
    fun fullAuthenticationFrame(
        certificate: LeapBLEKeyCertificate,
        accountId: String,
        deviceId: String,
        timestamp: Long = System.currentTimeMillis() / 1000,
        configuration: LeapBLEConfiguration = LeapBLEConfiguration.OFFICIAL_DEFAULT,
    ): ByteArray {
        val certificateFields = certificate.plainText.split(";")
        if (certificateFields.size < 6) {
            throw LeapBLEProtocolError.invalidCertificate("plainText 字段不足 6 项")
        }
        if (accountId.isEmpty() || deviceId.isEmpty() ||
            accountId.contains(";") || deviceId.contains(";")
        ) {
            throw LeapBLEProtocolError.invalidCertificate("账号或设备标识为空/含分隔符")
        }
        val signature = LeapCrypto.base64Decode(certificate.signResult)
        if (signature.isEmpty()) {
            throw LeapBLEProtocolError.invalidCertificate("signResult 不是有效 Base64")
        }

        // 官方 1.9 明文在时间戳后保留一个空字段，末尾的 1 是 isSupportBtn。
        // 这两处是 resultCode=9 的根因，缺一个车端就拒认——不要「顺手清理」。
        val authText = listOf(
            timestamp.toString(), "", accountId, deviceId,
            certificateFields[3], certificateFields[4], certificateFields[5],
            configuration.calibrationText,
            if (configuration.isEnabled) "1" else "0",
            if (configuration.isEnabled && configuration.autoLockEnabled) "1" else "0",
            if (configuration.isEnabled && configuration.autoUnlockEnabled) "1" else "0",
            if (configuration.supportsButton) "1" else "0",
            "",
        ).joinToString(";")
        val authTextData = LeapCrypto.utf8(authText)
        val plain = buildBytes {
            leU32(authTextData.size.toLong())
            write(authTextData)
            write(signature)
        }

        val encodedCipher = LeapCrypto.utf8(LeapCrypto.base64Encode(encrypt(plain)))
        val payload = buildBytes {
            leU32(sessionID)
            write(publicKey)
            write(encodedCipher)
            write(0x01)
            write(0x09)
        }
        if (payload.size > 0xFFFF) throw LeapBLEProtocolError.invalidFrame("认证载荷过长")

        return buildBytes {
            write(0xAA)
            write(LeapBLEFrameKind.FullAuthentication.code)
            leU16(payload.size)
            write(payload)
        }
    }

    /// 官方 1.9 token 快速重连帧（`AA EE`）。
    fun reconnectAuthenticationFrame(
        token: String,
        accountId: String,
        configuration: LeapBLEConfiguration = LeapBLEConfiguration.OFFICIAL_DEFAULT,
        timestamp: Long = System.currentTimeMillis() / 1000,
    ): ByteArray {
        val tokenData = LeapBLEProtocol.decodeReconnectToken(token)
        val accountData = LeapCrypto.utf8(accountId)
        if (accountData.isEmpty() || accountData.size > 0xFFFF) {
            throw LeapBLEProtocolError.invalidCertificate("账号为空或长度超过 UInt16")
        }
        val plain = buildBytes {
            leU64(timestamp)
            write(tokenData)
            write(configuration.bytes)
            leU16(accountData.size)
            write(accountData)
        }
        return reconnectFrame(
            sessionID = sessionID,
            publicKey = publicKey,
            encodedCipher = LeapCrypto.utf8(LeapCrypto.base64Encode(encrypt(plain))),
            usesSM3 = usesSM,
        )
    }

    fun controlFrame(
        command: LeapBLEControlCommand,
        timestamp: Long = System.currentTimeMillis() / 1000,
    ): ByteArray = encryptedCommandFrame(command.code, ByteArray(0), timestamp)

    /// 已认证连接内下发命令 `3`，让车辆更新无感钥匙配置。
    fun configurationFrame(
        configuration: LeapBLEConfiguration,
        timestamp: Long = System.currentTimeMillis() / 1000,
    ): ByteArray = encryptedCommandFrame(3, configuration.bytes, timestamp)

    fun callCarAuthenticationFrame(certificate: LeapBLEKeyCertificate, accountId: String, deviceId: String,
        timestamp: Long = System.currentTimeMillis() / 1000): ByteArray {
        val fields = certificate.plainText.split(";").toMutableList()
        require(fields.size >= 6 && accountId.isNotEmpty() && deviceId.isNotEmpty() &&
            !accountId.contains(';') && !deviceId.contains(';')) { "直进直出证书无效" }
        fields[1] = accountId; fields[2] = deviceId
        val text = LeapCrypto.utf8("$timestamp;${fields.joinToString(";")};")
        val signature = LeapCrypto.base64Decode(certificate.signResult)
        require(signature.isNotEmpty()) { "直进直出证书签名无效" }
        val cipher = LeapCrypto.utf8(LeapCrypto.base64Encode(encrypt(buildBytes {
            leU32(text.size.toLong()); write(text); write(signature)
        })))
        require(cipher.size + 69 <= 65535)
        return buildBytes {
            write(byteArrayOf(0xAA.toByte(), 0xAE.toByte(), 1, 1, 10))
            leU16(cipher.size + 69); leU32(sessionID); write(publicKey); write(cipher)
        }
    }

    fun callCarOrderFrame(order: Int): ByteArray {
        val cipher = LeapCrypto.utf8(LeapCrypto.base64Encode(encrypt(byteArrayOf(order.toByte()))))
        return buildBytes { write(0xAA); write(0xAB); leU32(cipher.size.toLong()); write(cipher) }
    }

    /// 直进直出使用独立明文：只有一个 order 字节，没有 RKE 的 CRC、时间戳和 cmdID。
    fun straightMoveFrame(order: StraightMoveOrder): ByteArray {
        val encodedCipher = LeapCrypto.utf8(
            LeapCrypto.base64Encode(encrypt(byteArrayOf(order.code.toByte()))),
        )
        return buildBytes {
            write(0xAA)
            write(LeapBLEFrameKind.Encrypted.code)
            leU32(encodedCipher.size.toLong())
            write(encodedCipher)
        }
    }

    private fun encryptedCommandFrame(
        commandID: Int,
        payload: ByteArray,
        timestamp: Long,
    ): ByteArray {
        val body = buildBytes {
            leU64(timestamp)
            write(commandID)
            write(payload)
        }
        val framed = byteArrayOf(crc8(body)) + body
        val encodedCipher = LeapCrypto.utf8(LeapCrypto.base64Encode(encrypt(framed)))
        return buildBytes {
            write(0xAA)
            write(LeapBLEFrameKind.Encrypted.code)
            leU32(encodedCipher.size.toLong())
            write(encodedCipher)
        }
    }

    fun decrypt(frame: LeapBLEFrame): ByteArray {
        if (frame.kind != LeapBLEFrameKind.Encrypted) {
            throw LeapBLEProtocolError.invalidFrame("只有 AA AB 帧可解密")
        }
        val cipher = LeapCrypto.base64Decode(LeapCrypto.utf8(frame.payload).trim())
        if (cipher.isEmpty()) {
            throw LeapBLEProtocolError.invalidFrame("AA AB 载荷不是有效 Base64")
        }
        return if (usesSM) {
            LeapGMCrypto.sm4Decrypt(cipher, key, iv)
        } else {
            aes(cipher, encrypting = false)
        }
    }

    private fun encrypt(data: ByteArray): ByteArray = if (usesSM) {
        LeapGMCrypto.sm4Encrypt(data, key, iv)
    } else {
        aes(data, encrypting = true)
    }

    private fun aes(data: ByteArray, encrypting: Boolean): ByteArray = try {
        val cipher = javax.crypto.Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(
            if (encrypting) javax.crypto.Cipher.ENCRYPT_MODE else javax.crypto.Cipher.DECRYPT_MODE,
            javax.crypto.spec.SecretKeySpec(key, "AES"),
            javax.crypto.spec.IvParameterSpec(iv),
        )
        cipher.doFinal(data)
    } catch (e: Exception) {
        throw LeapBLEProtocolError.cryptoFailure("AES-CBC 失败：${LeapError.messageOf(e)}")
    }

    companion object {

        fun make(
            certificate: LeapBLEKeyCertificate,
            vin: String,
            requestedSessionID: Long? = null,
            privateKeyRaw: ByteArray? = null,
            smPeerPublicKeyX963: ByteArray? = null,
        ): LeapBLECryptoSession {
            if (certificate.vin.isNotEmpty() && certificate.vin != vin) {
                throw LeapBLEProtocolError.invalidCertificate("证书 VIN 与当前车辆不一致")
            }
            certificate.validatePasswordCard()

            val agreement: LeapGMCrypto.Agreement
            val usesSM: Boolean
            when (certificate.keyType) {
                0 -> {
                    val peer = LeapCrypto.base64Decode(certificate.ecdhPublicKey)
                    agreement = LeapGMCrypto.ecdhP256(peer, privateKeyRaw)
                    usesSM = false
                }
                1 -> {
                    agreement = LeapGMCrypto.sm2KAP(
                        certificatePEM = certificate.ecdhPublicKey,
                        privateKey = privateKeyRaw,
                        peerPublicKeyX963 = smPeerPublicKeyX963,
                    )
                    usesSM = true
                }
                else -> throw LeapBLEProtocolError.unsupportedKeyType(certificate.keyType)
            }

            val sessionID = requestedSessionID ?: Random.nextLong(10_000, 10_010_000)
            val indexMaterial = buildBytes {
                leU32(sessionID)
                write(LeapCrypto.utf8(vin.reversed()))
            }
            val indexDigest = if (usesSM) {
                LeapGMCrypto.sm3(indexMaterial)
            } else {
                MessageDigest.getInstance("SHA-256").digest(indexMaterial)
            }
            val cardIndex = (indexDigest[0].toInt() and 0xFF) shr 4
            val start = cardIndex * 5
            val passwordBytes = LeapCrypto.utf8(certificate.passwordCard)

            val keyMaterial = passwordBytes.copyOfRange(start, start + 5) + agreement.sharedKey
            val digest = if (usesSM) {
                LeapGMCrypto.sm3(keyMaterial)
            } else {
                MessageDigest.getInstance("SHA-256").digest(keyMaterial)
            }
            val digestHex = LeapCrypto.toHex(digest)
            return LeapBLECryptoSession(
                sessionID = sessionID,
                publicKey = agreement.publicKey,
                key = LeapCrypto.utf8(digestHex.take(16)),
                iv = LeapCrypto.utf8(digestHex.takeLast(16)),
                usesSM = usesSM,
            )
        }

        /// 独立保留组帧步骤，便于直接对照官方 App 运行时固定向量。
        fun reconnectFrame(
            sessionID: Long,
            publicKey: ByteArray,
            encodedCipher: ByteArray,
            usesSM3: Boolean,
        ): ByteArray {
            if (publicKey.size != 65 || publicKey[0] != 0x04.toByte()) {
                throw LeapBLEProtocolError.invalidFrame("重连公钥不是 65 字节未压缩公钥")
            }
            if (encodedCipher.isEmpty()) {
                throw LeapBLEProtocolError.invalidFrame("重连密文为空")
            }
            val payloadLength = 4 + publicKey.size + encodedCipher.size + 2 + 16
            if (payloadLength > 0xFFFF) throw LeapBLEProtocolError.invalidFrame("重连载荷过长")

            val head = buildBytes {
                write(0xAA)
                write(LeapBLEFrameKind.ReconnectAuthentication.code)
                leU16(payloadLength)
                leU32(sessionID)
                write(publicKey)
                write(encodedCipher)
                write(0x01)
                write(0x09)
            }
            val digest = if (usesSM3) {
                LeapGMCrypto.sm3(head)
            } else {
                MessageDigest.getInstance("SHA-256").digest(head)
            }
            if (digest.size < 16) throw LeapBLEProtocolError.cryptoFailure("重连摘要不足 16 字节")
            return head + digest.copyOf(16)
        }

        /// XOR 型 CRC8，多项式 0x07。
        fun crc8(data: ByteArray): Byte {
            var crc = 0
            for (byte in data) {
                crc = crc xor (byte.toInt() and 0xFF)
                repeat(8) {
                    crc = if (crc and 0x80 != 0) ((crc shl 1) xor 0x07) and 0xFF else (crc shl 1) and 0xFF
                }
            }
            return crc.toByte()
        }
    }
}

enum class LeapBLEFrameKind(val code: Int) {
    Encrypted(0xAB),
    Event(0xAC),
    FullAuthentication(0xAE),
    ReconnectAuthentication(0xEE);

    val label: String
        get() = when (this) {
            Encrypted -> "AA AB"
            Event -> "AA AC"
            FullAuthentication -> "AA AE"
            ReconnectAuthentication -> "AA EE"
        }

    companion object {
        fun of(code: Int): LeapBLEFrameKind? = entries.firstOrNull { it.code == code }
    }
}

class LeapBLEFrame(
    val kind: LeapBLEFrameKind,
    val declaredPayloadLength: Int,
    val bytes: ByteArray,
) {
    val payload: ByteArray
        get() {
            val offset = when (kind) {
                LeapBLEFrameKind.Encrypted -> 6
                LeapBLEFrameKind.Event -> 10
                LeapBLEFrameKind.FullAuthentication, LeapBLEFrameKind.ReconnectAuthentication -> 4
            }
            if (bytes.size <= offset) return ByteArray(0)
            return bytes.copyOfRange(offset, bytes.size)
        }

    val event: LeapBLEEvent? get() = LeapBLEEvent.from(this)

    /// 载荷是密文/明文指令，只有开了「记录原始帧」才允许落日志。
    fun logDetail(includingPayload: Boolean): String = if (includingPayload) {
        "hex=${LeapCrypto.toHex(bytes).uppercase()}"
    } else {
        "header=${LeapCrypto.toHex(bytes.copyOf(minOf(2, bytes.size))).uppercase()} " +
            "payload=<已隐藏 ${payload.size} bytes>"
    }
}

/// `AA AC` 的明文事件。这里只解释已经由官方字符串表和实车时序交叉确认的值。
sealed class LeapBLEEvent {
    data class ErrorResponse(val resultCode: Int, val payload: ByteArray) : LeapBLEEvent()

    data class LockOperation(val crc8: Int, val trigger: Trigger, val operation: Operation) :
        LeapBLEEvent()

    data class AreaChange(val crc8: Int, val area: Area) : LeapBLEEvent()

    data class Other(val messageType: Int, val payload: ByteArray) : LeapBLEEvent()

    enum class Trigger { None, Active, Passive, Button, Unknown;

        val label: String
            get() = when (this) {
                None -> "无触发"
                Active -> "有感"
                Passive -> "无感"
                Button -> "按钮"
                Unknown -> "未知触发"
            }

        companion object {
            fun of(value: Int) = when (value) {
                0 -> None
                1 -> Active
                2 -> Passive
                3 -> Button
                else -> Unknown
            }
        }
    }

    enum class Operation { None, Unlock, Lock, Unknown;

        val label: String
            get() = when (this) {
                None -> "无操作"
                Unlock -> "解锁"
                Lock -> "闭锁"
                Unknown -> "未知操作"
            }

        companion object {
            fun of(value: Int) = when (value) {
                0 -> None
                1 -> Unlock
                2 -> Lock
                else -> Unknown
            }
        }
    }

    enum class Area { Unlock, TrendLock, Unknown;

        val label: String
            get() = when (this) {
                Unlock -> "进入解锁区域"
                TrendLock -> "进入趋势闭锁区域"
                Unknown -> "未知区域"
            }

        companion object {
            fun of(value: Int) = when (value) {
                1 -> Unlock
                3 -> TrendLock
                else -> Unknown
            }
        }
    }

    val summary: String
        get() = when (this) {
            is ErrorResponse -> "错误应答：resultCode=$resultCode"
            is LockOperation ->
                "解闭锁事件：${trigger.label} / ${operation.label}，CRC8=%02X".format(crc8)
            is AreaChange -> "区域事件：${area.label}，CRC8=%02X".format(crc8)
            is Other -> "未解析事件：type=$messageType，payload=${payload.size} bytes"
        }

    companion object {
        fun from(frame: LeapBLEFrame): LeapBLEEvent? {
            if (frame.kind != LeapBLEFrameKind.Event || frame.bytes.size < 10) return null
            val messageType = frame.bytes[5].toInt() and 0xFF
            val payload = frame.payload
            fun at(index: Int) = payload[index].toInt() and 0xFF
            return when {
                messageType == 1 && payload.isNotEmpty() ->
                    ErrorResponse(payload.last().toInt() and 0xFF, payload)
                messageType == 2 && payload.size >= 3 ->
                    LockOperation(at(0), Trigger.of(at(1)), Operation.of(at(2)))
                messageType == 3 && payload.size >= 2 -> AreaChange(at(0), Area.of(at(1)))
                else -> Other(messageType, payload)
            }
        }
    }
}

/// 一次 GATT 通知不等于一帧；认证帧也会按 MTU 拆成多个分片。
class LeapBLEFrameReassembler {
    private var buffer = ArrayList<Byte>()

    val bufferedByteCount: Int get() = buffer.size

    fun reset() {
        buffer = ArrayList()
    }

    fun append(data: ByteArray): List<LeapBLEFrame> {
        for (byte in data) buffer.add(byte)
        val frames = ArrayList<LeapBLEFrame>()

        while (true) {
            if (!alignToFrameHeader()) break
            val description = expectedFrameDescription() ?: break

            if (description.total > LeapBLEProtocol.MAXIMUM_FRAME_LENGTH) {
                buffer.removeAt(0)
                continue
            }
            if (buffer.size < description.total) break

            val total = description.total.toInt()
            val raw = ByteArray(total) { buffer[it] }
            frames.add(LeapBLEFrame(description.kind, description.declared, raw))
            buffer.subList(0, total).clear()
        }
        return frames
    }

    /// [total] 用 Long：长度字段是攻击面上的 32 位无符号数，`6 + length` 用 Int 算会溢出成负数，
    /// 溢出后既躲过上面那道超长闸、又让 `ByteArray(total)` 直接抛 NegativeArraySize。
    private class Description(val kind: LeapBLEFrameKind, val declared: Int, val total: Long)

    /// 丢弃帧头前的噪声；末尾单独一个 AA 留给下一分片继续匹配。
    private fun alignToFrameHeader(): Boolean {
        if (buffer.size < 2) return false
        val start = (0 until buffer.size - 1).firstOrNull { index ->
            byteAt(index) == 0xAA && LeapBLEFrameKind.of(byteAt(index + 1)) != null
        }
        if (start == null) {
            buffer = if (byteAt(buffer.size - 1) == 0xAA) {
                arrayListOf(0xAA.toByte())
            } else {
                ArrayList()
            }
            return false
        }
        if (start > 0) buffer.subList(0, start).clear()
        return true
    }

    private fun expectedFrameDescription(): Description? {
        if (buffer.size < 2) return null
        val kind = LeapBLEFrameKind.of(byteAt(1)) ?: return null
        return when (kind) {
            LeapBLEFrameKind.Encrypted -> {
                if (buffer.size < 6) return null
                val length = leU32At(2)
                Description(kind, declaredOf(length), 6 + length)
            }
            LeapBLEFrameKind.Event -> {
                if (buffer.size < 10) return null
                val length = leU32At(6)
                Description(kind, declaredOf(length), 10 + length)
            }
            LeapBLEFrameKind.FullAuthentication, LeapBLEFrameKind.ReconnectAuthentication -> {
                if (buffer.size < 4) return null
                val length = byteAt(2) or (byteAt(3) shl 8)
                Description(kind, length, 4L + length)
            }
        }
    }

    private fun byteAt(index: Int): Int = buffer[index].toInt() and 0xFF

    /// 只有过了超长闸的帧才会被真正取出来，那时 declared 一定在 Int 范围内；
    /// 这里的钳位纯粹是为了让越界的坏值也有个确定取值，不参与判定。
    private fun declaredOf(length: Long): Int =
        if (length > LeapBLEProtocol.MAXIMUM_FRAME_LENGTH) LeapBLEProtocol.MAXIMUM_FRAME_LENGTH else length.toInt()

    /// 长度字段是 32 位无符号数，一路按 Long 传到超长闸那里，中途不做截断——
    /// 截断成 Int.MAX_VALUE 会让后面的 `6 + length` 反而溢出。
    private fun leU32At(offset: Int): Long =
        byteAt(offset).toLong() or
            (byteAt(offset + 1).toLong() shl 8) or
            (byteAt(offset + 2).toLong() shl 16) or
            (byteAt(offset + 3).toLong() shl 24)
}

// —— 小工具：小端写入 ——

internal fun buildBytes(block: ByteArrayOutputStream.() -> Unit): ByteArray =
    ByteArrayOutputStream().apply(block).toByteArray()

internal fun ByteArrayOutputStream.leU16(value: Int) {
    write(value and 0xFF)
    write((value ushr 8) and 0xFF)
}

internal fun ByteArrayOutputStream.leU32(value: Long) {
    for (shift in 0 until 32 step 8) write(((value ushr shift) and 0xFF).toInt())
}

internal fun ByteArrayOutputStream.leU64(value: Long) {
    for (shift in 0 until 64 step 8) write(((value ushr shift) and 0xFF).toInt())
}
