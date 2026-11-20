package org.yipao.app.core

/// 本机标定学到的信号映射，按车型存。
///
/// 零跑没有公开信号表，新车型的字段名只能靠「做一个动作、看哪个字段变了」反推。
/// 标定页把反推结果存在这里，`LeapClient.fetchVehicleState` 每次都叠到检测出来的
/// 体系上（`SignalSchema.merging`），学到的键优先级最高。
object LearnedSignals {

    private const val PREFS = "leap-calibration"
    private const val KEY = "calibration.learned"

    /// 存的是 `{车型: {信号名: 字段名}}` 的 JSON。
    private fun load(): Map<String, Map<String, String>> {
        if (!AppEnv.isInstalled) return emptyMap()
        val text = AppEnv.prefs(PREFS).getString(KEY, null) ?: return emptyMap()
        val root = JsonValue.parse(text)?.objectValue ?: return emptyMap()
        return root.mapValues { (_, byCarType) ->
            byCarType.objectValue.orEmpty().mapNotNull { (signal, key) ->
                key.stringValue?.let { signal to it }
            }.toMap()
        }
    }

    private fun store(all: Map<String, Map<String, String>>) {
        if (!AppEnv.isInstalled) return
        val root = all.mapValues { (_, entries) ->
            JsonValue.of(entries.mapValues { JsonValue.of(it.value) })
        }
        AppEnv.prefs(PREFS).edit().putString(KEY, JsonValue.of(root).compactText).apply()
    }

    fun keys(carType: String): Map<VehicleSignal, String> {
        if (carType.isEmpty()) return emptyMap()
        val stored = load()[carType.uppercase()] ?: return emptyMap()
        return stored.mapNotNull { (name, key) ->
            runCatching { VehicleSignal.valueOf(name) }.getOrNull()?.let { it to key }
        }.toMap()
    }

    fun save(learned: Map<VehicleSignal, String>, carType: String) {
        if (carType.isEmpty() || learned.isEmpty()) return
        val all = load().toMutableMap()
        // 与已有的合并：分几次标定完也能累加，不会把上次的成果冲掉。
        val merged = (all[carType.uppercase()] ?: emptyMap()).toMutableMap()
        for ((signal, key) in learned) merged[signal.name] = key
        all[carType.uppercase()] = merged
        store(all)
    }

    fun clear(carType: String) {
        val all = load().toMutableMap()
        all.remove(carType.uppercase())
        store(all)
    }
}
