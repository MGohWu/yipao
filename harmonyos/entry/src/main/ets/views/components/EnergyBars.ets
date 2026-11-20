import { LeapStyle, LeapColors } from '../../design/LeapStyle';

/** 电量条。充电时填充带一段渐变，充电上限画一道刻度。 */
@ComponentV2
export struct BatteryBar {
  @Param soc: number = 0;
  /** 读不到就不画那道刻度。画一个猜出来的位置，等于告诉用户车设的就是那个数。 */
  @Param limit: number | null = null;
  @Param charging: boolean = false;
  /** 条的粗细。增程车电量、油量两条并排，改细一点（4）更清爽；纯电车单条保持 6。 */
  @Param barHeight: number = 6;

  private get ratio(): number {
    return Math.min(100, Math.max(0, this.soc)) / 100;
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      // 槽
      Row()
        .width('100%')
        .height(this.barHeight)
        .borderRadius(this.barHeight / 2)
        .backgroundColor(LeapStyle.separator)

      // 填充
      Row()
        .width(`${this.ratio * 100}%`)
        .height(this.barHeight)
        .borderRadius(this.barHeight / 2)
        .linearGradient(this.charging ? {
          angle: 90,
          colors: [[LeapStyle.accent, 0.0], [LeapStyle.accentSoft, 1.0]]
        } : {
          angle: 90,
          colors: [[LeapStyle.accent, 0.0], [LeapStyle.accent, 1.0]]
        })
        .animation({ duration: 600, curve: Curve.Smooth })

      // 充电上限刻度。比条略高一点（上下各多 2）才看得出是刻度而不是填充的一段。
      if (this.limit !== null) {
        Row()
          .width(2)
          .height(this.barHeight + 4)
          .borderRadius(1)
          .backgroundColor(LeapStyle.mutedFill)
          .offset({ x: `${Math.min(100, Math.max(0, this.limit)) }%` })
      }
    }
    .width('100%')
    .height(this.barHeight + 4)
  }
}

/**
 * 增程车的油量。和电量条同宽同高并排叠着，一眼能比出「电还剩多少、油还剩多少」。
 *
 * 官方小组件按 ≤5 / 5–10 / >10 三档换图标来警示低油量，我们改成换颜色。
 * 但**油量正常时和电量条同色**：两条一深绿一深橙并排着卡片会很吵，
 * 而且橙色本身就是警示信号，天天亮着等于每天警示一件没发生的事。
 */
@ComponentV2
export struct FuelBar {
  @Param percent: number = 0;
  /** 和电量条一致的粗细。增程车两条并排时传 4，比默认 6 细。 */
  @Param barHeight: number = 6;

  private get tint(): ResourceColor {
    if (this.percent <= 5) {
      return Color.Red;
    }
    if (this.percent <= 10) {
      return LeapStyle.warm;
    }
    return LeapStyle.accent;
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width('100%')
        .height(this.barHeight)
        .borderRadius(this.barHeight / 2)
        .backgroundColor(LeapStyle.separator)
      Row()
        .width(`${Math.min(100, Math.max(0, this.percent))}%`)
        .height(this.barHeight)
        .borderRadius(this.barHeight / 2)
        .backgroundColor(this.tint)
        .animation({ duration: 600, curve: Curve.Smooth })
    }
    .width('100%')
    .height(this.barHeight + 4)
  }
}

/**
 * 车窗开度指示。只画两个前窗——后窗在该车型上恒报 0，
 * 那不是「全开」而是占位值，画出来会误导。
 */
@ComponentV2
export struct WindowLevelIndicator {
  @Param leftFront: number = 0;
  @Param rightFront: number = 0;

  build() {
    Row({ space: 6 }) {
      this.bar(this.leftFront)
      this.bar(this.rightFront)
    }
    .height(26)
    .alignItems(VerticalAlign.Bottom)
  }

  /** 值是开度百分比：0 关闭（最矮），100 全开（最高）。 */
  @Builder
  bar(value: number) {
    Column()
      .width(8)
      .height(9 + Math.min(100, Math.max(0, value)) / 100 * 17)
      .borderRadius(4)
      .backgroundColor(value > 0 ? LeapStyle.cool : LeapStyle.mutedFill)
      .animation({ duration: 300, curve: Curve.Smooth })
  }
}
