import {
  ConfiguredActionTile, CardActionParams, CardEnergyBars, CardPalette, CardSocRow
} from '../common/CardCommon';

/**
 * 2×2 车辆卡片，对应 iOS 的小尺寸。
 *
 * 卡片数据由主应用通过 `formProvider.updateForm` 推进来（见 FormPusher），
 * 字段名必须和 `FormPusher.bindingData` 一一对应。
 */
@Entry
@Component
struct VehicleCardSmall {
  @LocalStorageProp('vehicleName') vehicleName: string = '我的车';
  @LocalStorageProp('soc') soc: number = -1;
  @LocalStorageProp('gasolinePercent') gasolinePercent: number = -1;
  @LocalStorageProp('rangeKm') rangeKm: number = -1;
  @LocalStorageProp('isLocked') isLocked: string = '';
  @LocalStorageProp('isCharging') isCharging: boolean = false;
  @LocalStorageProp('climateOn') climateOn: boolean = false;
  @LocalStorageProp('trunkOpen') trunkOpen: boolean = false;
  /** 按钮是直发还是打开 App。由 FormPusher 算好推过来。 */
  @LocalStorageProp('directControl') directControl: boolean = false;
  /** 上一次直发失败的原因，空串表示没有。 */
  @LocalStorageProp('controlError') controlError: string = '';
  @LocalStorageProp('smallWidgetButtons') smallWidgetButtons: string[] = ['toggleLock', 'toggleClimate'];

  build() {
    Column() {
      Row() {
        Text(this.vehicleName)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(CardPalette.textSecondary)
          .layoutWeight(1)
        if (this.isCharging) {
          SymbolGlyph($r('sys.symbol.bolt_fill'))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor([CardPalette.accent])
        }
      }
      .width('100%')

      Blank()

      CardSocRow({ soc: this.soc, rangeKm: this.rangeKm, socSize: 36 })
      CardEnergyBars({ soc: this.soc, fuelPercent: this.gasolinePercent, isCharging: this.isCharging })
        .margin({ top: 5 })

      Blank()

      // 小卡本来没有摘要那行字，只在直发失败后临时挤出一行——
      // 卡片进程弹不了 toast，不说这一句，用户看到的就是「按了没反应」。
      if (this.controlError.length > 0) {
        Text(this.controlError)
          .fontSize(10)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(CardPalette.caution)
          .width('100%')
          .margin({ bottom: 5 })
      }

      // 小卡只放两个最常用的动作，再多就挤到看不清图标了。
      Row({ space: 7 }) {
        ForEach(this.smallWidgetButtons, (action: string) => {
          ConfiguredActionTile({ action: action, lockState: this.isLocked, climateOn: this.climateOn, trunkOpen: this.trunkOpen,
            tileHeight: 54, directControl: this.directControl })
        })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    // 深色下系统给的卡片底是纯黑，一整块死黑贴在壁纸上很突兀，自己铺一层。
    .backgroundColor($r('app.color.leap_card_bg'))
    // 桌面默认边距太窄，三种尺寸各自写死，和添加卡片时的预览才一致。
    .padding(15)
    .onClick(() => {
      // 点空白处只打开 App，不带动作。
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: new CardActionParams()
      });
    })
  }
}
