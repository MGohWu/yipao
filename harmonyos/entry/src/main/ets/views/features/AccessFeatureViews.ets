import { HdsNavDestination } from '@kit.UIDesignKit';
import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { GlassCard, LeapBackground } from '../../design/LeapGlass';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../../design/LeapStyle';
import { FeatureChrome, FeatureNote } from './FeatureScaffold';
import { WidgetConfigurationPreviews } from './WidgetConfigurationPreviews';

/** 桌面卡片的尺寸预览、按钮配置与直接控车设置。 */
@ComponentV2
export struct WidgetSetupView {
  store: VehicleStore = vehicleStore;
  private scroller: Scroller = new Scroller();

  /** 关掉直接控车的原因只有一个：没有存过操作密码，卡片上按下去也没法验证。 */
  private get canDirectControl(): boolean {
    return this.store.hasSavedPassword;
  }

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: LeapColors.accentGlow })

        Scroll(this.scroller) {
          Column({ space: 18 }) {
            Column()
              .width('100%')
              .height(FeatureChrome.topInset)

            WidgetConfigurationPreviews({ onEditOffset: (offset: number) => {
              if (Number.isFinite(offset)) {
                this.scroller.scrollTo({ xOffset: 0, yOffset: FeatureChrome.topInset + offset,
                  animation: { duration: 200, curve: Curve.EaseOut } });
              }
            } })

            GlassCard({ radius: LeapStyle.tileRadius }) {
              this.controlToggle()
            }

            FeatureNote({
              symbol: $r('sys.symbol.square_grid_2x2'),
              // 加卡片的手势两端不一样：iOS 是长按桌面空白处再点加号，
              // 鸿蒙是长按 App 图标里的「服务卡片」。这一句照系统实际操作写。
              text: '长按桌面上的壹跑图标，选「服务卡片」，把卡片拖到桌面上。'
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
    .titleBar(FeatureChrome.titleBar('桌面小组件'))
  }
  @Builder
  controlToggle() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.bolt_shield_fill'))
          .fontSize(22)
          .fontColor([LeapStyle.accent])

        Column({ space: 3 }) {
          Text('卡片直接控车')
            .fontSize(15)
            .fontColor(LeapStyle.textPrimary)
          Text('关闭时先打开 App 完成验证')
            .fontSize(12)
            .fontColor(LeapStyle.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.store.widgetControlEnabled })
          .selectedColor(LeapStyle.accent)
          .enabled(this.canDirectControl)
          .onChange((on: boolean) => {
            this.store.setWidgetControlEnabled(on);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (!this.canDirectControl) {
        Text('还没有保存操作密码，卡片上按下去没法验证，先去设置里存一次。')
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
          .width('100%')
      }
    }
    .width('100%')
  }
}

/**
 * 蓝牙钥匙。对应 iOS 的 `BluetoothFeatureOverview`。
 *
 * 这一页是真链路了（`app/BLEVehicleController`），所以不挂预览横幅：
 * 标题那句直接读控制器的运行时状态，进去就是真的绑定和真的开关。
 *
 * 门槛和 iOS 一样是 `bluetoothKeyEligible`，不是 `featureActionsUnlocked`——
 * 演示态不该出现一条能连真车的入口，那边只看得到一条灰的胶囊。
 */
@ComponentV2
export struct BluetoothKeyView {
  store: VehicleStore = vehicleStore;

  @Event onPush: (route: string) => void = () => {
  };

  aboutToAppear(): void {
    this.store.refreshBluetoothRuntime();
  }

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: LeapColors.coolGlow })

        Scroll() {
          Column({ space: 18 }) {
            Column()
              .width('100%')
              .height(FeatureChrome.topInset)

            Column({ space: 14 }) {
              Stack() {
                SymbolGlyph($r('sys.symbol.car_key_fill'))
                  .fontSize(48)
                  .fontColor([LeapStyle.cool])
              }
              .width(110)
              .height(110)
              .borderRadius(55)
              .backgroundColor(LeapStyle.fillCool)

              Text(this.store.bleController.runtimeState.label)
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(LeapStyle.textPrimary)
              Text('可信车辆绑定 · 近车直连 · 无感解闭锁')
                .fontSize(12)
                .fontColor(LeapStyle.textSecondary)
            }
            .width('100%')
            .padding({ top: 26, bottom: 26 })

            if (this.store.bluetoothKeyEligible) {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.arrow_right_circle'))
                  .fontSize(16)
                  .fontColor([LeapStyle.onAccent])
                Text('进入蓝牙钥匙设置')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(LeapStyle.onAccent)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 14, bottom: 14 })
              .borderRadius(28)
              .backgroundColor(LeapStyle.cool)
              .onClick(() => {
                this.onPush('bluetoothKeySettings');
              })
            } else {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.lock_fill'))
                  .fontSize(16)
                  .fontColor([LeapStyle.textTertiary])
                Text('演示模式不能绑定车辆')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(LeapStyle.textSecondary)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 14, bottom: 14 })
              .borderRadius(28)
              .backgroundEffect(LeapMaterial.cardEffect)
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
    .titleBar(FeatureChrome.titleBar('蓝牙钥匙'))
  }
}
