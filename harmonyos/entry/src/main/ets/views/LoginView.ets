import { inputMethod } from '@kit.IMEKit';
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { SafeAreaInsets } from '../app/SafeAreaInsets';
import { LeapBackground } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapStyle, LeapColors } from '../design/LeapStyle';
import { LegalDoc, LegalDocView } from './LegalDocView';

@ComponentV2
export struct LoginView {
  store: VehicleStore = vehicleStore;
  private insets: SafeAreaInsets = SafeAreaInsets.shared;
  @Local phone: string = '';
  @Local code: string = '';
  @Local isWorking: boolean = false;
  @Local countdown: number = 0;
  /** 同意用户协议和隐私政策，不勾不能登录。默认不勾——同意得是用户的主动动作。 */
  @Local agreed: boolean = false;
  /** 协议浮层：showDoc 控制是否盖上，docKind 决定看哪一份。 */
  @Local showDoc: boolean = false;
  @Local docKind: LegalDoc = LegalDoc.userAgreement;
  private countdownTimer: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToDisappear(): void {
    this.stopCountdown();
  }

  /** 底部那一块要让开的高度：键盘收着时就是手势条那一截。 */
  private get bottomInset(): number {
    return this.insets.keyboard > 0 ? this.insets.keyboard + 12 : 34;
  }

  private get phoneValid(): boolean {
    return this.phone.length === 11 && /^[0-9]+$/.test(this.phone);
  }

  private get codeValid(): boolean {
    return this.code.length === 6 && /^[0-9]+$/.test(this.code);
  }

  /** 两个按钮各自的可点状态。取出来单列是因为配色和 `enabled` 都要用到同一个判断。 */
  private get smsEnabled(): boolean {
    return this.phoneValid && this.countdown <= 0 && !this.isWorking;
  }

  private get submitEnabled(): boolean {
    return this.phoneValid && this.codeValid && !this.isWorking;
  }

  private startCountdown(): void {
    this.stopCountdown();
    this.countdown = 60;
    this.countdownTimer = setInterval(() => {
      this.countdown--;
      if (this.countdown <= 0) {
        this.stopCountdown();
      }
    }, 1000);
  }

  private stopCountdown(): void {
    if (this.countdownTimer >= 0) {
      clearInterval(this.countdownTimer);
      this.countdownTimer = -1;
    }
  }

  /** 收起软键盘。号码/验证码键盘没有回车键，点空白处调这个。 */
  private static dismissKeyboard(): void {
    inputMethod.getController().stopInputSession()
      .then((r: boolean) => {
      })
      .catch((e: Error) => {
      });
  }

  /** 没勾同意就别往下走，弹一句提示。 */
  private requireAgreement(): boolean {
    if (!this.agreed) {
      this.store.show('请先同意协议', '请阅读并勾选同意《用户协议》和《隐私政策》', true);
      this.scroller.scrollEdge(Edge.Bottom);
      return false;
    }
    return true;
  }

  build() {
    Stack() {
      LeapBackground({ tint: LeapColors.accentGlow })

      Column() {
        // 上半部分套一层滚动：键盘顶起来之后剩的高度可能装不下标题加三个字段，
        // 装不下时让它自己滚，而不是把内容挤出屏幕。空间够时 Scroll 不动，
        // 标题和输入框就停在原地——升起来的只有底部那一块。
        Scroll(this.scroller) {
          Column() {
            this.header()

            this.phoneField()
            this.codeField()
            this.smsButton()
            this.agreementRow()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        this.submitButton()

        Text('手机号加密后发送，登录状态只保存在本机。')
          .fontSize(11)
          .fontColor(LeapStyle.textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 10 })
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 28, right: 28, top: 90, bottom: this.bottomInset })
      // 键盘高度是一步跳过来的，不加这一句按钮会瞬移。挂在 padding 后面，
      // 这个 Column 上会变的也只有 padding。
      .animation({ duration: 250, curve: Curve.Friction })

      // 协议浮层：还没进导航栈，只能整屏盖上去。放在最后一层压住登录内容。
      if (this.showDoc) {
        LegalDocView({
          doc: this.docKind,
          showAsOverlay: true,
          // 浮层是从登录页盖上来的，背景跟着登录页那团绿走，不要在这儿换一次色。
          tint: LeapColors.accentGlow,
          onClose: () => {
            this.showDoc = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    // 点空白处收键盘：号码/验证码键盘没有回车键，手动收太麻烦。
    // 父节点的 onClick 只在子节点没消费点击时才触发，不会挡住按钮和输入框。
    .onClick(() => {
      LoginView.dismissKeyboard();
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  agreementRow() {
    Row({ space: 8 }) {
      SymbolGlyph(this.agreed ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
        .fontSize(18)
        .fontColor([this.agreed ? LeapStyle.accent : LeapStyle.textSecondary])
        .onClick(() => {
          this.agreed = !this.agreed;
        })
      // 协议名各自可点，其余是说明文字。字号小、可能换行，用 Flex 居中包裹。
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
        Text('我已阅读并同意')
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
        Text('《用户协议》')
          .fontSize(12)
          .fontColor(LeapStyle.accent)
          .onClick(() => {
            this.docKind = LegalDoc.userAgreement;
            this.showDoc = true;
          })
        Text('和')
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
        Text('《隐私政策》')
          .fontSize(12)
          .fontColor(LeapStyle.accent)
          .onClick(() => {
            this.docKind = LegalDoc.privacy;
            this.showDoc = true;
          })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 14 })
    // 整行可点：勾选框太小不好戳。两个协议名的 Text 各自消费自己的点击（子节点消费后
    // 不再冒泡到这层），所以点它们仍是弹文档，点其余任何地方都切换勾选。
    .onClick(() => {
      this.agreed = !this.agreed;
    })
  }

  @Builder
  header() {
    Column({ space: 10 }) {
      Text('壹跑')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .letterSpacing(6)
        .fontColor(LeapStyle.textTertiary)
      Text('你好，\n欢迎回来')
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .fontColor(LeapStyle.textPrimary)
      Text('使用手机验证码登录')
        .fontSize(14)
        .fontColor(LeapStyle.textSecondary)
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  phoneField() {
    Row({ space: 12 }) {
      Text('+86')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textSecondary)
      TextInput({ text: this.phone, placeholder: '手机号' })
        .type(InputType.PhoneNumber)
        .maxLength(11)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textPrimary)
        .backgroundColor(Color.Transparent)
        // 只清左右内边距会让文字贴着「+86」，`padding(0)` 又把上下也清光了。
        // 留一点左内边距，输入的号码和前缀之间才有个喘气的地方。
        .padding({ left: 6, right: 0, top: 0, bottom: 0 })
        .layoutWeight(1)
        .onChange((value: string) => {
          this.phone = value.replace(/[^0-9]/g, '').substring(0, 11);
        })
    }
    .width('100%')
    .padding(16)
    .margin({ top: 34 })
    .borderRadius(18)
    .backgroundEffect(LeapMaterial.cardEffect)
    // 这一格不上光感。点光源是渲染级的滤镜，会连输入框的光标一起处理——
    // 真机上光标会被拉变形。输入框只要「透」，边靠自己描一道。
    .border({ width: 1, color: LeapStyle.glassEdge })
  }

  @Builder
  codeField() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.message_fill'))
        .fontSize(18)
        .fontColor([LeapStyle.textSecondary])
      TextInput({ text: this.code, placeholder: '6 位验证码' })
        .type(InputType.Number)
        .maxLength(6)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textPrimary)
        .backgroundColor(Color.Transparent)
        .padding({ left: 6, right: 0, top: 0, bottom: 0 })
        .layoutWeight(1)
        .onChange((value: string) => {
          this.code = value.replace(/[^0-9]/g, '').substring(0, 6);
        })
    }
    .width('100%')
    .padding(16)
    .margin({ top: 12 })
    .borderRadius(18)
    .backgroundEffect(LeapMaterial.cardEffect)
    // 这一格不上光感。点光源是渲染级的滤镜，会连输入框的光标一起处理——
    // 真机上光标会被拉变形。输入框只要「透」，边靠自己描一道。
    .border({ width: 1, color: LeapStyle.glassEdge })
  }

  @Builder
  smsButton() {
    // 不用 Button：它自带一层背景，再挂 `backgroundBlurStyle` 在深色下会渲染成
    // 一条纯白的胶囊。挂系统材质的表面一律用普通容器。
    Text(this.countdown > 0 ? `重新发送 (${this.countdown}s)` : '获取验证码')
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      // 能点时是主色绿，不能点时换中性灰。不要退回 `.opacity(0.4)`——
      // 那样量出来只有 1.55:1，正是 1.0.1 被上架检测点名的那一条。
      .fontColor(this.smsEnabled ? LeapStyle.accent : LeapStyle.textDisabled)
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(46)
      .margin({ top: 12 })
      .borderRadius(23)
      .backgroundEffect(LeapMaterial.cardEffect)
      .visualEffect(LeapMaterial.pressable)
      .enabled(this.smsEnabled)
      .onClick(async () => {
        if (!this.requireAgreement()) {
          return;
        }
        this.isWorking = true;
        const ok = await this.store.sendSMS(this.phone);
        if (ok) {
          this.startCountdown();
        }
        this.isWorking = false;
      })
  }

  @Builder
  submitButton() {
    Button() {
      if (this.isWorking) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Color.White)
      } else {
        Text('登录')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          // 两种底配两种前景：能点时底是实心主色，走 onAccent（深色下 accent 是
          // 亮绿，白字只有 1.96:1）；不能点时底是中性灰，白字 5.26:1，照旧。
          .fontColor(this.submitEnabled ? LeapStyle.onAccent : Color.White)
      }
    }
    .width('100%')
    .height(54)
    .borderRadius(27)
    // 禁用时换成中性灰底，白字照旧（量到 5.26:1）。原先是整块 `.opacity(0.4)`，
    // 白字落在淡绿底上只剩 1.17:1——比「获取验证码」那条还低，审核没点名纯属运气。
    .backgroundColor(this.submitEnabled ? LeapStyle.accent : LeapStyle.fillDisabled)
    .enabled(this.submitEnabled)
    .onClick(async () => {
      if (!this.requireAgreement()) {
        return;
      }
      this.isWorking = true;
      // 登录成功不用在这儿收场：登录页是根视图的一个分支，
      // `isLoggedIn` 一变整棵树就换成主界面了。
      await this.store.login(this.phone, this.code);
      this.isWorking = false;
    })
  }
}
