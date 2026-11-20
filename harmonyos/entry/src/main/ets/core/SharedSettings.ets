import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/**
 * 主应用与服务卡片共享的普通设置（对应 iOS 的 App Group UserDefaults）。
 *
 * 鸿蒙同一应用的 UIAbility 与 FormExtensionAbility 共用应用沙箱，
 * 用同一个 preferences 文件名即可共享，不需要额外的容器声明。
 *
 * 首选项的读接口是异步的，但界面里到处要同步读，所以启动时 `init` 一次性
 * 把整份快照拉进内存，之后读走缓存、写同时落盘。
 */
export class SharedSettings {
  private static readonly storeName = 'leap_shared';
  private static store: preferences.Preferences | null = null;
  private static cache = new Map<string, string>();

  /**
   * 应用/卡片启动时调一次。失败不抛——设置读不到时各处都有默认值。
   *
   * 同步：卡片的 `onAddForm` 必须当场返回绑定数据，等不了 Promise。
   * 首选项本身有同步接口，内部也确实没有异步步骤。
   */
  static init(context: common.Context): void {
    if (SharedSettings.store !== null) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(context, { name: SharedSettings.storeName });
      SharedSettings.store = store;
      const all = store.getAllSync() as Record<string, string>;
      const keys = Object.keys(all);
      for (let i = 0; i < keys.length; i++) {
        const value = all[keys[i]];
        if (typeof value === 'string') {
          SharedSettings.cache.set(keys[i], value);
        }
      }
    } catch (e) {
      console.error(`[settings] 初始化失败：${(e as Error).message}`);
    }
  }

  /**
   * 把磁盘上的值重新拉一遍，盖掉内存缓存。
   *
   * 缓存是启动时读一次的，跨进程的写这边一律看不见。两个方向都会出事：
   * 卡片进程活着的时候用户在 App 里刚开了「卡片直接控车」、刚存了操作密码，
   * 卡片按下去还是按老值走；反过来，卡片写下的待执行动作，后台里的 App
   * 回到前台时也读不到。所以两边都在自己的入口处先 `reload` 一次。
   *
   * 只重读，不清空：`getAllSync` 拿到的就是这一刻的全量，缺的键本来就该消失。
   */
  static reload(): void {
    const store = SharedSettings.store;
    if (store === null) {
      return;
    }
    try {
      const all = store.getAllSync() as Record<string, string>;
      const keys = Object.keys(all);
      const fresh = new Map<string, string>();
      for (let i = 0; i < keys.length; i++) {
        const value = all[keys[i]];
        if (typeof value === 'string') {
          fresh.set(keys[i], value);
        }
      }
      SharedSettings.cache = fresh;
    } catch (e) {
      console.error(`[settings] 重读失败：${(e as Error).message}`);
    }
  }

  static getString(key: string, fallback: string = ''): string {
    return SharedSettings.cache.get(key) ?? fallback;
  }

  static getBool(key: string, fallback: boolean = false): boolean {
    const value = SharedSettings.cache.get(key);
    if (value === undefined) {
      return fallback;
    }
    return value === 'true';
  }

  static getInt(key: string, fallback: number): number {
    const value = SharedSettings.cache.get(key);
    if (value === undefined) {
      return fallback;
    }
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }

  static setString(key: string, value: string): void {
    SharedSettings.cache.set(key, value);
    const store = SharedSettings.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flush();
    } catch (e) {
      console.error(`[settings] 写入 ${key} 失败：${(e as Error).message}`);
    }
  }

  static setBool(key: string, value: boolean): void {
    SharedSettings.setString(key, value ? 'true' : 'false');
  }

  static setInt(key: string, value: number): void {
    SharedSettings.setString(key, String(value));
  }

  static remove(key: string): void {
    SharedSettings.cache.delete(key);
    const store = SharedSettings.store;
    if (store === null) {
      return;
    }
    try {
      store.deleteSync(key);
      store.flush();
    } catch (e) {
      console.error(`[settings] 删除 ${key} 失败：${(e as Error).message}`);
    }
  }
}
