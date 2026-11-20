import { HdsNavigationTitleBarOptions } from '@kit.UIDesignKit';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapStyle } from '../../design/LeapStyle';

import { PageMetrics } from '../components/PageHeader';

/**
 * 功能详情页共用的外壳。
 *
 * 八个详情页都是同一副骨架：`HdsNavDestination` + 沉浸标题栏 + 一列滚动内容。
 * 骨架没做成一个包住 `HdsNavDestination` 的组件——那样等于在 NavDestination
 * 外面再套一层自定义组件，路由那层的行为不好保证；这里只把重复的参数收成静态方法，
 * 每页仍然自己把 `HdsNavDestination` 摆在根上。
 */
export class FeatureChrome {
  /** 标题栏。和其它二级页一套参数，颜色见 `LeapMaterial.navigationTitleBarStyle`。 */
  static titleBar(title: string): HdsNavigationTitleBarOptions {
    return {
      style: LeapMaterial.navigationTitleBarStyle(),
      content: { title: { mainTitle: title } },
      // 默认是 false，标题栏会直接压在状态栏上，返回键和系统时间叠成一团。
      avoidLayoutSafeArea: true
    };
  }

  /** 滚动内容的顶部留白。标题栏浮在内容之上，内容得自己让开。 */
  static get topInset(): number {
    return PageMetrics.navTopInset;
  }

  /** 滚动内容的底部留白。 */
  static get bottomInset(): number {
    return PageMetrics.navBottomInset;
  }
}

/**
 * 「这一页暂未接入」的横幅。
 *
 * iOS 那边只有未接链路的几页挂它（`LabPreviewScaffold`），已接链路的走
 * `ConnectedFeatureScaffold` 不挂。鸿蒙这边同一条规矩：电池预热、充电计划、驻车照片、
 * 蓝牙钥匙已经接上真车，那几页不挂；直进直出这类还只有界面的仍旧挂着——
 * 不挂的话，「连接车辆」这些按钮看着就像真的能用。
 */
@ComponentV2
export struct FeatureAvailabilityBanner {
  build() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.hammer_fill'))
        .fontSize(18)
        .fontColor([LeapStyle.cool])

      Column({ space: 2 }) {
        Text('暂未接入')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(LeapStyle.textPrimary)
        Text('只能预览操作页面，不会向车辆发送指令')
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(14)
    .borderRadius(LeapStyle.tileRadius)
    // 底走卡片材质，不是 `fillCool`。
    // 两个原因：`fillCool` 是半透明的蓝，直接压在页面底噪上时，暖色页（电池预热）
    // 会把它染成一块脏紫；而且色板的对比度是按「fill 叠在卡片上」量的
    // （见 contrast-check 的 SURFACES），直接铺在背景上等于换了个没量过的底。
    .backgroundEffect(LeapMaterial.cardEffect)
  }
}

/**
 * 一段带图标的说明。
 *
 * iOS 那边是 `Label { Text(...) } icon: { Image(...) }` 再套一层玻璃，
 * 几乎每一页底下都挂一条，这里收成一个组件。
 */
@ComponentV2
export struct FeatureNote {
  @Param symbol: Resource = $r('sys.symbol.info_circle_fill');
  @Param text: string = '';
  @Param tint: ResourceColor = LeapStyle.textSecondary;

  build() {
    Row({ space: 10 }) {
      SymbolGlyph(this.symbol)
        .fontSize(17)
        .fontColor([this.tint])

      Text(this.text)
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(16)
    .borderRadius(LeapStyle.tileRadius)
    .backgroundEffect(LeapMaterial.cardEffect)
  }
}
