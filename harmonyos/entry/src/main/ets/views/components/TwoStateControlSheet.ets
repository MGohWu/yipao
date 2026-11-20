import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapStyle } from '../../design/LeapStyle';
import { SafeAreaInsets } from '../../app/SafeAreaInsets';

/** 这张半屏控的是哪一样。半屏本身只认这个枚举，静态描述见 `TwoStateControlKinds`。 */
export enum TwoStateControl {
  sunshade,
  sunroof,
  frunk
}

/** 一种控制的静态描述。当前状态不存在这里，半屏每次重建现读 store。 */
interface TwoStateControlKind {
  title: string;
  openTitle: string;
  closeTitle: string;
  openSymbol: Resource;
  closeSymbol: Resource;
  /** 车压根不上报这个状态时，副标题说的那句话。 */
  noStatusText: string;
  /** 行驶中要不要禁用。perform 里按 cmdid 还有一道拦截，这里是界面上先说清楚、按钮先变灰。 */
  blocksWhileDriving: boolean;
}

export class TwoStateControlKinds {
  static of(control: TwoStateControl): TwoStateControlKind {
    switch (control) {
      case TwoStateControl.sunshade:
        return {
          title: '遮阳帘',
          openTitle: '打开遮阳帘',
          closeTitle: '关闭遮阳帘',
          // 系统字形里天幕遮阳帘只有 `sunshade_top` 一个，没有开/关两态，
          // 两个按钮各摆一个一模一样的图标等于没画。这里换到百叶帘那一对——
          // 它是系统里唯一一对语义正好是「拉开 / 合上」的同族字形。
          openSymbol: $r('sys.symbol.blind_curtain_open'),
          closeSymbol: $r('sys.symbol.blind_curtain_close'),
          noStatusText: '车辆不上报遮阳帘状态',
          blocksWhileDriving: false
        };
      case TwoStateControl.sunroof:
        return {
          title: '天窗',
          openTitle: '打开天窗',
          closeTitle: '关闭天窗',
          openSymbol: $r('sys.symbol.car_topwindow_open'),
          closeSymbol: $r('sys.symbol.car_topwindow'),
          noStatusText: '车辆不上报天窗状态',
          blocksWhileDriving: false
        };
      default:
        return {
          title: '前备箱',
          openTitle: '打开前备箱',
          closeTitle: '关闭前备箱',
          // 和尾门那对同一个语言：关着是描边、开着填实。
          openSymbol: $r('sys.symbol.car_side_front_open_fill'),
          closeSymbol: $r('sys.symbol.car_side_front_open'),
          noStatusText: '该车型未上报前备箱状态',
          blocksWhileDriving: true
        };
    }
  }
}

/** 半屏里的一个动作。@Builder 的入参走对象，多个平铺参数在 ArkUI 里不会跟着状态刷新。 */
interface TwoStateAction {
  title: string;
  symbol: Resource;
  /** 这个按钮要下发的方向：true 打开、false 关闭。 */
  open: boolean;
}

/**
 * 遮阳帘 / 天窗 / 前备箱共用的「开 / 关」半屏。
 *
 * 交互规矩照抄尾门（`TrunkControlSheet`）：方向不由 App 替用户猜，开和关都摆出来，
 * 点哪个发哪个，不点就什么都不发生。差别收在 `TwoStateControlKind` 里：前备箱有车况位
 * （信号 1282）能点亮当前那一侧、且行驶中禁用；遮阳帘 / 天窗车况里没有对应字段，
 * 两个按钮都不点亮，副标题直说「不上报状态」——不猜一个状态点上去
 * （和尾门、车窗半屏同一条规矩）。
 */
@ComponentV2
export struct TwoStateControlSheet {
  store: VehicleStore = vehicleStore;
  @Param control: TwoStateControl = TwoStateControl.sunshade;
  @Event onClose: () => void = () => {
  };

  private get kind(): TwoStateControlKind {
    return TwoStateControlKinds.of(this.control);
  }

  /**
   * 车报没报当前状态。读不到（null）时副标题用 `noStatusText` 交代。
   * 遮阳帘读信号 `1724`（实测 C16 在报）、天窗读 `1718`（报 15 / 150 这类占位值时
   * `sunroofOpen` 已经当读不到处理），2026-11-19 起同 iOS。
   */
  private get reportedOpen(): boolean | null {
    const state = this.store.state;
    if (state === null) {
      return null;
    }
    switch (this.control) {
      case TwoStateControl.sunshade:
        return state.sunshadeOpen;
      case TwoStateControl.sunroof:
        return state.sunroofOpen;
      default:
        return state.frontTrunkOpen;
    }
  }

  private get isDriving(): boolean {
    return this.kind.blocksWhileDriving && this.store.state?.isDriving === true;
  }

  /**
   * 报的是当前状态，不是操作说明——点亮哪个按钮全看这一句，
   * 车没上报（或压根不上报）时更要说清楚是「不知道」，
   * 否则一个按钮都不亮看着像界面没加载出来。
   */
  private get statusText(): string {
    const kind = this.kind;
    if (this.isDriving) {
      return `行驶中不能操作${kind.title}`;
    }
    const open = this.reportedOpen;
    if (open === null) {
      return kind.noStatusText;
    }
    return open ? `${kind.title}当前已打开` : `${kind.title}当前已关闭`;
  }

  /**
   * 下发并关掉半屏。结果提示是贴在根视图底部的，半屏开着会把它整个盖住，
   * 关掉才看得到「指令已下发 / 未收到车辆确认」。
   */
  private send(open: boolean): void {
    switch (this.control) {
      case TwoStateControl.sunshade:
        this.store.setSunshade(open);
        break;
      case TwoStateControl.sunroof:
        this.store.setSunroof(open);
        break;
      default:
        this.store.setFrunk(open);
        break;
    }
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
        this.action({ title: this.kind.openTitle, symbol: this.kind.openSymbol, open: true })
        this.action({ title: this.kind.closeTitle, symbol: this.kind.closeSymbol, open: false })
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
      // 上一条还在等车确认时 perform 会把新指令直接丢掉，这层保护要挡在按钮上——
      // 不然点了就是「半屏关了、车没动、也没人说为什么」。
      // 只禁用，不整块变淡：变淡会把底和前景一起拉向背景。为什么点不动由下面那行话直说。
      .enabled(!this.store.isSendingCommand && !this.isDriving)

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

  /** 点亮的是「车现在停在这一侧」，和尾门、车窗半屏一个意思；不上报状态的控制两边都不亮。 */
  @Builder
  action(item: TwoStateAction) {
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
