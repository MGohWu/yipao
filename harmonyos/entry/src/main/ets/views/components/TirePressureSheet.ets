import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { TirePressure } from '../../core/LeapModels';
import { LeapStyle, LeapColors } from '../../design/LeapStyle';
import { HomeView } from '../HomeView';
import { SafeAreaInsets } from '../../app/SafeAreaInsets';

/**
 * 四轮胎压。按车辆俯视图摆位，左右两列夹着车身，位置和实车一一对应，
 * 不用再去读「左前/右后」才知道说的是哪个轮子。
 *
 * 只读：胎压没有对应的远控命令，车端也不上报推荐值，所以这里不给「标准范围」，
 * 只如实显示数值和车端自己的告警位。
 */
@ComponentV2
export struct TirePressureSheet {
  store: VehicleStore = vehicleStore;

  private get tires(): TirePressure[] {
    return this.store.state?.tirePressures ?? [];
  }

  private get hasData(): boolean {
    return this.store.state?.hasTireData === true;
  }

  build() {
    Column() {
      // 标题走系统半屏自己的标题栏，这里只留一句结论。
      Text(this.store.state?.hasTireWarning === true ? '有轮胎胎压异常' : '四轮胎压正常')
        .fontSize(12)
        .fontColor(this.store.state?.hasTireWarning === true ? LeapStyle.caution : LeapStyle.textTertiary)
        .padding({ bottom: 18 })

      if (!this.hasData || this.tires.length < 4) {
        this.emptyState()
      } else {
        this.diagram()
        Text(this.store.lastUpdated > 0
          ? HomeView.freshnessText(this.store.reportedAt, this.store.lastUpdated)
          : '胎压随车况一起更新')
          .fontSize(11)
          .fontColor(LeapStyle.textTertiary)
          .padding({ top: 18 })
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 20 + SafeAreaInsets.shared.bottom })
  }

  /** 上排是前轮、下排是后轮，车身画在四块中间。 */
  @Builder
  diagram() {
    Stack() {
      // 车身垫在底下：并排放一列的话它会把整行撑到多高就占多高。
      this.carBody()

      Column({ space: 12 }) {
        Row({ space: 92 }) {
          this.tile(0)
          this.tile(1)
        }
        Row({ space: 92 }) {
          this.tile(2)
          this.tile(3)
        }
      }
      .width('100%')
    }
    .width('100%')
    // 高度必须写死。车身那一竖条是 height('100%')，而弹窗是按内容算高的，
    // 百分比在这里没有可依据的父高度，整块会塌成 0——表现就是弹窗「弹不出来」。
    .height(206)
    .padding({ left: 20, right: 20 })
  }

  /**
   * 没有现成的俯视车符号，只能自己画：一条车身 + 贴在四角支出去的四个轮子。
   * 轮子画出来，俯视图一眼就认得出是车、朝向哪（车头那端圆得多，上圆下方就是个
   * 车鼻子），四张胎压卡也自然对上「哪个轮子」。
   *
   * 原来只用两个后视镜标朝向，反被误读成车胎、以为掉了两个轮子——现在直接画四个轮子。
   */
  @Builder
  carBody() {
    Stack() {
      // 车身：比轮距窄一圈，好让轮子从两侧支出去。
      Column()
        .width(56)
        .height('100%')
        .borderRadius({ topLeft: 28, topRight: 28, bottomLeft: 14, bottomRight: 14 })
        .backgroundColor(LeapStyle.separator)

      // 上排前轮、下排后轮，贴着车身两侧各支出去一截，位置跟着前/后排胎压卡走。
      // 上下各留 22 由 padding 给：@Builder 调用返回 void，没法在它上面链 margin。
      Column() {
        this.wheelPair()
        Blank()
        this.wheelPair()
      }
      .width(74)
      .height('100%')
      .padding({ top: 22, bottom: 22 })
    }
    .width(74)
  }

  /** 一根车轴上的左右两个轮子。 */
  @Builder
  wheelPair() {
    Row() {
      this.wheel()
      Blank()
      this.wheel()
    }
    .width(74)
  }

  @Builder
  wheel() {
    Column()
      .width(10)
      .height(20)
      .borderRadius(3)
      .backgroundColor(LeapStyle.textTertiary)
  }

  @Builder
  tile(index: number) {
    Column({ space: 3 }) {
      Text(this.tires[index].label)
        .fontSize(11)
        .fontColor(LeapStyle.textTertiary)
      Row({ space: 3 }) {
        Text(this.tires[index].kPa !== null ? String(Math.round(this.tires[index].kPa as number)) : '--')
          .fontSize(27)
          .fontWeight(FontWeight.Lighter)
          .fontFeature('"tnum" 1')
          .fontColor(this.tires[index].warning ? LeapStyle.caution : LeapStyle.textPrimary)
        Text('kPa')
          .fontSize(11)
          .fontColor(LeapStyle.textSecondary)
      }
      .alignItems(VerticalAlign.Bottom)
      if (this.tires[index].warning) {
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
            .fontSize(14)
            .fontColor([LeapStyle.caution])
          Text('异常')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.caution)
        }
      }
    }
    .layoutWeight(1)
    .padding({ top: 14, bottom: 14 })
    .borderRadius(LeapStyle.tileRadius)
    // 弹窗底下是系统给的面板，没有内容可透，磨砂只会糊成一块脏灰。给一层浅底。
    .backgroundColor(LeapStyle.fillNeutral)
  }

  @Builder
  emptyState() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_tirepressure'))
        .fontSize(30)
        .fontColor([LeapStyle.textTertiary])
      Text('车辆暂未上报胎压')
        .fontSize(14)
        .fontColor(LeapStyle.textSecondary)
    }
    .padding({ top: 40, bottom: 40 })
  }
}
