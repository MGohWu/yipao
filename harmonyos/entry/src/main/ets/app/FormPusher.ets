import { formProvider } from '@kit.FormKit';
import { formBindingData } from '@kit.FormKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { DiagLog } from '../core/DiagLog';
import { SnapshotStore, SnapshotUtil, VehicleSnapshot, WidgetSettings } from './VehicleSnapshot';
import { CarSnapshot } from './CarSnapshot';

/**
 * 卡片数据。字段名和卡片页里的 `@LocalStorageProp` 键一一对应。
 *
 * `formImages` 是 Form Kit 的固定字段名，不能缺省也不能改名：
 * 值是「key → 已打开文件的 fd」，卡片侧用同名 key 当 `Image` 的入参。
 * 4×4 卡片上那张车图就是这么过去的——卡片进程读不到应用沙箱，图只能这么递。
 */
class CardData {
  vehicleName: string = '';
  soc: number = -1;
  /** 增程车油量百分比；纯电车推 -1，卡片据此不画油量条。 */
  gasolinePercent: number = -1;
  rangeKm: number = -1;
  hasFuel: boolean = false;
  mediumRangeText: string = '';
  /** 增程车的纯电续航；读不到或纯电车推 -1，卡片据此不摆那个数。 */
  energyRangeKm: number = -1;
  /** 增程车的燃油续航；同上。 */
  fuelRangeKm: number = -1;
  isLocked: string = '';
  isCharging: boolean = false;
  chargeLimit: number = -1;
  indoorTemp: number = -1000;
  climateOn: boolean = false;
  windowsClosed: string = '';
  anyDoorOpen: boolean = false;
  trunkOpen: boolean = false;
  hasTireWarning: boolean = false;
  headline: string = '';
  freshness: string = '';
  /** 大卡标题行用的「几分钟前」，不带动词。 */
  freshnessCompact: string = '';
  needsAttention: boolean = false;
  isStale: boolean = false;
  /**
   * 卡片上的按钮这一刻是「按下即发」还是「打开 App」。
   * 由这一侧算好推过去，卡片渲染时不用（也没法）自己去问设置和钥匙串。
   */
  directControl: boolean = false;
  /** 上一次直发失败的原因，空串表示没有。卡片直接显示这句话。 */
  controlError: string = '';
  widgetButtons: string[] = WidgetSettings.buttons(false);
  smallWidgetButtons: string[] = WidgetSettings.buttons(true);
  lockText: string = '状态未知';
  carImage: string = '';
  formImages: Record<string, number> = {};
}

/**
 * 把最新快照推给桌面上所有已添加的卡片。
 *
 * 鸿蒙的卡片没有 iOS「重载时间线」那种整体刷新入口，得按 formId 逐个 `updateForm`。
 * 卡片被添加/删除时由 LeapFormAbility 维护这份 id 名单（存共享首选项，
 * 因为卡片进程和主应用进程各自独立，内存里的名单互相看不到）。
 */
export class FormPusher {
  /** 车图在卡片里的 key。固定一个就行，每次推的是同一张图的新内容。 */
  private static readonly carImageKey = 'leapCardCar';
  /** 最近一次挂上去的车图 fd，推送完就关。-1 表示这次没有图。 */
  private static carFd: number = -1;
  /** 卡片 id 名单的落盘位置。见 loadIds 说明。 */
  private static idsPath: string = '';

  /** 主应用和卡片进程各自启动时调一次，把沙箱路径记下来。 */
  static init(context: common.Context): void {
    FormPusher.idsPath = `${context.filesDir}/form-ids.txt`;
  }

  static registerForm(formId: string): void {
    const ids = FormPusher.loadIds();
    if (ids.indexOf(formId) < 0) {
      ids.push(formId);
      FormPusher.saveIds(ids);
    }
  }

  static unregisterForm(formId: string): void {
    FormPusher.saveIds(FormPusher.loadIds().filter((id: string) => id !== formId));
  }

  /**
   * 桌面上已添加的卡片 id。
   *
   * 这份名单必须每次现读文件，不能走 SharedSettings：卡片是在卡片进程里登记的
   * （`onAddForm`），而首选项是各进程各缓存一份、启动时读一次，主应用这边的缓存
   * 永远看不到卡片进程后来写进去的 id。现象是新添加的卡片一直停在添加那一刻的
   * 数据上——电量、锁车状态都不再更新，除非把 App 杀掉重开。
   * 首选项本身也不支持跨进程，所以换成一个双方都现读现写的小文件。
   */
  private static loadIds(): string[] {
    if (FormPusher.idsPath.length === 0) {
      return [];
    }
    try {
      const file = fileIo.openSync(FormPusher.idsPath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      const read = fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const text = util.TextDecoder.create('utf-8')
        .decodeToString(new Uint8Array(buffer, 0, read));
      return text.split(',').filter((id: string) => id.length > 0);
    } catch (e) {
      // 一张卡片都还没加过时文件不存在，这是正常情况。
      return [];
    }
  }

  private static saveIds(ids: string[]): void {
    if (FormPusher.idsPath.length === 0) {
      return;
    }
    try {
      const file = fileIo.openSync(FormPusher.idsPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, ids.join(','));
      fileIo.closeSync(file);
    } catch (e) {
      DiagLog.note(`[card] 卡片名单写入失败：${e}`);
    }
  }

  /** 把快照转成卡片可直接渲染的数据。卡片端的字段名必须和这里一致。 */
  static bindingData(snapshot: VehicleSnapshot): CardData {
    const data = new CardData();
    data.vehicleName = snapshot.vehicleName;
    data.soc = snapshot.soc ?? -1;
    data.gasolinePercent = snapshot.gasolinePercent ?? -1;
    data.rangeKm = snapshot.rangeKm ?? -1;
    data.hasFuel = SnapshotUtil.hasFuel(snapshot);
    data.mediumRangeText = SnapshotUtil.mediumRangeText(snapshot);
    data.energyRangeKm = snapshot.energyRangeKm ?? -1;
    data.fuelRangeKm = snapshot.fuelRangeKm ?? -1;
    // 三态：'locked' / 'unlocked' / ''（车没报）。用布尔的话读不到会被当成「没锁」。
    data.isLocked = snapshot.isLocked === null ? '' : (snapshot.isLocked ? 'locked' : 'unlocked');
    data.lockText = snapshot.isLocked === null ? '状态未知' : (snapshot.isLocked ? '已锁车' : '已解锁');
    data.isCharging = snapshot.isCharging;
    data.chargeLimit = snapshot.chargeLimit ?? -1;
    data.indoorTemp = snapshot.indoorTemp ?? -1000;
    data.climateOn = snapshot.climateOn;
    data.windowsClosed = snapshot.windowsClosed === null
      ? '' : (snapshot.windowsClosed ? 'closed' : 'open');
    data.anyDoorOpen = snapshot.anyDoorOpen;
    data.trunkOpen = snapshot.trunkOpen === true;
    data.hasTireWarning = snapshot.hasTireWarning;
    data.headline = SnapshotUtil.headline(snapshot);
    data.freshness = SnapshotUtil.freshnessText(snapshot);
    data.freshnessCompact = SnapshotUtil.freshnessCompact(snapshot);
    data.needsAttention = SnapshotUtil.needsAttention(snapshot);
    data.isStale = SnapshotUtil.isStale(snapshot);
    data.directControl = WidgetSettings.canDispatchDirectly;
    // 刚失败过的话，那句原因顶掉车况摘要——这一刻用户最需要知道的是「刚才那下没成」，
    // 而不是「已锁车」。和 iOS 同一套处理（`WidgetControlFeedback.recentFailure`）。
    data.controlError = WidgetSettings.recentControlError;
    if (data.controlError.length > 0) {
      data.headline = data.controlError;
      data.needsAttention = true;
    }
    FormPusher.carFd = FormPusher.attachCar(data);
    return data;
  }

  /**
   * 把预渲染好的车图挂上去，返回为它打开的文件描述符（没有图时返回 -1）。
   *
   * 图不在（关了「显示车模型」、资源还没下完、演示态）就留空，卡片那边退回剪影——
   * 不给 key 比给一个开不了的 fd 好，后者卡片会一直转圈。
   *
   * 描述符要由调用方在推送之后关掉。框架在 `updateForm` 里就把它复制走了，
   * 留着不关就是纯泄漏：卡片五秒推一次，实测 fd 号一路涨到两百多。
   */
  private static attachCar(data: CardData): number {
    const path = CarSnapshot.filePath;
    if (path.length === 0) {
      return -1;
    }
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const images: Record<string, number> = {};
      images[FormPusher.carImageKey] = file.fd;
      data.formImages = images;
      data.carImage = FormPusher.carImageKey;
      return file.fd;
    } catch (e) {
      DiagLog.note(`[card] 车图 fd 打开失败：${e}`);
      return -1;
    }
  }

  /** 当前快照对应的绑定数据。没有快照就给一份空的，卡片显示占位而不是白屏。 */
  static currentBinding(): formBindingData.FormBindingData {
    const snapshot = SnapshotStore.read();
    const data = snapshot !== null ? FormPusher.bindingData(snapshot) : new CardData();
    return FormPusher.toBinding(data);
  }

  /**
   * 转成 Form Kit 认的绑定数据。
   *
   * 必须先摊成普通对象再交出去：`CardData` 是个类，实例直接传进
   * `createFormBindingData` 时框架不把里面的 `formImages` 当「文件描述符表」处理，
   * 描述符既不会被读取也不会被关闭——现象就是卡片明明拿到了图片 key，
   * `Image` 却渲染不出任何东西，而主应用这边 fd 一路往上涨（实测涨到 200 多）。
   */
  private static toBinding(data: CardData): formBindingData.FormBindingData {
    const plain: Record<string, Object> = JSON.parse(JSON.stringify(data)) as Record<string, Object>;
    return formBindingData.createFormBindingData(plain);
  }

  /** 推给指定卡片。 */
  static push(formId: string): void {
    formProvider.updateForm(formId, FormPusher.currentBinding()).catch(() => {
      FormPusher.unregisterForm(formId);
    });
    FormPusher.closeCarFd();
  }

  /** 关掉上一次挂车图时开的描述符。框架在 updateForm 里已经复制走了。 */
  private static closeCarFd(): void {
    if (FormPusher.carFd < 0) {
      return;
    }
    try {
      fileIo.closeSync(FormPusher.carFd);
    } catch (e) {
      DiagLog.note(`[card] 关闭车图 fd 失败：${e}`);
    }
    FormPusher.carFd = -1;
  }

  /** 读一次快照，推给所有卡片。没有卡片或没有快照时什么都不做。 */
  static pushAll(): void {
    const ids = FormPusher.loadIds();
    if (ids.length === 0) {
      return;
    }
    const snapshot = SnapshotStore.read();
    if (snapshot === null) {
      return;
    }
    for (let i = 0; i < ids.length; i++) {
      const formId = ids[i];
      // 每张卡片单独构造一份：`formImages` 里装的是文件描述符，交出去就由卡片框架
      // 接管、用完即关。几张卡片共用同一份 data 的话，第一张消费完后面几张拿到的
      // 就是已经关掉的 fd，车图只有第一张能出图。
      const data = FormPusher.toBinding(FormPusher.bindingData(snapshot));
      formProvider.updateForm(formId, data).catch(() => {
        // 卡片可能已被用户删掉，从名单里剔除，别每次都白推一遍。
        FormPusher.unregisterForm(formId);
      });
      FormPusher.closeCarFd();
    }
  }
}
