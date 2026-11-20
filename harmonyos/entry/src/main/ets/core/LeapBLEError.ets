/**
 * 蓝牙钥匙链路的错误。
 *
 * 单独于 `LeapError` 立一个类型，理由和 iOS 的 `LeapBLEProtocolError` 一样：
 * 这条链路整条都不走 HTTP，`LeapErrorKind` 里那套「会话过期要踢回登录页」
 * 的分流对它一条都不适用，混在一起只会让上层判错分支。
 *
 * 文案逐字对齐 iOS，出问题时两端截图能直接对。
 */
export enum LeapBLEErrorKind {
  UnsupportedKeyType,
  InvalidCertificate,
  InvalidFrame,
  CryptoFailure
}

export class LeapBLEError extends Error {
  readonly kind: LeapBLEErrorKind;

  constructor(kind: LeapBLEErrorKind, message: string) {
    super(message);
    this.name = 'LeapBLEError';
    this.kind = kind;
  }

  static unsupportedKeyType(value: number): LeapBLEError {
    return new LeapBLEError(LeapBLEErrorKind.UnsupportedKeyType,
      `暂不支持的蓝牙证书类型（keyType=${value}）`);
  }

  static invalidCertificate(reason: string): LeapBLEError {
    return new LeapBLEError(LeapBLEErrorKind.InvalidCertificate, `蓝牙证书无效：${reason}`);
  }

  static invalidFrame(reason: string): LeapBLEError {
    return new LeapBLEError(LeapBLEErrorKind.InvalidFrame, `蓝牙帧无效：${reason}`);
  }

  static cryptoFailure(reason: string): LeapBLEError {
    return new LeapBLEError(LeapBLEErrorKind.CryptoFailure, `蓝牙加解密失败：${reason}`);
  }
}
