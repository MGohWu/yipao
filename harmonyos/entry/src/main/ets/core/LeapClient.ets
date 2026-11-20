import { BLECalibration } from './BLECalibration';
import { LeapBLEProtocol, LeapBLEConfiguration, BLEUnlockDistance } from './BLEProtocol';
import { JsonValue } from './JsonValue';
import { LeapCrypto } from './LeapCrypto';
import { LeapError, LeapErrorKind } from './LeapError';
import { DiagLog } from './DiagLog';
import { HttpTransport, BodyKind } from './HttpTransport';
import { CrossProcessLock, LockHolding } from './CrossProcessLock';
import { SessionStore } from './SecureStore';
import { SignalSchema } from './SignalSchema';
import { LearnedSignals } from './Calibration';
import { DrivingStats, DrivingStatsRange, EnergyDistribution, WeeklyEC, weekEcId } from './DrivingStats';
import { CarModel } from './CarModel';
import { ClimateAppointment } from './ClimateAppointment';
import { LeapBLEKeyCertificate } from './BLEProtocol';
import {
  LeapSession, SessionUtil, OldAuth, NewAuth, AuthUtil, Vehicle, VehicleUtil, VehicleRoute,
  VehicleState, LeapConstants, LeapCommand, ControlReceipt, ChargePlan, ParkingPhoto
} from './LeapModels';

/**
 * 零跑中国 App 链路客户端。
 *
 * 服务端同时存在两套鉴权：
 * - 老链路（appuser.leapmotor.cn / carownerservice / 远控）：MD5 短签名 + `XFX-CDN-CROSS-NODE` token。
 * - 新网关（app-gw-global）：HMAC-SHA256(signKey) 签名 + JWT accessToken。
 * 远控、里程、位置走老链路，车辆列表/路由/车况走新网关，两条链路的 token 各自续期。
 *
 * **一个进程里只该有一个实例**（主应用是 `VehicleStore` 里那个，卡片进程是
 * `LeapFormAbility` 里现开的那个）。`sessionData` 在 `restore()` 时读一次，
 * 之后只在内存里更新——同一进程内写的人只有一个，就不会自己覆盖自己。
 *
 * 但**跨进程有两个写者**：卡片进程会联网刷新车况、会直发控车，它手里那份会话是
 * 卡片被拉起那一刻的快照。整份写回就会互相覆盖——把对方刚换来的 token 抹成几小时前
 * 的旧值，下次续期拿着作废的 refreshToken 去问服务端，被拒后按登录态失效处理，
 * 用户莫名其妙回到登录页（iOS 正是这么出的事）。所以落盘分三档，别混用：
 *
 * - `persistAuth()`：**整份**写回并打上新版本号。只有本进程就是权威的那几步能用——
 *   登录、退登、重置会话。
 * - `persistTokens()`：续期专用。以**磁盘那份为底**，只把凭证字段盖上去，
 *   选中车、车辆列表一概不碰。
 * - `persist()`：其余（选中车、路由、车型别名这些）。写之前先 `syncAuthFromStore()`
 *   把别人换发的凭证捞回来，免得连带把新 token 盖回旧的。
 *
 * 「谁新听谁的」靠 `LeapSession.authRevision`；两边**同时**发起续期的那个窗口
 * 版本号管不了，靠 `refreshLock` 关上。
 */
export class LeapClient {
  private sessionData: LeapSession;
  private readonly store: SessionStore;

  /** 并发调用时只跑一次续期。这只挡得住本进程，跨进程那道是 `refreshLock`。 */
  private refreshTask: Promise<void> | null = null;
  private oldRefreshTask: Promise<void> | null = null;

  /** 老链路连着几次 39 了。任何一次成功都清零，见 `noteOldAuthFailure`。 */
  private oldAuthFailureStreak: number = 0;
  /** 这串连败是什么时候开始的（毫秒）。连点三下不算，得真的拖过一个窗口。 */
  private oldAuthFailureStreakStartedAt: number = 0;

  /**
   * 续期的跨进程互斥。两条链路共用一把：老链路续期尾部还会重换新网关凭证，
   * 两把锁反而要考虑重入。锁内第一件事永远是 `syncAuthFromStore()`——
   * 等锁的这段时间里，别的进程多半已经把新凭证换好写回了。
   */
  private readonly refreshLock: CrossProcessLock = new CrossProcessLock('token-refresh.lock');

  /**
   * 充电计划缓存。commonConfig 是张几乎不变的配置表，没必要每轮车况轮询都拉一次。
   * 最多缓存 15 秒；编辑页和保存后强制读取，失败保留上次成功值。
   * `cachedConfigVin` 记的是「已成功拉到的那台车」，换车即失效——绝不把上一台车的计划贴过来。
   */
  private cachedChargePlan: ChargePlan | null = null;
  private cachedChargePlanLimit: number | null = null;
  private cachedConfigVin: string = '';
  private configFetchedAt: number = 0;
  private configAccount: string = '';
  private configRequest: number = 0;

  constructor(store: SessionStore = new SessionStore()) {
    this.store = store;
    this.sessionData = SessionUtil.fresh();
  }

  /** 从关键资产载入已保存的会话。应用启动时调一次。 */
  async restore(): Promise<void> {
    const saved = await this.store.load();
    if (saved !== null) {
      this.sessionData = saved;
    }
    // 设备号单独一条，会话读不到时它也可能读得到（反过来同理）。两件事分开取。
    await this.ensureDeviceIdLoaded();
  }

  /**
   * 把关键资产里那条设备号捞回内存。已经有了就什么都不做。
   *
   * 关键资产在设备首次解锁前读不到，这条路要能被反复走——每个异步的请求入口
   * （`oldAuthedRequest` / `newGatewayRequest`）都会先来一次，等到能读了自然就接上了。
   */
  private async ensureDeviceIdLoaded(): Promise<boolean> {
    if (this.sessionData.deviceId.length > 0) {
      return true;
    }
    const stored = await this.store.loadDeviceId();
    if (stored === null) {
      return false;
    }
    this.sessionData.deviceId = stored;
    DiagLog.note('[auth] 从关键资产读回 deviceId');
    return true;
  }

  /**
   * 登录链路专用：没有设备号就现发一个并立刻落盘。
   *
   * **只有这里**允许生成新设备号。别处凭空发一个，老签名链路的 `deviceID` 就跟服务端
   * 记的对不上，一律 result=39。
   */
  private async ensureDeviceId(): Promise<void> {
    if (await this.ensureDeviceIdLoaded()) {
      return;
    }
    const generated = SessionUtil.randomDeviceId();
    this.sessionData.deviceId = generated;
    // 立刻落盘：登录请求带的就是它，服务端拿它绑 token。这一步没写成，下次启动就成了
    // 「服务端记着一个设备号、本机手里另一个」——老链路全废。
    await this.store.saveDeviceId(generated);
    DiagLog.note('[auth] 生成新的 deviceId（登录流程）');
  }

  /**
   * 发请求前的最后一道闸：设备号是空的就别发。
   *
   * 空设备号签出来的请求服务端必回 result=39，而 39 会被上层当成「token 该刷新了」——
   * 于是刷新永远成功、重试永远失败，用户看到的就是「按什么都提示指令下发失败」。
   * 宁可这一次明说「解锁手机后重试」。
   */
  private requireDeviceId(): void {
    if (this.sessionData.deviceId.length > 0) {
      return;
    }
    DiagLog.note('[auth] 拒绝在 deviceId 为空时发请求（关键资产仍读不到）');
    throw LeapError.server('设备信息暂时读不到，请解锁手机后重试');
  }

  get session(): LeapSession {
    return this.sessionData;
  }

  /**
   * 一般落盘（选中车、路由、车型别名这些）。
   *
   * 落盘前先看一眼别的进程有没有换发过凭证。整份写回是会覆盖的：本进程内存里
   * 那份 token 可能是几小时前的，直接盖上去等于把卡片刚换来的新 token 抹掉，
   * 下次续期就拿着作废的 refreshToken 去问服务端，被拒后判成登录失效。
   */
  private async persist(): Promise<void> {
    await this.syncAuthFromStore();
    if (this.sessionData.deviceId.length === 0) {
      // 设备号还没就位（关键资产这一帧读不到）：整份写回会把好端端的设备号抹成空。
      // 这份内存快照本来也发不出请求，丢掉这次写盘不损失什么。
      DiagLog.note('[auth] deviceId 为空，跳过这次写盘');
      return;
    }
    if (!(await this.shouldPersistWholeSession())) {
      return;
    }
    await this.store.save(this.sessionData);
  }

  /**
   * 整份写回之前的最后一道闸：本进程手里这份是不是「空快照」。
   *
   * 设备号只是被这个问题咬得最狠的那个字段，选中车同样会被盖：启动那帧关键资产读失败的
   * 进程（卡片进程会联网刷新、会直发控车）内存里选中车是空的，它一次 `persist()` 就把
   * 关键资产里那辆抹掉——界面读内存、卡片读关键资产，两边从此认的不是同一辆车。
   *
   * 鸿蒙这边读不到和没有分不出来（`AssetVault.read` 两种都返回 null），所以读不到就一概
   * 不写：`persist()` 的调用点全在登录之后，而登录那一步 `persistAuth()` 已经整份写过一次，
   * 正常情况下这里不可能读到 null——读到 null 就说明是读不出来，那更不该写。
   */
  private async shouldPersistWholeSession(): Promise<boolean> {
    const latest = await this.store.load();
    if (latest === null) {
      DiagLog.note('[auth] 跳过整份落盘：这一次读不到关键资产，无从判断手里这份全不全');
      return false;
    }
    // 反过来（内存里有、关键资产里没有）是合法的：选中车变空只发生在退登/重置，
    // 而那两条走的是 `persistAuth()`，不经过这里。
    if (this.sessionData.selectedVin.length === 0 && latest.selectedVin.length > 0) {
      DiagLog.note('[auth] 跳过整份落盘：本进程手里没有选中车，关键资产那份有'
        + `（${VehicleUtil.maskedVin(latest.selectedVin)}）`);
      return false;
    }
    return true;
  }

  /**
   * 凭证变更后**整份**落盘：打上新的版本号，别的进程据此认账。
   *
   * 整份写回意味着本进程手里的选中车、车辆列表也会一起盖上去，所以只有
   * **本进程就是权威**的那几步能用它：登录（要把上一个账号的车清空）、
   * 退登、重置会话。续期不行——见 `persistTokens()`。
   */
  private async persistAuth(): Promise<void> {
    this.sessionData.authRevision = Date.now();
    await this.store.save(this.sessionData);
  }

  /**
   * 续期后落盘，**只写凭证，不碰选中车**。
   *
   * 续期会发生在卡片进程里，而它手里那份会话是进程启动时的快照。用 `persistAuth()`
   * 整份写回的话，换过账号之后会这样：卡片第一次续期时 `syncAuthFromStore` 发现
   * App 换发过，采纳凭证后让路——**但同步只搬凭证，它内存里的选中车还是上一辆**；
   * 等版本号追平，下一次它自己续期就不再让路，于是把上一辆车原样写回了钥匙串。
   * 后果是界面与卡片认的车不一致，App 冷启动也会读到并显示上一辆车。
   *
   * 所以这里以钥匙串里那份为底，只把凭证字段盖上去。钥匙串是空的（还没登录过）
   * 就退回整份写——那种情况下本进程手里这份就是唯一的一份。
   */
  private async persistTokens(): Promise<void> {
    this.sessionData.authRevision = Date.now();
    const latest = await this.store.load();
    if (latest === null) {
      // 钥匙串是空的（还没登录过），本进程手里这份就是唯一的一份。
      if (this.sessionData.deviceId.length === 0) {
        DiagLog.note('[auth] deviceId 为空，跳过这次写盘（续期）');
        return;
      }
      await this.store.save(this.sessionData);
      return;
    }
    const merged = LeapClient.mergeTokens(this.sessionData, latest);
    if (merged === null) {
      return;
    }
    await this.store.save(merged);
  }

  /**
   * 把 `source` 的凭证盖到 `base` 上，选中车、车辆列表、路由一概保留 `base` 的。
   *
   * 返回 null 表示**这一次不该写**：`base` 里已经没有凭证了，说明续期这段时间里
   * App 退了登（`logout` 会写一份空会话）。这时候把手里的新凭证写回去，
   * 等于把刚退出的用户又装回登录态。
   */
  static mergeTokens(source: LeapSession, base: LeapSession): LeapSession | null {
    if (base.oldAuth === null && base.newAuth === null) {
      return null;
    }
    const merged = SessionUtil.snapshot(base);
    merged.oldAuth = source.oldAuth;
    merged.newAuth = source.newAuth;
    merged.authRevision = source.authRevision;
    if (source.phone.length > 0) {
      merged.phone = source.phone;
    }
    return merged;
  }

  /**
   * 从关键资产捞一次别的进程换发的凭证，采纳了返回 true。
   *
   * 只同步凭证本身（`oldAuth` / `newAuth` / `phone`）。车辆列表、选中车、路由不动——
   * 那些是本进程正在用的状态，卡片进程手里的往往更旧。
   */
  private async syncAuthFromStore(): Promise<boolean> {
    const stored = await this.store.load();
    if (stored === null) {
      return false;
    }
    // 设备号顺带对齐：本进程启动那帧可能读不到关键资产，手里这份是空的。
    // 凭证同步得再勤，设备号对不上老链路照样一律 39。
    if (this.sessionData.deviceId.length === 0 && stored.deviceId.length > 0) {
      this.sessionData.deviceId = stored.deviceId;
      DiagLog.note('[auth] 同步凭证时顺带把 deviceId 对齐');
    }
    const mine = this.sessionData.authRevision ?? 0;
    const theirs = stored.authRevision ?? 0;
    if (theirs <= mine) {
      return false;
    }
    this.sessionData.oldAuth = stored.oldAuth;
    this.sessionData.newAuth = stored.newAuth;
    if (stored.phone.length > 0) {
      this.sessionData.phone = stored.phone;
    }
    this.sessionData.authRevision = theirs;
    DiagLog.note(`[auth] 采纳其它进程换发的凭证（revision ${Math.trunc(mine)} → ${Math.trunc(theirs)}）`);
    return true;
  }

  // MARK: - 登录

  async sendSMS(phone: string): Promise<void> {
    // 登录链路是唯一允许发新设备号的地方，从发验证码这步就得有：
    // 下面 `oldAppHeaders()` 的 APPImei 要用它。
    await this.ensureDeviceId();
    const cipher = LeapCrypto.phoneNoCiphertext(phone);
    const query = new Map<string, string>();
    query.set('phoneNo', cipher);
    const response = await HttpTransport.request(
      `${LeapConstants.appUserHost}/app-user/applogin/compliance/sendmessagecode`,
      'GET', this.oldAppHeaders(false), query
    );
    LeapClient.assertSuccess(response, '验证码发送失败');
  }

  /**
   * 短信验证码登录。
   *
   * 第一步先把本机会话清成干净态。这不是顺手做的清理，是这条链路能不能走通的前提：
   * 被官方 App 挤下线后，本机手里那份 `oldAuth.token` 已经被服务端作废，而
   * `oldAppHeaders()` 会把它当 `XFX-CDN-CROSS-NODE` 一起发出去——带着一个作废的
   * token 去打登录接口，验证码再对也会被拒。用户看到的就是「验证码是对的，但报登录异常」。
   *
   * 更糟的是它会自锁死：`oldAuth` 在 `exchangeNewGateway()` **之前**就赋了值，换网关那步
   * 一失败，内存里就留下一份「有 oldAuth、没 newAuth」的半截会话。界面那边 `isLoggedIn`
   * 为假，停在登录页，可 `expireSession()` 的守卫也正是看 `isLoggedIn`，于是清理逻辑一次
   * 都跑不了——用户怎么重试都是同一个脏 token 发出去。
   *
   * 从干净态起步，上面两件事就都不成立了：header 里没有 token 可带，中途失败留下的
   * 也是干净态而不是半截态。顺带也清掉了上一个账号的车辆列表、选中车和机房路由：
   * loadVehicles() 只在 selectedVin 为空时才设默认车，留着旧 VIN 车况请求就会一直打别人的车。
   *
   * 保留 deviceId：换设备号会让老签名链路直接返回 result=39。
   */
  async login(phone: string, smsCode: string): Promise<void> {
    // 直接进登录页（没走发验证码那步，比如码是在别的设备上收到的）时这里才真的生成。
    await this.ensureDeviceId();
    const deviceId = this.sessionData.deviceId;
    this.sessionData = SessionUtil.fresh();
    this.sessionData.deviceId = deviceId;

    const params = new Map<string, string>();
    params.set('phoneNoCiphertext', LeapCrypto.phoneNoCiphertext(phone));
    params.set('smsCode', smsCode);
    params.set('deviceID', this.sessionData.deviceId);
    // 对齐官方 iOS 1.20.64：三个参数放 POST_Form 请求体，密文由传输层百分号编码。
    const response = await HttpTransport.request(
      `${LeapConstants.appUserHost}/app-user/applogin/loginwithphone`,
      'POST', this.oldAppHeaders(false), null, BodyKind.form, params
    );
    LeapClient.assertSuccess(response, '验证码登录失败');

    this.sessionData.phone = phone.trim();
    this.sessionData.oldAuth = LeapClient.extractOldAuth(response);
    try {
      await this.exchangeNewGateway();
    } catch (error) {
      // 换网关失败：把刚拿到的 oldAuth 丢掉，退回干净态再抛。
      // 留着它下一次登录就会带上，一次偶发失败会变成永久登不上。
      this.sessionData = SessionUtil.fresh();
      this.sessionData.deviceId = deviceId;
      throw error as Error;
    }
    await this.persistAuth();
  }

  async logout(): Promise<void> {
    this.sessionData = SessionUtil.fresh();
    await this.store.clear();
    // 退登也是一次凭证变更，且必须是最新的那次：卡片进程可能正跑着一次刷新，
    // 它手里还是旧凭证，写回时得看到「退登比我新」才不会把人又装回登录态。
    await this.persistAuth();
  }

  /** 保留 deviceId 重置会话：换设备号会让老签名链路直接返回 result=39。 */
  async resetSession(): Promise<void> {
    const deviceId = this.sessionData.deviceId;
    this.sessionData = SessionUtil.fresh();
    this.sessionData.deviceId = deviceId;
    await this.store.clear();
    await this.persistAuth();
  }

  /** 用老 token 换新网关的 accessToken / signKey。 */
  private async exchangeNewGateway(): Promise<void> {
    const oldAuth = this.sessionData.oldAuth;
    if (oldAuth === null) {
      throw LeapError.notLoggedIn();
    }
    const body = new Map<string, string>();
    body.set('identifier', oldAuth.accountId);
    body.set('identifierType', '1');
    body.set('security', oldAuth.token);
    const response = await HttpTransport.request(
      `${LeapConstants.globalHost}/base/base-user/account/v1/login`,
      'POST', this.newGatewayHeaders(body, false), null, BodyKind.json, body
    );
    LeapClient.assertSuccess(response, '新网关换取 token 失败');
    this.sessionData.newAuth = LeapClient.extractNewAuth(response, oldAuth);
    // 换网关也是一次凭证变更，但本进程未必是权威（老 token 续期尾部就会走到这里），
    // 所以只合并凭证。登录那条路上紧接着还有一次 persistAuth 整份写回，不受影响。
    await this.persistTokens();
  }

  // MARK: - Token 续期

  /**
   * 续期期间进来的请求先在这儿排一下队，等换发完再带着新凭证出门。
   *
   * 对齐官方的 `CacheRequestManager`：官方在刷新 token 期间把后来的请求整队缓存住，
   * 刷新完拿新 token 重放。我们原来是「照发不误 → 拿旧 token 撞 401/39 → 各自再触发
   * 一次重试」，多打的那几发全是注定失败的，还平白抬高服务端看到的鉴权失败频次
   * （老链路的 39 更是会被风控盯上）。
   *
   * 只等、不发起，也不把续期的错误扣到这条请求头上：等完照发，成不成由它自己那套
   * 判据（401 重试、39 冷却窗口、连败升级）说了算。
   *
   * 续期自身那几发请求走的是 `HttpTransport.request(...)`，不经过这道闸，不会自等自。
   */
  private async awaitOngoingRefresh(): Promise<void> {
    const refresh = this.refreshTask;
    const oldRefresh = this.oldRefreshTask;
    if (refresh === null && oldRefresh === null) {
      return;
    }
    DiagLog.note('[auth] 请求撞上正在进行的续期，先排队等换发完成');
    // 各等一次就够：等到的时候续期已经结束，紧接着又起的新一轮是下一次的事。
    if (refresh !== null) {
      try {
        await refresh;
      } catch (e) {
        // 续期失败不在这里报，交给下面这条请求自己撞出来。
      }
    }
    if (oldRefresh !== null) {
      try {
        await oldRefresh;
      } catch (e) {
        // 同上。
      }
    }
  }

  async refreshAccessToken(): Promise<void> {
    if (this.refreshTask !== null) {
      return this.refreshTask;
    }
    const task = this.performAccessTokenRefresh();
    this.refreshTask = task;
    try {
      await task;
    } finally {
      this.refreshTask = null;
    }
  }

  private async performAccessTokenRefresh(): Promise<void> {
    // 别的进程刚换来一份，直接用它的——refreshToken 每换发一次旧的就作废，
    // 这里再换一次，等于把它那份也作废掉，两个进程会互相把对方踢下线。
    if (await this.syncAuthFromStore()) {
      return;
    }
    // 跨进程串行化：版本号只能让「已写回」的换发被看见，两个进程**同时**
    // 发起续期的窗口要靠锁关上。等到锁后先再看一眼——等锁期间对方多半已换好。
    const holding: LockHolding | null = await this.refreshLock.acquire();
    try {
      if (holding !== null && await this.syncAuthFromStore()) {
        return;
      }
      const newAuth = this.sessionData.newAuth;
      if (newAuth === null || newAuth.refreshToken.length === 0) {
        throw LeapError.sessionExpired();
      }
      const body = new Map<string, string>();
      body.set('refreshToken', newAuth.refreshToken);
      const response = await HttpTransport.request(
        `${LeapConstants.globalHost}/base/base-user/token/v1/refresh`,
        'POST', this.newGatewayHeaders(body, true), null, BodyKind.json, body
      );
      if (!response.isSuccess) {
        // 只有服务端明确说鉴权不过，才算登录态没了。限流、系统繁忙、字段改名都会走到
        // 这里，把它们一律当失效就是无缘无故把用户踢回登录页。网络异常在传输层就抛了。
        if (LeapClient.isNewAuthFailure(response)) {
          // 最后的兜底：被拒可能只是因为手里这份刚被别的进程换掉了（锁超时降级过）。
          // 关键资产里有更新的就采纳，这次续期等于别人替我们完成了。
          if (await this.syncAuthFromStore()) {
            DiagLog.note('[auth] 新链路续期被拒，但别的进程已换发更新的凭证，采纳后继续');
            return;
          }
          // 官方那条静默重登：老 token 还在手里就拿它重换一份新网关凭证
          // （`PublicUtils.reLogin` → `LoginManager` 打的正是这个 account/v1/login）。
          // 新网关的 refreshToken 只是「这一份换发链」断了，老 token 未必也废了——
          // 不试一次就退登，等于把官方从不会退登的那条路自己堵上。
          const oldAuth = this.sessionData.oldAuth;
          if (oldAuth !== null && oldAuth.token.length > 0) {
            try {
              await this.exchangeNewGateway();
              DiagLog.note('[auth] 新链路续期被拒，已用老 token 静默重换新网关凭证');
              return;
            } catch (e) {
              // 网络不通这类传输层故障抛的是系统 BusinessError，不是 LeapError。
              // 咽掉它就会掉进下面的 sessionExpired——一次断网把人踢回登录页。
              if (!(e instanceof LeapError)) {
                throw e as Error;
              }
              DiagLog.note(`[auth] 新链路续期被拒后静默重换也失败：${LeapError.messageOf(e as object)}`);
            }
          }
          throw LeapError.sessionExpired();
        }
        const message = response.responseMessage;
        throw LeapError.server(message.length > 0 ? message : '登录续期失败');
      }
      this.sessionData.newAuth = LeapClient.extractNewAuth(response, this.sessionData.oldAuth);
      await this.persistTokens();
    } finally {
      if (holding !== null) {
        holding.release();
      }
    }
  }

  async refreshOldToken(): Promise<void> {
    if (this.oldRefreshTask !== null) {
      return this.oldRefreshTask;
    }
    const task = this.performOldTokenRefresh();
    this.oldRefreshTask = task;
    try {
      await task;
    } finally {
      this.oldRefreshTask = null;
    }
  }

  /**
   * 老 token 续期：GET /app-user/appuseroperate/getnewtoken。
   * refreshToken 参与签名但不出现在 query 里，只放在 `XFX-CDN-CROSS-REFRESH-NODE` 头。
   */
  private async performOldTokenRefresh(): Promise<void> {
    // 同 performAccessTokenRefresh：别的进程刚换发过就用它那份，不再自己换一次。
    if (await this.syncAuthFromStore()) {
      return;
    }
    // 同上：跨进程串行化，等到锁后再看一眼别人是不是已经换好了。
    const holding: LockHolding | null = await this.refreshLock.acquire();
    try {
      if (holding !== null && await this.syncAuthFromStore()) {
        return;
      }
      const oldAuth = this.sessionData.oldAuth;
      if (oldAuth === null || oldAuth.refreshToken.length === 0) {
        throw LeapError.sessionExpired();
      }
      if (this.sessionData.phone.length === 0) {
        // 本机会话缺了手机号，续期签不出来。这是本地数据问题，不是服务端说登录态没了——
        // 当前 token 只要还没到期就照常能用，不该借机把人踢回登录页。
        throw LeapError.server('本地登录信息不完整，暂时无法续期');
      }
      const accountNumber = LeapCrypto.phoneNoCiphertext(this.sessionData.phone);
      const map = new Map<string, string>();
      map.set('timespan', String(Date.now()));
      map.set('nonce', LeapCrypto.randomNonce());
      map.set('deviceID', this.sessionData.deviceId);
      map.set('refreshtoken', oldAuth.refreshToken);
      map.set('accountId', oldAuth.accountId);
      map.set('accountNumber', accountNumber);
      const signStr = LeapCrypto.shortMD5(LeapCrypto.sortAndConcatValues(map));
      map.delete('refreshtoken');
      map.set('signStr', signStr);

      const headers = this.oldAppHeaders();
      headers.set('XFX-CDN-CROSS-REFRESH-NODE', oldAuth.refreshToken);

      const response = await HttpTransport.request(
        `${LeapConstants.appUserHost}/app-user/appuseroperate/getnewtoken`,
        'GET', headers, map
      );
      const data = response.get('data') ?? response;
      const tokenNode = data.get('token');
      const token = tokenNode !== null ? tokenNode.stringValue : null;
      if (token === null || token.length === 0 || !response.isSuccess) {
        // refreshToken 被服务端明确拒了，救不回来，只能重新短信登录。
        if (LeapClient.isOldAuthFailure(response)) {
          // 兜底同新链路：被拒也可能只是手里这份刚被别的进程换掉了。
          if (await this.syncAuthFromStore()) {
            DiagLog.note('[auth] 老链路续期被拒，但别的进程已换发更新的凭证，采纳后继续');
            return;
          }
          throw LeapError.sessionExpired();
        }
        // 其余情况——限流、系统繁忙、响应结构变了——都不是登录态的事。
        // 原来这里一律抛 sessionExpired，服务端抖一下用户就被踢回登录页了。
        const message = response.responseMessage;
        throw LeapError.server(message.length > 0 ? message : '登录续期失败');
      }
      const expiredNode = data.get('tokenExpired');
      const expiredText = expiredNode !== null ? expiredNode.stringValue : null;
      const expiredSeconds = expiredText !== null && Number.isFinite(Number(expiredText))
        ? Number(expiredText) : 21600;
      const now = Date.now();
      const refreshNode = data.get('refreshToken');
      const newRefresh = refreshNode !== null && refreshNode.stringValue !== null
        ? refreshNode.stringValue : oldAuth.refreshToken;
      this.sessionData.oldAuth = {
        accountId: oldAuth.accountId,
        token: token,
        refreshToken: newRefresh,
        nickname: oldAuth.nickname,
        tokenExpired: String(Math.trunc(expiredSeconds)),
        tokenObtainedAt: now,
        tokenExpiresAt: now + expiredSeconds * 1000
      };
      await this.persistTokens();
      // 新网关凭证绑定在老 token 上，续期后需要重新交换。
      // 在锁里做：它自己不取锁（两条链路共用这一把，取了就是自锁）。
      try {
        await this.exchangeNewGateway();
      } catch (e) {
        // 换不成不影响这次续期的结果（老链路已经好了），但新网关那份会一直用旧的、
        // 直到 401 再走一次续期——所以失败要留痕，否则这条路是全静默的。
        DiagLog.note(`[auth] 老 token 续期后重换新网关凭证失败：${LeapError.messageOf(e as object)}`);
      }
    } finally {
      if (holding !== null) {
        holding.release();
      }
    }
  }

  private async ensureFreshAccessToken(): Promise<void> {
    const newAuth = this.sessionData.newAuth;
    if (newAuth === null) {
      return;
    }
    const expiry = AuthUtil.newExpiresAt(newAuth);
    if (expiry <= 0) {
      return;
    }
    if ((expiry - Date.now()) / 1000 <= LeapConstants.accessTokenLeeway) {
      await this.refreshAccessToken();
    }
  }

  /**
   * 老链路请求 + `result=39` 自愈。对齐官方零跑 App 的做法：39 只当「这份 token 该
   * 刷新了」，不当「登录态没了」。官方 `OKHttpLPClientRequest.tokenExpiration` 对国内
   * 39 一律走 `handleRefreshToken`（刷新后重试），只有网关级 refreshToken 过期码
   * （302010214 / 302010219）才会 `reLogin`——所以官方几乎不会莫名退登。
   *
   * - A：刷新后重试仍是 39，**不再抛 `sessionExpired`**（不清会话、不回登录页），改抛
   *   瞬时业务错误。服务端在刚续期后的短窗口里对老链路回一两次 39 是常见抖动，把它
   *   升级成退登正是「登录约 77 分钟后莫名掉登录」的直接根因。真正的失效仍由
   *   `refreshOldToken` 内部 refreshToken 被拒（→ `sessionExpired`）兜底，对应官方 reLogin。
   * - B：冷却窗口——老 token 是 `oldTokenReauthCooldown` 秒内换发的，再收到 39 就**不刷新**，
   *   直接重试一次，仍失败当瞬时错误。避免一次续期后紧跟的 39 触发第二次续期（旧
   *   refreshToken 立刻作废，反而制造失效窗口），对齐官方 60 秒闸。
   */
  private async oldAuthedRequest(
    transientFailureMessage: string,
    perform: () => Promise<JsonValue>): Promise<JsonValue> {
    // 关键资产这一帧可能才刚变得可读，先把设备号接回来再签名。
    await this.ensureDeviceIdLoaded();
    // 正在换发凭证就先等着，别拿一个马上要作废的 token 出门。
    await this.awaitOngoingRefresh();
    let response = await perform();
    if (!LeapClient.isOldAuthFailure(response)) {
      this.oldAuthFailureStreak = 0;
      return response;
    }

    if (this.recentlyRefreshedOldToken()) {
      // B：冷却窗口内不再续期，直接重试一次。
      DiagLog.note('[auth] 老链路 result=39 命中续期冷却窗口，跳过刷新直接重试');
      response = await perform();
      if (!LeapClient.isOldAuthFailure(response)) {
        this.oldAuthFailureStreak = 0;
        return response;
      }
      // A：仍是 39，当瞬时错误，不退登。
      DiagLog.note('[auth] 老链路冷却窗口内重试仍 result=39，按瞬时错误处理，不退登');
      throw this.noteOldAuthFailure(transientFailureMessage);
    }

    await this.refreshOldToken();
    response = await perform();
    if (LeapClient.isOldAuthFailure(response)) {
      // A：刷新后仍 39，不再判定登录失效——这正是官方不会退登的场景。
      DiagLog.note('[auth] 老链路刷新后仍 result=39，按瞬时错误处理，不退登');
      throw this.noteOldAuthFailure(transientFailureMessage);
    }
    this.oldAuthFailureStreak = 0;
    return response;
  }

  /**
   * 记一次老链路连败，顺便决定这次该抛哪种错。
   *
   * 「不退登」修的是一半问题：偶发 39 不该把人踢回登录页。另一半是——真的失效了
   * （设备号在服务端换了绑、账号被挤下线且 refreshToken 也一起废了）也永远只说
   * 「请稍后重试」，用户按到天亮都不会知道该重新登录。所以连败够多、且拖得够久，
   * 就明说一句。不清会话（那会连蓝牙钥匙证书一起清掉），只是把话说明白。
   */
  private noteOldAuthFailure(transientFailureMessage: string): LeapError {
    const now = Date.now();
    if (this.oldAuthFailureStreak === 0) {
      this.oldAuthFailureStreakStartedAt = now;
    }
    this.oldAuthFailureStreak += 1;
    const spannedSeconds = (now - this.oldAuthFailureStreakStartedAt) / 1000;
    if (!LeapClient.shouldEscalateOldAuthFailure(this.oldAuthFailureStreak, spannedSeconds)) {
      return LeapError.server(transientFailureMessage);
    }
    DiagLog.note(`[auth] 老链路连续 ${this.oldAuthFailureStreak} 次 result=39、`
      + `已持续 ${Math.trunc(spannedSeconds)} 秒，提示重新登录`);
    return LeapError.needsRelogin();
  }

  /// 连败到什么程度才算「重试也不会好」。抽成纯函数是为了能测。
  static shouldEscalateOldAuthFailure(streak: number, spannedSeconds: number): boolean {
    return streak >= LeapConstants.oldAuthFailureEscalationCount
      && spannedSeconds >= LeapConstants.oldAuthFailureEscalationWindow;
  }

  /** 老 token 是否在续期冷却窗口内换发（含登录时初次取得）。 */
  private recentlyRefreshedOldToken(): boolean {
    const oldAuth = this.sessionData.oldAuth;
    if (oldAuth === null || oldAuth.tokenObtainedAt <= 0) {
      return false;
    }
    const age = (Date.now() - oldAuth.tokenObtainedAt) / 1000;
    return age >= 0 && age < LeapConstants.oldTokenReauthCooldown;
  }

  private async ensureFreshOldToken(): Promise<void> {
    const oldAuth = this.sessionData.oldAuth;
    if (oldAuth === null || oldAuth.tokenExpiresAt <= 0) {
      return;
    }
    if ((oldAuth.tokenExpiresAt - Date.now()) / 1000 <= LeapConstants.oldTokenLeeway) {
      try {
        await this.refreshOldToken();
      } catch (e) {
        // 续期失败时让后续请求自己去撞鉴权失败，那条路上有更完整的处理。
      }
    }
  }

  /**
   * 主动校验登录态。开 App、回前台时调用。
   *
   * 车况刷新走的是新网关读取 token——被别的设备挤下线后它仍然活着，所以刷新永远探不到
   * 失效（用户「还能看到页面」正是这个原因）。真正会被服务端作废的是老链路那条控车
   * token。这里主动对它做一次续期探测：refreshToken 被服务端拒 = 登录态没了，抛
   * sessionExpired；网络等其它错误照原样抛出，**不**当作失效——弱网不该把人误踢下线。
   * 续期成功顺带把控车 token 焐热，正好省下之后控车时的那次续期。
   *
   * 但探测不能每次开 App、每次回前台都真打一次续期：老 token 服务端给的是 6 小时，
   * 每探一次就换发一次，探得越勤，撞上限流、撞上误判文案的机会越多——而这条路上
   * 任何一次判错都是把用户清回登录页。所以刚换发过的就直接认有效：那次换发本身
   * 就是服务端对这份登录态的确认，比再问一遍更可信也更便宜。
   */
  async validateSession(): Promise<void> {
    const oldAuth = this.sessionData.oldAuth;
    if (oldAuth === null) {
      throw LeapError.sessionExpired();
    }
    const age = (Date.now() - oldAuth.tokenObtainedAt) / 1000;
    if (oldAuth.tokenObtainedAt > 0 && age >= 0 && age < LeapConstants.sessionProbeFreshness) {
      return;
    }
    await this.refreshOldToken();
  }

  // MARK: - 车辆

  async loadVehicles(): Promise<Vehicle[]> {
    const response = await this.newGatewayRequest(
      `${LeapConstants.globalHost}/app/app-global-service/v1/vehicle/list`,
      'GET', new Map<string, string>()
    );
    // 诊断：在 assertSuccess 之前打，否则接口报错时这份响应就看不到了。
    DiagLog.emit('vehicle-list', DiagLog.redacted(response).prettyPrinted);
    LeapClient.assertSuccess(response, '获取车辆列表失败');

    const seen = new Set<string>();
    const vehicles: Vehicle[] = [];
    const objects = response.allObjects((dict: Map<string, JsonValue>) => {
      const vin = dict.get('vin');
      if (vin === undefined) {
        return false;
      }
      const text = vin.stringValue;
      return text !== null && text.length >= 8;
    });
    for (let i = 0; i < objects.length; i++) {
      const object = objects[i];
      const vinNode = object.get('vin');
      const vin = vinNode !== undefined ? vinNode.stringValue : null;
      if (vin === null || seen.has(vin)) {
        continue;
      }
      seen.add(vin);
      const carType = LeapClient.mapString(object, 'carType') ?? LeapClient.mapString(object, 'cartype') ?? '';
      // 车名优先取 vinNickname，只降级到 carAlias；都取不到再兜底 carType/'我的车'。
      // 不要再引入 nickName/vehicleName/carName——它们跟用户想要的车名不是一回事。
      const name = LeapClient.mapString(object, 'vinNickname')
        ?? LeapClient.mapString(object, 'carAlias')
        ?? (carType.length === 0 ? '我的车' : carType);
      // 增程判据跟官方对齐：abilities 数组含能力码字符串 "39"（内部 key isExtendRange）。
      const abilities = LeapClient.mapStringArray(object, 'abilities');
      const isExtendRange = abilities.includes('39');
      // 权限码来自 abilities 里的**原始短码**，经 CarPerManager 那张表（VehicleUtil.permissionCodes）
      // 翻成内部码。vehicle/list 响应里**根本没有** permission 字段——曾误读它 → 恒空 → 哨兵对所有
      // 真实用户判假（只有手填内部码的体验模式看得到）。下面的 mapCodeList 只为「将来服务端真加上
      // permission 字段」留个前向兼容合并，正常响应它返回空。判据钉死：carType 不是 S01/T03 且
      // 内部码含 "400"（官方 updateSentinel 门控，S01/T03 白名单恒排除）。
      // 翻译表见 apk-analysis/permission-codes-map.md §5、哨兵门控见 sentinel-mode-interfaces.md §4。
      const permission = VehicleUtil.permissionCodes(abilities);
      for (const code of LeapClient.mapCodeList(object, 'permission')) {
        if (!permission.includes(code)) {
          permission.push(code);
        }
      }
      const isSentinelSupported = VehicleUtil.supportsSentinel(carType, permission);
      vehicles.push({
        vin: vin, carType: carType, name: name, isExtendRange: isExtendRange,
        permission: permission, isSentinelSupported: isSentinelSupported
      });
    }
    DiagLog.note(`[vehicle-list] 解析出 ${vehicles.length} 辆：` + vehicles
      .map((v: Vehicle) =>
        `${DiagLog.maskVin(v.vin)} carType=${v.carType.length === 0 ? '(空)' : v.carType}`
        + ` name=${v.name} 增程=${v.isExtendRange} 哨兵=${v.isSentinelSupported}`)
      .join(' | '));

    this.sessionData.vehicles = vehicles;
    if (this.sessionData.selectedVin.length === 0 && vehicles.length > 0) {
      this.sessionData.selectedVin = vehicles[0].vin;
      this.sessionData.selectedCarType = vehicles[0].carType;
      this.sessionData.route = null;
    }
    await this.persist();
    return vehicles;
  }

  async selectVehicle(vin: string, carType: string = ''): Promise<void> {
    this.sessionData.selectedVin = vin;
    const vehicle = this.sessionData.vehicles.find((v: Vehicle) => v.vin === vin);
    this.sessionData.selectedCarType = carType.length > 0
      ? carType : (vehicle !== undefined ? vehicle.carType : '');
    // 别名是上一台车的，留着卡片会顶着旧车名，等新车资源就位再重新推。
    this.sessionData.selectedCarAlias = null;
    this.sessionData.route = null;
    await this.persist();
  }

  /** 记下从 3D 资源目录反推出来的车型别名，给界面和卡片显示用。 */
  rememberCarAlias(alias: string | null): void {
    if (this.sessionData.selectedCarAlias === alias) {
      return;
    }
    this.sessionData.selectedCarAlias = alias;
    this.persist();
  }

  /** 车辆所在区域，决定车况/远控请求打到哪个机房。 */
  private async ensureRoute(): Promise<VehicleRoute> {
    if (this.sessionData.selectedVin.length === 0) {
      throw LeapError.missingVehicle();
    }
    const cached = this.sessionData.route;
    if (cached !== null && cached.appRegion.length > 0) {
      return cached;
    }

    const params = new Map<string, string>();
    params.set('vin', this.sessionData.selectedVin);
    const response = await this.newGatewayRequest(
      `${LeapConstants.globalHost}/app/app-global-service/v1/vehicle/getCarRoute`,
      'GET', params, params
    );
    LeapClient.assertSuccess(response, '获取车辆路由失败');
    const dataNode = response.get('data');
    let node: Map<string, JsonValue> | null = dataNode !== null ? dataNode.objectValue : null;
    if (node === null) {
      node = response.firstObject((dict: Map<string, JsonValue>) =>
        dict.has('appRegion') || dict.has('appCenter'));
    }
    const route: VehicleRoute = {
      appRegion: LeapClient.trimTrailingSlash(node !== null ? (LeapClient.mapString(node, 'appRegion') ?? '') : ''),
      appCenter: LeapClient.trimTrailingSlash(node !== null ? (LeapClient.mapString(node, 'appCenter') ?? '') : '')
    };
    DiagLog.note(`[route] vin=${DiagLog.maskVin(this.sessionData.selectedVin)}`
      + ` appRegion=${route.appRegion.length === 0 ? '(空)' : route.appRegion}`
      + ` appCenter=${route.appCenter.length === 0 ? '(空)' : route.appCenter}`);
    if (route.appRegion.length === 0) {
      throw LeapError.server('车辆路由缺少 appRegion');
    }
    this.sessionData.route = route;
    await this.persist();
    return route;
  }

  /**
   * 拉一份车况。
   *
   * `refreshConfig`：是否顺带重拉 commonConfig（充电上限 / 充电计划）。
   * 轮询传 false 复用缓存；下拉/手动刷新传 true 重拉。换车会无视这个参数强制重拉。
   */
  async fetchVehicleState(refreshConfig: boolean = false): Promise<VehicleState> {
    const route = await this.ensureRoute();
    const body = new Map<string, string>();
    body.set('vin', this.sessionData.selectedVin);
    const response = await this.newGatewayRequest(
      `${route.appRegion}/app/app-signal-service/signal/info/query`,
      'POST', body, null, body
    );
    DiagLog.note(`[state] vin=${DiagLog.maskVin(this.sessionData.selectedVin)}`
      + ` carType=${this.sessionData.selectedCarType.length === 0 ? '(空)' : this.sessionData.selectedCarType}`
      + ` code=${response.responseCode ?? 'null'}`
      + ` msg=${response.responseMessage.length === 0 ? '(空)' : response.responseMessage}`);
    LeapClient.assertSuccess(response, '获取车况失败');

    const container = response.firstObject((dict: Map<string, JsonValue>) => {
      const signalMap = dict.get('signalMap');
      return signalMap !== undefined && signalMap.objectValue !== null;
    });
    let signalNode: JsonValue | null = container !== null ? (container.get('signalMap') ?? null) : null;
    if (signalNode === null) {
      signalNode = response.path('data', 'signalMap');
    }
    if (signalNode === null) {
      signalNode = response.get('signalMap');
    }
    const map = signalNode !== null ? signalNode.objectValue : null;
    if (map === null) {
      // 找不到 signalMap 时，完整响应是唯一线索——新车型可能换了外层结构。
      DiagLog.emit('state-raw', DiagLog.redacted(response).prettyPrinted);
      throw LeapError.decode('车况响应里没有 signalMap');
    }

    const state = new VehicleState();
    // 是否增程不看 signalMap，看 vehicle/list 存下来的 abilities（含 "39"）。按当前
    // 选中车的 vin 匹配注入；匹配不到（旧会话没这字段或车不在列表）就保持 false。
    const selected = this.sessionData.vehicles.find(
      (v: Vehicle) => v.vin === this.sessionData.selectedVin);
    state.isExtendRange = (selected !== undefined ? selected.isExtendRange : false) ?? false;
    const dropped: string[] = [];
    map.forEach((value: JsonValue, key: string) => {
      const text = value.stringValue;
      if (text !== null) {
        state.signalMap.set(key, text);
      } else {
        dropped.push(key);
      }
    });
    // 充电上限 / 充电计划不在 signal/info/query 里——数字口径的车这份响应根本不带 config，
    // 得单独打 commonConfig 拿（见下方 fetchCommonConfig）。别再从这份响应里内联取，
    // 那样数字口径的车恒为 null，充电上限就永远是空的。
    // 车型不同，上报的字段命名体系也不同，按上报内容自己判断该用哪套表，
    // 再叠上车主自己标定出来的映射。
    state.schema = SignalSchema.detect(state.signalMap, this.sessionData.selectedCarType)
      .merging(LearnedSignals.keys(this.sessionData.selectedCarType));

    const sortedKeys: string[] = [];
    state.signalMap.forEach((_value: string, key: string) => {
      sortedKeys.push(key);
    });
    sortedKeys.sort();
    DiagLog.emit('signalmap',
      `体系=${state.schema.id} 共 ${map.size} 个字段，取到字符串值 ${state.signalMap.size} 个\n`
        + sortedKeys.map((k: string) => `${k} = ${state.signalMap.get(k) ?? ''}`).join('\n'));
    // 值是对象/数组的字段会被整个丢掉，字段名单独留一份——万一某个车型的 signalMap
    // 是嵌套结构，state 会是空的，而这里正好能看出来。
    if (dropped.length > 0) {
      dropped.sort();
      DiagLog.emit('signalmap-dropped', `非字符串值的字段 ${dropped.length} 个：` + dropped.join(', '));
    }
    // 充电上限和充电计划单独走 commonConfig（signal/info/query 里数字口径的车没有 config）。
    // 走缓存：首拉一次，轮询复用，下拉/手动刷新或换车才重拉。见 fillChargePlanFromCache。
    await this.fillChargePlanFromCache(state, refreshConfig);
    state.collectedAt = Date.now();
    return state;
  }

  /**
   * 用 commonConfig 里的充电计划填这份车况，带按 VIN 的缓存。
   *
   * - 换车（selectedVin 变）：立刻作废旧缓存，绝不把上一台车的计划贴到这台车上，并强制重拉。
   * - 同一 VIN：最多缓存 15 秒；编辑页和保存后强制读取。
   * - 失败绝不阻断车况：同一台车这轮拉不到就沿用上次缓存，界面不闪；换车拉不到则保持已清空的 null。
   * - 只有成功才把 `cachedConfigVin` 记成这台车——失败留待下一轮继续重试，直到首拉成功。
   */
  private async fillChargePlanFromCache(state: VehicleState, refreshConfig: boolean): Promise<void> {
    const vin = this.sessionData.selectedVin;
    const vinChanged = vin !== this.cachedConfigVin || (this.sessionData.oldAuth?.accountId ?? '') !== this.configAccount;
    if (vinChanged) {
      // 换车先清缓存，防止重拉失败时界面还挂着上一台车的计划。
      this.cachedChargePlan = null;
      this.cachedChargePlanLimit = null;
    }
    if (refreshConfig || vinChanged || Date.now() - this.configFetchedAt >= 15000) {
      try {
        await this.refreshChargePlan();
      } catch (e) {
        DiagLog.note(`[commonConfig] 拉取失败，充电计划沿用上次缓存：${LeapError.messageOf(e as object)}`);
      }
    }
    state.chargePlanLimit = this.cachedChargePlanLimit;
    state.chargePlan = this.cachedChargePlan;
  }

  /**
   * 拉 commonConfig，取出充电计划所在的 config 对象（`data.config`）。
   * 走老签名 GET + host fallback。请求失败抛错，成功但没有配置才返回 null。
   */
  async refreshChargePlan(): Promise<ChargePlan | null> {
    const vin = this.sessionData.selectedVin;
    const account = this.sessionData.oldAuth?.accountId ?? '';
    const request = ++this.configRequest;
    const config = await this.fetchCommonConfig();
    if (vin !== this.sessionData.selectedVin || account !== (this.sessionData.oldAuth?.accountId ?? '') ||
      request !== this.configRequest) {
      throw LeapError.server('车辆或配置请求已更新，请重试');
    }
    const plan = VehicleState.chargePlanFromConfig(config);
    this.cachedChargePlan = plan;
    this.cachedChargePlanLimit = plan?.percent ?? null;
    this.cachedConfigVin = vin;
    this.configAccount = account;
    this.configFetchedAt = Date.now();
    return plan;
  }

  async fetchCommonConfig(): Promise<JsonValue | null> {
    const route = await this.ensureRoute();
    await this.ensureFreshOldToken();
    const hosts = LeapClient.uniqueHosts([route.appCenter, route.appRegion, LeapConstants.globalHost]);
    const params = new Map<string, string>();
    params.set('appVersion', this.sessionData.appVersion);
    params.set('osType', 'iOS');
    params.set('vin', this.sessionData.selectedVin);
    for (let i = 0; i < hosts.length; i++) {
      try {
        const query = this.oldSignedParams(params);
        const response = await HttpTransport.request(
          `${hosts[i]}/carownerservice/v3/api/vehicleinfo/commonConfig`,
          'GET', this.oldAppHeaders(), query
        );
        if (response.isSuccess) {
          const config = response.path('data', 'config');
          DiagLog.note(`[commonConfig] host=${hosts[i]} success=true config=${config !== null}`);
          return config;
        }
      } catch (e) {
        continue;
      }
    }
    DiagLog.note('[commonConfig] 各 host 均无有效响应');
    throw LeapError.server('获取充电计划失败，请稍后重试');
  }

  // MARK: - 里程能耗统计

  /**
   * 一次拉齐三个 drivingrecord 接口，揉成规范化统计。
   * 任一接口失败/该车不返回不影响其它块，缺的置 null。
   */
  async fetchDrivingStats(range: DrivingStatsRange | null = null): Promise<DrivingStats> {
    const route = await this.ensureRoute();
    await this.ensureFreshOldToken();
    const hosts = LeapClient.uniqueHosts([LeapConstants.globalHost, route.appCenter, route.appRegion]);
    const window = range ?? DrivingStatsRange.lastSevenDays();
    const vin = this.sessionData.selectedVin;

    const mileageParams = new Map<string, string>();
    mileageParams.set('vin', vin);
    mileageParams.set('begintime', String(window.begintime));
    mileageParams.set('endtime', String(window.endtime));

    const weeklyParams = new Map<string, string>();
    weeklyParams.set('carvin', vin);

    const results = await Promise.all([
      this.oldDrivingRecord('mileage/energy/detail', mileageParams, hosts),
      this.oldDrivingRecord('getLastNweeks100kmECAndRank', weeklyParams, hosts)
    ]);
    const mileageRaw = results[0];
    const weeklyRaw = results[1];

    // 能耗构成默认跟着「本周」那根柱子走（和官方一致），可它的区间要等周列表回来才知道，
    // 所以这一发只能串在周列表后面——总请求数没变，只多一个来回。
    // 周列表拉不到就退回 window（近 7 天）并把 distributionWeekId 留空，界面据此改口。
    const lastWeek = LeapClient.lastWeekOf(weeklyRaw);
    const lastWeekRange = lastWeek !== null
      ? DrivingStatsRange.forWeek(lastWeek.weekStart, lastWeek.weekEnd) : null;
    const distributionRaw = await this.fetchEnergyDistributionRaw(
      vin, lastWeekRange ?? window, hosts);

    return DrivingStats.fromResponses(mileageRaw, distributionRaw, weeklyRaw, window,
      lastWeekRange !== null && lastWeek !== null ? weekEcId(lastWeek) : null);
  }

  /**
   * 单独拉某个区间的能耗构成（`getLastweekEC`）。页面点周柱子时按周调，
   * 拿不到就返回 null——调用方按「这周没数据」处理，不许拿别的区间顶。
   */
  async fetchEnergyDistribution(range: DrivingStatsRange): Promise<EnergyDistribution | null> {
    const route = await this.ensureRoute();
    await this.ensureFreshOldToken();
    const hosts = LeapClient.uniqueHosts([LeapConstants.globalHost, route.appCenter, route.appRegion]);
    const raw = await this.fetchEnergyDistributionRaw(this.sessionData.selectedVin, range, hosts);
    return DrivingStats.distributionFrom(raw);
  }

  private async fetchEnergyDistributionRaw(vin: string, range: DrivingStatsRange,
    hosts: string[]): Promise<JsonValue | null> {
    const params = new Map<string, string>();
    params.set('carvin', vin);
    // 时间戳收**秒**，不是毫秒。同一个 drivingrecord 命名空间下 mileage/energy/detail
    // 收的是毫秒，唯独这个接口收秒——传毫秒不报「参数越界」也不返空，而是被网关判成
    // `code:2 请求参数含非法字符`，看着像签名或字符集问题，实际只是量纲错了（2026-08-18 实测）。
    params.set('begintime', String(range.begintimeSeconds));
    params.set('endtime', String(range.endtimeSeconds));
    return await this.oldDrivingRecord('getLastweekEC', params, hosts);
  }

  /** 周列表里最后一根柱子（本周）。拿不到返回 null。 */
  private static lastWeekOf(weeklyRaw: JsonValue | null): WeeklyEC | null {
    const data = weeklyRaw !== null ? weeklyRaw.get('data') : null;
    const node = data !== null ? data.get('weeklyEC') : null;
    const items = node !== null ? node.arrayValue : null;
    if (items === null || items.length === 0) {
      return null;
    }
    const last = items[items.length - 1];
    const start = last.get('weekStart');
    const end = last.get('weekEnd');
    return {
      weekStart: start !== null ? start.stringValue : null,
      weekEnd: end !== null ? end.stringValue : null,
      hundredKmEc: null
    };
  }

  /**
   * 老签名 GET 一个 drivingrecord 接口，按 host 依次 fallback（global 常 404，落到路由 host）。
   * 失败/非成功响应返回 null，交给上层揉数据时按缺失处理。
   */
  private async oldDrivingRecord(path: string, params: Map<string, string>,
    hosts: string[]): Promise<JsonValue | null> {
    for (let i = 0; i < hosts.length; i++) {
      try {
        const query = this.oldSignedParams(params);
        const response = await HttpTransport.request(
          `${hosts[i]}/carownerservice/v3/api/drivingrecord/${path}`,
          'GET', this.oldAppHeaders(), query
        );
        if (response.isSuccess) {
          return response;
        }
      } catch (e) {
        continue;
      }
    }
    return null;
  }

  // MARK: - 蓝牙钥匙

  /**
   * 从官方 `syncBluetoothKeys` 同步当前车辆的蓝牙认证证书。
   *
   * 返回值里有 ECDH 公钥、签名和 passwordCard，调用方只能写进关键资产，
   * 不许进普通诊断日志——那份日志是会被用户导出去发出来的。
   */
  async fetchBLEProtocolMinor(vin: string, accountId: string): Promise<number> {
    if (this.sessionData.selectedVin !== vin || this.sessionData.oldAuth?.accountId !== accountId) { throw LeapError.server('车辆已切换，请重试'); }
    await this.ensureFreshOldToken();
    const route = await this.ensureRoute();
    const host = route.appCenter.length > 0 ? route.appCenter : route.appRegion;
    const response = await this.oldAuthedRequest('蓝牙协议版本读取失败', async (): Promise<JsonValue> => {
      if (this.sessionData.selectedVin !== vin || this.sessionData.oldAuth?.accountId !== accountId) { throw LeapError.server('车辆已切换，请重试'); }
      return HttpTransport.request(`${host}/carownerservice/v3/api/commoninfo/sync`, 'POST', this.oldAppHeaders(),
        null, BodyKind.form, this.oldSignedParams(new Map<string, string>([['type', 'bluetoothMac'], ['vin', vin]])));
    });
    if (this.sessionData.selectedVin !== vin || this.sessionData.oldAuth?.accountId !== accountId) { throw LeapError.server('车辆已切换，请重试'); }
    LeapClient.assertSuccess(response, '蓝牙协议版本读取失败');
    const minor = LeapBLEProtocol.cloudProtocolMinor(response);
    if (minor === undefined) { throw LeapError.decode('蓝牙协议版本缺失或格式无效'); }
    return minor;
  }

  async fetchBLECalibration(model: string, manufacturer: string, multipleAnchors: boolean, vin: string, accountId: string): Promise<BLECalibration> {
    if (this.sessionData.selectedVin !== vin || this.sessionData.oldAuth?.accountId !== accountId) { throw LeapError.server('车辆已切换，请重试'); }
    return BLECalibration.fromJson(await this.bleCalibrationRequest('getAnchorPoint/calibrateParams', model,
      manufacturer, null), multipleAnchors);
  }

  async saveBLECalibration(model: string, configuration: LeapBLEConfiguration, vin: string, accountId: string): Promise<void> {
    if (this.sessionData.selectedVin !== vin || this.sessionData.oldAuth?.accountId !== accountId) {
      throw LeapError.server('车辆已切换，请重试');
    }
    const params = new Map<string, string>();
    params.set('anchorType', configuration.multipleAnchors ? '1' : '0');
    params.set('operate', configuration.unlockDistance === BLEUnlockDistance.Standard ? 'delete' : 'add');
    if (configuration.unlockDistance !== BLEUnlockDistance.Standard) { params.set('params', configuration.calibrationText); }
    await this.bleCalibrationRequest('uploadAutonomyCalibrateParams', model, '', params);
  }

  private async bleCalibrationRequest(path: string, model: string, manufacturer: string,
    body: Map<string, string> | null): Promise<JsonValue> {
    const vin = this.sessionData.selectedVin;
    const account = this.sessionData.oldAuth?.accountId ?? '';
    if (vin.length === 0 || account.length === 0) { throw LeapError.notLoggedIn(); }
    const params = body ?? new Map<string, string>();
    params.set('vin', vin);
    params.set('model', model.replace(/ /g, ''));
    if (body === null) { params.set('manufacture', manufacturer); }
    DiagLog.note(`[ble:calibration.request] route=globalApp auth=gateway operation=${path}`);
    const response = await this.newGatewayRequest(`${LeapConstants.globalHost}/app/app-global-service/v3/api/bluetoothkey/${path}`,
      'POST', params, null, null, params, account, vin);
    DiagLog.note(`[ble:calibration.response] success=${response.isSuccess}`);
    if (this.sessionData.selectedVin !== vin || this.sessionData.oldAuth?.accountId !== account) {
      throw LeapError.server('车辆已切换，请重试');
    }
    LeapClient.assertSuccess(response, '距离设置同步失败');
    return response;
  }

  async fetchBLEKeyCertificate(): Promise<LeapBLEKeyCertificate> {
    if (this.sessionData.selectedVin.length === 0) {
      throw LeapError.missingVehicle();
    }
    if (this.sessionData.oldAuth === null) {
      throw LeapError.notLoggedIn();
    }
    const vin = this.sessionData.selectedVin;
    const account = this.sessionData.oldAuth.accountId;
    await this.ensureFreshOldToken();
    const route = await this.ensureRoute();
    if (route.appCenter.length === 0) {
      throw LeapError.server('车辆中心路由为空');
    }
    const params = new Map<string, string>();
    params.set('vin', vin);
    const url = `${route.appCenter}/carownerservice/v3/api/bluetoothkey/combine/syncBluetoothKeys`;

    const response = await this.oldAuthedRequest('蓝牙钥匙证书同步失败，请稍后重试',
      () => HttpTransport.request(
        url, 'POST', this.oldAppHeaders(), null, BodyKind.form, this.oldSignedParams(params)));
    if (this.sessionData.selectedVin !== vin || this.sessionData.oldAuth?.accountId !== account) {
      throw LeapError.server('车辆已切换，请重新同步蓝牙钥匙');
    }
    LeapClient.assertSuccess(response, '蓝牙钥匙证书同步失败');

    const certificate = LeapBLEKeyCertificate.fromJson(response, this.sessionData.selectedVin);
    if (certificate === null) {
      throw LeapError.decode('蓝牙钥匙响应缺少 bluetoothKey');
    }
    // 服务端按 VIN 查，但同一个账号下多台车时返回过别的车——拿错了证书的话
    // 要一路走到车端回 resultCode 才失败，那时根本看不出问题出在这里。
    if (certificate.vin.length > 0 && certificate.vin !== this.sessionData.selectedVin) {
      throw LeapError.decode('蓝牙钥匙证书 VIN 不匹配');
    }
    try {
      certificate.validatePasswordCard();
    } catch (e) {
      throw LeapError.decode(LeapError.messageOf(e as object));
    }
    return certificate;
  }

  // MARK: - 驻车照片

  /**
   * 拉最近一张驻车照片。
   *
   * 接口只有「最近一张」，没有历史列表，也不能让车临时拍照。
   * 走老签名 GET，按 global → 路由 host 依次回退（和 iOS `fetchParkingPhoto` 同一条链路）。
   */
  async fetchParkingPhoto(): Promise<ParkingPhoto> {
    if (this.sessionData.selectedVin.length === 0) {
      throw LeapError.missingVehicle();
    }
    if (this.sessionData.oldAuth === null) {
      throw LeapError.notLoggedIn();
    }
    await this.ensureFreshOldToken();
    const route = await this.ensureRoute();
    const hosts = LeapClient.uniqueHosts(
      [LeapConstants.globalHost, route.appRegion, route.appCenter]);
    const params = new Map<string, string>();
    params.set('vin', this.sessionData.selectedVin);
    let lastMessage = '';
    for (let i = 0; i < hosts.length; i++) {
      try {
        const host = hosts[i];
        const response = await this.oldAuthedRequest('接口返回失败，请稍后重试',
          async (): Promise<JsonValue> => await HttpTransport.request(
            `${host}/carownerservice/v3/api/chassis/query`,
            'GET', this.oldAppHeaders(), this.oldSignedParams(params)));
        if (response.isSuccess) {
          return ParkingPhoto.fromResponse(response);
        }
        lastMessage = response.responseMessage;
      } catch (e) {
        const error = e as LeapError;
        // 登录真失效要立刻上抛，不能被后面的 host 循环吞成「查询失败」。
        if (error.kind === LeapErrorKind.SessionExpired) {
          throw error;
        }
        lastMessage = LeapError.messageOf(e as object);
      }
    }
    throw LeapError.server(lastMessage.length > 0 ? lastMessage : '驻车照片查询失败');
  }

  /**
   * 下载驻车照片本体。
   *
   * 图片地址由业务接口直接返回，**不追加**老网关签名或登录凭证——带上反而会被图片服务拒。
   * `HttpTransport.download` 出错只会返回 null，所以这里靠魔数复核：鉴权失败/限流时
   * 服务端回的是 JSON 错误体，长度和状态码都正常，只有内容不是图。
   */
  async downloadParkingPhoto(url: string): Promise<ArrayBuffer> {
    if (!url.toLowerCase().startsWith('https://')) {
      throw LeapError.server('驻车照片地址不是安全连接');
    }
    const data = await HttpTransport.download(url, new Map<string, string>(), 30000);
    if (data === null) {
      throw LeapError.server('驻车照片下载失败');
    }
    if (data.byteLength < 4) {
      throw LeapError.decode('驻车照片内容为空');
    }
    if (!LeapClient.looksLikeImage(data)) {
      throw LeapError.decode('驻车照片返回了非图片内容');
    }
    return data;
  }

  /** 按文件头认图：JPEG / PNG / GIF / WebP(RIFF) / HEIC(ftyp)。 */
  private static looksLikeImage(data: ArrayBuffer): boolean {
    const head = new Uint8Array(data, 0, Math.min(12, data.byteLength));
    if (head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) {
      return true;
    }
    if (head.length >= 8 && head[0] === 0x89 && head[1] === 0x50
      && head[2] === 0x4e && head[3] === 0x47) {
      return true;
    }
    if (head.length >= 6 && head[0] === 0x47 && head[1] === 0x49 && head[2] === 0x46) {
      return true;
    }
    if (head.length >= 12 && head[0] === 0x52 && head[1] === 0x49
      && head[2] === 0x46 && head[3] === 0x46
      && head[8] === 0x57 && head[9] === 0x45 && head[10] === 0x42 && head[11] === 0x50) {
      return true;
    }
    if (head.length >= 12 && head[4] === 0x66 && head[5] === 0x74
      && head[6] === 0x79 && head[7] === 0x70) {
      return true;
    }
    return false;
  }

  // MARK: - 车模型（爱车图）

  /** 拉爱车页车模型。走老签名 + host fallback（carpicture 挂在 appCenter，优先它）。 */
  async fetchCarModel(): Promise<CarModel> {
    const route = await this.ensureRoute();
    await this.ensureFreshOldToken();
    const hosts = LeapClient.uniqueHosts([route.appCenter, route.appRegion, LeapConstants.globalHost]);
    const params = new Map<string, string>();
    params.set('vin', this.sessionData.selectedVin);
    for (let i = 0; i < hosts.length; i++) {
      try {
        const query = this.oldSignedParams(params);
        const response = await HttpTransport.request(
          `${hosts[i]}/carownerservice/v3/api/carpicture/3d/key`,
          'GET', this.oldAppHeaders(), query
        );
        const model = CarModel.fromResponse(response);
        DiagLog.note(`[carmodel] host=${hosts[i]} success=${response.isSuccess}`
          + ` code=${response.responseCode ?? 'null'} msg=${response.responseMessage}`
          + ` parsed=${model !== null}`);
        if (response.isSuccess && model !== null) {
          return model;
        }
      } catch (e) {
        DiagLog.note(`[carmodel] host=${hosts[i]} 抛错：${LeapError.messageOf(e as object)}`);
        continue;
      }
    }
    throw LeapError.server('车模型接口无数据');
  }

  /**
   * 下载资源包（3D 模型 zip、渲染器 zip 或 2D 分层贴图包）。
   * 返回体是 ZIP 二进制而不是 JSON，所以不走 request。
   */
  async fetchCarModelPackage(key: string): Promise<ArrayBuffer> {
    if (key.length === 0) {
      throw LeapError.server('资源 key 为空');
    }
    const route = await this.ensureRoute();
    await this.ensureFreshOldToken();
    const hosts = LeapClient.uniqueHosts([route.appCenter, route.appRegion]);
    const params = new Map<string, string>();
    params.set('key', key);
    for (let i = 0; i < hosts.length; i++) {
      try {
        const query = this.oldSignedParams(params);
        const url = HttpTransport.buildURL(
          `${hosts[i]}/carownerservice/v3/api/carpicture/key/package`, query);
        const data = await HttpTransport.download(url, this.oldAppHeaders());
        if (data === null || data.byteLength < 4) {
          continue;
        }
        // 鉴权失败时服务端回的是 JSON 错误体，用 ZIP 魔数把它和真包区分开。
        const head = new Uint8Array(data, 0, 2);
        if (head[0] !== 0x50 || head[1] !== 0x4b) {
          continue;
        }
        return data;
      } catch (e) {
        continue;
      }
    }
    throw LeapError.server('车模型资源包下载失败');
  }

  // MARK: - 远控

  /** 发送远控指令，返回服务端回执里的 msgID。 */
  async sendControl(command: LeapCommand, operationPassword: string): Promise<ControlReceipt> {
    if (this.sessionData.selectedVin.length === 0) {
      throw LeapError.missingVehicle();
    }
    const oldAuth = this.sessionData.oldAuth;
    if (oldAuth === null) {
      throw LeapError.notLoggedIn();
    }
    if (command.requiresOperationPassword && operationPassword.length === 0) {
      throw LeapError.server('该指令需要操作密码');
    }
    await this.ensureFreshOldToken();
    const route = await this.ensureRoute();
    // 预约类命令是另一套端点，且优先打 appCenter。
    let url: string;
    if (command.isAppointment) {
      const host = route.appCenter.length === 0 ? route.appRegion : route.appCenter;
      url = `${host}/carownerservice/v3/api/appremotectl/appointment`;
    } else {
      url = `${route.appRegion}/app/app-control-service/v3/api/appremotectl`;
    }

    const buildBody = (): Map<string, string> => {
      const params = new Map<string, string>();
      params.set('cmdid', command.cmdid);
      params.set('state', command.stateJSON);
      params.set('carvin', this.sessionData.selectedVin);
      if (operationPassword.length > 0) {
        const token = this.sessionData.oldAuth !== null ? this.sessionData.oldAuth.token : oldAuth.token;
        params.set('oppwd', LeapCrypto.encryptOperationPassword(operationPassword, token));
      }
      return this.oldSignedParams(params);
    };

    const response = await this.oldAuthedRequest(
      `${command.label}指令下发失败，请稍后重试`,
      () => HttpTransport.request(
        url, 'POST', this.oldAppHeaders(), null, BodyKind.form, buildBody()));
    // 车没动作时，第一件要分清的事是「指令根本没发出去」还是「发出去了车不认」。
    DiagLog.note(`[control] cmdid=${command.cmdid} state=${command.stateJSON}`
      + ` code=${response.responseCode ?? 'null'}`
      + ` msg=${response.responseMessage.length === 0 ? '(空)' : response.responseMessage}`);
    LeapClient.assertSuccess(response, `${command.label}指令发送失败`);

    const node = response.firstObject((dict: Map<string, JsonValue>) =>
      dict.has('msgID') || dict.has('msgId'));
    let msgID = '';
    if (node !== null) {
      const value = node.get('msgID') ?? node.get('msgId');
      if (value !== undefined && value.stringValue !== null) {
        msgID = value.stringValue;
      }
    }
    if (msgID.length === 0) {
      const dataNode = response.get('data');
      if (dataNode !== null && dataNode.stringValue !== null) {
        msgID = dataNode.stringValue;
      }
    }
    return { msgID: msgID, label: command.label, sentAt: Date.now() };
  }

  /** 查询指令执行结果。服务端是异步执行，下发成功不等于车辆已响应。 */
  async queryControlResult(msgID: string): Promise<JsonValue> {
    if (msgID.length === 0) {
      throw LeapError.server('msgID 为空');
    }
    const route = await this.ensureRoute();
    await this.ensureFreshOldToken();
    const url = `${route.appRegion}/app/app-control-service/v3/api/appremotectl/query`;
    const params = new Map<string, string>();
    params.set('msgID', msgID);
    return this.oldAuthedRequest(
      '指令结果查询失败，请稍后重试',
      () => HttpTransport.request(
        url, 'GET', this.oldAppHeaders(), this.oldSignedParams(params)));
  }

  /**
   * 回读车上已有的预约（目前只用于 cmdid 171 预约空调）。同 iOS `fetchAppointmentControls`。
   *
   * `GET {appCenter}/carownerservice/v3/api/appremotectl/getappointment?carvin=&cmdid=`，
   * 老签名，host 取 `appCenter ?? appRegion`（和下发预约的端点同一台）。出处是 leapauto 记录的
   * 官方抓包 `[334]`。返回 `controls[]`；`data` 本身是一段 JSON 字符串，解析见
   * `ClimateAppointment.controlsFromAppointmentData`。解析不出抛错——那是「读不到」，
   * 和「车上没有预约」（空数组）是两回事，界面要分开说。
   */
  async fetchAppointmentControls(cmdid: string): Promise<JsonValue[]> {
    if (this.sessionData.selectedVin.length === 0) {
      throw LeapError.missingVehicle();
    }
    if (this.sessionData.oldAuth === null) {
      throw LeapError.notLoggedIn();
    }
    await this.ensureFreshOldToken();
    const route = await this.ensureRoute();
    const host = route.appCenter.length === 0 ? route.appRegion : route.appCenter;
    const params = new Map<string, string>();
    params.set('carvin', this.sessionData.selectedVin);
    params.set('cmdid', cmdid);
    const response = await this.oldAuthedRequest('读取预约失败',
      async (): Promise<JsonValue> => await HttpTransport.request(
        `${host}/carownerservice/v3/api/appremotectl/getappointment`,
        'GET', this.oldAppHeaders(), this.oldSignedParams(params)));
    LeapClient.assertSuccess(response, '读取预约失败');
    const controls = ClimateAppointment.controlsFromAppointmentData(response.get('data'));
    if (controls === null) {
      throw LeapError.server('预约数据格式无法识别');
    }
    return controls;
  }

  // MARK: - 请求装配

  /**
   * 老链路通用头。
   *
   * `includeToken = false` 用于登录、发验证码这类**建立身份之前**的请求：它们不该带
   * `XFX-CDN-CROSS-NODE`。本机手里那份 token 在被挤下线后已经作废，带上去只会让
   * 服务端拒掉整个请求。靠调用点当时 `oldAuth` 恰好为空来保证是不够的——显式关掉，
   * 将来谁在登录前动了 session 也不会把这条链路又打脏。
   */
  private oldAppHeaders(includeToken: boolean = true): Map<string, string> {
    const headers = new Map<string, string>();
    headers.set('APPPlatform', 'iOS');
    headers.set('APPVersion', this.sessionData.appVersion);
    headers.set('APPImei', this.sessionData.deviceId);
    headers.set('C-VERSIONS', 'APP');
    headers.set('XFX-CDN-VRS', 'v4');
    const oldAuth = this.sessionData.oldAuth;
    if (includeToken && oldAuth !== null && oldAuth.token.length > 0) {
      headers.set('XFX-CDN-CROSS-NODE', oldAuth.token);
    }
    return headers;
  }

  /** 老链路签名：timespan/nonce/deviceID/token + 业务参数，排序拼接后取短 MD5；token 本身不发送。 */
  private oldSignedParams(params: Map<string, string>): Map<string, string> {
    // 设备号是服务端认这条会话的凭据，签名里少了它必然 result=39。
    this.requireDeviceId();
    const oldAuth = this.sessionData.oldAuth;
    if (oldAuth === null) {
      throw LeapError.notLoggedIn();
    }
    const map = new Map<string, string>();
    map.set('timespan', String(Date.now()));
    map.set('nonce', LeapCrypto.randomNonce());
    map.set('deviceID', this.sessionData.deviceId);
    map.set('token', oldAuth.token);
    params.forEach((value: string, key: string) => {
      map.set(key, value);
    });
    const signStr = LeapCrypto.shortMD5(LeapCrypto.sortAndConcatValues(map));
    map.delete('token');
    map.set('signStr', signStr);
    return map;
  }

  /**
   * 新网关签名：固定 8 个头字段 + 业务参数一起参与签名。
   * 登录前用 sha256，登录后用 HMAC-SHA256(signKey)。
   */
  private newGatewayHeaders(params: Map<string, string>, needLogin: boolean): Map<string, string> {
    this.requireDeviceId();
    const nonce = LeapCrypto.randomNonce();
    const timestamp = String(Date.now());
    const newAuth = this.sessionData.newAuth;
    const oldAuth = this.sessionData.oldAuth;

    const headers = new Map<string, string>();
    headers.set('source', 'leapmotor');
    headers.set('channel', '1');
    headers.set('acceptLanguage', 'zh-CN');
    headers.set('x-region', 'CN');
    headers.set('x-api-signature-version', '2.0');
    headers.set('digest', '');
    headers.set('version', this.sessionData.appVersion);
    headers.set('deviceType', 'ios');
    headers.set('nonce', nonce);
    headers.set('timestamp', timestamp);
    headers.set('deviceId', this.sessionData.deviceId);
    headers.set('userId', newAuth !== null ? newAuth.accountId : (oldAuth !== null ? oldAuth.accountId : ''));
    headers.set('carvin', this.sessionData.selectedVin);
    headers.set('cartype', this.sessionData.selectedCarType);
    headers.set('x-subversion', this.sessionData.subVersion);

    const signHeaders = new Map<string, string>();
    signHeaders.set('acceptLanguage', 'zh-CN');
    signHeaders.set('channel', '1');
    signHeaders.set('deviceId', this.sessionData.deviceId);
    signHeaders.set('deviceType', 'ios');
    signHeaders.set('nonce', nonce);
    signHeaders.set('source', 'leapmotor');
    signHeaders.set('timestamp', timestamp);
    signHeaders.set('version', this.sessionData.appVersion);

    const signBase = LeapCrypto.sortAndConcatValues(signHeaders, params);
    if (needLogin) {
      if (newAuth === null || newAuth.accessToken.length === 0) {
        throw LeapError.notLoggedIn();
      }
      const signKey = AuthUtil.newSignKeyData(newAuth);
      if (signKey.length === 0) {
        throw LeapError.notLoggedIn();
      }
      headers.set('token', newAuth.accessToken);
      if (newAuth.accountId.length > 0) {
        headers.set('userId', newAuth.accountId);
      }
      headers.set('sign', LeapCrypto.hmacSHA256Hex(signBase, signKey));
    } else {
      headers.set('sign', LeapCrypto.sha256Hex(signBase));
    }
    return headers;
  }

  /** 新网关请求：先按需续期，失败时再续期重试一次。 */
  private async newGatewayRequest(url: string, method: string, params: Map<string, string>,
    query: Map<string, string> | null = null,
    jsonBody: Map<string, string> | null = null,
    formBody: Map<string, string> | null = null,
    expectedAccount: string = '', expectedVin: string = ''): Promise<JsonValue> {
    await this.ensureDeviceIdLoaded();
    await this.awaitOngoingRefresh();
    await this.ensureFreshAccessToken();

    const perform = async (): Promise<JsonValue> => {
      if (expectedAccount.length > 0 && (this.sessionData.oldAuth?.accountId !== expectedAccount || this.sessionData.selectedVin !== expectedVin)) {
        throw LeapError.server('车辆已切换，请重试');
      }
      return HttpTransport.request(
        url, method, this.newGatewayHeaders(params, true), query,
        jsonBody !== null ? BodyKind.json : (formBody !== null ? BodyKind.form : BodyKind.none), jsonBody ?? formBody);
    };

    try {
      const response = await perform();
      if (!LeapClient.isNewAuthFailure(response)) {
        return response;
      }
    } catch (error) {
      const err = error as LeapError;
      const isAuthStatus = err.kind === LeapErrorKind.Http && (err.httpStatus === 401 || err.httpStatus === 403);
      if (!isAuthStatus) {
        throw error as Error;
      }
    }
    await this.refreshAccessToken();
    const retried = await perform();
    // 续期之后还是被拒，说明登录态真的失效了。这里不抛出去的话，
    // 界面会一直停在首页反复弹同一条错误，永远回不到登录页。
    if (LeapClient.isNewAuthFailure(retried)) {
      throw LeapError.sessionExpired();
    }
    return retried;
  }

  // MARK: - 响应解析

  private static assertSuccess(response: JsonValue, fallback: string): void {
    if (response.isSuccess) {
      return;
    }
    const message = response.responseMessage;
    throw LeapError.server(message.length === 0 ? fallback : message);
  }

  private static mapString(dict: Map<string, JsonValue>, key: string): string | null {
    const value = dict.get(key);
    if (value === undefined) {
      return null;
    }
    return value.stringValue;
  }

  /** 取字符串数组：非数组或取不到值都返回空数组，逐项按 stringValue 归一（数字也转字符串）。 */
  private static mapStringArray(dict: Map<string, JsonValue>, key: string): string[] {
    const value = dict.get(key);
    const items = value !== undefined ? value.arrayValue : null;
    if (items === null) {
      return [];
    }
    const result: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const text = items[i].stringValue;
      if (text !== null) {
        result.push(text);
      }
    }
    return result;
  }

  /**
   * 取能力码清单，两种上报形态都认：数组（`["400","39"]`）和逗号分隔字符串（`"400,39"`）。
   * permission / abilities 这类字段官方在不同响应里两种形态都出现过，靠这个统一归一，
   * 逐项 trim 并丢掉空段，避免 `"400, "` 里的空串混进来。
   */
  private static mapCodeList(dict: Map<string, JsonValue>, key: string): string[] {
    const value = dict.get(key);
    if (value === undefined) {
      return [];
    }
    // 先按数组解，非数组（是字符串）再按逗号切。
    const array = LeapClient.mapStringArray(dict, key);
    if (array.length > 0) {
      return array.map((s: string): string => s.trim()).filter((s: string): boolean => s.length > 0);
    }
    const text = value.stringValue;
    if (text === null || text.length === 0) {
      return [];
    }
    return text.split(',').map((s: string): string => s.trim()).filter((s: string): boolean => s.length > 0);
  }

  private static extractOldAuth(response: JsonValue): OldAuth {
    let node: Map<string, JsonValue> | null = null;
    const appLoginVO = response.path('data', 'appLoginVO');
    if (appLoginVO !== null) {
      node = appLoginVO.objectValue;
    }
    if (node === null) {
      const appOneLoginVO = response.path('data', 'appOneLoginVO');
      if (appOneLoginVO !== null) {
        node = appOneLoginVO.objectValue;
      }
    }
    if (node === null) {
      node = response.firstObject((dict: Map<string, JsonValue>) =>
        dict.has('accountId') && dict.has('token'));
    }
    const accountId = node !== null ? LeapClient.mapString(node, 'accountId') : null;
    const token = node !== null ? LeapClient.mapString(node, 'token') : null;
    if (node === null || accountId === null || token === null) {
      throw LeapError.decode('登录响应里没有 accountId/token');
    }
    const expiredText = LeapClient.mapString(node, 'tokenExpired');
    const expiredSeconds = expiredText !== null && Number.isFinite(Number(expiredText)) ? Number(expiredText) : 0;
    const now = Date.now();
    return {
      accountId: accountId,
      token: token,
      refreshToken: LeapClient.mapString(node, 'refreshToken') ?? '',
      nickname: LeapClient.mapString(node, 'nickname') ?? '',
      tokenExpired: expiredSeconds > 0 ? String(Math.trunc(expiredSeconds)) : '',
      tokenObtainedAt: now,
      tokenExpiresAt: expiredSeconds > 0 ? now + expiredSeconds * 1000 : 0
    };
  }

  private static extractNewAuth(response: JsonValue, oldAuth: OldAuth | null): NewAuth {
    const dataNode = response.get('data');
    let node: Map<string, JsonValue> | null = dataNode !== null ? dataNode.objectValue : null;
    if (node === null) {
      node = response.firstObject((dict: Map<string, JsonValue>) =>
        dict.has('accessToken') && dict.has('signParam'));
    }
    const accessToken = node !== null ? LeapClient.mapString(node, 'accessToken') : null;
    const signParam = node !== null ? node.get('signParam') : undefined;
    const r2Node = signParam !== undefined && signParam !== null ? signParam.get('r2') : null;
    const r3Node = signParam !== undefined && signParam !== null ? signParam.get('r3') : null;
    const r2 = r2Node !== null ? r2Node.stringValue : null;
    const r3 = r3Node !== null ? r3Node.stringValue : null;
    if (node === null || accessToken === null || r2 === null || r3 === null) {
      throw LeapError.decode('新网关响应里没有 accessToken/signParam');
    }
    const signKey = LeapCrypto.deriveSignKey(accessToken, r2, r3);
    const jwtExpiry = LeapCrypto.jwtExpiryMilliseconds(accessToken);
    const expireText = LeapClient.mapString(node, 'tokenExpireTime');
    const fallbackExpiry = expireText !== null && Number.isFinite(Number(expireText))
      ? Date.now() + Number(expireText) * 1000 : 0;
    const gatewayAccountId = LeapClient.mapString(node, 'accountId') ?? '';
    return {
      accountId: oldAuth !== null ? oldAuth.accountId : gatewayAccountId,
      gatewayAccountId: gatewayAccountId,
      accessToken: accessToken,
      refreshToken: LeapClient.mapString(node, 'refreshToken') ?? '',
      accessTokenExpiresAt: jwtExpiry > 0 ? jwtExpiry : fallbackExpiry,
      nickname: LeapClient.mapString(node, 'nickname') ?? '',
      signKeyBase64: LeapCrypto.base64Encode(signKey)
    };
  }

  /**
   * 需要重新登录的强判据文案：命中任意一条即视为登录态失效。
   * 两类：登录/会话/token 明确过期失效、异地或他设备登录被挤下线。
   * 都是能独立成立的多字短语，避免「登录成功」这类误伤。
   * 匹配前统一小写并去空格，容忍「token 失效」这种中间带空格的写法。
   *
   * 这张表只收「除了重新登录没有别的解释」的文案。以下几条曾经在表里，都撤了：
   * - 「已下线」：撞的是「**车辆**已下线」，车在休眠而已，跟登录态无关。
   * - 「未授权」：撞的是「未授权访问该车辆」，是这辆车的权限问题。
   * - 「信息校验失败」：老链路签名不过就是这句——设备时钟偏一点、nonce 撞了都会出，
   *   续期救不了它，重试还是同一句，于是稳定地把用户踢回登录页。
   * - 「鉴权失败」「认证失败」「身份验证失败」：同一个理由，签名不过也叫这几个名字，
   *   分不出是「这次请求没签对」还是「这个人不该在线」。真正的失效有 401/403 和
   *   result=39 兜着，不缺这几条。
   * 宁可漏判：漏了顶多多弹一次错误提示，误判是直接清掉登录态。
   */
  private static readonly reauthPhrases: string[] = [
    // 登录 / 会话 过期失效
    '重新登录', '登录已失效', '登录失效', '登录已过期', '登录过期',
    '登录信息已过期', '登录信息失效', '登录状态已失效', '登录状态失效', '登录态失效',
    '会话已过期', '会话过期', '会话失效', '账号已失效', '账号失效',
    // token 类
    'token失效', 'token已失效', 'token过期', 'token已过期',
    'tokeninvalid', 'tokenexpired', '第三方token失效',
    // 异地 / 他设备登录被挤下线
    '异地登录', '其他设备登录', '其它设备登录', '别处登录', '别的设备登录',
    '换设备登录', '其他终端登录', '被挤下线', '顶下线', '强制下线',
    // 未登录：服务端明说这次请求没带上有效身份，没有第二种解释。
    '未登录'
  ];

  private static matchesReauthPhrase(message: string): boolean {
    const normalized = message.toLowerCase().replace(/ /g, '');
    return LeapClient.reauthPhrases.some((p: string) => normalized.includes(p));
  }

  /** 老链路失效标志：result=39 或命中失效文案。 */
  private static isOldAuthFailure(response: JsonValue): boolean {
    const result = response.get('result');
    if (result !== null && result.stringValue === '39') {
      DiagLog.note('[auth] 老链路 result=39，判定登录态失效');
      return true;
    }
    const message = response.responseMessage;
    if (LeapClient.matchesReauthPhrase(message)) {
      DiagLog.note(`[auth] 老链路命中失效文案：${message}`);
      return true;
    }
    return false;
  }

  private static isNewAuthFailure(response: JsonValue): boolean {
    const code = response.responseCode;
    if (code === '401' || code === '403') {
      DiagLog.note(`[auth] 新链路 code=${code}，判定登录态失效`);
      return true;
    }
    const message = response.responseMessage;
    if (LeapClient.matchesReauthPhrase(message)) {
      DiagLog.note(`[auth] 新链路命中失效文案：${message}`);
      return true;
    }
    // 这里原来还有一条组合兜底：消息里同时出现「登录/鉴权/认证/授权/token」和
    // 「过期/失效/无效」就判失效。撤掉了——「无效」「授权」在业务报错里太常见，
    // 「该车辆未授权，参数无效」这种句子会被它一并判成登录失效，把人踢回登录页。
    // 401/403 才是新链路的强判据，兜底那点覆盖率不值这个代价。
    //
    // 成功响应也会走这个判断，别把正常返回也刷进日志。
    if (!response.isSuccess && message.length > 0) {
      DiagLog.note(`[auth] 新链路未命中失效判据，按业务错误处理：${message}`);
    }
    return false;
  }

  private static uniqueHosts(hosts: string[]): string[] {
    const seen = new Set<string>();
    const out: string[] = [];
    for (let i = 0; i < hosts.length; i++) {
      const host = hosts[i];
      if (host.length > 0 && !seen.has(host)) {
        seen.add(host);
        out.push(host);
      }
    }
    return out;
  }

  private static trimTrailingSlash(value: string): string {
    let out = value;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
