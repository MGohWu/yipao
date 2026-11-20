import { HdsNavDestination } from '@kit.UIDesignKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { BLEPermission } from '../app/BLEPermission';
import { BLEVehicleController } from '../app/BLEVehicleController';
import {
  BLEAuthenticationMode,
  BLEAuthenticationState,
  BLEBluetoothState,
  BLEDiagnosticLogEntry,
  BLEDiscoveredDevice,
  BLELinkState
} from '../app/BLEVehicleControllerTypes';
import { LeapBLEControlCommand, leapBLEControlCommandLabel } from '../core/BLEProtocol';
import { GlassCard, LeapBackground } from '../design/LeapGlass';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { LeapMaterial } from '../design/LeapMaterial';
import { PageMetrics } from './components/PageHeader';

/**
 * 实机调试向导的七步。数值就是进度条的分子，顺序别改。
 */
enum BLEGuideStage {
  Certificate = 0,
  Bluetooth = 1,
  Connection = 2,
  FullAuthentication = 3,
  ReconnectAuthentication = 4,
  Control = 5,
  Export = 6
}

const bleGuideStageCount: number = 7;

/** 当前这一步该显示什么、该给哪个按钮。 */
interface BLEGuidePresentation {
  stage: BLEGuideStage;
  message: string;
  actionTitle: string;
  actionSymbol: Resource;
  isBusy: boolean;
}

/**
 * 蓝牙诊断。对应 iOS 的 `BLEDiagnosticView`。
 *
 * 这一页会把完整 BLE 协议帧摊出来，还能整份导出（打开「导出原始载荷」时连载荷明文一起）。
 * 完整日志里有设备标识和协议载荷，只该发给项目维护者。
 *
 * 入口和 iOS 一样是注释掉的：实现留着，要用时在设置页把那一行放回来。
 */
@ComponentV2
export struct BLEDiagnosticView {
  store: VehicleStore = vehicleStore;

  @Local isSyncingCertificate: boolean = false;
  @Local certificateSyncError: string = '';
  @Local includeSensitivePayloads: boolean = false;
  @Local isConnectionDetailsExpanded: boolean = false;
  @Local isManualToolsExpanded: boolean = false;

  private get manager(): BLEVehicleController {
    return this.store.bleController;
  }

  aboutToAppear(): void {
    this.loadCachedCertificate();
  }

  private async loadCachedCertificate(): Promise<void> {
    const context = await this.store.cachedBLECredentialContext();
    await this.manager.configure(context);
  }

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: LeapColors.coolGlow })

        Scroll() {
          Column({ space: 20 }) {
            this.guideSection()
            if (this.shouldShowNearbyDevices) {
              this.nearbyDevicesSection()
            }
            this.connectionDetailsSection()
            this.manualToolsSection()
            this.logScopeSection()
            this.logSection()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: PageMetrics.navTopInset, bottom: PageMetrics.navBottomInset })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      style: LeapMaterial.navigationTitleBarStyle(),
      content: { title: { mainTitle: '蓝牙诊断' } },
      avoidLayoutSafeArea: true
    })
  }

  // MARK: - 向导

  @Builder
  guideSection() {
    Column({ space: 8 }) {
      this.sectionHeader('实机调试向导')
      GlassCard() {
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            SymbolGlyph(this.guide.actionSymbol)
              .fontSize(22)
              .fontColor([LeapStyle.cool])
              .width(30)
            Column({ space: 3 }) {
              Text(`第 ${this.guide.stage + 1} 步，共 ${bleGuideStageCount} 步`)
                .fontSize(12)
                .fontColor(LeapStyle.textSecondary)
              Text(BLEDiagnosticView.stageTitle(this.guide.stage))
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(LeapStyle.textPrimary)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          Progress({ value: this.guide.stage + 1, total: bleGuideStageCount, type: ProgressType.Linear })
            .color(LeapStyle.accent)
            .width('100%')

          Text(this.guide.message)
            .fontSize(14)
            .fontColor(LeapStyle.textSecondary)
            .width('100%')

          Row({ space: 14 }) {
            BLEMilestone({ title: '证书', complete: this.manager.certificateFingerprint.length > 0 })
            BLEMilestone({ title: 'Token', complete: this.manager.reconnectTokenAvailable })
            BLEMilestone({
              title: 'AA EE',
              complete: this.manager.lastSuccessfulAuthenticationMode === BLEAuthenticationMode.Reconnect
            })
          }
          .width('100%')

          if (this.guide.isBusy) {
            Row({ space: 10 }) {
              LoadingProgress()
                .width(18)
                .height(18)
                .color(LeapStyle.cool)
              Text('请稍候')
                .fontSize(14)
                .fontColor(LeapStyle.textSecondary)
            }
            .width('100%')
          } else if (this.guide.actionTitle.length > 0) {
            BLEActionButton({
              title: this.guide.actionTitle,
              prominent: true,
              isEnabled: this.isGuideActionEnabled,
              onTap: () => {
                this.performGuideAction();
              }
            })
          }

          if (this.guide.stage === BLEGuideStage.Control) {
            this.controlTestButtons()
          }

          if (this.guide.stage === BLEGuideStage.Export) {
            this.exportActions()
          }

          if (this.guideError.length > 0) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
                .fontSize(14)
                .fontColor([LeapStyle.caution])
              Text(this.guideError)
                .fontSize(12)
                .fontColor(LeapStyle.caution)
                .layoutWeight(1)
            }
            .width('100%')
          }
        }
        .width('100%')
      }
      this.sectionFooter('完整认证用 AA AE，快速重连用 AA EE。每一步的原始帧都留在导出日志里。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  controlTestButtons() {
    Row({ space: 12 }) {
      BLEActionButton({
        title: '闭锁测试',
        prominent: true,
        isEnabled: this.manager.canControl,
        onTap: () => {
          this.confirmControl(LeapBLEControlCommand.Lock);
        }
      })
      BLEActionButton({
        title: '解锁测试',
        prominent: false,
        tint: LeapStyle.caution,
        isEnabled: this.manager.canControl,
        onTap: () => {
          this.confirmControl(LeapBLEControlCommand.Unlock);
        }
      })
    }
    .width('100%')
  }

  @Builder
  exportActions() {
    Column({ space: 10 }) {
      BLEActionButton({
        title: '分享完整诊断日志',
        prominent: true,
        isEnabled: this.manager.entries.length > 0,
        onTap: () => {
          this.shareLog(true);
        }
      })
      BLEActionButton({
        title: '复制完整日志',
        prominent: false,
        isEnabled: this.manager.entries.length > 0,
        onTap: () => {
          this.copyLog(true);
        }
      })
      Text('完整日志包含设备标识和协议原始载荷，请只发给项目维护者。')
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)
    }
    .width('100%')
  }

  // MARK: - 附近车辆

  @Builder
  nearbyDevicesSection() {
    Column({ space: 8 }) {
      this.sectionHeader('附近车辆')
      GlassCard({ contentPadding: 0 }) {
        Column() {
          if (this.manager.devices.length === 0) {
            Text(this.manager.isScanning ? '正在搜索附近车辆…' : '还没有扫描结果')
              .fontSize(14)
              .fontColor(LeapStyle.textSecondary)
              .width('100%')
              .padding(16)
          } else {
            ForEach(this.manager.devices, (device: BLEDiscoveredDevice, index: number) => {
              if (index > 0) {
                this.rowDivider()
              }
              BLEDeviceRow({
                name: device.name,
                maskedIdentifier: device.maskedIdentifier,
                rssi: device.rssi,
                services: device.serviceUUIDs.join(', '),
                isVehicle: device.advertisesTargetService,
                isRecommended: this.recommendedDeviceId === device.deviceId,
                isConnected: this.manager.connectedDeviceId === device.deviceId,
                isEnabled: device.isConnectable && this.manager.connectedDeviceId !== device.deviceId
                  && this.manager.linkState !== BLELinkState.Connecting,
                onTap: () => {
                  this.manager.connect(device.deviceId);
                }
              })
              // RSSI 一直在跳，key 不带上它这一行就不重画。
            }, (device: BLEDiscoveredDevice) => `${device.deviceId}-${device.rssi}`)
          }
        }
        .width('100%')
      }
      this.sectionFooter('推荐项先看有没有车辆服务标记，再按信号强度排；拿不准就站到车边重新扫一次。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 连接详情

  @Builder
  connectionDetailsSection() {
    Column({ space: 8 }) {
      GlassCard({ contentPadding: 0 }) {
        Column() {
          BLEDisclosureRow({
            title: '查看连接详情',
            expanded: this.isConnectionDetailsExpanded,
            onTap: () => {
              this.isConnectionDetailsExpanded = !this.isConnectionDetailsExpanded;
            }
          })

          if (this.isConnectionDetailsExpanded) {
            this.rowDivider()
            Column({ space: 10 }) {
              BLEDetailRow({ label: '系统蓝牙', value: this.manager.bluetoothState })
              BLEDetailRow({ label: '扫描', value: this.manager.isScanning ? '进行中' : '已停止' })
              BLEDetailRow({ label: '连接', value: this.manager.linkState })
              BLEDetailRow({ label: '认证', value: this.manager.authenticationState })
              BLEDetailRow({
                label: '快速重连',
                value: this.manager.reconnectTokenAvailable ? '凭证已缓存' : '无凭证'
              })
              if (this.manager.authenticationMode !== null) {
                BLEDetailRow({ label: '当前认证', value: this.manager.authenticationMode! })
              }
              if (this.manager.certificateFingerprint.length > 0) {
                BLEDetailRow({ label: '证书', value: this.manager.certificateFingerprint })
              }
              if (this.manager.connectedDeviceName.length > 0) {
                BLEDetailRow({ label: '设备', value: this.manager.connectedDeviceName })
              }
              BLEDetailRow({ label: '服务', value: this.serviceText })
              BLEDetailRow({ label: '特征', value: this.characteristicText })
              BLEDetailRow({ label: '协商 MTU', value: `${this.manager.negotiatedMtu} bytes` })
            }
            .width('100%')
            .padding(16)
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 高级工具

  @Builder
  manualToolsSection() {
    Column({ space: 8 }) {
      this.sectionHeader('高级工具')
      GlassCard({ contentPadding: 0 }) {
        Column() {
          BLEDisclosureRow({
            title: '显示手动工具',
            expanded: this.isManualToolsExpanded,
            onTap: () => {
              this.isManualToolsExpanded = !this.isManualToolsExpanded;
            }
          })

          if (this.isManualToolsExpanded) {
            this.rowDivider()
            BLEToolRow({
              symbol: $r('sys.symbol.key_fill'),
              title: this.isSyncingCertificate ? '正在同步' : '重新同步官方证书',
              isEnabled: !this.isSyncingCertificate,
              onTap: () => {
                this.syncCertificate();
              }
            })
            this.rowDivider()
            BLEToolRow({
              symbol: $r('sys.symbol.checkmark_shield'),
              title: '发送 AA AE 完整认证',
              isEnabled: this.manager.canAuthenticate,
              onTap: () => {
                this.manager.authenticate(true);
              }
            })

            if (this.manager.reconnectTokenAvailable) {
              this.rowDivider()
              BLEToolRow({
                symbol: $r('sys.symbol.bolt_circle'),
                title: '发送 AA EE 快速重连',
                isEnabled: this.manager.canAuthenticate,
                onTap: () => {
                  this.manager.authenticate(false);
                }
              })
              this.rowDivider()
              BLEToolRow({
                symbol: $r('sys.symbol.trash'),
                title: '清除快速重连凭证',
                tint: LeapStyle.caution,
                isEnabled: true,
                onTap: () => {
                  this.manager.clearReconnectToken();
                }
              })
            }

            this.rowDivider()
            BLEToolRow({
              symbol: $r('sys.symbol.dot_radiowaves_left_and_right'),
              title: this.manager.isScanning ? '停止扫描' : '开始扫描',
              isEnabled: this.manager.bluetoothState === BLEBluetoothState.PoweredOn,
              onTap: () => {
                if (this.manager.isScanning) {
                  this.manager.stopScan();
                } else {
                  this.beginScan();
                }
              }
            })
            this.rowDivider()
            BLEToolRow({
              symbol: $r('sys.symbol.xmark'),
              title: '断开车辆',
              tint: LeapStyle.caution,
              isEnabled: this.manager.connectedDeviceId.length > 0,
              onTap: () => {
                this.manager.disconnect();
              }
            })

            Column() {
              this.controlTestButtons()
            }
            .width('100%')
            .padding(16)
          }
        }
        .width('100%')
      }
      this.sectionFooter('只在向导走不下去时手动重试；日常实机测试照着顶上那一步做就行。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 日志

  @Builder
  logScopeSection() {
    Column({ space: 8 }) {
      this.sectionHeader('日志范围')
      GlassCard({ contentPadding: 0 }) {
        Row({ space: 12 }) {
          Text('导出原始载荷')
            .fontSize(15)
            .fontColor(LeapStyle.textPrimary)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.includeSensitivePayloads })
            .selectedColor(LeapStyle.caution)
            .onChange((on: boolean) => {
              this.includeSensitivePayloads = on;
            })
        }
        .width('100%')
        .padding(16)
      }
      this.sectionFooter(this.includeSensitivePayloads
        ? '导出会带上设备标识、广播数据和完整协议十六进制，只用于已授权车辆联调。'
        : '当前导出已隐去设备标识、广播内容和协议载荷。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  logSection() {
    Column({ space: 8 }) {
      Row({ space: 16 }) {
        Text(`实时摘要（${this.manager.entries.length}）`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(LeapStyle.textSecondary)
          .layoutWeight(1)
        BLEIconAction({
          symbol: $r('sys.symbol.doc_filled_on_doc'),
          isEnabled: this.manager.entries.length > 0,
          onTap: () => {
            this.copyLog(this.includeSensitivePayloads);
          }
        })
        BLEIconAction({
          symbol: $r('sys.symbol.share'),
          isEnabled: this.manager.entries.length > 0,
          onTap: () => {
            this.shareLog(this.includeSensitivePayloads);
          }
        })
        BLEIconAction({
          symbol: $r('sys.symbol.trash'),
          tint: LeapStyle.caution,
          isEnabled: this.manager.entries.length > 0,
          onTap: () => {
            this.manager.clearLogs();
          }
        })
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      GlassCard({ contentPadding: 0 }) {
        Column() {
          if (this.visibleEntries.length === 0) {
            Text('暂无日志')
              .fontSize(14)
              .fontColor(LeapStyle.textSecondary)
              .width('100%')
              .padding(16)
          } else {
            ForEach(this.visibleEntries, (entry: BLEDiagnosticLogEntry, index: number) => {
              if (index > 0) {
                this.rowDivider()
              }
              BLELogRow({
                category: entry.category,
                clock: entry.clockText,
                message: entry.message,
                detail: this.includeSensitivePayloads ? entry.sensitiveDetail : ''
              })
            }, (entry: BLEDiagnosticLogEntry, index: number) => `${entry.timestamp}-${index}`)
          }
        }
        .width('100%')
      }
      this.sectionFooter('页面只显示关键事件；重复广播、原始分片和完整协议帧仍留在复制或分享出去的日志里。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 动作

  /**
   * 控车测试要先问一句。
   *
   * 主按钮是取消：这一页上的解锁是真解锁，车就在旁边。
   */
  private confirmControl(command: LeapBLEControlCommand): void {
    const label = leapBLEControlCommandLabel(command);
    this.getUIContext().showAlertDialog({
      title: `确认蓝牙${label}`,
      message: '这条指令会立刻发到当前连接的车辆。请确认车就在你视线里。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: `确认${label}`,
        fontColor: LeapStyle.caution,
        action: () => {
          this.manager.sendControl(command);
        }
      }
    });
  }

  private async syncCertificate(): Promise<void> {
    if (this.isSyncingCertificate) {
      return;
    }
    this.isSyncingCertificate = true;
    this.certificateSyncError = '';
    try {
      const context = await this.store.syncBLECredentialContext();
      await this.manager.configure(context);
    } catch (e) {
      this.certificateSyncError = (e as Error).message;
    }
    this.isSyncingCertificate = false;
  }

  private async copyLog(includingSensitive: boolean): Promise<void> {
    try {
      const text = this.manager.exportText(includingSensitive);
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.store.show('日志已拷贝');
    } catch (e) {
      this.store.show('拷贝失败', String(e));
    }
  }

  /** 走系统分享面板。对应 iOS 的 `ShareLink`，落地形式是一段纯文本。 */
  private async shareLog(includingSensitive: boolean): Promise<void> {
    try {
      const data = new systemShare.SharedData({
        utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
        content: this.manager.exportText(includingSensitive),
        title: 'LeapControl-BLE-Diagnostic.txt'
      });
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await new systemShare.ShareController(data).show(context, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (e) {
      this.store.show('分享失败', String(e));
    }
  }

  private performGuideAction(): void {
    switch (this.guideStage) {
      case BLEGuideStage.Certificate:
        this.syncCertificate();
        break;
      case BLEGuideStage.Bluetooth:
        // 鸿蒙这边没有能直达蓝牙开关的深链，只能提示用户自己去开——
        // 按钮在这一步本来也是灰的（见 `isGuideActionEnabled`）。
        this.store.show('请在控制中心或系统设置里打开蓝牙');
        break;
      case BLEGuideStage.Connection:
        this.connectGuideTarget();
        break;
      case BLEGuideStage.FullAuthentication:
        this.manager.authenticate(true);
        break;
      case BLEGuideStage.ReconnectAuthentication:
        if (this.manager.linkState === BLELinkState.Ready) {
          if (this.manager.authenticationState === BLEAuthenticationState.Authenticated
            && this.manager.lastSuccessfulAuthenticationMode === BLEAuthenticationMode.Full) {
            this.manager.disconnect();
          } else {
            this.manager.authenticate(false);
          }
        } else {
          this.connectGuideTarget();
        }
        break;
      default:
        break;
    }
  }

  private connectGuideTarget(): void {
    if (this.manager.canReconnectLastDevice) {
      this.manager.reconnectLastDevice();
      return;
    }
    const device = this.manager.recommendedDevice;
    if (device !== null) {
      this.manager.connect(device.deviceId);
      return;
    }
    if (!this.manager.isScanning) {
      this.beginScan();
    }
  }

  /**
   * 开扫描前先要权限。
   *
   * `ACCESS_BLUETOOTH` 是 user_grant，没授权时 `startBLEScan` 只会抛异常进日志，
   * 页面上看着就是一直搜不到设备。这里申请一次，已经给过的话系统不会再弹。
   */
  private beginScan(): void {
    BLEPermission.ensure().then((granted: boolean) => {
      if (granted) {
        this.manager.startScan();
      } else {
        this.store.show('需要蓝牙权限', '请在系统设置里允许本应用使用蓝牙', true);
      }
    });
  }

  // MARK: - 派生状态

  /**
   * 当前走到第几步。
   *
   * 判定顺序照抄 iOS：证书 → 手机蓝牙 → 连接 → AA AE → AA EE → 控车 → 导出。
   * 「AA EE 认过 + 控过一次车」就算走完，落到导出那一步。
   */
  private get guideStage(): BLEGuideStage {
    if (this.manager.certificateFingerprint.length === 0) {
      return BLEGuideStage.Certificate;
    }
    if (this.manager.bluetoothState !== BLEBluetoothState.PoweredOn) {
      return BLEGuideStage.Bluetooth;
    }
    if (this.manager.authenticationState === BLEAuthenticationState.Authenticating) {
      return this.manager.authenticationMode === BLEAuthenticationMode.Reconnect
        ? BLEGuideStage.ReconnectAuthentication : BLEGuideStage.FullAuthentication;
    }
    if (this.manager.lastSuccessfulAuthenticationMode === BLEAuthenticationMode.Reconnect
      && this.manager.lastConfirmedControlCommand !== null) {
      return BLEGuideStage.Export;
    }
    if (this.manager.lastSuccessfulAuthenticationMode === BLEAuthenticationMode.Full
      && this.manager.reconnectTokenAvailable) {
      return BLEGuideStage.ReconnectAuthentication;
    }
    if (this.manager.linkState !== BLELinkState.Ready) {
      return BLEGuideStage.Connection;
    }
    if (this.manager.authenticationState !== BLEAuthenticationState.Authenticated) {
      return this.manager.reconnectTokenAvailable
        ? BLEGuideStage.ReconnectAuthentication : BLEGuideStage.FullAuthentication;
    }
    if (this.manager.lastSuccessfulAuthenticationMode === BLEAuthenticationMode.Reconnect) {
      return BLEGuideStage.Control;
    }
    return this.manager.reconnectTokenAvailable
      ? BLEGuideStage.ReconnectAuthentication : BLEGuideStage.FullAuthentication;
  }

  private get guide(): BLEGuidePresentation {
    switch (this.guideStage) {
      case BLEGuideStage.Certificate:
        return {
          stage: BLEGuideStage.Certificate,
          message: this.isSyncingCertificate
            ? '正在从零跑服务器取当前车辆的蓝牙证书。' : '先取到当前账号和车辆对应的蓝牙证书。',
          actionTitle: this.isSyncingCertificate ? '' : '同步官方证书',
          actionSymbol: $r('sys.symbol.key_fill'),
          isBusy: this.isSyncingCertificate
        };
      case BLEGuideStage.Bluetooth:
        return {
          stage: BLEGuideStage.Bluetooth,
          message: this.manager.bluetoothState === BLEBluetoothState.Unsupported
            ? '这台设备不支持低功耗蓝牙，没法继续实车调试。'
            : '请打开手机蓝牙，并允许壹跑使用蓝牙。',
          actionTitle: this.manager.bluetoothState === BLEBluetoothState.PoweredOff
            || this.manager.bluetoothState === BLEBluetoothState.Unauthorized ? '去打开蓝牙' : '',
          actionSymbol: $r('sys.symbol.gearshape'),
          isBusy: this.manager.bluetoothState === BLEBluetoothState.Unknown
            || this.manager.bluetoothState === BLEBluetoothState.Resetting
        };
      case BLEGuideStage.Connection:
        return this.connectionPresentation(BLEGuideStage.Connection);
      case BLEGuideStage.FullAuthentication:
        return this.fullAuthenticationPresentation;
      case BLEGuideStage.ReconnectAuthentication:
        return this.reconnectPresentation;
      case BLEGuideStage.Control:
        return {
          stage: BLEGuideStage.Control,
          message: this.manager.pendingControlLabel.length > 0
            ? `已发送${this.manager.pendingControlLabel}，正在等车辆事件确认。`
            : 'AA EE 已认证成功。发一次闭锁或解锁，确认这条会话还能继续控车。',
          actionTitle: '',
          actionSymbol: $r('sys.symbol.lock_fill'),
          isBusy: this.manager.pendingControlLabel.length > 0
        };
      default:
        return {
          stage: BLEGuideStage.Export,
          message: 'AA EE 和控车事件都验过了。把完整日志分享出去就算跑完这一轮。',
          actionTitle: '',
          actionSymbol: $r('sys.symbol.share'),
          isBusy: false
        };
    }
  }

  private get fullAuthenticationPresentation(): BLEGuidePresentation {
    const waiting = this.manager.authenticationState === BLEAuthenticationState.Authenticating;
    const authenticated = this.manager.authenticationState === BLEAuthenticationState.Authenticated;
    let message: string = '发送 AA AE 完整认证，成功后会把快速重连凭证存进本机。';
    if (waiting) {
      message = 'AA AE 已发送，正在等车辆返回认证结果和快速重连凭证。';
    } else if (authenticated) {
      message = '认证已通过，但还没收到快速重连凭证；可以再等等，或者重发一次。';
    }
    let actionTitle: string = '发送 AA AE 完整认证';
    if (waiting) {
      actionTitle = '';
    } else if (authenticated) {
      actionTitle = '重新发送 AA AE';
    }
    return {
      stage: BLEGuideStage.FullAuthentication,
      message: message,
      actionTitle: actionTitle,
      actionSymbol: $r('sys.symbol.checkmark_shield'),
      isBusy: waiting
    };
  }

  private get reconnectPresentation(): BLEGuidePresentation {
    if (this.manager.authenticationState === BLEAuthenticationState.Authenticating) {
      const isFallback = this.manager.authenticationMode === BLEAuthenticationMode.Full;
      return {
        stage: BLEGuideStage.ReconnectAuthentication,
        message: isFallback
          ? '车辆拒了旧凭证，正在自动用 AA AE 换一份新的。换完会再引导一次快速重连。'
          : '155 字节的 AA EE 已发送，正在等车辆返回认证结果。',
        actionTitle: '',
        actionSymbol: $r('sys.symbol.bolt_circle'),
        isBusy: true
      };
    }
    if (this.manager.linkState === BLELinkState.Ready) {
      if (this.manager.authenticationState === BLEAuthenticationState.Authenticated
        && this.manager.lastSuccessfulAuthenticationMode === BLEAuthenticationMode.Full) {
        return {
          stage: BLEGuideStage.ReconnectAuthentication,
          message: '快速重连凭证已存好。先断开这条 AA AE 会话，再连同一辆车。',
          actionTitle: '断开并准备快速重连',
          actionSymbol: $r('sys.symbol.xmark'),
          isBusy: false
        };
      }
      return {
        stage: BLEGuideStage.ReconnectAuthentication,
        message: '车辆连接已就绪，现在发官方那 155 字节的 AA EE 快速重连帧。',
        actionTitle: '发送 AA EE 快速重连',
        actionSymbol: $r('sys.symbol.bolt_circle'),
        isBusy: false
      };
    }
    const connection = this.connectionPresentation(BLEGuideStage.ReconnectAuthentication);
    return {
      stage: BLEGuideStage.ReconnectAuthentication,
      message: this.manager.linkState === BLELinkState.Disconnecting
        ? '正在断开 AA AE 会话，断完重新连同一辆车。' : connection.message,
      actionTitle: connection.actionTitle,
      actionSymbol: connection.actionSymbol,
      isBusy: connection.isBusy
    };
  }

  private connectionPresentation(stage: BLEGuideStage): BLEGuidePresentation {
    const link = this.manager.linkState;
    if (link === BLELinkState.Connecting || link === BLELinkState.Discovering
      || link === BLELinkState.Subscribing) {
      return {
        stage: stage,
        message: '正在建立连接并订阅车辆的 FFFE/FFF2 通道。',
        actionTitle: '',
        actionSymbol: $r('sys.symbol.link'),
        isBusy: true
      };
    }
    if (link === BLELinkState.Disconnecting) {
      return {
        stage: stage,
        message: '正在断开当前车辆连接。',
        actionTitle: '',
        actionSymbol: $r('sys.symbol.xmark'),
        isBusy: true
      };
    }
    if (this.manager.canReconnectLastDevice) {
      return {
        stage: stage,
        message: '上次连的那辆车还在，可以直接重连。',
        actionTitle: '重新连接上次车辆',
        actionSymbol: $r('sys.symbol.link'),
        isBusy: false
      };
    }
    const device = this.manager.recommendedDevice;
    if (device !== null) {
      return {
        stage: stage,
        message: `已找到 ${device.name}，优先挑带车辆服务标记且信号最强的那台。`,
        actionTitle: '连接推荐车辆',
        actionSymbol: $r('sys.symbol.link'),
        isBusy: false
      };
    }
    return {
      stage: stage,
      message: this.manager.isScanning ? '正在搜索附近车辆，请站到车边。' : '开始扫描之后，页面会推荐最像那辆车的设备。',
      actionTitle: this.manager.isScanning ? '' : '开始扫描车辆',
      actionSymbol: $r('sys.symbol.dot_radiowaves_left_and_right'),
      isBusy: this.manager.isScanning
    };
  }

  private get isGuideActionEnabled(): boolean {
    switch (this.guideStage) {
      case BLEGuideStage.Certificate:
        return !this.isSyncingCertificate;
      case BLEGuideStage.Bluetooth:
        return this.manager.bluetoothState === BLEBluetoothState.PoweredOff
          || this.manager.bluetoothState === BLEBluetoothState.Unauthorized;
      case BLEGuideStage.Connection:
        return this.manager.linkState !== BLELinkState.Connecting
          && this.manager.linkState !== BLELinkState.Discovering
          && this.manager.linkState !== BLELinkState.Subscribing;
      case BLEGuideStage.FullAuthentication:
        return this.manager.canAuthenticate;
      case BLEGuideStage.ReconnectAuthentication:
        if (this.manager.linkState === BLELinkState.Ready) {
          return this.manager.authenticationState === BLEAuthenticationState.Authenticated
            ? this.manager.lastSuccessfulAuthenticationMode === BLEAuthenticationMode.Full
            : this.manager.canAuthenticate;
        }
        return this.manager.linkState !== BLELinkState.Disconnecting;
      case BLEGuideStage.Control:
        return this.manager.canControl;
      default:
        return this.manager.entries.length > 0;
    }
  }

  private get guideError(): string {
    if (this.certificateSyncError.length > 0) {
      return this.certificateSyncError;
    }
    if (this.manager.authenticationError.length > 0) {
      return this.manager.authenticationError;
    }
    return this.manager.linkState === BLELinkState.Failed ? '车辆连接失败，请重新扫描或连接。' : '';
  }

  private get shouldShowNearbyDevices(): boolean {
    if (this.isManualToolsExpanded || this.guideStage === BLEGuideStage.Connection) {
      return true;
    }
    return this.guideStage === BLEGuideStage.ReconnectAuthentication
      && this.manager.linkState !== BLELinkState.Ready;
  }

  private get recommendedDeviceId(): string {
    const device = this.manager.recommendedDevice;
    return device === null ? '' : device.deviceId;
  }

  private get serviceText(): string {
    const services = this.manager.discoveredServiceUUIDs;
    return services.length === 0 ? '未发现' : services.join(', ');
  }

  private get characteristicText(): string {
    const characteristics = this.manager.discoveredCharacteristicUUIDs;
    return characteristics.length === 0 ? '未发现' : characteristics.join(', ');
  }

  /** 屏幕上只留最近 40 条，新的在上面。完整的那份在导出里。 */
  private get visibleEntries(): BLEDiagnosticLogEntry[] {
    const entries = this.manager.entries;
    const start = entries.length > 40 ? entries.length - 40 : 0;
    return entries.slice(start).reverse();
  }

  private static stageTitle(stage: BLEGuideStage): string {
    switch (stage) {
      case BLEGuideStage.Certificate:
        return '同步车辆证书';
      case BLEGuideStage.Bluetooth:
        return '检查手机蓝牙';
      case BLEGuideStage.Connection:
        return '连接车辆';
      case BLEGuideStage.FullAuthentication:
        return '完成 AA AE 首次认证';
      case BLEGuideStage.ReconnectAuthentication:
        return '验证 AA EE 快速重连';
      case BLEGuideStage.Control:
        return '验证蓝牙控车';
      default:
        return '分享完整日志';
    }
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
}

/** 向导下面那三个里程碑。 */
@ComponentV2
struct BLEMilestone {
  @Param title: string = '';
  @Param complete: boolean = false;

  build() {
    Row({ space: 5 }) {
      SymbolGlyph(this.complete ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
        .fontSize(13)
        .fontColor([this.complete ? LeapStyle.accent : LeapStyle.textTertiary])
      Text(this.title)
        .fontSize(12)
        .fontColor(this.complete ? LeapStyle.accent : LeapStyle.textSecondary)
    }
  }
}

/** 向导里的按钮。实心的是当前这一步该做的事，描边的是次要动作。 */
@ComponentV2
struct BLEActionButton {
  @Param title: string = '';
  @Param prominent: boolean = true;
  @Param isEnabled: boolean = true;
  @Param tint: ResourceColor = LeapStyle.accent;
  @Event onTap: () => void = () => {
  };

  build() {
    Text(this.title)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.foreground)
      .layoutWeight(1)
      .height(44)
      .textAlign(TextAlign.Center)
      .borderRadius(LeapStyle.tileRadius)
      .backgroundColor(this.fillColor)
      .enabled(this.isEnabled)
      .onClick(() => {
        this.onTap();
      })
  }

  /**
   * 禁用态换色，不用 `.opacity`。
   *
   * 变淡会把底和前景一起拉向背景，对比度必掉（`scripts/contrast-check.mjs` 专门查这个）。
   * 实心底上的禁用前景是白字：`fillDisabled` 是中性灰，深灰的 `textDisabled` 压上去只有 1.5:1。
   */
  private get foreground(): ResourceColor {
    if (!this.isEnabled) {
      return this.prominent ? Color.White : LeapStyle.textDisabled;
    }
    // 实心主色底上的文字走 onAccent，不写死白色——深色下的 accent 是亮绿。
    return this.prominent ? LeapStyle.onAccent : this.tint;
  }

  private get fillColor(): ResourceColor {
    if (this.prominent) {
      return this.isEnabled ? this.tint : LeapStyle.fillDisabled;
    }
    return LeapStyle.fillCool;
  }
}

/** 折叠区的标题行。 */
@ComponentV2
struct BLEDisclosureRow {
  @Param title: string = '';
  @Param expanded: boolean = false;
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      Text(this.title)
        .fontSize(15)
        .fontColor(LeapStyle.textPrimary)
        .layoutWeight(1)
      SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
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

/** 连接详情里的一行。值大多是十六进制或 UUID，用等宽数字。 */
@ComponentV2
struct BLEDetailRow {
  @Param label: string = '';
  @Param value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(14)
        .fontColor(LeapStyle.textSecondary)
      Text(this.value)
        .fontSize(13)
        .fontColor(LeapStyle.textPrimary)
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 16 })
    }
    .width('100%')
  }
}

/** 手动工具里的一行。 */
@ComponentV2
struct BLEToolRow {
  @Param symbol: Resource = $r('sys.symbol.gearshape');
  @Param title: string = '';
  @Param tint: ResourceColor = LeapStyle.cool;
  @Param isEnabled: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.symbol)
        .fontSize(19)
        .fontColor([this.isEnabled ? this.tint : LeapStyle.textDisabled])
      Text(this.title)
        .fontSize(15)
        .fontColor(this.isEnabled ? LeapStyle.textPrimary : LeapStyle.textDisabled)
        .layoutWeight(1)
    }
    .width('100%')
    .padding(16)
    .enabled(this.isEnabled)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 扫描结果的一行。 */
@ComponentV2
struct BLEDeviceRow {
  @Param name: string = '';
  @Param maskedIdentifier: string = '';
  @Param rssi: number = 0;
  @Param services: string = '';
  @Param isVehicle: boolean = false;
  @Param isRecommended: boolean = false;
  @Param isConnected: boolean = false;
  @Param isEnabled: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.isVehicle ? $r('sys.symbol.car_fill') : $r('sys.symbol.dot_radiowaves_left_and_right'))
        .fontSize(19)
        .fontColor([this.isVehicle ? LeapStyle.accent : LeapStyle.textSecondary])
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(this.name)
            .fontSize(15)
            .fontColor(LeapStyle.textPrimary)
          if (this.isRecommended) {
            Text('推荐')
              .fontSize(11)
              .fontColor(LeapStyle.accent)
          }
        }
        Text(`${this.maskedIdentifier} · RSSI ${this.rssi}`)
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
        if (this.services.length > 0) {
          Text(this.services)
            .fontSize(11)
            .fontColor(LeapStyle.textTertiary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph(this.isConnected ? $r('sys.symbol.checkmark') : $r('sys.symbol.link'))
        .fontSize(16)
        .fontColor([this.isConnected ? LeapStyle.accent : LeapStyle.cool])
    }
    .width('100%')
    .padding(16)
    .enabled(this.isEnabled)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 日志里的一条。 */
@ComponentV2
struct BLELogRow {
  @Param category: string = '';
  @Param clock: string = '';
  @Param message: string = '';
  @Param detail: string = '';

  build() {
    Column({ space: 4 }) {
      Row() {
        Text(this.category)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.category === 'ERROR' ? LeapStyle.caution : LeapStyle.cool)
        Blank()
        Text(this.clock)
          .fontSize(11)
          .fontColor(LeapStyle.textTertiary)
      }
      .width('100%')
      Text(this.message)
        .fontSize(12)
        .fontColor(LeapStyle.textPrimary)
        .width('100%')
      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(11)
          .fontColor(LeapStyle.textSecondary)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }
}

/** 日志那一栏右上角的图标按钮。 */
@ComponentV2
struct BLEIconAction {
  @Param symbol: Resource = $r('sys.symbol.doc_filled_on_doc');
  @Param tint: ResourceColor = LeapStyle.cool;
  @Param isEnabled: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    SymbolGlyph(this.symbol)
      .fontSize(18)
      .fontColor([this.isEnabled ? this.tint : LeapStyle.textDisabled])
      .enabled(this.isEnabled)
      .onClick(() => {
        this.onTap();
      })
  }
}
