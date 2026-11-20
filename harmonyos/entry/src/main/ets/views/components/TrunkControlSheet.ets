import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { LeapCommand } from '../../core/LeapModels';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapStyle } from '../../design/LeapStyle';
import { SafeAreaInsets } from '../../app/SafeAreaInsets';

/** 半屏里的一个动作。@Builder 的入参走对象，多个平铺参数在 ArkUI 里不会跟着状态刷新。 */
interface TrunkAction {
  title: string;
  symbol: Resource;
  /** 这个按钮要下发的方向：true 打开、false 关闭。 */
  open: boolean;
}

/**
 * 尾门控制。
 *
 * 控车条上原来点一下就直接反转尾门：手机在兜里蹭一下，尾门就在车主看不见的地方掀起来，
 * 而且这个方向是 App 替他判的——车况读不到时判的还可能是反的。
 * 这里把方向交回给用户：开和关都摆出来，点哪个发哪个，不点就什么都不发生。
 */
@ComponentV2
export struct TrunkControlSheet {
  store: VehicleStore = vehicleStore;
  @Event onClose: () => void = () => {
  };

  /**
   * 车报没报尾门状态。没报时一个按钮都不点亮——猜一个「关着」点上去，
   * 等于替车说了句它没说过的话（和车窗半屏同一条规矩）。
   */
  private get reportedOpen(): boolean | null {
    return this.store.state?.trunkOpen ?? null;
  }

  /** S01 / T03 关不了尾门，那个按钮在这些车上就不该出现（依据见 `trunkSupportsClose`）。 */
  private get supportsClose(): boolean {
    return LeapCommand.trunkSupportsClose(this.store.session.selectedCarType);
  }

  /**
   * 报的是当前状态，不是操作说明——点亮哪个按钮全看这一句，
   * 车没上报时更要说清楚是「不知道」，否则一个按钮都不亮看着像界面没加载出来。
   */
  private get statusText(): string {
    const open = this.reportedOpen;
    if (open === null) {
      return '该车型未上报尾门状态';
    }
    return open ? '尾门当前已打开' : '尾门当前已关闭';
  }

  /**
   * 下发并关掉半屏。结果提示是贴在根视图底部的，半屏开着会把它整个盖住，
   * 关掉才看得到「指令已下发 / 未收到车辆确认」。
   */
  private send(open: boolean): void {
    this.store.setTrunk(open);
    this.onClose();
  }

  build() {
    Column() {
      // 标题走系统半屏自己的标题栏，这里只报当前状态。
      Text(this.statusText)
        .fontSize(11)
        .fontColor(LeapStyle.textTertiary)
        .width('100%')
        .padding({ left: 20, bottom: 14 })

      Row({ space: 8 }) {
        this.action({ title: '打开尾门', symbol: $r('sys.symbol.car_side_rear_open_1'), open: true })
        if (this.supportsClose) {
          this.action({ title: '关闭尾门', symbol: $r('sys.symbol.car_side_rear'), open: false })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
      // 上一条还在等车确认时 perform 会把新指令直接丢掉，这层保护要挡在按钮上——
      // 不然点了就是「半屏关了、车没动、也没人说为什么」。
      // 只禁用，不整块变淡：变淡会把底和前景一起拉向背景。为什么点不动由下面那行话直说。
      .enabled(!this.store.isSendingCommand)

      // 只剩一个按钮的界面不说明白，看着像另一个没加载出来。
      if (!this.supportsClose) {
        Text('该车型不支持远程关闭尾门。')
          .fontSize(11)
          .fontColor(LeapStyle.textTertiary)
          .width('100%')
          .padding({ left: 20, right: 20, top: 14 })
      }

      if (this.store.isSendingCommand) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(LeapStyle.textSecondary)
          Text('上一条指令还在等车辆确认')
            .fontSize(12)
            .fontColor(LeapStyle.textSecondary)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 14 })
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 24 + SafeAreaInsets.shared.bottom })
  }

  /** 点亮的是「车现在停在这一侧」，和车窗半屏的档位按钮一个意思。 */
  @Builder
  action(item: TrunkAction) {
    Column({ space: 6 }) {
      SymbolGlyph(item.symbol)
        .fontSize(22)
        .fontColor([this.reportedOpen === item.open ? LeapStyle.cool : LeapStyle.textPrimary])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
        // 两个字形高矮差着几点，钉死这一行，两个按钮的标题才在同一条线上。
        .height(26)
      Text(item.title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.reportedOpen === item.open ? LeapStyle.cool : LeapStyle.textPrimary)
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 12 })
    .borderRadius(LeapStyle.tileRadius)
    // 半屏底下是系统给的面板，没有内容可透，磨砂只会糊成一块脏灰。给一层浅底。
    .backgroundColor(LeapStyle.fillNeutral)
    .visualEffect(LeapMaterial.pressable)
    .onClick(() => {
      this.send(item.open);
    })
  }
}
