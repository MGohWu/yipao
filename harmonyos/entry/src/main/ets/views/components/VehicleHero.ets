import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { CarLayerComposer } from '../../core/CarLayerComposer';
import { CarModel3DView } from './CarModel3DView';
import { VehicleSilhouette } from './VehicleSilhouette';

/**
 * 车辆主视觉。
 *
 * 三层回退：能渲 3D 就渲 3D，其次按车况叠出来的官方车图，最后才是剪影。
 */
@ComponentV2
export struct VehicleHero {
  // 必须 @Local 持有，下面两个 @Monitor 才监听得到——普通成员做监听路径的根时，
  // 编译期只给一条警告，运行期彻底不触发。同 `Index.ets` 那条。
  @Local store: VehicleStore = vehicleStore;

  @Builder
  defaultBadges() {
  }

  @BuilderParam badges: () => void = this.defaultBadges;

  /** 3D 首帧出来之前先盖着占位图，避免露出一块空白的画布。 */
  @Local is3DReady: boolean = false;
  /** 3D 渲不出来（车型资源不全、WebGL 挂了）就别再试，安心用 2D。 */
  @Local is3DFailed: boolean = false;
  /** 充电动画当前帧。 */
  @Local chargeFrame: number = 0;
  private chargeTimer: number = -1;

  /**
   * 车辆主视觉的基准尺寸，由首页按可用高度算好传进来。
   *
   * 写死过 106：那会儿首页想在一屏里放下车、控车条、车况卡和地图卡四块。
   * 现在跟 iOS 一样按屏高取，长屏上车能长大去占那块空白，而不是让空白
   * 在车的上下各留一块。
   */
  @Param heroSize: number = 132;

  /**
   * 2D 车图的高度上限，相对 `heroSize`。
   *
   * 官方图层是 1125×525（2.14:1），按宽度铺满一行需要的高度比 1.35 给得多——
   * 1.35 会把图缩到只占大半行宽，两侧各空一截，图层边缘那圈羽化过的痕迹
   * 落在画面中间偏内的位置，比贴着屏幕边还显眼。
   *
   * 上限没有直接去掉：画布更方的车型（同一个包里就有 1125×1200 的图层）
   * 不设限会长到把下面的卡片顶下去。
   */
  private static readonly staticHeightRatio: number = 1.8;

  /**
   * 3D 画布的高度，相对 `heroSize`。
   *
   * 比 2D 那套矮一点，但比 1.35 高：模型转到某些角度（车头朝下那侧）
   * 下沿会顶出画布被切掉。车本身的大小靠 `radius`（相机距离）调，不靠撑画布。
   */
  private static readonly modelHeightRatio: number = 1.62;

  /** 官方图层的宽高比（1125×525）。 */
  private static readonly layerAspect: number = 1125 / 525;

  /** 这块舞台有多宽。图按宽度铺满，高度得从它算出来。 */
  @Local stageWidth: number = 0;

  /**
   * 车图那块画布的高度。
   *
   * ArkUI 的 `Image` 在没有高度约束的父容器里**不会**按宽高比把自己撑出来，
   * 高度必须由外面给。给多了车就悬在一片空白中间，给少了车顶被裁掉——
   * 两种都实测见过。所以按「铺满这一行需要多高」算，再用 `staticHeightRatio`
   * 封住上限（画布更方的车型不封会把下面的卡片顶下去）。
   *
   * 3D 在场时按它自己那块画布来：模型要的取景余量和 2D 图不是一回事。
   */
  private get stageHeight(): number {
    if (this.shows3D) {
      return this.heroSize * VehicleHero.modelHeightRatio;
    }
    const byWidth = this.stageWidth > 0
      ? this.stageWidth / VehicleHero.layerAspect
      : this.heroSize * 1.35;
    return Math.min(this.heroSize * VehicleHero.staticHeightRatio, byWidth);
  }

  @Monitor('store.carModelRoot')
  onRootChanged(): void {
    // 资源被撤走或换成另一台车的目录时必须把就绪/失败位清掉：
    // 不清的话占位那层会一直全透明——剪影明明在层里却什么都看不见。
    this.is3DReady = false;
    this.is3DFailed = false;
  }

  /**
   * 图层方案变了就重起动画。方案没变时 store 不会换对象，
   * 这个回调也就不触发——充电动画因此能一直连着播，不会每五秒跳回第一帧。
   */
  @Monitor('store.carLayerPlan')
  onLayerPlanChanged(): void {
    this.chargeFrame = 0;
    this.restartChargeAnimation();
  }

  aboutToAppear(): void {
    this.restartChargeAnimation();
  }

  aboutToDisappear(): void {
    this.stopChargeAnimation();
  }

  private restartChargeAnimation(): void {
    this.stopChargeAnimation();
    const frames = this.store.carLayerPlan.chargeFrames.length;
    // 只有一帧是静态图（插枪待机、已充满），不用起定时器。
    if (frames <= 1 || !this.showsLayers) {
      return;
    }
    this.chargeTimer = setInterval(() => {
      this.chargeFrame = (this.chargeFrame + 1) % this.store.carLayerPlan.chargeFrames.length;
    }, CarLayerComposer.frameIntervalMs);
  }

  private stopChargeAnimation(): void {
    if (this.chargeTimer >= 0) {
      clearInterval(this.chargeTimer);
      this.chargeTimer = -1;
    }
  }

  private get shows3D(): boolean {
    return this.store.carModelRoot.length > 0
      && this.store.carModel !== null
      && this.store.carModel.modelParam !== null
      && !this.is3DFailed;
  }

  private get showsLayers(): boolean {
    return this.store.carLayerDirectory.length > 0 && !this.store.carLayerPlan.isEmpty;
  }

  build() {
    Column({ space: 14 }) {
      Stack() {
        // 占位一直垫在底下：3D 渲不出来时它就是最终画面，而不是留一块空白。
        this.staticVehicle()

        if (this.shows3D) {
          CarModel3DView({
            root: this.store.carModelRoot,
            param: this.store.carModel!.modelParam!,
            assetAlias: this.store.carAssetAlias,
            state: this.store.state,
            onReady: () => {
              this.is3DReady = true;
            },
            onFailure: () => {
              this.is3DFailed = true;
              this.is3DReady = false;
              // 资源可能是残缺的（缓存被回收了一半、包本身就缺文件）。
              // 交给 store 作废重下一次，成功了 carModelRoot 一变就会重来。
              this.store.repairCarModel();
            },
            // 3D 车的服务卡片车图只能从这里来，包里没有 2D 图层可叠。
            onSnapshot: (dataURL: string) => {
              this.store.adoptRenderedCarImage(dataURL);
            }
          })
            .width('100%')
            .height('100%')
            .opacity(this.is3DReady ? 1 : 0)
            .animation({ duration: 350, curve: Curve.EaseOut })
        }
      }
      .width('100%')
      .height(this.stageHeight)
      .onAreaChange((_old: Area, area: Area) => {
        this.stageWidth = Number(area.width);
      })

      this.badges()
    }
    .width('100%')
    // 车这块自己要留出呼吸：不留的话车顶贴着副标题、车尾贴着徽章和快控条。
    // 数值和安卓对齐（见 HomeScreen 里那块 Column），比 iOS 宽一档。
    .padding({ top: 16, bottom: 4 })
  }

  /** 按车况叠出来的官方车图，没有就退回剪影。也充当 3D 加载期间的占位。 */
  @Builder
  staticVehicle() {
    if (this.showsLayers) {
      this.layeredVehicle()
    } else {
      VehicleSilhouette({ carHeight: this.heroSize * 0.8 })
        .opacity(this.is3DReady ? 0 : 1)
    }
  }

  /**
   * 官方分层贴图。声明顺序就是 z 序，不做像素合成——
   * iOS 那版要合成是因为 SwiftUI 和小组件都只吃单张图，这边 Stack 天然分层。
   *
   * 图层是透明背景的宽幅图（1125×525），车本身只占中间一条。按高度约束会缩得很小，
   * 所以让它按宽度铺开，和官方 App 一样占满整行。图层里自带渲染好的接地阴影，
   * 外面不要再叠阴影。
   */
  @Builder
  layeredVehicle() {
    Stack() {
      ForEach(CarLayerComposer.paths(this.store.carLayerDirectory, this.store.carLayerPlan.below),
        (path: string) => {
          Image(path)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }, (path: string) => path)

      if (this.store.carLayerPlan.chargeFrames.length > 0) {
        Image(CarLayerComposer.path(this.store.carLayerDirectory,
          this.store.carLayerPlan.chargeFrames[
            this.chargeFrame % this.store.carLayerPlan.chargeFrames.length]))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
      }

      ForEach(CarLayerComposer.paths(this.store.carLayerDirectory, this.store.carLayerPlan.above),
        (path: string) => {
          Image(path)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }, (path: string) => path)
    }
    .width('100%')
    .height('100%')
    .opacity(this.is3DReady ? 0 : 1)
  }
}
