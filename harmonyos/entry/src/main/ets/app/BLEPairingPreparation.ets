import { BusinessError } from '@kit.BasicServicesKit';
import { LeapBLECredentialContext } from '../core/BLEProtocol';
import { LeapError, LeapErrorKind } from '../core/LeapError';
import { BLEPairingStateKind } from './BLEVehicleControllerTypes';

/** Match the iOS manual-pairing policy without adding network dependency to managed reconnects. */
export class BLEPairingPreparation {
  static preservesConnection(state: BLEPairingStateKind, current: LeapBLECredentialContext | null,
    incoming: LeapBLECredentialContext | null, eligible: boolean): boolean {
    return eligible && current !== null && incoming !== null && current.matches(incoming)
      && current.certificate.keyType === incoming.certificate.keyType
      && current.certificate.vin === incoming.certificate.vin
      && (state === BLEPairingStateKind.Scanning || state === BLEPairingStateKind.Connecting
        || state === BLEPairingStateKind.Authenticating);
  }

  static async resolve(cached: LeapBLECredentialContext | null,
    fetch: () => Promise<LeapBLECredentialContext>, isCurrent: () => boolean,
    log: (message: string) => void): Promise<LeapBLECredentialContext> {
    try {
      const fresh = await fetch();
      if (!isCurrent()) { throw LeapError.server('配对已取消或上下文已变化'); }
      const changed = cached !== null && (!cached.matches(fresh)
        || cached.certificate.keyType !== fresh.certificate.keyType);
      log(`certificate.pair.source=cloud hadCache=${cached !== null} materialChanged=${changed}`);
      return fresh;
    } catch (e) {
      if (!isCurrent()) { throw LeapError.server('配对已取消或上下文已变化'); }
      const networkFailure = BLEPairingPreparation.isNetworkFailure(e as object);
      log(`certificate.pair.refresh.failed networkFailure=${networkFailure}`);
      if (!networkFailure || cached === null || !cached.certificate.isSupportedKeyType
        || !cached.certificate.hasValidPasswordCard) { throw e as Error; }
      log(`certificate.pair.source=cache reason=networkFailure keyType=${cached.certificate.keyType}`);
      return cached;
    }
  }

  private static isNetworkFailure(error: object): boolean {
    if (error instanceof LeapError) {
      return error.kind === LeapErrorKind.Http && error.httpStatus >= 500 && error.httpStatus <= 599;
    }
    // NetworkKit DNS/connect/timeout/empty response/send/receive failures. Do not turn
    // cancellation, permission denial, invalid certificates or arbitrary errors into offline mode.
    return [2300005, 2300006, 2300007, 2300028, 2300052, 2300055, 2300056]
      .includes((error as BusinessError).code);
  }
}
