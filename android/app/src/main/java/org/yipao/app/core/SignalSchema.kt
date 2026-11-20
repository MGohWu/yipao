package org.yipao.app.core

/// 车况信号的语义名。界面和业务只认这一层。
///
/// 零跑的车况接口只有两套口径，车型按这两套分组：
/// - **S01 / T03**：上报语义化字段名（`soc`、`acSwitch`…）
/// - **C11 及其余车型**：上报数字信号 ID（`100003`、`1318`…），同一个 ID 在这组车型里含义相同
///
/// 两套字段一个都对不上，早先直接把 key 写死在取值属性里，换车型就整屏空白。
enum class VehicleSignal {
    // 电池 / 充电
    Soc,
    ExpectedMileage,
    BatteryVoltage,
    BatteryCurrent,
    DumpEnergy,
    ChargeLimit,
    ChargeRemainTime,
    MinSingleTemp,
    ChargeTimeSetting,
    ChargeState,
    ChargeGunConnected,
    FastCharging,
    HealthyCharge,
    CancelChargeOnce,

    // 门锁
    DriverDoorLocked,
    DoorControlAllowed,
    TrunkOpen,
    FrontTrunkOpen,
    DriverDoor,
    PassengerDoor,
    LeftRearDoor,
    RightRearDoor,

    // 车窗
    WindowsRemoteSupported,
    LeftFrontWindow,
    RightFrontWindow,
    LeftRearWindow,
    RightRearWindow,

    // 车窗开合状态位，和上面的开度是**两组独立信号**：开度只说开了多少，
    // 这组只说开没开，而且有的车只报这一组。官方判「车窗开没开」用的就是它。
    LeftFrontWindowOpen,
    RightFrontWindowOpen,
    LeftRearWindowOpen,
    RightRearWindowOpen,

    // 空调
    AcSwitch,
    AcSetting,
    AcFanLevel,
    AcMode,
    AcCircleMode,
    AcTempMode,
    IndoorTemp,
    OutdoorTemp,

    /// PTC 加热功率（W）。
    PtcPower,

    /// 电池热管理请求档位。
    ThermalManageRequest,

    /// 快速降温 / 快速制热是否正在执行。两个独立状态位，不是空调模式的另一种说法。
    RapidCooling,
    RapidHeating,

    /// 前挡除雾（除霜）状态位。
    WindshieldDefrost,

    // 舒适座舱
    /// 座椅加热 / 通风档位，0=关、1…3 档。四个座位八个独立信号。
    DriverSeatHeating,
    DriverSeatVentilation,
    PassengerSeatHeating,
    PassengerSeatVentilation,
    LeftRearSeatHeating,
    LeftRearSeatVentilation,
    RightRearSeatHeating,
    RightRearSeatVentilation,

    /// 方向盘加热档位：0=关、1=弱、2=强。**只有两档**，不是座椅那样的三档。
    SteeringWheelHeating,

    /// 方向盘加热剩余运行分钟数。**加热关闭时这个值也非 0**，不能拿它判「正在加热」，
    /// 取值见 `VehicleState.steeringWheelHeatMinutes`。
    SteeringWheelHeatMinutes,

    /// 左 / 右外后视镜加热，0 / 1。
    LeftMirrorHeating,
    RightMirrorHeating,

    /// 后风挡 **及外后视镜** 电加热除雾，0 / 1。名字里带后视镜，所以它也是 cmdid 440 的候选确认位。
    RearWindowHeating,

    // 车载冰箱
    FridgeSwitch,
    FridgeMode,
    FridgeTargetTemp,
    FridgeStyle,
    FridgeFault,
    FridgeParkSwitch,
    FridgeParkDurationHours,
    FridgeParkCycles,
    FridgeParkEndTime,

    // 遮阳帘 / 天窗开度
    /// 天幕遮阳帘开度，0…100（0 = 全关）。车主 C16 在报（能力码也有 `13` 遮阳帘）。
    SunshadeOpening,

    /// 天窗开度，0…10（0 = 全关）。没选装可开启天窗的车会报 `15` / `150` 这类 CAN 占位值，
    /// 不是「开了 15 格」，取值见 `VehicleState.sunroofOpen`。车主 C16 不报（能力码也没有 `25`）。
    SunroofOpening,

    // 驾驶状态
    /// 挡位。官方判「行车中」就是它取 1 或 3。
    GearStatus,

    /// ON3 电源位。官方把它当远程控车是否可用的前提。
    PowerOn3,

    // 哨兵
    /// 哨兵模式当前状态位。差分采样 0→1→0 与开关对齐，只有数字口径的车报（映射见 numeric）。
    Sentinel,

    // 增程（C11 增程版这类油电混动才有）
    /// 油量百分比。官方小组件用它画油量条，≤5 / 5–10 / >10 三档换图标。
    GasolinePercent,
    FuelLevel,
    FuelHeating,
    FuelHeatingError,

    /// 续航口径：`0` = CLTC、`1` = WLTC。官方按它二选一，不是两套都显示。
    WorkingCondition,
    CltcEnergyRange,
    CltcGasolineRange,
    CltcTotalRange,
    WltcEnergyRange,
    WltcGasolineRange,
    WltcTotalRange,

    // 胎压
    LeftFrontTirePressure,
    RightFrontTirePressure,
    LeftRearTirePressure,
    RightRearTirePressure,
    LeftFrontTireState,
    RightFrontTireState,
    LeftRearTireState,
    RightRearTireState,

    // 位置 / 里程
    Latitude,
    Longitude,
    PrivacyGPS,
    CollectTime,
    TotalMileage,
}

/// 空调模式。定义放这里（而不是 LeapModels）是为了和 ClimateModeCoding 待在一起。
enum class ClimateMode {
    Cold,
    Hot,
    Vent,
    Auto;

    val label: String
        get() = when (this) {
            Cold -> "制冷"
            Hot -> "制热"
            Vent -> "通风"
            Auto -> "自动"
        }

    /// 控车 state 里的 mode 字段。
    ///
    /// `nohotcold` 是**通风**，不是自动——真车实测下发它之后模式原始值变成 `4`，
    /// 自动位 `1939` 仍是 0，只剩鼓风机在转。自动是靠 `operate: "auto"` 打通的，
    /// 这里保留 `hotcold` 只是要有个值可发。
    val wireValue: String
        get() = when (this) {
            Cold -> "cold"
            Hot -> "hot"
            Vent -> "nohotcold"
            Auto -> "hotcold"
        }
}

/// 车型判据。同一件事散在各处、还写成两种写法，就是漂移的开始。
///
/// 统一成前缀匹配：车型字符串是零跑给的，会随年款和配置增加后缀，前缀才是稳的那部分。
/// **官方比我们严**：`CarDataUtil.isT03Car()` 用的是精确相等，带后缀的车型在官方那边
/// 会被当成「其它车型」。我们这样更宽松——实测那台报的是干净的 `T03`，两边目前没有分歧。
object CarTypeFamily {
    fun isS01(carType: String): Boolean = carType.uppercase().startsWith("S01")

    fun isT03(carType: String): Boolean = carType.uppercase().startsWith("T03")

    /// S01 / T03 那套老口径（语义化字段名）。其余车型都是数字信号 ID 那套。
    ///
    /// **这只是车型侧的判据**，选用哪张表仍然看 `signalMap` 自己的形态（见 `SignalSchema.detect`）
    /// ——新车型不必往这里加一行也能接进来。
    fun isLegacyFamily(carType: String): Boolean = isS01(carType) || isT03(carType)

    /// carType 是不是这批车型码里的一个。同样是前缀匹配、大小写无关。
    /// 给车图层那套分组用：那张表照官方 `CarDataUtil.sCarTypes` 穷举抄，成员多，
    /// 给每个车型码都造一个 `isXxx` 不现实。
    fun matches(carType: String, codes: List<String>): Boolean {
        val upper = carType.uppercase()
        return codes.any { upper.startsWith(it.uppercase()) }
    }
}

/// 车端上报的车窗刻度，两套口径不是一套。统一换算成开度百分比之后，界面只认这一套。
///
/// S01 实测 `0` 是全开、`10` 是关闭，C11 实测 `0` 是关闭、`50` 是降一半——方向完全相反。
enum class WindowScale {
    /// S01 那套：0…10，且方向是反的（`0` 全开、`10` 关闭）。
    InvertedTen,

    /// C11 / T03 那套：0…100 的开度百分比，`0` 关闭。
    ///
    /// T03 的量程 2026-08-10 由真车验明：下发 `50` 车报回 `51`（那个 1 是电机停位精度），
    /// 上报和下发是同一把 0…100 的尺子。
    ///
    /// **不是每台 T03 都报得出开度**：没有电动升降窗的那台只报四个布尔状态位。
    Percent;

    /// 车端原始值 → 开度百分比（0 关闭，100 全开）。
    fun openness(raw: Int): Int = when (this) {
        InvertedTen -> (10 - raw.coerceIn(0, 10)) * 10
        Percent -> raw.coerceIn(0, 100)
    }

    /// 车端原始值 → 开没开。判据按车型各自的源码来，不是统一的 `> 0`。
    fun isOpen(raw: Int): Boolean = when (this) {
        InvertedTen -> raw != 10
        // 官方 T03 分支判的是 `!= 0`，和这里等价（开度不会是负的）。
        Percent -> raw > 0
    }

    /// 开度百分比 → 车端原始值。
    ///
    /// S01 和 T03 用得上（这两个车型下发和上报是同一套刻度）；C11 那组的下发刻度
    /// 和上报不是一套，换算收在下发那一侧单独写。
    fun rawValue(openness: Int): Int {
        val value = openness.coerceIn(0, 100)
        return when (this) {
            InvertedTen -> 10 - Math.round(value / 10.0).toInt()
            Percent -> value
        }
    }
}

/// 空调模式的原始值编码。和车窗刻度一样，两套口径不是一套。
/// 同一个原始值 `3` 在两套体系里是两个意思，照着一套读另一套，制热会被显示成自动。
enum class ClimateModeCoding {
    /// S01 / T03 那套：0=nohotcold、1=cold、2=hot、3=hotcold。
    Legacy,

    /// C11 及其余车型那套：0=自动、1=制冷、3=制热、4=通风。
    Numeric;

    fun mode(raw: Int?): ClimateMode? {
        if (raw == null) return null
        return when (this) {
            // 名字本身就说明了：nohotcold 是既不制冷也不制热，就是通风；
            // hotcold 是冷热都可能，对应自动。
            Legacy -> when (raw) {
                0 -> ClimateMode.Vent
                1 -> ClimateMode.Cold
                2 -> ClimateMode.Hot
                3 -> ClimateMode.Auto
                else -> null
            }

            Numeric -> when (raw) {
                0 -> ClimateMode.Auto
                1 -> ClimateMode.Cold
                3 -> ClimateMode.Hot
                4 -> ClimateMode.Vent
                else -> null
            }
        }
    }
}

/// 一套 `signalMap` 命名体系：语义信号 → 车端实际 key。
///
/// 表里没有的信号取值返回 null，界面显示占位符——这比按字段名臆测一个值要诚实。
class SignalSchema(
    val id: String,
    /// 一个语义信号可以挂多个候选 key，按顺序取第一个真的有值的。
    val keys: Map<VehicleSignal, List<String>>,
    val windowScale: WindowScale = WindowScale.InvertedTen,
    val climateModeCoding: ClimateModeCoding = ClimateModeCoding.Legacy,
) {

    /// 候选 key，按优先级排列。
    fun candidates(signal: VehicleSignal): List<String> = keys[signal] ?: emptyList()

    /// 兼容只关心「有没有映射」的地方。
    fun key(signal: VehicleSignal): String? = keys[signal]?.firstOrNull()

    /// 叠加本机标定学到的映射，标定结果优先。
    /// 车主自己在车上试出来的，比内置表里那些靠量级推断的更可信，所以排在候选的最前面，
    /// 但不删掉内置的——标定那次没覆盖到的状态还得靠它们兜底。
    fun merging(learned: Map<VehicleSignal, String>): SignalSchema {
        if (learned.isEmpty()) return this
        val merged = keys.mapValues { it.value.toMutableList() }.toMutableMap()
        for ((signal, key) in learned) {
            val existing = (merged[signal] ?: mutableListOf()).filter { it != key }
            merged[signal] = (listOf(key) + existing).toMutableList()
        }
        return SignalSchema("$id+learned", merged, windowScale, climateModeCoding)
    }

    companion object {
        /// S01 / T03 那套：语义化字段名。零跑两套口径里的老那套，从真车实测确认过。
        val legacy = SignalSchema(
            "legacy",
            mapOf(
                VehicleSignal.Soc to listOf("soc"),
                VehicleSignal.ExpectedMileage to listOf("expectedMileage"),
                VehicleSignal.BatteryVoltage to listOf("batteryVoltage"),
                VehicleSignal.BatteryCurrent to listOf("batteryCurrent"),
                VehicleSignal.DumpEnergy to listOf("dumpEnergy"),
                VehicleSignal.ChargeLimit to listOf("chargesocSetting"),
                VehicleSignal.ChargeRemainTime to listOf("chargeRemainTime"),
                VehicleSignal.MinSingleTemp to listOf("minSingleTemp"),
                VehicleSignal.ChargeTimeSetting to listOf("chargeTimeSetting"),
                VehicleSignal.ChargeState to listOf("chargeState"),
                VehicleSignal.FastCharging to listOf("dcInputFastCharge"),

                VehicleSignal.DriverDoorLocked to listOf("driverDoorLockStatus"),
                VehicleSignal.DoorControlAllowed to listOf("bcmDoorCtrlAllow"),
                VehicleSignal.TrunkOpen to listOf("bbcmBackDoorStatus"),
                VehicleSignal.DriverDoor to listOf("lbcmDriverDoorStatus"),
                VehicleSignal.PassengerDoor to listOf("rbcmDriverDoorStatus"),
                VehicleSignal.LeftRearDoor to listOf("lbcmLeftRearDoorStatus"),
                VehicleSignal.RightRearDoor to listOf("rbcmRightRearDoorStatus"),

                VehicleSignal.WindowsRemoteSupported to listOf("isSupportWindowsRemoteControl"),
                VehicleSignal.LeftFrontWindow to listOf("leftFrontWindowPercent"),
                VehicleSignal.RightFrontWindow to listOf("rightFrontWindowPercent"),
                VehicleSignal.LeftRearWindow to listOf("leftRearWindowPercent"),
                VehicleSignal.RightRearWindow to listOf("rightRearWindowPercent"),

                // T03 实测（2026-08-10，55 字段）：上面那组 `*Percent` **一个都不报**，
                // 车窗只有这四个状态位。名字也不是一套——左前叫 `driverWindowStatus`（主驾），
                // 只有其余三扇是方位命名，照着 `leftFrontWindowStatus` 找是找不到的。
                //
                // 值是 `'true'` / `'false'` 字面量，不是数字口径那组的 `'0'` / `'2'`。
                // 判开合见 `VehicleState.windowOpenFlag`：那里必须先认布尔字面量，
                // 直接照抄官方的「非 `'0'` 即开」会把 `'false'` 读成开着——
                // 四扇关好的窗全报成开着，比读不到还糟。
                VehicleSignal.LeftFrontWindowOpen to listOf("driverWindowStatus"),
                VehicleSignal.RightFrontWindowOpen to listOf("rightFrontWindowStatus"),
                VehicleSignal.LeftRearWindowOpen to listOf("leftRearWindowStatus"),
                VehicleSignal.RightRearWindowOpen to listOf("rightRearWindowStatus"),

                VehicleSignal.AcSwitch to listOf("acSwitch"),
                VehicleSignal.AcSetting to listOf("acSetting"),
                VehicleSignal.AcFanLevel to listOf("acAirVolume"),
                VehicleSignal.AcMode to listOf("acCoolingAndHeating"),
                VehicleSignal.AcCircleMode to listOf("acCircleMode"),
                VehicleSignal.AcTempMode to listOf("acTempMode"),
                VehicleSignal.IndoorTemp to listOf("indoorTemp"),
                VehicleSignal.OutdoorTemp to listOf("outdoorTemp"),
                // `ptcPowerSettingValue` 是设定值/记忆值，不是实际 PTC 输出功率，不能用于判定正在预热。
                // 语义车型暂时没有已确认的实际功率字段；数字车型使用下方的 1348。
                VehicleSignal.PtcPower to emptyList(),

                VehicleSignal.GearStatus to listOf("gearStatus"),
                VehicleSignal.PowerOn3 to listOf("bcmKeyPositionOn3"),

                VehicleSignal.LeftFrontTirePressure to listOf("leftFrontTirePressure"),
                VehicleSignal.RightFrontTirePressure to listOf("rightFrontTirePressure"),
                VehicleSignal.LeftRearTirePressure to listOf("leftRearTirePressure"),
                VehicleSignal.RightRearTirePressure to listOf("rightRearTirePressure"),
                VehicleSignal.LeftFrontTireState to listOf("leftFrontTirePressureState"),
                VehicleSignal.RightFrontTireState to listOf("rightFrontTirePressureState"),
                VehicleSignal.LeftRearTireState to listOf("leftRearTirePressureState"),
                VehicleSignal.RightRearTireState to listOf("rightRearTirePressureState"),

                VehicleSignal.Latitude to listOf("latitude"),
                VehicleSignal.Longitude to listOf("longitude"),
                VehicleSignal.PrivacyGPS to listOf("privacyGPS"),
                VehicleSignal.CollectTime to listOf("collectTime"),
                VehicleSignal.TotalMileage to listOf("totalMileage"),
            ),
        )

        /// C11 及其余车型那套：数字信号 ID。S01 / T03 之外的车型都走这一张表。
        ///
        /// 零跑没有公开信号表，每一条都是从真车实测响应反推、且有独立佐证才收录的；
        /// 佐证过程详见 iOS 版 `SignalSchema.swift` 里的逐条注释，这里保持映射一致。
        val numeric = SignalSchema(
            "numeric",
            mapOf(
                // `100003` 是带小数的精确值（79.9），但车端时报时不报；`1204` 是它的整数版。
                VehicleSignal.Soc to listOf("100003", "1204"),
                // 35347，全表唯一的万级里程量
                VehicleSignal.TotalMileage to listOf("1318"),
                // 454，与 SOC 79.9% 对得上的续航量级
                VehicleSignal.ExpectedMileage to listOf("2188"),

                // 胎压值。四个 ID 等距 +7；轮位对应见官方强类型模型 SignalBean：
                // 左前 2646 / 右前 2653 / 左后 2660 / 右后 2667。
                VehicleSignal.LeftFrontTirePressure to listOf("2646"),
                VehicleSignal.RightFrontTirePressure to listOf("2653"),
                VehicleSignal.LeftRearTirePressure to listOf("2660"),
                VehicleSignal.RightRearTirePressure to listOf("2667"),
                // 四个胎压告警位。**告警位 = 对应胎压 ID − 5**：左前2641/右前2648/左后2655/右后2662。
                // 曾错成「胎压ID +2」整组错位一格，第四个 2669 又撞上非告警信号 → 正常 C11 被
                // 误报右后异常（2026-08-11）。现按官方模型改正，2669/2681 一律不解释为胎压告警。
                VehicleSignal.LeftFrontTireState to listOf("2641"),
                VehicleSignal.RightFrontTireState to listOf("2648"),
                VehicleSignal.LeftRearTireState to listOf("2655"),
                VehicleSignal.RightRearTireState to listOf("2662"),

                // 与顶层时间戳字段连号的一组，取值落在车辆实际所在地。
                //
                // **这套口径没有 collectTime**：顶层那个 `1` 看着像时间戳，但没有独立佐证，
                // 拿它标注「车况多久前」一旦认错就是编时间。数字口径的车 reportedAt 读不到，
                // 界面退回本机拉取时间 collectedAt。
                //
                // **2026-11-19 换组**（同 iOS）：上面那组 `2` / `3` 和车端另外两组经纬度在
                // **同一帧里差着约 500 米**（示意值：`2`=120.155527 / `3`=30.276109，
                // 而 `3724`=120.150009 / `3725`=30.27797、`2190`=120.150028 / `2191`=30.277968）。
                // 后两组彼此重合、只有 `2`/`3` 偏出去，而官方 `LPNewStatusBinaryParser` 读的正是
                // `2190`/`2191` 那一路。候选顺序就是可信度顺序：`3724`/`3725` 优先，退 `2190`/`2191`，
                // 最后才退回 `2`/`3`（只报老那组的车仍能显示位置，不至于整块空掉）。
                VehicleSignal.Longitude to listOf("3724", "2190", "2"),
                VehicleSignal.Latitude to listOf("3725", "2191", "3"),

                // 1 = 已锁。真车标定：正反两次值完全对调才采信。
                VehicleSignal.DriverDoorLocked to listOf("1298"),
                VehicleSignal.DriverDoor to listOf("1277"),
                // 官方只写了后两门和尾门/前备箱；四门必然连号，副驾只能是 1278。
                VehicleSignal.PassengerDoor to listOf("1278"),
                VehicleSignal.LeftRearDoor to listOf("1279"),
                VehicleSignal.RightRearDoor to listOf("1280"),
                VehicleSignal.TrunkOpen to listOf("1281"),
                VehicleSignal.FrontTrunkOpen to listOf("1282"),
                // 两次独立标定都指向它：只在开关空调时动。
                VehicleSignal.AcSwitch to listOf("1938"),
                // 真车联调钉死：26 度 3 档 → 2183=26、1941=3；改 22 度 6 档同时跟着变。
                VehicleSignal.AcSetting to listOf("2183"),
                VehicleSignal.AcFanLevel to listOf("1941"),
                // 开度百分比，0=关闭。轮位顺序不是连号的顺序：644 左前、645 左后、865 右前、866 右后。
                //
                // **不是每台车都报这一组**：C11 增程版（2026-08-07 实测 90 字段）四个全缺。
                // 官方自己也只拿它喂 3D 车模的车窗动画，判「车窗开没开」用的是下面那组状态位。
                VehicleSignal.LeftFrontWindow to listOf("644"),
                VehicleSignal.LeftRearWindow to listOf("645"),
                VehicleSignal.RightFrontWindow to listOf("865"),
                VehicleSignal.RightRearWindow to listOf("866"),
                // 车窗开合状态位，官方判据是**非 `'0'` 即开**。增程版只报这一组。
                // **轮位顺序和开度那组不一样**：1693 左前、1694 右前、1695 左后、1696 右后。
                VehicleSignal.LeftFrontWindowOpen to listOf("1693"),
                VehicleSignal.RightFrontWindowOpen to listOf("1694"),
                VehicleSignal.LeftRearWindowOpen to listOf("1695"),
                VehicleSignal.RightRearWindowOpen to listOf("1696"),

                // 早上 26.5、午后 31.5，对得上车机显示。
                VehicleSignal.IndoorTemp to listOf("1349"),

                VehicleSignal.GearStatus to listOf("1010"),
                VehicleSignal.PowerOn3 to listOf("1258"),

                // 哨兵模式状态位。抓包差分「开→看→关」三段，3636 干净地 0→1→0 与开关完全对齐。
                // legacy（S01/T03）不给：这两个车型本就不支持哨兵。
                VehicleSignal.Sentinel to listOf("3636"),

                // 动力电池总电压。**同是 C11，动力版本不同电压平台也不同**：纯电版 800V
                // （实测 708–718 V），增程版 400V（实测 421.3 V）。判据靠字段本身、不靠量级。
                VehicleSignal.BatteryVoltage to listOf("1177"),
                // 电池电流：制热功率 3500W ÷ 716.9V ≈ 4.88A 与同刻 1178 的跳变吻合；充电时 −8.699。
                VehicleSignal.BatteryCurrent to listOf("1178"),
                VehicleSignal.MinSingleTemp to listOf("1182"),
                // PTC 加热功率（W），官方读作 ptcPower。
                VehicleSignal.PtcPower to listOf("1348"),
                VehicleSignal.ThermalManageRequest to listOf("1186"),

                // 充电剩余时间（分钟）。只在充电时才出现的字段。
                VehicleSignal.ChargeRemainTime to listOf("1200"),
                // 充电状态：0 不代表没插枪；1=充电中、2=本次充电已结束。
                VehicleSignal.ChargeState to listOf("1149"),
                // 充电枪已连接：插上即 1、拔掉即 0，充不充电不影响。
                VehicleSignal.ChargeGunConnected to listOf("47"),
                // 直流快充枪已连接，官方判据 != "0"。
                VehicleSignal.FastCharging to listOf("1197"),
                VehicleSignal.HealthyCharge to listOf("48"),
                VehicleSignal.CancelChargeOnce to listOf("3737"),

                // 增程版专有的一组。纯电车也会报（3260 = 标定出的续航），判断增程看 abilities。
                VehicleSignal.GasolinePercent to listOf("3235"),
                VehicleSignal.CltcGasolineRange to listOf("3256"),
                VehicleSignal.CltcEnergyRange to listOf("3257"),
                VehicleSignal.CltcTotalRange to listOf("3258"),
                VehicleSignal.WltcGasolineRange to listOf("3259"),
                VehicleSignal.WltcEnergyRange to listOf("3260"),
                VehicleSignal.WltcTotalRange to listOf("3261"),
                VehicleSignal.WorkingCondition to listOf("3262"),
                VehicleSignal.FuelLevel to listOf("2956"),
                VehicleSignal.FuelHeating to listOf("2946"),
                VehicleSignal.FuelHeatingError to listOf("2954"),

                // 空调模式：手动制冷 1 → 自动 0 → 制冷 1 → 制热 3。
                // 注意 3 在 S01 那套里是自动，这里是制热。
                VehicleSignal.AcMode to listOf("3713"),
                // 自动位，1 = 自动。
                VehicleSignal.AcTempMode to listOf("1939"),
                // 内外循环（1 = 内循环）。这一项之前整个是缺的——空调页那张「内循环 / 外循环」卡
                // 一直只能显示本机草稿。语义来自 leapauto，和我们当时「制热那份从 1 变 0」的
                // 观察自洽（制热时空调自动切外循环）。
                VehicleSignal.AcCircleMode to listOf("1943"),
                // 前挡除雾、快速降温、快速制热三个状态位（2669/2681 原先只在胎压那段被排除为
                // 「含义未知的其它信号」，2026-11-19 定名）。
                VehicleSignal.WindshieldDefrost to listOf("1945"),
                VehicleSignal.RapidCooling to listOf("2669"),
                VehicleSignal.RapidHeating to listOf("2681"),

                // 舒适座舱。八个座椅信号 + 方向盘两项 + 后视镜三项，全部在车主 C16 的真实
                // signalMap 里逐个在场（采样时功能都没开、值全为 0）。值域：座椅 0…3、方向盘 0…2、
                // 后视镜 0/1。**legacy（S01/T03）一条都不加**：那套口径里没有任何对应字段。
                VehicleSignal.DriverSeatHeating to listOf("2100"),
                VehicleSignal.DriverSeatVentilation to listOf("2101"),
                VehicleSignal.PassengerSeatHeating to listOf("2118"),
                VehicleSignal.PassengerSeatVentilation to listOf("2119"),
                VehicleSignal.LeftRearSeatHeating to listOf("1879"),
                VehicleSignal.LeftRearSeatVentilation to listOf("3727"),
                VehicleSignal.RightRearSeatHeating to listOf("1880"),
                VehicleSignal.RightRearSeatVentilation to listOf("3728"),
                VehicleSignal.SteeringWheelHeating to listOf("1816"),
                VehicleSignal.SteeringWheelHeatMinutes to listOf("1624"),
                VehicleSignal.LeftMirrorHeating to listOf("49"),
                VehicleSignal.RightMirrorHeating to listOf("50"),
                VehicleSignal.RearWindowHeating to listOf("1946"),

                // 车载冰箱。**车主这台 C16 一个都不报**（abilities 也没有 `76`），
                // 两路证据一致判定没装这个选装件，界面整块隐藏，见 `Vehicle.supportsFridge`。
                // 唯一在场的是 `11260`（离车保温截止时间，值 0），单独一个确认不了任何事。
                VehicleSignal.FridgeSwitch to listOf("10709"),
                VehicleSignal.FridgeMode to listOf("10708"),
                VehicleSignal.FridgeTargetTemp to listOf("10707"),
                VehicleSignal.FridgeStyle to listOf("10711"),
                VehicleSignal.FridgeFault to listOf("10712"),
                VehicleSignal.FridgeParkSwitch to listOf("11190"),
                VehicleSignal.FridgeParkDurationHours to listOf("11189"),
                VehicleSignal.FridgeParkCycles to listOf("11191"),
                VehicleSignal.FridgeParkEndTime to listOf("11260"),

                // 遮阳帘 / 天窗开度。**`1724` 是遮阳帘、`1718` 才是天窗**（iOS 设计文档初稿写反过一次）。
                // 和车主 C16 的能力码互相印证：有 `13`（遮阳帘）、没有 `25`（天窗），
                // signalMap 里也正好是 `1724` 在、`1718` 不在。
                VehicleSignal.SunshadeOpening to listOf("1724"),
                VehicleSignal.SunroofOpening to listOf("1718"),
            ),
            WindowScale.Percent,
            ClimateModeCoding.Numeric,
        )

        /// 认不出来的体系。取值全部返回 null，界面老实显示占位符。
        val unknown = SignalSchema("unknown", emptyMap())

        private val numericKeyPattern = Regex("^[0-9]+$")

        /// 按 `signalMap` 自身的形态判断用哪套表。
        ///
        /// 不看 `carType`：车型字符串会随新车不断增加，而口径就两套，
        /// 按形态判断能让新车型零改动接入。
        fun detect(signalMap: Map<String, String>, carType: String = ""): SignalSchema {
            if (signalMap.containsKey("soc")) {
                // 车型只用来定车窗刻度的方向：T03 和 S01 共用这张表、共用同一个
                // leftFrontWindowPercent 字段，方向却是反的（S01 判开 != 10、T03 判开 != 0），
                // 光看上报形态区分不出来。
                if (CarTypeFamily.isT03(carType)) {
                    return SignalSchema(
                        "legacy-t03",
                        legacy.keys,
                        WindowScale.Percent,
                        legacy.climateModeCoding,
                    )
                }
                return legacy
            }
            val numericKeys = signalMap.keys.count { it.isNotEmpty() && numericKeyPattern.matches(it) }
            return if (numericKeys * 2 > signalMap.size) numeric else unknown
        }
    }
}
