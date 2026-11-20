import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { LeapBLEError } from './LeapBLEError';
import { LeapGMCrypto } from './LeapGMCrypto';
import { bytesToBigInt, concatBytes, EllipticCurve } from './EllipticCurve';
import { JsonValue } from './JsonValue';

/**
 * 零跑蓝牙钥匙协议里已经由实车抓包确认的常量与帧结构。
 *
 * 与 iOS `Core/BLEProtocol.swift` 一一对应，帧的每一个字节都按那边的顺序拼。
 * 这一层不碰 GATT，也不碰界面：进来的是证书和命令，出去的是字节。
 * 好处是它能在 Node 上原样跑起来对拍固定向量（`scripts/ble-selftest.mjs`），
 * 而真机上出问题时，能先把「帧拼错了」从嫌疑里排掉。
 */
export class LeapBLEProtocol {
  static acceptsConfigurationResult(result: string): boolean { return result === '0' || result === '00'; }

  static advertisedProtocolMinor(serviceUUIDs: string[]): number | undefined {
    for (const uuid of serviceUUIDs) {
      const normalized = LeapBLEProtocol.normalizeUUID(uuid);
      if (/^000001[0-9a-f]{2}-0000-1000-8000-00805f9b34fb$/.test(normalized)) {
        return parseInt(normalized.substring(6, 8), 16);
      }
    }
    return undefined;
  }

  static protocolMinor(serviceUUIDs: string[], fallback: number = 8): number {
    return LeapBLEProtocol.advertisedProtocolMinor(serviceUUIDs)
      ?? (Number.isInteger(fallback) && fallback >= 0 && fallback <= 255 ? fallback : 8);
  }

  static cloudProtocolMinor(response: JsonValue): number | undefined {
    const list = response.get('data')?.get('list')?.arrayValue;
    if (list === null || list === undefined || list.length !== 1) { return undefined; }
    const info = list[0].get('bluetoothInfo')?.stringValue ?? '';
    const token = info.split(',').pop()?.trim() ?? '';
    if (token.length === 0 || token.length > 128 || !/^[0-9]+(\.[0-9]+)*$/.test(token)) { return undefined; }
    const parts = token.split('.').map((part: string) => Number(part));
    if (parts.some((part: number) => !Number.isSafeInteger(part)) || parts[0] < 1 || parts[0] > 255) { return undefined; }
    const minor = parts.length > 1 ? parts[1] : 0;
    return parts[0] > 1 || minor >= 9 ? 9 : minor;
  }

  static resolvedProtocolMinor(cloud: number | undefined, services: string[], verified: number | undefined): number | undefined {
    if (cloud !== undefined && cloud >= 0 && cloud <= 255) { return cloud; }
    const advertised = LeapBLEProtocol.advertisedProtocolMinor(services);
    if (advertised !== undefined) { return advertised; }
    return verified !== undefined && verified >= 0 && verified <= 255 ? verified : undefined;
  }

  // A scan response need not repeat services from the preceding advertisement.
  static mergingAdvertisedServices(previous: string[], incoming: string[]): string[] {
    const hasVersion = LeapBLEProtocol.advertisedProtocolMinor(incoming) !== undefined;
    const merged: string[] = [];
    for (const uuid of previous) {
      if (!hasVersion || LeapBLEProtocol.advertisedProtocolMinor([uuid]) === undefined) {
        const value = LeapBLEProtocol.normalizeUUID(uuid);
        if (!merged.includes(value)) { merged.push(value); }
      }
    }
    for (const uuid of incoming) {
      const value = LeapBLEProtocol.normalizeUUID(uuid);
      if (!merged.includes(value)) { merged.push(value); }
    }
    return merged.sort();
  }

  static readonly serviceUUID = '0000FFFE-0000-1000-8000-00805F9B34FB';
  static readonly characteristicUUID = '0000FFF2-0000-1000-8000-00805F9B34FB';

  /** `passwordCard` 按 16 个 5 字节切片取值，服务端材料必须覆盖完整范围。 */
  static readonly minimumPasswordCardByteCount = 80;

  /** 防止损坏的长度字段让重组器无限等待或吃掉过多内存。 */
  static readonly maximumFrameLength = 1048576;

  /**
   * 归一化 GATT UUID：一律补成 128 位小写。
   *
   * 鸿蒙 BLE 栈回的 UUID 可能是 16 位短格式（`fffe`），也可能是补全的 128 位，
   * 大小写还不固定，直接比字符串会把同一个服务认成两个。
   * iOS 那边 `CBUUID` 自带这套归一化，所以没有对应代码。
   */
  static normalizeUUID(uuid: string): string {
    let lower = uuid.trim().toLowerCase();
    if (lower.startsWith('0x')) {
      lower = lower.substring(2);
    }
    if (lower.length === 4) {
      return `0000${lower}-0000-1000-8000-00805f9b34fb`;
    }
    if (lower.length === 8) {
      return `${lower}-0000-1000-8000-00805f9b34fb`;
    }
    return lower;
  }

  /** 比较两个 GATT UUID，短格式与 128 位视为同一个。 */
  static sameUUID(lhs: string, rhs: string): boolean {
    return LeapBLEProtocol.normalizeUUID(lhs) === LeapBLEProtocol.normalizeUUID(rhs);
  }

  /** 官方目前有两条可用的蓝牙证书密码路径；其它值必须在认证前拒绝。 */
  static supportsKeyType(keyType: number): boolean {
    return keyType === 0 || keyType === 1;
  }

  static decodeReconnectToken(token: string): Uint8Array {
    if (token.length === 0 || token.length % 2 !== 0 || token.length > 1024) {
      throw LeapBLEError.invalidFrame('重连 token 不是有效的偶数长度 Hex');
    }
    const out = new Uint8Array(token.length / 2);
    for (let index = 0; index < out.length; index++) {
      const high = LeapBLEProtocol.hexDigit(token.charAt(index * 2));
      const low = LeapBLEProtocol.hexDigit(token.charAt(index * 2 + 1));
      if (high < 0 || low < 0) {
        throw LeapBLEError.invalidFrame('重连 token 包含非 Hex 字符');
      }
      out[index] = (high << 4) | low;
    }
    return out;
  }

  private static hexDigit(character: string): number {
    const value = '0123456789abcdef'.indexOf(character.toLowerCase());
    return value;
  }
}

// ---- 字节工具 ----

/**
 * 帧里所有多字节整数都是小端。
 *
 * 单独收成一个类而不是散着写移位，是因为 iOS 那边靠 `appendLittleEndian` 泛型统一，
 * 这边一旦某处手写反了字节序，症状是车辆静默不响应，比报错难查得多。
 */
export class LeapBytes {
  static littleEndian16(value: number): Uint8Array {
    return new Uint8Array([value & 0xff, (value >> 8) & 0xff]);
  }

  static littleEndian32(value: number): Uint8Array {
    return new Uint8Array([
      value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff
    ]);
  }

  /**
   * 时间戳是 8 字节，超出 32 位安全范围，走 bigint。
   *
   * 入参收 number 也收 bigint：实际用的是 Unix 秒，落在 double 的安全整数内；
   * 但协议固定向量里出现过高位有值的 8 字节（`0x0102030405060708`），
   * 那种数 double 存不下，末位会被抹平，只有 bigint 传得进来。
   */
  static littleEndian64(value: number | bigint): Uint8Array {
    const out = new Uint8Array(8);
    let remaining: bigint = 0n;
    if (typeof value === 'bigint') {
      remaining = value as bigint;
    } else {
      remaining = BigInt(Math.trunc(value as number));
    }
    for (let index = 0; index < 8; index++) {
      out[index] = Number(remaining & 0xffn);
      remaining >>= 8n;
    }
    return out;
  }

  static readLittleEndian32(bytes: Uint8Array, offset: number): number {
    return bytes[offset]
      | (bytes[offset + 1] << 8)
      | (bytes[offset + 2] << 16)
      | (bytes[offset + 3] << 24);
  }

  /** 十六进制大写，和 iOS 的 `hexString` 一致，日志里两端能直接对。 */
  static hexString(bytes: Uint8Array): string {
    let out = '';
    for (let index = 0; index < bytes.length; index++) {
      const value = bytes[index];
      out += '0123456789ABCDEF'.charAt((value >> 4) & 0x0f) + '0123456789ABCDEF'.charAt(value & 0x0f);
    }
    return out;
  }

  static utf8(text: string): Uint8Array {
    return new util.TextEncoder('utf-8').encodeInto(text);
  }

  static base64Bytes(data: Uint8Array): Uint8Array {
    return LeapBytes.utf8(new util.Base64Helper().encodeToStringSync(data));
  }

  static decodeUTF8(data: Uint8Array): string {
    return util.TextDecoder.create('utf-8').decodeToString(data);
  }

  /** 当前 Unix 秒。协议里全是秒，毫秒传进去会被车端判成过期。 */
  static currentTimestamp(): number {
    return Math.floor(Date.now() / 1000);
  }
}

// ---- 证书 ----

/** `syncBluetoothKeys` 返回的每车蓝牙钥匙证书。字段都属于认证材料，必须放关键资产。 */
export class LeapBLEKeyCertificate {
  readonly ecdhPublicKey: string;
  readonly keyType: number;
  readonly passwordCard: string;
  readonly plainText: string;
  readonly signResult: string;
  readonly vin: string;

  constructor(ecdhPublicKey: string, keyType: number, passwordCard: string,
    plainText: string, signResult: string, vin: string) {
    this.ecdhPublicKey = ecdhPublicKey;
    this.keyType = keyType;
    this.passwordCard = passwordCard;
    this.plainText = plainText;
    this.signResult = signResult;
    this.vin = vin;
  }

  static fromJson(json: JsonValue, expectedVin: string = ''): LeapBLEKeyCertificate | null {
    const isCertificateNode: (dict: Map<string, JsonValue>) => boolean = (dict: Map<string, JsonValue>) => {
      return dict.has('ecdhPublicKey') && dict.has('passwordCard')
        && dict.has('plainText') && dict.has('signResult')
        && (expectedVin.length === 0 || dict.get('vin')?.stringValue === expectedVin);
    };

    // 官方 DTO 同时返回 bluetoothKey/mobileControl；BLE 认证只能用前者。
    const bluetoothKey = json.path('data', 'bluetoothKey') ?? json.get('bluetoothKey');
    const node = bluetoothKey !== null
      ? bluetoothKey.firstObject(isCertificateNode)
      : json.firstObject(isCertificateNode);
    if (node === null) {
      return null;
    }

    const ecdhPublicKey = LeapBLEKeyCertificate.stringOf(node, 'ecdhPublicKey');
    const passwordCard = LeapBLEKeyCertificate.stringOf(node, 'passwordCard');
    const plainText = LeapBLEKeyCertificate.stringOf(node, 'plainText');
    const signResult = LeapBLEKeyCertificate.stringOf(node, 'signResult');
    if (ecdhPublicKey === null || passwordCard === null || plainText === null || signResult === null) {
      return null;
    }
    // 老接口曾省略 keyType；缺省时按官方老款路径处理，显式的未知值仍由会话创建拒绝。
    const keyTypeValue = node.get('keyType');
    const keyType = keyTypeValue !== undefined ? (keyTypeValue.intValue ?? 0) : 0;
    const vin = LeapBLEKeyCertificate.stringOf(node, 'vin') ?? '';
    return new LeapBLEKeyCertificate(ecdhPublicKey, keyType, passwordCard, plainText, signResult, vin);
  }

  private static stringOf(node: Map<string, JsonValue>, key: string): string | null {
    const value = node.get(key);
    return value !== undefined ? value.stringValue : null;
  }

  /** 日志和界面上用来指认「换过证书没有」，不泄露材料本身。 */
  get fingerprint(): string {
    const digest = LeapBLECryptoSession.sha256(LeapBytes.utf8('ios-1.22.66|' + this.ecdhPublicKey + this.signResult + this.passwordCard + this.plainText));
    return LeapBytes.hexString(digest.slice(0, 6)).toLowerCase();
  }

  get isSupportedKeyType(): boolean {
    return LeapBLEProtocol.supportsKeyType(this.keyType);
  }

  /** 官方 Java 按字符切片，当前协议要求这些字符是一字节 ASCII。 */
  get hasValidPasswordCard(): boolean {
    if (this.passwordCard.length < LeapBLEProtocol.minimumPasswordCardByteCount) {
      return false;
    }
    for (let index = 0; index < this.passwordCard.length; index++) {
      if (this.passwordCard.charCodeAt(index) > 0x7f) {
        return false;
      }
    }
    return true;
  }

  validatePasswordCard(): void {
    if (!this.hasValidPasswordCard) {
      throw LeapBLEError.invalidCertificate('passwordCard 必须是至少 80 字节的 ASCII 字符串');
    }
  }
}

/**
 * 一次认证要用到的全套凭据。
 *
 * 单独立一个类而不是把四个参数一路往下传：证书、账号、设备号、VIN 必须同批取用，
 * 拆开传过一次就会出现「证书是这辆车的、accountId 是上一个账号的」这种组合，
 * 而车端只会回一个 resultCode，根本看不出是哪一项对不上。
 */
export class LeapBLECredentialContext {
  readonly certificate: LeapBLEKeyCertificate;
  readonly accountId: string;
  readonly deviceId: string;
  readonly vin: string;

  constructor(certificate: LeapBLEKeyCertificate, accountId: string, deviceId: string, vin: string) {
    this.certificate = certificate;
    this.accountId = accountId;
    this.deviceId = deviceId;
    this.vin = vin;
  }

  matches(other: LeapBLECredentialContext | null): boolean {
    if (other === null) {
      return false;
    }
    return this.accountId === other.accountId && this.vin === other.vin
      && this.deviceId === other.deviceId
      && this.certificate.fingerprint === other.certificate.fingerprint;
  }
}

// ---- 命令 ----

export enum LeapBLEControlCommand {
  Unlock = 1,
  Lock = 2
}

export function leapBLEControlCommandLabel(command: LeapBLEControlCommand): string {
  return command === LeapBLEControlCommand.Unlock ? '解锁' : '闭锁';
}

export enum StraightMoveDirection {
  Forward = 1,
  Backward = 2
}

export enum StraightMoveOrder {
  Forward = 1,
  Backward = 2,
  Stop = 3
}

export function straightMoveDirectionLabel(direction: StraightMoveDirection): string {
  return direction === StraightMoveDirection.Forward ? '向前' : '向后';
}

export function straightMoveOrderLabel(order: StraightMoveOrder): string {
  if (order === StraightMoveOrder.Forward) {
    return '直进';
  }
  return order === StraightMoveOrder.Backward ? '直出' : '停止挪车';
}

export function straightMoveOrderOf(direction: StraightMoveDirection): StraightMoveOrder {
  return direction === StraightMoveDirection.Forward ? StraightMoveOrder.Forward : StraightMoveOrder.Backward;
}

// ---- 无感钥匙配置 ----

/**
 * 官方 1.9 重连明文里的 9 字节蓝牙钥匙配置。
 *
 * 无感解锁的判距是车端做的：手机只把这几个标定值写进车里，
 * 之后维持连接就行。所以这个结构一改，车的行为就变——不是本机开关。
 */
export enum BLEUnlockDistance {
  Standard = 0,
  Near = 4,
  Far = 7
}

export class LeapBLEConfiguration {
  readonly distanceCalibration: number;
  readonly coefficientHundredths: number;
  readonly unlockCalibration: number;
  readonly lockCalibration: number;
  readonly isEnabled: boolean;
  readonly autoLockEnabled: boolean;
  readonly autoUnlockEnabled: boolean;
  readonly supportsButton: boolean;
  readonly distanceSelection: number;
  readonly defaultUnlockCalibration: number;
  readonly multipleAnchors: boolean;

  constructor(distanceCalibration: number, coefficientHundredths: number, unlockCalibration: number,
    lockCalibration: number, isEnabled: boolean, autoLockEnabled: boolean,
    autoUnlockEnabled: boolean, supportsButton: boolean,
    distanceSelection: number = -1, defaultUnlockCalibration: number = -1, multipleAnchors: boolean = false) {
    this.multipleAnchors = multipleAnchors;
    this.distanceCalibration = distanceCalibration;
    this.coefficientHundredths = coefficientHundredths;
    this.unlockCalibration = unlockCalibration;
    this.lockCalibration = lockCalibration;
    this.isEnabled = isEnabled;
    this.autoLockEnabled = autoLockEnabled;
    this.autoUnlockEnabled = autoUnlockEnabled;
    this.supportsButton = supportsButton;
    this.distanceSelection = distanceSelection;
    this.defaultUnlockCalibration = defaultUnlockCalibration;
  }

  static readonly officialDefault: LeapBLEConfiguration =
    new LeapBLEConfiguration(56, 200, 8, 16, true, false, true, true);

  /** 首次只绑定蓝牙控车时使用。车辆仍接受手动指令，但不会自动解锁或闭锁。 */
  static readonly manualControl: LeapBLEConfiguration =
    new LeapBLEConfiguration(56, 200, 8, 16, true, false, false, true);

  /**
   * 逐字段比较。
   *
   * iOS 那边 `LeapBLEConfiguration` 是 `Equatable` 的 struct，`==` 直接可用；
   * ArkTS 里它是类，`===` 只比引用，而「发送期间用户又改了设置」这条分支
   * （见 `completeConfigurationSync`）恰恰要比的是值。
   */
  equals(other: LeapBLEConfiguration): boolean {
    return this.distanceCalibration === other.distanceCalibration
      && this.coefficientHundredths === other.coefficientHundredths
      && this.unlockCalibration === other.unlockCalibration
      && this.lockCalibration === other.lockCalibration
      && this.isEnabled === other.isEnabled
      && this.autoLockEnabled === other.autoLockEnabled
      && this.autoUnlockEnabled === other.autoUnlockEnabled
      && this.supportsButton === other.supportsButton
      && this.distanceSelection === other.distanceSelection
      && this.defaultUnlockCalibration === other.defaultUnlockCalibration
      && this.multipleAnchors === other.multipleAnchors;
  }

  /** 换一组开关，标定原样保留。 */
  withSwitches(isEnabled: boolean, autoLockEnabled: boolean,
    autoUnlockEnabled: boolean): LeapBLEConfiguration {
    return new LeapBLEConfiguration(this.distanceCalibration, this.coefficientHundredths,
      this.unlockCalibration, this.lockCalibration, isEnabled, autoLockEnabled,
      autoUnlockEnabled, this.supportsButton, this.distanceSelection, this.defaultUnlockCalibration, this.multipleAnchors);
  }

  /** 把无感解锁开关翻过来，其余标定原样保留。 */
  withPassiveUnlock(enabled: boolean): LeapBLEConfiguration {
    return new LeapBLEConfiguration(this.distanceCalibration, this.coefficientHundredths,
      this.unlockCalibration, this.lockCalibration, this.isEnabled, this.autoLockEnabled,
      enabled, this.supportsButton, this.distanceSelection, this.defaultUnlockCalibration, this.multipleAnchors);
  }

  get unlockDistance(): BLEUnlockDistance {
    return this.distanceSelection === 4 ? BLEUnlockDistance.Near
      : (this.distanceSelection === 7 ? BLEUnlockDistance.Far : BLEUnlockDistance.Standard);
  }

  withUnlockDistance(distance: BLEUnlockDistance): LeapBLEConfiguration {
    const baseline = this.defaultUnlockCalibration >= 0 ? this.defaultUnlockCalibration : this.unlockCalibration;
    return new LeapBLEConfiguration(this.distanceCalibration, this.coefficientHundredths,
      distance === BLEUnlockDistance.Standard ? baseline : distance, this.lockCalibration,
      this.isEnabled, this.autoLockEnabled, this.autoUnlockEnabled, this.supportsButton, distance, baseline, this.multipleAnchors);
  }

  diagnosticSummary(minor: number = -1): string {
    const summary = `distance=${this.unlockDistance} calibration=${this.calibrationText} baseline=${this.defaultUnlockCalibration} anchors=${this.multipleAnchors} enabled=${this.isEnabled} autoUnlock=${this.autoUnlockEnabled} autoLock=${this.autoLockEnabled} button=${this.supportsButton}`;
    return minor < 0 ? summary : `${summary} profile=${minor} wire=${Array.from(this.wireBytes(minor)).map((b: number) => b.toString(16).padStart(2, '0')).join('')}`;
  }

  get calibrationText(): string {
    const coefficient = (this.coefficientHundredths / 100).toFixed(2);
    const unlock = this.unlockCalibration < 10 ? `0${this.unlockCalibration}` : `${this.unlockCalibration}`;
    const lock = this.lockCalibration < 10 ? `0${this.lockCalibration}` : `${this.lockCalibration}`;
    return `${this.distanceCalibration};${coefficient};${unlock};${lock}`;
  }

  get bytes(): Uint8Array { return this.wireBytes(9); }

  wireBytes(protocolMinor: number): Uint8Array {
    const result = concatBytes([
      new Uint8Array([this.distanceCalibration]),
      LeapBytes.littleEndian16(this.coefficientHundredths),
      new Uint8Array([
        this.unlockCalibration,
        this.lockCalibration,
        (protocolMinor >= 9 ? this.isEnabled : this.isEnabled && this.autoUnlockEnabled) ? 1 : 0,
        this.isEnabled && this.autoLockEnabled ? 1 : 0
      ])
    ]);
    return protocolMinor >= 9 ? concatBytes([result, new Uint8Array([
      this.isEnabled && this.autoUnlockEnabled ? 1 : 0, this.isEnabled && this.supportsButton ? 1 : 0])]) : result;
  }
}

// ---- 解密后的应答 ----

export enum LeapBLEResponseKind {
  Authentication,
  ReconnectToken,
  Command,
  Other
}

/** `AA AB` 解密后的分号文本。官方解析器至少要求类型和一个数据字段。 */
export class LeapBLEDecryptedResponse {
  readonly kind: LeapBLEResponseKind;
  /** Authentication 的锁状态 / Command 的命令号 / Other 的类型号。 */
  readonly identifier: string;
  /** ReconnectToken 的 token / Command 的执行结果，其余为空。 */
  readonly value: string;
  readonly remainingFields: string[];

  private constructor(kind: LeapBLEResponseKind, identifier: string, value: string, remainingFields: string[]) {
    this.kind = kind;
    this.identifier = identifier;
    this.value = value;
    this.remainingFields = remainingFields;
  }

  static parse(data: Uint8Array): LeapBLEDecryptedResponse | null {
    if (data.length === 0) {
      return null;
    }
    const text = LeapBytes.decodeUTF8(data);
    if (text.length === 0) {
      return null;
    }
    const fields = text.split(';');
    if (fields.length < 2) {
      return null;
    }
    if (fields[0] === '0') {
      if (fields[1].length === 0) {
        return null;
      }
      return new LeapBLEDecryptedResponse(LeapBLEResponseKind.Authentication,
        fields[1], '', fields.slice(2));
    }
    if (fields[0] === '1') {
      try {
        LeapBLEProtocol.decodeReconnectToken(fields[1]);
      } catch (e) {
        return null;
      }
      return new LeapBLEDecryptedResponse(LeapBLEResponseKind.ReconnectToken, '', fields[1], []);
    }
    if (fields[0] === '2') {
      // 实车回包格式是 `2;<结果码>;<命令号>`，例如配置成功为 `2;00;3`。
      // 旧实现沿用了 iOS 变量名的错误语义，把 `00` 当成命令号，导致车已经确认
      // 配置后仍等满 8 秒报超时。
      return new LeapBLEDecryptedResponse(LeapBLEResponseKind.Command,
        fields.length > 2 ? fields[2] : '', fields[1], fields.length > 3 ? fields.slice(3) : []);
    }
    return new LeapBLEDecryptedResponse(LeapBLEResponseKind.Other, fields[0], '', fields.slice(1));
  }
}

// ---- 会话 ----

enum SessionCipher {
  Aes,
  Sm4
}

/** 一次 GATT 连接内使用的会话密钥。临时私钥完成协商后立即丢弃，只保留 key/iv。 */
export class LeapBLECryptoSession {
  readonly sessionID: number;
  readonly publicKey: Uint8Array;
  private readonly key: Uint8Array;
  private readonly iv: Uint8Array;
  private readonly cipher: SessionCipher;

  private constructor(sessionID: number, publicKey: Uint8Array,
    key: Uint8Array, iv: Uint8Array, cipher: SessionCipher) {
    this.sessionID = sessionID;
    this.publicKey = publicKey;
    this.key = key;
    this.iv = iv;
    this.cipher = cipher;
  }

  /**
   * 按证书类型完成协商，导出这次连接的 key/iv。
   *
   * keyType=0 走 P-256 ECDH + AES-CBC + SHA256，keyType=1 走 SM2 KAP + SM4-CBC + SM3。
   * 两条路的后半段完全一样：拿会话号和倒过来的 VIN 求摘要，用摘要首字节的高四位
   * 从 passwordCard 上挑一段 5 字节，接上协商密钥再求一次摘要，
   * 摘要的十六进制文本前 16 个字符当 key、后 16 个当 iv——是文本不是字节，这里不能「优化」。
   */
  static make(certificate: LeapBLEKeyCertificate, vin: string,
    requestedSessionID: number = -1, privateKeyRaw: Uint8Array | null = null,
    smPeerPublicKeyX963: Uint8Array | null = null): LeapBLECryptoSession {
    if (certificate.vin.length > 0 && certificate.vin !== vin) {
      throw LeapBLEError.invalidCertificate('证书 VIN 与当前车辆不一致');
    }
    certificate.validatePasswordCard();
    if (!LeapBLEProtocol.supportsKeyType(certificate.keyType)) { throw LeapBLEError.unsupportedKeyType(certificate.keyType); }

    let publicKey: Uint8Array;
    let sharedSecret: Uint8Array;
    let cipher: SessionCipher;
    if (certificate.keyType === 0) {
      const peerBytes = LeapGMCrypto.base64ToBytes(certificate.ecdhPublicKey);
      const peer = EllipticCurve.p256.decodeX963(peerBytes);
      if (peer === null) {
        throw LeapBLEError.invalidCertificate('ECDH 公钥不是 65 字节 P-256 公钥');
      }
      const privateBytes = privateKeyRaw !== null
        ? privateKeyRaw
        : LeapGMCrypto.generatePrivateKey(EllipticCurve.p256);
      const scalar = bytesToBigInt(privateBytes);
      if (privateBytes.length !== 32 || !EllipticCurve.p256.isValidPrivateKey(scalar)) {
        throw LeapBLEError.cryptoFailure('临时 P-256 私钥无效');
      }
      const selfPublic = EllipticCurve.p256.multiplyBase(scalar);
      const shared = EllipticCurve.p256.multiply(scalar, peer);
      if (selfPublic === null || shared === null) {
        throw LeapBLEError.cryptoFailure('P-256 ECDH 协商失败');
      }
      publicKey = EllipticCurve.p256.encodeX963(selfPublic);
      // X9.63 的共享密钥就是协商点的 x 坐标，和 CryptoKit 的 `SharedSecret` 一致。
      sharedSecret = EllipticCurve.p256.encodeX963(shared).slice(1, 33);
      cipher = SessionCipher.Aes;
    } else if (certificate.keyType === 1) {
      const agreement = LeapGMCrypto.sm2KAP(certificate.ecdhPublicKey, privateKeyRaw, smPeerPublicKeyX963);
      publicKey = agreement.publicKey;
      sharedSecret = agreement.sharedKey;
      cipher = SessionCipher.Sm4;
    } else {
      throw LeapBLEError.unsupportedKeyType(certificate.keyType);
    }

    const sessionID = requestedSessionID >= 0
      ? requestedSessionID
      : LeapBytes.readLittleEndian32(cryptoFramework.createRandom().generateRandomSync(4).data, 0);
    const indexMaterial = concatBytes([
      LeapBytes.littleEndian32(sessionID),
      LeapBytes.utf8(LeapBLECryptoSession.reversed(vin))
    ]);
    const usesSM = certificate.keyType === 1;
    const indexDigest = usesSM ? LeapGMCrypto.sm3(indexMaterial) : LeapBLECryptoSession.sha256(indexMaterial);
    const start = (indexDigest[0] >> 4) * 5;
    const passwordBytes = LeapBytes.utf8(certificate.passwordCard);

    const keyMaterial = concatBytes([passwordBytes.slice(start, start + 5), sharedSecret]);
    const digest = usesSM ? LeapGMCrypto.sm3(keyMaterial) : LeapBLECryptoSession.sha256(keyMaterial);
    const digestHex = LeapBytes.hexString(digest).toLowerCase();
    return new LeapBLECryptoSession(
      sessionID,
      publicKey,
      LeapBytes.utf8(digestHex.substring(0, 16)),
      LeapBytes.utf8(digestHex.substring(digestHex.length - 16)),
      cipher
    );
  }

  private static reversed(text: string): string {
    let out = '';
    for (let index = text.length - 1; index >= 0; index--) {
      out += text.charAt(index);
    }
    return out;
  }

  private get usesSM(): boolean {
    return this.cipher === SessionCipher.Sm4;
  }

  /** 官方 1.9 协议的完整认证帧（`AA AE`）。 */
  fullAuthenticationFrame(certificate: LeapBLEKeyCertificate, accountId: string, deviceId: string,
    timestamp: number | bigint = LeapBytes.currentTimestamp(),
    configuration: LeapBLEConfiguration = LeapBLEConfiguration.officialDefault, protocolMinor: number = 9): Uint8Array {
    const certificateFields = certificate.plainText.split(';');
    if (certificateFields.length < 6) {
      throw LeapBLEError.invalidCertificate('plainText 字段不足 6 项');
    }
    if (accountId.length === 0 || deviceId.length === 0
      || accountId.indexOf(';') >= 0 || deviceId.indexOf(';') >= 0) {
      throw LeapBLEError.invalidCertificate('账号或设备标识为空/含分隔符');
    }
    const signature = LeapGMCrypto.base64ToBytes(certificate.signResult);
    if (signature.length === 0) {
      throw LeapBLEError.invalidCertificate('signResult 不是有效 Base64');
    }

    // 官方 iOS 1.22.66 保留完整证书明文，并按车辆协议版本附加开关。
    const authFields = [
      `${timestamp}`, certificateFields.map((value: string, index: number) =>
        index === 1 ? accountId : (index === 2 ? deviceId : value)).join(';'),
      configuration.calibrationText,
      (protocolMinor >= 9 ? configuration.isEnabled : configuration.isEnabled && configuration.autoUnlockEnabled) ? '1' : '0',
      configuration.isEnabled && configuration.autoLockEnabled ? '1' : '0',
    ];
    if (protocolMinor >= 9) {
      authFields.push(configuration.isEnabled && configuration.autoUnlockEnabled ? '1' : '0');
      authFields.push(configuration.isEnabled && configuration.supportsButton ? '1' : '0');
    }
    const authText = authFields.concat(['']).join(';');
    const authTextData = LeapBytes.utf8(authText);
    const plain = concatBytes([LeapBytes.littleEndian32(authTextData.length), authTextData, signature]);

    const payload = concatBytes([
      LeapBytes.littleEndian32(this.sessionID),
      this.publicKey,
      LeapBytes.base64Bytes(this.encrypt(plain)),
      new Uint8Array([0x01, 0x09])
    ]);
    if (payload.length > 0xffff) {
      throw LeapBLEError.invalidFrame('认证载荷过长');
    }
    return concatBytes([
      new Uint8Array([0xAA, LeapBLEFrameKind.FullAuthentication]),
      LeapBytes.littleEndian16(payload.length),
      payload
    ]);
  }

  /** 官方 1.9 token 快速重连帧（`AA EE`）。 */
  reconnectAuthenticationFrame(token: string, accountId: string,
    configuration: LeapBLEConfiguration = LeapBLEConfiguration.officialDefault,
    timestamp: number | bigint = LeapBytes.currentTimestamp(), pre17: boolean = false,
    protocolMinor: number = 9): Uint8Array {
    const tokenData = LeapBLEProtocol.decodeReconnectToken(token);
    const accountData = LeapBytes.utf8(accountId);
    if (accountData.length === 0 || accountData.length > 0xffff) {
      throw LeapBLEError.invalidCertificate('账号为空或长度超过 UInt16');
    }
    const plain = concatBytes([
      LeapBytes.littleEndian64(timestamp),
      tokenData,
      configuration.wireBytes(protocolMinor),
      LeapBytes.littleEndian16(accountData.length),
      accountData
    ]);
    return LeapBLECryptoSession.reconnectFrame(
      this.sessionID, this.publicKey, LeapBytes.base64Bytes(this.encrypt(plain)), this.usesSM, pre17);
  }

  /** 独立保留组帧步骤，便于直接对照官方 App 的运行时固定向量。 */
  static reconnectFrame(sessionID: number, publicKey: Uint8Array,
    encodedCipher: Uint8Array, usesSM: boolean, pre17: boolean = false): Uint8Array {
    if (publicKey.length !== 65 || publicKey[0] !== 0x04) {
      throw LeapBLEError.invalidFrame('重连公钥不是 65 字节未压缩公钥');
    }
    if (encodedCipher.length === 0) {
      throw LeapBLEError.invalidFrame('重连密文为空');
    }
    if (pre17) {
      if (4 + publicKey.length + encodedCipher.length > 0xffff) { throw LeapBLEError.invalidFrame('重连载荷过长'); }
      return concatBytes([new Uint8Array([0xAA, LeapBLEFrameKind.ReconnectAuthentication]),
        LeapBytes.littleEndian16(4 + publicKey.length + encodedCipher.length),
        LeapBytes.littleEndian32(sessionID), publicKey, encodedCipher]);
    }
    const payloadLength = 4 + publicKey.length + encodedCipher.length + 2 + 16;
    if (payloadLength > 0xffff) {
      throw LeapBLEError.invalidFrame('重连载荷过长');
    }
    const head = concatBytes([
      new Uint8Array([0xAA, LeapBLEFrameKind.ReconnectAuthentication]),
      LeapBytes.littleEndian16(payloadLength),
      LeapBytes.littleEndian32(sessionID),
      publicKey,
      encodedCipher,
      new Uint8Array([0x01, 0x09])
    ]);
    const digest = usesSM ? LeapGMCrypto.sm3(head) : LeapBLECryptoSession.sha256(head);
    if (digest.length < 16) {
      throw LeapBLEError.cryptoFailure('重连摘要不足 16 字节');
    }
    return concatBytes([head, digest.slice(0, 16)]);
  }

  controlFrame(command: LeapBLEControlCommand,
    timestamp: number | bigint = LeapBytes.currentTimestamp()): Uint8Array {
    return this.encryptedCommandFrame(command as number, new Uint8Array(0), timestamp);
  }

  /** 已认证连接内下发命令 `3`，让车辆更新无感钥匙配置。 */
  configurationFrame(configuration: LeapBLEConfiguration,
    timestamp: number | bigint = LeapBytes.currentTimestamp(), protocolMinor: number = 9): Uint8Array {
    return this.encryptedCommandFrame(3, configuration.wireBytes(protocolMinor), timestamp);
  }

  callCarAuthenticationFrame(certificate: LeapBLEKeyCertificate, accountId: string, deviceId: string,
    timestamp: number = Math.floor(Date.now() / 1000)): Uint8Array {
    const fields = certificate.plainText.split(';');
    if (fields.length < 6 || accountId.length === 0 || deviceId.length === 0 ||
      accountId.includes(';') || deviceId.includes(';')) { throw LeapBLEError.invalidCertificate('直进直出证书无效'); }
    fields[1] = accountId; fields[2] = deviceId;
    const text = LeapBytes.utf8(`${timestamp};${fields.join(';')};`);
    const signature = LeapGMCrypto.base64ToBytes(certificate.signResult);
    if (signature.length === 0) { throw LeapBLEError.invalidCertificate('直进直出证书签名无效'); }
    const cipher = LeapBytes.base64Bytes(this.encrypt(concatBytes([LeapBytes.littleEndian32(text.length), text, signature])));
    if (cipher.length + 69 > 65535) { throw LeapBLEError.invalidFrame('认证帧过长'); }
    return concatBytes([new Uint8Array([0xaa, 0xae, 1, 1, 10]), LeapBytes.littleEndian16(cipher.length + 69),
      LeapBytes.littleEndian32(this.sessionID), this.publicKey, cipher]);
  }

  callCarOrderFrame(order: number): Uint8Array {
    return LeapBLECryptoSession.encryptedFrame(LeapBytes.base64Bytes(this.encrypt(new Uint8Array([order]))));
  }

  /** 直进直出用独立明文：只有一个 order 字节，没有 RKE 的 CRC、时间戳和 cmdID。 */
  straightMoveFrame(order: StraightMoveOrder): Uint8Array {
    return LeapBLECryptoSession.encryptedFrame(
      LeapBytes.base64Bytes(this.encrypt(new Uint8Array([order as number]))));
  }

  private encryptedCommandFrame(commandID: number, payload: Uint8Array, timestamp: number | bigint): Uint8Array {
    const body = concatBytes([LeapBytes.littleEndian64(timestamp), new Uint8Array([commandID]), payload]);
    const framed = concatBytes([new Uint8Array([LeapBLECryptoSession.crc8(body)]), body]);
    return LeapBLECryptoSession.encryptedFrame(LeapBytes.base64Bytes(this.encrypt(framed)));
  }

  private static encryptedFrame(encodedCipher: Uint8Array): Uint8Array {
    return concatBytes([
      new Uint8Array([0xAA, LeapBLEFrameKind.Encrypted]),
      LeapBytes.littleEndian32(encodedCipher.length),
      encodedCipher
    ]);
  }

  decrypt(frame: LeapBLEFrame): Uint8Array {
    if (frame.kind !== LeapBLEFrameKind.Encrypted) {
      throw LeapBLEError.invalidFrame('AA AB 载荷不是有效 Base64');
    }
    const cipher = LeapGMCrypto.base64ToBytes(LeapBytes.decodeUTF8(frame.payload));
    if (cipher.length === 0) {
      throw LeapBLEError.invalidFrame('AA AB 载荷不是有效 Base64');
    }
    return this.usesSM
      ? LeapGMCrypto.sm4Decrypt(cipher, this.key, this.iv)
      : LeapBLECryptoSession.aesCBC(cipher, this.key, this.iv, false);
  }

  /** 多项式 0x07 的 CRC8，初值 0，不反转。RKE 命令体的第一个字节。 */
  static crc8(data: Uint8Array): number {
    let crc = 0;
    for (let index = 0; index < data.length; index++) {
      crc ^= data[index];
      for (let round = 0; round < 8; round++) {
        crc = (crc & 0x80) !== 0 ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
      }
    }
    return crc;
  }

  private encrypt(data: Uint8Array): Uint8Array {
    return this.usesSM
      ? LeapGMCrypto.sm4Encrypt(data, this.key, this.iv)
      : LeapBLECryptoSession.aesCBC(data, this.key, this.iv, true);
  }

  static sha256(data: Uint8Array): Uint8Array {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: data });
    return md.digestSync().data;
  }

  private static aesCBC(data: Uint8Array, key: Uint8Array, iv: Uint8Array, encrypting: boolean): Uint8Array {
    try {
      const symKey = cryptoFramework.createSymKeyGenerator('AES128').convertKeySync({ data: key });
      const ivSpec: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: iv } };
      const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
      cipher.initSync(
        encrypting ? cryptoFramework.CryptoMode.ENCRYPT_MODE : cryptoFramework.CryptoMode.DECRYPT_MODE,
        symKey, ivSpec);
      return cipher.doFinalSync({ data: data }).data;
    } catch (e) {
      throw LeapBLEError.cryptoFailure(`AES-CBC 失败（${(e as Error).message}）`);
    }
  }
}

// ---- 帧 ----

export enum LeapBLEFrameKind {
  Encrypted = 0xAB,
  Event = 0xAC,
  FullAuthentication = 0xAE,
  ReconnectAuthentication = 0xEE
}

export function leapBLEFrameKindOf(value: number): LeapBLEFrameKind | null {
  if (value === 0xAB) {
    return LeapBLEFrameKind.Encrypted;
  }
  if (value === 0xAC) {
    return LeapBLEFrameKind.Event;
  }
  if (value === 0xAE) {
    return LeapBLEFrameKind.FullAuthentication;
  }
  return value === 0xEE ? LeapBLEFrameKind.ReconnectAuthentication : null;
}

export function leapBLEFrameKindLabel(kind: LeapBLEFrameKind): string {
  if (kind === LeapBLEFrameKind.Encrypted) {
    return 'AA AB';
  }
  if (kind === LeapBLEFrameKind.Event) {
    return 'AA AC';
  }
  return kind === LeapBLEFrameKind.FullAuthentication ? 'AA AE' : 'AA EE';
}

export class LeapBLEFrame {
  readonly kind: LeapBLEFrameKind;
  readonly declaredPayloadLength: number;
  readonly bytes: Uint8Array;

  constructor(kind: LeapBLEFrameKind, declaredPayloadLength: number, bytes: Uint8Array) {
    this.kind = kind;
    this.declaredPayloadLength = declaredPayloadLength;
    this.bytes = bytes;
  }

  get payload(): Uint8Array {
    let offset = 4;
    if (this.kind === LeapBLEFrameKind.Encrypted) {
      offset = 6;
    } else if (this.kind === LeapBLEFrameKind.Event) {
      offset = 10;
    }
    return this.bytes.length >= offset ? this.bytes.slice(offset) : new Uint8Array(0);
  }

  get event(): LeapBLEEvent | null {
    return LeapBLEEvent.parse(this);
  }

  /**
   * 日志一行。
   *
   * `includingPayload` 默认关：载荷里带的是认证材料和会话密文，
   * 诊断日志是会被用户导出去发给我的，不能默认把它们写进去。
   */
  logDetail(includingPayload: boolean): string {
    if (includingPayload) {
      return `hex=${LeapBytes.hexString(this.bytes)}`;
    }
    return `header=${LeapBytes.hexString(this.bytes.slice(0, 2))} payload=<已隐藏 ${this.payload.length} bytes>`;
  }
}

// ---- 事件 ----

/** 触发来源。未知值原样留着，日志里能看出车端到底报了什么。 */
export class LeapBLETrigger {
  readonly rawValue: number;

  constructor(rawValue: number) {
    this.rawValue = rawValue;
  }

  get label(): string {
    if (this.rawValue === 0) {
      return '无触发';
    }
    if (this.rawValue === 1) {
      return '有感';
    }
    if (this.rawValue === 2) {
      return '无感';
    }
    return this.rawValue === 3 ? '按钮' : `未知触发(${this.rawValue})`;
  }
}

export class LeapBLEOperation {
  readonly rawValue: number;

  constructor(rawValue: number) {
    this.rawValue = rawValue;
  }

  get label(): string {
    if (this.rawValue === 0) {
      return '无操作';
    }
    if (this.rawValue === 1) {
      return '解锁';
    }
    return this.rawValue === 2 ? '闭锁' : `未知操作(${this.rawValue})`;
  }
}

export class LeapBLEArea {
  readonly rawValue: number;

  constructor(rawValue: number) {
    this.rawValue = rawValue;
  }

  get label(): string {
    if (this.rawValue === 1) {
      return '进入解锁区域';
    }
    return this.rawValue === 3 ? '进入趋势闭锁区域' : `未知区域(${this.rawValue})`;
  }
}

export enum LeapBLEEventKind {
  ErrorResponse,
  LockOperation,
  AreaChange,
  Other
}

/** `AA AC` 的明文事件。这里只解释已经由官方字符串表和实车时序交叉确认的值。 */
export class LeapBLEEvent {
  readonly kind: LeapBLEEventKind;
  readonly messageType: number;
  readonly resultCode: number;
  readonly crc8: number;
  readonly trigger: LeapBLETrigger;
  readonly operation: LeapBLEOperation;
  readonly area: LeapBLEArea;
  readonly payload: Uint8Array;

  private constructor(kind: LeapBLEEventKind, messageType: number, resultCode: number, crc8: number,
    trigger: LeapBLETrigger, operation: LeapBLEOperation, area: LeapBLEArea, payload: Uint8Array) {
    this.kind = kind;
    this.messageType = messageType;
    this.resultCode = resultCode;
    this.crc8 = crc8;
    this.trigger = trigger;
    this.operation = operation;
    this.area = area;
    this.payload = payload;
  }

  static parse(frame: LeapBLEFrame): LeapBLEEvent | null {
    if (frame.kind !== LeapBLEFrameKind.Event || frame.bytes.length < 10) {
      return null;
    }
    const messageType = frame.bytes[5];
    const payload = frame.payload;
    if (messageType === 1 && payload.length > 0) {
      return new LeapBLEEvent(LeapBLEEventKind.ErrorResponse, messageType, payload[payload.length - 1],
        0, new LeapBLETrigger(0), new LeapBLEOperation(0), new LeapBLEArea(0), payload);
    }
    if (messageType === 2 && payload.length >= 3) {
      return new LeapBLEEvent(LeapBLEEventKind.LockOperation, messageType, 0, payload[0],
        new LeapBLETrigger(payload[1]), new LeapBLEOperation(payload[2]), new LeapBLEArea(0), payload);
    }
    if (messageType === 3 && payload.length >= 2) {
      return new LeapBLEEvent(LeapBLEEventKind.AreaChange, messageType, 0, payload[0],
        new LeapBLETrigger(0), new LeapBLEOperation(0), new LeapBLEArea(payload[1]), payload);
    }
    return new LeapBLEEvent(LeapBLEEventKind.Other, messageType, 0, 0,
      new LeapBLETrigger(0), new LeapBLEOperation(0), new LeapBLEArea(0), payload);
  }

  get summary(): string {
    if (this.kind === LeapBLEEventKind.ErrorResponse) {
      return `错误应答：resultCode=${this.resultCode}（${leapBLEAuthenticationResultDescription(this.resultCode)}）`;
    }
    const crcText = LeapBytes.hexString(new Uint8Array([this.crc8]));
    if (this.kind === LeapBLEEventKind.LockOperation) {
      return `解闭锁事件：${this.trigger.label} / ${this.operation.label}，CRC8=${crcText}`;
    }
    if (this.kind === LeapBLEEventKind.AreaChange) {
      return `区域事件：${this.area.label}，CRC8=${crcText}`;
    }
    return `未解析事件：type=${this.messageType}，payload=${this.payload.length} bytes`;
  }
}

// ---- 重组 ----

class FrameDescription {
  readonly kind: LeapBLEFrameKind;
  readonly declaredLength: number;
  readonly totalLength: number;

  constructor(kind: LeapBLEFrameKind, declaredLength: number, totalLength: number) {
    this.kind = kind;
    this.declaredLength = declaredLength;
    this.totalLength = totalLength;
  }
}

/** 一次 GATT 通知不等于一帧；认证帧也会按 MTU 拆成多个分片写入。 */
export class LeapBLEFrameReassembler {
  private buffer: number[] = [];

  get bufferedByteCount(): number {
    return this.buffer.length;
  }

  reset(): void {
    this.buffer = [];
  }

  append(data: Uint8Array): LeapBLEFrame[] {
    for (let index = 0; index < data.length; index++) {
      this.buffer.push(data[index]);
    }
    const frames: LeapBLEFrame[] = [];
    while (true) {
      if (!this.alignToFrameHeader()) {
        break;
      }
      const description = this.expectedFrameDescription();
      if (description === null) {
        break;
      }
      if (description.totalLength > LeapBLEProtocol.maximumFrameLength) {
        this.buffer.shift();
        continue;
      }
      if (this.buffer.length < description.totalLength) {
        break;
      }
      const raw = new Uint8Array(this.buffer.slice(0, description.totalLength));
      frames.push(new LeapBLEFrame(description.kind, description.declaredLength, raw));
      this.buffer = this.buffer.slice(description.totalLength);
    }
    return frames;
  }

  /** 丢弃帧头前的噪声；末尾单独一个 AA 留给下一分片继续匹配。 */
  private alignToFrameHeader(): boolean {
    if (this.buffer.length < 2) {
      return false;
    }
    let start = -1;
    for (let index = 0; index < this.buffer.length - 1; index++) {
      if (this.buffer[index] === 0xAA && leapBLEFrameKindOf(this.buffer[index + 1]) !== null) {
        start = index;
        break;
      }
    }
    if (start < 0) {
      this.buffer = this.buffer[this.buffer.length - 1] === 0xAA ? [0xAA] : [];
      return false;
    }
    if (start > 0) {
      this.buffer = this.buffer.slice(start);
    }
    return true;
  }

  private expectedFrameDescription(): FrameDescription | null {
    if (this.buffer.length < 2) {
      return null;
    }
    const kind = leapBLEFrameKindOf(this.buffer[1]);
    if (kind === null) {
      return null;
    }
    if (kind === LeapBLEFrameKind.Encrypted) {
      if (this.buffer.length < 6) {
        return null;
      }
      const length = this.littleEndian32(2);
      return new FrameDescription(kind, length, 6 + length);
    }
    if (kind === LeapBLEFrameKind.Event) {
      if (this.buffer.length < 10) {
        return null;
      }
      const length = this.littleEndian32(6);
      return new FrameDescription(kind, length, 10 + length);
    }
    if (this.buffer.length < 4) {
      return null;
    }
    const length = this.buffer[2] | (this.buffer[3] << 8);
    return new FrameDescription(kind, length, 4 + length);
  }

  private littleEndian32(offset: number): number {
    return this.buffer[offset]
      | (this.buffer[offset + 1] << 8)
      | (this.buffer[offset + 2] << 16)
      | (this.buffer[offset + 3] << 24);
  }
}

/** 官方 iOS 1.22.66 handleResultCode: 查找表；含义不等同于已确定根因。 */
export function leapBLEAuthenticationResultDescription(code: number): string {
  const descriptions: string[] = [
    '认证通过', '时间戳校验不通过', '验签不通过', 'Token已失效',
    'Token验证不通过', '超时5秒未收到App数据', '命令码无效', 'Token生成失败',
    '数据包格式异常', '参数解析错误', '解析到参数，但是参数无效', '数据解密失败',
    'ECDH密钥协商失败', 'AES密钥生成失败', '数据包类型解析错误', '明文长度异常',
    '协议版本号低于1.7', '加密芯片无应答', '加密芯片应答错误'
  ];
  return Number.isInteger(code) && code >= 0 && code < descriptions.length
    ? descriptions[code] : '未知错误码';
}
