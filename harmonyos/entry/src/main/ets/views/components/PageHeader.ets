import { SafeAreaInsets } from '../../app/SafeAreaInsets';
import { LeapStyle } from '../../design/LeapStyle';

/**
 * 一级页面的页头。
 *
 * 一级页面挂在底部导航上，没有 `NavDestination` 那条系统标题栏，
 * 标题得自己画，安全区也得自己让——页面是沉浸式铺到状态栏底下的，
 * 不让的话标题会和系统时间叠在一起。
 *
 * 二级页面（车辆位置、标定、诊断）仍然是 `NavDestination`，
 * 标题栏和返回键由系统给，不走这里。
 */
@ComponentV2
export struct PageHeader {
  @Param title: string = '';
  @Param subtitle: string = '';
  /** 右上角可选的一个图标按钮。要更复杂的东西就用 `trailing`。 */
  @Param actionSymbol: Resource | null = null;
  @Event onAction: () => void = () => {
  };

  @Builder
  noTrailing() {
  }

  /** 右上角自定义内容。给了它就不再看 `actionSymbol`。 */
  @BuilderParam trailing: () => void = this.noTrailing;

  private insets: SafeAreaInsets = SafeAreaInsets.shared;

  build() {
    Row() {
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(LeapStyle.textPrimary)
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor(LeapStyle.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      this.trailing()

      if (this.actionSymbol !== null) {
        SymbolGlyph(this.actionSymbol)
          .fontSize(28)
          .fontColor([LeapStyle.textSecondary])
          .position({ right: 0 })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .height(48 + this.insets.top)
    .padding({ left: 16, right: 16, top: this.insets.top })
  }
}

/**
 * 一级页面滚动内容的底部留白。
 *
 * 底部导航是浮在内容之上的（`barOverlap(true)`），最后一张卡片不留出这段
 * 就会被那条浮动栏压住一半。
 */
export class PageMetrics {
  /**
   * 浮动导航条本身的高度加它离屏幕底边的距离，再多给一点呼吸。
   *
   * 那条 bar 高约 96，离屏幕底 22，再给一点呼吸。
   *
   * 用法：在滚动内容的**最后一个子节点**上放一个这么高的空 `Column`，
   * 并且让滚动内容用 `constraintSize({ minHeight: '100%' })` 而不是 `height('100%')`。
   *
   * 两条歧路都试过：
   * 写成 padding 不生效——ArkUI 的尺寸是 content-box，加在 `100%` 的容器上
   * （或它外面的 Scroll 上）是加在那 100% 之外的，整块溢出视口，留白不参与布局。
   * 做成 Scroll 的兄弟节点确实能留出空当，但那是从视口高度里扣的，
   * 每个页面的内容都跟着上移一截，页面短的时候尤其明显。
   */
  private static readonly barSpace: number = 126;

  /**
   * 底部留白。
   *
   * 不加 `SafeAreaInsets.shared.bottom`：页面本来就铺到屏幕最底下，手势条那一截
   * 是空的，浮动导航条就浮在它上面——再把它加一遍等于留了两次。
   */
  static get bottomInset(): number {
    return PageMetrics.barSpace;
  }

  /**
   * 二级页（`HdsNavDestination`）滚动内容的底部留白。
   *
   * 二级页盖在整个底部导航之上，没有那条浮动栏要让，只需给最后一块内容一点呼吸。
   * 也不加 `SafeAreaInsets.shared.bottom`：手势条那一截本来就是空的。
   */
  static get navBottomInset(): number {
    return 40;
  }

  /**
   * 二级页滚动内容的**顶部**留白。
   *
   * HDS 那条标题栏是沉浸材质 + 滚动渐变模糊的，它**浮在内容之上**，内容区仍然从
   * 屏幕最顶开始——不自己让出这段高度的话，第一块内容会被返回键和标题压住
   * （空调页那个温度盘就是这么和标题叠成一团的）。
   *
   * 56 是标题栏自身的高度，再加状态栏：`avoidLayoutSafeArea` 只把标题栏推到
   * 状态栏下面，没有连带把内容也推下去。
   *
   * 用法和 `bottomInset` 一样，做成滚动内容的**第一个**子节点放一个这么高的空
   * `Column`，别写成 padding——ArkUI 的尺寸是 content-box，加在 `minHeight: '100%'`
   * 的容器上不参与布局。
   */
  static get navTopInset(): number {
    return 56 + SafeAreaInsets.shared.top;
  }
}
