import { SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsNavigation, HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { LeapBackground } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { LoginView } from '../views/LoginView';
import { HomeView } from '../views/HomeView';
import { FeatureCenterView } from '../views/FeatureCenterView';
import { SettingsView } from '../views/SettingsView';
import { ClimateView } from '../views/ClimateView';
import { ChargeView } from '../views/ChargeView';
import { VehicleLocationView } from '../views/VehicleLocationView';
import { TripsView } from '../views/TripsView';
import { CalibrationView } from '../views/CalibrationView';
import { ControlDiagnosticView } from '../views/ControlDiagnosticView';
import { LegalDoc, LegalDocView } from '../views/LegalDocView';
import { BluetoothKeyView, WidgetSetupView } from '../views/features/AccessFeatureViews';
import { BLEPairingView, BluetoothKeySettingsView } from '../views/features/BluetoothKeyViews';
import { BLEDiagnosticView } from '../views/BLEDiagnosticView';
import { BatteryPreheatView, ChargePlanView } from '../views/features/EnergyFeatureViews';
import { ParkingPhotosView } from '../views/features/VehicleFeatureViews';
import { ComfortCabinView, FridgeView } from '../views/features/CabinFeatureViews';
import { ClimateAppointmentView } from '../views/ClimateAppointmentView';
import { LeapToast } from '../views/components/LeapToast';
import { OperationPasswordSheet } from '../views/components/OperationPasswordSheet';
import { WindowControlSheet } from '../views/components/WindowControlSheet';
import { TirePressureSheet } from '../views/components/TirePressureSheet';
import { TrunkControlSheet } from '../views/components/TrunkControlSheet';
import { TwoStateControlSheet, TwoStateControl } from '../views/components/TwoStateControlSheet';

/** 根页面上那张半屏当前装的是什么。 */
enum LeapSheet {
  windows,
  tires,
  trunk,
  sunshade,
  sunroof,
  frunk
}

/** 底部导航的三个一级页面。 */
export enum LeapTab {
  vehicle = 0,
  features = 1,
  settings = 2
}

/**
 * 根页面。
 *
 * 没登录就是登录页，登录了就是三个页签——中间不隔任何东西。
 *
 * 导航是两层：
 * - 一级页面（车辆 / 功能 / 设置）挂在官方的 `HdsTabs` 上，底栏用 `barFloatingStyle`
 *   的浮动形态，材质交给 `systemMaterialEffect`——系统自己的沉浸光感。
 * - 二级页（能源、空调、里程、位置、标定、蓝牙钥匙…）全部压在 `HdsNavigation` 的栈上。
 */
@Entry
@ComponentV2
struct Index {
  // 用 @Local 持有，下面那个 @Monitor 才监听得到 store 里的 @Trace 字段——
  // 普通成员做监听路径的根时，编译期只给一条警告，运行期是彻底不触发的。
  @Local store: VehicleStore = vehicleStore;
  @Local pathStack: NavPathStack = new NavPathStack();
  @Local selectedTab: number = LeapTab.vehicle;
  /**
   * `bootstrap` 跑完了没有。
   *
   * 会话恢复是异步的，恢复完成之前 `isLoggedIn` 一律是假。照它渲染的话，
   * 已经登录的人每次冷启动都会先看见半秒登录页。所以恢复完成之前两边都不画，
   * 只留一层背景。
   */
  @Local booted: boolean = false;
  /**
   * 车窗、胎压、尾门共用这一张半屏，而不是各挂各的。
   *
   * 两点都是踩出来的：
   * - 半屏必须挂在根节点上。挂在首页上时它弹出来约半秒就被拆掉——首页在
   *   TabContent 里，那棵子树重建频繁，半屏跟着一起没了。
   * - 同一个节点上只能有一张 `bindSheet`。挂两张时后挂的那张会把前一张顶掉，
   *   前一张的生命周期日志是 onWillAppear 紧跟着同一毫秒的 onWillDisappear，
   *   界面上就是「点了没反应」。所以这里用一个开关加一个类型，内容自己分支。
   */
  @Local showSheet: boolean = false;
  @Local sheetKind: LeapSheet = LeapSheet.windows;
  private tabsController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    this.store.loadPreferences();
    this.boot();
  }

  private async boot(): Promise<void> {
    await this.store.bootstrap();
    this.booted = true;
  }

  /** 退出登录之后回到登录页，路由栈和选中页都归零。 */
  @Monitor('store.loginEpoch')
  onLoginEpochChanged(): void {
    this.pathStack.clear();
    this.selectedTab = LeapTab.vehicle;
  }

  /** 卡片深链：一级页面切下标，其余推进栈里。 */
  @Monitor('store.pendingDeepLink')
  onDeepLink(): void {
    const link = this.store.pendingDeepLink;
    if (link.length === 0) {
      return;
    }
    this.store.pendingDeepLink = '';
    // 没登录时整棵树是登录页，没有页签也没有导航栈可推。桌面卡片是上一次登录时
    // 留下的，退出登录之后它还在桌面上——这条路走得到。
    if (!this.store.isLoggedIn) {
      return;
    }
    const tab = Index.tabOf(link);
    if (tab >= 0) {
      this.selectedTab = tab;
      return;
    }
    const route = Index.routeOf(link);
    if (route.length === 0) {
      return;
    }
    this.pathStack.pushPathByName(route, null, false);
  }

  private static tabOf(deepLink: string): number {
    switch (deepLink) {
      case 'vehicle':
      case 'home':
        return LeapTab.vehicle;
      case 'features':
        return LeapTab.features;
      case 'settings':
        return LeapTab.settings;
      default:
        return -1;
    }
  }

  /**
   * 深链名到路由名。
   *
   * 卡片和外部只认这几个老名字（能源 / 空调 / 里程原来还是页签），这里统一收敛。
   */
  private static routeOf(deepLink: string): string {
    switch (deepLink) {
      case 'charge':
      case 'climate':
      case 'location':
      case 'bluetoothKey':
        return deepLink;
      case 'mileage':
      case 'mileageStats':
        return 'mileage';
      default:
        return '';
    }
  }

  @Builder
  destination(name: string) {
    if (name === 'charge') {
      ChargeView({ onPush: this.pushRoute })
    } else if (name === 'climate') {
      ClimateView({ onPush: this.pushRoute })
    } else if (name === 'climateAppointment') {
      ClimateAppointmentView()
    } else if (name === 'mileage') {
      TripsView({ onPush: this.pushRoute })
    } else if (name === 'location') {
      VehicleLocationView()
    } else if (name === 'calibration') {
      CalibrationView()
    } else if (name === 'diagnostic') {
      ControlDiagnosticView()
    } else if (name === 'agreement') {
      LegalDocView({ doc: LegalDoc.userAgreement })
    } else if (name === 'privacy') {
      LegalDocView({ doc: LegalDoc.privacy })
    } else if (name === 'widgets') {
      WidgetSetupView()
    } else if (name === 'bluetoothKey') {
      BluetoothKeyView({ onPush: this.pushRoute })
    } else if (name === 'bluetoothKeySettings') {
      BluetoothKeySettingsView({ onPush: this.pushRoute })
    } else if (name === 'blePairing') {
      BLEPairingView({ onPush: this.pushRoute })
    } else if (name === 'bleDiagnostic') {
      // 和 iOS 一样：页面留着，入口在设置页里注释掉了，要用时把那一行放回来。
      BLEDiagnosticView()
    } else if (name === 'batteryPreheat') {
      BatteryPreheatView()
    } else if (name === 'chargePlan') {
      ChargePlanView()
    } else if (name === 'parkingPhotos') {
      // 功能页入口 2026-11-19 撤了（地图页位置卡上已有驻车照片），页面和路由先留着。
      ParkingPhotosView()
    } else if (name === 'comfortCabin') {
      ComfortCabinView()
    } else if (name === 'fridge') {
      FridgeView()
    }
  }

  build() {
    Stack() {
      HdsNavigation(this.pathStack) {
        if (!this.booted) {
          // 会话还在恢复：先只铺背景，别让已登录的人闪一下登录页。
          LeapBackground({ tint: LeapColors.coolGlow })
        } else if (this.store.isLoggedIn) {
          this.tabs()
        } else {
          LoginView()
        }
      }
      .hideTitleBar(true)
      .mode(NavigationMode.Stack)
      .navDestination(this.destination)

      // 提示与操作密码键盘常驻在最上层：控车流程从任何一页发起都要能弹出来。
      LeapToast()
      if (this.store.challenge !== null) {
        OperationPasswordSheet()
      }
    }
    .width('100%')
    .height('100%')
    // 高度写死，不用 FIT_CONTENT：内容自适应在这里算不出高度，半屏挂上了但高度是 0。
    // 标题交给系统的半屏标题栏，不再自己在内容里画一遍。
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: this.sheetHeight,
      dragBar: true,
      showClose: true,
      title: this.sheetTitle,
      onDisappear: () => {
        this.showSheet = false;
      }
    })
  }

  /**
   * 下面这几个回调都是稳定引用，不在 Builder 里现写闭包——
   * 现写的话每次重建都是一个新函数，框架判定入参变了就把整棵子树拆了重建。
   * 半屏尤其吃这一条：拆了就是「点了没反应」。
   */
  private readonly closeSheet: () => void = () => {
    this.showSheet = false;
  };
  private readonly pushRoute: (route: string) => void = (route: string) => {
    this.pathStack.pushPathByName(route, null, true);
  };
  private readonly openSheet: (name: string) => void = (name: string) => {
    if (name === 'tires') {
      this.sheetKind = LeapSheet.tires;
    } else if (name === 'trunk') {
      this.sheetKind = LeapSheet.trunk;
    } else if (name === 'sunshade') {
      this.sheetKind = LeapSheet.sunshade;
    } else if (name === 'sunroof') {
      this.sheetKind = LeapSheet.sunroof;
    } else if (name === 'frunk') {
      this.sheetKind = LeapSheet.frunk;
    } else {
      this.sheetKind = LeapSheet.windows;
    }
    this.showSheet = true;
  };

  /**
   * 半屏高度。写死，不用 FIT_CONTENT——内容自适应在这里算不出高度，半屏挂上了但高度是 0。
   * 尾门只有一行状态加一排按钮，按车窗那 360 开就是大半屏空白。
   */
  private get sheetHeight(): number {
    if (this.sheetKind === LeapSheet.tires) {
      return 420;
    }
    // 遮阳帘 / 天窗 / 前备箱和尾门一样：一行状态加一排按钮，照车窗那 360 开就是大半屏空白。
    if (this.sheetKind === LeapSheet.trunk || this.sheetKind === LeapSheet.sunshade
      || this.sheetKind === LeapSheet.sunroof || this.sheetKind === LeapSheet.frunk) {
      return 240;
    }
    return 360;
  }

  /** 标题交给系统的半屏标题栏，内容里不再自己画一遍。 */
  private get sheetTitle(): SheetTitleOptions {
    if (this.sheetKind === LeapSheet.tires) {
      return { title: '胎压' };
    }
    if (this.sheetKind === LeapSheet.trunk) {
      return { title: '尾门' };
    }
    if (this.sheetKind === LeapSheet.sunshade) {
      return { title: '遮阳帘' };
    }
    if (this.sheetKind === LeapSheet.sunroof) {
      return { title: '天窗' };
    }
    if (this.sheetKind === LeapSheet.frunk) {
      return { title: '前备箱' };
    }
    return { title: '车窗控制', subtitle: '两侧前窗同时调节' };
  }

  @Builder
  sheetContent() {
    if (this.sheetKind === LeapSheet.tires) {
      TirePressureSheet()
    } else if (this.sheetKind === LeapSheet.trunk) {
      TrunkControlSheet({ onClose: this.closeSheet })
    } else if (this.sheetKind === LeapSheet.sunshade) {
      TwoStateControlSheet({ control: TwoStateControl.sunshade, onClose: this.closeSheet })
    } else if (this.sheetKind === LeapSheet.sunroof) {
      TwoStateControlSheet({ control: TwoStateControl.sunroof, onClose: this.closeSheet })
    } else if (this.sheetKind === LeapSheet.frunk) {
      TwoStateControlSheet({ control: TwoStateControl.frunk, onClose: this.closeSheet })
    } else {
      WindowControlSheet({ onClose: this.closeSheet })
    }
  }

  @Builder
  tabs() {
    HdsTabs({ controller: this.tabsController, index: this.selectedTab }) {
      TabContent() {
        HomeView({
          onPush: this.pushRoute,
          onOpenSheet: this.openSheet
        })
      }
      .tabBar(Index.barItem($r('sys.symbol.car_fill'), '车辆'))

      TabContent() {
        FeatureCenterView({ onPush: this.pushRoute })
      }
      .tabBar(Index.barItem($r('sys.symbol.square_fill_grid_2x2'), '功能'))

      TabContent() {
        SettingsView({ onNavigate: this.pushRoute })
      }
      .tabBar(Index.barItem($r('sys.symbol.gearshape_fill'), '设置'))
    }
    // 浮动底栏压在内容之上，页面自己留出底部空当（见 PageMetrics.bottomInset）。
    .barOverlap(true)
    .barPosition(BarPosition.End)
    .vertical(false)
    .barFloatingStyle({
      barWidth: { smallWidth: 300, mediumWidth: 340, largeWidth: 380 },
      barBottomMargin: 22,
      // 材质交给系统：这就是沉浸光感官方开放的入口之一。
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .barMode(BarMode.Fixed)
    .scrollable(false)
    .animationDuration(0)
    .onChange((index: number) => {
      this.selectedTab = index;
    })
    .width('100%')
    .height('100%')
  }

  /**
   * 底栏一项。
   *
   * 选中用我们自己的主色——`ohos_id_color_activated` 是系统蓝，
   * 和这个 App 一身的绿凑一起不搭。
   *
   * 未选中原先走系统语义色（`ohos_id_color_bottom_tab_icon_off` / `_text_off`），
   * 按说系统色最稳妥，实测却是深色下量到 1.72:1，被上架检测点名。原因是那套色
   * 是照普通页面底设计的，而这里的页签条挂着 ADAPTIVE 系统材质，底比普通页面亮。
   * 系统色不达标也只能自己兜住，所以换成自己的值。
   */
  private static barItem(symbol: Resource, label: string): BottomTabBarStyle {
    return new BottomTabBarStyle({
      normal: new SymbolGlyphModifier(symbol)
        .fontColor([LeapStyle.tabOff]),
      selected: new SymbolGlyphModifier(symbol)
        .fontColor([LeapStyle.accent])
    }, label)
      .labelStyle({
        unselectedColor: LeapStyle.tabOff,
        selectedColor: LeapStyle.accent
      });
  }
}
