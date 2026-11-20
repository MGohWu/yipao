import { CardActionParams, CardPalette } from './CardCommon';

@Component
export struct LockCardContent {
  @Prop action: string = 'toggleLock';
  @LocalStorageProp('vehicleName') vehicleName: string = '我的车';
  @LocalStorageProp('isLocked') isLocked: string = '';
  @LocalStorageProp('isStale') isStale: boolean = false;
  @LocalStorageProp('lockText') lockText: string = '状态未知';
  @LocalStorageProp('freshnessCompact') freshnessCompact: string = '';
  @LocalStorageProp('controlError') controlError: string = '';
  @LocalStorageProp('carImage') carImage: string = '';
  @LocalStorageProp('directControl') directControl: boolean = false;
  @LocalStorageProp('anyDoorOpen') anyDoorOpen: boolean = false;
  @LocalStorageProp('windowsClosed') windowsClosed: string = '';
  @LocalStorageProp('trunkOpen') trunkOpen: boolean = false;

  build() {
    Column({ space: 5 }) {
      Row({ space: 5 }) {
        Column({ space: 2 }) {
          Text(this.action === 'unlock' || (this.action === 'toggleLock' && this.isLocked === 'locked' && !this.isStale)
            ? '解锁车辆' : '上锁车辆')
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(CardPalette.textPrimary).maxLines(1)
          Text(this.vehicleName)
            .fontSize(11).fontColor(CardPalette.textSecondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph(this.action === 'unlock' || (this.action === 'toggleLock' && this.isLocked === 'locked' && !this.isStale)
          ? $r('sys.symbol.lock_open_fill') : $r('sys.symbol.lock_fill'))
          .fontSize(18)
          .fontColor([this.action === 'unlock' || (this.action === 'toggleLock' && this.isLocked === 'locked' && !this.isStale)
            ? CardPalette.caution : CardPalette.accent])
      }
      .width('100%')
      Stack() {
        if (this.carImage.length > 0) {
          Image(`memory://${this.carImage}`)
            .width('100%').height('100%').objectFit(ImageFit.Contain)
        } else {
          SymbolGlyph($r('sys.symbol.car_fill')).fontSize(46).fontColor([CardPalette.textTertiary])
        }
      }
      .width('100%').layoutWeight(1)
      Text(this.controlError.length > 0 ? this.controlError :
        this.anyDoorOpen ? '有车门未关闭' : this.trunkOpen ? '尾门未关闭' :
        this.windowsClosed === 'open' ? '车窗未关闭' : `${this.lockText} · ${this.freshnessCompact}`)
        .fontSize(10).fontColor(CardPalette.textSecondary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
    }
    .width('100%').height('100%').padding(12)
    .backgroundColor($r('app.color.leap_card_bg'))
    .onClick(() => {
      const params = new CardActionParams();
      params.leapAction = this.action === 'toggleLock'
        ? (this.isLocked === 'locked' && !this.isStale ? 'unlock' : 'lock') : this.action;
      if (this.directControl) {
        postCardAction(this, { action: 'message', params: params });
      } else {
        postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: params });
      }
    })
  }
}
