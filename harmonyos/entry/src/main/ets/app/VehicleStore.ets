import { BLEPairingPreparation } from './BLEPairingPreparation';
import { deviceInfo } from '@kit.BasicServicesKit';
import { BLEUnlockDistance } from '../core/BLEProtocol';
import { LeapClient } from '../core/LeapClient';
import { OperationPasswordStore } from '../core/SecureStore';
import { SharedSettings } from '../core/SharedSettings';
import { DiagLog } from '../core/DiagLog';
import { LeapError, LeapErrorKind } from '../core/LeapError';
import { JsonValue } from '../core/JsonValue';
import { DrivingStats, DrivingStatsRange, EnergyDistribution } from '../core/DrivingStats';
import { CarModel } from '../core/CarModel';
import { CarModelAssets } from '../core/CarModelAssets';
import { CarLayerComposer, LayerPlan } from '../core/CarLayerComposer';
import { VehicleSignal, ClimateMode } from '../core/SignalSchema';
import {
  LeapSession, SessionUtil, Vehicle, VehicleState, LeapCommand, ControlReceipt, Coordinate,
  ExpectationKind, ParkingPhoto, VehicleUtil
} from '../core/LeapModels';
import { SeatPosition, SeatPositions, SeatComfortChannel, SeatChannels, FridgeSetting } from '../core/CabinComfort';
import { ClimateAppointment } from '../core/ClimateAppointment';
import { CalibrationTask, CalibrationTasks, LearnedSignals } from '../core/Calibration';
import { Appearance } from './Appearance';
import { BiometricGate, BiometricKind } from './BiometricGate';
import { ReviewDemo } from './ReviewDemo';
import { LocationNaming } from './LocationNaming';
import {
  VehicleSnapshot, SnapshotStore, SnapshotUtil, WidgetAction, WidgetSettings
} from './VehicleSnapshot';
import {
  ControlDiagnostic, ControlDiagnosticStore, ControlOutcome, ReceiptSample
} from './ControlDiagnostic';
import { FormPusher } from './FormPusher';
import { LeapBLECredentialContext } from '../core/BLEProtocol';
import { BLEKeyCertificateStore, BLEPairingHistory } from './BLEVehicleBinding';
import { BLEPermission } from './BLEPermission';
import { BLEVehicleController } from './BLEVehicleController';
import { BLERuntimeStateKind } from './BLEVehicleControllerTypes';
import { CarSnapshot } from './CarSnapshot';

/**
 * 空调设定草稿存本机。空调没开的时候车端不保存这几项（上报的是上次运行的残留值），
 * 不自己存一份的话，每次冷启动都会回到默认值而不是用户上次选的。
 */
export class ClimateDraft {
  private static readonly prefix = 'climate.draft.';

  static get temperature(): number {
    return SharedSettings.getInt(ClimateDraft.prefix + 'temperature', 24);
  }

  static set temperature(value: number) {
    SharedSettings.setInt(ClimateDraft.prefix + 'temperature', value);
  }

  static get fanLevel(): number {
    return SharedSettings.getInt(ClimateDraft.prefix + 'fanLevel', 3);
  }

  static set fanLevel(value: number) {
    SharedSettings.setInt(ClimateDraft.prefix + 'fanLevel', value);
  }

  static get mode(): ClimateMode {
    const raw = SharedSettings.getString(ClimateDraft.prefix + 'mode', '');
    switch (raw) {
      case 'hot':
        return ClimateMode.hot;
      case 'vent':
        return ClimateMode.vent;
      case 'auto':
        return ClimateMode.auto;
      default:
        return ClimateMode.cold;
    }
  }

  static set mode(value: ClimateMode) {
    SharedSettings.setString(ClimateDraft.prefix + 'mode', value);
  }

  static get circleIn(): boolean {
    return SharedSettings.getBool(ClimateDraft.prefix + 'circleIn', true);
  }

  static set circleIn(value: boolean) {
    SharedSettings.setBool(ClimateDraft.prefix + 'circleIn', value);
  }
}

/** 深浅色外观。默认跟随系统，用户也可以在设置里固定成浅色或深色。 */
export enum AppearanceMode {
  system = 'system',
  light = 'light',
  dark = 'dark'
}

export class AppearanceModeUtil {
  static label(mode: AppearanceMode): string {
    switch (mode) {
      case AppearanceMode.light:
        return '浅色';
      case AppearanceMode.dark:
        return '深色';
      default:
        return '跟随系统';
    }
  }

  static all(): AppearanceMode[] {
    return [AppearanceMode.system, AppearanceMode.light, AppearanceMode.dark];
  }
}

/** 一次控车请求在 UI 上要走的确认流程。目前只有「请输入操作密码」这一种。 */
/** 驻车照片查询结果：元信息 + 图片二进制（地址为空时为 null）。 */
export interface ParkingPhotoResult {
  photo: ParkingPhoto;
  data: ArrayBuffer | null;
}

export interface AuthChallenge {
  prompt: string;
}

/** 预约回读的四种状态。 */
export enum AppointmentReadbackKind {
  loading,
  /** 车上没有预约（回读到空 `controls`，或者里面没有开着的项）。 */
  empty,
  loaded,
  /** 读不到。和 empty 必须分开说：读不到不等于没有。 */
  failed
}

export class AppointmentReadback {
  readonly kind: AppointmentReadbackKind;
  readonly appointment: ClimateAppointment | null;
  readonly message: string;

  private constructor(kind: AppointmentReadbackKind, appointment: ClimateAppointment | null, message: string) {
    this.kind = kind;
    this.appointment = appointment;
    this.message = message;
  }

  static loading(): AppointmentReadback {
    return new AppointmentReadback(AppointmentReadbackKind.loading, null, '');
  }

  static empty(): AppointmentReadback {
    return new AppointmentReadback(AppointmentReadbackKind.empty, null, '');
  }

  static loaded(appointment: ClimateAppointment): AppointmentReadback {
    return new AppointmentReadback(AppointmentReadbackKind.loaded, appointment, '');
  }

  static failed(message: string): AppointmentReadback {
    return new AppointmentReadback(AppointmentReadbackKind.failed, null, message);
  }
}

@ObservedV2
export class ToastMessage {
  @Trace text: string = '';
  @Trace detail: string = '';
  @Trace isError: boolean = false;
  /** 带重试按钮的提示要停久一点，否则用户还没来得及点就消失了。 */
  @Trace showsRetry: boolean = false;
  @Trace seconds: number = 3;
  /** 每条提示一个序号，界面靠它判断「这是新的一条」而不是同一条改了字。 */
  @Trace id: number = 0;
}

/** 车上当前那份被确认过的空调设定。 */
interface ClimateSettings {
  on: boolean;
  temperature: number;
  fanLevel: number;
  mode: ClimateMode;
  circleIn: boolean;
}

/**
 * 全局车况与控车状态。
 *
 * 用状态管理 V2：`@ObservedV2` + `@Trace` 能追踪到嵌套类的属性变化，
 * 不像 V1 的 `@Observed`/`@ObjectLink` 只认第一层。
 */
@ObservedV2
export class VehicleStore {
  private blePairingPreparationInProgress: boolean = false;
  private readonly client: LeapClient = new LeapClient();
  private readonly passwordStore: OperationPasswordStore = new OperationPasswordStore();
  private readonly bleCertificateStore: BLEKeyCertificateStore = new BLEKeyCertificateStore();
  /** 蓝牙钥匙运行时。整个进程只有这一个，蓝牙钥匙页和首页控车共用同一条链路。 */
  readonly bleController: BLEVehicleController = new BLEVehicleController();

  /** 卡片点进来时要打开的页面。 */
  @Trace pendingDeepLink: string = '';

  // MARK: - 对外状态

  @Trace session: LeapSession = SessionUtil.fresh();
  /** 每退出一次登录递增。根视图拿它当首页的 key，强制整棵视图树重建。 */
  @Trace loginEpoch: number = 0;
  @Trace state: VehicleState | null = null;
  @Trace isRefreshing: boolean = false;
  @Trace isSendingCommand: boolean = false;
  /** 本机最后一次成功拉到车况的时刻。 */
  @Trace lastUpdated: number = 0;
  /**
   * 车端采集这份车况的时刻，0 表示这台车没报（或报了个不可信的值）。
   *
   * 界面上那句「车况几分钟前更新」要的是这个数，不是 `lastUpdated`——
   * 车休眠时服务端会把同一份旧数据一直发回来，本机拉得再勤也不会变新。
   */
  @Trace reportedAt: number = 0;
  @Trace lastReceipt: ControlReceipt | null = null;
  /**
   * 指令下发后正在等车动作。和 `isSendingCommand` 分开：
   * 前者是「网络请求在飞」，这个是「车还没确认」，界面上要提示的是后者。
   */
  @Trace confirmingLabel: string = '';
  /** 超时后可以原样重发的指令。不自动重发——尾门和鸣笛重发是会真的再动一次车的。 */
  @Trace retryableCommand: LeapCommand | null = null;
  @Trace lastDiagnostic: ControlDiagnostic | null = null;
  /** 车辆位置反解析出的地址名，比经纬度对用户有意义得多。 */
  @Trace locationName: string = '';
  @Trace toast: ToastMessage | null = null;
  @Trace challenge: AuthChallenge | null = null;

  @Trace carModel: CarModel | null = null;
  /** 3D 资源解压目录。有值才渲染 3D。 */
  @Trace carModelRoot: string = '';
  /**
   * 从解压目录反推的车型别名（`Lafa5` 这种）。渲染器按它拼资源路径，
   * 接口不返回，只能等资源落地后现推——见 `CarModelAssets.assetAlias`。
   */
  @Trace carAssetAlias: string | null = null;
  @Trace is3DDownloading: boolean = false;
  /**
   * 2D 图层包解压后的目录。空串表示没有图层可用（首页回退剪影）。
   *
   * iOS 那版这里存的是「叠好的成品图」的路径，因为 SwiftUI 和桌面小组件都要单张图；
   * 鸿蒙这边不合成，首页直接把图层摆进 Stack，所以只需要目录和方案两样。
   */
  @Trace carLayerDirectory: string = '';
  /** 当前车况对应的图层方案。方案没变就不重建，充电动画不会每次刷新都跳回第一帧。 */
  @Trace carLayerPlan: LayerPlan = new LayerPlan();

  /** 生物识别开关（用户可关，关掉后每次控车都手输操作密码）。 */
  @Trace biometricEnabled: boolean = true;
  /** 记住操作密码后才能用生物识别代替输入。 */
  @Trace hasSavedPassword: boolean = false;
  /**
   * 首页是否显示官方车模型（3D / 按车况叠的 2D 车图）。
   * 关掉就回到剪影，同时也不再下载、解压、叠图——完全不碰模型资源。
   */
  @Trace showCarModel: boolean = true;
  /** 已经为哪台车自愈过一次资源。只在内存里记，重开 App 可以再试一次。 */
  private repairedModelVin: string = '';
  /** 深浅色外观，默认跟随系统。 */
  @Trace appearance: AppearanceMode = AppearanceMode.system;
  /** 桌面卡片是否允许绕过 App 直接下发指令。 */
  @Trace widgetControlEnabled: boolean = false;

  readonly biometricKind: BiometricKind = BiometricGate.available;

  // MARK: - 本地草稿（控件即时反馈，指令下发后再由车况纠正）

  @Trace climateTemperature: number = 24;
  @Trace climateFanLevel: number = 3;
  @Trace climateMode: ClimateMode = ClimateMode.cold;
  @Trace climateCircleIn: boolean = true;
  @Trace climateOn: boolean = false;
  @Trace chargeLimitDraft: number = 90;
  /**
   * 哨兵开关的即时反馈草稿。哨兵是纯布尔开关，没有空调那套温度/风量草稿，但同样需要
   * 乐观翻转：点一下立刻变，指令下发→车况轮询确认后再由 syncDraftsFromState 以车况纠正。
   */
  @Trace sentinelOn: boolean = false;

  // MARK: 舒适座舱草稿（同 iOS `VehicleStore`「舒适座舱」段）

  /**
   * 座椅 / 方向盘档位的本机草稿。只活在「用户点了」到「这条指令跑完」之间：
   * 跑完之后由 `clearCabinDraftsIfSettled` 清掉，界面落回车况报的真值——
   * 成功就是新档位，失败就是原档位，不需要单独写一套回滚。
   *
   * 每次改动整份换一个新 Map，别原地 set：状态管理靠引用变化最稳。
   */
  @Trace cabinDrafts: Map<string, number> = new Map<string, number>();
  @Trace mirrorHeatingDraft: boolean | null = null;
  /** 冰箱草稿。进页面时从车况播种（见 `seedFridgeDraft`），之后由界面整份替换。 */
  @Trace fridgeDraft: FridgeSetting | null = null;

  /** 车上预约空调的回读结果。`null` 是还没读过。 */
  @Trace climateAppointmentReadback: AppointmentReadback | null = null;

  /**
   * 每个「座位 + 通道」各一个防抖定时器。**不能共用一个**：共用的话
   * 「主驾调到 3 档后马上点副驾」会把主驾那条取消掉，用户看到的是主驾白点一遍。
   */
  private cabinPushTimers: Map<string, number> = new Map<string, number>();
  /**
   * `perform` 是单航道的——上一条还在等车确认时它会把新指令直接丢掉。
   * 座舱这页一次能点出好几条（四个座位，还有「全部关闭」一次发一批），
   * 丢掉就等于用户点了没反应，所以压进队列，等上一条跑完再接着发。
   */
  private cabinQueue: LeapCommand[] = [];
  /** 松手到下发之间的防抖窗口。和空调页调温度那条同一个值、同一个理由。 */
  static readonly cabinPushDelayMs = 800;
  private static readonly steeringWheelKey = 'steeringWheel';
  private static readonly fridgeKey = 'fridge';

  /**
   * 用户最后一次在界面上动空调的时间。
   *
   * 这段时间里的车况不许回冲草稿：从按下到指令真正发出去有一段延迟，
   * 期间五秒一次的轮询要是插进来，车报的还是旧值，用户刚调的数字会被弹回去——
   * 看上去就是「这一下没生效，得再按一次」。
   */
  private climateEditedAt: number = 0;
  /** 正在用车况回填草稿，这期间的改动不算用户操作。 */
  private isSyncingClimateDrafts: boolean = false;
  /** 指令还在路上时用户又调了。等这条走完补发一次最新的，别把用户的调整吞掉。 */
  private climatePushQueued: boolean = false;
  private static readonly climateEditGrace = 3000;

  /** 等待用户确认后要发送的指令。 */
  private pendingCommand: LeapCommand | null = null;

  /**
   * 等着一次密码覆盖整批的充电指令（480 + 190）。
   *
   * 和 `pendingCommand` 互斥：走到批量分支时把单条那个清空，
   * 否则密码回来后两边都会发，190 会被发两遍。
   */
  private pendingChargeBatch: LeapCommand[] | null = null;

  /**
   * 最近一次车真的知道的空调设定。
   *
   * 界面上改模式、温度、风量是立刻生效的（要的就是这个即时反馈），但指令还得过操作密码。
   * 用户取消掉密码、或者指令下发失败，车压根没收到，界面却已经显示成新设定了——
   * 这时必须退回这份，否则就是在骗人。C11 不上报空调模式，靠车况纠正是等不到的。
   */
  private confirmedClimate: ClimateSettings | null = null;

  /**
   * 本次前台使用期间已经验证过身份，后续指令直接下发。
   *
   * 退到后台就作废：手机放在桌上被别人拿起来时，不该还能一路点到底。
   * 密码只留在内存里，不额外落盘——落盘的那份始终只有关键资产里勾了「记住」的那个。
   */
  private verifiedPassword: string = '';

  private pollTimer: number = -1;
  /** 轮询和用户手动刷新会撞在一起，同一时刻只允许一个请求在飞。 */
  private fetchInFlight: boolean = false;
  /** 有请求在飞时被挡掉的刷新请求，等这次落地后补上。 */
  private refreshPending: boolean = false;
  /**
   * 本次 App 运行内是否已成功拉过一次 vehicle/list。用来「首启强制刷新一次能力码」：
   * 升级用户持久化的旧车列表缺 isExtendRange，必须重拉一次纠正，之后轮询不再重复拉。
   */
  private didLoadVehiclesThisLaunch: boolean = false;
  private toastSeq: number = 0;

  /**
   * 车况没有推送，只能轮询。前台每 5 秒一次，进后台立刻停。
   *
   * 注意这只决定「本机多久问一次服务端」。车端自己什么时候上报是另一回事——
   * 界面上那句新鲜度用的是车端时间，拉得再勤也不会让它变新。
   */
  static readonly pollIntervalMs = 5000;
  /**
   * 实测车辆 5–10 秒响应，休眠时更久。20 秒是覆盖正常情况又不至于干等太久的折中。
   * 已知一次真实样本：空调开启 11.8 秒确认。
   */
  static readonly confirmTimeoutMs = 20000;
  /**
   * 每 2 秒查一次。这个值同时决定了确认的时间分辨率——
   * 间隔多长，「车实际什么时候动的」就有多大误差，而这个数字正是在用来定窗口长度。
   */
  static readonly pollStepMs = 2000;

  /** 读回本机偏好。SharedSettings.init 之后调。 */
  loadPreferences(): void {
    this.biometricEnabled = SharedSettings.getBool('biometricEnabled', true);
    this.showCarModel = SharedSettings.getBool('showCarModel', true);
    const appearanceRaw = SharedSettings.getString('appearanceMode', '');
    this.appearance = appearanceRaw === 'light' ? AppearanceMode.light
      : (appearanceRaw === 'dark' ? AppearanceMode.dark : AppearanceMode.system);
    Appearance.apply(this.appearance);
    this.widgetControlEnabled = WidgetSettings.controlEnabled;
    this.climateTemperature = ClimateDraft.temperature;
    this.climateFanLevel = ClimateDraft.fanLevel;
    this.climateMode = ClimateDraft.mode;
    this.climateCircleIn = ClimateDraft.circleIn;
    this.lastDiagnostic = ControlDiagnosticStore.load();
  }

  /**
   * 把客户端里的会话同步到状态层。
   *
   * 必须取快照而不是直接赋引用：客户端是就地改自己那份会话的字段，
   * 引用从头到尾没变过，`@Trace` 比较引用后判定「没变化」，
   * 登录成功也不会触发重绘——界面就卡在登录页。
   */
  private syncSession(): void {
    this.session = SessionUtil.snapshot(this.client.session);
  }

  /**
   * 蓝牙钥匙能不能真用：演示态一律不跑。下面几处失败文案也因此只会在演示态出现。
   */
  get bluetoothKeyEligible(): boolean {
    return !this.isDemo;
  }

  // MARK: - 蓝牙钥匙

  /**
   * 读本机存着的蓝牙证书。
   *
   * iOS 那边这里是三态（有 / 没有 / 钥匙串锁着读不到），锁着时要挂起武装等解锁重试。
   * 关键资产在锁屏期间同样返回「找不到」，两种情况分不出来，所以这里只有两态；
   * 好在读不到的后果只是这一轮武装停在「尚未绑定」，不会删任何东西，
   * 回到前台再走一次 `refreshBluetoothRuntime` 就补上了。
   */
  async cachedBLECredentialContext(): Promise<LeapBLECredentialContext | null> {
    if (this.isDemo) {
      return null;
    }
    const accountId = this.session.oldAuth !== null ? this.session.oldAuth.accountId : '';
    if (accountId.length === 0 || this.session.selectedVin.length === 0) {
      return null;
    }
    // 设备号还没就位（开机后关键资产还读不到的那段窗口）：证书就算在手里也签不出认证包
    // （`LeapBLEProtocol` 会挡空 deviceId），拿空值装配只会得到一次静默失败的连接。
    // 这一轮停在「尚未绑定」，回到前台再走一次 `refreshBluetoothRuntime` 就补上了。
    if (this.session.deviceId.length === 0) {
      DiagLog.note('[ble:arm] deviceId 尚未就绪，先不武装');
      return null;
    }
    const vin = this.session.selectedVin;
    const deviceId = this.session.deviceId;
    const certificate = await this.bleCertificateStore.load(accountId, vin);
    if (!this.isBLEIdentityCurrent(accountId, vin, deviceId)) { return null; }
    if (certificate === null) {
      return null;
    }
    return new LeapBLECredentialContext(certificate, accountId, deviceId, vin);
  }

  /** 从服务端重新同步蓝牙证书并落盘。资格、类型、passwordCard 三道都过了才算数。 */
  async syncBLECredentialContext(): Promise<LeapBLECredentialContext> {
    if (this.isDemo) {
      throw LeapError.server('演示模式不能同步蓝牙证书');
    }
    if (!this.bluetoothKeyEligible) {
      throw LeapError.server('演示模式不能使用蓝牙钥匙');
    }
    const accountId = this.session.oldAuth?.accountId ?? '';
    const vin = this.session.selectedVin;
    const deviceId = this.session.deviceId;
    if (accountId.length === 0 || vin.length === 0 || deviceId.length === 0) {
      throw LeapError.notLoggedIn();
    }
    const certificate = await this.client.fetchBLEKeyCertificate();
    if (!this.isBLEIdentityCurrent(accountId, vin, deviceId) || !this.bluetoothKeyEligible) {
      throw LeapError.server('蓝牙证书同步期间账号或车辆已变化');
    }
    if (!certificate.isSupportedKeyType) {
      throw LeapError.server(`当前蓝牙证书类型不受支持（keyType=${certificate.keyType}）`);
    }
    if (!certificate.hasValidPasswordCard) {
      throw LeapError.server('当前蓝牙证书的 passwordCard 无效，请重新同步');
    }
    this.syncSession();
    if (!this.isBLEIdentityCurrent(accountId, vin, deviceId) || !this.bluetoothKeyEligible) {
      throw LeapError.server('蓝牙证书同步期间账号或车辆已变化');
    }
    if (!(await this.bleCertificateStore.save(certificate, accountId, vin))) {
      throw LeapError.server('蓝牙证书写入关键资产失败');
    }
    if (!this.isBLEIdentityCurrent(accountId, vin, deviceId) || !this.bluetoothKeyEligible) {
      throw LeapError.server('蓝牙证书同步期间账号或车辆已变化');
    }
    const context = new LeapBLECredentialContext(certificate, accountId, deviceId, vin);
    await this.bleController.configureProduction(context, this.bluetoothKeyEligible);
    await this.refreshBLEProtocolVersion();
    await this.refreshBLECalibration();
    return context;
  }

  /** 按当前会话、当前车、当前资格重新武装一轮。登录、换车、兑码后都要走。 */
  async refreshBluetoothRuntime(): Promise<void> {
    const accountId = this.session.oldAuth?.accountId ?? '';
    const vin = this.session.selectedVin;
    const deviceId = this.session.deviceId;
    const context = await this.cachedBLECredentialContext();
    if ((this.session.oldAuth?.accountId ?? '') !== accountId
      || this.session.selectedVin !== vin || this.session.deviceId !== deviceId) { return; }
    await this.bleController.configureProduction(context, this.bluetoothKeyEligible);
  }

  /**
   * 登录后补一次证书同步。
   *
   * 退登会把证书连坐清掉，重登之后没人补，蓝牙钥匙页就一直停在「缺少蓝牙证书」。
   * 绑定救不回来（得在车旁重新配对），所以证书补上后若发现停在未绑定，
   * 就把「差的是配对」这一步明确说出来——只对确实配过的车说，
   * 从没配过的车同样停在未绑定，弹这条只会让用户以为丢了什么。
   */
  async recoverBluetoothCredentialIfNeeded(): Promise<void> {
    if (!this.bluetoothKeyEligible) {
      return;
    }
    if ((await this.cachedBLECredentialContext()) !== null) {
      return;
    }
    try {
      await this.syncBLECredentialContext();
      DiagLog.note('[ble:recover] 登录后证书缺失，已自动补同步');
      const accountId = this.session.oldAuth !== null ? this.session.oldAuth.accountId : '';
      if (this.bleController.runtimeState.kind === BLERuntimeStateKind.Unbound
        && accountId.length > 0
        && BLEPairingHistory.hasPaired(accountId, this.session.selectedVin)) {
        this.show('蓝牙钥匙需要重新配对',
          '退出登录会清除配对信息，请在车旁打开 功能 → 蓝牙钥匙 完成配对', false, false, 6);
      }
    } catch (e) {
      // 补不上不打扰用户：没资格、离线、服务端拒绝都可能走到这，
      // 蓝牙钥匙页的「需要处理」文案会兜底。
      DiagLog.note(`[ble:recover] 登录后补同步蓝牙证书失败：${LeapError.messageOf(e as object)}`);
    }
  }

  private isBLEIdentityCurrent(accountId: string, vin: string, deviceId: string): boolean {
    return !this.isDemo && (this.session.oldAuth?.accountId ?? '') === accountId
      && this.session.selectedVin === vin && this.session.deviceId === deviceId
      && (this.client.session.oldAuth?.accountId ?? '') === accountId
      && this.client.session.selectedVin === vin && this.client.session.deviceId === deviceId;
  }

  /** 手动配对优先刷新证书；正常自动重连仍使用本机凭证。 */
  async prepareBLEPairing(): Promise<void> {
    if (this.blePairingPreparationInProgress) { return; }
    if (!this.bluetoothKeyEligible) {
      this.show('演示模式不能使用蓝牙钥匙', '', true);
      return;
    }
    this.blePairingPreparationInProgress = true;
    this.bleController.cancelPairing();
    const generation = this.bleController.pairingPreparationGeneration;
    const accountId = this.session.oldAuth?.accountId ?? '';
    const vin = this.session.selectedVin;
    const deviceId = this.session.deviceId;
    const isCurrent = (): boolean => this.bluetoothKeyEligible
      && this.isBLEIdentityCurrent(accountId, vin, deviceId)
      && generation === this.bleController.pairingPreparationGeneration;
    try {
      const permitted = await BLEPermission.ensure();
      if (!isCurrent()) { return; }
      if (!permitted) {
        this.show('需要蓝牙权限', '请在系统设置里允许本应用使用蓝牙', true);
        return;
      }
      const cached = await this.cachedBLECredentialContext();
      if (!isCurrent()) { return; }
      const context = await BLEPairingPreparation.resolve(cached,
        (): Promise<LeapBLECredentialContext> => this.syncBLECredentialContext(), isCurrent,
        (message: string): void => this.bleController.recordPairingPreparation(message));
      if (!isCurrent()) { return; }
      await this.bleController.configureProduction(context, true);
      if (!isCurrent()) { return; }
      await this.refreshBLEProtocolVersion();
      if (!isCurrent()) { return; }
      this.bleController.beginPairing();
    } catch (e) {
      if (isCurrent()) { this.showError(e as Error); }
    } finally {
      this.blePairingPreparationInProgress = false;
    }
  }

  /** 蓝牙控车总开关。关掉的那一步也要连上车把配置写回去，不是本机改个标记。 */
  async refreshBLEProtocolVersion(): Promise<void> {
    if (!this.bluetoothKeyEligible) { return; }
    const account = this.session.oldAuth?.accountId ?? '';
    const vin = this.session.selectedVin;
    if (account.length === 0 || vin.length === 0) { return; }
    try {
      const minor = await this.client.fetchBLEProtocolMinor(vin, account);
      this.bleController.configureProtocolVersion(minor, account, vin);
    } catch (_) {
      DiagLog.note('[ble:version.fetch.failed] 保留已验证版本');
    }
  }

  async refreshBLECalibration(): Promise<void> {
    const binding = this.bleController.binding;
    if (binding === null) { return; }
    try {
      const calibration = await this.client.fetchBLECalibration(deviceInfo.productModel, deviceInfo.manufacture,
        SessionUtil.selectedVehicle(this.session)?.permission.includes('bleMultipleAnchors') ?? false, binding.vin, binding.accountId);
      await this.bleController.applyCalibration(calibration, binding.accountId, binding.vin);
      DiagLog.note(`[ble:calibration.cloudFetch.success] ${calibration.applying(binding.configuration).diagnosticSummary()}`);
    } catch (_) {
      DiagLog.note('[ble:calibration.cloudFetch.failed] 保留本机标定');
      // 离线保留本机已保存的距离标定，不能阻止蓝牙控车。
    }
  }

  async setBLEUnlockDistance(distance: BLEUnlockDistance): Promise<void> {
    const current = this.bleController.binding;
    if (current === null) { return; }
    let locallySaved: boolean = false;
    try {
      await this.bleController.setUnlockDistance(distance);
      locallySaved = true;
      const updated = this.bleController.binding;
      if (updated === null || updated.vin !== current.vin || updated.accountId !== current.accountId) { return; }
      if (updated.configuration.unlockDistance !== distance) { return; }
      DiagLog.note(`[ble:distance.cloudSave.begin] ${updated.configuration.diagnosticSummary()}`);
      await this.client.saveBLECalibration(deviceInfo.productModel, updated.configuration, updated.vin, updated.accountId);
      DiagLog.note(`[ble:distance.cloudSave.success] vehicleConfirmation=separate ${updated.configuration.diagnosticSummary()}`);
    } catch (e) {
      DiagLog.note('[ble:distance.cloudSave.failed]');
      if (this.bleController.binding?.vin !== current.vin || this.bleController.binding?.accountId !== current.accountId) { return; }
      if (locallySaved) { this.show('距离已保存到手机，云端同步失败', '靠近车辆后会下发设置', true); }
      else { this.showError(e as Error); }
    }
  }

  async setBluetoothControlEnabled(enabled: boolean): Promise<void> {
    try {
      await this.bleController.setBluetoothControlEnabled(enabled);
    } catch (e) {
      this.showError(e as Error);
    }
  }

  /**
   * 无感解锁。
   *
   * 除了把配置写回车里，这一项在鸿蒙上还会决定要不要起长时任务
   * （`BLEPassiveEntryTask`）——进程被回收就没有常连，也就没有无感。
   * 所以打开它会多一条撤不掉的常驻通知，默认是关的。
   */
  async setPassiveAutoUnlock(enabled: boolean): Promise<void> {
    try {
      await this.bleController.updatePassiveEntry(enabled, this.bleController.autoLockEnabled);
    } catch (e) {
      this.showError(e as Error);
    }
  }

  /** 离车自动闭锁。同样要常连，所以和无感解锁共用那条长时任务。 */
  async setPassiveAutoLock(enabled: boolean): Promise<void> {
    try {
      await this.bleController.updatePassiveEntry(this.bleController.autoUnlockEnabled, enabled);
    } catch (e) {
      this.showError(e as Error);
    }
  }

  /** 解绑。先把「关掉」发给车，车确认之后才删本机记录。 */
  async removeBluetoothBinding(): Promise<void> {
    try {
      await this.bleController.removeBinding();
    } catch (e) {
      this.showError(e as Error);
    }
  }

  /** 前后台切换。后台要停直进直出，也要停正在搜索的配对。 */
  setApplicationActive(active: boolean): void {
    this.bleController.setApplicationActive(active);
  }

  get isLoggedIn(): boolean {
    return SessionUtil.isLoggedIn(this.session);
  }

  get vehicleName(): string {
    return SessionUtil.displayVehicleName(this.session);
  }

  /** 车辆坐标，隐私模式下拿不到。 */
  get coordinate(): Coordinate | null {
    return this.state !== null ? this.state.shareableCoordinate : null;
  }

  /**
   * 这台车能不能远程控车窗，见 `VehicleState.windowsRemoteSupported`。
   *
   * **读不到车况时按「能」算**：不知道不等于不能。冷启动那一下车况还是空的，
   * 按「不能」算会让入口先消失、读到车况再冒出来，比多摆一个入口更难看。
   */
  get windowsControllable(): boolean {
    return this.state !== null ? this.state.windowsRemoteSupported : true;
  }

  /**
   * 当前选中车支不支持哨兵模式，决定首页第二格显示哨兵卡还是空调卡。
   * 判据在 loadVehicles 里从 abilities 翻出的内部码派生、随车持久化（见 Vehicle.isSentinelSupported）；
   * 老会话缺该字段读出来是 undefined，`?? false` 兜底（同时 sentinelStale 会触发一次重拉补齐）。
   * 选不到车（冷启动车列表还没到）也按 false：宁可先摆空调卡，等真支持了再换成哨兵卡。
   */
  get sentinelSupported(): boolean {
    const vehicle = SessionUtil.selectedVehicle(this.session);
    return vehicle !== null ? (vehicle.isSentinelSupported ?? false) : false;
  }

  /**
   * 遮阳帘 / 天窗 / 前备箱支不支持远控。和哨兵一样随车走（vehicle/list 的能力码）、不看车况；
   * 区别是不落持久化字段、就地现算——`permission` 本身已随会话持久化，
   * 老会话缺 `permission` 的场景已有 sentinelStale 强制重拉 vehicle/list 兜底。
   * 选不到车（冷启动车列表还没到）一律 false：控车条上宁可少一格，也不摆一个点了没反应的按钮。
   */
  get sunshadeSupported(): boolean {
    const vehicle = SessionUtil.selectedVehicle(this.session);
    return vehicle !== null ? VehicleUtil.supportsSunshade(vehicle.permission ?? []) : false;
  }

  get sunroofSupported(): boolean {
    const vehicle = SessionUtil.selectedVehicle(this.session);
    return vehicle !== null ? VehicleUtil.supportsSunroof(vehicle.carType, vehicle.permission ?? []) : false;
  }

  get frunkSupported(): boolean {
    const vehicle = SessionUtil.selectedVehicle(this.session);
    return vehicle !== null ? VehicleUtil.supportsFrunk(vehicle.carType, vehicle.permission ?? []) : false;
  }

  /**
   * 舒适座舱页要不要给入口。
   *
   * 和上面那几项反过来：**车况信号说话，能力码只是兜底**。理由两条——
   * 信号比能力码更贴车端（八个座椅信号在实测 C16 上逐个在场），而方向盘加热那条
   * 指令（cmdid 320）压根没有已知的 `abilities` 原始码，只能靠信号 `1816`。
   * 两路都没有才隐藏。
   */
  get cabinComfortSupported(): boolean {
    if (this.state !== null && this.state.hasCabinComfort) {
      return true;
    }
    const vehicle = SessionUtil.selectedVehicle(this.session);
    return vehicle !== null
      ? VehicleUtil.supportsCabinComfort(vehicle.carType, vehicle.permission ?? []) : false;
  }

  /**
   * 车载冰箱要不要给入口。同上，信号优先。
   *
   * 实测用的那台 C16 两路都没有（`abilities` 不含 `76`、signalMap 里冰箱信号全无），
   * 所以这个入口在那台车上整个不出现——这是「读不到就别显示」，不是功能缺失。
   */
  get fridgeSupported(): boolean {
    if (this.state !== null && this.state.fridgeState !== null) {
      return true;
    }
    const vehicle = SessionUtil.selectedVehicle(this.session);
    return vehicle !== null ? VehicleUtil.supportsFridge(vehicle.carType, vehicle.permission ?? []) : false;
  }

  // MARK: - 偏好写回

  setBiometricEnabled(value: boolean): void {
    this.biometricEnabled = value;
    SharedSettings.setBool('biometricEnabled', value);
  }

  setAppearance(value: AppearanceMode): void {
    this.appearance = value;
    SharedSettings.setString('appearanceMode', value);
    // 存下来只是为了下次启动。这一句才是真正让界面当场变深浅的。
    Appearance.apply(value);
  }

  setWidgetControlEnabled(value: boolean): void {
    this.widgetControlEnabled = value;
    WidgetSettings.controlEnabled = value;
    this.reloadWidgets();
  }

  async setShowCarModel(value: boolean): Promise<void> {
    if (this.showCarModel === value) {
      return;
    }
    this.showCarModel = value;
    SharedSettings.setBool('showCarModel', value);
    if (value) {
      await this.loadCarModel();
    } else {
      this.unloadCarModel();
    }
  }

  // MARK: - 前台轮询

  startPolling(): void {
    this.stopPolling();
    if (!this.isLoggedIn || this.isDemo) {
      return;
    }
    this.pollTimer = setInterval(() => {
      this.refresh(false);
    }, VehicleStore.pollIntervalMs);
  }

  stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  // MARK: - 生命周期

  async bootstrap(): Promise<void> {
    // 每次启动都让桌面卡片重新刷一遍。不这么做的话，装了新版本后桌面上那张卡
    // 还会拿旧数据渲染出的画面顶很久，看起来就像改动没生效。
    this.reloadWidgets();
    // 审核员可能会杀掉 App 重进，演示态要能恢复，否则会掉回登录页。
    if (this.isDemo) {
      this.session = ReviewDemo.session();
      const demoState = ReviewDemo.vehicleState();
      this.state = demoState;
      this.markUpdated(demoState);
      this.syncDraftsFromState(demoState);
      await this.resolveLocationName();
      this.publishSnapshot();
      return;
    }
    await this.client.restore();
    this.syncSession();
    this.setSavedPasswordFlag(await this.passwordStore.hasPassword());
    if (!this.isLoggedIn) {
      return;
    }
    // 开 App 先探一次登录态：被挤下线后车况仍能刷出来，只有主动探控车 token 才发现。
    // 失效就直接回登录页，不再往下拉车况和轮询。
    if (!(await this.validateSession(true))) {
      return;
    }
    await this.refresh(true);
    await this.consumePendingWidgetAction();
    this.startPolling();
    // 蓝牙钥匙自己武装：没资格、没证书、没绑定都会安静地停下，不打扰用户。
    this.bleController.start();
    await this.refreshBluetoothRuntime();
    await this.recoverBluetoothCredentialIfNeeded();
    // 车模型是静态的，拉一次即可；放最后不挡车况刷新。
    await this.loadCarModel();
  }

  /**
   * 演示态不发任何网络请求，控车只回一条提示。
   * 来源是审核用的演示账号，Release 也有（见 ReviewDemo）。
   */
  get isDemo(): boolean {
    return ReviewDemo.isActive;
  }

  /**
   * @param showSpinner 是否转下拉菊花（用户可见的刷新才转）。
   * @param refreshConfig 是否顺带重拉 commonConfig（充电上限 / 充电计划）。
   *   轮询默认 false 复用缓存；下拉/手动刷新传 true 重拉。换车走 selectVehicle，
   *   由 client 侧按 VIN 变化强制重拉，不依赖这个参数。
   */
  async refreshChargePlan(): Promise<boolean> {
    if (this.isDemo) { return true; }
    const vin = this.session.selectedVin;
    const account = this.session.oldAuth?.accountId;
    try {
      const plan = await this.client.refreshChargePlan();
      if (vin !== this.session.selectedVin || account !== this.session.oldAuth?.accountId) { return false; }
      const fresh = new VehicleState();
      fresh.signalMap = this.state?.signalMap ?? new Map<string, string>();
      fresh.schema = this.state?.schema ?? fresh.schema;
      fresh.collectedAt = this.state?.collectedAt ?? 0;
      fresh.isExtendRange = this.state?.isExtendRange ?? false;
      fresh.chargePlan = plan;
      fresh.chargePlanLimit = plan?.percent ?? null;
      this.state = fresh;
      return true;
    } catch (e) {
      if (vin === this.session.selectedVin && account === this.session.oldAuth?.accountId) {
        this.show('充电计划读取失败', '请稍后重试，暂未取得最新设置', true);
      }
      return false;
    }
  }

  async refresh(showSpinner: boolean = false, refreshConfig: boolean = false): Promise<void> {
    if (!this.isLoggedIn || this.isDemo) {
      return;
    }
    if (this.fetchInFlight) {
      // 撞上正在飞的请求，这一拍不能就这么丢：一次慢请求会把 5 秒的节奏拖成 10 秒、
      // 15 秒，而用户看到的还是「刚刚更新」。记下来，等在飞的那次落地了立刻补。
      this.refreshPending = true;
      return;
    }
    this.fetchInFlight = true;
    if (showSpinner) {
      this.isRefreshing = true;
    }
    try {
      // 只补一次。请求耗时长期超过轮询间隔时，无限补下去就成了连轴请求，
      // 白耗电换不来更新的数据——补完这一次就把节奏交还给定时器。
      let makeup = 1;
      do {
        this.refreshPending = false;
        await this.fetchState(refreshConfig);
      } while (this.refreshPending && makeup-- > 0 && this.isLoggedIn && !this.isDemo);
    } finally {
      this.isRefreshing = false;
      this.fetchInFlight = false;
      this.refreshPending = false;
    }
  }

  /** 拉一次车况并落地。调用方负责 `fetchInFlight` 与转菊花。 */
  private async fetchState(refreshConfig: boolean = false): Promise<void> {
    DiagLog.note(`[session] 车辆数=${this.session.vehicles.length}`
      + ` selectedVin=${DiagLog.maskVin(this.session.selectedVin)}`
      + ` selectedCarType=${this.session.selectedCarType.length === 0 ? '(空)' : this.session.selectedCarType}`
      + ` route=${this.session.route !== null ? this.session.route.appRegion : 'null'}`);
    try {
      // 本会话首次、或车辆列表为空、或任一车能力码是老会话兜出来的默认值（abilitiesStale），
      // 都强制重拉一次 vehicle/list 把 abilities→isExtendRange 刷到最新。否则升级用户持久化的
      // 旧车列表非空、又缺 isExtendRange，增程会被永久误判成纯电、油量整块消失，永不自愈。
      // 刷新成功后 didLoadVehiclesThisLaunch 置真，之后轮询照旧跳过，不额外打接口。
      // 哨兵支持位（isSentinelSupported）和增程能力码各判各的字段，老会话可能缺任一个，
      // 缺哪个就得重拉一次把对应清单补回来，所以两份 stale 一并纳入重拉门。
      const abilitiesStale: boolean =
        this.session.vehicles.some((v: Vehicle) => v.abilitiesStale === true)
        || this.session.vehicles.some((v: Vehicle) => v.sentinelStale === true);
      if (this.session.vehicles.length === 0 || !this.didLoadVehiclesThisLaunch || abilitiesStale) {
        await this.client.loadVehicles();
        this.didLoadVehiclesThisLaunch = true;
        this.syncSession();
      }
      const fresh = await this.client.fetchVehicleState(refreshConfig);
      this.state = fresh;
      // 车辆资料里的蓝牙地址只进诊断日志的抬头，用来和实际连上的那台设备对一眼。
      const bluetoothAddress = fresh.signalMap.get('bluetoothAddr');
      this.bleController.configureVehicleBluetoothAddress(
        bluetoothAddress === undefined ? '' : bluetoothAddress);
      this.markUpdated(fresh);
      this.syncDraftsFromState(fresh);
      this.syncSession();
      await this.resolveLocationName();
      this.publishSnapshot();
    } catch (error) {
      this.showError(error as Error);
    }
  }

  /**
   * 车况落地时把两个时间一起记下：本机什么时候拉的，车端什么时候采的。
   * 车端那个拿不到就置 0，界面自己会退回本机时间并改口径。
   */
  private markUpdated(state: VehicleState): void {
    this.lastUpdated = Date.now();
    this.reportedAt = state.reportedAt ?? 0;
  }

  /** 快照该标成什么时候的：车端报了就用车端的，没报才退回本机拉取时刻。 */
  private snapshotTime(): number {
    if (this.reportedAt > 0) {
      return this.reportedAt;
    }
    return this.lastUpdated > 0 ? this.lastUpdated : Date.now();
  }

  /**
   * 把展示用的车况写进共享文件，供服务卡片读取。
   * 只写非敏感字段——token 和操作密码始终在关键资产里。
   */
  private publishSnapshot(): void {
    const state = this.state;
    if (state === null) {
      return;
    }
    // 2D 车图跟着车况走（开门、充电），车况一落地就重排一次图层。
    this.refreshCarLayers();
    // 卡片上那句「刚刚 / 几分钟前」和「数据已过期」的判定都吃这个时间，同样以车端
    // 采集时刻为准：本机拉得再勤，车没上报就是没上报，卡片不该替它说是新的。
    SnapshotStore.write(SnapshotUtil.make(
      state, this.vehicleName,
      this.locationName.length > 0 ? this.locationName : null,
      this.snapshotTime()
    ));
    this.reloadWidgets();
    // 4×4 卡片上那张车图得在主应用这边拍平——首页是几张 Image 现叠的，
    // 卡片进程读不到沙箱、也解不动七八张大图。合成是异步的，出好之后再推一次，
    // 卡片上的车才跟得上门开、插枪这些变化。
    this.refreshCardCar();
  }

  /**
   * 3D 渲染器截来的车图，**只给服务卡片用**。
   *
   * 3D 车的资源包里根本没有 2D 图层，`carLayerDirectory` 一直是空串，
   * `refreshCardCar()` 那条路一次都跑不了——卡片上的车图因此始终是空的，
   * 桌面上只剩剪影。首页不用这张：那儿有现渲的 3D，比截图新鲜。
   */
  adoptRenderedCarImage(dataURL: string): void {
    if (!this.isLoggedIn || this.isDemo || !this.showCarModel) {
      return;
    }
    CarSnapshot.adoptRendered(dataURL).then((path: string) => {
      if (path.length > 0) {
        this.reloadWidgets();
      }
    });
  }

  /** 车况变了才重新出图。CarSnapshot 内部按图层方案去重，这里不必再判一次。 */
  private async refreshCardCar(): Promise<void> {
    const path = await CarSnapshot.render(this.carLayerDirectory, this.carLayerPlan);
    if (path.length > 0) {
      this.reloadWidgets();
    }
  }

  /**
   * 通知桌面上所有本应用的卡片重新渲染。
   *
   * 卡片进程和主应用是两个 Ability，共享的是沙箱里那份快照文件；
   * 真正的推送在 LeapFormAbility 侧按 formId 调 `formProvider.updateForm`，
   * 这里只负责把「快照已更新」这件事登记下来。
   */
  private reloadWidgets(): void {
    FormPusher.pushAll();
  }

  /**
   * 把坐标换成「杭州市滨江区江陵路」这类地址，失败时不显示任何回退坐标。
   * 五秒一次的轮询里，车没动就不重复解析。
   */
  async resolveLocationName(): Promise<void> {
    const coordinate = this.coordinate;
    if (coordinate === null) {
      this.locationName = '';
      return;
    }
    const name = await LocationNaming.nameReusing(coordinate, SnapshotStore.read());
    if (name !== null) {
      this.locationName = name;
    }
  }

  /** 拉里程能耗统计。演示模式给演示数据；真机三个接口并发拉，失败的块置 null。 */
  async loadDrivingStats(): Promise<DrivingStats | null> {
    if (this.isDemo) {
      return ReviewDemo.drivingStats();
    }
    try {
      return await this.client.fetchDrivingStats();
    } catch (e) {
      return null;
    }
  }

  /**
   * 拉某一周的能耗构成（点周柱子时按周调）。
   * 演示模式给一份跟着周变的假数据——六根柱子点下去数字纹丝不动，看着就像点坏了。
   */
  async loadEnergyDistribution(range: DrivingStatsRange): Promise<EnergyDistribution | null> {
    if (this.isDemo) {
      return ReviewDemo.energyDistribution(range);
    }
    try {
      return await this.client.fetchEnergyDistribution(range);
    } catch (e) {
      return null;
    }
  }

  /**
   * 车况回来后把本地草稿对齐。
   *
   * 只在空调**开着**的时候对齐：这时车端是权威的，界面该显示车里真实在跑的设定。
   * 空调关着时车端上报的模式/温度是上一次运行留下的残留值，拿它覆盖草稿，
   * 界面就会每次都落回上一次的档位，而且五秒一次的轮询会把用户刚选好的设定反复冲掉。
   */
  private syncDraftsFromState(state: VehicleState): void {
    const limit = state.chargeLimit;
    if (limit !== null && limit > 0) {
      this.chargeLimitDraft = limit;
    }
    this.clearCabinDraftsIfSettled();
    // 哨兵草稿以车况为准对齐，但下发中 / 密码挑战未回时不许回冲——那期间车况还是旧值，
    // 会把乐观翻转的开关弹回去。空调靠 climateEditedAt 挡这一下，哨兵没有温度草稿、判据也简单：
    // 只要没有在途指令（isSendingCommand 覆盖 dispatch+确认窗口，pendingCommand 覆盖密码挑战窗口）
    // 就对齐。放在空调那道 freshness 门之前：哨兵和空调各管各的，不该被对方的编辑窗口连带冻住。
    if (!this.isSendingCommand && this.pendingCommand === null) {
      this.sentinelOn = state.sentinelOn;
    }
    // 用户刚动过、或者指令还在路上时，车况里还是旧值，回冲草稿等于把刚调的弹回去。
    if (this.isClimateDraftFresh || this.isSendingCommand || this.climatePushQueued) {
      return;
    }
    this.isSyncingClimateDrafts = true;
    this.climateOn = state.acOn;
    if (!state.acOn) {
      this.isSyncingClimateDrafts = false;
      return;
    }
    const temperature = state.acSetting;
    if (temperature !== null) {
      this.setClimateTemperature(temperature);
    }
    const fan = state.acFanLevel;
    if (fan !== null && fan > 0) {
      this.setClimateFanLevel(Math.min(7, fan));
    }
    // 车端没上报模式就别动草稿。硬对齐会把用户刚选的「制冷」冲成「自动」，
    // 而且五秒一次的轮询会反复冲。原始值各车型编码不同套，交给 state 去解释。
    const mode = state.climateMode;
    if (mode !== null) {
      this.setClimateMode(mode);
    }
    const circle = state.acCircleIn;
    if (circle !== null) {
      this.setClimateCircleIn(circle);
    }
    this.isSyncingClimateDrafts = false;
    // 车况是车自己报的，对齐完这份就是车确认知道的设定。
    this.confirmedClimate = this.currentClimate();
  }

  private get isClimateDraftFresh(): boolean {
    if (this.climateEditedAt === 0) {
      return false;
    }
    return Date.now() - this.climateEditedAt < VehicleStore.climateEditGrace;
  }

  private noteClimateEdit(): void {
    if (this.isSyncingClimateDrafts) {
      return;
    }
    this.climateEditedAt = Date.now();
  }

  private currentClimate(): ClimateSettings {
    return {
      on: this.climateOn,
      temperature: this.climateTemperature,
      fanLevel: this.climateFanLevel,
      mode: this.climateMode,
      circleIn: this.climateCircleIn
    };
  }

  private rollbackClimateDraft(): void {
    const settings = this.confirmedClimate;
    if (settings === null) {
      return;
    }
    this.isSyncingClimateDrafts = true;
    this.climateOn = settings.on;
    this.climateTemperature = settings.temperature;
    this.climateFanLevel = settings.fanLevel;
    this.climateMode = settings.mode;
    this.climateCircleIn = settings.circleIn;
    this.isSyncingClimateDrafts = false;
  }

  // MARK: - 草稿写入（等价于 iOS 属性的 didSet）

  setClimateTemperature(value: number): void {
    this.climateTemperature = value;
    ClimateDraft.temperature = value;
    this.noteClimateEdit();
  }

  setClimateFanLevel(value: number): void {
    this.climateFanLevel = value;
    ClimateDraft.fanLevel = value;
    this.noteClimateEdit();
  }

  setClimateMode(value: ClimateMode): void {
    this.climateMode = value;
    ClimateDraft.mode = value;
    this.noteClimateEdit();
  }

  setClimateCircleIn(value: boolean): void {
    this.climateCircleIn = value;
    ClimateDraft.circleIn = value;
    this.noteClimateEdit();
  }

  // MARK: - 登录

  async sendSMS(phone: string): Promise<boolean> {
    // 演示账号不走短信通道：这个号码在零跑那边并不存在，真发只会拿到一个错误。
    if (phone === ReviewDemo.phone) {
      this.show(`演示账号无需验证码`, `验证码填 ${ReviewDemo.code}`);
      return true;
    }
    try {
      await this.client.sendSMS(phone);
      this.show('验证码已发送');
      return true;
    } catch (error) {
      this.showError(error as Error);
      return false;
    }
  }

  async login(phone: string, code: string): Promise<boolean> {
    if (ReviewDemo.matches(phone, code)) {
      await this.enterDemo();
      return true;
    }
    try {
      DiagLog.note('[login] 开始短信登录');
      await this.client.login(phone, code);
      this.syncSession();
      DiagLog.note(`[login] 会话已建立 isLoggedIn=${this.isLoggedIn}`);
      try {
        await this.client.loadVehicles();
      } catch (e) {
        // 车辆列表拉不到不挡登录，刷新时还会再试一次。
      }
      this.syncSession();
      await this.refresh(true);
      // 从卡片点进来但当时还没登录，动作一直留着，这时接手。
      await this.consumePendingWidgetAction();
      this.startPolling();
      this.show('登录成功');
      // 登录进来的这条路不经过 bootstrap，车模型得在这里拉一次。
      await this.loadCarModel();
      return true;
    } catch (error) {
      // 失败也要把 client 那边的会话同步过来。client.login() 失败时已经把自己退回
      // 干净态了，界面这份要是还停在旧值，两边就又不一致了。
      this.syncSession();
      this.showError(error as Error);
      return false;
    }
  }

  /** 进入演示态：装载写死的车况，不建立任何会话，也不启动轮询。 */
  private async enterDemo(): Promise<void> {
    ReviewDemo.isActive = true;
    this.session = ReviewDemo.session();
    const demoState = ReviewDemo.vehicleState();
    this.state = demoState;
    this.markUpdated(demoState);
    this.syncDraftsFromState(demoState);
    await this.resolveLocationName();
    this.publishSnapshot();
    this.show('已进入演示模式', '数据为模拟，不会控制真实车辆');
  }

  async logout(): Promise<void> {
    ReviewDemo.isActive = false;
    this.loginEpoch++;
    this.stopPolling();
    this.endForegroundVerification();
    await this.client.logout();
    await this.passwordStore.clear();
    this.setSavedPasswordFlag(false);
    // 退出后卡片不能继续显示上一位用户的车况。
    SnapshotStore.clear();
    this.reloadWidgets();
    this.syncSession();
    this.state = null;
    this.lastUpdated = 0;
    this.reportedAt = 0;
    this.locationName = '';
    // 车图也得清：VehicleStore 随进程活着，不清的话换账号登录后
    // 首页会先渲上一位用户那台车。
    this.unloadCarModel();
    // 蓝牙绑定同样是这位用户的。留着的话下一位用户登录后，
    // 手机会带着上一个账号的证书去连那台车。
    await this.bleController.deactivate(true);
  }

  async resetSession(): Promise<void> {
    this.loginEpoch++;
    this.stopPolling();
    this.endForegroundVerification();
    await this.client.resetSession();
    await this.passwordStore.clear();
    this.setSavedPasswordFlag(false);
    this.syncSession();
    this.state = null;
    this.lastUpdated = 0;
    this.reportedAt = 0;
    this.unloadCarModel();
    await this.bleController.deactivate(true);
    this.show('会话已重置');
  }

  async selectVehicle(vehicle: Vehicle): Promise<void> {
    await this.client.selectVehicle(vehicle.vin, vehicle.carType);
    this.syncSession();
    this.state = null;
    // 换车了，上一台的车图/3D 资源不能再用。
    this.unloadCarModel();
    await this.refresh(true);
    // 蓝牙证书和绑定都是一车一份，换车之后手上那份属于上一台。
    await this.refreshBluetoothRuntime();
    await this.loadCarModel();
  }

  async forgetPassword(): Promise<void> {
    await this.passwordStore.clear();
    this.setSavedPasswordFlag(false);
    this.show('已忘记操作密码');
  }

  /**
   * 「本机存过操作密码」这件事要同时落到共享设置里。
   *
   * 卡片进程读不了关键资产（异步接口，卡片要当场返回绑定数据等不了），只能靠这个
   * 标记决定按钮是直发还是打开 App。所有改动都必须走这里，漏一处就会出现
   * 卡片以为有密码、实际发不出去的情况。
   */
  private setSavedPasswordFlag(value: boolean): void {
    this.hasSavedPassword = value;
    WidgetSettings.hasSavedPassword = value;
  }

  // MARK: - 车模型

  /** 拉车模型。资源准备在 CarModelAssets 里，这里只负责状态流转。 */
  async loadCarModel(): Promise<void> {
    if (!this.isLoggedIn || this.isDemo || !this.showCarModel) {
      return;
    }
    const vin = this.session.selectedVin;
    if (vin.length === 0) {
      return;
    }
    try {
      const model = await this.client.fetchCarModel();
      // 下载途中用户可能把「显示车模型」关掉了，每次 await 回来都要再看一眼。
      if (!this.showCarModel) {
        return;
      }
      this.carModel = model;
      if (model === null) {
        return;
      }

      const download = (key: string): Promise<ArrayBuffer> => this.client.fetchCarModelPackage(key);
      // 下载十几兆的包期间界面上要有个说法，不然用户只看到剪影一直不变。
      this.is3DDownloading = !CarModelAssets.isReady(vin) && !CarModelAssets.areLayersReady(vin);
      try {
        if (model.has3DPackages) {
          const root = await CarModelAssets.prepare(vin, model, download);
          if (!this.showCarModel) {
            return;
          }
          // 别名要在设 root 之前推出来：root 一变 3D 组件就重建并立刻 newInit，
          // 那时 alias 还是空的话，第一帧仍然按 carType 拼路径。
          const param = model.modelParam;
          this.carAssetAlias = param === null
            ? null
            : CarModelAssets.assetAlias(root, param.carTypeCode);
          this.client.rememberCarAlias(this.carAssetAlias);
          this.carModelRoot = root;
          // 3D 车型也把包里那套 2D 图层认下来：包里两套都有，原来走这条分支时
          // 从没试过取图层。首页照旧渲 3D，只是加载期间垫的不再是剪影而是真车图，
          // 4×4 卡片上那张车图也才有得可拍——卡片里跑不了 3D。
          if (this.carLayerDirectory.length === 0) {
            this.carLayerDirectory = CarLayerComposer.layerDirectory(root) ?? '';
            this.refreshCarLayers();
          }
        } else {
          // 没有 3D 的车型走分层贴图。图层包和 3D 包解在同一个目录，
          // 所以两条路径不会互相覆盖——一台车只会走其中一条。
          const root = await CarModelAssets.prepareLayers(vin, model, download);
          if (!this.showCarModel) {
            return;
          }
          this.carLayerDirectory = CarLayerComposer.layerDirectory(root) ?? '';
          this.refreshCarLayers();
        }
      } finally {
        this.is3DDownloading = false;
      }
    } catch (error) {
      // 拿不到就保持剪影，不打扰用户。
      DiagLog.note(`[carmodel] 失败：${LeapError.messageOf(error as object)}`);
    }
  }

  /**
   * 渲染器把资源加载不下去时的自愈：作废这台车的包，重下一次。
   *
   * `isReady` 查不出车型子目录缺了哪张贴图、哪张显隐表——文件名跟着车型走，
   * 只有渲染器自己知道要什么。缺文件的包照样带着 `.ready`，不作废就永远
   * 卡在同一份坏包上。
   *
   * 一台车只自愈一次：包要是在服务端那头就是缺的，重下多少遍都一样，
   * 每次进首页都白拉十几兆流量。
   */
  async repairCarModel(): Promise<void> {
    const vin = this.session.selectedVin;
    if (vin.length === 0 || this.repairedModelVin === vin) {
      return;
    }
    this.repairedModelVin = vin;
    DiagLog.note('[carmodel] 渲染失败，作废资源重下一次');
    CarModelAssets.invalidate(vin);
    // 置空会触发首页把就绪/失败位清掉，新资源到位后才有机会再渲一次。
    this.carModelRoot = '';
    await this.loadCarModel();
  }

  /**
   * 按当前车况重排图层。方案一样就原样留着——
   * 每次轮询都换一份新数组的话，充电动画会被打断、每五秒跳回第一帧。
   */
  private refreshCarLayers(): void {
    if (this.carLayerDirectory.length === 0) {
      return;
    }
    const next = CarLayerComposer.plan(this.state, this.session.selectedCarType);
    if (next.signature === this.carLayerPlan.signature) {
      return;
    }
    this.carLayerPlan = next;
  }

  /**
   * 清掉内存里的车图和 3D 资源引用，首页立刻回到剪影。
   * 磁盘上已下载的资源留着，按 VIN 分目录，回来时不用再下一遍。
   */
  private unloadCarModel(): void {
    // 卡片那份也得清，否则桌面上会一直挂着上一台车（或上一位用户的车）。
    CarSnapshot.clear();
    this.carLayerDirectory = '';
    this.carLayerPlan = new LayerPlan();
    this.carModel = null;
    this.carModelRoot = '';
    this.carAssetAlias = null;
    this.is3DDownloading = false;
    // 桌面上那张也得当场退回剪影：卡片是被动接收的，不推一次的话它会一直
    // 停在上一次推过去的车图上，直到下一轮车况回来。
    this.reloadWidgets();
  }

  // MARK: - 卡片动作

  /** 卡片按钮在未开启「直接控车」时会把动作交回 App，这里接手并走完整验证流程。 */
  async consumePendingWidgetAction(): Promise<void> {
    const raw = WidgetSettings.pendingAction;
    if (raw.length === 0) {
      return;
    }
    // 卡片深链唤起 App 时可能早于 bootstrap 拿到 session。
    // 这时不能把动作吃掉——先留着，等 bootstrap 或登录完成后再来一次。
    if (!this.isLoggedIn) {
      return;
    }
    WidgetSettings.pendingAction = '';
    switch (raw) {
      case WidgetAction.toggleLock:
        await this.toggleLock();
        break;
      case WidgetAction.lock:
        await this.perform(LeapCommand.lock());
        break;
      case WidgetAction.unlock:
        await this.perform(LeapCommand.unlock());
        break;
      case WidgetAction.toggleClimate:
        await this.applyClimate(!this.climateOn);
        break;
      case WidgetAction.trunk:
        await this.toggleTrunk();
        break;
      case WidgetAction.horn:
        await this.honk();
        break;
      default:
        break;
    }
  }

  // MARK: - 车型标定

  /** 这台车还没适配上的标定项。为空说明该认的字段都认全了，设置页里就不必出现标定入口。 */
  get pendingCalibrationTasks(): CalibrationTask[] {
    const state = this.state;
    if (state === null) {
      return [];
    }
    return CalibrationTasks.all.filter((task: CalibrationTask) => state.schema.key(task.signal) === null);
  }

  /**
   * 标定用：绕开轮询和 fetchInFlight 直接取一份最新车况。
   * 标定要自己控制采样节奏——用户点「我做好了」之后得连着刷几次等车上报。
   */
  async captureSignalMap(): Promise<Map<string, string> | null> {
    if (this.isDemo) {
      return null;
    }
    try {
      const state = await this.client.fetchVehicleState();
      return state.signalMap;
    } catch (e) {
      return null;
    }
  }

  /** 标定结果落地，并立刻用新映射重解析一次——用户做完就该看见自己车的门窗锁。 */
  async applyCalibration(learned: Map<VehicleSignal, string>): Promise<void> {
    if (learned.size === 0) {
      return;
    }
    LearnedSignals.save(learned, this.session.selectedCarType);
    this.state = null;
    await this.refresh(true);
    this.show(`已适配 ${learned.size} 项车况`);
  }

  /** 忘掉本机标定结果，回到内置映射表。 */
  async resetCalibration(): Promise<void> {
    LearnedSignals.clear(this.session.selectedCarType);
    this.state = null;
    await this.refresh(true);
    this.show('已清除本机标定结果');
  }

  // MARK: - 控车

  /** 统一入口：所有会真正动车的指令都从这里走确认流程。 */
  async perform(command: LeapCommand): Promise<void> {
    if (this.isSendingCommand) {
      return;
    }
    if (this.isDemo) {
      this.show(`${command.label}指令已发送`, '演示模式');
      return;
    }
    this.pendingCommand = command;

    if (!command.requiresOperationPassword) {
      await this.dispatch(command, '');
      return;
    }

    // 这次前台已经验证过了，不再打断。回到后台会作废。
    if (this.verifiedPassword.length > 0) {
      await this.dispatch(command, this.verifiedPassword);
      return;
    }

    // 已保存密码 + 生物识别可用：解锁本地密码，不打断操作。
    if (this.biometricEnabled && this.biometricKind !== BiometricKind.none) {
      const saved = await this.passwordStore.read();
      if (saved !== null && saved.length > 0) {
        const ok = await BiometricGate.authenticate(`验证身份以${command.label}`);
        if (ok) {
          this.verifiedPassword = saved;
          await this.dispatch(command, saved);
        } else {
          // 识别失败不静默丢弃指令，回退到手输密码。
          this.challenge = { prompt: command.label };
        }
        return;
      }
    }

    this.challenge = { prompt: command.label };
  }

  /** 退到后台时作废本次验证，下次控车要重新过生物识别或密码。 */
  endForegroundVerification(): void {
    this.verifiedPassword = '';
  }

  /** 用户在密码键盘上输满后调用。 */
  async submitOperationPassword(password: string, remember: boolean): Promise<void> {
    this.challenge = null;
    // 充电计划保存的批量指令优先——一次密码覆盖整批。
    const batch = this.pendingChargeBatch;
    const command = this.pendingCommand;
    if (batch === null && command === null) {
      return;
    }
    if (remember) {
      const ok = await this.passwordStore.write(password);
      this.setSavedPasswordFlag(ok);
      if (!ok) {
        // 存不进关键资产就直说，别让用户以为记住了、下次又被要求手输。
        this.show('密码这次没能记住', '安全存储写入失败');
      }
    }
    // 不管记不记，这次前台内不再重复问。
    this.verifiedPassword = password;
    if (batch !== null) {
      this.pendingChargeBatch = null;
      await this.dispatchBatch(batch, password);
      return;
    }
    await this.dispatch(command!, password);
  }

  cancelChallenge(): void {
    const wasClimate = this.pendingCommand !== null && this.pendingCommand.changesClimate;
    this.challenge = null;
    this.pendingCommand = null;
    this.pendingChargeBatch = null;
    // 用户中途反悔，车没收到任何东西，界面不能停在新设定上，
    // 排队等着补发的那条也一起作废。
    if (wasClimate) {
      this.climatePushQueued = false;
      this.climateEditedAt = 0;
      this.rollbackClimateDraft();
    }
    // 座舱同理：用户在密码框上反悔，车什么都没收到，界面不能停在新档位上。
    // 连队列里排着的那几条（「全部关闭」一次压一批）一起作废。
    this.cancelPendingCabinPushes();
    this.cabinQueue = [];
    this.cabinDrafts = new Map<string, number>();
    this.mirrorHeatingDraft = null;
    this.fridgeDraft = null;
  }

  /**
   * 一次密码下发一批指令（眼下只有充电计划：480 + 190）。
   *
   * 和 `perform` 走的是同一套验证顺序（本次前台已验 → 生物识别 → 手输密码），
   * 只是密码拿到之后串行发整批，而不是发一条。
   */
  async performCharge(commands: LeapCommand[]): Promise<void> {
    if (this.isSendingCommand || commands.length === 0) {
      return;
    }
    if (this.isDemo) {
      this.show('充电计划已发送', '演示模式');
      return;
    }
    // 充电类指令不在行驶禁操作清单里，无需 driving 检查。
    const reason = '保存充电计划';
    if (this.verifiedPassword.length > 0) {
      await this.dispatchBatch(commands, this.verifiedPassword);
      return;
    }
    if (this.biometricEnabled && this.biometricKind !== BiometricKind.none) {
      const saved = await this.passwordStore.read();
      if (saved !== null && saved.length > 0) {
        const ok = await BiometricGate.authenticate(`验证身份以${reason}`);
        if (ok) {
          this.verifiedPassword = saved;
          await this.dispatchBatch(commands, saved);
        } else {
          // 识别失败不静默丢弃，回退到手输密码。
          this.pendingCommand = null;
          this.pendingChargeBatch = commands;
          this.challenge = { prompt: reason };
        }
        return;
      }
    }
    this.pendingCommand = null;
    this.pendingChargeBatch = commands;
    this.challenge = { prompt: reason };
  }

  /**
   * 顺序下发一批指令，逐条走完整的 `dispatch`（错误提示、诊断、刷新都在里面）。
   * 串行 await，`isSendingCommand` 在两条之间短暂翻假不影响——不会并发重入。
   */
  private async dispatchBatch(commands: LeapCommand[], password: string): Promise<void> {
    for (let i = 0; i < commands.length; i++) {
      await this.dispatch(commands[i], password);
    }
  }

  private async dispatch(command: LeapCommand, password: string): Promise<void> {
    this.isSendingCommand = true;
    this.retryableCommand = null;
    try {
      const receipt = await this.client.sendControl(command, password);
      this.lastReceipt = receipt;
      // 车已经收到了，这份设定就算数了。
      if (command.changesClimate) {
        this.confirmedClimate = this.currentClimate();
      }
      await this.confirm(command, receipt);
    } catch (error) {
      // 指令根本没发出去，界面得退回车知道的那份设定。
      if (command.changesClimate) {
        this.rollbackClimateDraft();
      }
      const message = LeapError.messageOf(error as object);
      DiagLog.note(`[control] ${command.label} 失败：${message}`);
      // 密码错误时清掉已保存的密码，否则会一直用错的重试。
      if (message.includes('密码')) {
        // 这条子串匹配很宽：本地那几个「该指令需要操作密码」「操作密码加密失败」
        // 也会撞上，把用户刚勾了「记住」存下的密码一并清掉，下次自然弹不出人脸。
        // 记一笔，出问题时能一眼看出是被哪条消息清的。
        DiagLog.note('[control] 消息里带「密码」，清掉已保存的操作密码');
        await this.passwordStore.clear();
        this.setSavedPasswordFlag(false);
        this.verifiedPassword = '';
      }
      this.setDiagnostic({
        label: command.label,
        cmdid: command.cmdid,
        msgID: '',
        sentAt: Date.now(),
        outcome: ControlOutcome.failed,
        elapsed: 0,
        pollCount: 0,
        receiptResponses: [],
        errorMessage: message
      });
      this.showError(error as Error);
    } finally {
      this.isSendingCommand = false;
      this.pendingCommand = null;
      await this.flushQueuedClimatePush();
      this.flushCabinQueue();
    }
  }

  /**
   * 下发后等车真的动作。
   *
   * 服务端是异步执行的，返回 200 只代表受理；实测车辆要 5–10 秒才响应，
   * 休眠时更久。所以这里**以车况为判据**——车自己报的状态才是真的，
   * 而回执接口的返回结构至今没有已验证样本。回执照查，但只攒样本进诊断，不参与判定。
   */
  private async confirm(command: LeapCommand, receipt: ControlReceipt): Promise<void> {
    const started = Date.now();
    const responses: ReceiptSample[] = [];
    let polls = 0;

    const sampleReceipt = async (): Promise<void> => {
      if (receipt.msgID.length === 0) {
        return;
      }
      try {
        const result: JsonValue = await this.client.queryControlResult(receipt.msgID);
        responses.push({ at: (Date.now() - started) / 1000, body: result.prettyPrinted });
      } catch (e) {
        // 回执查不到不影响判定，车况才是判据。
      }
    };

    const finish = (outcome: ControlOutcome): void => {
      this.setDiagnostic({
        label: command.label,
        cmdid: command.cmdid,
        msgID: receipt.msgID,
        sentAt: started,
        outcome: outcome,
        elapsed: (Date.now() - started) / 1000,
        pollCount: polls,
        receiptResponses: responses,
        errorMessage: null
      });
    };

    if (!command.expectation.isObservable) {
      // 鸣笛这类动作车况里查不到，等一轮刷新就如实说「已发送」，不假称已生效。
      this.show(`${command.label}指令已发送`);
      await VehicleStore.sleep(2000);
      await this.refresh(false);
      if (command.cmdid === '190') { await this.refreshChargePlan(); }
      // 预约空调没有车况信号可确认，下发完回读一次预约表，界面上那行「车上当前预约」
      // 就是确认——读回来对上了才算真的设进去了。
      if (command.cmdid === '171') { await this.refreshClimateAppointment(); }
      await sampleReceipt();
      polls = 1;
      finish(ControlOutcome.sentOnly);
      return;
    }

    this.confirmingLabel = command.label;
    this.show(`${command.label}指令已发送`, '等待车辆响应…', false, false,
      VehicleStore.confirmTimeoutMs / 1000);
    // 后台那个 5 秒轮询会占住 fetchInFlight，把这里的刷新直接跳过，先停掉。
    this.stopPolling();

    try {
      const deadline = started + VehicleStore.confirmTimeoutMs;
      while (Date.now() < deadline) {
        await VehicleStore.sleep(VehicleStore.pollStepMs);
        polls++;
        await this.refresh(false);
        await sampleReceipt();
        const state = this.state;
        if (state !== null && command.expectation.isSatisfied(state)) {
          if (!this.showLockReminder(command)) {
            this.show(VehicleStore.successText(command));
          }
          // 车况已经翻转了，这时候的回执才可能是终态值——最该留下的一份样本。
          await sampleReceipt();
          finish(ControlOutcome.confirmed);
          return;
        }
      }

      // 窗口内没等到。不自动重发——尾门、鸣笛重发会真的再动一次车。
      this.retryableCommand = command;
      this.show(`${command.label}未收到车辆确认`, '车可能仍在唤醒，可稍后重试', true, true, 10);
      finish(ControlOutcome.timedOut);
    } finally {
      this.confirmingLabel = '';
      this.startPolling();
    }
  }

  private static successText(command: LeapCommand): string {
    switch (command.expectation.kind) {
      case ExpectationKind.locked:
        return command.expectation.boolValue ? '车辆已上锁' : '车辆已解锁';
      case ExpectationKind.climate:
        return command.expectation.climateOn ? '空调已开启' : '空调已关闭';
      case ExpectationKind.windowPosition:
        return '车窗已调整';
      case ExpectationKind.trunkOpen:
        return '尾门已打开';
      case ExpectationKind.sentinel:
        return command.expectation.boolValue ? '哨兵已开启' : '哨兵已关闭';
      case ExpectationKind.frontTrunkOpen:
        return command.expectation.boolValue ? '前备箱已打开' : '前备箱已关闭';
      case ExpectationKind.sunshadeOpen:
        return command.expectation.boolValue ? '遮阳帘已打开' : '遮阳帘已关闭';
      case ExpectationKind.sunroofOpen:
        return command.expectation.boolValue ? '天窗已打开' : '天窗已关闭';
      case ExpectationKind.charging:
        return command.expectation.boolValue ? '已开始充电' : '已停止充电';
      // 这几条的 label 本身就把位置和档位说全了（「主驾加热 2 档」），再套一层话术反而更绕。
      case ExpectationKind.seatLevel:
      case ExpectationKind.steeringWheelLevel:
        return `${command.label}已生效`;
      case ExpectationKind.mirrorHeating:
        return command.expectation.boolValue ? '后视镜加热已开启' : '后视镜加热已关闭';
      case ExpectationKind.fridge:
        return command.expectation.boolValue ? `${command.label}已生效` : '车载冰箱已关闭';
      default:
        return `${command.label}已完成`;
    }
  }

  /**
   * 锁车成功但还有东西开着时，把成功提示换成一句提醒（leapauto 的「锁车后检查」，同 iOS `lockReminder`）。
   *
   * 用的是确认轮询刚刷回来的那份车况，不额外发请求。只看读得到的项，见 `VehicleState.openItemsAfterLock`。
   * 锁本身是成功的，所以文案先说「已上锁」；用告警样式和多停几秒，是因为这句是要人回去处理的。
   * 返回有没有显示提醒。
   */
  private showLockReminder(command: LeapCommand): boolean {
    if (command.expectation.kind !== ExpectationKind.locked || !command.expectation.boolValue) {
      return false;
    }
    const items = this.state?.openItemsAfterLock ?? [];
    if (items.length === 0) {
      return false;
    }
    this.show('车辆已上锁', `${items.join('、')}还开着`, true, false, 6);
    return true;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private setDiagnostic(diagnostic: ControlDiagnostic): void {
    this.lastDiagnostic = diagnostic;
    ControlDiagnosticStore.save(diagnostic);
  }

  /** 超时提示上的重试。走完整的 perform 流程，该验身份还是要验。 */
  async retryLastCommand(): Promise<void> {
    const command = this.retryableCommand;
    if (command === null) {
      return;
    }
    this.retryableCommand = null;
    this.toast = null;
    await this.perform(command);
  }

  // MARK: - 具体动作

  async toggleLock(): Promise<void> {
    const locked = this.state !== null ? (this.state.isLocked ?? true) : true;
    await this.perform(locked ? LeapCommand.unlock() : LeapCommand.lock());
  }

  /** 首页控车条的「上锁」「解锁」两格：方向写在按钮上，不看车况猜。 */
  async lockCar(): Promise<void> {
    await this.perform(LeapCommand.lock());
  }

  async unlockCar(): Promise<void> {
    await this.perform(LeapCommand.unlock());
  }

  /**
   * 尾门开着就发关闭，否则发打开。读不到状态时按「开」走——
   * 这是原来唯一的行为，未适配的车型不该因为这次改动变得更奇怪。
   *
   * 控车条上的尾门按钮已经改成先开半屏、由用户挑开还是关（见 `TrunkControlSheet`），
   * 这条只剩卡片/快捷方式那条路径在用——那边没有界面可弹，只能替用户判一次方向。
   */
  async toggleTrunk(): Promise<void> {
    // 关不了的车型（S01 / T03）只发得出「打开」。尾门开着时照着反转发一条关闭，
    // 车根本不会理，用户看到的是「按了卡片什么都没发生」。
    if (!LeapCommand.trunkSupportsClose(this.session.selectedCarType)) {
      await this.setTrunk(true);
      return;
    }
    const open = this.state !== null ? (this.state.trunkOpen ?? false) : false;
    await this.setTrunk(!open);
  }

  /** 明确开或关，方向由调用方给定。 */
  async setTrunk(open: boolean): Promise<void> {
    await this.perform(LeapCommand.trunk(open));
  }

  /**
   * 遮阳帘 / 天窗 / 前备箱。方向都由半屏里的用户点击给定（见 `TwoStateControlSheet`），
   * 照 setTrunk 一行透传、没有本地草稿。
   * 车报着开度就等信号翻转确认，不报就照旧只说「已发送」（见 `LeapCommand.sunshade` 的说明）。
   */
  async setSunshade(open: boolean): Promise<void> {
    const observable = this.state !== null && this.state.sunshadeOpen !== null;
    await this.perform(LeapCommand.sunshade(open, observable));
  }

  async setSunroof(open: boolean): Promise<void> {
    const observable = this.state !== null && this.state.sunroofOpen !== null;
    await this.perform(LeapCommand.sunroof(open, observable));
  }

  /** 远程开始 / 停止充电。按钮只在插着枪时出现（见 `ChargeView`），这里不重复判。 */
  async setCharging(start: boolean): Promise<void> {
    await this.perform(LeapCommand.charging(start));
  }

  async unlockChargingGun(): Promise<void> {
    await this.perform(LeapCommand.unlockChargingGun());
  }

  async setFrunk(open: boolean): Promise<void> {
    await this.perform(LeapCommand.frunk(open));
  }

  async honk(): Promise<void> {
    await this.perform(LeapCommand.horn());
  }

  async preheatBattery(): Promise<void> {
    await this.perform(LeapCommand.batteryPreheat(true));
  }

  async stopBatteryPreheat(): Promise<void> {
    await this.perform(LeapCommand.batteryPreheat(false));
  }

  /**
   * 预约电池预热（cmdid 161）。
   *
   * `days` 用预约类共用编码（0 = 周日、1 = 周一 … 6 = 周六，见 `AppointmentWeekday`），
   * 空数组表示只热这一次。
   * set_id 实测格式是「前缀_VIN_创建毫秒」，VIN 从当前选中车取（见 `batteryPreheatAppointment`）。
   */
  async scheduleBatteryPreheat(at: Date, enabled: boolean,
    days: number[] = [1, 2, 3, 4, 5]): Promise<void> {
    await this.perform(LeapCommand.batteryPreheatAppointment(
      enabled, at, days, this.session.selectedVin));
  }

  /**
   * 保存充电计划：充电上限 + 预约充电走 cmdid 190；这次动过健康充电开关才连发 480。
   *
   * `healthyChargeOn` 传 null 表示用户没碰过那个开关——不能拿界面上的当前值回发，
   * 那会把车上原本的设置按界面初值覆盖一遍。
   */
  async saveChargePlan(limitPercent: number, scheduledEnabled: boolean,
    startTime: string, endTime: string, cycles: boolean[],
    circulation: number, recharge: number, healthyChargeOn: boolean | null): Promise<void> {
    const commands: LeapCommand[] = [];
    // 先发健康充电：它决定上限封顶，先落定约束再发上限更稳妥。
    if (healthyChargeOn !== null) {
      commands.push(LeapCommand.healthyCharge(healthyChargeOn));
    }
    commands.push(LeapCommand.chargePlan(limitPercent, scheduledEnabled,
      startTime, endTime, cycles, circulation, recharge));
    await this.performCharge(commands);
  }

  /**
   * 拉最近一张驻车照片，连图片二进制一起返回。
   *
   * 接口只给地址，图要另外下一次；地址为空时返回 null 的那份，界面按「暂无照片」显示，
   * 不许拿占位图顶。
   */
  async loadParkingPhoto(): Promise<ParkingPhotoResult> {
    if (this.isDemo) {
      throw LeapError.server('演示模式没有驻车照片');
    }
    const photo = await this.client.fetchParkingPhoto();
    const url = photo.url;
    if (url === null) {
      return { photo: photo, data: null };
    }
    return { photo: photo, data: await this.client.downloadParkingPhoto(url) };
  }

  /** `openness` 是开度百分比：0 关闭、100 全开。 */
  async applyWindows(openness: number): Promise<void> {
    await this.perform(LeapCommand.window(openness, this.session.selectedCarType));
  }

  async applyClimate(on: boolean): Promise<void> {
    this.climateOn = on;
    this.noteClimateEdit();
    await this.perform(LeapCommand.climate(
      on, this.climateTemperature, this.climateFanLevel,
      this.climateMode, this.climateCircleIn, false
    ));
  }

  /**
   * 哨兵开 / 关。仿 applyClimate：先乐观翻转草稿给即时反馈，再走 perform 的完整流程
   * （受权控命令，需操作密码），下发后由 confirm() 轮询车况直到 sentinelOn 达成。
   */
  async applySentinel(on: boolean): Promise<void> {
    this.sentinelOn = on;
    await this.perform(LeapCommand.sentinel(on));
  }

  /** 空调已开时改参数才即时下发，关着的时候只改本地草稿。 */
  async pushClimateIfRunning(): Promise<void> {
    if (!this.climateOn) {
      return;
    }
    // 上一条还在等车确认——那是个最长几十秒的窗口，perform 会把这条直接丢掉，
    // 用户就得再按一次，反馈出来正是「每次都要按两次」。记下来，等这条完事补发最新的。
    if (this.isSendingCommand) {
      this.climatePushQueued = true;
      return;
    }
    await this.applyClimate(true);
  }

  /** 补发那条被压下的空调指令，用的是用户最后调到的值。 */
  private async flushQueuedClimatePush(): Promise<void> {
    if (!this.climatePushQueued) {
      return;
    }
    this.climatePushQueued = false;
    if (!this.climateOn || this.isDemo) {
      return;
    }
    await this.pushClimateIfRunning();
  }

  async quickCool(): Promise<void> {
    this.climateOn = true;
    this.setClimateMode(ClimateMode.cold);
    this.setClimateTemperature(18);
    this.setClimateFanLevel(7);
    await this.perform(LeapCommand.quickCool());
  }

  async quickHeat(): Promise<void> {
    this.climateOn = true;
    this.setClimateMode(ClimateMode.hot);
    this.setClimateTemperature(32);
    this.setClimateFanLevel(7);
    await this.perform(LeapCommand.quickHeat());
  }

  async defrost(): Promise<void> {
    this.climateOn = true;
    await this.perform(LeapCommand.defrost());
  }

  /**
   * 快速除味：通风 + 外循环 + 7 档。草稿跟着改，免得页面上还停在原来的制冷 / 内循环。
   * 温度草稿不动：通风模式下温度不起作用，车端会不会改设定温度也没验过，等车况回来再同步。
   */
  async deodorize(): Promise<void> {
    this.climateOn = true;
    this.setClimateMode(ClimateMode.vent);
    this.setClimateFanLevel(7);
    this.setClimateCircleIn(false);
    await this.perform(LeapCommand.deodorize());
  }

  // MARK: - 预约空调

  async refreshClimateAppointment(): Promise<void> {
    if (this.isDemo) {
      this.climateAppointmentReadback = AppointmentReadback.empty();
      return;
    }
    // 已经有结果时不把界面闪回「读取中」，只在第一次读时给转圈。
    if (this.climateAppointmentReadback === null) {
      this.climateAppointmentReadback = AppointmentReadback.loading();
    }
    try {
      const controls = await this.client.fetchAppointmentControls('171');
      const parsed = ClimateAppointment.parse(controls);
      this.climateAppointmentReadback = parsed !== null
        ? AppointmentReadback.loaded(parsed) : AppointmentReadback.empty();
    } catch (error) {
      this.climateAppointmentReadback = AppointmentReadback.failed(LeapError.messageOf(error as object));
    }
  }

  /** 保存预约。改的是车上已有的那条时沿用它的 `set_id`（调用方从回读里带过来）。 */
  async saveClimateAppointment(appointment: ClimateAppointment): Promise<void> {
    await this.perform(LeapCommand.climateAppointment(appointment, this.session.selectedVin));
  }

  async cancelClimateAppointment(): Promise<void> {
    await this.perform(LeapCommand.cancelClimateAppointment());
  }

  // MARK: - 舒适座舱

  private static cabinKey(position: SeatPosition, channel: SeatComfortChannel): string {
    return `${channel}|${position}`;
  }

  private setCabinDraft(key: string, value: number): void {
    const next = new Map<string, number>(this.cabinDrafts);
    next.set(key, value);
    this.cabinDrafts = next;
  }

  /**
   * 界面读的档位：草稿优先，没有草稿就读车况。车况也读不到返回 null——
   * 那是「这车没这个座位」，界面该整块隐藏，不是显示 0 档。
   */
  seatLevel(position: SeatPosition, channel: SeatComfortChannel): number | null {
    const draft = this.cabinDrafts.get(VehicleStore.cabinKey(position, channel));
    if (draft !== undefined) {
      return draft;
    }
    return this.state !== null ? this.state.seatLevel(position, channel) : null;
  }

  get steeringWheelLevel(): number | null {
    const draft = this.cabinDrafts.get(VehicleStore.steeringWheelKey);
    if (draft !== undefined) {
      return draft;
    }
    return this.state !== null ? this.state.steeringWheelHeatLevel : null;
  }

  get mirrorHeatingOn(): boolean | null {
    if (this.mirrorHeatingDraft !== null) {
      return this.mirrorHeatingDraft;
    }
    return this.state !== null ? this.state.mirrorHeatingOn : null;
  }

  /**
   * 方向盘加热剩余分钟。**只在车况报着加热开着时才有值**——草稿不参与，
   * 因为剩余分钟是车端算的，本机刚点的那一档还没生效时没有对应的分钟数。
   */
  get steeringWheelHeatMinutes(): number | null {
    return this.state !== null ? this.state.steeringWheelHeatMinutes : null;
  }

  /** 轻点座位：`0 → 1 → 2 → 3 → 0` 循环。读不到档位的座位界面上本来就不画，点不到。 */
  cycleSeat(position: SeatPosition, channel: SeatComfortChannel): void {
    const current = this.seatLevel(position, channel);
    if (current === null) {
      return;
    }
    this.setSeat(position, channel, (current + 1) % (SeatChannels.maxLevel + 1));
  }

  setSeat(position: SeatPosition, channel: SeatComfortChannel, level: number): void {
    const key = VehicleStore.cabinKey(position, channel);
    this.setCabinDraft(key, Math.min(SeatChannels.maxLevel, Math.max(0, level)));
    this.scheduleCabinPush(key, () => {
      const target = this.cabinDrafts.get(key);
      if (target !== undefined) {
        this.enqueueCabin(LeapCommand.seatComfort(position, channel, target));
      }
    });
  }

  /** 方向盘加热：`0 → 1 → 2 → 0`，**两档**，和座椅不是一套量程。 */
  setSteeringWheelHeat(level: number): void {
    const key = VehicleStore.steeringWheelKey;
    this.setCabinDraft(key, Math.min(2, Math.max(0, level)));
    this.scheduleCabinPush(key, () => {
      const target = this.cabinDrafts.get(key);
      if (target !== undefined) {
        this.enqueueCabin(LeapCommand.steeringWheelHeating(target));
      }
    });
  }

  /** 后视镜加热只有开 / 关两态，没有连点加档的场景，不走防抖，点了就发。 */
  toggleMirrorHeating(): void {
    const next = !(this.mirrorHeatingOn ?? false);
    this.mirrorHeatingDraft = next;
    this.enqueueCabin(LeapCommand.mirrorHeating(next));
  }

  /** 页面上还有没有开着的项（决定「全部关闭」能不能点）。 */
  get cabinAnythingOn(): boolean {
    for (const channel of SeatChannels.all) {
      for (const position of SeatPositions.all) {
        if ((this.seatLevel(position, channel) ?? 0) > 0) {
          return true;
        }
      }
    }
    return (this.steeringWheelLevel ?? 0) > 0 || this.mirrorHeatingOn === true;
  }

  /**
   * 「全部关闭」：把当前**确实不为 0** 的项逐条发 0。
   *
   * 只发不为 0 的那几条：读不到档位的项（这车没这个座位）不该发，已经是 0 的项
   * 再发一遍纯粹是多一次远控请求和一次等车确认。
   */
  closeAllCabinComfort(): void {
    const commands: LeapCommand[] = [];
    const drafts = new Map<string, number>(this.cabinDrafts);
    for (const channel of SeatChannels.all) {
      for (const position of SeatPositions.all) {
        const level = this.seatLevel(position, channel);
        if (level === null || level <= 0) {
          continue;
        }
        const key = VehicleStore.cabinKey(position, channel);
        // 这一格的防抖还没到点的话，取消掉，不然 0.8 秒后又把刚关的档位发回去。
        this.cancelCabinPush(key);
        drafts.set(key, 0);
        commands.push(LeapCommand.seatComfort(position, channel, 0));
      }
    }
    const wheel = this.steeringWheelLevel;
    if (wheel !== null && wheel > 0) {
      this.cancelCabinPush(VehicleStore.steeringWheelKey);
      drafts.set(VehicleStore.steeringWheelKey, 0);
      commands.push(LeapCommand.steeringWheelHeating(0));
    }
    this.cabinDrafts = drafts;
    if (this.mirrorHeatingOn === true) {
      this.mirrorHeatingDraft = false;
      commands.push(LeapCommand.mirrorHeating(false));
    }
    if (commands.length === 0) {
      this.show('座舱加热与通风都已关闭');
      return;
    }
    commands.forEach((command: LeapCommand) => {
      this.enqueueCabin(command);
    });
  }

  /** 冰箱：电源键点了就发；其余设定项改完走防抖，和空调页调温度一个节奏。 */
  setFridgePower(on: boolean): void {
    const base = this.fridgeDraft ?? this.state?.fridgeState?.asSetting() ?? new FridgeSetting();
    const setting = base.copy();
    setting.enabled = on;
    this.fridgeDraft = setting;
    this.cancelCabinPush(VehicleStore.fridgeKey);
    this.enqueueCabin(LeapCommand.fridge(setting));
  }

  /** 界面改完一项（整份替换草稿）之后调。关机状态下不发——开机键才是那条指令。 */
  updateFridgeDraft(setting: FridgeSetting): void {
    this.fridgeDraft = setting;
    if (!setting.enabled) {
      return;
    }
    this.scheduleCabinPush(VehicleStore.fridgeKey, () => {
      const latest = this.fridgeDraft;
      if (latest !== null) {
        this.enqueueCabin(LeapCommand.fridge(latest));
      }
    });
  }

  /**
   * 进冰箱页时把车况里的设定搬进草稿。已经有草稿就不动——
   * 那是用户正在调的东西，被轮询回来的车况冲掉就是「调了弹回去」。
   */
  seedFridgeDraft(): void {
    if (this.fridgeDraft !== null) {
      return;
    }
    const fridge = this.state?.fridgeState ?? null;
    this.fridgeDraft = fridge !== null ? fridge.asSetting() : null;
  }

  private scheduleCabinPush(key: string, send: () => void): void {
    this.cancelCabinPush(key);
    const timer = setTimeout(() => {
      this.cabinPushTimers.delete(key);
      send();
    }, VehicleStore.cabinPushDelayMs);
    this.cabinPushTimers.set(key, timer);
  }

  private cancelCabinPush(key: string): void {
    const timer = this.cabinPushTimers.get(key);
    if (timer !== undefined) {
      clearTimeout(timer);
      this.cabinPushTimers.delete(key);
    }
  }

  /** 单航道被占着就排队，空着就直接发。 */
  private enqueueCabin(command: LeapCommand): void {
    if (this.isSendingCommand || this.pendingCommand !== null) {
      this.cabinQueue = this.cabinQueue.concat([command]);
      return;
    }
    this.perform(command);
  }

  /** 上一条跑完后接着发队列里的下一条。放到下一拍，别在上一条的 finally 里递归套娃。 */
  private flushCabinQueue(): void {
    if (this.cabinQueue.length === 0) {
      return;
    }
    const next = this.cabinQueue[0];
    this.cabinQueue = this.cabinQueue.slice(1);
    setTimeout(() => {
      this.perform(next);
    }, 0);
  }

  /**
   * 车况回来时清掉已经尘埃落定的草稿。
   *
   * 「尘埃落定」= 没有待发的防抖任务、队列空了、也没有指令在飞或在等密码。
   * 清掉之后界面读的就是车报的真值：成功显示新档位，失败显示原档位。
   */
  private clearCabinDraftsIfSettled(): void {
    if (this.cabinPushTimers.size > 0 || this.cabinQueue.length > 0
      || this.isSendingCommand || this.pendingCommand !== null) {
      return;
    }
    if (this.cabinDrafts.size > 0) {
      this.cabinDrafts = new Map<string, number>();
    }
    this.mirrorHeatingDraft = null;
  }

  /** 离开座舱 / 冰箱页时取消还没发出去的那几条。空调页 `aboutToDisappear` 同理。 */
  cancelPendingCabinPushes(): void {
    this.cabinPushTimers.forEach((timer: number) => {
      clearTimeout(timer);
    });
    this.cabinPushTimers.clear();
  }

  // MARK: - 提示

  show(text: string, detail: string = '', isError: boolean = false,
    showsRetry: boolean = false, seconds: number = 3): void {
    const message = new ToastMessage();
    message.text = text;
    message.detail = detail;
    message.isError = isError;
    message.showsRetry = showsRetry;
    message.seconds = seconds;
    this.toastSeq++;
    message.id = this.toastSeq;
    this.toast = message;
  }

  showError(error: Error): void {
    const leapError = error as LeapError;
    if (leapError.kind === LeapErrorKind.NeedsRelogin) {
      // 故意**不**走 `expireSession`：那条路会把会话连同蓝牙钥匙证书一起清掉，
      // 而这个状态未必是登录态没了——多半是本机的设备号跟服务端记的那个对不上，
      // 车况照常刷新、新网关一切正常，只有老链路（远控/里程/位置）全废。
      // 自动清一遍等于顺手毁掉还能用的蓝牙钥匙。
      //
      // 但也不能继续说「请稍后重试」——重试一万次都不会好。把话说明白，
      // 什么时候去重登由用户自己决定。停久一点，这条比普通失败重要。
      this.show('控车授权已失效', '重试无法恢复，请到「设置」退出登录后重新登录', true, false, 8);
      return;
    }
    this.show(LeapError.messageOf(error), '', true);
    if (leapError.kind === LeapErrorKind.SessionExpired) {
      this.expireSession();
    }
  }

  /** 最近一次主动校验登录态的时间戳（ms）。频繁切前后台时用它节流。 */
  private lastSessionValidation: number = 0;

  /**
   * 主动确认登录态还在——开 App、回到前台时调用。
   *
   * 为什么要单独探：车况刷新走新网关读取 token，被挤下线后它仍活着，刷新永远发现不了；
   * 真正会死的是老链路控车 token（详见 LeapClient.validateSession）。
   *
   * 两层节流：这里 30 秒内探过就跳过，挡住频繁切前后台；LeapClient 那边再看一次老
   * token 有多新，刚换发过就直接认有效、连请求都不发。
   * 返回 false 表示已判定失效并开始回登录页；true 表示有效或无法判定（按有效处理）。
   */
  async validateSession(force: boolean = false): Promise<boolean> {
    if (!this.isLoggedIn || this.isDemo) {
      return true;
    }
    if (!force && Date.now() - this.lastSessionValidation < 30000) {
      return true;
    }
    this.lastSessionValidation = Date.now();
    try {
      await this.client.validateSession();
      return true;
    } catch (e) {
      const leapError = e as LeapError;
      if (leapError.kind === LeapErrorKind.SessionExpired) {
        this.show('登录已过期', '请重新登录', true);
        await this.expireSession();
        return false;
      }
      // 网络等其它错误：判不了，按有效继续，别打扰也别误踢。
      return true;
    }
  }

  /**
   * 服务端明确说登录态失效时退回登录页。留在首页只会不停弹同一条错误，
   * 而用户根本没有入口重新登录。
   *
   * 操作密码不清：同一个账号重新登录后还是那一个，重新走一遍短信验证已经够验证身份了。
   */
  private async expireSession(): Promise<void> {
    // 守卫不能只看界面这份 session。它是 client 那份的快照，而且只在成功路径上同步：
    // login() 中途失败时界面这份还停在登录前的空态，client 内部却可能攥着半截凭证。
    // 只看 isLoggedIn 就会在这里直接 return，那份脏凭证于是永远清不掉——用户只能靠
    // 进一次演示模式再退出（那条路上的 logout() 没有守卫）才解得开。以 client 手里的为准。
    if (!this.isLoggedIn && !SessionUtil.hasAnyCredential(this.client.session)) {
      return;
    }
    this.stopPolling();
    this.endForegroundVerification();
    await this.client.logout();
    // 卡片不能继续显示一份已经无法刷新的车况。
    SnapshotStore.clear();
    this.reloadWidgets();
    this.syncSession();
    this.state = null;
    this.lastUpdated = 0;
    this.reportedAt = 0;
    this.locationName = '';
    this.challenge = null;
    this.pendingCommand = null;
    this.pendingChargeBatch = null;
    // 被踢回登录页后同样不能留着这台车的车图。
    this.unloadCarModel();
  }
}

/** 全局单例。页面通过它读写状态。 */
export const vehicleStore: VehicleStore = new VehicleStore();
