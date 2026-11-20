import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { DiagLog } from '../core/DiagLog';
import { LeapError } from '../core/LeapError';

/**
 * 蓝牙权限。
 *
 * `ohos.permission.ACCESS_BLUETOOTH` 是 user_grant：光在 `module.json5` 里声明不够，
 * 不主动申请的话扫描和连接会直接抛 201（权限校验失败），界面上只会看到「搜不到车」。
 *
 * iOS 那边没有这一层——CoreBluetooth 第一次用到就由系统代为弹窗。
 *
 * 申请时机也照着这条差异定：只在用户**主动**去绑车（`prepareBLEPairing`）或在诊断页手动
 * 开扫描时问一次，不在启动时问。已经授权过就直接返回，系统不会重复弹。
 */
export class BLEPermission {
  private static readonly permissions: Permissions[] = ['ohos.permission.ACCESS_BLUETOOTH'];
  private static context: common.UIAbilityContext | null = null;

  static init(context: common.UIAbilityContext): void {
    BLEPermission.context = context;
  }

  /** 返回是否拿到了授权。拿不到时调用方照常往下走——失败信息由蓝牙那层给。 */
  static async ensure(): Promise<boolean> {
    const context = BLEPermission.context;
    if (context === null) {
      DiagLog.note('[ble:perm] 还没拿到 context，跳过蓝牙权限申请');
      return false;
    }
    try {
      const result = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(context, BLEPermission.permissions);
      const granted = result.authResults.length > 0 && result.authResults[0] === 0;
      if (!granted) {
        DiagLog.note('[ble:perm] 用户没有授予蓝牙权限');
      }
      return granted;
    } catch (e) {
      DiagLog.note(`[ble:perm] 申请蓝牙权限失败：${LeapError.messageOf(e as object)}`);
      return false;
    }
  }
}
