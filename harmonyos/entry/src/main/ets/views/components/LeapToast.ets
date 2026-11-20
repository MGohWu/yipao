import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapStyle } from '../../design/LeapStyle';

/**
 * 全局提示条。贴在底部控车条上方，不遮住那一排按钮。
 *
 * 不用系统 `promptAction.showToast`：控车超时那条要带一个「重试」按钮，
 * 而系统 toast 是纯文本的。
 */
@ComponentV2
export struct LeapToast {
  // 必须 @Local 持有，下面那个 @Monitor 才监听得到——普通成员做监听路径的根时，
  // 编译期只给一条警告，运行期彻底不触发。同 `Index.ets` 那条。
  @Local store: VehicleStore = vehicleStore;
  @Local visible: boolean = false;
  private dismissTimer: number = -1;

  @Monitor('store.toast')
  onToastChanged(): void {
    const toast = this.store.toast;
    if (toast === null) {
      this.visible = false;
      return;
    }
    this.visible = true;
    if (this.dismissTimer >= 0) {
      clearTimeout(this.dismissTimer);
    }
    this.dismissTimer = setTimeout(() => {
      this.visible = false;
      this.store.toast = null;
      this.dismissTimer = -1;
    }, toast.seconds * 1000);
  }

  aboutToDisappear(): void {
    if (this.dismissTimer >= 0) {
      clearTimeout(this.dismissTimer);
    }
  }

  build() {
    Column() {
      if (this.visible && this.store.toast !== null) {
        Row({ space: 12 }) {
          SymbolGlyph(this.store.toast.isError
            ? $r('sys.symbol.exclamationmark_triangle_fill')
            : $r('sys.symbol.checkmark_circle_fill'))
            .fontSize(18)
            .fontColor([this.store.toast.isError ? LeapStyle.caution : LeapStyle.accent])

          Column({ space: 2 }) {
            Text(this.store.toast.text)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(LeapStyle.textPrimary)
            if (this.store.toast.detail.length > 0) {
              Text(this.store.toast.detail)
                .fontSize(12)
                .fontColor(LeapStyle.textSecondary)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.store.toast.showsRetry) {
            Text('重试')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(LeapStyle.cool)
              .onClick(() => {
                this.visible = false;
                this.store.retryLastCommand();
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .borderRadius(LeapStyle.tileRadius)
        .backgroundEffect(LeapMaterial.panelEffect)
        .transition(TransitionEffect.OPACITY.combine(
          TransitionEffect.translate({ y: 20 })
        ))
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 92 })
    .justifyContent(FlexAlign.End)
    .height('100%')
    // 外层铺满全屏只是为了把提示条压到底部。必须 Transparent：用 Default 时提示条在场
    // 那几秒（等车确认时长达 20 秒）整页点击全被这层吞掉，舒适座舱连点座椅只认第一下。
    // Transparent 下提示条和「重试」照常可点，空白处的点击透给下面的页面。
    .hitTestBehavior(this.visible ? HitTestMode.Transparent : HitTestMode.None)
  }
}
