export class WindowPosition {
  /** 值是开度百分比：0 关闭、100 全开。各车型的原始刻度已经在 WindowScale 里换算过了。 */
  static describe(value: number): string {
    if (value <= 0) {
      return '已关';
    }
    if (value >= 100) {
      return '全开';
    }
    return `开 ${value}%`;
  }
}
