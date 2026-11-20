import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { VehicleState, LeapFormat, ClimateMode } from '../core/LeapModels';
import { LeapBackground, CardLabel, MetricValue, StatusPill, GlassCard } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapStyle, LeapColors } from '../design/LeapStyle';
import { QuickControlBar } from './components/QuickControlBar';
import { VehicleHero } from './components/VehicleHero';
import { BatteryBar, FuelBar } from './components/EnergyBars';
import { LocationThumbnail } from './components/LocationThumbnail';
import { WindowPosition } from './components/WindowPosition';
import { SafeAreaInsets } from '../app/SafeAreaInsets';
import { PageMetrics } from './components/PageHeader';

@ComponentV2
export struct HomeView {
  store: VehicleStore = vehicleStore;
  /**
   * 推二级页面。能源 / 空调 / 里程能耗 / 车辆位置都走这里——
   * 它们是从这一屏点进去看细节的地方，不是和车辆页平级的去处。
   */
  @Event onPush: (route: string) => void = () => {
  };
  /** 车窗、胎压、尾门三张半屏挂在根页面上，这里只负责请求打开。 */
  @Event onOpenSheet: (name: string) => void = () => {
  };
  private insets: SafeAreaInsets = SafeAreaInsets.shared;
  /**
   * 电量卡 / 空调卡顶行的高度。
   *
   * 空调卡那行里挂着一个 34 的电源按钮，电量卡只有一行 12 号标题。两边都垫到这个高度，
   * 标题和底下的大数字才落在同一条线上——不垫的话空调卡整块被按钮往下推大半行，
   * 「电量」和「车内温度」、「91」和「29」全都错开。
   */
  private readonly tileHeaderHeight: number = 34;
  /**
   * 电量卡 / 空调卡末行的高度。
   *
   * 电量条自己只有 10 高，「空调设置」那行是 17。给两边同一个下限并各自居中，
   * 末行的底边才对得齐。写 `constraintSize` 而不是 `height`：文案偶尔折成两行时
   * 让它自己长高，总比压扁强。
   */
  private readonly tileFooterHeight: number = 18;
  /** 滚动视口的高度，车辆主视觉按它取尺寸。量到之前先按一个常见长条屏估。 */
  @Local viewportHeight: number = 0;

  /**
   * 首页的第一视觉永远是车辆。按可用高度取 20%，并把范围钉住，
   * 避免小屏被挤没、长屏又只剩一大片空白。
   *
   * 上限是给车图留的余地——再大就顶到卡片上了；
   * 下限保证小屏把卡片撑高之后，车还认得出来是辆车。
   */
  private get heroSize(): number {
    const height = this.viewportHeight > 0 ? this.viewportHeight : 640;
    return Math.min(190, Math.max(132, height * 0.20));
  }

  private get state(): VehicleState | null {
    return this.store.state;
  }

  /** 背景色随车辆当前最显著的状态走。 */
  private get backgroundTint(): string {
    const state = this.state;
    if (state !== null && state.isCharging) {
      return LeapColors.accentGlow;
    }
    if (this.store.climateOn) {
      return this.store.climateMode === ClimateMode.hot ? LeapColors.warmGlow : LeapColors.coolGlow;
    }
    return LeapColors.coolGlow;
  }

  /** 标题下面这一行既报车况新鲜度，也在有异常时优先报异常。 */
  private get subtitle(): string {
    // 车要 5–10 秒才动作，这段时间必须明确说「在等」，否则看起来就是没反应，
    // 用户会反复点同一个按钮。
    if (this.store.confirmingLabel.length > 0) {
      return `${this.store.confirmingLabel} · 等待车辆响应…`;
    }
    const state = this.state;
    if (state === null) {
      return this.store.isRefreshing ? '正在读取车况…' : '等待车况';
    }
    if (state.anyDoorOpen) {
      return '有车门未关闭';
    }
    if (state.hasTireWarning) {
      return '胎压异常，请尽快检查';
    }
    if (this.store.lastUpdated <= 0) {
      return this.chargeLabel;
    }
    return HomeView.freshnessText(this.store.reportedAt, this.store.lastUpdated);
  }

  /**
   * 车况新鲜度。
   *
   * 优先报车端自己采集这份数据的时刻：本机每 5 秒问一次服务端，但车休眠着不上报时，
   * 服务端会把同一份旧数据一直发回来——按本机拉取时间算，屏幕上就永远写着「刚刚更新」，
   * 而实际数据可能是半小时前的。这正是「刷新不及时」最常见的真身。
   *
   * 车端时间拿不到（`reportedAt` 为 0，某些车型不报这个字段）时退回本机拉取时间，
   * 同时把措辞从「更新」换成「读取」——那句话只能保证「几分钟前问过」，
   * 保证不了「车况就是那时候的」，不能拿同一种说法混过去。
   *
   * 系统的相对时间会说出「2 秒钟前」这种别扭的说法，所以一分钟内直接说「刚刚」。
   */
  static freshnessText(reportedAt: number, fetchedAt: number): string {
    const known = reportedAt > 0;
    const verb = known ? '更新' : '读取';
    const elapsed = HomeView.elapsedSeconds(known ? reportedAt : fetchedAt);
    if (elapsed < 60) {
      return `车况刚刚${verb}`;
    }
    return `车况${verb}于 ${HomeView.relativeText(known ? reportedAt : fetchedAt)}`;
  }

  /** 「刚刚 / 12 分钟前 / 3 小时前」。不带主语，谁在什么时候发生由调用方自己说。 */
  static relativeText(timestamp: number): string {
    const elapsed = HomeView.elapsedSeconds(timestamp);
    if (elapsed < 60) {
      return '刚刚';
    }
    if (elapsed < 3600) {
      return `${Math.trunc(elapsed / 60)} 分钟前`;
    }
    if (elapsed < 86400) {
      return `${Math.trunc(elapsed / 3600)} 小时前`;
    }
    return `${Math.trunc(elapsed / 86400)} 天前`;
  }

  /** 时钟回拨或车端时间略微超前时会算出负数，一律当作 0，别说出「-2 分钟前」。 */
  private static elapsedSeconds(timestamp: number): number {
    return Math.max(0, Math.trunc((Date.now() - timestamp) / 1000));
  }

  /**
   * 有任何一扇上报的车窗没关严。读不到就不算开着——不知道不等于有事。
   *
   * 判据在 `VehicleState.anyWindowOpen` 里：状态位优先、开度兜底。
   * 只看开度的那版对不报开度的车（C11 增程版）永远是 false，窗开着也不出徽章。
   */
  private get windowsOpen(): boolean {
    return this.state?.anyWindowOpen === true;
  }

  private get chargeLabel(): string {
    const state = this.state;
    if (state === null) {
      return '电量';
    }
    switch (state.chargeState) {
      case 1:
        return state.isFastCharging ? '充电中 · 直流快充' : '充电中';
      case 2:
        return '充电完成';
      case 3:
        return '充电故障';
      case 4:
        return '预约充电等待';
      case 6:
        return '充电暂停';
      // 不充电是常态，标题里天天挂着「未充电」等于每天报告一件没发生的事。
      default:
        return '电量';
    }
  }

  /** 续航那行。增程车把电和油分开写——官方也是分两个数，不给总续航。 */
  private get rangeText(): string {
    const state = this.state;
    if (state === null) {
      return '';
    }
    if (state.hasFuel) {
      const energy = state.energyRange;
      const fuel = state.gasolineRange;
      if (energy !== null && fuel !== null) {
        return `电 ${energy} · 油 ${fuel} km`;
      }
    }
    const mileage = state.expectedMileage;
    return mileage !== null ? `${mileage} km` : '';
  }

  /** 空调那行小字。读到哪项写哪项，一项都读不到就说清楚是没上报，不拿草稿凑数。 */
  private get climateDetail(): string {
    const state = this.state;
    const parts: string[] = [];
    if (state !== null) {
      const setting = state.acSetting;
      if (setting !== null) {
        parts.push(`设定 ${setting} °C`);
      }
      const fan = state.acFanLevel;
      if (fan !== null && fan > 0) {
        parts.push(`${fan} 档`);
      }
    }
    return parts.length === 0 ? '设定值未上报' : parts.join(' · ');
  }

  private get windowSummary(): string {
    const state = this.state;
    if (state === null) {
      return '--';
    }
    const open = state.anyWindowOpen;
    if (open === null) {
      return '--';
    }
    // 有开度就说得具体些：四扇里开得最大的那个概括这一格。
    const openness = state.maxWindowOpenness;
    if (openness !== null && openness > 0) {
      return WindowPosition.describe(openness);
    }
    // 只有开合状态位的车（C11 增程版就是）只能说到这儿——
    // 开了多少车根本没报，编一个百分比出来就是撒谎。
    return open ? '已开' : '已关';
  }

  private get tireSummary(): string {
    const state = this.state;
    if (state === null || !state.hasTireData) {
      return '--';
    }
    return state.hasTireWarning ? '异常' : '正常';
  }

  private get locationSummary(): string {
    const state = this.state;
    if (state === null) {
      return '读取中';
    }
    if (!state.privacyGPSAllowed) {
      return '隐私模式已开启';
    }
    if (this.store.coordinate === null) {
      return '暂无定位';
    }
    return this.store.locationName.length > 0 ? this.store.locationName : '正在解析位置';
  }

  build() {
    Stack() {
      LeapBackground({ tint: this.backgroundTint })

      Column() {
        this.dashboardHeader()

        Refresh({ refreshing: this.store.isRefreshing }) {
          Scroll() {
            Column({ space: 12 }) {
              VehicleHero({
                heroSize: this.heroSize,
                badges: (): void => this.statusBadges()
              })
              this.quickControlCard()
              this.summaryRow()
              this.statusStrip()
              this.locationCard()
              this.privacyNote()
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
            .constraintSize({ minHeight: '100%' })
            .padding({ left: 16, right: 16 })
          }
          .scrollBar(BarState.Off)
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
        }
        .onRefreshing(() => {
          // 主页下拉是手动刷新，顺带重拉充电上限 / 充电计划（轮询不拉，走缓存）。
          this.store.refresh(true, true);
        })
        .layoutWeight(1)
        // 车辆主视觉按可用高度取尺寸，这里把视口量出来交给它。
        .onAreaChange((_old: Area, area: Area) => {
          this.viewportHeight = Number(area.height);
        })

      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 顶部标题栏：车名 + 副标题。
   *
   * 车名左对齐，不居中——这一行只有文字，居中的标题在长车名下会被撑得来回跳，
   * 那种「差一点」比明确的左对齐更难看。
   *
   * 这里不放刷新按钮：整页本来就能下拉刷新，右上角再摆一个是同一件事的第二个入口。
   */
  @Builder
  dashboardHeader() {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(this.store.vehicleName)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(LeapStyle.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitle)
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 页面是沉浸式铺到状态栏底下的，标题这一行得自己把状态栏那条高度让回来，
    // 否则车名和系统时间叠在一起。
    //
    // 让回来之后还要再留一段：紧接着状态栏起排的标题读起来贴着刘海。
    // 28 是和安卓 `PageTitleTopPadding` 对齐的值，观感基准是 iOS 的 `headerTopInset`。
    .padding({ left: 16, right: 16, top: this.insets.top + 28, bottom: 8 })
  }

  /**
   * 车图下面那排徽章。
   *
   * 车锁常驻——锁没锁上是每次看这一屏都想知道的事。车窗、尾门、前备箱只在开着时才出现：
   * 关好是常态，天天挂一颗「尾门已关」的徽章等于每天报告一件没发生的事，
   * 真出事那次反而淹在里面。哨兵同理只在开着时出现，但用冷静色不用告警色——
   * 它是主动开启的功能，不是没关好的洞。
   *
   * 天窗（告警色）和遮阳帘（冷静色）只在车报了信号 `1718` / `1724` 且确实开着时出现；
   * 不报的车没有这两颗，照「读不到就不显示」。
   *
   * 容器换行且居中，不是一条 `Row`：装货那种场景（解锁 + 尾门 + 前备箱 + 车窗）
   * 四五颗一起亮，一行摆不下，挤在一条 Row 里会溢出屏幕两侧。
   */
  @Builder
  statusBadges() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
      // 行驶中门锁本就是解锁的，这时再报一颗告警色的「已解锁」是误报——看着像出事，
      // 其实只是在开车。所以行驶中把这颗徽章整个换成中性色的「行驶中」，停车后恢复
      // 成锁/解锁。判据是官方那套挡位（见 `VehicleState.isDriving`）。
      if (this.state?.isDriving === true) {
        StatusPill({
          text: '行驶中',
          symbol: $r('sys.symbol.car_fill'),
          tint: LeapStyle.cool,
          tintHex: LeapColors.coolGlow
        })
          .margin({ left: 4, right: 4, bottom: 4 })
      } else {
        // 锁好了是常态，不给它上色——一颗常驻的绿徽章天天在报一件没发生的事，
        // 真解锁那次的琥珀色反而不显眼了。锁着只报事实，颜色留给异常。
        StatusPill({
          text: (this.state?.isLocked ?? true) ? '已锁车' : '已解锁',
          symbol: (this.state?.isLocked ?? true) ? $r('sys.symbol.lock_fill') : $r('sys.symbol.lock_open_fill'),
          tint: (this.state?.isLocked ?? true) ? LeapStyle.textSecondary : LeapStyle.caution,
          tintHex: (this.state?.isLocked ?? true) ? LeapColors.neutralTint : LeapColors.warmGlow
        })
          .margin({ left: 4, right: 4, bottom: 4 })
      }
      if (this.state?.trunkOpen === true) {
        StatusPill({
          text: '尾门开启',
          symbol: $r('sys.symbol.car_side_rear_open_1'),
          tint: LeapStyle.caution,
          tintHex: LeapColors.warmGlow
        })
          .margin({ left: 4, right: 4, bottom: 4 })
      }
      if (this.state?.frontTrunkOpen === true) {
        StatusPill({
          text: '前备箱开启',
          // 和控车条的前备箱按钮同一套「车头特写」字形，同一件事在两处不该长成两个样子。
          symbol: $r('sys.symbol.car_side_front_open_fill'),
          tint: LeapStyle.caution,
          tintHex: LeapColors.warmGlow
        })
          .margin({ left: 4, right: 4, bottom: 4 })
      }
      if (this.windowsOpen) {
        StatusPill({
          text: '车窗开启',
          symbol: $r('sys.symbol.car_window_open_1'),
          tint: LeapStyle.caution,
          tintHex: LeapColors.warmGlow
        })
          .margin({ left: 4, right: 4, bottom: 4 })
      }
      // 天窗和遮阳帘（2026-11-19 起，信号 `1718` / `1724`，同 iOS）只在车报了、且确实开着时出现。
      // 天窗开着跟车窗没关是一类事——下雨会进水——所以用告警色；遮阳帘开着不是隐患，
      // 跟哨兵一样用冷静色，只告诉你它开着。不报这两个信号的车（多数车型）照旧没有这两颗。
      if (this.state?.sunroofOpen === true) {
        StatusPill({
          text: '天窗开启',
          symbol: $r('sys.symbol.car_topwindow_open'),
          tint: LeapStyle.caution,
          tintHex: LeapColors.warmGlow
        })
          .margin({ left: 4, right: 4, bottom: 4 })
      }
      if (this.state?.sunshadeOpen === true) {
        StatusPill({
          text: '遮阳帘开启',
          symbol: $r('sys.symbol.blind_curtain_open'),
          tint: LeapStyle.cool,
          tintHex: LeapColors.coolGlow
        })
          .margin({ left: 4, right: 4, bottom: 4 })
      }
      if (this.store.sentinelOn) {
        // 哨兵是主动开启的功能，不是没关好的洞：用冷静色，别混进那排琥珀色告警里。
        StatusPill({
          text: '哨兵开启',
          symbol: $r('sys.symbol.lock_shield'),
          tint: LeapStyle.cool,
          tintHex: LeapColors.coolGlow
        })
          .margin({ left: 4, right: 4, bottom: 4 })
      }
    }
    .width('100%')
    .animation({ duration: 300, curve: Curve.Smooth })
  }

  // MARK: - 电量 / 空调

  /**
   * 控车卡。车辆主视觉下面那张，四个即时动作收在一张卡里。
   *
   * 它是当前车辆的操作面板，不承担页面导航——和底部那条一级导航形成明确的形态差异。
   */
  @Builder
  quickControlCard() {
    GlassCard({
      radius: LeapStyle.tileRadius,
      contentPadding: 0,
      content: (): void => this.quickControlContent()
    })
  }

  @Builder
  quickControlContent() {
    QuickControlBar({
      onOpenSheet: (name: string) => {
        this.onOpenSheet(name);
      }
    })
  }

  /**
   * 电量卡 + 空调卡，并排两张。
   *
   * 两张必须等高：增程车的电量卡多一条油量条，比空调卡高，不等高时右边那张会浮在
   * 中间、底下露出一截背景，很显眼。
   *
   * 等高只能靠给这一行**写死高度**，两条歧路都试过、都是同一个症状（两张卡一起被
   * 拉到大半屏高，中间空出一大片）：
   * - `Flex` + `ItemAlign.Stretch`：ArkUI 的 `Flex` 默认铺满父容器，
   *   而这里的父容器是 `minHeight: '100%'` 的滚动内容。
   * - `Row` + 子项 `height('100%')`：那个百分比解的也是同一个父容器，
   *   不是 `Row` 自己被内容撑出来的高度。
   *
   * 高度分两档：增程车的电量卡要竖着放续航、还多一条油量条，比纯电那档高一截。
   */
  @Builder
  summaryRow() {
    Row({ space: 12 }) {
      Column() {
        this.batteryTile()
      }
      .layoutWeight(1)
      .height('100%')
      .clip(true)
      .borderRadius(LeapStyle.tileRadius)
      .backgroundEffect(LeapMaterial.cardEffect)
      .visualEffect(LeapMaterial.pressable)
      .onClick(() => {
        this.onPush('charge');
      })

      // 第二格固定是空调卡，不再和哨兵卡二选一：哨兵已经搬进控车条做成一格开关
      // （见 `QuickControlBar`）。原来那套「支持哨兵就把空调卡换掉」的结果是
      // 支持哨兵的车上空调卡整个消失——首页最常看的一张卡，不该被另一个功能挤掉。
      // 空调卡整体不可点：开关和「空调设置」各管各的。
      Column() {
        this.climateTile()
      }
      .layoutWeight(1)
      .height('100%')
      .clip(true)
      .borderRadius(LeapStyle.tileRadius)
      .backgroundEffect(LeapMaterial.cardEffect)
    }
    .width('100%')
    .height(this.summaryHeight)
    .alignItems(VerticalAlign.Top)
  }

  /**
   * 电量卡 / 空调卡这一行的高度。
   *
   * 两张卡各行的字号都是写死的（12 / 32 / 12），高度算得出来，所以这里也写死。
   * 按现在的三段结构逐项加出来的（上下 padding 各 14，段间距 8）：
   * - 纯电 141 = 14 + 34 顶行 + 8 + 45 大数字 + 8 + 18 末行 + 14
   * - 增程 171 = 14 + 34 顶行 + 8 + 64（大数字 + 续航那行）+ 8 + 29（电、油两条）+ 14
   *
   * 增程那个数原来是 185：电、油两条各由一个 16vp 的 SymbolGlyph 撑到 19 高。
   * 换成压了 `lineHeight` 的文字标签之后每条 12，两条连间距 29，整张卡矮了 14。
   * 这一行两张卡等高，电量卡矮下来空调卡跟着矮，中间那片空白也就没了。
   *
   * 早先这两个数是 132 / 152，比内容实际需要的**小**，空调卡下面那行
   * 一直被外层的 `clip(true)` 削掉一截——看着像贴着卡底，其实是被裁的。
   * 所以往下调完必须装机看一眼，裁没裁界面上不报错。
   */
  private get summaryHeight(): number {
    return this.state?.hasFuel === true ? 171 : 141;
  }

  @Builder
  batteryTile() {
    Column({ space: 8 }) {
      // 只有一行标题也要包一层定高的 Row：对面那行有个 34 的电源按钮撑着，
      // 见 `tileHeaderHeight`。
      Row() {
        CardLabel({ text: this.chargeLabel })
      }
      .width('100%')
      .height(this.tileHeaderHeight)
      .alignItems(VerticalAlign.Center)

      Column() {
        // 增程那行「电 312 · 油 380 km」比纯电的「312 km」长一倍，和「76 %」并排就放不下，
        // 所以增程车让续航自己占一行。
        if (this.state?.hasFuel === true) {
          Column({ space: 2 }) {
            MetricValue({ value: this.socText, unit: '%', valueSize: 32 })
            this.rangeLabel()
          }
          .alignItems(HorizontalAlign.Start)
        } else {
          Row({ space: 6 }) {
            MetricValue({ value: this.socText, unit: '%', valueSize: 32 })
            this.rangeLabel()
          }
          .alignItems(VerticalAlign.Bottom)
        }

        // 增程车才有第二条。两条一模一样的条并排着看不出哪条是什么，
        // 各自左边给一个图标，一眼就分得开。
        if (this.state?.gasolinePercent !== null && this.state?.gasolinePercent !== undefined) {
          Column({ space: 5 }) {
            this.batteryLine()
            this.fuelLine()
          }
        } else {
          // 车端没报上限就不画那道刻度。原来这里回退到设置页滑杆的本地草稿值
          // （初值写死 90），于是在 90% 处画出一道车上根本没设过的刻度——同一台车
          // 充电页那行写的是 `--`，两处对不上。数字口径的车本来就不把上限当信号报，
          // 读不到是常态，不是异常。
          Row() {
            BatteryBar({
              soc: this.state?.soc ?? 0,
              limit: this.state?.chargeLimit ?? null,
              charging: this.state?.isCharging ?? false
            })
          }
          .width('100%')
          .constraintSize({ minHeight: this.tileFooterHeight })
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // 大数字贴着标题行，能量条贴着卡底。空调卡下半区也是这么分的——
      // 增程车这张卡比空调卡高，中间那段空白必须让给中间，两张卡的末行才共用一条底线。
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    // 这个 100% 解的是 `summaryRow` 那个写死的行高，不是什么还没定下来的值，所以是安全的
    // （旧版这里注释说不能写，那时候外层还是 Flex 的 Stretch，百分比会去解滚动内容的高度）。
    // 而且必须写：里面那段 `layoutWeight(1)` 要有确定的总高才分得出剩余空间。
    .height('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }

  private get socText(): string {
    const soc = this.state?.soc;
    return soc !== null && soc !== undefined ? String(soc) : '--';
  }

  @Builder
  rangeLabel() {
    if (this.rangeText.length > 0) {
      Text(this.rangeText)
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)
        .maxLines(1)
    }
  }

  /**
   * 电、油各一条。拆成两个无参 @Builder 而不是一个带参的：
   * ArkUI 的 @Builder 传值参数时不会随状态刷新，条子会永远停在首帧那个值。
   */
  @Builder
  batteryLine() {
    this.energyLine(true)
  }

  @Builder
  fuelLine() {
    this.energyLine(false)
  }

  @Builder
  energyLine(isBattery: boolean) {
    Row({ space: 6 }) {
      // 这里原来是 bolt_fill / fuelpump_fill 两个符号。它们是瘦长字形，9vp 渲染出来
      // 只有 5vp 宽，低于规范 2.1.4.3.2 的 8vp 硬线（同一条把四宫格那个右箭头判成了
      // 4×8vp），要过线就得给到 16vp——而 16 的字形框把每条撑到 21 高，两条加起来
      // 比 iOS 那版高出 16vp，增程车的电量卡被顶高，等高的空调卡跟着一起高，
      // 中间空出一大片。
      //
      // 换成一个字的文字标签就没这个矛盾：汉字是方块字，11vp 就是实打实的 11×11，
      // 本来就在硬线之上，不用为了过线去放大。字号取 11 也是项目里小字的基线。
      Text(isBattery ? '电' : '油')
        .fontSize(11)
        .fontColor(LeapStyle.textSecondary)
        // 固定宽高让两条的起点对得齐、行高可控。这里卡的是文字的布局框，和符号那版
        // 不一样：符号的检测量的是字形本身，卡布局框只会把字形裁窄；汉字撑满自己的
        // 字面框，12 装得下 11vp 的字。
        //
        // `lineHeight` 是这次真正省下高度的那一下：不写的话 11 号字的默认行框
        // 有 15~16（行距是按拉丁文的升降部留的），而这两个汉字压根没有降部，
        // 12 就够。省下来的直接体现在下面 `summaryHeight` 的算式里。
        .lineHeight(12)
        .width(12)
        .textAlign(TextAlign.Center)
      if (isBattery) {
        // 增程车两条并排，都改细到 4，比纯电单条的 6 清爽。
        BatteryBar({
          soc: this.state?.soc ?? 0,
          limit: this.state?.chargeLimit ?? null,
          charging: this.state?.isCharging ?? false,
          barHeight: 4
        })
          .layoutWeight(1)
      } else {
        FuelBar({ percent: this.state?.gasolinePercent ?? 0, barHeight: 4 })
          .layoutWeight(1)
      }
    }
    .width('100%')
    // 和上面 `lineHeight` 配套：行高定死，`summaryHeight` 才算得出来。
    .height(12)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 空调卡。
   *
   * 分成互不相干的两块：顶行是标题加一个即开即关的开关，下半区整块点进空调页。
   * 控车条里已经有一个空调开关了，这里再来一个不是重复——那一个是「四个高频动作」
   * 里的一项，这一个是这张卡自己的开关，跟着卡上的温度和设定一起看。
   */
  @Builder
  climateTile() {
    Column({ space: 8 }) {
      Row() {
        CardLabel({ text: this.temperatureLabel })
        Blank()
        this.climatePowerButton()
      }
      .width('100%')
      // 这行的高度本来就是那个 34 的按钮撑出来的，写死只是为了让电量卡照着垫平，
      // 见 `tileHeaderHeight`。
      .height(this.tileHeaderHeight)
      .alignItems(VerticalAlign.Center)

      Column() {
        // 大数字始终是车里实际多少度。空调开不开都是同一件事，数字在「实测」和「设定」
        // 之间跳来跳去，看的人根本分不清眼前这个是哪个。设定温度和风量放到下面那行。
        MetricValue({
          value: this.displayedTempText,
          unit: '°C',
          valueSize: 32
        })
        Row({ space: 4 }) {
          Text(this.store.climateOn ? this.climateDetail : '空调设置')
            .fontSize(12)
            .fontColor(this.store.climateOn ? LeapStyle.cool : LeapStyle.textSecondary)
            .maxLines(2)
            .layoutWeight(1)
          // 圆底那版箭头。光杆 `chevron_right` 字形瘦长，14vp 渲染出来短边只有 6–7vp，
          // 低于规范 2.1.4.3.2 的 8vp 硬线；圆底版 14vp 就是实打实的 14×14。
          SymbolGlyph($r('sys.symbol.chevron_right_circle'))
            .fontSize(14)
            .fontColor([LeapStyle.textTertiary])
        }
        .width('100%')
        .constraintSize({ minHeight: this.tileFooterHeight })
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .layoutWeight(1)
      // 大数字贴标题行、「空调设置」贴卡底，和电量卡分法一致。
      .justifyContent(FlexAlign.SpaceBetween)
      .onClick(() => {
        this.onPush('climate');
      })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    // 同电量卡：解的是 `summaryRow` 写死的行高，也是 `layoutWeight` 分剩余空间的前提。
    .height('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }

  /**
   * 空调卡右上角那个开关。
   *
   * 开着时底是实心主色、前景走 `onAccent`，关着时退回玻璃表面用主文本色——
   * 和空调页那个主开关是同一套配色。不用 iOS 那边的冷蓝：这套色板里
   * 只有 `accent` 配 `onAccent` 是量过的组合（见 `LeapStyle.onAccent`）。
   */
  @Builder
  climatePowerButton() {
    Stack() {
      SymbolGlyph($r('sys.symbol.power'))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor([this.store.climateOn ? LeapStyle.onAccent : LeapStyle.textPrimary])
    }
    .width(34)
    .height(34)
    .borderRadius(17)
    .backgroundColor(this.store.climateOn ? LeapStyle.accent : Color.Transparent)
    .backgroundEffect(this.store.climateOn ? undefined : LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    // 下发中只禁用，不变淡——变淡会把前景和底一起拉向背景，对比度直接掉到 2.5:1。
    .enabled(!this.store.isSendingCommand)
    .accessibilityText(this.store.climateOn ? '关闭空调' : '开启空调')
    .onClick(() => {
      this.store.applyClimate(!this.store.climateOn);
    })
  }

  /**
   * 空调卡的标题。
   *
   * 显示的是车外温度时，标题**必须**说车外，哪怕空调正开着——原来这里空调一开
   * 就写「空调运行中」，那大数字是车内还是车外就没地方交代了。空调开没开
   * 由下面那行小字（`climateDetail`，开着时是蓝色的「设定 x °C · x 档」）负责说。
   */
  private get temperatureLabel(): string {
    const indoor = this.state?.indoorTemp;
    const outdoor = this.state?.outdoorTemp;
    if ((indoor === null || indoor === undefined) && outdoor !== null && outdoor !== undefined) {
      return '车外温度';
    }
    return this.store.climateOn ? '空调运行中' : '车内温度';
  }

  /**
   * 大数字显示哪个温度。车内读不到就退车外——车外是**另一个真实的值**，
   * 不是编出来的默认值，所以这不算「回退成假数据」；但标题必须跟着改口，
   * 见 `temperatureLabel`，绝不能让车外温度冒充车内温度。
   *
   * T03 实测（2026-08-10）整张表里没有 `indoorTemp`，只有 `outdoorTemp`——
   * 这台车不上报车内温度，不是没读到。
   */
  private get displayedTempText(): string {
    const indoor = this.state?.indoorTemp;
    if (indoor !== null && indoor !== undefined) {
      return LeapFormat.temperature(indoor);
    }
    const outdoor = this.state?.outdoorTemp;
    return outdoor !== null && outdoor !== undefined ? LeapFormat.temperature(outdoor) : '--';
  }

  // MARK: - 位置

  @Builder
  locationCard() {
    Column() {
      LocationThumbnail({ coordinate: this.store.coordinate })
        .width('100%')
        .height(132)

      Row({ space: 10 }) {
        Column({ space: 4 }) {
          CardLabel({ text: '车辆位置' })
          Text(this.locationSummary)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
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
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
    .width('100%')
    .clip(true)
    .borderRadius(LeapStyle.tileRadius)
    .backgroundEffect(LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    .onClick(() => {
      this.onPush('location');
    })
  }

  /**
   * 底部常驻的一行小字：说明零跑会话与控车信息的边界。
   * 放在滚动内容最底、控制条上方，一屏之内始终看得到。
   */
  @Builder
  privacyNote() {
    Row({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(12)
        .fontColor([LeapStyle.textTertiary])
      Text('我们不会记录和上传零跑官方服务的会话信息，控车信息等其他信息。')
        .fontSize(11)
        .fontColor(LeapStyle.textTertiary)
        .textAlign(TextAlign.Center)
        .maxLines(2)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 2 })
  }

  // MARK: - 状态条

  /**
   * 车门、车窗、胎压、里程压成一行四列。
   *
   * 原本这些占三张卡，首页要一屏放下就没有那个预算了。
   */
  @Builder
  statusStrip() {
    GlassCard({
      radius: LeapStyle.tileRadius,
      contentPadding: 0,
      content: (): void => this.statusStripContent()
    })
  }

  @Builder
  statusStripContent() {
    Row() {
      StatusColumn({
        title: '车门',
        value: this.state?.anyDoorOpen === true ? '未关' : '已关',
        symbol: $r('sys.symbol.car_top_door_front_left_and_front_right_open'),
        alert: this.state?.anyDoorOpen === true
      })
      this.columnDivider()
      // 控不了车窗的车（部分 T03 没有电动升降窗）这一格退成纯状态显示，和「车门」那格
      // 一样不可点——开合状态位这些车照样报，看得到开没开，只是点进去也没有能下发的档位。
      // 判据见 `VehicleState.windowsRemoteSupported`。
      StatusColumn({
        title: '车窗',
        value: this.windowSummary,
        symbol: $r('sys.symbol.car_window_close_1'),
        tappable: this.store.windowsControllable,
        onTap: () => {
          this.onOpenSheet('windows');
        }
      })
      this.columnDivider()
      StatusColumn({
        title: '胎压',
        value: this.tireSummary,
        symbol: $r('sys.symbol.tire'),
        alert: this.state?.hasTireWarning === true,
        tappable: true,
        onTap: () => {
          this.onOpenSheet('tires');
        }
      })
      this.columnDivider()
      // 这一格比另外三格宽：里程是六位数（跑到 10 万公里不稀奇），
      // 而另外三格永远是两个字。四等分的话六位数加单位加箭头一定挤破。
      StatusColumn({
        title: '行程',
        value: this.mileageSummary,
        unit: this.mileageUnit,
        symbol: $r('sys.symbol.road'),
        columnWeight: 1.3,
        tappable: true,
        onTap: () => {
          this.onPush('mileage');
        }
      })
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
  }

  /** 里程数本身。单位分开给（见 `StatusColumn.unit`），排得下六位数。 */
  private get mileageSummary(): string {
    const total = this.state?.totalMileage;
    return total !== null && total !== undefined ? `${total}` : '--';
  }

  /** 读不到里程时连单位一起不显示，别留一个孤零零的「-- km」。 */
  private get mileageUnit(): string {
    const total = this.state?.totalMileage;
    return total !== null && total !== undefined ? 'km' : '';
  }

  @Builder
  columnDivider() {
    Divider()
      .vertical(true)
      .height(30)
      .color(LeapStyle.separator)
  }

}

/**
 * 状态条里的一列。
 *
 * 做成组件而不是 `@Builder`：ArkUI 的 `@Builder` 传值参数时不会随状态刷新——
 * 首页这一排就曾经卡在车况还没到时的「--」上，之后车况来了也不动。
 * `@Param` 是会跟着变的。
 */
@ComponentV2
export struct StatusColumn {
  @Param title: string = '';
  @Param value: string = '';
  /**
   * 值后面那个小单位，比值小三号。
   *
   * 拆开写不是为了好看，是为了排得下：里程那格是「87564 km」，
   * 单位和值同号时六位数会把胶囊撑破。给空串就当没有。
   */
  @Param unit: string = '';
  @Param symbol: Resource = $r('sys.symbol.car_fill');
  @Param alert: boolean = false;
  @Param tappable: boolean = false;
  /**
   * 这一列占多少份。默认四格均分，需要更宽的格子（里程）自己调大。
   *
   * 不叫 `weight`：那类通用名和 `CustomComponent` 上的属性方法撞过好几次
   * （`size`、`direction` 都栽过），编译期直接报「不能赋给基类的同名属性」。
   */
  @Param columnWeight: number = 1;
  @Event onTap: () => void = () => {
  };

  build() {
    Column({ space: 6 }) {
      // 四个符号的字形高矮不一，高度交给字形自己定的话，下面的值和标题就跟着各差几个点，
      // 四列横着看全是错的。钉死这一行的高度，符号在里头居中。
      SymbolGlyph(this.symbol)
        .fontSize(15)
        .fontColor([this.alert ? LeapStyle.caution : LeapStyle.textSecondary])
        .height(18)
      // 四格里只有车窗和胎压点得进去，可它们和车门、里程长得一模一样，
      // 唯一的区别是一个箭头，等于没有。给能点的那两格套个胶囊底。
      Row({ space: 3 }) {
        Text(this.value)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.alert ? LeapStyle.caution : LeapStyle.textPrimary)
          .maxLines(1)
        if (this.unit.length > 0) {
          Text(this.unit)
            .fontSize(9)
            .fontColor(LeapStyle.textSecondary)
            .maxLines(1)
            // Row 的 space 是 3，单位要紧贴数字，这里把那 3 收回来 1。
            .margin({ left: -1 })
        }
        if (this.tappable) {
          // 用圆底那版箭头，不用光杆 `chevron_right`。
          // 光杆 chevron 字形太瘦，9vp 渲染出来只有 4×8vp，短边低于规范
          // 2.1.4.3.2 的 8vp 硬线——上架检测逮的就是这一处。而它要靠放大过线
          // 得开到 27vp，比旁边 12vp 的数字大出一大截。圆底版宽高相等，
          // 14vp 就是实打实的 14×14vp。
          SymbolGlyph($r('sys.symbol.chevron_right_circle'))
            .fontSize(14)
            .fontColor([LeapStyle.textSecondary])
        }
      }
      .padding({
        left: this.tappable ? 8 : 0,
        right: this.tappable ? 8 : 0,
        // 纵向留白四格一律给，不然有胶囊的两格会比另外两格高出一截。
        top: 4,
        bottom: 4
      })
      .borderRadius(12)
      .backgroundColor(this.tappable ? LeapStyle.fillNeutral : Color.Transparent)

      Text(this.title)
        .fontSize(11)
        .fontColor(LeapStyle.textTertiary)
        .maxLines(1)
    }
    .layoutWeight(this.columnWeight)
    .onClick(() => {
      if (this.tappable) {
        this.onTap();
      }
    })
  }
}
