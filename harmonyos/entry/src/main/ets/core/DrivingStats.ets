import { JsonValue } from './JsonValue';

/** 里程能耗接口的时间窗（毫秒时间戳，闭区间）。 */
export class DrivingStatsRange {
  begintime: number;
  endtime: number;

  constructor(begintime: number, endtime: number) {
    this.begintime = begintime;
    this.endtime = endtime;
  }

  /**
   * 秒级区间。`getLastweekEC` 收的是**秒**，而同一个 drivingrecord 命名空间下的
   * `mileage/energy/detail` 收毫秒。传错量纲不会报越界、也不返空，服务端一律回
   * `code:2 请求参数含非法字符`——文案指向字符集，跟真实原因半点关系没有。
   */
  get begintimeSeconds(): number {
    return Math.floor(this.begintime / 1000);
  }

  get endtimeSeconds(): number {
    return Math.floor(this.endtime / 1000);
  }

  /** 最近 7 天（含今天），按北京时间整日边界。 */
  static lastSevenDays(nowMs: number = Date.now()): DrivingStatsRange {
    const cnOffset = 8 * 3600;
    const day = 86400;
    const nowSec = nowMs / 1000;
    const cnDayStart = (Math.floor((nowSec + cnOffset) / day) * day) - cnOffset;
    return new DrivingStatsRange(
      Math.trunc((cnDayStart - 6 * day) * 1000),
      Math.trunc((cnDayStart + day) * 1000) - 1
    );
  }

  /**
   * 把 `getLastNweeks100kmECAndRank` 给的 weekStart/weekEnd（"2026-07-06" 这种日期串）
   * 折成北京时间的整周闭区间——官方点某根周柱子时，`getLastweekEC` 收的就是这个区间。
   * weekEnd 要补到当天 23:59:59.999，只传日零点会把最后一天整天漏掉。
   * 日期串缺失/畸形返回 null，这根柱子就点不动。
   */
  static forWeek(weekStart: string | null, weekEnd: string | null): DrivingStatsRange | null {
    const start = DrivingStatsRange.cnDayStartMs(weekStart);
    const end = DrivingStatsRange.cnDayStartMs(weekEnd);
    if (start === null || end === null) {
      return null;
    }
    return new DrivingStatsRange(start, end + 86400000 - 1);
  }

  /** "2026-07-06" → 北京时间当天零点的毫秒时间戳。设备时区跟着用户跑，不能参与。 */
  private static cnDayStartMs(day: string | null): number | null {
    if (day === null) {
      return null;
    }
    const parts = day.split('-');
    // 长度和空段都要判：Number('') 是 0，"2026--06" 会被算成上一年 12 月而不报错。
    if (parts.length !== 3 || parts[0].length === 0 || parts[1].length === 0 || parts[2].length === 0) {
      return null;
    }
    const year = Number(parts[0]);
    const month = Number(parts[1]);
    const date = Number(parts[2]);
    if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(date)) {
      return null;
    }
    return Date.UTC(year, month - 1, date) - 8 * 3600 * 1000;
  }
}

export interface StatsTotals {
  totalMileageKm: number | null;
  totalEnergyKwh: number | null;
  deliveryDays: number | null;
  rangeMileageKm: number | null;
}

export interface DailyMileage {
  day: string;
  mileageKm: number | null;
  energyWh: number | null;
}

export interface EnergyDistribution {
  driverKwh: number;
  acKwh: number;
  otherKwh: number;
  totalKwh: number;
  driverPct: number | null;
  acPct: number | null;
  otherPct: number | null;
}

export interface WeeklyEC {
  weekStart: string | null;
  weekEnd: string | null;
  hundredKmEc: number | null;
}

/** 周柱子的缓存键 / 选中标识。和 iOS 的 `WeeklyEC.id` 同规则。 */
export function weekEcId(week: WeeklyEC): string {
  return `${week.weekStart ?? ''}~${week.weekEnd ?? ''}`;
}

export interface Weekly {
  rankPercent: string | null;
  rankHundredKmEc: number | null;
  weeks: WeeklyEC[];
}

/** 四个 drivingrecord 接口揉成的规范化统计。任一块缺失都为 null。 */
export class DrivingStats {
  totals: StatsTotals | null = null;
  daily: DailyMileage[] = [];
  energyDistribution: EnergyDistribution | null = null;
  weekly: Weekly | null = null;
  range: DrivingStatsRange;
  /**
   * `energyDistribution` 是哪根周柱子的（值为 `weekEcId(week)`）。
   * 正常就是最后一周（本周）——页面默认选中它。周列表没拉到时退回「近 7 天」窗口，
   * 这时为 null，界面得跟着改口，不能顶着某一周的名头显示另一个区间的数。
   */
  distributionWeekId: string | null = null;

  constructor(range: DrivingStatsRange) {
    this.range = range;
  }

  get isEmpty(): boolean {
    return this.totals === null && this.daily.length === 0 &&
      this.energyDistribution === null && this.weekly === null;
  }

  static fromResponses(mileageRaw: JsonValue | null, distributionRaw: JsonValue | null,
    weeklyRaw: JsonValue | null, range: DrivingStatsRange,
    distributionWeekId: string | null = null): DrivingStats {
    const stats = new DrivingStats(range);
    stats.distributionWeekId = distributionWeekId;

    const mileage = mileageRaw !== null ? mileageRaw.get('data') : null;
    if (mileage !== null) {
      stats.totals = {
        totalMileageKm: DrivingStats.intOf(mileage, 'totalmileage'),
        totalEnergyKwh: DrivingStats.intOf(mileage, 'totalEnergy'),
        deliveryDays: DrivingStats.intOf(mileage, 'deliveryDays'),
        rangeMileageKm: DrivingStats.intOf(mileage, 'totalAccumulatedMileage')
      };
      const detail = mileage.get('detail');
      const items = detail !== null ? detail.arrayValue : null;
      if (items !== null) {
        for (let i = 0; i < items.length; i++) {
          const entry = items[i];
          stats.daily.push({
            day: DrivingStats.strOf(entry, 'day') ?? '',
            mileageKm: DrivingStats.intOf(entry, 'accumulatedMileage'),
            energyWh: DrivingStats.intOf(entry, 'accumulatedEnergyConsume')
          });
        }
      }
    }

    stats.energyDistribution = DrivingStats.distributionFrom(distributionRaw);

    const weeklyNode = weeklyRaw !== null ? weeklyRaw.get('data') : null;
    if (weeklyNode !== null) {
      const rankResult = weeklyNode.get('rankResult');
      const weeks: WeeklyEC[] = [];
      const weeklyEC = weeklyNode.get('weeklyEC');
      const items = weeklyEC !== null ? weeklyEC.arrayValue : null;
      if (items !== null) {
        for (let i = 0; i < items.length; i++) {
          weeks.push({
            weekStart: DrivingStats.strOf(items[i], 'weekStart'),
            weekEnd: DrivingStats.strOf(items[i], 'weekEnd'),
            hundredKmEc: DrivingStats.doubleOf(items[i], 'hundredKmEC')
          });
        }
      }
      stats.weekly = {
        rankPercent: rankResult !== null ? DrivingStats.strOf(rankResult, 'rank') : null,
        rankHundredKmEc: rankResult !== null ? DrivingStats.doubleOf(rankResult, 'hundredKmEC') : null,
        weeks: weeks
      };
    }

    return stats;
  }

  /**
   * 从 `getLastweekEC` 整份响应解析能耗构成。三块都是**字符串**，`doubleValue` 负责转。
   * 没有 `data` 就是这段区间没数据，返回 null——界面据此整卡隐藏，不填 0。
   */
  static distributionFrom(raw: JsonValue | null): EnergyDistribution | null {
    const node = raw !== null ? raw.get('data') : null;
    if (node === null) {
      return null;
    }
    return DrivingStats.distributionOf(
      DrivingStats.doubleOf(node, 'driverEC') ?? 0,
      DrivingStats.doubleOf(node, 'acEC') ?? 0,
      DrivingStats.doubleOf(node, 'otherEC') ?? 0
    );
  }

  /** 三块用量推出总量和占比，占比留一位小数——和官方饼图口径一致。 */
  static distributionOf(driverKwh: number, acKwh: number, otherKwh: number): EnergyDistribution {
    const total = driverKwh + acKwh + otherKwh;
    const pct = (part: number): number | null => total > 0 ? Math.round((part / total) * 1000) / 10 : null;
    return {
      driverKwh: driverKwh,
      acKwh: acKwh,
      otherKwh: otherKwh,
      totalKwh: Math.round(total * 10) / 10,
      driverPct: pct(driverKwh),
      acPct: pct(acKwh),
      otherPct: pct(otherKwh)
    };
  }

  private static intOf(node: JsonValue, key: string): number | null {
    const v = node.get(key);
    return v !== null ? v.intValue : null;
  }

  private static doubleOf(node: JsonValue, key: string): number | null {
    const v = node.get(key);
    return v !== null ? v.doubleValue : null;
  }

  private static strOf(node: JsonValue, key: string): string | null {
    const v = node.get(key);
    return v !== null ? v.stringValue : null;
  }
}
