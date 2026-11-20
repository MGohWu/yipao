package org.yipao.app.app

import org.yipao.app.core.AppEnv
import org.yipao.app.core.DrivingStats
import org.yipao.app.core.DrivingStatsRange
import org.yipao.app.core.LeapCrypto
import org.yipao.app.core.LeapSession
import org.yipao.app.core.NewAuth
import org.yipao.app.core.OldAuth
import org.yipao.app.core.SignalSchema
import org.yipao.app.core.Vehicle
import org.yipao.app.core.VehicleRoute
import org.yipao.app.core.VehicleState
import kotlin.math.roundToLong

/// 演示账号。
///
/// 应用市场上架要提供可用的测试账号。但这个 App 控的是真车——把真实零跑账号交给
/// 审核员，等于让陌生人能解锁、鸣笛、开尾门。所以提供一个固定的演示账号：
/// 用它登录后走一份写死的车况，不发任何网络请求，也不会有任何指令到达车辆。
///
/// 这不是后门：演示态下所有控车操作都只回一条提示，`VehicleStore.perform`
/// 在 `isDemo` 时直接返回，根本走不到签名和下发。
object ReviewDemo {

    const val PHONE = "13800138000"
    const val CODE = "000000"

    private const val PREFS_NAME = "leap-app"
    private const val ACTIVE_KEY = "review.demo.active"

    fun matches(phone: String, code: String): Boolean = phone == PHONE && code == CODE

    /// 审核员可能会杀掉 App 重进，所以这个状态要落盘。
    var isActive: Boolean
        get() = AppEnv.prefs(PREFS_NAME).getBoolean(ACTIVE_KEY, false)
        set(value) {
            AppEnv.prefs(PREFS_NAME).edit().putBoolean(ACTIVE_KEY, value).apply()
        }

    val session: LeapSession
        get() {
            val now = System.currentTimeMillis()
            // 演示车按 C11 纯电立人设：控制栏八个按钮（含哨兵/遮阳帘/天窗/前备箱）审核员
            // 才全都点得到。能力码就是 vehicle/list 会下发的那份 permission 清单——
            // 400 哨兵、240 遮阳帘、300 天窗、131 前备箱，支持位用正式判据算出来，不手填。
            val permission = listOf("400", "240", "300", "131")
            val vehicle = Vehicle(
                vin = "LP0DEMO0000012086",
                carType = "C11",
                name = "C11",
                permission = permission,
                isSentinelSupported = Vehicle.supportsSentinel("C11", permission),
            )
            return LeapSession.fresh().copy(
                phone = PHONE,
                oldAuth = OldAuth(
                    accountId = "demo",
                    token = "d".repeat(96),
                    refreshToken = "demo-refresh",
                    nickname = "演示",
                    tokenExpired = "21600",
                    tokenObtainedAt = now,
                    tokenExpiresAt = now + 21600 * 1000L,
                ),
                newAuth = NewAuth(
                    accountId = "demo",
                    gatewayAccountId = "demo",
                    accessToken = "demo.access.token",
                    refreshToken = "demo-refresh",
                    accessTokenExpiresAt = now + 6 * 3600 * 1000L,
                    nickname = "演示",
                    signKeyBase64 = LeapCrypto.base64Encode(ByteArray(32) { 7 }),
                ),
                vehicles = listOf(vehicle),
                selectedVin = vehicle.vin,
                selectedCarType = vehicle.carType,
                // 指向一个不存在的域名：万一哪条路径漏了 isDemo 判断，请求也发不出去。
                route = VehicleRoute(appRegion = "https://demo.invalid", appCenter = "https://demo.invalid"),
            )
        }

    /// 车况写的是**数字口径**（C11 那套信号 ID，见 `SignalSchema.numeric`）：车型既然立成 C11，
    /// signalMap 的形态也得跟着换，legacy 字段名在这套 schema 下一个都读不出来。
    /// 数字口径没有的字段（剩余能量、车外温度、数据时间…）不硬造——真 C11 也不报，
    /// 界面本来就按「读不到就隐藏」处理。
    val vehicleState: VehicleState
        get() {
            val signalMap = mapOf(
                "1204" to "76",      // 电量 %
                "2188" to "312",     // 续航 km
                "1318" to "86339",   // 总里程 km
                "1177" to "715.9",   // 电池电压：C11 纯电是 800V 平台，静置 708–718 才像话
                "1178" to "1.0",     // 电池电流（静置底噪）
                "1182" to "27",      // 电池最低单体温度
                "1149" to "0",       // 充电状态：未充电
                "47" to "0",         // 慢充枪未连接
                "1197" to "0",       // 快充枪未连接

                "1298" to "1",       // 已锁车（1 = 已锁）
                "1277" to "0", "1278" to "0", "1279" to "0", "1280" to "0", // 四门已关
                "1281" to "0",       // 尾门已关
                "1282" to "0",       // 前备箱已关

                // 前两扇窗开 10%：数字口径 percent 是正向刻度（0 = 关）。
                "644" to "10", "865" to "10", "645" to "0", "866" to "0",
                "1693" to "1", "1694" to "1", "1695" to "0", "1696" to "0",

                "1938" to "0",       // 空调关
                "2183" to "24",      // 设定温度
                "1941" to "3",       // 风量
                "3713" to "1",       // 模式：制冷
                "1939" to "0",       // 手动
                "1349" to "33",      // 车内温度

                "1010" to "0",       // 挡位 P，非行驶
                "1258" to "0",       // ON3 电源位：下电

                "3636" to "0",       // 哨兵未开启

                // 杭州市民中心，公开地标，不是任何人的真实位置。
                "2" to "120.21201",  // 经度
                "3" to "30.24704",   // 纬度

                "2646" to "252", "2653" to "249", "2660" to "261", "2667" to "255", // 胎压 kPa
                "2641" to "0", "2648" to "0", "2655" to "0", "2662" to "0",         // 胎压告警：四轮正常
            )
            return VehicleState(
                signalMap = signalMap,
                // 正常链路里 schema 是 `fetchVehicleState` 检测后赋的，演示态不走那条路，这里补上；
                // 走同一个 detect 而不是硬编码 numeric，免得两处口径各判各的。
                schema = SignalSchema.detect(signalMap, carType = "C11"),
                collectedAt = System.currentTimeMillis(),
                // 充电上限在数字口径下不是信号，正常链路来自 commonConfig，演示态直接放到同一个落点。
                chargePlanLimit = 90,
            )
        }

    /// 演示用里程能耗统计，数值取自公开演示车，用来在审核/截图时把统计页填满。
    val drivingStats: DrivingStats
        get() {
            val days = listOf("07-31", "08-01", "08-02", "08-03", "08-04", "08-05", "08-06")
            val mileages = listOf(24, 28, 24, 26, 16, 31, 29)
            val energies = listOf(3768, 5406, 3492, 4206, 2753, 4728, 4205)
            val weekList = listOf(
                DrivingStats.WeeklyEC("2026-06-22", "2026-06-28", 13.9),
                DrivingStats.WeeklyEC("2026-06-29", "2026-07-05", 14.1),
                DrivingStats.WeeklyEC("2026-07-06", "2026-07-12", 16.4),
                DrivingStats.WeeklyEC("2026-07-13", "2026-07-19", 15.5),
                DrivingStats.WeeklyEC("2026-07-20", "2026-07-26", 16.4),
                DrivingStats.WeeklyEC("2026-07-27", "2026-08-02", 15.7),
            )
            val last = weekList.last()
            return DrivingStats(
                totals = DrivingStats.Totals(
                    totalMileageKm = 87398,
                    totalEnergyKwh = 12292,
                    deliveryDays = 2093,
                    rangeMileageKm = 178,
                ),
                daily = days.indices.map {
                    DrivingStats.DailyMileage(days[it], mileages[it], energies[it])
                },
                // 默认选中最后一周，构成图得跟那根柱子对上。
                energyDistribution = last.range?.let { energyDistribution(it) }
                    ?: DrivingStats.EnergyDistribution.of(22.5, 3.7, 2.2),
                weekly = DrivingStats.Weekly(
                    rankPercent = "31%",
                    rankHundredKmEc = 15.7,
                    weeks = weekList,
                ),
                range = DrivingStatsRange.lastSevenDays(),
                distributionWeekID = last.id,
            )
        }

    /// 演示用的能耗构成。按区间起点派生，所以同一周反复点开是同一组数，
    /// 换一周又确实变——正好验「点了跟不跟着变」。
    fun energyDistribution(range: DrivingStatsRange): DrivingStats.EnergyDistribution {
        val seed = (range.begintime / 86_400_000L).toInt()
        // 模数不能取 7：相邻周的 seed 正好差 7 天，模 7 恒等，六根柱子会给出同一个数。
        fun step(modulus: Int): Double = (((seed % modulus) + modulus) % modulus).toDouble()
        fun round1(value: Double): Double = (value * 10).roundToLong() / 10.0
        return DrivingStats.EnergyDistribution.of(
            driverKwh = round1(19.8 + step(11) * 0.45),
            acKwh = round1(2.6 + step(3) * 0.55),
            otherKwh = round1(1.8 + step(2) * 0.6),
        )
    }
}
