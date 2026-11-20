import { HdsNavDestination } from '@kit.UIDesignKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { ControlDiagnostic, ControlOutcome, ReceiptSample } from '../app/ControlDiagnostic';
import { LeapBackground, GlassCard } from '../design/LeapGlass';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { LeapMaterial } from '../design/LeapMaterial';
import { PageMetrics } from './components/PageHeader';

/** 折叠后的一段回执。连续内容相同的采样归成一段。 */
interface ResponseGroup {
  title: string;
  body: string;
}

/**
 * 最近一次控车的经过。
 *
 * 这一页是给排查用的，不是给日常使用的，所以允许出现 cmdid、原始响应这类东西。
 * 它存在的原因很具体：回执接口 `/appremotectl/query` 的返回结构没有任何已验证样本，
 * 「车还在执行」和「车拒绝了这条指令」现在区分不出来。攒够真实响应才能写出码表，
 * 在那之前只能靠超时来判断，而超时说不出原因。
 */
@ComponentV2
export struct ControlDiagnosticView {
  store: VehicleStore = vehicleStore;

  private get diagnostic(): ControlDiagnostic | null {
    return this.store.lastDiagnostic;
  }

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: LeapColors.coolGlow })

        if (this.diagnostic !== null) {
          Scroll() {
            Column({ space: 20 }) {
              this.processSection(this.diagnostic!)
              this.identifierSection(this.diagnostic!)
              this.responsesSection(this.diagnostic!)
              this.copyButton(this.diagnostic!)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: PageMetrics.navTopInset, bottom: 32 })
          }
          .scrollBar(BarState.Off)
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
        } else {
          this.emptyState()
        }
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      style: LeapMaterial.navigationTitleBarStyle(),
      content: { title: { mainTitle: '指令诊断' } },
      // 默认是 false，标题栏会直接压在状态栏上。
      avoidLayoutSafeArea: true
    })
  }

  @Builder
  processSection(diagnostic: ControlDiagnostic) {
    Column({ space: 8 }) {
      this.sectionHeader('经过')
      GlassCard() {
        Column({ space: 12 }) {
          this.field('指令', diagnostic.label, LeapStyle.textPrimary)
          this.field('结果', ControlDiagnosticView.outcomeText(diagnostic.outcome),
            ControlDiagnosticView.outcomeTint(diagnostic.outcome))
          this.field('耗时', `${diagnostic.elapsed.toFixed(1)} 秒`, LeapStyle.textPrimary)
          this.field('查询次数', String(diagnostic.pollCount), LeapStyle.textPrimary)
          this.field('时间', ControlDiagnosticView.timestamp(diagnostic.sentAt), LeapStyle.textPrimary)
          if (diagnostic.errorMessage !== null) {
            this.field('错误', diagnostic.errorMessage, LeapStyle.caution)
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  identifierSection(diagnostic: ControlDiagnostic) {
    Column({ space: 8 }) {
      this.sectionHeader('标识')
      GlassCard() {
        Column({ space: 12 }) {
          this.field('cmdid', diagnostic.cmdid, LeapStyle.textPrimary)
          this.field('msgID', diagnostic.msgID.length > 0 ? diagnostic.msgID : '（未返回）',
            LeapStyle.textPrimary)
        }
        .width('100%')
      }
      Text(`耗时这一项是判断等待窗口该设多长的唯一实测依据。`
        + `目前窗口是 ${Math.round(VehicleStore.confirmTimeoutMs / 1000)} 秒。`)
        .fontSize(11)
        .fontColor(LeapStyle.textTertiary)
        .padding({ left: 4, right: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  responsesSection(diagnostic: ControlDiagnostic) {
    Column({ space: 8 }) {
      this.sectionHeader('回执响应')
      if (diagnostic.receiptResponses.length === 0) {
        GlassCard() {
          Text('没有拿到回执响应')
            .fontSize(13)
            .fontColor(LeapStyle.textSecondary)
        }
      } else {
        ForEach(ControlDiagnosticView.groupedResponses(diagnostic), (group: ResponseGroup) => {
          Column({ space: 6 }) {
            Text(group.title)
              .fontSize(12)
              .fontColor(LeapStyle.textSecondary)
              .padding({ left: 4 })
            GlassCard() {
              Text(group.body)
                .fontSize(11)
                .fontFeature('"tnum" 1')
                .fontColor(LeapStyle.textPrimary)
                .copyOption(CopyOptions.LocalDevice)
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (group: ResponseGroup, index: number) => `${index}-${group.title}`)

        if (ControlDiagnosticView.groupedResponses(diagnostic).length === 1) {
          Text('整个过程回执没有变过——包括车况确认之后那一次。'
            + '说明这个接口不上报执行结果，只能靠车况判断。')
            .fontSize(11)
            .fontColor(LeapStyle.textTertiary)
            .padding({ left: 4, right: 4 })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  copyButton(diagnostic: ControlDiagnostic) {
    GlassCard() {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.doc_text_on_doc_text'))
          .fontSize(17)
          .fontColor([LeapStyle.cool])
        Text('拷贝全部')
          .fontSize(15)
          .fontColor(LeapStyle.cool)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.copy(ControlDiagnosticView.exportText(diagnostic));
      })
    }
  }

  @Builder
  emptyState() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.dot_radiowaves'))
        .fontSize(44)
        .fontColor([LeapStyle.textTertiary])
      Text('还没有控车记录')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textPrimary)
      Text('发一条控车指令后，这里会记下完整经过。')
        .fontSize(13)
        .fontColor(LeapStyle.textSecondary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
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
  field(label: string, value: string, tint: ResourceColor) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(LeapStyle.textSecondary)
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor(tint)
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 16 })
    }
    .width('100%')
  }

  private async copy(text: string): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.store.show('已拷贝');
    } catch (e) {
      this.store.show('拷贝失败', String(e));
    }
  }

  /**
   * 把连续相同的回执折叠成一段。
   *
   * 实测一条指令下来 6 次采样内容完全一样（`{"code":0,"data":1,"result":0}`），
   * 逐条铺开只会把页面撑满、反而看不出重点。折叠之后，
   * 一旦某次响应变了值——那正是我们要找的失败标志——会立刻多出一段。
   */
  static groupedResponses(diagnostic: ControlDiagnostic): ResponseGroup[] {
    const samples = diagnostic.receiptResponses;
    if (samples.length === 0) {
      return [];
    }
    const firsts: number[] = [];
    const lasts: number[] = [];
    const froms: number[] = [];
    const tos: number[] = [];
    const bodies: string[] = [];
    for (let i = 0; i < samples.length; i++) {
      const sample: ReceiptSample = samples[i];
      const tail = bodies.length - 1;
      if (tail >= 0 && bodies[tail] === sample.body) {
        lasts[tail] = i;
        tos[tail] = sample.at;
      } else {
        firsts.push(i);
        lasts.push(i);
        froms.push(sample.at);
        tos.push(sample.at);
        bodies.push(sample.body);
      }
    }
    const groups: ResponseGroup[] = [];
    for (let i = 0; i < bodies.length; i++) {
      const single = firsts[i] === lasts[i];
      const seconds = single
        ? `第 ${froms[i].toFixed(1)} 秒`
        : `第 ${froms[i].toFixed(1)}–${tos[i].toFixed(1)} 秒`;
      const times = single
        ? `回执 第 ${firsts[i] + 1} 次`
        : `回执 第 ${firsts[i] + 1}–${lasts[i] + 1} 次（内容相同）`;
      groups.push({ title: `${times} · ${seconds}`, body: bodies[i] });
    }
    return groups;
  }

  static outcomeText(outcome: ControlOutcome): string {
    switch (outcome) {
      case ControlOutcome.confirmed:
        return '车况已确认生效';
      case ControlOutcome.timedOut:
        return '窗口内未收到确认';
      case ControlOutcome.sentOnly:
        return '已下发（该指令无法从车况确认）';
      default:
        return '下发失败';
    }
  }

  static outcomeTint(outcome: ControlOutcome): ResourceColor {
    switch (outcome) {
      case ControlOutcome.confirmed:
        return LeapStyle.accent;
      case ControlOutcome.sentOnly:
        return LeapStyle.textSecondary;
      default:
        return LeapStyle.caution;
    }
  }

  /** "8月6日 17:32:05"。诊断要对得上车端日志，所以到秒。 */
  private static timestamp(milliseconds: number): string {
    const date = new Date(milliseconds);
    const pad = (value: number): string => value < 10 ? `0${value}` : String(value);
    return `${date.getMonth() + 1}月${date.getDate()}日 `
      + `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  }

  static exportText(diagnostic: ControlDiagnostic): string {
    const lines: string[] = [
      `指令：${diagnostic.label}（cmdid ${diagnostic.cmdid}）`,
      `结果：${ControlDiagnosticView.outcomeText(diagnostic.outcome)}`,
      `耗时：${diagnostic.elapsed.toFixed(1)} 秒，查询 ${diagnostic.pollCount} 次`,
      `msgID：${diagnostic.msgID.length > 0 ? diagnostic.msgID : '（未返回）'}`
    ];
    if (diagnostic.errorMessage !== null) {
      lines.push(`错误：${diagnostic.errorMessage}`);
    }
    for (let i = 0; i < diagnostic.receiptResponses.length; i++) {
      const sample: ReceiptSample = diagnostic.receiptResponses[i];
      lines.push(`\n回执 第 ${i + 1} 次 · 第 ${sample.at.toFixed(1)} 秒：\n${sample.body}`);
    }
    return lines.join('\n');
  }
}
