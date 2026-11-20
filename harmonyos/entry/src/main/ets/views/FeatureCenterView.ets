import { SafeAreaInsets } from '../app/SafeAreaInsets';
import { vehicleStore, VehicleStore } from '../app/VehicleStore';
import { LeapBackground } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../design/LeapStyle';
import { PageMetrics } from './components/PageHeader';

/** 功能页上的一项。 */
interface FeatureItem {
  title: string;
  detail: string;
  symbol: Resource;
  /** 详情页的路由名，见 `Index.destination`。 */
  route: string;
}

/** 一组功能。 */
interface FeatureGroup {
  name: string;
  items: FeatureItem[];
}

/**
 * 功能页（2026-11-19 随 iOS 重做）。
 *
 * 原先是一个功能一张 152 高的大玻璃卡，图标外再套圆底，滑好几屏。现在跟 iOS 定稿一致：
 * **一组一张卡，卡里两列，每格是「图标（不套圆框）+ 名字 + 一行说明」**。
 * 顶部只留一个大标题「功能」，原来叠着的「控车中心」和车名那行去掉了——车名首页已经有。
 *
 * 分组：快捷控车（原「快捷解锁」）/ 座舱 / 能源。同日去掉「车辆」组：
 * 「直进直出」整个下线（只删入口和页面，蓝牙底层 `CallCarController` 等留着）；
 * 「驻车照片」地图页位置卡上已经有，这里不再重复一个入口（页面和路由还留着）。
 *
 * iOS 特有的锁屏控件和侧边按钮不在这份列表里，鸿蒙没有对应的系统能力。
 *
 * 演示态和 iOS 一样把整个目录换成「常用功能」一组（`reviewSafeControls`），同一套宫格。
 */
@ComponentV2
export struct FeatureCenterView {
  store: VehicleStore = vehicleStore;

  /** 二级页的跳转由根页面代劳，这里只报路由名。 */
  @Event onPush: (route: string) => void = () => {
  };

  /**
   * 演示态不列未发布的能力，整页换成「常用功能」一组。
   *
   * 和 iOS 的 `showsLabCatalog` 一条规矩：审核用的演示账号看到的是一个纯控车 App。
   */
  private get showsLabCatalog(): boolean {
    return !this.store.isDemo;
  }

  private readonly catalog: FeatureGroup[] = [
    {
      name: '快捷控车',
      items: [
        {
          title: '桌面小组件',
          detail: '主屏快速控车',
          symbol: $r('sys.symbol.square_grid_2x2'),
          route: 'widgets'
        },
        {
          title: '蓝牙钥匙',
          detail: '近车直连与无感解锁',
          symbol: $r('sys.symbol.key_fill'),
          route: 'bluetoothKey'
        }
      ]
    },
    {
      name: '座舱',
      items: [
        {
          title: '舒适座舱',
          detail: '座椅加热通风、方向盘与后视镜',
          symbol: $r('sys.symbol.carseat_left_heat_waves'),
          route: 'comfortCabin'
        },
        {
          title: '车载冰箱',
          detail: '制冷保温与离车保持',
          symbol: $r('sys.symbol.mini_fridge'),
          route: 'fridge'
        }
      ]
    },
    {
      name: '能源',
      items: [
        {
          title: '电池预热',
          detail: '立即或预约加热',
          symbol: $r('sys.symbol.thermometer_medium'),
          route: 'batteryPreheat'
        },
        {
          title: '充电计划',
          detail: '预约时段、目标电量与循环日',
          symbol: $r('sys.symbol.battery_100percent'),
          route: 'chargePlan'
        }
      ]
    }
  ];

  /**
   * 这台车真摆得出来的格子。
   *
   * 舒适座舱和车载冰箱按车走：车况信号在场、或能力码有，才给入口
   * （判据见 `VehicleStore.cabinComfortSupported` / `fridgeSupported`）。
   * 实测用的那台 C16 没装冰箱，这个格子在那台车上整个不出现——照「读不到就别显示」。
   * 整组都被挡掉时连标题一起不出现，否则会剩一个底下什么都没有的小标题。
   */
  private get visibleGroups(): FeatureGroup[] {
    const out: FeatureGroup[] = [];
    for (const group of this.catalog) {
      const items = group.items.filter((item: FeatureItem): boolean => {
        if (item.route === 'comfortCabin') {
          return this.store.cabinComfortSupported;
        }
        if (item.route === 'fridge') {
          return this.store.fridgeSupported;
        }
        return true;
      });
      if (items.length > 0) {
        out.push({ name: group.name, items: items });
      }
    }
    return out;
  }

  /** 演示态的目录：三项都是已经上线的控车页，路由和车辆页上那几张卡指的是同一处。 */
  private readonly reviewSafeGroup: FeatureGroup = {
    name: '常用功能',
    items: [
      { title: '空调', detail: '温度、模式与风量', symbol: $r('sys.symbol.fan_fill_1'), route: 'climate' },
      { title: '能源', detail: '电量、续航与充电状态', symbol: $r('sys.symbol.bolt_fill'), route: 'charge' },
      { title: '车辆位置', detail: '位置与导航', symbol: $r('sys.symbol.location_up_fill'), route: 'location' }
    ]
  };

  build() {
    Stack() {
      // 底噪用青，和 iOS 功能页的 `LeapBackground(tint: LeapStyle.frost)` 同一个色。
      LeapBackground({ tint: LeapColors.frostGlow })

      Column() {
        Scroll() {
          Column({ space: 22 }) {
            // 页头跟着一起滚，和 iOS 一样。
            this.pageHeader()

            if (this.showsLabCatalog) {
              ForEach(this.visibleGroups, (group: FeatureGroup) => {
                FeatureGroupCard({
                  group: group,
                  onPush: (route: string) => {
                    this.onPush(route);
                  }
                })
              }, (group: FeatureGroup) =>
                `${group.name}|${group.items.map((item: FeatureItem): string => item.route).join(',')}`)
            } else {
              FeatureGroupCard({
                group: this.reviewSafeGroup,
                onPush: (route: string) => {
                  this.onPush(route);
                }
              })
            }

            // 底部那条浮动导航栏压在内容之上，最后一块内容自己让出它那段高度。
            Column()
              .width('100%')
              .height(PageMetrics.bottomInset)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 页头：左对齐的大标题「功能」，没有副标题行。 */
  @Builder
  pageHeader() {
    Text('功能')
      .fontSize(28)
      .fontWeight(FontWeight.Bold)
      .fontColor(LeapStyle.textPrimary)
      // 和首页标题一样：让完状态栏之后再留一段，别让大标题贴着刘海起排。
      .padding({ top: SafeAreaInsets.shared.top + 28 })
  }
}

/** 一组功能：小标题 + 一张玻璃卡，卡里两列。 */
@ComponentV2
struct FeatureGroupCard {
  @Param group: FeatureGroup = { name: '', items: [] };
  @Event onPush: (route: string) => void = () => {
  };

  build() {
    Column({ space: 8 }) {
      Text(this.group.name)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textSecondary)
        .padding({ left: 6 })

      // 两列。用 `Flex` 换行而不是 `Grid`：`Grid` 在 `Scroll` 里要自己算总高度。
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.group.items, (item: FeatureItem) => {
          FeatureGridCell({
            item: item,
            onTap: () => {
              this.onPush(item.route);
            }
          })
            .width('50%')
        }, (item: FeatureItem) => item.route)
      }
      .width('100%')
      .padding(4)
      .borderRadius(LeapStyle.tileRadius)
      .backgroundEffect(LeapMaterial.cardEffect)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 卡里的一格：图标在左，名字和一行说明在右。图标不套圆框，框里不再套框。
 *
 * 做成组件而不是带参 `@Builder`：带参 builder 是值传递，不随状态刷新。
 * 高度是 `minHeight`：系统字号调大时格子跟着长，别把说明那两行裁掉。
 */
@ComponentV2
struct FeatureGridCell {
  @Param item: FeatureItem = {
    title: '', detail: '', symbol: $r('sys.symbol.car_fill'), route: ''
  };
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: 10 }) {
      SymbolGlyph(this.item.symbol)
        .fontSize(20)
        .fontColor([LeapStyle.accent])
        .width(26)

      Column({ space: 2 }) {
        Text(this.item.title)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(LeapStyle.textPrimary)
          .maxLines(1)
        Text(this.item.detail)
          .fontSize(11)
          .fontColor(LeapStyle.textSecondary)
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: 72 })
    .padding({ left: 12, right: 12, top: 14, bottom: 14 })
    .borderRadius(LeapStyle.tileRadius - 4)
    .visualEffect(LeapMaterial.pressable)
    .accessibilityGroup(true)
    .onClick(() => {
      this.onTap();
    })
  }
}
