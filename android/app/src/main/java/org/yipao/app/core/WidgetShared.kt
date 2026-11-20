package org.yipao.app.core

/// 小组件 / 磁贴 / 常驻通知这三处「App 界面之外的表面」共享的存储与判据。
/// 对齐 iOS `SnapshotStore` + `SharedSettings` + `WidgetControlFeedback` + `LeapDeepLink`。

/// 卡片按钮、磁贴、通知按钮能触发的动作。
enum class WidgetAction(val rawValue: String, val label: String) {
    ToggleLock("toggleLock", "车锁"),
    ToggleClimate("toggleClimate", "空调"),
    Trunk("trunk", "尾门"),
    Horn("horn", "鸣笛寻车"),
    Lock("lock", "上锁车辆"),
    Unlock("unlock", "解锁车辆");

    companion object {
        fun of(rawValue: String?): WidgetAction? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

object WidgetButtonLayout {
    val defaults = listOf(WidgetAction.ToggleLock, WidgetAction.ToggleClimate, WidgetAction.Trunk, WidgetAction.Horn)

    fun normalize(raw: List<String>, small: Boolean): List<WidgetAction> =
        (raw.mapNotNull(WidgetAction::of) + defaults).distinct().take(if (small) 2 else 4)

    fun replacing(actions: List<WidgetAction>, index: Int, action: WidgetAction): List<WidgetAction> =
        actions.toMutableList().apply {
            val previous = indexOf(action)
            if (previous >= 0) this[previous] = this[index]
            this[index] = action
        }

    fun moving(actions: List<WidgetAction>, from: Int, to: Int): List<WidgetAction> {
        if (from !in actions.indices || to !in actions.indices || from == to) return actions
        return actions.toMutableList().apply { add(to, removeAt(from)) }
    }
}

/// 快照落盘。**只放非敏感的展示数据**，token 和操作密码始终在 `SecureVault`。
object SnapshotStore {

    private const val PREFS_NAME = "leap-widget"
    private const val KEY = "vehicle.snapshot"

    private val prefs get() = AppEnv.prefs(PREFS_NAME)

    fun read(): VehicleSnapshot? =
        prefs.getString(KEY, null)?.let { VehicleSnapshot.fromJson(it) }

    /// 用 `commit` 而不是 `apply`：写完紧接着就要通知小组件重画，异步落盘的话
    /// 那一侧可能读到上一份，卡片会闪一下旧值再跳回来。
    fun write(snapshot: VehicleSnapshot) {
        prefs.edit().putString(KEY, snapshot.toJson()).commit()
    }

    fun clear() {
        prefs.edit().remove(KEY).commit()
    }
}

/// App 与卡片共享的偏好。
object WidgetSettings {

    private const val PREFS_NAME = "leap-widget"
    private const val DIRECT_CONTROL_KEY = "directControlEnabled"
    private const val ERROR_KEY = "lastControlError"
    private const val ERROR_AT_KEY = "lastControlErrorAt"
    private const val PENDING_ACTION_KEY = "pendingWidgetAction"
    private const val PENDING_ACTION_AT_KEY = "pendingWidgetActionAt"

    private val prefs get() = AppEnv.prefs(PREFS_NAME)

    /// 桌面小组件、快捷磁贴和常驻通知是否允许直接下发控车指令。
    ///
    /// 关闭时（默认），按钮只是打开 App，由 App 走生物识别 + 操作密码的完整流程。
    /// 打开后会用本机已保存的操作密码直接下发——这三处表面都弹不出生物识别弹窗
    /// （磁贴和通知根本没有宿主界面），所以这等于把「控车」的门槛降到「手机已解锁」。
    /// 这是个真实的安全折衷，必须用户自己选。
    var directControlEnabled: Boolean
        get() = prefs.getBoolean(DIRECT_CONTROL_KEY, false)
        set(value) {
            prefs.edit().putBoolean(DIRECT_CONTROL_KEY, value).commit()
        }

    fun buttons(small: Boolean): List<WidgetAction> = WidgetButtonLayout.normalize(
        prefs.getString(if (small) "smallWidgetButtons" else "widgetButtons", null)
            ?.split(',').orEmpty(),
        small,
    )

    fun setButtons(small: Boolean, actions: List<WidgetAction>) {
        val normalized = WidgetButtonLayout.normalize(actions.map { it.rawValue }, small)
        prefs.edit().putString(
            if (small) "smallWidgetButtons" else "widgetButtons",
            normalized.joinToString(",") { it.rawValue },
        ).commit()
    }

    /// 上一次直接下发失败的原因，和失败时刻。
    ///
    /// 这三处表面失败是**没有出口**的：卡片弹不了 toast，磁贴和通知也没法把 App
    /// 顶到前台。不记下来的话，用户按一下、屏幕上什么都不发生，连「是不是我没按到」
    /// 都判断不了。
    val lastControlError: Pair<String, Long>?
        get() {
            val text = prefs.getString(ERROR_KEY, null) ?: return null
            return text to prefs.getLong(ERROR_AT_KEY, 0L)
        }

    /// 记一条失败；传 null 表示这次成功了，把上一条抹掉。
    fun recordControlError(text: String?) {
        val editor = prefs.edit()
        if (text == null) {
            editor.remove(ERROR_KEY).remove(ERROR_AT_KEY)
        } else {
            editor.putString(ERROR_KEY, text).putLong(ERROR_AT_KEY, System.currentTimeMillis())
        }
        editor.commit()
    }

    /// 留给 App 下次启动时接手的动作。
    ///
    /// 过期窗口一分钟：动作是用户按下那一刻的意图，隔了几小时再执行，
    /// 车门会在他毫无预期的时候自己开。
    const val PENDING_ACTION_WINDOW_MS = 60_000L

    /// 取走待办动作（取一次就没了）。超时的直接丢。
    fun consumePendingAction(): WidgetAction? {
        val raw = prefs.getString(PENDING_ACTION_KEY, null) ?: return null
        val at = prefs.getLong(PENDING_ACTION_AT_KEY, 0L)
        prefs.edit().remove(PENDING_ACTION_KEY).remove(PENDING_ACTION_AT_KEY).commit()
        if (System.currentTimeMillis() - at > PENDING_ACTION_WINDOW_MS) return null
        return WidgetAction.of(raw)
    }

    fun setPendingAction(action: WidgetAction) {
        prefs.edit()
            .putString(PENDING_ACTION_KEY, action.rawValue)
            .putLong(PENDING_ACTION_AT_KEY, System.currentTimeMillis())
            .commit()
    }
}

/// 卡片和磁贴上那句「刚才那下没成」。
object WidgetControlFeedback {

    /// 过了这么久就不再顶在卡片上了。一条五分钟前的失败还占着卡片顶部那行字，
    /// 只会把真正的车况挤掉。
    const val WINDOW_MS = 300_000L

    /// 还该被顶在卡片上的失败原因，没有就是 null。
    val recentFailure: String?
        get() {
            val (text, at) = WidgetSettings.lastControlError ?: return null
            return text.takeIf { System.currentTimeMillis() - at < WINDOW_MS }
        }
}

/// 卡片 / 通知点击后要跳到哪一屏。和 iOS 用同一套 scheme，两端文档能对上。
object LeapDeepLink {
    const val SCHEME = "leapcontrol"
    private const val ACTION_HOST = "action"

    const val HOME = "$SCHEME://home"

    fun action(action: WidgetAction): String = "$SCHEME://$ACTION_HOST?a=${action.rawValue}"

    /// 取出控车动作；不是控车链接就返回 null。
    fun actionOf(uri: android.net.Uri?): WidgetAction? {
        if (uri == null || uri.scheme != SCHEME || uri.host != ACTION_HOST) return null
        return WidgetAction.of(uri.getQueryParameter("a"))
    }
}
