/**
 * 全局视觉语言。
 *
 * iOS 那版用的是 iOS 26 的液态玻璃；鸿蒙这版换成官方的**沉浸光感**
 * （HDS 的 `hdsEffect` / `hdsMaterial`，见 `LeapMaterial`）：页面底噪是一层随车况变色的
 * 渐变加两团光晕，卡片交给系统材质把底下的光透上来。
 * 两者的共同前提都是「底下得有内容」——所以背景不是纯色。
 *
 * 颜色一律走资源（base / dark 两套 color.json），深浅色由系统自动切换，
 * 代码里不再手写明暗分支。
 */
export class LeapStyle {
  static readonly cardRadius: number = 26;
  static readonly tileRadius: number = 22;
  static readonly pagePadding: number = 16;

  /*
   * 关于对比度：整套色板是按华为《通用应用 UX 体验标准》2.1.4.1 反算出来的
   * ——正文文字与背景 >4.5:1，图标/标题 >3:1。
   *
   * 反算时不能拿 `bg_*` 那三个值当背景：真正压在文字底下的是「渐变 + 两团光晕 +
   * 卡片材质」层层叠出来的颜色，跟着光晕在屏幕上到处漂。1.0.1 被上架检测打回来
   * 就是栽在这里——深色模式下光晕把卡片抬到了 #4979C1 那种亮蓝，
   * **连纯白文字压上去都只有 4.39:1**，色值再怎么调都不可能达标。
   *
   * 所以深色的 `glass_tint` 反过来叠黑（见下），卡片压得比背景暗，
   * 对比度才不再随光晕漂移。光晕本身一点没动。
   *
   * **改这里的任何色值之后，跑一遍 `node scripts/contrast-check.mjs`。**
   * 它复刻整套渲染，在全屏光晕 × 三种车况色调 × 所有表面层上取最差值，
   * 不达标就非零退出。
   */

  // 主题色。浅色版是压暗加饱和过的，深色版是提亮过的，都按最差位置（光晕最强处的
  // 卡片表面）量过，全部在 4.5:1 以上。
  static readonly accent: Resource = $r('app.color.leap_accent');
  static readonly cool: Resource = $r('app.color.leap_cool');
  static readonly warm: Resource = $r('app.color.leap_warm');
  static readonly caution: Resource = $r('app.color.leap_caution');
  /**
   * 除霜专用。不能用主文本色：深色模式下它是纯白，材质被白色一染就成了亮底，
   * 排在快速降温、快速制热旁边活像已经选中。所以给一个饱和度相当、色相岔开的冰蓝。
   */
  static readonly frost: Resource = $r('app.color.leap_frost');

  /** 「有值但不是当前重点」的填充，比如空调关着时亮起的风量柱。 */
  static readonly mutedFill: Resource = $r('app.color.leap_muted_fill');
  /**
   * 分段控件里「这一档选中了」的底。
   *
   * 只有主文本色的 14%，很淡——选中态靠的是文字提亮，底色只起个定位作用。
   * 别拿 `mutedFill` 顶替：那个是 60%，铺在深色底上是一块刺眼的白，
   * 整页就剩它最亮。
   */
  static readonly selectedFill: Resource = $r('app.color.leap_selected_fill');
  /** 首页那辆车的剪影填充。 */
  static readonly vehicleSilhouette: Resource = $r('app.color.leap_vehicle_silhouette');
  /** 卡片边缘线。系统材质本身没有边缘高光，卡片和背景会糊成一片，得手动描一道。 */
  static readonly glassEdge: Resource = $r('app.color.leap_glass_edge');
  /**
   * 垫在材质上的那层薄色，决定卡片相对背景是提亮还是压暗。
   *
   * 浅色叠白（60%），深色叠**黑**（50%）——两边方向是相反的，这不是笔误。
   * 深色下光晕铺在暗底上，0.6 的亮绿/亮蓝几乎主导整片背景，卡片要是继续叠白，
   * 就会被抬成 #4979C1 那种亮蓝，前景全糊（1.0.1 上架被拒的直接原因）。
   * 叠黑之后卡片稳定压在背景之下，光晕原样保留，只是从「透光的亮玻璃」
   * 变成「透光的暗玻璃」——深色模式本来也该是这个方向。
   */
  static readonly glassTint: Resource = $r('app.color.leap_glass_tint');
  /**
   * 模态浮层（操作密码键盘、确认弹窗）的垫色，比卡片的 `glassTint` 厚得多，
   * 接近实色。浮层要把底下整屏都压住、自成一个面，卡片那档半透在这里会糊成
   * 一片和背景分不清的灰——深色下尤其明显。浅色叠近实白，深色叠近实深，
   * 两个方向都保证浮层上的文字对比度稳定。
   */
  static readonly panelTint: Resource = $r('app.color.leap_panel_tint');

  static readonly textPrimary: Resource = $r('app.color.leap_text_primary');
  static readonly textSecondary: Resource = $r('app.color.leap_text_secondary');
  static readonly textTertiary: Resource = $r('app.color.leap_text_tertiary');
  /**
   * 不可点时的文字色。
   *
   * 禁用态**不靠 `opacity` 变淡**：整控件调透明度会把前景和背景一起拉向底色，
   * 「获取验证码」那个绿字按钮 0.4 透明度下量出来只有 1.55:1，是上架检测点名的一条。
   * 改成换一个达标的中性灰——彩色变灰本身就是够清楚的「点不了」信号，
   * 不需要再靠看不清来表达。
   */
  static readonly textDisabled: Resource = $r('app.color.leap_text_disabled');
  /** 实心按钮禁用时的底。配白字量到 5.26:1。 */
  static readonly fillDisabled: Resource = $r('app.color.leap_fill_disabled');
  /**
   * 底部页签未选中态。
   *
   * 原先走系统语义色 `ohos_id_color_bottom_tab_icon_off` / `_text_off`，
   * 但那套色压在浮动页签条的材质上只有 1.72:1，同样被检测点名。系统色不达标
   * 也得自己兜住，所以改成自己的值。
   */
  static readonly tabOff: Resource = $r('app.color.leap_tab_off');

  /*
   * 色块填充。
   *
   * 这几个原先是 `LeapColors.alpha(accentGlow, 0.28)` 这样在代码里现算的，
   * 硬编码的十六进制深浅色共用一个值。卡片改成暗玻璃之后这行不通了：
   * 同样一档 alpha，铺在浅色白卡片上只是淡淡一层，铺在深色暗卡片上却是明显提亮，
   * 把上面那层彩色文字的对比度重新吃掉。改成走资源，深浅两套各自取值。
   */
  static readonly fillAccent: Resource = $r('app.color.leap_fill_accent');
  static readonly fillCool: Resource = $r('app.color.leap_fill_cool');
  /** 中性色块（次要按钮、可点胶囊）。承 `textPrimary` 和 `cool`。 */
  static readonly fillNeutral: Resource = $r('app.color.leap_fill_neutral');
  /**
   * 图表里非高亮的柱子。
   *
   * 原先是 `alpha(coolGlow, 0.5)`，深浅色共用。半透明的亮蓝铺在浅色白卡片上
   * 只有 1.5:1，几乎看不见；铺在深色暗卡片上又只有 2.3:1。图形元素按规范要过 3:1，
   * 只能拆成深浅两套实色。
   */
  static readonly chartBar: Resource = $r('app.color.leap_chart_bar');
  /** 充电时电量条渐变的亮端。同样是原来 `alpha(accentGlow, 0.65)` 拆出来的两套值。 */
  static readonly accentSoft: Resource = $r('app.color.leap_accent_soft');
  /**
   * 压在**实心主色底**上的前景（文字和图标），配 `accent` 用。
   *
   * 别在这种地方写死 `Color.White`：浅色的 accent 是深绿，白字有 8.12:1；
   * 深色的 accent 是亮绿 #5FCE8C，白字只有 1.96:1——「关闭空调」那个按钮就是
   * 这么被检测点名的。深色这一档改成深墨绿，亮底配深字，量到 6.47:1。
   *
   * 只跟 `accent` 配对。别的底（比如 `fillDisabled` 那种中性灰）另算，
   * 那个深浅同值、白字 5.26:1，继续用白色就行。
   */
  static readonly onAccent: Resource = $r('app.color.leap_on_accent');

  static readonly separator: Resource = $r('app.color.leap_separator');

  static readonly bgTop: Resource = $r('app.color.leap_bg_top');
  static readonly bgMid: Resource = $r('app.color.leap_bg_mid');
  static readonly bgBottom: Resource = $r('app.color.leap_bg_bottom');

  /**
   * 把光晕色（`LeapColors` 里的十六进制）换成对应的填充资源。
   *
   * 组件之间是拿十六进制串传色调的（`StatusPill`、`GlassActionCard` 的 `tintHex`），
   * 那串值同时还要喂给背景光晕，不好直接换成 Resource；这里做一次映射，
   * 让填充走资源、深浅色各自取值，光晕那边照旧用十六进制。
   */
  static fillFor(tintHex: string): ResourceColor {
    switch (tintHex) {
      case LeapColors.coolGlow:
        return LeapStyle.fillCool;
      case LeapColors.warmGlow:
        // 暖色没有单独的填充档，跟主色共用一档——两者亮度相近，量出来都过线。
        return LeapStyle.fillAccent;
      case LeapColors.neutralTint:
        return LeapStyle.fillNeutral;
      default:
        return LeapStyle.fillAccent;
    }
  }
}

/** 一个可以按透明度调淡的十六进制色。资源色拿不到分量，光晕这类要调淡的地方用它。 */
export class LeapColors {
  /** 深色底下的光晕用色，与资源里的 dark 值同源。 */
  static readonly accentGlow = '#4DC47D';
  static readonly coolGlow = '#6BA8FF';
  static readonly warmGlow = '#FF8C59';
  /**
   * 「不上色」那一档的色调键。
   *
   * 它不是光晕色，也没有对应的资源色——只是给 `fillFor` 当键用，让 `StatusPill`
   * 这类按 tintHex 取填充的组件能选到中性的 `fillNeutral`。前景配 `textSecondary`，
   * 这一对已经在 `scripts/contrast-check.mjs` 的检查表里。
   */
  static readonly neutralTint = '#8A8A8E';
  /**
   * 功能页背景那团青，对齐 iOS 功能页的 `LeapBackground(tint: LeapStyle.frost)`。
   *
   * 不是 `leap_frost` 的 dark 值 #6BE0EB——那个亮度是按「压在卡片上的前景」定的，
   * 铺成 0.6 alpha 的整屏光晕会把深色下的卡片抬亮一大截，accent / cool / warm
   * 三个前景色当场跌到 4.2 以下（`scripts/contrast-check.mjs` 会拦）。
   * 这里取一档亮度和 `coolGlow` 相当的青，色相还是那个青，光感一致。
   */
  static readonly frostGlow = '#46B4C0';

  /** 给 #RRGGBB 加上 alpha，返回 ArkUI 认的 #AARRGGBB。 */
  static alpha(hex: string, alpha: number): string {
    const clamped = Math.min(1, Math.max(0, alpha));
    const value = Math.round(clamped * 255);
    const head = value < 16 ? `0${value.toString(16)}` : value.toString(16);
    return `#${head}${hex.replace('#', '')}`;
  }

  /**
   * 把资源色解析成 Canvas 认的十六进制串。
   *
   * Canvas 的 `fillStyle` / `strokeStyle` 只吃字符串，喂 `$r(...)` 是画不出来的。
   * 走一次 resourceManager 而不是在这里再抄一份色值：深浅色切换时资源会自己给对的那套，
   * 抄下来的常量不会跟着变。
   */
  static resolve(context: Context, color: Resource, fallback: string): string {
    try {
      const argb = context.resourceManager.getColorSync(color.id);
      // getColorSync 给的是 0xAARRGGBB 的有符号整数，无符号化后补足八位。
      const hex = (argb >>> 0).toString(16).padStart(8, '0');
      return `#${hex}`;
    } catch (e) {
      return fallback;
    }
  }
}
