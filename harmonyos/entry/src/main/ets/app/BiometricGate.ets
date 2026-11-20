import { userAuth } from '@kit.UserAuthenticationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DiagLog } from '../core/DiagLog';

export enum BiometricKind {
  face = 'face',
  fingerprint = 'fingerprint',
  none = 'none'
}

/**
 * 控车前的本人确认。人脸/指纹只是「取出已保存的操作密码」的钥匙，
 * 真正发给服务端的仍然是加密后的操作密码，生物识别不能替代它。
 */
export class BiometricGate {
  /** 认证等级：ATL3 覆盖 3D 人脸与指纹，是控车这类场景的常用档。 */
  private static readonly trustLevel = userAuth.AuthTrustLevel.ATL3;

  static label(kind: BiometricKind): string {
    switch (kind) {
      case BiometricKind.face:
        return '人脸识别';
      case BiometricKind.fingerprint:
        return '指纹识别';
      default:
        return '生物识别';
    }
  }

  static symbol(kind: BiometricKind): Resource {
    switch (kind) {
      case BiometricKind.face:
        return $r('sys.symbol.face');
      case BiometricKind.fingerprint:
        return $r('sys.symbol.touchid');
      default:
        return $r('sys.symbol.lock_shield');
    }
  }

  /** 本机可用的生物识别方式。人脸优先——有人脸的机型上它更顺手。 */
  static get available(): BiometricKind {
    if (BiometricGate.supports(userAuth.UserAuthType.FACE)) {
      return BiometricKind.face;
    }
    if (BiometricGate.supports(userAuth.UserAuthType.FINGERPRINT)) {
      return BiometricKind.fingerprint;
    }
    return BiometricKind.none;
  }

  private static supports(type: userAuth.UserAuthType): boolean {
    try {
      userAuth.getAvailableStatus(type, BiometricGate.trustLevel);
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 认证的挑战值，防重放用。
   *
   * **不能传空的 `Uint8Array`**：系统在 NAPI 层读它时走 `memcpy_s`，空数组直接失败，
   * 整个 `getUserAuthInstance` 报 401 Parameter error——认证连发起都发不起来，
   * 上层只看到「识别失败」，然后默默回退到手输密码，看着就像人脸压根没接上。
   * 上限是 32 字节，就按上限给满。
   */
  private static newChallenge(): Uint8Array {
    try {
      return cryptoFramework.createRandom().generateRandomSync(32).data;
    } catch (e) {
      // 拿不到系统随机数也得给个非空的，不然又回到 401。
      const fallback = new Uint8Array(32);
      for (let i = 0; i < fallback.length; i++) {
        fallback[i] = Math.floor(Math.random() * 256);
      }
      return fallback;
    }
  }

  /** 返回 true 表示验证通过；用户取消或识别失败都返回 false，由调用方回退到操作密码。 */
  static async authenticate(reason: string): Promise<boolean> {
    const kind = BiometricGate.available;
    if (kind === BiometricKind.none) {
      return false;
    }
    const authTypes: userAuth.UserAuthType[] = kind === BiometricKind.face
      ? [userAuth.UserAuthType.FACE, userAuth.UserAuthType.FINGERPRINT]
      : [userAuth.UserAuthType.FINGERPRINT];
    try {
      const authParam: userAuth.AuthParam = {
        challenge: BiometricGate.newChallenge(),
        authType: authTypes,
        authTrustLevel: BiometricGate.trustLevel
      };
      const widgetParam: userAuth.WidgetParam = {
        title: reason,
        // 生物识别失败时用户可以走这条回到手输操作密码。
        navigationButtonText: '使用操作密码'
      };
      const instance = userAuth.getUserAuthInstance(authParam, widgetParam);
      return await new Promise<boolean>((resolve: (ok: boolean) => void) => {
        instance.on('result', {
          onResult(result: userAuth.UserAuthResult) {
            resolve(result.result === userAuth.UserAuthResultCode.SUCCESS);
          }
        });
        try {
          instance.start();
        } catch (e) {
          resolve(false);
        }
      });
    } catch (error) {
      const err = error as BusinessError;
      // 走 DiagLog 而不是 console.error：这条失败在界面上只表现为「回退到手输密码」，
      // 不落到能捞出来的日志里，就只能靠猜。
      DiagLog.note(`[auth] 认证发起失败：${err.code} ${err.message}`);
      return false;
    }
  }
}
