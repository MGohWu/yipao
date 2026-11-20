import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { LeapCommand, WindowPreset, CarTypeFamily } from '../../core/LeapModels';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapStyle, LeapColors } from '../../design/LeapStyle';
import { SafeAreaInsets } from '../../app/SafeAreaInsets';
import { WindowPosition } from './WindowPosition';

/**
 * 车窗控制。零跑远控只接受一个开度值，两侧前窗一起动，
 * 所以这里是一个统一的位置滑杆，而不是左右各一个（左右各一个会给出无法下发的组合）。
 */
@ComponentV2
export struct WindowControlSheet {
  store: VehicleStore = vehicleStore;
  @Event onClose: () => void = () => {
  };
  /** 开度百分比：0 关闭、100 全开。车端原始刻度各车型不同，换算在 WindowScale 里做完了。 */
  @Local openness: number = 0;
  /**
   * 打开弹窗时车上的开度，也就是「已经下发过的那个值」。
   * 手指按上滑杆再原地松开也会走一次结束回调，拿它挡掉那种「没挪动」的下发——
   * 否则用户只是碰了一下滑杆，就凭空发出一条控车指令并被关掉弹窗。
   */
  @Local committedOpenness: number = 0;

  /**
   * 车到底停在哪个开度，是不是知道。
   *
   * 有的车只报「开没开」不报开度（C11 增程版实测），这时 `openness` 里的 0
   * 是没得选的占位、不是车的真实位置——照着它把「关闭」点亮，等于替车说了句
   * 它没说过的话。所以那种情况下一个档位都不点亮，等用户自己按了才算数。
   */
  @Local knowsPosition: boolean = false;

  aboutToAppear(): void {
    // 四扇里开得最大的那扇代表当前位置，两侧前窗通常同步。
    const reported = this.store.state?.maxWindowOpenness ?? null;
    // 车不报开度，但报了「关着」，那位置就是 0，这一条是知道的。
    const closedByFlag = this.store.state?.anyWindowOpen === false;
    const current: number | null = reported !== null ? reported : (closedByFlag ? 0 : null);
    this.knowsPosition = current !== null;
    this.openness = current ?? 0;
    // 位置不知道时给个不可能相等的值，免得第一次下发被「没挪动」那条挡掉。
    this.committedOpenness = current ?? -1;
  }

  private get carType(): string {
    return this.store.session.selectedCarType;
  }

  /** 只知道「开着」、不知道开了多少的那种车，得把这句说出来。 */
  private get showsOpenHint(): boolean {
    return !this.knowsPosition && this.store.state?.anyWindowOpen === true;
  }

  private get presets(): WindowPreset[] {
    // 从开到关排——和滑杆「往右越开」的方向一致。
    return LeapCommand.windowPresets(this.carType).slice().reverse();
  }

  private get showsSlider(): boolean {
    return LeapCommand.windowSupportsSlider(this.carType);
  }

  /**
   * 下发并关掉弹窗。结果提示是贴在根视图底部的，弹窗开着会把它整个盖住，
   * 关掉才看得到「指令已下发 / 未收到车辆确认」。
   */
  private send(value: number): void {
    this.store.applyWindows(value);
    this.onClose();
  }

  build() {
    Column() {
      // 标题走系统半屏自己的标题栏，这里只补一句下发时机——
      // 发送按钮没了，滑杆车型得说清楚「松手就发」，
      // 否则用户会拖完站在那儿等，或者反复拖找那个按钮。
      // 车报了开合、没报开度时，把「现在是开着的」说在这儿——
      // 一个档位都没点亮的界面，不说清楚就像是没读到车况。
      if (this.showsSlider || this.showsOpenHint) {
        Text(this.showsOpenHint ? '车窗当前已开' : '松手即下发')
          .fontSize(11)
          .fontColor(LeapStyle.textTertiary)
          .width('100%')
          .padding({ left: 20, bottom: 14 })
      }

      Column({ space: 16 }) {
        if (this.showsSlider) {
          this.positionSlider()
        }
        this.presetRow()
        // 这句只对 S01 说过，别因为别的车型也有了滑杆就跟着冒出来——
        // 后窗能不能远控是单车型的实测结论，和接口口径分组是两回事。
        if (CarTypeFamily.isS01(this.carType)) {
          Text('该车型的后窗不支持远程控制。')
            .fontSize(11)
            .fontColor(LeapStyle.textTertiary)
            .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
      // 上一条还在等车确认时 perform 会把新指令直接丢掉，这层保护要挡在滑杆和档位按钮上——
      // 不然点了就是「弹窗关了、车没动、也没人说为什么」。
      //
      // 只禁用，不再挂 `.opacity(0.55)`：整块变淡会把底和前景一起拉向背景，
      // 正文那时只有 2.72:1。为什么点不动改成下面一行话直说。
      .enabled(!this.store.isSendingCommand)

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

  @Builder
  positionSlider() {
    Column({ space: 10 }) {
      Text(WindowPosition.describe(Math.round(this.openness)))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textPrimary)
        .width('100%')

      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.car_window_close_1'))
          .fontSize(16)
          .fontColor([LeapStyle.textTertiary])
        // 值本身就是开度，往右 = 开得更大，不用再取反。
        Slider({
          value: this.openness,
          min: 0,
          max: 100,
          step: 10,
          style: SliderStyle.OutSet
        })
          .selectedColor(LeapStyle.cool)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.openness = value;
            // 拖动途中一条都不发：十个刻度一路划过去就是十条控车指令，
            // 车根本跟不上，用户也说不清最后停在哪一格。
            // 手指离开才算「他停下了」，这时把最终开度发出去。
            if (mode !== SliderChangeMode.End && mode !== SliderChangeMode.Click) {
              return;
            }
            const target = Math.round(value);
            if (target === this.committedOpenness) {
              return;
            }
            this.knowsPosition = true;
            this.committedOpenness = target;
            this.send(target);
          })
        SymbolGlyph($r('sys.symbol.car_window_open_1'))
          .fontSize(16)
          .fontColor([LeapStyle.textTertiary])
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(16)
    .borderRadius(LeapStyle.tileRadius)
    // 弹窗底下是系统给的面板，没有内容可透，磨砂只会糊成一块脏灰。给一层浅底。
    .backgroundColor(LeapStyle.fillNeutral)
  }

  /** 按车型能力渲染。点档位就是下发——按钮按下去就该有事发生。 */
  @Builder
  presetRow() {
    Row({ space: 8 }) {
      // 同样避开 Button：它自带的那层背景在深色下会把档位渲染成一排白块。
      ForEach(this.presets, (item: WindowPreset) => {
        Text(item.label)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.knowsPosition && Math.round(this.openness) === item.openness
            ? LeapStyle.cool : LeapStyle.textPrimary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(44)
          .borderRadius(22)
          .backgroundColor(LeapStyle.fillNeutral)
          .visualEffect(LeapMaterial.pressable)
          .onClick(() => {
            this.knowsPosition = true;
            this.openness = item.openness;
            this.committedOpenness = item.openness;
            this.send(item.openness);
          })
      }, (item: WindowPreset) => String(item.openness))
    }
    .width('100%')
  }
}
