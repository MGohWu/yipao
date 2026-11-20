package org.yipao.app.app

import org.yipao.app.BuildConfig
import org.yipao.app.core.AppEnv
import org.yipao.app.core.VehicleState
import java.io.File

/// 本地核对用的演示车况叠加层，对应 iOS `App/DemoData.swift`（那边是 `-demo -screen xxx` 启动参数）。
///
/// **只在 Debug 包里生效**。Release 下 [screen] 恒为 null，审核用的 `ReviewDemo` 一个字都不变——
/// 那份演示车立的是 C11，凭空给它加二排座椅和冰箱就是在造车况。
///
/// 用法（模拟器上已用演示账号登录过）：
/// ```
/// adb shell run-as org.yipao.app sh -c 'echo cabin > files/demo-screen'
/// ```
/// 再冷启动 App。可选词：`cabin` `fridge` `charging` `features` `unlocked` `roof`；
/// 再追加一行 `lab` 时功能页按正式目录显示（演示账号默认只给「常用功能」三项）。
/// 删掉文件即恢复。值取自车主 C16 的真实信号 ID，档位是随手摆的几种状态，方便一屏看全。
object DemoData {
    private val words: List<String>
        get() {
            if (!BuildConfig.DEBUG || !AppEnv.isInstalled) return emptyList()
            return runCatching {
                File(AppEnv.context.filesDir, "demo-screen").readLines().map { it.trim() }.filter { it.isNotEmpty() }
            }.getOrDefault(emptyList())
        }

    val screen: String? get() = words.firstOrNull { it != "lab" }

    /// 演示账号下也按正式目录显示功能页（iOS 的 `-lab`）。
    val showsLabCatalog: Boolean get() = "lab" in words

    fun overlay(state: VehicleState): VehicleState {
        val extra: Map<String, String> = when (screen) {
            "cabin" -> mapOf(
                "2100" to "3", "2101" to "0",   // 主驾加热 3 档
                "2118" to "1", "2119" to "2",   // 副驾加热 1 档、通风 2 档
                "1879" to "0", "3727" to "0",
                "1880" to "2", "3728" to "0",   // 二排右加热 2 档
                "1816" to "1", "1624" to "12",  // 方向盘弱档，约剩 12 分钟
                "49" to "1", "50" to "1", "1946" to "1",
            )
            "fridge" -> mapOf(
                "10709" to "1", "10708" to "0", "10707" to "4", "10711" to "0", "10712" to "0",
                "11190" to "1", "11189" to "2", "11191" to "0",
                "11260" to (System.currentTimeMillis() / 1000 + 2 * 3600).toString(),
            )
            // 插着慢充枪、没在充：能源页应该摆出「开始充电」+「解锁充电枪」。
            "charging" -> mapOf("47" to "1", "1149" to "0")
            // 充电中：能源页只给「停止充电」。
            "chargingnow" -> mapOf("47" to "1", "1149" to "1")
            // 功能页：座舱、冰箱信号都叠上，让「座舱」组两个入口都出来（要配 `lab`）。
            "features" -> mapOf(
                "2100" to "0", "2101" to "0", "2118" to "0", "2119" to "0",
                "1816" to "0", "49" to "0", "50" to "0",
                "10709" to "0", "10708" to "0", "10707" to "4",
            )
            // 首页控车条：车没锁时「解锁」那格亮琥珀色、「上锁」不上色。
            "unlocked" -> mapOf("1298" to "0")
            // 首页天窗 / 遮阳帘徽章：天窗开到底、遮阳帘全开，右后窗开着。
            "roof" -> mapOf("1718" to "10", "1724" to "100", "1696" to "2")
            else -> emptyMap()
        }
        if (extra.isEmpty()) return state
        return state.copy(signalMap = state.signalMap + extra)
    }
}
