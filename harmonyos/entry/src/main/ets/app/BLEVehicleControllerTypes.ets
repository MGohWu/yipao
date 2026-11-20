import { LeapBytes, LeapBLEProtocol, LeapBLEControlCommand, leapBLEControlCommandLabel,
  StraightMoveDirection, straightMoveDirectionLabel } from '../core/BLEProtocol';

/**
 * 蓝牙钥匙运行时用到的值类型。
 *
 * 从控制器里拆出来只有一个原因：iOS 那边这些是带关联值的 enum
 * （`case needsAttention(String)`、`case moving(StraightMoveDirection)`），
 * ArkTS 的 enum 只能是常量，一律要拆成「kind 枚举 + 携带字段的类」两截写。
 * 拆出来的代码量和控制器本体差不多，混在一个文件里翻起来太痛苦。
 *
 * 一律做成不可变类 + 静态工厂：这些值会挂在 `@Trace` 字段上，
 * 就地改字段的话 V2 追踪不到嵌套属性的变化，界面不会刷新。
 */

/** 系统蓝牙开关状态。文案逐字对齐 iOS 的 `BluetoothState`。 */
export enum BLEBluetoothState {
  Unknown = '未知',
  Resetting = '正在重置',
  Unsupported = '不支持',
  Unauthorized = '未授权',
  PoweredOff = '已关闭',
  PoweredOn = '已开启'
}

/** GATT 链路状态。文案逐字对齐 iOS 的 `LinkState`。 */
export enum BLELinkState {
  Idle = '未连接',
  Connecting = '连接中',
  Discovering = '发现服务中',
  Subscribing = '订阅通知中',
  Ready = '已订阅',
  Disconnecting = '断开中',
  Failed = '失败'
}

/** 认证状态。文案逐字对齐 iOS 的 `AuthenticationState`。 */
export enum BLEAuthenticationState {
  MissingCertificate = '未同步证书',
  Prepared = '待认证',
  Authenticating = '认证中',
  Authenticated = '已认证',
  Failed = '认证失败'
}

/** 认证方式。 */
export enum BLEAuthenticationMode {
  Full = '完整认证',
  Reconnect = '快速重连'
}

// ---- 运行时状态 ----

export enum BLERuntimeStateKind {
  Disabled,
  Unbound,
  WaitingForBluetooth,
  Scanning,
  Connecting,
  Authenticating,
  SyncingConfiguration,
  Ready,
  Recovering,
  NeedsAttention
}

/** 首页和蓝牙钥匙页共用的一句话状态。 */
export class BLERuntimeState {
  readonly kind: BLERuntimeStateKind;
  /** 只有 `NeedsAttention` 用得上，其余为空串。 */
  readonly detail: string;

  private constructor(kind: BLERuntimeStateKind, detail: string) {
    this.kind = kind;
    this.detail = detail;
  }

  static readonly disabled: BLERuntimeState = new BLERuntimeState(BLERuntimeStateKind.Disabled, '');
  static readonly unbound: BLERuntimeState = new BLERuntimeState(BLERuntimeStateKind.Unbound, '');
  static readonly waitingForBluetooth: BLERuntimeState =
    new BLERuntimeState(BLERuntimeStateKind.WaitingForBluetooth, '');
  static readonly scanning: BLERuntimeState = new BLERuntimeState(BLERuntimeStateKind.Scanning, '');
  static readonly connecting: BLERuntimeState = new BLERuntimeState(BLERuntimeStateKind.Connecting, '');
  static readonly authenticating: BLERuntimeState =
    new BLERuntimeState(BLERuntimeStateKind.Authenticating, '');
  static readonly syncingConfiguration: BLERuntimeState =
    new BLERuntimeState(BLERuntimeStateKind.SyncingConfiguration, '');
  static readonly ready: BLERuntimeState = new BLERuntimeState(BLERuntimeStateKind.Ready, '');
  static readonly recovering: BLERuntimeState = new BLERuntimeState(BLERuntimeStateKind.Recovering, '');

  static needsAttention(message: string): BLERuntimeState {
    return new BLERuntimeState(BLERuntimeStateKind.NeedsAttention, message);
  }

  get label(): string {
    switch (this.kind) {
      case BLERuntimeStateKind.Disabled:
        return '已关闭';
      case BLERuntimeStateKind.Unbound:
        return '尚未绑定';
      case BLERuntimeStateKind.WaitingForBluetooth:
        return '等待系统蓝牙';
      case BLERuntimeStateKind.Scanning:
        return '正在搜索车辆';
      case BLERuntimeStateKind.Connecting:
        return '正在连接车辆';
      case BLERuntimeStateKind.Authenticating:
        return '正在认证车辆';
      case BLERuntimeStateKind.SyncingConfiguration:
        return '正在同步设置';
      case BLERuntimeStateKind.Ready:
        return '蓝牙钥匙可用';
      case BLERuntimeStateKind.Recovering:
        return '正在等待车辆';
      default:
        return this.detail.length > 0 ? this.detail : '需要处理';
    }
  }

  equals(other: BLERuntimeState): boolean {
    return this.kind === other.kind && this.detail === other.detail;
  }
}

// ---- 配对状态 ----

export enum BLEPairingStateKind {
  Idle,
  Preparing,
  Scanning,
  Connecting,
  Authenticating,
  Bound,
  Failed
}

/** 配对向导的进度。`deviceId` 只有连接/认证两步用得上。 */
export class BLEPairingState {
  readonly kind: BLEPairingStateKind;
  readonly deviceId: string;
  readonly message: string;

  private constructor(kind: BLEPairingStateKind, deviceId: string, message: string) {
    this.kind = kind;
    this.deviceId = deviceId;
    this.message = message;
  }

  static readonly idle: BLEPairingState = new BLEPairingState(BLEPairingStateKind.Idle, '', '');
  static readonly preparing: BLEPairingState = new BLEPairingState(BLEPairingStateKind.Preparing, '', '');
  static readonly scanning: BLEPairingState = new BLEPairingState(BLEPairingStateKind.Scanning, '', '');
  static readonly bound: BLEPairingState = new BLEPairingState(BLEPairingStateKind.Bound, '', '');

  static connecting(deviceId: string): BLEPairingState {
    return new BLEPairingState(BLEPairingStateKind.Connecting, deviceId, '');
  }

  static authenticating(deviceId: string): BLEPairingState {
    return new BLEPairingState(BLEPairingStateKind.Authenticating, deviceId, '');
  }

  static failed(message: string): BLEPairingState {
    return new BLEPairingState(BLEPairingStateKind.Failed, '', message);
  }

  get isBusy(): boolean {
    return this.kind === BLEPairingStateKind.Preparing || this.kind === BLEPairingStateKind.Scanning
      || this.kind === BLEPairingStateKind.Connecting
      || this.kind === BLEPairingStateKind.Authenticating;
  }

  equals(other: BLEPairingState): boolean {
    return this.kind === other.kind && this.deviceId === other.deviceId
      && this.message === other.message;
  }
}

// ---- 控制结果 ----

export enum BLEControlAttemptResultKind {
  /** 车辆事件确认动作已完成。 */
  Confirmed,
  /** 帧已写完，但没等到车辆确认。 */
  SentWithoutConfirmation,
  /** 控制帧第一个字节都没写出去，调用方可以安全回退 HTTP。 */
  UnavailableBeforeWrite,
  /** 已经写出去了才失败——车可能已经动了，不能再补一次 HTTP。 */
  FailedAfterWrite
}

export class BLEControlAttemptResult {
  readonly kind: BLEControlAttemptResultKind;
  readonly message: string;

  private constructor(kind: BLEControlAttemptResultKind, message: string) {
    this.kind = kind;
    this.message = message;
  }

  static readonly confirmed: BLEControlAttemptResult =
    new BLEControlAttemptResult(BLEControlAttemptResultKind.Confirmed, '');
  static readonly sentWithoutConfirmation: BLEControlAttemptResult =
    new BLEControlAttemptResult(BLEControlAttemptResultKind.SentWithoutConfirmation, '');

  static unavailableBeforeWrite(message: string): BLEControlAttemptResult {
    return new BLEControlAttemptResult(BLEControlAttemptResultKind.UnavailableBeforeWrite, message);
  }

  static failedAfterWrite(message: string): BLEControlAttemptResult {
    return new BLEControlAttemptResult(BLEControlAttemptResultKind.FailedAfterWrite, message);
  }

  /**
   * 只有「写之前就不可用」才允许回退 HTTP。
   *
   * 写出去之后再回退，等于同一个动作可能被执行两次——蓝牙那次车已经动了，
   * HTTP 那次再来一遍。锁车还好，解锁就是把刚锁上的车又打开。
   */
  get shouldFallbackToHTTP(): boolean {
    return this.kind === BLEControlAttemptResultKind.UnavailableBeforeWrite;
  }
}

// ---- 直进直出 ----

export enum BLEStraightMoveStateKind {
  Idle,
  Preparing,
  Ready,
  Moving,
  Paused,
  Failed
}

export class BLEStraightMoveState {
  readonly kind: BLEStraightMoveStateKind;
  readonly direction: StraightMoveDirection;
  readonly message: string;

  private constructor(kind: BLEStraightMoveStateKind, direction: StraightMoveDirection, message: string) {
    this.kind = kind;
    this.direction = direction;
    this.message = message;
  }

  static readonly idle: BLEStraightMoveState =
    new BLEStraightMoveState(BLEStraightMoveStateKind.Idle, StraightMoveDirection.Forward, '');
  static readonly preparing: BLEStraightMoveState =
    new BLEStraightMoveState(BLEStraightMoveStateKind.Preparing, StraightMoveDirection.Forward, '');
  static readonly ready: BLEStraightMoveState =
    new BLEStraightMoveState(BLEStraightMoveStateKind.Ready, StraightMoveDirection.Forward, '');
  static readonly paused: BLEStraightMoveState =
    new BLEStraightMoveState(BLEStraightMoveStateKind.Paused, StraightMoveDirection.Forward, '');

  static moving(direction: StraightMoveDirection): BLEStraightMoveState {
    return new BLEStraightMoveState(BLEStraightMoveStateKind.Moving, direction, '');
  }

  static failed(message: string): BLEStraightMoveState {
    return new BLEStraightMoveState(BLEStraightMoveStateKind.Failed, StraightMoveDirection.Forward, message);
  }

  /** 已经进入可控阶段。断连、认证失效这些异常只在这个阶段才需要急停。 */
  get isPrepared(): boolean {
    return this.kind === BLEStraightMoveStateKind.Ready
      || this.kind === BLEStraightMoveStateKind.Moving
      || this.kind === BLEStraightMoveStateKind.Paused;
  }

  get isMoving(): boolean {
    return this.kind === BLEStraightMoveStateKind.Moving;
  }

  get label(): string {
    switch (this.kind) {
      case BLEStraightMoveStateKind.Idle:
        return '未开始';
      case BLEStraightMoveStateKind.Preparing:
        return '正在准备';
      case BLEStraightMoveStateKind.Ready:
        return '已就绪';
      case BLEStraightMoveStateKind.Moving:
        return straightMoveDirectionLabel(this.direction);
      case BLEStraightMoveStateKind.Paused:
        return '已暂停';
      default:
        return this.message.length > 0 ? this.message : '已停止';
    }
  }

  equals(other: BLEStraightMoveState): boolean {
    return this.kind === other.kind && this.direction === other.direction
      && this.message === other.message;
  }
}

// ---- 扫描结果与日志 ----

/** 一台扫到的 BLE 设备。 */
export class BLEDiscoveredDevice {
  readonly deviceId: string;
  readonly name: string;
  readonly rssi: number;
  readonly serviceUUIDs: string[];
  readonly isConnectable: boolean;
  /** 毫秒时间戳。 */
  readonly lastSeen: number;

  constructor(deviceId: string, name: string, rssi: number, serviceUUIDs: string[],
    isConnectable: boolean, lastSeen: number) {
    this.deviceId = deviceId;
    this.name = name;
    this.rssi = rssi;
    this.serviceUUIDs = serviceUUIDs;
    this.isConnectable = isConnectable;
    this.lastSeen = lastSeen;
  }

  /** 广播里带着目标服务的排在前面——那才是车。 */
  get advertisesTargetService(): boolean {
    for (const uuid of this.serviceUUIDs) {
      if (LeapBLEProtocol.sameUUID(uuid, LeapBLEProtocol.serviceUUID)) {
        return true;
      }
    }
    return false;
  }

  /** 界面上只显示后半截地址。设备地址是可以长期跟踪一个人的标识，截图会外流。 */
  get maskedIdentifier(): string {
    return BLEDiscoveredDevice.mask(this.deviceId);
  }

  static mask(deviceId: string): string {
    const parts = deviceId.split(':');
    if (parts.length === 6) {
      return `**:**:**:**:${parts[4]}:${parts[5]}`;
    }
    return deviceId.length > 8 ? `...${deviceId.substring(deviceId.length - 8)}` : '***';
  }
}

/**
 * 一条诊断日志。
 *
 * `sensitiveDetail` 是认证材料和密文，只在用户主动「导出完整日志」时才拼进去；
 * 屏幕上和系统日志里永远只有 `message`。
 */
export class BLEDiagnosticLogEntry {
  readonly timestamp: number;
  readonly category: string;
  readonly message: string;
  readonly sensitiveDetail: string;

  constructor(timestamp: number, category: string, message: string, sensitiveDetail: string) {
    this.timestamp = timestamp;
    this.category = category;
    this.message = message;
    this.sensitiveDetail = sensitiveDetail;
  }

  /** 屏幕上显示的时刻，只到秒。 */
  get clockText(): string {
    const date = new Date(this.timestamp);
    const hour = BLEDiagnosticLogEntry.pad(date.getHours());
    const minute = BLEDiagnosticLogEntry.pad(date.getMinutes());
    const second = BLEDiagnosticLogEntry.pad(date.getSeconds());
    return `${hour}:${minute}:${second}`;
  }

  text(includingSensitive: boolean): string {
    const stamp = new Date(this.timestamp).toISOString();
    const head = `${stamp} [${this.category}] ${this.message}`;
    if (includingSensitive && this.sensitiveDetail.length > 0) {
      return `${head} | ${this.sensitiveDetail}`;
    }
    return head;
  }

  private static pad(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }
}

// ---- 内部记账 ----

/** 一次首页控车的在途记录。`didStartWrite` 决定失败后还能不能回退 HTTP。 */
export class BLEControlAttempt {
  readonly id: number;
  didStartWrite: boolean;

  constructor(id: number) {
    this.id = id;
    this.didStartWrite = false;
  }
}

export class BLECompletedControlAttempt {
  readonly id: number;
  readonly result: BLEControlAttemptResult;

  constructor(id: number, result: BLEControlAttemptResult) {
    this.id = id;
    this.result = result;
  }
}

export enum BLETransmissionKind {
  Authentication,
  Configuration,
  Control,
  StraightMove
}

/** 正在写出去的这一帧是干什么的。响应超时和写失败的分流全看它。 */
export class BLETransmissionPurpose {
  readonly kind: BLETransmissionKind;
  readonly mode: BLEAuthenticationMode;
  readonly command: LeapBLEControlCommand;
  /** 只有首页控车（`performControl`）才有，诊断页手动发的是 null。 */
  readonly attemptId: number;

  private constructor(kind: BLETransmissionKind, mode: BLEAuthenticationMode,
    command: LeapBLEControlCommand, attemptId: number) {
    this.kind = kind;
    this.mode = mode;
    this.command = command;
    this.attemptId = attemptId;
  }

  static authentication(mode: BLEAuthenticationMode): BLETransmissionPurpose {
    return new BLETransmissionPurpose(BLETransmissionKind.Authentication, mode,
      LeapBLEControlCommand.Unlock, 0);
  }

  static readonly configuration: BLETransmissionPurpose =
    new BLETransmissionPurpose(BLETransmissionKind.Configuration, BLEAuthenticationMode.Full,
      LeapBLEControlCommand.Unlock, 0);

  static control(command: LeapBLEControlCommand, attemptId: number): BLETransmissionPurpose {
    return new BLETransmissionPurpose(BLETransmissionKind.Control, BLEAuthenticationMode.Full,
      command, attemptId);
  }

  static readonly straightMove: BLETransmissionPurpose =
    new BLETransmissionPurpose(BLETransmissionKind.StraightMove, BLEAuthenticationMode.Full,
      LeapBLEControlCommand.Unlock, 0);

  get label(): string {
    switch (this.kind) {
      case BLETransmissionKind.Authentication:
        return this.mode as string;
      case BLETransmissionKind.Configuration:
        return '蓝牙钥匙设置';
      case BLETransmissionKind.Control:
        return leapBLEControlCommandLabel(this.command);
      default:
        return '直进直出';
    }
  }
}

/** ArrayBuffer ↔ Uint8Array。鸿蒙 GATT 的读写都收发 ArrayBuffer，协议层只认 Uint8Array。 */
export class BLEBuffer {
  static toBytes(buffer: ArrayBuffer): Uint8Array {
    return new Uint8Array(buffer);
  }

  /**
   * 复制一份再取 `buffer`。
   *
   * 协议层大量用 `slice()` 切出视图，直接拿 `bytes.buffer` 会连底下整块内存一起交出去，
   * 车端收到的就是整帧而不是这一片。
   */
  static toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    const copy = new Uint8Array(bytes.length);
    copy.set(bytes);
    return copy.buffer as ArrayBuffer;
  }

  static hex(bytes: Uint8Array): string {
    return LeapBytes.hexString(bytes);
  }
}
