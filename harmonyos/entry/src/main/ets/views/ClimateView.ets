import { HdsNavDestination, HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { ClimateMode, ClimateModeInfo } from '../core/SignalSchema';
import { LeapFormat } from '../core/LeapModels';
import { LeapBackground, CardLabel, GlassCard, GlassActionCard } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { PageMetrics } from './components/PageHeader';

@ComponentV2
export struct ClimateView {
  store: VehicleStore = vehicleStore;
  /** 二级页的跳转由根页面代劳，这里只报路由名（照 `ChargeView` 那套）。 */
  @Event onPush: (route: string) => void = () => {
  };
  /**
   * 温度连点的防抖任务。只由 +/- 按钮启动——不能挂在温度值上观察，
   * 因为车况轮询也会写这个值，那样等于把车端自己的设定当成用户操作再发回去。
   */
  private temperaturePush: number = -1;

  aboutToDisappear(): void {
    // 调完温度立刻退出去的话，那条还没发的指令就不该再发了。
    if (this.temperaturePush >= 0) {
      clearTimeout(this.temperaturePush);
      this.temperaturePush = -1;
    }
  }

  private get tintHex(): string {
    if (!this.store.climateOn) {
      return LeapColors.coolGlow;
    }
    return this.store.climateMode === ClimateMode.hot ? LeapColors.warmGlow : LeapColors.coolGlow;
  }

  private get tint(): ResourceColor {
    if (!this.store.climateOn) {
      return LeapStyle.cool;
    }
    return this.store.climateMode === ClimateMode.hot ? LeapStyle.warm : LeapStyle.cool;
  }

  /** 松手 0.8 秒后再下发，避免连点 +/- 打出一串远控请求。 */
  private scheduleTemperaturePush(): void {
    if (this.temperaturePush >= 0) {
      clearTimeout(this.temperaturePush);
    }
    this.temperaturePush = setTimeout(() => {
      this.temperaturePush = -1;
      this.store.pushClimateIfRunning();
    }, 800);
  }

  private get stateLine(): string {
    if (!this.store.climateOn) {
      return '空调已关闭 · 保留上次设定';
    }
    // 只有车真报上来的模式才敢写进这句。读不到就只说「运行中」，
    // 不拿本机草稿冒充车上正在跑的模式。
    const mode = this.confirmedMode;
    return mode === null ? '空调运行中' : `空调运行中 · ${ClimateModeInfo.label(mode)}`;
  }

  /** 车况里能确认的模式。读不到返回 null。 */
  private get confirmedMode(): ClimateMode | null {
    const reported = this.store.state?.climateMode ?? null;
    if (reported !== null) {
      return reported;
    }
    return this.store.state?.acAutoMode === true ? ClimateMode.auto : null;
  }

  /**
   * 这一档要不要高亮。
   *
   * 车说了算：能确认就按车上的；车明确说「不在自动」时，哪怕本机草稿是自动也不许高亮——
   * 用户点了「自动」车却没接受，界面还亮着自动，那就是在骗人。
   * 剩下确实无从确认的（手动时的冷热），才退回本机草稿。
   */
  private isSelected(mode: ClimateMode): boolean {
    const confirmed = this.confirmedMode;
    if (confirmed !== null) {
      return confirmed === mode;
    }
    if (this.store.state?.acAutoMode === false && mode === ClimateMode.auto) {
      return false;
    }
    return this.store.climateMode === mode;
  }

  private static symbol(mode: ClimateMode): Resource {
    switch (mode) {
      case ClimateMode.cold:
        return $r('sys.symbol.snowflake');
      case ClimateMode.hot:
        return $r('sys.symbol.flame');
      case ClimateMode.vent:
        return $r('sys.symbol.car_ac');
      default:
        return $r('sys.symbol.auto_mode');
    }
  }

  build() {
    // 二级页：标题栏和返回键交给系统，页面自己不再画页头。
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopEnd }) {
        // 空调关着时光晕压到六成，同 iOS 的 `LeapBackground(tint: cool.opacity(0.6))`：
        // 关机态还给满强度的话，这页开着和关着看起来是同一个画面。
        LeapBackground({ tint: this.tintHex, tintIntensity: this.store.climateOn ? 1 : 0.6 })

        Scroll() {
          Column({ space: 10 }) {
            // 让开浮在内容之上的那条标题栏，否则温度盘和返回键叠成一团。
            Column()
              .width('100%')
              .height(PageMetrics.navTopInset)
            // 内容比屏幕短。多出来的空白分摊在温度盘上下和快捷动作之前，
            // 而不是全堆在一处成为页面中间一个洞。
            Blank()
            this.temperatureDial()
            this.powerSwitch()
            Blank()
            this.modePicker()
            this.modeNotice()
            this.fanControl()
            this.circulationRow()
            this.quickActions()
            // 最后一块内容自己让出底部那点呼吸。
            //
            // 这个空块必须是滚动内容里的最后一个子节点，不能做成 Scroll 的兄弟：
            // 做兄弟会把它从视口高度里扣掉，整页内容跟着上移一截。
            // 也不能写成 padding——ArkUI 的尺寸是 content-box，
            // 加在 `minHeight: '100%'` 的容器上是加在那 100% 之外的，根本不参与布局。
            Column()
              .width('100%')
              .height(PageMetrics.navBottomInset)
          }
          .width('100%')
          .constraintSize({ minHeight: '100%' })
          .padding({ left: 16, right: 16 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)

        // 页内所有控件都受同一个 `isSendingCommand` 管，指示器就做成页级的一个，
        // 浮在正文右上角——不管滚到哪儿都看得见，也不占正文布局。
        // 页头交给系统之后它没地方挂了，改成压在内容层上。
        //
        // 原来是给每组控件挂 `.opacity(0.55)` 表示「下发中」。那个做法会把底和前景
        // 一起拉向背景：整块 0.5 时「关闭空调」量出来只有 2.51:1，和上架检测点名的
        // 1.86 是同一个坑。变淡一律不用来表达状态，改成禁用 + 一个明确的转圈。
        if (this.store.isSendingCommand) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(LeapStyle.textSecondary)
            .margin({ top: 8, right: 16 })
        }
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      style: LeapMaterial.navigationTitleBarStyle(),
      content: {
        title: { mainTitle: '空调' },
        menu: { value: this.titleBarMenu() }
      },
      avoidLayoutSafeArea: true
    })
  }

  /** 右上「预约」：进预约空调子页（cmdid 171，同 iOS 工具栏那颗日历钟）。 */
  private titleBarMenu(): HdsNavigationMenuItemOptions[] {
    return [{
      content: {
        icon: new SymbolGlyphModifier($r('sys.symbol.calendar_badge_clock')),
        label: '预约空调',
        action: () => {
          this.onPush('climateAppointment');
        }
      }
    }];
  }

  /**
   * 主开关。整行一条，摆在温度盘正下方。
   *
   * 原来是页头右上角一个 32×32 的图标，贴着屏幕边角，单手根本按不到——
   * iOS 那版放在导航栏工具栏里是合理的，但那套热区和手势习惯搬不过来。
   * 这里是全页最重要的一个动作，就该在拇指够得到的地方，并且用文字说清楚按下去会怎样。
   */
  @Builder
  powerSwitch() {
    Row({ space: 8 }) {
      // 开着时底是实心主色，前景走 onAccent 而不是白色：深色的 accent 是亮绿，
      // 白字压上去只有 1.96:1。关着时底退回玻璃表面，用常规主文本色。
      SymbolGlyph($r('sys.symbol.power'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor([this.store.climateOn ? LeapStyle.onAccent : LeapStyle.textPrimary])
      Text(this.store.climateOn ? '关闭空调' : '开启空调')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.store.climateOn ? LeapStyle.onAccent : LeapStyle.textPrimary)
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(26)
    // 开着时是实心主色，一眼看得出「现在是开的」；关着时退回玻璃表面。
    .backgroundColor(this.store.climateOn ? LeapStyle.accent : Color.Transparent)
    .backgroundEffect(this.store.climateOn ? undefined : LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    // 下发中只禁用，不变淡（变淡到 0.5 时对比度只剩 2.51:1）。转圈在页头。
    .enabled(!this.store.isSendingCommand)
    .onClick(() => {
      this.store.applyClimate(!this.store.climateOn);
    })
  }

  // MARK: - 温度

  @Builder
  temperatureDial() {
    Column({ space: 12 }) {
      Text(this.stateLine)
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)

      Row({ space: 26 }) {
        this.stepButton($r('sys.symbol.minus'), () => {
          this.store.climateTemperature = Math.max(18, this.store.climateTemperature - 1);
          this.scheduleTemperaturePush();
        })

        Stack({ alignContent: Alignment.TopEnd }) {
          Text(String(this.store.climateTemperature))
            .fontSize(78)
            .fontWeight(FontWeight.Lighter)
            .fontFeature('"tnum" 1')
            // 关机时压暗表示「这是待机的设定值」，但不能压到 textTertiary——
            // 那一级在浅色玻璃上几乎读不出来，而这是整页最大的一个数字。
            .fontColor(this.store.climateOn ? LeapStyle.textPrimary : LeapStyle.textSecondary)
            .animation({ duration: 180, curve: Curve.Sharp })
          // 全 App 只有这里用裸「°」：78 号的目标温度旁边再挂个 C 会打断视觉，
          // 而且这个符号是手动定位到右上角的，位置本来就对。
          // 其余所有温度读数都写「°C」。
          Text('°')
            .fontSize(28)
            .fontWeight(FontWeight.Lighter)
            .fontColor(LeapStyle.textSecondary)
            .offset({ x: 20, y: 10 })
        }

        this.stepButton($r('sys.symbol.plus'), () => {
          this.store.climateTemperature = Math.min(32, this.store.climateTemperature + 1);
          this.scheduleTemperaturePush();
        })
      }

      this.ambientReadings()
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  ambientReadings() {
    Row({ space: 14 }) {
      if (this.store.state?.indoorTemp !== null && this.store.state?.indoorTemp !== undefined) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.car_fill'))
            .fontSize(14)
            .fontColor([LeapStyle.textTertiary])
          Text(`车内 ${LeapFormat.temperature(this.store.state!.indoorTemp!)} °C`)
            .fontSize(11)
            .fontColor(LeapStyle.textTertiary)
        }
      }
      if (this.store.state?.outdoorTemp !== null && this.store.state?.outdoorTemp !== undefined) {
        Row({ space: 4 }) {
          // 同样换圆底版：细长的 `thermometer_medium` 11vp 只有 4vp 宽，
          // 过不了 8vp 硬线，放大到能过又会比旁边 11vp 的字大一圈。
          SymbolGlyph($r('sys.symbol.thermometer_circle'))
            .fontSize(14)
            .fontColor([LeapStyle.textTertiary])
          Text(`车外 ${Math.round(this.store.state!.outdoorTemp!)} °C`)
            .fontSize(11)
            .fontColor(LeapStyle.textTertiary)
        }
      }
    }
  }

  /**
   * 用 Row 而不是 Button 兜住。Button 自带一层背景，再挂 `backgroundBlurStyle`
   * 会在深色下渲染成一个刺眼的纯白圆——同页的卡片都是深的，只有这两个圆是白的。
   * 页面里所有挂系统材质的表面都用普通容器，观感才统一。
   */
  @Builder
  stepButton(symbol: Resource, action: () => void) {
    Row() {
      SymbolGlyph(symbol)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor([LeapStyle.textPrimary])
    }
    .width(54)
    .height(54)
    .justifyContent(FlexAlign.Center)
    .borderRadius(27)
    .backgroundEffect(LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    .onClick(action)
  }

  // MARK: - 模式

  @Builder
  modePicker() {
    Row({ space: 6 }) {
      ForEach(ClimateModeInfo.all(), (mode: ClimateMode) => {
        Row({ space: 5 }) {
          SymbolGlyph(ClimateView.symbol(mode))
            .fontSize(14)
            .fontColor([this.isSelected(mode) ? LeapStyle.textPrimary : LeapStyle.textSecondary])
          Text(ClimateModeInfo.label(mode))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .fontColor(this.isSelected(mode) ? LeapStyle.textPrimary : LeapStyle.textSecondary)
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .padding({ top: 11, bottom: 11 })
        .borderRadius(22)
        .backgroundColor(this.isSelected(mode) ? LeapStyle.selectedFill : Color.Transparent)
        .animation({ duration: 180, curve: Curve.Sharp })
        .onClick(() => {
          this.store.climateMode = mode;
          this.store.pushClimateIfRunning();
        })
      }, (mode: ClimateMode) => mode)
    }
    .width('100%')
    .padding(5)
    .borderRadius(28)
    .backgroundEffect(LeapMaterial.cardEffect)
  }

  /**
   * 模式选择器下面那句：说清楚高亮的那一档是车报的还是本机记的。
   *
   * C11 只报「自动 / 手动」，冷热一次都没报过。不说明的话，用户会以为
   * 「App 高亮着制冷」等于「车上正在制冷」。
   */
  @Builder
  modeNotice() {
    if (this.store.climateOn && this.store.state?.acModeRaw === null) {
      Text(this.store.state?.acAutoMode === null
        ? '这台车不上报空调模式，上面选中的是本机记录的上次设定。'
        : '这台车只上报是不是自动模式，制冷还是制热它不报——那两档高亮的是本机记录。')
        .fontSize(11)
        .fontColor(LeapStyle.textTertiary)
        .width('100%')
        .padding({ left: 4, right: 4 })
    }
  }

  // MARK: - 风量

  @Builder
  fanControl() {
    GlassCard() {
      Column({ space: 12 }) {
        Row() {
          CardLabel({ text: '风量' })
          Blank()
          Text(`${this.store.climateFanLevel} 档`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
        }
        .width('100%')

        Row({ space: 6 }) {
          ForEach([1, 2, 3, 4, 5, 6, 7], (level: number) => {
            // 上方留白把柱子压到底部对齐，形成递增的阶梯。
            Column() {
              Blank()
              Column()
                .width('100%')
                .height(12 + level * 4.5)
                .borderRadius(5)
                .backgroundColor(level <= this.store.climateFanLevel
                  ? (this.store.climateOn ? LeapStyle.cool : LeapStyle.mutedFill)
                  : LeapStyle.separator)
                .animation({ duration: 180, curve: Curve.Sharp })
            }
            .layoutWeight(1)
            .height(44)
            .justifyContent(FlexAlign.End)
            .onClick(() => {
              this.store.climateFanLevel = level;
              this.store.pushClimateIfRunning();
            })
          }, (level: number) => String(level))
        }
        .width('100%')
        .height(44)
        .alignItems(VerticalAlign.Bottom)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  // MARK: - 循环模式

  /**
   * 这里原来还并排放着一张「自动温控 / 手动温控」卡（车况字段 `acTempMode`）。
   * 它是只读的——`cmdid 170` 的 state 只有 operate/temperature/windlevel/mode/circle/wshld/position
   * 七个字段，demo 里 `operate` 只出现过 `manual` 和 `off`，没有切换温控模式的入口。
   * 但它长得和旁边可点的「内循环」一模一样，用户点了没反应只会以为是坏了，所以撤掉。
   *
   * 上色的条件带上 `climateOn`：空调关着的时候温度数字是灰的、风量柱是灰的，
   * 这张卡再亮着蓝色就成了整页唯一还带色的控件，看上去像空调其实开着。
   * 内循环的设定值仍然保留（和温度、风量一样是「下次开机用的设定」），只是不再高亮。
   */
  @Builder
  circulationRow() {
    GlassActionCard({
      radius: LeapStyle.tileRadius,
      tintHex: this.store.climateOn && this.store.climateCircleIn ? LeapColors.coolGlow : '',
      onTap: () => {
        this.store.climateCircleIn = !this.store.climateCircleIn;
        this.store.pushClimateIfRunning();
      }
    }) {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          SymbolGlyph(this.store.climateCircleIn
            ? $r('sys.symbol.car_internal_circulation_fill')
            : $r('sys.symbol.wind'))
            .fontSize(15)
            .fontColor([LeapStyle.textPrimary])
          Text(this.store.climateCircleIn ? '内循环' : '外循环')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
        }
        Text('轻点切换')
          .fontSize(11)
          .fontColor(LeapStyle.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  // MARK: - 快捷动作

  @Builder
  quickActions() {
    Row({ space: 10 }) {
      this.quickAction('快速降温', $r('sys.symbol.snowflake'), LeapStyle.cool, () => {
        this.store.quickCool();
      })
      this.quickAction('快速制热', $r('sys.symbol.flame'), LeapStyle.warm, () => {
        this.store.quickHeat();
      })
      this.quickAction('除霜', $r('sys.symbol.windshield_front_and_heat_waves'), LeapStyle.frost, () => {
        this.store.defrost();
      })
      // 快速除味：通风 + 外循环 + 7 档，判据不比温度（见 `LeapCommand.deodorize`）。
      this.quickAction('除味', $r('sys.symbol.wind'), LeapStyle.accent, () => {
        this.store.deodorize();
      })
    }
    .width('100%')
    // 同上：不变淡，页头那个转圈就是这一页统一的「下发中」。
    .enabled(!this.store.isSendingCommand)
  }

  /** 四个按钮等宽：图标在上文字在下，中文不会被挤断。 */
  @Builder
  quickAction(title: string, symbol: Resource, tint: ResourceColor, action: () => void) {
    Column({ space: 6 }) {
      SymbolGlyph(symbol)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor([tint])
      Text(title)
        .fontSize(12)
        .fontColor(tint)
    }
    .layoutWeight(1)
    .padding({ top: 14, bottom: 14 })
    .borderRadius(LeapStyle.tileRadius)
    .backgroundEffect(LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    .onClick(action)
  }
}
