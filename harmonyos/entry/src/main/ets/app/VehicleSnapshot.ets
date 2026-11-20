import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { VehicleState, Coordinate } from '../core/LeapModels';
import { SharedSettings } from '../core/SharedSettings';

/** 卡片上的控车动作。 */
export enum WidgetAction {
  toggleLock = 'toggleLock',
  toggleClimate = 'toggleClimate',
  trunk = 'trunk',
  horn = 'horn',
  lock = 'lock',
  unlock = 'unlock'
}

export class WidgetButtonLayout {
  static moving(actions: WidgetAction[], from: number, to: number): WidgetAction[] {
    const next = actions.slice();
    if (from < 0 || from >= next.length || to < 0 || to >= next.length || from === to) { return next; }
    const moved = next.splice(from, 1)[0];
    next.splice(to, 0, moved);
    return next;
  }

  static readonly defaults: WidgetAction[] = [WidgetAction.toggleLock, WidgetAction.toggleClimate,
    WidgetAction.trunk, WidgetAction.horn];
  static readonly all: WidgetAction[] = [WidgetAction.toggleLock, WidgetAction.toggleClimate,
    WidgetAction.trunk, WidgetAction.horn, WidgetAction.lock, WidgetAction.unlock];

  static normalize(raw: string[], small: boolean): WidgetAction[] {
    const result: WidgetAction[] = [];
    raw.concat(WidgetButtonLayout.defaults).forEach((value: string) => {
      const action = WidgetButtonLayout.all.find((item: WidgetAction) => item === value);
      if (action !== undefined && result.indexOf(action) < 0) {
        result.push(action);
      }
    });
    return result.slice(0, small ? 2 : 4);
  }

  static title(action: string): string {
    switch (action) {
      case WidgetAction.toggleLock: return '车锁';
      case WidgetAction.toggleClimate: return '空调';
      case WidgetAction.trunk: return '尾门';
      case WidgetAction.horn: return '鸣笛寻车';
      case WidgetAction.lock: return '上锁车辆';
      case WidgetAction.unlock: return '解锁车辆';
      default: return '';
    }
  }
}

/**
 * App 与桌面卡片共享的一小份车况快照。
 *
 * 主 App 每次刷新车况后写一份；卡片刷新时也会自己拉一次车况并写回同一份，
 * 拉不到就沿用上一份，并如实标出数据有多旧。
 */
export interface VehicleSnapshot {
  vehicleName: string;
  soc: number | null;
  /** 增程车的油量百分比；纯电车为 null（卡片据此决定要不要画油量条）。 */
  gasolinePercent: number | null;
  /** 来自车辆能力码；旧快照缺失时兼容已有电油分项。 */
  isExtendRange?: boolean;
  rangeKm: number | null;
  /**
   * 增程车的纯电续航（km）。纯电车为 null——纯电车的续航就是 `rangeKm`，不重复存一份。
   * 老快照没有这个键，解出来是 undefined，取用处按 null 兜。
   */
  energyRangeKm?: number | null;
  /**
   * 增程车的燃油续航（km）。纯电车为 null。
   * 车端本来就把电和油分成两个数报，官方也不给综合续航，所以大卡上分两段显示。
   */
  fuelRangeKm?: number | null;
  isLocked: boolean | null;
  isCharging: boolean;
  chargeLimit: number | null;
  indoorTemp: number | null;
  climateOn: boolean;
  windowsClosed: boolean | null;
  anyDoorOpen: boolean;
  hasTireWarning: boolean;
  /**
   * 尾门开着没有。卡片直发尾门时靠它决定发「开」还是「关」——卡片进程没有
   * `VehicleStore` 那些草稿状态，方向只能照这份快照判。老快照没有这个键，
   * 解出来是 undefined，取用处按 null 兜。
   */
  trunkOpen?: boolean | null;
  /**
   * 车在动没有。用来挡住行驶中开尾门，和 App 里那道保护同一个判据。
   * 老快照缺这个键，兜底成 false——按"没在动"处理，退回到加这道保护之前的行为。
   */
  isDriving?: boolean;
  locationName: string | null;
  latitude: number | null;
  longitude: number | null;
  /** 本机什么时候把这份车况拉下来的。注意不是车端采集时刻，那个看 `reportedAt`。 */
  updatedAt: number;
  /**
   * 车端采集这份车况的时刻（毫秒）。读不到（某些车型不报 `collectTime`）时是 0。
   *
   * 卡片刷得再勤 `updatedAt` 都是「刚刚」；车休眠着不上报时，服务端会把同一份旧数据
   * 一直发回来，只有这个字段能看出车况到底有多旧。
   * 老快照落盘时没有这个键，解出来是 undefined，取用处一律 `?? 0` 兜住。
   */
  reportedAt: number;
}

export class SnapshotUtil {
  static hasFuel(snapshot: VehicleSnapshot): boolean {
    return snapshot.isExtendRange ?? (snapshot.gasolinePercent !== null ||
      (snapshot.energyRangeKm ?? null) !== null || (snapshot.fuelRangeKm ?? null) !== null);
  }

  /** 增程中卡只展示当前工况的电油分项，不退回可能停留在旧值的 expectedMileage。 */
  static mediumRangeText(snapshot: VehicleSnapshot): string {
    if (!SnapshotUtil.hasFuel(snapshot)) {
      return snapshot.rangeKm !== null && snapshot.rangeKm >= 0 ? `${snapshot.rangeKm} km` : '';
    }
    const parts: string[] = [];
    const energy = snapshot.energyRangeKm ?? -1;
    const fuel = snapshot.fuelRangeKm ?? -1;
    if (energy >= 0) { parts.push(`电 ${energy}`); }
    if (fuel >= 0) { parts.push(`油 ${fuel}`); }
    return parts.length > 0 ? `${parts.join(' · ')} km` : '';
  }

  static placeholder(): VehicleSnapshot {
    return {
      vehicleName: 'S01',
      soc: 76,
      gasolinePercent: null,
      rangeKm: 312,
      energyRangeKm: null,
      fuelRangeKm: null,
      isLocked: true,
      isCharging: false,
      chargeLimit: 90,
      indoorTemp: 26,
      climateOn: false,
      windowsClosed: true,
      anyDoorOpen: false,
      hasTireWarning: false,
      trunkOpen: false,
      isDriving: false,
      locationName: '杭州市滨江区',
      latitude: 30.18682,
      longitude: 120.19551,
      updatedAt: Date.now(),
      reportedAt: Date.now()
    };
  }

  /**
   * 从车况构造快照。App 和卡片两边都要写这份文件，字段映射必须是同一套，
   * 所以放在共享层而不是各写一遍。
   */
  static make(state: VehicleState, vehicleName: string, locationName: string | null,
    updatedAt: number = Date.now()): VehicleSnapshot {
    // 判据统一收在 anyWindowOpen 里：开合状态位优先、开度兜底。
    // 只看开度的那版对不报开度的车（C11 增程版）恒为 null，卡片上这一项永远是空的。
    const anyOpen = state.anyWindowOpen;
    const windowsClosed: boolean | null = anyOpen === null ? null : !anyOpen;
    const coordinate: Coordinate | null = state.shareableCoordinate;
    return {
      vehicleName: vehicleName,
      soc: state.soc,
      gasolinePercent: state.gasolinePercent,
      isExtendRange: state.hasFuel,
      rangeKm: state.expectedMileage,
      energyRangeKm: state.hasFuel ? state.energyRange : null,
      fuelRangeKm: state.hasFuel ? state.gasolineRange : null,
      isLocked: state.isLocked,
      isCharging: state.isCharging,
      chargeLimit: state.chargeLimit,
      indoorTemp: state.indoorTemp,
      climateOn: state.acOn,
      windowsClosed: windowsClosed,
      anyDoorOpen: state.anyDoorOpen,
      hasTireWarning: state.hasTireWarning,
      trunkOpen: state.trunkOpen,
      isDriving: state.isDriving,
      locationName: locationName,
      latitude: coordinate !== null ? coordinate.latitude : null,
      longitude: coordinate !== null ? coordinate.longitude : null,
      updatedAt: updatedAt,
      reportedAt: state.reportedAt ?? 0
    };
  }

  /**
   * 拿新车况刷一份已有的快照，车况里没有的东西（车名、位置）留着不动。
   *
   * 卡片进程走的就是这条路：它拉得到车况，但**反查不了地名**（那要走地图 SDK 的
   * 逆地理，卡片这边没有也不该有），照 `make` 重造一份的话位置那行会当场变空。
   */
  static merged(state: VehicleState, base: VehicleSnapshot,
    updatedAt: number = Date.now()): VehicleSnapshot {
    const anyOpen = state.anyWindowOpen;
    const coordinate: Coordinate | null = state.shareableCoordinate;
    const next: VehicleSnapshot = {
      vehicleName: base.vehicleName,
      soc: state.soc,
      gasolinePercent: state.gasolinePercent,
      isExtendRange: state.hasFuel,
      rangeKm: state.expectedMileage,
      energyRangeKm: state.hasFuel ? state.energyRange : null,
      fuelRangeKm: state.hasFuel ? state.gasolineRange : null,
      isLocked: state.isLocked,
      isCharging: state.isCharging,
      chargeLimit: state.chargeLimit,
      indoorTemp: state.indoorTemp,
      climateOn: state.acOn,
      // 车没报开合状态时保持原样，别把「读不到」写成「关着」。
      windowsClosed: anyOpen === null ? base.windowsClosed : !anyOpen,
      anyDoorOpen: state.anyDoorOpen,
      hasTireWarning: state.hasTireWarning,
      trunkOpen: state.trunkOpen,
      isDriving: state.isDriving,
      locationName: base.locationName,
      // 隐私模式下车不报坐标，这时留着上一次的位置，地图那块不至于突然空掉。
      latitude: coordinate !== null ? coordinate.latitude : base.latitude,
      longitude: coordinate !== null ? coordinate.longitude : base.longitude,
      updatedAt: updatedAt,
      reportedAt: state.reportedAt ?? 0
    };
    return next;
  }

  /**
   * 卡片按下之后立刻把结果画上去，对不对以下一次拉到的车况为准。
   *
   * 只动能当场确定的那两个开关。尾门和鸣笛不猜：尾门那个开合过程比回读那几秒长得多，
   * 车端也根本不报「刚刚响过没有」。
   */
  static optimistic(action: WidgetAction, base: VehicleSnapshot): VehicleSnapshot {
    const next: VehicleSnapshot = SnapshotUtil.copy(base);
    if (action === WidgetAction.lock || action === WidgetAction.unlock) {
      next.isLocked = action === WidgetAction.lock;
    } else if (action === WidgetAction.toggleLock) {
      next.isLocked = !(base.isLocked ?? true);
    } else if (action === WidgetAction.toggleClimate) {
      next.climateOn = !base.climateOn;
    }
    return next;
  }

  private static copy(base: VehicleSnapshot): VehicleSnapshot {
    return {
      vehicleName: base.vehicleName,
      soc: base.soc,
      gasolinePercent: base.gasolinePercent,
      isExtendRange: base.isExtendRange,
      rangeKm: base.rangeKm,
      energyRangeKm: base.energyRangeKm,
      fuelRangeKm: base.fuelRangeKm,
      isLocked: base.isLocked,
      isCharging: base.isCharging,
      chargeLimit: base.chargeLimit,
      indoorTemp: base.indoorTemp,
      climateOn: base.climateOn,
      windowsClosed: base.windowsClosed,
      anyDoorOpen: base.anyDoorOpen,
      hasTireWarning: base.hasTireWarning,
      trunkOpen: base.trunkOpen,
      isDriving: base.isDriving,
      locationName: base.locationName,
      latitude: base.latitude,
      longitude: base.longitude,
      updatedAt: base.updatedAt,
      reportedAt: base.reportedAt
    };
  }

  /** 这份车况实际有多旧。车端报了采集时刻就以它为准，读不到才退回本机拉取时间。 */
  private static moment(snapshot: VehicleSnapshot): number {
    const reported = snapshot.reportedAt ?? 0;
    return reported > 0 ? reported : snapshot.updatedAt;
  }

  /**
   * 卡片上那句「多久前」的措辞。
   *
   * 带动词，而且**车端时刻读不到时动词要改口**：那时这句话只能保证「几分钟前问过」，
   * 保证不了「车况就是那时候的」，不能拿同一种说法混过去。和首页副标题同一套口径。
   *
   * 系统的相对时间会说「2 秒钟前」这种别扭的说法，所以一分钟内直接说「刚刚」。
   */
  static freshnessText(snapshot: VehicleSnapshot): string {
    const verb = (snapshot.reportedAt ?? 0) > 0 ? '更新' : '读取';
    const elapsed = Math.max(0, Math.trunc((Date.now() - SnapshotUtil.moment(snapshot)) / 1000));
    if (elapsed < 60) {
      return `刚刚${verb}`;
    }
    if (elapsed < 3600) {
      return `${verb}于 ${Math.trunc(elapsed / 60)} 分钟前`;
    }
    if (elapsed < 86400) {
      return `${verb}于 ${Math.trunc(elapsed / 3600)} 小时前`;
    }
    return `${verb}于 ${Math.trunc(elapsed / 86400)} 天前`;
  }

  /**
   * 大卡标题行那句「几分钟前」。
   *
   * 和 `freshnessText` 同一个时刻口径，只是不带动词——那一行是「地名 · 3 分钟前」
   * 这样拼起来的，再塞「更新于」就顶到车名了。
   */
  static freshnessCompact(snapshot: VehicleSnapshot): string {
    const elapsed = Math.max(0, Math.trunc((Date.now() - SnapshotUtil.moment(snapshot)) / 1000));
    if (elapsed < 60) {
      return '刚刚';
    }
    if (elapsed < 3600) {
      return `${Math.trunc(elapsed / 60)} 分钟前`;
    }
    if (elapsed < 86400) {
      return `${Math.trunc(elapsed / 3600)} 小时前`;
    }
    return `${Math.trunc(elapsed / 86400)} 天前`;
  }

  /**
   * 超过半小时的数据不该让用户以为是实时的。
   *
   * 按车端采集时刻算：车休眠着的时候本机每次都拉得到东西，但那是同一份旧数据，
   * 按拉取时间算的话它永远不会过期。
   */
  static isStale(snapshot: VehicleSnapshot): boolean {
    return (Date.now() - SnapshotUtil.moment(snapshot)) > 1800000;
  }

  /** 卡片上只留一句最该被看到的话。 */
  static headline(snapshot: VehicleSnapshot): string {
    if (snapshot.anyDoorOpen) {
      return '有车门未关闭';
    }
    if (snapshot.hasTireWarning) {
      return '胎压异常';
    }
    if (snapshot.windowsClosed === false) {
      return '车窗未关闭';
    }
    if (snapshot.isCharging) {
      return snapshot.chargeLimit !== null ? `充电中 · 上限 ${snapshot.chargeLimit}%` : '充电中';
    }
    if (snapshot.climateOn) {
      return '空调运行中';
    }
    if (snapshot.locationName !== null && snapshot.locationName.length > 0) {
      return snapshot.locationName;
    }
    return snapshot.isLocked === false ? '已解锁' : '已锁车';
  }

  /** 需要提醒用户的状态，卡片上要用警示色。 */
  static needsAttention(snapshot: VehicleSnapshot): boolean {
    return snapshot.anyDoorOpen || snapshot.hasTireWarning
      || snapshot.isLocked === false || snapshot.windowsClosed === false;
  }
}

/**
 * 快照存在应用沙箱的 files 目录里，服务卡片（同一应用的 FormExtensionAbility）读得到。
 *
 * 这里只放非敏感的展示数据——token 和操作密码始终在关键资产里，不进这个文件。
 */
export class SnapshotStore {
  static readonly formName = 'LeapVehicleCard';
  private static filePath: string = '';

  /** 应用与卡片进程各自启动时调一次，把沙箱路径记下来。 */
  static init(context: common.Context): void {
    SnapshotStore.filePath = `${context.filesDir}/vehicle-snapshot.json`;
  }

  static read(): VehicleSnapshot | null {
    if (SnapshotStore.filePath.length === 0) {
      return null;
    }
    try {
      const file = fileIo.openSync(SnapshotStore.filePath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      const read = fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer, 0, read));
      return JSON.parse(text) as VehicleSnapshot;
    } catch (e) {
      return null;
    }
  }

  static write(snapshot: VehicleSnapshot): void {
    if (SnapshotStore.filePath.length === 0) {
      return;
    }
    try {
      const file = fileIo.openSync(SnapshotStore.filePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(snapshot));
      fileIo.closeSync(file);
    } catch (e) {
      console.error(`[snapshot] 写入失败：${(e as Error).message}`);
    }
  }

  static clear(): void {
    if (SnapshotStore.filePath.length === 0) {
      return;
    }
    try {
      fileIo.unlinkSync(SnapshotStore.filePath);
    } catch (e) {
      // 本来就不存在，忽略。
    }
  }
}

/** App 与卡片共享的偏好。 */
export class WidgetSettings {
  static buttons(small: boolean): WidgetAction[] {
    return WidgetButtonLayout.normalize(
      SharedSettings.getString(small ? 'smallWidgetButtons' : 'widgetButtons', '').split(','), small);
  }

  static setButtons(small: boolean, actions: WidgetAction[]): void {
    SharedSettings.setString(small ? 'smallWidgetButtons' : 'widgetButtons',
      WidgetButtonLayout.normalize(actions, small).join(','));
  }

  private static readonly widgetControlKey = 'widgetControlEnabled';
  private static readonly pendingActionKey = 'pendingWidgetAction';
  private static readonly pendingActionAtKey = 'pendingWidgetActionAt';
  private static readonly hasPasswordKey = 'hasSavedOperationPassword';
  private static readonly lastControlErrorKey = 'lastWidgetControlError';
  private static readonly lastControlErrorAtKey = 'lastWidgetControlErrorAt';
  /** 失败原因在卡片上顶多停留这么久（毫秒）。 */
  private static readonly controlErrorWindowMs = 300000;
  /**
   * 按下之后到 App 接手之间，这条动作还算不算数（毫秒）。
   *
   * 卡片按钮、桌面快捷方式和 App 之间隔着一次冷启动，用户按下和 App 真正跑起来之间
   * 可以隔很久：按完就锁屏、几小时后才想起来打开 App，那时车门自己开一下不是他要的。
   * 一分钟足够覆盖「按下 → App 起来 → 验证」这条正常路径。和 iOS 同一个时限。
   */
  private static readonly pendingActionWindowMs = 60000;

  /**
   * 桌面卡片是否允许直接下发控车指令。
   *
   * 关闭时（默认），卡片按钮只是打开 App，由 App 走生物识别 + 操作密码的完整流程。
   * 打开后卡片会用本机已保存的操作密码直接下发——卡片进程弹不出身份认证界面，
   * 所以这等于把「控车」的门槛降到「手机已解锁」。这是个真实的安全折衷，必须用户自己选。
   */
  static get controlEnabled(): boolean {
    return SharedSettings.getBool(WidgetSettings.widgetControlKey, false);
  }

  static set controlEnabled(value: boolean) {
    SharedSettings.setBool(WidgetSettings.widgetControlKey, value);
  }

  /**
   * 本机存过操作密码没有。
   *
   * 卡片渲染时要据此决定按钮是直发还是打开 App，而**卡片进程不该去读钥匙串**：
   * 关键资产是异步接口，卡片要当场返回绑定数据等不了；何况读一次就是一次解密。
   * 这个标记本身不敏感（只说"存过"，密码始终留在关键资产里），放共享设置正合适。
   * 真正下发时才去读密码，那时读不到就在卡片上写明原因，不会静默。
   */
  static get hasSavedPassword(): boolean {
    return SharedSettings.getBool(WidgetSettings.hasPasswordKey, false);
  }

  static set hasSavedPassword(value: boolean) {
    SharedSettings.setBool(WidgetSettings.hasPasswordKey, value);
  }

  /**
   * 卡片进程这一侧到底能不能自己把指令发出去。
   *
   * 两个条件缺一不可：用户开了「卡片直接控车」，且本机确实存过
   * 操作密码。开着开关却没存密码是会出现的（换了手机、点过「忘记已保存的操作密码」），
   * 这时按钮必须退回打开 App 那条路，而不是发一条注定被拒的请求。
   */
  static get canDispatchDirectly(): boolean {
    return WidgetSettings.controlEnabled && WidgetSettings.hasSavedPassword;
  }

  /**
   * 记一条直发失败的原因；传空串表示这次成功了，把上一条抹掉。
   *
   * 卡片进程没有别的出口能告诉用户「刚才那下没成」——弹不了 toast，也没法把 App
   * 顶到前台。所以失败就在这里留一句话，跟着下一次 `updateForm` 显示在卡片上，
   * 用户抬眼就能看见，而不是对着一张毫无变化的卡片发呆。
   */
  static recordControlError(text: string): void {
    if (text.length === 0) {
      SharedSettings.remove(WidgetSettings.lastControlErrorKey);
      SharedSettings.remove(WidgetSettings.lastControlErrorAtKey);
      return;
    }
    SharedSettings.setString(WidgetSettings.lastControlErrorKey, text);
    SharedSettings.setInt(WidgetSettings.lastControlErrorAtKey, Date.now());
  }

  /**
   * 还该被顶在卡片上的失败原因，没有就是空串。
   *
   * 过了 `controlErrorWindowMs` 就不再显示：一条五分钟前的失败还占着卡片上那行字，
   * 只会把真正的车况挤掉。和 iOS 同一个时限。
   */
  static get recentControlError(): string {
    const text = SharedSettings.getString(WidgetSettings.lastControlErrorKey, '');
    if (text.length === 0) {
      return '';
    }
    const at = SharedSettings.getInt(WidgetSettings.lastControlErrorAtKey, 0);
    return (Date.now() - at) < WidgetSettings.controlErrorWindowMs ? text : '';
  }

  /**
   * 卡片按钮或桌面快捷方式按下、需要回 App 验证的动作。**过了时效就当没按过。**
   *
   * 读的时候顺手把过期值抹掉：留着的话，下次谁再读一遍还得再判一次，
   * 而这个键是跨进程的（卡片进程也写），多留一会儿就多一分被读到旧值的机会。
   */
  static get pendingAction(): string {
    const raw = SharedSettings.getString(WidgetSettings.pendingActionKey, '');
    if (raw.length === 0) {
      return '';
    }
    const at = SharedSettings.getInt(WidgetSettings.pendingActionAtKey, 0);
    if (at <= 0 || (Date.now() - at) >= WidgetSettings.pendingActionWindowMs) {
      WidgetSettings.discardPendingAction();
      return '';
    }
    return raw;
  }

  static set pendingAction(value: string) {
    if (value.length === 0) {
      WidgetSettings.discardPendingAction();
    } else {
      SharedSettings.setString(WidgetSettings.pendingActionKey, value);
      SharedSettings.setInt(WidgetSettings.pendingActionAtKey, Date.now());
    }
  }

  /**
   * 动作和它的时间戳一起抹掉。**两个键必须一起清**：只清动作留下时间戳，
   * 下一条动作要是写失败了，读到的会是一个配着旧时间戳的空值。
   */
  private static discardPendingAction(): void {
    SharedSettings.remove(WidgetSettings.pendingActionKey);
    SharedSettings.remove(WidgetSettings.pendingActionAtKey);
  }
}

/**
 * 卡片进程这一侧根本发不出去时的说法。文案会原样显示在卡片上，
 * 所以要写成给车主看的话，和 iOS 的 `WidgetControlUnavailable` 一一对应。
 */
export class WidgetControlUnavailable {
  /** 开关开着，但本机这会儿拿不到操作密码（换过手机、点过「忘记已保存的操作密码」）。 */
  static readonly noOperationPassword = '本机没存操作密码，打开 App 控车';
  static readonly trunkWhileDriving = '行驶中不能操作尾门';
  /** 会话不在（退登了、被挤下线），卡片这边没法重新登录。 */
  static readonly notLoggedIn = '登录已失效，打开 App 重新登录';
}
