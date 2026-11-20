import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LeapCrypto } from './LeapCrypto';
import { LeapSession, SessionUtil } from './LeapModels';

/**
 * 关键资产存取（对应 iOS 的 Keychain）。
 *
 * 鸿蒙的 Asset Store Kit 天然按应用隔离，同一应用内的主 Ability 与卡片
 * （FormExtensionAbility）共享同一份资产，不需要 iOS 那套 access group 探测。
 */
export class AssetVault {
  /**
   * 单条资产的 SECRET 上限是 1024 字节（真机实测超了直接抛「Invalid array length」）。
   * 会话 JSON 光两个 JWT 就好几 KB，装不下，所以超长的切片存。
   * 留出余量按 900 字节一片。
   */
  private static readonly chunkBytes: number = 900;
  /** 切片模式的标记。会话 JSON 以 `{` 开头、操作密码是纯数字，不会撞上。 */
  private static readonly chunkMarker: string = '#leap-chunks:';
  /** 清理残留分片时的扫描上限，够存 45KB，比任何会话都大得多。 */
  private static readonly maxChunks: number = 50;

  private static alias(name: string): Uint8Array {
    return LeapCrypto.utf8Encode(name);
  }

  /** 读明文，自动拼回切片存的长内容。不存在或读失败返回 null。 */
  static async read(name: string): Promise<string | null> {
    const head = await AssetVault.readOne(name);
    if (head === null || !head.startsWith(AssetVault.chunkMarker)) {
      return head;
    }
    const count = Number(head.substring(AssetVault.chunkMarker.length));
    if (!Number.isFinite(count) || count <= 0) {
      return null;
    }
    let bytes = new Uint8Array(0);
    for (let i = 0; i < count; i++) {
      const part = await AssetVault.readBytes(`${name}.${i}`);
      if (part === null) {
        // 少一片就整份作废：拼出来的半截 JSON 解析只会更晚才炸。
        return null;
      }
      const merged = new Uint8Array(bytes.length + part.length);
      merged.set(bytes, 0);
      merged.set(part, bytes.length);
      bytes = merged;
    }
    return LeapCrypto.utf8Decode(bytes);
  }

  /** 写入，超长自动切片。 */
  static async write(name: string, value: string, accessibility: asset.Accessibility): Promise<boolean> {
    const bytes = LeapCrypto.utf8Encode(value);
    // 换一份内容前先把旧分片扫掉，否则上次更长的那几片会留在钥匙串里。
    await AssetVault.clearChunks(name);
    if (bytes.length <= AssetVault.chunkBytes) {
      return AssetVault.writeBytes(name, bytes, accessibility);
    }
    const count = Math.ceil(bytes.length / AssetVault.chunkBytes);
    for (let i = 0; i < count; i++) {
      const start = i * AssetVault.chunkBytes;
      // 按字节切而不是按字符：中文车辆名被从中间劈开就解不回来了。
      const slice = bytes.slice(start, Math.min(start + AssetVault.chunkBytes, bytes.length));
      const ok = await AssetVault.writeBytes(`${name}.${i}`, slice, accessibility);
      if (!ok) {
        return false;
      }
    }
    return AssetVault.writeBytes(name,
      LeapCrypto.utf8Encode(`${AssetVault.chunkMarker}${count}`), accessibility);
  }

  static async remove(name: string): Promise<void> {
    await AssetVault.clearChunks(name);
    await AssetVault.removeOne(name);
  }

  /**
   * 列出 alias 以 `prefix` 开头的全部条目。
   *
   * 蓝牙那几个 store 的 alias 里带账号和 VIN，退登时手上不一定还有完整的车辆列表
   * （资格或证书变化会先把内存里的绑定清掉），只能反过来按前缀扫。
   * 切片写入的 `.0`、`.1` 也会被扫出来，交给 `removeAll` 一并删掉。
   */
  static async aliases(prefix: string): Promise<string[]> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    try {
      const result: Array<asset.AssetMap> = await asset.query(query);
      const names: string[] = [];
      for (const item of result) {
        const alias = item.get(asset.Tag.ALIAS) as Uint8Array;
        if (alias === undefined) {
          continue;
        }
        const name = LeapCrypto.utf8Decode(alias);
        if (name.startsWith(prefix)) {
          names.push(name);
        }
      }
      return names;
    } catch (error) {
      const err = error as BusinessError;
      if (err.code !== 24000002) {
        console.error(`[asset] 枚举 ${prefix} 失败：${err.code} ${err.message}`);
      }
      return [];
    }
  }

  /** 按前缀整批删除。用在退登：一次把某类蓝牙材料清干净。 */
  static async removeAll(prefix: string): Promise<void> {
    const names = await AssetVault.aliases(prefix);
    for (const name of names) {
      await AssetVault.removeOne(name);
    }
  }

  private static async clearChunks(name: string): Promise<void> {
    for (let i = 0; i < AssetVault.maxChunks; i++) {
      const alias = `${name}.${i}`;
      const existing = await AssetVault.readBytes(alias);
      if (existing === null) {
        // 分片是连着写的，遇到第一个空位后面就没有了。
        return;
      }
      await AssetVault.removeOne(alias);
    }
  }

  /** 读明文。不存在或读失败返回 null。 */
  private static async readOne(name: string): Promise<string | null> {
    const bytes = await AssetVault.readBytes(name);
    return bytes !== null ? LeapCrypto.utf8Decode(bytes) : null;
  }

  private static async readBytes(name: string): Promise<Uint8Array | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, AssetVault.alias(name));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result: Array<asset.AssetMap> = await asset.query(query);
      if (result.length === 0) {
        return null;
      }
      const secret = result[0].get(asset.Tag.SECRET) as Uint8Array;
      return secret !== undefined ? secret : null;
    } catch (error) {
      // NOT_FOUND(24000002) 是正常的「还没存过」，不必当错误上报。
      const err = error as BusinessError;
      if (err.code !== 24000002) {
        console.error(`[asset] 读取 ${name} 失败：${err.code} ${err.message}`);
      }
      return null;
    }
  }

  /**
   * 写入一条（存在则更新）。返回是否真的写进去了。
   *
   * 写失败必须让上层知道——否则用户勾了「记住密码」，下次还是被要求手输，却看不到原因。
   */
  private static async writeBytes(name: string, secret: Uint8Array,
    accessibility: asset.Accessibility): Promise<boolean> {
    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.ALIAS, AssetVault.alias(name));
    attr.set(asset.Tag.SECRET, secret);
    attr.set(asset.Tag.ACCESSIBILITY, accessibility);
    // 同名已存在时 add 会抛 DUPLICATED(24000003)，改走 update。
    try {
      await asset.add(attr);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      if (err.code !== 24000003) {
        console.error(`[asset] 写入 ${name} 失败：${err.code} ${err.message}`);
        return false;
      }
    }
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, AssetVault.alias(name));
    const update: asset.AssetMap = new Map();
    update.set(asset.Tag.SECRET, secret);
    try {
      await asset.update(query, update);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[asset] 更新 ${name} 失败：${err.code} ${err.message}`);
      return false;
    }
  }

  private static async removeOne(name: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, AssetVault.alias(name));
    try {
      await asset.remove(query);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code !== 24000002) {
        console.error(`[asset] 删除 ${name} 失败：${err.code} ${err.message}`);
      }
    }
  }
}

/** 会话落关键资产。里面是 token、signKey 和 VIN，不能进普通首选项。 */
export class SessionStore {
  private static readonly alias = 'org.yipao.app.session';
  /**
   * 设备号单独一条，读写都只经过 `loadDeviceId` / `saveDeviceId`。
   *
   * 为什么不跟会话放一起：会话是**整份**写回的，两个进程谁后写谁说了算。某个进程
   * 启动那帧读不到关键资产、手里只有一份空会话，它一写回就把设备号也盖掉了——
   * 老签名链路从此一律 result=39，只有重新登录能救。单独一条谁都盖不着。
   */
  private static readonly deviceIdAlias = 'org.yipao.app.device-id';
  /** 内存缓存：Asset 是异步接口，同步路径（构造请求头）读不到，所以启动时载入一次。 */
  private cached: LeapSession | null = null;

  async load(): Promise<LeapSession | null> {
    const text = await AssetVault.read(SessionStore.alias);
    if (text === null) {
      return null;
    }
    try {
      const session = JSON.parse(text) as LeapSession;
      // 设备号以单独那条为准（那条谁都盖不着）；单独那条还没有、会话里却有，
      // 说明是升级上来的老用户——把它迁过去，别让人白白换一个新设备号。
      const deviceId = await this.loadDeviceId();
      if (deviceId !== null) {
        session.deviceId = deviceId;
      } else if (session.deviceId !== undefined && session.deviceId !== null && session.deviceId.length > 0) {
        await this.saveDeviceId(session.deviceId);
      }
      // 老会话（升级前持久化）的车对象可能缺 isExtendRange 字段——JSON 里没有解出来就是
      // undefined，增程会被当纯电、油量整块消失。这里按字段是否真实存在标记 abilitiesStale，
      // 让 refresh 链路强制重拉一次 vehicle/list 把真实能力码补回来（永不自愈是这次 bug 的根因）。
      // 不动 isExtendRange 本身：保持 undefined，重拉成功前一直标记着。
      if (session.vehicles != null) {
        for (const v of session.vehicles) {
          v.abilitiesStale = (v.isExtendRange === undefined || v.isExtendRange === null);
          // 哨兵支持位同理另起一份 stale：老会话缺 isSentinelSupported（哨兵是这次才加的），
          // 读出来是 undefined 会把支持哨兵的车永久当成不支持、哨兵卡永不出现。虽然增程和哨兵
          // 如今都从 abilities 翻出来，但持久化的是 isExtendRange / isSentinelSupported 两个各自
          // 派生的字段——一个缺不等于另一个也缺，所以要两份 stale，不能共用 abilitiesStale。
          v.sentinelStale = (v.isSentinelSupported === undefined || v.isSentinelSupported === null);
        }
      }
      this.cached = session;
      return session;
    } catch (e) {
      return null;
    }
  }

  /** 读设备号。不存在、读不到、空串都返回 null——调用方一律按「还没就位」处理。 */
  async loadDeviceId(): Promise<string | null> {
    const value = await AssetVault.read(SessionStore.deviceIdAlias);
    if (value === null || value.length === 0) {
      return null;
    }
    return value;
  }

  /** 写设备号。空值直接忽略：写进去等于把这台手机的身份抹了。 */
  async saveDeviceId(deviceId: string): Promise<void> {
    if (deviceId.length === 0) {
      return;
    }
    await AssetVault.write(SessionStore.deviceIdAlias, deviceId,
      asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  }

  async clearDeviceId(): Promise<void> {
    await AssetVault.remove(SessionStore.deviceIdAlias);
  }

  async save(session: LeapSession): Promise<void> {
    this.cached = session;
    // 单独那条跟着一起更新（空值不写，见 `saveDeviceId`）。
    await this.saveDeviceId(session.deviceId);
    // 设备解锁后可读，且不参与迁移（对应 iOS 的 AfterFirstUnlockThisDeviceOnly）。
    await AssetVault.write(SessionStore.alias, JSON.stringify(session),
      asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  }

  /**
   * 清会话。**设备号不清**：它是这台手机的身份，不跟登录态走。
   * 退登换一个新设备号，服务端那边就多堆一台设备，还平白多一次风控。
   */
  async clear(): Promise<void> {
    this.cached = null;
    await AssetVault.remove(SessionStore.alias);
  }

  get cachedSession(): LeapSession {
    return this.cached ?? SessionUtil.fresh();
  }
}

/** 操作密码单独存放，只在通过生物识别后取出，用于免去每次手输。 */
export class OperationPasswordStore {
  private static readonly alias = 'org.yipao.app.oppwd';

  async read(): Promise<string | null> {
    return AssetVault.read(OperationPasswordStore.alias);
  }

  async write(password: string): Promise<boolean> {
    return AssetVault.write(OperationPasswordStore.alias, password,
      asset.Accessibility.DEVICE_UNLOCKED);
  }

  async clear(): Promise<void> {
    await AssetVault.remove(OperationPasswordStore.alias);
  }

  async hasPassword(): Promise<boolean> {
    const value = await this.read();
    return value !== null && value.length > 0;
  }
}
