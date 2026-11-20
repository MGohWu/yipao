import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { CarModel } from './CarModel';
import { CarLayerComposer } from './CarLayerComposer';
import { ZipArchive } from './ZipArchive';
import { LeapError } from './LeapError';
import { DiagLog } from './DiagLog';

/**
 * 车模型的本地资源目录：下载 ZIP、解压、按车缓存。
 *
 * 目录布局照着渲染器的相对路径来——渲染器包里的 `index.js` 用
 * `./C11_2026/C11_2026_full_car.fbx` 这样的相对路径取模型，所以模型包必须
 * 解到渲染器同一级：
 *
 *     <cacheDir>/CarModel3D/<vin>/
 *       ├─ index.html / index.js / FBX.worker.js / models/ / textures/   ← 渲染器包
 *       └─ C11_2026/…                                                    ← 模型包
 *
 * 一辆车约 14MB，放缓存目录：系统缺空间时可以回收，回收了下次自动重下。
 *
 * 解压走自带的 `ZipArchive`：系统的 `zlib.decompressFile` 没有文件名编码开关，
 * 包里那批 GBK 命名的 CSV 会解成一串替换字符。
 */
export class CarModelAssets {
  /** 解压完成的标记。两个包都解开才写，避免半成品被当成可用。 */
  private static readonly readyMarker = '.ready';
  private static cacheRoot: string = '';

  /** 在 EntryAbility 里调一次，把缓存目录记下来。之后的调用都是同步的。 */
  static init(context: common.Context): void {
    CarModelAssets.cacheRoot = `${context.cacheDir}/CarModel3D`;
  }

  static directory(vin: string): string {
    return `${CarModelAssets.cacheRoot}/${CarModelAssets.sanitize(vin)}`;
  }

  /** VIN 直接当目录名有风险（理论上可含任意字符），非字母数字一律换成下划线。 */
  private static sanitize(raw: string): string {
    let out = '';
    for (let i = 0; i < raw.length; i++) {
      const ch = raw.charAt(i);
      const isDigit = ch >= '0' && ch <= '9';
      const isUpper = ch >= 'A' && ch <= 'Z';
      const isLower = ch >= 'a' && ch <= 'z';
      out += (isDigit || isUpper || isLower) ? ch : '_';
    }
    return out;
  }

  private static exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  /**
   * 3D 资源是否已就绪。
   *
   * 光看 `.ready` 不够：缓存目录是系统可回收的，回收往往只带走一部分文件，
   * 标记还留着。所以把渲染器跑起来必需的几个入口一起校验——`index.html`
   * 只是壳，真正加载模型的是 `index.js` 和那个 Worker，少一个都起不来。
   *
   * 车型子目录里缺贴图、缺显隐表这类，这里查不出来（文件名跟着车型走），
   * 靠渲染失败后 `invalidate` 重下一次兜底。
   */
  static isReady(vin: string): boolean {
    const dir = CarModelAssets.directory(vin);
    return CarModelAssets.exists(`${dir}/${CarModelAssets.readyMarker}`)
      && CarModelAssets.exists(`${dir}/index.html`)
      && CarModelAssets.exists(`${dir}/index.js`)
      && CarModelAssets.exists(`${dir}/FBX.worker.js`);
  }

  /**
   * 把这台车的资源作废，下次 `prepare` 会重新下。
   *
   * 只删标记不删整个目录：十几兆的包重下一遍要时间，万一新包也是坏的，
   * 至少旧文件还在，`reset` 时再统一清。
   */
  static invalidate(vin: string): void {
    const marker = `${CarModelAssets.directory(vin)}/${CarModelAssets.readyMarker}`;
    try {
      fileIo.unlinkSync(marker);
    } catch (e) {
      // 标记本来就不在，等同于已经作废。
    }
  }

  /**
   * 从解压出来的目录名反推车型别名，`Lafa5_2026/` → `Lafa5`。
   *
   * 渲染器按 `<别名>_<年款>/` 取资源，而别名不一定等于 `carType`：B05 的资源目录叫
   * `Lafa5_2026`（Lafa5 是它的内部代号），按 carType 拼必然 404。接口的 `modelParam`
   * 里没有这个别名——只有 carType/carTypeCode/colorCode/year 四项，唯一可靠的来源
   * 就是包自己解出来的目录名。这样接新车型不用维护映射表。
   *
   * 渲染器缺省的 `"lafa5"` 顶不上：那是写死的小写，而目录是 `Lafa5_2026`，
   * 大小写敏感的文件系统上命不中。必须按目录名原样传。
   *
   * B05 会同时解出 `Lafa5_2026` 和 `Lafa5Ultra_2026` 两套，靠 `carTypeCode` 里
   * 有没有 `ultra` 区分——和渲染器 `confirmVehicleLoad` 自己那段特判同一个判据。
   */
  static assetAlias(root: string, carTypeCode: string): string | null {
    let entries: string[];
    try {
      entries = fileIo.listFileSync(root);
    } catch (e) {
      return null;
    }

    const names: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      const name = entries[i];
      const separator = name.lastIndexOf('_');
      // `<名字>_<四位年款>`。渲染器自带的 models/、textures/ 不长这样，自然被滤掉。
      if (separator <= 0 || name.length - separator !== 5) {
        continue;
      }
      const year = name.substring(separator + 1);
      let allDigits = true;
      for (let j = 0; j < year.length; j++) {
        const ch = year.charAt(j);
        if (ch < '0' || ch > '9') {
          allDigits = false;
          break;
        }
      }
      if (allDigits) {
        names.push(name.substring(0, separator));
      }
    }
    if (names.length === 0) {
      return null;
    }

    const wantsUltra = carTypeCode.toLowerCase().includes('ultra');
    for (let i = 0; i < names.length; i++) {
      if (names[i].toLowerCase().includes('ultra') === wantsUltra) {
        return names[i];
      }
    }
    // 挑不出对应版本就退回任意一个：拼错版本也比拼一个必然 404 的 carType 强。
    return names[0];
  }

  /** 2D 图层包是否已就绪。 */
  static areLayersReady(vin: string): boolean {
    const dir = CarModelAssets.directory(vin);
    return CarModelAssets.exists(`${dir}/${CarModelAssets.readyMarker}`)
      && CarLayerComposer.layerDirectory(dir) !== null;
  }

  /**
   * 准备 2D 图层包。没有 3D 的车型（S01、C10…）用 `srcKey` 换到的是这一套图层，
   * 官方爱车页那张会跟着车况变的图就是它叠出来的。
   */
  static async prepareLayers(vin: string, model: CarModel,
    download: (key: string) => Promise<ArrayBuffer>): Promise<string> {
    const dir = CarModelAssets.directory(vin);
    if (CarModelAssets.areLayersReady(vin)) {
      return dir;
    }
    CarModelAssets.reset(dir);
    await CarModelAssets.unpack(await download(model.srcKey), dir);
    if (CarLayerComposer.layerDirectory(dir) === null) {
      CarModelAssets.clearPath(dir);
      throw LeapError.server('图层包里没有 android/<density> 目录');
    }
    CarModelAssets.markReady(dir);
    return dir;
  }

  /**
   * 准备 3D 资源：已就绪直接返回目录；否则下载两个包解压。
   *
   * `download` 由调用方注入（`LeapClient.fetchCarModelPackage`），
   * 这样这里不依赖网络层，测试时也能塞本地包。
   */
  static async prepare(vin: string, model: CarModel,
    download: (key: string) => Promise<ArrayBuffer>): Promise<string> {
    const dir = CarModelAssets.directory(vin);
    if (CarModelAssets.isReady(vin)) {
      return dir;
    }
    CarModelAssets.reset(dir);
    // 渲染器包在外层，模型包解进去后正好是它的同级子目录。
    await CarModelAssets.unpack(await download(model.h5Key), dir);
    await CarModelAssets.unpack(await download(model.srcKey), dir);
    if (!CarModelAssets.exists(`${dir}/index.html`)) {
      CarModelAssets.clearPath(dir);
      throw LeapError.server('渲染器包里没有 index.html');
    }
    CarModelAssets.markReady(dir);
    return dir;
  }

  /** 上次可能解到一半就被杀了，重来一遍前先清干净。 */
  private static reset(dir: string): void {
    CarModelAssets.clearPath(dir);
    try {
      // recursion 让中间的 CarModel3D 那一级也一起建出来。
      fileIo.mkdirSync(dir, true);
    } catch (e) {
      DiagLog.note(`[carmodel] 建目录失败：${e}`);
    }
  }

  /**
   * 解包直接在内存里做，不落临时 zip。
   *
   * 原来走的是 `zlib.decompressFile`，但它没有文件名编码开关：包里那批 GBK
   * 命名的 CSV 解出来是一串替换字符，渲染器按正确名字取就是 404，最后卡在
   * 「加载车模型显隐表错误」。`ZipArchive` 解名字时会退到 GB18030。
   */
  private static async unpack(payload: ArrayBuffer, dir: string): Promise<void> {
    await ZipArchive.extract(payload, dir);
  }

  private static markReady(dir: string): void {
    try {
      const marker = fileIo.openSync(`${dir}/${CarModelAssets.readyMarker}`,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.closeSync(marker);
    } catch (e) {
      DiagLog.note(`[carmodel] 写就绪标记失败：${e}`);
    }
  }

  /** 换车或换车型版本时清掉旧资源。 */
  static clear(vin: string): void {
    CarModelAssets.clearPath(CarModelAssets.directory(vin));
  }

  private static clearPath(dir: string): void {
    try {
      fileIo.rmdirSync(dir);
    } catch (e) {
      // 本来就不存在，正常。
    }
  }
}
