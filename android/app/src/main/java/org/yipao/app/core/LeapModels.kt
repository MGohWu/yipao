package org.yipao.app.core

import java.util.Calendar
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// MARK: - 常量

object LeapConstants {
    const val APP_VERSION = "1.22.87"
    const val SUB_VERSION = "3.19.2-2"
    const val APP_USER_HOST = "https://appuser.leapmotor.cn"
    const val GLOBAL_HOST = "https://app-gw-global-master.leapmotor.com"

    /// accessToken 剩余不足 5 分钟就提前续期（秒）。
    const val ACCESS_TOKEN_LEEWAY = 5 * 60L

    /// 老 token 剩余不足 60 秒才续期（秒）。
    const val OLD_TOKEN_LEEWAY = 60L

    /// 老链路 `result=39` 的续期冷却窗口（秒）：老 token 是这段时间内换发的，再收到 39
    /// 就不重复续期，只当瞬时抖动重试一次。对齐官方零跑 App 的 60 秒不重复刷新闸——
    /// 刚续期后紧跟的 39 若又触发一次续期，旧 refreshToken 立刻作废，反而制造失效窗口。
    const val OLD_TOKEN_REAUTH_COOLDOWN = 60L

    /// 老链路连续判定失败到这个次数，就不再当瞬时抖动，提示用户重新登录。
    /// 每一次计数都已经经过「刷新 token 后重试」或「冷却窗口内重试」，不是裸重试。
    const val OLD_AUTH_FAILURE_ESCALATION_COUNT = 3

    /// 连续失败还要跨过这段时间才升级（秒）。服务端抖动是以秒计的，跨过 5 分钟仍每次都失败，
    /// 就不是抖动了。两个条件都满足才提示，避免又变回「服务端抖一下就被踢」。
    const val OLD_AUTH_FAILURE_ESCALATION_WINDOW = 5 * 60L

    /// 老 token 是这段时间内换发的，登录态探测就直接认它有效，不再打一次续期（秒）。
    /// 探得太勤，每次都换发一份新 refreshToken，旧的当场作废，撞上限流和误判文案的机会也跟着翻倍。
    const val SESSION_PROBE_FRESHNESS = 30 * 60L

    /// 远控指令里 set_id 的平台前缀。官方安卓端就是 `Android_`。
    const val PLATFORM_TAG = "Android"
}

/// 服务端的服务名段。拼在各自 host 后面构成完整路径，值来自抓包与官方包反编译，
/// 一个字母都不能改——网关按段路由，写错直接 404。
object LeapPaths {
    /// 老链路登录 / 发验证码 / 续期。
    const val APP_USER = "app-user"

    /// 新网关账号服务（换取 accessToken、刷新 token）。
    const val BASE_USER = "base-user"

    /// 新网关车辆服务（车辆列表、路由）。
    const val APP_GLOBAL = "app-global-service"

    /// 新网关车况服务。
    const val APP_SIGNAL = "app-signal-service"

    /// 远控指令下发 / 结果查询。
    const val APP_CONTROL = "app-control-service"

    /// 老链路车主业务（里程能耗、驻车照片、车辆配置）。
    const val CAROWNER = "carownerservice"
}

/// 零跑自定义请求头名。`XFX-CDN-*` 这一组是它家 CDN 网关认的，大小写敏感。
object LeapHeaders {
    const val XFX_VRS = "XFX-CDN-VRS"

    /// 老链路的登录态 token 头。
    const val XFX_CROSS_NODE = "XFX-CDN-CROSS-NODE"

    /// 老链路续期时放 refreshToken 的头（它参与签名但不进 query）。
    const val XFX_CROSS_REFRESH_NODE = "XFX-CDN-CROSS-REFRESH-NODE"

    const val API_SIG_VERSION = "x-api-signature-version"
    const val SUB_VERSION = "x-subversion"
    const val REGION = "x-region"

    /// 新网关 `source` 头的固定值。
    const val VAL_LEAPMOTOR = "leapmotor"
}

object LeapFormat {
    /// 温度：车报 26.5 就写 26.5，报 26.0 就写 26。
    /// 半度是车端真实的分辨率，不该替它抹掉（`%.0f` 会把 26.5 进位成 27）。
    fun temperature(value: Double): String =
        if (value == Math.rint(value)) value.roundToInt().toString() else String.format("%.1f", value)
}

// MARK: - 会话

data class OldAuth(
    val accountId: String = "",
    val token: String = "",
    val refreshToken: String = "",
    val nickname: String = "",
    val tokenExpired: String = "",
    val tokenObtainedAt: Long = 0,
    /// 老 token 过期时间戳（毫秒），0 表示无。
    val tokenExpiresAt: Long = 0,
)

data class NewAuth(
    val accountId: String = "",
    val gatewayAccountId: String = "",
    val accessToken: String = "",
    val refreshToken: String = "",
    val accessTokenExpiresAt: Long = 0,
    val nickname: String = "",
    /// 以 base64 落盘，运行时用 signKeyData。
    val signKeyBase64: String = "",
) {
    val signKeyData: ByteArray
        get() = LeapCrypto.base64Decode(signKeyBase64)

    /// 新网关 token 过期时间戳（毫秒），优先取 JWT exp。
    val expiresAt: Long
        get() {
            val exp = LeapCrypto.jwtExpiryMilliseconds(accessToken)
            return if (exp > 0) exp else accessTokenExpiresAt
        }
}

data class Vehicle(
    val vin: String,
    val carType: String,
    val name: String,
    /// 这台车是不是增程（REEV/EREV）。判据跟官方对齐：vehicle/list 响应里每辆车的
    /// `abilities` 字符串数组含能力码 "39"（官方内部 key isExtendRange）就是增程。
    /// 会随 Vehicle 一起持久化进会话；旧会话没有这字段，读出来按 false 兜底。
    val isExtendRange: Boolean = false,
    /// 运行时兜底标志：isExtendRange 是从「缺该字段的老会话 JSON」兜出来的、
    /// 还没被 vehicle/list 的真实 abilities 刷新过，不可信。SessionStore 在反序列化
    /// 时按字段是否真实存在置位，refresh 链路见到任一车为真就强制重拉一次能力码。
    /// 升级用户增程被误判成纯电、油量整块消失就是这个字段缺失且永不重拉导致的。
    val abilitiesStale: Boolean = false,
    /// 这台车的**内部权限码清单**（"400" 这类），由 loadVehicles 把 `abilities` 里的原始短码
    /// 经 CarPerManager 翻译表（VehicleUtil.permissionCodes）换算出来。
    ///
    /// **注意 vehicle/list 响应里根本没有 `permission` 字段**：能力码全在 `abilities` 里，
    /// 是服务端**原始短码**（"1".."89"），判据吃的却是内部码，中间隔着 CarPerManager 一层。
    /// 曾误以为存在一个和 abilities 并列的 permission 字段直接读，结果恒空 → 哨兵对所有真实用户
    /// 判假（只有手填内部码的体验模式看得到）。判增程用的 `abilities.contains("39")` 判不了哨兵，
    /// 因为哨兵是内部码 "400"（原始短码 "50" 翻过来的）。
    val permission: List<String> = emptyList(),
    /// 这台车支不支持哨兵模式。判据跟官方钉死的对齐：
    /// `carType 不是 "S01"/"T03"` 且内部权限码含 `"400"`。
    val isSentinelSupported: Boolean = false,
    /// 运行时兜底标志，语义同 abilitiesStale，但各判各的字段——abilities 缺不代表 permission
    /// 也缺，反之亦然，所以要各自一份，不能合并。
    val sentinelStale: Boolean = false,
) {
    companion object {
        /// 支持哨兵模式的判据（反编译已钉死）：车型不是 S01/T03，且 `permission` 含 `"400"`。
        ///
        /// **判据查的是内部码 `permission`，不是原始 `abilities`**——`permission` 由 `abilities`
        /// 经 `CarPerManager` 翻译而来（原始 `"50"` → 内部 `"400"`），增程那套
        /// `abilities.contains("39")` 判不了哨兵。S01/T03 官方在 `RemoteContorllerUtil.contains()`
        /// 里对车型走白名单硬排除，哪怕 `permission` 里有 `"400"` 也恒隐藏哨兵，
        /// 所以这里先把这两个车型挡在门外，再看能力码。
        fun supportsSentinel(carType: String, permission: List<String>): Boolean {
            if (CarTypeFamily.isS01(carType) || CarTypeFamily.isT03(carType)) return false
            return permission.contains("400")
        }

        /// 支持远控遮阳帘（天幕）的判据：`permission` 含 `"240"`（快捷面板 btnType "29" →
        /// `lpcar_btn_sunshade`，确证）。
        ///
        /// 和哨兵不同**不排除 S01/T03**：官方对这两个车型的前置白名单里有 766="240"，
        /// 遮阳帘照常按能力码判。
        fun supportsSunshade(permission: List<String>): Boolean = permission.contains("240")

        /// 支持远控天窗的判据：车型不是 S01/T03，且 `permission` 含 `"300"`（btnType "26" →
        /// `lpcar_btn_skylight`）。S01/T03 白名单里**没有** 763="300"——官方在这两个车型上
        /// 恒隐藏天窗，哪怕服务端下发了能力码，所以照哨兵那样先挡车型再看码。
        fun supportsSunroof(carType: String, permission: List<String>): Boolean {
            if (CarTypeFamily.isS01(carType) || CarTypeFamily.isT03(carType)) return false
            return permission.contains("300")
        }

        /// 支持远控前备箱的判据：车型不是 S01/T03，且 `permission` 含 `"131"`（btnType "137" →
        /// `lpcar_btn_front_trunk`；白名单没有 153="131"，车型排除理由同天窗）。
        fun supportsFrunk(carType: String, permission: List<String>): Boolean {
            if (CarTypeFamily.isS01(carType) || CarTypeFamily.isT03(carType)) return false
            return permission.contains("131")
        }

        /// 舒适座舱四项的能力码判据。
        ///
        /// 这几项**只当第二道判据**：真正说话的是车况信号在不在场（见
        /// `VehicleState.hasCabinComfort`）。原因是信号比能力码更贴车端，而且方向盘加热
        /// （cmdid `320`）压根没有已知的 `abilities` 原始码，只能靠信号 `1816`。两者都没有才隐藏。
        ///
        /// S01 / T03 一律排除：那套老口径的 signalMap 里没有任何一个对应字段，整页在老车上就是空的。
        fun supportsCabinComfort(carType: String, permission: List<String>): Boolean {
            if (CarTypeFamily.isLegacyFamily(carType)) return false
            return permission.contains("301") || permission.contains("370") || permission.contains("440")
        }

        /// 车载冰箱的能力码判据（原始码 `76`）。车主那台 C16 不含 `76`，
        /// 和它的 signalMap 里冰箱信号全无互相印证。
        fun supportsFridge(carType: String, permission: List<String>): Boolean {
            if (CarTypeFamily.isLegacyFamily(carType)) return false
            return permission.contains("500")
        }
    }
}

object VehicleUtil {
    /// 只展示后 4 位，避免整屏 VIN 泄露。
    fun maskedVin(vin: String): String {
        if (vin.length <= 6) return vin
        return vin.substring(0, 2) + "*".repeat(max(0, vin.length - 6)) + vin.takeLast(4)
    }

    /// 服务端原始能力短码 → App 内部权限码 的翻译表（官方 CarPerManager 那张表的子集）。
    /// vehicle/list 每辆车只回**原始短码**（在 `abilities` 里，且响应里**根本没有** permission 字段），
    /// 而判据吃的是内部码，中间必须翻这一道。四条已三路交叉验证：
    /// 50→400 哨兵、13→240 遮阳帘、25→300 天窗、79→131 前备箱。
    private val abilityToPermission = mapOf(
        "50" to "400",
        "13" to "240",
        "25" to "300",
        "79" to "131",
        // 舒适座舱四项（2026-11-19 补，同 iOS）。这四个内部码在我们自己解出的 `CarPerManager`
        // 全表里本来就在，只是官方 APK 里一个中文名都没有（官方 App 自己没做这些功能）。
        // 语义来自 leapauto，与车主 C16 的 `abilities` 逐项对得上：含 21/42/43/59、不含 76。
        "21" to "301", // 座椅加热
        "85" to "301",
        "93" to "301",
        "42" to "370", // 座椅通风
        "43" to "370",
        "59" to "440", // 后视镜加热
        "76" to "500", // 车载冰箱
    )

    /// 把 vehicle/list 的原始 `abilities` 短码翻成内部权限码清单（认不出的短码丢弃）。
    fun permissionCodes(abilities: List<String>): List<String> =
        abilities.mapNotNull { abilityToPermission[it] }.distinct()
}

data class VehicleRoute(
    val appRegion: String = "",
    val appCenter: String = "",
)

data class LeapSession(
    val deviceId: String,
    val appVersion: String = LeapConstants.APP_VERSION,
    val subVersion: String = LeapConstants.SUB_VERSION,
    val phone: String = "",
    val oldAuth: OldAuth? = null,
    val newAuth: NewAuth? = null,
    val vehicles: List<Vehicle> = emptyList(),
    val selectedVin: String = "",
    val selectedCarType: String = "",
    /// 车型别名（`Lafa5` 这种），从 3D 资源目录名反推、随会话存下来。
    /// 存而不是每次现推：小组件那边读的是持久化的会话，拿不到主界面的缓存目录判断，
    /// 只有存下来小组件和首页才不会叫出两个名字。
    val selectedCarAlias: String? = null,
    val route: VehicleRoute? = null,
    /// 凭证（`oldAuth` / `newAuth`）最后一次换发的时刻，毫秒。
    ///
    /// 主 App、小组件、磁贴 / 通知 Intent 是几个不同进程，各自 new 一个 `LeapClient`、
    /// 各自续期。服务端每换发一次就把旧 refreshToken 作废，所以「谁的凭证新听谁的」
    /// 必须有个判据——没有它，主 App 那个常驻实例会拿着几小时前、早被小组件换掉的
    /// refreshToken 去续期，被服务端拒之后判成登录失效，用户就莫名其妙回到了登录页。
    ///
    /// 老会话解不出这个字段，可空保证旧数据照样能解码（当 0 处理，任何一次换发都比它新）。
    val authRevision: Long? = null,
) {
    val isLoggedIn: Boolean
        get() = (oldAuth?.token?.isNotEmpty() == true) && (newAuth?.accessToken?.isNotEmpty() == true)

    /// 手里还攥着**任何一份**凭证——哪怕只有半份，不足以算登录成功。
    ///
    /// 半份是真会出现的：`login()` 拿到 oldAuth 之后换新网关那步失败，就剩 oldAuth。
    /// 这种会话登录不了，却足以把登录请求的 header 打脏，所以清理逻辑得认它，
    /// 不能只认 `isLoggedIn`。
    val hasAnyCredential: Boolean
        get() = oldAuth != null || newAuth != null

    val selectedVehicle: Vehicle?
        get() = vehicles.firstOrNull { it.vin == selectedVin }

    /// 界面和小组件上显示的车名。两边必须一致，否则小组件和首页会叫出两个名字。
    ///
    /// 车主在官方 App 起的名字最优先。没起过名就用车型别名——B05 这种内部代号
    /// 不适合直接摆在界面上，别名（`Lafa5`）是渲染器实际认的那个名字。
    /// 别名只有 3D 车推得出来（靠资源目录名），2D 图层车退回 carType：
    /// C10、S01 这些本来就是对外车型名，摆出来没问题。
    val displayVehicleName: String
        get() {
            selectedVehicle?.name?.takeIf { it.isNotEmpty() }?.let { return it }
            selectedCarAlias?.takeIf { it.isNotEmpty() }?.let { return it }
            if (selectedCarType.isNotEmpty()) return selectedCarType
            return "我的车"
        }

    companion object {
        /// 空态会话。`deviceId` 是**空的**，不是新生成的——这是刻意的。
        ///
        /// 老链路签名把 deviceID 和 token 绑在一起（服务端按请求里的 deviceID 取它记录的
        /// token 重算 MD5），换一个设备号就一律 `result=39`，而重新绑定只能靠重新短信登录。
        /// 空态会话恰恰出现在「这一次读不到存储」的入口上（直接启动加密阶段被拉起、
        /// 密钥库忙），那里凭空发一个新设备号，就等于把还活着的登录态钉死。
        ///
        /// 空设备号的会话发不出任何请求（`requireDeviceId()` 会挡住），也不会整份写回，
        /// 只有 `ensureDeviceId()`（登录流程）才生成新的。
        fun fresh(): LeapSession = LeapSession(deviceId = "")

        /// 只给 `LeapClient.ensureDeviceId()`（登录流程）用。别处一律不发新设备号。
        fun randomDeviceId(): String {
            val hex = "0123456789abcdef"
            val out = StringBuilder(32)
            repeat(32) { out.append(hex[(Math.random() * 16).toInt().coerceIn(0, 15)]) }
            return out.toString()
        }
    }
}

// MARK: - 坐标

data class Coordinate(val latitude: Double, val longitude: Double)

// MARK: - 充电计划

/// 充电计划。来自 commonConfig 接口 `data.config."3"`——数字口径的车不把它当信号报，
/// 官方就从这里读预约时段、目标电量和循环日。只解析要展示的字段；`circulation` /
/// `recharge` 存下来但界面不展示。
data class ChargePlan(
    /// 预约充电起始时刻，"HH:mm"。
    val beginTime: String = "",
    /// 预约充电结束时刻，"HH:mm"。
    val endTime: String = "",
    /// 目标 SOC（%），也就是充电上限。
    val percent: Int = 0,
    /// 预约充电开关。
    val isEnable: Boolean = false,
    /// 循环日，**恒七位**。假设 cycles[0]=周一 … cycles[6]=周日——实测样本全是 1（每天），
    /// 无法证伪星期顺序，这里按最常见的「周一起」约定，`cyclesDescription` 也照这个顺序读。
    val cycles: List<Boolean> = List(7) { false },
    /// 循环模式码，界面不展示。
    val circulation: Int = 0,
    /// recharge 标志，界面不展示。
    val recharge: Int = 0,
) {
    /// 有没有拿到完整的七位循环日。
    val hasCycles: Boolean get() = cycles.size == 7

    /// 循环日转成人类可读：全选「每天」、周一~周五「工作日」、仅周末「周末」、
    /// 一天都没有「从不」，其余列出具体日（「周一 周三 周五」）。星期顺序假设见 `cycles` 注释。
    val cyclesDescription: String
        get() {
            if (!hasCycles) return ""
            val names = listOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")
            if (cycles.all { it }) return "每天"
            if (cycles.none { it }) return "从不"
            val weekdaysOn = cycles[0] && cycles[1] && cycles[2] && cycles[3] && cycles[4]
            val weekendOff = !cycles[5] && !cycles[6]
            if (weekdaysOn && weekendOff) return "工作日"
            val weekdaysOff = !cycles[0] && !cycles[1] && !cycles[2] && !cycles[3] && !cycles[4]
            val weekendOn = cycles[5] && cycles[6]
            if (weekdaysOff && weekendOn) return "周末"
            return cycles.indices.filter { cycles[it] }.joinToString(" ") { names[it] }
        }

    /// 预约时段 "23:00–08:00"，缺任一端返回空串。
    val timeRange: String
        get() = if (beginTime.isEmpty() || endTime.isEmpty()) "" else "$beginTime–$endTime"

    companion object {
        /// 从 commonConfig 的**整个 config 对象**里解析充电计划。
        ///
        /// 官方 `@SerializedName("3")` 是充电计划，反编译 bean 名叫 `_$3`，两个 key 都认。
        /// `percent` 缺失（含空串）就没有充电计划可言，返回 null——和官方
        /// 「percent 非空才 parse」的判据一致，不要兜个 0 出来当成「上限 0%」。
        fun fromConfig(config: JsonValue?): ChargePlan? {
            val plan = config?.get("3") ?: config?.get("_\$3") ?: return null
            val percent = plan.get("percent")?.intValue ?: return null
            return ChargePlan(
                beginTime = plan.get("beginTime")?.stringValue.orEmpty(),
                endTime = plan.get("endTime")?.stringValue.orEmpty(),
                percent = percent,
                isEnable = (plan.get("isEnable")?.intValue ?: 0) == 1,
                cycles = parseCycles(plan.get("cycles")?.stringValue),
                circulation = plan.get("circulation")?.intValue ?: 0,
                recharge = plan.get("recharge")?.intValue ?: 0,
            )
        }

        /// `"1,1,1,1,1,1,1"` → 7 个布尔，`1` 为启用。缺位补 `false`、多位截到 7 位，
        /// 读不到就是全 `false`（给 UI 一个稳定的 7 位数组，不必到处判长度）。
        private fun parseCycles(raw: String?): List<Boolean> {
            val text = raw.orEmpty()
            if (text.isEmpty()) return List(7) { false }
            val flags = text.split(",").map { it.trim() == "1" }
            return List(7) { flags.getOrElse(it) { false } }
        }
    }
}

// MARK: - 车况

/// 车端 signalMap 原始值，统一按字符串存放，解释权全部下放到取值方法。
/// key 用哪一套由 schema 决定——不同车型上报的字段命名体系不同，见 SignalSchema。
data class VehicleState(
    val signalMap: Map<String, String> = emptyMap(),
    val schema: SignalSchema = SignalSchema.legacy,
    /// 本机什么时候把这份车况拉下来的。注意不是车端采集时刻，那个看 `reportedAt`。
    val collectedAt: Long = 0,
    /// 充电计划里设的充电上限（%）。数字口径的车不把它当信号报。
    val chargePlanLimit: Int? = null,
    /// 完整充电计划（预约时段 / 目标电量 / 循环日）。同样来自 commonConfig 的 config.3，
    /// 由 LeapClient 拉车况后容错注入；拿不到就保持 null，界面按缺失处理。
    val chargePlan: ChargePlan? = null,
    /// 这台车是不是增程（REEV/EREV）。由 LeapClient 拉车况时从当前选中车的
    /// Vehicle.isExtendRange 注入（源头是 vehicle/list 的 abilities 含 "39"）。
    /// hasFuel 现在直接看它，signalMap 里的汽油续航字段不再参与判增程。
    val isExtendRange: Boolean = false,
) {

    /// 按候选顺序取第一个真的有值的 key。
    fun raw(signal: VehicleSignal): String? {
        for (key in schema.candidates(signal)) {
            val value = signalMap[key]
            if (!value.isNullOrEmpty()) return value
        }
        return null
    }

    fun int(signal: VehicleSignal): Int? {
        val parsed = raw(signal)?.toDoubleOrNull() ?: return null
        return if (parsed.isFinite()) parsed.toInt() else null
    }

    fun double(signal: VehicleSignal): Double? {
        val parsed = raw(signal)?.toDoubleOrNull() ?: return null
        return if (parsed.isFinite()) parsed else null
    }

    fun bool(signal: VehicleSignal): Boolean? = when (raw(signal)?.lowercase()) {
        "true", "1" -> true
        "false", "0" -> false
        else -> null
    }

    // 电池
    val soc: Int? get() = int(VehicleSignal.Soc)

    val expectedMileage: Int? get() = int(VehicleSignal.ExpectedMileage)

    /// 剩余能量，单位瓦时。界面上除以 1000 显示成 kWh。
    val dumpEnergyWh: Double? get() = double(VehicleSignal.DumpEnergy)

    val batteryVoltage: Double? get() = double(VehicleSignal.BatteryVoltage)

    val batteryCurrent: Double? get() = double(VehicleSignal.BatteryCurrent)

    val chargeLimit: Int? get() = int(VehicleSignal.ChargeLimit) ?: chargePlanLimit

    val chargeRemainMinutes: Int? get() = int(VehicleSignal.ChargeRemainTime)

    val minSingleTemp: Int? get() = int(VehicleSignal.MinSingleTemp)

    val chargeTimeSetting: String? get() = raw(VehicleSignal.ChargeTimeSetting)

    /// 0 未在充电，1 充电中，2 本次充电已结束，3 故障，4 预约等待，6 暂停。
    val chargeState: Int? get() = int(VehicleSignal.ChargeState)

    val isCharging: Boolean get() = chargeState == 1

    /// 健康充电开没开。信号 `48`（2026-08-18 关→开往返实测确认），读不到返回 null。
    /// 写入见 `LeapCommand.healthyCharge`。
    val healthyChargeOn: Boolean? get() = bool(VehicleSignal.HealthyCharge)

    /// 充电枪是否插上。只有 C11 那套数字 ID 报这一项，S01/T03 读不到（返回 null）。
    val chargeGunConnected: Boolean?
        get() {
            val fast = raw(VehicleSignal.FastCharging)?.let { it != "0" }
            val slow = bool(VehicleSignal.ChargeGunConnected)
            if (fast == null && slow == null) return null
            return fast == true || slow == true
        }

    /// 充电功率（kW）。车不上报功率，用电压 × 电流算，取绝对值。
    val chargePowerKW: Double?
        get() {
            val voltage = batteryVoltage ?: return null
            val current = batteryCurrent ?: return null
            return abs(voltage * current) / 1000
        }

    /// 电池预热的三态判定结果。
    enum class BatteryPreheatStatus { Heating, TemperatureGood, Inactive, Unknown }

    /// 官方 App 的「温度良好，无需加热」对应热管理请求档位为 0，且实际 PTC 没有输出功率。
    /// 只有数字口径的 1348 是已确认的实际功率；语义口径的设定值不参与判定（映射留空）。
    val batteryPreheatStatus: BatteryPreheatStatus
        get() {
            val power = double(VehicleSignal.PtcPower)
            if (power != null && power > 0) return BatteryPreheatStatus.Heating
            val request = int(VehicleSignal.ThermalManageRequest)
                // 读到了实际功率、而且是 0：这就足以断定没在加热，只是分不出是「温度够了」
                // 还是「压根没开」。**不能因此退回 Unknown**——那会让界面把一个已知的
                // 「没加热」说成「读不到」。真正读不到是另一回事：功率字段本身缺席。
                ?: return if (power == null) BatteryPreheatStatus.Unknown else BatteryPreheatStatus.Inactive
            return if (request == 0) BatteryPreheatStatus.TemperatureGood else BatteryPreheatStatus.Inactive
        }

    val isBatteryPreheating: Boolean?
        get() = when (batteryPreheatStatus) {
            BatteryPreheatStatus.Heating -> true
            BatteryPreheatStatus.TemperatureGood, BatteryPreheatStatus.Inactive -> false
            BatteryPreheatStatus.Unknown -> null
        }

    /// 直流快充。判据：非空且不等于 0（不是 == "1"）。
    val isFastCharging: Boolean
        get() = raw(VehicleSignal.FastCharging)?.let { it.isNotEmpty() && it != "0" } ?: false

    // 增程
    /// 是不是增程/混动车。
    ///
    /// 语义就是**这台车是不是增程车**。判据跟官方对齐：来自 vehicle/list 响应里
    /// 每辆车的 `abilities` 数组含能力码 "39"（官方内部 key isExtendRange），
    /// 由 LeapClient 注入到 isExtendRange，这里直接透出去。
    ///
    /// 早先拿 signalMap 里「有没有汽油续航字段」判增程，被现实打脸两次：纯电车
    /// 一样会上报非零的汽油续航（3256/3259），于是纯电车被误判成增程车，能源页
    /// 多出几格、首页和小组件多出一条油量条。signalMap 各字段都不可靠——纯电车该报
    /// 的照报、恒为 0 的也有，唯一稳的判据是官方 abilities 里的能力码。
    val hasFuel: Boolean get() = isExtendRange

    /// 油量百分比。纯电车即使报了这一项也不给——纯电 C01 报的是 0，
    /// 直接透出去首页和桌面小组件就会画一条空油量条。
    val gasolinePercent: Int? get() = if (hasFuel) int(VehicleSignal.GasolinePercent) else null

    private val usesWLTC: Boolean get() = int(VehicleSignal.WorkingCondition) == 1

    val energyRange: Int?
        get() = int(if (usesWLTC) VehicleSignal.WltcEnergyRange else VehicleSignal.CltcEnergyRange)

    val gasolineRange: Int?
        get() = int(if (usesWLTC) VehicleSignal.WltcGasolineRange else VehicleSignal.CltcGasolineRange)

    val totalRange: Int?
        get() = int(if (usesWLTC) VehicleSignal.WltcTotalRange else VehicleSignal.CltcTotalRange)

    /// 燃油加热中。先要是台有油箱的车：纯电 C11 实测 2946 = 1，
    /// 光看这个字段会说它在给燃油加热。
    val isFuelHeating: Boolean get() = hasFuel && (bool(VehicleSignal.FuelHeating) ?: false)

    // 驾驶状态
    /// 行车中。官方判据就是挡位取 1 或 3。
    val isDriving: Boolean
        get() {
            val gear = int(VehicleSignal.GearStatus)
            return gear == 1 || gear == 3
        }

    val powerOn3: Boolean? get() = bool(VehicleSignal.PowerOn3)

    // 哨兵
    /// 哨兵模式当前开没开。
    ///
    /// 哨兵没有独立的状态查询接口，状态藏在 signalMap 里：差分「开→看→关」三段采样，
    /// 信号 `3636` 干净地 0→1→0 与开关完全对齐。只有数字口径的车报这一位
    /// （S01/T03 本就不支持哨兵），映射收在 numeric schema。
    val sentinelOn: Boolean get() = bool(VehicleSignal.Sentinel) ?: false

    // 遮阳帘 / 天窗
    /// 遮阳帘开没开（信号 `1724`，0…100 开度）。开度 > 0 就算开、等于 0 才算关——
    /// 下发 `240` 开发的是 `"10"`，车回报的开度是 10 还是 100 没验过，所以不拿目标值比对。读不到 null。
    val sunshadeOpen: Boolean? get() = int(VehicleSignal.SunshadeOpening)?.let { it > 0 }

    /// 天窗开没开（信号 `1718`，0…10 开度）。
    ///
    /// **超出 0…10 一律当读不到**：没选装可开启天窗的车会报 `15` / `150` 这类 CAN 占位值
    /// （Signal Not Available），按「> 0 即开」读会把一辆根本没天窗的车说成天窗开着。
    val sunroofOpen: Boolean?
        get() {
            val value = int(VehicleSignal.SunroofOpening) ?: return null
            if (value !in 0..10) return null
            return value > 0
        }

    // 门锁
    val isLocked: Boolean? get() = bool(VehicleSignal.DriverDoorLocked)

    val doorControlAllowed: Boolean get() = bool(VehicleSignal.DoorControlAllowed) ?: true

    val trunkOpen: Boolean? get() = bool(VehicleSignal.TrunkOpen)

    val frontTrunkOpen: Boolean? get() = bool(VehicleSignal.FrontTrunkOpen)

    val anyDoorOpen: Boolean
        get() = listOf(
            VehicleSignal.DriverDoor,
            VehicleSignal.PassengerDoor,
            VehicleSignal.LeftRearDoor,
            VehicleSignal.RightRearDoor,
        ).any { bool(it) == true }

    // 车窗（对外一律是开度百分比：0 关闭、100 全开）
    /// 这台车能不能远程控车窗。
    ///
    /// **支持位单独用判不出来**：两台 T03 实测（2026-08-10），一台能控、一台不能，
    /// `isSupportWindowsRemoteControl` **都报 `2`**。官方那条 `== 2` 是必要不充分条件。
    ///
    /// 真正的分水岭是**四个开度字段在不在**：能控的那台 60 个字段，比不能控的多且只多
    /// `leftFrontWindowPercent` 那四个开度；不能控的那台只有 `*WindowStatus` 四个开合状态位。
    /// 讲得通——电动升降窗的电机有位置反馈才报得出开度，手摇窗只有一组给防盗用的开关传感器。
    ///
    /// **这条只对语义名那套（S01 / T03）成立，绝不能推广到数字口径**：C11 增程版实测
    /// 四个开度全缺，但它的车窗是能控的，而且数字口径那套压根不报支持位——
    /// 官方在那套解析里直接把车窗开关置 true。所以按「有没有报支持位」区分两套口径。
    val windowsRemoteSupported: Boolean
        get() {
            // 没报支持位 = 数字口径那套，官方无条件放行。
            val flag = raw(VehicleSignal.WindowsRemoteSupported) ?: return true
            if (flag != "2") return false
            return raw(VehicleSignal.LeftFrontWindow) != null ||
                raw(VehicleSignal.RightFrontWindow) != null ||
                raw(VehicleSignal.LeftRearWindow) != null ||
                raw(VehicleSignal.RightRearWindow) != null
        }

    private fun windowOpenness(signal: VehicleSignal): Int? =
        int(signal)?.let { schema.windowScale.openness(it) }

    /// 单扇窗的开合状态位。官方判据原样照抄：**非 `"0"` 即开**，不是 `== "2"`——
    /// 这组信号不止 0/2 两个取值，只认 2 会把别的开启档漏成「关着」。
    ///
    /// **布尔字面量要先认**：T03 这组状态位报的是 `"true"` / `"false"`（实测），
    /// 而 `"false" != "0"` 是成立的——直接套官方判据，四扇关好的窗会全报成开着。
    /// 数字口径那组不受影响：`"0"` 走布尔分支同样是 false，`"2"` 认不出布尔、
    /// 落回 `!= "0"` 仍是开着。
    private fun windowOpenFlag(signal: VehicleSignal): Boolean? {
        val value = raw(signal)
        if (value.isNullOrEmpty()) return null
        return bool(signal) ?: (value != "0")
    }

    /// 从开度字段判开没开。判据按车型各自的源码来（S01 是 `!= 10`、T03 是 `!= 0`），
    /// 不是统一的「百分比 > 0」。
    private fun windowOpenByOpenness(signal: VehicleSignal): Boolean? =
        int(signal)?.let { schema.windowScale.isOpen(it) }

    val leftFrontWindow: Int? get() = windowOpenness(VehicleSignal.LeftFrontWindow)

    val rightFrontWindow: Int? get() = windowOpenness(VehicleSignal.RightFrontWindow)

    val leftRearWindow: Int? get() = windowOpenness(VehicleSignal.LeftRearWindow)

    val rightRearWindow: Int? get() = windowOpenness(VehicleSignal.RightRearWindow)

    val leftFrontWindowOpen: Boolean? get() = windowOpenFlag(VehicleSignal.LeftFrontWindowOpen)

    val rightFrontWindowOpen: Boolean? get() = windowOpenFlag(VehicleSignal.RightFrontWindowOpen)

    val leftRearWindowOpen: Boolean? get() = windowOpenFlag(VehicleSignal.LeftRearWindowOpen)

    val rightRearWindowOpen: Boolean? get() = windowOpenFlag(VehicleSignal.RightRearWindowOpen)

    /// 有没有窗开着。读不到任何一路车窗信号时是 null——不知道不等于关好了。
    ///
    /// **两组信号取或：任何一路说开就算开**，不分主次。
    ///
    /// 先前是「状态位优先、开度兜底」，被真车打脸：2026-08-10 那台 T03 车窗实际开着，
    /// 四扇开度都报 `18`，而四个 `*WindowStatus` **仍然全报 `false`**（车况是 34 秒前的，
    /// 不是没刷新）。状态位优先于是界面说「已关」——该报的时候不报，比不知道更糟。
    ///
    /// 反过来「开度优先」也不对：官方在两套口径上判据本来就不一样——数字口径（C11）
    /// 判开合读的是状态位 `1693…1696`（开度那组只喂 3D 车模动画），而语义名口径的
    /// T03 分支判的是开度 `leftFrontWindowPercent != 0`。真按开度优先，
    /// C11 那边「开度报 0、状态位说开」的情形会被读成关着。
    ///
    /// 取或同时满足两边，而且方向是安全的：宁可多报一次「窗开着」，不能漏报。
    val anyWindowOpen: Boolean?
        get() {
            val readings = opennessWindowSignals.map { windowOpenByOpenness(it) } +
                listOf(leftFrontWindowOpen, rightFrontWindowOpen, leftRearWindowOpen, rightRearWindowOpen)
            if (readings.none { it != null }) return null
            return readings.any { it == true }
        }

    /// 这台车按开度口径实际有的车窗。
    ///
    /// S01（invertedTen）是两门轿跑，**没有后窗**——车端后窗字段恒报占位 0，
    /// 而倒序刻度里 0 恰好是「全开」。把后窗算进来，关好的 S01 会因为那个占位 0
    /// 被读成「全开」，整车永远显示车窗开着。所以倒序刻度只认前两扇；
    /// percent（C11 / T03）那套后窗是真的，四扇全认。
    private val opennessWindowSignals: List<VehicleSignal>
        get() = if (schema.windowScale == WindowScale.InvertedTen) {
            listOf(VehicleSignal.LeftFrontWindow, VehicleSignal.RightFrontWindow)
        } else {
            listOf(
                VehicleSignal.LeftFrontWindow, VehicleSignal.RightFrontWindow,
                VehicleSignal.LeftRearWindow, VehicleSignal.RightRearWindow,
            )
        }

    /// 四扇窗里开得最大的那个开度。车不报开度时是 null——**这和「关着」是两回事**，
    /// 界面得靠 `anyWindowOpen` 才知道到底开没开。
    val maxWindowOpenness: Int?
        get() = opennessWindowSignals.mapNotNull { windowOpenness(it) }.maxOrNull()

    /// 锁车成功那一刻还开着的东西，给「已上锁，但 XX 还开着」那句提示用。
    ///
    /// 只列**读得到且确实开着**的项，读不到的一律不算——不知道不等于开着，也不能猜。
    /// 单扇窗的判据跟 [anyWindowOpen] 同一套（开度和状态位取或），四扇都开就合成一个「车窗」。
    /// 遮阳帘不在里面：它开着不是隐患，锁车时不必提醒。
    val openItemsAfterLock: List<String>
        get() {
            val items = mutableListOf<String>()
            if (anyDoorOpen) items.add("车门")
            val windows = listOf(
                Triple("主驾车窗", VehicleSignal.LeftFrontWindow, leftFrontWindowOpen),
                Triple("副驾车窗", VehicleSignal.RightFrontWindow, rightFrontWindowOpen),
                Triple("左后车窗", VehicleSignal.LeftRearWindow, leftRearWindowOpen),
                Triple("右后车窗", VehicleSignal.RightRearWindow, rightRearWindowOpen),
            )
            val opened = windows.filter { (_, signal, flag) ->
                val byOpenness = if (signal in opennessWindowSignals) windowOpenByOpenness(signal) else null
                byOpenness == true || flag == true
            }.map { it.first }
            if (opened.size == windows.size) items.add("车窗") else items.addAll(opened)
            if (sunroofOpen == true) items.add("天窗")
            if (trunkOpen == true) items.add("尾门")
            if (frontTrunkOpen == true) items.add("前备箱")
            return items
        }

    // 空调
    val acOn: Boolean get() = bool(VehicleSignal.AcSwitch) ?: false

    /// -1 表示无有效值；夹取到 18…32。
    val acSetting: Int?
        get() {
            val value = int(VehicleSignal.AcSetting) ?: return null
            if (value < 0) return null
            return value.coerceIn(18, 32)
        }

    val acFanLevel: Int? get() = int(VehicleSignal.AcFanLevel)

    val acModeRaw: Int? get() = int(VehicleSignal.AcMode)

    /// 车上当前的空调模式。车没上报就是 null。
    val climateMode: ClimateMode? get() = schema.climateModeCoding.mode(acModeRaw)

    /// true=内循环。
    ///
    /// 数字口径（C11 那批）原先**没有这一项**，空调页那张「内循环 / 外循环」卡只能显示本机草稿。
    /// 2026-11-19 补上信号 `1943` 后两套口径都能读到真实状态，`syncDraftsFromState` 会自动对齐。
    val acCircleIn: Boolean? get() = bool(VehicleSignal.AcCircleMode)

    /// 前挡除雾（除霜）状态位。数字口径信号 `1945`，读不到 null。
    val windshieldDefrostOn: Boolean? get() = bool(VehicleSignal.WindshieldDefrost)

    /// 快速降温 / 快速制热是否正在执行。数字口径信号 `2669` / `2681`。
    val rapidCoolingOn: Boolean? get() = bool(VehicleSignal.RapidCooling)
    val rapidHeatingOn: Boolean? get() = bool(VehicleSignal.RapidHeating)

    /// true=auto，false=manual
    val acAutoMode: Boolean? get() = bool(VehicleSignal.AcTempMode)

    val indoorTemp: Double? get() = double(VehicleSignal.IndoorTemp)

    val outdoorTemp: Double? get() = double(VehicleSignal.OutdoorTemp)

    // 胎压
    val tirePressures: List<TirePressure>
        get() = listOf(
            TirePressure(
                "左前",
                double(VehicleSignal.LeftFrontTirePressure),
                raw(VehicleSignal.LeftFrontTireState) == "1",
            ),
            TirePressure(
                "右前",
                double(VehicleSignal.RightFrontTirePressure),
                raw(VehicleSignal.RightFrontTireState) == "1",
            ),
            TirePressure(
                "左后",
                double(VehicleSignal.LeftRearTirePressure),
                raw(VehicleSignal.LeftRearTireState) == "1",
            ),
            TirePressure(
                "右后",
                double(VehicleSignal.RightRearTirePressure),
                raw(VehicleSignal.RightRearTireState) == "1",
            ),
        )

    val hasTireData: Boolean get() = tirePressures.any { it.kPa != null }

    val hasTireWarning: Boolean get() = tirePressures.any { it.warning }

    // 位置
    val latitude: Double? get() = double(VehicleSignal.Latitude)

    val longitude: Double? get() = double(VehicleSignal.Longitude)

    val privacyGPSAllowed: Boolean get() = bool(VehicleSignal.PrivacyGPS) ?: true

    val collectTime: String? get() = raw(VehicleSignal.CollectTime)

    /// 车端采集这份车况的时刻（毫秒）。读不到或不可信时是 null。
    ///
    /// 和 `collectedAt` 是两回事：后者只说明本机什么时候拉的，轮询拉得再勤它都是「刚刚」。
    /// 车休眠着不上报时，服务端会把同一份旧数据一直发回来，只有这个字段能看出车况到底有多旧。
    val reportedAt: Long? get() = collectTime?.let { parseReportTime(it) }

    val totalMileage: Int? get() = int(VehicleSignal.TotalMileage)

    /// 可以对外展示的车辆坐标。隐私模式下车端不给真实位置，非法值也一并挡掉。
    ///
    /// 注意这是 **GCJ-02**（车端就是这个坐标系），高德地图直接吃，不要转换。
    val shareableCoordinate: Coordinate?
        get() {
            if (!privacyGPSAllowed) return null
            val lat = latitude ?: return null
            val lon = longitude ?: return null
            if (abs(lat) > 90 || abs(lon) > 180 || (lat == 0.0 && lon == 0.0)) return null
            return Coordinate(lat, lon)
        }

    companion object {
        private val digitsOnly = Regex("^\\d+$")

        /// 充电上限。数字口径的车不把它当信号报，官方是从 commonConfig 的
        /// `config."3".percent` 读的——和完整的 `ChargePlan` 同源，只是这里只要那一个数。
        fun chargePlanLimitFromConfig(config: JsonValue?): Int? = ChargePlan.fromConfig(config)?.percent

        /// 完整充电计划，percent 与 chargePlanLimitFromConfig 同源。config 缺计划时返回 null。
        fun chargePlanFromConfig(config: JsonValue?): ChargePlan? = ChargePlan.fromConfig(config)

        /// 车端时间戳解析。两种形态都见过：`2026-08-05 09:40:12` 这样的字面时间，
        /// 以及秒/毫秒 epoch。字面时间不带时区，按本机时区解释——车和手机在同一个国家。
        ///
        /// 解析不出、或者落在「三十天前到五分钟后」这个窗口之外的，一律当读不到：
        /// 车端时间是拿来标注车况新旧的，宁可退回本机拉取时间，也不能报一个 1970 年。
        fun parseReportTime(raw: String, now: Long = System.currentTimeMillis()): Long? {
            val text = raw.trim()
            if (text.isEmpty()) return null
            val millis: Long
            if (digitsOnly.matches(text)) {
                val value = text.toDoubleOrNull() ?: return null
                if (!value.isFinite() || value <= 0) return null
                // 十位数是秒，十三位数是毫秒。按量级判断，不数位数。
                millis = if (value < 1e11) (value * 1000).toLong() else value.toLong()
            } else {
                // 日期和时间之间可能是空格也可能是 T，秒可以缺省，末尾的毫秒/时区后缀直接扔掉。
                val halves = text.replace('T', ' ').split(" ")
                val date = halves[0].split("-")
                val time = if (halves.size > 1) halves[1].split(":") else emptyList()
                if (date.size != 3 || time.size < 2) return null
                val year = date[0].toIntOrNull() ?: return null
                val month = date[1].toIntOrNull() ?: return null
                val day = date[2].toIntOrNull() ?: return null
                val hour = time[0].toIntOrNull() ?: return null
                val minute = time[1].toIntOrNull() ?: return null
                // 秒位可能带小数（`12.480`），取整。
                val second = if (time.size > 2) (time[2].toDoubleOrNull() ?: return null).toInt() else 0
                val calendar = Calendar.getInstance()
                calendar.clear()
                calendar.set(year, month - 1, day, hour, minute, second)
                millis = calendar.timeInMillis
            }
            // 允许略微超前：车端时钟和手机差几十秒很常见，不该因此判定为不可信。
            if (millis > now + 5 * 60 * 1000L || millis < now - 30 * 24 * 3600 * 1000L) return null
            return millis
        }
    }
}

data class TirePressure(val label: String, val kPa: Double?, val warning: Boolean)

// MARK: - 控车命令

/// 车窗控制界面上的一个可选档位。开度百分比：0 关闭、100 全开。
data class WindowPreset(val label: String, val openness: Int)

/// 指令的预期终态类型。
enum class ExpectationKind {
    Locked, Climate, WindowPosition, TrunkOpen, FrontTrunkOpen, Sentinel,
    SeatLevel, SteeringWheelLevel, MirrorHeating, SunshadeOpen, SunroofOpen, Charging, Fridge,
    Unobservable,
}

/// 一条指令声明一个能在 signalMap 上验证的终态，轮询车况直到达成。
/// 下发成功只代表服务端受理，车可能还在休眠，实测要 5–10 秒才动作。
class ControlExpectation private constructor(
    val kind: ExpectationKind,
    val boolValue: Boolean = false,
    val intValue: Int = 0,
    // climate 专用
    val climateOn: Boolean = false,
    val temperature: Int? = null,
    val fanLevel: Int? = null,
    val mode: ClimateMode? = null,
    // 座椅专用
    val seatPosition: SeatPosition? = null,
    val seatChannel: SeatComfortChannel? = null,
    // 冰箱专用
    val fridgeSetting: FridgeSetting? = null,
) {
    val isObservable: Boolean get() = kind != ExpectationKind.Unobservable

    fun isSatisfied(state: VehicleState): Boolean = when (kind) {
        ExpectationKind.Locked -> state.isLocked == boolValue

        ExpectationKind.Climate -> {
            when {
                state.acOn != climateOn -> false
                !climateOn -> true
                else -> {
                    // 车端偶尔会夹取或省略某一项，缺值时不作为否决条件。
                    val tempOk = temperature == null ||
                        state.acSetting.let { it == null || it == temperature }
                    val fanOk = fanLevel == null ||
                        state.acFanLevel.let { it == null || it <= 0 || it == fanLevel }
                    val modeOk = mode == null ||
                        state.climateMode.let { it == null || it == mode }
                    tempOk && fanOk && modeOk
                }
            }
        }

        // 留 ±5 的容差：车窗停位不是数字精确的，T03 实测发 `50` 车报回 `51`，
        // 精确相等会把一次成功的控车判成「未收到车辆确认」。
        // S01 那边刻度本来就是 10 的整倍数，容差对它没有影响。
        ExpectationKind.WindowPosition ->
            state.leftFrontWindow?.let { abs(it - intValue) <= 5 } ?: false

        ExpectationKind.TrunkOpen -> state.trunkOpen == boolValue

        // 前备箱靠信号 1282 确认。**语义未经实车验证**：官方内部键名叫 `isFrontTrunkLock`，
        // 若真值方向和「开」相反，成功的控车会被误报成「未收到车辆确认」——
        // 实车验证后如有出入在这里修正方向。
        ExpectationKind.FrontTrunkOpen -> state.frontTrunkOpen == boolValue

        // 哨兵终态就看信号 3636 翻没翻到位（sentinelOn 由它派生）。
        ExpectationKind.Sentinel -> state.sentinelOn == boolValue

        ExpectationKind.SunshadeOpen -> state.sunshadeOpen == boolValue

        ExpectationKind.SunroofOpen -> state.sunroofOpen == boolValue

        // 启停充电（193）。照 leapauto 的实车规则：开始要等 `1149` 报 1；停止接受
        // 0（未在充）/ 2（本次已结束）/ 4（预约等待）/ 6（暂停）——3 是故障，不算「停下来了」。
        ExpectationKind.Charging -> {
            val charge = state.chargeState
            when {
                charge == null -> false
                boolValue -> charge == 1
                else -> charge in setOf(0, 2, 4, 6)
            }
        }

        ExpectationKind.SeatLevel -> {
            val position = seatPosition
            val channel = seatChannel
            position != null && channel != null && state.seatLevel(position, channel) == intValue
        }

        ExpectationKind.SteeringWheelLevel -> state.steeringWheelHeatLevel == intValue

        // 三个候选位里只要有一个报到期望值就算确认：`49`、`50`，还有 `1946`
        // （后风挡「及外后视镜」电加热除雾）。cmdid 440 到底动的是哪一个没验过，不赌一个。
        ExpectationKind.MirrorHeating -> listOf(
            state.int(VehicleSignal.LeftMirrorHeating)?.let { it > 0 },
            state.int(VehicleSignal.RightMirrorHeating)?.let { it > 0 },
            state.rearWindowHeatingOn,
        ).any { it == boolValue }

        // 开关必比；开机时再比模式、目标温度、风格，车端没报温度就跳过那项
        // （照空调那条「缺值不作否决」的宽松判法）。
        ExpectationKind.Fridge -> {
            val setting = fridgeSetting
            val fridge = state.fridgeState
            when {
                setting == null || fridge == null -> false
                fridge.enabled != setting.enabled -> false
                !setting.enabled -> true
                fridge.mode != setting.mode -> false
                fridge.targetTemp != null && fridge.targetTemp != setting.wireTemperature -> false
                else -> fridge.style == setting.style
            }
        }

        ExpectationKind.Unobservable -> false
    }

    companion object {
        fun locked(expected: Boolean) = ControlExpectation(ExpectationKind.Locked, boolValue = expected)

        fun climate(on: Boolean, temperature: Int?, fanLevel: Int?, mode: ClimateMode?) =
            ControlExpectation(
                ExpectationKind.Climate,
                climateOn = on,
                temperature = temperature,
                fanLevel = fanLevel,
                mode = mode,
            )

        fun windowPosition(expected: Int) =
            ControlExpectation(ExpectationKind.WindowPosition, intValue = expected)

        fun trunkOpen(expected: Boolean) =
            ControlExpectation(ExpectationKind.TrunkOpen, boolValue = expected)

        fun frontTrunkOpen(expected: Boolean) =
            ControlExpectation(ExpectationKind.FrontTrunkOpen, boolValue = expected)

        fun sentinel(expected: Boolean) =
            ControlExpectation(ExpectationKind.Sentinel, boolValue = expected)

        fun seatLevel(position: SeatPosition, channel: SeatComfortChannel, level: Int) =
            ControlExpectation(
                ExpectationKind.SeatLevel,
                intValue = level,
                seatPosition = position,
                seatChannel = channel,
            )

        fun steeringWheelLevel(level: Int) =
            ControlExpectation(ExpectationKind.SteeringWheelLevel, intValue = level)

        fun mirrorHeating(on: Boolean) = ControlExpectation(ExpectationKind.MirrorHeating, boolValue = on)

        fun sunshadeOpen(open: Boolean) = ControlExpectation(ExpectationKind.SunshadeOpen, boolValue = open)

        fun sunroofOpen(open: Boolean) = ControlExpectation(ExpectationKind.SunroofOpen, boolValue = open)

        fun charging(start: Boolean) = ControlExpectation(ExpectationKind.Charging, boolValue = start)

        fun fridge(setting: FridgeSetting) = ControlExpectation(ExpectationKind.Fridge, fridgeSetting = setting)

        fun unobservable() = ControlExpectation(ExpectationKind.Unobservable)
    }
}

/// 车辆驻车时自动上传的最近一张照片。接口没有历史列表，也不会触发车辆临时拍照。
class ParkingPhoto private constructor(
    val available: Boolean,
    val url: String?,
    val uploadTime: String?,
    val raw: JsonValue,
) {
    /// 上传时刻的中文写法。
    ///
    /// 车端给的是纪元时间字符串，秒和毫秒两种都出现过——大于 10^10 的按毫秒算。
    /// 不是数字就原样透出，宁可显示个奇怪的字符串，也不要凭空编一个时间出来。
    val displayUploadTime: String?
        get() {
            val text = uploadTime ?: return null
            val timestamp = text.toDoubleOrNull()
            if (timestamp == null || !timestamp.isFinite()) return text
            val millis = if (timestamp > 1e10) timestamp else timestamp * 1000
            val calendar = Calendar.getInstance().apply { timeInMillis = millis.toLong() }
            val pad = { value: Int -> if (value < 10) "0$value" else "$value" }
            return "${calendar.get(Calendar.YEAR)}年${calendar.get(Calendar.MONTH) + 1}月" +
                "${calendar.get(Calendar.DAY_OF_MONTH)}日 " +
                "${pad(calendar.get(Calendar.HOUR_OF_DAY))}:${pad(calendar.get(Calendar.MINUTE))}"
        }

    companion object {
        fun fromResponse(response: JsonValue): ParkingPhoto {
            val data = response.get("data")
            val url = data?.get("fileUrl")?.stringValue?.trim()?.let { secureImageURL(it) }
            val uploadTime = data?.get("uploadTime")?.stringValue?.takeIf { it.isNotEmpty() }
            return ParkingPhoto(url != null, url, uploadTime, response)
        }

        /// 老接口仍可能返回 `http://` 图片地址；图片服务支持 HTTPS，统一在信任边界升级。
        /// 拆不出主机的一律当无效地址丢掉，免得把一段畸形文本当图片去下载。
        private fun secureImageURL(text: String): String? {
            if (text.isEmpty()) return null
            val normalized = if (text.startsWith("//")) "https:$text" else text
            val lower = normalized.lowercase()
            val rest = when {
                lower.startsWith("https://") -> normalized.substring(8)
                lower.startsWith("http://") -> normalized.substring(7)
                else -> return null
            }
            // 主机段止于第一个 `/`、`?`、`#`，三者取最靠前的一个。
            val cut = listOf("/", "?", "#").mapNotNull { mark ->
                rest.indexOf(mark).takeIf { it >= 0 }
            }.minOrNull() ?: rest.length
            var authority = rest.substring(0, cut)
            val tail = rest.substring(cut)
            if (authority.isEmpty()) return null
            // 升到 HTTPS 之后 `:80` 就不再是那个端口的意思了，去掉走默认 443。
            if (authority.endsWith(":80")) {
                authority = authority.dropLast(3)
                if (authority.isEmpty()) return null
            }
            return "https://$authority$tail"
        }
    }
}

/// 一条待发送的远控指令：cmdid + state JSON。
data class LeapCommand(
    val cmdid: String,
    val stateJSON: String,
    val label: String,
    val requiresOperationPassword: Boolean = true,
    val expectation: ControlExpectation = ControlExpectation.unobservable(),
    /// 这条指令有没有对应的蓝牙帧。只有解锁/上锁有——车端 BLE 只认这两条。
    /// 非空时首页会先试蓝牙直连，写入前不可用才回退网络远控。
    val bleCommand: LeapBLEControlCommand? = null,
) {
    val isAppointment: Boolean get() = cmdid in appointmentCmdIds

    /// 这条指令会动空调设定。取消或失败时界面上的草稿要退回去。
    val changesClimate: Boolean get() = cmdid == "170"

    companion object {
        /// 预约类命令走另一个端点，且优先打到 appCenter。
        private val appointmentCmdIds = setOf("161", "171", "361", "392")

        fun lock() = LeapCommand(
            "110",
            """{"value":"lock"}""",
            "上锁",
            true,
            ControlExpectation.locked(true),
            LeapBLEControlCommand.Lock,
        )

        fun unlock() = LeapCommand(
            "110",
            """{"value":"unlock"}""",
            "解锁",
            true,
            ControlExpectation.locked(false),
            LeapBLEControlCommand.Unlock,
        )

        /// 这台车能不能远程关尾门。
        ///
        /// 只有 C11 那套口径的车型能，S01 / T03 不能，三条依据指向同一件事：
        /// 零跑官方 App 在这些车上只给「打开尾门」、没有关闭；真车发过 `cmdid 130` 的
        /// `value=false`，车没有任何反应；车本身也没有能自己合上的电动尾门——
        /// 弹得开、合不上是物理限制，不是接口没适配。
        fun trunkSupportsClose(carType: String): Boolean = !CarTypeFamily.isLegacyFamily(carType)

        /// 关闭发的 `false` 没有文档依据，是照着开启那条推的。车不认的话指令会静默失败——
        /// 等不到 `trunkOpen` 翻转，App 会如实报「未收到车辆确认」，不会有别的动作。
        /// 界面和小组件都先过 `trunkSupportsClose`，关不了的车型根本走不到这条分支。
        fun trunk(open: Boolean = true) = LeapCommand(
            "130",
            if (open) """{"value":"true"}""" else """{"value":"false"}""",
            if (open) "打开尾门" else "关闭尾门",
            true,
            ControlExpectation.trunkOpen(open),
        )

        /// 哨兵模式开 / 关。cmdid=400，抓包实测。
        ///
        /// **state 的 key 是 `operation` 不是别的命令用的 `value`**：开 `{"operation":"on"}`、
        /// 关 `{"operation":"off"}`。和尾门（130）一样是受权控命令，需操作密码。
        /// 终态用车况的 sentinelOn（信号 3636）确认，和空调/门锁同一套等待机制。
        fun sentinel(on: Boolean) = LeapCommand(
            "400",
            if (on) """{"operation":"on"}""" else """{"operation":"off"}""",
            if (on) "开启哨兵" else "关闭哨兵",
            true,
            ControlExpectation.sentinel(on),
        )

        fun horn() = LeapCommand("120", """{"value":"true"}""", "鸣笛寻车")

        /// 天幕遮阳帘开 / 关。cmdid 240（实车验证过 cmdid）：开 `{"value":"10"}`、关 `{"value":"0"}`。
        ///
        /// **2026-11-19 起可确认**：遮阳帘开度是信号 `1724`（0…100），车主 C16 在报。
        /// 但不是每台车都报，所以由调用方告诉这条指令「这车报不报」——报就等信号翻转，
        /// 不报仍走 unobservable，发完如实说「已发送」。不能一刀切成可观测：
        /// 不报的车会永远等不到翻转，每次都误报「未收到车辆确认」。
        fun sunshade(open: Boolean, observable: Boolean = false) = LeapCommand(
            "240",
            if (open) """{"value":"10"}""" else """{"value":"0"}""",
            if (open) "打开遮阳帘" else "关闭遮阳帘",
            true,
            if (observable) ControlExpectation.sunshadeOpen(open) else ControlExpectation.unobservable(),
        )

        /// 天窗开 / 关。cmdid 300：开 `{"value":"1"}`、关 `{"value":"0"}`。
        ///
        /// 这里原先写着「任何口径的车况里都没有天窗字段」——那是错的：天窗开度是信号 `1718`
        /// （0…10）。只是车主那台 C16 没有可开启天窗、不报这一项，所以同遮阳帘按车决定可不可观测。
        fun sunroof(open: Boolean, observable: Boolean = false) = LeapCommand(
            "300",
            if (open) """{"value":"1"}""" else """{"value":"0"}""",
            if (open) "打开天窗" else "关闭天窗",
            true,
            if (observable) ControlExpectation.sunroofOpen(open) else ControlExpectation.unobservable(),
        )

        /// 前备箱开 / 关。cmdid 131：开 `{"value":"100"}`、关 `{"value":"0"}`。
        /// 确认走车况信号 1282（`VehicleState.frontTrunkOpen`，仅数字口径有——
        /// 支持判据本来就把 legacy 车型挡在门外，见 `Vehicle.supportsFrunk`）。
        /// 关闭那条和尾门一样是照开启推的：车不认就等不到 1282 翻转，如实报「未收到车辆确认」。
        fun frunk(open: Boolean) = LeapCommand(
            "131",
            if (open) """{"value":"100"}""" else """{"value":"0"}""",
            if (open) "打开前备箱" else "关闭前备箱",
            true,
            ControlExpectation.frontTrunkOpen(open),
        )

        fun batteryPreheat(on: Boolean) = LeapCommand(
            "160",
            if (on) """{"value":"ptcon"}""" else """{"value":"ptcoff"}""",
            if (on) "电池预热开启" else "电池预热关闭",
        )

        /// 预约电池预热。cmdid 161（2026-08-18 实测）：预约接口要求把预约对象包在
        /// `controls` 数组里，`on` 是字符串 `"1"`/`"0"`，`set_id` 实测格式是
        /// 「前缀_VIN_创建毫秒」（官方安卓端就用 `Android_`），`update_time` 与 set_id
        /// 尾部同为那个毫秒时间戳。
        ///
        /// `days` 用预约类指令共用的星期编码：**0 = 周日**、1 = 周一 … 6 = 周六
        /// （见 `AppointmentWeekday`）。2026-11-19 之前界面给周日发的是 7，已改（同 iOS）。
        fun batteryPreheatAppointment(
            on: Boolean,
            startTime: Long,
            days: List<Int>,
            vin: String,
            setID: String? = null,
        ): LeapCommand {
            val timestamp = System.currentTimeMillis()
            val appointmentID = setID?.takeIf { it.isNotEmpty() }
                ?: "${LeapConstants.PLATFORM_TAG}_${vin}_$timestamp"
            val state = """{"controls":[{"days":[${days.joinToString(",")}]""" +
                ""","on":"${if (on) "1" else "0"}"""" +
                ""","set_id":"$appointmentID","start_time":"${appointmentTime(startTime)}"""" +
                ""","update_time":"$timestamp"}]}"""
            return LeapCommand("161", state, if (on) "预约电池预热" else "关闭预约预热")
        }

        /// 预约接口要的时刻格式：`yyyy-MM-dd HH:mm:ss`，本机时区。
        private fun appointmentTime(millis: Long): String {
            val calendar = Calendar.getInstance().apply { timeInMillis = millis }
            val pad = { value: Int -> if (value < 10) "0$value" else "$value" }
            return "${calendar.get(Calendar.YEAR)}-${pad(calendar.get(Calendar.MONTH) + 1)}" +
                "-${pad(calendar.get(Calendar.DAY_OF_MONTH))} " +
                "${pad(calendar.get(Calendar.HOUR_OF_DAY))}:${pad(calendar.get(Calendar.MINUTE))}" +
                ":${pad(calendar.get(Calendar.SECOND))}"
        }

        /// 远程开始 / 停止充电。cmdid 193，走普通远控端点。
        ///
        /// **停止发 `finish`，不是 `stop`**：leapauto 2026-10-31 官方抓包确认车端 OBC 只认
        /// `start` / `finish`，发 `stop` 服务端照收、车不理。确认判据见 `ExpectationKind.Charging`。
        fun charging(start: Boolean) = LeapCommand(
            "193",
            if (start) """{"value":"start"}""" else """{"value":"finish"}""",
            if (start) "开始充电" else "停止充电",
            true,
            ControlExpectation.charging(start),
        )

        /// 解锁充电枪。cmdid 192，state 的 key 是 `operation`（同哨兵，不是 `value`）。
        ///
        /// **确认不了**，只能如实说「已发送」。看着能用的信号 `94`（官方读作慢充枪锁止）不行：
        /// C11 四种情形实测过，停充未拔枪时它已经是 0——拿它当判据，「解锁」一发出就被判成功，
        /// 是假确认。插枪位 `47` 也不行：解锁后枪还插着，要人去拔它才翻。
        fun unlockChargingGun() = LeapCommand("192", """{"operation":"unlock"}""", "解锁充电枪")

        /// 健康充电开关。cmdid 480（2026-08-18 实测）：开 `{"value":"on"}`、关 `{"value":"off"}`，
        /// 走普通远控端点。车况里可判定：信号 `48`（见 `VehicleState.healthyChargeOn`），
        /// 回读靠下次拉车况。
        fun healthyCharge(on: Boolean) = LeapCommand(
            "480",
            if (on) """{"value":"on"}""" else """{"value":"off"}""",
            if (on) "开启健康充电" else "关闭健康充电",
        )

        /// 充电上限 + 预约充电（合并一条，cmdid 190；2026-08-18 实测）。
        ///
        /// 写入字段名与读取 `config."3"` 不同、且全小写：`percent→chargesoc`、`isEnable→chargeEnable`、
        /// `beginTime→starttime`、`endTime→endtime`，`cycles`/`circulation`/`recharge` 同名。
        /// 只改充电上限、不开预约充电也走这条，`chargeEnable=0`。`circulation`/`recharge` 含义未确认，
        /// 原样回填车辆上报的那份（读不到则按实测样本默认 1/0），不擅自改。车况无判定位，
        /// 所以 expectation 留 unobservable。
        fun chargePlan(
            limitPercent: Int,
            scheduledEnabled: Boolean,
            startTime: String,
            endTime: String,
            cycles: List<Boolean>,
            circulation: Int = 1,
            recharge: Int = 0,
        ): LeapCommand {
            val bits = (0 until 7).joinToString(",") { if (cycles.getOrElse(it) { false }) "1" else "0" }
            val soc = limitPercent.coerceIn(50, 100)
            val state = """{"chargeEnable":${if (scheduledEnabled) 1 else 0},"chargesoc":$soc""" +
                ""","circulation":$circulation,"cycles":"$bits"""" +
                ""","endtime":"$endTime","recharge":$recharge,"starttime":"$startTime"}"""
            return LeapCommand("190", state, "充电计划")
        }

        /// 这台车的车窗远控能做到哪几档。
        ///
        /// 四档是统一的开度百分比，各车型下发时再按自己的刻度换算（见 windowValue）。
        /// S01 / T03 原先少一个「半开」，那是没来由的：S01 的 `5`（倒序 0…10 的中点）
        /// 和 T03 的 `50` 都是能发的值，T03 那个 `50` 车主还真车验过就是开一半。
        fun windowPresets(carType: String): List<WindowPreset> = listOf(
            WindowPreset("关闭", 0),
            WindowPreset("微开", 20),
            WindowPreset("半开", 50),
            WindowPreset("全开", 100),
        )

        /// 给滑杆的车型：S01 和 T03。
        ///
        /// 能不能给滑杆看两条：刻度得是连续的，且下发和上报得是同一套刻度——
        /// 松手后车报回来的位置要对得上滑杆停的位置，否则就是「拖到哪儿都没有回音」。
        ///
        /// S01 是 0…10 十一个刻度，早就验过。**T03 是 2026-08-10 验的**，而且比 S01 还干净：
        /// 下发 `50` 车报回 `51`（那个 1 是电机停位精度），刻度是真正的 0…100。
        ///
        /// C11 那组仍然不给：下发 0…10、上报 0…100，两边不是一套。
        fun windowSupportsSlider(carType: String): Boolean = CarTypeFamily.isLegacyFamily(carType)

        fun windowValue(openness: Int, carType: String): String {
            val value = openness.coerceIn(0, 100)
            if (CarTypeFamily.isS01(carType)) {
                return WindowScale.InvertedTen.rawValue(value).toString()
            }
            // T03：下发就是 0…100 的百分比，**线性**，原样发。
            //
            // 这里原先抄 demo 映射成 `0 / 20 / 50` 三档，把 `50` 当成「全开档位码」——
            // 2026-08-10 真车证伪：车主点「全开」（我们发 `50`），**车窗只开了一半**。
            // `50` 就是 50%，不是全开。全开得发 `100`。
            if (CarTypeFamily.isT03(carType)) return value.toString()
            // C11 及其余车型：上报 0…100，下发 0…10，差十倍。
            return (value / 10).toString()
        }

        fun window(openness: Int, carType: String): LeapCommand {
            val value = windowValue(openness, carType)
            // S01 和 T03 的下发刻度和上报刻度是同一套，比对上报值才有意义。
            // C11 那套口径两边不是一套：下发 0…10、上报 0…100，发 `2` 之后车报回来是不是
            // 正好 20 至今没验过，拿它比对会误报未响应。
            val expectation = if (CarTypeFamily.isLegacyFamily(carType)) {
                ControlExpectation.windowPosition(openness.coerceIn(0, 100))
            } else {
                ControlExpectation.unobservable()
            }
            return LeapCommand("230", """{"value":"$value"}""", "车窗控制", true, expectation)
        }

        fun climate(
            on: Boolean,
            temperature: Int,
            fanLevel: Int,
            mode: ClimateMode,
            circleIn: Boolean,
            windshield: Boolean,
            // 出风位置。协议本来支持分区（`all` / `wshld` / 座位位置），我们一直硬编码 `all`——
            // 连前挡除雾都在往全车吹，白耗一半风量。现在由调用方给，默认仍是 `all`。
            position: String = "all",
        ): LeapCommand {
            // 自动走 operate 这一层，真车验证过；mode 那一层是死路。
            val operate = if (!on) "off" else if (mode == ClimateMode.Auto) "auto" else "manual"
            val state = """{"operate":"$operate","temperature":"$temperature"""" +
                ""","windlevel":"$fanLevel"""" +
                ""","mode":"${if (on) mode.wireValue else "nohotcold"}"""" +
                ""","circle":"${if (circleIn) "in" else "out"}"""" +
                ""","wshld":"${if (windshield) "1" else "0"}","position":"$position"}"""
            return LeapCommand(
                "170",
                state,
                if (on) "空调开启" else "空调关闭",
                true,
                ControlExpectation.climate(
                    on,
                    if (on) temperature else null,
                    if (on) fanLevel else null,
                    if (on) mode else null,
                ),
            )
        }

        fun quickCool() =
            climate(true, 18, 7, ClimateMode.Cold, circleIn = true, windshield = false).copy(label = "极速降温")

        fun quickHeat() =
            climate(true, 32, 7, ClimateMode.Hot, circleIn = true, windshield = false).copy(label = "极速升温")

        /// 快速除味（leapauto `QUICK_DEODORIZE_STATE`，2026-11-19 对照补上）：
        /// 通风（`nohotcold`）+ **外循环** + 7 档 + 不开除雾，24 ℃ 只是占位——
        /// 通风模式下温度不起作用，但协议要求字段齐全。
        ///
        /// **温度不进判据**：通风模式下车会不会把设定温度改成 24 没验过，车若保留原温度，
        /// 带着温度比对就会把成功误报成「未收到车辆确认」。外循环 `1943` 也不进判据。
        fun deodorize() =
            climate(true, 24, 7, ClimateMode.Vent, circleIn = false, windshield = false).copy(
                label = "快速除味",
                expectation = ControlExpectation.climate(true, null, 7, ClimateMode.Vent),
            )

        /// 前挡除雾。
        ///
        /// **2026-11-19 修正两处方向错误**（同 iOS）：
        /// - `circle` 原先发 `in`（内循环）。除雾的物理前提是把干燥的外气引进来，
        ///   内循环等于把车里的湿气闷住再吹上玻璃，方向是反的。改 `out`。
        /// - `position` 原先硬编码 `all` 往全车吹，一半风量白耗。改 `wshld`。
        ///
        /// 温度和模式**故意不跟 leapauto**（它发 24 ℃ 制冷靠压缩机除湿）：保留 32 ℃ 制热 7 档——
        /// 热风同样是干燥空气，冬天结霜的玻璃上更对症。
        fun defrost() =
            climate(
                true, 32, 7, ClimateMode.Hot,
                circleIn = false, windshield = true, position = "wshld",
            ).copy(label = "前挡除雾")
    }
}

/// 控车下发后服务端返回的回执。
data class ControlReceipt(val msgID: String, val label: String, val sentAt: Long)

/// 最近一次控车的完整经过，存起来用于排查。
///
/// 存在的理由：回执接口 `/appremotectl/query` 的返回结构没有任何已验证样本，
/// 要把「执行中」和「车拒绝了」区分开，得先拿真车攒出几份真实响应，才能写出可信的码表。
data class ControlDiagnostic(
    val label: String,
    val cmdid: String,
    val msgID: String,
    /// 下发时刻，毫秒。
    val sentAt: Long,
    val outcome: Outcome,
    /// 车况确认耗时（秒）。这是判断「窗口该设多长」的唯一实测依据。
    val elapsed: Double,
    val pollCount: Int,
    /// 回执采样，按时间排列。确认之后还会再采一次——那一次才可能拿到终态值。
    val receiptResponses: List<ReceiptSample>,
    val errorMessage: String? = null,
) {
    enum class Outcome {
        /// 车况确认已生效。
        Confirmed,

        /// 窗口内没等到预期终态。
        TimedOut,

        /// 无可观测终态，只能确认已下发。
        SentOnly,

        /// 下发本身就失败了。
        Failed,
    }

    /// 一次回执采样。带时间戳是为了回答一个具体问题：
    /// 实测回执里 `code`/`result` 只表示「这次查询成功了」，真正的执行状态在 `data`，
    /// 而 `data` 在下发后 2/5/8 秒都是 `1`。这个 `1` 是「执行中」，
    /// 还是「已成功、只是车况接口滞后」？看 `data` 什么时候变值，和车况什么时候翻转一比就知道。
    data class ReceiptSample(
        /// 距下发的秒数。
        val at: Double,
        val body: String,
    )
}

// MARK: - 里程能耗统计

/// 里程能耗接口的时间窗（毫秒时间戳，闭区间）。
data class DrivingStatsRange(val begintime: Long, val endtime: Long) {

    /// 秒级区间。`getLastweekEC` 收的是**秒**，而同一个 drivingrecord 命名空间下的
    /// `mileage/energy/detail` 收毫秒。传错量纲不会报越界、也不返空，服务端一律回
    /// `code:2 请求参数含非法字符`——文案指向字符集，跟真实原因半点关系没有。
    /// 单独开两个属性而不是在调用点现除，是为了让这个坑能被测试守住。
    val begintimeSeconds: Long get() = begintime / 1000
    val endtimeSeconds: Long get() = endtime / 1000

    companion object {
        private const val DAY_MS = 86_400_000L
        private const val CN_OFFSET_MS = 8 * 3600_000L

        /// 最近 7 天（含今天），按北京时间整日边界——和官方「里程能耗」页取的区间一致。
        /// mileage/energy/detail 不带时间范围只回退化数据（没有累计能耗、没有按天明细）。
        fun lastSevenDays(now: Long = System.currentTimeMillis()): DrivingStatsRange {
            val cnDayStart = ((now + CN_OFFSET_MS) / DAY_MS) * DAY_MS - CN_OFFSET_MS
            return DrivingStatsRange(
                begintime = cnDayStart - 6 * DAY_MS,
                endtime = cnDayStart + DAY_MS - 1,
            )
        }

        /// 把 `getLastNweeks100kmECAndRank` 给的 `weekStart`/`weekEnd`（"2026-07-06" 这种日期串）
        /// 折成北京时间的整周闭区间——官方点某根周柱子时，`getLastweekEC` 收的就是这个区间。
        /// `weekEnd` 要补到当天 23:59:59.999，只传日零点会把最后一天整天漏掉。
        fun ofWeek(weekStart: String?, weekEnd: String?): DrivingStatsRange? {
            val start = cnDayStartMs(weekStart) ?: return null
            val end = cnDayStartMs(weekEnd) ?: return null
            return DrivingStatsRange(start, end + DAY_MS - 1)
        }

        /// "2026-07-06" → 北京时间当天零点的毫秒时间戳。
        ///
        /// 手工拆串而不是过 `SimpleDateFormat`：后者太宽松，`"2026/07/06"` 这种也照收不误，
        /// 悄悄给出一个能用的区间。日期串一律按北京时间解析——设备时区跟着用户跑，
        /// 用本地时区整段会错位一天。
        private fun cnDayStartMs(day: String?): Long? {
            if (day == null) return null
            val parts = day.split("-")
            if (parts.size != 3) return null
            val year = parts[0].toIntOrNull() ?: return null
            val month = parts[1].toIntOrNull() ?: return null
            val date = parts[2].toIntOrNull() ?: return null
            val calendar = Calendar.getInstance(TimeZone.getTimeZone("GMT+08:00"))
            calendar.clear()
            calendar.set(year, month - 1, date, 0, 0, 0)
            return calendar.timeInMillis
        }
    }
}

/// 四个 drivingrecord 接口揉成的规范化统计。任一块缺失（接口失败 / 该车不返回）都为 null。
data class DrivingStats(
    val totals: Totals?,
    val daily: List<DailyMileage>,
    val energyDistribution: EnergyDistribution?,
    val weekly: Weekly?,
    val range: DrivingStatsRange,
    /// `energyDistribution` 是哪根周柱子的（值为 `WeeklyEC.id`）。
    /// 正常就是最后一周（本周）——页面默认选中它。周列表没拉到时退回「近 7 天」窗口，
    /// 这时为 null，界面得跟着改口，不能顶着某一周的名头显示另一个区间的数。
    val distributionWeekID: String? = null,
) {
    data class Totals(
        val totalMileageKm: Int?,
        val totalEnergyKwh: Int?,
        val deliveryDays: Int?,
        val rangeMileageKm: Int?,
    )

    data class DailyMileage(val day: String, val mileageKm: Int?, val energyWh: Int?)

    data class EnergyDistribution(
        val driverKwh: Double,
        val acKwh: Double,
        val otherKwh: Double,
        val totalKwh: Double,
        val driverPct: Double?,
        val acPct: Double?,
        val otherPct: Double?,
    ) {
        companion object {
            /// 三块用量推出总量和占比，占比留一位小数——和官方饼图的口径一致。
            fun of(driverKwh: Double, acKwh: Double, otherKwh: Double): EnergyDistribution {
                val total = driverKwh + acKwh + otherKwh
                fun pct(part: Double): Double? =
                    if (total > 0) Math.round((part / total) * 1000).toDouble() / 10 else null
                return EnergyDistribution(
                    driverKwh = driverKwh,
                    acKwh = acKwh,
                    otherKwh = otherKwh,
                    totalKwh = Math.round(total * 10).toDouble() / 10,
                    driverPct = pct(driverKwh),
                    acPct = pct(acKwh),
                    otherPct = pct(otherKwh),
                )
            }

            /// 从 `getLastweekEC` 整份响应解析。三块都是**字符串**，`doubleValue` 负责转。
            /// 没有 `data` 就是这段区间没数据，返回 null——界面据此整卡隐藏，不填 0。
            fun fromRaw(raw: JsonValue?): EnergyDistribution? {
                val node = raw?.get("data") ?: return null
                return of(
                    driverKwh = node.get("driverEC")?.doubleValue ?: 0.0,
                    acKwh = node.get("acEC")?.doubleValue ?: 0.0,
                    otherKwh = node.get("otherEC")?.doubleValue ?: 0.0,
                )
            }
        }
    }

    data class WeeklyEC(val weekStart: String?, val weekEnd: String?, val hundredKmEc: Double?) {
        val id: String get() = (weekStart.orEmpty()) + "~" + (weekEnd.orEmpty())

        /// 这一周对应的请求区间。点柱子拉该周能耗构成时用它当 `getLastweekEC` 的入参；
        /// 日期串缺失 / 畸形就是 null，这根柱子点不动。
        val range: DrivingStatsRange? get() = DrivingStatsRange.ofWeek(weekStart, weekEnd)
    }

    data class Weekly(
        val rankPercent: String?,
        val rankHundredKmEc: Double?,
        val weeks: List<WeeklyEC>,
    )

    /// 空数据（拉取全失败时的兜底），用于 UI 判空。
    val isEmpty: Boolean
        get() = totals == null && daily.isEmpty() && energyDistribution == null && weekly == null

    companion object {
        fun from(
            mileageRaw: JsonValue?,
            distributionRaw: JsonValue?,
            weeklyRaw: JsonValue?,
            range: DrivingStatsRange,
            distributionWeekID: String? = null,
        ): DrivingStats {
            val mileage = mileageRaw?.get("data")
            val totals = mileage?.let {
                Totals(
                    totalMileageKm = it.get("totalmileage")?.intValue,
                    totalEnergyKwh = it.get("totalEnergy")?.intValue,
                    deliveryDays = it.get("deliveryDays")?.intValue,
                    rangeMileageKm = it.get("totalAccumulatedMileage")?.intValue,
                )
            }
            val daily = (mileage?.get("detail")?.arrayValue ?: emptyList()).map { entry ->
                DailyMileage(
                    day = entry.get("day")?.stringValue.orEmpty(),
                    mileageKm = entry.get("accumulatedMileage")?.intValue,
                    energyWh = entry.get("accumulatedEnergyConsume")?.intValue,
                )
            }
            val weeklyNode = weeklyRaw?.get("data")
            val weekly = weeklyNode?.let { node ->
                Weekly(
                    rankPercent = node.get("rankResult")?.get("rank")?.stringValue,
                    rankHundredKmEc = node.get("rankResult")?.get("hundredKmEC")?.doubleValue,
                    weeks = (node.get("weeklyEC")?.arrayValue ?: emptyList()).map {
                        WeeklyEC(
                            weekStart = it.get("weekStart")?.stringValue,
                            weekEnd = it.get("weekEnd")?.stringValue,
                            hundredKmEc = it.get("hundredKmEC")?.doubleValue,
                        )
                    },
                )
            }
            return DrivingStats(
                totals = totals,
                daily = daily,
                energyDistribution = EnergyDistribution.fromRaw(distributionRaw),
                weekly = weekly,
                range = range,
                distributionWeekID = distributionWeekID,
            )
        }
    }
}

/// 爱车页车模型。官方 `carpicture/3d/key` 一个接口同时覆盖两类车：
/// `modelType == 3` 是真 3D（渲染器 + 模型两个 zip，本地 WebView 离线渲染），
/// 其余（S01、C10 等）用 `srcKey` 换到的是一套分层贴图，见 `CarLayerComposer`。
///
/// 响应里还有个 `shareBindUrl` 静态图直链，我们不用——那是分享绑定用的素材，
/// 和官方爱车页显示的不是同一张，角度更偏，也不会跟着车况动。
data class CarModel(
    val modelType: Int,
    val modelVersion: String,
    /// 资源包 key。3D 车 `srcKey` 是模型、`h5Key` 是渲染器；
    /// 2D 车只有 `srcKey`，换到的是分层贴图。都走 `carpicture/key/package?key=…`。
    val srcKey: String,
    val h5Key: String = "",
    /// 加密整包指针，官方用来做整包校验；我们按 key 下载，留着备查。
    val srcWhole: String = "",
    val h5Whole: String = "",
    /// 渲染器 `newInit` 要的车型参数，字段名与渲染器 `parseServerJson` 完全对应，
    /// 所以换车型不用我们逐个适配文件名——渲染器自己按 carType/year 拼路径。
    val modelParam: CarModelParam? = null,
) {
    val is3D: Boolean get() = modelType == 3

    /// 两个包齐了才渲染得起来。
    val has3DPackages: Boolean get() = is3D && srcKey.isNotEmpty() && h5Key.isNotEmpty()

    companion object {
        /// 从 `carpicture/3d/key` 响应解析。没有 `srcKey` 就什么资源都取不到，返回 null。
        fun fromRaw(raw: JsonValue?): CarModel? {
            val data = raw?.get("data") ?: return null
            val srcKey = data.get("srcKey")?.stringValue.orEmpty()
            if (srcKey.isEmpty()) return null
            return CarModel(
                modelType = data.get("modelType")?.intValue ?: 2,
                modelVersion = data.get("modelVersion")?.stringValue.orEmpty(),
                srcKey = srcKey,
                h5Key = data.get("h5Key")?.stringValue.orEmpty(),
                srcWhole = data.get("srcWhole")?.stringValue.orEmpty(),
                h5Whole = data.get("h5Whole")?.stringValue.orEmpty(),
                modelParam = CarModelParam.fromRaw(data.get("modelParam")),
            )
        }
    }
}

/// 3D 渲染器的车型参数。字段名照抄渲染器 `parseServerJson` 读的那几个键，
/// 序列化出来的 JSON 直接就是 `newInit` 的第一个入参。
data class CarModelParam(
    val carType: String,
    val year: Int,
    val carTypeCode: String,
    val colorCode: Int,
    val roofColorCode: Int?,
    val seat: Int?,
    /// 左右舵。资源文件名的第一段就是它（`C11_2026_0_0_0_…`），
    /// 不传的话渲染器默认按右舵拼路径，国内车全都会 404，然后卡在「加载颜色信息」那步。
    val rudder: Int,
) {
    /// 资源目录名，`C11_2026` 这种。渲染器按同样规则拼资源路径。
    val assetDirectory: String get() = "${carType}_$year"

    /// 渲染器 `newInit(serverJson, appJson)` 的第一个入参。
    ///
    /// `alias` 传解压目录反推出来的真实别名（`CarModelAssets.assetAlias`）。
    /// 渲染器 `confirmVehicleLoad` 先按 carType 拼资源目录，404 了才拿 alias 再试一次——
    /// 这个兜底就是给代号和目录名对不上的车型准备的：B05 的目录叫 `Lafa5_2026`。
    /// 反推不出来就不传，让渲染器用包自带的缺省值，总比填一个必然 404 的 carType 强。
    fun serverJSON(alias: String?): String {
        val fields = mutableListOf(
            "\"carType\":\"$carType\"",
            "\"year\":$year",
            "\"carTypeCode\":\"$carTypeCode\"",
            "\"colorCode\":$colorCode",
            "\"rudder\":$rudder",
            // 相机距离。渲染器默认 20 是给全屏爱车页的，车在首页这块小画布里会显得很小；
            // 11 大约是 2D 车图那个观感，再近就顶到卡片上了。
            "\"radius\":11",
            // 垂直偏移。车默认落在画布正中偏下，正好撞上下面那排状态徽章；
            // 往上提一点，徽章那一行就空出来了。
            "\"offset\":0.3",
        )
        if (!alias.isNullOrEmpty()) fields += "\"alias\":\"$alias\""
        roofColorCode?.let { fields += "\"roofColorCode\":$it" }
        seat?.let { fields += "\"seat\":$it" }
        return "{${fields.joinToString(",")}}"
    }

    companion object {
        fun fromRaw(raw: JsonValue?): CarModelParam? {
            val carType = raw?.get("carType")?.stringValue.orEmpty()
            if (raw == null || carType.isEmpty()) return null
            return CarModelParam(
                carType = carType,
                year = raw.get("year")?.intValue ?: 2025,
                carTypeCode = raw.get("carTypeCode")?.stringValue.orEmpty(),
                colorCode = raw.get("colorCode")?.intValue ?: 0,
                roofColorCode = raw.get("roofColor")?.intValue,
                seat = raw.get("seat")?.intValue,
                // 接口不返回这项，国内车一律左舵。
                rudder = raw.get("rudder")?.intValue ?: 0,
            )
        }
    }
}
