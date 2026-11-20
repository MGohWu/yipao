import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { SharedSettings } from '../../core/SharedSettings';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapStyle } from '../../design/LeapStyle';

/** 控车条上的一项。字符串值就是持久化排序时写进首选项的那个键。 */
enum QuickControl {
  /** 上锁。值沿用原来那个翻转式「车锁」的 `lock`，存过的排序不用迁移这一格。 */
  lock = 'lock',
  /** 解锁（2026-11-19 从「车锁」拆出来，同 iOS）。 */
  unlock = 'unlock',
  trunk = 'trunk',
  climate = 'climate',
  horn = 'horn',
  sentinel = 'sentinel',
  sunshade = 'sunshade',
  sunroof = 'sunroof',
  frunk = 'frunk'
}

/**
 * 排序的读写。顺序存成逗号分隔的键串（`SharedSettings` 只存字符串）。
 *
 * 读出来的顺序后面补上所有没出现过的项：新版本加了控制项时，
 * 老用户存下的那串里没有它，补在末尾而不是让它整个消失。
 */
class QuickControlOrder {
  static readonly key = 'homeQuickControlOrder';
  static readonly all: QuickControl[] = [
    QuickControl.lock, QuickControl.unlock, QuickControl.trunk, QuickControl.climate, QuickControl.horn,
    QuickControl.sentinel, QuickControl.sunshade, QuickControl.sunroof, QuickControl.frunk
  ];

  static saved(): QuickControl[] {
    return QuickControlOrder.order(SharedSettings.getString(QuickControlOrder.key, ''));
  }

  /**
   * 把存下的排序串还原成完整列表。
   *
   * 拆分之前存的排序里只有 `lock`（那时它是翻转式的「车锁」）。新出的「解锁」紧跟在它后面，
   * 不是追加到末尾——车主原来把车锁放在哪儿，上锁 / 解锁这一对就还在哪儿。
   * 其余没存过的照旧追加到末尾。
   */
  static order(raw: string): QuickControl[] {
    const decoded: QuickControl[] = [];
    for (const piece of raw.split(',')) {
      for (const known of QuickControlOrder.all) {
        if (known === piece && !decoded.includes(known)) {
          decoded.push(known);
        }
      }
    }
    if (!decoded.includes(QuickControl.unlock)) {
      const lockIndex = decoded.indexOf(QuickControl.lock);
      if (lockIndex >= 0) {
        decoded.splice(lockIndex + 1, 0, QuickControl.unlock);
      }
    }
    for (const known of QuickControlOrder.all) {
      if (!decoded.includes(known)) {
        decoded.push(known);
      }
    }
    return decoded;
  }

  static save(controls: QuickControl[]): void {
    SharedSettings.setString(QuickControlOrder.key, controls.join(','));
  }
}

/**
 * 车辆主视觉下面那张横向遥控卡。它是当前车辆的操作面板，不承担页面导航，
 * 也不固定在底栏上方——即时动作收在一张卡内，和底部一级导航形成明确的形态差异。
 *
 * 按钮文案一律是名词（空调 / 尾门 / 鸣笛……），不写「关空调」这类动作词——
 * 它们和旁边的名词按钮并排时会被读成状态。当前状态由图标和文字的颜色表达。
 *
 * **唯一的例外是「上锁」「解锁」**（2026-11-19 拆开，同 iOS）：翻转式的「车锁」要先看清
 * 现在是什么状态才知道点下去会发什么，车况一滞后就会发反。拆成两格后方向写在按钮上，
 * 点哪个发哪个；状态改由「解锁」那格在车没锁时亮琥珀色来表达，两格都始终能点
 * （车况可能滞后，重复上锁也无害，置灰反而可能把真正要按的那个灰掉）。
 *
 * 只有「反常」的那一档才上色：车没锁、尾门开着、空调开着。锁好了是常态，
 * 天天给它亮一格颜色等于每天报告一件没发生的事。
 *
 * 控制项超过一行（4 个）时收起成「前 4 个 + 行尾 chevron」，点 chevron 向下展开其余各行
 * （Grid 四列，自动按每行 4 个换行；9 项全支持时展开后是 4 + 4 + 1）。
 * 哪 4 个在收起时可见不另做编辑界面——就是长按拖拽排序：排在前面的就是常用的。
 * 车不支持的控制（判据见各 `VehicleUtil.supports*`）整格隐藏，项目不够一行就没有 chevron。
 *
 * 这里没有「车窗」：车窗不是一个按一下就完事的开关，得选开度，点了只能弹半屏。
 * 那个入口车况条的「车窗」那一格已经有了。
 *
 * 它自己不画底和圆角，那些由外面那张卡给。
 */
@ComponentV2
export struct QuickControlBar {
  /** 一行摆几个。拆出「解锁」后 9 项全支持时收起 4 个、展开后再摆两行（4 + 1）。 */
  private static readonly rowCapacity: number = 4;
  private static readonly expandedKey: string = 'homeQuickControlExpanded';
  /** 一格的高度。图标行 26 + 间距 6 + 标题 ~15 + 上下留白。 */
  private static readonly rowHeight: number = 62;

  store: VehicleStore = vehicleStore;
  /** 半屏都挂在根页面上，这里只负责请求打开。 */
  @Event onOpenSheet: (name: string) => void = () => {
  };

  @Local controls: QuickControl[] = QuickControlOrder.saved();
  /** 展开状态记住：常用第二行的人不必每次进首页都点一下。 */
  @Local expanded: boolean = SharedSettings.getBool(QuickControlBar.expandedKey, false);

  /** 读不到锁状态时按锁着画：「解锁」那格不上色。 */
  private get locked(): boolean {
    return this.store.state?.isLocked ?? true;
  }

  /** 尾门读不到就按关着画。开着是要提醒的异常，猜一个「开着」出来天天报警更糟。 */
  private get trunkOpen(): boolean {
    return this.store.state?.trunkOpen ?? false;
  }

  /** 前备箱同尾门：读不到按关着画。 */
  private get frunkOpen(): boolean {
    return this.store.state?.frontTrunkOpen ?? false;
  }

  private get isDriving(): boolean {
    return this.store.state?.isDriving === true;
  }

  /** 车不支持的控制整格隐藏（不是置灰：摆一个永远点不了的按钮等于承诺了做不到的事）。 */
  private isSupported(control: QuickControl): boolean {
    switch (control) {
      case QuickControl.sentinel:
        return this.store.sentinelSupported;
      case QuickControl.sunshade:
        return this.store.sunshadeSupported;
      case QuickControl.sunroof:
        return this.store.sunroofSupported;
      case QuickControl.frunk:
        return this.store.frunkSupported;
      default:
        return true;
    }
  }

  private get visible(): QuickControl[] {
    const out: QuickControl[] = [];
    for (const control of this.controls) {
      if (this.isSupported(control)) {
        out.push(control);
      }
    }
    return out;
  }

  private get overflow(): boolean {
    return this.visible.length > QuickControlBar.rowCapacity;
  }

  /** 当前真正摆出来的那几格：收起时只摆前一行。 */
  private get shown(): QuickControl[] {
    const visible = this.visible;
    if (this.overflow && !this.expanded) {
      return visible.slice(0, QuickControlBar.rowCapacity);
    }
    return visible;
  }

  private get gridHeight(): number {
    const rows = Math.max(1, Math.ceil(this.shown.length / QuickControlBar.rowCapacity));
    return rows * QuickControlBar.rowHeight + (rows - 1) * 8;
  }

  build() {
    Stack() {
      Row() {
        Grid() {
          ForEach(this.shown, (control: QuickControl) => {
            GridItem() {
              this.slot(control)
            }
          }, (control: QuickControl) => `${control}|${this.isActive(control)}|${this.isBlocked(control)}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .rowsGap(8)
        .layoutWeight(1)
        .height(this.gridHeight)
        // 长按拖拽排序。没有单独的编辑界面：排在前面的就是收起时看得见的那 4 个。
        .editMode(true)
        .supportAnimation(true)
        .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
          this.dragging = itemIndex;
          return this.draggedSlot();
        })
        .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
          if (isSuccess) {
            this.reorder(itemIndex, insertIndex);
          }
          this.dragging = -1;
        })

        // chevron 不占一个整格：它是布局开关不是控制项，占格会把四个真按钮挤瘦一号。
        if (this.overflow) {
          this.chevron()
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })

      if (this.store.isSendingCommand) {
        LoadingProgress()
          .width(26)
          .height(26)
          .color(LeapStyle.textPrimary)
      }
    }
    .width('100%')
    // 下发中只禁用，不整块变淡——变淡会把底和前景一起拉向背景，0.55 时正文只剩
    // 2.72:1。反馈交给上面那个 LoadingProgress。
    .enabled(!this.store.isSendingCommand)
    .animation({ duration: 200, curve: Curve.EaseOut })
  }

  /** 拖拽中那一格的下标，只给拖影用。没在拖时是 -1。 */
  @Local dragging: number = -1;

  /** 拖影。名字不能叫 dragPreview——那是 CustomComponent 自带的通用属性，会撞名（10505001）。 */
  @Builder
  draggedSlot() {
    Column() {
      if (this.dragging >= 0 && this.dragging < this.shown.length) {
        this.slot(this.shown[this.dragging])
      }
    }
    .width(80)
    .height(QuickControlBar.rowHeight)
    .borderRadius(14)
    .backgroundColor(LeapStyle.fillNeutral)
  }

  @Builder
  chevron() {
    Stack() {
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor([LeapStyle.textSecondary])
        .rotate({ angle: this.expanded ? 180 : 0 })
    }
    .width(24)
    .height(QuickControlBar.rowHeight)
    .accessibilityText(this.expanded ? '收起更多控制' : '展开更多控制')
    .onClick(() => {
      this.expanded = !this.expanded;
      SharedSettings.setBool(QuickControlBar.expandedKey, this.expanded);
    })
  }

  /**
   * 把 `shown` 里的一次拖放翻译成整份排序（`controls`）里的一次移动。
   *
   * 收起时 `shown` 只有前 4 个，下标对不上整份排序，所以要先换算回具体的控制项再挪。
   */
  private reorder(from: number, to: number): void {
    const shown = this.shown;
    if (from < 0 || from >= shown.length || to < 0 || to >= shown.length || from === to) {
      return;
    }
    const dragged = shown[from];
    const target = shown[to];
    const next = this.controls.slice();
    const sourceIndex = next.indexOf(dragged);
    const targetIndex = next.indexOf(target);
    if (sourceIndex < 0 || targetIndex < 0 || sourceIndex === targetIndex) {
      return;
    }
    next.splice(sourceIndex, 1);
    const landing = next.indexOf(target);
    next.splice(sourceIndex < targetIndex ? landing + 1 : landing, 0, dragged);
    this.controls = next;
    QuickControlOrder.save(next);
  }

  /** 这一格现在亮不亮。只有「反常」的那一档才亮，见类注释。 */
  private isActive(control: QuickControl): boolean {
    switch (control) {
      case QuickControl.unlock:
        return !this.locked;
      case QuickControl.trunk:
        return this.trunkOpen;
      case QuickControl.climate:
        return this.store.climateOn;
      case QuickControl.sentinel:
        return this.store.sentinelOn;
      case QuickControl.frunk:
        return this.frunkOpen;
      default:
        return false;
    }
  }

  /** 行驶中不给开的两格：尾门和前备箱。 */
  private isBlocked(control: QuickControl): boolean {
    if (control !== QuickControl.trunk && control !== QuickControl.frunk) {
      return false;
    }
    return this.isDriving;
  }

  @Builder
  slot(control: QuickControl) {
    if (control === QuickControl.lock) {
      // 上锁是回到常态，永远不上色。
      QuickControlButton({
        title: '上锁',
        symbol: $r('sys.symbol.lock_fill'),
        tint: LeapStyle.textPrimary,
        onTap: () => {
          this.store.lockCar();
        }
      })
    } else if (control === QuickControl.unlock) {
      // 车没锁是要提醒的反常，由这一格亮琥珀色来说。读不到锁状态时按锁着画，不上色。
      QuickControlButton({
        title: '解锁',
        symbol: $r('sys.symbol.lock_open_fill'),
        tint: LeapStyle.caution,
        active: !this.locked,
        onTap: () => {
          this.store.unlockCar();
        }
      })
    } else if (control === QuickControl.climate) {
      QuickControlButton({
        title: '空调',
        symbol: this.store.climateOn ? $r('sys.symbol.fan_fill_1') : $r('sys.symbol.car_ac'),
        tint: LeapStyle.cool,
        active: this.store.climateOn,
        onTap: () => {
          this.store.applyClimate(!this.store.climateOn);
        }
      })
    } else if (control === QuickControl.trunk) {
      QuickControlButton({
        title: '尾门',
        // sys.symbol.trunk 那一对画的是拉杆箱，不是车尾门。换成车侧影的一对：
        // 同一台车，关着是完整轮廓，开着尾门掀起来。
        symbol: this.trunkOpen ? $r('sys.symbol.car_side_rear_open_1') : $r('sys.symbol.car_side_rear'),
        tint: LeapStyle.caution,
        active: this.trunkOpen,
        blocked: this.isDriving,
        onTap: () => {
          // 不直接下发：开还是关交给半屏里的按钮，这里只负责把半屏叫出来。
          this.onOpenSheet('trunk');
        }
      })
    } else if (control === QuickControl.horn) {
      QuickControlButton({
        title: '鸣笛',
        symbol: $r('sys.symbol.horn_fill'),
        tint: LeapStyle.textPrimary,
        onTap: () => {
          this.store.honk();
        }
      })
    } else if (control === QuickControl.sentinel) {
      // 和另外三个新按钮不同，哨兵有状态回读（信号 3636）也没有物理风险，
      // 就地开关（原来那张哨兵卡就是这个交互），不弹半屏。
      QuickControlButton({
        title: '哨兵',
        symbol: this.store.sentinelOn ? $r('sys.symbol.lock_shield_fill') : $r('sys.symbol.lock_shield'),
        tint: LeapStyle.cool,
        active: this.store.sentinelOn,
        onTap: () => {
          this.store.applySentinel(!this.store.sentinelOn);
        }
      })
    } else if (control === QuickControl.sunshade) {
      // 车况里没有遮阳帘状态，图标不做两态、不上色；方向在半屏里由用户明确点。
      QuickControlButton({
        title: '遮阳帘',
        symbol: $r('sys.symbol.sunshade_top'),
        tint: LeapStyle.textPrimary,
        onTap: () => {
          this.onOpenSheet('sunshade');
        }
      })
    } else if (control === QuickControl.sunroof) {
      QuickControlButton({
        title: '天窗',
        symbol: $r('sys.symbol.car_topwindow'),
        tint: LeapStyle.textPrimary,
        onTap: () => {
          this.onOpenSheet('sunroof');
        }
      })
    } else {
      // 车头特写的一对，和尾门那对同一个语言：关着是描边、开着填实并上色。
      QuickControlButton({
        title: '前备箱',
        symbol: this.frunkOpen ? $r('sys.symbol.car_side_front_open_fill') : $r('sys.symbol.car_side_front_open'),
        tint: LeapStyle.caution,
        active: this.frunkOpen,
        blocked: this.isDriving,
        onTap: () => {
          this.onOpenSheet('frunk');
        }
      })
    }
  }
}

/**
 * 控车条里的一个动作。
 *
 * 不给底色。这一行长在一张玻璃卡的最上面，谁激活就给谁糊一块彩色圆角底的话，
 * 卡的第一行就成了几块浮在玻璃上的色块，和卡里其余几行的排版完全对不上。
 * 激活状态改由图标和文字一起上色表达——同一个信息，不额外占一层。
 */
@ComponentV2
export struct QuickControlButton {
  @Param title: string = '';
  @Param symbol: Resource = $r('sys.symbol.lock_fill');
  /** 激活时图标和文字用的颜色。 */
  @Param tint: ResourceColor = LeapStyle.textPrimary;
  /**
   * 这个动作现在是不是「亮着」的。
   *
   * 只有「反常」的那一档才亮：车没锁、空调开着、尾门开着。锁好了、关好了是常态，
   * 天天亮着等于每天报告一件没发生的事，真出事那次反而淹在里面。
   * 鸣笛是一次性动作，没有状态。
   */
  @Param active: boolean = false;
  /** 行驶中不给操作的那几格（尾门、前备箱）。点不动，但不变淡——理由同控车条。 */
  @Param blocked: boolean = false;
  @Event onTap: () => void = () => {
  };

  build() {
    Column({ space: 6 }) {
      // 八个字形高矮差着好几个点，高度交给字形自己定的话，下面那行标题就跟着各差几个点，
      // 四列横着看没有一条基线是齐的。钉死图标行的高度，符号在里头居中。
      SymbolGlyph(this.symbol)
        .fontSize(23)
        .fontColor([this.active ? this.tint : (this.blocked ? LeapStyle.textTertiary : LeapStyle.textPrimary)])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
        .height(26)
      Text(this.title)
        .fontSize(11)
        .fontColor(this.active ? this.tint : (this.blocked ? LeapStyle.textTertiary : LeapStyle.textSecondary))
        .maxLines(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .enabled(!this.blocked)
    .visualEffect(LeapMaterial.pressable)
    .onClick(() => {
      this.onTap();
    })
  }
}
