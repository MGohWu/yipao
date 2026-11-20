package org.yipao.app.app

import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal
import org.yipao.app.core.AppEnv
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/// 生物识别门。对应 iOS 的 Face ID / Touch ID 那道闸：
/// 已经把操作密码记在本机时，用指纹/人脸代替每次手输。
///
/// 用的是系统框架的 `BiometricPrompt`（API 28 起，minSdk 31 全都有），
/// 不引 `androidx.biometric`——那个要求宿主是 `FragmentActivity`，
/// 而这个 App 的 `MainActivity` 是纯 Compose 的 `ComponentActivity`。
///
/// 接受系统登记的生物识别（`BIOMETRIC_WEAK`，也包含强指纹）。部分 ColorOS 机型的
/// 系统人脸只上报便捷级强度；只认 STRONG 会出现“密码能保存、却永远没有复用入口”。
/// 这里仍然必须经过系统 BiometricPrompt，不接受单纯的锁屏滑动或无验证直发。
object BiometricGate {

    enum class Kind {
        None,
        Fingerprint,
        Face,
        Iris;

        val label: String
            get() = when (this) {
                None -> "生物识别"
                Fingerprint -> "指纹"
                Face -> "人脸识别"
                Iris -> "虹膜"
            }
    }

    /// 这台设备当前能不能用。**已录入**才算数——有指纹传感器但一个指纹都没录，
    /// 弹出来的只会是一条错误。
    val available: Kind
        get() {
            val manager = AppEnv.context.getSystemService(BiometricManager::class.java)
                ?: return Kind.None
            // 兜一层：这个调用要 USE_BIOMETRIC（清单里已经声明），但厂商 ROM 上还见过
            // 别的 SecurityException 变体。问一句「有没有指纹」不值得把整个设置页崩掉。
            val status = runCatching {
                manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            }.getOrNull() ?: return Kind.None
            if (status != BiometricManager.BIOMETRIC_SUCCESS) return Kind.None
            val packages = AppEnv.context.packageManager
            return when {
                packages.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT) -> Kind.Fingerprint
                packages.hasSystemFeature(PackageManager.FEATURE_FACE) -> Kind.Face
                packages.hasSystemFeature(PackageManager.FEATURE_IRIS) -> Kind.Iris
                // 能过 canAuthenticate 却报不出具体形态（部分厂商 ROM），仍然可用。
                else -> Kind.Fingerprint
            }
        }

    /// 弹系统验证框。返回是否通过；用户取消、识别失败、没有前台 Activity 都算不通过。
    ///
    /// 不通过不静默丢指令——调用方会退回手输操作密码那条路。
    suspend fun authenticate(reason: String): Boolean {
        val activity = AppEnv.currentActivity ?: return false
        if (available == Kind.None) return false
        return suspendCancellableCoroutine { continuation ->
            val cancellation = CancellationSignal()
            continuation.invokeOnCancellation { cancellation.cancel() }
            val prompt = BiometricPrompt.Builder(activity)
                .setTitle("身份验证")
                .setSubtitle(reason)
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
                // 不给「使用密码」的系统入口：那条路验的是锁屏密码，
                // 而这里要放行的是操作密码，两者不是一回事。取消后由 App 自己弹密码键盘。
                .setNegativeButton("取消", activity.mainExecutor) { _, _ -> }
                .build()
            prompt.authenticate(
                cancellation,
                activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult?) {
                        if (continuation.isActive) continuation.resume(true)
                    }

                    override fun onAuthenticationError(code: Int, message: CharSequence?) {
                        if (continuation.isActive) continuation.resume(false)
                    }

                    /// 单次比对没过（换根手指再试）不结束流程，系统框自己会继续等。
                    override fun onAuthenticationFailed() = Unit
                },
            )
        }
    }
}
