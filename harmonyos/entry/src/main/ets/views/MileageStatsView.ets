
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { DailyMileage, DrivingStats, DrivingStatsRange, EnergyDistribution, StatsTotals, Weekly, WeeklyEC,
  weekEcId } from '../core/DrivingStats';
import { GlassCard } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { PageMetrics } from './components/PageHeader';

/**
 * 里程能耗统计页。数据来自四个 drivingrecord 接口（见 LeapClient.fetchDrivingStats）。
 *
 * 环形图用官方的 `DataPanel`（Circle 型），折线图用 `Canvas` 手绘——
 * 折线要在点上标数值、末点空心加粗，现成图表组件给不了这个粒度。
 */
@ComponentV2
export struct MileageStatsContent {
  store: VehicleStore = vehicleStore;
  @Local stats: DrivingStats | null = null;
  @Local isLoading: boolean = true;
  @Local isRefreshing: boolean = false;
  /**
   * 当前选中的周柱子（`weekEcId`）。默认是最后一根「本周」，和官方一致。
   * 周列表整个没拉到时为 null，构成卡退回「近 7 天」并改口。
   */
  @Local selectedWeekId: string | null = null;
  /** 按周缓存的能耗构成：点过的周不再重复请求。整份替换才会触发刷新，别原地 set。 */
  @Local distributions: Map<string, EnergyDistribution> = new Map();
  @Local loadingWeekId: string | null = null;

  // 行车/空调/其他三块的固定配色，和图例、环形图共用。
  private readonly driverColor: ResourceColor = LeapStyle.accent;
  private readonly acColor: ResourceColor = LeapStyle.cool;
  private readonly otherColor: ResourceColor = LeapStyle.warm;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.isLoading = true;
    const loaded = await this.store.loadDrivingStats();
    this.stats = loaded;
    // 下拉刷新会把六周的数一起换新，旧缓存不能留着接着用。
    const fresh = new Map<string, EnergyDistribution>();
    this.loadingWeekId = null;
    this.selectedWeekId = loaded !== null ? loaded.distributionWeekId : null;
    if (loaded !== null && loaded.distributionWeekId !== null && loaded.energyDistribution !== null) {
      fresh.set(loaded.distributionWeekId, loaded.energyDistribution);
    }
    this.distributions = fresh;
    this.isLoading = false;
  }

  /** 点某根周柱子：切选中态，缺数据才发请求，拿过的直接用缓存。 */
  private async select(week: WeeklyEC): Promise<void> {
    const range = DrivingStatsRange.forWeek(week.weekStart, week.weekEnd);
    if (range === null) {
      return;
    }
    const id = weekEcId(week);
    this.selectedWeekId = id;
    if (this.distributions.has(id)) {
      return;
    }
    this.loadingWeekId = id;
    const distribution = await this.store.loadEnergyDistribution(range);
    // 拉不到就不写缓存：下次再点还会重试，界面这轮整卡隐藏。
    if (distribution !== null) {
      const next = new Map<string, EnergyDistribution>(this.distributions);
      next.set(id, distribution);
      this.distributions = next;
    }
    if (this.loadingWeekId === id) {
      this.loadingWeekId = null;
    }
  }

  /** 当前选中的那一周。周列表里找不到（比如刷新后周边界变了）就 null。 */
  private get selectedWeek(): WeeklyEC | null {
    const id = this.selectedWeekId;
    const weekly = this.stats !== null ? this.stats.weekly : null;
    if (id === null || weekly === null) {
      return null;
    }
    for (const week of weekly.weeks) {
      if (weekEcId(week) === id) {
        return week;
      }
    }
    return null;
  }

  /**
   * 构成卡该显示的那份数据。选中周还没拉到 / 拉失败就是 null——整卡不出，
   * 不填 0，也不拿别的区间顶。没选中任何周时退回 stats 里那份「近 7 天」。
   */
  private get selectedDistribution(): EnergyDistribution | null {
    const id = this.selectedWeekId;
    if (id === null) {
      return this.stats !== null ? this.stats.energyDistribution : null;
    }
    return this.distributions.get(id) ?? null;
  }

  private get distributionTitle(): string {
    if (this.selectedWeekId === null) {
      return '近 7 天能耗分布';
    }
    const week = this.selectedWeek;
    return week !== null ? `${this.weekRangeLabel(week)}能耗分布` : '所选周能耗分布';
  }

  /** 构成卡标题里的周名：最后一根叫「本周」，其余用 "7/6–7/12" 这样的区间。 */
  private weekRangeLabel(week: WeeklyEC): string {
    if (this.isLastWeek(week)) {
      return '本周';
    }
    const start = MileageStatsContent.weekLabel(week);
    const end = week.weekEnd;
    if (end === null) {
      return start;
    }
    const parts = end.split('-');
    if (parts.length !== 3) {
      return start;
    }
    return `${start}–${Number(parts[1])}/${Number(parts[2])}`;
  }

  private isLastWeek(week: WeeklyEC): boolean {
    const weekly = this.stats !== null ? this.stats.weekly : null;
    if (weekly === null || weekly.weeks.length === 0) {
      return false;
    }
    return weekEcId(weekly.weeks[weekly.weeks.length - 1]) === weekEcId(week);
  }

  private get hasContent(): boolean {
    return this.stats !== null && !this.stats.isEmpty;
  }

  build() {
    // 没有自己的标题栏和背景：这一块是「行程」页里的一栏，外面那层（`TripsView`）
    // 已经铺好背景、画好分段控件，也已经让开了标题栏。
    Refresh({ refreshing: this.isRefreshing }) {
      Scroll() {
        Column({ space: 14 }) {
          if (this.hasContent) {
            this.content()
          } else if (this.isLoading) {
            this.placeholder('正在加载里程能耗…', true)
          } else {
            this.placeholder('暂时拿不到里程能耗数据', false)
          }
          // 官方那份是按天统计的，没有逐趟行程——说一句，免得和隔壁那栏的数字对不上时
          // 让人以为是坏了。
          Text('数据来自零跑官方，按天统计，不含逐趟行程。')
            .fontSize(11)
            .fontColor(LeapStyle.textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
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
        .padding({ left: 16, right: 16 })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .onRefreshing(async () => {
      await this.load();
      this.isRefreshing = false;
    })
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  content() {
    if (this.stats!.totals !== null) {
      this.totalsCard(this.stats!.totals!)
    }
    if (this.stats!.weekly !== null && this.stats!.weekly!.weeks.length > 0) {
      this.weeklyCard()
    }
    // 带参数的 @Builder 是值传递，选中周一变它不会重跑；这两块都得读状态。
    if (this.selectedDistribution !== null) {
      this.distributionCard()
    } else if (this.loadingWeekId !== null && this.loadingWeekId === this.selectedWeekId) {
      this.distributionLoadingCard()
    }
    if (this.stats!.daily.length > 0) {
      this.dailyCard(this.stats!.daily)
    }
  }

  // MARK: - 累计里程 / 累计能耗 / 交付天数

  @Builder
  totalsCard(totals: StatsTotals) {
    GlassCard({ radius: LeapStyle.tileRadius }) {
      Row() {
        this.totalColumn('累计里程', MileageStatsContent.grouped(totals.totalMileageKm), 'km')
        this.columnDivider()
        this.totalColumn('累计能耗', MileageStatsContent.grouped(totals.totalEnergyKwh), 'kWh')
        this.columnDivider()
        this.totalColumn('交付天数', MileageStatsContent.grouped(totals.deliveryDays), '天')
      }
      .width('100%')
    }
  }

  @Builder
  totalColumn(title: string, value: string, unit: string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)
      Text(value)
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontFeature('"tnum" 1')
        .fontColor(LeapStyle.textPrimary)
        .maxLines(1)
      Text(unit)
        .fontSize(11)
        .fontColor(LeapStyle.textTertiary)
    }
    .layoutWeight(1)
  }

  @Builder
  columnDivider() {
    Column()
      .width(1)
      .height(34)
      .backgroundColor(LeapStyle.separator)
  }

  // MARK: - 近 6 周百公里电耗 + 排名 + 柱状

  @Builder
  weeklyCard() {
    GlassCard({ radius: LeapStyle.tileRadius }) {
      Column({ space: 14 }) {
        Row() {
          Column({ space: 4 }) {
            Text('近 6 周百公里电耗')
              .fontSize(12)
              .fontColor(LeapStyle.textSecondary)
            Row({ space: 4 }) {
              Text(this.weeklyData.rankHundredKmEc !== null
                ? MileageStatsContent.trimmed(this.weeklyData.rankHundredKmEc) : '--')
                .fontSize(26)
                .fontWeight(FontWeight.Medium)
                .fontFeature('"tnum" 1')
                .fontColor(LeapStyle.textPrimary)
              Text('kWh')
                .fontSize(12)
                .fontColor(LeapStyle.textTertiary)
            }
            .alignItems(VerticalAlign.Bottom)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.weeklyData.rankPercent !== null) {
            Column({ space: 4 }) {
              Row({ space: 4 }) {
                SymbolGlyph($r('sys.symbol.star_trophy'))
                  .fontSize(13)
                  .fontColor([LeapStyle.accent])
                Text(`前 ${this.weeklyData.rankPercent}`)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(LeapStyle.accent)
              }
              .padding({ left: 11, right: 11, top: 5, bottom: 5 })
              .borderRadius(20)
              .backgroundColor(LeapStyle.fillAccent)
              Text('领先全国同车型')
                .fontSize(11)
                .fontColor(LeapStyle.textTertiary)
            }
            .alignItems(HorizontalAlign.End)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Row({ space: 7 }) {
          ForEach(this.weeklyData.weeks, (week: WeeklyEC, index: number) => {
            Column({ space: 4 }) {
              Text(week.hundredKmEc !== null ? MileageStatsContent.trimmed(week.hundredKmEc) : '--')
                .fontSize(10)
                .fontWeight(this.isHighlighted(week, index) ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.isHighlighted(week, index) ? LeapStyle.textPrimary : LeapStyle.textSecondary)
              Column()
                .width('100%')
                .height(MileageStatsContent.barHeight(week.hundredKmEc ?? 0,
                  MileageStatsContent.maxEc(this.weeklyData.weeks)))
                .borderRadius(4)
                .backgroundColor(this.isHighlighted(week, index) ? LeapStyle.accent : LeapStyle.chartBar)
              Text(index === this.weeklyData.weeks.length - 1 ? '本周' : MileageStatsContent.weekLabel(week))
                .fontSize(9)
                .fontColor(LeapStyle.textTertiary)
                .maxLines(1)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.End)
            .onClick(() => {
              this.select(week);
            })
          // key 得带上选中态：只改属性不换 key，ForEach 会复用旧节点，颜色纹丝不动。
          }, (week: WeeklyEC, index: number) =>
            `${index}-${week.weekStart ?? ''}-${weekEcId(week) === this.selectedWeekId ? 1 : 0}`)
        }
        .width('100%')
        .height(108)
        .alignItems(VerticalAlign.Bottom)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  /** 柱子上不上主色：跟着选中走；一根都没选中时回到「本周高亮」。 */
  private isHighlighted(week: WeeklyEC, index: number): boolean {
    if (this.selectedWeekId !== null) {
      return weekEcId(week) === this.selectedWeekId;
    }
    const weekly = this.stats !== null ? this.stats.weekly : null;
    return weekly !== null && index === weekly.weeks.length - 1;
  }

  /** weeklyCard 是无参 @Builder，数据从这里取——带参 builder 不跟着状态重跑。 */
  private get weeklyData(): Weekly {
    const weekly = this.stats !== null ? this.stats.weekly : null;
    return weekly ?? { rankPercent: null, rankHundredKmEc: null, weeks: [] };
  }

  private static maxEc(weeks: WeeklyEC[]): number {
    let max = 0.1;
    for (const week of weeks) {
      const value = week.hundredKmEc ?? 0;
      if (value > max) {
        max = value;
      }
    }
    return max;
  }

  private static barHeight(value: number, maxValue: number): number {
    const usable = 74;
    return Math.max(6, (value / maxValue) * usable);
  }

  // MARK: - 能耗构成环形图

  @Builder
  distributionLoadingCard() {
    GlassCard({ radius: LeapStyle.tileRadius }) {
      Column({ space: 12 }) {
        Text(this.distributionTitle)
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)
        Column() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(LeapStyle.textTertiary)
        }
        .width('100%')
        .height(112)
        .justifyContent(FlexAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  @Builder
  distributionCard() {
    GlassCard({ radius: LeapStyle.tileRadius }) {
      Column({ space: 12 }) {
        Text(`${this.distributionTitle} · 总 ${MileageStatsContent.trimmed(this.distribution.totalKwh)} kWh`)
          .fontSize(12)
          .fontColor(LeapStyle.textSecondary)

        Row({ space: 18 }) {
          Stack() {
            // 官方 DataPanel 的 Circle 型就是环形占比图，比自己画弧稳。
            // 环外径 112、环宽 13 → 内圈直径 86vp，能放进去的正方形边长约 61vp。
            // 原先是 104/15，内圈只有 74vp、可用方框 52vp，而中间那两行
            // （20vp 的数字 + 11vp 的单位）就要占掉约 40×38vp，
            // 四个角全贴在环上。加大外径、收窄环宽，两边各让出一点。
            DataPanel({
              values: [this.distribution.driverKwh, this.distribution.acKwh, this.distribution.otherKwh],
              max: Math.max(this.distribution.driverKwh + this.distribution.acKwh
                + this.distribution.otherKwh, 0.0001),
              type: DataPanelType.Circle
            })
              .width(112)
              .height(112)
              .strokeWidth(13)
              .valueColors([this.driverColor, this.acColor, this.otherColor])
              .trackBackgroundColor(LeapStyle.separator)
              // 关掉光晕：卡片本身已经有材质，再加一层辉光会糊成一团。
              .closeEffect(true)

            Column() {
              Text(MileageStatsContent.trimmed(this.distribution.totalKwh))
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontFeature('"tnum" 1')
                .fontColor(LeapStyle.textPrimary)
              Text('kWh')
                .fontSize(11)
                .fontColor(LeapStyle.textTertiary)
            }
          }
          .width(112)
          .height(112)

          Column({ space: 10 }) {
            // 图例做成独立组件而不是带参 @Builder：builder 的参数是值传递，
            // 换一周之后百分比会停在第一次的数上。
            LegendRow({ title: '行车能耗', pct: this.distribution.driverPct, dotColor: this.driverColor })
            LegendRow({ title: '空调能耗', pct: this.distribution.acPct, dotColor: this.acColor })
            LegendRow({ title: '其他能耗', pct: this.distribution.otherPct, dotColor: this.otherColor })
          }
          .layoutWeight(1)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  /** distributionCard 是无参 @Builder，数据从这里取。调用方已保证非 null。 */
  private get distribution(): EnergyDistribution {
    return this.selectedDistribution ?? DrivingStats.distributionOf(0, 0, 0);
  }

  // MARK: - 近 7 天里程折线

  @Builder
  dailyCard(daily: DailyMileage[]) {
    GlassCard({ radius: LeapStyle.tileRadius }) {
      Column({ space: 12 }) {
        Row() {
          Text('近 7 天里程')
            .fontSize(12)
            .fontColor(LeapStyle.textSecondary)
          Blank()
          Row({ space: 3 }) {
            Text(MileageStatsContent.grouped(MileageStatsContent.sum(daily)))
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontFeature('"tnum" 1')
              .fontColor(LeapStyle.textPrimary)
            Text('km')
              .fontSize(11)
              .fontColor(LeapStyle.textTertiary)
          }
          .alignItems(VerticalAlign.Bottom)
        }
        .width('100%')

        DailyMileageChart({ entries: daily })
          .width('100%')
          .height(104)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  private static sum(daily: DailyMileage[]): number {
    let total = 0;
    for (const entry of daily) {
      total += entry.mileageKm ?? 0;
    }
    return total;
  }

  // MARK: - 状态占位

  @Builder
  placeholder(text: string, spinning: boolean) {
    GlassCard() {
      Column({ space: 12 }) {
        if (spinning) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color(LeapStyle.textSecondary)
        } else {
          SymbolGlyph($r('sys.symbol.histogram'))
            .fontSize(24)
            .fontColor([LeapStyle.textSecondary])
        }
        Text(text)
          .fontSize(13)
          .fontColor(LeapStyle.textSecondary)
      }
      .width('100%')
      .padding({ top: 28, bottom: 28 })
    }
  }

  // MARK: - 小工具

  /** 千分位分组：12345 → "12,345"。读不到写 `--`。 */
  private static grouped(value: number | null): string {
    if (value === null) {
      return '--';
    }
    const rounded = Math.round(value);
    const negative = rounded < 0;
    let digits = String(Math.abs(rounded));
    let out = '';
    while (digits.length > 3) {
      out = `,${digits.substring(digits.length - 3)}${out}`;
      digits = digits.substring(0, digits.length - 3);
    }
    return `${negative ? '-' : ''}${digits}${out}`;
  }

  /** 去掉多余小数尾巴：15.0 → "15"，15.7 → "15.7"。 */
  static trimmed(value: number): string {
    return value === Math.round(value) ? String(Math.round(value)) : value.toFixed(1);
  }

  /** "2026-07-06" → "7/6" */
  private static weekLabel(week: WeeklyEC): string {
    const start = week.weekStart;
    if (start === null) {
      return '';
    }
    const parts = start.split('-');
    if (parts.length !== 3) {
      return start;
    }
    return `${Number.parseInt(parts[1], 10)}/${Number.parseInt(parts[2], 10)}`;
  }
}

/**
 * 折线图：把每日里程点连成线，点上标数值，底部标日期。末点空心加粗。
 *
 * Canvas 而不是官方图表组件：数值标签、末点描边这些细节图表组件调不出来，
 * 而这几样正是「今天跑了多少」一眼可读的关键。
 */
/** 能耗构成图例的一行。@Param 会跟着父组件重画更新，带参 @Builder 不会。 */
@ComponentV2
struct LegendRow {
  @Param title: string = '';
  @Param pct: number | null = null;
  @Param dotColor: ResourceColor = LeapStyle.accent;

  build() {
    Row({ space: 8 }) {
      Column()
        .width(10)
        .height(10)
        .borderRadius(2)
        .backgroundColor(this.dotColor)
      Text(this.title)
        .fontSize(13)
        .fontColor(LeapStyle.textSecondary)
      Blank()
      Text(this.pct !== null ? `${MileageStatsContent.trimmed(this.pct)}%` : '--')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontFeature('"tnum" 1')
        .fontColor(LeapStyle.textPrimary)
    }
    .width('100%')
  }
}

@ComponentV2
struct DailyMileageChart {
  @Param entries: DailyMileage[] = [];
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  /** Canvas 只吃十六进制串，资源色在这里解析一次。深浅色切换会重建组件，值跟着变。 */
  private textPrimary: string = '#FFFFFF';
  private textSecondary: string = '#99FFFFFF';
  private textTertiary: string = '#66FFFFFF';
  private pointFill: string = '#101418';
  /**
   * 折线和数据点的颜色。
   *
   * 原先直接写 `LeapColors.accentGlow`——那是给背景光晕用的十六进制常量，
   * 深浅色共用一个值。浅色模式下这条亮绿线画在白卡片上只有 1.8:1，
   * 同一页的「本周」柱子和图例方块却是深绿的，一眼就能看出不是一家的。
   * 走资源解析，跟着深浅色取值。
   */
  private lineColor: string = '#4DC47D';

  aboutToAppear(): void {
    const context = getContext(this);
    this.textPrimary = LeapColors.resolve(context, LeapStyle.textPrimary, this.textPrimary);
    this.textSecondary = LeapColors.resolve(context, LeapStyle.textSecondary, this.textSecondary);
    this.textTertiary = LeapColors.resolve(context, LeapStyle.textTertiary, this.textTertiary);
    this.pointFill = LeapColors.resolve(context, LeapStyle.bgMid, this.pointFill);
    this.lineColor = LeapColors.resolve(context, LeapStyle.accent, this.lineColor);
  }

  @Monitor('entries')
  onEntriesChanged(): void {
    this.draw();
  }

  build() {
    Canvas(this.context)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.draw();
      })
  }

  private draw(): void {
    const ctx = this.context;
    const width = ctx.width;
    const height = ctx.height;
    if (width <= 0 || height <= 0 || this.entries.length === 0) {
      return;
    }
    ctx.clearRect(0, 0, width, height);

    // 标签字号从 10/9vp 提到 12vp 之后，上下都得多让一点，
    // 否则最高点的数值会顶到卡片边、日期会被裁掉半行。
    const topInset = 24; // 给数值标签留头
    const bottomInset = 24; // 给日期标签留脚
    const plotHeight = Math.max(height - topInset - bottomInset, 1);

    const values: number[] = this.entries.map((entry: DailyMileage) => entry.mileageKm ?? 0);
    let maxValue = 1;
    let minValue = values[0];
    for (const value of values) {
      if (value > maxValue) {
        maxValue = value;
      }
      if (value < minValue) {
        minValue = value;
      }
    }
    if (minValue > maxValue) {
      minValue = maxValue;
    }
    const span = Math.max(maxValue - minValue, 1);

    // 左右各让出一截。首尾两个点如果落在 x=0 和 x=width 上，
    // 它们底下那两个居中的日期标签会被画布边缘裁掉一半——右边那个正是「今天」，
    // 整张图最该看清的一格反而没了。
    const sideInset = 20;
    const plotWidth = Math.max(width - sideInset * 2, 1);

    const xs: number[] = [];
    const ys: number[] = [];
    for (let i = 0; i < values.length; i++) {
      xs.push(values.length > 1
        ? sideInset + plotWidth * i / (values.length - 1)
        : width / 2);
      ys.push(topInset + plotHeight * (1 - (values[i] - minValue) / span));
    }

    // 折线
    ctx.beginPath();
    ctx.lineWidth = 2.5;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.strokeStyle = this.lineColor;
    ctx.moveTo(xs[0], ys[0]);
    for (let i = 1; i < xs.length; i++) {
      ctx.lineTo(xs[i], ys[i]);
    }
    ctx.stroke();

    ctx.textAlign = 'center';
    for (let i = 0; i < xs.length; i++) {
      const isLast = i === xs.length - 1;
      // 数据点。末点空心：今天还没走完，和已经定死的历史点区分开。
      ctx.beginPath();
      ctx.arc(xs[i], ys[i], isLast ? 4.5 : 3, 0, Math.PI * 2);
      if (isLast) {
        ctx.fillStyle = this.pointFill;
        ctx.fill();
        ctx.lineWidth = 2;
        ctx.strokeStyle = this.lineColor;
        ctx.stroke();
      } else {
        ctx.fillStyle = this.lineColor;
        ctx.fill();
      }

      // 数值标签。10vp 在真机上偏小，画在折线旁边不好认；提到 12vp——
      // 这也正好是规范 2.1.4.2 的推荐字号（硬线是 8vp）。
      // 非末点用 secondary 而不是 tertiary：这一列是图里最该读出来的数，
      // 压到第三档没必要。
      ctx.font = isLast ? '500 12vp sans-serif' : '12vp sans-serif';
      ctx.fillStyle = isLast ? this.textPrimary : this.textSecondary;
      ctx.fillText(String(Math.round(values[i])), xs[i], Math.max(ys[i] - 15, 14));

      // 日期标签。同样提到 12vp——7 个标签横排间距约 47vp，放得下。
      ctx.font = '12vp sans-serif';
      ctx.fillStyle = this.textTertiary;
      ctx.fillText(this.dayText(i), xs[i], height - 7);
    }
  }

  private dayText(index: number): string {
    const count = this.entries.length;
    if (index === count - 1) {
      return '今天';
    }
    if (index === count - 2) {
      return '昨天';
    }
    if (index === count - 3) {
      return '前天';
    }
    // day 形如 "2026-08-06" 或 "08-06"，取日。
    const parts = this.entries[index].day.split('-');
    const last = parts[parts.length - 1];
    const value = Number.parseInt(last, 10);
    return Number.isNaN(value) ? this.entries[index].day : String(value);
  }
}
