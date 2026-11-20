import { HdsNavDestination } from '@kit.UIDesignKit';
import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { ChargePlan } from '../../core/LeapModels';
import { AppointmentWeekday, WeekdayOption } from '../../core/ClimateAppointment';
import { GlassCard, LeapBackground } from '../../design/LeapGlass';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../../design/LeapStyle';
import { FeatureChrome, FeatureNote } from './FeatureScaffold';

/**
 * 电池预热。对应 iOS 的 `BatteryPreheatPreviewView`。
 *
 * 两段都是**真实下发**：
 * - 立即预热 / 停止预热走 cmdid 160；
 * - 预约预热走 cmdid 161（state 结构 2026-08-18 已真车抓包验证，见
 *   `apk-analysis/android-battery-charge-interfaces.md` §0.3），set_id 由 store 按
 *   「HarmonyOS_VIN_毫秒」构造。
 *
 * 不显示「预热开着/关着」：车端不上报可判定的预热终态（ptcState 枚举未确认），
 * 显示一个状态等于凭空断言。这里只给动作，结果交给全局提示——服务端拒了会如实弹出来。
 */
@ComponentV2
export struct BatteryPreheatView {
  @Local store: VehicleStore = vehicleStore;
  @Local scheduleEnabled: boolean = true;
  @Local scheduleHour: number = 7;
  @Local scheduleMinute: number = 30;
  /**
   * 重复星期，用预约类共用编码：**0 = 周日**、1 = 周一 … 6 = 周六（见 `AppointmentWeekday`）。
   * 2026-11-19 之前周日发的是 7，已改（和 iOS、预约空调 171 同一套）。默认工作日。
   */
  @Local scheduleDays: number[] = [1, 2, 3, 4, 5];

  private get scheduleText(): string {
    const hour = this.scheduleHour < 10 ? `0${this.scheduleHour}` : `${this.scheduleHour}`;
    const minute = this.scheduleMinute < 10 ? `0${this.scheduleMinute}` : `${this.scheduleMinute}`;
    return `${hour}:${minute}`;
  }

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: LeapColors.warmGlow })

        Scroll() {
          Column({ space: 18 }) {
            Column()
              .width('100%')
              .height(FeatureChrome.topInset)

            this.immediateSection()

            GlassCard({ radius: LeapStyle.tileRadius }) {
              this.scheduleCard()
            }

            this.saveScheduleButton()

            FeatureNote({
              symbol: $r('sys.symbol.info_circle_fill'),
              text: '预约设置会下发到车辆，是否按时生效以车辆实际表现为准。低电量、车辆已启动、'
                + '行驶中或电池不允许预热时，服务端会直接拒绝。'
            })

            if (this.store.isSendingCommand) {
              this.busyRow()
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
      }
      .width('100%')
      .height('100%')
    }
    .titleBar(FeatureChrome.titleBar('电池预热'))
  }

  /** 立即预热 / 停止预热（cmdid 160）。 */
  @Builder
  immediateSection() {
    Column({ space: 14 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.thermometer_medium'))
          .fontSize(52)
          .fontColor([LeapStyle.warm])
      }
      .width(142)
      .height(142)
      .borderRadius(71)
      .backgroundColor(LeapStyle.selectedFill)

      Text('立即预热')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(LeapStyle.textPrimary)

      Text('是否生效以车辆实际表现为准')
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)

      // 主按钮走材质底 + 暖色字，不是实心绿。
      // iOS 那边是 `leapGlassButton(prominent:).tint(warm)`，本来就是玻璃加暖色；
      // 换成实心 accent 的话，一块正绿压在整页橙光上非常刺眼，而 `onAccent`
      // 又只和 `accent` 配对量过，别的底没数。`warm` 压在卡片上是量过的。
      Row({ space: 8 }) {
        this.actionButton('开启预热', $r('sys.symbol.heat_waves'), LeapStyle.warm, () => {
          this.store.preheatBattery();
        })
        this.actionButton('关闭预热', $r('sys.symbol.power'), LeapStyle.textPrimary, () => {
          this.store.stopBatteryPreheat();
        })
      }
      .width('100%')
      // 上一条还在等车确认时 perform 会把新指令直接丢掉，这层保护要挡在按钮上。
      .enabled(!this.store.isSendingCommand)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  actionButton(title: string, symbol: Resource, tint: ResourceColor, action: () => void) {
    Row({ space: 8 }) {
      SymbolGlyph(symbol)
        .fontSize(18)
        .fontColor([tint])
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(tint)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 14, bottom: 14 })
    .borderRadius(28)
    .backgroundEffect(LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    .onClick(action)
  }

  /** 保存 / 取消预约（cmdid 161）。开关关着时保存 = 下发 on:0 取消预约。 */
  @Builder
  saveScheduleButton() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.calendar_badge_clock'))
        .fontSize(18)
        .fontColor([LeapStyle.accent])
      Text(this.scheduleEnabled ? '保存预约' : '取消预约')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(LeapStyle.accent)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 14, bottom: 14 })
    .borderRadius(28)
    .backgroundEffect(LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    .enabled(!this.store.isSendingCommand)
    .onClick(() => {
      const days = this.scheduleDays.slice().sort((a: number, b: number): number => a - b);
      // 下发的是「年-月-日 时:分:00」，日期取今天——选择器只给时分，
      // 拿一个写死的日期去拼会发出一个已经过去的时刻。
      const now = new Date();
      const at = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
        this.scheduleHour, this.scheduleMinute, 0);
      this.store.scheduleBatteryPreheat(at, this.scheduleEnabled, days);
    })
  }

  /** 页级忙态。页内所有控件都受同一个 `isSendingCommand` 管，指示器就做成页级的一个。 */
  @Builder
  busyRow() {
    Row({ space: 8 }) {
      LoadingProgress()
        .width(16)
        .height(16)
        .color(LeapStyle.textSecondary)
      Text('上一条指令还在等车辆确认')
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  scheduleCard() {
    Column({ space: 14 }) {
      Row() {
        Text('预约预热')
          .fontSize(15)
          .fontColor(LeapStyle.textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.scheduleEnabled })
          .selectedColor(LeapStyle.accent)
          .onChange((on: boolean) => {
            this.scheduleEnabled = on;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.scheduleEnabled) {
        Row() {
          Text('出发时间')
            .fontSize(15)
            .fontColor(LeapStyle.textPrimary)
            .layoutWeight(1)
          Text(this.scheduleText)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.cool)
            .onClick(() => {
              // 时间选择器交给系统那一套。
              // 走 UIContext 而不是全局的 `TimePickerDialog.show`——后者已废弃。
              this.getUIContext().showTimePickerDialog({
                selected: new Date(2026, 0, 1, this.scheduleHour, this.scheduleMinute),
                useMilitaryTime: true,
                onAccept: (value: TimePickerResult) => {
                  this.scheduleHour = value.hour;
                  this.scheduleMinute = value.minute;
                }
              });
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Column({ space: 8 }) {
          Text('重复星期')
            .fontSize(15)
            .fontColor(LeapStyle.textPrimary)
            .width('100%')
          this.weekdayRow()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
  }

  @Builder
  weekdayRow() {
    Row() {
      ForEach(AppointmentWeekday.ordered, (option: WeekdayOption) => {
        Text(option.label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .fontColor(this.scheduleDays.includes(option.value)
            ? LeapStyle.onAccent : LeapStyle.textSecondary)
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor(this.scheduleDays.includes(option.value)
            ? LeapStyle.accent : LeapStyle.selectedFill)
          .onClick(() => {
            const day = option.value;
            if (this.scheduleDays.includes(day)) {
              // 一天都不留的预约没有意义，最后一个不许取消。
              if (this.scheduleDays.length <= 1) {
                return;
              }
              this.scheduleDays = this.scheduleDays.filter((it: number): boolean => it !== day);
            } else {
              this.scheduleDays = this.scheduleDays.concat([day]);
            }
          })
      }, (option: WeekdayOption) =>
        `${option.value}-${this.scheduleDays.includes(option.value) ? '1' : '0'}`)
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
  }
}

/**
 * 充电计划。对应 iOS 的 `ChargePlanPreviewView`。
 *
 * **真实下发**：充电上限 + 预约充电走 cmdid 190，健康充电走 cmdid 480，
 * 保存时按「先 480 后 190」串成一批，一次密码覆盖整批（见 `VehicleStore.saveChargePlan`）。
 *
 * 初值取当前车真实的充电计划（commonConfig 的 `config."3"`）和车况信号 48，
 * 拿不到时退到一组默认值（23:00–08:00 / 90% / 每天 / 关）。只播种一次，
 * 之后不再回冲——否则十秒一次的轮询会把用户刚拖好的滑块弹回去。
 */
@ComponentV2
export struct ChargePlanView {
  @Local store: VehicleStore = vehicleStore;
  private loadedScope: string = '';
  private active: boolean = false;
  @Local loading: boolean = true;
  @Local loaded: boolean = false;
  @Local loadFailed: boolean = false;
  private loadGeneration: number = 0;
  @Local limit: number = 90;
  @Local scheduleEnabled: boolean = false;
  @Local beginHour: number = 23;
  @Local beginMinute: number = 0;
  @Local endHour: number = 8;
  @Local endMinute: number = 0;
  @Local cycles: boolean[] = [true, true, true, true, true, true, true];
  /** 健康充电开关。初值取车况信号 48（见 `VehicleState.healthyChargeOn`），读不到才默认关。 */
  @Local healthyChargeOn: boolean = false;
  /** 这次动过健康充电开关没有。没动就不发 480——不必重写一遍车上已有的设置。 */
  @Local healthyTouched: boolean = false;
  /** `circulation`/`recharge` 含义未确认，原样回填车辆上报的那份（见 `ChargePlan`）。 */
  @Local circulation: number = 1;
  @Local recharge: number = 0;

  /** 循环日七个可切换项的短标签，顺序与 ChargePlan.cycles 一致（周一起）。 */
  private static readonly dayLabels: string[] = ['一', '二', '三', '四', '五', '六', '日'];

  /** 健康充电开着时充电上限最多 90%（官方页面同款约束）。 */
  private get maxPercent(): number {
    return this.healthyChargeOn ? 90 : 100;
  }

  /** 初值取当前车的真实充电计划与健康充电状态；缺失就保留上面那组默认值。 */
  aboutToAppear(): void { this.active = true; this.loadPlan(); }

  @Monitor('store.session')
  onSessionChanged(): void {
    if (this.active && this.loadedScope !== this.sessionScope()) { this.loadPlan(); }
  }

  private sessionScope(): string {
    return `${this.store.session.oldAuth?.accountId ?? ''}/${this.store.session.selectedVin}`;
  }

  aboutToDisappear(): void { this.active = false; this.loadGeneration++; }

  private async loadPlan(): Promise<void> {
    const generation = ++this.loadGeneration;
    this.loadedScope = this.sessionScope();
    this.loading = true;
    this.loaded = false;
    this.loadFailed = false;
    const success = await this.store.refreshChargePlan();
    if (generation !== this.loadGeneration) { return; }
    if (success) { this.seedFromPlan(); }
    this.loaded = success;
    this.loadFailed = !success;
    this.loading = false;
  }

  private seedFromPlan(): void {
    this.limit = 90;
    this.scheduleEnabled = false;
    this.beginHour = 23;
    this.beginMinute = 0;
    this.endHour = 8;
    this.endMinute = 0;
    this.cycles = [true, true, true, true, true, true, true];
    this.circulation = 1;
    this.recharge = 0;
    this.healthyChargeOn = false;
    this.healthyTouched = false;
    const healthy = this.store.state?.healthyChargeOn ?? null;
    if (healthy !== null) {
      this.healthyChargeOn = healthy;
    }
    const plan: ChargePlan | null = this.store.state?.chargePlan ?? null;
    if (plan === null) {
      return;
    }
    if (plan.percent > 0) {
      this.limit = Math.min(100, Math.max(50, plan.percent));
    }
    this.scheduleEnabled = plan.isEnable;
    const begin = ChargePlanView.parseTime(plan.beginTime, this.beginHour, this.beginMinute);
    this.beginHour = begin[0];
    this.beginMinute = begin[1];
    const end = ChargePlanView.parseTime(plan.endTime, this.endHour, this.endMinute);
    this.endHour = end[0];
    this.endMinute = end[1];
    if (plan.cycles.length === 7) {
      this.cycles = plan.cycles.slice();
    }
    this.circulation = plan.circulation;
    this.recharge = plan.recharge;
  }

  /** "HH:mm" 解析成 [时, 分]，解析不出就用给定的默认值。 */
  private static parseTime(text: string, defHour: number, defMinute: number): number[] {
    const parts = text.split(':');
    if (parts.length !== 2) {
      return [defHour, defMinute];
    }
    const hour = Number(parts[0]);
    const minute = Number(parts[1]);
    if (!Number.isFinite(hour) || !Number.isFinite(minute)) {
      return [defHour, defMinute];
    }
    return [Math.trunc(hour), Math.trunc(minute)];
  }

  private static clock(hour: number, minute: number): string {
    const h = hour < 10 ? `0${hour}` : `${hour}`;
    const m = minute < 10 ? `0${minute}` : `${minute}`;
    return `${h}:${m}`;
  }

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: LeapColors.accentGlow })

        Scroll() {
          Column({ space: 18 }) {
            Column()
              .width('100%')
              .height(FeatureChrome.topInset)

            if (this.loading) { Text('正在读取充电计划…') }
            if (this.loadFailed) {
              Button('读取失败，点击重试').onClick(() => { this.loadPlan(); })
            }
            this.limitReadout()

            GlassCard({ radius: LeapStyle.tileRadius }) {
              this.limitSlider()
            }

            GlassCard({ radius: LeapStyle.tileRadius }) {
              this.healthyCard()
            }

            GlassCard({ radius: LeapStyle.tileRadius }) {
              this.scheduleCard()
            }

            this.saveButton()

            Text('改动保存后才下发到车辆，是否生效以车辆实际表现为准。')
              .fontSize(12)
              .fontColor(LeapStyle.textSecondary)
              .width('100%')

            if (this.store.isSendingCommand) {
              Row({ space: 8 }) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color(LeapStyle.textSecondary)
                Text('上一条指令还在等车辆确认')
                  .fontSize(12)
                  .fontColor(LeapStyle.textSecondary)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            }

            Column()
              .width('100%')
              .height(FeatureChrome.bottomInset)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .enabled(!this.loading)
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
    }
    .titleBar(FeatureChrome.titleBar('充电计划'))
  }

  @Builder
  limitReadout() {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        Text(`${Math.round(this.limit)}`)
          .fontSize(78)
          .fontWeight(FontWeight.Lighter)
          .fontColor(LeapStyle.textPrimary)
        Text('%')
          .fontSize(22)
          .fontWeight(FontWeight.Lighter)
          .fontColor(LeapStyle.textSecondary)
      }
      .alignItems(VerticalAlign.Bottom)

      Text('目标电量（充电停止电量）')
        .fontSize(14)
        .fontColor(LeapStyle.textSecondary)
    }
    .width('100%')
    .padding({ top: 18, bottom: 18 })
  }

  @Builder
  limitSlider() {
    Column({ space: 14 }) {
      Slider({
        value: this.limit,
        min: 50,
        max: this.maxPercent,
        step: 5,
        style: SliderStyle.OutSet
      })
        .selectedColor(LeapStyle.accent)
        .width('100%')
        .onChange((value: number) => {
          this.limit = value;
        })

      Row() {
        Text('50%')
          .fontSize(11)
          .fontColor(LeapStyle.textSecondary)
        Blank()
        // 80% 是日常建议值，标出来给个参照。
        Text('80%')
          .fontSize(11)
          .fontColor(LeapStyle.accent)
        Blank()
        Text(`${this.maxPercent}%`)
          .fontSize(11)
          .fontColor(LeapStyle.textSecondary)
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  healthyCard() {
    Column({ space: 6 }) {
      Row() {
        Text('健康充电')
          .fontSize(15)
          .fontColor(LeapStyle.textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.healthyChargeOn })
          .selectedColor(LeapStyle.accent)
          .onChange((on: boolean) => {
            this.healthyChargeOn = on;
            this.healthyTouched = true;
            // 开启健康充电后上限最多 90%，超了就回拉。
            if (on && this.limit > 90) {
              this.limit = 90;
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('开启后充电上限最多 90%。开关状态取自车况，改动后保存才下发。')
        .fontSize(11)
        .fontColor(LeapStyle.textSecondary)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  scheduleCard() {
    Column({ space: 14 }) {
      Row() {
        Text('预约充电')
          .fontSize(15)
          .fontColor(LeapStyle.textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.scheduleEnabled })
          .selectedColor(LeapStyle.accent)
          .onChange((on: boolean) => {
            this.scheduleEnabled = on;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.scheduleEnabled) {
        this.timeRow('开始时间', this.beginHour, this.beginMinute, true)
        this.timeRow('结束时间', this.endHour, this.endMinute, false)

        Column({ space: 8 }) {
          Text('循环日')
            .fontSize(15)
            .fontColor(LeapStyle.textPrimary)
            .width('100%')
          this.cyclesRow()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
  }

  /** 把当前设置下发给车：上限 + 预约走 190；这次动过健康充电才连发 480。 */
  @Builder
  saveButton() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.bolt_fill'))
        .fontSize(18)
        .fontColor([LeapStyle.accent])
      Text('保存充电计划')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(LeapStyle.accent)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 14, bottom: 14 })
    .borderRadius(28)
    .backgroundEffect(LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    .enabled(!this.store.isSendingCommand && this.loaded && !this.loading)
    .onClick(() => {
      this.store.saveChargePlan(
        Math.round(this.limit),
        this.scheduleEnabled,
        ChargePlanView.clock(this.beginHour, this.beginMinute),
        ChargePlanView.clock(this.endHour, this.endMinute),
        this.cycles,
        this.circulation,
        this.recharge,
        this.healthyTouched ? this.healthyChargeOn : null);
    })
  }

  @Builder
  timeRow(label: string, hour: number, minute: number, isBegin: boolean) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(LeapStyle.textPrimary)
        .layoutWeight(1)
      Text(ChargePlanView.clock(hour, minute))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.cool)
        .onClick(() => {
          // 时间选择器交给系统那一套。
          this.getUIContext().showTimePickerDialog({
            selected: new Date(2026, 0, 1, hour, minute),
            useMilitaryTime: true,
            onAccept: (value: TimePickerResult) => {
              if (isBegin) {
                this.beginHour = value.hour;
                this.beginMinute = value.minute;
              } else {
                this.endHour = value.hour;
                this.endMinute = value.minute;
              }
            }
          });
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  cyclesRow() {
    Row() {
      ForEach(ChargePlanView.dayLabels, (label: string, index: number) => {
        Text(label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .fontColor(this.cycles[index] ? LeapStyle.onAccent : LeapStyle.textSecondary)
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor(this.cycles[index] ? LeapStyle.accent : LeapStyle.selectedFill)
          .onClick(() => {
            this.cycles = this.cycles.map((on: boolean, i: number): boolean => i === index ? !on : on);
          })
      }, (label: string, index: number) => `${index}-${this.cycles[index] ? '1' : '0'}`)
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
  }
}
