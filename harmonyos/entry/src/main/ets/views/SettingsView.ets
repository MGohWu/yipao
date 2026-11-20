import { bundleManager } from '@kit.AbilityKit';
import { AppearanceMode, AppearanceModeUtil, vehicleStore, VehicleStore } from '../app/VehicleStore';
import { BiometricGate, BiometricKind } from '../app/BiometricGate';
import { Vehicle, VehicleUtil } from '../core/LeapModels';
import { LeapBackground, GlassCard } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { PageHeader, PageMetrics } from './components/PageHeader';
import { HomeView } from './HomeView';

/**
 * 第三个页签：设置。
 *
 * 这一页装的是整个 App 的设置：账号与车辆、安全验证、外观、协议、退出登录，
 * 外加几段默认藏起来的（适配车型 / 诊断 / 蓝牙诊断）。分段顺序照 iOS 那版排，
 * 两端对着看的时候不用换脑子。
 *
 * 鸿蒙没有 SwiftUI 那套 `List` + `Section` 的分组表单，这里用「分组标题 + 玻璃卡片」
 * 自己排：每组一张卡，卡内是行，卡下面挂脚注。视觉上和首页那套卡片一致。
 */
@ComponentV2
export struct SettingsView {
  /** 深浅外观下拉的选项。建一次就够，放实例字段每次重绘都会新建一个数组。 */
  private static readonly appearanceOptions: SelectOption[] =
    AppearanceModeUtil.all().map((mode: AppearanceMode) => {
      const option: SelectOption = { value: AppearanceModeUtil.label(mode) };
      return option;
    });

  store: VehicleStore = vehicleStore;
  @Local showLogoutConfirm: boolean = false;
  @Event onNavigate: (route: string) => void = () => {
  };

  private get appVersion(): string {
    try {
      return bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (e) {
      return '1.0';
    }
  }

  build() {
    Stack() {
      LeapBackground({ tint: LeapColors.coolGlow })

      Column() {
        PageHeader({ title: '设置' })

        Scroll() {
          Column({ space: 20 }) {
            this.accountSection()
            this.securitySection()
            this.displaySection()
            // 下面这三段都不出现，段落本身留着，取消注释就回来：
            // - 最近操作：iOS 那版没有这一段
            // - 适配我的车型 / 指令诊断：iOS 那边也是注释掉的，两端一起藏
            // this.receiptSection()
            // this.calibrationSection()
            // this.diagnosticSection()
            // 蓝牙诊断入口也照 iOS 藏着，实现留在 `views/BLEDiagnosticView.ets`。
            // 它是给获准的测试人员用的：完整 BLE 协议帧（还能带明文载荷）只该
            // 通过受控测试包发给项目维护者，不要公开转发。
            // this.bleDiagnosticSection()
            this.aboutSection()
            this.logoutSection()
            // 底部那条浮动导航栏压在内容之上，最后一块内容自己让出它那段高度。
            //
            // 这个空块必须是滚动内容里的最后一个子节点，不能做成 Scroll 的兄弟：
            // 做兄弟会把它从视口高度里扣掉，整页内容跟着上移一截。
            // 也不能写成 padding——ArkUI 的尺寸是 content-box，
            // 加在 `minHeight: '100%'` 的容器上是加在那 100% 之外的，根本不参与布局。
            Column()
              .width('100%')
              .height(PageMetrics.bottomInset)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')

      if (this.showLogoutConfirm) {
        this.logoutConfirm()
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // MARK: - 账号

  /**
   * 账号和车辆合成一段：说到底是一件事——这个账号下有哪些车。
   * iOS 那版也是合着的；分成两段、中间隔着别的设置的话，得上下翻才对得起来。
   */
  @Builder
  accountSection() {
    Column({ space: 8 }) {
      this.sectionHeader('账号')
      GlassCard({ contentPadding: 0 }) {
        Column() {
          Row({ space: 14 }) {
            Row() {
              SymbolGlyph($r('sys.symbol.person_fill'))
                .fontSize(19)
                .fontColor([LeapStyle.accent])
            }
            .width(46)
            .height(46)
            .justifyContent(FlexAlign.Center)
            .borderRadius(23)
            .backgroundColor(LeapStyle.fillAccent)

            Column({ space: 4 }) {
              Text(this.maskedPhone)
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontFeature('"tnum" 1')
                .fontColor(LeapStyle.textPrimary)
              Text(this.store.isLoggedIn ? '已登录' : '未登录')
                .fontSize(12)
                .fontColor(LeapStyle.textSecondary)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding(16)

          if (this.store.session.vehicles.length > 0) {
            this.rowDivider()
            this.vehicleRows()
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private get maskedPhone(): string {
    const phone = this.store.session.phone;
    if (phone.length !== 11) {
      return phone.length === 0 ? '未知账号' : phone;
    }
    return `${phone.substring(0, 3)} **** ${phone.substring(7)}`;
  }

  /** 多车时可点着换，单车时只是一行只读信息。 */
  @Builder
  vehicleRows() {
    if (this.store.session.vehicles.length > 1) {
      ForEach(this.store.session.vehicles, (vehicle: Vehicle, index: number) => {
        // 第一行前面那条分隔线由账号行那边画（账号行和车辆行之间只该有一条）。
        if (index > 0) {
          this.rowDivider()
        }
        Row() {
          Column({ space: 3 }) {
            Text(vehicle.name)
              .fontSize(15)
              .fontColor(LeapStyle.textPrimary)
            Text(VehicleUtil.maskedVin(vehicle.vin))
              .fontSize(12)
              .fontFeature('"tnum" 1')
              .fontColor(LeapStyle.textSecondary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          if (vehicle.vin === this.store.session.selectedVin) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([LeapStyle.accent])
          }
        }
        .width('100%')
        .padding(16)
        .onClick(() => {
          this.store.selectVehicle(vehicle);
        })
      }, (vehicle: Vehicle) => vehicle.vin)
    } else if (this.store.session.vehicles.length === 1) {
      Row() {
        Text(this.store.session.vehicles[0].name)
          .fontSize(15)
          .fontColor(LeapStyle.textPrimary)
        Blank()
        Text(VehicleUtil.maskedVin(this.store.session.vehicles[0].vin))
          .fontSize(13)
          .fontFeature('"tnum" 1')
          .fontColor(LeapStyle.textSecondary)
      }
      .width('100%')
      .padding(16)
    }
  }

  // MARK: - 安全

  @Builder
  securitySection() {
    Column({ space: 8 }) {
      this.sectionHeader('安全')
      GlassCard({ contentPadding: 0 }) {
        Column() {
          if (this.store.biometricKind === BiometricKind.none) {
            this.infoRow($r('sys.symbol.lock_shield'), '生物识别不可用',
              '此设备未启用面容或指纹，控车时需要输入操作密码')
          } else {
            Row({ space: 12 }) {
              SymbolGlyph(BiometricGate.symbol(this.store.biometricKind))
                .fontSize(19)
                .fontColor([LeapStyle.accent])
              Column({ space: 3 }) {
                Text(`${BiometricGate.label(this.store.biometricKind)} 快捷验证`)
                  .fontSize(15)
                  .fontColor(LeapStyle.textPrimary)
                Text(`控车时用${BiometricGate.label(this.store.biometricKind)}解锁已保存的操作密码`)
                  .fontSize(12)
                  .fontColor(LeapStyle.textSecondary)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.store.biometricEnabled })
                .selectedColor(LeapStyle.accent)
                .onChange((on: boolean) => {
                  this.store.setBiometricEnabled(on);
                })
            }
            .width('100%')
            .padding(16)
          }

          this.rowDivider()

          if (this.store.hasSavedPassword) {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.key_shield_slash'))
                .fontSize(19)
                .fontColor([LeapStyle.caution])
              Text('忘记已保存的操作密码')
                .fontSize(15)
                .fontColor(LeapStyle.caution)
                .layoutWeight(1)
            }
            .width('100%')
            .padding(16)
            .onClick(() => {
              this.store.forgetPassword();
            })
          } else {
            this.infoRow($r('sys.symbol.key'), '操作密码未保存', '下次控车输入后可选择记住')
          }
        }
        .width('100%')
      }
      this.sectionFooter('操作密码只加密保存在本机，不会同步到别处。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 外观

  /** 深浅外观 + 车模型，和 iOS 那版一样合成「外观」一段。 */
  @Builder
  displaySection() {
    Column({ space: 8 }) {
      this.sectionHeader('外观')
      GlassCard({ contentPadding: 0 }) {
        Column() {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.circle_lefthalf_inset_filled'))
              .fontSize(19)
              .fontColor([LeapStyle.accent])
            Text('深浅外观')
              .fontSize(15)
              .fontColor(LeapStyle.textPrimary)
              .layoutWeight(1)

            // 官方的下拉选择，不自己拿 Text 拼档位——弹出层、选中打勾、按压反馈、
            // 深浅色和字体缩放都是组件自己管的。
            Select(SettingsView.appearanceOptions)
              .selected(AppearanceModeUtil.all().indexOf(this.store.appearance))
              .value(AppearanceModeUtil.label(this.store.appearance))
              .font({ size: 14 })
              .backgroundColor(Color.Transparent)
              .onSelect((index: number) => {
                this.store.setAppearance(AppearanceModeUtil.all()[index]);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 8, top: 16, bottom: 16 })

          this.rowDivider()

          Row({ space: 12 }) {
            // 自绘剪影的宽度跟着车形走，横过来比同列那些方形字框宽出一截，
            // 这一列的图标左边就对不上。换成官方符号，1000×1000 的方 em，
            // 和上一行的「深浅外观」天然共一条左边线。
            SymbolGlyph($r('sys.symbol.car'))
              .fontSize(19)
              .fontColor([LeapStyle.accent])
            Column({ space: 3 }) {
              Text('显示车模型')
                .fontSize(15)
                .fontColor(LeapStyle.textPrimary)
              Text('关闭后首页显示轮廓剪影')
                .fontSize(12)
                .fontColor(LeapStyle.textSecondary)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.store.showCarModel })
              .selectedColor(LeapStyle.accent)
              .onChange((on: boolean) => {
                this.store.setShowCarModel(on);
              })
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
      }
      this.sectionFooter('车模型资源来自零跑官方，关闭后不再下载，重新打开时自动恢复。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 关于

  /** 用户协议与隐私政策。 */
  @Builder
  aboutSection() {
    Column({ space: 8 }) {
      this.sectionHeader('关于')
      GlassCard({ contentPadding: 0 }) {
        Column() {
          this.linkRow($r('sys.symbol.doc_text'), '用户协议', '', 'agreement')
          this.rowDivider()
          this.linkRow($r('sys.symbol.lock_shield'), '隐私政策', '', 'privacy')
        }
        .width('100%')
      }
      this.sectionFooter('我们不会记录和上传零跑官方服务的会话信息，控车信息等其他信息。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 退出登录

  @Builder
  logoutSection() {
    Column({ space: 8 }) {
      GlassCard({ contentPadding: 0 }) {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.rectangle_and_arrowshape_turn_up_right'))
            .fontSize(19)
            .fontColor([LeapStyle.caution])
          Text('退出登录')
            .fontSize(15)
            .fontColor(LeapStyle.caution)
            .layoutWeight(1)
        }
        .width('100%')
        .padding(16)
        .onClick(() => {
          this.showLogoutConfirm = true;
        })
      }
      Text(`壹跑 ${this.appVersion}`)
        .fontSize(11)
        .fontColor(LeapStyle.textTertiary)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 确认浮层挂在页面根 Stack 上，不挂在滚动内容里——那样它只盖住半屏。 */
  @Builder
  logoutConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.showLogoutConfirm = false;
        })

      Column({ space: 8 }) {
        Text('退出登录？')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(LeapStyle.textPrimary)
        Text('会清除本机的登录状态和操作密码，需要重新用验证码登录。')
          .fontSize(13)
          .fontColor(LeapStyle.textSecondary)
          .textAlign(TextAlign.Center)
          .margin({ bottom: 10 })

        Text('退出登录')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(LeapStyle.caution)
          .width('100%')
          .height(46)
          .textAlign(TextAlign.Center)
          .borderRadius(LeapStyle.tileRadius)
          .backgroundEffect(LeapMaterial.cardEffect)
          .visualEffect(LeapMaterial.pressable)
          .onClick(() => {
            this.showLogoutConfirm = false;
            this.store.logout();
          })

        Text('取消')
          .fontSize(16)
          .fontColor(LeapStyle.textSecondary)
          .width('100%')
          .height(46)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.showLogoutConfirm = false;
          })
      }
      .width('78%')
      .padding(22)
      .borderRadius(28)
      .backgroundEffect(LeapMaterial.panelEffect)
    }
    .width('100%')
    .height('100%')
  }

  // MARK: - 最近操作

  @Builder
  receiptSection() {
    if (this.store.lastReceipt !== null) {
      Column({ space: 8 }) {
        this.sectionHeader('最近操作')
        GlassCard() {
          Row() {
            Text(this.store.lastReceipt!.label)
              .fontSize(15)
              .fontColor(LeapStyle.textPrimary)
            Blank()
            // 这里是指令什么时候发的，跟车况新鲜度无关，别套「车况…更新」那套话。
            Text(HomeView.relativeText(this.store.lastReceipt!.sentAt))
              .fontSize(13)
              .fontColor(LeapStyle.textSecondary)
          }
          .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  // MARK: - 适配我的车型

  /**
   * 只在这台车确实有认不出的车况时才出现。
   * 字段都认全的车（比如 S01）根本看不到这一段——对他们来说这个入口只会让人困惑。
   */
  @Builder
  calibrationSection() {
    if (this.store.pendingCalibrationTasks.length > 0) {
      Column({ space: 8 }) {
        GlassCard({ contentPadding: 0 }) {
          this.linkRow($r('sys.symbol.wand_and_stars'), '适配我的车型',
            `还有 ${this.store.pendingCalibrationTasks.length} 项车况认不出来`, 'calibration')
        }
        this.sectionFooter('零跑没有公开车况字段表，不同车型上报的字段名也不一样。'
          + '在车边按提示操作几下，App 就能认出你这台车的门锁、车窗和空调。不上传任何数据。')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 开发诊断。演示态不出现，且整段默认不出现。 */
  @Builder
  bleDiagnosticSection() {
    if (this.store.bluetoothKeyEligible) {
      Column({ space: 8 }) {
        this.sectionHeader('开发诊断')
        GlassCard({ contentPadding: 0 }) {
          this.linkRow($r('sys.symbol.dot_radiowaves_left_and_right'), '蓝牙诊断', '', 'bleDiagnostic')
        }
        this.sectionFooter('同步官方证书，并记录扫描、认证、锁车/解锁和完整 BLE 协议帧。')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  diagnosticSection() {
    Column({ space: 8 }) {
      GlassCard({ contentPadding: 0 }) {
        this.linkRow($r('sys.symbol.stethoscope'), '指令诊断', '', 'diagnostic')
      }
      this.sectionFooter('控车指令是异步执行的，车辆通常要 5–10 秒才动作。'
        + '这里记录最近一次指令等了多久、有没有等到确认。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 通用行

  @Builder
  sectionHeader(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(LeapStyle.textSecondary)
      .padding({ left: 4 })
  }

  @Builder
  sectionFooter(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(LeapStyle.textTertiary)
      .padding({ left: 4, right: 4 })
  }

  @Builder
  rowDivider() {
    Column()
      .width('100%')
      .height(0.5)
      .backgroundColor(LeapStyle.separator)
  }

  /** 只读的说明行：有图标、有主副文案，但点不了。 */
  @Builder
  infoRow(symbol: Resource, title: string, detail: string) {
    Row({ space: 12 }) {
      SymbolGlyph(symbol)
        .fontSize(19)
        .fontColor([LeapStyle.textSecondary])
      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontColor(LeapStyle.textPrimary)
        Text(detail)
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(16)
  }

  /** 跳到子页面的行，右侧有箭头。 */
  @Builder
  linkRow(symbol: Resource, title: string, detail: string, route: string) {
    Row({ space: 12 }) {
      SymbolGlyph(symbol)
        .fontSize(19)
        .fontColor([LeapStyle.accent])
      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontColor(LeapStyle.textPrimary)
        if (detail.length > 0) {
          Text(detail)
            .fontSize(12)
            .fontColor(LeapStyle.textSecondary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 圆底那版箭头。光杆 `chevron_right` 字形瘦长，14vp 渲染出来短边只有 6–7vp，
      // 低于规范 2.1.4.3.2 的 8vp 硬线；圆底版 14vp 就是实打实的 14×14。
      SymbolGlyph($r('sys.symbol.chevron_right_circle'))
        .fontSize(14)
        .fontColor([LeapStyle.textTertiary])
    }
    .width('100%')
    .padding(16)
    .onClick(() => {
      this.onNavigate(route);
    })
  }
}
