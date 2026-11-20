import { HdsNavDestination, HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import {
  SeatPosition, SeatPositions, SeatComfortChannel, SeatChannels,
  FridgeSetting, FridgeState, FridgeMode, FridgeStyle, FridgePreset, FridgeText
} from '../../core/CabinComfort';
import { CardLabel, GlassActionCard, GlassCard, LeapBackground } from '../../design/LeapGlass';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../../design/LeapStyle';
import { FeatureChrome, FeatureNote } from './FeatureScaffold';

/** 把 `#RRGGBB` 调成带透明度的 `#AARRGGBB`。资源色拿不到分量，座位档位的深浅靠它。 */
function withAlpha(hex: string, alpha: number): string {
  const value = Math.round(Math.min(1, Math.max(0, alpha)) * 255);
  const text = value.toString(16).toUpperCase();
  return `#${text.length < 2 ? '0' + text : text}${hex.substring(1)}`;
}

/**
 * 舒适座舱：座椅加热 / 通风、方向盘加热、后视镜加热。对应 iOS `ComfortCabinView`。
 *
 * 和空调页最大的不同是**这一页的状态是真的**：八个座椅信号、方向盘的 `1816`、
 * 后视镜的 `49`/`50` 全在实测 C16 的真实 signalMap 里，档位能直接回显、指令成败能靠信号确认。
 * 草稿只活在点击到车确认之间（见 `VehicleStore.cabinDrafts`）。
 *
 * 五条下发指令都**没有实车样本**。
 */
@ComponentV2
export struct ComfortCabinView {
  @Local store: VehicleStore = vehicleStore;
  /** 当前看的是加热还是通风。纯视图状态，不下发。 */
  @Local channel: SeatComfortChannel = SeatComfortChannel.heating;

  aboutToDisappear(): void {
    // 调完档位立刻退出去的话，那条还没发的指令就不该再发了。同空调页。
    this.store.cancelPendingCabinPushes();
  }

  private get tintHex(): string {
    return this.channel === SeatComfortChannel.heating ? LeapColors.warmGlow : LeapColors.coolGlow;
  }

  /** 任一通道、任一座位读得到。决定要不要画「加热 / 通风」分段。 */
  private get hasAnySeat(): boolean {
    return SeatChannels.all.some((channel: SeatComfortChannel): boolean =>
      SeatPositions.all.some((position: SeatPosition): boolean => this.store.seatLevel(position, channel) !== null));
  }

  /** 当前通道下有座位可画。 */
  private get hasSeatInChannel(): boolean {
    return SeatPositions.all.some((position: SeatPosition): boolean =>
      this.store.seatLevel(position, this.channel) !== null);
  }

  private get hasAnything(): boolean {
    return this.hasAnySeat || this.store.steeringWheelLevel !== null || this.store.mirrorHeatingOn !== null;
  }

  private rowVisible(row: SeatPosition[]): boolean {
    return row.some((position: SeatPosition): boolean => this.store.seatLevel(position, this.channel) !== null);
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopEnd }) {
        LeapBackground({ tint: this.tintHex })

        Scroll() {
          Column({ space: 16 }) {
            Column()
              .width('100%')
              .height(FeatureChrome.topInset)

            // 两条通道都读不到任何座位时，分段和座位图整块不画——
            // 不然剩一个只有方向盘图标的空框，等于摆了个点不动的格子。
            if (this.hasAnySeat) {
              this.channelPicker()
              if (this.hasSeatInChannel) {
                this.seatMap()
              }
            }
            if (this.store.steeringWheelLevel !== null) {
              this.steeringWheelCard()
            }
            if (this.store.mirrorHeatingOn !== null) {
              this.mirrorCard()
            }
            if (!this.hasAnything) {
              this.emptyNotice()
            }

            Column()
              .width('100%')
              .height(FeatureChrome.bottomInset)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)

        // 下发中的统一指示，同空调页：不变淡，只禁用 + 转圈。
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
        title: { mainTitle: '舒适座舱' },
        menu: { value: this.titleBarMenu() }
      },
      avoidLayoutSafeArea: true
    })
  }

  /** 右上「全部关闭」。批量指令，点了先问一句。 */
  private titleBarMenu(): HdsNavigationMenuItemOptions[] {
    return [{
      content: {
        icon: new SymbolGlyphModifier($r('sys.symbol.power')),
        label: '全部关闭',
        action: () => {
          this.confirmCloseAll();
        }
      }
    }];
  }

  private confirmCloseAll(): void {
    if (!this.store.cabinAnythingOn) {
      this.store.show('座舱加热与通风都已关闭');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '关闭所有座舱加热与通风？',
      message: '会把当前开着的座椅、方向盘和后视镜逐条关掉。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '全部关闭',
        fontColor: LeapStyle.caution,
        action: () => {
          this.store.closeAllCabinComfort();
        }
      }
    });
  }

  /**
   * 车况一项都没报回来时给一句话，而不是留一整屏空白。
   * 这不是「本车不支持」——入口本身已经过了支持门控，走到这儿还全空，
   * 最常见的原因是车在休眠、这一轮车况字段缺了一片。
   */
  @Builder
  emptyNotice() {
    FeatureNote({
      symbol: $r('sys.symbol.moon_z_fill'),
      text: '暂时读不到座舱状态。车辆休眠时这一批字段会整片缺失，等车况刷新后会自动出现。'
    })
  }

  // MARK: - ① 加热 / 通风

  @Builder
  channelPicker() {
    Row({ space: 6 }) {
      ForEach(SeatChannels.all, (item: SeatComfortChannel) => {
        Row({ space: 5 }) {
          SymbolGlyph(item === SeatComfortChannel.heating ? $r('sys.symbol.heat_waves') : $r('sys.symbol.wind'))
            .fontSize(14)
            .fontColor([this.channel === item ? LeapStyle.textPrimary : LeapStyle.textSecondary])
          Text(SeatChannels.label(item))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .fontColor(this.channel === item ? LeapStyle.textPrimary : LeapStyle.textSecondary)
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .padding({ top: 11, bottom: 11 })
        .borderRadius(22)
        .backgroundColor(this.channel === item ? LeapStyle.selectedFill : Color.Transparent)
        .animation({ duration: 180, curve: Curve.Sharp })
        .onClick(() => {
          this.channel = item;
        })
      }, (item: SeatComfortChannel) => `${item}-${this.channel === item ? 1 : 0}`)
    }
    .width('100%')
    .padding(5)
    .borderRadius(28)
    .backgroundEffect(LeapMaterial.cardEffect)
  }

  // MARK: - ② 车内俯视座位图

  @Builder
  seatMap() {
    Column({ space: 18 }) {
      // 仪表台那一道：方向盘正对主驾座位，一眼看出车头朝上、主驾在左。
      Row({ space: 26 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.steeringwheel'))
            .fontSize(18)
            .fontColor([LeapStyle.textTertiary])
        }
        .width(64)
        Column()
          .width(64)
          .height(1)
      }
      .accessibilityLevel('no')

      if (this.rowVisible(SeatPositions.front)) {
        this.seatRow(true)
      }
      if (this.rowVisible(SeatPositions.rear)) {
        this.seatRow(false)
      }
    }
    .width('100%')
    .padding({ top: 20, bottom: 20 })
    .borderRadius(28)
    .backgroundEffect(LeapMaterial.cardEffect)
  }

  /**
   * 一排两座。座位做成独立组件（`SeatTile`）而不是带参 `@Builder`：
   * 带参 builder 是值传递，档位变了也不重画（见 harmony-builder-param-stale）。
   * 同一行里个别座位读不到时留一块等大的透明占位，左右两座不会因为少一个而跑到中间去。
   */
  @Builder
  seatRow(front: boolean) {
    Row({ space: 26 }) {
      ForEach(front ? SeatPositions.front : SeatPositions.rear, (position: SeatPosition) => {
        if (this.store.seatLevel(position, this.channel) !== null) {
          SeatTile({
            seat: position,
            channel: this.channel,
            level: this.store.seatLevel(position, this.channel) ?? 0,
            onTap: () => {
              this.store.cycleSeat(position, this.channel);
            }
          })
        } else {
          Column()
            .width(64)
            .height(93)
        }
      }, (position: SeatPosition) =>
        `${position}-${this.channel}-${this.store.seatLevel(position, this.channel) ?? 'x'}`)
    }
  }

  // MARK: - ③ 方向盘加热

  @Builder
  steeringWheelCard() {
    GlassCard({ radius: LeapStyle.tileRadius }) {
      Column({ space: 12 }) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.steering_wheel_heat_waves'))
            .fontSize(16)
            .fontColor([(this.store.steeringWheelLevel ?? 0) > 0 ? LeapStyle.warm : LeapStyle.textPrimary])
          Text('方向盘加热')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
          Blank()
          // 剩余分钟只在加热确实开着时才给——信号 1624 在关闭时也非 0，
          // 取值判据收在 `VehicleState.steeringWheelHeatMinutes` 里。
          if (this.store.steeringWheelHeatMinutes !== null) {
            Text(`约剩 ${this.store.steeringWheelHeatMinutes} 分钟`)
              .fontSize(11)
              .fontColor(LeapStyle.textTertiary)
          }
        }
        .width('100%')

        // 方向盘只有两档（弱 / 强），和座椅的三档不是一套量程。
        Row({ space: 6 }) {
          ForEach([0, 1, 2], (level: number) => {
            Text(level === 0 ? '关' : (level === 1 ? '弱' : '强'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Center)
              .fontColor(this.store.steeringWheelLevel === level ? LeapStyle.textPrimary : LeapStyle.textSecondary)
              .layoutWeight(1)
              .padding({ top: 10, bottom: 10 })
              .borderRadius(20)
              .backgroundColor(this.store.steeringWheelLevel === level ? LeapStyle.selectedFill : Color.Transparent)
              .onClick(() => {
                this.store.setSteeringWheelHeat(level);
              })
          }, (level: number) => `${level}-${this.store.steeringWheelLevel === level ? 1 : 0}`)
        }
        .width('100%')
        .padding(4)
        .borderRadius(24)
        .backgroundColor(LeapStyle.fillNeutral)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  // MARK: - ④ 后视镜加热

  @Builder
  mirrorCard() {
    GlassActionCard({
      radius: LeapStyle.tileRadius,
      tintHex: this.store.mirrorHeatingOn === true ? LeapColors.frostGlow : '',
      onTap: () => {
        if (!this.store.isSendingCommand) {
          this.store.toggleMirrorHeating();
        }
      }
    }) {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          // 车端那个信号（1946）本来就是「后风挡**及外后视镜**电加热除雾」，
          // 用后风挡加热这个字形比任何后视镜字形都贴。
          SymbolGlyph($r('sys.symbol.windshield_rear_and_heat_waves'))
            .fontSize(16)
            .fontColor([LeapStyle.textPrimary])
          Text('后视镜加热')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
          Blank()
          Text(this.store.mirrorHeatingOn === true ? '已开启' : '已关闭')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.store.mirrorHeatingOn === true ? LeapStyle.frost : LeapStyle.textSecondary)
        }
        .width('100%')
        // 这是五项里唯一官方 App 自己都没做的功能：内部码 440 在官方包里连中文文案都没有。
        // 按下去没反应时，用户该先知道这件事，而不是以为我们坏了。
        Text(this.store.state?.mirrorHeatingMismatched === true
          ? '左右状态不一致 · 该指令未经官方 App 验证'
          : '轻点切换 · 该指令未经官方 App 验证')
          .fontSize(11)
          .fontColor(LeapStyle.textSecondary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/**
 * 座位图里的一座。组件化是为了档位变了能跟着重画（`@Param` 会更新，builder 参数不会）。
 *
 * 档位表达：0 = 淡灰底 + 模式图标；1…3 = 模式色由浅到深 + 大号数字。轻点 `0→1→2→3→0` 循环，
 * 800 ms 防抖后只发最后那一档（`VehicleStore.setSeat`）。
 */
@ComponentV2
struct SeatTile {
  @Param seat: SeatPosition = SeatPosition.driver;
  @Param channel: SeatComfortChannel = SeatComfortChannel.heating;
  @Param level: number = 0;
  @Event onTap: () => void = () => {
  };

  private get fill(): ResourceColor {
    if (this.level <= 0) {
      return LeapStyle.fillNeutral;
    }
    const hex = this.channel === SeatComfortChannel.heating ? LeapColors.warmGlow : LeapColors.coolGlow;
    return withAlpha(hex, 0.24 + 0.26 * (this.level - 1));
  }

  build() {
    Column({ space: 6 }) {
      Column({ space: 3 }) {
        // 靠背
        Column()
          .width(56)
          .height(16)
          .borderRadius(7)
          .backgroundColor(this.fill)
        // 坐垫 + 档位
        Stack() {
          if (this.level > 0) {
            Text(String(this.level))
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .fontFeature('"tnum" 1')
              .fontColor(LeapStyle.textPrimary)
          } else {
            SymbolGlyph(this.channel === SeatComfortChannel.heating ? $r('sys.symbol.heat_waves') : $r('sys.symbol.wind'))
              .fontSize(15)
              .fontColor([LeapStyle.textTertiary])
          }
        }
        .width(64)
        .height(52)
        .borderRadius(12)
        .backgroundColor(this.fill)
        .border({ width: this.level > 0 ? 0 : 1, color: LeapStyle.glassEdge, radius: 12 })
      }
      Text(SeatPositions.label(this.seat))
        .fontSize(11)
        .fontColor(this.level > 0 ? LeapStyle.textSecondary : LeapStyle.textTertiary)
    }
    .width(64)
    .height(93)
    .visualEffect(LeapMaterial.pressable)
    .accessibilityGroup(true)
    .accessibilityText(`${SeatPositions.label(this.seat)}座椅${SeatChannels.label(this.channel)}，`
      + (this.level > 0 ? `${this.level} 档` : '已关闭'))
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * 车载冰箱：电源、三个预设、目标温度、制冷风格、离车保持。对应 iOS `FridgeView`。
 *
 * 这一页在**没装冰箱的车上整个不出现**（入口门控见 `VehicleStore.fridgeSupported`）。
 * 实测用的那台 C16 就是这种情况：`abilities` 不含 `76`，signalMap 里九个冰箱信号一个都不报。
 *
 * cmdid `500` 的 state 是**全量**的——改一项也要把八个字段一起发出去，
 * 所以这页维护的是整份草稿（`VehicleStore.fridgeDraft`），不是增量。
 */
@ComponentV2
export struct FridgeView {
  @Local store: VehicleStore = vehicleStore;

  aboutToAppear(): void {
    this.store.seedFridgeDraft();
  }

  aboutToDisappear(): void {
    this.store.cancelPendingCabinPushes();
  }

  /**
   * 界面读的那份草稿。车况还没回来时给一份中性默认值，
   * 这不是「伪造车况」——草稿本来就是本机准备要发的东西，必须有个值；
   * 上面那行状态文字读的仍然是车况，读不到就不显示。
   */
  private get draft(): FridgeSetting {
    const draft = this.store.fridgeDraft;
    if (draft !== null) {
      return draft;
    }
    const fridge = this.store.state?.fridgeState ?? null;
    return fridge !== null ? fridge.asSetting() : new FridgeSetting();
  }

  private get fridge(): FridgeState | null {
    return this.store.state?.fridgeState ?? null;
  }

  private get tintHex(): string {
    if (!this.draft.enabled) {
      return LeapColors.frostGlow;
    }
    return this.draft.mode === FridgeMode.hot ? LeapColors.warmGlow : LeapColors.coolGlow;
  }

  private get tint(): ResourceColor {
    if (!this.draft.enabled) {
      return LeapStyle.textSecondary;
    }
    return this.draft.mode === FridgeMode.hot ? LeapStyle.warm : LeapStyle.cool;
  }

  /** 改一项：复制一份、改、整份换回去，再交给 store 走防抖。 */
  private update(change: (setting: FridgeSetting) => void): void {
    const next = this.draft.copy();
    change(next);
    this.store.updateFridgeDraft(next);
  }

  /** 这一行读的是**车况**，不是草稿——它要回答「车上现在到底什么状态」。读不到就整行不显示。 */
  private get stateLine(): string | null {
    const fridge = this.fridge;
    if (fridge === null) {
      return null;
    }
    if (!fridge.enabled) {
      return '冰箱已关闭 · 保留上次设定';
    }
    const parts: string[] = [];
    if (fridge.mode === FridgeMode.hot) {
      parts.push(`保温 ${FridgeSetting.hotTemp} ℃`);
    } else if (fridge.targetTemp !== null) {
      parts.push(`制冷 ${fridge.targetTemp} ℃`);
    } else {
      parts.push(FridgeText.modeLabel(fridge.mode));
    }
    parts.push(FridgeText.styleLabel(fridge.style));
    if (fridge.parkEnabled) {
      parts.push('离车保持中');
    }
    return parts.join(' · ');
  }

  private get parkEndText(): string | null {
    const endsAt = this.fridge?.parkEndsAt ?? null;
    if (endsAt === null) {
      return null;
    }
    const date = new Date(endsAt);
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `预计 ${pad(date.getHours())}:${pad(date.getMinutes())} 结束`;
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopEnd }) {
        LeapBackground({ tint: this.tintHex, tintIntensity: this.draft.enabled ? 1 : 0.6 })

        Scroll() {
          Column({ space: 16 }) {
            Column()
              .width('100%')
              .height(FeatureChrome.topInset)

            if (this.fridge !== null && this.fridge.hasFault) {
              this.faultBanner()
            }
            this.powerSection()
            if (this.draft.enabled) {
              this.presetPicker()
              this.temperatureCard()
              this.styleCard()
              this.parkCard()
            }

            Column()
              .width('100%')
              .height(FeatureChrome.bottomInset)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)

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
    .titleBar(FeatureChrome.titleBar('车载冰箱'))
  }

  // MARK: - 故障

  /** 不编造排查指引：这个码的含义我们没有任何对照表。 */
  @Builder
  faultBanner() {
    FeatureNote({
      symbol: $r('sys.symbol.exclamationmark_triangle_fill'),
      tint: LeapStyle.caution,
      text: `冰箱自检故障（码 ${this.fridge?.fault ?? 0}）。车端报了一个非零故障码，具体含义以车机或售后为准。`
    })
  }

  // MARK: - 电源

  @Builder
  powerSection() {
    Column({ space: 14 }) {
      Stack() {
        Column({ space: 2 }) {
          SymbolGlyph(this.draft.mode === FridgeMode.hot ? $r('sys.symbol.cup_fill') : $r('sys.symbol.snowflake'))
            .fontSize(34)
            .fontColor([this.tint])
          Text(`${this.draft.wireTemperature} °C`)
            .fontSize(26)
            .fontWeight(FontWeight.Lighter)
            .fontFeature('"tnum" 1')
            .fontColor(this.draft.enabled ? LeapStyle.textPrimary : LeapStyle.textSecondary)
        }
      }
      .width(142)
      .height(142)
      .borderRadius(71)
      .backgroundColor(LeapStyle.selectedFill)

      if (this.stateLine !== null) {
        Text(this.stateLine)
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
      }

      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.power'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor([this.draft.enabled ? LeapStyle.textPrimary : LeapStyle.onAccent])
        Text(this.draft.enabled ? '关闭冰箱' : '开启冰箱')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.draft.enabled ? LeapStyle.textPrimary : LeapStyle.onAccent)
      }
      .width('100%')
      .height(52)
      .justifyContent(FlexAlign.Center)
      .borderRadius(26)
      // 关着时是实心主色（要按的就是它）；开着时退回玻璃表面。同空调页电源键反过来。
      .backgroundColor(this.draft.enabled ? Color.Transparent : LeapStyle.accent)
      .backgroundEffect(this.draft.enabled ? LeapMaterial.cardEffect : undefined)
      .visualEffect(LeapMaterial.pressable)
      .enabled(!this.store.isSendingCommand)
      .onClick(() => {
        this.store.setFridgePower(!this.draft.enabled);
      })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  // MARK: - 预设

  @Builder
  presetPicker() {
    Row({ space: 6 }) {
      ForEach(FridgeText.presets, (preset: FridgePreset) => {
        Column({ space: 4 }) {
          SymbolGlyph(preset === FridgePreset.keepWarm ? $r('sys.symbol.cup_fill')
            : (preset === FridgePreset.freeze ? $r('sys.symbol.snowflake_circle_fill') : $r('sys.symbol.snowflake')))
            .fontSize(15)
            .fontColor([this.draft.preset === preset ? LeapStyle.textPrimary : LeapStyle.textSecondary])
          Text(FridgeText.presetLabel(preset))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.draft.preset === preset ? LeapStyle.textPrimary : LeapStyle.textSecondary)
        }
        .layoutWeight(1)
        .padding({ top: 10, bottom: 10 })
        .borderRadius(22)
        .backgroundColor(this.draft.preset === preset ? LeapStyle.selectedFill : Color.Transparent)
        .onClick(() => {
          this.update((setting: FridgeSetting) => {
            setting.apply(preset);
          });
        })
      }, (preset: FridgePreset) => `${preset}-${this.draft.preset === preset ? 1 : 0}`)
    }
    .width('100%')
    .padding(5)
    .borderRadius(28)
    .backgroundEffect(LeapMaterial.cardEffect)
  }

  // MARK: - 目标温度

  @Builder
  temperatureCard() {
    GlassCard() {
      Column({ space: 10 }) {
        Row() {
          CardLabel({ text: '目标温度' })
          Blank()
          Text(this.draft.mode === FridgeMode.hot ? `固定 ${FridgeSetting.hotTemp} ℃` : `${this.draft.temperature} ℃`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontFeature('"tnum" 1')
            .fontColor(LeapStyle.textPrimary)
        }
        .width('100%')

        // 保温模式下协议写死 50 ℃，滑杆无从施力，禁用而不是藏起来——
        // 藏起来会让卡片在两个模式之间跳高度。
        Slider({
          value: this.draft.temperature,
          min: FridgeSetting.minTemp,
          max: FridgeSetting.maxTemp,
          step: 1
        })
          .width('100%')
          .selectedColor(LeapStyle.cool)
          .enabled(this.draft.mode !== FridgeMode.hot)
          .accessibilityText('制冷目标温度')
          .onChange((value: number) => {
            const rounded = Math.round(value);
            if (rounded !== this.draft.temperature) {
              this.update((setting: FridgeSetting) => {
                setting.temperature = rounded;
              });
            }
          })

        if (this.draft.mode === FridgeMode.hot) {
          Text(`保温模式恒温 ${FridgeSetting.hotTemp} ℃，温度不可调。`)
            .fontSize(11)
            .fontColor(LeapStyle.textTertiary)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  // MARK: - 制冷风格

  @Builder
  styleCard() {
    GlassCard({ radius: LeapStyle.tileRadius }) {
      Row() {
        CardLabel({ text: '制冷风格' })
        Blank()
        Row({ space: 6 }) {
          ForEach([FridgeStyle.normal, FridgeStyle.turbo], (style: FridgeStyle) => {
            Text(FridgeText.styleLabel(style))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.draft.style === style ? LeapStyle.textPrimary : LeapStyle.textSecondary)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .borderRadius(18)
              .backgroundColor(this.draft.style === style ? LeapStyle.selectedFill : Color.Transparent)
              .onClick(() => {
                this.update((setting: FridgeSetting) => {
                  setting.style = style;
                });
              })
          }, (style: FridgeStyle) => `${style}-${this.draft.style === style ? 1 : 0}`)
        }
        .padding(4)
        .borderRadius(22)
        .backgroundColor(LeapStyle.fillNeutral)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  // MARK: - 离车保持

  @Builder
  parkCard() {
    GlassCard() {
      Column({ space: 12 }) {
        Row() {
          Text('离车保持')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.draft.parkEnabled })
            .selectedColor(LeapStyle.accent)
            .onChange((on: boolean) => {
              if (on !== this.draft.parkEnabled) {
                this.update((setting: FridgeSetting) => {
                  setting.parkEnabled = on;
                });
              }
            })
        }
        .width('100%')

        if (this.draft.parkEnabled) {
          Row({ space: 10 }) {
            CardLabel({ text: '工作时长' })
            Blank()
            this.hourStep($r('sys.symbol.minus'), -1)
            Text(`${this.draft.parkHours} 小时`)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontFeature('"tnum" 1')
              .fontColor(LeapStyle.textPrimary)
              .constraintSize({ minWidth: 48 })
              .textAlign(TextAlign.Center)
            this.hourStep($r('sys.symbol.plus'), 1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 截止时刻读车况（信号 11260），车端没给就不显示。
          if (this.parkEndText !== null) {
            Text(this.parkEndText)
              .fontSize(11)
              .fontColor(LeapStyle.textTertiary)
          }

          // 周期这一版不暴露：下发口径（"1"/"2"）和上报口径（0/1）对不上，
          // 哪个值是「仅本次」哪个是「每次离车」没有依据，固定发 "1"。
          Text('当前仅对本次离车生效。')
            .fontSize(11)
            .fontColor(LeapStyle.textTertiary)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  hourStep(symbol: Resource, delta: number) {
    Row() {
      SymbolGlyph(symbol)
        .fontSize(14)
        .fontColor([LeapStyle.textPrimary])
    }
    .width(36)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .borderRadius(18)
    .backgroundColor(LeapStyle.fillNeutral)
    .visualEffect(LeapMaterial.pressable)
    .onClick(() => {
      const next = Math.min(24, Math.max(1, this.draft.parkHours + delta));
      if (next !== this.draft.parkHours) {
        this.update((setting: FridgeSetting) => {
          setting.parkHours = next;
        });
      }
    })
  }
}
