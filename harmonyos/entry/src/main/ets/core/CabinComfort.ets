import { VehicleSignal } from './SignalSchema';

/**
 * 舒适座舱（座椅加热 / 通风、方向盘加热、后视镜加热）与车载冰箱的纯类型。
 *
 * 对应 iOS `Core/CabinComfort.swift`。车况派生（`seatLevel` 等）和指令构造器写在
 * `LeapModels.ets` 里（`VehicleState` / `LeapCommand` 身上），这个文件只放不依赖它们的类型，
 * 免得两个文件互相 import。
 *
 * 协议来源是第三方仓库 leapauto，信号 ID 在实测 C16 的真实 signalMap 里逐个在场（A 级），
 * 五条下发指令（301 / 370 / 320 / 440 / 500）**都没有实车样本**。
 */

// MARK: - 座椅

/**
 * 可远控的座位。协议里 `position` 字段只认这四个值，第三排没有任何对应值与信号。
 *
 * 下发走 cmdid `301`（加热）/ `370`（通风），state 是 `{"position":"left_front","level":"2"}`。
 */
export enum SeatPosition {
  driver = 'driver',
  passenger = 'passenger',
  leftRear = 'leftRear',
  rightRear = 'rightRear'
}

export class SeatPositions {
  static readonly all: SeatPosition[] = [
    SeatPosition.driver, SeatPosition.passenger, SeatPosition.leftRear, SeatPosition.rightRear
  ];
  static readonly front: SeatPosition[] = [SeatPosition.driver, SeatPosition.passenger];
  static readonly rear: SeatPosition[] = [SeatPosition.leftRear, SeatPosition.rightRear];

  /** 下发用的 `position` 值。 */
  static wireValue(position: SeatPosition): string {
    switch (position) {
      case SeatPosition.driver:
        return 'left_front';
      case SeatPosition.passenger:
        return 'right_front';
      case SeatPosition.leftRear:
        return 'left_rear';
      default:
        return 'right_rear';
    }
  }

  static label(position: SeatPosition): string {
    switch (position) {
      case SeatPosition.driver:
        return '主驾';
      case SeatPosition.passenger:
        return '副驾';
      case SeatPosition.leftRear:
        return '二排左';
      default:
        return '二排右';
    }
  }
}

/** 座椅的两条通道。整页只有一个当前通道，切换只换视图，不下发。 */
export enum SeatComfortChannel {
  heating = 'heating',
  ventilation = 'ventilation'
}

export class SeatChannels {
  static readonly all: SeatComfortChannel[] = [SeatComfortChannel.heating, SeatComfortChannel.ventilation];

  /** 座椅两条通道都是 0…3 档。 */
  static readonly maxLevel: number = 3;

  static label(channel: SeatComfortChannel): string {
    return channel === SeatComfortChannel.heating ? '加热' : '通风';
  }

  static cmdid(channel: SeatComfortChannel): string {
    return channel === SeatComfortChannel.heating ? '301' : '370';
  }

  /** 这个座位 + 这条通道对应的车况信号。 */
  static signal(channel: SeatComfortChannel, position: SeatPosition): VehicleSignal {
    if (channel === SeatComfortChannel.heating) {
      switch (position) {
        case SeatPosition.driver:
          return VehicleSignal.driverSeatHeating;
        case SeatPosition.passenger:
          return VehicleSignal.passengerSeatHeating;
        case SeatPosition.leftRear:
          return VehicleSignal.leftRearSeatHeating;
        default:
          return VehicleSignal.rightRearSeatHeating;
      }
    }
    switch (position) {
      case SeatPosition.driver:
        return VehicleSignal.driverSeatVentilation;
      case SeatPosition.passenger:
        return VehicleSignal.passengerSeatVentilation;
      case SeatPosition.leftRear:
        return VehicleSignal.leftRearSeatVentilation;
      default:
        return VehicleSignal.rightRearSeatVentilation;
    }
  }
}

// MARK: - 车载冰箱

/**
 * 冰箱运行模式。协议里**只有两个值**——没有独立的「冷冻」模式，
 * 「冷藏 / 冷冻」是同一个 `cold` 模式下的不同目标温度（见 `FridgePreset`）。
 */
export enum FridgeMode {
  cold = 'cold',
  hot = 'hot'
}

/**
 * 制冷风格。
 *
 * ⚠️ leapauto 的接口文档写 `fast`、它自己的代码写 `turbo`，两者只能有一个对。
 * 这里按**代码**走；真车发了不认时，第一个要试的替代值就是 `fast`。
 */
export enum FridgeStyle {
  normal = 'normal',
  turbo = 'turbo'
}

/** 界面上的三个预设。协议侧只是 `mode` + `temp` 的两种组合。 */
export enum FridgePreset {
  chill = 'chill',
  freeze = 'freeze',
  keepWarm = 'keepWarm'
}

export class FridgeText {
  static modeLabel(mode: FridgeMode): string {
    return mode === FridgeMode.hot ? '保温' : '制冷';
  }

  static styleLabel(style: FridgeStyle): string {
    return style === FridgeStyle.turbo ? '急速' : '标准';
  }

  /** 上报信号 `10708`：0 = 制冷、1 = 保温暖食。 */
  static modeFromSignal(raw: number | null): FridgeMode {
    return raw === 1 ? FridgeMode.hot : FridgeMode.cold;
  }

  /** 上报信号 `10711`：0 = 标准、1 = 急速。 */
  static styleFromSignal(raw: number | null): FridgeStyle {
    return raw === 1 ? FridgeStyle.turbo : FridgeStyle.normal;
  }

  static readonly presets: FridgePreset[] = [FridgePreset.chill, FridgePreset.freeze, FridgePreset.keepWarm];

  static presetLabel(preset: FridgePreset): string {
    switch (preset) {
      case FridgePreset.chill:
        return '冷藏';
      case FridgePreset.freeze:
        return '冷冻';
      default:
        return '保温';
    }
  }

  static presetMode(preset: FridgePreset): FridgeMode {
    return preset === FridgePreset.keepWarm ? FridgeMode.hot : FridgeMode.cold;
  }

  static presetTemperature(preset: FridgePreset): number {
    switch (preset) {
      case FridgePreset.chill:
        return FridgeSetting.chillTemp;
      case FridgePreset.freeze:
        return FridgeSetting.minTemp;
      default:
        return FridgeSetting.hotTemp;
    }
  }

  /** 当前设定落在哪个预设上。都不落就是 null（三个都不高亮）。 */
  static matching(mode: FridgeMode, temperature: number): FridgePreset | null {
    if (mode === FridgeMode.hot) {
      return FridgePreset.keepWarm;
    }
    if (temperature === FridgeSetting.chillTemp) {
      return FridgePreset.chill;
    }
    if (temperature === FridgeSetting.minTemp) {
      return FridgePreset.freeze;
    }
    return null;
  }
}

/**
 * 一份完整的冰箱设定。cmdid `500` 的 state 是**全量**的——
 * 改一项也要把八个字段一起发出去，所以界面那边维护的是整份草稿，不是增量。
 *
 * 值语义：改之前先 `copy()`，别在共享实例上原地改（草稿要能整份替换才能被状态管理看见）。
 */
export class FridgeSetting {
  /** 制冷目标温度量程，协议给的是 −6…15 ℃。 */
  static readonly minTemp: number = -6;
  static readonly maxTemp: number = 15;
  /** 冷藏预设温度。 */
  static readonly chillTemp: number = 4;
  /** 保温模式固定下发这个温度（协议写死 50 ℃ 恒温）。 */
  static readonly hotTemp: number = 50;
  /** 离车工作时长下限：leapauto 的实现把 `duration` 夹到 ≥1800 秒，照搬。 */
  static readonly minDurationSeconds: number = 1800;

  enabled: boolean = true;
  mode: FridgeMode = FridgeMode.cold;
  /**
   * 制冷目标温度。`mode == hot` 时下发前会被换成 `hotTemp`，这里存的仍是用户调的制冷温度，
   * 这样从保温切回制冷不会把他调好的温度弄丢。
   */
  temperature: number = FridgeSetting.chillTemp;
  style: FridgeStyle = FridgeStyle.normal;
  parkEnabled: boolean = false;
  parkHours: number = 1;

  copy(): FridgeSetting {
    const next = new FridgeSetting();
    next.enabled = this.enabled;
    next.mode = this.mode;
    next.temperature = this.temperature;
    next.style = this.style;
    next.parkEnabled = this.parkEnabled;
    next.parkHours = this.parkHours;
    return next;
  }

  /** 真正下发的温度值。 */
  get wireTemperature(): number {
    if (this.mode === FridgeMode.hot) {
      return FridgeSetting.hotTemp;
    }
    return Math.min(FridgeSetting.maxTemp, Math.max(FridgeSetting.minTemp, this.temperature));
  }

  get durationSeconds(): number {
    return Math.max(FridgeSetting.minDurationSeconds, this.parkHours * 3600);
  }

  get preset(): FridgePreset | null {
    return FridgeText.matching(this.mode, this.wireTemperature);
  }

  /** 套用一个预设。保温不覆盖用户调过的制冷温度（见 `temperature` 的说明）。 */
  apply(preset: FridgePreset): void {
    this.mode = FridgeText.presetMode(preset);
    if (this.mode === FridgeMode.cold) {
      this.temperature = FridgeText.presetTemperature(preset);
    }
  }

  /**
   * 全量 state JSON。字段按 key 排序，和 iOS `JSONSerialization(.sortedKeys)` 的输出逐字一致。
   *
   * `cycles` 这一版固定发 `"1"`：下发口径（`"1"` / `"2"`）和上报口径（`0` / `1`）对不上，
   * 哪个值是「仅本次离车」哪个是「每次离车」没有依据，所以不暴露这个开关。
   * `value` 字段含义不明，协议样本里恒为 `"false"`，照常量发。
   *
   * 手写而不是 JSON.stringify：数字和字符串混装，ArkTS 的 stringify 对 Record 混装会报错。
   */
  get stateJSON(): string {
    return `{"cycles":"1","duration":${this.durationSeconds},"enable":${this.enabled ? 1 : 0}`
      + `,"mode":"${this.mode}","parkEnable":${this.parkEnabled ? 1 : 0}`
      + `,"style":"${this.style}","temp":${this.wireTemperature},"value":"false"}`;
  }

  equals(other: FridgeSetting): boolean {
    return this.enabled === other.enabled && this.mode === other.mode
      && this.temperature === other.temperature && this.style === other.style
      && this.parkEnabled === other.parkEnabled && this.parkHours === other.parkHours;
  }
}

/**
 * 车端报回来的冰箱状态。`fridgeSwitch` 读不到就整个是 null——
 * 没装这个选装件的车（实测用的那台 C16 就是）不该凭空得到一份默认值。
 */
export class FridgeState {
  enabled: boolean = false;
  mode: FridgeMode = FridgeMode.cold;
  targetTemp: number | null = null;
  style: FridgeStyle = FridgeStyle.normal;
  /** 自检故障码，0 为正常。 */
  fault: number = 0;
  parkEnabled: boolean = false;
  parkHours: number | null = null;
  /** 离车保温截止时刻（毫秒）。车端给的是秒级时间戳，0 当没有。 */
  parkEndsAt: number | null = null;

  get hasFault(): boolean {
    return this.fault !== 0;
  }

  /**
   * 把车况当成界面草稿的初值。目标温度读不到时退回冷藏预设，
   * 这不是「伪造车况」——草稿本来就是本机要发的东西，必须有个值。
   */
  asSetting(): FridgeSetting {
    const setting = new FridgeSetting();
    setting.enabled = this.enabled;
    setting.mode = this.mode;
    setting.temperature = this.mode === FridgeMode.hot
      ? FridgeSetting.chillTemp
      : (this.targetTemp ?? FridgeSetting.chillTemp);
    setting.style = this.style;
    setting.parkEnabled = this.parkEnabled;
    setting.parkHours = this.parkHours ?? 1;
    return setting;
  }
}
