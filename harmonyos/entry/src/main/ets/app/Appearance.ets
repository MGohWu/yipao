import { common, ConfigurationConstant } from '@kit.AbilityKit';

/**
 * 把「深浅外观」的选择真正落到系统上。
 *
 * 只把选择写进首选项是不够的——那样重启也好、当场切也好，界面都不会变一下。
 * 深浅色是应用级配置，得调 `ApplicationContext.setColorMode`，由系统去重刷整棵
 * 组件树；所有 `sys.color.*` 和 `$r` 的深浅两套值都跟着它走，页面这边什么都不用改。
 *
 * 「跟随系统」对应 `COLOR_MODE_NOT_SET`，不是「浅色」。
 */
export class Appearance {
  private static appContext: common.ApplicationContext | null = null;

  /** 启动时挂一次。挂之前的调用会被记下来，挂上以后补发。 */
  static attach(context: common.UIAbilityContext): void {
    Appearance.appContext = context.getApplicationContext();
    if (Appearance.pending !== null) {
      const mode = Appearance.pending;
      Appearance.pending = null;
      Appearance.apply(mode);
    }
  }

  private static pending: string | null = null;

  /** 取 `AppearanceMode` 的原始值（'system' / 'light' / 'dark'）。这里收字符串是为了不反向依赖 VehicleStore。 */
  static apply(mode: string): void {
    const context = Appearance.appContext;
    if (context === null) {
      // 首选项比 attach 先读出来，这时先记下，等 attach 补发。
      Appearance.pending = mode;
      return;
    }
    try {
      context.setColorMode(Appearance.colorModeOf(mode));
    } catch (e) {
      console.error(`[appearance] 切换失败：${(e as Error).message}`);
    }
  }

  private static colorModeOf(mode: string): ConfigurationConstant.ColorMode {
    switch (mode) {
      case 'light':
        return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      case 'dark':
        return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      default:
        return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    }
  }
}
