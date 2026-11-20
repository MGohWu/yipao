import { BLEUnlockDistance } from '../../core/BLEProtocol';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { BLEVehicleController } from '../../app/BLEVehicleController';
import {
  BLEBluetoothState,
  BLEDiscoveredDevice,
  BLEPairingStateKind,
  BLERuntimeStateKind
} from '../../app/BLEVehicleControllerTypes';
import { BLEConfigurationSyncState } from '../../app/BLEVehicleBinding';
import { GlassCard, LeapBackground } from '../../design/LeapGlass';
import { LeapColors, LeapStyle } from '../../design/LeapStyle';
import { FeatureChrome, FeatureNote } from './FeatureScaffold';
import { HomeView } from '../HomeView';

/**
 * 蓝牙钥匙设置。对应 iOS 的 `BluetoothKeySettingsView`。
 *
 * 分三段，和 iOS 的三个 Section 一一对应：状态、车辆钥匙、绑定。
 * 三个开关改的都是**车端**那 9 字节配置，不是本机标记——每拨一次都要连上车下发一遍，
 * 「设置同步」那一行说的就是这件事。
 *
 * 鸿蒙独有的一条：无感解锁/离车闭锁要靠长时任务把进程留住（`BLEPassiveEntryTask`），
 * 开着就会多一条撤不掉的常驻通知。这句话写在开关下面，别让人事后才发现。
 *
 * 会变的行一律做成独立组件（`BLEToggleRow` 这些）而不是带参 `@Builder`：
 * builder 的参数是值传递，父组件重画时不重跑，开关会冻在第一次的值上。
 */
@ComponentV2
export struct BluetoothKeySettingsView {
  store: VehicleStore = vehicleStore;
  @Local distanceSaving: boolean = false;

  @Event onPush: (route: string) => void = () => {
  };

  private get controller(): BLEVehicleController {
    return this.store.bleController;
  }

  aboutToAppear(): void {
    this.store.refreshBluetoothRuntime().then(() => this.store.refreshBLEProtocolVersion()).then(() => this.store.refreshBLECalibration());
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

            this.statusSection()

            if (this.controller.binding !== null) {
              this.keySection()
              this.bindingSection()
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

  // MARK: - 状态

  @Builder
  statusSection() {
    Column({ space: 8 }) {
      this.sectionHeader('状态')
      GlassCard({ contentPadding: 0 }) {
        Column() {
          Row({ space: 12 }) {
            SymbolGlyph(this.runtimeSymbol)
              .fontSize(19)
              .fontColor([this.runtimeTint])
            Column({ space: 3 }) {
              Text(this.controller.runtimeState.label)
                .fontSize(15)
                .fontColor(LeapStyle.textPrimary)
              if (this.controller.runtimeState.detail.length > 0) {
                Text(this.controller.runtimeState.detail)
                  .fontSize(12)
                  .fontColor(LeapStyle.textSecondary)
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding(16)

          if (this.controller.binding === null) {
            this.rowDivider()
            BLELinkRow({
              symbol: $r('sys.symbol.dot_radiowaves_left_and_right'),
              title: '搜索并绑定车辆',
              onTap: () => {
                this.onPush('blePairing');
              }
            })
          }
        }
        .width('100%')
      }
      this.sectionFooter('上滑强杀 App 或关掉系统蓝牙之后，无感钥匙要重新打开一次 App 才能恢复。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 车辆钥匙

  @Builder
  keySection() {
    Column({ space: 8 }) {
      this.sectionHeader('车辆钥匙')
      GlassCard({ contentPadding: 0 }) {
        Column() {
          BLEToggleRow({
            symbol: $r('sys.symbol.key_fill'),
            title: '蓝牙控车',
            detail: '车在身边时锁车解锁走蓝牙，不必等网络',
            isOn: this.controller.isBluetoothControlEnabled,
            isEnabled: true,
            onToggle: (on: boolean) => {
              this.store.setBluetoothControlEnabled(on);
            }
          })

          this.rowDivider()

          BLEToggleRow({
            symbol: $r('sys.symbol.lock_open_fill'),
            title: '无感解锁',
            detail: '人走近车自动开锁，需要常驻通知保持连接',
            isOn: this.controller.autoUnlockEnabled,
            isEnabled: this.controller.isBluetoothControlEnabled,
            onToggle: (on: boolean) => {
              this.store.setPassiveAutoUnlock(on);
            }
          })

          this.rowDivider()

          BLEToggleRow({
            symbol: $r('sys.symbol.lock_fill'),
            title: '离车自动闭锁',
            detail: '人走远一段距离后车辆自动上锁',
            isOn: this.controller.autoLockEnabled,
            isEnabled: this.controller.isBluetoothControlEnabled,
            onToggle: (on: boolean) => {
              this.store.setPassiveAutoLock(on);
            }
          })

          this.rowDivider()
          Column({ space: 10 }) {
            Text('解锁距离').fontSize(15).fontColor($r('app.color.leap_text_primary'))
            Row({ space: 8 }) {
              ForEach([BLEUnlockDistance.Standard, BLEUnlockDistance.Near, BLEUnlockDistance.Far],
                (distance: BLEUnlockDistance) => {
                  Button(distance === BLEUnlockDistance.Standard ? '默认' : (distance === BLEUnlockDistance.Near ? '较近' : '较远'))
                    .layoutWeight(1)
                    .type(ButtonType.Capsule)
                    .backgroundColor(this.controller.binding?.configuration.unlockDistance === distance
                      ? $r('app.color.leap_accent') : $r('app.color.leap_selected_fill'))
                    .fontColor(this.controller.binding?.configuration.unlockDistance === distance
                      ? Color.White : $r('app.color.leap_text_primary'))
                    .enabled(this.controller.isBluetoothControlEnabled && !this.distanceSaving)
                    .onClick(async () => {
                      this.distanceSaving = true;
                      try { await this.store.setBLEUnlockDistance(distance); }
                      finally { this.distanceSaving = false; }
                    })
                }, (distance: BLEUnlockDistance) => distance.toString())
            }
            Text('靠近车辆连接后生效，实际距离受手机、携带位置和环境影响')
              .fontSize(12).fontColor($r('app.color.leap_text_secondary'))
          }.width('100%').padding(16)
          this.rowDivider()
          BLEValueRow({ label: '设置同步', value: this.syncStateText })
          this.rowDivider()
          BLEValueRow({
            label: '快速重连',
            value: this.controller.reconnectTokenAvailable ? '已就绪' : '等待首次认证'
          })
        }
        .width('100%')
      }
      this.sectionFooter('无感的距离判断在车上，App 不读 RSSI 主动解锁。'
        + '开着无感时手机要一直连着车，系统会挂一条常驻通知——那条通知就是连接还活着的凭证。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 绑定

  @Builder
  bindingSection() {
    Column({ space: 8 }) {
      this.sectionHeader('绑定')
      GlassCard({ contentPadding: 0 }) {
        Column() {
          BLEValueRow({ label: '车辆', value: this.bindingDeviceText })
          this.rowDivider()
          BLEValueRow({ label: '证书', value: this.bindingCertificateText })
          if (this.lastVerifiedText.length > 0) {
            this.rowDivider()
            BLEValueRow({ label: '最近验证', value: this.lastVerifiedText })
          }
          this.rowDivider()
          BLELinkRow({
            symbol: $r('sys.symbol.arrow_2_circlepath'),
            title: '重新绑定',
            onTap: () => {
              this.onPush('blePairing');
            }
          })
          this.rowDivider()

          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(19)
              .fontColor([LeapStyle.caution])
            Text('移除蓝牙钥匙')
              .fontSize(15)
              .fontColor(LeapStyle.caution)
              .layoutWeight(1)
          }
          .width('100%')
          .padding(16)
          .onClick(() => {
            this.confirmRemove();
          })
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 解绑前问一句。
   *
   * 主按钮是取消：解绑要先连上车把无感关掉才算干净，误触之后车上可能还留着一份开着的配置。
   */
  private confirmRemove(): void {
    this.getUIContext().showAlertDialog({
      title: '移除蓝牙钥匙？',
      message: 'App 会先同步关闭车辆端的无感设置；车不在附近时会留成待同步，等下次连上再关。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '移除',
        fontColor: LeapStyle.caution,
        action: () => {
          this.store.removeBluetoothBinding();
        }
      }
    });
  }

  // MARK: - 通用行

  @Builder
  rowDivider() {
    Column()
      .width('100%')
      .height(0.5)
      .backgroundColor(LeapStyle.separator)
  }

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

  // MARK: - 派生文案

  private get syncStateText(): string {
    switch (this.controller.configurationSyncState) {
      case BLEConfigurationSyncState.Synced:
        return '已同步';
      case BLEConfigurationSyncState.Pending:
        return '等待车辆';
      case BLEConfigurationSyncState.PendingDisable:
        return '等待同步关闭';
      default:
        return '未绑定';
    }
  }

  private get bindingDeviceText(): string {
    const binding = this.controller.binding;
    return binding === null ? '' : BLEDiscoveredDevice.mask(binding.deviceId);
  }

  private get bindingCertificateText(): string {
    const binding = this.controller.binding;
    return binding === null ? '' : binding.certificateFingerprint;
  }

  /** 还没认证成功过就返回空串，那一行整行不出——不编「从未」这种半真半假的话。 */
  private get lastVerifiedText(): string {
    const binding = this.controller.binding;
    if (binding === null || binding.lastVerifiedAt <= 0) {
      return '';
    }
    return HomeView.relativeText(binding.lastVerifiedAt);
  }

  private get runtimeSymbol(): Resource {
    switch (this.controller.runtimeState.kind) {
      case BLERuntimeStateKind.Ready:
        return $r('sys.symbol.checkmark_circle_fill');
      case BLERuntimeStateKind.WaitingForBluetooth:
      case BLERuntimeStateKind.NeedsAttention:
        return $r('sys.symbol.exclamationmark_triangle_fill');
      case BLERuntimeStateKind.Disabled:
        return $r('sys.symbol.power');
      case BLERuntimeStateKind.Unbound:
        return $r('sys.symbol.plus_circle');
      default:
        return $r('sys.symbol.dot_radiowaves_left_and_right');
    }
  }

  private get runtimeTint(): ResourceColor {
    switch (this.controller.runtimeState.kind) {
      case BLERuntimeStateKind.Ready:
        return LeapStyle.accent;
      case BLERuntimeStateKind.WaitingForBluetooth:
      case BLERuntimeStateKind.NeedsAttention:
        return LeapStyle.caution;
      default:
        return LeapStyle.cool;
    }
  }
}

/**
 * 绑定车辆。对应 iOS 的 `BLEPairingView`。
 *
 * 只列广播里带 FFFE 的候选——别的蓝牙设备连上去也认证不过，摆出来只会让人乱点。
 * 认证走完整的 AA AE 且 VIN 对得上，才会存成绑定。
 */
@ComponentV2
export struct BLEPairingView {
  store: VehicleStore = vehicleStore;

  @Event onPush: (route: string) => void = () => {
  };

  private get controller(): BLEVehicleController {
    return this.store.bleController;
  }

  aboutToAppear(): void {
    this.store.prepareBLEPairing();
  }

  aboutToDisappear(): void {
    // 已经绑上了就别取消——那会把刚建立的连接一并关掉。
    if (this.controller.pairingState.kind !== BLEPairingStateKind.Bound) {
      this.controller.cancelPairing();
    }
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

            Column({ space: 8 }) {
              this.sectionHeader('配对前准备')
              GlassCard() {
                Text('请先在零跑官方 App 中临时关闭蓝牙钥匙，或解除蓝牙钥匙绑定，再返回这里搜索。官方 App 占用蓝牙连接时，可能搜索不到车辆。请保持手机系统蓝牙开启。')
                  .fontSize(14)
                  .fontColor(LeapStyle.textSecondary)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 8 }) {
              this.sectionHeader('当前车辆')
              GlassCard() {
                this.pairingStatus()
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 8 }) {
              this.sectionHeader('附近车辆')
              GlassCard({ contentPadding: 0 }) {
                Column() {
                  if (this.candidates.length === 0) {
                    Text(this.controller.isScanning ? '正在搜索附近车辆' : '没有发现车辆')
                      .fontSize(14)
                      .fontColor(LeapStyle.textSecondary)
                      .width('100%')
                      .padding(16)
                  } else {
                    ForEach(this.candidates, (device: BLEDiscoveredDevice, index: number) => {
                      if (index > 0) {
                        this.rowDivider()
                      }
                      BLECandidateRow({
                        name: device.name,
                        maskedIdentifier: device.maskedIdentifier,
                        rssi: device.rssi,
                        isEnabled: !this.controller.pairingState.isBusy,
                        onTap: () => {
                          this.controller.pair(device.deviceId);
                        }
                      })
                      // key 带上 RSSI：只用 deviceId 的话信号强度变了也不会重画。
                    }, (device: BLEDiscoveredDevice) => `${device.deviceId}-${device.rssi}`)
                  }

                  if (this.controller.pairingState.kind === BLEPairingStateKind.Failed) {
                    this.rowDivider()
                    this.retryRow()
                  }
                }
                .width('100%')
              }
              this.sectionFooter('只有用当前 VIN 走完整认证的车才会存成绑定。')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            FeatureNote({
              symbol: $r('sys.symbol.car_fill'),
              text: '请站在车旁操作。绑定过程中车辆可能会闪一下灯，是正常反馈。'
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
    .titleBar(FeatureChrome.titleBar('绑定车辆'))
  }

  @Builder
  pairingStatus() {
    Row({ space: 12 }) {
      if (this.controller.pairingState.isBusy) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(LeapStyle.cool)
      } else {
        SymbolGlyph(this.statusSymbol)
          .fontSize(19)
          .fontColor([this.statusTint])
      }
      Text(this.statusText)
        .fontSize(15)
        .fontColor(this.statusTint)
        .layoutWeight(1)
    }
    .width('100%')
  }

  /**
   * 失败之后那一行。
   *
   * 蓝牙没开或没授权时给的是「去系统设置」——重搜一百次也没用；其余情况才是重新搜索。
   * 设备根本不支持 BLE 时两条都不给。
   */
  @Builder
  retryRow() {
    if (this.controller.bluetoothState === BLEBluetoothState.PoweredOff
      || this.controller.bluetoothState === BLEBluetoothState.Unauthorized) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(19)
          .fontColor([LeapStyle.cool])
        Text(this.controller.bluetoothState === BLEBluetoothState.PoweredOff
          ? '请在控制中心或系统设置里打开蓝牙' : '请在系统设置里允许本应用使用蓝牙')
          .fontSize(14)
          .fontColor(LeapStyle.textSecondary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding(16)
    } else if (this.controller.bluetoothState !== BLEBluetoothState.Unsupported) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(19)
          .fontColor([LeapStyle.cool])
        Text('重新搜索')
          .fontSize(15)
          .fontColor(LeapStyle.cool)
          .layoutWeight(1)
      }
      .width('100%')
      .padding(16)
      .onClick(() => {
        this.store.prepareBLEPairing();
      })
    }
  }

  @Builder
  rowDivider() {
    Column()
      .width('100%')
      .height(0.5)
      .backgroundColor(LeapStyle.separator)
  }

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

  /** 只有广播里带 FFFE 的才是候选，和 iOS 的 `advertisesTargetService` 过滤一致。 */
  private get candidates(): BLEDiscoveredDevice[] {
    return this.controller.devices.filter((device: BLEDiscoveredDevice) => device.advertisesTargetService);
  }

  private get statusText(): string {
    switch (this.controller.pairingState.kind) {
      case BLEPairingStateKind.Idle:
      case BLEPairingStateKind.Preparing:
        return '正在准备蓝牙';
      case BLEPairingStateKind.Scanning:
        return '请选择车辆';
      case BLEPairingStateKind.Connecting:
        return '正在连接';
      case BLEPairingStateKind.Authenticating:
        return '正在验证车辆身份';
      case BLEPairingStateKind.Bound:
        return '绑定成功';
      default:
        return this.controller.pairingState.message;
    }
  }

  private get statusSymbol(): Resource {
    switch (this.controller.pairingState.kind) {
      case BLEPairingStateKind.Bound:
        return $r('sys.symbol.checkmark_circle_fill');
      case BLEPairingStateKind.Failed:
        return $r('sys.symbol.exclamationmark_triangle_fill');
      default:
        return $r('sys.symbol.dot_radiowaves_left_and_right');
    }
  }

  private get statusTint(): ResourceColor {
    switch (this.controller.pairingState.kind) {
      case BLEPairingStateKind.Bound:
        return LeapStyle.accent;
      case BLEPairingStateKind.Failed:
        return LeapStyle.caution;
      default:
        return LeapStyle.textPrimary;
    }
  }
}

/**
 * 一行开关。
 *
 * 做成组件而不是带参 `@Builder`：`@Param` 会跟着父组件重画更新，builder 的参数不会——
 * 后者拨完开关界面纹丝不动。
 */
@ComponentV2
struct BLEToggleRow {
  @Param symbol: Resource = $r('sys.symbol.gearshape');
  @Param title: string = '';
  @Param detail: string = '';
  @Param isOn: boolean = false;
  @Param isEnabled: boolean = true;
  @Event onToggle: (on: boolean) => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.symbol)
        .fontSize(19)
        .fontColor([this.isEnabled ? LeapStyle.accent : LeapStyle.textDisabled])
      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(15)
          .fontColor(this.isEnabled ? LeapStyle.textPrimary : LeapStyle.textDisabled)
        Text(this.detail)
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(LeapStyle.accent)
        .enabled(this.isEnabled)
        .onChange((on: boolean) => {
          this.onToggle(on);
        })
    }
    .width('100%')
    .padding(16)
  }
}

/** 左标题右值的一行。值会变，所以同样是组件。 */
@ComponentV2
struct BLEValueRow {
  @Param label: string = '';
  @Param value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(15)
        .fontColor(LeapStyle.textPrimary)
      Text(this.value)
        .fontSize(14)
        .fontColor(LeapStyle.textSecondary)
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 16 })
    }
    .width('100%')
    .padding(16)
  }
}

/** 跳到子页面的一行。 */
@ComponentV2
struct BLELinkRow {
  @Param symbol: Resource = $r('sys.symbol.chevron_right');
  @Param title: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.symbol)
        .fontSize(19)
        .fontColor([LeapStyle.accent])
      Text(this.title)
        .fontSize(15)
        .fontColor(LeapStyle.textPrimary)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right_circle'))
        .fontSize(14)
        .fontColor([LeapStyle.textTertiary])
    }
    .width('100%')
    .padding(16)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 附近车辆的一行。RSSI 一直在变，必须是组件。 */
@ComponentV2
struct BLECandidateRow {
  @Param name: string = '';
  @Param maskedIdentifier: string = '';
  @Param rssi: number = 0;
  @Param isEnabled: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.car_fill'))
        .fontSize(19)
        .fontColor([LeapStyle.cool])
      Column({ space: 3 }) {
        Text(this.name)
          .fontSize(15)
          .fontColor(LeapStyle.textPrimary)
        Text(`${this.maskedIdentifier}  ·  ${this.rssi} dBm`)
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right_circle'))
        .fontSize(14)
        .fontColor([LeapStyle.textTertiary])
    }
    .width('100%')
    .padding(16)
    .enabled(this.isEnabled)
    .onClick(() => {
      this.onTap();
    })
  }
}
