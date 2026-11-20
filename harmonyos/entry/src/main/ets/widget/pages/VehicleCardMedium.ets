import {
  ConfiguredActionTile, CardActionParams, CardEnergyBars, CardPalette, CardSocRow
} from '../common/CardCommon';

/**
 * 2×4 车辆卡片，对应 iOS 的中尺寸：左边信息、右边 2×2 动作网格。
 */
@Entry
@Component
struct VehicleCardMedium {
  @LocalStorageProp('vehicleName') vehicleName: string = '我的车';
  @LocalStorageProp('soc') soc: number = -1;
  @LocalStorageProp('gasolinePercent') gasolinePercent: number = -1;
  @LocalStorageProp('rangeKm') rangeKm: number = -1;
  @LocalStorageProp('hasFuel') hasFuel: boolean = false;
  @LocalStorageProp('mediumRangeText') mediumRangeText: string = '';
  @LocalStorageProp('isLocked') isLocked: string = '';
  @LocalStorageProp('isCharging') isCharging: boolean = false;
  @LocalStorageProp('climateOn') climateOn: boolean = false;
  @LocalStorageProp('trunkOpen') trunkOpen: boolean = false;
  @LocalStorageProp('headline') headline: string = '';
  @LocalStorageProp('needsAttention') needsAttention: boolean = false;
  /** 按钮是直发还是打开 App。由 FormPusher 算好推过来。 */
  @LocalStorageProp('directControl') directControl: boolean = false;
  @LocalStorageProp('widgetButtons') widgetButtons: string[] = ['toggleLock', 'toggleClimate', 'trunk', 'horn'];

  build() {
    Row({ space: 14 }) {
      this.infoColumn()
      this.actionGrid()
    }
    .width('100%')
    .height('100%')
    // 深色下系统给的卡片底是纯黑，一整块死黑贴在壁纸上很突兀，自己铺一层。
    .backgroundColor($r('app.color.leap_card_bg'))
    .padding(15)
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: new CardActionParams()
      });
    })
  }

  @Builder
  infoColumn() {
    Column() {
      Row({ space: 5 }) {
        Text(this.vehicleName)
          .fontSize(12)
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

      CardSocRow({ soc: this.soc, rangeKm: this.hasFuel ? -1 : this.rangeKm, socSize: 40 })
      if (this.hasFuel && this.mediumRangeText.length > 0) {
        Text(this.mediumRangeText)
          .fontSize(10)
          .minFontSize(8)
          .maxFontSize(10)
          .maxLines(1)
          .fontColor(CardPalette.textSecondary)
      }
      CardEnergyBars({ soc: this.soc, fuelPercent: this.gasolinePercent, isCharging: this.isCharging })
        .margin({ top: 7 })

      Blank()

      Text(this.headline)
        .fontSize(10)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.needsAttention ? CardPalette.caution : CardPalette.textTertiary)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .height('100%')
    .layoutWeight(1)
  }

  /** 2×2 等大网格。四个动作块尺寸一致，和 4×4 卡片用的是同一个组件。 */
  @Builder
  actionGrid() {
    Column({ space: 7 }) {
      Row({ space: 7 }) {
        ForEach(this.widgetButtons.slice(0, 2), (action: string) => {
          ConfiguredActionTile({ action: action, lockState: this.isLocked, climateOn: this.climateOn, trunkOpen: this.trunkOpen,
            tileHeight: 62, directControl: this.directControl })
        })
      }
      Row({ space: 7 }) {
        ForEach(this.widgetButtons.slice(2, 4), (action: string) => {
          ConfiguredActionTile({ action: action, lockState: this.isLocked, climateOn: this.climateOn, trunkOpen: this.trunkOpen,
            tileHeight: 62, directControl: this.directControl })
        })
      }
    }
    .width(146)
  }
}
