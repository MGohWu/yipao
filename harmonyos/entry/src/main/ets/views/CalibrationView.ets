import { HdsNavDestination } from '@kit.UIDesignKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import {
  Calibration, CalibrationBaseline, CalibrationTask, CalibrationTasks, SignalChange, TaskOutcome
} from '../core/Calibration';
import { VehicleSignal } from '../core/SignalSchema';
import { LeapBackground, GlassCard } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { PageMetrics } from './components/PageHeader';

/** 流程阶段。task 阶段还要带上「第几项 / 是不是复原步」。 */
enum CalibrationStage {
  intro = 'intro',
  /** 静止采样，摸清哪些字段自己会变。 */
  baseline = 'baseline',
  task = 'task',
  summary = 'summary'
}

/**
 * 「帮我适配车型」的引导流程。
 *
 * 车主在车边按提示操作，App 比对操作前后的车况，反推出这台车的信号 ID。
 * 全程不上传任何数据——标定结果先存本机立刻生效，要不要发给开发者由用户自己决定。
 *
 * iOS 那版把流程状态拆在一个独立的 `CalibrationModel` 里；这里合进组件：
 * 状态全是这一页私有的，V2 的 `@Local` 已经够用，再拆一层反而要多写一遍同步。
 */
@ComponentV2
export struct CalibrationView {
  store: VehicleStore = vehicleStore;

  @Local stage: CalibrationStage = CalibrationStage.intro;
  @Local taskIndex: number = 0;
  @Local isBackwardStep: boolean = false;
  @Local baseline: CalibrationBaseline = new CalibrationBaseline();
  @Local outcomes: TaskOutcome[] = [];
  /** 正在等车上报变化。 */
  @Local isCapturing: boolean = false;
  /** 上一步有没有捕捉到变化，用来给用户即时反馈。null 表示还没有上一步。 */
  @Local lastStepCaught: boolean | null = null;
  @Local progressText: string = '';

  /** 当前这一步的操作前快照。 */
  private before: Map<string, string> = new Map<string, string>();
  private forwardChanges: SignalChange[] = [];

  /** 和确认车辆响应用的是同一个窗口：实测车辆 5–10 秒响应，休眠时更久。 */
  private static readonly captureTimeoutMs: number = 20000;

  aboutToAppear(): void {
    // 标定要自己控制采样节奏，五秒一次的后台轮询会插进来干扰 diff。
    this.store.stopPolling();
  }

  aboutToDisappear(): void {
    this.store.startPolling();
  }

  private get tasks(): CalibrationTask[] {
    return CalibrationTasks.all;
  }

  private get currentTask(): CalibrationTask | null {
    return this.taskIndex < this.tasks.length ? this.tasks[this.taskIndex] : null;
  }

  /** 当前该让用户做的动作。 */
  private get actionText(): string {
    const task = this.currentTask;
    if (task === null) {
      return '';
    }
    return this.isBackwardStep ? task.backward : task.forward;
  }

  private get learned(): Map<VehicleSignal, string> {
    return Calibration.learnedKeys(this.outcomes);
  }

  private get report(): string {
    return Calibration.report(
      this.store.session.selectedCarType,
      this.store.state?.schema.id ?? 'unknown',
      this.baseline,
      this.outcomes,
      CalibrationView.today()
    );
  }

  // MARK: - 流程

  private async start(): Promise<void> {
    this.stage = CalibrationStage.baseline;
    await this.runBaseline();
  }

  /**
   * 静止采 3 次，两两相比，变过的字段全部拉进排除名单。
   *
   * 不做这一步，后面每个任务的 diff 都会混进时间戳、经纬度、电压这些一直在跳的字段。
   */
  private async runBaseline(): Promise<void> {
    const samples: Map<string, string>[] = [];
    for (let index = 0; index < 3; index++) {
      this.progressText = `正在采样 ${index + 1}/3`;
      const map = await this.store.captureSignalMap();
      if (map !== null) {
        samples.push(map);
      }
      if (index < 2) {
        await CalibrationView.sleep(10000);
      }
    }
    this.baseline = CalibrationBaseline.make(samples);
    this.progressText = '';
    await this.beginStep(0, false);
  }

  /** 进入某一步：先记下操作前的车况，再让用户去动车。 */
  private async beginStep(index: number, isBackward: boolean): Promise<void> {
    if (index >= this.tasks.length) {
      this.stage = CalibrationStage.summary;
      return;
    }
    this.lastStepCaught = null;
    this.taskIndex = index;
    this.isBackwardStep = isBackward;
    this.stage = CalibrationStage.task;
    this.before = await this.store.captureSignalMap() ?? new Map<string, string>();
  }

  /** 用户点了「我做好了」。车端上报有延迟，实测 5–10 秒，所以要连着刷几次等。 */
  private async confirmStepDone(): Promise<void> {
    if (this.stage !== CalibrationStage.task || this.isCapturing) {
      return;
    }
    this.isCapturing = true;
    const index = this.taskIndex;
    const isBackward = this.isBackwardStep;

    let caught: SignalChange[] = [];
    const deadline = Date.now() + CalibrationView.captureTimeoutMs;
    while (Date.now() < deadline) {
      await CalibrationView.sleep(2000);
      this.progressText = '正在等车辆上报…';
      const after = await this.store.captureSignalMap();
      if (after === null) {
        continue;
      }
      const changes = Calibration.changes(this.before, after, this.baseline.noisyKeys);
      if (changes.length > 0) {
        caught = changes;
        break;
      }
    }

    this.isCapturing = false;
    this.progressText = '';
    this.lastStepCaught = caught.length > 0;

    if (isBackward) {
      this.outcomes = this.outcomes.concat([
        new TaskOutcome(this.tasks[index].id, this.tasks[index].signal, this.forwardChanges, caught)
      ]);
      this.forwardChanges = [];
      await this.beginStep(index + 1, false);
    } else {
      this.forwardChanges = caught;
      await this.beginStep(index, true);
    }
  }

  /**
   * 这一步做不了（比如车没有电动尾门），跳过整个任务。
   *
   * 在第 2 步跳过时，第 1 步采到的变化不扔——它按单向规则还有可能立得住。
   */
  private async skipTask(): Promise<void> {
    if (this.stage !== CalibrationStage.task) {
      return;
    }
    const index = this.taskIndex;
    if (this.isBackwardStep) {
      this.outcomes = this.outcomes.concat([
        new TaskOutcome(this.tasks[index].id, this.tasks[index].signal, this.forwardChanges, [], false)
      ]);
    }
    this.forwardChanges = [];
    await this.beginStep(index + 1, false);
  }

  /** 报告里的日期。只到天——精确到秒对排查没帮助，反而多一条可关联的信息。 */
  private static today(): string {
    const now = new Date();
    const pad = (value: number): string => value < 10 ? `0${value}` : String(value);
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
  }

  private static sleep(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, milliseconds);
    });
  }

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: LeapColors.accentGlow })

        // 背景照旧铺满，只有内容让开那条浮在它之上的标题栏。
        Column() {
          if (this.stage === CalibrationStage.intro) {
            this.intro()
          } else if (this.stage === CalibrationStage.baseline) {
            this.baselineStage()
          } else if (this.stage === CalibrationStage.task) {
            this.taskStep()
          } else {
            this.summary()
          }
        }
        .width('100%')
        .height('100%')
        .padding({ top: PageMetrics.navTopInset })
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      style: LeapMaterial.navigationTitleBarStyle(),
      content: { title: { mainTitle: '适配我的车型' } },
      // 默认是 false，标题栏会直接压在状态栏上。
      avoidLayoutSafeArea: true
    })
  }

  // MARK: - 说明

  @Builder
  intro() {
    Scroll() {
      Column({ space: 18 }) {
        Text('你的车有些车况这个 App 还认不出来')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(LeapStyle.textPrimary)

        Text('零跑没有公开车况字段表，不同车型上报的字段名也不一样。'
          + '跟着提示在车边操作几下，App 比对操作前后的差异，'
          + '就能认出你这台车的门锁、车门、车窗和空调。')
          .fontSize(14)
          .fontColor(LeapStyle.textSecondary)

        Column({ space: 12 }) {
          this.bullet($r('sys.symbol.car_fill'), '需要你在车边，全程约 10–15 分钟')
          this.bullet($r('sys.symbol.lock_shield'), '不上传任何数据，结果只存在这台手机上')
          this.bullet($r('sys.symbol.checkmark_circle'), '做完立刻生效，马上能看到自己车的状态')
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 4, bottom: 4 })

        Text('要做的事')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(LeapStyle.textPrimary)

        ForEach(this.tasks, (task: CalibrationTask) => {
          Row({ space: 10 }) {
            Column()
              .width(5)
              .height(5)
              .borderRadius(3)
              .backgroundColor(LeapStyle.textTertiary)
              .margin({ top: 7 })
            Text(`${task.title}：${task.forward}，然后${task.backward}`)
              .fontSize(14)
              .fontColor(LeapStyle.textSecondary)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (task: CalibrationTask) => task.id)

        this.primaryButton('开始', () => {
          this.start();
        })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(20)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  bullet(symbol: Resource, text: string) {
    Row({ space: 8 }) {
      SymbolGlyph(symbol)
        .fontSize(15)
        .fontColor([LeapStyle.textSecondary])
      Text(text)
        .fontSize(14)
        .fontColor(LeapStyle.textSecondary)
    }
  }

  // MARK: - 静止基线

  @Builder
  baselineStage() {
    Column({ space: 16 }) {
      LoadingProgress()
        .width(44)
        .height(44)
        .color(LeapStyle.accent)
      Text('请先什么都别做')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(LeapStyle.textPrimary)
      Text('车上有些数值自己就一直在变——时间、位置、电压。'
        + '先记下它们，后面才分得清哪些变化是你操作出来的。')
        .fontSize(14)
        .fontColor(LeapStyle.textSecondary)
        .textAlign(TextAlign.Center)
      Text(this.progressText)
        .fontSize(12)
        .fontFeature('"tnum" 1')
        .fontColor(LeapStyle.textTertiary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(30)
  }

  // MARK: - 单步操作

  @Builder
  taskStep() {
    Column() {
      Progress({
        value: this.taskIndex,
        total: this.tasks.length,
        type: ProgressType.Linear
      })
        .color(LeapStyle.accent)
        .backgroundColor(LeapStyle.separator)
        .width('100%')
        .margin({ left: 20, right: 20, top: 8 })

      Blank()

      Column({ space: 14 }) {
        Text(`${this.currentTask?.title ?? ''} · ${this.isBackwardStep ? '第 2 步' : '第 1 步'}`)
          .fontSize(12)
          .fontColor(LeapStyle.textTertiary)

        Text(this.actionText)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(LeapStyle.textPrimary)
          .textAlign(TextAlign.Center)

        if ((this.currentTask?.hint ?? '').length > 0) {
          Text(this.currentTask!.hint)
            .fontSize(14)
            .fontColor(LeapStyle.textSecondary)
            .textAlign(TextAlign.Center)
        }

        if (this.lastStepCaught !== null) {
          Row({ space: 6 }) {
            SymbolGlyph(this.lastStepCaught
              ? $r('sys.symbol.checkmark_circle_fill')
              : $r('sys.symbol.exclamationmark_triangle_fill'))
              .fontSize(13)
              .fontColor([this.lastStepCaught ? LeapStyle.accent : LeapStyle.caution])
            Text(this.lastStepCaught ? '上一步已捕捉到变化' : '上一步没捕捉到变化')
              .fontSize(12)
              .fontColor(this.lastStepCaught ? LeapStyle.accent : LeapStyle.caution)
          }
        }
      }
      .width('100%')
      .padding({ left: 30, right: 30 })

      Blank()

      Column({ space: 12 }) {
        if (this.isCapturing) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(LeapStyle.textSecondary)
            Text(this.progressText)
              .fontSize(14)
              .fontColor(LeapStyle.textSecondary)
          }
          .height(44)
        } else {
          this.primaryButton('我做好了', () => {
            this.confirmStepDone();
          })
        }

        Text('这项跳过')
          .fontSize(14)
          .fontColor(LeapStyle.textSecondary)
          // 采集中只禁用，不变淡——`.opacity(0.4)` 会把它拉到 1.85:1。
          // 上面那行转圈加进度文案已经说清楚了现在在干什么。
          .enabled(!this.isCapturing)
          .onClick(() => {
            this.skipTask();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 24 })
    }
    .width('100%')
    .height('100%')
  }

  // MARK: - 汇总

  @Builder
  summary() {
    Scroll() {
      Column({ space: 18 }) {
        Text(this.learned.size === 0 ? '这次没能认出新字段' : `认出了 ${this.learned.size} 项车况`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(LeapStyle.textPrimary)

        if (this.baseline.looksAsleep) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.sleep'))
              .fontSize(14)
              .fontColor([LeapStyle.caution])
            Text('开始那会儿车是睡着的，采样三次一个数都没变。'
              + '这一轮的结果可靠性打折，车醒着时重做一次会准得多。')
              .fontSize(12)
              .fontColor(LeapStyle.caution)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }

        if (this.learned.size === 0) {
          Text('可能是操作和车辆上报之间隔得太久，或者这台车不上报这些状态。可以隔一会儿再试一次。')
            .fontSize(14)
            .fontColor(LeapStyle.textSecondary)
        } else {
          GlassCard({ contentPadding: 0 }) {
            Column() {
              ForEach(this.outcomes, (outcome: TaskOutcome, index: number) => {
                if (index > 0) {
                  Column().width('100%').height(0.5).backgroundColor(LeapStyle.separator)
                }
                Row({ space: 10 }) {
                  SymbolGlyph(outcome.isConfirmed
                    ? $r('sys.symbol.checkmark_circle_fill')
                    : $r('sys.symbol.minus_circle'))
                    .fontSize(16)
                    .fontColor([outcome.isConfirmed ? LeapStyle.accent : LeapStyle.textTertiary])
                  Text(CalibrationView.titleOf(outcome.taskID))
                    .fontSize(14)
                    .fontColor(LeapStyle.textPrimary)
                  Blank()
                  Text(outcome.confirmedKeys.length > 0 ? outcome.confirmedKeys.join(', ') : '未确认')
                    .fontSize(12)
                    .fontFeature('"tnum" 1')
                    .fontColor(LeapStyle.textSecondary)
                }
                .width('100%')
                .padding(14)
              }, (outcome: TaskOutcome) => outcome.taskID)
            }
            .width('100%')
          }
        }

        if (this.learned.size > 0) {
          this.primaryButton('在这台手机上启用', () => {
            this.store.applyCalibration(this.learned);
          })
        }

        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.doc_text_on_doc_text'))
            .fontSize(16)
            .fontColor([LeapStyle.textPrimary])
          Text('拷贝标定报告发给开发者')
            .fontSize(15)
            .fontColor(LeapStyle.textPrimary)
        }
        .width('100%')
        .height(48)
        .justifyContent(FlexAlign.Center)
        .borderRadius(LeapStyle.tileRadius)
        .backgroundEffect(LeapMaterial.cardEffect)
        .visualEffect(LeapMaterial.pressable)
        .onClick(() => {
          this.copyReport();
        })

        Text('报告里只有信号编号和前后数值，不含车架号、位置和账号信息。')
          .fontSize(12)
          .fontColor(LeapStyle.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(20)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  private static titleOf(taskID: string): string {
    const task = CalibrationTasks.all.find((item: CalibrationTask) => item.id === taskID);
    return task !== undefined ? task.title : taskID;
  }

  /**
   * 鸿蒙没有 SwiftUI 的 `ShareLink`。报告是纯文本，走剪贴板比拉起分享面板直接——
   * 用户要贴到哪儿（邮件、IM、issue）由他自己决定。
   */
  private async copyReport(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.report);
      await pasteboard.getSystemPasteboard().setData(data);
      this.store.show('标定报告已拷贝', '可以粘贴到任意聊天窗口发给开发者');
    } catch (e) {
      this.store.show('拷贝失败', String(e));
    }
  }

  @Builder
  primaryButton(title: string, action: () => void) {
    Text(title)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      // 实心主色底上的文字走 onAccent，不写死白色——深色的 accent 是亮绿。
      .fontColor(LeapStyle.onAccent)
      .width('100%')
      .height(48)
      .textAlign(TextAlign.Center)
      .borderRadius(LeapStyle.tileRadius)
      .backgroundColor(LeapStyle.accent)
      .onClick(action)
  }
}
