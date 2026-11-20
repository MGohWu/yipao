package org.yipao.app.core

import org.json.JSONObject

/// App 与桌面小组件、快捷磁贴、常驻通知共享的一小份车况快照。对齐 iOS `VehicleSnapshot`。
///
/// 安卓这边小组件和磁贴跑在**同一个进程**里，本可以直接读 `VehicleStore.shared`。
/// 仍然要这份快照的理由是冷启动：系统可能只为了画一张卡片就把进程拉起来，那时
/// `VehicleStore` 是空的，而它自愈要走网络。落一份盘上的快照，卡片才能立刻画出东西来。
///
/// 这里只放**非敏感的展示数据**——token 和操作密码始终留在 `SecureVault`，不进这份文件。
data class VehicleSnapshot(
    val vehicleName: String,
    val soc: Int?,
    /// 增程车的油量百分比；纯电车为 null（卡片据此决定要不要画油量条）。
    val gasolinePercent: Int?,
    /// 来自车辆能力码；null 兼容旧快照。
    val isExtendRange: Boolean? = null,
    val rangeKm: Int?,
    /// 增程车的纯电续航（km）。纯电车为 null——纯电车的续航就是 [rangeKm]，不重复存一份。
    val energyRangeKm: Int? = null,
    /// 增程车的燃油续航（km）。纯电车为 null。
    /// 车端本来就把电和油分成两个数报，官方也不给综合续航，所以大卡上分两段显示。
    val fuelRangeKm: Int? = null,
    val isLocked: Boolean?,
    val isDriving: Boolean,
    val isCharging: Boolean,
    val chargeLimit: Int?,
    val chargeRemainMinutes: Int?,
    val chargePowerKW: Double?,
    val indoorTemp: Double?,
    val climateOn: Boolean,
    val windowsClosed: Boolean?,
    val anyDoorOpen: Boolean,
    /// 尾门开着。
    ///
    /// 注意 `anyDoorOpen` **不含**尾门（它只看四个车门），所以这一项必须单独带过来，
    /// 否则卡片上的尾门键永远是灰的、顶部那句话也永远不提尾门。
    /// 读不到是 null，一律按「不亮、不提」处理——不亮只是中性外观，
    /// 不像文字那样会替车编出一个「已关」。
    val trunkOpen: Boolean?,
    val hasTireWarning: Boolean,
    val locationName: String?,
    val latitude: Double?,
    val longitude: Double?,
    /// 本机什么时候把这份车况拉下来的。注意不是车端采集时刻，那个看 [reportedAt]。
    val updatedAt: Long,
    /// 车端采集这份车况的时刻。读不到（某些车型不报 `collectTime`）时是 null。
    ///
    /// 卡片刷得再勤 [updatedAt] 都是「刚刚」；车休眠着不上报时，服务端会把同一份旧数据
    /// 一直发回来，只有这个字段能看出车况到底有多旧。
    val reportedAt: Long?,
) {

    val hasFuel: Boolean
        get() = isExtendRange ?: (gasolinePercent != null || energyRangeKm != null || fuelRangeKm != null)

    /// 增程车中卡跟随当前工况的电油分项；缺失时不退回可能滞留的 expectedMileage。
    val mediumRangeText: String?
        get() {
            if (!hasFuel) return rangeKm?.takeIf { it >= 0 }?.let { "$it km" }
            val parts = listOfNotNull(
                energyRangeKm?.takeIf { it >= 0 }?.let { "电 $it" },
                fuelRangeKm?.takeIf { it >= 0 }?.let { "油 $it" },
            )
            return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")?.plus(" km")
        }

    /// 这份车况实际有多旧。车端报了采集时刻就以它为准，读不到才退回本机拉取时间。
    private val moment: Long get() = reportedAt ?: updatedAt

    /// 卡片上那句「多久前」的措辞。
    ///
    /// 带动词，而且**车端时刻读不到时动词要改口**：那时这句话只能保证「几分钟前问过」，
    /// 保证不了「车况就是那时候的」。和首页副标题同一套口径。
    val freshnessText: String get() = freshnessText(System.currentTimeMillis())

    /// 大卡上那句「多久前」的短版：只有时间，不带动词。
    ///
    /// 那一行右边已经站着一句状态（地名或「车窗未关闭」），再拼一个「更新于」就长到
    /// 要缩字号了。动词丢掉之后车端时刻和本机拉取时间的区别也跟着丢了——这一行本来就
    /// 只承诺「这个数字有多新」，要追究是哪一种「新」，首页副标题里说得全。
    val freshnessCompact: String get() = freshnessCompact(System.currentTimeMillis())

    internal fun freshnessCompact(now: Long): String {
        val elapsed = ((now - moment) / 1000).coerceAtLeast(0)
        return when {
            elapsed < 60 -> "刚刚"
            elapsed < 3600 -> "${elapsed / 60} 分钟前"
            elapsed < 86400 -> "${elapsed / 3600} 小时前"
            else -> "${elapsed / 86400} 天前"
        }
    }

    internal fun freshnessText(now: Long): String {
        val verb = if (reportedAt == null) "读取" else "更新"
        val elapsed = ((now - moment) / 1000).coerceAtLeast(0)
        return when {
            elapsed < 60 -> "刚刚$verb"
            elapsed < 3600 -> "${verb}于 ${elapsed / 60} 分钟前"
            elapsed < 86400 -> "${verb}于 ${elapsed / 3600} 小时前"
            else -> "${verb}于 ${elapsed / 86400} 天前"
        }
    }

    /// 超过半小时的数据不该让用户以为是实时的。
    ///
    /// 按车端采集时刻算：车休眠着的时候本机每次都拉得到东西，但那是同一份旧数据，
    /// 按拉取时间算的话它永远不会过期。
    val isStale: Boolean get() = isStale(System.currentTimeMillis())

    internal fun isStale(now: Long): Boolean = now - moment > 1_800_000

    /// 卡片上只留一句最该被看到的话。
    val headline: String
        get() = when {
            anyDoorOpen -> "有车门未关闭"
            trunkOpen == true -> "尾门未关闭"
            hasTireWarning -> "胎压异常"
            windowsClosed == false -> "车窗未关闭"
            isCharging -> chargeLimit?.let { "充电中 · 上限 $it%" } ?: "充电中"
            climateOn -> "空调运行中"
            !locationName.isNullOrEmpty() -> locationName
            else -> if (isLocked == false) "已解锁" else "已锁车"
        }

    val chargeRemainingText: String?
        get() {
            val minutes = chargeRemainMinutes?.takeIf { it > 0 } ?: return null
            val hours = minutes / 60
            val rest = minutes % 60
            if (hours == 0) return "还需 $rest 分"
            return if (rest == 0) "还需 $hours 小时" else "还需 $hours 小时 $rest 分"
        }

    val chargePowerText: String?
        get() {
            val power = chargePowerKW ?: return null
            if (!power.isFinite() || power < 0) return null
            return String.format(java.util.Locale.US, "%.1f kW", power)
        }

    /// 充电那一行有没有东西可说。两个都读不到就整行别出现——摆一行「剩余时间 --
    /// 功率 --」等于用两个占位符告诉用户「我不知道」。SOC 那种主数字读不到才用 `--`
    /// 顶着，因为不占位卡片会空一块；这一行不是。
    val hasChargeMetrics: Boolean get() = chargeRemainingText != null || chargePowerText != null

    /// 锁状态在卡片上的统一说法。
    ///
    /// **别在各处各写一遍。** iOS 那边判据分叉过一次：状态卡写的是 `isLocked != false`，
    /// 于是车端没报锁状态时画出一个绿色闭锁——等于替车说了句「锁好了」；
    /// 而同一时刻单功能锁车卡显示的是「状态未知」。同一台车，两张卡两个说法。
    val lockText: String
        get() = when (isLocked) {
            true -> "已锁车"
            false -> "已解锁"
            null -> "状态未知"
        }

    /// 还能拿来**决定按下去发哪个方向**的锁状态。过期就是 null，不做断言。
    ///
    /// 和 [isLocked] 的区别只在时效，但用错地方后果不一样：卡片拿它显示，旧一点顶多是
    /// 信息旧了，旁边那句「多久前」已经说清楚；而按钮按下去会变成一条真指令，
    /// **显示什么就决定了发哪个方向**——显示「已锁车」按下去就是解锁。
    val trustedLock: Boolean? get() = if (isStale) null else isLocked

    /// 照着这份快照，按一下车锁键该把车变成什么状态（`true` = 锁上）。
    ///
    /// **凡是要把快照翻译成一条锁车指令的地方都读这一个。** 对齐 iOS
    /// `VehicleSnapshot.lockActionTarget`：只有确知车锁着的时候才发解锁，其余一律锁车。
    /// 读不到、旧到不该再当真，都归进「其余」——两个方向里这个是安全的那个，
    /// 多锁一次没有损失，按反了就是在停车场里把车打开。
    val lockActionTarget: Boolean get() = trustedLock != true

    /// 需要提醒用户的状态，卡片上要用警示色。
    val needsAttention: Boolean
        get() = anyDoorOpen || trunkOpen == true || hasTireWarning ||
            isLocked == false || windowsClosed == false

    fun toJson(): String = JSONObject().apply {
        put("vehicleName", vehicleName)
        soc?.let { put("soc", it) }
        gasolinePercent?.let { put("gasolinePercent", it) }
        isExtendRange?.let { put("isExtendRange", it) }
        rangeKm?.let { put("rangeKm", it) }
        energyRangeKm?.let { put("energyRangeKm", it) }
        fuelRangeKm?.let { put("fuelRangeKm", it) }
        isLocked?.let { put("isLocked", it) }
        put("isDriving", isDriving)
        put("isCharging", isCharging)
        chargeLimit?.let { put("chargeLimit", it) }
        chargeRemainMinutes?.let { put("chargeRemainMinutes", it) }
        chargePowerKW?.let { put("chargePowerKW", it) }
        indoorTemp?.let { put("indoorTemp", it) }
        put("climateOn", climateOn)
        windowsClosed?.let { put("windowsClosed", it) }
        put("anyDoorOpen", anyDoorOpen)
        trunkOpen?.let { put("trunkOpen", it) }
        put("hasTireWarning", hasTireWarning)
        locationName?.let { put("locationName", it) }
        latitude?.let { put("latitude", it) }
        longitude?.let { put("longitude", it) }
        put("updatedAt", updatedAt)
        reportedAt?.let { put("reportedAt", it) }
    }.toString()

    companion object {

        val placeholder = VehicleSnapshot(
            vehicleName = "S01",
            soc = 76,
            gasolinePercent = null,
            rangeKm = 312,
            isLocked = true,
            isDriving = false,
            isCharging = false,
            chargeLimit = 90,
            chargeRemainMinutes = null,
            chargePowerKW = null,
            indoorTemp = 26.0,
            climateOn = false,
            windowsClosed = true,
            anyDoorOpen = false,
            trunkOpen = false,
            hasTireWarning = false,
            locationName = "杭州市上城区",
            latitude = 30.24704,
            longitude = 120.21201,
            updatedAt = System.currentTimeMillis(),
            reportedAt = System.currentTimeMillis(),
        )

        /// 从车况构造快照。字段映射只此一处，别在下发回读那条路上再抄一遍。
        fun make(
            state: VehicleState,
            vehicleName: String,
            locationName: String?,
            updatedAt: Long = System.currentTimeMillis(),
        ): VehicleSnapshot {
            // 判据统一收在 `anyWindowOpen` 里：开合状态位优先、开度兜底。
            // 只看开度的那版对不报开度的车（C11 增程版）恒为 null，卡片上这一项永远是空的。
            val coordinate = state.shareableCoordinate
            return VehicleSnapshot(
                vehicleName = vehicleName,
                soc = state.soc,
                gasolinePercent = state.gasolinePercent,
                isExtendRange = state.hasFuel,
                rangeKm = state.expectedMileage,
                energyRangeKm = if (state.hasFuel) state.energyRange else null,
                fuelRangeKm = if (state.hasFuel) state.gasolineRange else null,
                isLocked = state.isLocked,
                isDriving = state.isDriving,
                isCharging = state.isCharging,
                chargeLimit = state.chargeLimit,
                chargeRemainMinutes = state.chargeRemainMinutes,
                chargePowerKW = state.chargePowerKW,
                indoorTemp = state.indoorTemp,
                climateOn = state.acOn,
                windowsClosed = state.anyWindowOpen?.not(),
                anyDoorOpen = state.anyDoorOpen,
                trunkOpen = state.trunkOpen,
                hasTireWarning = state.hasTireWarning,
                locationName = locationName,
                latitude = coordinate?.latitude,
                longitude = coordinate?.longitude,
                updatedAt = updatedAt,
                reportedAt = state.reportedAt,
            )
        }

        fun fromJson(text: String): VehicleSnapshot? = try {
            val json = JSONObject(text)
            VehicleSnapshot(
                vehicleName = json.optString("vehicleName", "车辆"),
                soc = json.intOrNull("soc"),
                gasolinePercent = json.intOrNull("gasolinePercent"),
                isExtendRange = json.boolOrNull("isExtendRange"),
                rangeKm = json.intOrNull("rangeKm"),
                energyRangeKm = json.intOrNull("energyRangeKm"),
                fuelRangeKm = json.intOrNull("fuelRangeKm"),
                isLocked = json.boolOrNull("isLocked"),
                isDriving = json.optBoolean("isDriving", false),
                isCharging = json.optBoolean("isCharging", false),
                chargeLimit = json.intOrNull("chargeLimit"),
                chargeRemainMinutes = json.intOrNull("chargeRemainMinutes"),
                chargePowerKW = if (json.has("chargePowerKW")) json.optDouble("chargePowerKW") else null,
                indoorTemp = if (json.has("indoorTemp")) json.optDouble("indoorTemp") else null,
                climateOn = json.optBoolean("climateOn", false),
                windowsClosed = json.boolOrNull("windowsClosed"),
                anyDoorOpen = json.optBoolean("anyDoorOpen", false),
                trunkOpen = json.boolOrNull("trunkOpen"),
                hasTireWarning = json.optBoolean("hasTireWarning", false),
                locationName = json.optString("locationName").takeIf { it.isNotEmpty() },
                latitude = if (json.has("latitude")) json.optDouble("latitude") else null,
                longitude = if (json.has("longitude")) json.optDouble("longitude") else null,
                updatedAt = json.optLong("updatedAt", 0L),
                reportedAt = if (json.has("reportedAt")) json.optLong("reportedAt") else null,
            )
        } catch (e: Exception) {
            null
        }

        private fun JSONObject.intOrNull(key: String): Int? = if (has(key)) optInt(key) else null
        private fun JSONObject.boolOrNull(key: String): Boolean? = if (has(key)) optBoolean(key) else null
    }
}
