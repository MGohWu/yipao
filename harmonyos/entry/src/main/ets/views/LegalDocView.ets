import { util } from '@kit.ArkTS';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { SafeAreaInsets } from '../app/SafeAreaInsets';
import { LeapBackground } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { PageMetrics } from './components/PageHeader';

/**
 * 内置法律文档：用户协议、隐私政策。
 *
 * 文档源文件是 `resources/rawfile/*.md`，随包发，点开即看，不依赖网络。
 *
 * 两种呈现方式复用同一套渲染：
 * - 设置页里作为二级页压进导航栈（`overlay = false`，走 `HdsNavDestination`）；
 * - 登录页还没进导航栈，只能作为整屏浮层盖上去（`overlay = true`，自绘返回栏）。
 */
export enum LegalDoc {
  userAgreement,
  privacy
}

export class LegalDocInfo {
  static file(doc: LegalDoc): string {
    return doc === LegalDoc.privacy ? 'privacy-policy.md' : 'user-agreement.md';
  }

  static title(doc: LegalDoc): string {
    return doc === LegalDoc.privacy ? '隐私政策' : '用户协议';
  }
}

/** 一行 markdown 对应的块类型。 */
enum BlockKind {
  title,
  heading,
  bullet,
  table,
  body,
  blank
}

class DocBlock {
  kind: BlockKind;
  text: string;

  constructor(kind: BlockKind, text: string) {
    this.kind = kind;
    this.text = text;
  }
}

/** 行内片段：`**加粗**` 之内为 bold，其余普通。 */
class InlineSpan {
  text: string;
  bold: boolean;

  constructor(text: string, bold: boolean) {
    this.text = text;
    this.bold = bold;
  }
}

@ComponentV2
export struct LegalDocView {
  @Param doc: LegalDoc = LegalDoc.userAgreement;
  /** true：整屏浮层（登录页用）；false：导航二级页（设置页用）。
   * 不叫 `overlay`——那是通用属性方法名，成员撞上去编译不过。 */
  @Param showAsOverlay: boolean = false;
  /**
   * 背景光晕色，由把这一页推出来的那个页面给。
   *
   * iOS 的协议页自己不声明 tint，直接继承外面那层 `LeapBackground`；鸿蒙是每页
   * 各画各的背景，没有「上一层」可继承，所以改成让来源页把色报进来。
   * 默认冷蓝对的是「设置 → 隐私政策」这条路；登录页那条浮层自己传绿。
   */
  @Param tint: string = LeapColors.coolGlow;
  @Event onClose: () => void = () => {
  };
  @Local blocks: DocBlock[] = [];
  private insets: SafeAreaInsets = SafeAreaInsets.shared;

  aboutToAppear(): void {
    this.blocks = LegalDocView.parse(this.loadMarkdown());
  }

  /** 从 rawfile 读 markdown 原文。读不到时给一句兜底，不至于弹个空白页。 */
  private loadMarkdown(): string {
    try {
      const data = getContext(this).resourceManager.getRawFileContentSync(LegalDocInfo.file(this.doc));
      return util.TextDecoder.create('utf-8').decodeToString(data);
    } catch (e) {
      return '文档暂时无法加载，请在本项目的开源代码仓库提交 Issue。';
    }
  }

  build() {
    if (this.showAsOverlay) {
      this.overlayPage()
    } else {
      this.navPage()
    }
  }

  /** 登录页浮层：自绘一条返回栏，盖满全屏。 */
  @Builder
  overlayPage() {
    Stack() {
      LeapBackground({ tint: this.tint })

      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([LeapStyle.textPrimary])
            .onClick(() => {
              this.onClose();
            })
          Text(LegalDocInfo.title(this.doc))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(LeapStyle.textPrimary)
            .margin({ left: 8 })
          Blank()
        }
        .width('100%')
        .height(48 + this.insets.top)
        .padding({ left: 16, right: 16, top: this.insets.top })

        this.docScroll()
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 设置页二级页：标题栏交给系统。 */
  @Builder
  navPage() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: this.tint })
        // 背景照旧铺满，只有正文让开那条浮在它之上的标题栏。
        // 不能把留白写进 `docScroll`——半屏那条路自己画了头，会多让一次。
        Column() {
          this.docScroll()
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
      content: { title: { mainTitle: LegalDocInfo.title(this.doc) } },
      avoidLayoutSafeArea: true
    })
  }

  @Builder
  docScroll() {
    Scroll() {
      Column({ space: 10 }) {
        ForEach(this.blocks, (block: DocBlock, index: number) => {
          this.blockView(block)
        }, (block: DocBlock, index: number) => index.toString())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: 8, bottom: 40 })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
  }

  @Builder
  blockView(block: DocBlock) {
    if (block.kind === BlockKind.blank) {
      Column().height(2)
    } else if (block.kind === BlockKind.title) {
      this.inlineText(block.text, 22, LeapStyle.textPrimary, FontWeight.Bold)
    } else if (block.kind === BlockKind.heading) {
      this.inlineText(block.text, 17, LeapStyle.textPrimary, FontWeight.Medium)
    } else if (block.kind === BlockKind.bullet) {
      Row({ space: 8 }) {
        Text('•')
          .fontSize(15)
          .fontColor(LeapStyle.textSecondary)
        this.inlineText(block.text, 15, LeapStyle.textPrimary, FontWeight.Normal)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else if (block.kind === BlockKind.table) {
      this.inlineText(block.text, 12, LeapStyle.textSecondary, FontWeight.Normal)
    } else {
      this.inlineText(block.text, 15, LeapStyle.textPrimary, FontWeight.Normal)
    }
  }

  /** 一行带 `**加粗**` 的文本：拆成 Span，加粗段落套 Bold，其余按 baseWeight。 */
  @Builder
  inlineText(text: string, size: number, color: ResourceColor, baseWeight: FontWeight) {
    Text() {
      ForEach(LegalDocView.inlineSpans(text), (span: InlineSpan, index: number) => {
        Span(span.text)
          .fontWeight(span.bold ? FontWeight.Bold : baseWeight)
      }, (span: InlineSpan, index: number) => index.toString() + span.text)
    }
    .fontSize(size)
    .fontColor(color)
    .width('100%')
  }

  /** 把一行按 `**` 切开：偶数段普通、奇数段加粗。 */
  private static inlineSpans(text: string): InlineSpan[] {
    const parts = text.split('**');
    const spans: InlineSpan[] = [];
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].length === 0) {
        continue;
      }
      spans.push(new InlineSpan(parts[i], i % 2 === 1));
    }
    if (spans.length === 0) {
      spans.push(new InlineSpan(text, false));
    }
    return spans;
  }

  /** 逐行解析 markdown。表格分隔行（`|---|`）直接吃掉。 */
  private static parse(md: string): DocBlock[] {
    const blocks: DocBlock[] = [];
    for (const raw of md.split('\n')) {
      const t = raw.trim();
      if (t.length === 0) {
        blocks.push(new DocBlock(BlockKind.blank, ''));
      } else if (t.startsWith('## ')) {
        blocks.push(new DocBlock(BlockKind.heading, t.substring(3)));
      } else if (t.startsWith('# ')) {
        blocks.push(new DocBlock(BlockKind.title, t.substring(2)));
      } else if (t.startsWith('- ')) {
        blocks.push(new DocBlock(BlockKind.bullet, t.substring(2)));
      } else if (t.startsWith('|')) {
        const cells = t.split('|')
          .map((c: string) => c.trim())
          .filter((c: string) => c.length > 0);
        const isSeparator = cells.length > 0 && cells.every((c: string) => /^:?-+:?$/.test(c));
        if (isSeparator || cells.length === 0) {
          blocks.push(new DocBlock(BlockKind.blank, ''));
        } else {
          blocks.push(new DocBlock(BlockKind.table, cells.join('  ·  ')));
        }
      } else {
        blocks.push(new DocBlock(BlockKind.body, t));
      }
    }
    return blocks;
  }
}
