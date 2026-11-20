import { SharedSettings } from './SharedSettings';
import { VehicleSignal, SignalSchema, ALL_VEHICLE_SIGNALS } from './SignalSchema';

/**
 * 引导车主操作车辆，用车况前后的差异反推信号 ID。
 *
 * 存在的理由：零跑没有公开信号表。连续量还能靠量级推，但门窗锁这类布尔量，
 * 车停着的时候上报的全是 0，除了「动一下看谁变了」没有别的办法。
 */
export interface CalibrationTask {
  id: string;
  /** 这一步要标定的信号。 */
  signal: VehicleSignal;
  title: string;
  /** 正向动作。 */
  forward: string;
  /** 复原动作。单向变化可能只是赶巧，反向也跟着变才算数。 */
  backward: string;
  hint: string;
}

export class CalibrationTasks {
  /**
   * 八个任务，每个都是「操作 → 复原」两步。
   *
   * 顺序有讲究：一次只动一个东西。开车门会顺带解锁，所以车锁排在车门前面先标定完；
   * 空调的温度和风量得在空调开着的时候调，所以排在开关空调那步后面。
   */
  static readonly all: CalibrationTask[] = [
    {
      id: 'lock',
      signal: VehicleSignal.driverDoorLocked,
      title: '车锁',
      forward: '解锁车辆',
      backward: '重新锁上车辆',
      hint: '用车钥匙或手机钥匙都行，不要开车门'
    },
    {
      id: 'driverDoor',
      signal: VehicleSignal.driverDoor,
      title: '驾驶位车门',
      forward: '打开驾驶位车门',
      backward: '关上驾驶位车门',
      hint: '只开这一扇，其他门保持关闭'
    },
    {
      id: 'trunk',
      signal: VehicleSignal.trunkOpen,
      title: '后备箱',
      forward: '打开后备箱',
      backward: '关上后备箱',
      hint: ''
    },
    {
      id: 'window',
      signal: VehicleSignal.leftFrontWindow,
      title: '主驾车窗',
      forward: '把主驾车窗降下一半',
      backward: '把主驾车窗升回去关好',
      hint: '只动主驾这一扇'
    },
    {
      id: 'rearWindow',
      signal: VehicleSignal.leftRearWindow,
      title: '左后车窗',
      forward: '把左后车窗降下一半',
      backward: '把左后车窗升回去关好',
      hint: '前窗保持关好，只动左后这一扇'
    },
    {
      id: 'climate',
      signal: VehicleSignal.acSwitch,
      title: '空调',
      forward: '打开空调',
      backward: '关闭空调',
      hint: '在车里操作，不要用 App 的空调按钮'
    },
    {
      id: 'acTemp',
      signal: VehicleSignal.acSetting,
      title: '空调温度',
      forward: '先把空调打开，再把设定温度调高 3 度',
      backward: '把温度调回原来的度数',
      hint: '记住原来是多少度，第 2 步要调回同一个值'
    },
    {
      id: 'acFan',
      signal: VehicleSignal.acFanLevel,
      title: '空调风量',
      forward: '把风量调到最大档',
      backward: '把风量调回原来的档位',
      hint: '空调要一直开着；调完风量记得把空调关掉'
    }
  ];
}

/** 一个字段在操作前后的变化。 */
export interface SignalChange {
  key: string;
  before: string;
  after: string;
}

/** 一个任务两步走完的结果。 */
export class TaskOutcome {
  taskID: string;
  signal: string;
  forward: SignalChange[];
  backward: SignalChange[];
  /** 复原那一步做没做。跳过了就只剩正向证据，判据要换一套更严的。 */
  didReverse: boolean;

  constructor(taskID: string, signal: string, forward: SignalChange[],
    backward: SignalChange[], didReverse: boolean = true) {
    this.taskID = taskID;
    this.signal = signal;
    this.forward = forward;
    this.backward = backward;
    this.didReverse = didReverse;
  }

  /**
   * 正反两次都变、且值完全对调的 key。只有这种才写进映射表。
   * 只在一个方向出现的，可能是车自己在动（空调余温、电压波动），不能算。
   */
  get confirmedKeys(): string[] {
    if (!this.didReverse) {
      // 单向任务：唯一站得住的判据是「没有别的字段陪着一起动」。
      return this.forward.length === 1 ? [this.forward[0].key] : [];
    }
    const out: string[] = [];
    for (let i = 0; i < this.forward.length; i++) {
      const change = this.forward[i];
      const back = this.backward.find((b: SignalChange) => b.key === change.key);
      if (back === undefined) {
        continue;
      }
      if (back.before === change.after && back.after === change.before) {
        out.push(change.key);
      }
    }
    out.sort();
    return out;
  }

  /** 只在一个方向出现的 key，报告里列出来供人工判断，但不生效。 */
  get unconfirmedKeys(): string[] {
    const confirmed = new Set<string>(this.confirmedKeys);
    const all = new Set<string>();
    for (let i = 0; i < this.forward.length; i++) {
      all.add(this.forward[i].key);
    }
    for (let i = 0; i < this.backward.length; i++) {
      all.add(this.backward[i].key);
    }
    const out: string[] = [];
    all.forEach((key: string) => {
      if (!confirmed.has(key)) {
        out.push(key);
      }
    });
    out.sort();
    return out;
  }

  get isConfirmed(): boolean {
    return this.confirmedKeys.length > 0;
  }
}

/**
 * 静止基线：什么都不操作时自己就会变的字段。
 *
 * 不先摸清这些，每个任务的 diff 都会混进十几个无关 ID——时间戳每次都变，
 * 经纬度车停着也会飘几十米，电压电流温度是连续量一直在小幅跳。
 */
export class CalibrationBaseline {
  noisyKeys: Set<string>;
  sampleCount: number;

  constructor(noisyKeys: Set<string> = new Set<string>(), sampleCount: number = 0) {
    this.noisyKeys = noisyKeys;
    this.sampleCount = sampleCount;
  }

  /**
   * 采了好几次却一个字段都没变——车多半睡着了，车端在重复上报同一份缓存。
   * 这种基线等于没采：后面每一步的 diff 都会混进自己会跳的字段。
   */
  get looksAsleep(): boolean {
    return this.sampleCount > 1 && this.noisyKeys.size === 0;
  }

  /** 连续几次静止采样两两相比，变过的都算噪声。 */
  static make(samples: Map<string, string>[]): CalibrationBaseline {
    if (samples.length <= 1) {
      return new CalibrationBaseline(new Set<string>(), samples.length);
    }
    const noisy = new Set<string>();
    for (let i = 1; i < samples.length; i++) {
      const changes = Calibration.changes(samples[i - 1], samples[i]);
      for (let j = 0; j < changes.length; j++) {
        noisy.add(changes[j].key);
      }
    }
    return new CalibrationBaseline(noisy, samples.length);
  }
}

export class Calibration {
  /** 两份 signalMap 的差异。只看变化，新增和消失的字段都算。 */
  static changes(before: Map<string, string>, after: Map<string, string>,
    noisy: Set<string> = new Set<string>()): SignalChange[] {
    const keys = new Set<string>();
    before.forEach((_value: string, key: string) => {
      keys.add(key);
    });
    after.forEach((_value: string, key: string) => {
      keys.add(key);
    });
    const sorted: string[] = [];
    keys.forEach((key: string) => {
      if (!noisy.has(key)) {
        sorted.push(key);
      }
    });
    sorted.sort();

    const out: SignalChange[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const key = sorted[i];
      const oldValue = before.get(key) ?? '';
      const newValue = after.get(key) ?? '';
      if (oldValue === newValue) {
        continue;
      }
      if (Calibration.isLocation(key, [oldValue, newValue])) {
        continue;
      }
      out.push({ key: key, before: oldValue, after: newValue });
    }
    return out;
  }

  /**
   * 位置字段无条件排除，不进 diff 也就进不了报告。
   *
   * 「报告里不含位置」是给车主的承诺，不能建立在「静止基线刚好把坐标采进噪声」上面——
   * 车睡着那次三份采样一模一样，噪声名单是空的，坐标就一路进了报告。
   */
  static isLocation(key: string, values: string[]): boolean {
    if (Calibration.locationKeys.has(key)) {
      return true;
    }
    return values.some((v: string) => Calibration.looksLikeCoordinate(v));
  }

  /** 各套体系里所有经纬度的候选 key。 */
  private static readonly locationKeys: Set<string> = Calibration.buildLocationKeys();

  private static buildLocationKeys(): Set<string> {
    const out = new Set<string>();
    const schemas: SignalSchema[] = [SignalSchema.legacy, SignalSchema.numeric];
    const signals: VehicleSignal[] = [VehicleSignal.latitude, VehicleSignal.longitude, VehicleSignal.privacyGPS];
    for (let i = 0; i < schemas.length; i++) {
      for (let j = 0; j < signals.length; j++) {
        const candidates = schemas[i].candidates(signals[j]);
        for (let k = 0; k < candidates.length; k++) {
          out.add(candidates[k]);
        }
      }
    }
    return out;
  }

  /**
   * 按值的形状兜底：小数点后 4 位以上、落在经纬度量程内。
   * 车上其它连续量（温度 31.5、电压 718.6）都只报一位小数，六位小数基本只有坐标。
   */
  private static looksLikeCoordinate(value: string): boolean {
    const dot = value.indexOf('.');
    if (dot < 0) {
      return false;
    }
    const fraction = value.substring(dot + 1);
    if (fraction.length < 4 || !/^[0-9]+$/.test(fraction)) {
      return false;
    }
    const number = Number(value);
    return Number.isFinite(number) && Math.abs(number) <= 180;
  }

  /**
   * 从确认过的任务里取出映射。一个任务只认一个 key——
   * 同时变了好几个的说明这一步没隔离干净，宁可放弃也不猜哪个才对。
   */
  static learnedKeys(outcomes: TaskOutcome[]): Map<VehicleSignal, string> {
    const out = new Map<VehicleSignal, string>();
    for (let i = 0; i < outcomes.length; i++) {
      const outcome = outcomes[i];
      const confirmed = outcome.confirmedKeys;
      if (confirmed.length !== 1) {
        continue;
      }
      const signal = Calibration.signalFromRaw(outcome.signal);
      if (signal !== null) {
        out.set(signal, confirmed[0]);
      }
    }
    return out;
  }

  static signalFromRaw(raw: string): VehicleSignal | null {
    for (let i = 0; i < ALL_VEHICLE_SIGNALS.length; i++) {
      if (ALL_VEHICLE_SIGNALS[i] === raw) {
        return ALL_VEHICLE_SIGNALS[i];
      }
    }
    return null;
  }

  /** 导出给开发者的报告。不含 VIN、不含账号，经纬度在 changes 里就已经被无条件滤掉。 */
  static report(carType: string, schemaID: string, baseline: CalibrationBaseline,
    outcomes: TaskOutcome[], dateText: string): string {
    const noisySorted: string[] = [];
    baseline.noisyKeys.forEach((key: string) => {
      noisySorted.push(key);
    });
    noisySorted.sort();

    const lines: string[] = [
      '壹跑 车型标定报告',
      `车型: ${carType.length === 0 ? '(未知)' : carType}`,
      `字段体系: ${schemaID}`,
      `日期: ${dateText}`,
      '',
      '【噪声字段】静止时自己会变，已从所有 diff 中排除',
      noisySorted.length === 0 ? '(无)' : noisySorted.join(', '),
      ''
    ];

    if (baseline.looksAsleep) {
      lines.push('⚠ 基线一个字段都没变，车很可能是睡着的。');
      lines.push('  下面每一步的 diff 里都会混进时间戳、电压这类自己会跳的字段，');
      lines.push('  双向对调的判据还站得住，单向那几步基本不可信。建议车醒着时重做一次。');
      lines.push('');
    }

    for (let i = 0; i < CalibrationTasks.all.length; i++) {
      const task = CalibrationTasks.all[i];
      const outcome = outcomes.find((o: TaskOutcome) => o.taskID === task.id);
      if (outcome === undefined) {
        lines.push(`【${task.title}】未做`);
        lines.push('');
        continue;
      }
      let verdict: string;
      if (!outcome.isConfirmed) {
        verdict = '未确认 ⚠';
      } else {
        verdict = outcome.didReverse ? '双向确认 ✓' : '单向唯一变化 ✓';
      }
      lines.push(`【${task.title}】${verdict}`);
      lines.push(`  目标信号: ${task.signal}`);
      lines.push(`  ${task.forward}:`);
      const forwardLines = Calibration.describe(outcome.forward);
      for (let j = 0; j < forwardLines.length; j++) {
        lines.push(forwardLines[j]);
      }
      if (outcome.didReverse) {
        lines.push(`  ${task.backward}:`);
        const backwardLines = Calibration.describe(outcome.backward);
        for (let j = 0; j < backwardLines.length; j++) {
          lines.push(backwardLines[j]);
        }
      } else {
        lines.push(`  ${task.backward}: (跳过)`);
      }
      if (outcome.confirmedKeys.length > 0) {
        lines.push(`  → 确认: ${outcome.confirmedKeys.join(', ')}`);
      }
      if (outcome.unconfirmedKeys.length > 0) {
        lines.push(`  → 只单向变化，未采信: ${outcome.unconfirmedKeys.join(', ')}`);
      }
      lines.push('');
    }

    const learned = Calibration.learnedKeys(outcomes);
    lines.push('【可写入映射表】');
    if (learned.size === 0) {
      lines.push('(无)');
    } else {
      const entries: string[] = [];
      learned.forEach((key: string, signal: VehicleSignal) => {
        entries.push(`  ${signal}: "${key}",`);
      });
      entries.sort();
      for (let i = 0; i < entries.length; i++) {
        lines.push(entries[i]);
      }
    }
    return lines.join('\n');
  }

  private static describe(changes: SignalChange[]): string[] {
    if (changes.length === 0) {
      return ['    (没捕捉到变化)'];
    }
    return changes.map((c: SignalChange) =>
      `    ${c.key}: ${c.before.length === 0 ? '(无)' : c.before} → ${c.after.length === 0 ? '(无)' : c.after}`);
  }
}

/** 本机标定学到的映射，按车型存在共享设置里——服务卡片也要用同一份。 */
export class LearnedSignals {
  private static readonly storageKey = 'calibration.learned';

  private static load(): Record<string, Record<string, string>> {
    const text = SharedSettings.getString(LearnedSignals.storageKey, '');
    if (text.length === 0) {
      return {};
    }
    try {
      return JSON.parse(text) as Record<string, Record<string, string>>;
    } catch (e) {
      return {};
    }
  }

  static keys(carType: string): Map<VehicleSignal, string> {
    const out = new Map<VehicleSignal, string>();
    if (carType.length === 0) {
      return out;
    }
    const stored = LearnedSignals.load()[carType.toUpperCase()];
    if (stored === undefined) {
      return out;
    }
    const signalNames = Object.keys(stored);
    for (let i = 0; i < signalNames.length; i++) {
      const signal = Calibration.signalFromRaw(signalNames[i]);
      if (signal !== null) {
        out.set(signal, stored[signalNames[i]]);
      }
    }
    return out;
  }

  static save(learned: Map<VehicleSignal, string>, carType: string): void {
    if (carType.length === 0 || learned.size === 0) {
      return;
    }
    const all = LearnedSignals.load();
    const type = carType.toUpperCase();
    // 与已有的合并：分几次标定完也能累加，不会把上次的成果冲掉。
    const stored: Record<string, string> = all[type] ?? {};
    learned.forEach((key: string, signal: VehicleSignal) => {
      stored[signal] = key;
    });
    all[type] = stored;
    SharedSettings.setString(LearnedSignals.storageKey, JSON.stringify(all));
  }

  static clear(carType: string): void {
    const all = LearnedSignals.load();
    const target = carType.toUpperCase();
    // ArkTS 不支持 delete，重建一份不含该车型的记录。
    const kept: Record<string, Record<string, string>> = {};
    const types = Object.keys(all);
    for (let i = 0; i < types.length; i++) {
      if (types[i] !== target) {
        kept[types[i]] = all[types[i]];
      }
    }
    SharedSettings.setString(LearnedSignals.storageKey, JSON.stringify(kept));
  }
}
