package org.yipao.app.core

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/// 服务端返回的结构在不同接口之间差异很大，且会随 App 版本变化。
/// 这里用一个动态 JSON 表示，配合深度查找，避免为每个接口硬写模型。
///
/// 与 iOS 侧 `JSONValue.swift`、鸿蒙侧 `JsonValue.ets` 一一对应。
sealed class JsonValue {
    data class Str(val value: String) : JsonValue()
    data class Num(val value: Double) : JsonValue()
    data class Bool(val value: Boolean) : JsonValue()

    /// 键的插入顺序要保留：诊断日志按原样打印时，和抓包对照才对得上。
    data class Obj(val value: Map<String, JsonValue>) : JsonValue()
    data class Arr(val value: List<JsonValue>) : JsonValue()
    data object Null : JsonValue()

    companion object {
        fun of(value: String): JsonValue = Str(value)
        fun of(value: Double): JsonValue = Num(value)
        fun of(value: Int): JsonValue = Num(value.toDouble())
        fun of(value: Boolean): JsonValue = Bool(value)
        fun of(value: Map<String, JsonValue>): JsonValue = Obj(value)
        fun of(value: List<JsonValue>): JsonValue = Arr(value)

        /// 从 JSON 文本解析。解析失败返回 null。
        fun parse(text: String): JsonValue? = try {
            fromRaw(JSONTokener(text).nextValue())
        } catch (e: Exception) {
            null
        }

        /// 从 org.json 的原始结果构造。
        fun fromRaw(raw: Any?): JsonValue = when (raw) {
            null, JSONObject.NULL -> Null
            is String -> Str(raw)
            is Boolean -> Bool(raw)
            is Number -> Num(raw.toDouble())
            is JSONObject -> {
                val map = LinkedHashMap<String, JsonValue>(raw.length())
                val keys = raw.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    map[key] = fromRaw(raw.opt(key))
                }
                Obj(map)
            }

            is JSONArray -> Arr((0 until raw.length()).map { fromRaw(raw.opt(it)) })
            else -> Str(raw.toString())
        }
    }

    /// 取对象字段，非对象或字段不存在返回 null。
    fun get(key: String): JsonValue? = (this as? Obj)?.value?.get(key)

    /// 连续取多层字段。
    fun path(vararg keys: String): JsonValue? {
        var current: JsonValue? = this
        for (key in keys) {
            current = current?.get(key) ?: return null
        }
        return current
    }

    val objectValue: Map<String, JsonValue>? get() = (this as? Obj)?.value

    val arrayValue: List<JsonValue>? get() = (this as? Arr)?.value

    /// 数字、布尔、字符串统一转成字符串，方便直接参与签名和展示。
    val stringValue: String?
        get() = when (this) {
            is Str -> value
            is Bool -> if (value) "true" else "false"
            is Num -> {
                // 整数别渲染成 "1.0"：这些值要直接进签名串，多一个小数点就 result=39。
                if (value == Math.rint(value) && Math.abs(value) < 1e15) {
                    value.toLong().toString()
                } else {
                    value.toString()
                }
            }

            else -> null
        }

    val intValue: Int?
        get() = when (this) {
            is Num -> value.toInt()
            is Str -> value.trim().toDoubleOrNull()?.toInt()
            is Bool -> if (value) 1 else 0
            else -> null
        }

    val longValue: Long?
        get() = when (this) {
            is Num -> value.toLong()
            is Str -> value.trim().toDoubleOrNull()?.toLong()
            is Bool -> if (value) 1L else 0L
            else -> null
        }

    val doubleValue: Double?
        get() = when (this) {
            is Num -> value
            is Str -> value.trim().toDoubleOrNull()
            is Bool -> if (value) 1.0 else 0.0
            else -> null
        }

    val boolValue: Boolean?
        get() = when (this) {
            is Bool -> value
            is Num -> value != 0.0
            is Str -> when (value.lowercase()) {
                "true", "1" -> true
                "false", "0" -> false
                else -> null
            }

            else -> null
        }

    /// 深度优先查找第一个满足条件的对象节点。
    fun firstObject(predicate: (Map<String, JsonValue>) -> Boolean): Map<String, JsonValue>? {
        when (this) {
            is Obj -> {
                if (predicate(value)) return value
                for (child in value.values) {
                    child.firstObject(predicate)?.let { return it }
                }
            }

            is Arr -> {
                for (item in value) {
                    item.firstObject(predicate)?.let { return it }
                }
            }

            else -> Unit
        }
        return null
    }

    /// 收集所有满足条件的对象节点。
    fun allObjects(predicate: (Map<String, JsonValue>) -> Boolean): List<Map<String, JsonValue>> {
        val out = mutableListOf<Map<String, JsonValue>>()
        collectObjects(predicate, out)
        return out
    }

    private fun collectObjects(
        predicate: (Map<String, JsonValue>) -> Boolean,
        out: MutableList<Map<String, JsonValue>>,
    ) {
        when (this) {
            is Obj -> {
                if (predicate(value)) out.add(value)
                for (child in value.values) child.collectObjects(predicate, out)
            }

            is Arr -> for (item in value) item.collectObjects(predicate, out)
            else -> Unit
        }
    }

    /// 接口返回码：code / result / status 任一存在即可。
    val responseCode: String?
        get() {
            for (key in arrayOf("code", "result", "status")) {
                get(key)?.stringValue?.let { return it }
            }
            return null
        }

    val responseMessage: String
        get() {
            for (key in arrayOf("msg", "message", "error")) {
                val value = get(key)?.stringValue
                if (!value.isNullOrEmpty()) return value
            }
            return ""
        }

    val isSuccess: Boolean
        get() {
            if ((get("success") as? Bool)?.value == true) return true
            val code = responseCode ?: return true
            return code == "0" || code == "200"
        }

    /// 排查用的可读文本。键排序，方便两次响应直接对比。
    val prettyPrinted: String
        get() = try {
            when (val plain = toPlain()) {
                is JSONObject -> plain.toString(2)
                is JSONArray -> plain.toString(2)
                else -> plain?.toString() ?: "null"
            }
        } catch (e: Exception) {
            "(无法序列化)"
        }

    /// 紧凑序列化，用于落盘。
    val compactText: String
        get() = try {
            toPlain()?.toString() ?: "null"
        } catch (e: Exception) {
            "null"
        }

    /// 还原成 org.json 值（对象键按字典序），用于序列化。
    fun toPlain(): Any? = when (this) {
        is Str -> value
        is Num -> if (value == Math.rint(value) && Math.abs(value) < 1e15) value.toLong() else value
        is Bool -> value
        Null -> JSONObject.NULL
        is Arr -> JSONArray().also { array -> value.forEach { array.put(it.toPlain()) } }
        is Obj -> JSONObject().also { obj ->
            value.keys.sorted().forEach { key -> obj.put(key, value[key]?.toPlain()) }
        }
    }
}
