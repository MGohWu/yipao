import { JsonValue } from './JsonValue';
import { LeapCrypto } from './LeapCrypto';
import {
  VehicleSignal, SignalSchema, ClimateMode, ClimateModeInfo,
  WindowScale, WindowScaleUtil, ClimateModeCoding, ClimateModeCodingUtil, CarTypeFamily
} from './SignalSchema';
import {
  SeatPosition, SeatPositions, SeatComfortChannel, SeatChannels,
  FridgeSetting, FridgeState, FridgeText, FridgeMode
} from './CabinComfort';
import { ClimateAppointment } from './ClimateAppointment';

export { LeapError, LeapErrorKind } from './LeapError';
export {
  VehicleSignal, SignalSchema, ClimateMode, ClimateModeInfo, WindowScale, ClimateModeCoding, CarTypeFamily
} from './SignalSchema';

// MARK: - 常量

export class LeapConstants {
  static readonly appVersion = '1.22.87';
  static readonly subVersion = '3.19.2-2';
  static readonly appUserHost = 'https://appuser.leapmotor.cn';
  static readonly globalHost = 'https://app-gw-global-master.leapmotor.com';
  /** accessToken 剩余不足 5 分钟就提前续期（秒）。 */
  static readonly accessTokenLeeway = 5 * 60;
  /** 老 token 剩余不足 60 秒才续期（秒）。 */
  static readonly oldTokenLeeway = 60;
  /**
   * 老链路 `result=39` 的续期冷却窗口（秒）：老 token 是这段时间内换发的，再收到 39
   * 就不重复续期，只当瞬时抖动重试一次。对齐官方零跑 App 的 60 秒不重复刷新闸——
   * 刚续期后紧跟的 39 若又触发一次续期，旧 refreshToken 立刻作废，反而制造失效窗口。
   * 见 iOS 的 `LeapClient.oldAuthedRequest`。
   */
  static readonly oldTokenReauthCooldown = 60;
  /**
   * 老链路连着多少次 `result=39` 才把「请稍后重试」升级成「请重新登录」。
   *
   * 冷却窗口那一档（上面那条）解决的是「偶发 39 别退登」，但只有那一半的话，
   * 真的失效了（比如设备号在服务端换了绑）会永远停在「请稍后重试」——用户按什么都
   * 失败、也没人告诉他该重新登录。所以再加一档：连败够多、且拖得够久，才明说。
   */
  static readonly oldAuthFailureEscalationCount = 3;
  /** 连败还要跨过这么长时间才算「重试也不会好」（秒）。挡住连点三下就被赶去登录页。 */
  static readonly oldAuthFailureEscalationWindow = 5 * 60;
  /**
   * 老 token 是这段时间内换发的，登录态探测就直接认它有效，不再打一次续期（秒）。
   * 见 `LeapClient.validateSession`：探得太勤，每次都换发一份新 refreshToken，
   * 旧的当场作废，撞上限流和误判文案的机会也跟着翻倍。
   */
  static readonly sessionProbeFreshness = 30 * 60;
}

export class LeapFormat {
  /**
   * 温度：车报 26.5 就写 26.5，报 26.0 就写 26。
   * 半度是车端真实的分辨率，不该替它抹掉（`%.0f` 会把 26.5 进位成 27）。
   */
  static temperature(value: number): string {
    return value === Math.round(value) ? String(Math.round(value)) : value.toFixed(1);
  }
}

// MARK: - 会话

export interface OldAuth {
  accountId: string;
  token: string;
  refreshToken: string;
  nickname: string;
  tokenExpired: string;
  tokenObtainedAt: number;
  tokenExpiresAt: number;
}

export interface NewAuth {
  accountId: string;
  gatewayAccountId: string;
  accessToken: string;
  refreshToken: string;
  accessTokenExpiresAt: number;
  nickname: string;
  /** 以 base64 落盘，运行时用 signKeyData()。 */
  signKeyBase64: string;
}

export class AuthUtil {
  /** 老 token 过期时间戳（毫秒），0 表示无。 */
  static oldExpiresAt(auth: OldAuth): number {
    return auth.tokenExpiresAt;
  }

  static newSignKeyData(auth: NewAuth): Uint8Array {
    return LeapCrypto.base64Decode(auth.signKeyBase64);
  }

  /** 新网关 token 过期时间戳（毫秒），优先取 JWT exp。 */
  static newExpiresAt(auth: NewAuth): number {
    const exp = LeapCrypto.jwtExpiryMilliseconds(auth.accessToken);
    return exp > 0 ? exp : auth.accessTokenExpiresAt;
  }
}

export interface Vehicle {
  vin: string;
  carType: string;
  name: string;
  /**
   * 这台车是不是增程（REEV/EREV）。判据跟官方对齐：vehicle/list 响应里每辆车的
   * `abilities` 字符串数组含能力码 "39"（官方内部 key isExtendRange）就是增程。
   * 会随 Vehicle 一起持久化进会话；旧会话没有这字段，读出来是 undefined，
   * 各处读取一律 `?? false` 兜底。
   */
  isExtendRange: boolean;
  /**
   * 运行时兜底标志：isExtendRange 是从「缺该字段的老会话 JSON」兜出来的 undefined、
   * 还没被 vehicle/list 的真实 abilities 刷新过，不可信。SessionStore.load() 在反序列化
   * 时按字段是否真实存在置位，refresh 链路（fetchState）见到任一车为真就强制重拉一次能力码。
   * 升级用户增程被误判成纯电、油量整块消失就是这个字段缺失且永不重拉导致的。
   * 持久化无所谓：loadVehicles 成功后整辆车被带 isExtendRange 的新对象覆盖，此标志自然消失。
   */
  abilitiesStale?: boolean;
  /**
   * 这台车的**内部权限码清单**（"400" 这类），由 loadVehicles 把 `abilities` 里的原始短码
   * 经 CarPerManager 翻译表（VehicleUtil.permissionCodes）换算出来。
   *
   * **注意 vehicle/list 响应里根本没有 `permission` 字段**：能力码全在 `abilities` 里，
   * 是服务端**原始短码**（"1".."89"），判据吃的却是内部码，中间隔着 CarPerManager 一层。
   * 曾误以为存在一个和 abilities 并列的 permission 字段直接读，结果恒空 → 哨兵对所有真实用户
   * 判假（只有手填内部码的体验模式看得到）。判增程用的 `abilities.contains("39")` 判不了哨兵，
   * 因为哨兵是内部码 "400"（原始短码 "50" 翻过来的）。翻译表见 permission-codes-map.md §5、
   * 哨兵门控佐证见 apk-analysis/sentinel-mode-interfaces.md。
   */
  permission: string[];
  /**
   * 这台车支不支持哨兵模式。判据跟官方钉死的对齐：
   * `carType 不是 "S01"/"T03"` 且内部权限码含 `"400"`
   * （官方门控 updateSentinel：RemoteContorllerUtil.contains("400")，S01/T03 走白名单恒排除）。
   * 由 loadVehicles 从 abilities 翻出的内部码派生、随会话持久化；老会话没有这字段读出来是
   * undefined，取值处一律 `?? false` 兜底，并靠 sentinelStale 触发一次重拉补齐。
   */
  isSentinelSupported: boolean;
  /**
   * 运行时兜底标志，语义同 abilitiesStale：isSentinelSupported 是从「缺该字段的老会话 JSON」
   * 兜出来的 undefined、还没被真实 permission 刷新过，不可信。SessionStore.load() 反序列化时
   * 按字段是否真实存在置位，fetchState 见到任一车为真就强制重拉一次 vehicle/list 把 permission
   * 补回来。和 abilitiesStale 各判各的字段（abilities 缺不代表 permission 也缺，反之亦然），
   * 所以要各自一份，不能合并。持久化无所谓：重拉成功后整辆车被新对象覆盖，此标志自然消失。
   */
  sentinelStale?: boolean;
}

export class VehicleUtil {
  /** 只展示后 4 位，避免整屏 VIN 泄露。 */
  static maskedVin(vin: string): string {
    if (vin.length <= 6) {
      return vin;
    }
    return vin.substring(0, 2) + '*'.repeat(Math.max(0, vin.length - 6)) + vin.substring(vin.length - 4);
  }

  /**
   * 服务端原始能力短码 → App 内部权限码 的翻译表（官方 CarPerManager 那张表的子集）。
   * vehicle/list 每辆车只回**原始短码**（在 `abilities` 里，且响应里**根本没有** permission 字段），
   * 而判据吃的是内部码，中间必须翻这一道。四条已三路交叉验证：
   * 50→400 哨兵、13→240 遮阳帘、25→300 天窗、79→131 前备箱。
   * 四条全都在用：400 哨兵、240 遮阳帘、300 天窗、131 前备箱。
   * 全量表见 apk-analysis/permission-codes-map.md §5。
   */
  private static readonly abilityToPermission: Map<string, string> = new Map<string, string>([
    ['105', 'bleMultipleAnchors'],
    ['50', '400'],
    ['13', '240'],
    ['25', '300'],
    ['79', '131'],
    // 舒适座舱四项（2026-11-19 补，同 iOS）。这四个内部码在我们自己解出的 CarPerManager 全表里
    // 本来就在，只是官方 APK 里一个中文名都没有（官方 App 自己没做这些功能），所以之前没收。
    // 语义来自 leapauto，与实测 C16 的 abilities 逐项对得上：含 21/42/43/59、不含 76，
    // 而那台车的 signalMap 里座椅/方向盘/后视镜信号全在、冰箱信号全无——两路证据一致。
    ['21', '301'],   // 座椅加热
    ['85', '301'],
    ['93', '301'],
    ['42', '370'],   // 座椅通风
    ['43', '370'],
    ['59', '440'],   // 后视镜加热
    ['76', '500']    // 车载冰箱
  ]);

  /**
   * 支持哨兵的判据：车型不是 S01 / T03，且内部权限码含 "400"
   * （官方 updateSentinel 门控，见 sentinel-mode-interfaces.md §4）。
   *
   * 这份判据的结果随车持久化在 `Vehicle.isSentinelSupported` 里（拉车列表时算一次），
   * 界面读的是那个字段而不是每次现算——所以这里只有两个调用点：解析车列表、演示车。
   */
  static supportsSentinel(carType: string, permission: string[]): boolean {
    if (CarTypeFamily.isS01(carType) || CarTypeFamily.isT03(carType)) {
      return false;
    }
    return permission.includes('400');
  }

  /**
   * 支持远控天幕遮阳帘的判据：内部权限码含 "240"
   * （permission-codes-map.md，快捷面板 btnType "29" → lpcar_btn_sunshade，确证）。
   *
   * 和哨兵不同**不排除 S01 / T03**：官方对这两个车型的前置白名单
   * （RemoteContorllerUtil.OooO00o）里有 766="240"，遮阳帘照常按能力码判。
   */
  static supportsSunshade(permission: string[]): boolean {
    return permission.includes('240');
  }

  /**
   * 支持远控天窗的判据：车型不是 S01 / T03，且内部权限码含 "300"
   * （同上出处，btnType "26" → lpcar_btn_skylight）。S01 / T03 的白名单里**没有** 763="300"——
   * 官方在这两个车型上恒隐藏天窗，哪怕服务端下发了能力码，所以照哨兵那样先挡车型再看码。
   */
  static supportsSunroof(carType: string, permission: string[]): boolean {
    if (CarTypeFamily.isS01(carType) || CarTypeFamily.isT03(carType)) {
      return false;
    }
    return permission.includes('300');
  }

  /**
   * 支持远控前备箱的判据：车型不是 S01 / T03，且内部权限码含 "131"
   * （同上出处，btnType "137" → lpcar_btn_front_trunk；白名单没有 153="131"，车型排除理由同天窗）。
   */
  static supportsFrunk(carType: string, permission: string[]): boolean {
    if (CarTypeFamily.isS01(carType) || CarTypeFamily.isT03(carType)) {
      return false;
    }
    return permission.includes('131');
  }

  /**
   * 舒适座舱四项的能力码判据。
   *
   * 这几项**只当第二道判据**：真正说话的是车况信号在不在场（见 `VehicleState.hasCabinComfort`）。
   * 原因是信号比能力码更贴车端，而且方向盘加热（cmdid `320`）压根没有已知的 `abilities` 原始码，
   * 只能靠信号 `1816`。两者都没有才隐藏。
   *
   * S01 / T03 一律排除：那套老口径的 signalMap 里没有任何一个对应字段，整页在老车上就是空的。
   */
  static supportsCabinComfort(carType: string, permission: string[]): boolean {
    if (CarTypeFamily.isLegacyFamily(carType)) {
      return false;
    }
    return permission.includes('301') || permission.includes('370') || permission.includes('440');
  }

  /** 车载冰箱的能力码判据（原始码 `76`）。实测用的那台 C16 不含 `76`，和它的冰箱信号全无互相印证。 */
  static supportsFridge(carType: string, permission: string[]): boolean {
    if (CarTypeFamily.isLegacyFamily(carType)) {
      return false;
    }
    return permission.includes('500');
  }

  /**
   * 把 vehicle/list 的原始 `abilities` 短码翻成内部权限码清单（认不出的短码丢弃）。
   * 多个原始码可能翻到同一个内部码（21/85/93 → 301），去重。
   */
  static permissionCodes(abilities: string[]): string[] {
    const out: string[] = [];
    for (const code of abilities) {
      const mapped = VehicleUtil.abilityToPermission.get(code);
      if (mapped !== undefined && !out.includes(mapped)) {
        out.push(mapped);
      }
    }
    return out;
  }
}

export interface VehicleRoute {
  appRegion: string;
  appCenter: string;
}

export interface LeapSession {
  deviceId: string;
  appVersion: string;
  subVersion: string;
  phone: string;
  oldAuth: OldAuth | null;
  newAuth: NewAuth | null;
  vehicles: Vehicle[];
  selectedVin: string;
  selectedCarType: string;
  /**
   * 车型别名（`Lafa5` 这种），从 3D 资源目录名反推、随会话存下来。
   * 存而不是每次现推：卡片那边读的是持久化的会话，拿不到主界面的缓存目录判断，
   * 只有存下来卡片和首页才不会叫出两个名字。
   * 老会话里没有这个字段，反序列化出来是 undefined，取值处都按空处理。
   */
  selectedCarAlias: string | null;
  route: VehicleRoute | null;
  /**
   * 凭证换发时刻（毫秒）。**只在 token 真的换过之后才往上打**，别的字段变了不算。
   *
   * 会话现在有两个写者：主应用和卡片进程（`LeapFormAbility` 会联网刷新、会直发控车）。
   * 两边手里那份都是各自进程启动时的快照，整份写回就会互相覆盖——把对方刚换来的
   * token 抹成几小时前的旧值，下次续期拿着作废的 refreshToken 去问服务端，被拒之后
   * 按登录态失效处理，用户就莫名其妙回到登录页了。iOS 正是这么出的事。
   *
   * 有了这个版本号，落盘前比一比谁的新，新的那份说了算（见 `LeapClient.syncAuthFromStore`）。
   * 老会话里没有这个字段，解出来是 undefined，比较处一律按 0 兜底——那是「最旧」，
   * 任何一次真实换发都能盖过它。
   */
  authRevision?: number;
}

export class SessionUtil {
  static fresh(): LeapSession {
    return {
      // 设备号是**空的**，不是新生成的——这是刻意的。
      //
      // 关键资产在设备首次解锁前读不到（卡片进程、开机后被拉起的那一帧都会撞上）。
      // 原来这里凭空发一个新设备号，老签名链路的 `deviceID` 就跟服务端记的对不上，
      // 服务端一律回 result=39；更糟的是它会被整份写回钉进关键资产，从此只有重新
      // 登录才能救回来——「按什么控制都提示指令下发失败，要重新登录才行」正是这么来的。
      //
      // 空设备号的会话发不出任何请求（`requireDeviceId()` 会挡住），也不会落盘，
      // 只有 `ensureDeviceId()`（登录流程）才生成新的。
      deviceId: '',
      appVersion: LeapConstants.appVersion,
      subVersion: LeapConstants.subVersion,
      phone: '',
      oldAuth: null,
      newAuth: null,
      vehicles: [],
      selectedVin: '',
      selectedCarType: '',
      selectedCarAlias: null,
      route: null,
      authRevision: 0
    };
  }

  /** 只给 `LeapClient.ensureDeviceId()`（登录流程）用。别处一律不发新设备号。 */
  static randomDeviceId(): string {
    let out = '';
    const hex = '0123456789abcdef';
    for (let i = 0; i < 32; i++) {
      out += hex.charAt(Math.floor(Math.random() * 16));
    }
    return out;
  }

  /**
   * 浅拷贝一份会话。
   *
   * 给状态层用：`LeapClient` 登录时是就地改自己那个 `sessionData` 的字段，
   * 引用自始至终没变。`@Trace` 只比较引用，把同一个对象再赋一次等于没赋，
   * 界面收不到通知——登录成功了也还留在登录页。取一份新对象才能让 V2 认账。
   */
  static snapshot(session: LeapSession): LeapSession {
    return {
      deviceId: session.deviceId,
      appVersion: session.appVersion,
      subVersion: session.subVersion,
      phone: session.phone,
      oldAuth: session.oldAuth,
      newAuth: session.newAuth,
      vehicles: session.vehicles,
      selectedVin: session.selectedVin,
      selectedCarType: session.selectedCarType,
      selectedCarAlias: session.selectedCarAlias,
      route: session.route,
      authRevision: session.authRevision
    };
  }

  static isLoggedIn(session: LeapSession): boolean {
    const oldOk = session.oldAuth !== null && session.oldAuth.token.length > 0;
    const newOk = session.newAuth !== null && session.newAuth.accessToken.length > 0;
    return oldOk && newOk;
  }

  /**
   * 手里还攥着**任何一份**凭证——哪怕只有半份，不足以算登录成功。
   *
   * 半份是真会出现的：`login()` 拿到 oldAuth 之后换新网关那步失败，就剩 oldAuth。
   * 这种会话登录不了，却足以把登录请求的 header 打脏，所以清理逻辑得认它，
   * 不能只认 `isLoggedIn`。
   */
  static hasAnyCredential(session: LeapSession): boolean {
    return session.oldAuth !== null || session.newAuth !== null;
  }

  static selectedVehicle(session: LeapSession): Vehicle | null {
    for (let i = 0; i < session.vehicles.length; i++) {
      if (session.vehicles[i].vin === session.selectedVin) {
        return session.vehicles[i];
      }
    }
    return null;
  }

  /**
   * 界面和卡片上显示的车名。两边必须一致，否则卡片和首页会叫出两个名字。
   *
   * 车主在官方 App 起的名字最优先。没起过名就用车型别名——B05 这种内部代号
   * 不适合直接摆在界面上，别名（`Lafa5`）是渲染器实际认的那个名字。
   * 别名只有 3D 车推得出来（靠资源目录名），2D 图层车退回 carType：
   * C10、S01 这些本来就是对外车型名，摆出来没问题。
   */
  static displayVehicleName(session: LeapSession): string {
    const vehicle = SessionUtil.selectedVehicle(session);
    if (vehicle !== null && vehicle.name.length > 0) {
      return vehicle.name;
    }
    const alias = session.selectedCarAlias;
    if (alias !== null && alias !== undefined && alias.length > 0) {
      return alias;
    }
    if (session.selectedCarType.length > 0) {
      return session.selectedCarType;
    }
    return '我的车';
  }
}

// MARK: - 坐标

export interface Coordinate {
  latitude: number;
  longitude: number;
}

// MARK: - 充电计划

/**
 * 充电计划。来自 commonConfig 接口 `data.config."3"`——数字口径的车不把它当信号报，
 * 官方就从这里读预约时段、目标电量和循环日。只解析要展示的字段；`circulation` /
 * `recharge` 存下来但界面不展示。
 */
export class ChargePlan {
  /** 预约充电起始时刻，"HH:mm"。 */
  beginTime: string = '';
  /** 预约充电结束时刻，"HH:mm"。 */
  endTime: string = '';
  /** 目标 SOC（%），也就是充电上限。 */
  percent: number = 0;
  /** 预约充电开关。 */
  isEnable: boolean = false;
  /**
   * 循环日，七位。**假设 cycles[0]=周一 … cycles[6]=周日**——实测样本全是 1（每天），
   * 无法证伪星期顺序，这里按最常见的「周一起」约定，`cyclesSummary` 也照这个顺序读。
   */
  cycles: boolean[] = [];
  /** 循环模式码，界面不展示。 */
  circulation: number = 0;
  /** recharge 标志，界面不展示。 */
  recharge: number = 0;

  /**
   * 从 config 里的充电计划节点（`config."3"`）解析。
   * cycles 形如 "1,1,1,1,1,1,1"，逐位 `=== '1'` 转布尔。
   */
  static fromConfigNode(plan: JsonValue): ChargePlan {
    const result = new ChargePlan();
    result.beginTime = ChargePlan.timeString(plan.get('beginTime'));
    result.endTime = ChargePlan.timeString(plan.get('endTime'));
    result.percent = ChargePlan.intOr(plan.get('percent'), 0);
    const enable = plan.get('isEnable');
    result.isEnable = enable !== null && enable.intValue === 1;
    result.cycles = ChargePlan.parseCycles(plan.get('cycles'));
    result.circulation = ChargePlan.intOr(plan.get('circulation'), 0);
    result.recharge = ChargePlan.intOr(plan.get('recharge'), 0);
    return result;
  }

  private static timeString(node: JsonValue | null): string {
    if (node === null) {
      return '';
    }
    const text = node.stringValue;
    return text !== null ? text : '';
  }

  private static intOr(node: JsonValue | null, fallback: number): number {
    if (node === null || node.intValue === null) {
      return fallback;
    }
    return node.intValue;
  }

  private static parseCycles(node: JsonValue | null): boolean[] {
    if (node === null) {
      return [];
    }
    const text = node.stringValue;
    if (text === null || text.length === 0) {
      return [];
    }
    return text.split(',').map((part: string): boolean => part.trim() === '1');
  }

  /** 有没有拿到完整的七位循环日。 */
  get hasCycles(): boolean {
    return this.cycles.length === 7;
  }

  /**
   * 循环日转成人类可读：全选「每天」、周一~周五「工作日」、仅周末「周末」，
   * 其余列出具体日（周一 / 周三 …）。星期顺序假设见 `cycles` 注释。
   */
  get cyclesSummary(): string {
    if (!this.hasCycles) {
      return '';
    }
    const days = this.cycles;
    const names: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    if (days.every((on: boolean): boolean => on)) {
      return '每天';
    }
    if (days.every((on: boolean): boolean => !on)) {
      return '不重复';
    }
    const weekdaysOn = days[0] && days[1] && days[2] && days[3] && days[4];
    const weekendOff = !days[5] && !days[6];
    if (weekdaysOn && weekendOff) {
      return '工作日';
    }
    const weekdaysOff = !days[0] && !days[1] && !days[2] && !days[3] && !days[4];
    const weekendOn = days[5] && days[6];
    if (weekdaysOff && weekendOn) {
      return '周末';
    }
    const picked: string[] = [];
    for (let i = 0; i < 7; i++) {
      if (days[i]) {
        picked.push(names[i]);
      }
    }
    return picked.join(' / ');
  }

  /** 预约时段 "23:00–08:00"，缺任一端返回空串。 */
  get timeRange(): string {
    if (this.beginTime.length === 0 || this.endTime.length === 0) {
      return '';
    }
    return `${this.beginTime}–${this.endTime}`;
  }
}

// MARK: - 车况

/**
 * 车端 signalMap 原始值，统一按字符串存放，解释权全部下放到取值方法。
 * key 用哪一套由 schema 决定——不同车型上报的字段命名体系不同，见 SignalSchema。
 */
export class VehicleState {
  signalMap: Map<string, string> = new Map<string, string>();
  schema: SignalSchema = SignalSchema.legacy;
  /** 本机什么时候把这份车况拉下来的。注意不是车端采集时刻，那个看 `reportedAt`。 */
  collectedAt: number = 0;
  /** 充电计划里设的充电上限（%）。数字口径的车不把它当信号报。 */
  chargePlanLimit: number | null = null;
  /**
   * 完整充电计划（预约时段 / 目标电量 / 循环日）。同样来自 commonConfig 的 config.3，
   * 由 LeapClient 拉车况后容错注入；拿不到就保持 null，界面按缺失处理。
   */
  chargePlan: ChargePlan | null = null;
  /**
   * 这台车是不是增程（REEV/EREV）。由 LeapClient 拉车况时从当前选中车的
   * Vehicle.isExtendRange 注入（源头是 vehicle/list 的 abilities 含 "39"）。
   * hasFuel 现在直接看它，signalMap 里的汽油续航字段不再参与判增程。
   */
  isExtendRange: boolean = false;

  /** 按候选顺序取第一个真的有值的 key。 */
  raw(signal: VehicleSignal): string | null {
    const candidates = this.schema.candidates(signal);
    for (let i = 0; i < candidates.length; i++) {
      const value = this.signalMap.get(candidates[i]);
      if (value !== undefined && value.length > 0) {
        return value;
      }
    }
    return null;
  }

  int(signal: VehicleSignal): number | null {
    const value = this.raw(signal);
    if (value === null) {
      return null;
    }
    const parsed = Number(value);
    return Number.isFinite(parsed) ? Math.trunc(parsed) : null;
  }

  double(signal: VehicleSignal): number | null {
    const value = this.raw(signal);
    if (value === null) {
      return null;
    }
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }

  bool(signal: VehicleSignal): boolean | null {
    const value = this.raw(signal);
    if (value === null) {
      return null;
    }
    const lower = value.toLowerCase();
    if (lower === 'true' || lower === '1') {
      return true;
    }
    if (lower === 'false' || lower === '0') {
      return false;
    }
    return null;
  }

  // 电池
  get soc(): number | null {
    return this.int(VehicleSignal.soc);
  }

  get expectedMileage(): number | null {
    return this.int(VehicleSignal.expectedMileage);
  }

  /** 剩余能量，单位瓦时。界面上除以 1000 显示成 kWh。 */
  get dumpEnergyWh(): number | null {
    return this.double(VehicleSignal.dumpEnergy);
  }

  get batteryVoltage(): number | null {
    return this.double(VehicleSignal.batteryVoltage);
  }

  get batteryCurrent(): number | null {
    return this.double(VehicleSignal.batteryCurrent);
  }

  get chargeLimit(): number | null {
    const value = this.int(VehicleSignal.chargeLimit);
    return value !== null ? value : this.chargePlanLimit;
  }

  /** config 里的充电计划节点：官方 key 是「3」，被 bean 序列化改名时是「_$3」，两个都认。 */
  static chargePlanNode(config: JsonValue | null): JsonValue | null {
    if (config === null) {
      return null;
    }
    const plan = config.get('3');
    return plan !== null ? plan : config.get('_$3');
  }

  static chargePlanLimitFromConfig(config: JsonValue | null): number | null {
    const plan = VehicleState.chargePlanNode(config);
    if (plan === null) {
      return null;
    }
    const percent = plan.get('percent');
    if (percent === null) {
      return null;
    }
    // 空串按官方判据视同没有，不 parse 成 0。
    const text = percent.stringValue;
    if (text === null || text.length === 0) {
      return null;
    }
    return percent.intValue;
  }

  /** 完整充电计划，percent 与 chargePlanLimitFromConfig 同源。config 缺计划时返回 null。 */
  static chargePlanFromConfig(config: JsonValue | null): ChargePlan | null {
    const plan = VehicleState.chargePlanNode(config);
    return plan !== null ? ChargePlan.fromConfigNode(plan) : null;
  }

  get chargeRemainMinutes(): number | null {
    return this.int(VehicleSignal.chargeRemainTime);
  }

  get minSingleTemp(): number | null {
    return this.int(VehicleSignal.minSingleTemp);
  }

  /** 0 未在充电，1 充电中，2 本次充电已结束，3 故障，4 预约等待，6 暂停。 */
  get chargeState(): number | null {
    return this.int(VehicleSignal.chargeState);
  }

  get isCharging(): boolean {
    return this.chargeState === 1;
  }

  /**
   * 健康充电开没开。信号 `48`（2026-08-18 关→开往返实测确认），读不到返回 null。
   * 写入见 `LeapCommand.healthyCharge`。
   */
  get healthyChargeOn(): boolean | null {
    return this.bool(VehicleSignal.healthyCharge);
  }

  /** 充电枪是否插上。只有 C11 那套数字 ID 报这一项，S01/T03 读不到（返回 null）。 */
  get chargeGunConnected(): boolean | null {
    const fastRaw = this.raw(VehicleSignal.fastCharging);
    const fast = fastRaw !== null ? fastRaw !== '0' : null;
    const slow = this.bool(VehicleSignal.chargeGunConnected);
    if (fast === null && slow === null) {
      return null;
    }
    return fast === true || slow === true;
  }

  /** 充电功率（kW）。车不上报功率，用电压 × 电流算，取绝对值。 */
  get chargePowerKW(): number | null {
    const voltage = this.batteryVoltage;
    const current = this.batteryCurrent;
    if (voltage === null || current === null) {
      return null;
    }
    return Math.abs(voltage * current) / 1000;
  }

  /** 直流快充。判据：非空且不等于 0（不是 == "1"）。 */
  get isFastCharging(): boolean {
    const value = this.raw(VehicleSignal.fastCharging);
    if (value === null || value.length === 0) {
      return false;
    }
    return value !== '0';
  }

  // 增程
  /**
   * 是不是增程/混动车。
   *
   * 语义就是**这台车是不是增程车**。判据跟官方对齐：来自 vehicle/list 响应里
   * 每辆车的 `abilities` 数组含能力码 "39"（官方内部 key isExtendRange），
   * 由 LeapClient 注入到 isExtendRange，这里直接透出去。
   *
   * 早先拿 signalMap 里「有没有汽油续航字段」判增程，被现实打脸两次：纯电车
   * 一样会上报非零的汽油续航（3256/3259），于是纯电车被误判成增程车，能源页
   * 多出几格、首页和卡片多出一条油量条。signalMap 各字段都不可靠——纯电车该报
   * 的照报、恒为 0 的也有，唯一稳的判据是官方 abilities 里的能力码。
   */
  get hasFuel(): boolean {
    return this.isExtendRange;
  }

  /**
   * 油量百分比。纯电车即使报了这一项也不给——纯电 C01 报的是 0，
   * 直接透出去首页和桌面卡片就会画一条空油量条。
   */
  get gasolinePercent(): number | null {
    return this.hasFuel ? this.int(VehicleSignal.gasolinePercent) : null;
  }

  private get usesWLTC(): boolean {
    return this.int(VehicleSignal.workingCondition) === 1;
  }

  get energyRange(): number | null {
    return this.int(this.usesWLTC ? VehicleSignal.wltcEnergyRange : VehicleSignal.cltcEnergyRange);
  }

  get gasolineRange(): number | null {
    return this.int(this.usesWLTC ? VehicleSignal.wltcGasolineRange : VehicleSignal.cltcGasolineRange);
  }

  get totalRange(): number | null {
    return this.int(this.usesWLTC ? VehicleSignal.wltcTotalRange : VehicleSignal.cltcTotalRange);
  }

  /**
   * 燃油加热中。先要是台有油箱的车：纯电 C11 实测 2946 = 1，
   * 光看这个字段会说它在给燃油加热。
   */
  get isFuelHeating(): boolean {
    return this.hasFuel && (this.bool(VehicleSignal.fuelHeating) ?? false);
  }

  // 驾驶状态
  /** 行车中。官方判据就是挡位取 1 或 3。 */
  get isDriving(): boolean {
    const gear = this.int(VehicleSignal.gearStatus);
    return gear === 1 || gear === 3;
  }

  get powerOn3(): boolean | null {
    return this.bool(VehicleSignal.powerOn3);
  }

  // 哨兵
  /**
   * 哨兵模式当前开没开。
   *
   * 哨兵没有独立的状态查询接口，状态藏在 signalMap 里：差分「开→看→关」三段采样，
   * 信号 `3636` 干净地 0→1→0 与开关完全对齐（见 apk-analysis/sentinel-mode-interfaces.md）。
   * 只有数字口径的车报这一位（S01/T03 本就不支持哨兵），映射收在 numeric schema。
   * 读不到（旧车况、或不支持哨兵的车）按 int 返回 null，`=== 1` 自然落到 false。
   */
  get sentinelOn(): boolean {
    return this.int(VehicleSignal.sentinel) === 1;
  }

  // 遮阳帘 / 天窗
  /**
   * 遮阳帘开没开（信号 `1724`，0…100 开度）。开度 > 0 就算开、等于 0 才算关——
   * 下发 `240` 开发的是 `"10"`，车回报的开度是 10 还是 100 没验过，所以不拿目标值比对。
   * 读不到 null。
   */
  get sunshadeOpen(): boolean | null {
    const value = this.int(VehicleSignal.sunshadeOpening);
    if (value === null) {
      return null;
    }
    return value > 0;
  }

  /**
   * 天窗开没开（信号 `1718`，0…10 开度）。
   *
   * **超出 0…10 一律当读不到**：没选装可开启天窗的车会报 `15` / `150` 这类 CAN 占位值
   * （Signal Not Available），按「> 0 即开」读会把一辆根本没天窗的车说成天窗开着。
   */
  get sunroofOpen(): boolean | null {
    const value = this.int(VehicleSignal.sunroofOpening);
    if (value === null || value < 0 || value > 10) {
      return null;
    }
    return value > 0;
  }

  // MARK: 舒适座舱 / 车载冰箱（同 iOS `CabinComfort.swift` 里的 VehicleState 扩展）

  /**
   * 某个座位某条通道的当前档位。**读不到返回 null**，界面整块隐藏，不退 0——
   * 退 0 等于断言「这个座位有加热、现在是关的」，而实际可能是这车根本没这个座位。
   */
  seatLevel(position: SeatPosition, channel: SeatComfortChannel): number | null {
    const value = this.int(SeatChannels.signal(channel, position));
    if (value === null) {
      return null;
    }
    return Math.min(SeatChannels.maxLevel, Math.max(0, value));
  }

  /** 这条通道上有档位可读的座位。空数组表示整条通道都读不到。 */
  seats(channel: SeatComfortChannel): SeatPosition[] {
    return SeatPositions.all.filter((position: SeatPosition): boolean =>
      this.seatLevel(position, channel) !== null);
  }

  /** 二排两座里有任何一项可读。决定座位图画两行还是只画前排。 */
  get hasRearSeatComfort(): boolean {
    return SeatChannels.all.some((channel: SeatComfortChannel): boolean =>
      SeatPositions.rear.some((position: SeatPosition): boolean => this.seatLevel(position, channel) !== null));
  }

  get hasSeatComfort(): boolean {
    return SeatChannels.all.some((channel: SeatComfortChannel): boolean => this.seats(channel).length > 0);
  }

  /**
   * 舒适座舱页上**至少有一块东西能显示**。整页的门控用它，而不是用能力码——
   * 信号比能力码更贴车端，方向盘加热还压根没有能力码。
   */
  get hasCabinComfort(): boolean {
    return this.hasSeatComfort || this.steeringWheelHeatLevel !== null || this.mirrorHeatingOn !== null;
  }

  /** 方向盘加热档位：0 关、1 弱、2 强。读不到 null。 */
  get steeringWheelHeatLevel(): number | null {
    const value = this.int(VehicleSignal.steeringWheelHeating);
    if (value === null) {
      return null;
    }
    return Math.min(2, Math.max(0, value));
  }

  /**
   * 方向盘加热剩余分钟。
   *
   * **只在加热确实开着时才给值。** 信号 `1624` 在加热关闭时也非 0——实测 C16 实测
   * `1816 = 0`（没开）而 `1624` 先是 `2`、后来跳到 `15`。拿它当「正在加热」的佐证
   * 会在界面上凭空报出一个加热中，所以这里用 `1816` 把门。
   */
  get steeringWheelHeatMinutes(): number | null {
    const level = this.steeringWheelHeatLevel;
    if (level === null || level <= 0) {
      return null;
    }
    const minutes = this.int(VehicleSignal.steeringWheelHeatMinutes);
    if (minutes === null || minutes <= 0) {
      return null;
    }
    return minutes;
  }

  /** 后视镜加热开没开。两侧任一为开即算开；两侧都读不到返回 null。 */
  get mirrorHeatingOn(): boolean | null {
    const left = this.int(VehicleSignal.leftMirrorHeating);
    const right = this.int(VehicleSignal.rightMirrorHeating);
    if (left === null && right === null) {
      return null;
    }
    return (left ?? 0) > 0 || (right ?? 0) > 0;
  }

  /** 两侧后视镜加热状态不一致。只有两侧都读到才有意义。 */
  get mirrorHeatingMismatched(): boolean {
    const left = this.int(VehicleSignal.leftMirrorHeating);
    const right = this.int(VehicleSignal.rightMirrorHeating);
    if (left === null || right === null) {
      return false;
    }
    return (left > 0) !== (right > 0);
  }

  /** 后风挡（含外后视镜）电加热除雾。cmdid 440 的第三个候选确认位。 */
  get rearWindowHeatingOn(): boolean | null {
    const value = this.int(VehicleSignal.rearWindowHeating);
    if (value === null) {
      return null;
    }
    return value > 0;
  }

  /** 冰箱状态。`fridgeSwitch` 读不到即 null。 */
  get fridgeState(): FridgeState | null {
    const switchValue = this.int(VehicleSignal.fridgeSwitch);
    if (switchValue === null) {
      return null;
    }
    const fridge = new FridgeState();
    fridge.enabled = switchValue === 1;
    fridge.mode = FridgeText.modeFromSignal(this.int(VehicleSignal.fridgeMode));
    fridge.targetTemp = this.int(VehicleSignal.fridgeTargetTemp);
    fridge.style = FridgeText.styleFromSignal(this.int(VehicleSignal.fridgeStyle));
    fridge.fault = this.int(VehicleSignal.fridgeFault) ?? 0;
    fridge.parkEnabled = this.int(VehicleSignal.fridgeParkSwitch) === 1;
    fridge.parkHours = this.int(VehicleSignal.fridgeParkDurationHours);
    const endSeconds = this.double(VehicleSignal.fridgeParkEndTime) ?? 0;
    fridge.parkEndsAt = endSeconds > 0 ? endSeconds * 1000 : null;
    return fridge;
  }

  // 门锁
  get isLocked(): boolean | null {
    return this.bool(VehicleSignal.driverDoorLocked);
  }

  get doorControlAllowed(): boolean {
    return this.bool(VehicleSignal.doorControlAllowed) ?? true;
  }

  get trunkOpen(): boolean | null {
    return this.bool(VehicleSignal.trunkOpen);
  }

  get frontTrunkOpen(): boolean | null {
    return this.bool(VehicleSignal.frontTrunkOpen);
  }

  get anyDoorOpen(): boolean {
    const doors: VehicleSignal[] =
      [VehicleSignal.driverDoor, VehicleSignal.passengerDoor, VehicleSignal.leftRearDoor, VehicleSignal.rightRearDoor];
    for (let i = 0; i < doors.length; i++) {
      if (this.bool(doors[i]) === true) {
        return true;
      }
    }
    return false;
  }

  // 车窗（对外一律是开度百分比：0 关闭、100 全开）
  /**
   * 这台车能不能远程控车窗。
   *
   * **支持位单独用判不出来**：两台 T03 实测（2026-08-10），一台能控、一台不能，
   * `isSupportWindowsRemoteControl` **都报 `2`**。官方那条 `== 2` 是必要不充分条件。
   *
   * 真正的分水岭是**四个开度字段在不在**：能控的那台 60 个字段，比不能控的多且只多
   * `leftFrontWindowPercent` 那四个开度（外加一个无关的 `parkOutEnable`）；
   * 不能控的那台只有 `*WindowStatus` 四个开合状态位。讲得通——电动升降窗的电机有位置
   * 反馈才报得出开度，手摇窗只有一组给防盗用的开关传感器。
   *
   * **这条只对语义名那套（S01 / T03）成立，绝不能推广到数字口径**：C11 增程版实测
   * 四个开度全缺，但它的车窗是能控的，而且数字口径那套压根不报支持位——
   * 官方在那套解析里直接把车窗开关置 true。所以按「有没有报支持位」区分两套口径。
   */
  get windowsRemoteSupported(): boolean {
    const flag = this.raw(VehicleSignal.windowsRemoteSupported);
    if (flag === null) {
      // 没报支持位 = 数字口径那套，官方无条件放行。
      return true;
    }
    if (flag !== '2') {
      return false;
    }
    return this.raw(VehicleSignal.leftFrontWindow) !== null
      || this.raw(VehicleSignal.rightFrontWindow) !== null
      || this.raw(VehicleSignal.leftRearWindow) !== null
      || this.raw(VehicleSignal.rightRearWindow) !== null;
  }

  private windowOpenness(signal: VehicleSignal): number | null {
    const value = this.int(signal);
    if (value === null) {
      return null;
    }
    return WindowScaleUtil.openness(this.schema.windowScale, value);
  }

  /**
   * 单扇窗的开合状态位。官方判据原样照抄：**非 `'0'` 即开**
   * （`OooOOO0.OooO0OO()` 里 `!get_$1693().equals("0")`），不是 `=== '2'`——
   * 这组信号不止 0/2 两个取值，只认 2 会把别的开启档漏成「关着」。
   *
   * **布尔字面量要先认**：T03 这组状态位报的是 `'true'` / `'false'`（实测），
   * 而 `'false' !== '0'` 是成立的——直接套官方判据，四扇关好的窗会全报成开着。
   * 数字口径那组不受影响：`'0'` 走布尔分支同样是 false，`'2'` 认不出布尔、
   * 落回 `!== '0'` 仍是开着。
   */
  private windowOpenFlag(signal: VehicleSignal): boolean | null {
    const value = this.raw(signal);
    if (value === null || value.length === 0) {
      return null;
    }
    const flag = this.bool(signal);
    if (flag !== null) {
      return flag;
    }
    return value !== '0';
  }

  /**
   * 从开度字段判开没开。判据按车型各自的源码来（S01 是 `!= 10`、T03 是 `!= 0`），
   * 不是统一的「百分比 > 0」。
   */
  private windowOpenByOpenness(signal: VehicleSignal): boolean | null {
    const value = this.int(signal);
    if (value === null) {
      return null;
    }
    return WindowScaleUtil.isOpen(this.schema.windowScale, value);
  }

  get leftFrontWindow(): number | null {
    return this.windowOpenness(VehicleSignal.leftFrontWindow);
  }

  get rightFrontWindow(): number | null {
    return this.windowOpenness(VehicleSignal.rightFrontWindow);
  }

  get leftRearWindow(): number | null {
    return this.windowOpenness(VehicleSignal.leftRearWindow);
  }

  get rightRearWindow(): number | null {
    return this.windowOpenness(VehicleSignal.rightRearWindow);
  }

  get leftFrontWindowOpen(): boolean | null {
    return this.windowOpenFlag(VehicleSignal.leftFrontWindowOpen);
  }

  get rightFrontWindowOpen(): boolean | null {
    return this.windowOpenFlag(VehicleSignal.rightFrontWindowOpen);
  }

  get leftRearWindowOpen(): boolean | null {
    return this.windowOpenFlag(VehicleSignal.leftRearWindowOpen);
  }

  get rightRearWindowOpen(): boolean | null {
    return this.windowOpenFlag(VehicleSignal.rightRearWindowOpen);
  }

  /**
   * 有没有窗开着。读不到任何一路车窗信号时是 null——不知道不等于关好了。
   *
   * **两组信号取或：任何一路说开就算开**，不分主次。
   *
   * 先前是「状态位优先、开度兜底」，被真车打脸：2026-08-10 那台 T03 车窗实际开着，
   * 四扇开度都报 `18`，而四个 `*WindowStatus` **仍然全报 `false`**（车况是 34 秒前的，
   * 不是没刷新）。状态位优先于是界面说「已关」——该报的时候不报，比不知道更糟。
   *
   * 反过来「开度优先」也不对：官方在两套口径上判据本来就不一样——数字口径（C11）
   * 判开合读的是状态位 `1693…1696`（开度那组只喂 3D 车模动画），而语义名口径的
   * T03 分支（`isT03Car()`）判的是开度 `leftFrontWindowPercent != 0`。真按开度优先，
   * C11 那边「开度报 0、状态位说开」的情形会被读成关着。
   *
   * 取或同时满足两边，而且方向是安全的：宁可多报一次「窗开着」，不能漏报。
   */
  get anyWindowOpen(): boolean | null {
    const readings: (boolean | null)[] = this.opennessWindowSignals
      .map((sig: VehicleSignal) => this.windowOpenByOpenness(sig));
    readings.push(this.leftFrontWindowOpen, this.rightFrontWindowOpen,
      this.leftRearWindowOpen, this.rightRearWindowOpen);
    if (!readings.some((flag: boolean | null) => flag !== null)) {
      return null;
    }
    return readings.some((flag: boolean | null) => flag === true);
  }

  /**
   * 这台车按开度口径实际有的车窗。
   *
   * S01（invertedTen）是两门轿跑，**没有后窗**——车端后窗字段恒报占位 0，
   * 而倒序刻度里 0 恰好是「全开」。把后窗算进来，关好的 S01 会因为那个占位 0
   * 被读成「全开」，整车永远显示车窗开着。所以倒序刻度只认前两扇；
   * percent（C11 / T03）那套后窗是真的，四扇全认。
   */
  private get opennessWindowSignals(): VehicleSignal[] {
    return this.schema.windowScale === WindowScale.invertedTen
      ? [VehicleSignal.leftFrontWindow, VehicleSignal.rightFrontWindow]
      : [VehicleSignal.leftFrontWindow, VehicleSignal.rightFrontWindow,
         VehicleSignal.leftRearWindow, VehicleSignal.rightRearWindow];
  }

  /**
   * 四扇窗里开得最大的那个开度。车不报开度时是 null——**这和「关着」是两回事**，
   * 界面得靠 `anyWindowOpen` 才知道到底开没开。
   */
  get maxWindowOpenness(): number | null {
    const values: (number | null)[] = this.opennessWindowSignals
      .map((sig: VehicleSignal) => this.windowOpenness(sig));
    let best: number | null = null;
    values.forEach((value: number | null) => {
      if (value !== null && (best === null || value > best)) {
        best = value;
      }
    });
    return best;
  }

  /**
   * 锁车成功那一刻还开着的东西，给「已上锁，XX 还开着」那句提示用（同 iOS `openItemsAfterLock`）。
   *
   * 只列**读得到且确实开着**的项，读不到的一律不算——不知道不等于开着，也不能猜。
   * 单扇窗的判据跟 `anyWindowOpen` 同一套（开度和状态位取或），四扇都开就合成一个「车窗」。
   * 遮阳帘不在里面：它开着不是隐患，锁车时不必提醒。
   */
  get openItemsAfterLock(): string[] {
    const items: string[] = [];
    if (this.anyDoorOpen) {
      items.push('车门');
    }
    const openness = this.opennessWindowSignals;
    const windowOpen = (signal: VehicleSignal, flag: boolean | null): boolean => {
      const byOpenness = openness.includes(signal) ? this.windowOpenByOpenness(signal) : null;
      return byOpenness === true || flag === true;
    };
    const windows: [string, boolean][] = [
      ['主驾车窗', windowOpen(VehicleSignal.leftFrontWindow, this.leftFrontWindowOpen)],
      ['副驾车窗', windowOpen(VehicleSignal.rightFrontWindow, this.rightFrontWindowOpen)],
      ['左后车窗', windowOpen(VehicleSignal.leftRearWindow, this.leftRearWindowOpen)],
      ['右后车窗', windowOpen(VehicleSignal.rightRearWindow, this.rightRearWindowOpen)]
    ];
    const openWindows = windows.filter((item: [string, boolean]): boolean => item[1])
      .map((item: [string, boolean]): string => item[0]);
    if (openWindows.length === windows.length) {
      items.push('车窗');
    } else {
      openWindows.forEach((name: string) => {
        items.push(name);
      });
    }
    if (this.sunroofOpen === true) {
      items.push('天窗');
    }
    if (this.trunkOpen === true) {
      items.push('尾门');
    }
    if (this.frontTrunkOpen === true) {
      items.push('前备箱');
    }
    return items;
  }

  // 空调
  get acOn(): boolean {
    return this.bool(VehicleSignal.acSwitch) ?? false;
  }

  /** -1 表示无有效值；夹取到 18…32。 */
  get acSetting(): number | null {
    const value = this.int(VehicleSignal.acSetting);
    if (value === null || value < 0) {
      return null;
    }
    return Math.min(32, Math.max(18, value));
  }

  get acFanLevel(): number | null {
    return this.int(VehicleSignal.acFanLevel);
  }

  get acModeRaw(): number | null {
    return this.int(VehicleSignal.acMode);
  }

  /** 车上当前的空调模式。车没上报就是 null。 */
  get climateMode(): ClimateMode | null {
    return ClimateModeCodingUtil.mode(this.schema.climateModeCoding, this.acModeRaw);
  }

  /**
   * true=内循环。
   *
   * 数字口径（C11 那批）原先**没有这一项**，空调页那张「内循环 / 外循环」卡只能显示本机草稿。
   * 2026-11-19 补上信号 `1943` 后两套口径都能读到真实状态，`syncDraftsFromState` 会自动对齐。
   */
  get acCircleIn(): boolean | null {
    return this.bool(VehicleSignal.acCircleMode);
  }

  /** 前挡除雾（除霜）状态位。数字口径信号 `1945`，读不到 null。 */
  get windshieldDefrostOn(): boolean | null {
    return this.bool(VehicleSignal.windshieldDefrost);
  }

  /** 快速降温 / 快速制热是否正在执行。数字口径信号 `2669` / `2681`。 */
  get rapidCoolingOn(): boolean | null {
    return this.bool(VehicleSignal.rapidCooling);
  }

  get rapidHeatingOn(): boolean | null {
    return this.bool(VehicleSignal.rapidHeating);
  }

  /** true=auto，false=manual */
  get acAutoMode(): boolean | null {
    return this.bool(VehicleSignal.acTempMode);
  }

  get indoorTemp(): number | null {
    return this.double(VehicleSignal.indoorTemp);
  }

  get outdoorTemp(): number | null {
    return this.double(VehicleSignal.outdoorTemp);
  }

  // 胎压
  get tirePressures(): TirePressure[] {
    return [
      {
        label: '左前',
        kPa: this.double(VehicleSignal.leftFrontTirePressure),
        warning: this.raw(VehicleSignal.leftFrontTireState) === '1'
      },
      {
        label: '右前',
        kPa: this.double(VehicleSignal.rightFrontTirePressure),
        warning: this.raw(VehicleSignal.rightFrontTireState) === '1'
      },
      {
        label: '左后',
        kPa: this.double(VehicleSignal.leftRearTirePressure),
        warning: this.raw(VehicleSignal.leftRearTireState) === '1'
      },
      {
        label: '右后',
        kPa: this.double(VehicleSignal.rightRearTirePressure),
        warning: this.raw(VehicleSignal.rightRearTireState) === '1'
      }
    ];
  }

  get hasTireData(): boolean {
    return this.tirePressures.some((t: TirePressure) => t.kPa !== null);
  }

  get hasTireWarning(): boolean {
    return this.tirePressures.some((t: TirePressure) => t.warning);
  }

  // 位置
  get latitude(): number | null {
    return this.double(VehicleSignal.latitude);
  }

  get longitude(): number | null {
    return this.double(VehicleSignal.longitude);
  }

  get privacyGPSAllowed(): boolean {
    return this.bool(VehicleSignal.privacyGPS) ?? true;
  }

  get collectTime(): string | null {
    return this.raw(VehicleSignal.collectTime);
  }

  /**
   * 车端采集这份车况的时刻（毫秒）。读不到或不可信时是 null。
   *
   * 和 `collectedAt` 是两回事：后者只说明本机什么时候拉的，轮询拉得再勤它都是「刚刚」。
   * 车休眠着不上报时，服务端会把同一份旧数据一直发回来，只有这个字段能看出车况到底有多旧。
   */
  get reportedAt(): number | null {
    const raw = this.collectTime;
    return raw !== null ? VehicleState.parseReportTime(raw) : null;
  }

  /**
   * 车端时间戳解析。两种形态都见过：`2026-08-05 09:40:12` 这样的字面时间，
   * 以及秒/毫秒 epoch。字面时间不带时区，按本机时区解释——车和手机在同一个国家。
   *
   * 解析不出、或者落在「三十天前到五分钟后」这个窗口之外的，一律当读不到：
   * 车端时间是拿来标注车况新旧的，宁可退回本机拉取时间，也不能报一个 1970 年。
   */
  static parseReportTime(raw: string, now: number = Date.now()): number | null {
    const text = raw.trim();
    if (text.length === 0) {
      return null;
    }
    let millis: number = 0;
    if (/^\d+$/.test(text)) {
      const value = Number(text);
      if (!Number.isFinite(value) || value <= 0) {
        return null;
      }
      // 十位数是秒，十三位数是毫秒。按量级判断，不数位数。
      millis = value < 1e11 ? value * 1000 : value;
    } else {
      // 日期和时间之间可能是空格也可能是 T，秒可以缺省，末尾的毫秒/时区后缀直接扔掉。
      const halves = text.replace('T', ' ').split(' ');
      const date = halves[0].split('-');
      const time = halves.length > 1 ? halves[1].split(':') : [];
      if (date.length !== 3 || time.length < 2) {
        return null;
      }
      const year = Number(date[0]);
      const month = Number(date[1]);
      const day = Number(date[2]);
      const hour = Number(time[0]);
      const minute = Number(time[1]);
      // 秒位可能带小数（`12.480`），Number 认得，Date 也接得住取整后的值。
      const second = time.length > 2 ? Math.trunc(Number(time[2])) : 0;
      if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)
        || !Number.isFinite(hour) || !Number.isFinite(minute) || !Number.isFinite(second)) {
        return null;
      }
      millis = new Date(year, month - 1, day, hour, minute, second).getTime();
    }
    if (!Number.isFinite(millis)) {
      return null;
    }
    // 允许略微超前：车端时钟和手机差几十秒很常见，不该因此判定为不可信。
    if (millis > now + 5 * 60 * 1000 || millis < now - 30 * 24 * 3600 * 1000) {
      return null;
    }
    return millis;
  }

  get totalMileage(): number | null {
    return this.int(VehicleSignal.totalMileage);
  }

  /** 可以对外展示的车辆坐标。隐私模式下车端不给真实位置，非法值也一并挡掉。 */
  get shareableCoordinate(): Coordinate | null {
    if (!this.privacyGPSAllowed) {
      return null;
    }
    const lat = this.latitude;
    const lon = this.longitude;
    if (lat === null || lon === null) {
      return null;
    }
    if (Math.abs(lat) > 90 || Math.abs(lon) > 180 || (lat === 0 && lon === 0)) {
      return null;
    }
    return { latitude: lat, longitude: lon };
  }
}

export interface TirePressure {
  label: string;
  kPa: number | null;
  warning: boolean;
}

// MARK: - 控车命令

/** 车窗控制界面上的一个可选档位。开度百分比：0 关闭、100 全开。 */
export interface WindowPreset {
  label: string;
  openness: number;
}

/** 指令的预期终态类型。 */
export enum ExpectationKind {
  locked,
  climate,
  windowPosition,
  trunkOpen,
  frontTrunkOpen,
  sentinel,
  /** 座椅加热 / 通风档位。八个座椅信号都在实测 C16 的真实 signalMap 里，档位能直接比对。 */
  seatLevel,
  /** 方向盘加热档位（信号 1816）。 */
  steeringWheelLevel,
  /**
   * 后视镜加热开关。**三个信号任一翻到位就算确认**：`49`、`50`，还有 `1946`
   * （后风挡「及外后视镜」电加热除雾）。cmdid 440 到底动的是哪一个没验过，不赌一个。
   */
  mirrorHeating,
  /**
   * 遮阳帘 / 天窗开合（信号 `1724` / `1718`）。只在车确实报这个信号时才会用上，
   * 不报的车构造器直接给 unobservable，见 `LeapCommand.sunshade(open, observable)`。
   */
  sunshadeOpen,
  sunroofOpen,
  /**
   * 启停充电（cmdid 193）。确认判据照 leapauto 的实车规则：开始要等充电状态 `1149` 报 1；
   * 停止接受 0（未在充）/ 2（本次已结束）/ 4（预约等待）/ 6（暂停）——3 是故障，不算「停下来了」。
   */
  charging,
  /**
   * 车载冰箱。开关必比；开机时再比模式、目标温度、风格，车端没报的项跳过
   * （照空调那条「缺值不作否决」的宽松判法）。
   */
  fridge,
  unobservable
}

/**
 * 一条指令声明一个能在 signalMap 上验证的终态，轮询车况直到达成。
 * 下发成功只代表服务端受理，车可能还在休眠，实测要 5–10 秒才动作。
 */
export class ControlExpectation {
  readonly kind: ExpectationKind;
  readonly boolValue: boolean;
  readonly intValue: number;
  // climate 专用
  readonly climateOn: boolean;
  readonly temperature: number | null;
  readonly fanLevel: number | null;
  readonly mode: ClimateMode | null;
  // seatLevel 专用
  seatPosition: SeatPosition = SeatPosition.driver;
  seatChannel: SeatComfortChannel = SeatComfortChannel.heating;
  // fridge 专用
  fridgeSetting: FridgeSetting | null = null;

  private constructor(kind: ExpectationKind, boolValue: boolean, intValue: number,
    climateOn: boolean, temperature: number | null, fanLevel: number | null, mode: ClimateMode | null) {
    this.kind = kind;
    this.boolValue = boolValue;
    this.intValue = intValue;
    this.climateOn = climateOn;
    this.temperature = temperature;
    this.fanLevel = fanLevel;
    this.mode = mode;
  }

  static locked(expected: boolean): ControlExpectation {
    return new ControlExpectation(ExpectationKind.locked, expected, 0, false, null, null, null);
  }

  static climate(on: boolean, temperature: number | null, fanLevel: number | null,
    mode: ClimateMode | null): ControlExpectation {
    return new ControlExpectation(ExpectationKind.climate, false, 0, on, temperature, fanLevel, mode);
  }

  static windowPosition(expected: number): ControlExpectation {
    return new ControlExpectation(ExpectationKind.windowPosition, false, expected, false, null, null, null);
  }

  static trunkOpen(expected: boolean): ControlExpectation {
    return new ControlExpectation(ExpectationKind.trunkOpen, expected, 0, false, null, null, null);
  }

  static frontTrunkOpen(expected: boolean): ControlExpectation {
    return new ControlExpectation(ExpectationKind.frontTrunkOpen, expected, 0, false, null, null, null);
  }

  static sentinel(expected: boolean): ControlExpectation {
    return new ControlExpectation(ExpectationKind.sentinel, expected, 0, false, null, null, null);
  }

  static seatLevel(position: SeatPosition, channel: SeatComfortChannel, level: number): ControlExpectation {
    const expectation = new ControlExpectation(ExpectationKind.seatLevel, false, level, false, null, null, null);
    expectation.seatPosition = position;
    expectation.seatChannel = channel;
    return expectation;
  }

  static steeringWheelLevel(level: number): ControlExpectation {
    return new ControlExpectation(ExpectationKind.steeringWheelLevel, false, level, false, null, null, null);
  }

  static mirrorHeating(on: boolean): ControlExpectation {
    return new ControlExpectation(ExpectationKind.mirrorHeating, on, 0, false, null, null, null);
  }

  static sunshadeOpen(open: boolean): ControlExpectation {
    return new ControlExpectation(ExpectationKind.sunshadeOpen, open, 0, false, null, null, null);
  }

  static sunroofOpen(open: boolean): ControlExpectation {
    return new ControlExpectation(ExpectationKind.sunroofOpen, open, 0, false, null, null, null);
  }

  static charging(start: boolean): ControlExpectation {
    return new ControlExpectation(ExpectationKind.charging, start, 0, false, null, null, null);
  }

  static fridge(setting: FridgeSetting): ControlExpectation {
    const expectation = new ControlExpectation(ExpectationKind.fridge, setting.enabled, 0, false, null, null, null);
    expectation.fridgeSetting = setting.copy();
    return expectation;
  }

  static unobservable(): ControlExpectation {
    return new ControlExpectation(ExpectationKind.unobservable, false, 0, false, null, null, null);
  }

  get isObservable(): boolean {
    return this.kind !== ExpectationKind.unobservable;
  }

  isSatisfied(state: VehicleState): boolean {
    switch (this.kind) {
      case ExpectationKind.locked:
        return state.isLocked === this.boolValue;

      case ExpectationKind.climate: {
        if (state.acOn !== this.climateOn) {
          return false;
        }
        if (!this.climateOn) {
          return true;
        }
        // 车端偶尔会夹取或省略某一项，缺值时不作为否决条件。
        if (this.temperature !== null) {
          const actual = state.acSetting;
          if (actual !== null && actual !== this.temperature) {
            return false;
          }
        }
        if (this.fanLevel !== null) {
          const actual = state.acFanLevel;
          if (actual !== null && actual > 0 && actual !== this.fanLevel) {
            return false;
          }
        }
        if (this.mode !== null) {
          const actual = state.climateMode;
          if (actual !== null && actual !== this.mode) {
            return false;
          }
        }
        return true;
      }

      case ExpectationKind.windowPosition: {
        // 留 ±5 的容差：车窗停位不是数字精确的，T03 实测发 `50` 车报回 `51`，
        // 精确相等会把一次成功的控车判成「未收到车辆确认」。
        // S01 那边刻度本来就是 10 的整倍数，容差对它没有影响。
        const actual = state.leftFrontWindow;
        if (actual === null) {
          return false;
        }
        return Math.abs(actual - this.intValue) <= 5;
      }

      case ExpectationKind.trunkOpen:
        return state.trunkOpen === this.boolValue;

      case ExpectationKind.frontTrunkOpen:
        // 前备箱看信号 1282（frontTrunkOpen）。只有 C11 那套数字口径有这个字段，
        // 但支持判据（supportsFrunk）本来就把 legacy 车型挡在门外，走不到这里。
        return state.frontTrunkOpen === this.boolValue;

      case ExpectationKind.sentinel:
        // 哨兵终态就看信号 3636 翻没翻到位（sentinelOn 由它派生）。
        return state.sentinelOn === this.boolValue;

      case ExpectationKind.sunshadeOpen:
        return state.sunshadeOpen === this.boolValue;

      case ExpectationKind.sunroofOpen:
        return state.sunroofOpen === this.boolValue;

      case ExpectationKind.charging: {
        const charge = state.chargeState;
        if (charge === null) {
          return false;
        }
        return this.boolValue ? charge === 1 : [0, 2, 4, 6].includes(charge);
      }

      case ExpectationKind.seatLevel: {
        const actual = state.seatLevel(this.seatPosition, this.seatChannel);
        return actual !== null && actual === this.intValue;
      }

      case ExpectationKind.steeringWheelLevel: {
        const actual = state.steeringWheelHeatLevel;
        return actual !== null && actual === this.intValue;
      }

      case ExpectationKind.mirrorHeating: {
        // 三个候选位里只要有一个报到期望值就算确认。全都读不到 / 全都没翻 → 不算。
        const left = state.int(VehicleSignal.leftMirrorHeating);
        const right = state.int(VehicleSignal.rightMirrorHeating);
        const candidates: (boolean | null)[] = [
          left === null ? null : left > 0,
          right === null ? null : right > 0,
          state.rearWindowHeatingOn
        ];
        return candidates.some((value: boolean | null): boolean => value === this.boolValue);
      }

      case ExpectationKind.fridge: {
        const fridge = state.fridgeState;
        const setting = this.fridgeSetting;
        if (fridge === null || setting === null) {
          return false;
        }
        if (fridge.enabled !== setting.enabled) {
          return false;
        }
        if (!setting.enabled) {
          return true;
        }
        if (fridge.mode !== setting.mode) {
          return false;
        }
        if (fridge.targetTemp !== null && fridge.targetTemp !== setting.wireTemperature) {
          return false;
        }
        return fridge.style === setting.style;
      }

      default:
        return false;
    }
  }
}

/**
 * 车辆驻车时自动上传的最近一张照片。接口没有历史列表，也不会触发车辆临时拍照。
 *
 * 与 iOS 侧 `ParkingPhoto` 一一对应。
 */
export class ParkingPhoto {
  readonly available: boolean;
  readonly url: string | null;
  readonly uploadTime: string | null;
  readonly raw: JsonValue;

  private constructor(available: boolean, url: string | null, uploadTime: string | null, raw: JsonValue) {
    this.available = available;
    this.url = url;
    this.uploadTime = uploadTime;
    this.raw = raw;
  }

  static fromResponse(response: JsonValue): ParkingPhoto {
    const data = response.get('data');
    const urlText = data === null ? null : data.get('fileUrl')?.stringValue ?? null;
    const rawTime = data === null ? null : data.get('uploadTime')?.stringValue ?? null;
    const url = urlText === null ? null : ParkingPhoto.secureImageURL(urlText.trim());
    const uploadTime = rawTime !== null && rawTime.length > 0 ? rawTime : null;
    return new ParkingPhoto(url !== null, url, uploadTime, response);
  }

  /**
   * 上传时刻的中文写法。
   *
   * 车端给的是纪元时间字符串，秒和毫秒两种都出现过——大于 10^10 的按毫秒算。
   * 不是数字就原样透出，宁可显示个奇怪的字符串，也不要凭空编一个时间出来。
   */
  get displayUploadTime(): string | null {
    if (this.uploadTime === null) {
      return null;
    }
    const timestamp = Number.parseFloat(this.uploadTime);
    if (Number.isNaN(timestamp) || !Number.isFinite(timestamp)) {
      return this.uploadTime;
    }
    const millis = timestamp > 10000000000 ? timestamp : timestamp * 1000;
    const date = new Date(millis);
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`
      + ` ${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  /**
   * 老接口仍可能返回 `http://` 图片地址；图片服务支持 HTTPS，统一在信任边界升级。
   *
   * 没有 `URLComponents` 可用，只能手拆：协议 + 主机 + 剩下的原样保留。
   * 拆不出主机的一律当无效地址丢掉，免得把一段畸形文本当图片去下载。
   */
  private static secureImageURL(text: string): string | null {
    if (text.length === 0) {
      return null;
    }
    const normalized = text.startsWith('//') ? `https:${text}` : text;
    const lower = normalized.toLowerCase();
    let rest = '';
    if (lower.startsWith('https://')) {
      rest = normalized.substring(8);
    } else if (lower.startsWith('http://')) {
      rest = normalized.substring(7);
    } else {
      return null;
    }
    // 主机段止于第一个 `/`、`?`、`#`，三者取最靠前的一个。
    let cut = rest.length;
    const marks = ['/', '?', '#'];
    for (let i = 0; i < marks.length; i++) {
      const index = rest.indexOf(marks[i]);
      if (index >= 0 && index < cut) {
        cut = index;
      }
    }
    let authority = rest.substring(0, cut);
    const tail = rest.substring(cut);
    if (authority.length === 0) {
      return null;
    }
    // 升到 HTTPS 之后 `:80` 就不再是那个端口的意思了，去掉走默认 443。
    if (authority.endsWith(':80')) {
      authority = authority.substring(0, authority.length - 3);
      if (authority.length === 0) {
        return null;
      }
    }
    return `https://${authority}${tail}`;
  }
}

/** 一条待发送的远控指令：cmdid + state JSON。 */
export class LeapCommand {
  cmdid: string;
  stateJSON: string;
  label: string;
  requiresOperationPassword: boolean;
  expectation: ControlExpectation;

  constructor(cmdid: string, stateJSON: string, label: string,
    requiresOperationPassword: boolean = true,
    expectation: ControlExpectation = ControlExpectation.unobservable()) {
    this.cmdid = cmdid;
    this.stateJSON = stateJSON;
    this.label = label;
    this.requiresOperationPassword = requiresOperationPassword;
    this.expectation = expectation;
  }

  /** 预约类命令走另一个端点，且优先打到 appCenter。 */
  private static readonly appointmentCmdIds: string[] = ['161', '171', '361', '392'];

  get isAppointment(): boolean {
    return LeapCommand.appointmentCmdIds.indexOf(this.cmdid) >= 0;
  }

  /** 这条指令会动空调设定。取消或失败时界面上的草稿要退回去。 */
  get changesClimate(): boolean {
    return this.cmdid === '170';
  }

  static lock(): LeapCommand {
    return new LeapCommand('110', '{"value":"lock"}', '上锁', true, ControlExpectation.locked(true));
  }

  static unlock(): LeapCommand {
    return new LeapCommand('110', '{"value":"unlock"}', '解锁', true, ControlExpectation.locked(false));
  }

  /**
   * 这台车能不能远程关尾门。
   *
   * 只有 C11 那套口径的车型能，S01 / T03 不能，三条依据指向同一件事：
   * 零跑官方 App 在这些车上只给「打开尾门」、没有关闭；真车发过 `cmdid 130` 的
   * `value=false`，车没有任何反应；车本身也没有能自己合上的电动尾门——
   * 弹得开、合不上是物理限制，不是接口没适配。
   * 所以关闭这个选项在这些车上既不该摆在界面上，也不该在后台被替用户发出去。
   */
  static trunkSupportsClose(carType: string): boolean {
    return !CarTypeFamily.isLegacyFamily(carType);
  }

  /**
   * 关闭发的 `false` 没有文档依据，是照着开启那条推的。车不认的话指令会静默失败——
   * 等不到 `trunkOpen` 翻转，App 会如实报「未收到车辆确认」，不会有别的动作。
   * 界面和卡片都先过 `trunkSupportsClose`，关不了的车型根本走不到这条分支。
   */
  static trunk(open: boolean = true): LeapCommand {
    return new LeapCommand(
      '130',
      open ? '{"value":"true"}' : '{"value":"false"}',
      open ? '打开尾门' : '关闭尾门',
      true,
      ControlExpectation.trunkOpen(open)
    );
  }

  /**
   * 哨兵模式开 / 关。cmdid=400，抓包实测（apk-analysis/sentinel-mode-interfaces.md §1）。
   *
   * **state 的 key 是 `operation` 不是别的命令用的 `value`**：开 `{"operation":"on"}`、
   * 关 `{"operation":"off"}`。和尾门（130）一样是受权控命令，需操作密码（官方开关前先验密码）。
   * 终态用车况的 sentinelOn（信号 3636）确认，和空调/门锁同一套等待机制。
   */
  static sentinel(on: boolean): LeapCommand {
    return new LeapCommand(
      '400',
      on ? '{"operation":"on"}' : '{"operation":"off"}',
      on ? '开启哨兵' : '关闭哨兵',
      true,
      ControlExpectation.sentinel(on)
    );
  }

  /**
   * 天幕遮阳帘开 / 关。cmdid 240（README「尚未接入的接口」表，实车验证过 cmdid）：
   * 开 `{"value":"10"}`、关 `{"value":"0"}`。
   *
   * **2026-11-19 起可确认**：遮阳帘开度是信号 `1724`（0…100），实测 C16 在报。
   * 但不是每台车都报，所以由调用方告诉这条指令「这车报不报」——报就等信号翻转，
   * 不报仍走 unobservable，发完如实说「已发送」。不能一刀切成可观测：
   * 不报的车会永远等不到翻转，每次都误报「未收到车辆确认」。
   */
  static sunshade(open: boolean, observable: boolean = false): LeapCommand {
    return new LeapCommand(
      '240',
      open ? '{"value":"10"}' : '{"value":"0"}',
      open ? '打开遮阳帘' : '关闭遮阳帘',
      true,
      observable ? ControlExpectation.sunshadeOpen(open) : ControlExpectation.unobservable()
    );
  }

  /**
   * 天窗开 / 关。cmdid 300：开 `{"value":"1"}`、关 `{"value":"0"}`。
   *
   * 这里原先写着「任何口径的车况里都没有天窗字段」——那是错的：天窗开度是信号 `1718`
   * （0…10）。只是实测用的那台 C16 没有可开启天窗、不报这一项，所以同遮阳帘按车决定可不可观测。
   */
  static sunroof(open: boolean, observable: boolean = false): LeapCommand {
    return new LeapCommand(
      '300',
      open ? '{"value":"1"}' : '{"value":"0"}',
      open ? '打开天窗' : '关闭天窗',
      true,
      observable ? ControlExpectation.sunroofOpen(open) : ControlExpectation.unobservable()
    );
  }

  /**
   * 前备箱开 / 关。cmdid 131：开 `{"value":"100"}`、关 `{"value":"0"}`。
   * 确认走车况信号 1282（VehicleState.frontTrunkOpen）。关闭那条和尾门一样是照开启推的：
   * 车不认就等不到 1282 翻转，App 如实报「未收到车辆确认」，不会有别的动作。
   */
  static frunk(open: boolean): LeapCommand {
    return new LeapCommand(
      '131',
      open ? '{"value":"100"}' : '{"value":"0"}',
      open ? '打开前备箱' : '关闭前备箱',
      true,
      ControlExpectation.frontTrunkOpen(open)
    );
  }

  static horn(): LeapCommand {
    return new LeapCommand('120', '{"value":"true"}', '鸣笛寻车');
  }

  static batteryPreheat(on: boolean): LeapCommand {
    return new LeapCommand(
      '160',
      on ? '{"value":"ptcon"}' : '{"value":"ptcoff"}',
      on ? '电池预热开启' : '电池预热关闭'
    );
  }

  /**
   * 预约电池预热。cmdid 161（2026-08-18 实测，见 iOS 侧
   * `apk-analysis/android-battery-charge-interfaces.md` §0.3）：
   * 预约接口要求把预约对象包在 `controls` 数组里，`on` 是字符串 `"1"`/`"0"`，
   * `set_id` 实测格式是「前缀_VIN_创建毫秒」（官方用 `Android_`，这里如实标 `HarmonyOS_`
   * ——服务端大概率只要求唯一性），`update_time` 与 set_id 尾部同为那个毫秒时间戳。
   *
   * `days` 用预约类指令共用的星期编码：**0 = 周日**、1 = 周一 … 6 = 周六（见 `AppointmentWeekday`）。
   * 2026-11-19 之前界面给周日发的是 7，已改（和 iOS 同一天同一套）。
   */
  static batteryPreheatAppointment(on: boolean, startTime: Date, days: number[],
    vin: string, setID: string | null = null): LeapCommand {
    const timestamp = Date.now();
    const appointmentID = setID !== null && setID.length > 0
      ? setID
      : `HarmonyOS_${vin}_${timestamp}`;
    // 手写而不是 JSON.stringify：ArkTS 的 stringify 对 Record 里混装数组/字符串
    // 会走 any 分支，编译期直接报错。字段顺序照 iOS 的 sortedKeys 排。
    const dayList = days.length === 0 ? '' : days.join(',');
    const state = `{"controls":[{"days":[${dayList}],"on":"${on ? '1' : '0'}"`
      + `,"set_id":"${appointmentID}","start_time":"${LeapCommand.appointmentTime(startTime)}"`
      + `,"update_time":"${timestamp}"}]}`;
    return new LeapCommand('161', state, on ? '预约电池预热' : '关闭预约预热');
  }

  /** 预约接口要的时刻格式：`yyyy-MM-dd HH:mm:ss`，本机时区。 */
  private static appointmentTime(date: Date): string {
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
      + ` ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  }

  /**
   * 远程开始 / 停止充电。cmdid 193，走普通远控端点。
   *
   * **停止发 `finish`，不是 `stop`**：leapauto 2026-10-31 官方抓包确认车端 OBC 只认
   * `start` / `finish`，发 `stop` 服务端照收、车不理。确认判据见 `ExpectationKind.charging`。
   */
  static charging(start: boolean): LeapCommand {
    return new LeapCommand(
      '193',
      start ? '{"value":"start"}' : '{"value":"finish"}',
      start ? '开始充电' : '停止充电',
      true,
      ControlExpectation.charging(start)
    );
  }

  /**
   * 解锁充电枪。cmdid 192，state 的 key 是 `operation`（同哨兵，不是 `value`）。
   *
   * **确认不了**，只能如实说「已发送」。看着能用的信号 `94`（官方读作慢充枪锁止）不行：
   * C11 四种情形实测过，停充未拔枪时它已经是 0——拿它当判据，「解锁」一发出就被判成功，
   * 是假确认。插枪位 `47` 也不行：解锁后枪还插着，要人去拔它才翻。
   */
  static unlockChargingGun(): LeapCommand {
    return new LeapCommand('192', '{"operation":"unlock"}', '解锁充电枪');
  }

  /**
   * 健康充电开关。cmdid 480（2026-08-18 实测，§0.1）：开 `{"value":"on"}`、关 `{"value":"off"}`，
   * 走普通远控端点。车况里可判定：信号 `48`（见 `VehicleState.healthyChargeOn`），
   * 回读靠下次拉车况。
   */
  static healthyCharge(on: boolean): LeapCommand {
    return new LeapCommand(
      '480',
      on ? '{"value":"on"}' : '{"value":"off"}',
      on ? '开启健康充电' : '关闭健康充电'
    );
  }

  /**
   * 充电上限 + 预约充电（合并一条，cmdid 190；2026-08-18 实测见 §0.2）。
   *
   * 写入字段名与读取 `config."3"` 不同、且全小写：`percent→chargesoc`、`isEnable→chargeEnable`、
   * `beginTime→starttime`、`endTime→endtime`，`cycles`/`circulation`/`recharge` 同名。
   * 只改充电上限、不开预约充电也走这条，`chargeEnable=0`。`circulation`/`recharge` 含义未确认，
   * 原样回填车辆上报的那份（读不到则按实测样本默认 1/0），不擅自改。车况无判定位，
   * 所以 expectation 留 unobservable。
   */
  static chargePlan(limitPercent: number, scheduledEnabled: boolean,
    startTime: string, endTime: string, cycles: boolean[],
    circulation: number = 1, recharge: number = 0): LeapCommand {
    const bits: string[] = [];
    for (let i = 0; i < 7; i++) {
      bits.push(i < cycles.length && cycles[i] ? '1' : '0');
    }
    const soc = Math.max(50, Math.min(100, Math.round(limitPercent)));
    const state = `{"chargeEnable":${scheduledEnabled ? 1 : 0},"chargesoc":${soc}`
      + `,"circulation":${circulation},"cycles":"${bits.join(',')}"`
      + `,"endtime":"${endTime}","recharge":${recharge},"starttime":"${startTime}"}`;
    return new LeapCommand('190', state, '充电计划');
  }

  /** 这台车的车窗远控能做到哪几档。 */
  static windowPresets(carType: string): WindowPreset[] {
    // 四档是统一的开度百分比，各车型下发时再按自己的刻度换算（见 windowValue）。
    // S01 / T03 原先少一个「半开」，那是没来由的：S01 的 `5`（倒序 0…10 的中点）
    // 和 T03 的 `50` 都是能发的值，T03 那个 `50` 真车验过就是开一半。
    return [
      { label: '关闭', openness: 0 },
      { label: '微开', openness: 20 },
      { label: '半开', openness: 50 },
      { label: '全开', openness: 100 }
    ];
  }

  /**
   * 给滑杆的车型：S01 和 T03。
   *
   * 能不能给滑杆看两条：刻度得是连续的，且下发和上报得是同一套刻度——
   * 松手后车报回来的位置要对得上滑杆停的位置，否则就是「拖到哪儿都没有回音」。
   *
   * S01 是 0…10 十一个刻度，早就验过。**T03 是 2026-08-10 验的**，而且比 S01 还干净：
   * 下发 `50` 车报回 `51`（那个 1 是电机停位精度），刻度是真正的 0…100。
   *
   * C11 那组仍然不给：下发 0…10、上报 0…100，两边不是一套
   * （见 `window()` 走 unobservable 的原因）。
   */
  static windowSupportsSlider(carType: string): boolean {
    return CarTypeFamily.isLegacyFamily(carType);
  }

  static windowValue(openness: number, carType: string): string {
    const value = Math.min(100, Math.max(0, openness));
    if (CarTypeFamily.isS01(carType)) {
      return String(WindowScaleUtil.raw(WindowScale.invertedTen, value));
    }
    // T03：下发就是 0…100 的百分比，**线性**，原样发。
    //
    // 这里原先抄 demo 映射成 `0 / 20 / 50` 三档，把 `50` 当成「全开档位码」——
    // 2026-08-10 真车证伪：点「全开」（我们发 `50`），**车窗只开了一半**。
    // `50` 就是 50%，不是全开。全开得发 `100`。
    if (CarTypeFamily.isT03(carType)) {
      return String(value);
    }
    // C11 及其余车型：上报 0…100，下发 0…10，差十倍。
    return String(Math.trunc(value / 10));
  }

  static window(openness: number, carType: string): LeapCommand {
    const value = LeapCommand.windowValue(openness, carType);
    // S01 和 T03 的下发刻度和上报刻度是同一套，比对上报值才有意义。
    // C11 那套口径两边不是一套：下发 0…10、上报 0…100，发 `2` 之后车报回来是不是
    // 正好 20 至今没验过，拿它比对会误报未响应。
    const expectation = CarTypeFamily.isLegacyFamily(carType)
      ? ControlExpectation.windowPosition(Math.min(100, Math.max(0, openness)))
      : ControlExpectation.unobservable();
    return new LeapCommand('230', `{"value":"${value}"}`, '车窗控制', true, expectation);
  }

  static climate(on: boolean, temperature: number, fanLevel: number, mode: ClimateMode,
    circleIn: boolean, windshield: boolean, position: string = 'all'): LeapCommand {
    const stateObj: Record<string, string> = {
      // 自动走 operate 这一层，真车验证过；mode 那一层是死路。
      'operate': on ? (mode === ClimateMode.auto ? 'auto' : 'manual') : 'off',
      'temperature': String(temperature),
      'windlevel': String(fanLevel),
      'mode': on ? ClimateModeInfo.wireValue(mode) : 'nohotcold',
      'circle': circleIn ? 'in' : 'out',
      'wshld': windshield ? '1' : '0',
      // 出风位置。协议本来支持分区（`all` / `wshld` / 座位位置），我们一直硬编码 `all`——
      // 连前挡除雾都在往全车吹，白耗一半风量。现在由调用方给，默认仍是 `all`。
      'position': position
    };
    const json = JSON.stringify(stateObj);
    return new LeapCommand(
      '170',
      json,
      on ? '空调开启' : '空调关闭',
      true,
      ControlExpectation.climate(
        on,
        on ? temperature : null,
        on ? fanLevel : null,
        on ? mode : null
      )
    );
  }

  static quickCool(): LeapCommand {
    const command = LeapCommand.climate(true, 18, 7, ClimateMode.cold, true, false);
    command.label = '极速降温';
    return command;
  }

  static quickHeat(): LeapCommand {
    const command = LeapCommand.climate(true, 32, 7, ClimateMode.hot, true, false);
    command.label = '极速升温';
    return command;
  }

  /**
   * 快速除味（leapauto `QUICK_DEODORIZE_STATE`，2026-11-19 对照补上，同 iOS）：
   * 通风（`nohotcold`，不制冷也不制热）+ **外循环** + 7 档 + 不开除雾，24 ℃ 只是占位——
   * 通风模式下温度不起作用，但协议要求字段齐全。
   *
   * 判据沿用空调那套（开着 / 7 档 / 通风模式）。**温度不进判据**：通风模式下车会不会把设定温度
   * 改成 24 没验过，车若保留原温度，带着温度比对就会把成功误报成「未收到车辆确认」。
   * 外循环 `1943` 也不进判据：它的取值方向只有一次观察，宁可少判一项也不误报。
   */
  static deodorize(): LeapCommand {
    const command = LeapCommand.climate(true, 24, 7, ClimateMode.vent, false, false);
    command.label = '快速除味';
    command.expectation = ControlExpectation.climate(true, null, 7, ClimateMode.vent);
    return command;
  }

  /**
   * 前挡除雾。
   *
   * **2026-11-19 修正两处方向错误**（同 iOS）：
   * - `circle` 原先发 `in`（内循环）。除雾的物理前提是把干燥的外气引进来，
   *   内循环等于把车里的湿气闷住再吹上玻璃，方向是反的。改 `out`。
   * - `position` 原先跟着 `climate` 硬编码的 `all` 往全车吹，一半风量白耗。改 `wshld`。
   *
   * 温度和模式**故意不跟 leapauto**：它那条发的是 24 ℃ 制冷（靠压缩机除湿），
   * 在冬天结霜的玻璃上不如热风干得快。我们保留 32 ℃ 制热 7 档。
   */
  static defrost(): LeapCommand {
    const command = LeapCommand.climate(true, 32, 7, ClimateMode.hot, false, true, 'wshld');
    command.label = '前挡除雾';
    return command;
  }

  // MARK: 舒适座舱 / 车载冰箱（同 iOS `CabinComfort.swift` 的 LeapCommand 扩展）

  /** 座椅加热 / 通风。`level` 0 就是关闭，没有单独的关闭指令。 */
  static seatComfort(position: SeatPosition, channel: SeatComfortChannel, level: number): LeapCommand {
    const clamped = Math.min(SeatChannels.maxLevel, Math.max(0, Math.trunc(level)));
    const action = clamped === 0 ? '关闭' : ` ${clamped} 档`;
    return new LeapCommand(
      SeatChannels.cmdid(channel),
      `{"position":"${SeatPositions.wireValue(position)}","level":"${clamped}"}`,
      `${SeatPositions.label(position)}${SeatChannels.label(channel)}${action}`,
      true,
      ControlExpectation.seatLevel(position, channel, clamped)
    );
  }

  /**
   * 方向盘加热。`level` 0 关、1 弱、2 强——**只有两档**，和座椅不是一套量程。
   *
   * ⚠️ `level` 这里发的是 **JSON 数字**，不是座椅那样的字符串。leapauto 的代码发数字、
   * 它自己的文档写字符串，两者只能有一个对，按代码走。真车不动时第一个要试的就是
   * 换成 `{"level":"2"}`。
   */
  static steeringWheelHeating(level: number): LeapCommand {
    const clamped = Math.min(2, Math.max(0, Math.trunc(level)));
    const action = clamped === 0 ? '关闭' : (clamped === 1 ? '弱档' : '强档');
    return new LeapCommand(
      '320',
      `{"level":${clamped}}`,
      `方向盘加热${action}`,
      true,
      ControlExpectation.steeringWheelLevel(clamped)
    );
  }

  /**
   * 后视镜加热。开 `"2"`、关 `"1"`——**不是 `"1"`/`"0"`**。
   *
   * 这是五项里唯一官方 App 自己都没做的：内部码 `440` 在官方 APK 里连中文文案都没有。
   * 能力码 `59 → 440` 在实测车上在场，信号 `49`/`50`/`1946` 也在报，但下发这条没有任何实车样本。
   */
  static mirrorHeating(on: boolean): LeapCommand {
    return new LeapCommand(
      '440',
      on ? '{"value":"2"}' : '{"value":"1"}',
      on ? '开启后视镜加热' : '关闭后视镜加热',
      true,
      ControlExpectation.mirrorHeating(on)
    );
  }

  /** 车载冰箱。state 是全量的，见 `FridgeSetting.stateJSON`。 */
  static fridge(setting: FridgeSetting): LeapCommand {
    let label: string;
    if (!setting.enabled) {
      label = '关闭车载冰箱';
    } else if (setting.mode === FridgeMode.hot) {
      label = `冰箱保温 ${FridgeSetting.hotTemp} ℃`;
    } else {
      label = `冰箱制冷 ${setting.wireTemperature} ℃ · ${FridgeText.styleLabel(setting.style)}`;
    }
    return new LeapCommand('500', setting.stateJSON, label, true, ControlExpectation.fridge(setting));
  }

  // MARK: 预约空调（同 iOS `ClimateAppointment.swift` 的 LeapCommand 扩展）

  /**
   * 预约空调。cmdid 171，走预约端点（`appointmentCmdIds` 里本来就有 171）。
   *
   * 字段值全用字符串（`on` / `temperature` / `windlevel` 等），`days` 是整数数组——
   * 照官方抓包 `[681]` 的形态，不自作主张统一类型。字段顺序照 iOS 的 sortedKeys 排。
   * 没有车况信号可确认，下发后由 store 回读 `getappointment` 当确认。
   */
  static climateAppointment(appointment: ClimateAppointment, vin: string, now: Date = new Date()): LeapCommand {
    const millis = now.getTime();
    const setID = appointment.setID !== null && appointment.setID.length > 0
      ? appointment.setID
      : `HarmonyOS_${vin}_${millis}`;
    const days = appointment.days.slice().sort((a: number, b: number): number => a - b);
    const temperature = Math.min(ClimateAppointment.maxTemperature,
      Math.max(ClimateAppointment.minTemperature, appointment.temperature));
    const state = `{"controls":[{"circle":"in","days":[${days.join(',')}]`
      + `,"mode":"${appointment.mode}","on":"1","operate":"manual","position":"all"`
      + `,"set_id":"${setID}","start_time":"${LeapCommand.appointmentTime(appointment.nextStart(now))}"`
      + `,"temperature":"${temperature}","update_time":"${millis}","windlevel":"7","wshld":"1"}]}`;
    return new LeapCommand('171', state, '预约空调');
  }

  /**
   * 取消预约空调：**发空的 `controls`**，不是发一条 `on: "0"` 的预约项。
   * 官方取消抓包 `cancel/[332]` 就是这样，随后回读 `[334]` 拿到的也是空 `controls`。
   */
  static cancelClimateAppointment(): LeapCommand {
    return new LeapCommand('171', '{"controls":[]}', '取消预约空调');
  }
}

/** 控车下发后服务端返回的回执。 */
export interface ControlReceipt {
  msgID: string;
  label: string;
  sentAt: number;
}
