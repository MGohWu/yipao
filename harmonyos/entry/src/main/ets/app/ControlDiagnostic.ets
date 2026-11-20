import { SharedSettings } from '../core/SharedSettings';

export enum ControlOutcome {
  /** 车况确认已生效 */
  confirmed = 'confirmed',
  /** 窗口内没等到预期终态 */
  timedOut = 'timedOut',
  /** 无可观测终态，只能确认已下发 */
  sentOnly = 'sentOnly',
  /** 下发本身就失败了 */
  failed = 'failed'
}

/**
 * 一次回执采样。带时间戳是为了回答一个具体问题：
 * 实测回执里 `code`/`result` 只表示「这次查询成功了」，真正的执行状态在 `data`，
 * 而 `data` 在下发后 2/5/8 秒都是 `1`。看 `data` 什么时候变值，
 * 和车况什么时候翻转一比，就知道这个 `1` 是「执行中」还是「已成功、车况接口滞后」。
 */
export interface ReceiptSample {
  /** 距下发的秒数。 */
  at: number;
  body: string;
}

/**
 * 最近一次控车的完整经过，存起来用于排查。
 *
 * 存在的理由：回执接口 `/appremotectl/query` 的返回结构没有任何已验证样本。
 * 要把「执行中」和「车拒绝了」区分开，得先拿真车攒出几份真实响应。
 */
export interface ControlDiagnostic {
  label: string;
  cmdid: string;
  msgID: string;
  sentAt: number;
  outcome: ControlOutcome;
  /** 车况确认耗时（秒）。这是判断「窗口该设多长」的唯一实测依据。 */
  elapsed: number;
  pollCount: number;
  /** 回执采样，按时间排列。确认之后还会再采一次——那一次才可能拿到终态值。 */
  receiptResponses: ReceiptSample[];
  errorMessage: string | null;
}

/**
 * 最近一次控车经过存首选项——排查时 App 往往已经被杀过一次了。
 * 里面只有回执响应和时序，没有 token 也没有操作密码。
 */
export class ControlDiagnosticStore {
  private static readonly key = 'control.diagnostic.last';

  static save(diagnostic: ControlDiagnostic | null): void {
    if (diagnostic === null) {
      SharedSettings.remove(ControlDiagnosticStore.key);
      return;
    }
    SharedSettings.setString(ControlDiagnosticStore.key, JSON.stringify(diagnostic));
  }

  static load(): ControlDiagnostic | null {
    const text = SharedSettings.getString(ControlDiagnosticStore.key, '');
    if (text.length === 0) {
      return null;
    }
    try {
      return JSON.parse(text) as ControlDiagnostic;
    } catch (e) {
      return null;
    }
  }
}
