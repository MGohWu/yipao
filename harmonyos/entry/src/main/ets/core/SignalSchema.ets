/**
 * 车况信号的语义名。界面和业务只认这一层。
 *
 * 零跑的车况接口只有两套口径，车型按这两套分组：
 * - **S01 / T03**：上报语义化字段名（`soc`、`acSwitch`…）
 * - **C11 及其余车型**：上报数字信号 ID（`100003`、`1318`…），同一个 ID 在这组车型里含义相同
 *
 * 两套字段一个都对不上，早先直接把 key 写死在取值属性里，换车型就整屏空白。
 */
export enum VehicleSignal {
  // 电池 / 充电
  soc = 'soc',
  expectedMileage = 'expectedMileage',
  batteryVoltage = 'batteryVoltage',
  batteryCurrent = 'batteryCurrent',
  dumpEnergy = 'dumpEnergy',
  chargeLimit = 'chargeLimit',
  chargeRemainTime = 'chargeRemainTime',
  minSingleTemp = 'minSingleTemp',
  chargeTimeSetting = 'chargeTimeSetting',
  chargeState = 'chargeState',
  chargeGunConnected = 'chargeGunConnected',
  fastCharging = 'fastCharging',
  healthyCharge = 'healthyCharge',
  cancelChargeOnce = 'cancelChargeOnce',

  // 门锁
  driverDoorLocked = 'driverDoorLocked',
  doorControlAllowed = 'doorControlAllowed',
  trunkOpen = 'trunkOpen',
  frontTrunkOpen = 'frontTrunkOpen',
  driverDoor = 'driverDoor',
  passengerDoor = 'passengerDoor',
  leftRearDoor = 'leftRearDoor',
  rightRearDoor = 'rightRearDoor',

  // 车窗
  windowsRemoteSupported = 'windowsRemoteSupported',
  leftFrontWindow = 'leftFrontWindow',
  rightFrontWindow = 'rightFrontWindow',
  leftRearWindow = 'leftRearWindow',
  rightRearWindow = 'rightRearWindow',
  // 车窗开合状态位，和上面的开度是**两组独立信号**：开度只说开了多少，
  // 这组只说开没开，而且有的车只报这一组。官方判「车窗开没开」用的就是它。
  leftFrontWindowOpen = 'leftFrontWindowOpen',
  rightFrontWindowOpen = 'rightFrontWindowOpen',
  leftRearWindowOpen = 'leftRearWindowOpen',
  rightRearWindowOpen = 'rightRearWindowOpen',

  // 空调
  acSwitch = 'acSwitch',
  acSetting = 'acSetting',
  acFanLevel = 'acFanLevel',
  acMode = 'acMode',
  acCircleMode = 'acCircleMode',
  acTempMode = 'acTempMode',
  indoorTemp = 'indoorTemp',
  outdoorTemp = 'outdoorTemp',
  /** PTC 加热功率（W）。 */
  ptcPower = 'ptcPower',
  /** 电池热管理请求档位。 */
  thermalManageRequest = 'thermalManageRequest',
  /** 快速降温 / 快速制热是否正在执行。两个独立状态位，不是空调模式的另一种说法。 */
  rapidCooling = 'rapidCooling',
  rapidHeating = 'rapidHeating',
  /** 前挡除雾（除霜）状态位。 */
  windshieldDefrost = 'windshieldDefrost',

  // 舒适座舱
  /** 座椅加热 / 通风档位，0=关、1…3 档。四个座位八个独立信号。 */
  driverSeatHeating = 'driverSeatHeating',
  driverSeatVentilation = 'driverSeatVentilation',
  passengerSeatHeating = 'passengerSeatHeating',
  passengerSeatVentilation = 'passengerSeatVentilation',
  leftRearSeatHeating = 'leftRearSeatHeating',
  leftRearSeatVentilation = 'leftRearSeatVentilation',
  rightRearSeatHeating = 'rightRearSeatHeating',
  rightRearSeatVentilation = 'rightRearSeatVentilation',
  /** 方向盘加热档位：0=关、1=弱、2=强。**只有两档**，不是座椅那样的三档。 */
  steeringWheelHeating = 'steeringWheelHeating',
  /**
   * 方向盘加热剩余运行分钟数。**加热关闭时这个值也非 0**，不能拿它判「正在加热」，
   * 取值见 `VehicleState.steeringWheelHeatMinutes`。
   */
  steeringWheelHeatMinutes = 'steeringWheelHeatMinutes',
  /** 左 / 右外后视镜加热，0 / 1。 */
  leftMirrorHeating = 'leftMirrorHeating',
  rightMirrorHeating = 'rightMirrorHeating',
  /** 后风挡 **及外后视镜** 电加热除雾，0 / 1。名字里带后视镜，所以它也是 cmdid 440 的候选确认位。 */
  rearWindowHeating = 'rearWindowHeating',

  // 车载冰箱
  fridgeSwitch = 'fridgeSwitch',
  fridgeMode = 'fridgeMode',
  fridgeTargetTemp = 'fridgeTargetTemp',
  fridgeStyle = 'fridgeStyle',
  fridgeFault = 'fridgeFault',
  fridgeParkSwitch = 'fridgeParkSwitch',
  fridgeParkDurationHours = 'fridgeParkDurationHours',
  fridgeParkCycles = 'fridgeParkCycles',
  fridgeParkEndTime = 'fridgeParkEndTime',

  // 遮阳帘 / 天窗开度
  /** 天幕遮阳帘开度，0…100（0 = 全关）。实测 C16 在报（能力码也有 `13` 遮阳帘）。 */
  sunshadeOpening = 'sunshadeOpening',
  /**
   * 天窗开度，0…10（0 = 全关）。没选装可开启天窗的车会报 `15` / `150` 这类 CAN 占位值，
   * 不是「开了 15 格」，取值见 `VehicleState.sunroofOpen`。实测 C16 不报（能力码也没有 `25`）。
   */
  sunroofOpening = 'sunroofOpening',

  // 驾驶状态
  /** 挡位。官方判「行车中」就是它取 1 或 3。 */
  gearStatus = 'gearStatus',
  /** ON3 电源位。官方把它当远程控车是否可用的前提。 */
  powerOn3 = 'powerOn3',

  // 哨兵
  /**
   * 哨兵模式当前状态位。差分采样 0→1→0 与开关对齐，只有数字口径的车报（映射见 numeric）。
   * 见 apk-analysis/sentinel-mode-interfaces.md §3。
   */
  sentinel = 'sentinel',

  // 增程（C11 增程版这类油电混动才有）
  /** 油量百分比。官方小组件用它画油量条，≤5 / 5–10 / >10 三档换图标。 */
  gasolinePercent = 'gasolinePercent',
  fuelLevel = 'fuelLevel',
  fuelHeating = 'fuelHeating',
  fuelHeatingError = 'fuelHeatingError',
  /** 续航口径：`0` = CLTC、`1` = WLTC。官方按它二选一，不是两套都显示。 */
  workingCondition = 'workingCondition',
  cltcEnergyRange = 'cltcEnergyRange',
  cltcGasolineRange = 'cltcGasolineRange',
  cltcTotalRange = 'cltcTotalRange',
  wltcEnergyRange = 'wltcEnergyRange',
  wltcGasolineRange = 'wltcGasolineRange',
  wltcTotalRange = 'wltcTotalRange',

  // 胎压
  leftFrontTirePressure = 'leftFrontTirePressure',
  rightFrontTirePressure = 'rightFrontTirePressure',
  leftRearTirePressure = 'leftRearTirePressure',
  rightRearTirePressure = 'rightRearTirePressure',
  leftFrontTireState = 'leftFrontTireState',
  rightFrontTireState = 'rightFrontTireState',
  leftRearTireState = 'leftRearTireState',
  rightRearTireState = 'rightRearTireState',

  // 位置 / 里程
  latitude = 'latitude',
  longitude = 'longitude',
  privacyGPS = 'privacyGPS',
  collectTime = 'collectTime',
  totalMileage = 'totalMileage'
}

/**
 * 所有语义信号。ArkTS 不允许把 enum 当对象用（`Object.values(VehicleSignal)` 会被拦），
 * 需要按名字反查信号时走这张表。新增枚举项时记得同步加进来。
 */
export const ALL_VEHICLE_SIGNALS: VehicleSignal[] = [
  VehicleSignal.soc, VehicleSignal.expectedMileage, VehicleSignal.batteryVoltage,
  VehicleSignal.batteryCurrent, VehicleSignal.dumpEnergy, VehicleSignal.chargeLimit,
  VehicleSignal.chargeRemainTime, VehicleSignal.minSingleTemp, VehicleSignal.chargeTimeSetting,
  VehicleSignal.chargeState, VehicleSignal.chargeGunConnected, VehicleSignal.fastCharging,
  VehicleSignal.healthyCharge, VehicleSignal.cancelChargeOnce,

  VehicleSignal.driverDoorLocked, VehicleSignal.doorControlAllowed, VehicleSignal.trunkOpen,
  VehicleSignal.frontTrunkOpen, VehicleSignal.driverDoor, VehicleSignal.passengerDoor,
  VehicleSignal.leftRearDoor, VehicleSignal.rightRearDoor,

  VehicleSignal.windowsRemoteSupported, VehicleSignal.leftFrontWindow, VehicleSignal.rightFrontWindow,
  VehicleSignal.leftRearWindow, VehicleSignal.rightRearWindow,
  VehicleSignal.leftFrontWindowOpen, VehicleSignal.rightFrontWindowOpen,
  VehicleSignal.leftRearWindowOpen, VehicleSignal.rightRearWindowOpen,

  VehicleSignal.acSwitch, VehicleSignal.acSetting, VehicleSignal.acFanLevel, VehicleSignal.acMode,
  VehicleSignal.acCircleMode, VehicleSignal.acTempMode, VehicleSignal.indoorTemp,
  VehicleSignal.outdoorTemp, VehicleSignal.ptcPower, VehicleSignal.thermalManageRequest,
  VehicleSignal.rapidCooling, VehicleSignal.rapidHeating, VehicleSignal.windshieldDefrost,

  VehicleSignal.driverSeatHeating, VehicleSignal.driverSeatVentilation,
  VehicleSignal.passengerSeatHeating, VehicleSignal.passengerSeatVentilation,
  VehicleSignal.leftRearSeatHeating, VehicleSignal.leftRearSeatVentilation,
  VehicleSignal.rightRearSeatHeating, VehicleSignal.rightRearSeatVentilation,
  VehicleSignal.steeringWheelHeating, VehicleSignal.steeringWheelHeatMinutes,
  VehicleSignal.leftMirrorHeating, VehicleSignal.rightMirrorHeating, VehicleSignal.rearWindowHeating,

  VehicleSignal.fridgeSwitch, VehicleSignal.fridgeMode, VehicleSignal.fridgeTargetTemp,
  VehicleSignal.fridgeStyle, VehicleSignal.fridgeFault, VehicleSignal.fridgeParkSwitch,
  VehicleSignal.fridgeParkDurationHours, VehicleSignal.fridgeParkCycles, VehicleSignal.fridgeParkEndTime,

  VehicleSignal.sunshadeOpening, VehicleSignal.sunroofOpening,

  VehicleSignal.gearStatus, VehicleSignal.powerOn3, VehicleSignal.sentinel,

  VehicleSignal.gasolinePercent, VehicleSignal.fuelLevel, VehicleSignal.fuelHeating,
  VehicleSignal.fuelHeatingError, VehicleSignal.workingCondition,
  VehicleSignal.cltcEnergyRange, VehicleSignal.cltcGasolineRange, VehicleSignal.cltcTotalRange,
  VehicleSignal.wltcEnergyRange, VehicleSignal.wltcGasolineRange, VehicleSignal.wltcTotalRange,

  VehicleSignal.leftFrontTirePressure, VehicleSignal.rightFrontTirePressure,
  VehicleSignal.leftRearTirePressure, VehicleSignal.rightRearTirePressure,
  VehicleSignal.leftFrontTireState, VehicleSignal.rightFrontTireState,
  VehicleSignal.leftRearTireState, VehicleSignal.rightRearTireState,

  VehicleSignal.latitude, VehicleSignal.longitude, VehicleSignal.privacyGPS,
  VehicleSignal.collectTime, VehicleSignal.totalMileage
];

/** 空调模式。定义放这里（而不是 LeapModels）是为了避免与 ClimateModeCoding 循环依赖。 */
export enum ClimateMode {
  cold = 'cold',
  hot = 'hot',
  vent = 'vent',
  auto = 'auto'
}

export class ClimateModeInfo {
  static label(mode: ClimateMode): string {
    switch (mode) {
      case ClimateMode.cold:
        return '制冷';
      case ClimateMode.hot:
        return '制热';
      case ClimateMode.vent:
        return '通风';
      case ClimateMode.auto:
        return '自动';
      default:
        return '';
    }
  }

  /**
   * 控车 state 里的 mode 字段。
   *
   * `nohotcold` 是**通风**，不是自动——真车实测下发它之后模式原始值变成 `4`，
   * 自动位 `1939` 仍是 0，只剩鼓风机在转。自动是靠 `operate: "auto"` 打通的，
   * 这里保留 `hotcold` 只是要有个值可发。
   */
  static wireValue(mode: ClimateMode): string {
    switch (mode) {
      case ClimateMode.cold:
        return 'cold';
      case ClimateMode.hot:
        return 'hot';
      case ClimateMode.vent:
        return 'nohotcold';
      case ClimateMode.auto:
        return 'hotcold';
      default:
        return 'nohotcold';
    }
  }

  static all(): ClimateMode[] {
    return [ClimateMode.cold, ClimateMode.hot, ClimateMode.vent, ClimateMode.auto];
  }
}

/**
 * 车型判据。同一件事散在各处、还写成两种写法，就是漂移的开始。
 *
 * 起因：`SignalSchema.detect` 判 T03 用的是**精确相等**（`carType.toLowerCase() === 't03'`），
 * 而下发那边（`LeapCommand` 的车窗、尾门几处）一律是 `toUpperCase().startsWith('T03')`——
 * carType 一旦带上年款之类的后缀，同一台车会被两边判成两个结论：
 * 车窗刻度按 S01 的倒序读（关好的窗显示成全开），下发却仍按 T03 的三档发。
 * 实测那台报的是干净的 `T03`，没踩上，但这属于「碰巧没炸」。
 *
 * 统一成前缀匹配：车型字符串是零跑给的，会随年款和配置增加后缀，前缀才是稳的那部分。
 *
 * **官方比我们严**：`CarDataUtil.isT03Car()` 用的是精确相等
 * （`TextUtils.equals('t03', getCarType().toLowerCase())`），带后缀的车型在官方那边
 * 会被当成「其它车型」。我们这样更宽松——真出现 `T03-2023` 这种，官方按 C11 那套读，
 * 我们仍按 T03 读。实测那台报的是干净的 `T03`，两边目前没有分歧。
 */
export class CarTypeFamily {
  static isS01(carType: string): boolean {
    return carType.toUpperCase().startsWith('S01');
  }

  static isT03(carType: string): boolean {
    return carType.toUpperCase().startsWith('T03');
  }

  /**
   * S01 / T03 那套老口径（语义化字段名）。其余车型都是数字信号 ID 那套。
   *
   * **这只是车型侧的判据**，选用哪张表仍然看 `signalMap` 自己的形态
   * （见 `SignalSchema.detect`）——新车型不必往这里加一行也能接进来。
   */
  static isLegacyFamily(carType: string): boolean {
    return CarTypeFamily.isS01(carType) || CarTypeFamily.isT03(carType);
  }

  /**
   * carType 是不是这批车型码里的一个。同样是前缀匹配、大小写无关。
   *
   * 给车图层那套分组用：那张表是照官方 `CarDataUtil.sCarTypes` 穷举抄的
   * （s01 t03 a05 a10 b11 b10 b01 b05 c01 c11 c10 c16 d19 d21 d99），
   * 成员多、还按两个不同维度各分了一组（门窗一组、充电层 z 槽位另一组），
   * 给每个车型码都造一个 `isXxx` 不现实。
   */
  static matches(carType: string, codes: string[]): boolean {
    const upper = carType.toUpperCase();
    for (let i = 0; i < codes.length; i++) {
      if (upper.startsWith(codes[i].toUpperCase())) {
        return true;
      }
    }
    return false;
  }
}

/**
 * 车端上报的车窗刻度，三套口径不是一套。统一换算成开度百分比之后，界面只认这一套。
 *
 * S01 实测 `0` 是全开、`10` 是关闭，C11 实测 `0` 是关闭、`50` 是降一半——方向完全相反。
 */
export enum WindowScale {
  /** S01 那套：0…10，且方向是反的（`0` 全开、`10` 关闭）。 */
  invertedTen = 'invertedTen',
  /**
   * C11 / T03 那套：0…100 的开度百分比，`0` 关闭。
   *
   * T03 一度单开一套「方向是正的，但量程未知，只回答开没开」的刻度，
   * 2026-08-10 真车把量程验明了，那套就删了：先是下发 `50` 车窗肉眼是半开，
   * 再是车主手动开窗上报 `18`，最后下发 `50` 车报回 **`51`**——
   * **上报和下发是同一把 0…100 的尺子**，那个 1 是电机停位精度。
   *
   * **不是每台 T03 都报得出开度**：2026-08-10 对照了两台 T03，没有电动升降窗的
   * 那台（55 字段）`leftFrontWindowPercent` 那组一个都没有，只报四个布尔状态位；
   * 有电动窗的那台（60 字段）四个开度都在。官方 `isT03Car()` 读的正是
   * `leftFrontWindowPercent`，同一个道理。判断一台 T03 属于哪种，
   * 见 `VehicleState.windowsRemoteSupported`。
   */
  percent = 'percent'
}

export class WindowScaleUtil {
  /** 车端原始值 → 开度百分比（0 关闭，100 全开）。 */
  static openness(scale: WindowScale, raw: number): number {
    if (scale === WindowScale.invertedTen) {
      return (10 - Math.min(10, Math.max(0, raw))) * 10;
    }
    return Math.min(100, Math.max(0, raw));
  }

  /** 车端原始值 → 开没开。判据按车型各自的源码来，不是统一的 `> 0`。 */
  static isOpen(scale: WindowScale, raw: number): boolean {
    if (scale === WindowScale.invertedTen) {
      return raw !== 10;
    }
    // 官方 T03 分支判的是 `!== 0`，和这里等价（开度不会是负的）。
    return raw > 0;
  }

  /**
   * 开度百分比 → 车端原始值。
   *
   * S01 和 T03 用得上（这两个车型下发和上报是同一套刻度）；C11 那组的下发刻度
   * 和上报不是一套，换算收在下发那一侧单独写。
   */
  static raw(scale: WindowScale, openness: number): number {
    const value = Math.min(100, Math.max(0, openness));
    if (scale === WindowScale.invertedTen) {
      return 10 - Math.round(value / 10);
    }
    return value;
  }
}

/**
 * 空调模式的原始值编码。和车窗刻度一样，两套口径不是一套。
 * 同一个原始值 `3` 在两套体系里是两个意思，照着一套读另一套，制热会被显示成自动。
 */
export enum ClimateModeCoding {
  /** S01 / T03 那套：0=nohotcold、1=cold、2=hot、3=hotcold。 */
  legacy = 'legacy',
  /** C11 及其余车型那套：0=自动、1=制冷、3=制热、4=通风。 */
  numeric = 'numeric'
}

export class ClimateModeCodingUtil {
  static mode(coding: ClimateModeCoding, raw: number | null): ClimateMode | null {
    if (raw === null) {
      return null;
    }
    if (coding === ClimateModeCoding.legacy) {
      switch (raw) {
        // 名字本身就说明了：nohotcold 是既不制冷也不制热，就是通风；hotcold 是冷热都可能，对应自动。
        case 0:
          return ClimateMode.vent;
        case 1:
          return ClimateMode.cold;
        case 2:
          return ClimateMode.hot;
        case 3:
          return ClimateMode.auto;
        default:
          return null;
      }
    }
    switch (raw) {
      case 0:
        return ClimateMode.auto;
      case 1:
        return ClimateMode.cold;
      case 3:
        return ClimateMode.hot;
      case 4:
        return ClimateMode.vent;
      default:
        return null;
    }
  }
}

/**
 * 一套 `signalMap` 命名体系：语义信号 → 车端实际 key。
 *
 * 表里没有的信号取值返回 null，界面显示占位符——这比按字段名臆测一个值要诚实。
 */
export class SignalSchema {
  readonly id: string;
  /** 一个语义信号可以挂多个候选 key，按顺序取第一个真的有值的。 */
  readonly keys: Map<VehicleSignal, string[]>;
  readonly windowScale: WindowScale;
  readonly climateModeCoding: ClimateModeCoding;

  constructor(id: string, keys: Map<VehicleSignal, string[]>,
    windowScale: WindowScale = WindowScale.invertedTen,
    climateModeCoding: ClimateModeCoding = ClimateModeCoding.legacy) {
    this.id = id;
    this.keys = keys;
    this.windowScale = windowScale;
    this.climateModeCoding = climateModeCoding;
  }

  /** 候选 key，按优先级排列。 */
  candidates(signal: VehicleSignal): string[] {
    return this.keys.get(signal) ?? [];
  }

  /** 兼容只关心「有没有映射」的地方。 */
  key(signal: VehicleSignal): string | null {
    const list = this.keys.get(signal);
    return list !== undefined && list.length > 0 ? list[0] : null;
  }

  /**
   * 叠加本机标定学到的映射，标定结果优先。
   * 车主自己在车上试出来的，比内置表里那些靠量级推断的更可信，所以排在候选的最前面，
   * 但不删掉内置的——标定那次没覆盖到的状态还得靠它们兜底。
   */
  merging(learned: Map<VehicleSignal, string>): SignalSchema {
    if (learned.size === 0) {
      return this;
    }
    const merged = new Map<VehicleSignal, string[]>();
    this.keys.forEach((value: string[], key: VehicleSignal) => {
      merged.set(key, value.slice());
    });
    learned.forEach((key: string, signal: VehicleSignal) => {
      const existing = (merged.get(signal) ?? []).filter((k: string) => k !== key);
      const combined: string[] = [key];
      for (let i = 0; i < existing.length; i++) {
        combined.push(existing[i]);
      }
      merged.set(signal, combined);
    });
    return new SignalSchema(this.id + '+learned', merged, this.windowScale, this.climateModeCoding);
  }

  private static buildMap(entries: [VehicleSignal, string[]][]): Map<VehicleSignal, string[]> {
    const map = new Map<VehicleSignal, string[]>();
    for (let i = 0; i < entries.length; i++) {
      map.set(entries[i][0], entries[i][1]);
    }
    return map;
  }

  /** S01 / T03 那套：语义化字段名。零跑两套口径里的老那套，从真车实测确认过。 */
  static readonly legacy: SignalSchema = new SignalSchema('legacy', SignalSchema.buildMap([
    [VehicleSignal.soc, ['soc']],
    [VehicleSignal.expectedMileage, ['expectedMileage']],
    [VehicleSignal.batteryVoltage, ['batteryVoltage']],
    [VehicleSignal.batteryCurrent, ['batteryCurrent']],
    [VehicleSignal.dumpEnergy, ['dumpEnergy']],
    [VehicleSignal.chargeLimit, ['chargesocSetting']],
    [VehicleSignal.chargeRemainTime, ['chargeRemainTime']],
    [VehicleSignal.minSingleTemp, ['minSingleTemp']],
    [VehicleSignal.chargeTimeSetting, ['chargeTimeSetting']],
    [VehicleSignal.chargeState, ['chargeState']],
    [VehicleSignal.fastCharging, ['dcInputFastCharge']],

    [VehicleSignal.driverDoorLocked, ['driverDoorLockStatus']],
    [VehicleSignal.doorControlAllowed, ['bcmDoorCtrlAllow']],
    [VehicleSignal.trunkOpen, ['bbcmBackDoorStatus']],
    [VehicleSignal.driverDoor, ['lbcmDriverDoorStatus']],
    [VehicleSignal.passengerDoor, ['rbcmDriverDoorStatus']],
    [VehicleSignal.leftRearDoor, ['lbcmLeftRearDoorStatus']],
    [VehicleSignal.rightRearDoor, ['rbcmRightRearDoorStatus']],

    [VehicleSignal.windowsRemoteSupported, ['isSupportWindowsRemoteControl']],
    [VehicleSignal.leftFrontWindow, ['leftFrontWindowPercent']],
    [VehicleSignal.rightFrontWindow, ['rightFrontWindowPercent']],
    [VehicleSignal.leftRearWindow, ['leftRearWindowPercent']],
    [VehicleSignal.rightRearWindow, ['rightRearWindowPercent']],
    // T03 实测（2026-08-10，55 字段）：上面那组 `*Percent` **一个都不报**，
    // 车窗只有这四个状态位。名字也不是一套——左前叫 `driverWindowStatus`（主驾），
    // 只有其余三扇是方位命名，照着 `leftFrontWindowStatus` 找是找不到的。
    //
    // 值是 `'true'` / `'false'` 字面量，不是数字口径那组的 `'0'` / `'2'`。
    // 判开合见 `VehicleState.windowOpenFlag`：那里必须先认布尔字面量，
    // 直接照抄官方的「非 `'0'` 即开」会把 `'false'` 读成开着——
    // 四扇关好的窗全报成开着，比读不到还糟。
    [VehicleSignal.leftFrontWindowOpen, ['driverWindowStatus']],
    [VehicleSignal.rightFrontWindowOpen, ['rightFrontWindowStatus']],
    [VehicleSignal.leftRearWindowOpen, ['leftRearWindowStatus']],
    [VehicleSignal.rightRearWindowOpen, ['rightRearWindowStatus']],

    [VehicleSignal.acSwitch, ['acSwitch']],
    [VehicleSignal.acSetting, ['acSetting']],
    [VehicleSignal.acFanLevel, ['acAirVolume']],
    [VehicleSignal.acMode, ['acCoolingAndHeating']],
    [VehicleSignal.acCircleMode, ['acCircleMode']],
    [VehicleSignal.acTempMode, ['acTempMode']],
    [VehicleSignal.indoorTemp, ['indoorTemp']],
    [VehicleSignal.outdoorTemp, ['outdoorTemp']],
    [VehicleSignal.ptcPower, ['ptcPowerSettingValue']],

    [VehicleSignal.gearStatus, ['gearStatus']],
    [VehicleSignal.powerOn3, ['bcmKeyPositionOn3']],

    [VehicleSignal.leftFrontTirePressure, ['leftFrontTirePressure']],
    [VehicleSignal.rightFrontTirePressure, ['rightFrontTirePressure']],
    [VehicleSignal.leftRearTirePressure, ['leftRearTirePressure']],
    [VehicleSignal.rightRearTirePressure, ['rightRearTirePressure']],
    [VehicleSignal.leftFrontTireState, ['leftFrontTirePressureState']],
    [VehicleSignal.rightFrontTireState, ['rightFrontTirePressureState']],
    [VehicleSignal.leftRearTireState, ['leftRearTirePressureState']],
    [VehicleSignal.rightRearTireState, ['rightRearTirePressureState']],

    [VehicleSignal.latitude, ['latitude']],
    [VehicleSignal.longitude, ['longitude']],
    [VehicleSignal.privacyGPS, ['privacyGPS']],
    [VehicleSignal.collectTime, ['collectTime']],
    [VehicleSignal.totalMileage, ['totalMileage']]
  ]));

  /**
   * C11 及其余车型那套：数字信号 ID。S01 / T03 之外的车型都走这一张表。
   *
   * 零跑没有公开信号表，每一条都是从真车实测响应反推、且有独立佐证才收录的；
   * 佐证过程详见 iOS 版 `SignalSchema.swift` 里的逐条注释，这里保持映射一致。
   */
  static readonly numeric: SignalSchema = new SignalSchema('numeric', SignalSchema.buildMap([
    // `100003` 是带小数的精确值（79.9），但车端时报时不报；`1204` 是它的整数版。
    [VehicleSignal.soc, ['100003', '1204']],
    // 35347，全表唯一的万级里程量
    [VehicleSignal.totalMileage, ['1318']],
    // 454，与 SOC 79.9% 对得上的续航量级
    [VehicleSignal.expectedMileage, ['2188']],

    // 胎压值。四个 ID 等距 +7；轮位对应见官方强类型模型 SignalBean：
    // 左前 2646 / 右前 2653 / 左后 2660 / 右后 2667。
    [VehicleSignal.leftFrontTirePressure, ['2646']],
    [VehicleSignal.rightFrontTirePressure, ['2653']],
    [VehicleSignal.leftRearTirePressure, ['2660']],
    [VehicleSignal.rightRearTirePressure, ['2667']],
    // 四个胎压告警位。**告警位 = 对应胎压 ID − 5**：左前2641/右前2648/左后2655/右后2662。
    // 曾错成「胎压ID +2」（2648/2655/2662/2669）整组错位一格，第四个 2669 又撞上非告警
    // 信号 → 正常 C11 被误报右后异常（2026-08-11）。现按官方模型改正，三重佐证：
    //   1. 官方 SignalBean 声明的 *TirePressureState 就是 2641/2648/2655/2662，无 2669/2681；
    //   2. 运行时抓误报车原始响应：2641=0 2648=0 2655=0 2662=0、2669=1、2681=2；
    //   3. 官方界面同时显示四轮正常 → 2669=1 不能当告警。
    // 2669/2681 一律不解释为胎压告警。详见 iOS SignalSchema.swift。
    [VehicleSignal.leftFrontTireState, ['2641']],
    [VehicleSignal.rightFrontTireState, ['2648']],
    [VehicleSignal.leftRearTireState, ['2655']],
    [VehicleSignal.rightRearTireState, ['2662']],

    // 经纬度。**2026-11-19 换组**（同 iOS）：原先用的是和时间戳 `1` 连号的 `2` / `3`，
    // 那组和车端另外两组经纬度在**同一帧里差着约 500 米**（C16 实测样本，坐标已平移脱敏：
    // `2`=120.215527 / `3`=30.246109，而 `3724`=120.210009 / `3725`=30.24797、
    // `2190`=120.210028 / `2191`=30.247968）。后两组彼此重合、只有 `2`/`3` 偏出去，
    // 而官方 `LPNewStatusBinaryParser` 读的正是 `2190`/`2191` 那一路——
    // 三份证据都指向 `2`/`3` 是偏的那一组。
    //
    // 候选顺序就是可信度顺序：`3724`/`3725` 优先，退 `2190`/`2191`，
    // 最后才退回 `2`/`3`（只报老那组的车仍能显示位置，不至于整块空掉）。
    // 这一条没在车旁核对过。
    [VehicleSignal.longitude, ['3724', '2190', '2']],
    [VehicleSignal.latitude, ['3725', '2191', '3']],
    // `1` 就是上面那个时间戳。只用来标注车况新旧，解析不出或明显离谱时会被
    // VehicleState.parseReportTime 挡掉、退回本机拉取时间，认错了也不会显示出错误时间。
    [VehicleSignal.collectTime, ['1']],

    // 1 = 已锁。真车标定：正反两次值完全对调才采信。
    [VehicleSignal.driverDoorLocked, ['1298']],
    [VehicleSignal.driverDoor, ['1277']],
    // 官方只写了后两门和尾门/前备箱；四门必然连号，副驾只能是 1278。
    [VehicleSignal.passengerDoor, ['1278']],
    [VehicleSignal.leftRearDoor, ['1279']],
    [VehicleSignal.rightRearDoor, ['1280']],
    [VehicleSignal.trunkOpen, ['1281']],
    [VehicleSignal.frontTrunkOpen, ['1282']],
    // 两次独立标定都指向它：只在开关空调时动。
    [VehicleSignal.acSwitch, ['1938']],
    // 真车联调钉死：26 度 3 档 → 2183=26、1941=3；改 22 度 6 档同时跟着变。
    [VehicleSignal.acSetting, ['2183']],
    [VehicleSignal.acFanLevel, ['1941']],
    // 开度百分比，0=关闭。轮位顺序不是连号的顺序：644 左前、645 左后、865 右前、866 右后。
    //
    // **不是每台车都报这一组**：C11 增程版（2026-08-07 实测 90 字段）四个全缺。
    // 官方自己也只拿它喂 3D 车模的车窗动画，判「车窗开没开」用的是下面那组状态位。
    [VehicleSignal.leftFrontWindow, ['644']],
    [VehicleSignal.leftRearWindow, ['645']],
    [VehicleSignal.rightFrontWindow, ['865']],
    [VehicleSignal.rightRearWindow, ['866']],
    // 车窗开合状态位，官方判据是**非 `'0'` 即开**（`OooOOO0.OooO0OO()`）。
    // 增程版只报这一组，开度那组一个都没有——先前只接开度，它整项就是空的。
    // **轮位顺序和开度那组不一样**：1693 左前、1694 右前、1695 左后、1696 右后。
    [VehicleSignal.leftFrontWindowOpen, ['1693']],
    [VehicleSignal.rightFrontWindowOpen, ['1694']],
    [VehicleSignal.leftRearWindowOpen, ['1695']],
    [VehicleSignal.rightRearWindowOpen, ['1696']],

    // 早上 26.5、午后 31.5，对得上车机显示。
    [VehicleSignal.indoorTemp, ['1349']],

    [VehicleSignal.gearStatus, ['1010']],
    [VehicleSignal.powerOn3, ['1258']],

    // 哨兵模式状态位。抓包差分「开→看→关」三段，3636 干净地 0→1→0 与开关完全对齐，
    // 且和油量 3235/续航 3260 同处原始车辆信号段，最像车端状态位。1=开、0=关。
    // legacy（S01/T03）不给：这两个车型本就不支持哨兵。见 sentinel-mode-interfaces.md §3。
    [VehicleSignal.sentinel, ['3636']],

    // 动力电池总电压。**同是 C11，动力版本不同电压平台也不同**：纯电版 800V（实测 708–718 V，
    // 标定就在这台做的），增程版 400V（实测 421.3 V）。两版差一倍，判据靠字段本身、不靠量级。
    // 跟随 SOC 单调下降，充电时端电压升高，验证通过。
    [VehicleSignal.batteryVoltage, ['1177']],
    // 电池电流：制热功率 3500W ÷ 716.9V ≈ 4.88A 与同刻 1178 的跳变吻合；充电时 −8.699。
    [VehicleSignal.batteryCurrent, ['1178']],
    [VehicleSignal.minSingleTemp, ['1182']],
    // PTC 加热功率（W），官方读作 ptcPower。
    [VehicleSignal.ptcPower, ['1348']],
    [VehicleSignal.thermalManageRequest, ['1186']],

    // 充电剩余时间（分钟）。只在充电时才出现的字段。
    [VehicleSignal.chargeRemainTime, ['1200']],
    // 充电状态：0 不代表没插枪；1=充电中、2=本次充电已结束。
    [VehicleSignal.chargeState, ['1149']],
    // 充电枪已连接：插上即 1、拔掉即 0，充不充电不影响。
    [VehicleSignal.chargeGunConnected, ['47']],
    // 直流快充枪已连接，官方判据 != "0"。
    [VehicleSignal.fastCharging, ['1197']],
    [VehicleSignal.healthyCharge, ['48']],
    [VehicleSignal.cancelChargeOnce, ['3737']],

    // 增程版专有的一组。纯电车也会报（3260 = 标定出的续航），判断增程要看油量。
    [VehicleSignal.gasolinePercent, ['3235']],
    [VehicleSignal.cltcGasolineRange, ['3256']],
    [VehicleSignal.cltcEnergyRange, ['3257']],
    [VehicleSignal.cltcTotalRange, ['3258']],
    [VehicleSignal.wltcGasolineRange, ['3259']],
    [VehicleSignal.wltcEnergyRange, ['3260']],
    [VehicleSignal.wltcTotalRange, ['3261']],
    [VehicleSignal.workingCondition, ['3262']],
    [VehicleSignal.fuelLevel, ['2956']],
    [VehicleSignal.fuelHeating, ['2946']],
    [VehicleSignal.fuelHeatingError, ['2954']],

    // 空调模式：手动制冷 1 → 自动 0 → 制冷 1 → 制热 3。注意 3 在 S01 那套里是自动，这里是制热。
    [VehicleSignal.acMode, ['3713']],
    // 自动位，1 = 自动。
    [VehicleSignal.acTempMode, ['1939']],
    // 内外循环（1 = 内循环）。这一项之前整个是缺的——空调页那张「内循环 / 外循环」卡
    // 一直只能显示本机草稿。2026-11-19 对照 leapauto 定名：原先记的「制热那份从 1 变 0，
    // 而驾驶门 1277 全程没动」换成内外循环就讲得通了——制热时空调自动切到外循环。
    [VehicleSignal.acCircleMode, ['1943']],
    // 前挡除雾、快速降温、快速制热三个状态位。2669 / 2681 原先只在胎压误报那段里被排除为
    // 「每车取值不同、正常时也非 0 的其它信号」（当时抓到 2669=1、2681=2），和这个语义不矛盾。
    [VehicleSignal.windshieldDefrost, ['1945']],
    [VehicleSignal.rapidCooling, ['2669']],
    [VehicleSignal.rapidHeating, ['2681']],

    // 舒适座舱。八个座椅信号 + 方向盘两项 + 后视镜三项，全部在实测 C16 的真实
    // signalMap 里逐个在场（采样时功能都没开、值全为 0）。值域：座椅 0…3、方向盘 0…2、后视镜 0/1。
    // 语义来自第三方仓库 leapauto。
    [VehicleSignal.driverSeatHeating, ['2100']],
    [VehicleSignal.driverSeatVentilation, ['2101']],
    [VehicleSignal.passengerSeatHeating, ['2118']],
    [VehicleSignal.passengerSeatVentilation, ['2119']],
    [VehicleSignal.leftRearSeatHeating, ['1879']],
    [VehicleSignal.leftRearSeatVentilation, ['3727']],
    [VehicleSignal.rightRearSeatHeating, ['1880']],
    [VehicleSignal.rightRearSeatVentilation, ['3728']],
    [VehicleSignal.steeringWheelHeating, ['1816']],
    [VehicleSignal.steeringWheelHeatMinutes, ['1624']],
    [VehicleSignal.leftMirrorHeating, ['49']],
    [VehicleSignal.rightMirrorHeating, ['50']],
    [VehicleSignal.rearWindowHeating, ['1946']],

    // 车载冰箱。**实测用的这台 C16 一个都不报**（abilities 也没有 `76`），
    // 两路证据一致判定没装这个选装件，界面整块隐藏。
    // 唯一在场的是 `11260`（离车保温截止时间，值 0），单独一个确认不了任何事。
    [VehicleSignal.fridgeSwitch, ['10709']],
    [VehicleSignal.fridgeMode, ['10708']],
    [VehicleSignal.fridgeTargetTemp, ['10707']],
    [VehicleSignal.fridgeStyle, ['10711']],
    [VehicleSignal.fridgeFault, ['10712']],
    [VehicleSignal.fridgeParkSwitch, ['11190']],
    [VehicleSignal.fridgeParkDurationHours, ['11189']],
    [VehicleSignal.fridgeParkCycles, ['11191']],
    [VehicleSignal.fridgeParkEndTime, ['11260']],

    // 遮阳帘 / 天窗开度。**`1724` 是遮阳帘、`1718` 才是天窗**。和实测 C16 的能力码互相印证：
    // 有 `13`（遮阳帘）、没有 `25`（天窗），signalMap 里也正好是 `1724` 在、`1718` 不在。
    [VehicleSignal.sunshadeOpening, ['1724']],
    [VehicleSignal.sunroofOpening, ['1718']]
  ]), WindowScale.percent, ClimateModeCoding.numeric);

  /** 认不出来的体系。取值全部返回 null，界面老实显示占位符。 */
  static readonly unknown: SignalSchema = new SignalSchema('unknown', new Map<VehicleSignal, string[]>());

  /**
   * 按 `signalMap` 自身的形态判断用哪套表。
   *
   * 不看 `carType`：车型字符串会随新车不断增加，而口径就两套，
   * 按形态判断能让新车型零改动接入。
   */
  static detect(signalMap: Map<string, string>, carType: string = ''): SignalSchema {
    if (signalMap.has('soc')) {
      // 车型只用来定车窗刻度的方向：T03 和 S01 共用这张表、共用同一个
      // leftFrontWindowPercent 字段，方向却是反的（S01 判开 != 10、T03 判开 != 0），
      // 光看上报形态区分不出来。
      // 前缀匹配，判据统一收在 `CarTypeFamily` 里：这儿原先是精确相等，
      // 和下发那边的 `startsWith` 对不上，carType 带后缀就会两边各判各的。
      if (CarTypeFamily.isT03(carType)) {
        return new SignalSchema(
          'legacy-t03',
          SignalSchema.legacy.keys,
          WindowScale.percent,
          SignalSchema.legacy.climateModeCoding
        );
      }
      return SignalSchema.legacy;
    }
    let numericKeys = 0;
    signalMap.forEach((_value: string, key: string) => {
      if (key.length > 0 && /^[0-9]+$/.test(key)) {
        numericKeys++;
      }
    });
    return numericKeys * 2 > signalMap.size ? SignalSchema.numeric : SignalSchema.unknown;
  }
}
