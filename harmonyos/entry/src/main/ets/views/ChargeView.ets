import { HdsNavDestination } from '@kit.UIDesignKit';
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { ChargePlan, LeapFormat, VehicleState } from '../core/LeapModels';
import { VehicleSignal, CarTypeFamily } from '../core/SignalSchema';
import { LeapBackground, CardLabel, GlassActionCard, GlassCard, MetricValue } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { BatteryBar } from './components/EnergyBars';
import { PageMetrics } from './components/PageHeader';

/** 指标格的一项。整页六格全摆着，读不到的写 `--`。 */
interface Metric {
  label: string;
  value: string;
  unit: string;
}

@ComponentV2
export struct ChargeView {
  store: VehicleStore = vehicleStore;
  @Local isRefreshing: boolean = false;

  /** 二级页的跳转由根页面代劳，这里只报路由名（照 `FeatureCenterView` 那套）。 */
  @Event onPush: (route: string) => void = () => {
  };

  private get state(): VehicleState | null {
    return this.store.state;
  }

  build() {
    // 二级页：标题栏和返回键交给系统，页面自己不再画页头。
    HdsNavDestination() {
      Stack() {
        LeapBackground({
          tint: this.state?.isCharging === true ? LeapColors.accentGlow : LeapColors.coolGlow
        })

        Refresh({ refreshing: this.isRefreshing }) {
          Scroll() {
            Column({ space: 14 }) {
              // 让开浮在内容之上的那条标题栏，再多给一点呼吸。
              // 这个空档同时封了顶：不封的话上下平分，电量数字会掉到屏幕正中，
              // 标题栏底下空出一大片什么都没有。电量是这页的主角，让它靠上坐着。
              Column().height(PageMetrics.navTopInset + 12)
              this.socHeader()
              this.chargingControls()
              // 车端报了充电计划才摆这张卡。config.3 读不到（老车没这项、或 commonConfig
              // 这轮没拉到）就整卡不出现——空摆一张「未设置」只是每天报告一件读不到的事。
              this.chargePlanCard()
              Blank()
              this.metricsGrid()
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
        }
        .onRefreshing(async () => {
          // 这页自己转菊花（showSpinner=false），但下拉是手动刷新，顺带重拉充电计划。
          await this.store.refresh(false, true);
          this.isRefreshing = false;
        })
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      style: LeapMaterial.navigationTitleBarStyle(),
      // 叫「能源」而不是「电池与充电」：增程车这页还要放油量和汽油续航，
      // 原来那个名字容不下油。
      content: { title: { mainTitle: '能源' } },
      avoidLayoutSafeArea: true
    })
  }

  // MARK: - 启停充电 / 解锁充电枪

  /**
   * 按车况只摆当下用得上的按钮（同 iOS）：充电中给「停止」；插着枪没在充给「开始」+「解锁」；
   * 没插枪整行不出现。
   *
   * S01 / T03 不给：cmdid 193 / 192 的依据全来自数字口径的车（leapauto 的 C16 抓包），
   * 老车型那套没有任何样本，摆出来大概率是点了等不到确认。
   */
  private get chargingControlsMode(): number {
    const state = this.state;
    if (state === null || CarTypeFamily.isLegacyFamily(this.store.session.selectedCarType)) {
      return 0;
    }
    if (state.isCharging) {
      return 1;
    }
    return state.chargeGunConnected === true ? 2 : 0;
  }

  @Builder
  chargingControls() {
    if (this.chargingControlsMode === 1) {
      Row({ space: 10 }) {
        this.chargeButton('停止充电', $r('sys.symbol.stop_circle_fill'), LeapStyle.caution, () => {
          this.confirmStop();
        })
      }
      .width('100%')
      .enabled(!this.store.isSendingCommand)
    } else if (this.chargingControlsMode === 2) {
      Row({ space: 10 }) {
        // 开始充电不问——发错了再停就是。
        this.chargeButton('开始充电', $r('sys.symbol.bolt_fill'), LeapStyle.accent, () => {
          this.store.setCharging(true);
        })
        this.chargeButton('解锁充电枪', $r('sys.symbol.lock_open_fill'), LeapStyle.textPrimary, () => {
          this.confirmUnlockGun();
        })
      }
      .width('100%')
      .enabled(!this.store.isSendingCommand)
    }
  }

  @Builder
  chargeButton(title: string, symbol: Resource, tint: ResourceColor, action: () => void) {
    Row({ space: 6 }) {
      SymbolGlyph(symbol)
        .fontSize(16)
        .fontColor([tint])
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(tint)
        .maxLines(1)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 12 })
    .borderRadius(24)
    .backgroundEffect(LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    .onClick(action)
  }

  /** 停充之后要重新插枪或回车机才能再充，不好撤回，所以先问一句。主按钮是取消。 */
  private confirmStop(): void {
    this.getUIContext().showAlertDialog({
      title: '停止充电？',
      message: '停止后需要重新插枪或在车机上操作才能继续充电。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '停止充电',
        fontColor: LeapStyle.caution,
        action: () => {
          this.store.setCharging(false);
        }
      }
    });
  }

  /** 解锁之后线缆可以被直接拔走，同样先问。 */
  private confirmUnlockGun(): void {
    this.getUIContext().showAlertDialog({
      title: '解锁充电枪？',
      message: '解锁后充电线可以被直接拔下。车辆不上报解锁结果，发出后无法确认是否生效。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '解锁',
        fontColor: LeapStyle.caution,
        action: () => {
          this.store.unlockChargingGun();
        }
      }
    });
  }

  // MARK: - SOC

  @Builder
  socHeader() {
    Column({ space: 14 }) {
      Row({ space: 6 }) {
        Text(this.state?.soc !== null && this.state?.soc !== undefined ? String(this.state!.soc) : '--')
          .fontSize(104)
          .fontWeight(FontWeight.Lighter)
          .fontFeature('"tnum" 1')
          .fontColor(LeapStyle.textPrimary)
          .animation({ duration: 320, curve: Curve.Smooth })
        Text('%')
          .fontSize(31)
          .fontWeight(FontWeight.Lighter)
          .fontColor(LeapStyle.textSecondary)
      }
      .alignItems(VerticalAlign.Bottom)

      Text(this.chargeStateLine)
        .fontSize(15)
        .fontColor(LeapStyle.textSecondary)
        .textAlign(TextAlign.Center)

      BatteryBar({
        soc: this.state?.soc ?? 0,
        limit: this.state?.chargeLimit ?? null,
        charging: this.state?.isCharging ?? false
      })
        .height(10)
        .margin({ top: 4 })

      // 车端没报就整行不出现。回退到本地草稿的默认值 90% 是错的——车主实际
      // 设的可能是 95%，凭空显示一个错数字比不显示糟得多；而写一个「充电上限 --」
      // 摆在那儿，也只是把一件读不到的事天天摆到眼前，不如让位置留给别的。
      if (this.state?.chargeLimit !== null && this.state?.chargeLimit !== undefined) {
        Row() {
          CardLabel({ text: '充电上限' })
          Blank()
          Text(`${this.state!.chargeLimit}%`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontFeature('"tnum" 1')
            .fontColor(LeapStyle.textPrimary)
        }
        .width('100%')
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding({ top: 18, bottom: 18 })
  }

  private get chargeStateLine(): string {
    const state = this.state;
    if (state === null) {
      return '读取车况中';
    }
    // 车端没报充电状态，不等于没插枪。nil 落进 default 会说成「未连接充电枪」，
    // 车正在充电时也是这句，等于凭空断言。
    const charging = state.chargeState;
    if (charging === null) {
      return '充电状态未上报';
    }
    switch (charging) {
      case 1: {
        const kind = state.isFastCharging ? '直流快充' : '交流慢充';
        const remain = state.chargeRemainMinutes;
        if (remain === null || remain <= 0) {
          return `${kind}中`;
        }
        // 充电上限读不到就别说「充至几%」。没读到写死 100% 的话，
        // 车主实际设的是 95——凭空多出来的那 5% 会让预计时间显得对不上。
        const limit = state.chargeLimit;
        if (limit === null) {
          return `${kind} · 预计还需 ${ChargeView.duration(remain)}`;
        }
        return `${kind} · 预计 ${ChargeView.duration(remain)}充至 ${limit}%`;
      }
      case 2:
        return '充电完成';
      case 3:
        return '充电故障，请检查充电枪';
      case 4:
        return '预约充电等待中';
      case 6:
        return '充电已暂停';
      default:
        // 充电状态的 0 只说明「没在充」，插没插枪是另一个字段。
        // 报了枪已连接就照说，没报（S01 / T03 没有这一项）才回到原来那句。
        return state.chargeGunConnected === true ? '充电枪已连接 · 等待充电' : '未连接充电枪';
    }
  }

  /** 分钟数写成「2 小时 20 分」。不满一小时就只写分钟，别写「0 小时 40 分」。 */
  static duration(minutes: number): string {
    const hours = Math.floor(minutes / 60);
    const rest = minutes % 60;
    if (hours === 0) {
      return `${rest} 分`;
    }
    return rest === 0 ? `${hours} 小时` : `${hours} 小时 ${rest} 分`;
  }

  // MARK: - 充电计划

  /**
   * 充电计划卡。
   *
   * 只读地摆出车端 `commonConfig` 里 config.3 的预约设置：时段、目标电量、循环日、开关。
   * 这里不改也不下发——点这张卡是跳到功能中心的「充电计划」预览页去看／试，
   * 真正的下发链路两边都还没接。
   */
  @Builder
  chargePlanCard() {
    if (this.state?.chargePlan !== null && this.state?.chargePlan !== undefined) {
      GlassActionCard({
        radius: LeapStyle.tileRadius,
        onTap: () => {
          this.onPush('chargePlan');
        }
      }) {
        Column({ space: 12 }) {
          Row() {
            Text('充电计划')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(LeapStyle.textPrimary)
            Blank()
            Text(this.state!.chargePlan!.isEnable ? '预约开启' : '预约关闭')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.state!.chargePlan!.isEnable ? LeapStyle.accent : LeapStyle.textSecondary)
            // 圆底那版箭头。理由同 `FeatureCenterView`：光杆 chevron 短边不达 8vp 硬线。
            SymbolGlyph($r('sys.symbol.chevron_right_circle'))
              .fontSize(13)
              .fontColor([LeapStyle.textTertiary])
              .margin({ left: 6 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          this.planRow('预约时段', this.planTimeText)
          this.planRow('充电至', this.planPercentText)
          this.planRow('循环日', this.planCyclesText)
        }
        .width('100%')
      }
    }
  }

  @Builder
  planRow(label: string, value: string) {
    Row() {
      CardLabel({ text: label })
      Blank()
      Text(value)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontFeature('"tnum" 1')
        .fontColor(LeapStyle.textPrimary)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  private get planTimeText(): string {
    const plan: ChargePlan | null | undefined = this.state?.chargePlan;
    if (plan === null || plan === undefined) {
      return '--';
    }
    return plan.timeRange.length > 0 ? plan.timeRange : '--';
  }

  /** 目标电量。percent 缺报（空串会被解析成 0）就写 `--`，不摆一个凭空的 0%。 */
  private get planPercentText(): string {
    const plan: ChargePlan | null | undefined = this.state?.chargePlan;
    if (plan === null || plan === undefined || plan.percent <= 0) {
      return '--';
    }
    return `${plan.percent}%`;
  }

  private get planCyclesText(): string {
    const plan: ChargePlan | null | undefined = this.state?.chargePlan;
    if (plan === null || plan === undefined) {
      return '--';
    }
    return plan.cyclesSummary.length > 0 ? plan.cyclesSummary : '--';
  }

  // MARK: - 指标

  /**
   * 六格全摆着，读不到的写 `--`。
   *
   * 格子该在的位置就得在——某项这次读不到就把卡片抽走、下次读到了又冒出来，
   * 整页会跟着重排，比留个横杠更让人摸不着头脑。底下那行小字负责说明横杠是什么意思。
   */
  @Builder
  metricsGrid() {
    Column({ space: 10 }) {
      Grid() {
        ForEach(this.metrics(), (metric: Metric) => {
          GridItem() {
            GlassCard({ radius: LeapStyle.tileRadius }) {
              Column({ space: 10 }) {
                CardLabel({ text: metric.label })
                MetricValue({ value: metric.value, unit: metric.unit, valueSize: 20 })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .constraintSize({ minHeight: 62 })
            }
          }
        }, (metric: Metric) => metric.label)
      }
      .columnsTemplate('1fr 1fr')
      .rowsGap(12)
      .columnsGap(12)
      .width('100%')
      .height(this.gridHeight)

    }
    .width('100%')
  }

  /** Grid 不会按内容自适应高度，得按行数算。每格 94（62 内容 + 32 内外边距）。 */
  private get gridHeight(): number {
    const rows = Math.ceil(this.metrics().length / 2);
    return rows * 94 + (rows - 1) * 12;
  }

  private metrics(): Metric[] {
    const state = this.state;
    const list: Metric[] = [];

    // 充电时把「还要多久」和「多快」顶到最前——这时候它俩就是最该被看到的数。
    if (state !== null && state.isCharging) {
      const remain = state.chargeRemainMinutes;
      if (remain !== null && remain > 0) {
        list.push({ label: '充电剩余时间', value: ChargeView.duration(remain), unit: '' });
      }
      const power = state.chargePowerKW;
      if (power !== null) {
        list.push({ label: '充电功率', value: power.toFixed(1), unit: 'kW' });
      }
    }

    // 这台车压根没有剩余能量这个字段时，格子整个不摆。
    // 「这次读不到」摆个横杠是有意义的，「这辈子都读不到」摆着就只是占地方。
    if (this.reportsRemainingEnergy) {
      const wh = state?.dumpEnergyWh ?? null;
      list.push({ label: '剩余能量', value: wh !== null ? (wh / 1000).toFixed(1) : '--', unit: 'kWh' });
    }

    // 增程车的续航是电、油两个数，官方也是分开列的。纯电车照旧一个「估算续航」。
    if (state !== null && state.hasFuel) {
      list.push({ label: '纯电续航', value: ChargeView.text(state.energyRange), unit: 'km' });
      list.push({ label: '汽油续航', value: ChargeView.text(state.gasolineRange), unit: 'km' });
      list.push({ label: '综合续航', value: ChargeView.text(state.totalRange), unit: 'km' });
      list.push({ label: '油量', value: ChargeView.text(state.gasolinePercent), unit: '%' });
      // 燃油加热是间歇性的，加热时才摆——常驻一格「未加热」是每天报告一件没发生的事。
      if (state.isFuelHeating) {
        list.push({ label: '燃油加热', value: '加热中', unit: '' });
      }
    } else {
      list.push({ label: '估算续航', value: ChargeView.text(state?.expectedMileage ?? null), unit: 'km' });
    }

    // 电压电流是两个数，各带一个单位，只能拼在一起塞进 value。
    const voltage = state?.batteryVoltage ?? null;
    const current = state?.batteryCurrent ?? null;
    list.push({
      label: '电压 / 电流',
      value: `${voltage !== null ? Math.round(voltage) : '--'}V · ${current !== null ? Math.round(current) : '--'}A`,
      unit: ''
    });
    list.push({ label: '最低单体温度', value: ChargeView.text(state?.minSingleTemp ?? null), unit: '°C' });
    list.push({ label: '总里程', value: ChargeView.text(state?.totalMileage ?? null), unit: 'km' });
    // 和首页空调卡同一套：车内读不到就退车外，标签跟着改口。
    // 车外是另一个真实的值，但绝不许它冒充车内——见 `HomeView.temperatureLabel`。
    // T03 实测整张表没有 `indoorTemp`，只有 `outdoorTemp`。
    const indoor = state?.indoorTemp ?? null;
    const outdoor = state?.outdoorTemp ?? null;
    const shown = indoor !== null ? indoor : outdoor;
    list.push({
      label: indoor === null && outdoor !== null ? '车外温度' : '车内温度',
      value: shown !== null ? LeapFormat.temperature(shown) : '--',
      unit: '°C'
    });

    return list;
  }

  private static text(value: number | null): string {
    return value !== null ? String(value) : '--';
  }

  /**
   * 这台车的字段体系里到底有没有「剩余能量」这一项。
   *
   * C11 那套数字 ID 里没有：81.9 kWh 的包、SOC 77.5%，该是 63.5 kWh，
   * 而 55–70 / 550–700 / 55000–70000 三个量级在 96 个字段里一个候选都没有。
   */
  private get reportsRemainingEnergy(): boolean {
    const state = this.state;
    if (state === null) {
      return true;
    }
    return state.schema.candidates(VehicleSignal.dumpEnergy).length > 0;
  }

}
