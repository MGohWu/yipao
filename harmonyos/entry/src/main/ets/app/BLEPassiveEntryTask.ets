import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { DiagLog } from '../core/DiagLog';
import { LeapError } from '../core/LeapError';

/**
 * 「无感解锁」的长时任务。
 *
 * iOS 那边不需要这一层：CoreBluetooth 的状态恢复会在系统回收进程之后把 App 拉起来，
 * 蓝牙连接自己就活着。鸿蒙没有这套恢复机制——进程一被回收，GATT 连接就断了，
 * 人走到车边也不会有任何反应。要让「无感」真的无感，只能申请
 * `BLUETOOTH_INTERACTION` 长时任务把进程留住。
 *
 * 代价是一条撤不掉的常驻通知，所以这件事必须由用户自己决定：蓝牙钥匙页里那个
 * 「无感解锁」开关默认是关的，只有打开它才会走到这里。关掉、解绑、退出登录都要
 * 立刻停掉——留着一条通知却不干活是最糟的一种。
 */
export class BLEPassiveEntryTask {
  private static context: common.UIAbilityContext | null = null;
  private static running: boolean = false;

  /** 在 `EntryAbility.onCreate` 里挂上。拿不到 context 就发不起长时任务。 */
  static init(context: common.UIAbilityContext): void {
    BLEPassiveEntryTask.context = context;
  }

  static get isRunning(): boolean {
    return BLEPassiveEntryTask.running;
  }

  /**
   * 起长时任务。已经在跑就直接返回，重复申请系统会报 9800005。
   *
   * 失败不抛出去：无感解锁起不来只影响「靠近自动开锁」，手动的蓝牙控车照旧能用，
   * 为它把上层的设置流程打断不值当。失败原因进诊断日志。
   */
  static async start(): Promise<boolean> {
    if (BLEPassiveEntryTask.running) {
      return true;
    }
    const context = BLEPassiveEntryTask.context;
    if (context === null) {
      DiagLog.note('[ble:task] 还没拿到 context，长时任务起不来');
      return false;
    }
    try {
      // 点常驻通知回到 App 本身。不带 leapRoute：这条通知是「无感解锁正开着」的
      // 状态指示，用户点它多半只是想看一眼 App，不该把他弹到某个具体页面上。
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION, agent);
      BLEPassiveEntryTask.running = true;
      DiagLog.note('[ble:task] 无感解锁长时任务已启动');
      return true;
    } catch (e) {
      DiagLog.note(`[ble:task] 长时任务启动失败：${LeapError.messageOf(e as object)}`);
      return false;
    }
  }

  /** 停掉长时任务。没在跑也照样调一次系统接口兜底：进程重启后本机标记会丢。 */
  static async stop(): Promise<void> {
    const context = BLEPassiveEntryTask.context;
    if (context === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      DiagLog.note('[ble:task] 无感解锁长时任务已停止');
    } catch (e) {
      // 本来就没在跑时系统会报错，这一条不值得记成故障。
      DiagLog.note(`[ble:task] 停止长时任务：${LeapError.messageOf(e as object)}`);
    }
    BLEPassiveEntryTask.running = false;
  }
}
