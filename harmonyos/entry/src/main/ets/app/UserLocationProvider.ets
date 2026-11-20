import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { DiagLog } from '../core/DiagLog';
import { LeapError } from '../core/LeapError';

/**
 * 手机自己的位置。只有车辆位置页用：地图上那个蓝点，以及「离车还有多远」。
 *
 * 权限只要前台这一次（`when: "inuse"`），不申请「始终」，也不做持续订阅——
 * 进这一页取一次就够，人走了不会有任何后台定位。
 *
 * 坐标系：这里返回的是 **WGS-84**，而车端上报的是 GCJ-02，两边差着一个偏移。实测
 * 人站在车边时，直接相减是 838 米，把手机那头转成 GCJ-02 之后是 290 米。所以凡是要和车比、
 * 要喂给地图相机或路线服务的地方，都得先用 `map.convertCoordinateSync` 转一道
 * （见 `VehicleLocationView` 的 `userPoint`）。
 *
 * 唯一的例外是地图的 `setMyLocation`：它收的就是这里返回的原始 `Location`，
 * 偏移由地图自己加，转过再喂反而会偏两次。
 *
 * iOS 对应 `UserLocationProvider`（CoreLocation 那份）。那边权限是系统代为弹窗，
 * 这边必须自己申请，同 `BLEPermission`。
 */
export class UserLocationProvider {
  private static readonly permissions: Permissions[] = [
    'ohos.permission.APPROXIMATELY_LOCATION',
    'ohos.permission.LOCATION'
  ];
  private static context: common.UIAbilityContext | null = null;

  static init(context: common.UIAbilityContext): void {
    UserLocationProvider.context = context;
  }

  /**
   * 取一次当前位置。没授权、超时、定位不可用都返回 null——这一页的距离读不到就整行
   * 不显示，不回退成假值。
   */
  static async current(): Promise<geoLocationManager.Location | null> {
    const context = UserLocationProvider.context;
    if (context === null) {
      DiagLog.note('[location] 还没拿到 context，跳过定位');
      return null;
    }
    try {
      const result = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(context, UserLocationProvider.permissions);
      // 两条要一起给：只给模糊定位（APPROXIMATELY）时精确那条会是 -1，
      // 但模糊定位也够算「离车多远」，所以只要有一条通过就往下走。
      const granted = result.authResults.some((code: number) => code === 0);
      if (!granted) {
        DiagLog.note('[location] 用户没有授予定位权限');
        return null;
      }
    } catch (e) {
      DiagLog.note(`[location] 申请定位权限失败：${LeapError.messageOf(e as object)}`);
      return null;
    }
    try {
      const request: geoLocationManager.SingleLocationRequest = {
        // 要的是「离车多远」这个量级，不是导航精度。先拿到再说，别让人对着「定位中」等。
        locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_LOCATING_SPEED,
        locatingTimeoutMs: 8000
      };
      return await geoLocationManager.getCurrentLocation(request);
    } catch (e) {
      DiagLog.note(`[location] 定位失败：${LeapError.messageOf(e as object)}`);
      return null;
    }
  }

  /** 两点间直线距离（米）。半正矢公式。两个点必须是同一套坐标系，调用方自己保证。 */
  static distanceMeters(fromLat: number, fromLng: number, toLat: number, toLng: number): number {
    const earthRadius = 6371000;
    const toRad = (deg: number): number => deg * Math.PI / 180;
    const dLat = toRad(toLat - fromLat);
    const dLng = toRad(toLng - fromLng);
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
      + Math.cos(toRad(fromLat)) * Math.cos(toRad(toLat)) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return earthRadius * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  }

  /** 和 iOS 的 `formatDistance` 同一套口径：一公里以内报米，超过报公里。 */
  static formatDistance(meters: number): string {
    return meters < 1000
      ? `约 ${Math.round(meters)} 米`
      : `约 ${(meters / 1000).toFixed(1)} 公里`;
  }
}
