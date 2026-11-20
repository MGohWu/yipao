/**
 * 服务卡片共用的配色与构件。
 *
 * 卡片是独立的渲染环境，拿不到主应用的 `LeapStyle`（沉浸光感那套组件在卡片里
 * 用不了），但 `app.color` 资源卡片进程是读得到的，所以配色直接引资源，
 * 和主应用同一份，深浅色也就自动跟着走。
 *
 * 早先这里写的是一串硬编码十六进制，值是照着深色配的。卡片声明的是
 * `colorMode: auto`，桌面在浅色下给的是浅色底——浅字落在浅底上，整张卡片
 * 只剩几个图标看得见。
 *
 * 三种尺寸（2×2 / 2×4 / 4×4）对应 iOS 的 small / medium / large。
 * 鸿蒙没有锁屏卡片，iOS 那三款 accessory 样式相应舍弃。
 */
/** postCardAction 的 params。ArkTS 不收无类型对象字面量，得有个明确的类。 */
export class CardActionParams {
  leapAction: string = '';
}

/** 动作块的色调。底色要跟着深浅色走，就没法再用 alpha() 现算，改成按语义取资源。 */
export enum CardTint {
  accent = 'accent',
  cool = 'cool',
  caution = 'caution'
}

export class CardPalette {
  static readonly accent: Resource = $r('app.color.leap_accent');
  static readonly cool: Resource = $r('app.color.leap_cool');
  static readonly caution: Resource = $r('app.color.leap_caution');
  static readonly textPrimary: Resource = $r('app.color.leap_text_primary');
  static readonly textSecondary: Resource = $r('app.color.leap_text_secondary');
  static readonly textTertiary: Resource = $r('app.color.leap_text_tertiary');
  static readonly track: Resource = $r('app.color.leap_card_track');

  /** 图标和文字用的前景色。 */
  static tintColor(tint: CardTint): Resource {
    switch (tint) {
      case CardTint.accent:
        return CardPalette.accent;
      case CardTint.caution:
        return CardPalette.caution;
      default:
        return CardPalette.cool;
    }
  }

  /**
   * 动作块的底色。
   *
   * 只有「亮着」的块才用带色调的底（锁车常亮，空调开着才亮）；
   * 其余一律中性淡底——四个块都上色的话，卡片就成了一排彩色方糖，
   * 谁都在喊，反而看不出哪个是要紧的。
   */
  static tileFill(tint: CardTint, prominent: boolean): Resource {
    if (!prominent) {
      return $r('app.color.leap_card_tile_soft');
    }
    switch (tint) {
      case CardTint.accent:
        return $r('app.color.leap_card_tile_accent');
      case CardTint.caution:
        return $r('app.color.leap_card_tile_caution');
      default:
        return $r('app.color.leap_card_tile_cool');
    }
  }
}

/**
 * 卡片上唯一的按钮样式：圆角方块，图标在上文字在下。
 * 2×2 用它单独做锁车键，2×4 / 4×4 用它拼网格——三种规格因此看起来是一家人。
 *
 * 点击分两条路，由 `directControl` 决定（值是主应用侧算好推过来的，
 * 见 `WidgetSettings.canDispatchDirectly`）：
 * - 关着（默认）：走 `router` 把 App 拉到前台，由 App 走生物识别 + 操作密码的完整流程。
 * - 开着：走 `message`，指令在卡片进程里直接发出去（见 `LeapFormAbility.onFormEvent`）。
 *
 * 直发把控车门槛降到「手机已解锁」——卡片进程弹不出身份认证界面。正因为降的是门槛，
 * 它才要用户在设置里自己开。
 */
@Component
export struct ActionTile {
  @Prop action: string = '';
  @Prop symbol: Resource = $r('sys.symbol.lock_fill');
  @Prop title: string = '';
  /** 主要动作（锁车）用带色调的底，次要动作用中性淡底。 */
  @Prop prominent: boolean = false;
  @Prop tint: CardTint = CardTint.cool;
  @Prop tileHeight: number = 60;
  /**
   * 这一刻能不能在卡片进程里直接下发。
   *
   * 必须由外面一路传进来，不能在这里自己去问 `WidgetSettings`：卡片是独立的渲染
   * 环境，读得到的只有 `updateForm` 推过来的那份数据。
   */
  @Prop directControl: boolean = false;

  build() {
    Column({ space: 4 }) {
      SymbolGlyph(this.symbol)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor([this.prominent ? CardPalette.tintColor(this.tint) : CardPalette.textSecondary])
      Text(this.title)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .fontColor(this.prominent ? CardPalette.tintColor(this.tint) : CardPalette.textSecondary)
    }
    .layoutWeight(1)
    .height(this.tileHeight)
    .justifyContent(FlexAlign.Center)
    .borderRadius(14)
    .backgroundColor(CardPalette.tileFill(this.tint, this.prominent))
    .onClick(() => {
      const params = new CardActionParams();
      params.leapAction = this.action;
      if (this.directControl) {
        // message 落在 LeapFormAbility.onFormEvent 里，App 一直留在后台。
        // 参数会被框架序列化成 JSON 字符串交过去。
        postCardAction(this, {
          action: 'message',
          params: params
        });
      } else {
        postCardAction(this, {
          action: 'router',
          abilityName: 'EntryAbility',
          params: params
        });
      }
    })
  }
}

/**
 * 车锁键。文案固定是名词，和旁边的空调/尾门并排时才不会被读成状态；
 * 当前是锁着还是开着由图标和配色表达（绿色闭锁 = 已锁）。
 *
 * 判断直接写在参数里，不抽 `private get locked()`：卡片里的 `@Component`
 * 用取值器算出来的东西一律是假值——车锁明明收到 `locked` 却画成开锁，
 * 电量条那截绿色（原来也走取值器算百分比）宽度一直是 0，是同一个毛病。
 * 取值器是状态管理 V2 才正式支持的，卡片这边还是 V1。
 */
@Component
export struct LockActionTile {
  /** 'locked' / 'unlocked' / ''（读不到）。读不到时按锁着画，和主应用一致。 */
  @Prop lockState: string = '';
  @Prop tileHeight: number = 60;
  @Prop directControl: boolean = false;

  build() {
    ActionTile({
      action: 'toggleLock',
      symbol: this.lockState !== 'unlocked'
        ? $r('sys.symbol.lock_fill') : $r('sys.symbol.lock_open_fill'),
      title: '车锁',
      prominent: this.lockState === 'locked' || this.lockState === 'unlocked',
      tint: this.lockState !== 'unlocked' ? CardTint.accent : CardTint.caution,
      tileHeight: this.tileHeight,
      directControl: this.directControl
    })
  }
}

@Component
export struct ConfiguredActionTile {
  @Prop action: string = 'toggleLock';
  @Prop lockState: string = '';
  @Prop climateOn: boolean = false;
  @Prop trunkOpen: boolean = false;
  @Prop tileHeight: number = 60;
  @Prop directControl: boolean = false;

  build() {
    if (this.action === 'toggleLock') {
      LockActionTile({ lockState: this.lockState, tileHeight: this.tileHeight, directControl: this.directControl })
    } else {
      ActionTile({
        action: this.action,
        symbol: this.action === 'lock' ? $r('sys.symbol.lock_fill') :
          this.action === 'unlock' ? $r('sys.symbol.lock_open_fill') :
          this.action === 'trunk' ? (this.trunkOpen ? $r('sys.symbol.car_side_rear_open_1') : $r('sys.symbol.car_side_rear')) :
          this.action === 'horn' ? $r('sys.symbol.horn_fill') :
          this.climateOn ? $r('sys.symbol.car_ac') : $r('sys.symbol.wind'),
        title: this.action === 'lock' ? '上锁车辆' : this.action === 'unlock' ? '解锁车辆' :
          this.action === 'trunk' ? '尾门' : this.action === 'horn' ? '鸣笛' : '空调',
        prominent: this.action === 'lock' || this.action === 'unlock' ||
          (this.action === 'toggleClimate' && this.climateOn) || (this.action === 'trunk' && this.trunkOpen),
        tint: this.action === 'lock' ? CardTint.accent :
          this.action === 'unlock' || (this.action === 'trunk' && this.trunkOpen) ? CardTint.caution : CardTint.cool,
        tileHeight: this.tileHeight,
        directControl: this.directControl
      })
    }
  }
}

/**
 * 电量条。
 *
 * 用官方 `Progress`，不再自己拿两个 `Column` 叠：原来里面那截绿色是
 * `width('60%')`，百分比在卡片的渲染环境里量不出来，实际宽度一直是 0，
 * 看着就只剩一条灰底——灰底是 `width('100%')`，那个是好的，所以更迷惑。
 * 进度条这种东西本来也该交给官方组件算。
 */
@Component
export struct CardBatteryBar {
  @Prop soc: number = -1;
  @Prop isCharging: boolean = false;

  build() {
    Progress({
      value: Math.min(100, Math.max(0, this.soc < 0 ? 0 : this.soc)),
      total: 100,
      type: ProgressType.Linear
    })
      .color(CardPalette.accent)
      .backgroundColor(CardPalette.track)
      // 充电时开官方的扫光，替掉原来「充电就满色、不充电淡一档」那点区别——
      // 那点透明度差在卡片这么小的一条上根本看不出来。
      .style({ strokeWidth: 5, enableScanEffect: this.isCharging } as LinearStyleOptions)
      .width('100%')
  }
}

/**
 * 大卡读数区的一段：图标 + 百分比 + 续航，底下压一条进度条。
 *
 * 增程车摆两段（电一段油一段），纯电车只摆一段、铺满整行。续航读不到（-1）
 * 就整个不摆那个数——空着比写个 `--` 老实，也比编一个数强。
 *
 * 做成 `@Component` 而不是带参数的 `@Builder`：带参 builder 的参数是值传递，
 * 父组件因为推来新数据重画时 builder 体不重跑，那一段会冻在第一次的读数上。
 */
@Component
export struct CardEnergySegment {
  @Prop symbol: Resource = $r('sys.symbol.bolt_fill');
  /** 百分比，负数表示读不到。 */
  @Prop percent: number = -1;
  /** 续航公里数，负数表示读不到（那就不摆这个数）。 */
  @Prop km: number = -1;
  /** 充电中：图标着色 + 进度条走扫光。只有电那一段会传 true。 */
  @Prop isCharging: boolean = false;

  build() {
    Column({ space: 5 }) {
      Row({ space: 3 }) {
        SymbolGlyph(this.symbol)
          .fontSize(11)
          .fontColor([this.isCharging ? CardPalette.accent : CardPalette.textTertiary])
        Text(this.percent >= 0 ? String(this.percent) : '--')
          .fontSize(28)
          .fontFeature('"tnum" 1')
          .fontColor(CardPalette.textPrimary)
        Text('%')
          .fontSize(13)
          .fontColor(CardPalette.textSecondary)
        Blank()
        if (this.km >= 0) {
          Text(`${this.km} km`)
            .fontSize(12)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(CardPalette.textSecondary)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Progress({
        value: Math.min(100, Math.max(0, this.percent < 0 ? 0 : this.percent)),
        total: 100,
        type: ProgressType.Linear
      })
        .color(CardPalette.accent)
        .backgroundColor(CardPalette.track)
        .style({ strokeWidth: 5, enableScanEffect: this.isCharging } as LinearStyleOptions)
        .width('100%')
    }
    .layoutWeight(1)
  }
}

/**
 * 能量条。纯电车只有电量一条（沿用 CardBatteryBar）；增程车再叠一条同款油量条，
 * 各带一个小图标区分（和 App 首页那张卡一致）。fuelPercent < 0 视为没有油量数据。
 */
@Component
export struct CardEnergyBars {
  @Prop soc: number = -1;
  @Prop fuelPercent: number = -1;
  @Prop isCharging: boolean = false;

  build() {
    if (this.fuelPercent >= 0) {
      Column({ space: 4 }) {
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.bolt_fill'))
            .fontSize(11)
            .fontColor([CardPalette.textTertiary])
          Progress({
            value: Math.min(100, Math.max(0, this.soc < 0 ? 0 : this.soc)),
            total: 100,
            type: ProgressType.Linear
          })
            .color(CardPalette.accent)
            .backgroundColor(CardPalette.track)
            .style({ strokeWidth: 4, enableScanEffect: this.isCharging } as LinearStyleOptions)
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.drop_fill'))
            .fontSize(11)
            .fontColor([CardPalette.textTertiary])
          Progress({
            value: Math.min(100, Math.max(0, this.fuelPercent)),
            total: 100,
            type: ProgressType.Linear
          })
            .color(CardPalette.accent)
            .backgroundColor(CardPalette.track)
            .style({ strokeWidth: 4 } as LinearStyleOptions)
            .layoutWeight(1)
        }
        .width('100%')
      }
      .width('100%')
    } else {
      CardBatteryBar({ soc: this.soc, isCharging: this.isCharging })
    }
  }
}

/** 电量数字 + 百分号 + 右侧续航。三种尺寸只有字号不同。 */
@Component
export struct CardSocRow {
  @Prop soc: number = -1;
  @Prop rangeKm: number = -1;
  @Prop socSize: number = 36;

  build() {
    Row({ space: 2 }) {
      Text(this.soc >= 0 ? String(this.soc) : '--')
        .fontSize(this.socSize)
        .fontWeight(FontWeight.Lighter)
        .fontFeature('"tnum" 1')
        .fontColor(CardPalette.textPrimary)
      Text('%')
        .fontSize(this.socSize * 0.42)
        .fontWeight(FontWeight.Lighter)
        .fontColor(CardPalette.textSecondary)
      Blank()
      if (this.rangeKm >= 0) {
        Text(`${this.rangeKm} km`)
          .fontSize(11)
          .fontColor(CardPalette.textSecondary)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
  }
}
