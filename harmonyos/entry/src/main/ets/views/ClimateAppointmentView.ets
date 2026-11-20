import { HdsNavDestination } from '@kit.UIDesignKit';
import { AppointmentReadbackKind, vehicleStore, VehicleStore } from '../app/VehicleStore';
import {
  AppointmentWeekday, ClimateAppointment, ClimateAppointmentMode, WeekdayOption
} from '../core/ClimateAppointment';
import { CardLabel, GlassCard, LeapBackground } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { FeatureChrome, FeatureNote } from './features/FeatureScaffold';

/**
 * 预约空调（cmdid 171）。从空调页右上角进来。对应 iOS `ClimateAppointmentView`。
 *
 * 预约没有车况信号可确认，**确认靠回读**：页面一进来先读车上已有的预约，
 * 下发之后 store 再自动回读一次（见 `VehicleStore.confirm` 里 171 那条），
 * 顶上那张「车上当前预约」卡显示的永远是车端回读的结果，不是本机刚填的草稿。
 *
 * 风量 / 循环 / 除雾 / 出风位置不在界面上，照官方抓包默认值固定发，见 `ClimateAppointment`。
 */
@ComponentV2
export struct ClimateAppointmentView {
  @Local store: VehicleStore = vehicleStore;
  @Local draft: ClimateAppointment = new ClimateAppointment();
  @Local appointmentOn: boolean = true;
  /** 用户动过草稿之后，回读结果就不再覆盖它——不然刚调好的时间会被回读冲掉。 */
  @Local edited: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    await this.store.refreshClimateAppointment();
    this.seed();
  }

  private seed(): void {
    if (this.edited) {
      return;
    }
    const readback = this.store.climateAppointmentReadback;
    if (readback === null) {
      return;
    }
    if (readback.kind === AppointmentReadbackKind.loaded && readback.appointment !== null) {
      this.draft = readback.appointment.copy();
      this.appointmentOn = true;
    } else if (readback.kind === AppointmentReadbackKind.empty) {
      this.appointmentOn = true;
    }
  }

  private edit(change: (appointment: ClimateAppointment) => void): void {
    const next = this.draft.copy();
    change(next);
    this.draft = next;
    this.edited = true;
  }

  private get currentOnCar(): ClimateAppointment | null {
    const readback = this.store.climateAppointmentReadback;
    if (readback !== null && readback.kind === AppointmentReadbackKind.loaded) {
      return readback.appointment;
    }
    return null;
  }

  private get tintHex(): string {
    return this.draft.mode === ClimateAppointmentMode.hot ? LeapColors.warmGlow : LeapColors.coolGlow;
  }

  private get tint(): ResourceColor {
    return this.draft.mode === ClimateAppointmentMode.hot ? LeapStyle.warm : LeapStyle.cool;
  }

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: this.tintHex })

        Scroll() {
          Column({ space: 16 }) {
            Column()
              .width('100%')
              .height(FeatureChrome.topInset)

            this.readbackCard()
            this.editorCard()
            this.actionButton()
            FeatureNote({
              symbol: $r('sys.symbol.info_circle_fill'),
              text: '风量 7 档、内循环、前挡除雾开启，与官方 App 的预约默认值一致。到点是否开启以车辆实际表现为准。'
            })

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
    .titleBar(FeatureChrome.titleBar('预约空调'))
  }

  // MARK: - 车上当前预约（回读）

  @Builder
  readbackCard() {
    GlassCard({ radius: LeapStyle.tileRadius }) {
      Column({ space: 6 }) {
        CardLabel({ text: '车上当前预约' })
        if (this.store.climateAppointmentReadback === null
          || this.store.climateAppointmentReadback.kind === AppointmentReadbackKind.loading) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(LeapStyle.textSecondary)
            Text('读取中…')
              .fontSize(14)
              .fontColor(LeapStyle.textSecondary)
          }
        } else if (this.store.climateAppointmentReadback.kind === AppointmentReadbackKind.empty) {
          Text('没有预约空调')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
        } else if (this.store.climateAppointmentReadback.kind === AppointmentReadbackKind.loaded) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.calendar_badge_clock'))
              .fontSize(15)
              .fontColor([LeapStyle.textPrimary])
            Text(this.store.climateAppointmentReadback.appointment?.summary ?? '')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(LeapStyle.textPrimary)
          }
        } else {
          // 读不到 ≠ 没有预约。说清楚是哪一种，别让用户以为车上是空的。
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
              .fontSize(15)
              .fontColor([LeapStyle.caution])
            Text('读不到车上的预约')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(LeapStyle.caution)
          }
          Text(this.store.climateAppointmentReadback.message)
            .fontSize(11)
            .fontColor(LeapStyle.textSecondary)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  // MARK: - 编辑

  @Builder
  editorCard() {
    GlassCard() {
      Column({ space: 16 }) {
        Row() {
          Text('启用预约')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.appointmentOn })
            .selectedColor(LeapStyle.accent)
            .onChange((on: boolean) => {
              if (on !== this.appointmentOn) {
                this.appointmentOn = on;
                this.edited = true;
              }
            })
        }
        .width('100%')

        if (this.appointmentOn) {
          Row() {
            Text('开启时间')
              .fontSize(14)
              .fontColor(LeapStyle.textPrimary)
              .layoutWeight(1)
            Text(this.draft.timeText)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFeature('"tnum" 1')
              .fontColor(LeapStyle.cool)
              .onClick(() => {
                this.getUIContext().showTimePickerDialog({
                  selected: new Date(2026, 0, 1, this.draft.hour, this.draft.minute),
                  useMilitaryTime: true,
                  onAccept: (value: TimePickerResult) => {
                    this.edit((appointment: ClimateAppointment) => {
                      appointment.hour = value.hour;
                      appointment.minute = value.minute;
                    });
                  }
                });
              })
          }
          .width('100%')

          this.weekdayPicker()
          this.temperatureRow()
          this.modePicker()
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  weekdayPicker() {
    Column({ space: 8 }) {
      Row() {
        Text('重复')
          .fontSize(14)
          .fontColor(LeapStyle.textPrimary)
        Blank()
        Text(AppointmentWeekday.summary(this.draft.days))
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
      }
      .width('100%')

      Row() {
        ForEach(AppointmentWeekday.ordered, (option: WeekdayOption) => {
          Text(option.label)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .textAlign(TextAlign.Center)
            .fontColor(this.draft.days.includes(option.value) ? this.tint : LeapStyle.textSecondary)
            .width(34)
            .height(34)
            .borderRadius(17)
            .backgroundColor(this.draft.days.includes(option.value) ? LeapStyle.selectedFill : LeapStyle.fillNeutral)
            .accessibilityText(`星期${option.label}`)
            .onClick(() => {
              this.edit((appointment: ClimateAppointment) => {
                if (appointment.days.includes(option.value)) {
                  appointment.days = appointment.days.filter((day: number): boolean => day !== option.value);
                } else {
                  appointment.days = appointment.days.concat([option.value]);
                }
              });
            })
        }, (option: WeekdayOption) =>
          `${option.value}-${this.draft.days.includes(option.value) ? 1 : 0}-${this.draft.mode}`)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)

      // 一个都不勾就是一次性预约——协议里一次性预约的 `days` 就是空数组（161 实测）。
      if (this.draft.days.length === 0) {
        Text('不选星期即为只执行一次。')
          .fontSize(11)
          .fontColor(LeapStyle.textTertiary)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  temperatureRow() {
    Row({ space: 10 }) {
      Text('温度')
        .fontSize(14)
        .fontColor(LeapStyle.textPrimary)
      Blank()
      this.tempStep($r('sys.symbol.minus'), -1)
      Text(`${this.draft.temperature} °C`)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontFeature('"tnum" 1')
        .fontColor(LeapStyle.textPrimary)
        .constraintSize({ minWidth: 52 })
        .textAlign(TextAlign.Center)
      this.tempStep($r('sys.symbol.plus'), 1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  tempStep(symbol: Resource, delta: number) {
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
      const next = Math.min(ClimateAppointment.maxTemperature,
        Math.max(ClimateAppointment.minTemperature, this.draft.temperature + delta));
      if (next !== this.draft.temperature) {
        this.edit((appointment: ClimateAppointment) => {
          appointment.temperature = next;
        });
      }
    })
  }

  @Builder
  modePicker() {
    Row({ space: 6 }) {
      ForEach([ClimateAppointmentMode.cold, ClimateAppointmentMode.hot], (mode: ClimateAppointmentMode) => {
        Row({ space: 5 }) {
          SymbolGlyph(mode === ClimateAppointmentMode.hot ? $r('sys.symbol.flame') : $r('sys.symbol.snowflake'))
            .fontSize(14)
            .fontColor([this.draft.mode === mode ? LeapStyle.textPrimary : LeapStyle.textSecondary])
          Text(ClimateAppointment.modeLabel(mode))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.draft.mode === mode ? LeapStyle.textPrimary : LeapStyle.textSecondary)
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .padding({ top: 10, bottom: 10 })
        .borderRadius(20)
        .backgroundColor(this.draft.mode === mode ? LeapStyle.selectedFill : Color.Transparent)
        .onClick(() => {
          this.edit((appointment: ClimateAppointment) => {
            appointment.mode = mode;
          });
        })
      }, (mode: ClimateAppointmentMode) => `${mode}-${this.draft.mode === mode ? 1 : 0}`)
    }
    .width('100%')
    .padding(4)
    .borderRadius(24)
    .backgroundColor(LeapStyle.fillNeutral)
  }

  // MARK: - 保存 / 取消

  /**
   * 按钮做成组件（`WideActionButton`）而不是带参 `@Builder`：颜色跟着冷热模式变、
   * 可用性跟着回读结果变，带参 builder 是值传递，这两样都会冻在第一次的值上。
   */
  @Builder
  actionButton() {
    if (this.appointmentOn) {
      WideActionButton({
        title: '保存预约',
        symbol: $r('sys.symbol.calendar_badge_clock'),
        tint: this.tint,
        usable: !this.store.isSendingCommand,
        onTap: () => {
          // 改的是车上已有那条就沿用它的 set_id；新建交给构造器现造。
          const appointment = this.draft.copy();
          appointment.setID = this.currentOnCar?.setID ?? null;
          this.store.saveClimateAppointment(appointment);
          this.edited = false;
        }
      })
    } else {
      // 开关关掉 = 取消车上的预约（发空 controls）。车上本来就没有就没什么可取消的，按钮禁用。
      WideActionButton({
        title: '取消车上的预约',
        symbol: $r('sys.symbol.calendar'),
        tint: LeapStyle.caution,
        usable: this.currentOnCar !== null && !this.store.isSendingCommand,
        onTap: () => {
          this.store.cancelClimateAppointment();
          this.edited = false;
        }
      })
    }
  }
}

@ComponentV2
struct WideActionButton {
  @Param title: string = '';
  @Param symbol: Resource = $r('sys.symbol.calendar');
  @Param tint: ResourceColor = LeapStyle.accent;
  @Param usable: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: 8 }) {
      SymbolGlyph(this.symbol)
        .fontSize(18)
        .fontColor([this.usable ? this.tint : LeapStyle.textDisabled])
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.usable ? this.tint : LeapStyle.textDisabled)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 14, bottom: 14 })
    .borderRadius(28)
    .backgroundEffect(LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    .enabled(this.usable)
    .onClick(() => {
      this.onTap();
    })
  }
}
