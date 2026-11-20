import {
  hdsEffect,
  hdsMaterial,
  HdsTitleBarContentStyle,
  TitleBarStyleOptions,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { LeapStyle } from './LeapStyle';

/**
 * 表面材质。
 *
 * 走的全是官方接口，分两条：
 *
 * 1. **`hdsMaterial`** —— HDS 的系统材质，`MaterialType.IMMERSIVE` 就是沉浸光感那一档。
 *    它只能挂在官方组件给出的入口上（`HdsNavigation` 的标题栏、`HdsTabs` 的浮动条），
 *    由系统自己按深浅色和底下的内容算，不需要也不允许我们插手。
 * 2. **`backgroundBlurStyle`** —— 组件级系统材质，卡片的「透」由它负责。
 *    深浅色两套观感由系统给，代码里不写明暗分支。
 *
 * 一个教训记在这里：`hdsEffect` 的 `pointLight` 曾经被铺在每一张卡片、每一个按钮上，
 * 想靠它做出「光感」。真机深色模式下它给每个圆角都描了一道发白的高光边，
 * 满屏浮着一堆白框，非常难看。点光源是给特定组件点缀用的，不是页面通用底噪——
 * 官方示例里一处都没这么用。现在只留按压投影（`pressShadow`），
 * 那是官方的按下反馈，和系统其它应用一致，且只在手指按住时出现。
 */
export class LeapMaterial {
  /**
   * 可点按表面的按压反馈。按下去有形变和投影，松手复原，全程由系统渲染。
   * 不可点的卡片不要挂——给了形变反而像能按。
   */
  static readonly pressable: VisualEffect = new hdsEffect.HdsEffectBuilder()
    .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
    .buildEffect();

  /**
   * 材质的通透度。底下那层随车况变色的渐变要能糊着透上来，
   * 卡片才不是一块贴上去的实色。
   */
  static readonly cardBlur: BlurStyle = BlurStyle.COMPONENT_REGULAR;

  /**
   * 卡片的玻璃质感。
   *
   * `backgroundBlurStyle` 那几档是系统预设，深色下算出来是一块不透的中性灰——
   * 底下背景的蓝一点都透不上来，卡片看着就像贴在黑纸上的深灰方块。
   * 换成 `backgroundEffect` 把三件事分开调：
   *
   * - `color` 是垫在玻璃上的那层薄色（走资源，深浅两套），负责把卡片从背景里托起来。
   * - `saturation` 提上去，糊过之后底下的颜色不至于洗白。
   * - `adaptiveColor` 必须是 `DEFAULT`。用 `AVERAGE` 时每张卡片各自去取自己底下那片
   *   背景的平均色，背景一有明暗差（光晕就是），同一页的卡片就一张偏蓝一张偏黑，
   *   看着像是配色出了错。固定色调 + 背景模糊，玻璃感一样在，颜色却是齐的。
   *
   * HDS 的 `hdsMaterial` 帮不上这里：系统材质只对官方组件（导航标题栏、浮动页签条）
   * 开放入口，普通容器挂不上，所以卡片的质感只能自己按这几个量调出来。
   */
  static readonly cardEffect: BackgroundEffectOptions = {
    radius: 40,
    saturation: 1.6,
    brightness: 1.0,
    color: LeapStyle.glassTint,
    adaptiveColor: AdaptiveColor.DEFAULT
  };
  static readonly pillBlur: BlurStyle = BlurStyle.COMPONENT_ULTRA_THIN;
  static readonly panelBlur: BlurStyle = BlurStyle.COMPONENT_THICK;
  static readonly tileBlur: BlurStyle = BlurStyle.COMPONENT_THIN;

  /**
   * 模态浮层的材质。和 `cardEffect` 同理，但换用厚得多的 `panelTint`：
   * `backgroundBlurStyle` 的系统预设在深色下算出来是一块不透的中性灰
   * （见 `cardEffect` 的说明），浮层挂上去就会「颜色不对」。改走 `backgroundEffect`，
   * 深浅两套垫色由资源给，浮层始终是一个干净、对比度达标的面。
   */
  static readonly panelEffect: BackgroundEffectOptions = {
    radius: 48,
    saturation: 1.6,
    brightness: 1.0,
    color: LeapStyle.panelTint,
    adaptiveColor: AdaptiveColor.DEFAULT
  };

  /**
   * 标题栏上文字和图标的颜色。
   *
   * 沉浸材质默认把主标题、返回键都画成**纯白**——那一档是给「底下压着深色媒体」
   * 准备的，我们这套底噪是浅色渐变，白字浮在上面几乎看不见：浅色模式下量出来
   * 标题白 #FFFFFF 压在 #B5D2FC 的背景上只有 1.55:1，规范要求 4.5:1。
   *
   * 地图页最扎眼（底下是整屏亮白的地图），但每一个二级页都是同一个毛病，
   * 所以改在这里，不在各页各写一遍。换成 `textPrimary` 之后深浅两套各自取值，
   * 跟页面正文同一个颜色。
   */
  private static readonly titleContentStyle: HdsTitleBarContentStyle = {
    titleStyle: {
      mainTitleColor: LeapStyle.textPrimary,
      subTitleColor: LeapStyle.textSecondary
    },
    backIconStyle: { iconColor: LeapStyle.textPrimary },
    menuStyle: { iconColor: LeapStyle.textPrimary }
  };

  /**
   * HdsNavigation 标题栏的沉浸光感。这是 `hdsMaterial` 官方开放的入口之一，
   * 滚动时标题栏底下的内容按沉浸渐变糊掉，正是官方 App 的那种观感。
   *
   * `originalStyle` 和 `scrollEffectStyle` 是滚动前后两套样式，得都给——
   * 只给一套的话，滚一下标题就又变回白的。
   */
  static navigationTitleBarStyle(): TitleBarStyleOptions {
    if (!LeapMaterial.isEnabled) {
      // 没有系统材质的老系统同样是白标题，颜色照给。
      return {
        originalStyle: { contentStyle: LeapMaterial.titleContentStyle },
        scrollEffectStyle: { contentStyle: LeapMaterial.titleContentStyle }
      };
    }
    return {
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      originalStyle: { contentStyle: LeapMaterial.titleContentStyle },
      scrollEffectStyle: { contentStyle: LeapMaterial.titleContentStyle },
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: hdsMaterial.getSystemMaterialTypes().length > 0
          ? ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
          : ScrollEffectType.GRADUAL_BLUR
      }
    };
  }

  /**
   * 系统是否真的会渲染 HDS 系统材质。
   *
   * 判据抄官方示例（`HdsUtil.isSupportNewMaterialApi`）：看设备实际跑的发行版 API，
   * 而不是编译时的 SDK——同一个包装到老系统上也要能跑。6.1.0 起才有。
   */
  static get isEnabled(): boolean {
    return deviceInfo.distributionOSApiVersion >= 60100;
  }
}
