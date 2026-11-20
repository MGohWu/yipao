import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { SharedSettings } from '../core/SharedSettings';
import { CrossProcessLock } from '../core/CrossProcessLock';
import { DiagLog } from '../core/DiagLog';
import { LeapClient } from '../core/LeapClient';
import { LeapError } from '../core/LeapError';
import { ClimateMode, LeapCommand, SessionUtil, VehicleState } from '../core/LeapModels';
import { OperationPasswordStore } from '../core/SecureStore';
import {
  SnapshotStore, SnapshotUtil, VehicleSnapshot, WidgetAction, WidgetControlUnavailable, WidgetSettings
} from '../app/VehicleSnapshot';
import { FormPusher } from '../app/FormPusher';
import { CarSnapshot } from '../app/CarSnapshot';

/**
 * 服务卡片的提供方。
 *
 * 卡片进程和主应用进程各自独立，内存里的东西互相看不到，所以：
 * - 卡片 id 名单存一个双方现读现写的小文件，主应用靠它逐个 `updateForm`（见 FormPusher）
 * - 卡片要显示的车况来自共享的快照文件
 *
 * 这个进程会联网，两件事上都要联：
 * - `onUpdateForm`：系统定时唤起时自己拉一次车况。不拉的话，App 不在前台期间卡片上的
 *   车况是整个冻住的——推过来的永远是主应用最后一次轮询留下的那份。
 * - `onFormEvent`：用户开了「卡片直接控车」时，指令就在这里发出去，App 全程不露面。
 *
 * 唤起后能活多久没有承诺，所以这里的网络活儿一律**抢时间**：不长等、不重试，
 * 拿不到就维持上一份快照，绝不清空。
 *
 * 会话是两个进程共用的一份（关键资产里）。续期会互相踩，所以凭证的读写全部走
 * `LeapClient` 里那套 `authRevision` 仲裁 + 跨进程锁，这边只管调。
 */
export default class LeapFormAbility extends FormExtensionAbility {
  /** 下发之后等这么久再回读车况。指令是异步执行的，立刻读回来的还是动作之前的状态。 */
  private static readonly readBackDelayMs = 3000;
  /** 刷新键带过来的动作名。它不是控车指令，所以不在 `WidgetAction` 里。 */
  private static readonly refreshAction = 'refresh';

  /** 每次回调都要重新初始化：扩展进程可能是刚被拉起来的，静态状态是空的。 */
  private prepare(): void {
    SharedSettings.init(this.context);
    // 进程活过一轮的话，缓存还停在上次拉起时的值——用户刚在 App 里打开「卡片直接控车」、
    // 刚存了操作密码，这边看不见，按钮会照着老值走。每次回调都重读一遍，这是磁盘上的
    // 一个小文件，代价可以忽略。
    SharedSettings.reload();
    SnapshotStore.init(this.context);
    CarSnapshot.init(this.context);
    FormPusher.init(this.context);
    CrossProcessLock.init(this.context);
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    this.prepare();
    const params = want.parameters;
    const formId = params !== undefined
      ? params[formInfo.FormParam.IDENTITY_KEY] as string : '';
    if (formId !== undefined && formId.length > 0) {
      FormPusher.registerForm(formId);
    }
    return FormPusher.currentBinding();
  }

  onUpdateForm(formId: string): void {
    this.prepare();
    // 先把手上这份推出去：网拉不拉得到都不该让卡片空着，而且这一下是立刻的。
    FormPusher.push(formId);
    // 再抢着拉一次新的。拉到就再推一遍，拉不到就维持刚才那份旧的。
    this.refreshFromNetwork().then((updated: boolean) => {
      if (updated) {
        FormPusher.push(formId);
      }
    }).catch((e: Object) => {
      DiagLog.note(`[card] 定时刷新出错：${LeapError.messageOf(e as object)}`);
    });
  }

  onRemoveForm(formId: string): void {
    this.prepare();
    FormPusher.unregisterForm(formId);
  }

  onCastToNormalForm(formId: string): void {
    // 临时卡片转为常驻卡片。名单在 onAddForm 时就登记过了，这里不用再做事。
  }

  /**
   * 卡片上的按钮按下来了。
   *
   * 只有「卡片直接控车」开着时按钮才走这条路（`ActionTile` 按推过去的 `directControl`
   * 分流），否则按钮是把 App 拉起来，压根不到这里。
   */
  onFormEvent(formId: string, message: string): void {
    this.prepare();
    // 刷新只是重新拉一次车况，不下发任何指令：不问操作密码，
    // 也不走乐观更新。任何人任何时候按都成立。
    if (LeapFormAbility.rawAction(message) === LeapFormAbility.refreshAction) {
      this.refreshFromNetwork().then((updated: boolean) => {
        // 拉不到也要推一次：那句「几分钟前」会往上走，用户至少知道这一下按到了。
        FormPusher.push(formId);
      }).catch((e: Object) => {
        DiagLog.note(`[card] 手动刷新出错：${LeapError.messageOf(e as object)}`);
        FormPusher.push(formId);
      });
      return;
    }
    const action = LeapFormAbility.parseAction(message);
    if (action === null) {
      DiagLog.note(`[card] 收到无法识别的卡片事件：${message}`);
      return;
    }
    this.dispatch(action, formId).catch((e: Object) => {
      DiagLog.note(`[card] 直发出错：${LeapError.messageOf(e as object)}`);
    });
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  // MARK: - 直接下发

  /**
   * 卡片带过来的动作。框架把 `postCardAction` 的 params 序列化成 JSON 字符串交过来。
   * 认不出来就返回 null——这条路上的任何猜测都会变成一条替用户发出去的控车指令。
   */
  private static parseAction(message: string): WidgetAction | null {
    const raw = LeapFormAbility.rawAction(message);
    switch (raw) {
      case WidgetAction.toggleLock:
        return WidgetAction.toggleLock;
      case WidgetAction.lock:
        return WidgetAction.lock;
      case WidgetAction.unlock:
        return WidgetAction.unlock;
      case WidgetAction.toggleClimate:
        return WidgetAction.toggleClimate;
      case WidgetAction.trunk:
        return WidgetAction.trunk;
      case WidgetAction.horn:
        return WidgetAction.horn;
      default:
        return null;
    }
  }

  /** 把 `postCardAction` 那串 JSON 里的动作名取出来。取不出来返回空串。 */
  private static rawAction(message: string): string {
    try {
      const parsed = JSON.parse(message) as Record<string, Object>;
      const value = parsed.leapAction;
      return typeof value === 'string' ? value : '';
    } catch (e) {
      return '';
    }
  }

  /**
   * 走完一次直发：能发就发，发不了就在卡片上留一句原因。
   *
   * 卡片进程没有别的出口能告诉用户「刚才那下没成」——弹不了 toast，也没办法把 App
   * 顶到前台。所以每条失败都记进 `WidgetSettings` 并立刻重推一次卡片。
   */
  private async dispatch(action: WidgetAction, formId: string): Promise<void> {
    try {
      await this.perform(action, formId);
      WidgetSettings.recordControlError('');
    } catch (e) {
      const message = LeapError.messageOf(e as object);
      DiagLog.note(`[card] ${action} 直发失败：${message}`);
      WidgetSettings.recordControlError(message);
    }
    FormPusher.push(formId);
  }

  private async perform(action: WidgetAction, formId: string): Promise<void> {
    const before = SnapshotStore.read();
    // 车在动的时候不碰尾门，和 App 里那道保护同一个判据。
    if (action === WidgetAction.trunk && before !== null && before.isDriving === true) {
      throw new Error(WidgetControlUnavailable.trunkWhileDriving);
    }

    const password = WidgetSettings.canDispatchDirectly
      ? await new OperationPasswordStore().read() : null;
    if (password === null || password.length === 0) {
      // 渲染之后条件又没了（比如刚点过「忘记已保存的操作密码」）。动作先留给 App——
      // 下次打开 App 时 `consumePendingWidgetAction` 会接手；但不能只做这一步就返回，
      // 卡片进程顶不动 App，用户看到的会是「按了没反应」。所以还要抛出去写到卡片上。
      WidgetSettings.pendingAction = action as string;
      throw new Error(WidgetControlUnavailable.noOperationPassword);
    }

    const client = new LeapClient();
    await client.restore();
    if (!SessionUtil.isLoggedIn(client.session)) {
      throw new Error(WidgetControlUnavailable.notLoggedIn);
    }

    // 先把卡片切到「已经这样了」，按下去立刻有反馈，不用干等服务端。
    // 对不对以下面回读到的车况为准。
    if (before !== null) {
      SnapshotStore.write(SnapshotUtil.optimistic(action, before));
      FormPusher.push(formId);
    }

    await client.sendControl(LeapFormAbility.command(action, before), password);

    // 指令是异步执行的，等一下再拉车况，拿到的才是动作之后的状态。
    await LeapFormAbility.sleep(LeapFormAbility.readBackDelayMs);
    await this.readBack(client);
  }

  /**
   * 卡片上的按钮没有「我要它变成锁着」这种意图，只能照快照取反。
   *
   * 尾门固定发「打开」：能远程关的只有 C11 那套口径的车型，而卡片这边拿不到车型
   *（快照里没有，也不该为了这个再联网问一次）。发一条车不认的关闭指令，用户看到的
   * 是「指令已发出、车没反应」，比只给开更糟。和 iOS 卡片同一个取舍。
   */
  private static command(action: WidgetAction, snapshot: VehicleSnapshot | null): LeapCommand {
    switch (action) {
      case WidgetAction.lock:
        return LeapCommand.lock();
      case WidgetAction.unlock:
        return LeapCommand.unlock();
      case WidgetAction.toggleLock:
        // 读不到锁状态时按「锁着」算，于是这一下是解锁——和车锁图标画的方向一致。
        return (snapshot !== null && snapshot.isLocked === false)
          ? LeapCommand.lock() : LeapCommand.unlock();
      case WidgetAction.toggleClimate: {
        const on = !(snapshot !== null && snapshot.climateOn);
        // 卡片上没有温度和风量可选，用一组不会让人不舒服的固定值，和 iOS 一致。
        return LeapCommand.climate(on, 24, 3, ClimateMode.cold, true, false);
      }
      case WidgetAction.trunk:
        return LeapCommand.trunk(true);
      default:
        return LeapCommand.horn();
    }
  }

  /** 下发之后回读一次车况写回快照。拉不到就算了，乐观更新那份留着。 */
  private async readBack(client: LeapClient): Promise<void> {
    try {
      const state: VehicleState = await client.fetchVehicleState();
      const base = SnapshotStore.read();
      if (base !== null) {
        SnapshotStore.write(SnapshotUtil.merged(state, base));
      }
    } catch (e) {
      DiagLog.note(`[card] 回读车况失败：${LeapError.messageOf(e as object)}`);
    }
  }

  // MARK: - 定时刷新

  /**
   * 自己联网拉一次车况写回快照。拉到了返回 true。
   *
   * 没有快照时直接放弃：车名和位置只有主应用那边配得齐，卡片这边硬造一份出来，
   * 车名会是空的、位置会是空的——不如让卡片继续显示「打开 App 看看」的占位。
   */
  private async refreshFromNetwork(): Promise<boolean> {
    const base = SnapshotStore.read();
    if (base === null) {
      return false;
    }
    const client = new LeapClient();
    await client.restore();
    if (!SessionUtil.isLoggedIn(client.session)) {
      return false;
    }
    try {
      const state: VehicleState = await client.fetchVehicleState();
      SnapshotStore.write(SnapshotUtil.merged(state, base));
      return true;
    } catch (e) {
      // 拉不到就维持上一份，卡片上那句「更新于几分钟前」会如实说出它有多旧。
      DiagLog.note(`[card] 拉车况失败：${LeapError.messageOf(e as object)}`);
      return false;
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise((resolve: () => void) => setTimeout(resolve, ms));
  }
}
