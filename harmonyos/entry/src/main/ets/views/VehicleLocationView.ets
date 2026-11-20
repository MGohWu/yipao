import { HdsNavDestination, HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { MapComponent } from '@hms.core.map.MapComponent';
import { map, mapCommon, navi, petalMaps } from '@kit.MapKit';
import { geoLocationManager } from '@kit.LocationKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { UserLocationProvider } from '../app/UserLocationProvider';
import { LeapError } from '../core/LeapError';
import { SafeAreaInsets } from '../app/SafeAreaInsets';
import { DiagLog } from '../core/DiagLog';
import { LeapBackground } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { HomeView } from './HomeView';

/**
 * 车辆位置页。用华为地图的 `MapComponent`（完整可交互地图），
 * 首页那张缩略图走的是同一套地图服务的静态图接口。
 *
 * 导航交给「花瓣地图」：`petalMaps.openMapRoutePlan` 拉起系统地图应用做路线规划，
 * 对应 iOS 的 `MKMapItem.openInMaps`。车通常停在步行可达的地方，所以给步行路线。
 *
 * 注意：地图要在 AGC 里配好本应用的 client_id 且签名指纹匹配才出图。
 * 没配好时地图区域是空白，下面那张信息卡仍然可用。
 */
/**
 * 「导航到车辆」能拉起哪几家地图。iOS 那边是同一份清单（`AvailableMapApp`）。
 * `petal` 是华为自带的花瓣地图，走 Map Kit 接口，不靠 scheme，所以永远在列。
 */
enum MapChoice {
  petal,
  amap,
  baidu,
  tencent
}

@ComponentV2
export struct VehicleLocationView {
  // 必须 @Local 持有，下面那个 @Monitor 才监听得到——普通成员做监听路径的根时，
  // 编译期只给一条警告，运行期彻底不触发。同 `Index.ets` 那条。
  @Local store: VehicleStore = vehicleStore;
  /**
   * 手机自己的位置，**WGS-84 原样**。取一次，取不到就一直是 null，两个距离照实说取不到。
   *
   * 只喂给 `setMyLocation`——那个接口收的就是 LocationKit 原封不动的 `Location`，
   * 偏移由地图自己加。别的地方一律用下面那个 `userPoint`。
   */
  @Local userLocation: geoLocationManager.Location | null = null;
  /**
   * 上面那个位置转成 **GCJ-02** 之后的样子。距离、相机、路线服务都用这个。
   *
   * 鸿蒙的 `geoLocationManager` 返回的是 WGS-84，车端上报的却是 GCJ-02——两边差着
   * 一个偏移。实测人站在车边时：不转算出来 838 米，转了是 290 米。
   * 「直线距离」一直虚报了五百多米，「回到我的位置」也是因此对不准。
   */
  @Local userPoint: mapCommon.LatLng | null = null;
  @Local locationDenied: boolean = false;
  /** 驾车距离和时长。null 表示还没算出来，配合 `drivingUnavailable` 区分「在算」和「算不出」。 */
  @Local drivingDistance: number | null = null;
  @Local drivingMinutes: number | null = null;
  @Local drivingUnavailable: boolean = false;
  @Local parkingImage: image.PixelMap | null = null;
  @Local parkingUploadTime: string = '';
  @Local isLoadingParkingPhoto: boolean = false;
  @Local isShowingParkingPhoto: boolean = false;
  @Local isShowingMapChoices: boolean = false;
  /** 点开选择面板那一刻算出来的候选。别放 getter 里——每帧都去查一遍包管理器。 */
  @Local mapChoices: MapChoice[] = [];
  /** 大图的缩放和位移。手势结束才落到这两个上，进行中的增量在下面两个 @Local 里。 */
  @Local photoScale: number = 1;
  @Local photoOffsetX: number = 0;
  @Local photoOffsetY: number = 0;
  private photoScaleBase: number = 1;
  private photoOffsetBaseX: number = 0;
  private photoOffsetBaseY: number = 0;
  private controller: map.MapComponentController | null = null;
  private marker: map.Marker | null = null;
  /** 上一次把相机对准的坐标。没变就不动相机，免得把用户刚拖到的视野拽回去。 */
  private cameraKey: string = '';
  /** 上一次算过驾车距离的「人+车」组合，没变就不再问一次路线服务。 */
  private metricsKey: string = '';

  /** 车还没上报坐标就导航不了。配色和 `enabled` 用的是同一个判断。 */
  private get canNavigate(): boolean {
    return this.store.coordinate !== null;
  }

  private mapOptions: mapCommon.MapOptions = {
    position: {
      target: { latitude: 39.9, longitude: 116.4 },
      // 16 级差不多是「一个小区」的视野，能看清车停在哪条路上。
      zoom: 16
    },
    // 必须是平面地图。3D 建筑图层在没有数据覆盖的地方（国内只有大城市有）
    // 会整屏只剩空瓦片网格，等多久都不出图。
    mapType: mapCommon.MapType.STANDARD
  };

  private callback: AsyncCallback<map.MapComponentController> =
    async (err: BusinessError, controller: map.MapComponentController) => {
      if (err) {
        DiagLog.note(`[map] 地图初始化失败：${err.code} ${err.message}`);
        return;
      }
      this.controller = controller;
      // 缩放和指南针按钮都关掉：进页面就已经对准车了，坐标一变也会自己跟过去，
      // 地图上不需要再摆一排控件。
      controller.setZoomControlsEnabled(false);
      controller.setCompassControlsEnabled(false);
      controller.setDayNightMode(mapCommon.DayNightMode.AUTO);
      // 定位可能比地图先好，也可能后好，两边都调一次，谁后到谁生效。
      this.applyMyLocation();
      await this.syncToCoordinate(true);
    };

  aboutToAppear(): void {
    this.resolveName();
    this.startUserLocation();
    this.loadParkingPhoto();
  }

  aboutToDisappear(): void {
    // PixelMap 拿的是解码后的整张位图，不主动放要等 GC。
    this.parkingImage?.release();
    this.parkingImage = null;
  }

  /**
   * 监听 `store.state` 而不是 `store.coordinate`：`coordinate` 是个普通 getter
   * （转发 `state.shareableCoordinate`），`@Monitor` 只认显式标了 `@Trace` 的字段。
   *
   * 连同上面 `store` 的 `@Local`，这两处原来都不成立，于是这个回调从来没被调过：
   * 进页面时相机是对得准的（`onMapReady` 里那次 `syncToCoordinate(true)` 是好的），
   * 之后车再动地图就不跟了，退出重进才刷新。
   *
   * iOS 那边同一段逻辑是成立的（`VehicleLocationView.swift` 的
   * `.onChange(of: CoordinateKey(coordinate))`）：SwiftUI 追踪 getter 内部真正读到的
   * 属性，计算属性穿得过去。同源两份代码，这类差异不会有人提醒。
   *
   * `state` 每次刷车况都换一个新对象，触发比坐标变化频繁，但两个动作都自带去重：
   * `syncToCoordinate` 比 `cameraKey`，`resolveName` 看 `locationName` 空不空。
   */
  @Monitor('store.state')
  onCoordinateChanged(): void {
    this.resolveName();
    this.syncToCoordinate(false);
    // 车动了驾车距离就变了。`refreshDrivingMetrics` 自己比 `metricsKey` 去重，
    // 车况刷新但坐标没变时不会真去问路线服务。
    this.refreshDrivingMetrics();
  }

  private resolveName(): void {
    if (this.store.coordinate !== null && this.store.locationName.length === 0) {
      this.store.resolveLocationName();
    }
  }

  /** 把车的标记和相机对到当前坐标上。`initial` 时不做动画，直接落位。 */
  private async syncToCoordinate(initial: boolean): Promise<void> {
    const controller = this.controller;
    const coordinate = this.store.coordinate;
    if (controller === null || coordinate === null) {
      return;
    }
    const key = `${coordinate.latitude.toFixed(6)},${coordinate.longitude.toFixed(6)}`;
    if (key === this.cameraKey) {
      return;
    }
    this.cameraKey = key;
    const position: mapCommon.LatLng = {
      latitude: coordinate.latitude,
      longitude: coordinate.longitude
    };
    try {
      if (this.marker === null) {
        this.marker = await controller.addMarker({
          position: position,
          title: this.store.vehicleName,
          clickable: true
        });
      } else {
        this.marker.setPosition(position);
      }
      const update = map.newCameraPosition({ target: position, zoom: 16 });
      if (initial) {
        controller.animateCamera(update, 0);
      } else {
        controller.animateCamera(update, 400);
      }
    } catch (e) {
      DiagLog.note(`[map] 更新车辆标记失败：${e}`);
    }
  }

  /**
   * 取一次手机位置：地图上那个蓝点，以及下面两个距离。
   *
   * 权限弹窗就在这时候弹——进这一页才问，别的页面完全不碰定位。用户不给就把
   * `locationDenied` 立起来，两个距离直说「未授权定位」，不摆一个永远转不完的「定位中」。
   */
  private async startUserLocation(): Promise<void> {
    const location = await UserLocationProvider.current();
    if (location === null) {
      this.locationDenied = true;
      return;
    }
    this.userLocation = location;
    // 定位给的是 WGS-84，这一页别的东西（车的坐标、相机、路线服务）全是 GCJ-02，
    // 所以在入口转一次，后面统一用 `userPoint`。见字段上那段注释。
    this.userPoint = map.convertCoordinateSync(mapCommon.CoordinateType.WGS84,
      mapCommon.CoordinateType.GCJ02, { latitude: location.latitude, longitude: location.longitude });
    // 地图那层要 app 主动喂位置，光 setMyLocationEnabled 不会自己去定位。
    this.applyMyLocation();
    this.refreshDrivingMetrics();
  }

  /**
   * 标题栏那两个钮：把相机挪回车、或挪回自己。
   *
   * 不用 SDK 自带的「回到我的位置」圆钮——它固定钉在右下角，压在信息卡旁边，
   * 位置改不了（SDK 只给开关不给坐标），跟 iOS 那页也对不上。iOS 把这两个钮
   * 放在导航栏右上角，这里照做。
   *
   * 别在这里清 `cameraKey`：那个键记的是「相机已经对准过这个车辆坐标」，清掉之后
   * 下一次车况刷新（`@Monitor('store.state')` 每轮都会触发）会立刻把镜头拽回车上，
   * 人刚按的「回到我的位置」当场就被抵消。车真挪了键自然就不一样，照样跟得上。
   */
  private focusVehicle(): void {
    const controller = this.controller;
    const coordinate = this.store.coordinate;
    if (controller === null || coordinate === null) {
      return;
    }
    controller.animateCamera(map.newCameraPosition({
      target: { latitude: coordinate.latitude, longitude: coordinate.longitude },
      zoom: 16
    }), 400);
  }

  private focusUser(): void {
    const controller = this.controller;
    const point = this.userPoint;
    if (controller === null || point === null) {
      return;
    }
    controller.animateCamera(map.newCameraPosition({ target: point, zoom: 16 }), 400);
  }

  /** 把蓝点画到地图上。地图和定位谁先好都可能，所以两边好了都调一次。 */
  private applyMyLocation(): void {
    const controller = this.controller;
    const location = this.userLocation;
    if (controller === null || location === null) {
      return;
    }
    try {
      controller.setMyLocationEnabled(true);
      // 打开蓝点会连带把 SDK 自带的「回到我的位置」圆钮摆到右下角，
      // 压在信息卡旁边，跟 iOS 那页也不一样。只要蓝点，不要那个钮。
      controller.setMyLocationControlsEnabled(false);
      controller.setMyLocation(location);
    } catch (e) {
      DiagLog.note(`[map] 显示自身位置失败：${LeapError.messageOf(e as object)}`);
    }
  }

  /** 直线距离。两头都取 GCJ-02（人的那头已经在 `startUserLocation` 里转过）。 */
  private get straightDistanceText(): string {
    const coordinate = this.store.coordinate;
    const point = this.userPoint;
    if (coordinate === null || point === null) {
      return this.locationDenied ? '未授权定位' : '定位中';
    }
    return UserLocationProvider.formatDistance(UserLocationProvider.distanceMeters(
      point.latitude, point.longitude, coordinate.latitude, coordinate.longitude));
  }

  private get drivingDistanceText(): string {
    const distance = this.drivingDistance;
    if (distance === null) {
      if (this.userPoint === null) {
        return this.locationDenied ? '未授权定位' : '定位中';
      }
      return this.drivingUnavailable ? '暂不可用' : '计算中';
    }
    const minutes = this.drivingMinutes;
    const text = UserLocationProvider.formatDistance(distance);
    return minutes === null ? text : `${text} · ${minutes} 分钟`;
  }

  /**
   * 问一次路线服务要驾车距离和时长。
   *
   * 用 `getDrivingMatrix` 而不是 `getDrivingRoutes`：这里只要一个数字，
   * 矩阵接口不回传整条路线的折线点，省一大截。对应 iOS 的 `MKDirections.calculate`。
   *
   * 拿不到就是拿不到（超服务范围、路线服务不可用、跨海），显示「暂不可用」，
   * 上面那条直线距离照常给——那条是自己算的，不依赖任何服务。
   */
  private async refreshDrivingMetrics(): Promise<void> {
    const coordinate = this.store.coordinate;
    const point = this.userPoint;
    if (coordinate === null || point === null) {
      return;
    }
    const key = `${point.latitude.toFixed(4)},${point.longitude.toFixed(4)}`
      + `>${coordinate.latitude.toFixed(6)},${coordinate.longitude.toFixed(6)}`;
    if (key === this.metricsKey) {
      return;
    }
    this.metricsKey = key;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const params: navi.DrivingMatrixParams = {
        origins: [{ latitude: point.latitude, longitude: point.longitude }],
        destinations: [{ latitude: coordinate.latitude, longitude: coordinate.longitude }]
      };
      const result = await navi.getDrivingMatrix(context, params);
      const cell = result.rows.length > 0 && result.rows[0].cells.length > 0
        ? result.rows[0].cells[0] : null;
      const distance = cell?.distance ?? null;
      if (cell === null || distance === undefined || distance === null) {
        this.drivingUnavailable = true;
        return;
      }
      this.drivingDistance = distance;
      const duration = cell.duration;
      this.drivingMinutes = duration === undefined ? null : Math.round(duration / 60);
      this.drivingUnavailable = false;
    } catch (e) {
      DiagLog.note(`[map] 驾车距离算不出来：${LeapError.messageOf(e as object)}`);
      this.drivingDistance = null;
      this.drivingMinutes = null;
      this.drivingUnavailable = true;
    }
  }

  /**
   * 拉最近一张驻车照片。
   *
   * 失败、没照片都只是不显示，不打扰——这里是位置页的附加信息，读不到就当没有，
   * 报错留给功能中心那页说。同 iOS 的 `loadParkingPhoto`。
   */
  private async loadParkingPhoto(): Promise<void> {
    if (this.store.isDemo) {
      return;
    }
    this.isLoadingParkingPhoto = true;
    let source: image.ImageSource | null = null;
    try {
      const result = await this.store.loadParkingPhoto();
      const data = result.data;
      if (data === null) {
        return;
      }
      source = image.createImageSource(data);
      this.parkingImage = await source.createPixelMap();
      this.parkingUploadTime = result.photo.displayUploadTime ?? '';
    } catch (e) {
      DiagLog.note(`[map] 驻车照片读取失败：${LeapError.messageOf(e as object)}`);
      this.parkingImage = null;
      this.parkingUploadTime = '';
    } finally {
      source?.release();
      this.isLoadingParkingPhoto = false;
    }
  }

  private closePhotoViewer(): void {
    this.isShowingParkingPhoto = false;
    this.photoScale = 1;
    this.photoOffsetX = 0;
    this.photoOffsetY = 0;
  }

  /**
   * 这台手机上能用的地图。花瓣地图永远在（系统自带，`petalMaps` 走的是 Map Kit 不是
   * scheme），其余三家按 `canOpenLink` 过滤——没装就整条不出现，不摆一个点了没反应的项。
   *
   * `canOpenLink` 要求 scheme 事先写进 `module.json5` 的 `querySchemes`，
   * 没写的直接抛 17700056，不是返回 false，所以这里整段包了 try。
   */
  private computeAvailableMaps(): MapChoice[] {
    const out: MapChoice[] = [MapChoice.petal];
    for (const choice of [MapChoice.amap, MapChoice.baidu, MapChoice.tencent]) {
      try {
        if (bundleManager.canOpenLink(`${VehicleLocationView.schemeOf(choice)}://`)) {
          out.push(choice);
        }
      } catch (e) {
        DiagLog.note(`[map] 查询 ${choice} 是否可用失败：${LeapError.messageOf(e as object)}`);
      }
    }
    return out;
  }

  private static schemeOf(choice: MapChoice): string {
    switch (choice) {
      case MapChoice.amap: return 'amapuri';
      case MapChoice.baidu: return 'baidumap';
      case MapChoice.tencent: return 'qqmap';
      default: return '';
    }
  }

  private static titleOf(choice: MapChoice): string {
    switch (choice) {
      case MapChoice.amap: return '高德地图';
      case MapChoice.baidu: return '百度地图';
      case MapChoice.tencent: return '腾讯地图';
      default: return '花瓣地图';
    }
  }

  /**
   * 各家收的都是 GCJ-02，坐标只有一份，谁都不转——但**每家声明坐标系的方式不一样**，
   * 逐个写死，别照抄别处的模板（同 iOS 的 `AvailableMapApp.url`）：
   * - 高德 `dev`：0 = 我给的是高德坐标（GCJ-02），1 = GPS 原始坐标（WGS-84）。
   * - 百度 `coord_type`：百度内部用 BD-09，靠这个参数说明输入是什么，它再转一次。
   *   填 `wgs84` 会让它在 GCJ-02 上又叠一次纠偏，落点偏出几百米。
   * - 腾讯 `tocoord`：默认就按 GCJ-02 收，不需要额外参数。
   *
   * 鸿蒙版高德的 scheme 是 `amapuri`（`bm dump` 实测），不是 iOS 那个 `iosamap`。
   */
  private static linkFor(choice: MapChoice, latitude: number, longitude: number, name: string): string {
    const encoded = encodeURIComponent(name);
    switch (choice) {
      case MapChoice.amap:
        return `amapuri://route/plan?dlat=${latitude}&dlon=${longitude}&dname=${encoded}&dev=0&t=0`;
      case MapChoice.baidu:
        return `baidumap://map/direction?destination=name:${encoded}|latlng:${latitude},${longitude}`
          + '&mode=driving&coord_type=gcj02';
      case MapChoice.tencent:
        return `qqmap://map/routeplan?type=drive&to=${encoded}&tocoord=${latitude},${longitude}`;
      default:
        return '';
    }
  }

  /** 拉起选中的地图规划到车辆的路线。 */
  private async navigate(choice: MapChoice): Promise<void> {
    const coordinate = this.store.coordinate;
    if (coordinate === null) {
      return;
    }
    this.isShowingMapChoices = false;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      if (choice === MapChoice.petal) {
        await petalMaps.openMapRoutePlan(context, {
          destinationPosition: { latitude: coordinate.latitude, longitude: coordinate.longitude },
          destinationName: this.store.vehicleName,
          // 车通常停在步行可达的地方，直接给步行路线。
          vehicleType: petalMaps.VehicleType.WALKING,
          // 车端上报的是 GCJ-02（国测局坐标），不声明的话会被当成 WGS-84 偏出去几百米。
          coordinateType: mapCommon.CoordinateType.GCJ02
        });
        return;
      }
      await context.openLink(VehicleLocationView.linkFor(
        choice, coordinate.latitude, coordinate.longitude, this.store.vehicleName));
    } catch (e) {
      this.store.showError(new Error(`无法打开地图应用：${e}`));
    }
  }

  /**
   * 标题栏右上角：回到车辆 / 回到我的位置。没定位到就只剩前一个——
   * 摆一个按下去没地方可去的钮，比不摆更糟。
   */
  private titleBarMenu(): HdsNavigationMenuItemOptions[] {
    const items: HdsNavigationMenuItemOptions[] = [{
      content: {
        icon: new SymbolGlyphModifier($r('sys.symbol.car_fill')),
        label: '回到车辆',
        action: () => {
          this.focusVehicle();
        }
      }
    }];
    if (this.userPoint !== null) {
      items.push({
        content: {
          icon: new SymbolGlyphModifier($r('sys.symbol.location_up_fill')),
          label: '回到我的位置',
          action: () => {
            this.focusUser();
          }
        }
      });
    }
    return items;
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.store.coordinate !== null) {
          MapComponent({ mapOptions: this.mapOptions, mapCallback: this.callback })
            .width('100%')
            .height('100%')
        } else {
          LeapBackground({ tint: LeapColors.coolGlow })
          this.unavailable()
        }

        // 信息卡自己不带边距：它铺满 Stack 的宽度，边距由这层给。
        // 卡片上直接写 margin 会连同 100% 的宽度一起算，总宽超出屏幕反而更贴边。
        Column() {
          this.infoCard()
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 14 + SafeAreaInsets.shared.bottom })

        if (this.isShowingMapChoices) {
          this.mapChooser()
        }

        if (this.isShowingParkingPhoto && this.parkingImage !== null) {
          this.photoViewer()
        }
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      style: LeapMaterial.navigationTitleBarStyle(),
      content: {
        title: { mainTitle: '车辆位置' },
        menu: { value: this.titleBarMenu() }
      },
      // 默认是 false，标题栏会直接压在状态栏上，返回键和系统时间叠成一团。
      avoidLayoutSafeArea: true
    })
  }


  @Builder
  unavailable() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.map_slash'))
        .fontSize(44)
        .fontColor([LeapStyle.textTertiary])
      Text('暂无车辆位置')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textPrimary)
      Text(this.store.state?.privacyGPSAllowed === false
        ? '车辆已开启位置隐私模式，App 无法获取坐标。'
        : '车况里还没有上报经纬度，稍后再试。')
        .fontSize(13)
        .fontColor(LeapStyle.textSecondary)
        .textAlign(TextAlign.Center)
        .padding({ left: 40, right: 40 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  infoCard() {
    Column({ space: 12 }) {
      // 左文右图：地址、时间、两个距离在左边竖着排，右边一张竖着的驻车照片。
      // 车主拍驻车位置基本都是竖着拍的，铺满整卡宽度横切一刀就只剩中间一条，
      // 看不出停在哪个位置；竖图配竖图，占的宽度还更小。iOS 那边同一个版式。
      Row({ space: 12 }) {
        Column({ space: 12 }) {
          Text(this.store.locationName.length > 0 ? this.store.locationName : '正在解析位置')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.store.lastUpdated > 0) {
            // freshnessText 自己就带「车况…更新于」，外面再套一层「更新于」会读成
            // 「更新于 车况刚刚更新」。
            Text(HomeView.freshnessText(this.store.reportedAt, this.store.lastUpdated))
              .fontSize(12)
              .fontColor(LeapStyle.textSecondary)
          }

          Row({ space: 16 }) {
            this.straightMetric()
            this.drivingMetric()
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        this.parkingPhotoThumb()
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 10 }) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.arrowshape_turn_up_right'))
            .fontSize(15)
            .fontColor([this.canNavigate ? LeapStyle.cool : LeapStyle.textDisabled])
          Text('导航到车辆')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.canNavigate ? LeapStyle.cool : LeapStyle.textDisabled)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ top: 13, bottom: 13 })
        .borderRadius(LeapStyle.tileRadius)
        // 外层面板已经是一整块系统材质，按钮再糊一层就成了浮在面板上的白块。
        // 没坐标时不上蓝色垫、文字转灰，不再靠 `.opacity(0.45)` 变淡——
        // 那样蓝字会被拉到 2:1 以下。
        .backgroundColor(this.canNavigate ? LeapStyle.fillCool : LeapStyle.fillNeutral)
        .visualEffect(LeapMaterial.pressable)
        .enabled(this.canNavigate)
        .onClick(() => {
          this.mapChoices = this.computeAvailableMaps();
          // 只有花瓣地图一家就别弹了，多一步纯是打扰。
          if (this.mapChoices.length <= 1) {
            this.navigate(MapChoice.petal);
            return;
          }
          this.isShowingMapChoices = true;
        })

        Row() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor([LeapStyle.textPrimary])
        }
        .width(46)
        .justifyContent(FlexAlign.Center)
        .padding({ top: 13, bottom: 13 })
        .borderRadius(LeapStyle.tileRadius)
        .backgroundColor(LeapStyle.fillNeutral)
        .visualEffect(LeapMaterial.pressable)
        .onClick(() => {
          this.store.refresh(true);
        })
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(18)
    .borderRadius(28)
    .backgroundEffect(LeapMaterial.panelEffect)
  }

  /**
   * 两个距离指标。拆成两个无参 @Builder：带值参数的 @Builder 只算第一次，
   * 定位回来了文字也不会跟着变（同 `HomeView` 那两条能量条）。
   */
  @Builder
  straightMetric() {
    Column({ space: 3 }) {
      Text('直线距离')
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)
      Text(this.straightDistanceText)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  drivingMetric() {
    Column({ space: 3 }) {
      Text('驾车距离')
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)
      Text(this.drivingDistanceText)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  /**
   * 右边那张驻车照片。按原比例装进 78×104 的框，`Contain` 不裁。
   *
   * 上传时间不往这么小的图上压，挪到点开的大图里去说。没解锁、演示模式、这台车没照片，
   * 整块都不出现——位置卡对这些人保持原样，不摆空占位也不摆上锁提示。
   */
  @Builder
  parkingPhotoThumb() {
    if (this.parkingImage !== null) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.parkingImage)
          .objectFit(ImageFit.Contain)
          .width(VehicleLocationView.thumbWidth)
          .height(VehicleLocationView.thumbHeight)
        Row() {
          SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
            .fontSize(12)
            .fontColor([LeapStyle.textPrimary])
        }
        .padding(5)
        .borderRadius(20)
        .backgroundColor(LeapStyle.fillNeutral)
        .margin(5)
      }
      .width(VehicleLocationView.thumbWidth)
      .height(VehicleLocationView.thumbHeight)
      .borderRadius(12)
      .clip(true)
      .backgroundColor(LeapStyle.fillNeutral)
      .visualEffect(LeapMaterial.pressable)
      .onClick(() => {
        this.isShowingParkingPhoto = true;
      })
      .accessibilityText('驻车照片')
      .accessibilityDescription('点两下查看大图')
    } else if (this.isLoadingParkingPhoto) {
      // 拉取期间先占住这块，出图时左边那列的宽度不会跳一下。
      Row() {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(LeapStyle.textTertiary)
      }
      .width(VehicleLocationView.thumbWidth)
      .height(VehicleLocationView.thumbHeight)
      .justifyContent(FlexAlign.Center)
      .borderRadius(12)
      .backgroundColor(LeapStyle.fillNeutral)
    }
  }

  /**
   * 地图选择面板。自己画而不是用 `bindSheet`：`bindSheet` 只能挂在根节点上、
   * 一个节点一个，这页的根已经被别处占了（同 `pages/Index.ets` 里那条注释）。
   */
  @Builder
  mapChooser() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 点空白处关掉。这层要铺满整屏，否则手指落在面板以外没人接。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.isShowingMapChoices = false;
        })

      Column({ space: 2 }) {
        Text('选择地图')
          .fontSize(13)
          .fontColor(LeapStyle.textSecondary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 6, bottom: 10 })

        ForEach(this.mapChoices, (choice: MapChoice) => {
          Text(VehicleLocationView.titleOf(choice))
            .fontSize(16)
            .fontColor(LeapStyle.cool)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 14, bottom: 14 })
            .borderRadius(LeapStyle.tileRadius)
            .backgroundColor(LeapStyle.fillNeutral)
            .visualEffect(LeapMaterial.pressable)
            .onClick(() => {
              this.navigate(choice);
            })
        }, (choice: MapChoice) => choice.toString())

        Text('取消')
          .fontSize(16)
          .fontColor(LeapStyle.textPrimary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .borderRadius(LeapStyle.tileRadius)
          .backgroundColor(LeapStyle.fillNeutral)
          .visualEffect(LeapMaterial.pressable)
          .margin({ top: 8 })
          .onClick(() => {
            this.isShowingMapChoices = false;
          })
      }
      .width('100%')
      .padding(14)
      .borderRadius(28)
      .backgroundEffect(LeapMaterial.panelEffect)
      .margin({ left: 14, right: 14, bottom: 14 + SafeAreaInsets.shared.bottom })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 驻车照片全屏查看。捏合放大看细节（停在几号车位、旁边是什么），缩回 1 倍以下就弹回贴边。
   *
   * 铺在整页最上层而不是弹一个 Dialog：Dialog 会被标题栏和安全区一起缩进去，
   * 一张竖图剩不下多少。
   */
  @Builder
  photoViewer() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.parkingImage)
        .objectFit(ImageFit.Contain)
        .width('100%')
        .height('100%')
        .scale({ x: this.photoScale, y: this.photoScale })
        .translate({ x: this.photoOffsetX, y: this.photoOffsetY })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.photoScaleBase = this.photoScale;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.photoScale = Math.max(1, Math.min(4, this.photoScaleBase * event.scale));
              })
              .onActionEnd(() => {
                // 缩回原尺寸时把平移一并归零，否则会停在一个既小又偏出屏幕的位置。
                if (this.photoScale <= 1) {
                  this.photoOffsetX = 0;
                  this.photoOffsetY = 0;
                }
              }),
            PanGesture()
              .onActionStart(() => {
                this.photoOffsetBaseX = this.photoOffsetX;
                this.photoOffsetBaseY = this.photoOffsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                // 原尺寸下没有可平移的余量，拖了只会把图拽出屏幕。
                if (this.photoScale <= 1) {
                  return;
                }
                this.photoOffsetX = this.photoOffsetBaseX + event.offsetX;
                this.photoOffsetY = this.photoOffsetBaseY + event.offsetY;
              })
          )
        )

      Row() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor([Color.White])
      }
      .padding(10)
      .borderRadius(24)
      .backgroundColor('#33FFFFFF')
      .margin({ top: 12 + SafeAreaInsets.shared.top, right: 16 })
      .align(Alignment.TopEnd)
      .onClick(() => {
        this.closePhotoViewer();
      })
      .accessibilityText('关闭')

      if (this.parkingUploadTime.length > 0) {
        Text(this.parkingUploadTime)
          .fontSize(13)
          .fontColor(Color.White)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .borderRadius(8)
          .backgroundColor('#33FFFFFF')
          .margin({ bottom: 24 + SafeAreaInsets.shared.bottom })
          .align(Alignment.Bottom)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  private static readonly thumbWidth: number = 78;
  private static readonly thumbHeight: number = 104;
}
