package org.yipao.app.core

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// 敏感数据落盘（对应 iOS 的 Keychain、鸿蒙的 Asset Store Kit）。
///
/// 安卓没有现成的等价物：`EncryptedSharedPreferences` 已被 Google 废弃不再维护，
/// 所以这里自己封一层——密钥生在 Android Keystore（永远不出安全硬件），
/// 值用 AES-256-GCM 加密后存进普通 SharedPreferences。
///
/// 密钥属性对齐 iOS 的 `AfterFirstUnlockThisDeviceOnly`：Keystore 密钥本身就不参与
/// 云备份、不能导出、换机后失效，语义天然一致，不用额外声明。
object SecureVault {

    private const val KEY_ALIAS = "org.yipao.app.vault"
    private const val PREFS_NAME = "leap-secure"
    private const val GCM_TAG_BITS = 128
    private const val IV_BYTES = 12

    private val prefs: SharedPreferences
        get() = AppEnv.prefs(PREFS_NAME)

    /// 读的三种结局。「没有」和「读不到」必须分开。
    ///
    /// iOS 那边踩过的坑（见 auth-audit 归因）：把「这次读不到」定论成「没登录」，
    /// 用户就会莫名其妙被退出登录。安卓的对应场景是 Keystore 暂时不可用
    /// （直接启动加密阶段被拉起、安全硬件忙），那时候条目还在，只是这一次解不开。
    sealed class Outcome {
        data class Found(val value: String) : Outcome()

        /// 从没存过、已清除，或者密文永久解不开（换机 / 恢复备份后 Keystore 密钥已丢失）。
        /// 后者重试也救不回来，重新登录即自愈，所以和「没有」归成一类。
        data object Missing : Outcome()

        /// 其它异常：这一次没读到，不代表没有。
        data class Failure(val reason: String) : Outcome()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                // 不要求用户认证：会话要在锁屏状态下被小组件/磁贴读到。
                // 需要生物识别的是「取出操作密码」那一步，那道门在 BiometricGate，不在这里。
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    fun read(name: String): Outcome {
        val stored = prefs.getString(name, null) ?: return Outcome.Missing
        return try {
            val blob = LeapCrypto.base64Decode(stored)
            if (blob.size <= IV_BYTES) return Outcome.Missing
            val iv = blob.copyOfRange(0, IV_BYTES)
            val cipherText = blob.copyOfRange(IV_BYTES, blob.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
            Outcome.Found(LeapCrypto.utf8(cipher.doFinal(cipherText)))
        } catch (e: AEADBadTagException) {
            // 密文和密钥对不上——换机恢复了备份，或者密钥被系统重建过。永久坏数据。
            DiagLog.note("[vault] $name 密文校验失败，按未存过处理")
            Outcome.Missing
        } catch (e: UnrecoverableKeyException) {
            DiagLog.note("[vault] $name 密钥已不可用，按未存过处理")
            Outcome.Missing
        } catch (e: Exception) {
            Outcome.Failure(LeapError.messageOf(e))
        }
    }

    /// 写失败必须让上层知道——否则用户勾了「记住密码」，下次还是被要求手输，却看不到原因。
    fun write(name: String, value: String): Boolean = try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val cipherText = cipher.doFinal(LeapCrypto.utf8(value))
        val blob = cipher.iv + cipherText
        prefs.edit().putString(name, LeapCrypto.base64Encode(blob)).commit()
    } catch (e: Exception) {
        DiagLog.note("[vault] 写入 $name 失败：${LeapError.messageOf(e)}")
        false
    }

    fun remove(name: String) {
        prefs.edit().remove(name).commit()
    }

    /// 按前缀批量清除。给「退登要连坐清掉所有车的蓝牙钥匙」用：
    /// 条目是按「账号|VIN」分开存的，退登时手里未必还有那份车辆列表。
    fun removeByPrefix(prefix: String) {
        val editor = prefs.edit()
        prefs.all.keys.filter { it.startsWith(prefix) }.forEach { editor.remove(it) }
        editor.commit()
    }
}
