import { display } from '@kit.ArkUI';
import { LeapStyle, LeapColors } from './LeapStyle';
import { LeapMaterial } from './LeapMaterial';

/**
 * 页面通用构件。材质本身全部交给沉浸光感（见 `LeapMaterial`），
 * 这里只负责排版、配色和那层给材质提供折射源的背景。
 */

/**
 * 车辆主视觉背景：充电时偏绿、空调制热时偏暖，其余偏冷蓝。
 *
 * 顶部那团光晕是给材质提供折射源的——没有它，卡片浮在纯色背景上几乎看不出材质。
 */
@ComponentV2
export struct LeapBackground {
  /** 光晕主色，取 LeapColors 里的十六进制值。 */
  @Param tint: string = LeapColors.coolGlow;

  /**
   * 光晕强度倍率，用来表达「同一个色但更弱」这档。
   *
   * iOS 那边是给 tint 本身带透明度（空调关着时是 `cool.opacity(0.6)`），
   * 靠颜色的 alpha 把整团光晕调暗。这边 tint 是纯色 hex、alpha 是画的时候单独算的，
   * 直接往 hex 里塞 alpha 会被 `LeapColors.alpha` 覆盖掉，所以拆成独立一档乘进去。
   */
  @Param tintIntensity: number = 1;

  /**
   * 屏幕尺寸，单位 vp。
   *
   * 光晕的宽度**必须**用绝对值，不能写 `width('150%')`：Stack 会拿自己的宽度去约束
   * 子组件，百分比超过 100% 的部分被直接砍掉——实测光晕只剩预期的一半大，
   * 圆心也从屏幕中央偏到了四分之一处。绝对尺寸不受这个约束，配合外层 `clip` 溢出即可。
   */
  private static readonly screenW: number = LeapBackground.screenSize(true);
  private static readonly screenH: number = LeapBackground.screenSize(false);

  private static screenSize(wantWidth: boolean): number {
    try {
      const info = display.getDefaultDisplaySync();
      return px2vp(wantWidth ? info.width : info.height);
    } catch (e) {
      // 拿不到就按常见的长条屏估一个，光晕位置差一点比整块背景不画出来强。
      return wantWidth ? 360 : 780;
    }
  }

  /**
   * 光晕是**椭圆**：横向半径按屏宽取，纵向按屏高取。ArkUI 的 `radialGradient`
   * 只画正圆，所以先按屏宽画个圆，再在竖直方向拉这么多倍。
   */
  private static readonly aspect: number = LeapBackground.screenH / LeapBackground.screenW;

  /**
   * 光晕布局框的左上角。
   *
   * `position` 定位的是缩放前的布局框，而 `scale` 以元素中心为锚点，圆心不会跑，
   * 所以只要解「圆心减半径」：两个方向的半径都是按屏宽算的（竖直方向的拉伸是 scale 干的）。
   */
  private static corner(centerFraction: number, radiusOfWidth: number, alongWidth: boolean): number {
    const center = centerFraction * (alongWidth ? LeapBackground.screenW : LeapBackground.screenH);
    return center - radiusOfWidth * LeapBackground.screenW;
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[LeapStyle.bgTop, 0.0], [LeapStyle.bgMid, 0.55], [LeapStyle.bgBottom, 1.0]]
        })

      // 顶部光晕：随车况变色的那一团。圆心在屏幕纵向 6% 处，
      // 横向半径是屏宽的 75%、纵向半径是屏高的 75%——一团很大很柔的光，
      // 不是顶上一个小圆点。这几个数都照搬 iOS 那版，改一个就对不上了。
      Column()
        .width(LeapBackground.screenW * 1.5)
        .height(LeapBackground.screenW * 1.5)
        .radialGradient({
          center: ['50%', '50%'],
          radius: '50%',
          // 中间多给一个停止点，把衰减压平。只有首尾两点时亮度掉得很陡，
          // 光晕缩成中间一团，屏幕四周还是黑的，卡片压在明暗交界上就一张一个色。
          // iOS 那版是 0.45 起步，但它铺在液态玻璃底下、还叠着一层玻璃自身的折射，
          // 我们这边少了那一层，同样的数值上屏就淡一截，所以整体提一档。
          colors: [
            [LeapColors.alpha(this.tint, 0.60 * this.tintIntensity), 0.0],
            [LeapColors.alpha(this.tint, 0.42 * this.tintIntensity), 0.45],
            [LeapColors.alpha(this.tint, 0.18 * this.tintIntensity), 0.75],
            [LeapColors.alpha(this.tint, 0.0), 1.0]
          ]
        })
        .scale({ x: 1, y: LeapBackground.aspect })
        .position({
          x: LeapBackground.corner(0.5, 0.75, true),
          y: LeapBackground.corner(0.06, 0.75, false)
        })
        .animation({ duration: 900, curve: Curve.Smooth })

      // 右下角那团恒定的冷光，把画面下半部托住。圆心在 (90%, 80%)，半径 62%。
      Column()
        .width(LeapBackground.screenW * 1.24)
        .height(LeapBackground.screenW * 1.24)
        .radialGradient({
          center: ['50%', '50%'],
          radius: '50%',
          colors: [
            [LeapColors.alpha(LeapColors.coolGlow, 0.34), 0.0],
            [LeapColors.alpha(LeapColors.coolGlow, 0.24), 0.45],
            [LeapColors.alpha(LeapColors.coolGlow, 0.10), 0.75],
            [LeapColors.alpha(LeapColors.coolGlow, 0.0), 1.0]
          ]
        })
        .scale({ x: 1, y: LeapBackground.aspect })
        .position({
          x: LeapBackground.corner(0.9, 0.62, true),
          y: LeapBackground.corner(0.8, 0.62, false)
        })
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

/** 卡片里的标题小字。 */
@ComponentV2
export struct CardLabel {
  @Param text: string = '';

  build() {
    Text(this.text)
      .fontSize(12)
      .fontColor(LeapStyle.textSecondary)
  }
}

/** 数值 + 单位的排版，统一用等宽数字避免刷新时跳动。 */
@ComponentV2
export struct MetricValue {
  @Param value: string = '';
  @Param unit: string = '';
  @Param valueSize: number = 30;
  @Param weight: FontWeight = FontWeight.Medium;
  @Param color: ResourceColor = LeapStyle.textPrimary;

  build() {
    Row({ space: 4 }) {
      Text(this.value)
        .fontSize(this.valueSize)
        .fontWeight(this.weight)
        .fontColor(this.color)
        // 等宽数字：刷新时数字不会左右跳。
        .fontFeature('"tnum" 1')
      if (this.unit.length > 0) {
        Text(this.unit)
          .fontSize(Math.max(11, this.valueSize * 0.38))
          .fontWeight(FontWeight.Medium)
          .fontColor(LeapStyle.textSecondary)
          .margin({ bottom: this.valueSize * 0.1 })
      }
    }
    .alignItems(VerticalAlign.Bottom)
  }
}

/** 顶部状态胶囊，比如「已锁车」「充电中」。 */
@ComponentV2
export struct StatusPill {
  @Param text: string = '';
  @Param symbol: Resource = $r('sys.symbol.lock_fill');
  @Param tint: ResourceColor = LeapStyle.accent;
  @Param tintHex: string = LeapColors.accentGlow;

  build() {
    Row({ space: 5 }) {
      SymbolGlyph(this.symbol)
        .fontSize(14)
        .fontColor([this.tint])
      Text(this.text)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.tint)
    }
    .padding({ left: 11, right: 11, top: 6, bottom: 6 })
    .backgroundColor(LeapStyle.fillFor(this.tintHex))
    .borderRadius(20)
    .backgroundBlurStyle(LeapMaterial.pillBlur)
  }
}

/** 卡片：内容 + 统一圆角 + 沉浸式系统材质。 */
@ComponentV2
export struct GlassCard {
  @Param radius: number = LeapStyle.cardRadius;
  @Param contentPadding: number = 16;

  @Builder
  defaultContent() {
  }

  @BuilderParam content: () => void = this.defaultContent;

  build() {
    Column() {
      this.content()
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(this.contentPadding)
    .borderRadius(this.radius)
    .backgroundEffect(LeapMaterial.cardEffect)
  }
}

/**
 * 可点按的卡片。按压反馈交给 hdsEffect 的 `pressShadow`，不再自己写缩放动画——
 * 系统那套形变和别的应用一致。
 */
@ComponentV2
export struct GlassActionCard {
  @Param radius: number = LeapStyle.cardRadius;
  @Param contentPadding: number = 16;
  @Param isEnabled: boolean = true;
  /**
   * 激活态的主题色（十六进制）。空串表示不上色。
   * 上色只改点光源的颜色，通透度不变——卡片不会因为亮起来就变成一块实色。
   */
  @Param tintHex: string = '';
  @Event onTap: () => void = () => {
  };

  @Builder
  defaultContent() {
  }

  @BuilderParam content: () => void = this.defaultContent;

  build() {
    Column() {
      this.content()
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(this.contentPadding)
    .borderRadius(this.radius)
    .backgroundEffect(LeapMaterial.cardEffect)
    // 激活态的色垫在玻璃之上，卡片亮起来但不会变成一块实色。
    // 不可点时连色垫一起撤掉，靠「没亮起来」表达状态。
    //
    // 这里原本还挂着 `.opacity(this.isEnabled ? 1 : 0.45)`。整卡片调透明度会把
    // 里面每一行文字的对比度一起拖下去，而卡片内容是 `@BuilderParam` 传进来的，
    // 这一层根本管不到那些文字用的什么颜色——等于给调用方埋了个不达标的雷。
    // 眼下没有任何调用方传 `isEnabled: false`，撤掉不影响现有画面。
    .backgroundColor(this.tintHex.length > 0 && this.isEnabled
      ? LeapStyle.fillFor(this.tintHex)
      : Color.Transparent)
    .visualEffect(LeapMaterial.pressable)
    .onClick(() => {
      if (this.isEnabled) {
        this.onTap();
      }
    })
  }
}
