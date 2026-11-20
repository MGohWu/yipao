package org.yipao.app.core

import org.json.JSONArray
import org.json.JSONObject

/// 会话落加密存储。里面是 token、signKey 和 VIN，不能进普通 SharedPreferences。
///
/// 对应 iOS 的 `SessionStore`（Keychain）。安卓这边底座是 `SecureVault`
/// （Android Keystore 里的 AES-GCM 密钥 + 密文进 SharedPreferences）。
///
/// 序列化手写而不是上 kotlinx.serialization：一是不想为这一个结构多拉一个编译器插件，
/// 二是**字段缺失要能被感知**——`Vehicle` 的两个 stale 标志正是靠「JSON 里有没有这个键」
/// 判出来的，自动生成的解码器把缺失和默认值揉成了一件事，那个坑就永远看不见了。
class SessionStore {

    private val entry = "leap-session"

    /// 设备号单独存一条，不跟着会话 JSON 走。
    ///
    /// 它和 token 不是一类东西：token 会续期、会被别处换发，设备号则是登录那一刻上报给
    /// 服务端、被服务端拿去绑 token 的**唯一正确值**，一旦变了，老链路（远控、里程、位置）
    /// 就一律 `result=39`，且只有重新短信登录才解得开。
    ///
    /// 混在会话 JSON 里的问题是整份写回会盖它：任何一个手里拿着半截会话的入口
    /// （直接启动加密阶段被拉起、密钥库这一次读不到）一次 `save` 就能把它冲掉。
    /// 单独一条，读写都只经过 `loadDeviceId` / `saveDeviceId`，谁都盖不着。
    private val deviceIdEntry = "leap-device-id"

    /// 读存储的三种结局。「没有」和「读不到」必须分开：
    /// 把「这一次解不开」定论成「没登录」，用户就「莫名其妙被退出登录」了。
    /// 见 `SecureVault.Outcome` 上的同一段理由。
    sealed class LoadOutcome {
        data class Found(val session: LeapSession) : LoadOutcome()

        /// 从没存过、已退登，或者持久坏数据——重试救不了，重新登录即自愈。
        data object Missing : LoadOutcome()

        /// 其它异常：这一次没读到，不代表没有。
        data class Failure(val reason: String) : LoadOutcome()
    }

    fun loadOutcome(): LoadOutcome = when (val outcome = SecureVault.read(entry)) {
        is SecureVault.Outcome.Missing -> LoadOutcome.Missing
        is SecureVault.Outcome.Failure -> LoadOutcome.Failure(outcome.reason)
        is SecureVault.Outcome.Found -> {
            val session = decode(outcome.value)
            if (session == null) {
                // 解不出来按「没有」算：能读到密文说明密钥库没锁，坏的是数据本身，
                // 归进 Failure 会让调用方一直挂在「等一会儿再试」上。
                // 对用户这就是一次「莫名退登」，必须留痕——这份日志存在的目的就是给它归因。
                AuthAuditLog.note("[session] 会话条目在但解不出来（持久坏数据，${outcome.value.length} 字符），按未登录处理")
                LoadOutcome.Missing
            } else {
                // 设备号以单独那条为准；会话 JSON 里那份只是历史遗留（也可能已被谁盖空了）。
                val deviceId = loadDeviceId()
                when {
                    deviceId != null -> LoadOutcome.Found(session.copy(deviceId = deviceId))
                    session.deviceId.isNotEmpty() -> {
                        // 老用户第一次走到这：把会话里那个搬进单独条目，之后就再也不会被盖。
                        saveDeviceId(session.deviceId)
                        LoadOutcome.Found(session)
                    }
                    else -> LoadOutcome.Found(session)
                }
            }
        }
    }

    fun load(): LeapSession? = (loadOutcome() as? LoadOutcome.Found)?.session

    /// 单独那条设备号。读不到（没有 / 密钥库这次不可用）都返回 null——
    /// 调用方一律按「这次拿不到」处理，绝不能据此发一个新设备号。
    fun loadDeviceId(): String? =
        (SecureVault.read(deviceIdEntry) as? SecureVault.Outcome.Found)?.value?.takeIf { it.isNotEmpty() }

    /// 写单独那条设备号。空值一律不写：那只会把真的那个抹掉。
    fun saveDeviceId(deviceId: String) {
        if (deviceId.isEmpty()) return
        SecureVault.write(deviceIdEntry, deviceId)
    }

    fun save(session: LeapSession) {
        // 单独那条跟着一起更新（空值不写，见 `saveDeviceId`）。
        saveDeviceId(session.deviceId)
        SecureVault.write(entry, encode(session))
    }

    /// 只清会话，**不动设备号**。
    ///
    /// 设备号不是登录态的一部分，是这台手机的身份。退登后留着它，下次登录仍用同一个设备号
    /// 去绑——服务端那边不会多出一台设备，也少一次「新设备登录」的风控。
    fun clear() {
        SecureVault.remove(entry)
    }

    fun clearDeviceId() {
        SecureVault.remove(deviceIdEntry)
    }

    // MARK: - 编解码

    private fun encode(session: LeapSession): String {
        val root = JSONObject()
        root.put("deviceId", session.deviceId)
        root.put("appVersion", session.appVersion)
        root.put("subVersion", session.subVersion)
        root.put("phone", session.phone)
        session.oldAuth?.let { root.put("oldAuth", encodeOldAuth(it)) }
        session.newAuth?.let { root.put("newAuth", encodeNewAuth(it)) }
        root.put("vehicles", JSONArray().apply {
            session.vehicles.forEach { put(encodeVehicle(it)) }
        })
        root.put("selectedVin", session.selectedVin)
        root.put("selectedCarType", session.selectedCarType)
        session.selectedCarAlias?.let { root.put("selectedCarAlias", it) }
        session.route?.let {
            root.put("route", JSONObject()
                .put("appRegion", it.appRegion)
                .put("appCenter", it.appCenter))
        }
        session.authRevision?.let { root.put("authRevision", it) }
        return root.toString()
    }

    private fun encodeOldAuth(auth: OldAuth) = JSONObject()
        .put("accountId", auth.accountId)
        .put("token", auth.token)
        .put("refreshToken", auth.refreshToken)
        .put("nickname", auth.nickname)
        .put("tokenExpired", auth.tokenExpired)
        .put("tokenObtainedAt", auth.tokenObtainedAt)
        .put("tokenExpiresAt", auth.tokenExpiresAt)

    private fun encodeNewAuth(auth: NewAuth) = JSONObject()
        .put("accountId", auth.accountId)
        .put("gatewayAccountId", auth.gatewayAccountId)
        .put("accessToken", auth.accessToken)
        .put("refreshToken", auth.refreshToken)
        .put("accessTokenExpiresAt", auth.accessTokenExpiresAt)
        .put("nickname", auth.nickname)
        .put("signKeyBase64", auth.signKeyBase64)

    private fun encodeVehicle(vehicle: Vehicle) = JSONObject()
        .put("vin", vehicle.vin)
        .put("carType", vehicle.carType)
        .put("name", vehicle.name)
        .put("isExtendRange", vehicle.isExtendRange)
        .put("permission", JSONArray().apply { vehicle.permission.forEach { put(it) } })
        .put("isSentinelSupported", vehicle.isSentinelSupported)

    private fun decode(text: String): LeapSession? {
        val root = JsonValue.parse(text) ?: return null
        // 允许为空：设备号现在单独存放，会话 JSON 里这份可能是被半截会话写空的，
        // 由 `loadOutcome` 用单独那条补回来。键本身仍必须在，缺键才算坏数据。
        val deviceId = root.get("deviceId")?.stringValue ?: return null
        return LeapSession(
            deviceId = deviceId,
            appVersion = root.get("appVersion")?.stringValue ?: LeapConstants.APP_VERSION,
            subVersion = root.get("subVersion")?.stringValue ?: LeapConstants.SUB_VERSION,
            phone = root.get("phone")?.stringValue.orEmpty(),
            oldAuth = root.get("oldAuth")?.let { decodeOldAuth(it) },
            newAuth = root.get("newAuth")?.let { decodeNewAuth(it) },
            vehicles = (root.get("vehicles")?.arrayValue ?: emptyList()).mapNotNull { decodeVehicle(it) },
            selectedVin = root.get("selectedVin")?.stringValue.orEmpty(),
            selectedCarType = root.get("selectedCarType")?.stringValue.orEmpty(),
            selectedCarAlias = root.get("selectedCarAlias")?.stringValue,
            route = root.get("route")?.let {
                VehicleRoute(
                    appRegion = it.get("appRegion")?.stringValue.orEmpty(),
                    appCenter = it.get("appCenter")?.stringValue.orEmpty(),
                )
            },
            authRevision = root.get("authRevision")?.longValue,
        )
    }

    private fun decodeOldAuth(node: JsonValue) = OldAuth(
        accountId = node.get("accountId")?.stringValue.orEmpty(),
        token = node.get("token")?.stringValue.orEmpty(),
        refreshToken = node.get("refreshToken")?.stringValue.orEmpty(),
        nickname = node.get("nickname")?.stringValue.orEmpty(),
        tokenExpired = node.get("tokenExpired")?.stringValue.orEmpty(),
        tokenObtainedAt = node.get("tokenObtainedAt")?.longValue ?: 0,
        tokenExpiresAt = node.get("tokenExpiresAt")?.longValue ?: 0,
    )

    private fun decodeNewAuth(node: JsonValue) = NewAuth(
        accountId = node.get("accountId")?.stringValue.orEmpty(),
        gatewayAccountId = node.get("gatewayAccountId")?.stringValue.orEmpty(),
        accessToken = node.get("accessToken")?.stringValue.orEmpty(),
        refreshToken = node.get("refreshToken")?.stringValue.orEmpty(),
        accessTokenExpiresAt = node.get("accessTokenExpiresAt")?.longValue ?: 0,
        nickname = node.get("nickname")?.stringValue.orEmpty(),
        signKeyBase64 = node.get("signKeyBase64")?.stringValue.orEmpty(),
    )

    private fun decodeVehicle(node: JsonValue): Vehicle? {
        val vin = node.get("vin")?.stringValue ?: return null
        return Vehicle(
            vin = vin,
            carType = node.get("carType")?.stringValue.orEmpty(),
            name = node.get("name")?.stringValue.orEmpty(),
            isExtendRange = node.get("isExtendRange")?.boolValue ?: false,
            // JSON 里压根没有 isExtendRange 键 = 老会话，上面兜出来的 false 不可信，标记待重拉。
            // 光靠「兜底成 false」不够：老会话里既没有这个键、车列表又非空（于是永不重拉），
            // 增程会被永久误判成纯电、油量整块消失，且永不自愈。
            abilitiesStale = node.get("isExtendRange") == null,
            permission = (node.get("permission")?.arrayValue ?: emptyList())
                .mapNotNull { it.stringValue },
            isSentinelSupported = node.get("isSentinelSupported")?.boolValue ?: false,
            // 同上，只是盯的是哨兵支持位。两个标志各判各的字段，不能合并——
            // abilities 缺不代表 permission 也缺，反之亦然。
            sentinelStale = node.get("isSentinelSupported") == null,
        )
    }
}

/// 操作密码单独存放，用于免去每次手输。
///
/// 和会话分开存：退登要清它，但续期写会话时不该顺手动它。
class OperationPasswordStore {

    private val entry = "leap-operation-password"

    fun read(): String? = (SecureVault.read(entry) as? SecureVault.Outcome.Found)
        ?.value?.takeIf { it.isNotEmpty() }

    /// 返回是否真的写进去了。写失败必须让上层知道——否则用户勾了「记住密码」，
    /// 下次还是被要求手输，却看不到任何原因。
    fun write(password: String): Boolean = SecureVault.write(entry, password)

    fun clear() {
        SecureVault.remove(entry)
    }

    val hasPassword: Boolean get() = read() != null
}
