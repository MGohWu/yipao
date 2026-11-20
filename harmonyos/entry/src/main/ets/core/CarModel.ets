import { JsonValue } from './JsonValue';

/**
 * 3D 渲染器的车型参数。字段名照抄渲染器 `parseServerJson` 读的那几个键，
 * 序列化出来的 JSON 直接就是 `newInit` 的第一个入参。
 */
export class CarModelParam {
  carType: string;
  year: number;
  carTypeCode: string;
  colorCode: number;
  roofColorCode: number | null;
  seat: number | null;
  /**
   * 左右舵。资源文件名的第一段就是它（`C11_2026_0_0_0_…`），
   * 不传的话渲染器默认按右舵拼路径，国内车全都会 404。
   */
  rudder: number;

  constructor(carType: string, year: number, carTypeCode: string, colorCode: number,
    roofColorCode: number | null, seat: number | null, rudder: number) {
    this.carType = carType;
    this.year = year;
    this.carTypeCode = carTypeCode;
    this.colorCode = colorCode;
    this.roofColorCode = roofColorCode;
    this.seat = seat;
    this.rudder = rudder;
  }

  static fromJson(raw: JsonValue | null): CarModelParam | null {
    if (raw === null) {
      return null;
    }
    const carTypeNode = raw.get('carType');
    const carType = carTypeNode !== null ? carTypeNode.stringValue : null;
    if (carType === null || carType.length === 0) {
      return null;
    }
    const yearNode = raw.get('year');
    const codeNode = raw.get('carTypeCode');
    const colorNode = raw.get('colorCode');
    const roofNode = raw.get('roofColor');
    const seatNode = raw.get('seat');
    const rudderNode = raw.get('rudder');
    return new CarModelParam(
      carType,
      yearNode !== null && yearNode.intValue !== null ? yearNode.intValue : 2025,
      codeNode !== null && codeNode.stringValue !== null ? codeNode.stringValue : '',
      colorNode !== null && colorNode.intValue !== null ? colorNode.intValue : 0,
      roofNode !== null ? roofNode.intValue : null,
      seatNode !== null ? seatNode.intValue : null,
      // 接口不返回这项，国内车一律左舵。
      rudderNode !== null && rudderNode.intValue !== null ? rudderNode.intValue : 0
    );
  }

  /** 资源目录名，`C11_2026` 这种。渲染器按同样规则拼资源路径。 */
  get assetDirectory(): string {
    return `${this.carType}_${this.year}`;
  }

  /**
   * 渲染器 `newInit(serverJson, appJson)` 的第一个入参。
   *
   * `alias` 传解压目录反推出来的真实别名（`CarModelAssets.assetAlias`）。
   * 渲染器 `confirmVehicleLoad` 先按 carType 拼资源目录，404 了才拿 alias 再试一次——
   * 这个兜底就是给代号和目录名对不上的车型准备的：B05 的目录叫 `Lafa5_2026`。
   * 反推不出来就不传，让渲染器用包自带的缺省值，总比填一个必然 404 的 carType 强。
   */
  serverJSONWith(alias: string | null): string {
    const fields: string[] = [
      `"carType":"${this.carType}"`,
      `"year":${this.year}`,
      `"carTypeCode":"${this.carTypeCode}"`,
      `"colorCode":${this.colorCode}`,
      `"rudder":${this.rudder}`,
      // 相机距离。渲染器默认 20 是给全屏爱车页的，车在首页这块小画布里会显得很小。
      `"radius":11`,
      // 垂直偏移。车默认落在画布正中偏下，正好撞上下面那排状态徽章。
      `"offset":0.3`
    ];
    if (alias !== null && alias.length > 0) {
      fields.push(`"alias":"${alias}"`);
    }
    if (this.roofColorCode !== null) {
      fields.push(`"roofColorCode":${this.roofColorCode}`);
    }
    if (this.seat !== null) {
      fields.push(`"seat":${this.seat}`);
    }
    return `{${fields.join(',')}}`;
  }
}

/**
 * 爱车页车模型。官方 `carpicture/3d/key` 一个接口同时覆盖两类车：
 * `modelType == 3` 是真 3D（渲染器 + 模型两个 zip，本地离线渲染），
 * 其余（S01、C10 等）用 `srcKey` 换到的是一套分层贴图。
 */
export class CarModel {
  modelType: number;
  modelVersion: string;
  /** 资源包 key。3D 车 srcKey 是模型、h5Key 是渲染器；2D 车只有 srcKey。 */
  srcKey: string;
  h5Key: string;
  srcWhole: string;
  h5Whole: string;
  modelParam: CarModelParam | null;

  constructor(modelType: number, modelVersion: string, srcKey: string, h5Key: string = '',
    srcWhole: string = '', h5Whole: string = '', modelParam: CarModelParam | null = null) {
    this.modelType = modelType;
    this.modelVersion = modelVersion;
    this.srcKey = srcKey;
    this.h5Key = h5Key;
    this.srcWhole = srcWhole;
    this.h5Whole = h5Whole;
    this.modelParam = modelParam;
  }

  get is3D(): boolean {
    return this.modelType === 3;
  }

  /** 两个包齐了才渲染得起来。 */
  get has3DPackages(): boolean {
    return this.is3D && this.srcKey.length > 0 && this.h5Key.length > 0;
  }

  /** 从 `carpicture/3d/key` 响应解析。没有 srcKey 就什么资源都取不到，返回 null。 */
  static fromResponse(raw: JsonValue | null): CarModel | null {
    if (raw === null) {
      return null;
    }
    const data = raw.get('data');
    if (data === null) {
      return null;
    }
    const srcKeyNode = data.get('srcKey');
    const srcKey = srcKeyNode !== null ? srcKeyNode.stringValue : null;
    if (srcKey === null || srcKey.length === 0) {
      return null;
    }
    const typeNode = data.get('modelType');
    const versionNode = data.get('modelVersion');
    const h5KeyNode = data.get('h5Key');
    const srcWholeNode = data.get('srcWhole');
    const h5WholeNode = data.get('h5Whole');
    return new CarModel(
      typeNode !== null && typeNode.intValue !== null ? typeNode.intValue : 2,
      versionNode !== null && versionNode.stringValue !== null ? versionNode.stringValue : '',
      srcKey,
      h5KeyNode !== null && h5KeyNode.stringValue !== null ? h5KeyNode.stringValue : '',
      srcWholeNode !== null && srcWholeNode.stringValue !== null ? srcWholeNode.stringValue : '',
      h5WholeNode !== null && h5WholeNode.stringValue !== null ? h5WholeNode.stringValue : '',
      CarModelParam.fromJson(data.get('modelParam'))
    );
  }
}
