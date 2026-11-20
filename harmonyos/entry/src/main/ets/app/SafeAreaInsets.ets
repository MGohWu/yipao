import { window } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';

/**
 * 系统安全区高度（vp）。
 *
 * 页面用的是沉浸式布局（`setWindowLayoutFullScreen(true)`），内容会铺到状态栏和
 * 导航条底下——那层随车况变色的渐变背景要顶到屏幕最边上，这是要的。
 * 但铺过去之后必须自己把标题让回来，否则车名会和状态栏的时间叠在一起。
 *
 * 高度问同一个窗口要，不写死：不同机型的状态栏高度、有没有挖孔、横竖屏都不一样。
 */
@ObservedV2
export class SafeAreaInsets {
  /** 状态栏那一条的高度。 */
  @Trace top: number = 0;
  /** 底部手势条的高度。 */
  @Trace bottom: number = 0;
  /** 软键盘弹起时占住的高度，收起时是 0。这一截已经含了手势条。 */
  @Trace keyboard: number = 0;

  static readonly shared: SafeAreaInsets = new SafeAreaInsets();

  /** 绑定到主窗口，并跟着窗口尺寸变化重算（转屏、分屏）。 */
  static attach(mainWindow: window.Window): void {
    SafeAreaInsets.shared.measure(mainWindow);
    mainWindow.on('avoidAreaChange', () => {
      SafeAreaInsets.shared.measure(mainWindow);
    });
    // 键盘单独走这个事件，不跟状态栏挤 `avoidAreaChange`：沉浸式全屏
    // （`setWindowLayoutFullScreen(true)`）下键盘不算系统避让区，那边根本不上报，
    // 拿 `TYPE_KEYBOARD` 问出来的一直是 0。这个回调直接给高度，是唯一靠得住的。
    mainWindow.on('keyboardHeightChange', (height: number) => {
      SafeAreaInsets.shared.keyboard = SafeAreaInsets.toVp(height);
    });
  }

  private measure(mainWindow: window.Window): void {
    try {
      const systemArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const gestureArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.top = SafeAreaInsets.toVp(systemArea.topRect.height);
      this.bottom = SafeAreaInsets.toVp(gestureArea.bottomRect.height);
    } catch (e) {
      // 拿不到就按 0 处理，页面顶多贴边，不至于崩。
    }
  }

  /** 避让区给的是像素，布局用的是 vp，得换算。 */
  private static toVp(px: number): number {
    return px <= 0 ? 0 : px / display.getDefaultDisplaySync().densityPixels;
  }
}
