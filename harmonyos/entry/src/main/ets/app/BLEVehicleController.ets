import { BLEPairingPreparation } from './BLEPairingPreparation';
import { systemDateTime } from '@kit.BasicServicesKit';
import { CallCarController } from './CallCarController';
import { BLECalibration } from '../core/BLECalibration';
import { BLEUnlockDistance } from '../core/BLEProtocol';
import { ble, access, constant } from '@kit.ConnectivityKit';

import { BLEPassiveEntryTask } from './BLEPassiveEntryTask';
import { DiagLog } from '../core/DiagLog';
import { LeapError } from '../core/LeapError';
import {
  LeapBLEProtocol, LeapBytes, LeapBLECredentialContext, LeapBLEControlCommand,
  leapBLEControlCommandLabel, StraightMoveDirection, StraightMoveOrder, straightMoveOrderOf,
  straightMoveOrderLabel,
  LeapBLEConfiguration, LeapBLEDecryptedResponse, LeapBLEResponseKind, LeapBLECryptoSession,
  LeapBLEFrame, LeapBLEFrameKind, LeapBLEFrameReassembler, LeapBLEEvent, LeapBLEEventKind,
  leapBLEFrameKindLabel, leapBLEAuthenticationResultDescription
} from '../core/BLEProtocol';
import {
  BLEVehicleBinding, BLEVehicleBindingStore, BLEReconnectTokenStore,
  BLEConfigurationSyncState, BLEPairingHistory
} from './BLEVehicleBinding';
import {
  BLEBluetoothState, BLELinkState, BLEAuthenticationState, BLEAuthenticationMode,
  BLERuntimeState, BLERuntimeStateKind, BLEPairingState, BLEPairingStateKind,
  BLEControlAttemptResult, BLEStraightMoveState, BLEStraightMoveStateKind,
  BLEDiscoveredDevice, BLEDiagnosticLogEntry,
  BLEControlAttempt, BLECompletedControlAttempt, BLETransmissionKind, BLETransmissionPurpose,
  BLEBuffer
} from './BLEVehicleControllerTypes';

/**
 * 这条链路是谁要的。
 *
 * 同一套 GATT 代码被三种场景共用，断线之后该不该重连、认证成功之后要不要落绑定，
 * 全看这个值——诊断页连上的车不该被武装逻辑掐掉，配对中的连接也不该走重连重试。
 */
enum BLEConnectionIntent {
  Diagnostic,
  Pairing,
  Managed
}

/**
 * 蓝牙钥匙运行时：扫描、连接、认证、控车、配置同步，外加一份可导出的诊断日志。
 *
 * 逐条对照 iOS 的 `BLEVehicleController`（`App/BLEDiagnosticManager.swift`）移植。
 * 状态机、超时值、日志分类和全部中文文案都刻意保持一致——两端出问题时，
 * 用户发来的截图和导出日志要能直接并排看。
 *
 * 有四处是平台差异，不是漏移植：
 *
 * 1. **没有系统恢复。** CoreBluetooth 会在 App 被杀后为蓝牙事件重新拉起进程
 *    （`willRestoreState`），iOS 那边整套「先挂住恢复来的连接、等武装完成再认领」
 *    （`holdRestoredPeripheral` / `rejectUnclaimedRestoration` / `adoptRestoredPeripheralIfPossible`）
 *    就是为它写的。鸿蒙没有这个机制，进程没了连接也就没了，这几段整体不移植。
 *    对应的能力换成「无感解锁」开关打开时申请 `BLUETOOTH_INTERACTION` 长时任务
 *    （见 `PassiveUnlockService`）——进程活着才谈得上常连。
 *
 * 2. **没有钥匙串三态。** iOS 用 `KeychainLoadOutcome` 区分「没存过」和「锁着读不到」，
 *    后者要挂起武装等解锁重试（`armBlockedByKeychain`）。Asset Store Kit 在锁屏期间
 *    同样返回 NOT_FOUND，两种情况分不出来，所以这套挂起/重试机制没有移植，
 *    读不到一律按 null 处理，且**读失败时不清任何东西**（见 `BLEVehicleBinding.ets` 顶部）。
 *
 * 3. **武装是异步的。** iOS 的 Keychain 读取是同步的，`configureProduction` 也就是同步方法。
 *    Asset Store Kit 只有 Promise，这里整条链路都是 `async`。调用方要 `await`，
 *    不能像 iOS 那样调完立刻读 `runtimeState`。
 *
 * 4. **写特征不用自己做流控。** iOS 的 write-without-response 要盯着
 *    `canSendWriteWithoutResponse` 分批喂，鸿蒙的 `writeCharacteristicValue` 返回 Promise，
 *    顺序 await 就是天然背压，`sendAvailableChunks` 那套状态机收敛成一个循环。
 */
@ObservedV2
export class BLEVehicleController {
  /** 官方 iOS 1.20.64 的分片发送分支上限 160 字节。 */
  private static readonly preferredMtu: number = 200;
  private static readonly maximumChunkSize: number = 160;
  /**
   * 服务发现的耐心。车友日志里它卡满 9.5 秒都没回，一直干等到车端把连接踢掉——
   * 与其把这段时间白白耗在一条已经不健康的链路上，不如早点断开重来：
   * GATT 服务表系统会缓存，第二次连基本是秒回。
   */
  private static readonly discoveryTimeout: number = 5000;
  /**
   * 等 MTU 协商结果的耐心。实测事件 17 ms 就回来了，1.5 秒是留给弱信号的余量。
   * 等不到就丢掉仍有事务在飞的旧链路，重连后跳过 MTU，按 23 分片往下走。
   */
  private static readonly mtuTimeout: number = 1500;
  private static readonly maximumExportLogEntries: number = 4000;
  private static readonly maximumVisibleLogEntries: number = 80;
  /** 这几类只进导出日志，不刷屏、不写系统日志：高频且对用户没有意义。 */
  private static readonly exportOnlyCategories: string[] =
    ['DISCOVER', 'RX-CHUNK', 'TX-CHUNK', 'TX-FRAME', 'REASSEMBLY', 'SERVICE-MAP',
      'COCKPIT-TX', 'COCKPIT-RX'];

  // ---- 可观测状态 ----

  @Trace bluetoothState: BLEBluetoothState = BLEBluetoothState.Unknown;
  @Trace linkState: BLELinkState = BLELinkState.Idle;
  @Trace authenticationState: BLEAuthenticationState = BLEAuthenticationState.MissingCertificate;
  @Trace authenticationMode: BLEAuthenticationMode | null = null;
  @Trace lastSuccessfulAuthenticationMode: BLEAuthenticationMode | null = null;
  @Trace authenticationError: string = '';
  @Trace runtimeState: BLERuntimeState = BLERuntimeState.disabled;
  @Trace pairingState: BLEPairingState = BLEPairingState.idle;
  @Trace straightMoveState: BLEStraightMoveState = BLEStraightMoveState.idle;
  @Trace isScanning: boolean = false;
  @Trace devices: BLEDiscoveredDevice[] = [];
  @Trace entries: BLEDiagnosticLogEntry[] = [];
  @Trace connectedDeviceId: string = '';
  @Trace connectedDeviceName: string = '';
  @Trace discoveredServiceUUIDs: string[] = [];
  @Trace discoveredCharacteristicUUIDs: string[] = [];
  @Trace negotiatedMtu: number = 23;
  @Trace reconnectTokenAvailable: boolean = false;
  @Trace certificateFingerprint: string = '';
  @Trace binding: BLEVehicleBinding | null = null;
  @Trace pendingControlLabel: string = '';
  @Trace lastConfirmedControlCommand: LeapBLEControlCommand | null = null;
  @Trace productionEligible: boolean = false;
  private productionRefreshGeneration: number = 0;
  pairingPreparationGeneration: number = 0;
  /** 车辆资料里的蓝牙地址。只用于导出日志里的比对，不参与连接。 */
  @Trace vehicleBluetoothAddress: string = '';

  // ---- 非观测内部状态 ----

  readonly callCar: CallCarController = new CallCarController(
    (category: string, message: string, sensitiveDetail: string): void => {
      this.append(category, message, sensitiveDetail);
    });
  private credentialContext: LeapBLECredentialContext | null = null;
  private client: ble.GattClientDevice | null = null;
  private characteristic: ble.BLECharacteristic | null = null;
  private writeType: ble.GattWriteType = ble.GattWriteType.WRITE;
  private cryptoSession: LeapBLECryptoSession | null = null;
  private reconnectToken: string = '';
  private lastConnectedDeviceId: string = '';
  private applicationIsActive: boolean = true;
  private connectionIntent: BLEConnectionIntent = BLEConnectionIntent.Diagnostic;
  private pairingCandidateId: string = '';
  /** 当前 GATT 客户端对应的设备。判断「要连的那台是不是已经连上了」用它。 */
  private linkDeviceId: string = '';
  /** 已经因服务发现超时重连过一次的设备。每台车只兜底一次，避免连不上时空转。 */
  private discoveryRetriedDeviceId: string = '';
  /** 每次发起连接自增。超时任务靠它判断「我等的还是不是这一轮」。 */
  private connectionEpoch: number = 0;
  private transmissionPurpose: BLETransmissionPurpose | null = null;
  private transmissionInFlight: boolean = false;
  private transmissionGeneration: number = 0;
  private diagnosticAuthentication: number = 0;
  private diagnosticAuthStarted: number = -1;
  private diagnosticAuthSentParts: number = 0;
  private diagnosticAuthAckedParts: number = 0;
  private diagnosticAuthTotalParts: number = 0;

  private authenticationTrace(): string {
    const elapsed = this.diagnosticAuthStarted < 0 ? -1
      : systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false) - this.diagnosticAuthStarted;
    return `connection=${this.connectionEpoch} attempt=${this.diagnosticAuthentication} elapsedMs=${elapsed} sent=${this.diagnosticAuthSentParts}/${this.diagnosticAuthTotalParts} acked=${this.diagnosticAuthAckedParts}`;
  }
  private pendingFullAuthenticationFallback: boolean = false;
  private configurationInFlight: LeapBLEConfiguration | null = null;
  private activeControlAttempt: BLEControlAttempt | null = null;
  private completedControlAttempt: BLECompletedControlAttempt | null = null;
  private controlAttemptSeed: number = 0;
  private pendingStraightMoveOrder: StraightMoveOrder | null = null;
  private lastStraightMoveTransmissionAt: number = 0;
  private readonly reassembler: LeapBLEFrameReassembler = new LeapBLEFrameReassembler();
  private readonly bindingStore: BLEVehicleBindingStore = new BLEVehicleBindingStore();
  private readonly reconnectTokenStore: BLEReconnectTokenStore = new BLEReconnectTokenStore();
  private exportEntries: BLEDiagnosticLogEntry[] = [];
  private loggedAdvertisementSignatures: Map<string, Set<string>> = new Map();

  // 定时器句柄。-1 表示没有排定。
  private pairingTimeoutTimer: number = -1;
  private responseTimeoutTimer: number = -1;
  private straightMoveHeartbeatTimer: number = -1;
  private straightMoveWatchdogTimer: number = -1;
  private straightMoveStopTimer: number = -1;
  private managedRetryTimer: number = -1;
  /** 释放旧 GATT 句柄后延迟发起的单次重连。所有退出路径都必须能取消它。 */
  private linkRetryTimer: number = -1;

  // 监听器句柄。解绑时要传同一个引用，必须存下来。
  private scanListener: ((results: Array<ble.ScanResult>) => void) | null = null;
  private connectionListener: ((state: ble.BLEConnectionChangeState) => void) | null = null;
  private characteristicListener: ((value: ble.BLECharacteristic) => void) | null = null;
  private mtuListener: ((mtu: number) => void) | null = null;
  /**
   * 等 `BLEMtuChange` 的钩子。`setBLEMtuSize` 是同步返回 void 的，只把请求发出去，
   * 协商结果单独走事件回来——想等它，只能自己在这里挂一根线。
   */
  private mtuResolver: ((mtu: number) => void) | null = null;
  /** MTU 协商超时后的下一次连接跳过主动协商，直接按默认 23 分片。 */
  private skipMtuOnceDeviceId: string = '';
  private accessListener: ((state: access.BluetoothState) => void) | null = null;

  // ---- 生命周期 ----

  /** 进程内只建一次。监听系统蓝牙开关，其余一律等武装。 */
  start(): void {
    this.refreshBluetoothState();
    if (this.accessListener !== null) {
      return;
    }
    this.accessListener = (state: access.BluetoothState): void => {
      this.handleBluetoothStateChange(state);
    };
    try {
      access.on('stateChange', this.accessListener);
    } catch (e) {
      this.accessListener = null;
      this.append('ERROR', `监听系统蓝牙状态失败：${BLEVehicleController.messageOf(e as object)}`, '');
    }
  }

  /** 车辆资料里的蓝牙地址，只写进导出日志的抬头，方便和实际连上的设备对一眼。 */
  configureVehicleBluetoothAddress(address: string): void {
    this.vehicleBluetoothAddress = address;
  }

  /**
   * 诊断页用的轻量配置：只装证书，不做武装，也不碰绑定。
   *
   * 蓝牙钥匙页要能在还没配对时就连上车看协议交互，那条路走这里。
   */
  async configure(credentialContext: LeapBLECredentialContext | null): Promise<void> {
    this.callCar.configure(credentialContext);
    this.credentialContext = credentialContext;
    if (credentialContext === null) {
      this.certificateFingerprint = '';
      this.reconnectToken = '';
      this.reconnectTokenAvailable = false;
      this.authenticationState = BLEAuthenticationState.MissingCertificate;
      return;
    }
    this.certificateFingerprint = credentialContext.certificate.fingerprint;
    const token = await this.reconnectTokenStore.load(credentialContext.accountId, credentialContext.vin);
    if (this.credentialContext !== credentialContext) { return; }
    if (token !== null && token.length > 0 && BLEVehicleController.isDecodableToken(token)) {
      this.reconnectToken = token;
      this.reconnectTokenAvailable = true;
    } else {
      if (token !== null && token.length > 0) {
        await this.reconnectTokenStore.clear(credentialContext.accountId, credentialContext.vin);
        if (this.credentialContext !== credentialContext) { return; }
        this.append('TOKEN', '已保存的快速重连凭证不是合法十六进制，已丢弃', '');
      }
      this.reconnectToken = '';
      this.reconnectTokenAvailable = false;
    }
    if (this.authenticationState === BLEAuthenticationState.MissingCertificate) {
      this.authenticationState = BLEAuthenticationState.Prepared;
    }
  }

  /**
   * 生产武装：按资格和证书决定要不要维持常连。
   *
   * 和 iOS 的 `configureProduction` 同一条判定顺序，只是少了 `credentialUnreadable`
   * 那一路（Asset Store Kit 分不出「锁着」和「没有」，见文件顶部第 2 条）。
   */
  async configureProduction(credentialContext: LeapBLECredentialContext | null,
    eligible: boolean): Promise<void> {
    const generation = ++this.productionRefreshGeneration;
    const sameContext = BLEPairingPreparation.preservesConnection(BLEPairingStateKind.Scanning,
      this.credentialContext, credentialContext, eligible);
    this.productionEligible = eligible;
    if (this.preserveManualPairing(credentialContext, eligible)) { return; }
    await this.configure(credentialContext);
    if (generation !== this.productionRefreshGeneration) { return; }

    if (!eligible || credentialContext === null) {
      this.binding = null;
      this.runtimeState = eligible ? BLERuntimeState.needsAttention('缺少当前车辆的蓝牙证书')
        : BLERuntimeState.disabled;
      await BLEPassiveEntryTask.stop();
      if (generation !== this.productionRefreshGeneration) { return; }
      this.stopManagedConnection(false);
      return;
    }
    if (!credentialContext.certificate.isSupportedKeyType) {
      this.binding = null;
      this.runtimeState = BLERuntimeState.needsAttention(
        `当前蓝牙证书类型不受支持（keyType=${credentialContext.certificate.keyType}）`);
      this.stopManagedConnection(false);
      return;
    }
    if (!credentialContext.certificate.hasValidPasswordCard) {
      this.binding = null;
      this.runtimeState = BLERuntimeState.needsAttention('当前蓝牙证书的 passwordCard 无效，请重新同步');
      this.stopManagedConnection(false);
      return;
    }

    let stored = await this.bindingStore.load(credentialContext.accountId, credentialContext.vin);
    if (generation !== this.productionRefreshGeneration
      || (sameContext && this.preserveManualPairing(credentialContext, eligible))) { return; }
    if (stored !== null && stored.certificateFingerprint !== credentialContext.certificate.fingerprint) {
      // 证书换了，车端认的会话密钥也换了，旧 token 一定过不去，先清掉免得白试一轮。
      await this.reconnectTokenStore.clear(stored.accountId, stored.vin);
      if (generation !== this.productionRefreshGeneration
        || (sameContext && this.preserveManualPairing(credentialContext, eligible))) { return; }
      this.reconnectToken = '';
      this.reconnectTokenAvailable = false;
      stored.certificateFingerprint = credentialContext.certificate.fingerprint;
      stored.syncState = stored.configuration.isEnabled
        ? BLEConfigurationSyncState.Pending : BLEConfigurationSyncState.PendingDisable;
      stored.lastVerifiedAt = 0;
      await this.bindingStore.save(stored);
      if (generation !== this.productionRefreshGeneration
        || (sameContext && this.preserveManualPairing(credentialContext, eligible))) { return; }
    }
    this.binding = stored;
    // 重启 App 之后也要把长时任务接回来：开关的真值存在绑定里，进程里的标记是空的。
    await this.syncPassiveEntryTask();
    if (generation !== this.productionRefreshGeneration
      || (sameContext && this.preserveManualPairing(credentialContext, eligible))) { return; }

    if (stored === null) {
      this.stopManagedConnection(false);
      this.runtimeState = BLERuntimeState.unbound;
      return;
    }
    if (!stored.shouldMaintainConnection) {
      this.runtimeState = BLERuntimeState.disabled;
      this.stopManagedConnection(false);
      return;
    }
    this.ensureManagedConnection();
  }

  private preserveManualPairing(context: LeapBLECredentialContext | null, eligible: boolean): boolean {
    if (!BLEPairingPreparation.preservesConnection(this.pairingState.kind,
      this.credentialContext, context, eligible)) { return false; }
    this.recordPairingPreparation(`context.refresh.preservePairing state=${this.pairingState.kind}`);
    return true;
  }

  recordPairingPreparation(message: string): void {
    this.append('AUTH', message, '');
  }

  setApplicationActive(active: boolean): void {
    this.callCar.setApplicationActive(active);
    this.applicationIsActive = active;
    if (!active) {
      if (this.straightMoveState.isPrepared) {
        this.emergencyStopStraightMove('App 已离开前台');
      }
      if (this.pairingState.kind === BLEPairingStateKind.Scanning) {
        this.cancelPairing();
      }
      return;
    }
    this.ensureManagedConnection();
  }

  /**
   * 退登/换车/退出资格。
   *
   * `clearBinding` 为真时把持久化的绑定和 token 整批删掉——内存里的 `binding`
   * 这时可能已经因为资格或证书变化被清空了，按账号一条条删会漏，只能按前缀全删。
   */
  async deactivate(clearBinding: boolean): Promise<void> {
    this.productionRefreshGeneration++;
    this.pairingPreparationGeneration++;
    this.cancelPairingTimeout();
    this.stopScan();
    this.productionEligible = false;
    this.pairingState = BLEPairingState.idle;
    this.runtimeState = BLERuntimeState.disabled;
    if (clearBinding) {
      await this.bindingStore.clearAll();
      await this.reconnectTokenStore.clearAll();
    }
    this.binding = null;
    await BLEPassiveEntryTask.stop();
    this.stopManagedConnection(true);
    await this.configure(null);
  }

  // ---- 派生状态 ----

  /** 已认证且链路可写。首页按下锁车时先看它。 */
  get canControl(): boolean {
    return this.linkState === BLELinkState.Ready
      && this.authenticationState === BLEAuthenticationState.Authenticated
      && this.cryptoSession !== null;
  }

  get canAuthenticate(): boolean {
    return this.linkState === BLELinkState.Ready && this.credentialContext !== null
      && this.authenticationState !== BLEAuthenticationState.Authenticating;
  }

  /** 按钮文案：手上有 token 就是快速重连，没有就得走完整认证。 */
  get preferredAuthenticationLabel(): string {
    return this.reconnectTokenAvailable ? '发送 AA EE 快速重连' : '发送 AA AE 完整认证';
  }

  get canReconnectLastDevice(): boolean {
    return this.lastConnectedDeviceId.length > 0
      && this.bluetoothState === BLEBluetoothState.PoweredOn;
  }

  /** 蓝牙控车总开关。没绑定车就是关——设置页里那一整段这时本来也不显示。 */
  get isBluetoothControlEnabled(): boolean {
    const binding = this.binding;
    return binding !== null && binding.isBluetoothControlEnabled;
  }

  /** 无感解锁。它同时决定要不要起长时任务，见 `syncPassiveEntryTask`。 */
  get autoUnlockEnabled(): boolean {
    const binding = this.binding;
    return binding !== null && binding.configuration.autoUnlockEnabled;
  }

  /** 离车自动闭锁。 */
  get autoLockEnabled(): boolean {
    const binding = this.binding;
    return binding !== null && binding.configuration.autoLockEnabled;
  }

  /** 9 字节配置有没有写回车里。没绑定时给 null，界面显示「未绑定」。 */
  get configurationSyncState(): BLEConfigurationSyncState | null {
    const binding = this.binding;
    return binding === null ? null : binding.syncState;
  }

  /** 扫描结果里最值得连的一台：先看广播里有没有 FFFE，再看信号强弱。 */
  get recommendedDevice(): BLEDiscoveredDevice | null {
    let best: BLEDiscoveredDevice | null = null;
    for (const device of this.devices) {
      if (best === null) {
        best = device;
        continue;
      }
      if (device.advertisesTargetService !== best.advertisesTargetService) {
        if (device.advertisesTargetService) {
          best = device;
        }
        continue;
      }
      if (device.rssi > best.rssi) {
        best = device;
      }
    }
    return best;
  }

  // ---- 配对 ----

  /**
   * 开始按 FFFE 搜索当前车辆。
   *
   * 鸿蒙的 GATT 其实可以直接按 deviceId 连，不必先扫；但配对这一步的目的正是
   * 「拿到这台车的 deviceId」，所以和 iOS 一样必须扫一轮。
   */
  beginPairing(): void {
    if (!this.productionEligible) {
      this.pairingState = BLEPairingState.failed('演示模式不能使用蓝牙钥匙');
      return;
    }
    if (!this.applicationIsActive) {
      this.pairingState = BLEPairingState.failed('请回到 App 前台后搜索车辆');
      return;
    }
    const context = this.credentialContext;
    if (context === null) {
      this.pairingState = BLEPairingState.failed('请先同步当前车辆的蓝牙证书');
      return;
    }
    if (!context.certificate.isSupportedKeyType) {
      this.pairingState = BLEPairingState.failed(
        `当前蓝牙证书类型不受支持（keyType=${context.certificate.keyType}）`);
      return;
    }
    if (!context.certificate.hasValidPasswordCard) {
      this.pairingState = BLEPairingState.failed('当前蓝牙证书的 passwordCard 无效，请重新同步');
      return;
    }
    if (this.bluetoothState !== BLEBluetoothState.PoweredOn) {
      this.runtimeState = BLERuntimeState.waitingForBluetooth;
      switch (this.bluetoothState) {
        case BLEBluetoothState.Unknown:
        case BLEBluetoothState.Resetting:
          this.pairingState = BLEPairingState.preparing;
          break;
        case BLEBluetoothState.PoweredOff:
          this.pairingState = BLEPairingState.failed('请先打开手机蓝牙');
          break;
        case BLEBluetoothState.Unauthorized:
          this.pairingState = BLEPairingState.failed('请在系统设置中允许壹跑使用蓝牙');
          break;
        default:
          this.pairingState = BLEPairingState.failed('这台设备不支持低功耗蓝牙');
          break;
      }
      return;
    }

    this.closeClient();
    this.stopScan();
    this.devices = [];
    this.loggedAdvertisementSignatures = new Map();
    if (!this.startScanning(true)) {
      this.pairingState = BLEPairingState.failed('无法开始扫描，请检查蓝牙权限');
      return;
    }
    this.pairingState = BLEPairingState.scanning;
    this.runtimeState = BLERuntimeState.scanning;
    this.append('PAIR', '开始按 FFFE 搜索当前车辆', '');
    this.schedulePairingScanTimeout();
  }

  pair(deviceId: string): void {
    if (this.pairingState.kind !== BLEPairingStateKind.Scanning) {
      this.pairingState = BLEPairingState.failed('候选车辆已经离开扫描范围');
      return;
    }
    this.pairingCandidateId = deviceId;
    this.pairingState = BLEPairingState.connecting(deviceId);
    // 用户自己又点了一次配对，服务发现的兜底额度重新给——上一轮用掉的不该记在这一轮头上。
    this.discoveryRetriedDeviceId = '';
    this.skipMtuOnceDeviceId = '';
    this.openLink(deviceId, BLEConnectionIntent.Pairing);
    this.schedulePairingConnectionTimeout(deviceId, this.connectionEpoch);
  }

  cancelPairing(): void {
    this.pairingPreparationGeneration++;
    this.cancelPairingTimeout();
    this.stopScan();
    if (this.connectionIntent === BLEConnectionIntent.Pairing) {
      this.closeClient();
      this.resetVolatileConnectionState();
    }
    this.pairingState = BLEPairingState.idle;
    const binding = this.binding;
    if (binding !== null && binding.shouldMaintainConnection) {
      this.ensureManagedConnection();
    } else if (binding === null) {
      this.runtimeState = BLERuntimeState.unbound;
    }
  }

  // ---- 设置 ----

  /** 开/关蓝牙控车。关的那一步同样要连上去把 9 字节配置写回车里，不是本机改个开关。 */
  async setUnlockDistance(distance: BLEUnlockDistance): Promise<void> {
    if (this.binding === null) { return; }
    const configuration = this.binding.configuration.withUnlockDistance(distance);
    this.append('CONFIG', `distance.selected before={${this.binding.configuration.diagnosticSummary()}} after={${configuration.diagnosticSummary()}}`, '');
    await this.persistAndApply(this.binding.withConfiguration(configuration,
      configuration.isEnabled ? BLEConfigurationSyncState.Pending : BLEConfigurationSyncState.PendingDisable));
  }

  async applyCalibration(calibration: BLECalibration, accountId: string, vin: string): Promise<void> {
    if (this.binding === null || this.binding.accountId !== accountId || this.binding.vin !== vin) { return; }
    const configuration = calibration.applying(this.binding.configuration);
    this.append('CONFIG', `calibration.apply changed=${!configuration.equals(this.binding.configuration)} ${configuration.diagnosticSummary()}`, '');
    if (configuration.equals(this.binding.configuration)) { return; }
    await this.persistAndApply(this.binding.withConfiguration(configuration,
      configuration.isEnabled ? BLEConfigurationSyncState.Pending : BLEConfigurationSyncState.PendingDisable));
  }

  async setBluetoothControlEnabled(enabled: boolean): Promise<void> {
    const binding = this.binding;
    if (binding === null) {
      return;
    }
    // 必须换一个新对象：`binding` 是 `@Trace` 字段，类类型只在引用变化时才通知界面，
    // 原地改字段的话开关会先弹回去、等下一次别的刷新才跟上。
    const configuration = enabled
      ? binding.configuration.withSwitches(true, binding.configuration.autoLockEnabled,
        binding.configuration.autoUnlockEnabled)
      : binding.configuration.withSwitches(false, false, false);
    const next = binding.withConfiguration(configuration,
      enabled ? BLEConfigurationSyncState.Pending : BLEConfigurationSyncState.PendingDisable);
    if (enabled) {
      next.removeAfterDisable = false;
    }
    await this.persistAndApply(next);
  }

  /** 无感解锁/无感闭锁。改这两项一定伴随一次配置下发。 */
  async updatePassiveEntry(autoUnlock: boolean, autoLock: boolean): Promise<void> {
    const binding = this.binding;
    if (binding === null) {
      return;
    }
    const next = binding.withConfiguration(
      binding.configuration.withSwitches(true, autoLock, autoUnlock),
      BLEConfigurationSyncState.Pending);
    next.removeAfterDisable = false;
    await this.persistAndApply(next);
  }

  /** 解绑：先把「关掉」这条配置发给车，车确认之后才删本机记录。 */
  async removeBinding(): Promise<void> {
    const binding = this.binding;
    if (binding === null) {
      return;
    }
    const next = binding.withConfiguration(binding.configuration.withSwitches(false, false, false),
      BLEConfigurationSyncState.PendingDisable);
    next.removeAfterDisable = true;
    await this.persistAndApply(next);
  }

  // ---- 控制 ----

  /**
   * 首页锁车/解锁的蓝牙优先路径。
   *
   * 返回值区分「写之前就不行」和「写出去之后才失败」——只有前者调用方才可以回退 HTTP，
   * 详见 `BLEControlAttemptResult.shouldFallbackToHTTP`。
   */
  async performControl(command: LeapBLEControlCommand,
    connectionTimeoutMillis: number = 6000): Promise<BLEControlAttemptResult> {
    const binding = this.binding;
    if (!this.productionEligible || binding === null || !binding.isBluetoothControlEnabled) {
      return BLEControlAttemptResult.unavailableBeforeWrite('蓝牙钥匙未启用');
    }
    this.ensureManagedConnection();

    const deadline = Date.now() + connectionTimeoutMillis;
    while (!this.canControl && Date.now() < deadline) {
      if (this.runtimeState.kind === BLERuntimeStateKind.NeedsAttention) {
        return BLEControlAttemptResult.unavailableBeforeWrite(this.runtimeState.detail);
      }
      await BLEVehicleController.sleep(80);
    }
    if (!this.canControl) {
      return BLEControlAttemptResult.unavailableBeforeWrite('车辆蓝牙连接或认证未就绪');
    }

    this.controlAttemptSeed += 1;
    const attemptId = this.controlAttemptSeed;
    this.completedControlAttempt = null;
    this.activeControlAttempt = new BLEControlAttempt(attemptId);
    const session = this.cryptoSession;
    if (session === null) {
      this.activeControlAttempt = null;
      return BLEControlAttemptResult.unavailableBeforeWrite('蓝牙会话密钥不可用');
    }
    const label = leapBLEControlCommandLabel(command);
    try {
      const frame = session.controlFrame(command);
      this.lastConfirmedControlCommand = null;
      this.pendingControlLabel = label;
      this.append('CONTROL',
        `生成${label}指令 cmdID=${command as number} frame=${frame.length} bytes`, '');
      await this.beginTransmission(frame, BLETransmissionPurpose.control(command, attemptId));
    } catch (e) {
      this.activeControlAttempt = null;
      this.pendingControlLabel = '';
      return BLEControlAttemptResult.unavailableBeforeWrite(BLEVehicleController.messageOf(e as object));
    }

    const resultDeadline = Date.now() + 9000;
    while (Date.now() < resultDeadline) {
      const settled = this.takeControlResult(attemptId);
      if (settled !== null) {
        this.activeControlAttempt = null;
        return settled;
      }
      await BLEVehicleController.sleep(80);
    }
    const didStartWrite = this.didControlWriteStart(attemptId);
    this.activeControlAttempt = null;
    this.pendingControlLabel = '';
    return didStartWrite ? BLEControlAttemptResult.sentWithoutConfirmation
      : BLEControlAttemptResult.unavailableBeforeWrite('蓝牙控制帧未能开始写入');
  }

  /**
   * 取走这次控车的结果，没有就返回 null。
   *
   * 单独立一个方法是为了绕开编译器的类型收窄：`performControl` 里刚把
   * `completedControlAttempt` 赋成 null，之后它就被当成恒为 null 了——
   * 可真正给它赋值的是通知回调，不在这条控制流上。
   */
  private takeControlResult(attemptId: number): BLEControlAttemptResult | null {
    const completed = this.completedControlAttempt;
    if (completed === null || completed.id !== attemptId) {
      return null;
    }
    this.completedControlAttempt = null;
    return completed.result;
  }

  /** 同上：这一帧的第一片有没有真的写出去，决定了还能不能回退 HTTP。 */
  private didControlWriteStart(attemptId: number): boolean {
    const attempt = this.activeControlAttempt;
    return attempt !== null && attempt.id === attemptId && attempt.didStartWrite;
  }

  /** 诊断页手动发一条控制帧。不参与首页的 HTTP 回退判定。 */
  async sendControl(command: LeapBLEControlCommand): Promise<void> {
    const session = this.cryptoSession;
    const label = leapBLEControlCommandLabel(command);
    if (this.authenticationState !== BLEAuthenticationState.Authenticated || session === null) {
      this.append('ERROR', `${label}前必须完成蓝牙认证`, '');
      return;
    }
    try {
      const frame = session.controlFrame(command);
      this.lastConfirmedControlCommand = null;
      this.pendingControlLabel = label;
      this.append('CONTROL',
        `生成${label}指令 cmdID=${command as number} frame=${frame.length} bytes`, '');
      await this.beginTransmission(frame, BLETransmissionPurpose.control(command, 0));
    } catch (e) {
      this.pendingControlLabel = '';
      this.append('ERROR', `生成${label}指令失败：${BLEVehicleController.messageOf(e as object)}`, '');
    }
  }

  // ---- 认证 ----

  /** 有 token 走 `AA EE`，没有或强制时走 `AA AE`。 */
  async authenticate(forceFull: boolean = false): Promise<void> {
    if (this.transmissionInFlight) {
      this.append('AUTH', '等待上一笔写入回调完成', '');
      return;
    }
    if (this.linkState !== BLELinkState.Ready || this.client === null
      || this.characteristic === null) {
      this.append('ERROR', '认证前必须先连接并订阅 FFF2', '');
      return;
    }
    const context = this.credentialContext;
    if (context === null) {
      this.authenticationState = BLEAuthenticationState.MissingCertificate;
      this.append('ERROR', '请先同步蓝牙证书', '');
      return;
    }
    if (this.resolvedProtocolMinor() === undefined) {
      this.failAuthentication('缺少蓝牙协议版本，请联网同步钥匙后重试');
      return;
    }
    try {
      const session = LeapBLECryptoSession.make(context.certificate, context.vin);
      const configuration = this.activeConfiguration();
      let mode: BLEAuthenticationMode;
      let frame: Uint8Array;
      if (!forceFull && this.reconnectToken.length > 0) {
        mode = BLEAuthenticationMode.Reconnect;
        frame = session.reconnectAuthenticationFrame(this.reconnectToken, context.accountId, configuration,
          LeapBytes.currentTimestamp(), this.negotiatedProtocolMinor() < 7, this.negotiatedProtocolMinor());
      } else {
        mode = BLEAuthenticationMode.Full;
        frame = session.fullAuthenticationFrame(context.certificate, context.accountId,
          context.deviceId, LeapBytes.currentTimestamp(), configuration, this.negotiatedProtocolMinor());
      }
      this.diagnosticAuthentication++;
      this.diagnosticAuthStarted = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
      this.diagnosticAuthSentParts = 0;
      this.diagnosticAuthAckedParts = 0;
      this.diagnosticAuthTotalParts = 0;
      const capability = mode === BLEAuthenticationMode.Full ? BLEBuffer.hex(frame.slice(-2)) : 'reconnect';
      this.append('AUTH', `auth.structure ${this.authenticationTrace()} publicKeyBytes=${session.publicKey.length} frameBytes=${frame.length} capability=${capability} certificateFields=${context.certificate.plainText.split(';').length}`, '');
      this.cryptoSession = session;
      this.authenticationMode = mode;
      this.lastConfirmedControlCommand = null;
      this.authenticationState = BLEAuthenticationState.Authenticating;
      this.runtimeState = BLERuntimeState.authenticating;
      if (this.connectionIntent === BLEConnectionIntent.Pairing) {
        this.cancelPairingTimeout();
        this.pairingState = BLEPairingState.authenticating(this.pairingCandidateId);
      }
      this.authenticationError = '';
      const frameType = mode === BLEAuthenticationMode.Reconnect ? 'AA EE' : 'AA AE';
      this.append('AUTH',
        `生成${mode as string}帧 type=${frameType} publicKey=${session.publicKey.length} bytes frame=${frame.length} bytes`,
        '');
      await this.beginTransmission(frame, BLETransmissionPurpose.authentication(mode));
    } catch (e) {
      this.failAuthentication(BLEVehicleController.messageOf(e as object));
    }
  }

  async clearReconnectToken(): Promise<void> {
    await this.invalidateReconnectToken('用户手动清除快速重连凭证');
  }

  // ---- 扫描与连接（诊断页） ----

  /** 诊断页的「扫描全部」。不加服务过滤，用来看周围到底有什么在广播。 */
  startScan(): void {
    if (this.bluetoothState !== BLEBluetoothState.PoweredOn) {
      this.append('ERROR', `蓝牙不可扫描：${this.bluetoothState as string}`, '');
      return;
    }
    if (this.isScanning) {
      return;
    }
    this.devices = [];
    this.loggedAdvertisementSignatures = new Map();
    if (this.startScanning(false)) {
      this.append('SCAN', '开始扫描所有 BLE 广播', '');
    }
  }

  stopScan(): void {
    if (!this.isScanning) {
      return;
    }
    try {
      ble.stopBLEScan();
    } catch (e) {
      this.append('ERROR', `停止扫描失败：${BLEVehicleController.messageOf(e as object)}`, '');
    }
    if (this.scanListener !== null) {
      try {
        ble.off('BLEDeviceFind', this.scanListener);
      } catch (e) {
        // 已经解绑过就算了，没有可补救的动作。
      }
      this.scanListener = null;
    }
    this.isScanning = false;
    this.append('SCAN', `停止扫描，共发现 ${this.devices.length} 个设备`, '');
  }

  connect(deviceId: string): void {
    const binding = this.binding;
    const intent = binding !== null && binding.deviceId === deviceId && this.productionEligible
      ? BLEConnectionIntent.Managed : BLEConnectionIntent.Diagnostic;
    this.openLink(deviceId, intent);
  }

  disconnect(): void {
    if (this.client === null && this.linkRetryTimer === -1) {
      return;
    }
    this.linkState = BLELinkState.Disconnecting;
    this.append('CONNECT', '请求断开连接', '');
    this.closeClient();
    this.resetVolatileConnectionState();
  }

  reconnectLastDevice(): void {
    if (this.lastConnectedDeviceId.length === 0) {
      this.append('ERROR', '上次连接的车辆已不可用，请重新扫描', '');
      return;
    }
    this.connect(this.lastConnectedDeviceId);
  }

  // ---- 日志 ----

  clearLogs(): void {
    this.entries = [];
    this.exportEntries = [];
    this.append('SESSION', '日志已清空', '');
  }

  /**
   * 导出全文。
   *
   * `includingSensitive` 打开才会带上认证材料和密文——这份文本是要发给我排查的，
   * 默认那一份必须能随手发。
   */
  exportText(includingSensitive: boolean): string {
    let address = '(无)';
    if (this.vehicleBluetoothAddress.length > 0) {
      address = includingSensitive ? this.vehicleBluetoothAddress
        : BLEDiscoveredDevice.mask(this.vehicleBluetoothAddress);
    }
    const header: string[] = [
      'LeapControl BLE Diagnostic',
      `service=${LeapBLEProtocol.serviceUUID}`,
      `characteristic=${LeapBLEProtocol.characteristicUUID}`,
      `vehicleBluetoothAddr=${address}`,
      `sensitivePayloads=${includingSensitive ? 'included' : 'redacted'}`,
      `bluetoothState=${this.bluetoothState as string}`,
      `linkState=${this.linkState as string}`,
      `authenticationState=${this.authenticationState as string}`,
      `authenticationMode=${this.authenticationMode === null ? '(无)' : this.authenticationMode as string}`,
      `lastSuccessfulAuthenticationMode=${this.lastSuccessfulAuthenticationMode === null ? '(无)'
        : this.lastSuccessfulAuthenticationMode as string}`,
      `lastConfirmedControl=${this.lastConfirmedControlCommand === null ? '(无)'
        : leapBLEControlCommandLabel(this.lastConfirmedControlCommand)}`,
      `reconnectTokenAvailable=${this.reconnectTokenAvailable}`,
      `mtu=${this.negotiatedMtu}`,
      `certificateFingerprint=${this.certificateFingerprint.length > 0 ? this.certificateFingerprint : '(无)'}`,
      '---'
    ];
    const lines: string[] = header;
    for (const entry of this.exportEntries) {
      lines.push(entry.text(includingSensitive));
    }
    return lines.join('\n');
  }

  // ---- 直进直出 ----

  /**
   * 准备直进直出：确保已连接已认证，最长等 50 秒。
   *
   * 和普通控车不同，这里没有 HTTP 回退——直进直出本来就只有蓝牙这一条路，
   * 等不到就只能失败。
   */
  async prepareStraightMove(): Promise<void> {
    if (!this.productionEligible) {
      this.straightMoveState = BLEStraightMoveState.failed('演示模式不能使用蓝牙钥匙');
      return;
    }
    const binding = this.binding;
    if (binding === null || !binding.isBluetoothControlEnabled) {
      this.straightMoveState = BLEStraightMoveState.failed('请先在蓝牙钥匙里启用蓝牙控车');
      return;
    }
    if (!this.applicationIsActive) {
      this.straightMoveState = BLEStraightMoveState.failed('请回到 App 前台后使用直进直出');
      return;
    }
    if (this.bluetoothState !== BLEBluetoothState.PoweredOn) {
      this.straightMoveState = BLEStraightMoveState.failed('请先打开手机蓝牙');
      return;
    }
    this.straightMoveState = BLEStraightMoveState.preparing;
    this.ensureManagedConnection();

    const deadline = Date.now() + 50000;
    while (!this.canControl && Date.now() < deadline) {
      if (this.straightMoveState.kind !== BLEStraightMoveStateKind.Preparing) {
        // 用户在等待期间退出了这一页，别再把状态改回 ready。
        return;
      }
      await BLEVehicleController.sleep(80);
    }
    if (this.straightMoveState.kind !== BLEStraightMoveStateKind.Preparing) {
      return;
    }
    if (!this.canControl) {
      this.straightMoveState = BLEStraightMoveState.failed('车辆蓝牙连接或认证未就绪');
      return;
    }
    this.straightMoveState = BLEStraightMoveState.ready;
    this.append('STRAIGHT', '直进直出已就绪', '');
  }

  /**
   * 开始挪车。
   *
   * 车端把「连续收到指令」当成「用户手指还按着」，所以按下之后必须每 100 毫秒补发一次；
   * 另有一条看门狗盯着实际发出时间，超过 350 毫秒没发出去就立刻急停——
   * 手指还按着但帧堵在链路上，车却在动，这是这套功能唯一会伤人的失败模式。
   */
  async startStraightMove(direction: StraightMoveDirection): Promise<void> {
    if (!this.straightMoveState.isPrepared) {
      return;
    }
    this.straightMoveState = BLEStraightMoveState.moving(direction);
    const order = straightMoveOrderOf(direction);
    this.lastStraightMoveTransmissionAt = Date.now();
    this.append('STRAIGHT', `开始${straightMoveOrderLabel(order)}`, '');
    await this.sendStraightMove(order);
    this.startStraightMoveHeartbeat(order);
  }

  /** 松手：停下但保留就绪状态，用户可以接着按另一个方向。 */
  async stopStraightMove(): Promise<void> {
    await this.haltStraightMove(BLEStraightMoveState.paused);
  }

  /** 退出直进直出页：停车并回到未准备状态。 */
  async closeStraightMove(): Promise<void> {
    await this.haltStraightMove(BLEStraightMoveState.idle);
  }

  private startStraightMoveHeartbeat(order: StraightMoveOrder): void {
    this.cancelStraightMoveTimers();
    this.straightMoveHeartbeatTimer = setInterval((): void => {
      if (!this.straightMoveState.isMoving) {
        this.cancelStraightMoveTimers();
        return;
      }
      this.sendStraightMove(order);
    }, 100);
    this.straightMoveWatchdogTimer = setInterval((): void => {
      if (!this.straightMoveState.isMoving) {
        return;
      }
      if (Date.now() - this.lastStraightMoveTransmissionAt > 350) {
        this.emergencyStopStraightMove('指令发送已中断');
      }
    }, 100);
  }

  private async haltStraightMove(finalState: BLEStraightMoveState): Promise<void> {
    this.cancelStraightMoveTimers();
    const wasMoving = this.straightMoveState.isMoving;
    if (wasMoving) {
      this.append('STRAIGHT', '停止挪车', '');
      await this.sendStraightMove(StraightMoveOrder.Stop);
      // 停车帧一条都不能丢，补发两次。写没出去和车没收到从这一层看不出区别。
      await BLEVehicleController.sleep(70);
      await this.sendStraightMove(StraightMoveOrder.Stop);
      await BLEVehicleController.sleep(70);
      await this.sendStraightMove(StraightMoveOrder.Stop);
      await BLEVehicleController.sleep(140);
    }
    this.pendingStraightMoveOrder = null;
    this.straightMoveState = finalState;
  }

  private emergencyStopStraightMove(reason: string): void {
    this.cancelStraightMoveTimers();
    this.append('STRAIGHT', `急停：${reason}`, '');
    this.pendingStraightMoveOrder = StraightMoveOrder.Stop;
    this.sendStraightMove(StraightMoveOrder.Stop);
    this.straightMoveState = BLEStraightMoveState.failed(reason);
  }

  private cancelStraightMoveTimers(): void {
    if (this.straightMoveHeartbeatTimer !== -1) {
      clearInterval(this.straightMoveHeartbeatTimer);
      this.straightMoveHeartbeatTimer = -1;
    }
    if (this.straightMoveWatchdogTimer !== -1) {
      clearInterval(this.straightMoveWatchdogTimer);
      this.straightMoveWatchdogTimer = -1;
    }
    if (this.straightMoveStopTimer !== -1) {
      clearTimeout(this.straightMoveStopTimer);
      this.straightMoveStopTimer = -1;
    }
  }

  private async sendStraightMove(order: StraightMoveOrder): Promise<void> {
    const session = this.cryptoSession;
    if (session === null || !this.canControl) {
      return;
    }
    if (this.transmissionInFlight) {
      this.queueStraightMove(order);
      return;
    }
    try {
      const frame = session.straightMoveFrame(order);
      this.lastStraightMoveTransmissionAt = Date.now();
      await this.beginTransmission(frame, BLETransmissionPurpose.straightMove);
    } catch (e) {
      this.append('ERROR', `${straightMoveOrderLabel(order)}指令发送失败：${BLEVehicleController.messageOf(e as object)}`, '');
    }
  }

  /**
   * 合并排队中的挪车指令。
   *
   * 心跳比一帧的写入还快，排队会越堆越长。合并规则：停止永远压过一切，
   * 方向指令只留最新的一条——晚到的那条才代表用户此刻的手指。
   */
  private queueStraightMove(order: StraightMoveOrder): void {
    if (this.pendingStraightMoveOrder === StraightMoveOrder.Stop) {
      return;
    }
    this.pendingStraightMoveOrder = order;
  }

  // ---- 配置同步 ----

  private activeConfiguration(): LeapBLEConfiguration {
    if (this.connectionIntent === BLEConnectionIntent.Pairing) {
      // 配对这一帧先把车设成「只手动控车」，无感相关的开关等用户自己开。
      return LeapBLEConfiguration.manualControl;
    }
    const binding = this.binding;
    if (binding !== null) {
      return binding.configuration;
    }
    return this.connectionIntent === BLEConnectionIntent.Managed
      ? LeapBLEConfiguration.manualControl : LeapBLEConfiguration.officialDefault;
  }

  private async persistAndApply(next: BLEVehicleBinding): Promise<void> {
    await this.bindingStore.save(next);
    if (this.binding?.accountId !== next.accountId || this.binding?.vin !== next.vin) { return; }
    this.binding = next;
    await this.syncPassiveEntryTask();
    if (!next.shouldMaintainConnection) {
      this.runtimeState = BLERuntimeState.disabled;
      this.stopManagedConnection(false);
      return;
    }
    this.ensureManagedConnection();
    await this.sendPendingConfigurationIfPossible();
  }

  /**
   * 让长时任务跟着「无感」那两个开关走。
   *
   * 只要车端开了无感解锁或离车自动闭锁，手机就得一直连着车，否则人走到车边时
   * 进程早被回收了。这是鸿蒙独有的一层，iOS 靠 CoreBluetooth 的状态恢复不需要它。
   */
  private async syncPassiveEntryTask(): Promise<void> {
    const binding = this.binding;
    const wanted = this.productionEligible && binding !== null
      && binding.isBluetoothControlEnabled && binding.isPassiveEntryEnabled;
    if (wanted) {
      await BLEPassiveEntryTask.start();
    } else {
      await BLEPassiveEntryTask.stop();
    }
  }

  /** 已认证且还有没同步的配置时，下发命令 3。 */
  private cloudVersionAccount: string = '';
  private cloudVersionVin: string = '';
  private cloudVersionMinor: number | undefined = undefined;

  configureProtocolVersion(minor: number, accountId: string, vin: string): void {
    if (this.credentialContext?.accountId !== accountId || this.credentialContext?.vin !== vin || minor < 0 || minor > 255) { return; }
    this.cloudVersionAccount = accountId;
    this.cloudVersionVin = vin;
    this.cloudVersionMinor = minor;
    this.append('VERSION', `version.cloud profile=${minor}`, '');
    if (this.linkState === BLELinkState.Ready && this.authenticationState !== BLEAuthenticationState.Authenticating && this.authenticationState !== BLEAuthenticationState.Authenticated) {
      this.authenticate(false);
    }
  }

  private resolvedProtocolMinor(): number | undefined {
    const device = this.devices.find((item: BLEDiscoveredDevice) => item.deviceId === this.connectedDeviceId);
    const saved = this.binding?.deviceId === this.connectedDeviceId ? this.binding?.protocolMinor : undefined;
    const cloud = this.cloudVersionAccount === this.credentialContext?.accountId && this.cloudVersionVin === this.credentialContext?.vin ? this.cloudVersionMinor : undefined;
    return LeapBLEProtocol.resolvedProtocolMinor(cloud, device?.serviceUUIDs ?? [], saved);
  }

  private negotiatedProtocolMinor(): number { return this.resolvedProtocolMinor() ?? 8; }

  private async sendPendingConfigurationIfPossible(): Promise<void> {
    const binding = this.binding;
    const session = this.cryptoSession;
    if (binding === null || session === null || !this.canControl) {
      return;
    }
    if (binding.syncState === BLEConfigurationSyncState.Synced) {
      return;
    }
    if (this.configurationInFlight !== null) {
      return;
    }
    const configuration = binding.configuration;
    this.configurationInFlight = configuration;
    this.runtimeState = BLERuntimeState.syncingConfiguration;
    try {
      const frame = session.configurationFrame(configuration, LeapBytes.currentTimestamp(), this.negotiatedProtocolMinor());
      this.append('CONFIG',
        `configuration.send cmd=3 ${configuration.diagnosticSummary(this.negotiatedProtocolMinor())}`, '');
      await this.beginTransmission(frame, BLETransmissionPurpose.configuration);
    } catch (e) {
      this.configurationInFlight = null;
      this.append('ERROR', `下发蓝牙钥匙配置失败：${BLEVehicleController.messageOf(e as object)}`, '');
    }
  }

  private async completeConfigurationSync(success: boolean, detail: string): Promise<void> {
    const sent = this.configurationInFlight;
    this.configurationInFlight = null;
    const binding = this.binding;
    if (sent === null || binding === null) {
      return;
    }
    if (!success) {
      this.append('ERROR', `车辆拒绝了蓝牙钥匙配置：${detail}`, '');
      this.runtimeState = BLERuntimeState.needsAttention('车辆未接受蓝牙钥匙设置，请稍后重试');
      return;
    }
    if (!binding.configuration.equals(sent)) {
      // 发出去到车确认之间用户又改了一次。刚确认的是旧配置，得再发一轮。
      this.append('CONFIG', `configuration.ack.stale sent={${sent.diagnosticSummary()}} current={${binding.configuration.diagnosticSummary()}}`, '');
      await this.sendPendingConfigurationIfPossible();
      return;
    }

    const next = binding.withConfiguration(sent, BLEConfigurationSyncState.Synced);
    if (next.protocolMinor !== this.negotiatedProtocolMinor() && next.syncState === BLEConfigurationSyncState.Synced) {
      next.syncState = BLEConfigurationSyncState.Pending;
    }
    next.protocolMinor = this.negotiatedProtocolMinor();
    next.lastVerifiedAt = Date.now();
    this.append('CONFIG', `configuration.synced vehicleAccepted=true ${sent.diagnosticSummary()}`, '');

    if (!sent.isEnabled && binding.removeAfterDisable) {
      // 车已经确认「关掉」了，这时候删本机记录才不会留下一台还在认我的车。
      await this.bindingStore.clear(binding.accountId, binding.vin);
      await this.reconnectTokenStore.clear(binding.accountId, binding.vin);
      this.reconnectToken = '';
      this.reconnectTokenAvailable = false;
      this.binding = null;
      this.pairingState = BLEPairingState.idle;
      this.runtimeState = BLERuntimeState.unbound;
      this.append('BIND', '已解除与该车辆的蓝牙钥匙绑定', '');
      this.stopManagedConnection(false);
      return;
    }

    await this.bindingStore.save(next);
    this.binding = next;
    if (!sent.isEnabled) {
      this.runtimeState = BLERuntimeState.disabled;
      this.stopManagedConnection(false);
      return;
    }
    this.runtimeState = BLERuntimeState.ready;
  }

  /** 配对认证成功：这时候才落绑定，之前认证没过的都不算数。 */
  private async completePairingIfNeeded(): Promise<void> {
    if (this.connectionIntent !== BLEConnectionIntent.Pairing) {
      return;
    }
    const context = this.credentialContext;
    if (context === null || this.linkDeviceId.length === 0) {
      return;
    }
    this.cancelPairingTimeout();
    const next = new BLEVehicleBinding(context.accountId, context.vin, this.linkDeviceId,
      context.certificate.fingerprint, LeapBLEConfiguration.manualControl,
      BLEConfigurationSyncState.Synced, false, Date.now(), this.negotiatedProtocolMinor());
    await this.bindingStore.save(next);
    this.binding = next;
    BLEPairingHistory.recordPaired(context.accountId, context.vin);
    await this.persistDeviceId(this.linkDeviceId);
    this.connectionIntent = BLEConnectionIntent.Managed;
    this.pairingState = BLEPairingState.bound;
    this.runtimeState = BLERuntimeState.ready;
    this.append('BIND', '配对完成，已记住这台车', '');
  }

  /**
   * 记住这台车的 deviceId。
   *
   * 鸿蒙给出的 deviceId 是随机地址，系统会定期换，不登记的话下次开 App
   * 拿着旧地址连不上，只能重新配对——iOS 的 peripheral UUID 天生稳定，没有这一步。
   */
  private async persistDeviceId(deviceId: string): Promise<void> {
    try {
      if (access.isValidRandomDeviceId(deviceId)) {
        await access.addPersistentDeviceId(deviceId);
        this.append('BIND', '已登记车辆随机地址，重启后仍可直接连接', deviceId);
      }
    } catch (e) {
      // 登记不上不影响这次连接，但下次可能要重新配对，所以要留痕。
      this.append('ERROR', `登记车辆随机地址失败：${BLEVehicleController.messageOf(e as object)}`, '');
    }
  }

  private async updateBindingVerification(): Promise<void> {
    const binding = this.binding;
    if (binding === null) {
      return;
    }
    const next = binding.withConfiguration(binding.configuration, binding.syncState);
    if (next.protocolMinor !== this.negotiatedProtocolMinor() && next.syncState === BLEConfigurationSyncState.Synced) {
      next.syncState = BLEConfigurationSyncState.Pending;
    }
    next.protocolMinor = this.negotiatedProtocolMinor();
    next.lastVerifiedAt = Date.now();
    await this.bindingStore.save(next);
    this.binding = next;
  }

  // ---- 连接生命周期 ----

  private ensureManagedConnection(): void {
    const binding = this.binding;
    if (!this.productionEligible || binding === null || !binding.shouldMaintainConnection) {
      return;
    }
    if (this.pairingState.isBusy) {
      return;
    }
    if (this.bluetoothState !== BLEBluetoothState.PoweredOn) {
      this.runtimeState = BLERuntimeState.waitingForBluetooth;
      return;
    }
    if (this.client !== null && this.linkDeviceId === binding.deviceId) {
      if (this.linkState === BLELinkState.Ready && this.canAuthenticate
        && this.authenticationState !== BLEAuthenticationState.Authenticated) {
        this.authenticate(false);
      }
      return;
    }
    this.openLink(binding.deviceId, BLEConnectionIntent.Managed);
  }

  private stopManagedConnection(includeDiagnostic: boolean): void {
    this.cancelManagedRetry();
    if (!includeDiagnostic && this.connectionIntent === BLEConnectionIntent.Diagnostic) {
      // 诊断页自己连上的那条链路不归武装管，别把用户正在看的连接掐了。
      return;
    }
    if (this.client === null && this.linkRetryTimer === -1) {
      return;
    }
    this.closeClient();
    this.resetVolatileConnectionState();
  }

  private openLink(deviceId: string, intent: BLEConnectionIntent): void {
    this.closeClient();
    this.resetVolatileConnectionState();
    this.cancelManagedRetry();
    this.connectionIntent = intent;
    this.linkDeviceId = deviceId;
    this.connectionEpoch += 1;
    this.linkState = BLELinkState.Connecting;
    if (intent === BLEConnectionIntent.Managed) {
      this.runtimeState = BLERuntimeState.connecting;
    }
    this.append('CONNECT',
      `发起连接 ${BLEDiscoveredDevice.mask(deviceId)}`
        + ` 来源=${BLEVehicleController.intentLabel(intent)}`, deviceId);
    try {
      const client = ble.createGattClientDevice(deviceId);
      this.client = client;
      this.connectionListener = (state: ble.BLEConnectionChangeState): void => {
        this.handleConnectionChange(state);
      };
      client.on('BLEConnectionStateChange', this.connectionListener);
      this.characteristicListener = (value: ble.BLECharacteristic): void => {
        this.handleCharacteristicChange(value);
      };
      client.on('BLECharacteristicChange', this.characteristicListener);
      this.mtuListener = (mtu: number): void => {
        if (this.client !== client) {
          return;
        }
        this.negotiatedMtu = mtu;
        this.append('MTU', `协商 MTU=${mtu}`, '');
        const resolver = this.mtuResolver;
        if (resolver !== null) {
          this.mtuResolver = null;
          resolver(mtu);
        }
      };
      client.on('BLEMtuChange', this.mtuListener);
      client.connect();
    } catch (e) {
      this.failLink(`连接失败：${BLEVehicleController.messageOf(e as object)}`);
    }
  }

  private closeClient(): void {
    this.cancelLinkRetry();
    const client = this.client;
    this.client = null;
    if (client === null) {
      return;
    }
    if (this.connectionListener !== null) {
      try {
        client.off('BLEConnectionStateChange', this.connectionListener);
      } catch (e) {
        // 连接已经没了，解绑失败没有补救动作。
      }
      this.connectionListener = null;
    }
    if (this.characteristicListener !== null) {
      try {
        client.off('BLECharacteristicChange', this.characteristicListener);
      } catch (e) {
      }
      this.characteristicListener = null;
    }
    if (this.mtuListener !== null) {
      try {
        client.off('BLEMtuChange', this.mtuListener);
      } catch (e) {
      }
      this.mtuListener = null;
    }
    // 链路都没了，还挂着等 MTU 的话让它自己超时收场，别再往下唤醒。
    this.mtuResolver = null;
    // 句柄一关，所有还挂在这条链路上的异步（`getServices`、写入、订阅）都会被顶回来。
    // epoch 必须在这里作废：不然它们醒来时 `epoch !== connectionEpoch` 那道闸拦不住，
    // 会接着往下跑，把已经设好的正确状态覆盖掉。1.1.5 的日志里就是这样——
    // 断连先写了「与车辆的连接已断开」，4ms 后被 `getServices` 返回的空列表
    // 改写成「没读到这台设备的服务列表」，把排查方向带到了 FFFE 上。
    this.connectionEpoch += 1;
    try {
      client.disconnect();
    } catch (e) {
    }
    try {
      // `close` 不调的话底层的 GATT 句柄会一直占着，连上几次之后新连接直接失败。
      client.close();
    } catch (e) {
    }
  }

  private handleConnectionChange(state: ble.BLEConnectionChangeState): void {
    if (state.deviceId !== this.linkDeviceId) {
      return;
    }
    if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
      this.connectedDeviceId = state.deviceId;
      // 名字只有扫描结果里有（按地址直连时拿不到）。诊断日志靠它分辨连的是不是车。
      const scanned = this.devices.find(
        (item: BLEDiscoveredDevice) => item.deviceId === state.deviceId);
      this.connectedDeviceName = scanned === undefined ? '' : scanned.name;
      this.append('CONNECT', `已连接 ${BLEDiscoveredDevice.mask(state.deviceId)}`
        + ` 名称=${this.connectedDeviceName.length > 0 ? this.connectedDeviceName : '(无名)'}`, state.deviceId);
      this.lastConnectedDeviceId = state.deviceId;
      if (this.isScanning) {
        this.stopScan();
      }
      this.cancelPairingTimeout();
      this.prepareLink(this.connectionEpoch);
      return;
    }
    if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
      this.handleDisconnect(state.reason === undefined ? -1 : state.reason as number);
    }
  }

  private handleDisconnect(reason: number): void {
    this.append('CONNECT', `连接已断开${reason >= 0
      ? `（${BLEVehicleController.disconnectReasonLabel(reason)}）` : ''}`, '');
    const intent = this.connectionIntent;
    this.closeClient();
    this.resetVolatileConnectionState();
    if (intent === BLEConnectionIntent.Pairing && this.pairingState.isBusy) {
      this.cancelPairingTimeout();
      this.pairingState = BLEPairingState.failed('与车辆的连接已断开，请靠近车辆后重试');
      return;
    }
    const binding = this.binding;
    if (intent === BLEConnectionIntent.Managed && binding !== null && binding.shouldMaintainConnection) {
      this.runtimeState = BLERuntimeState.recovering;
      this.scheduleManagedRetry();
    }
  }

  /**
   * 断线重连。
   *
   * iOS 那边 `connect(peripheral:)` 会一直挂着等车出现，掉线不用自己管；
   * 鸿蒙的 `connect()` 是一次性的，失败就结束，所以这里得自己定期重试。
   */
  private scheduleManagedRetry(): void {
    this.cancelManagedRetry();
    this.managedRetryTimer = setTimeout((): void => {
      this.managedRetryTimer = -1;
      this.ensureManagedConnection();
    }, 5000);
  }

  private cancelManagedRetry(): void {
    if (this.managedRetryTimer !== -1) {
      clearTimeout(this.managedRetryTimer);
      this.managedRetryTimer = -1;
    }
  }

  /**
   * 释放 GATT 后的单次重连。
   *
   * 定时器必须归 controller 持有：用户在 400 ms 窗口里取消配对、切车或关蓝牙时，
   * 旧回调不能把已经取消的连接重新拉起来。
   */
  private scheduleLinkRetry(deviceId: string, intent: BLEConnectionIntent,
    skipMtu: boolean): void {
    this.cancelLinkRetry();
    const expectedEpoch = this.connectionEpoch;
    this.linkRetryTimer = setTimeout((): void => {
      this.linkRetryTimer = -1;
      if (expectedEpoch !== this.connectionEpoch
        || this.bluetoothState !== BLEBluetoothState.PoweredOn) {
        return;
      }
      if (intent === BLEConnectionIntent.Pairing && !this.pairingState.isBusy) {
        return;
      }
      if (intent === BLEConnectionIntent.Managed) {
        const binding = this.binding;
        if (!this.productionEligible || binding === null || !binding.shouldMaintainConnection) {
          return;
        }
      }
      if (intent === BLEConnectionIntent.Diagnostic
        && this.connectionIntent !== BLEConnectionIntent.Diagnostic) {
        return;
      }
      if (skipMtu) {
        this.skipMtuOnceDeviceId = deviceId;
      }
      this.openLink(deviceId, intent);
      if (intent === BLEConnectionIntent.Pairing) {
        this.schedulePairingConnectionTimeout(deviceId, this.connectionEpoch);
      }
    }, 400);
  }

  private cancelLinkRetry(): void {
    if (this.linkRetryTimer !== -1) {
      clearTimeout(this.linkRetryTimer);
      this.linkRetryTimer = -1;
    }
  }

  /**
   * 连上之后：找 FFFE/FFF2 → 协商 MTU → 订阅通知 → 认证。
   *
   * 服务发现必须排在 MTU 协商**前面**，这一点是照着 iOS 改的。iOS 那边
   * `didConnect` 里直接 `discoverServices([FFFE])`，全程不主动协商 MTU
   * （CoreBluetooth 也没给这个 API，系统自己在连接建立时做过一次），实车能用。
   * 鸿蒙原来抢在服务发现前又发了一次 ATT MTU Exchange——同一条连接上做两次
   * 是协议违规，车端可以直接断链。1.1.5 的车友日志正是这个形状：
   * 连上 0.5 秒 MTU 回 200，接着服务发现卡死 9.5 秒，然后 reason=2 车端主动断开。
   *
   * MTU 仍然要谈：分片大小取自 `negotiatedMtu`，不谈就退化到 20 字节一片，
   * 而鸿蒙没有「读当前 MTU」的 API。所以只是挪后，不是删掉。
   */
  private async prepareLink(epoch: number): Promise<void> {
    const client = this.client;
    if (client === null) {
      return;
    }
    const deviceId = this.linkDeviceId;
    const intent = this.connectionIntent;

    this.linkState = BLELinkState.Discovering;
    let services: Array<ble.GattService> | null;
    // 这一步会不会卡、卡多久，是「空服务列表」那类反馈唯一分得清因果的依据：
    // 几十毫秒回空 = 车端真没这些服务；卡满几秒才回空 = 是断连把它顶回来的。
    const discoveryStartedAt = Date.now();
    this.append('SERVICE', '开始服务发现', '');
    try {
      services = await BLEVehicleController.withTimeout(
        client.getServices(), BLEVehicleController.discoveryTimeout);
    } catch (e) {
      this.append('SERVICE', `服务发现抛错，耗时 ${Date.now() - discoveryStartedAt} ms`, '');
      this.failLink(`发现服务失败：${BLEVehicleController.messageOf(e as object)}`);
      return;
    }
    if (epoch !== this.connectionEpoch) {
      this.append('SERVICE',
        `服务发现返回时链路已作废，耗时 ${Date.now() - discoveryStartedAt} ms，`
          + `拿到 ${services === null ? '(超时)' : `${services.length}`} 个服务`
          + `——这一份不作数，断连的原因见上一条`, '');
      return;
    }
    if (services === null) {
      this.handleDiscoveryTimeout(deviceId, intent);
      return;
    }
    // 走到这里说明这条链路的服务发现是通的，兜底重连的额度还给它。
    this.discoveryRetriedDeviceId = '';

    const serviceIds: string[] = [];
    let targetServiceCharacteristics: string[] | null = null;
    let target: ble.BLECharacteristic | null = null;
    for (const service of services) {
      serviceIds.push(service.serviceUuid);
      const characteristicIds: string[] = [];
      for (const characteristic of service.characteristics) {
        characteristicIds.push(characteristic.characteristicUuid);
      }
      // 整张服务表逐条留痕：「没有 FFFE/FFF2」这类反馈，只有把车端实际暴露了什么
      // 摊开才查得动。归 SERVICE-MAP 是为了不占界面那 80 行、也不刷 hilog，但进导出。
      this.append('SERVICE-MAP',
        `${service.serviceUuid} → ${characteristicIds.length === 0
          ? '(无特征)' : characteristicIds.join(' ')}`, '');
      if (!BLEVehicleController.sameUUID(service.serviceUuid, LeapBLEProtocol.serviceUUID)) {
        continue;
      }
      targetServiceCharacteristics = characteristicIds;
      for (const characteristic of service.characteristics) {
        if (BLEVehicleController.sameUUID(characteristic.characteristicUuid,
          LeapBLEProtocol.characteristicUUID)) {
          target = characteristic;
        }
      }
      this.discoveredCharacteristicUUIDs = characteristicIds;
    }
    this.discoveredServiceUUIDs = serviceIds;
    this.append('SERVICE',
      `服务发现完成：${services.length} 个服务，FFFE=${targetServiceCharacteristics === null ? '无' : '有'}`
        + `，耗时 ${Date.now() - discoveryStartedAt} ms`,
      serviceIds.join(', '));

    if (target === null) {
      // 三种情况的下一步完全不同：空列表值得重连一次，缺 FFFE 多半是连错了设备，
      // 有 FFFE 缺 FFF2 才是协议层面的事。日志和给用户的文案都分开。
      if (services.length === 0) {
        this.append('ERROR',
          'GATT 回了空服务列表——服务发现没完成，或者拿到的是过期缓存', '');
        this.logDiscoveryContext();
        this.failLink('没读到这台设备的服务列表，请断开手机与车辆的蓝牙后重试');
        return;
      }
      if (targetServiceCharacteristics === null) {
        this.append('ERROR',
          `服务表里没有 FFFE。期望 ${LeapBLEProtocol.normalizeUUID(LeapBLEProtocol.serviceUUID)}，`
            + `实际 ${serviceIds.map((id: string) => LeapBLEProtocol.normalizeUUID(id)).join(' ')}`, '');
        this.logDiscoveryContext();
        this.failLink('这台设备没有蓝牙钥匙服务（FFFE），可能连到了别的蓝牙设备');
        return;
      }
      this.append('ERROR',
        `FFFE 服务在，但里面没有 FFF2。期望 `
          + `${LeapBLEProtocol.normalizeUUID(LeapBLEProtocol.characteristicUUID)}，实际 `
          + `${targetServiceCharacteristics.length === 0 ? '(无特征)'
            : targetServiceCharacteristics.map((id: string) => LeapBLEProtocol.normalizeUUID(id)).join(' ')}`, '');
      this.logDiscoveryContext();
      this.failLink('这台设备的蓝牙钥匙服务缺少 FFF2 特征');
      return;
    }
    this.characteristic = target;
    const properties = target.properties;
    // 优先带应答的写，没有才退到不带应答——和 iOS 同序（BLEDiagnosticManager 的
    // `.write` 在前、`.writeWithoutResponse` 在后）。鸿蒙原来是反的，
    // 同一个特征上两端会选相反的写法，而实车验证过能用的是 iOS 这一套。
    this.writeType = properties !== undefined && properties.write === true
      ? ble.GattWriteType.WRITE
      : (properties !== undefined && properties.writeNoResponse === true
        ? ble.GattWriteType.WRITE_NO_RESPONSE : ble.GattWriteType.WRITE);

    // MTU 挪到这里：服务发现已经落地，再谈就不会挡住它了。
    //
    // 这里必须**等协商结果**，不能发完请求就往下走。ATT 规定同一时刻只允许一个
    // 未完成的 request-response 事务，EXCHANGE_MTU 还在飞就发下一个请求，
    // 它会被丢在半空，一直挂到车端十秒握手窗口到期把连接掐掉。
    // 1.1.5 卡的是 `getServices`（9.5 秒），1.1.6 卡的是订阅（9.37 秒）——
    // 换的只是排在 MTU 后面的那个操作，位置从来没变。官方安卓同样是等到
    // EXCHANGE_MTU_RESPONSE（47 ms）之后才写 CCCD 的。
    //
    // 而 `setBLEMtuSize` 是**同步返回 void** 的，只负责把请求发出去；
    // 结果单独走 `BLEMtuChange` 事件。所以 await 它毫无意义，得自己挂钩子等事件。
    if (this.skipMtuOnceDeviceId === deviceId) {
      this.skipMtuOnceDeviceId = '';
      this.append('MTU', '上一轮 MTU 协商未完成，本轮跳过主动协商，按 mtu=23 继续', '');
    } else {
      const mtuStartedAt = Date.now();
      this.append('MTU', `请求 MTU ${BLEVehicleController.preferredMtu}，等协商结果`, '');
      let negotiated: number | null = null;
      let requestIssued = false;
      let resolver: ((value: number) => void) | null = null;
      try {
        const settled = new Promise<number>((resolve: (value: number) => void): void => {
          resolver = resolve;
          this.mtuResolver = resolver;
        });
        client.setBLEMtuSize(BLEVehicleController.preferredMtu);
        requestIssued = true;
        negotiated = await BLEVehicleController.withTimeout(settled, BLEVehicleController.mtuTimeout);
      } catch (e) {
        // 同步抛错表示请求没有进入 GATT 队列，可以安全地按默认 MTU 继续。
        this.append('MTU',
          `请求 MTU ${BLEVehicleController.preferredMtu} 失败：${BLEVehicleController.messageOf(e as object)}`, '');
      }
      // 旧连接的超时不能清掉用户随后发起的新连接正在等待的 resolver。
      if (this.mtuResolver === resolver) {
        this.mtuResolver = null;
      }
      if (epoch !== this.connectionEpoch) {
        this.append('MTU',
          `等 MTU 期间链路已作废，耗时 ${Date.now() - mtuStartedAt} ms——断连的原因见上一条`, '');
        return;
      }
      if (requestIssued && negotiated === null) {
        // 超时只代表 App 不再等，不代表底层 EXCHANGE_MTU 已经取消。继续写 CCCD
        // 会重新制造两个并发 GATT request；必须丢掉这条链路，下一轮直接跳过 MTU。
        this.append('MTU',
          `等协商结果超时（${BLEVehicleController.mtuTimeout} ms），关闭当前链路并重连一次`, '');
        this.closeClient();
        this.resetVolatileConnectionState();
        this.scheduleLinkRetry(deviceId, intent, true);
        return;
      }
      if (negotiated !== null) {
        this.append('MTU', `协商结果已到，等了 ${Date.now() - mtuStartedAt} ms`, '');
      }
    }

    this.append('SERVICE',
      `FFF2 就绪：write=${properties !== undefined && properties.write === true}`
        + ` writeNoResponse=${properties !== undefined && properties.writeNoResponse === true}`
        + ` notify=${properties !== undefined && properties.notify === true}`
        + ` indicate=${properties !== undefined && properties.indicate === true}`
        + ` 采用=${this.writeType === ble.GattWriteType.WRITE_NO_RESPONSE ? 'WRITE_NO_RESPONSE' : 'WRITE'}`
        + ` mtu=${this.negotiatedMtu}`, '');

    this.linkState = BLELinkState.Subscribing;
    const subscribeStartedAt = Date.now();
    this.append('NOTIFY', '开始订阅 FFF2 通知（写 CCCD）', '');
    try {
      await client.setCharacteristicChangeNotification(target, true);
    } catch (e) {
      this.append('NOTIFY', `订阅抛错，耗时 ${Date.now() - subscribeStartedAt} ms`, '');
      this.failLink(`订阅 FFF2 通知失败：${BLEVehicleController.messageOf(e as object)}`);
      return;
    }
    if (epoch !== this.connectionEpoch) {
      this.append('NOTIFY',
        `订阅返回时链路已作废，耗时 ${Date.now() - subscribeStartedAt} ms`
          + '——这一份不作数，断连的原因见上一条', '');
      return;
    }
    this.linkState = BLELinkState.Ready;
    this.append('NOTIFY', `已订阅 FFF2 通知，耗时 ${Date.now() - subscribeStartedAt} ms`, '');
    // 配对时手上不可能有这台车的 token，直接走完整认证，省掉一轮必然失败的重连。
    await this.authenticate(this.connectionIntent === BLEConnectionIntent.Pairing);
  }

  /**
   * 服务发现超时的兜底：主动断开重连一次。
   *
   * 第一次连上时车端的服务表还没进系统缓存，全量发现（鸿蒙的 `getServices()`
   * 没有 iOS 那种只发现 FFFE 的过滤版）要把每个服务每个特征都读一遍，
   * 信号一弱就可能拖到车端不耐烦。断开重连之后服务表通常已经在缓存里，秒回。
   *
   * 每台设备只兜底一次：真连不上的时候空转重连只会让用户等更久。
   */
  private handleDiscoveryTimeout(deviceId: string, intent: BLEConnectionIntent): void {
    const elapsed = BLEVehicleController.discoveryTimeout;
    if (this.discoveryRetriedDeviceId === deviceId) {
      this.append('SERVICE', `服务发现再次超时（${elapsed} ms），这台设备已经重连过一次，不再重试`, '');
      this.logDiscoveryContext();
      this.failLink('读取车辆的蓝牙服务超时，请靠近车辆后重试');
      return;
    }
    this.discoveryRetriedDeviceId = deviceId;
    this.append('SERVICE',
      `服务发现超时（${elapsed} ms），主动断开重连一次——服务表这时通常已进系统缓存`, '');
    this.closeClient();
    this.resetVolatileConnectionState();
    // 给底层一点时间把 GATT 句柄真正释放掉，紧接着重连会失败。
    this.scheduleLinkRetry(deviceId, intent, false);
  }

  /**
   * 服务发现没找到 FFFE/FFF2 时，把「我到底连上了谁」记下来。
   *
   * 这一步最常见的真相不是协议不对，而是连错了设备——车机的音频模块、
   * 上一次绑定留下的旧地址、甚至旁边另一台车。光看服务列表分辨不出来，
   * 得把连接对象、来源、广播里带的服务一起摆出来才有得比。
   */
  private logDiscoveryContext(): void {
    const deviceId = this.linkDeviceId;
    const binding = this.binding;
    this.append('SERVICE',
      `连接对象 ${BLEDiscoveredDevice.mask(deviceId)}`
        + ` 名称=${this.connectedDeviceName.length > 0 ? this.connectedDeviceName : '(无名)'}`
        + ` 来源=${BLEVehicleController.intentLabel(this.connectionIntent)}`
        + ` 绑定地址=${binding === null ? '(未绑定)' : BLEDiscoveredDevice.mask(binding.deviceId)}`
        + ` 车辆资料地址=${this.vehicleBluetoothAddress.length > 0
          ? BLEDiscoveredDevice.mask(this.vehicleBluetoothAddress) : '(无)'}`,
      deviceId);

    const advertised = this.devices.find(
      (item: BLEDiscoveredDevice) => item.deviceId === deviceId);
    if (advertised === undefined) {
      this.append('SERVICE', '这台设备不在本次扫描列表里（按已保存的地址直连）', '');
      return;
    }
    this.append('SERVICE',
      `广播资料 rssi=${advertised.rssi} connectable=${advertised.isConnectable}`
        + ` 带FFFE=${advertised.advertisesTargetService}`
        + ` 广播服务=${advertised.serviceUUIDs.length === 0 ? '(无)' : advertised.serviceUUIDs.join(' ')}`, '');
  }

  /**
   * `GattDisconnectReason` 的中文说法。
   *
   * 分得清「谁断的」这件事很要紧：车主动断（2）说明连接本身是通的、是车端不接受
   * 或者在等一个没等到的动作；链路超时（1）才是信号/距离的问题。
   * 光看裸码号做不出这个判断，所以直接落在日志里。
   */
  private static disconnectReasonLabel(reason: number): string {
    switch (reason) {
      case ble.GattDisconnectReason.CONN_TIMEOUT:
        return 'reason=1 链路超时，信号弱或离得太远';
      case ble.GattDisconnectReason.CONN_TERMINATE_PEER_USER:
        return 'reason=2 车端主动断开';
      case ble.GattDisconnectReason.CONN_TERMINATE_LOCAL_HOST:
        return 'reason=3 本机主动断开';
      case ble.GattDisconnectReason.CONN_UNKNOWN:
        return 'reason=4 原因不明';
      default:
        return `reason=${reason}`;
    }
  }

  private static intentLabel(intent: BLEConnectionIntent): string {
    switch (intent) {
      case BLEConnectionIntent.Pairing:
        return '配对扫描';
      case BLEConnectionIntent.Managed:
        return '绑定记录';
      default:
        return '手动连接';
    }
  }

  private failLink(message: string): void {
    this.append('ERROR', message, '');
    this.linkState = BLELinkState.Failed;
    const intent = this.connectionIntent;
    this.closeClient();
    this.resetVolatileConnectionState();
    if (intent === BLEConnectionIntent.Pairing) {
      this.cancelPairingTimeout();
      this.pairingState = BLEPairingState.failed(message);
      return;
    }
    if (intent === BLEConnectionIntent.Managed) {
      this.runtimeState = BLERuntimeState.needsAttention(message);
      this.scheduleManagedRetry();
    }
  }

  private resetVolatileConnectionState(): void {
    this.cancelResponseTimeout();
    this.cancelStraightMoveTimers();
    this.characteristic = null;
    this.cryptoSession = null;
    this.reassembler.reset();
    this.transmissionPurpose = null;
    this.transmissionInFlight = false;
    this.transmissionGeneration++;
    this.diagnosticAuthStarted = -1;
    this.diagnosticAuthSentParts = 0;
    this.diagnosticAuthAckedParts = 0;
    this.diagnosticAuthTotalParts = 0;
    this.pendingFullAuthenticationFallback = false;
    this.configurationInFlight = null;
    this.pendingStraightMoveOrder = null;
    this.connectedDeviceId = '';
    this.connectedDeviceName = '';
    this.discoveredServiceUUIDs = [];
    this.discoveredCharacteristicUUIDs = [];
    this.negotiatedMtu = 23;
    this.pendingControlLabel = '';
    this.linkState = BLELinkState.Idle;
    this.authenticationMode = null;
    this.authenticationState = this.credentialContext === null
      ? BLEAuthenticationState.MissingCertificate : BLEAuthenticationState.Prepared;
    if (this.straightMoveState.isPrepared) {
      this.straightMoveState = BLEStraightMoveState.failed('与车辆的连接已断开');
    }
  }

  // ---- 扫描 ----

  private startScanning(targetServiceOnly: boolean): boolean {
    try {
      this.scanListener = (results: Array<ble.ScanResult>): void => {
        for (const result of results) {
          this.handleScanResult(result);
        }
      };
      ble.on('BLEDeviceFind', this.scanListener);
      const filters: Array<ble.ScanFilter> = targetServiceOnly
        ? [{ serviceUuid: LeapBLEProtocol.serviceUUID.toLowerCase() } as ble.ScanFilter] : [];
      ble.startBLEScan(filters);
      this.isScanning = true;
      return true;
    } catch (e) {
      if (this.scanListener !== null) {
        try {
          ble.off('BLEDeviceFind', this.scanListener);
        } catch (inner) {
        }
        this.scanListener = null;
      }
      this.isScanning = false;
      this.append('ERROR', `开始扫描失败：${BLEVehicleController.messageOf(e as object)}`, '');
      return false;
    }
  }

  private handleScanResult(result: ble.ScanResult): void {
    const previous = this.devices.find((item: BLEDiscoveredDevice) => item.deviceId === result.deviceId);
    const serviceUUIDs = LeapBLEProtocol.mergingAdvertisedServices(previous?.serviceUUIDs ?? [], result.serviceUuids ?? []);
    const device = new BLEDiscoveredDevice(result.deviceId, result.deviceName, result.rssi,
      serviceUUIDs, result.connectable, Date.now());
    const next: BLEDiscoveredDevice[] = [];
    let replaced = false;
    for (const existing of this.devices) {
      if (existing.deviceId !== device.deviceId) {
        next.push(existing);
        continue;
      }
      replaced = true;
      // 只在有实际变化时才换对象，否则每秒几十次的广播会把整张列表刷成动画。
      const changed = existing.name !== device.name
        || existing.isConnectable !== device.isConnectable
        || existing.serviceUUIDs.join('|') !== device.serviceUUIDs.join('|')
        || Math.abs(existing.rssi - device.rssi) >= 5
        || device.lastSeen - existing.lastSeen >= 1000;
      next.push(changed ? device : existing);
    }
    if (!replaced) {
      next.push(device);
      this.append('DISCOVER',
        `发现 ${device.name.length > 0 ? device.name : '(无名)'} rssi=${device.rssi}`
          + ` connectable=${device.isConnectable} 带FFFE=${device.advertisesTargetService}`
          + ` 广播服务=${serviceUUIDs.length === 0 ? '(无)' : serviceUUIDs.join(' ')}`,
        device.deviceId);
    }
    // 广播里带 FFFE 的排前面，其次信号强的——用户看到的第一行就该是车。
    next.sort((lhs: BLEDiscoveredDevice, rhs: BLEDiscoveredDevice): number => {
      if (lhs.advertisesTargetService !== rhs.advertisesTargetService) {
        return lhs.advertisesTargetService ? -1 : 1;
      }
      return rhs.rssi - lhs.rssi;
    });
    this.devices = next;

    if (this.pairingState.kind === BLEPairingStateKind.Scanning && device.advertisesTargetService) {
      // 配对时不让用户从一堆随机地址里挑，扫到第一台带 FFFE 的直接连。
      this.pair(device.deviceId);
    }
  }

  private schedulePairingScanTimeout(): void {
    this.cancelPairingTimeout();
    this.pairingTimeoutTimer = setTimeout((): void => {
      this.pairingTimeoutTimer = -1;
      if (this.pairingState.kind !== BLEPairingStateKind.Scanning) {
        return;
      }
      this.stopScan();
      this.pairingState = BLEPairingState.failed('没有找到可配对的车辆，请靠近车辆后重试');
      this.runtimeState = this.binding === null ? BLERuntimeState.unbound : this.runtimeState;
    }, 12000);
  }

  private schedulePairingConnectionTimeout(deviceId: string, epoch: number): void {
    this.cancelPairingTimeout();
    this.pairingTimeoutTimer = setTimeout((): void => {
      this.pairingTimeoutTimer = -1;
      if (epoch !== this.connectionEpoch || !this.pairingState.isBusy) {
        return;
      }
      this.closeClient();
      this.resetVolatileConnectionState();
      this.pairingState = BLEPairingState.failed('连接车辆超时，请靠近车辆后重试');
    }, 12000);
  }

  private cancelPairingTimeout(): void {
    if (this.pairingTimeoutTimer !== -1) {
      clearTimeout(this.pairingTimeoutTimer);
      this.pairingTimeoutTimer = -1;
    }
  }

  // ---- 系统蓝牙状态 ----

  private refreshBluetoothState(): void {
    try {
      this.handleBluetoothStateChange(access.getState());
    } catch (e) {
      this.bluetoothState = BLEBluetoothState.Unsupported;
      this.append('ERROR', `读取系统蓝牙状态失败：${BLEVehicleController.messageOf(e as object)}`, '');
    }
  }

  private handleBluetoothStateChange(state: access.BluetoothState): void {
    const previous = this.bluetoothState;
    switch (state) {
      case access.BluetoothState.STATE_ON:
      case access.BluetoothState.STATE_BLE_ON:
        this.bluetoothState = BLEBluetoothState.PoweredOn;
        break;
      case access.BluetoothState.STATE_OFF:
        this.bluetoothState = BLEBluetoothState.PoweredOff;
        break;
      case access.BluetoothState.STATE_TURNING_ON:
      case access.BluetoothState.STATE_BLE_TURNING_ON:
      case access.BluetoothState.STATE_TURNING_OFF:
      case access.BluetoothState.STATE_BLE_TURNING_OFF:
        this.bluetoothState = BLEBluetoothState.Resetting;
        break;
      default:
        this.bluetoothState = BLEBluetoothState.Unknown;
        break;
    }
    if (this.bluetoothState === previous) {
      return;
    }
    this.append('SESSION', `系统蓝牙状态：${this.bluetoothState as string}`, '');
    if (this.bluetoothState === BLEBluetoothState.PoweredOn) {
      this.ensureManagedConnection();
      return;
    }
    this.isScanning = false;
    this.closeClient();
    this.resetVolatileConnectionState();
    if (this.pairingState.isBusy) {
      this.cancelPairingTimeout();
      this.pairingState = BLEPairingState.failed('系统蓝牙已关闭');
    }
    const binding = this.binding;
    if (binding !== null && binding.shouldMaintainConnection) {
      this.runtimeState = BLERuntimeState.waitingForBluetooth;
    }
  }

  // ---- 发送 ----

  /**
   * 把一整帧按 MTU 切片写出去。
   *
   * 鸿蒙的 `writeCharacteristicValue` 返回 Promise，顺序 `await` 天然就是背压，
   * 不需要 iOS 那套盯着 `canSendWriteWithoutResponse` 的喂片状态机。
   */
  private async beginTransmission(frame: Uint8Array, purpose: BLETransmissionPurpose): Promise<void> {
    const client = this.client;
    const characteristic = this.characteristic;
    if (client === null || characteristic === null) {
      throw new Error('蓝牙链路尚未就绪');
    }
    if (this.transmissionInFlight) {
      throw new Error('已有数据正在写入');
    }
    const generation = ++this.transmissionGeneration;
    const connection = this.connectionEpoch;
    this.transmissionPurpose = purpose;
    this.transmissionInFlight = true;
    const chunkSize = Math.max(20, Math.min(this.negotiatedMtu - 3,
      BLEVehicleController.maximumChunkSize));
    const total = Math.ceil(frame.length / chunkSize);
    if (purpose.kind === BLETransmissionKind.Authentication) { this.diagnosticAuthTotalParts = total; }
    this.append('TX-FRAME',
      `发送${purpose.label} ${frame.length} bytes，分 ${total} 片（每片 ${chunkSize}）`,
      BLEBuffer.hex(frame));

    try {
      for (let index = 0; index < total; index++) {
        if (this.transmissionGeneration !== generation || this.connectionEpoch !== connection
          || this.client !== client || this.transmissionPurpose !== purpose) { return; }
        const chunk = frame.slice(index * chunkSize, Math.min((index + 1) * chunkSize, frame.length));
        const payload: ble.BLECharacteristic = {
          serviceUuid: characteristic.serviceUuid,
          characteristicUuid: characteristic.characteristicUuid,
          characteristicValue: BLEBuffer.toArrayBuffer(chunk),
          descriptors: characteristic.descriptors
        };
        if (purpose.kind === BLETransmissionKind.Authentication) {
          this.diagnosticAuthSentParts = index + 1;
          this.append('AUTH-TX', `auth.tx.write ${this.authenticationTrace()} bytes=${chunk.length}`, '');
        }
        await client.writeCharacteristicValue(payload, this.writeType);
        if (this.transmissionGeneration !== generation || this.connectionEpoch !== connection
          || this.client !== client) {
          this.append('AUTH-TX', `tx.ack.ignored generation=${generation} reason=replacedConnectionOrTransmission`, '');
          return;
        }
        if (purpose.kind === BLETransmissionKind.Authentication) {
          this.diagnosticAuthAckedParts = index + 1;
          this.append('AUTH-TX', `auth.tx.ack ${this.authenticationTrace()} cancelled=${this.transmissionPurpose !== purpose}`, '');
        }
        if (this.transmissionPurpose !== purpose) { return; }
        if (index === 0 && purpose.kind === BLETransmissionKind.Control) {
          // 第一片一旦写出去，这条指令就可能已经到车了，之后再也不能回退 HTTP。
          const attempt = this.activeControlAttempt;
          if (attempt !== null && attempt.id === purpose.attemptId) {
            attempt.didStartWrite = true;
          }
        }
        this.append('TX-CHUNK', `第 ${index + 1}/${total} 片，${chunk.length} bytes`,
          BLEBuffer.hex(chunk));
      }
      this.completeTransmission();
    } catch (e) {
      if (this.transmissionGeneration === generation && this.connectionEpoch === connection
        && this.client === client && this.transmissionPurpose === purpose) {
        this.failTransmission(BLEVehicleController.messageOf(e as object));
      } else {
        this.append('AUTH-TX', `tx.error.ignored generation=${generation} reason=cancelledOrReplacedTransmission`, '');
      }
    } finally {
      // A late Promise from a closed connection must never unlock a newer transmission.
      if (this.transmissionGeneration === generation) { this.transmissionInFlight = false; }
    }
  }

  private completeTransmission(): void {
    const purpose = this.transmissionPurpose;
    this.transmissionInFlight = false;
    if (purpose === null) {
      return;
    }
    if (this.pendingFullAuthenticationFallback) {
      // 车在这一帧还没写完时就否掉了快速重连，等写完再补完整认证。
      this.pendingFullAuthenticationFallback = false;
      this.transmissionPurpose = null;
      this.performFullAuthenticationFallback();
      return;
    }
    if (purpose.kind === BLETransmissionKind.StraightMove) {
      this.transmissionPurpose = null;
      const queued = this.pendingStraightMoveOrder;
      if (queued !== null) {
        this.pendingStraightMoveOrder = null;
        this.sendStraightMove(queued);
      }
      return;
    }
    this.startResponseTimeout(purpose);
  }

  private failTransmission(message: string): void {
    const purpose = this.transmissionPurpose;
    this.transmissionInFlight = false;
    this.transmissionPurpose = null;
    this.cancelResponseTimeout();
    this.append('ERROR', `写入失败：${message}`, '');
    if (purpose === null) {
      return;
    }
    switch (purpose.kind) {
      case BLETransmissionKind.Authentication:
        this.failAuthentication(message);
        break;
      case BLETransmissionKind.Configuration:
        this.configurationInFlight = null;
        this.runtimeState = BLERuntimeState.needsAttention('蓝牙钥匙设置未能下发，请稍后重试');
        break;
      case BLETransmissionKind.Control:
        this.finishControlAttempt(purpose, BLEControlAttemptResult.failedAfterWrite(message));
        break;
      default:
        this.emergencyStopStraightMove('指令写入失败');
        break;
    }
  }

  /**
   * 响应超时。
   *
   * 直进直出没有超时——它靠 100 毫秒心跳和看门狗自己收敛，
   * 再挂一层超时只会在松手那一刻误报。
   */
  private startResponseTimeout(purpose: BLETransmissionPurpose): void {
    this.cancelResponseTimeout();
    let timeout = 0;
    switch (purpose.kind) {
      case BLETransmissionKind.Authentication:
        timeout = 10000;
        break;
      case BLETransmissionKind.Configuration:
        timeout = 8000;
        break;
      case BLETransmissionKind.Control:
        timeout = 8000;
        break;
      default:
        return;
    }
    this.responseTimeoutTimer = setTimeout((): void => {
      this.responseTimeoutTimer = -1;
      this.handleResponseTimeout(purpose);
    }, timeout);
  }

  private handleResponseTimeout(purpose: BLETransmissionPurpose): void {
    if (this.transmissionPurpose !== purpose) {
      return;
    }
    this.transmissionPurpose = null;
    this.append('ERROR', `${purpose.label}等待车辆应答超时`, '');
    switch (purpose.kind) {
      case BLETransmissionKind.Authentication:
        this.failAuthentication('等待车辆应答超时');
        break;
      case BLETransmissionKind.Configuration: {
        const sent = this.configurationInFlight;
        this.append('CONFIG', `configuration.timeout pending=true sent={${sent?.diagnosticSummary() ?? 'none'}}`, '');
        this.configurationInFlight = null;
        this.runtimeState = this.canControl ? BLERuntimeState.ready : BLERuntimeState.recovering;
        if (sent !== null && this.binding !== null && !this.binding.configuration.equals(sent)) {
          this.sendPendingConfigurationIfPossible();
        }
        break;
      }
      case BLETransmissionKind.Control:
        // 帧已经写出去了，车可能已经执行。这里绝不能报「失败」让上层去发 HTTP。
        this.pendingControlLabel = '';
        this.finishControlAttempt(purpose, BLEControlAttemptResult.sentWithoutConfirmation);
        break;
      default:
        break;
    }
  }

  private cancelResponseTimeout(): void {
    if (this.responseTimeoutTimer !== -1) {
      clearTimeout(this.responseTimeoutTimer);
      this.responseTimeoutTimer = -1;
    }
  }

  private finishControlAttempt(purpose: BLETransmissionPurpose, result: BLEControlAttemptResult): void {
    if (purpose.attemptId === 0) {
      return;
    }
    this.completedControlAttempt = new BLECompletedControlAttempt(purpose.attemptId, result);
  }

  // ---- 接收 ----

  private handleCharacteristicChange(value: ble.BLECharacteristic): void {
    const bytes = BLEBuffer.toBytes(value.characteristicValue);
    if (bytes.length === 0) {
      return;
    }
    this.append('RX-CHUNK', `收到 ${bytes.length} bytes`, BLEBuffer.hex(bytes));
    const frames = this.reassembler.append(bytes);
    if (frames.length === 0 && this.reassembler.bufferedByteCount > 0) {
      this.append('REASSEMBLY', `帧尚未收全，已缓存 ${this.reassembler.bufferedByteCount} bytes`, '');
    }
    for (const frame of frames) {
      this.handle(frame);
    }
  }

  private handle(frame: LeapBLEFrame): void {
    this.append('RX-FRAME',
      `${leapBLEFrameKindLabel(frame.kind)} 声明载荷 ${frame.declaredPayloadLength} bytes ${this.authenticationTrace()}`,
      frame.logDetail(true));

    if (frame.kind === LeapBLEFrameKind.Encrypted) {
      this.handleEncrypted(frame);
      return;
    }
    const event = frame.event;
    if (event === null) {
      return;
    }
    this.append('EVENT', event.summary, BLEBuffer.hex(event.payload));
    this.handleEvent(event);
  }

  private handleEncrypted(frame: LeapBLEFrame): void {
    const session = this.cryptoSession;
    if (session === null) {
      this.append('ERROR', '收到密文但本地没有会话密钥', '');
      return;
    }
    let plain: Uint8Array;
    try {
      plain = session.decrypt(frame);
    } catch (e) {
      this.append('ERROR', `解密失败：${BLEVehicleController.messageOf(e as object)}`, '');
      return;
    }
    const response = LeapBLEDecryptedResponse.parse(plain);
    if (response === null) {
      this.append('ERROR', '密文解出来不是可识别的应答', BLEBuffer.hex(plain));
      return;
    }
    switch (response.kind) {
      case LeapBLEResponseKind.Authentication:
        if (this.authenticationState !== BLEAuthenticationState.Authenticating) {
          this.append('AUTH', '忽略重复认证应答', '');
          break;
        }
        this.append('AUTH', `车辆认证通过，锁状态=${response.identifier}`, '');
        this.completeAuthentication();
        break;
      case LeapBLEResponseKind.ReconnectToken:
        this.saveReconnectToken(response.value);
        break;
      case LeapBLEResponseKind.Command:
        this.handleCommandResponse(response);
        break;
      default:
        this.append('RX-FRAME', `未解析应答 type=${response.identifier}`, '');
        break;
    }
  }

  private handleCommandResponse(response: LeapBLEDecryptedResponse): void {
    const succeeded = response.value.length === 0 || /^0+$/.test(response.value);
    this.append('CONTROL', `命令 ${response.identifier} 执行结果=${response.value}`, '');
    if (response.identifier === '3') {
      if (this.configurationInFlight === null) {
        this.append('CONFIG', '忽略重复或迟到的命令 3 应答', '');
        return;
      }
      this.cancelResponseTimeout();
      this.transmissionPurpose = null;
      this.completeConfigurationSync(LeapBLEProtocol.acceptsConfigurationResult(response.value), `结果码 ${response.value}`);
      return;
    }
    const purpose = this.transmissionPurpose;
    if (purpose !== null && purpose.kind === BLETransmissionKind.Control) {
      this.cancelResponseTimeout();
      this.transmissionPurpose = null;
      this.pendingControlLabel = '';
      if (succeeded) {
        this.lastConfirmedControlCommand = purpose.command;
        this.finishControlAttempt(purpose, BLEControlAttemptResult.confirmed);
      } else {
        this.finishControlAttempt(purpose,
          BLEControlAttemptResult.failedAfterWrite(`车辆返回结果码 ${response.value}`));
      }
    }
  }

  private handleEvent(event: LeapBLEEvent): void {
    if (event.kind === LeapBLEEventKind.ErrorResponse) {
      this.handleErrorResponse(event.resultCode);
      return;
    }
    if (event.kind !== LeapBLEEventKind.LockOperation) {
      return;
    }
    // 只认「主动触发」的解闭锁：被动上报的是别人开的门，不能拿来确认我这条指令。
    if (event.trigger.rawValue !== 1) {
      return;
    }
    const label = event.operation.label;
    if (this.pendingControlLabel.length === 0 || !label.includes(this.pendingControlLabel)) {
      return;
    }
    const purpose = this.transmissionPurpose;
    this.pendingControlLabel = '';
    if (purpose !== null && purpose.kind === BLETransmissionKind.Control) {
      this.cancelResponseTimeout();
      this.transmissionPurpose = null;
      this.lastConfirmedControlCommand = purpose.command;
      this.finishControlAttempt(purpose, BLEControlAttemptResult.confirmed);
    }
  }

  /**
   * 车端的错误应答。
   *
   * 3/4/7 都是「这个会话我不认」，token 一定已经废了。留着它下次还会再撞一次，
   * 且撞的时候用户正在按解锁——所以立刻作废，能补完整认证就当场补。
   */
  private handleErrorResponse(resultCode: number): void {
    const message = `车辆返回 resultCode=${resultCode}：${leapBLEAuthenticationResultDescription(resultCode)}`;
    const tokenInvalid = resultCode === 3 || resultCode === 4 || resultCode === 7;
    this.append('ERROR', `${message} ${this.authenticationTrace()}`, '');
    if (tokenInvalid) { this.invalidateReconnectToken(`车辆返回 resultCode=${resultCode}`); }
    if (this.authenticationState !== BLEAuthenticationState.Authenticating) { return; }
    if (!tokenInvalid || this.authenticationMode !== BLEAuthenticationMode.Reconnect) {
      this.failAuthentication(message);
      return;
    }
    if (this.transmissionInFlight) {
      // 还有分片在写，这时候插一帧完整认证会和它交错。等写完再补。
      this.pendingFullAuthenticationFallback = true;
      return;
    }
    this.performFullAuthenticationFallback();
  }

  private performFullAuthenticationFallback(): void {
    this.cancelResponseTimeout();
    this.transmissionPurpose = null;
    this.append('AUTH', '快速重连被拒，改用完整认证重试', '');
    this.authenticate(true);
  }

  // ---- 认证结果 ----

  private completeAuthentication(): void {
    // 鸿蒙/车端在同一连接里可能重复投递相同通知。状态先同步切到 Authenticated，
    // 避免第二条认证应答并发启动第二次异步绑定落盘。
    if (this.authenticationState !== BLEAuthenticationState.Authenticating) {
      return;
    }
    this.cancelResponseTimeout();
    this.transmissionPurpose = null;
    this.authenticationState = BLEAuthenticationState.Authenticated;
    this.authenticationError = '';
    this.lastSuccessfulAuthenticationMode = this.authenticationMode;
    if (this.connectionIntent === BLEConnectionIntent.Pairing) {
      this.completePairingIfNeeded();
      return;
    }
    if (this.connectionIntent === BLEConnectionIntent.Managed) {
      this.runtimeState = BLERuntimeState.ready;
      this.updateBindingVerification();
      this.sendPendingConfigurationIfPossible();
    }
  }

  private failAuthentication(message: string): void {
    this.append('AUTH-TX', `auth.tx.cancel ${this.authenticationTrace()} unsent=${Math.max(0, this.diagnosticAuthTotalParts - this.diagnosticAuthSentParts)} pendingWrite=${this.transmissionInFlight}`, '');
    this.pendingFullAuthenticationFallback = false;
    this.cancelResponseTimeout();
    this.transmissionPurpose = null;
    this.authenticationState = BLEAuthenticationState.Failed;
    this.authenticationError = message;
    this.append('ERROR', `认证失败：${message}`, '');
    if (this.connectionIntent === BLEConnectionIntent.Pairing) {
      this.cancelPairingTimeout();
      this.pairingState = BLEPairingState.failed(message);
      return;
    }
    if (this.connectionIntent === BLEConnectionIntent.Managed) {
      this.runtimeState = BLERuntimeState.needsAttention(message);
    }
  }

  private async saveReconnectToken(token: string): Promise<void> {
    const context = this.credentialContext;
    if (context === null) {
      return;
    }
    if (this.reconnectTokenAvailable && token === this.reconnectToken) {
      return;
    }
    try {
      LeapBLEProtocol.decodeReconnectToken(token);
    } catch (e) {
      this.append('ERROR', '车辆下发的快速重连凭证不是合法十六进制，已忽略', '');
      return;
    }
    this.reconnectToken = token;
    this.reconnectTokenAvailable = true;
    this.append('TOKEN', `已保存快速重连凭证（${token.length} 字符）`, token);
    await this.reconnectTokenStore.save(token, context.accountId, context.vin);
  }

  private async invalidateReconnectToken(reason: string): Promise<void> {
    this.reconnectToken = '';
    this.reconnectTokenAvailable = false;
    this.append('TOKEN', `快速重连凭证已作废：${reason}`, '');
    const context = this.credentialContext;
    if (context !== null) {
      await this.reconnectTokenStore.clear(context.accountId, context.vin);
    }
  }

  // ---- 日志 ----

  /**
   * 写一条诊断日志。
   *
   * `sensitiveDetail` 是密文和认证材料，只在「导出含敏感信息」时才出现；
   * 高频分类（分片、广播）只进导出缓冲，不占界面那 80 行，也不写系统日志——
   * 写了会把 hilog 刷爆，真正有用的那几条反而看不见。
   */
  private append(category: string, message: string, sensitiveDetail: string): void {
    const entry = new BLEDiagnosticLogEntry(Date.now(), category, message, sensitiveDetail);
    const exported = this.exportEntries.slice();
    exported.push(entry);
    if (exported.length > BLEVehicleController.maximumExportLogEntries) {
      exported.splice(0, exported.length - BLEVehicleController.maximumExportLogEntries);
    }
    this.exportEntries = exported;

    if (BLEVehicleController.exportOnlyCategories.includes(category)) {
      return;
    }
    const visible = this.entries.slice();
    visible.push(entry);
    if (visible.length > BLEVehicleController.maximumVisibleLogEntries) {
      visible.splice(0, visible.length - BLEVehicleController.maximumVisibleLogEntries);
    }
    this.entries = visible;
    DiagLog.note(`[ble:${category}] ${message}`);
  }

  // ---- 工具 ----

  private static sleep(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, milliseconds);
    });
  }

  /**
   * 给一个没有取消能力的 Promise 加超时。超时 resolve 成 null，原异常照旧抛出。
   *
   * `getServices()` 一旦发出去就收不回来，只能不再等它——所以超时之后必须
   * 把整条链路关掉（`closeClient` 会作废 epoch），否则它稍后返回时会接着往下跑。
   */
  private static withTimeout<T>(promise: Promise<T>, milliseconds: number): Promise<T | null> {
    return new Promise<T | null>(
      (resolve: (value: T | null) => void, reject: (reason: Object) => void): void => {
        let settled = false;
        const timer = setTimeout((): void => {
          if (settled) {
            return;
          }
          settled = true;
          resolve(null);
        }, milliseconds);
        promise.then((value: T): void => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          resolve(value);
        }).catch((error: Object): void => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          reject(error);
        });
      });
  }

  private static messageOf(e: object | string | null | undefined): string {
    return LeapError.messageOf(e);
  }

  /**
   * 鸿蒙回的 UUID 大小写和长度都不固定：可能是小写短格式 `fffe`，
   * 也可能是补全的 128 位。归一化统一放在协议层，广播判定走的是同一份。
   */
  private static sameUUID(lhs: string, rhs: string): boolean {
    return LeapBLEProtocol.sameUUID(lhs, rhs);
  }

  private static isDecodableToken(token: string): boolean {
    try {
      LeapBLEProtocol.decodeReconnectToken(token);
      return true;
    } catch (e) {
      return false;
    }
  }
}
