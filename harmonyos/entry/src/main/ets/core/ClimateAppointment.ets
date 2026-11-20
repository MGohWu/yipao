import { JsonValue } from './JsonValue';

/** 星期选择器上的一项：协议值 + 短标签。 */
export interface WeekdayOption {
  value: number;
  label: string;
}

/**
 * 预约类指令（cmdid 161 预约电池预热、171 预约空调）共用的星期编码。
 *
 * **0 = 周日、1 = 周一 … 6 = 周六。** 2026-11-19 按 leapauto 的协议文档定下（同 iOS
 * `AppointmentWeekday`），171 和 161 一起改。在此之前 161 发的是 1…7（周日 = 7，出自静态分析），
 * 两边都没有勾周日的实车样本，暂定按 0 走。如果哪天读回来的预约里出现 `7`，就说明这条定错了。
 */
export class AppointmentWeekday {
  /** 界面上的排列顺序：周一在前、周日在末，和国内日历习惯一致；值仍是协议编码。 */
  static readonly ordered: WeekdayOption[] = [
    { value: 1, label: '一' }, { value: 2, label: '二' }, { value: 3, label: '三' },
    { value: 4, label: '四' }, { value: 5, label: '五' }, { value: 6, label: '六' },
    { value: 0, label: '日' }
  ];

  static readonly workdays: number[] = [1, 2, 3, 4, 5];

  private static sameSet(a: number[], b: number[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    return a.every((value: number): boolean => b.includes(value));
  }

  /** 「每周一、三、五」这种人话。空数组是一次性预约。 */
  static summary(days: number[]): string {
    if (days.length === 0) {
      return '仅一次';
    }
    if (days.length === 7) {
      return '每天';
    }
    if (AppointmentWeekday.sameSet(days, AppointmentWeekday.workdays)) {
      return '工作日';
    }
    if (AppointmentWeekday.sameSet(days, [6, 0])) {
      return '周末';
    }
    const labels = AppointmentWeekday.ordered
      .filter((option: WeekdayOption): boolean => days.includes(option.value))
      .map((option: WeekdayOption): string => option.label);
    return '每周' + labels.join('、');
  }
}

/** 预约只开放制冷 / 制热两档：自动模式在 171 上没有任何样本（抓包里 `operate` 只见过 `manual`）。 */
export enum ClimateAppointmentMode {
  cold = 'cold',
  hot = 'hot'
}

/**
 * 一条预约空调（cmdid 171）。对应 iOS `Core/ClimateAppointment.swift`。
 *
 * 协议出处：leapauto 的官方抓包 `[681]`（设置）、`cancel/[332]`（取消）、`[334]`（取消后回读）。
 * 设置 payload 里除了时间、星期、温度、模式之外，风量 / 循环 / 除雾 / 出风位置都是固定值——
 * 选的方案是照官方抓包的默认值发（7 档 / 内循环 / 前挡除雾开 / 全车出风），不在界面上暴露。
 *
 * 值语义：改之前先 `copy()`。
 */
export class ClimateAppointment {
  static readonly minTemperature: number = 18;
  static readonly maxTemperature: number = 32;

  hour: number = 7;
  minute: number = 30;
  /** 协议编码（0 = 周日），见 `AppointmentWeekday`。空数组 = 仅一次。 */
  days: number[] = AppointmentWeekday.workdays.slice();
  temperature: number = 24;
  mode: ClimateAppointmentMode = ClimateAppointmentMode.hot;
  /** 车上已有那条预约的 id。改已有预约时沿用，新建时为 null、下发时现造。 */
  setID: string | null = null;

  copy(): ClimateAppointment {
    const next = new ClimateAppointment();
    next.hour = this.hour;
    next.minute = this.minute;
    next.days = this.days.slice();
    next.temperature = this.temperature;
    next.mode = this.mode;
    next.setID = this.setID;
    return next;
  }

  static modeLabel(mode: ClimateAppointmentMode): string {
    return mode === ClimateAppointmentMode.cold ? '制冷' : '制热';
  }

  get timeText(): string {
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${pad(this.hour)}:${pad(this.minute)}`;
  }

  get summary(): string {
    return `${AppointmentWeekday.summary(this.days)} ${this.timeText} · `
      + `${ClimateAppointment.modeLabel(this.mode)} ${this.temperature} ℃`;
  }

  /**
   * 下一次到点的时刻。`start_time` 带日期，一次性预约（`days` 空）必须落在将来——
   * 今天这个钟点已经过了就往后推一天，不然下发的是一个已经过去的时间。
   */
  nextStart(now: Date): Date {
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate(), this.hour, this.minute, 0);
    if (today.getTime() > now.getTime()) {
      return today;
    }
    return new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, this.hour, this.minute, 0);
  }

  // MARK: - 回读

  /**
   * 从 `getappointment` 回读的 `controls[]` 里取第一条开着的预约。
   *
   * `controls` 为空（官方取消之后回读就是这样）或者里面没有 `on == "1"` 的项，返回 null——
   * 那是「车上没有预约」，不是「读不到」，调用方要分清。
   */
  static parse(controls: JsonValue[]): ClimateAppointment | null {
    for (const item of controls) {
      if (item.objectValue === null) {
        continue;
      }
      if (item.get('on')?.stringValue !== '1') {
        continue;
      }
      const start = item.get('start_time')?.stringValue ?? null;
      if (start === null) {
        continue;
      }
      const clock = ClimateAppointment.clock(start);
      if (clock === null) {
        continue;
      }
      const appointment = new ClimateAppointment();
      appointment.hour = clock[0];
      appointment.minute = clock[1];
      const days: number[] = [];
      const rawDays = item.get('days')?.arrayValue ?? [];
      for (const day of rawDays) {
        const value = day.intValue;
        if (value !== null && !days.includes(value)) {
          days.push(value);
        }
      }
      appointment.days = days;
      const temperature = item.get('temperature')?.intValue ?? 24;
      appointment.temperature = Math.min(ClimateAppointment.maxTemperature,
        Math.max(ClimateAppointment.minTemperature, temperature));
      const mode = item.get('mode')?.stringValue ?? '';
      appointment.mode = mode === 'cold' ? ClimateAppointmentMode.cold : ClimateAppointmentMode.hot;
      appointment.setID = item.get('set_id')?.stringValue ?? null;
      return appointment;
    }
    return null;
  }

  /** `"2026-10-22 19:54:00"` → [19, 54]。 */
  static clock(startTime: string): number[] | null {
    const parts = startTime.split(' ');
    const time = parts[parts.length - 1];
    const hm = time.split(':');
    if (hm.length < 2) {
      return null;
    }
    const hour = Number(hm[0]);
    const minute = Number(hm[1]);
    if (!Number.isInteger(hour) || !Number.isInteger(minute)
      || hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return null;
    }
    return [hour, minute];
  }

  /**
   * `getappointment` 的 `data` 是一段 **JSON 字符串**，里面才是 `{"controls":[...]}`。
   * 也兼容网关哪天直接回对象。解析不出返回 null（= 读不到，不是「没有预约」）。
   */
  static controlsFromAppointmentData(data: JsonValue | null): JsonValue[] | null {
    if (data === null) {
      return null;
    }
    if (data.objectValue !== null) {
      return data.get('controls')?.arrayValue ?? [];
    }
    const text = data.stringValue;
    if (text === null || text.length === 0) {
      return null;
    }
    const decoded = JsonValue.parse(text);
    if (decoded === null || decoded.objectValue === null) {
      return null;
    }
    return decoded.get('controls')?.arrayValue ?? [];
  }
}
