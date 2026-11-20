import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { DiagLog } from './DiagLog';

/**
 * 一次成功的持锁。释放靠 `release()`，重复调用无害。
 *
 * 释放要放开两样东西：真正的文件锁，和 `CrossProcessLock` 里那道进程内排队。
 */
export class LockHolding {
  private file: fileIo.File | null;
  private readonly leaveQueue: () => void;
  private released: boolean = false;

  constructor(file: fileIo.File, leaveQueue: () => void) {
    this.file = file;
    this.leaveQueue = leaveQueue;
  }

  release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    const file = this.file;
    this.file = null;
    if (file !== null) {
      try {
        file.unlock();
      } catch (e) {
        // 进程退出时内核会兜底释放，这里失败不值得让调用方感知。
      }
      try {
        fileIo.closeSync(file);
      } catch (e) {
      }
    }
    this.leaveQueue();
  }
}

/**
 * 主应用与卡片进程之间的互斥锁。对应 iOS 的 `CrossProcessLock`。
 *
 * 为什么需要它：refreshToken 每换发一次，旧的立刻作废。两个进程各自续期时，
 * 后到服务端的那个必然拿着已作废的 refreshToken 被拒——再被判成「登录态失效」，
 * 把另一个进程刚换来的有效凭证连同整个会话一起清掉。
 * `authRevision` 只挡得住「已经写回」的换发，两边**正在进行中**的那个窗口只有锁能关上。
 *
 * 和 iOS 不同，这里用的是真文件锁（`fileIo.tryLock`，底层 flock），不是租约文件。
 * iOS 那边绕开 flock 是因为进程挂起时只要还占着 App Group 里的文件锁就会被
 * `0xdead10cc` 必杀；鸿蒙没有这条规矩，而真锁在持有者进程猝死时由内核自动释放，
 * 比"到期时间 + 谁来清"那一套少一整类边界情况。
 *
 * 锁文件放在应用沙箱 files 目录——同一应用的 UIAbility 和 FormExtensionAbility 共用沙箱。
 *
 * 拿不到锁（等满超时）返回 null，调用方降级为**不加锁继续**：最坏退回没有锁的现状，
 * 绝不因为拿不到锁就把续期堵死——那会直接表现成控不了车。
 */
export class CrossProcessLock {
  private static baseDir: string = '';
  /**
   * 进程内的排队。
   *
   * flock 是按 fd 算的，同一个进程开两个 fd 去锁同一个文件照样互斥——
   * 老链路续期和新网关续期在本进程里是两个独立的 Promise，真撞上就会
   * 互相等到超时、然后双双降级成不加锁，正好是这把锁要挡的那件事。
   * 所以进程内先排一次队，跨进程那层才交给 flock。
   */
  private static queues = new Map<string, Promise<void>>();
  /**
   * 排队的兜底时限（毫秒）：持有者忘了 `release()`（或中途抛了个没人接的异常）时，
   * 后面的人最多堵这么久。没有这道兜底，一次疏漏就会让本进程再也拿不到这把锁。
   */
  private static readonly queueMaxHoldMs = 60000;

  private readonly name: string;

  constructor(name: string) {
    this.name = name;
  }

  /** 主应用与卡片进程各自启动时调一次，把沙箱路径记下来。 */
  static init(context: common.Context): void {
    CrossProcessLock.baseDir = context.filesDir;
  }

  /**
   * 拿到锁为止，最多等 `timeoutMs`。拿不到（或路径还没初始化）返回 null。
   *
   * `timeoutMs` 要长过一次续期的最坏耗时（请求超时 + 关键资产写回），
   * 否则等锁的人会在对方还没跑完时就放弃、降级成并发续期。
   */
  async acquire(timeoutMs: number = 25000, pollMs: number = 100): Promise<LockHolding | null> {
    if (CrossProcessLock.baseDir.length === 0) {
      return null;
    }
    // 先在进程内排队：前一个持有者释放之前，这里不去碰文件锁。
    const previous = CrossProcessLock.queues.get(this.name) ?? Promise.resolve();
    let leaveQueue: () => void = () => {
    };
    const mine = new Promise<void>((resolve: () => void) => {
      leaveQueue = resolve;
    });
    CrossProcessLock.queues.set(this.name,
      previous.then(() => Promise.race([mine, CrossProcessLock.sleep(CrossProcessLock.queueMaxHoldMs)])));
    await previous;

    const path = `${CrossProcessLock.baseDir}/${this.name}`;
    const deadline = Date.now() + timeoutMs;
    while (true) {
      let file: fileIo.File | null = null;
      try {
        file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        file.tryLock(true);
        return new LockHolding(file, leaveQueue);
      } catch (e) {
        // 锁被别的进程占着（或文件刚被谁删了），关掉这次的 fd 再等下一轮。
        if (file !== null) {
          try {
            fileIo.closeSync(file);
          } catch (closeError) {
          }
        }
      }
      if (Date.now() >= deadline) {
        DiagLog.note(`[lock] ${this.name} 等锁超时，本次不加锁继续`);
        leaveQueue();
        return null;
      }
      await CrossProcessLock.sleep(pollMs);
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise((resolve: () => void) => setTimeout(resolve, ms));
  }
}
