import { asset } from '@kit.AssetStoreKit';
import { LeapBLEConfiguration, LeapBLEKeyCertificate, LeapBLEProtocol } from '../core/BLEProtocol';
import { AssetVault } from '../core/SecureStore';
import { SharedSettings } from '../core/SharedSettings';

/**
 * 蓝牙钥匙的持久化层。对应 iOS 的 `App/BLEVehicleBinding.swift`
 * 加 `Core/SessionStore.swift` 里的两个蓝牙 store。
 *
 * 三样东西都是认证材料，一律进关键资产（对应 iOS 的钥匙串），不能落首选项：
 * 证书能直接换出会话密钥，重连 token 能跳过完整认证，绑定里带着车端的无感标定。
 *
 * 与 iOS 的两处差异，都是平台差异不是取舍：
 * 1. iOS 有 `BLEInstallationGuard`——重装会留下钥匙串条目，得防新安装接管旧车。
 *    鸿蒙的关键资产随应用卸载一起清掉，没有这个窗口，所以不移植。
 * 2. iOS 的 `KeychainLoadOutcome` 要把「没存过」和「锁着读不到」分开（首次解锁前
 *    读不到会被误判成没配对）。Asset Store Kit 的 DEVICE_FIRST_UNLOCKED 条目在
 *    锁屏期间查询同样返回 NOT_FOUND，分不出来，所以这里统一按 null 处理，
 *    并且不在读失败时清任何东西——宁可这次不可用，也不能把配对删掉。
 */

/** 配置写进车里没有的中间态。写失败要能在下次连上时补写，所以状态得落盘。 */
export enum BLEConfigurationSyncState {
  Synced = 'synced',
  Pending = 'pending',
  PendingDisable = 'pendingDisable'
}

/** 落盘用的扁平结构。类实例带 getter，`JSON.stringify` 出来的形状不稳定。 */
interface BLEConfigurationRecord {
  distanceCalibration: number;
  coefficientHundredths: number;
  unlockCalibration: number;
  lockCalibration: number;
  isEnabled: boolean;
  autoLockEnabled: boolean;
  autoUnlockEnabled: boolean;
  supportsButton: boolean;
  distanceSelection?: number;
  defaultUnlockCalibration?: number;
  multipleAnchors?: boolean;
}

interface BLEVehicleBindingRecord {
  accountId: string;
  vin: string;
  deviceId: string;
  certificateFingerprint: string;
  configuration: BLEConfigurationRecord;
  syncState: string;
  removeAfterDisable: boolean;
  lastVerifiedAt: number;
  protocolMinor?: number;
}

interface BLEKeyCertificateRecord {
  ecdhPublicKey: string;
  keyType: number;
  passwordCard: string;
  plainText: string;
  signResult: string;
  vin: string;
}

/**
 * 一台已配对车辆。
 *
 * `deviceId` 是鸿蒙 BLE 的设备地址，对应 iOS 的 `peripheralIdentifier`（CoreBluetooth
 * 的 UUID）。两边都只是「下次直接连这台外设」的凭据，不跨设备通用。
 */
export class BLEVehicleBinding {
  readonly accountId: string;
  readonly vin: string;
  readonly deviceId: string;
  certificateFingerprint: string;
  configuration: LeapBLEConfiguration;
  syncState: BLEConfigurationSyncState;
  removeAfterDisable: boolean;
  /** 上次认证成功的时刻（毫秒）。0 表示还没成功过。 */
  lastVerifiedAt: number;
  protocolMinor: number;

  constructor(accountId: string, vin: string, deviceId: string, certificateFingerprint: string,
    configuration: LeapBLEConfiguration, syncState: BLEConfigurationSyncState,
    removeAfterDisable: boolean, lastVerifiedAt: number, protocolMinor: number = 8) {
    this.protocolMinor = protocolMinor;
    this.accountId = accountId;
    this.vin = vin;
    this.deviceId = deviceId;
    this.certificateFingerprint = certificateFingerprint;
    this.configuration = configuration;
    this.syncState = syncState;
    this.removeAfterDisable = removeAfterDisable;
    this.lastVerifiedAt = lastVerifiedAt;
  }

  get isBluetoothControlEnabled(): boolean {
    return this.configuration.isEnabled && this.syncState !== BLEConfigurationSyncState.PendingDisable;
  }

  get isPassiveEntryEnabled(): boolean {
    return this.isBluetoothControlEnabled
      && (this.configuration.autoUnlockEnabled || this.configuration.autoLockEnabled);
  }

  /** 关蓝牙控车的那一步也要连上去把配置写回车里，所以 pendingDisable 仍然维持连接。 */
  get shouldMaintainConnection(): boolean {
    return this.isBluetoothControlEnabled || this.syncState === BLEConfigurationSyncState.PendingDisable;
  }

  toJson(): string {
    const configuration: BLEConfigurationRecord = {
      distanceCalibration: this.configuration.distanceCalibration,
      coefficientHundredths: this.configuration.coefficientHundredths,
      unlockCalibration: this.configuration.unlockCalibration,
      lockCalibration: this.configuration.lockCalibration,
      isEnabled: this.configuration.isEnabled,
      autoLockEnabled: this.configuration.autoLockEnabled,
      autoUnlockEnabled: this.configuration.autoUnlockEnabled,
      supportsButton: this.configuration.supportsButton,
      distanceSelection: this.configuration.distanceSelection,
      defaultUnlockCalibration: this.configuration.defaultUnlockCalibration,
      multipleAnchors: this.configuration.multipleAnchors
    };
    const record: BLEVehicleBindingRecord = {
      accountId: this.accountId,
      vin: this.vin,
      deviceId: this.deviceId,
      certificateFingerprint: this.certificateFingerprint,
      configuration: configuration,
      syncState: this.syncState as string,
      removeAfterDisable: this.removeAfterDisable,
      lastVerifiedAt: this.lastVerifiedAt,
      protocolMinor: this.protocolMinor
    };
    return JSON.stringify(record);
  }

  static fromJson(text: string): BLEVehicleBinding | null {
    let record: BLEVehicleBindingRecord;
    try {
      record = JSON.parse(text) as BLEVehicleBindingRecord;
    } catch (e) {
      return null;
    }
    if (record === null || record === undefined
      || typeof record.accountId !== 'string' || record.accountId.length === 0
      || typeof record.vin !== 'string' || record.vin.length === 0
      || typeof record.deviceId !== 'string' || record.deviceId.length === 0) {
      return null;
    }
    const raw = record.configuration;
    if (raw === null || raw === undefined || typeof raw.distanceCalibration !== 'number') {
      return null;
    }
    const configuration = new LeapBLEConfiguration(
      raw.distanceCalibration, raw.coefficientHundredths, raw.unlockCalibration, raw.lockCalibration,
      raw.isEnabled === true, raw.autoLockEnabled === true,
      raw.autoUnlockEnabled === true, raw.supportsButton === true,
      raw.distanceSelection ?? -1, raw.defaultUnlockCalibration ?? -1, raw.multipleAnchors ?? false);
    return new BLEVehicleBinding(
      record.accountId, record.vin, record.deviceId,
      typeof record.certificateFingerprint === 'string' ? record.certificateFingerprint : '',
      configuration,
      BLEVehicleBinding.syncStateOf(record.syncState),
      record.removeAfterDisable === true,
      typeof record.lastVerifiedAt === 'number' ? record.lastVerifiedAt : 0, record.protocolMinor ?? 8);
  }

  /** 未知状态一律当 pending：宁可多写一次配置，也不能当成「已经同步好了」。 */
  private static syncStateOf(value: string): BLEConfigurationSyncState {
    if (value === BLEConfigurationSyncState.Synced as string) {
      return BLEConfigurationSyncState.Synced;
    }
    if (value === BLEConfigurationSyncState.PendingDisable as string) {
      return BLEConfigurationSyncState.PendingDisable;
    }
    return BLEConfigurationSyncState.Pending;
  }

  /** 换一份配置，其余字段照抄。改配置一定伴随一次待同步。 */
  withConfiguration(configuration: LeapBLEConfiguration,
    syncState: BLEConfigurationSyncState): BLEVehicleBinding {
    return new BLEVehicleBinding(this.accountId, this.vin, this.deviceId, this.certificateFingerprint,
      configuration, syncState, this.removeAfterDisable, this.lastVerifiedAt, this.protocolMinor);
  }
}

/** 账号 + VIN 拼成 alias 的后半段。同一部手机上可以并存多个账号的多台车。 */
function bindingScope(accountId: string, vin: string): string {
  return `${accountId}|${vin}`;
}

/** 已认证车辆和它的无感配置，按账号/VIN 隔离保存。 */
export class BLEVehicleBindingStore {
  private static readonly prefix = 'org.yipao.app.ble-binding.';

  async load(accountId: string, vin: string): Promise<BLEVehicleBinding | null> {
    const text = await AssetVault.read(BLEVehicleBindingStore.prefix + bindingScope(accountId, vin));
    if (text === null) {
      return null;
    }
    const binding = BLEVehicleBinding.fromJson(text);
    if (binding === null) {
      // 解不出来按「没有」算：持久坏数据只能重新配对，重试救不了。
      return null;
    }
    // 存量回填：老版本配的对只在关键资产里，没走过本版的 `save()`。读到一次就补上痕迹，
    // 否则这批用户升级后一退登，「需要重新配对」提示会被 hasPaired 吞掉——
    // 而他们正是这条提示要服务的人。
    BLEPairingHistory.recordPaired(binding.accountId, binding.vin);
    return binding;
  }

  async save(binding: BLEVehicleBinding): Promise<boolean> {
    const saved = await AssetVault.write(
      BLEVehicleBindingStore.prefix + bindingScope(binding.accountId, binding.vin),
      binding.toJson(), asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    if (saved) {
      BLEPairingHistory.recordPaired(binding.accountId, binding.vin);
    }
    return saved;
  }

  async clear(accountId: string, vin: string): Promise<void> {
    await AssetVault.remove(BLEVehicleBindingStore.prefix + bindingScope(accountId, vin));
  }

  async clearAll(): Promise<void> {
    await AssetVault.removeAll(BLEVehicleBindingStore.prefix);
  }
}

/** 蓝牙钥匙证书。会话密钥由它协商出来，比 token 更敏感。 */
export class BLEKeyCertificateStore {
  private static readonly prefix = 'org.yipao.app.ble-cert.';

  async load(accountId: string, vin: string): Promise<LeapBLEKeyCertificate | null> {
    const text = await AssetVault.read(BLEKeyCertificateStore.prefix + bindingScope(accountId, vin));
    if (text === null) {
      return null;
    }
    let record: BLEKeyCertificateRecord;
    try {
      record = JSON.parse(text) as BLEKeyCertificateRecord;
    } catch (e) {
      return null;
    }
    if (record === null || record === undefined || typeof record.ecdhPublicKey !== 'string') {
      return null;
    }
    const certificate = new LeapBLEKeyCertificate(
      record.ecdhPublicKey, typeof record.keyType === 'number' ? record.keyType : 0,
      typeof record.passwordCard === 'string' ? record.passwordCard : '',
      typeof record.plainText === 'string' ? record.plainText : '',
      typeof record.signResult === 'string' ? record.signResult : '',
      typeof record.vin === 'string' ? record.vin : '');
    // 没过校验的按「没有」算：那是坏数据，出路是重新同步，重试救不了。
    if (!certificate.isSupportedKeyType || !certificate.hasValidPasswordCard) {
      return null;
    }
    return certificate;
  }

  async save(certificate: LeapBLEKeyCertificate, accountId: string, vin: string): Promise<boolean> {
    if (!certificate.isSupportedKeyType || !certificate.hasValidPasswordCard) {
      return false;
    }
    const record: BLEKeyCertificateRecord = {
      ecdhPublicKey: certificate.ecdhPublicKey,
      keyType: certificate.keyType,
      passwordCard: certificate.passwordCard,
      plainText: certificate.plainText,
      signResult: certificate.signResult,
      vin: certificate.vin
    };
    return AssetVault.write(BLEKeyCertificateStore.prefix + bindingScope(accountId, vin),
      JSON.stringify(record), asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  }

  async clear(accountId: string, vin: string): Promise<void> {
    await AssetVault.remove(BLEKeyCertificateStore.prefix + bindingScope(accountId, vin));
  }

  async clearAll(): Promise<void> {
    await AssetVault.removeAll(BLEKeyCertificateStore.prefix);
  }
}

/** 车端下发的快速重连 token。有它就能跳过完整认证，直接走 `AA EE`。 */
export class BLEReconnectTokenStore {
  private static readonly prefix = 'org.yipao.app.ble-token.';

  async load(accountId: string, vin: string): Promise<string | null> {
    const token = await AssetVault.read(BLEReconnectTokenStore.prefix + bindingScope(accountId, vin));
    return token !== null && token.length > 0 ? token : null;
  }

  async save(token: string, accountId: string, vin: string): Promise<boolean> {
    try {
      LeapBLEProtocol.decodeReconnectToken(token);
    } catch (e) {
      // 存下一份组不成帧的 token，只会让下次重连认证在车边上失败一次。
      return false;
    }
    return AssetVault.write(BLEReconnectTokenStore.prefix + bindingScope(accountId, vin),
      token, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  }

  async clear(accountId: string, vin: string): Promise<void> {
    await AssetVault.remove(BLEReconnectTokenStore.prefix + bindingScope(accountId, vin));
  }

  async clearAll(): Promise<void> {
    await AssetVault.removeAll(BLEReconnectTokenStore.prefix);
  }
}

/**
 * 「这台车在这部手机上配对过」的痕迹，专给「需要重新配对」提示做归因。
 *
 * 上面三份材料退登会被连坐清掉，没有痕迹就分不清「配对丢了」和「从没配过」，
 * 后者弹这条提示纯属吓人。放普通首选项而不是关键资产：它只影响一条提示文案，
 * 卸载重装丢了就不提示，无害。
 */
export class BLEPairingHistory {
  private static readonly key = 'ble.everPaired';

  static recordPaired(accountId: string, vin: string): void {
    const token = bindingScope(accountId, vin);
    const list = BLEPairingHistory.list();
    if (list.indexOf(token) >= 0) {
      return;
    }
    list.push(token);
    SharedSettings.setString(BLEPairingHistory.key, list.join('\n'));
  }

  static hasPaired(accountId: string, vin: string): boolean {
    return BLEPairingHistory.list().indexOf(bindingScope(accountId, vin)) >= 0;
  }

  private static list(): string[] {
    const text = SharedSettings.getString(BLEPairingHistory.key, '');
    return text.length === 0 ? [] : text.split('\n');
  }
}
