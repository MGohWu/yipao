import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SharedSettings } from '../core/SharedSettings';
import { CrossProcessLock } from '../core/CrossProcessLock';
import { CarModelAssets } from '../core/CarModelAssets';
import { CarSnapshot } from '../app/CarSnapshot';
import { SnapshotStore, WidgetSettings } from '../app/VehicleSnapshot';
import { FormPusher } from '../app/FormPusher';
import { BLEPassiveEntryTask } from '../app/BLEPassiveEntryTask';
import { BLEPermission } from '../app/BLEPermission';
import { UserLocationProvider } from '../app/UserLocationProvider';
import { vehicleStore } from '../app/VehicleStore';
import { SafeAreaInsets } from '../app/SafeAreaInsets';
import { Appearance } from '../app/Appearance';
import { DiagLog } from '../core/DiagLog';
import { LeapError } from '../core/LeapError';

const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'onCreate');
    // 三处本地存储都要先拿到 context。首选项是同步读的（界面要立刻拿到值），
    // 所以必须在页面起来之前初始化完，不然首帧读到的全是默认值。
    SharedSettings.init(this.context);
    // 深浅外观要在页面起来之前挂上，否则首帧会先用系统配色闪一下再切过来。
    Appearance.attach(this.context);
    SnapshotStore.init(this.context);
    // 续期用的跨进程锁也要先拿到沙箱路径，否则拿不到锁、退回并发续期。
    CrossProcessLock.init(this.context);
    CarModelAssets.init(this.context);
    CarSnapshot.init(this.context);
    FormPusher.init(this.context);
    // 无感解锁的长时任务要拿 UIAbility 的 context 才发得起来。
    BLEPassiveEntryTask.init(this.context);
    // 申请蓝牙权限也要 UIAbility 的 context；真正弹窗要等用户去绑车。
    BLEPermission.init(this.context);
    // 定位同理，弹窗要等用户进车辆位置页。
    UserLocationProvider.init(this.context);
    this.handleDeepLink(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleDeepLink(want);
  }

  /** 服务卡片点进来时带的目标页面和待执行动作。 */
  private handleDeepLink(want: Want): void {
    const params = want.parameters;
    if (params === undefined) {
      return;
    }
    const target = params.leapRoute;
    if (typeof target === 'string' && target.length > 0) {
      vehicleStore.pendingDeepLink = target;
    }
    // 卡片上的车锁/空调/尾门/鸣笛。卡片进程弹不出身份认证界面，所以那边只把
    // App 拉起来并把动作捎过来，真正下发在这边走完整的生物识别 + 操作密码流程。
    // 寄存而不是当场执行：冷启动时这会儿会话还没恢复，控车会因为没登录直接失败。
    const action = params.leapAction;
    if (typeof action === 'string' && action.length > 0) {
      WidgetSettings.pendingAction = action;
      // 卡片上的动作是对着车发的，落地就该在车辆页——补一条深链把页签切过去，
      // 指令本身照旧由 store 择机下发。
      if (vehicleStore.pendingDeepLink.length === 0) {
        vehicleStore.pendingDeepLink = 'vehicle';
      }
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, `loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      // 沉浸式：内容延伸到状态栏与导航条之下，由页面自行处理安全区
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);
      SafeAreaInsets.attach(mainWindow);
    });
  }

  onForeground(): void {
    // 先把共享设置重读一遍：寄存的动作可能是卡片进程写下的（直发时发现本机没存密码），
    // 而首选项的缓存是本进程启动时读的一份，看不见别的进程后来写进去的东西。
    SharedSettings.reload();
    this.resumeForeground().catch((e: Object) => {
      DiagLog.note(`[app] 回前台处理出错：${LeapError.messageOf(e as object)}`);
    });
    // 蓝牙钥匙的直进直出只在前台可用，配对搜索同理。
    vehicleStore.setApplicationActive(true);
  }

  /**
   * 回前台这一趟要按顺序走完：探登录态 → 拉车况 → 接手寄存的动作 → 开轮询。
   *
   * **顺序是这里唯一要紧的事。** 卡片按钮和桌面快捷方式都只是把动作捎进来，
   * 真正下发在 `consumePendingWidgetAction`，而车锁、尾门、空调这三个动作
   * 都是**照手上这份车况取反**的。退到后台就停了轮询，`state` 冻在退后台那一刻——
   * 中午锁好车、晚上长按图标点「开关车锁」，取反读到的还是中午那份「已锁」，
   * 发出去的会是解锁。所以必须先把车况拉准，再让动作落地。
   *
   * 原来这两件事是并排发的：`refresh()` 在 `then` 里，`consumePendingWidgetAction()`
   * 在外面同步调——后者一定跑在前者前面。
   *
   * 轮询挪到最后开：`refresh()` 撞上正在飞的请求会直接返回（只记个待办），
   * 先开轮询就等于给自己制造这个撞车。
   */
  private async resumeForeground(): Promise<void> {
    // 被挤下线只有主动探控车 token 才发现（节流 30 秒）。
    // 失效则 validateSession 已把人送回登录页，寄存的动作原样留着等下次登录。
    if (!(await vehicleStore.validateSession())) {
      return;
    }
    await vehicleStore.refresh();
    // App 本来就在后台时，卡片和快捷方式点进来只走 onNewWant，不经过 bootstrap，
    // 寄存的动作得在这里接手。冷启动时这会儿还没登录，它会原样留着等 bootstrap。
    await vehicleStore.consumePendingWidgetAction();
    vehicleStore.startPolling();
  }

  onBackground(): void {
    // 退到后台就停轮询，并作废这一次前台的身份验证——
    // 手机换手之后不该还能直接控车。
    vehicleStore.stopPolling();
    vehicleStore.endForegroundVerification();
    // 退到后台立刻急停挪车：手指离开屏幕而车还在动，是这套功能唯一会伤人的失败模式。
    vehicleStore.setApplicationActive(false);
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy');
  }
}
