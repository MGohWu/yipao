import {
  ConfiguredActionTile, CardActionParams, CardEnergySegment, CardPalette
} from '../common/CardCommon';

/**
 * 4×4 车辆卡片，对应 iOS 的大尺寸：信息区 + 车图 + 一整排动作。
 *
 * 车图是主应用拍平好的一张静态图（见 CarSnapshot），通过 Form Kit 的 `formImages`
 * 传 fd 过来——卡片进程读不到应用沙箱，也现叠不了图层。
 */
@Entry
@Component
struct VehicleCardLarge {
  @LocalStorageProp('vehicleName') vehicleName: string = '我的车';
  @LocalStorageProp('soc') soc: number = -1;
  @LocalStorageProp('gasolinePercent') gasolinePercent: number = -1;
  @LocalStorageProp('rangeKm') rangeKm: number = -1;
  /** 增程车的纯电续航；纯电车和读不到都是 -1。 */
  @LocalStorageProp('energyRangeKm') energyRangeKm: number = -1;
  /** 增程车的燃油续航；同上。 */
  @LocalStorageProp('fuelRangeKm') fuelRangeKm: number = -1;
  @LocalStorageProp('isLocked') isLocked: string = '';
  @LocalStorageProp('isCharging') isCharging: boolean = false;
  @LocalStorageProp('climateOn') climateOn: boolean = false;
  @LocalStorageProp('trunkOpen') trunkOpen: boolean = false;
  @LocalStorageProp('headline') headline: string = '';
  @LocalStorageProp('needsAttention') needsAttention: boolean = false;
  /** 「3 分钟前」这样一句，不带动词。拼在 headline 后面。 */
  @LocalStorageProp('freshnessCompact') freshnessCompact: string = '';
  /** 上一次直发失败的原因，空串表示没有。有的话 headline 已经被它顶掉了。 */
  @LocalStorageProp('controlError') controlError: string = '';
  /** formImages 里那张车图的 key。空串表示这次没有图。 */
  @LocalStorageProp('carImage') carImage: string = '';
  /** 按钮是直发还是打开 App。由 FormPusher 算好推过来。 */
  @LocalStorageProp('directControl') directControl: boolean = false;
  @LocalStorageProp('widgetButtons') widgetButtons: string[] = ['toggleLock', 'toggleClimate', 'trunk', 'horn'];

  build() {
    Column() {
      this.titleRow()
      this.carSection()
      this.energySection()
      this.actionRow()
    }
    .width('100%')
    .height('100%')
    // 深色下系统给的卡片底是纯黑，一整块死黑贴在壁纸上很突兀，自己铺一层。
    .backgroundColor($r('app.color.leap_card_bg'))
    .padding(17)
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: new CardActionParams()
      });
    })
  }

  /**
   * 车名摆左边，车停在哪、车况多旧摆右边。
   *
   * 续航不在这一行——它跟着各自的进度条走（见 `energySection`）：增程车电和油
   * 各有一个续航数，摆在标题行只能拼成「电 312 · 油 380 km」那样一长串，
   * 而摆到条子旁边，哪个数属于哪一格是自明的。
   */
  @Builder
  titleRow() {
    Row({ space: 8 }) {
      Text(this.vehicleName)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(CardPalette.textPrimary)
      // 状态那段吃掉剩下的宽度：长车名时被压的该是这句话，不是车名。
      // 失败时不拼时间——那一刻要说的是「刚才那下没成」，几分钟前的车况不相干。
      Text(this.controlError.length > 0 || this.freshnessCompact.length === 0
        ? this.headline : `${this.headline} · ${this.freshnessCompact}`)
        .fontSize(12)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .fontColor(this.needsAttention ? CardPalette.caution : CardPalette.textSecondary)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 车图下面那块读数。增程车切成左右对称的两段，电一段油一段，各自带一个续航数。
   *
   * 官方和车端都不给综合续航——电和油本来就是两个数，用一条总条子把它们并起来，
   * 等于替车主编了一个车上根本没有的读数。纯电车没有第二段，那一段整个不摆，
   * 剩下的一段铺满整行（不是留半边空着）。和 iOS 大卡同一套版式。
   */
  @Builder
  energySection() {
    Row() {
      CardEnergySegment({
        symbol: $r('sys.symbol.bolt_fill'),
        percent: this.soc,
        // 纯电车的续航就是快照里那个总数；增程车才有单独的纯电续航。
        km: this.gasolinePercent >= 0 ? this.energyRangeKm : this.rangeKm,
        isCharging: this.isCharging
      })
      if (this.gasolinePercent >= 0) {
        Divider()
          .vertical(true)
          .height(34)
          .color(CardPalette.track)
          .margin({ left: 7, right: 7 })
        CardEnergySegment({
          symbol: $r('sys.symbol.drop_fill'),
          percent: this.gasolinePercent,
          km: this.fuelRangeKm,
          isCharging: false
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /**
   * 中间这块摆车，不摆地图。
   *
   * 车停在哪已经由上面那句话说了（`headline` 没有更要紧的事要报时就是地名），
   * 而一张没有比例尺也没法缩放的静态地图截图并不比那句话多说什么。
   * 换成车图之后这张卡一眼能认出是哪台车，三端的大卡也长成同一个样子。
   *
   * 高度不写死：车吃掉标题行和读数区之间的所有余量，增程车那格更高时自己让出来。
   */
  @Builder
  carSection() {
    Stack() {
      if (this.carImage.length > 0) {
        // 必须带 `memory://` 前缀。`formImages` 传过来的是文件描述符，卡片这边要靠
        // 这个协议头才认得出「去内存里那份图片找」；直接把 key 递给 Image 是加载不出来的，
        // 而且不报错——那块区域就是一片空白，看着像是主应用压根没给图。
        Image(`memory://${this.carImage}`)
          // 只占七成宽，两侧留白。3D 渲染器截来的车图比图层叠出来的大不少，
          // 顶到卡片两边整张卡就散了。
          .width('70%')
          .height('100%')
          // 官方图层是宽幅画布，车只占中间一条。Cover 会把车裁掉头尾。
          .objectFit(ImageFit.Contain)
      } else {
        // 关了「显示车模型」、资源还没下完、演示态都会走到这里，和首页缺图时一样退回剪影。
        SymbolGlyph($r('sys.symbol.car_fill'))
          .fontSize(56)
          .fontColor([CardPalette.track])
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 四个等宽动作块，和 2×4 网格用的是同一个组件。 */
  @Builder
  actionRow() {
    Row({ space: 8 }) {
      ForEach(this.widgetButtons, (action: string) => {
        ConfiguredActionTile({ action: action, lockState: this.isLocked, climateOn: this.climateOn, trunkOpen: this.trunkOpen,
          tileHeight: 64, directControl: this.directControl })
      })
    }
    .width('100%')
    .margin({ top: 14 })
  }
}
