import { LeapStyle } from '../../design/LeapStyle';

/**
 * 自己描的车侧影。
 *
 * 只服务首页那张几十上百 vp 的大车图。这个尺寸上系统的 `sys.symbol.car_side_rear`
 * 是斜后方视角的三厢车，形不对且撑不住；小尺寸的图标位置该用系统符号就用系统
 * 符号，别拿这个来凑。这条轮廓按真车比例量出来：车长 4.3m、车高 1.45m、
 * 轴距 2.6m、轮径 0.69m，短前悬、平车顶、溜背尾。
 *
 * 整条路径只用 M/L/C/Z——圆和轮拱都换成了贝塞尔近似。这样缩放就是「每个数字
 * 乘以同一个系数」，不用去分辨哪些数是长度：`A` 命令里的旋转角和大弧/方向
 * 标志混在参数里，一律乘就会把弧画坏。Shape 的 viewPort 也能缩放，但它换算
 * 出来的实际墨迹只有预期的三分之一，行为对不上文档，索性自己算。
 *
 * 车窗和轮毂都不挖：这个尺寸下细节只会糊成脏点，整块实心反而立得住。
 * 轮子完全落在轮拱里、和车身不相交，所以填充规则是 nonzero 还是 evenodd
 * 都算得出同一个形状。
 */
@ComponentV2
export struct VehicleSilhouette {
  /** 车影高度（vp）。宽度按设计比例自己推出来，不用外面算。 */
  @Param carHeight: number = 94;
  @Param color: ResourceColor = LeapStyle.vehicleSilhouette;

  /** 下面那条路径的墨迹范围，左上角就是原点。 */
  private static readonly designWidth: number = 248.95;
  private static readonly designHeight: number = 94;

  static readonly aspectRatio: number =
    VehicleSilhouette.designWidth / VehicleSilhouette.designHeight;

  /**
   * 车身外轮廓 + 两个轮子。门槛线在轮拱处向上凹出半圆，轮子嵌在拱里，
   * 中间留一圈 4 个单位的轮眉缝——这条缝是纯实心剪影里唯一的结构线。
   */
  private static readonly outline: string =
    'M 6.67 80.00 C 1.71 80.00 0.00 74.00 0.00 66.00 C 0.00 56.00 2.53 47.00 10.10 41.00 ' +
    'C 20.11 36.00 34.28 34.00 45.10 33.00 C 50.51 32.50 54.12 32.00 57.73 32.00 ' +
    'L 74.87 13.00 C 80.28 5.00 88.40 1.00 99.22 0.00 L 169.58 0.00 ' +
    'C 184.01 0.00 198.44 6.00 212.87 16.00 L 232.72 34.00 ' +
    'C 239.03 37.00 243.54 40.00 246.25 46.00 C 248.95 52.00 249.85 60.00 248.95 68.00 ' +
    'C 248.95 76.00 244.44 80.00 239.12 80.00 ' +
    'L 224.35 80.00 C 227.81 69.29 223.99 57.57 214.89 50.96 C 205.78 44.35 193.45 44.35 184.34 50.96 ' +
    'C 175.23 57.57 171.41 69.29 174.87 80.00 ' +
    'L 71.73 80.00 C 75.20 69.29 71.38 57.57 62.27 50.96 C 53.16 44.35 40.83 44.35 31.72 50.96 ' +
    'C 22.61 57.57 18.79 69.29 22.26 80.00 L 6.67 80.00 Z ' +
    'M 68.99 72.00 C 68.99 84.15 59.14 94.00 46.99 94.00 C 34.84 94.00 24.99 84.15 24.99 72.00 ' +
    'C 24.99 59.85 34.84 50.00 46.99 50.00 C 59.14 50.00 68.99 59.85 68.99 72.00 Z ' +
    'M 221.61 72.00 C 221.61 84.15 211.76 94.00 199.61 94.00 C 187.46 94.00 177.61 84.15 177.61 72.00 ' +
    'C 177.61 59.85 187.46 50.00 199.61 50.00 C 211.76 50.00 221.61 59.85 221.61 72.00 Z';

  /**
   * 路径里除了命令字母全是长度，整条乘同一个系数就是等比缩放。
   *
   * 系数要走 `vp2px`：`commands` 里的坐标是 px，而组件的 width/height 是 vp。
   * 直接按 vp 算，车会缩成屏幕像素密度分之一那么大，还缩在组件框的左上角。
   */
  private get commands(): string {
    const ratio: number = vp2px(this.carHeight) / VehicleSilhouette.designHeight;
    const tokens: string[] = VehicleSilhouette.outline.split(' ');
    const scaled: string[] = [];
    for (const token of tokens) {
      const value: number = Number.parseFloat(token);
      scaled.push(Number.isNaN(value) ? token : (value * ratio).toFixed(2));
    }
    return scaled.join(' ');
  }

  build() {
    Path()
      .commands(this.commands)
      .fill(this.color)
      // Path 默认描一道 1px 黑边，不关掉车身会被套上一圈轮廓线。
      .strokeWidth(0)
      .stroke(Color.Transparent)
      .width(this.carHeight * VehicleSilhouette.aspectRatio)
      .height(this.carHeight)
  }
}
