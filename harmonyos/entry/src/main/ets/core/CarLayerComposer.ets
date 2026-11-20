import { fileIo } from '@kit.CoreFileKit';
import { VehicleState } from './LeapModels';
import { VehicleSignal, CarTypeFamily } from './SignalSchema';

/**
 * 2D 车的分层贴图。
 *
 * 没有 3D 的车型（S01、C10…）在 `carpicture/key/package` 里给的不是模型，
 * 而是一整套 1125×525 的图层：车身打底，门、引擎盖、尾门、充电各一层，
 * 官方爱车页就是把它们按车况叠出来的——所以那张图会跟着车动。
 *
 * **叠加顺序不是猜的**，来自官方三处对照：
 * - `res/layout/lpcar_car_model.xml` —— RelativeLayout 子节点顺序就是 z 序
 * - `LPCarStateViewManager.OooO00o(state, iv1…iv15)` —— 谁在什么车况下显示、用哪张图
 * - `FragmentCarModelBinding` —— 把 iv1…iv15 和布局里的 view id 对上
 *
 * 对上之后才发现两件容易叠错的事：**右侧的门和尾门画在车身下面**（那一侧本来
 * 就被车身挡住），以及**充电层的 z 位置按车型不同**（官方在布局里备了三个槽）。
 *
 * 官方布局里还留着空调 ×3、轮毂、加热灯、行车灯六个 ImageView，但 1.22.87
 * 全 App 没有一行代码给它们 setImage——加密字符串表里连 `carpic_ac_*`、
 * `carpic_wheel*`、`carpic_frontrunning_*`、`carpic_heatlight_*` 都不存在。
 * 包里那些图是给别的版本备着的，我们也不叠，保持和官方一致。
 *
 * 和 iOS 那版的差别：那边要把图层合成成一张 UIImage（SwiftUI 和 WidgetKit 都要
 * 单张图），鸿蒙这边不合成——ArkUI 的 `Stack` 里按顺序摆几个 `Image` 就是同一个
 * z 序，声明顺序即层序。省掉整套像素合成，也省掉那份几十兆的位图内存。
 */

/**
 * 门窗规则的分组，对应 `CarStateViewController` 里的分支。
 *
 * 车型码取自 `CarDataUtil.sCarTypes`：s01 t03 a05 a10 b11 b10 b01 b05
 * c01 c11 c10 c16 d19 d21 d99。注意官方 `isC10Car()` 把 `b11` 也算 c10。
 */
enum DoorRule {
  /** C11 和所有未列名车型：四门齐全，不补窗层，尾门恒显示。 */
  fullDoors = 'fullDoors',
  /** c10 / b11 / c01 / c16 / b10 / b01：四门齐全，门关时补一层窗。 */
  fullDoorsWithWindows = 'fullDoorsWithWindows',
  /** t03：同上，但尾门只在开着时画。 */
  t03 = 't03',
  /** s01：两门轿跑，没有后门和后窗，尾门只在开着时画。 */
  s01 = 's01'
}

/**
 * 充电层的 z 槽位。官方在布局里备了三个，按车型选一个用——
 * 分组和门窗那套**不一样**（b01 门窗跟 c10，充电跟 c11）。
 */
enum ChargeSlot {
  /** `newchargingAnimate`：车身**下面**。c11 / c01 / b10 / b01 和未列名车型。 */
  belowBody = 'belowBody',
  /** `chargingAnimate`：车身上面、左后门下面。c16 / c10（含 b11）。 */
  aboveBody = 'aboveBody',
  /** `ivChargeAnimateOuter`：所有门之上。t03 / s01。 */
  aboveDoors = 'aboveDoors'
}

/**
 * 一次渲染要用到的图层，按 z 序从下往上分三段。
 *
 * 中间那段是充电动画：0 张表示不画，1 张是静态图，多张按 `frameIntervalMs`
 * 循环播放。分三段是因为充电层夹在中间——底和顶都是不动的，只有中间这段换帧。
 */
export class LayerPlan {
  below: string[] = [];
  chargeFrames: string[] = [];
  above: string[] = [];

  get isAnimated(): boolean {
    return this.chargeFrames.length > 1;
  }

  /** 方案有没有变。没变就不重建图层，避免充电动画每次刷新都从第一帧跳回去。 */
  get signature(): string {
    return `${this.below.join('|')}#${this.chargeFrames.join('|')}#${this.above.join('|')}`;
  }

  get isEmpty(): boolean {
    return this.below.length === 0 && this.chargeFrames.length === 0 && this.above.length === 0;
  }
}

export class CarLayerComposer {
  /** 官方帧间隔：`startFileAnimDrawable(iv, "carpic_charge", n, 2, 110)`。 */
  static readonly frameIntervalMs: number = 110;

  /**
   * 图层目录（解压后的 `android/xxhdpi`）。
   * 密度目录名各车型可能不同，取第一个有 PNG 的。
   */
  static layerDirectory(root: string): string | null {
    const android = `${root}/android`;
    try {
      const densities = fileIo.listFileSync(android);
      for (let i = 0; i < densities.length; i++) {
        const dir = `${android}/${densities[i]}`;
        try {
          const files = fileIo.listFileSync(dir);
          for (let j = 0; j < files.length; j++) {
            if (files[j].endsWith('.png')) {
              return dir;
            }
          }
        } catch (e) {
          // 不是目录就跳过。
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  /**
   * 前缀匹配，判据统一走 `CarTypeFamily`：carType 带上年款之类的后缀时，
   * 原来的精确匹配会让 `T03-2023` 静悄悄落进 default，按 C11 那套画门窗。
   * 分支的先后顺序保持和原来的 switch 一致。
   */
  private static doorRule(carType: string): DoorRule {
    if (CarTypeFamily.isS01(carType)) {
      return DoorRule.s01;
    }
    if (CarTypeFamily.isT03(carType)) {
      return DoorRule.t03;
    }
    if (CarTypeFamily.matches(carType, ['c10', 'b11', 'c01', 'c16', 'b10', 'b01'])) {
      return DoorRule.fullDoorsWithWindows;
    }
    // c11 和其余车型走同一套
    return DoorRule.fullDoors;
  }

  private static chargeSlot(carType: string): ChargeSlot {
    if (CarTypeFamily.matches(carType, ['c16', 'c10', 'b11'])) {
      return ChargeSlot.aboveBody;
    }
    if (CarTypeFamily.isLegacyFamily(carType)) {  // t03 / s01
      return ChargeSlot.aboveDoors;
    }
    return ChargeSlot.belowBody;
  }

  /** 按车况和车型排出图层方案。 */
  static plan(state: VehicleState | null, carType: string): LayerPlan {
    const doors = CarLayerComposer.doorRule(carType);
    const slot = CarLayerComposer.chargeSlot(carType);
    const plan = new LayerPlan();

    // 充电槽之前写 below、之后写 above，一次遍历就分好段。
    let reachedCharge = false;
    const put = (name: string): void => {
      if (reachedCharge) {
        plan.above.push(name);
      } else {
        plan.below.push(name);
      }
    };

    const leftFrontOpen = state?.bool(VehicleSignal.driverDoor) === true;
    const rightFrontOpen = state?.bool(VehicleSignal.passengerDoor) === true;
    const leftRearOpen = state?.bool(VehicleSignal.leftRearDoor) === true;
    const rightRearOpen = state?.bool(VehicleSignal.rightRearDoor) === true;
    // 官方这个字段叫 isTrunkLock，但用法是 `isTrunkLock ? tailgate_open : tailgate_close`，
    // 说的其实是尾门开着。
    const trunkOpen = state?.trunkOpen === true;

    // ① 天幕。见 `skyLayerName` 的说明：判据我们拿不到，暂时不画。

    // ② 右前门。这一侧朝向观众的背面，官方把它画在车身下面。
    put(rightFrontOpen ? 'carpic_rightfront_open' : 'carpic_rightfront_close');

    // ③ 右后门。两门轿跑没有。
    if (doors !== DoorRule.s01) {
      put(rightRearOpen ? 'carpic_rightbehind_open' : 'carpic_rightbehind_close');
    }

    // ④ 尾门。t03/s01 只在开着时画（包里也只有 open 那张），其余恒画。
    if (doors === DoorRule.t03 || doors === DoorRule.s01) {
      if (trunkOpen) {
        put('carpic_tailgate_open');
      }
    } else {
      put(trunkOpen ? 'carpic_tailgate_open' : 'carpic_tailgate_close');
    }

    if (slot === ChargeSlot.belowBody) {
      reachedCharge = true;
    }

    // ⑤ 车身 + 引擎盖。引擎盖没有独立信号，官方也一律按关闭画。
    put('carpic_body');
    put('carpic_hood_close');

    // ⑥ 车窗补层。名字里的 close 说的是「门关着时那扇窗」——
    // 门开时用的是门的 open 图，里面自带窗，再叠这层会重影。
    // 所以它跟车窗开度无关，只看门。
    if (doors === DoorRule.fullDoorsWithWindows || doors === DoorRule.t03) {
      if (!leftFrontOpen) {
        put('carpic_leftfront_window_close');
      }
      if (!leftRearOpen) {
        put('carpic_leftbehind_window_close');
      }
    }

    if (slot === ChargeSlot.aboveBody) {
      reachedCharge = true;
    }

    // ⑦ 左侧的门。这一侧朝向观众，画在车身上面。
    if (doors !== DoorRule.s01) {
      put(leftRearOpen ? 'carpic_leftbehind_open' : 'carpic_leftbehind_close');
    }
    put(leftFrontOpen ? 'carpic_leftfront_open' : 'carpic_leftfront_close');

    if (slot === ChargeSlot.aboveDoors) {
      reachedCharge = true;
    }

    // ⑧ 充电。行车中官方整层隐藏。
    if (state?.isDriving !== true) {
      plan.chargeFrames = CarLayerComposer.chargeFrames(state, carType);
    }

    // ⑨ 充电口盖。只有 t03/s01 画，且跟着充电层一起显示或隐藏。
    if (slot === ChargeSlot.aboveDoors && plan.chargeFrames.length > 0) {
      plan.above.push('carpic_charge_open');
    }

    // ⑩ 车窗告警标签。同 ①，判据缺失。

    return plan;
  }

  /**
   * 充电层的帧。
   *
   * 官方 `startFileAnimDrawable(iv, "carpic_charge", n, 2, 110)`：从
   * `carpic_charge2` 起连着取 n 张，每张 110ms 循环，缺哪张就在那停。
   * n 按车型不同：s01 = 18、t03 = 14、其余 = 15。
   *
   * 不充电时按 `chargeState` 出一张静态图（`carpic_charge1` 是插枪待机、
   * `carpic_charge2` 是充满）。
   */
  private static chargeFrames(state: VehicleState | null, carType: string): string[] {
    const chargeState = state?.chargeState ?? null;
    if (chargeState === 1) {
      let count = 15;
      if (CarTypeFamily.isS01(carType)) {
        count = 18;
      } else if (CarTypeFamily.isT03(carType)) {
        count = 14;
      }
      const frames: string[] = [];
      for (let i = 0; i < count; i++) {
        frames.push(`carpic_charge${i + 2}`);
      }
      return frames;
    }
    if (chargeState === 3 || chargeState === 4 || chargeState === 6) {
      return ['carpic_charge1'];
    }
    if (chargeState === 2) {
      return ['carpic_charge2'];
    }
    return [];
  }

  /**
   * 图层名 → 沙箱文件路径。包里缺哪张就返回空串，调用方跳过——
   * 官方的图层包并不保证每个车型都齐全（比如 s01 就没有 tailgate_close）。
   */
  static path(layerDirectory: string, name: string): string {
    const full = `${layerDirectory}/${name}.png`;
    try {
      return fileIo.accessSync(full) ? `file://${full}` : '';
    } catch (e) {
      return '';
    }
  }

  /** 过滤掉包里没有的图层，返回可直接喂给 `Image` 的路径数组。 */
  static paths(layerDirectory: string, names: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const path = CarLayerComposer.path(layerDirectory, names[i]);
      if (path.length > 0) {
        out.push(path);
      }
    }
    return out;
  }
}

/**
 * 天幕状态标签（`carpic_windowstatus_top_green` / `_top_red`）没有接。
 * 官方判据是 `newSkystate` 加防盗状态 `isCarPrevent`，两个信号我们都没有，
 * 而且这层是张写着中文的标签图、不是车体的一部分——首页那排徽章已经在播报同样的事。
 *
 * 车窗告警标签（绿「车窗已开」/ 红「车窗未关」）同理：绿红之分看的是钥匙位置
 * ON1（`isOn1Open`）——人在车上开窗是绿，熄火离车还开着是红。这个信号读不到，
 * 猜错就是在车图上写一句错话，所以不画。
 */
