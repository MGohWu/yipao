import { hilog } from '@kit.PerformanceAnalysisKit';
import { JsonValue, JsonKind } from './JsonValue';

/**
 * 标定新车型用的诊断日志。
 *
 * 存在的理由：零跑没有公开信号表，`SignalSchema` 里每一条映射都得靠真实响应反推。
 * 接入下一个车型时，把 App 装到真机跑一遍，signalMap 全量就在日志里：
 *
 *     hdc shell hilog -T leap-diag
 *
 * 脱敏：VIN 只留后 4 位，token / 手机号 / 账号 ID 一类的键整体遮蔽。
 * 车况字段原样输出——包括经纬度，判断隐私模式开没开要用到。
 */
export class DiagLog {
  private static readonly domain = 0x0001;
  private static readonly tag = 'leap-diag';

  /** 值需要整体遮蔽的键，小写包含匹配。 */
  private static readonly secretKeyFragments: string[] = [
    'token', 'password', 'oppwd', 'sign', 'phone', 'mobile',
    'accountid', 'userid', 'idcard', 'openid', 'unionid', 'email'
  ];

  static note(text: string): void {
    hilog.info(DiagLog.domain, DiagLog.tag, '%{public}s', text);
  }

  static maskVin(vin: string): string {
    if (vin.length <= 4) {
      return vin.length === 0 ? '(空)' : vin;
    }
    return '…' + vin.substring(vin.length - 4);
  }

  /** 递归遮蔽敏感值，其余结构原样保留。 */
  static redacted(value: JsonValue): JsonValue {
    if (value.kind === JsonKind.Object) {
      const dict = value.objectValue;
      const out = new Map<string, JsonValue>();
      if (dict !== null) {
        dict.forEach((child: JsonValue, key: string) => {
          const lower = key.toLowerCase();
          if (lower.includes('vin')) {
            const raw = child.stringValue;
            out.set(key, JsonValue.ofString(raw !== null ? DiagLog.maskVin(raw) : '***'));
          } else if (DiagLog.secretKeyFragments.some((f: string) => lower.includes(f))) {
            out.set(key, JsonValue.ofString('***'));
          } else {
            out.set(key, DiagLog.redacted(child));
          }
        });
      }
      return JsonValue.ofObject(out);
    }
    if (value.kind === JsonKind.Array) {
      const items = value.arrayValue ?? [];
      const out: JsonValue[] = [];
      for (let i = 0; i < items.length; i++) {
        out.push(DiagLog.redacted(items[i]));
      }
      return JsonValue.ofArray(out);
    }
    return value;
  }

  /** hilog 单条会被截断，长文本按行切块发，带序号方便拼回。 */
  static emit(tag: string, text: string, limit: number = 700): void {
    const chunks: string[] = [];
    let current = '';
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (current.length > 0 && current.length + line.length + 1 > limit) {
        chunks.push(current);
        current = '';
      }
      current += current.length === 0 ? line : '\n' + line;
    }
    if (current.length > 0) {
      chunks.push(current);
    }
    const total = Math.max(1, chunks.length);
    for (let i = 0; i < chunks.length; i++) {
      DiagLog.note(`[${tag}] ${i + 1}/${total}\n${chunks[i]}`);
    }
  }
}
