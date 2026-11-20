import Foundation

/// 车况信号的语义名。界面和业务只认这一层。
///
/// 零跑的车况接口只有两套口径，车型按这两套分组：
/// - **S01 / T03**：上报语义化字段名（`soc`、`acSwitch`…）
/// - **C11 及其余车型**：上报数字信号 ID（`100003`、`1318`…），同一个 ID 在这组车型里含义相同
///
/// 两套字段一个都对不上，早先直接把 key 写死在取值属性里，换车型就整屏空白。
enum VehicleSignal: String, CaseIterable, Sendable {
    // 电池 / 充电
    case soc
    case expectedMileage
    case batteryVoltage
    case batteryCurrent
    case dumpEnergy
    case chargeLimit
    case chargeRemainTime
    case minSingleTemp
    case chargeTimeSetting
    case chargeState
    case chargeGunConnected
    case fastCharging
    case healthyCharge
    case cancelChargeOnce

    // 门锁
    case driverDoorLocked
    case doorControlAllowed
    case trunkOpen
    case frontTrunkOpen
    case driverDoor
    case passengerDoor
    case leftRearDoor
    case rightRearDoor

    // 车窗
    case windowsRemoteSupported
    case leftFrontWindow
    case rightFrontWindow
    case leftRearWindow
    case rightRearWindow
    /// 车窗开合状态位，和上面的开度是**两组独立信号**：开度只说开了多少，
    /// 这组只说开没开，而且有的车只报这一组。官方判「车窗开没开」用的就是它，
    /// 详见 `VehicleState.anyWindowOpen`。
    case leftFrontWindowOpen
    case rightFrontWindowOpen
    case leftRearWindowOpen
    case rightRearWindowOpen

    // 空调
    case acSwitch
    case acSetting
    case acFanLevel
    case acMode
    case acCircleMode
    case acTempMode
    case indoorTemp
    case outdoorTemp
    /// PTC 加热功率（W）。
    case ptcPower
    /// 电池热管理请求档位。
    case thermalManageRequest
    /// 快速降温 / 快速制热是否正在执行。两个独立状态位，不是空调模式的另一种说法。
    case rapidCooling
    case rapidHeating
    /// 前挡除雾（除霜）状态位。
    case windshieldDefrost

    // 舒适座舱
    /// 座椅加热 / 通风档位，0=关、1…3 档。四个座位八个独立信号。
    case driverSeatHeating
    case driverSeatVentilation
    case passengerSeatHeating
    case passengerSeatVentilation
    case leftRearSeatHeating
    case leftRearSeatVentilation
    case rightRearSeatHeating
    case rightRearSeatVentilation
    /// 方向盘加热档位：0=关、1=弱、2=强。**只有两档**，不是座椅那样的三档。
    case steeringWheelHeating
    /// 方向盘加热剩余运行分钟数。**加热关闭时这个值也非 0**，不能拿它判「正在加热」，
    /// 取值见 `VehicleState.steeringWheelHeatMinutes`。
    case steeringWheelHeatMinutes
    /// 左 / 右外后视镜加热，0 / 1。
    case leftMirrorHeating
    case rightMirrorHeating
    /// 后风挡 **及外后视镜** 电加热除雾，0 / 1。名字里带后视镜，所以它也是 cmdid 440 的候选确认位。
    case rearWindowHeating

    // 车载冰箱
    case fridgeSwitch
    case fridgeMode
    case fridgeTargetTemp
    case fridgeStyle
    case fridgeFault
    case fridgeParkSwitch
    case fridgeParkDurationHours
    case fridgeParkCycles
    case fridgeParkEndTime

    // 遮阳帘 / 天窗开度
    /// 天幕遮阳帘开度，0…100（0 = 全关）。实测 C16 在报（能力码也有 `13` 遮阳帘）。
    case sunshadeOpening
    /// 天窗开度，0…10（0 = 全关）。没选装可开启天窗的车会报 `15` / `150` 这类 CAN 占位值，
    /// 不是「开了 15 格」，取值见 `VehicleState.sunroofOpen`。实测 C16 不报（能力码也没有 `25`）。
    case sunroofOpening

    // 驾驶状态
    /// 挡位。官方判「行车中」就是它取 1 或 3。
    case gearStatus
    /// ON3 电源位。官方把它当远程控车是否可用的前提。
    case powerOn3

    // 哨兵
    /// 哨兵模式开/关状态位。1=开、0=关。数字口径的原始车辆信号段（与油量 3235/续航 3260 同段），
    /// 只有支持哨兵的车（非 S01/T03）才报；S01/T03 那套语义名里没有对应字段，读不到即当关。
    case sentinel

    // 增程（C11 增程版这类油电混动才有）
    /// 油量百分比。官方小组件用它画油量条，≤5 / 5–10 / >10 三档换图标。
    case gasolinePercent
    case fuelLevel
    case fuelHeating
    case fuelHeatingError
    /// 续航口径：`0` = CLTC、`1` = WLTC。官方按它二选一，不是两套都显示。
    case workingCondition
    case cltcEnergyRange
    case cltcGasolineRange
    case cltcTotalRange
    case wltcEnergyRange
    case wltcGasolineRange
    case wltcTotalRange

    // 胎压
    case leftFrontTirePressure
    case rightFrontTirePressure
    case leftRearTirePressure
    case rightRearTirePressure
    case leftFrontTireState
    case rightFrontTireState
    case leftRearTireState
    case rightRearTireState

    // 位置 / 里程
    case latitude
    case longitude
    case privacyGPS
    case collectTime
    case totalMileage
}

/// 车型判据。同一件事散在各处、还写成两种写法，就是漂移的开始。
///
/// 起因：`SignalSchema.detect` 判 T03 用的是**精确相等**（`carType.lowercased() == "t03"`），
/// 而下发那边（`LeapCommand` 的车窗、尾门几处）一律是 `uppercased().hasPrefix("T03")`——
/// carType 一旦带上年款之类的后缀，同一台车会被两边判成两个结论：
/// 车窗刻度按 S01 的倒序读（关好的窗显示成全开），下发却仍按 T03 的三档发。
/// 实测那台报的是干净的 `T03`，没踩上，但这属于「碰巧没炸」。
///
/// 统一成前缀匹配：车型字符串是零跑给的，会随年款和配置增加后缀，前缀才是稳的那部分。
///
/// **官方比我们严**：`CarDataUtil.isT03Car()` 用的是精确相等
/// （`TextUtils.equals("t03", getCarType().toLowerCase())`），带后缀的车型在官方那边
/// 会被当成「其它车型」。我们这样更宽松——真出现 `T03-2023` 这种，官方按 C11 那套读，
/// 我们仍按 T03 读。实测那台报的是干净的 `T03`，两边目前没有分歧。
enum CarTypeFamily {
    static func isS01(_ carType: String) -> Bool { carType.uppercased().hasPrefix("S01") }
    static func isT03(_ carType: String) -> Bool { carType.uppercased().hasPrefix("T03") }
    /// S01 / T03 那套老口径（语义化字段名）。其余车型都是数字信号 ID 那套。
    ///
    /// **这只是车型侧的判据**，选用哪张表仍然看 `signalMap` 自己的形态
    /// （见 `SignalSchema.detect`）——新车型不必往这里加一行也能接进来。
    static func isLegacyFamily(_ carType: String) -> Bool { isS01(carType) || isT03(carType) }

    /// carType 是不是这批车型码里的一个。同样是前缀匹配、大小写无关。
    ///
    /// 给车图层那套分组用：那张表是照官方 `CarDataUtil.sCarTypes` 穷举抄的
    /// （s01 t03 a05 a10 b11 b10 b01 b05 c01 c11 c10 c16 d19 d21 d99），
    /// 成员多、还按两个不同维度各分了一组（门窗一组、充电层 z 槽位另一组），
    /// 给每个车型码都造一个 `isXxx` 不现实。
    static func matches(_ carType: String, anyOf codes: [String]) -> Bool {
        let upper = carType.uppercased()
        return codes.contains { upper.hasPrefix($0.uppercased()) }
    }
}

/// 车端上报的车窗刻度，两套口径不是一套。统一换算成开度百分比之后，界面只认这一套。
///
/// 这不是纸面推断：S01 实测 `0` 是全开、`10` 是关闭，C11 实测 `0` 是关闭、`50` 是降一半——
/// **方向完全相反**。不换算就直接显示，C11 车窗关好时界面会说「全开」。
enum WindowScale: String, Equatable, Sendable {
    /// S01 那套：0…10，且方向是反的（`0` 全开、`10` 关闭）。
    case invertedTen
    /// C11 / T03 那套：0…100 的开度百分比，`0` 关闭。
    ///
    /// T03 一度单开一套 `openFlagOnly`（「方向是正的，但量程未知，只回答开没开」），
    /// 2026-08-10 真车把量程验明了，那套就删了：先是下发 `50` 车窗肉眼是半开，
    /// 再是车主手动开窗上报 `18`，最后下发 `50` 车报回 **`51`**——
    /// **上报和下发是同一把 0…100 的尺子**，那个 1 是电机停位精度。
    case percent

    /// 车端原始值 → 开度百分比（0 关闭，100 全开）。
    func openness(raw: Int) -> Int {
        switch self {
        case .invertedTen: return (10 - min(10, max(0, raw))) * 10
        case .percent: return min(100, max(0, raw))
        }
    }

    /// 车端原始值 → 开没开。判据按车型各自的源码来，不是统一的 `> 0`。
    func isOpen(raw: Int) -> Bool {
        switch self {
        case .invertedTen: return raw != 10
        // 官方 T03 分支判的是 `!= 0`，和这里等价（开度不会是负的）。
        case .percent: return raw > 0
        }
    }

    /// 开度百分比 → 车端原始值。
    ///
    /// S01 和 T03 用得上（这两个车型下发和上报是同一套刻度）；C11 那组的下发刻度
    /// 和上报不是一套，换算收在 `LeapCommand.windowValue` 里单独写。
    func raw(openness: Int) -> Int {
        let value = min(100, max(0, openness))
        switch self {
        case .invertedTen: return 10 - Int((Double(value) / 10).rounded())
        case .percent: return value
        }
    }
}

/// 空调模式的原始值编码。和车窗刻度一样，两套口径不是一套。
///
/// 同一个原始值 `3` 在两套体系里是两个意思，照着一套读另一套，制热会被显示成自动。
enum ClimateModeCoding: String, Equatable, Sendable {
    /// S01 / T03 那套：0=nohotcold、1=cold、2=hot、3=hotcold。冷热之外的两个都当自动。
    case legacy
    /// C11 及其余车型那套：0=自动、1=制冷、3=制热、4=通风。前三个是真车采样确认的，
    /// `4` 是下发 `mode: nohotcold` 之后车报回来的，车主对照车机确认就是通风。
    case numeric

    func mode(raw: Int?) -> ClimateMode? {
        switch self {
        case .legacy:
            switch raw {
            // 名字本身就说明了：nohotcold 是既不制冷也不制热，就是通风；
            // hotcold 是冷热都可能，对应自动。
            case 0: return .vent
            case 1: return .cold
            case 2: return .hot
            case 3: return .auto
            default: return nil
            }
        case .numeric:
            switch raw {
            case 0: return .auto
            case 1: return .cold
            case 3: return .hot
            case 4: return .vent
            default: return nil
            }
        }
    }
}

/// 一套 `signalMap` 命名体系：语义信号 → 车端实际 key。
///
/// 表里没有的信号取值返回 nil，界面显示占位符——这比按字段名臆测一个值要诚实。
/// 零跑目前只有 `legacy`（S01 / T03）和 `numeric`（C11 及其余车型）两套，
/// 加新车型落进哪一套由 `detect` 按上报形态自己认，零改动；
/// 真出现第三套，加一个常量 + 一条识别规则即可。
struct SignalSchema: Equatable, Sendable {
    let id: String
    /// 一个语义信号可以挂多个候选 key，按顺序取第一个真的有值的。
    ///
    /// 车端不是每次都上报同一批字段——C11 的 `100003`（电量）就时有时无，
    /// 只认一个 key 的话，它缺席那次整个电量就空了。
    let keys: [VehicleSignal: [String]]
    /// 这套体系的车窗刻度怎么读。
    var windowScale: WindowScale = .invertedTen
    /// 这套体系的空调模式怎么读。
    var climateModeCoding: ClimateModeCoding = .legacy

    init(
        id: String,
        keys: [VehicleSignal: [String]],
        windowScale: WindowScale = .invertedTen,
        climateModeCoding: ClimateModeCoding = .legacy
    ) {
        self.id = id
        self.keys = keys
        self.windowScale = windowScale
        self.climateModeCoding = climateModeCoding
    }

    /// 候选 key，按优先级排列。
    func candidates(for signal: VehicleSignal) -> [String] { keys[signal] ?? [] }

    /// 兼容只关心「有没有映射」的地方。
    func key(for signal: VehicleSignal) -> String? { keys[signal]?.first }

    /// 叠加本机标定学到的映射，标定结果优先。
    ///
    /// 车主自己在车上试出来的，比内置表里那些靠量级推断的更可信，所以排在候选的最前面，
    /// 但不删掉内置的——标定那次没覆盖到的状态还得靠它们兜底。
    func merging(_ learned: [VehicleSignal: String]) -> SignalSchema {
        guard !learned.isEmpty else { return self }
        var merged = keys
        for (signal, key) in learned {
            merged[signal] = [key] + (merged[signal] ?? []).filter { $0 != key }
        }
        return SignalSchema(
            id: id + "+learned",
            keys: merged,
            windowScale: windowScale,
            climateModeCoding: climateModeCoding
        )
    }
}

extension SignalSchema {
    /// S01 / T03 那套：语义化字段名。零跑两套口径里的老那套，从真车实测确认过。
    static let legacy = SignalSchema(id: "legacy", keys: [
        .soc: ["soc"],
        .expectedMileage: ["expectedMileage"],
        .batteryVoltage: ["batteryVoltage"],
        .batteryCurrent: ["batteryCurrent"],
        .dumpEnergy: ["dumpEnergy"],
        .chargeLimit: ["chargesocSetting"],
        .chargeRemainTime: ["chargeRemainTime"],
        .minSingleTemp: ["minSingleTemp"],
        .chargeTimeSetting: ["chargeTimeSetting"],
        .chargeState: ["chargeState"],
        .fastCharging: ["dcInputFastCharge"],

        .driverDoorLocked: ["driverDoorLockStatus"],
        .doorControlAllowed: ["bcmDoorCtrlAllow"],
        .trunkOpen: ["bbcmBackDoorStatus"],
        .driverDoor: ["lbcmDriverDoorStatus"],
        .passengerDoor: ["rbcmDriverDoorStatus"],
        .leftRearDoor: ["lbcmLeftRearDoorStatus"],
        .rightRearDoor: ["rbcmRightRearDoorStatus"],

        .windowsRemoteSupported: ["isSupportWindowsRemoteControl"],
        .leftFrontWindow: ["leftFrontWindowPercent"],
        .rightFrontWindow: ["rightFrontWindowPercent"],
        .leftRearWindow: ["leftRearWindowPercent"],
        .rightRearWindow: ["rightRearWindowPercent"],
        // T03 实测（2026-08-10，55 字段）：上面那组 `*Percent` **一个都不报**，
        // 车窗只有这四个状态位。名字也不是一套——左前叫 `driverWindowStatus`（主驾），
        // 只有其余三扇是方位命名，照着 `leftFrontWindowStatus` 找是找不到的。
        //
        // 值是 `"true"` / `"false"` 字面量，不是数字口径那组的 `"0"` / `"2"`。
        // 判开合见 `VehicleState.windowOpenFlag`：那里必须先认布尔字面量，
        // 直接照抄官方的「非 `"0"` 即开」会把 `"false"` 读成开着——
        // 四扇关好的窗全报成开着，比读不到还糟。
        .leftFrontWindowOpen: ["driverWindowStatus"],
        .rightFrontWindowOpen: ["rightFrontWindowStatus"],
        .leftRearWindowOpen: ["leftRearWindowStatus"],
        .rightRearWindowOpen: ["rightRearWindowStatus"],

        .acSwitch: ["acSwitch"],
        .acSetting: ["acSetting"],
        .acFanLevel: ["acAirVolume"],
        .acMode: ["acCoolingAndHeating"],
        .acCircleMode: ["acCircleMode"],
        .acTempMode: ["acTempMode"],
        .indoorTemp: ["indoorTemp"],
        .outdoorTemp: ["outdoorTemp"],
        // `ptcPowerSettingValue` 是设定值/记忆值，不是实际 PTC 输出功率，不能用于判定正在预热。
        // 语义车型暂时没有已确认的实际功率字段；数字车型使用下方的 1348。
        .ptcPower: [],

        // 官方 `ServerCarInfoBean.DataBean` 里的字段名。S01/T03 不是增程，
        // 所以增程那一组这套口径下没有对应项，只有数字口径才有。
        .gearStatus: ["gearStatus"],
        .powerOn3: ["bcmKeyPositionOn3"],

        .leftFrontTirePressure: ["leftFrontTirePressure"],
        .rightFrontTirePressure: ["rightFrontTirePressure"],
        .leftRearTirePressure: ["leftRearTirePressure"],
        .rightRearTirePressure: ["rightRearTirePressure"],
        .leftFrontTireState: ["leftFrontTirePressureState"],
        .rightFrontTireState: ["rightFrontTirePressureState"],
        .leftRearTireState: ["leftRearTirePressureState"],
        .rightRearTireState: ["rightRearTirePressureState"],

        .latitude: ["latitude"],
        .longitude: ["longitude"],
        .privacyGPS: ["privacyGPS"],
        .collectTime: ["collectTime"],
        .totalMileage: ["totalMileage"]
    ])

    /// C11 及其余车型那套：数字信号 ID。S01 / T03 之外的车型都走这一张表——
    /// 数字 ID 的含义在这组车型里是通用的，不是 C11 专属的。
    ///
    /// 零跑没有公开信号表，这里每一条都是从一份 C11 实测响应（98 字段，车停放、上锁、空调关）
    /// 反推的，**只收有独立佐证的**，其余一律不填——宁可显示占位符，也不拿猜的值糊在界面上。
    /// 佐证虽然都来自 C11，但既然口径通用，同组的其他车型直接沿用。
    ///
    /// 未收录但记录在案的观察，等后续标定确认后再补：
    /// - `1178`：连续量，一直在 0.4–1.6 之间飘。第一次标定空调那步它恰好来回波动骗过了双向判据，
    ///   第二次基线干净之后它直接进了噪声名单
    /// - `1255`：枚举或档位，含义未知（第三方实现命名为「车辆安防激活」，未否证也未验证）
    /// - `1348`：平时 0，切到制热那一刻变成 `3500`——制热功率（W）。语义层暂时没这一项
    /// - `1949`：手动 0 → 自动 1 → 制冷 0 → 制热 1。前三份和自动位 `1939` 完全同步，
    ///   制热那份分道扬镳，不是同一个东西
    ///
    /// **2026-11-19 解掉的三个未知**（对照 leapauto 的信号表，且与我们当时的观察自洽）：`1943` = 内外循环、`2669` / `2681` = 快速降温 /
    /// 快速制热、`1624` = 方向盘加热剩余分钟。
    /// - `1943` 原先记的是「制热那份从 1 变 0，而驾驶门 `1277` 全程没动，所以『`1277` 的互补位』
    ///   这个解释站不住」——换成内外循环就讲得通了：制热时空调自动切到外循环。
    /// - `2669` / `2681` 原先只在胎压误报那段里被排除为「每车取值不同、正常时也非 0 的其它信号」，
    ///   当时抓到 `2669=1`、`2681=2`，和「快速降温/制热状态位」不矛盾。
    ///
    /// 按量级排除掉的（不是没找，是全表确实没有）：
    /// - **充电上限**：车机设的 95，全表没有 95，也没有 19（5% 一档）、950、0.95 这些换算形式
    /// - **剩余能量**：该是 70 kWh 或 70000 Wh 量级，60–80 之间只有电量百分比，Wh 量级一个没有。
    ///   `1177` 的量级（717.4）看着像 71.74 kWh，但它对不上：两次采样之间 SOC 掉了 2.1%
    ///   （中间还开了 6 km），能量该掉近 2 kWh，`1177` 只掉了 1.3
    /// - **车外温度**：车机显示 33，全表没有 33
    ///
    /// 充电状态、充电剩余时间不充电时本来就是 0，而全表有 59 个字段是 0，
    /// 静态数据里挑不出来——得插枪充电时再读一次，看哪几个从 0 变了。
    /// - 空调**模式**（制冷/制热/自动）至今没在任何一次采样里出现过，很可能根本不上报
    /// - `2190/2191`、`3724/3725`：另外两组经纬度，与 `2`/`3` 相差数百米，口径未确认
    ///   （官方 `LPNewStatusBinaryParser` 确实读 `2190/2191` 当经纬度，但也没说和 `2/3` 是什么关系）
    ///
    /// **下面这些不再是猜的**：官方 `LPNewStatusBinaryParser`（`OooOOO0.java`）里
    /// 每个 `get_$NNNN()` 后面紧跟着赋给哪个语义字段，整张表是明写的。
    /// 早先靠标定试出来的部分全部对上了，另有两条注释是错的，已在下面各自更正。
    static let numeric = SignalSchema(id: "numeric", keys: [
        // `100003` 是带小数的精确值（79.9），但**车端时报时不报**——车休眠那次整个字段缺席。
        // `1204` 是它的整数版：两次采样都是 80，和 79.9 四舍五入吻合。
        // 车主确认过车机的充电上限设的是 95，所以 `1204` 不是充电上限，是电量。
        .soc: ["100003", "1204"],
        // 35347，全表唯一的万级里程量
        .totalMileage: ["1318"],
        // 454，与 SOC 79.9% 对得上的续航量级
        .expectedMileage: ["2188"],

        // 胎压值。与 S01 实测 249–261 同量级，四个 ID 等距 +7。轮位对应关系在官方
        // 强类型模型 `NewServerCarStateBean.DataBeanX.SignalBean` 里是明写的（下同）：
        // 左前 2646 / 右前 2653 / 左后 2660 / 右后 2667。
        .leftFrontTirePressure: ["2646"],
        .rightFrontTirePressure: ["2653"],
        .leftRearTirePressure: ["2660"],
        .rightRearTirePressure: ["2667"],
        // 四个胎压告警位。**告警位 = 对应胎压 ID − 5**（四轮统一）：
        //   左前 2646→2641 / 右前 2653→2648 / 左后 2660→2655 / 右后 2667→2662。
        //
        // 这里曾经错成「胎压 ID + 2」（2648/2655/2662/2669），整组错位一格，把每个轮的
        // 告警安到了后一个轮上，且第四个 `2669` 撞上一个非告警信号 → 一台胎压正常的 C11
        // 被误报「右后异常」（2026-08-11 车友实例，官方 App 四轮全正常）。
        //
        // 现按官方模型改正。佐证（三重）：
        //   1. 官方 `SignalBean` 强类型模型里 `*TirePressureState` 声明的就是 2641/2648/2655/2662；
        //      **模型里根本没有 2669、2681**。
        //   2. 运行时抓那台误报车的 `signal/info/query` 原始响应：
        //      2641=0 2648=0 2655=0 2662=0（官方判正常）、2669=1、2681=2。
        //   3. 官方 App 界面同时显示四轮正常 → 2669=1 绝不能当胎压告警。
        // `2669`/`2681` 是每车取值不同、正常时也非 0 的其它信号，一律不解释为胎压告警。
        // legacy 口径（S01/T03）读官方同名字段。
        .leftFrontTireState: ["2641"],
        .rightFrontTireState: ["2648"],
        .leftRearTireState: ["2655"],
        .rightRearTireState: ["2662"],

        // 经纬度。**2026-11-19 换组**：原先用的是和时间戳 `1` 连号的 `2` / `3`，
        // 那组和车端另外两组经纬度在**同一帧里差着约 500 米**（实测 C16，经纬度已换成示例值：
        // `2`=120.215527 / `3`=30.246109，而 `3724`=120.210009 / `3725`=30.24797、
        // `2190`=120.210028 / `2191`=30.247968）。后两组彼此重合、只有 `2`/`3` 偏出去，
        // 而官方 `LPNewStatusBinaryParser` 读的正是 `2190`/`2191` 那一路——
        // 三份证据都指向 `2`/`3` 是偏的那一组，车辆位置、导航、近车判据一直偏半公里。
        //
        // 候选顺序就是可信度顺序：`3724`/`3725` 优先，退 `2190`/`2191`，
        // 最后才退回 `2`/`3`（只报老那组的车仍能显示位置，不至于整块空掉）。
        .longitude: ["3724", "2190", "2"],
        .latitude: ["3725", "2191", "3"],

        // 以下四项来自一次真车标定（开锁/开门/开尾门/降窗各做一次再复原），
        // 每一条都是正反两次值完全对调才采信的。
        //
        // 1 = 已锁。语义正好对上，不用取反。
        .driverDoorLocked: ["1298"],
        // 0 → 1 开门、1 → 0 关门。标定那次 `1943` 跟着反向动，一度当成它的互补位，
        // 后来空调制热那轮 `1943` 自己变了而车门没动，那个解释就作废了。
        .driverDoor: ["1277"],
        // 官方只写了后两门（`1279` `1280`）和尾门（`1281`）、前备箱（`1282`）。
        // `1278` 它没读，但四门必然连号、`1277` 已标定为主驾，副驾就只能是它。
        .passengerDoor: ["1278"],
        .leftRearDoor: ["1279"],
        .rightRearDoor: ["1280"],
        .trunkOpen: ["1281"],
        // 前备箱。早先注释里猜的是「疑似引擎盖」，官方读作 `isFrontTrunkLock`，猜错了。
        .frontTrunkOpen: ["1282"],
        // 两次独立标定都指向它。第一次曾被推翻——那次基线没采到噪声，
        // 它在关车门那步也 `0→1`；第二次基线干净，它只在开关空调时动，
        // 开门开尾门降窗全程纹丝不动，「整车上电状态」的解释站不住脚。
        .acSwitch: ["1938"],
        // 空调设定温度和风量档位：一次真车联调钉死的。车主先报「26 度 3 档」，
        // 读到 `2183 = 26`、`1941 = 3`；再改成 22 度 6 档，两个字段同时跟着变成 22 和 6。
        // `2183` 还有第三个佐证——标定开空调那步它 `26 → 24`。
        .acSetting: ["2183"],
        .acFanLevel: ["1941"],
        // 开度百分比，0 = 关闭。标定时降一半读到 50，开车门车窗自动微降读到 6。
        // 注意方向和 S01 相反，换算见 `windowScale`。
        // 另外三扇是官方给的，**轮位顺序不是连号的顺序**：
        // `644` 左前、`645` 左后、`865` 右前、`866` 右后。
        //
        // **不是每台车都报这一组**：C11 增程版（2026-08-07 实测 90 字段）四个全缺。
        // 官方自己也只拿它喂 3D 车模的车窗动画（`CarModelController` 里 `percent / 100f`），
        // 判「车窗开没开」用的是下面那组状态位。
        .leftFrontWindow: ["644"],
        .leftRearWindow: ["645"],
        .rightFrontWindow: ["865"],
        .rightRearWindow: ["866"],
        // 车窗开合状态位，官方判据是**非 `"0"` 即开**（`OooOOO0.OooO0OO()`）。
        // 增程版只报这一组，开度那组一个都没有——先前只接开度，它整项就是空的。
        // **轮位顺序和开度那组不一样**：`1693` 左前、`1694` 右前、`1695` 左后、`1696` 右后
        // （开度那组是左前、左后、右前、右后），照连号顺序对会把右前记成左后。
        .leftFrontWindowOpen: ["1693"],
        .rightFrontWindowOpen: ["1694"],
        .leftRearWindowOpen: ["1695"],
        .rightRearWindowOpen: ["1696"],

        // 早上读到 26.5，午后晒过之后 31.5，车主对照车机显示的是 31——对得上。
        .indoorTemp: ["1349"],

        // 挡位。官方判「行车中」就是它取 1 或 3（`remoteCtrlState = 2`）。
        .gearStatus: ["1010"],
        // ON3 电源位。官方拿它当远控可用的前提：不是 1 就直接判定不可远控。
        .powerOn3: ["1258"],

        // 动力电池总电压。**同是 C11，动力版本不同电压平台也不同**，别把量级写死：
        // - 纯电版是 800V 平台，实测静置 708–718 V；标定就是在这台上做的
        //   （一开始按 400V 车找 350–450 才漏了它）。
        // - 增程版是 400V 平台，实测 421.3 V——两版差着一倍，判据只能靠字段本身，不能靠量级。
        // 纯电那台三次采样 718.7 → 717.7 → 717.4，跟着 SOC 79.9 → 78.1 → 77.8 单调下降，
        // 约 0.6 V / 1% SOC——按 ~190 串算是每节 3 mV/%，正是锂电平台区的斜率。
        // 「剩余能量」这个解释被排除：中间开了 6 km、SOC 掉 2.1%，能量该掉近 2 kWh，
        // 而它只掉了 1.3。
        // 充电时端电压明显高于静置电压：停车 717.3 V → 插枪充电 724.4 V，最终验证通过。
        .batteryVoltage: ["1177"],

        // 电池电流。切到制热那步先对上了：`1348`（制热功率）跳到 3500 W，
        // 3500 ÷ 716.9 V = 4.88 A，同一时刻 `1178` 从 1.0 跳到 5.2。
        // 充电那次坐实：停车 1.0 → 充电 **−8.699**，负号正是电流流进电池的方向，
        // 而 724.4 V × 8.699 A = 6.30 kW，交流慢充的典型功率。电压、电流、功率三者自洽。
        .batteryCurrent: ["1178"],
        // 整数温度，四次采样 27/27/27/26。车主报车外 33 度，所以不是车外温度。
        // 只有量级这一个佐证，充电时电池会明显升温，到时候再验。
        .minSingleTemp: ["1182"],
        // PTC 加热功率（W）。上面那条推电流时就用过它，官方读作 `ptcPower`，对上了。
        .ptcPower: ["1348"],
        // 电池热管理请求档位（官方 `CBms_ThermalManageRequest`）。
        .thermalManageRequest: ["1186"],

        // 充电剩余时间（分钟）。**只在充电时才出现的字段**——停车那几份采样里根本没有它，
        // 插枪后全表 96 个字段里只多了这一个。读到 140，按物理算：
        // SOC 77.5% 充到车主设的 95% 还差 14.33 kWh（81.9 kWh 的包），
        // 按当时 6.30 kW 需要 136 分钟。140 对 136。
        .chargeRemainTime: ["1200"],
        // 充电状态。一开始只拿到「停车」和「充电中」两份，`47`、`94`、`1149` 三个一起
        // 从 0 翻到 1，谁是谁分不出来。后来车主手动停充、拔枪、再插枪，凑齐四种情形，
        // 三个字段各自的身份就此坐实：
        //
        //            未插枪  插枪待充  充电中  停充未拔枪
        //   47          0       1       1        1      ← 充电枪已连接
        //   94          0       0       1        0      ← 慢充枪锁止（下面更正）
        //   1149        0       0       1        2      ← 充电状态
        //   1200        缺      缺     105       缺     ← 剩余时间只在真在充时才有
        //
        // 所以 `1149` 说的是「这次充电进行到哪一步」，不是插枪与否：**0 不代表没插枪**，
        // 插着枪等待充电时它也是 0；`2` 是本次充电已结束，拔枪后清回 0。
        // `1 = 充电中`、`2 = 充电完成` 和 S01 那套对得上，`isCharging == chargeState == 1` 不用改。
        // （SDK 字段表把 0 注成「未插枪」，C11 这里对不上——那份注释也是抓出来的，不是官方文档。）
        .chargeState: ["1149"],
        // 充电枪已连接。四种情形里只有它单跟插枪走，插上即 1、拔掉即 0，充不充电不影响。
        // 官方 `LPNewStatusBinaryParser` 里它一个人干两件事：`!= 0` 是 `isInsertGun`
        // （插枪，通用），`== 1` 是 `isInsertGunSlow`（慢充枪）。我们只用前者。
        // `94` 官方读作 `isInsertGunSlowLock`（慢充枪锁止），不是「正在充电」——
        // 早先按抓包猜的那句注释是错的，但它确实和 `1149 == 1` 同步，仍然不必映射。
        .chargeGunConnected: ["47"],
        // 直流快充枪已连接。**这一项之前整个是缺的**，所以 C11 直流快充也一直显示
        // 「交流慢充」——不是映射错了，是数字口径这套表里压根没有快充这一项。
        // 官方判据是 `!= "0"`（`isInsertGunFast`），和慢充那个 `47` 是两个独立信号。
        .fastCharging: ["1197"],
        // 健康充电开关、取消本次充电。官方只在充电设置页用，我们目前没有对应界面，
        // 先留在表里——它们和上面几项是同一段代码里读出来的，一起记下省得再挖一次。
        .healthyCharge: ["48"],
        .cancelChargeOnce: ["3737"],

        // 增程版专有的一组。官方小组件按 `3262`（0 = CLTC、1 = WLTC）**二选一**
        // 显示纯电续航和汽油续航两个数，不显示总续航，也不把两套并排列出来。
        // 纯电车这一组也会报（`3260` 就等于我们标定出来的续航 `2188`），
        // 所以别拿「有没有这组字段」判断是不是增程车，要看油量。
        .gasolinePercent: ["3235"],
        .cltcGasolineRange: ["3256"],
        .cltcEnergyRange: ["3257"],
        .cltcTotalRange: ["3258"],
        .wltcGasolineRange: ["3259"],
        .wltcEnergyRange: ["3260"],
        .wltcTotalRange: ["3261"],
        .workingCondition: ["3262"],
        .fuelLevel: ["2956"],
        .fuelHeating: ["2946"],
        .fuelHeatingError: ["2954"],

        // 空调模式。四次采样两次翻转，每一档都对上了：
        //   手动制冷 1 → 自动 0 → 制冷 1 → 制热 3
        // 注意 `3` 在 S01 那套里是 hotcold（当自动读），这里是制热——
        // 编码不同套，换算见 `climateModeCoding`。
        .acMode: ["3713"],
        // 自动位，1 = 自动。和 `3713 == 0` 说的是同一件事，留着当冗余佐证：
        //   手动 0 → 自动 1 → 制冷 0 → 制热 0
        // `1949` 与它在前三份完全同步，但制热那份是 1，不是同一个东西，没收。
        .acTempMode: ["1939"],
        // 内外循环（1 = 内循环）。这一项之前整个是缺的——空调页那张「内循环 / 外循环」卡
        // 一直只能显示本机草稿，车上实际是哪一边读不到。
        .acCircleMode: ["1943"],
        // 前挡除雾、快速降温、快速制热三个状态位。
        .windshieldDefrost: ["1945"],
        .rapidCooling: ["2669"],
        .rapidHeating: ["2681"],

        // 舒适座舱。八个座椅信号 + 方向盘两项 + 后视镜三项，全部在一台 C16 的真实
        // signalMap 里逐个在场（2026-11-19 核对 `apk-analysis/sentinel_capture.log`，
        // 采样时功能都没开、值全为 0）。值域：座椅 0…3、方向盘 0…2、后视镜 0/1。
        .driverSeatHeating: ["2100"],
        .driverSeatVentilation: ["2101"],
        .passengerSeatHeating: ["2118"],
        .passengerSeatVentilation: ["2119"],
        .leftRearSeatHeating: ["1879"],
        .leftRearSeatVentilation: ["3727"],
        .rightRearSeatHeating: ["1880"],
        .rightRearSeatVentilation: ["3728"],
        .steeringWheelHeating: ["1816"],
        .steeringWheelHeatMinutes: ["1624"],
        .leftMirrorHeating: ["49"],
        .rightMirrorHeating: ["50"],
        .rearWindowHeating: ["1946"],

        // 车载冰箱。**车主这台 C16 一个都不报**（abilities 也没有 `76`），
        // 两路证据一致判定没装这个选装件，界面整块隐藏，见 `Vehicle.supportsFridge`。
        // 唯一在场的是 `11260`（离车保温截止时间，值 0），单独一个确认不了任何事。
        .fridgeSwitch: ["10709"],
        .fridgeMode: ["10708"],
        .fridgeTargetTemp: ["10707"],
        .fridgeStyle: ["10711"],
        .fridgeFault: ["10712"],
        .fridgeParkSwitch: ["11190"],
        .fridgeParkDurationHours: ["11189"],
        .fridgeParkCycles: ["11191"],
        .fridgeParkEndTime: ["11260"],

        // 遮阳帘 / 天窗开度。**`1724` 是遮阳帘、`1718` 才是天窗**——2026-11-19 设计文档初稿把
        // `1724` 当成天窗写错过一次，已更正。和实测 C16 的能力码互相印证：有 `13`（遮阳帘）、
        // 没有 `25`（天窗），signalMap 里也正好是 `1724` 在、`1718` 不在。
        .sunshadeOpening: ["1724"],
        .sunroofOpening: ["1718"],

        // 哨兵模式开/关状态位。抓包差分「开→看→关」三段采样，3636 干净地 0→1→0 与开关完全对齐
        // （见 `apk-analysis/sentinel-mode-interfaces.md` §3），是最贴车端的哨兵状态位。
        // 注意：这是**状态**位，和车辆的**支持判据**（`permission` 含 "400"）是两回事，别混。
        .sentinel: ["3636"]
    ], windowScale: .percent, climateModeCoding: .numeric)

    /// 认不出来的体系。取值全部返回 nil，界面老实显示占位符。
    static let unknown = SignalSchema(id: "unknown", keys: [:])

    /// 按 `signalMap` 自身的形态判断用哪套表。
    ///
    /// **用哪张表不看 `carType`**：车型字符串会随新车不断增加，而口径就两套，
    /// 按形态判断能让新车型零改动接入——S01 / T03 之外的车型上报数字 ID，
    /// 在这里自动落进 `.numeric`，不需要往任何白名单里加一行。
    ///
    /// 车型只用来定车窗刻度的方向：T03 和 S01 共用 `legacy` 那张表、共用同一个
    /// `leftFrontWindowPercent` 字段，方向却是反的（`Oooo000` 里 S01 判开 `!= 10`、
    /// T03 判开 `!= 0`），光看上报形态区分不出来。
    static func detect(_ signalMap: [String: String], carType: String = "") -> SignalSchema {
        if signalMap["soc"] != nil {
            // 前缀匹配，判据统一收在 `CarTypeFamily` 里：这儿原先是精确相等，
            // 和下发那边的 `hasPrefix` 对不上，carType 带后缀就会两边各判各的。
            guard CarTypeFamily.isT03(carType) else { return .legacy }
            return SignalSchema(
                id: "legacy-t03",
                keys: legacy.keys,
                windowScale: .percent,
                climateModeCoding: legacy.climateModeCoding
            )
        }
        let numericKeys = signalMap.keys.count { $0.allSatisfy(\.isNumber) }
        return numericKeys * 2 > signalMap.count ? .numeric : .unknown
    }
}
