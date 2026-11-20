import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { BiometricGate, BiometricKind } from '../../app/BiometricGate';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapStyle, LeapColors } from '../../design/LeapStyle';

/**
 * 操作密码输入。用自绘键盘而不是系统键盘：密码是定长数字，
 * 自绘可以做到「输满即发」，也避免键盘弹出把材质层顶飞。
 *
 * 这层是常驻在根视图里的浮层，靠 store.challenge 决定显不显示——
 * 密码是控车链路的一环，不管从哪个页面发起的指令都要能弹出来。
 */
@ComponentV2
export struct OperationPasswordSheet {
  // 必须 @Local 持有，下面那个 @Monitor 才监听得到——普通成员做监听路径的根时，
  // 编译期只给一条警告，运行期彻底不触发。同 `Index.ets` 那条。
  @Local store: VehicleStore = vehicleStore;
  @Local digits: string = '';
  @Local remember: boolean = true;
  /** 输错位数时的抖动偏移，纯视觉反馈。 */
  @Local shakeOffset: number = 0;

  /** 零跑的操作密码是 4 位。输满即发，不用再点确认。 */
  private static readonly passwordLength: number = 4;
  private readonly keys: string[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', '⌫'];

  @Monitor('store.challenge')
  onChallengeChanged(): void {
    // 每次重新弹出都从空开始，不留上一次没输完的半截。
    if (this.store.challenge !== null) {
      this.digits = '';
    }
  }

  private get visible(): boolean {
    return this.store.challenge !== null;
  }

  private get rememberLabel(): string {
    return this.store.biometricKind === BiometricKind.none
      ? '在本机记住操作密码'
      : `记住密码，之后用${BiometricGate.label(this.store.biometricKind)}验证`;
  }

  private dismiss(): void {
    this.digits = '';
    this.store.cancelChallenge();
  }

  private tap(key: string): void {
    if (key === '⌫') {
      if (this.digits.length > 0) {
        this.digits = this.digits.substring(0, this.digits.length - 1);
      }
      return;
    }
    if (this.digits.length >= OperationPasswordSheet.passwordLength) {
      return;
    }
    this.digits = this.digits + key;
    if (this.digits.length < OperationPasswordSheet.passwordLength) {
      return;
    }
    const password = this.digits;
    const remember = this.remember;
    // 稍等一下再收：让最后一个圆点先填上，用户看得到「输满了」这一帧。
    setTimeout(() => {
      this.digits = '';
      this.store.submitOperationPassword(password, remember);
    }, 180);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.visible) {
        // 蒙层：点空白处等同取消。
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.dismiss();
          })

        Column() {
          this.header()
          this.dots()
          this.keypad()
          this.rememberToggle()
          this.cancelButton()
        }
        .width('100%')
        .padding({ top: 22, bottom: 28, left: 26, right: 26 })
        .borderRadius({ topLeft: 34, topRight: 34 })
        .backgroundEffect(LeapMaterial.panelEffect)
        .transition(TransitionEffect.translate({ y: 400 }).animation({ duration: 280, curve: Curve.Friction }))
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(this.visible ? HitTestMode.Default : HitTestMode.None)
  }

  @Builder
  header() {
    Column({ space: 6 }) {
      Text('输入操作密码')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textPrimary)
      Text(`用于验证「${this.store.challenge?.prompt ?? ''}」操作`)
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)
    }
  }

  @Builder
  dots() {
    Row({ space: 16 }) {
      ForEach([0, 1, 2, 3], (index: number) => {
        Column()
          .width(13)
          .height(13)
          .borderRadius(7)
          .backgroundColor(index < this.digits.length ? LeapStyle.textPrimary : Color.Transparent)
          .border({ width: 1.5, color: LeapStyle.textTertiary })
          .animation({ duration: 140, curve: Curve.Sharp })
      }, (index: number) => String(index))
    }
    .padding({ top: 22 })
    .translate({ x: this.shakeOffset })
  }

  @Builder
  keypad() {
    Column() {
      Grid() {
        ForEach(this.keys, (key: string, index: number) => {
        GridItem() {
          if (key.length === 0) {
            // 左下角空位：占格但不可点。
            Column().width('100%').height(54)
          } else {
            Button() {
              if (key === '⌫') {
                SymbolGlyph($r('sys.symbol.delete_left'))
                  .fontSize(19)
                  .fontColor([LeapStyle.textSecondary])
              } else {
                Text(key)
                  .fontSize(22)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(LeapStyle.textPrimary)
              }
            }
            .width('100%')
            .height(54)
            // 键盘整块面板已经是材质，每个键再糊一层会糊成一片白格子。
            .backgroundColor(LeapStyle.fillNeutral)
            .borderRadius(18)
            // 这里**不要**挂 `visualEffect(LeapMaterial.pressable)`。
            //
            // 那个按压投影是 `hdsEffect` 的 BLEND_GRADIENT，挂在 `Button` 上时
            // 不是按下才画，而是常驻——深色模式下十二个键被刷成一片发白的圆角块，
            // 白色数字压上去几乎看不见（就是「按键颜色不对」那条）。
            // 别处同样用 `fillNeutral + pressable` 的按钮（尾门、车窗、导航）都没事，
            // 区别在那些是 Row / Text，不是 Button。
            //
            // 按压反馈本来也不缺：`Button` 自带 `stateEffect`。
            .onClick(() => {
              this.tap(key);
            })
          }
        }
        }, (key: string, index: number) => `${index}-${key}`)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .rowsGap(12)
      .columnsGap(12)
      .width('100%')
      .height(54 * 4 + 12 * 3)
    }
    .width('100%')
    .padding({ top: 24 })
  }

  @Builder
  rememberToggle() {
    Row() {
      Text(this.rememberLabel)
        .fontSize(13)
        .fontColor(LeapStyle.textSecondary)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.remember })
        .selectedColor(LeapStyle.accent)
        .onChange((on: boolean) => {
          this.remember = on;
        })
    }
    .width('100%')
    .padding({ top: 18 })
  }

  @Builder
  cancelButton() {
    Text('取消')
      .fontSize(15)
      .fontColor(LeapStyle.textSecondary)
      .padding({ top: 14 })
      .onClick(() => {
        this.dismiss();
      })
  }
}
