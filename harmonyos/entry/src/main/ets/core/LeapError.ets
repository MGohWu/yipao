/** 业务错误。kind 用于分流处理（会话过期要踢回登录页，网络错误不能）。 */
export enum LeapErrorKind {
  Crypto,
  NotLoggedIn,
  /** 服务端明确拒绝了当前登录态，且续期也救不回来——只能重新短信登录。 */
  SessionExpired,
  /**
   * 老链路连着失败到「重试也不会好」的程度：**只提示**用户去重新登录，不清会话。
   *
   * 跟 `SessionExpired` 分开是有意的：那个会把会话连同蓝牙钥匙证书一起清掉，
   * 而这一档的判据是「连败次数 + 时长」的启发式，未必真是登录态没了。
   * 猜错的代价不对称——猜错就清，用户失去的是蓝牙钥匙；猜错只提示，最多多一句话。
   */
  NeedsRelogin,
  MissingVehicle,
  Server,
  Http,
  Decode
}

export class LeapError extends Error {
  readonly kind: LeapErrorKind;
  readonly httpStatus: number;

  constructor(kind: LeapErrorKind, message: string, httpStatus: number = 0) {
    super(message);
    this.name = 'LeapError';
    this.kind = kind;
    this.httpStatus = httpStatus;
  }

  static crypto(message: string): LeapError {
    return new LeapError(LeapErrorKind.Crypto, message);
  }

  static notLoggedIn(): LeapError {
    return new LeapError(LeapErrorKind.NotLoggedIn, '还没有登录，请先完成短信验证码登录');
  }

  static sessionExpired(): LeapError {
    return new LeapError(LeapErrorKind.SessionExpired, '登录已过期，请重新登录');
  }

  static needsRelogin(): LeapError {
    return new LeapError(LeapErrorKind.NeedsRelogin, '控车授权已失效，请重新登录');
  }

  static missingVehicle(): LeapError {
    return new LeapError(LeapErrorKind.MissingVehicle, '还没有选择车辆');
  }

  static server(message: string): LeapError {
    return new LeapError(LeapErrorKind.Server, message);
  }

  static http(status: number, body: string): LeapError {
    return new LeapError(LeapErrorKind.Http, `HTTP ${status}：${body}`, status);
  }

  static decode(message: string): LeapError {
    return new LeapError(LeapErrorKind.Decode, `响应解析失败：${message}`);
  }

  /**
   * 把任意抛出的值转成用户可读文案。
   *
   * 不能只认 `Error`：系统 Kit（网络、加密、关键资产）抛的是 `BusinessError`，
   * 它是个带 `code` / `message` 的普通对象，不是 `Error` 的实例。
   * 直接 `String()` 出来就是「[object Object]」——用户看到这个等于什么都没说。
   */
  static messageOf(e: object | string | null | undefined): string {
    if (e === null || e === undefined) {
      return '未知错误';
    }
    if (typeof e === 'string') {
      return e.length > 0 ? e : '未知错误';
    }
    if (e instanceof Error) {
      return e.message.length > 0 ? e.message : e.name;
    }

    // BusinessError 及其它带 message 的对象。错误码一并带上——
    // 排查时「登录失败」和「登录失败（2300006 无法解析主机）」差别很大。
    const record = e as Record<string, Object>;
    const rawMessage = record.message;
    const rawCode = record.code;
    const message = typeof rawMessage === 'string' ? rawMessage : '';
    const code = typeof rawCode === 'number' ? String(rawCode)
      : (typeof rawCode === 'string' ? rawCode : '');
    if (message.length > 0) {
      return code.length > 0 ? `${message}（${code}）` : message;
    }
    if (code.length > 0) {
      return `操作失败（错误码 ${code}）`;
    }

    // 连 message 和 code 都没有，退回 JSON——总比「[object Object]」多一点信息。
    try {
      const json = JSON.stringify(e);
      return json !== undefined && json.length > 2 && json !== '{}' ? json : '未知错误';
    } catch (jsonError) {
      return '未知错误';
    }
  }
}
