package org.yipao.app.core

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import java.lang.ref.WeakReference

/// 全局 `Context` 的落脚点。
///
/// 存在的理由：数据层（会话存储、审计日志、标定映射）不该为了拿一个 `Context` 就把
/// 参数一路从 Activity 传下去——iOS 那边这些类型是无参构造的，安卓要保持同样的调用
/// 形状，只能在 `Application.onCreate` 里装一次。
object AppEnv {

    private lateinit var app: Context

    private var activityRef: WeakReference<Activity>? = null

    /// 由 `LeapApplication.onCreate` 调一次，必须早于任何一次数据层访问。
    fun install(context: Context) {
        app = context.applicationContext
        (app as? Application)?.registerActivityLifecycleCallbacks(ActivityWatcher)
    }

    /// 当前在前台的 Activity。系统级弹窗（生物识别验证框）必须挂在 Activity 上，
    /// 拿 application context 弹不出来。弱引用持有，不拦住回收。
    val currentActivity: Activity? get() = activityRef?.get()

    private object ActivityWatcher : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            activityRef = WeakReference(activity)
        }

        override fun onActivityPaused(activity: Activity) {
            if (activityRef?.get() === activity) activityRef = null
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    val context: Context get() = app

    /// 单元测试和极早期回调里可能还没装上，读之前先问一句。
    val isInstalled: Boolean get() = ::app.isInitialized

    /// 展示用版本号（设置页页脚、诊断日志里的环境信息）。
    /// 从包信息里读而不是 BuildConfig：那东西默认不生成，为一个字符串开它不划算。
    val versionName: String
        get() = runCatching {
            app.packageManager.getPackageInfo(app.packageName, 0).versionName
        }.getOrNull().orEmpty().ifEmpty { "1.0" }

    val versionCode: Long
        get() = runCatching {
            app.packageManager.getPackageInfo(app.packageName, 0).longVersionCode
        }.getOrDefault(0L)

    /// 非敏感的普通偏好（标定映射、界面开关）。token 一类走 `SecureVault`。
    fun prefs(name: String): SharedPreferences =
        app.getSharedPreferences(name, Context.MODE_PRIVATE)
}
