package org.yipao.app.core

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/// 登录态审计日志：落在应用私有目录里的一个纯文本文件，只存在本机。
///
/// 存在的理由：「莫名其妙被退出登录」这类问题，等发现时现场早没了——
/// 到底是续期被服务端拒了、启动那帧密钥库没读到、还是被官方 App 挤下线，
/// 只有当时那次运行自己知道。这里把每一次登录态的关键变化（退登及其原因、
/// 续期被拒详情、存储读取失败、自愈恢复、采纳更新的凭证）都留一行痕。
///
/// 隐私：写入方负责脱敏——VIN 走 `DiagLog.maskVin`，token / 手机号一律不进这里。
///
/// 与 iOS 的差异：那边 App 和卡片扩展是**两个进程**，所以用 `O_APPEND` 追加、
/// 还要处理文件保护等级导致的打不开。安卓的小组件和快捷设置磁贴默认跑在应用
/// 自己的进程里（清单里没声明 `android:process`），既没有跨进程撕裂问题，也没有
/// 「锁屏期间打不开文件」这一说，所以这里就是最朴素的同步追加。
object AuthAuditLog {

    /// 超过这个大小就裁掉前半，只留最近的。日志是给人看的，几百行足够还原时间线。
    private const val MAX_BYTES = 128 * 1024
    private const val KEEP_BYTES = 64 * 1024

    private val timestamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)

    private val lock = Any()

    private val file: File?
        get() = if (AppEnv.isInstalled) File(AppEnv.context.filesDir, "auth-audit.log") else null

    /// 追加一行。同时走一遍 `DiagLog.note`，真机排查时两边能对上。
    fun note(text: String) {
        DiagLog.note("[audit] $text")
        val target = file ?: return
        synchronized(lock) {
            val line = "${timestamp.format(Date())} $text\n"
            try {
                target.appendText(line)
                trimIfNeeded(target)
            } catch (e: Exception) {
                // 日志写不进去不能反过来把业务打断，吞掉即可——DiagLog 那一份还在内存里。
                DiagLog.note("[audit] 写入失败：${LeapError.messageOf(e)}")
            }
        }
    }

    /// 有没有日志可读。只看文件大小，不把整份内容（上限 128KB）读进来。
    fun hasRecords(): Boolean = synchronized(lock) {
        val target = file ?: return false
        return try {
            target.exists() && target.length() > 0L
        } catch (e: Exception) {
            false
        }
    }

    /// 整个文件读出来。没有或读不到返回 null。
    fun dump(): String? = synchronized(lock) {
        val target = file ?: return null
        return try {
            target.takeIf { it.exists() }?.readText()?.takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            null
        }
    }

    fun clear() {
        synchronized(lock) { file?.delete() }
    }

    /// 文件长过头就裁到 `KEEP_BYTES`，从行边界开始留。
    private fun trimIfNeeded(target: File) {
        if (target.length() <= MAX_BYTES) return
        val tail = target.readBytes().let { it.copyOfRange(it.size - KEEP_BYTES, it.size) }
        val newline = tail.indexOf('\n'.code.toByte())
        val body = if (newline >= 0) tail.copyOfRange(newline + 1, tail.size) else tail
        target.writeBytes(LeapCrypto.utf8("(更早的日志已裁剪)\n") + body)
    }
}
