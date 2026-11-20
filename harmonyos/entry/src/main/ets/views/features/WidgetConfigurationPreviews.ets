import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { CarSnapshot } from '../../app/CarSnapshot';
import { WidgetAction, WidgetButtonLayout, WidgetSettings, SnapshotUtil } from '../../app/VehicleSnapshot';
import { FormPusher } from '../../app/FormPusher';
import { LeapStyle } from '../../design/LeapStyle';

// 预览只提供编辑事件，不使用服务卡片运行时的 postCardAction。
class PreviewActionStyle {
  static symbol(action: WidgetAction, locked: boolean | null, climateOn: boolean, trunkOpen: boolean): Resource {
    if (action === WidgetAction.unlock || (action === WidgetAction.toggleLock && locked === false)) {
      return $r('sys.symbol.lock_open_fill');
    }
    if (action === WidgetAction.lock || action === WidgetAction.toggleLock) { return $r('sys.symbol.lock_fill'); }
    if (action === WidgetAction.trunk) { return trunkOpen ? $r('sys.symbol.car_side_rear_open_1') : $r('sys.symbol.car_side_rear'); }
    if (action === WidgetAction.horn) { return $r('sys.symbol.horn_fill'); }
    return climateOn ? $r('sys.symbol.car_ac') : $r('sys.symbol.wind');
  }

  static fill(action: WidgetAction, locked: boolean | null, climateOn: boolean, trunkOpen: boolean): Resource {
    if (action === WidgetAction.lock || (action === WidgetAction.toggleLock && locked === true)) {
      return $r('app.color.leap_card_tile_accent');
    }
    if (action === WidgetAction.unlock || (action === WidgetAction.toggleLock && locked === false) || (action === WidgetAction.trunk && trunkOpen)) {
      return $r('app.color.leap_card_tile_caution');
    }
    if (action === WidgetAction.toggleClimate && climateOn) { return $r('app.color.leap_card_tile_cool'); }
    return $r('app.color.leap_card_tile_soft');
  }

  static tint(action: WidgetAction, locked: boolean | null, climateOn: boolean, trunkOpen: boolean): ResourceColor {
    if (action === WidgetAction.lock || (action === WidgetAction.toggleLock && locked === true)) { return LeapStyle.accent; }
    if (action === WidgetAction.unlock || (action === WidgetAction.toggleLock && locked === false) || (action === WidgetAction.trunk && trunkOpen)) { return LeapStyle.caution; }
    if (action === WidgetAction.toggleClimate && climateOn) { return LeapStyle.cool; }
    return LeapStyle.textSecondary;
  }
}

@ComponentV2
export struct WidgetConfigurationPreviews {
  store: VehicleStore = vehicleStore;
  @Local smallButtons: WidgetAction[] = WidgetSettings.buttons(true);
  @Local buttons: WidgetAction[] = WidgetSettings.buttons(false);
  @Local editingSize: number = -1;
  @Local editingIndex: number = 0;
  @Event onEditOffset: (offset: number) => void = () => {};
  private pendingScroll: number = -1;

  private sizeTitle(size: number): string {
    return size === 0 ? '小卡片' : size === 1 ? '中卡片' : '大卡片';
  }

  private edit(size: number, index: number): void {
    if (this.editingSize !== size) { this.pendingScroll = size; }
    this.editingSize = size;
    this.editingIndex = index;
  }

  private get editingActions(): WidgetAction[] {
    return this.editingSize === 0 ? this.smallButtons : this.buttons;
  }

  private replace(action: WidgetAction): void {
    const next = this.editingActions.slice();
    const previous = next.indexOf(action);
    if (previous >= 0) { next[previous] = next[this.editingIndex]; }
    next[this.editingIndex] = action;
    WidgetSettings.setButtons(this.editingSize === 0, next);
    if (this.editingSize === 0) { this.smallButtons = next; } else { this.buttons = next; }
    FormPusher.pushAll();
  }

  private move(size: number, from: number, to: number): void {
    const actions = size === 0 ? this.smallButtons : this.buttons;
    if (from < 0 || from >= actions.length || to < 0 || to >= actions.length) { return; }
    const next = WidgetButtonLayout.moving(actions, from, to);
    WidgetSettings.setButtons(size === 0, next);
    if (size === 0) { this.smallButtons = next; } else { this.buttons = next; }
    this.editingSize = size;
    this.editingIndex = to;
    FormPusher.pushAll();
  }

  build() {
    Column({ space: 20 }) {
      ForEach([0, 1, 2], (size: number) => {
        Column({ space: 10 }) {
          Row() {
            Column({ space: 3 }) {
              Text(this.sizeTitle(size)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(LeapStyle.textPrimary)
              Text(size === 0 ? '2×2 · 2 个按钮' : size === 1 ? '2×4 · 中大共用 4 个按钮' : '4×4 · 中大共用 4 个按钮')
                .fontSize(12).fontColor(LeapStyle.textSecondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph(this.editingSize === size ? $r('sys.symbol.checkmark') : $r('sys.symbol.gearshape'))
                .fontSize(18).fontColor([LeapStyle.textPrimary])
            }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText(this.editingSize === size ? '完成配置' : `配置${this.sizeTitle(size)}按钮`)
            .onClick(() => {
              if (this.editingSize === size) { this.editingSize = -1; } else { this.edit(size, 0); }
            })
          }.width('100%')
          WidgetSizePreview({ cardSize: size, actions: size === 0 ? this.smallButtons : this.buttons,
            editable: this.editingSize === size,
            selected: this.editingSize === size ? this.editingActions[this.editingIndex] : null,
            onEdit: (index: number) => { this.edit(size, index); },
            onMove: (from: number, to: number) => { this.move(size, from, to); } })
          if (this.editingSize === size) { this.actionPicker() }
        }.width('100%')
        .onAreaChange((_old: Area, area: Area) => {
          if (this.pendingScroll === size && this.editingSize === size) {
            this.pendingScroll = -1;
            this.onEditOffset(Number(area.position.y));
          }
        })
      })
      Column({ space: 12 }) {
        Text('独立控车卡片').fontSize(15).fontWeight(FontWeight.Medium).fontColor(LeapStyle.textPrimary)
        Row({ space: 12 }) {
          StandaloneControlPreview({ action: WidgetAction.lock })
          StandaloneControlPreview({ action: WidgetAction.unlock })
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ maxWidth: 420 })
  }

  @Builder
  actionPicker() {
    Column({ space: 10 }) {
      Text(`更换${WidgetButtonLayout.title(this.editingActions[this.editingIndex])}`)
        .fontSize(15).fontWeight(FontWeight.Medium).fontColor(LeapStyle.textPrimary)
      ForEach([0, 1], (row: number) => {
        Row({ space: 8 }) {
          this.actionChoice(WidgetButtonLayout.all[row * 3])
          this.actionChoice(WidgetButtonLayout.all[row * 3 + 1])
          this.actionChoice(WidgetButtonLayout.all[row * 3 + 2])
        }.width('100%')
      })
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 8, bottom: 12 })
  }

  @Builder
  actionChoice(action: WidgetAction) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 8 }) {
        SymbolGlyph(PreviewActionStyle.symbol(action, this.store.state?.isLocked ?? null, this.store.climateOn, this.store.state?.trunkOpen === true))
          .fontSize(22).fontColor([LeapStyle.textPrimary])
        Text(WidgetButtonLayout.title(action)).fontSize(12).fontWeight(FontWeight.Medium)
          .maxLines(1).fontColor(LeapStyle.textPrimary)
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      if (this.editingActions[this.editingIndex] === action) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(14).fontColor([LeapStyle.accent]).margin(5)
      }
    }
    .layoutWeight(1).height(78).borderRadius(8)
    .backgroundColor(this.editingActions[this.editingIndex] === action ? $r('app.color.leap_card_tile_accent') : $r('app.color.leap_card_tile_soft'))
    .border({ width: this.editingActions[this.editingIndex] === action ? 2 : 1,
      color: this.editingActions[this.editingIndex] === action ? LeapStyle.accent : $r('app.color.leap_card_track') })
    .onClick(() => { this.replace(action); })
  }
}

@ComponentV2
struct WidgetSizePreview {
  store: VehicleStore = vehicleStore;
  @Param cardSize: number = 0;
  @Param actions: WidgetAction[] = [];
  @Param editable: boolean = false;
  @Param selected: WidgetAction | null = null;
  @Event onEdit: (index: number) => void = () => {};
  @Event onMove: (from: number, to: number) => void = () => {};
  @Local dragging: number = -1;
  @Local dragTarget: number = -1;

  private get status(): string {
    if (this.store.state === null) { return '暂无车况'; }
    return SnapshotUtil.headline(SnapshotUtil.make(this.store.state, this.store.vehicleName, this.store.locationName, this.store.lastUpdated));
  }

  build() {
    Column() {
      if (this.cardSize === 1) {
        Row({ space: 14 }) {
          Column() {
            this.vehicleName()
            Blank()
            this.energy(false, true)
            Blank()
            Text(this.status).fontSize(10).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(LeapStyle.textSecondary)
          }.layoutWeight(1).height('100%').alignItems(HorizontalAlign.Start)
          Column({ space: 7 }) {
            this.actionGrid(2, 62)
          }.layoutWeight(1)
        }.width('100%').height('100%')
      } else {
        this.vehicleName()
        if (this.cardSize === 2) {
          PreviewCarImage().layoutWeight(1)
          Row({ space: 14 }) {
            Column() { this.energy(true) }.layoutWeight(1)
            if (this.store.state?.gasolinePercent !== null && this.store.state?.gasolinePercent !== undefined) {
              Column({ space: 5 }) {
                this.reading(this.store.state?.gasolinePercent ?? null, this.store.state?.gasolineRange ?? null)
                this.bar(this.store.state?.gasolinePercent ?? 0)
              }.layoutWeight(1)
            }
          }.width('100%')
          Blank().height(14)
          this.actionGrid(4, 64)
        } else {
          Blank()
          this.energy(false)
          Blank()
          this.actionGrid(2, 54)
        }
      }
    }
    .width(this.cardSize === 0 ? 178 : '100%').height(this.cardSize === 2 ? 350 : 178)
    .padding(this.cardSize === 2 ? 17 : 15).borderRadius(24)
    .backgroundColor($r('app.color.leap_card_bg'))
    .border({ width: 1, color: $r('app.color.leap_card_track') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  vehicleName() {
    Row() {
      Text(this.store.vehicleName).fontSize(this.cardSize === 2 ? 18 : 11).fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textSecondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      if (this.store.state?.isCharging === true) {
        SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(12).fontColor([LeapStyle.accent])
      }
    }.width('100%')
  }

  private get mediumRangeText(): string {
    const state = this.store.state;
    return state === null ? '' : SnapshotUtil.mediumRangeText(
      SnapshotUtil.make(state, this.store.vehicleName, this.store.locationName, this.store.lastUpdated));
  }

  @Builder
  energy(large: boolean, medium: boolean = false) {
    Column({ space: 5 }) {
      this.reading(this.store.state?.soc ?? null,
        medium && this.store.state?.hasFuel === true ? null :
          large && this.store.state?.hasFuel === true ? this.store.state?.energyRange ?? null : this.store.state?.expectedMileage ?? null)
      if (medium && this.store.state?.hasFuel === true && this.mediumRangeText.length > 0) {
        Text(this.mediumRangeText).fontSize(10).maxLines(1).fontColor(LeapStyle.textSecondary)
      }
      this.bar(this.store.state?.soc ?? 0)
      if (!large && this.store.state?.hasFuel === true) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.drop_fill')).fontSize(9).fontColor([LeapStyle.textSecondary])
          Column() { this.bar(this.store.state?.gasolinePercent ?? 0) }.layoutWeight(1)
        }.width('100%')
      }
    }.width('100%')
  }

  @Builder
  reading(percent: number | null, range: number | null) {
    Row({ space: 2 }) {
      Text(percent === null ? '--' : `${percent}`).fontSize(30).fontWeight(FontWeight.Medium).fontColor(LeapStyle.textPrimary)
      Text('%').fontSize(13).fontColor(LeapStyle.textSecondary).margin({ bottom: 4 })
      Blank()
      if (range !== null) { Text(`${range} km`).fontSize(10).fontColor(LeapStyle.textSecondary).margin({ bottom: 4 }) }
    }.width('100%').alignItems(VerticalAlign.Bottom)
  }

  @Builder
  bar(percent: number) {
    Progress({ value: Math.max(0, Math.min(100, percent)), total: 100, type: ProgressType.Linear })
      .color(LeapStyle.accent).backgroundColor($r('app.color.leap_card_track')).style({ strokeWidth: 5 }).width('100%')
  }

  @Builder
  actionGrid(columns: number, tileHeight: number) {
    Grid() {
      ForEach(this.actions, (action: WidgetAction, index: number) => {
        GridItem() {
          this.actionTile(action, tileHeight)
        }
        .height(tileHeight).borderRadius(14)
        .border({ width: (this.dragging >= 0 ? this.dragTarget === index : this.selected === action) ? 2 : 0,
          color: LeapStyle.accent })
        .accessibilityText(`更换${WidgetButtonLayout.title(action)}按钮`)
        .onClick(() => { this.onEdit(index); })
      }, (action: WidgetAction): string => action)
    }
    .columnsTemplate(columns === 4 ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
    .columnsGap(7).rowsGap(7).width('100%')
    .height(Math.ceil(this.actions.length / columns) * tileHeight + (Math.ceil(this.actions.length / columns) - 1) * 7)
    .editMode(this.editable).supportAnimation(true)
    .onItemDragStart((_event: ItemDragInfo, itemIndex: number) => {
      this.dragging = itemIndex;
      this.dragTarget = itemIndex;
      this.onEdit(itemIndex);
      return this.draggedTile();
    })
    .onItemDragMove((_event: ItemDragInfo, _itemIndex: number, insertIndex: number) => {
      this.dragTarget = Math.min(insertIndex, this.actions.length - 1);
    })
    .onItemDragLeave(() => { this.dragTarget = -1; })
    .onItemDrop((_event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
      if (isSuccess && this.editable) {
        this.onMove(itemIndex, Math.min(insertIndex, this.actions.length - 1));
      }
      this.dragging = -1;
      this.dragTarget = -1;
    })
  }

  @Builder
  actionTile(action: WidgetAction, tileHeight: number) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 4 }) {
        SymbolGlyph(PreviewActionStyle.symbol(action, this.store.state?.isLocked ?? null, this.store.climateOn, this.store.state?.trunkOpen === true))
          .fontSize(15).fontColor([PreviewActionStyle.tint(action, this.store.state?.isLocked ?? null, this.store.climateOn, this.store.state?.trunkOpen === true)])
        Text(action === WidgetAction.horn ? '鸣笛' : WidgetButtonLayout.title(action)).fontSize(10).maxLines(1)
          .fontColor(PreviewActionStyle.tint(action, this.store.state?.isLocked ?? null, this.store.climateOn, this.store.state?.trunkOpen === true))
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      if (this.editable) {
        SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(9).fontColor([LeapStyle.textSecondary])
          .margin(5)
      }
    }.width('100%').height(tileHeight).borderRadius(14)
    .backgroundColor(PreviewActionStyle.fill(action, this.store.state?.isLocked ?? null, this.store.climateOn, this.store.state?.trunkOpen === true))
  }

  @Builder
  draggedTile() {
    Column() {
      if (this.dragging >= 0 && this.dragging < this.actions.length) {
        this.actionTile(this.actions[this.dragging], 62)
      }
    }.width(80).height(62).borderRadius(14).backgroundColor($r('app.color.leap_card_bg'))
  }
}

@ComponentV2
struct PreviewCarImage {
  @Local imagePath: string = CarSnapshot.filePath;
  build() {
    Stack() {
      if (this.imagePath.length > 0) {
        Image(`file://${this.imagePath}`).width('80%').height('90%').objectFit(ImageFit.Contain)
      } else {
        SymbolGlyph($r('sys.symbol.car_fill')).fontSize(56).fontColor([LeapStyle.textTertiary])
      }
    }.width('100%').height('100%')
  }
}

@ComponentV2
struct StandaloneControlPreview {
  store: VehicleStore = vehicleStore;
  @Param action: WidgetAction = WidgetAction.lock;
  build() {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        Text(WidgetButtonLayout.title(this.action)).fontSize(12).fontWeight(FontWeight.Medium).fontColor(LeapStyle.textPrimary).layoutWeight(1)
        SymbolGlyph(this.action === WidgetAction.lock ? $r('sys.symbol.lock_fill') : $r('sys.symbol.lock_open_fill'))
          .fontSize(22).fontColor([this.action === WidgetAction.lock ? LeapStyle.accent : LeapStyle.caution])
      }.width('100%')
      Text(this.store.vehicleName).fontSize(10).maxLines(1).fontColor(LeapStyle.textSecondary)
      PreviewCarImage().layoutWeight(1)
      Text(this.store.state?.isLocked === true ? '已锁车' : this.store.state?.isLocked === false ? '已解锁' : '状态未知')
        .fontSize(10).fontColor(LeapStyle.textSecondary)
    }.layoutWeight(1).aspectRatio(1).padding(12).borderRadius(24)
    .alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.leap_card_bg'))
  }
}
