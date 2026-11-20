package org.yipao.app.core

// 舒适座舱（座椅加热 / 通风、方向盘、后视镜）+ 车载冰箱。和 iOS `Core/CabinComfort.swift`
// 一一对应。
//
// 协议来源是第三方 leapauto，车况信号在车主 C16 的真实 signalMap 里逐个在场（A 级），
// 但**五条下发指令（301/370/320/440/500）都没有实车样本**。

// MARK: - 座椅

/// 可远控的座位。协议里 `position` 字段只认这四个值，第三排没有任何对应值与信号。
///
/// 下发走 cmdid `301`（加热）/ `370`（通风），state 是 `{"position":"left_front","level":"2"}`。
enum class SeatPosition(val wireValue: String, val label: String) {
    Driver("left_front", "主驾"),
    Passenger("right_front", "副驾"),
    LeftRear("left_rear", "二排左"),
    RightRear("right_rear", "二排右");

    val isRear: Boolean get() = this == LeftRear || this == RightRear

    companion object {
        val front = listOf(Driver, Passenger)
        val rear = listOf(LeftRear, RightRear)
    }
}

/// 座椅的两条通道。整页只有一个当前通道，切换只换视图，不下发。
enum class SeatComfortChannel(val label: String, val cmdid: String) {
    Heating("加热", "301"),
    Ventilation("通风", "370");

    /// 座椅两条通道都是 0…3 档。
    val maxLevel: Int get() = 3

    /// 这个座位 + 这条通道对应的车况信号。
    fun signal(position: SeatPosition): VehicleSignal = when (this) {
        Heating -> when (position) {
            SeatPosition.Driver -> VehicleSignal.DriverSeatHeating
            SeatPosition.Passenger -> VehicleSignal.PassengerSeatHeating
            SeatPosition.LeftRear -> VehicleSignal.LeftRearSeatHeating
            SeatPosition.RightRear -> VehicleSignal.RightRearSeatHeating
        }
        Ventilation -> when (position) {
            SeatPosition.Driver -> VehicleSignal.DriverSeatVentilation
            SeatPosition.Passenger -> VehicleSignal.PassengerSeatVentilation
            SeatPosition.LeftRear -> VehicleSignal.LeftRearSeatVentilation
            SeatPosition.RightRear -> VehicleSignal.RightRearSeatVentilation
        }
    }
}

// MARK: - 车载冰箱

/// 冰箱运行模式。协议里**只有两个值**——没有独立的「冷冻」模式，
/// 「冷藏 / 冷冻」是同一个 `cold` 模式下的不同目标温度（见 [FridgePreset]）。
enum class FridgeMode(val wireValue: String, val label: String) {
    Cold("cold", "制冷"),
    Hot("hot", "保温");

    companion object {
        /// 上报信号 `10708`：0 = 制冷、1 = 保温暖食。
        fun fromSignal(raw: Int?): FridgeMode = if (raw == 1) Hot else Cold
    }
}

/// 制冷风格。
///
/// ⚠️ leapauto 的接口文档写 `fast`、它自己的代码写 `turbo`，两者只能有一个对。
/// 这里按**代码**走；真车发了不认时，第一个要试的替代值就是 `fast`。
enum class FridgeStyle(val wireValue: String, val label: String) {
    Normal("normal", "标准"),
    Turbo("turbo", "急速");

    companion object {
        /// 上报信号 `10711`：0 = 标准、1 = 急速。
        fun fromSignal(raw: Int?): FridgeStyle = if (raw == 1) Turbo else Normal
    }
}

/// 界面上的三个预设。协议侧只是 `mode` + `temp` 的两种组合。
enum class FridgePreset(val label: String, val mode: FridgeMode) {
    Chill("冷藏", FridgeMode.Cold),
    Freeze("冷冻", FridgeMode.Cold),
    KeepWarm("保温", FridgeMode.Hot);

    val temperature: Int
        get() = when (this) {
            Chill -> FridgeSetting.CHILL_TEMP
            Freeze -> FridgeSetting.MIN_TEMP
            KeepWarm -> FridgeSetting.HOT_TEMP
        }

    companion object {
        /// 当前设定落在哪个预设上。都不落就是 null（三个都不高亮）。
        fun matching(mode: FridgeMode, temperature: Int): FridgePreset? = when (mode) {
            FridgeMode.Hot -> KeepWarm
            FridgeMode.Cold -> when (temperature) {
                FridgeSetting.CHILL_TEMP -> Chill
                FridgeSetting.MIN_TEMP -> Freeze
                else -> null
            }
        }
    }
}

/// 一份完整的冰箱设定。cmdid `500` 的 state 是**全量**的——
/// 改一项也要把八个字段一起发出去，所以界面那边维护的是整份草稿，不是增量。
data class FridgeSetting(
    val enabled: Boolean = true,
    val mode: FridgeMode = FridgeMode.Cold,
    /// 制冷目标温度。`mode == Hot` 时下发前会被换成 [HOT_TEMP]，这里存的仍是用户调的制冷温度，
    /// 这样从保温切回制冷不会把他调好的温度弄丢。
    val temperature: Int = CHILL_TEMP,
    val style: FridgeStyle = FridgeStyle.Normal,
    val parkEnabled: Boolean = false,
    val parkHours: Int = 1,
) {
    /// 真正下发的温度值。
    val wireTemperature: Int
        get() = if (mode == FridgeMode.Hot) HOT_TEMP else temperature.coerceIn(MIN_TEMP, MAX_TEMP)

    val durationSeconds: Int get() = maxOf(MIN_DURATION_SECONDS, parkHours * 3600)

    val preset: FridgePreset? get() = FridgePreset.matching(mode, wireTemperature)

    /// 套用一个预设。保温不覆盖用户调过的制冷温度（见 [temperature] 的说明）。
    fun applying(preset: FridgePreset): FridgeSetting =
        if (preset.mode == FridgeMode.Cold) copy(mode = preset.mode, temperature = preset.temperature)
        else copy(mode = preset.mode)

    /// 全量 state JSON，字段按 key 排序（和 iOS 的 `.sortedKeys` 输出一致，便于比对）。
    ///
    /// `cycles` 这一版固定发 `"1"`：下发口径（`"1"` / `"2"`）和上报口径（`0` / `1`）对不上，
    /// 哪个值是「仅本次离车」哪个是「每次离车」没有依据，所以不暴露这个开关。
    /// `value` 字段含义不明，协议样本里恒为 `"false"`，照常量发。
    val stateJSON: String
        get() = "{\"cycles\":\"1\",\"duration\":$durationSeconds,\"enable\":${if (enabled) 1 else 0}" +
            ",\"mode\":\"${mode.wireValue}\",\"parkEnable\":${if (parkEnabled) 1 else 0}" +
            ",\"style\":\"${style.wireValue}\",\"temp\":$wireTemperature,\"value\":\"false\"}"

    companion object {
        /// 制冷目标温度量程，协议给的是 −6…15 ℃。
        const val MIN_TEMP = -6
        const val MAX_TEMP = 15

        /// 冷藏预设温度。
        const val CHILL_TEMP = 4

        /// 保温模式固定下发这个温度（协议写死 50 ℃ 恒温）。
        const val HOT_TEMP = 50

        /// 离车工作时长下限：leapauto 的实现把 `duration` 夹到 ≥1800 秒，照搬。
        const val MIN_DURATION_SECONDS = 1800
    }
}

/// 车端报回来的冰箱状态。`fridgeSwitch` 读不到就整个是 null——
/// 没装这个选装件的车（车主那台 C16 就是）不该凭空得到一份默认值。
data class FridgeState(
    val enabled: Boolean,
    val mode: FridgeMode,
    val targetTemp: Int?,
    val style: FridgeStyle,
    /// 自检故障码，0 为正常。
    val fault: Int,
    val parkEnabled: Boolean,
    val parkHours: Int?,
    /// 离车保温截止时刻（毫秒）。车端给的是秒级时间戳，0 当没有。
    val parkEndsAt: Long?,
) {
    val hasFault: Boolean get() = fault != 0

    /// 把车况当成界面草稿的初值。目标温度读不到时退回冷藏预设——
    /// 这不是「伪造车况」：草稿本来就是本机要发的东西，必须有个值。
    val asSetting: FridgeSetting
        get() = FridgeSetting(
            enabled = enabled,
            mode = mode,
            temperature = if (mode == FridgeMode.Hot) FridgeSetting.CHILL_TEMP else (targetTemp ?: FridgeSetting.CHILL_TEMP),
            style = style,
            parkEnabled = parkEnabled,
            parkHours = parkHours ?: 1,
        )
}

// MARK: - 车况派生

/// 某个座位某条通道的当前档位。**读不到返回 null**，界面整块隐藏，不退 0——
/// 退 0 等于断言「这个座位有加热、现在是关的」，而实际可能是这车根本没这个座位。
fun VehicleState.seatLevel(position: SeatPosition, channel: SeatComfortChannel): Int? =
    int(channel.signal(position))?.coerceIn(0, channel.maxLevel)

/// 这条通道上有档位可读的座位。空列表表示整条通道都读不到。
fun VehicleState.seats(channel: SeatComfortChannel): List<SeatPosition> =
    SeatPosition.entries.filter { seatLevel(it, channel) != null }

/// 二排两座里有任何一项可读。决定座位图画不画第二排。
val VehicleState.hasRearSeatComfort: Boolean
    get() = SeatComfortChannel.entries.any { channel ->
        SeatPosition.rear.any { seatLevel(it, channel) != null }
    }

val VehicleState.hasSeatComfort: Boolean
    get() = SeatComfortChannel.entries.any { seats(it).isNotEmpty() }

/// 舒适座舱页上**至少有一块东西能显示**。整页的门控用它，
/// 而不是用能力码——信号比能力码更贴车端，方向盘加热还压根没有能力码。
val VehicleState.hasCabinComfort: Boolean
    get() = hasSeatComfort || steeringWheelHeatLevel != null || mirrorHeatingOn != null

/// 方向盘加热档位：0 关、1 弱、2 强。读不到 null。
val VehicleState.steeringWheelHeatLevel: Int?
    get() = int(VehicleSignal.SteeringWheelHeating)?.coerceIn(0, 2)

/// 方向盘加热剩余分钟。
///
/// **只在加热确实开着时才给值。** 信号 `1624` 在加热关闭时也非 0——车主 C16 实测
/// `1816 = 0`（没开）而 `1624` 先是 `2`、后来跳到 `15`。拿它当「正在加热」的佐证
/// 会在界面上凭空报出一个加热中，所以这里用 `1816` 把门。
val VehicleState.steeringWheelHeatMinutes: Int?
    get() {
        val level = steeringWheelHeatLevel ?: return null
        if (level <= 0) return null
        val minutes = int(VehicleSignal.SteeringWheelHeatMinutes) ?: return null
        return minutes.takeIf { it > 0 }
    }

/// 后视镜加热开没开。两侧任一为开即算开；两侧都读不到返回 null。
val VehicleState.mirrorHeatingOn: Boolean?
    get() {
        val left = int(VehicleSignal.LeftMirrorHeating)
        val right = int(VehicleSignal.RightMirrorHeating)
        if (left == null && right == null) return null
        return (left ?: 0) > 0 || (right ?: 0) > 0
    }

/// 两侧后视镜加热状态不一致。只有两侧都读到才有意义。
val VehicleState.mirrorHeatingMismatched: Boolean
    get() {
        val left = int(VehicleSignal.LeftMirrorHeating) ?: return false
        val right = int(VehicleSignal.RightMirrorHeating) ?: return false
        return (left > 0) != (right > 0)
    }

/// 后风挡（含外后视镜）电加热除雾。cmdid 440 的第三个候选确认位。
val VehicleState.rearWindowHeatingOn: Boolean?
    get() = int(VehicleSignal.RearWindowHeating)?.let { it > 0 }

/// 冰箱状态。`fridgeSwitch` 读不到即 null。
val VehicleState.fridgeState: FridgeState?
    get() {
        val switchValue = int(VehicleSignal.FridgeSwitch) ?: return null
        val endSeconds = double(VehicleSignal.FridgeParkEndTime) ?: 0.0
        return FridgeState(
            enabled = switchValue == 1,
            mode = FridgeMode.fromSignal(int(VehicleSignal.FridgeMode)),
            targetTemp = int(VehicleSignal.FridgeTargetTemp),
            style = FridgeStyle.fromSignal(int(VehicleSignal.FridgeStyle)),
            fault = int(VehicleSignal.FridgeFault) ?: 0,
            parkEnabled = int(VehicleSignal.FridgeParkSwitch) == 1,
            parkHours = int(VehicleSignal.FridgeParkDurationHours),
            parkEndsAt = if (endSeconds > 0) (endSeconds * 1000).toLong() else null,
        )
    }

// MARK: - 指令

object CabinCommands {
    /// 座椅加热 / 通风。`level` 0 就是关闭，没有单独的关闭指令。
    fun seatComfort(position: SeatPosition, channel: SeatComfortChannel, level: Int): LeapCommand {
        val clamped = level.coerceIn(0, channel.maxLevel)
        val action = if (clamped == 0) "关闭" else " $clamped 档"
        return LeapCommand(
            channel.cmdid,
            "{\"position\":\"${position.wireValue}\",\"level\":\"$clamped\"}",
            "${position.label}${channel.label}$action",
            true,
            ControlExpectation.seatLevel(position, channel, clamped),
        )
    }

    /// 方向盘加热。`level` 0 关、1 弱、2 强——**只有两档**，和座椅不是一套量程。
    ///
    /// ⚠️ `level` 这里发的是 **JSON 数字**，不是座椅那样的字符串。leapauto 的代码发数字、
    /// 它自己的文档写字符串，两者只能有一个对，按代码走。真车不动时第一个要试的就是
    /// 换成 `{"level":"2"}`。
    fun steeringWheelHeating(level: Int): LeapCommand {
        val clamped = level.coerceIn(0, 2)
        val action = when (clamped) {
            0 -> "关闭"
            1 -> "弱档"
            else -> "强档"
        }
        return LeapCommand(
            "320",
            "{\"level\":$clamped}",
            "方向盘加热$action",
            true,
            ControlExpectation.steeringWheelLevel(clamped),
        )
    }

    /// 后视镜加热。开 `"2"`、关 `"1"`——**不是 `"1"`/`"0"`**。
    ///
    /// 这是五项里唯一官方 App 自己都没做的：内部码 `440` 在官方 APK 里连中文文案都没有。
    /// 能力码 `59 → 440` 在车主车上在场，信号 `49`/`50`/`1946` 也在报，但下发这条没有任何实车样本。
    fun mirrorHeating(on: Boolean) = LeapCommand(
        "440",
        if (on) "{\"value\":\"2\"}" else "{\"value\":\"1\"}",
        if (on) "开启后视镜加热" else "关闭后视镜加热",
        true,
        ControlExpectation.mirrorHeating(on),
    )

    /// 车载冰箱。state 是全量的，见 [FridgeSetting.stateJSON]。
    fun fridge(setting: FridgeSetting): LeapCommand {
        val label = when {
            !setting.enabled -> "关闭车载冰箱"
            setting.mode == FridgeMode.Hot -> "冰箱保温 ${FridgeSetting.HOT_TEMP} ℃"
            else -> "冰箱制冷 ${setting.wireTemperature} ℃ · ${setting.style.label}"
        }
        return LeapCommand("500", setting.stateJSON, label, true, ControlExpectation.fridge(setting))
    }
}
